#import "IXTrafficGuard.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <poll.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import "IXPathHooks.h"
#import "IXSymbolRebind.h"

static _Atomic int ix_vpn_on = 0;
static _Atomic int ix_proxy_up = 0;
static _Atomic int ix_kill = 1;
static _Atomic int ix_block_udp = 1;
static _Atomic uint16_t ix_socks_port = 61850;
static _Atomic uint16_t ix_http_port = 61851;

static char ix_proxy_host[256];
static _Atomic uint16_t ix_proxy_port = 0;
static pthread_mutex_t ix_host_mu = PTHREAD_MUTEX_INITIALIZER;

static int (*ix_orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;
static int (*ix_orig_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **) = NULL;
static struct hostent *(*ix_orig_gethostbyname)(const char *) = NULL;
static ssize_t (*ix_orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*ix_orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static int (*ix_orig_connectx)(int, const sa_endpoints_t *, sae_associd_t, unsigned int, const struct iovec *, unsigned int, size_t *, sae_connid_t *) = NULL;
static int (*ix_orig_getpeername)(int, struct sockaddr *, socklen_t *) = NULL;
static int (*ix_orig_close)(int) = NULL;
static ssize_t (*ix_orig_read)(int, void *, size_t) = NULL;
static ssize_t (*ix_orig_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*ix_orig_write)(int, const void *, size_t) = NULL;
static ssize_t (*ix_orig_send)(int, const void *, size_t, int) = NULL;

static BOOL ix_installed = NO;

#define IX_MAP_MAX 2048

typedef struct {
    uint32_t token;
    char host[256];
} IXMapEntry;

static IXMapEntry ix_map[IX_MAP_MAX];
static int ix_map_count = 0;
static uint32_t ix_next_token = 1;
static pthread_mutex_t ix_map_mu = PTHREAD_MUTEX_INITIALIZER;

static uint32_t IXRememberHost(const char *host) {
    if (!host || !host[0]) return 0;
    pthread_mutex_lock(&ix_map_mu);
    for (int i = 0; i < ix_map_count; i++) {
        if (strcasecmp(ix_map[i].host, host) == 0) {
            uint32_t token = ix_map[i].token;
            pthread_mutex_unlock(&ix_map_mu);
            return token;
        }
    }
    if (ix_map_count >= IX_MAP_MAX) ix_map_count = 0;
    uint32_t token = ix_next_token++;
    // 198.18.0.0/15 has 17 host bits. Wrapping forgets the old map.
    if (token == 0 || token > 0x0001FFFFu) {
        token = 1;
        ix_next_token = 2;
        ix_map_count = 0;
    }
    ix_map[ix_map_count].token = token;
    strlcpy(ix_map[ix_map_count].host, host, sizeof(ix_map[ix_map_count].host));
    ix_map_count++;
    pthread_mutex_unlock(&ix_map_mu);
    return token;
}

static BOOL IXLookupToken(uint32_t token, char *out, size_t outLen) {
    if (!token) return NO;
    pthread_mutex_lock(&ix_map_mu);
    for (int i = 0; i < ix_map_count; i++) {
        if (ix_map[i].token == token) {
            strlcpy(out, ix_map[i].host, outLen);
            pthread_mutex_unlock(&ix_map_mu);
            return YES;
        }
    }
    pthread_mutex_unlock(&ix_map_mu);
    return NO;
}

BOOL IXTrafficGuardCallerIsSelf(void) {
    void *ra = __builtin_return_address(0);
    Dl_info info;
    if (ra && dladdr(ra, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "SCInsta") || strstr(info.dli_fname, "InstagramX") || strstr(info.dli_fname, "IXRayCore")) return YES;
    }
    return NO;
}

static BOOL IXIsNumericHost(const char *node) {
    if (!node) return NO;
    struct in_addr v4;
    struct in6_addr v6;
    return inet_pton(AF_INET, node, &v4) == 1 || inet_pton(AF_INET6, node, &v6) == 1;
}

// 198.18.0.0/15, the fake-ip range used by Clash and Surge.
// 240.0.0.0/4 is IN_BADCLASS. iOS refuses it before connect(), then cancels
// the HTTP CONNECT that was already open, which is the broken pipe on http-in.
static uint32_t IXFakeIPv4(uint32_t token) {
    return htonl(0xC6120000u | (token & 0x0001FFFFu));
}

static uint32_t IXTokenFromIPv4(uint32_t addrNetwork) {
    uint32_t host = ntohl(addrNetwork);
    if ((host & 0xFFFE0000u) != 0xC6120000u) return 0;
    return host & 0x0001FFFFu;
}

// fd00:9::/64, token in the last 32 bits. Not a public route, so a missed hook
// cannot send the packet onto the real network as a valid destination.
static void IXFillFakeV6(struct in6_addr *out, uint32_t token) {
    memset(out, 0, sizeof(*out));
    out->s6_addr[0] = 0xfd;
    out->s6_addr[3] = 0x09;
    uint32_t net = htonl(token);
    memcpy(out->s6_addr + 12, &net, 4);
}

static uint32_t IXTokenFromV6(const struct in6_addr *addr) {
    if (!addr || addr->s6_addr[0] != 0xfd || addr->s6_addr[3] != 0x09) return 0;
    for (int i = 4; i < 12; i++) {
        if (addr->s6_addr[i] != 0) return 0;
    }
    uint32_t net = 0;
    memcpy(&net, addr->s6_addr + 12, 4);
    return ntohl(net);
}

void IXTrafficGuardSetRuntime(BOOL vpnOn, BOOL proxyUp, BOOL killSwitch, BOOL blockUDP) {
    atomic_store(&ix_vpn_on, vpnOn ? 1 : 0);
    atomic_store(&ix_proxy_up, proxyUp ? 1 : 0);
    atomic_store(&ix_kill, killSwitch ? 1 : 0);
    atomic_store(&ix_block_udp, blockUDP ? 1 : 0);
}

void IXTrafficGuardSetPorts(uint16_t socksPort, uint16_t httpPort) {
    if (socksPort) atomic_store(&ix_socks_port, socksPort);
    if (httpPort) atomic_store(&ix_http_port, httpPort);
}

void IXTrafficGuardSetProxyHost(const char *host, uint16_t port) {
    pthread_mutex_lock(&ix_host_mu);
    ix_proxy_host[0] = 0;
    if (host) strlcpy(ix_proxy_host, host, sizeof(ix_proxy_host));
    pthread_mutex_unlock(&ix_host_mu);
    atomic_store(&ix_proxy_port, port);
}

NSString *IXTrafficGuardProxyHost(void) {
    pthread_mutex_lock(&ix_host_mu);
    NSString *host = ix_proxy_host[0] ? [NSString stringWithUTF8String:ix_proxy_host] : @"";
    pthread_mutex_unlock(&ix_host_mu);
    uint16_t port = atomic_load(&ix_proxy_port);
    if (host.length && port) return [NSString stringWithFormat:@"%@:%u", host, port];
    return host;
}

BOOL IXTrafficGuardVPNOn(void) { return atomic_load(&ix_vpn_on) != 0; }
BOOL IXTrafficGuardProxyUp(void) { return atomic_load(&ix_proxy_up) != 0; }
BOOL IXTrafficGuardKillSwitch(void) { return atomic_load(&ix_kill) != 0; }
BOOL IXTrafficGuardBlockUDP(void) { return atomic_load(&ix_block_udp) != 0; }
uint16_t IXTrafficGuardSocksPort(void) { return atomic_load(&ix_socks_port); }
uint16_t IXTrafficGuardHTTPPort(void) { return atomic_load(&ix_http_port); }

int IXOrigConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (ix_orig_connect) return ix_orig_connect(fd, addr, len);
    return connect(fd, addr, len);
}

int IXOrigGetaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (ix_orig_getaddrinfo) return ix_orig_getaddrinfo(node, service, hints, res);
    return getaddrinfo(node, service, hints, res);
}

NSDictionary *IXTrafficGuardProxyDictionary(void) {
    // Port 9 is closed. Callers use it to fail closed while the tunnel is down.
    uint16_t http = IXTrafficGuardProxyUp() ? IXTrafficGuardHTTPPort() : 9;
    NSNumber *port = @(http);
    // HTTPSProxy / HTTPSPort are kCFStreamPropertyHTTPSProxyHost / Port.
    // SOCKS stays off so CFNetwork does not mix a SOCKS proxy with this HTTP proxy.
    return @{
        @"HTTPEnable": @YES,
        @"HTTPProxy": @"127.0.0.1",
        @"HTTPPort": port,
        @"HTTPSEnable": @YES,
        @"HTTPSProxy": @"127.0.0.1",
        @"HTTPSPort": port,
        @"SOCKSEnable": @NO
    };
}

NSString *IXTrafficGuardLookupHost(NSString *host) {
    if (host.length == 0) return nil;
    struct in_addr v4;
    if (inet_pton(AF_INET, host.UTF8String, &v4) == 1) {
        uint32_t token = IXTokenFromIPv4(v4.s_addr);
        char name[256];
        if (token && IXLookupToken(token, name, sizeof(name))) {
            return [NSString stringWithUTF8String:name];
        }
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6, host.UTF8String, &v6) == 1) {
        uint32_t token = IXTokenFromV6(&v6);
        char name[256];
        if (token && IXLookupToken(token, name, sizeof(name))) {
            return [NSString stringWithUTF8String:name];
        }
    }
    return nil;
}

BOOL IXTrafficGuardFakeSockaddrs(const char *host, struct sockaddr_in *v4, struct sockaddr_in6 *v6) {
    if (!host || !host[0] || IXIsNumericHost(host)) return NO;
    uint32_t token = IXRememberHost(host);
    if (!token) return NO;
    if (v4) {
        memset(v4, 0, sizeof(*v4));
        v4->sin_family = AF_INET;
        v4->sin_len = sizeof(*v4);
        v4->sin_addr.s_addr = IXFakeIPv4(token);
    }
    if (v6) {
        memset(v6, 0, sizeof(*v6));
        v6->sin6_family = AF_INET6;
        v6->sin6_len = sizeof(*v6);
        IXFillFakeV6(&v6->sin6_addr, token);
    }
    return YES;
}

static BOOL IXAddrIsLoopback(const struct sockaddr *addr) {
    if (!addr) return NO;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        return (ntohl(in->sin_addr.s_addr) >> 24) == 127;
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        return IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr);
    }
    return NO;
}

static int IXSocketType(int fd) {
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) != 0) return 0;
    return type;
}

// iPhoneOS 16.2 SDK headers used by CI omit SO_DOMAIN. The value is stable in xnu.
#ifndef SO_DOMAIN
#define SO_DOMAIN 0x1009
#endif

static int IXSocketDomain(int fd) {
    int domain = 0;
    socklen_t len = sizeof(domain);
    if (getsockopt(fd, SOL_SOCKET, SO_DOMAIN, &domain, &len) != 0) return AF_UNSPEC;
    return domain;
}

static BOOL IXDescribe(const struct sockaddr *addr, char *host, size_t hostLen, uint16_t *port) {
    if (!addr || !host || !port) return NO;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        *port = ntohs(in->sin_port);
        uint32_t token = IXTokenFromIPv4(in->sin_addr.s_addr);
        if (token && IXLookupToken(token, host, hostLen)) return YES;
        return inet_ntop(AF_INET, &in->sin_addr, host, (socklen_t)hostLen) != NULL;
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        *port = ntohs(in6->sin6_port);
        uint32_t token = IXTokenFromV6(&in6->sin6_addr);
        if (token && IXLookupToken(token, host, hostLen)) return YES;
        if (IN6_IS_ADDR_V4MAPPED(&in6->sin6_addr)) {
            struct in_addr v4;
            memcpy(&v4, in6->sin6_addr.s6_addr + 12, 4);
            uint32_t mapped = IXTokenFromIPv4(v4.s_addr);
            if (mapped && IXLookupToken(mapped, host, hostLen)) return YES;
        }
        return inet_ntop(AF_INET6, &in6->sin6_addr, host, (socklen_t)hostLen) != NULL;
    }
    return NO;
}

#define IX_FD_MAX 4096
#define IX_LOG_MAX 80

typedef struct {
    _Atomic int on;
    _Atomic uint64_t up;
    _Atomic uint64_t down;
    char host[96];
    uint16_t port;
    struct sockaddr_storage addr;
    socklen_t addrLen;
} IXLiveFD;

typedef struct {
    char path[16];
    char host[96];
    char reason[96];
    uint16_t port;
    uint64_t up;
    uint64_t down;
} IXLoggedConn;

static IXLiveFD ix_live[IX_FD_MAX];
static IXLoggedConn ix_log[IX_LOG_MAX];
static int ix_log_count = 0;
static int ix_log_next = 0;
static pthread_mutex_t ix_fd_mu = PTHREAD_MUTEX_INITIALIZER;

static void IXAddBytes(int fd, uint64_t up, uint64_t down) {
    if ((unsigned)fd >= IX_FD_MAX) return;
    if (!atomic_load_explicit(&ix_live[fd].on, memory_order_relaxed)) return;
    if (up) atomic_fetch_add_explicit(&ix_live[fd].up, up, memory_order_relaxed);
    if (down) atomic_fetch_add_explicit(&ix_live[fd].down, down, memory_order_relaxed);
}

static void IXPushLog(const char *path, const char *host, uint16_t port, uint64_t up, uint64_t down, const char *reason) {
    pthread_mutex_lock(&ix_fd_mu);
    IXLoggedConn *row = &ix_log[ix_log_next];
    strlcpy(row->path, path ?: "", sizeof(row->path));
    strlcpy(row->host, host ?: "", sizeof(row->host));
    strlcpy(row->reason, reason ?: "", sizeof(row->reason));
    row->port = port;
    row->up = up;
    row->down = down;
    ix_log_next = (ix_log_next + 1) % IX_LOG_MAX;
    if (ix_log_count < IX_LOG_MAX) ix_log_count++;
    pthread_mutex_unlock(&ix_fd_mu);
}

static void IXTrackFD(int fd, const struct sockaddr *addr, socklen_t len, const char *host, uint16_t port) {
    if ((unsigned)fd >= IX_FD_MAX || !addr || len == 0) return;
    pthread_mutex_lock(&ix_fd_mu);
    IXLiveFD *slot = &ix_live[fd];
    atomic_store(&slot->on, 0);
    slot->addrLen = len < sizeof(slot->addr) ? len : (socklen_t)sizeof(slot->addr);
    memcpy(&slot->addr, addr, slot->addrLen);
    strlcpy(slot->host, host ?: "", sizeof(slot->host));
    slot->port = port;
    atomic_store(&slot->up, 0);
    atomic_store(&slot->down, 0);
    atomic_store(&slot->on, 1);
    pthread_mutex_unlock(&ix_fd_mu);
    NSLog(@"[InstagramX] socket %s:%u via SOCKS", host ?: "?", port);
}

static void IXUntrackFD(int fd, const char *reason) {
    if ((unsigned)fd >= IX_FD_MAX) return;
    if (!atomic_load_explicit(&ix_live[fd].on, memory_order_acquire)) return;
    pthread_mutex_lock(&ix_fd_mu);
    IXLiveFD *slot = &ix_live[fd];
    if (!atomic_load(&slot->on)) {
        pthread_mutex_unlock(&ix_fd_mu);
        return;
    }
    char host[96];
    strlcpy(host, slot->host, sizeof(host));
    uint16_t port = slot->port;
    uint64_t up = atomic_load(&slot->up);
    uint64_t down = atomic_load(&slot->down);
    atomic_store(&slot->on, 0);
    pthread_mutex_unlock(&ix_fd_mu);
    IXPushLog("socket", host, port, up, down, reason ?: "tunneled · closed by app");
}

static ssize_t IXOrigSendBytes(int fd, const void *buf, size_t len) {
    if (ix_orig_send) return ix_orig_send(fd, buf, len, 0);
    return send(fd, buf, len, 0);
}

static ssize_t IXOrigRecvBytes(int fd, void *buf, size_t len) {
    if (ix_orig_recv) return ix_orig_recv(fd, buf, len, 0);
    return recv(fd, buf, len, 0);
}

static BOOL IXWaitSocket(int fd, short events) {
    for (;;) {
        struct pollfd pfd = {.fd = fd, .events = events};
        int rc = poll(&pfd, 1, 5000);
        if (rc > 0) return YES;
        if (rc == 0) return NO;
        if (errno == EINTR) continue;
        return NO;
    }
}

static BOOL IXWriteFull(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        if (!IXWaitSocket(fd, POLLOUT)) return NO;
        ssize_t n = IXOrigSendBytes(fd, p + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return NO;
        }
        if (n == 0) return NO;
        sent += (size_t)n;
    }
    return YES;
}

static BOOL IXReadFull(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    size_t got = 0;
    while (got < len) {
        if (!IXWaitSocket(fd, POLLIN)) return NO;
        ssize_t n = IXOrigRecvBytes(fd, p + got, len - got);
        if (n == 0) return NO;
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            return NO;
        }
        got += (size_t)n;
    }
    return YES;
}

static BOOL IXSOCKSHandshake(int fd, const char *host, uint16_t port) {
    uint8_t hello[3] = {0x05, 0x01, 0x00};
    if (!IXWriteFull(fd, hello, sizeof(hello))) return NO;
    uint8_t method[2];
    if (!IXReadFull(fd, method, 2) || method[1] != 0x00) return NO;

    uint8_t req[512];
    size_t len = 0;
    req[len++] = 0x05;
    req[len++] = 0x01;
    req[len++] = 0x00;
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, host, &v4) == 1 && IXTokenFromIPv4(v4.s_addr) == 0) {
        req[len++] = 0x01;
        memcpy(req + len, &v4, 4);
        len += 4;
    } else if (inet_pton(AF_INET6, host, &v6) == 1) {
        req[len++] = 0x04;
        memcpy(req + len, &v6, 16);
        len += 16;
    } else {
        size_t n = strlen(host);
        if (n == 0 || n > 255) return NO;
        req[len++] = 0x03;
        req[len++] = (uint8_t)n;
        memcpy(req + len, host, n);
        len += n;
    }
    req[len++] = (uint8_t)(port >> 8);
    req[len++] = (uint8_t)(port & 0xff);
    if (!IXWriteFull(fd, req, len)) return NO;

    uint8_t reply[4];
    if (!IXReadFull(fd, reply, 4) || reply[1] != 0x00) return NO;
    size_t skip = 0;
    if (reply[3] == 0x01) skip = 4;
    else if (reply[3] == 0x04) skip = 16;
    else if (reply[3] == 0x03) {
        uint8_t nlen = 0;
        if (!IXReadFull(fd, &nlen, 1)) return NO;
        skip = nlen;
    } else return NO;
    uint8_t sink[256];
    if (skip && !IXReadFull(fd, sink, skip)) return NO;
    if (!IXReadFull(fd, sink, 2)) return NO;
    return YES;
}

static BOOL IXShouldRedirect(int fd, const struct sockaddr *addr) {
    if (!IXTrafficGuardVPNOn() || !addr) return NO;
    if (IXTrafficGuardCallerIsSelf()) return NO;
    if (IXAddrIsLoopback(addr)) return NO;
    if (IXSocketType(fd) != SOCK_STREAM) return NO;
    char host[256];
    uint16_t port = 0;
    if (!IXDescribe(addr, host, sizeof(host), &port)) return NO;
    return YES;
}

static int IXProxiedConnect(int fd, const struct sockaddr *addr) {
    if (!IXTrafficGuardProxyUp()) {
        errno = ENETUNREACH;
        return -1;
    }
    char host[256];
    uint16_t port = 0;
    if (!IXDescribe(addr, host, sizeof(host), &port)) {
        errno = EAFNOSUPPORT;
        return -1;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    BOOL nonblock = flags >= 0 && (flags & O_NONBLOCK) != 0;
    struct timeval savedRecv = {0}, savedSend = {0};
    socklen_t timeLen = sizeof(savedRecv);
    getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &savedRecv, &timeLen);
    timeLen = sizeof(savedSend);
    getsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &savedSend, &timeLen);
    struct timeval five = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &five, sizeof(five));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &five, sizeof(five));
    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
    if (nonblock && flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    int domain = IXSocketDomain(fd);
    int rc = -1;
    if (domain == AF_INET6) {
        // iOS sockets are IPV6_V6ONLY, so an IPv4-mapped 127.0.0.1 never connects.
        struct sockaddr_in6 local;
        memset(&local, 0, sizeof(local));
        local.sin6_family = AF_INET6;
        local.sin6_len = sizeof(local);
        local.sin6_port = htons(IXTrafficGuardSocksPort());
        local.sin6_addr = in6addr_loopback;
        rc = ix_orig_connect(fd, (struct sockaddr *)&local, sizeof(local));
    } else {
        struct sockaddr_in local;
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_len = sizeof(local);
        local.sin_port = htons(IXTrafficGuardSocksPort());
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        rc = ix_orig_connect(fd, (struct sockaddr *)&local, sizeof(local));
    }
    if (rc != 0 && errno == EINPROGRESS) {
        rc = IXWaitSocket(fd, POLLOUT) ? 0 : -1;
        if (rc == 0) {
            int soerr = 0;
            socklen_t sl = sizeof(soerr);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
            if (soerr != 0) {
                errno = soerr;
                rc = -1;
            }
        }
    }
    BOOL ok = rc == 0 && IXSOCKSHandshake(fd, host, port);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &savedRecv, sizeof(savedRecv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &savedSend, sizeof(savedSend));
    if (nonblock && flags >= 0) fcntl(fd, F_SETFL, flags);
    if (!ok) {
        IXPushLog("socket", host, port, 0, 0, rc != 0 ? "could not reach the local SOCKS port" : "SOCKS handshake failed");
        NSLog(@"[InstagramX] socket %s:%u SOCKS failed (%s)", host, port, rc != 0 ? "connect" : "handshake");
        shutdown(fd, SHUT_RDWR);
        errno = rc != 0 ? ENETUNREACH : ECONNREFUSED;
        return -1;
    }
    socklen_t trackedLen = domain == AF_INET6 ? (socklen_t)sizeof(struct sockaddr_in6) : (socklen_t)sizeof(struct sockaddr_in);
    if (addr->sa_family == AF_INET) trackedLen = (socklen_t)sizeof(struct sockaddr_in);
    else if (addr->sa_family == AF_INET6) trackedLen = (socklen_t)sizeof(struct sockaddr_in6);
    IXTrackFD(fd, addr, trackedLen, host, port);
    return 0;
}

static void IXNoteAddr(const char *path, const struct sockaddr *addr, const char *reason);

static int IXConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!ix_orig_connect) {
        errno = ENOSYS;
        return -1;
    }
    if (IXSocketType(fd) == SOCK_DGRAM) {
        if (IXTrafficGuardVPNOn() && IXTrafficGuardBlockUDP() && !IXTrafficGuardCallerIsSelf() && !IXAddrIsLoopback(addr)) {
            IXNoteAddr("udp", addr, "blocked");
            errno = EPERM;
            return -1;
        }
        return ix_orig_connect(fd, addr, len);
    }
    if (!IXShouldRedirect(fd, addr)) return ix_orig_connect(fd, addr, len);
    if (!IXTrafficGuardProxyUp()) {
        if (IXTrafficGuardKillSwitch()) {
            IXNoteAddr("socket", addr, "blocked by kill switch");
            errno = ENETUNREACH;
            return -1;
        }
        IXNoteAddr("socket", addr, "direct");
        return ix_orig_connect(fd, addr, len);
    }
    return IXProxiedConnect(fd, addr);
}

static int IXConnectX(int fd, const sa_endpoints_t *endpoints, sae_associd_t associd, unsigned int flags, const struct iovec *iov, unsigned int iovcnt, size_t *len, sae_connid_t *connid) {
    if (!ix_orig_connectx) {
        errno = ENOTSUP;
        return -1;
    }
    const struct sockaddr *dest = endpoints ? endpoints->sae_dstaddr : NULL;
    if (dest && IXShouldRedirect(fd, dest)) {
        // connectx can send the first bytes with the handshake. Finish SOCKS first,
        // then write those bytes, so they are not mistaken for the SOCKS greeting.
        if (!IXTrafficGuardProxyUp()) {
            if (IXTrafficGuardKillSwitch()) {
                IXNoteAddr("socket", dest, "blocked by kill switch");
                errno = ENETUNREACH;
                return -1;
            }
            IXNoteAddr("socket", dest, "direct");
            return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
        }
        int rc = IXProxiedConnect(fd, dest);
        if (rc != 0) return rc;
        if (iov && iovcnt && len) {
            size_t wrote = 0;
            for (unsigned int i = 0; i < iovcnt; i++) {
                if (!IXWriteFull(fd, iov[i].iov_base, iov[i].iov_len)) {
                    errno = EPIPE;
                    return -1;
                }
                wrote += iov[i].iov_len;
            }
            *len = wrote;
            IXAddBytes(fd, wrote, 0);
        }
        if (connid) *connid = SAE_CONNID_ANY;
        return 0;
    }
    if (dest && IXSocketType(fd) == SOCK_DGRAM && IXTrafficGuardVPNOn() && IXTrafficGuardBlockUDP() && !IXTrafficGuardCallerIsSelf() && !IXAddrIsLoopback(dest)) {
        IXNoteAddr("udp", dest, "blocked");
        errno = EPERM;
        return -1;
    }
    return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
}

static int IXGetAddrInfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (!ix_orig_getaddrinfo) return EAI_FAIL;
    BOOL vpn = IXTrafficGuardVPNOn();
    if (!vpn || !node || IXTrafficGuardCallerIsSelf() || IXIsNumericHost(node)) {
        return ix_orig_getaddrinfo(node, service, hints, res);
    }
    int family = hints ? hints->ai_family : AF_UNSPEC;
    uint32_t token = IXRememberHost(node);
    if (!token) return EAI_FAIL;

    uint16_t port = 0;
    if (service && service[0]) {
        int parsed = atoi(service);
        if (parsed <= 0 || parsed > 65535) {
            struct servent *se = getservbyname(service, "tcp");
            if (se) parsed = ntohs(se->s_port);
        }
        if (parsed > 0 && parsed < 65536) port = (uint16_t)parsed;
    }
    int socktype = hints && hints->ai_socktype ? hints->ai_socktype : SOCK_STREAM;
    int protocol = hints ? hints->ai_protocol : 0;

    struct addrinfo *v4 = NULL;
    struct addrinfo *v6 = NULL;
    if (family != AF_INET6) {
        v4 = calloc(1, sizeof(struct addrinfo));
        struct sockaddr_in *sa = calloc(1, sizeof(struct sockaddr_in));
        if (!v4 || !sa) {
            free(v4);
            free(sa);
            return EAI_MEMORY;
        }
        sa->sin_family = AF_INET;
        sa->sin_len = sizeof(*sa);
        sa->sin_port = htons(port);
        sa->sin_addr.s_addr = IXFakeIPv4(token);
        v4->ai_family = AF_INET;
        v4->ai_socktype = socktype;
        v4->ai_protocol = protocol;
        v4->ai_addrlen = sizeof(*sa);
        v4->ai_addr = (struct sockaddr *)sa;
    }
    if (family != AF_INET) {
        v6 = calloc(1, sizeof(struct addrinfo));
        struct sockaddr_in6 *sa6 = calloc(1, sizeof(struct sockaddr_in6));
        if (!v6 || !sa6) {
            free(v6);
            free(sa6);
            if (v4) {
                free(v4->ai_addr);
                free(v4);
            }
            return EAI_MEMORY;
        }
        sa6->sin6_family = AF_INET6;
        sa6->sin6_len = sizeof(*sa6);
        sa6->sin6_port = htons(port);
        IXFillFakeV6(&sa6->sin6_addr, token);
        v6->ai_family = AF_INET6;
        v6->ai_socktype = socktype;
        v6->ai_protocol = protocol;
        v6->ai_addrlen = sizeof(*sa6);
        v6->ai_addr = (struct sockaddr *)sa6;
    }
    if (v4 && v6) v4->ai_next = v6;
    *res = v4 ?: v6;
    return 0;
}

static struct hostent *IXGetHostByName(const char *name) {
    if (!ix_orig_gethostbyname) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    if (!IXTrafficGuardVPNOn() || !name || IXTrafficGuardCallerIsSelf() || IXIsNumericHost(name)) {
        return ix_orig_gethostbyname(name);
    }
    uint32_t token = IXRememberHost(name);
    if (!token) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    static __thread char namebuf[256];
    static __thread uint32_t addr;
    static __thread char *addrList[2];
    static __thread char *aliases[1];
    static __thread struct hostent ent;
    strlcpy(namebuf, name, sizeof(namebuf));
    addr = IXFakeIPv4(token);
    addrList[0] = (char *)&addr;
    addrList[1] = NULL;
    aliases[0] = NULL;
    ent.h_name = namebuf;
    ent.h_aliases = aliases;
    ent.h_addrtype = AF_INET;
    ent.h_length = 4;
    ent.h_addr_list = addrList;
    return &ent;
}

static void IXNoteAddr(const char *path, const struct sockaddr *addr, const char *reason) {
    char host[256];
    uint16_t port = 0;
    if (!addr || IXAddrIsLoopback(addr) || !IXDescribe(addr, host, sizeof(host), &port)) return;
    IXPushLog(path, host, port, 0, 0, reason);
}

static BOOL IXUDPShouldBlock(int fd, const struct sockaddr *dest) {
    if (!IXTrafficGuardVPNOn() || !IXTrafficGuardBlockUDP()) return NO;
    if (IXTrafficGuardCallerIsSelf()) return NO;
    if (!dest || IXAddrIsLoopback(dest)) return NO;
    return IXSocketType(fd) == SOCK_DGRAM;
}

static int IXGetPeerName(int fd, struct sockaddr *addr, socklen_t *len) {
    if ((unsigned)fd < IX_FD_MAX && addr && len && atomic_load(&ix_live[fd].on)) {
        pthread_mutex_lock(&ix_fd_mu);
        socklen_t have = ix_live[fd].addrLen;
        if (atomic_load(&ix_live[fd].on) && have > 0) {
            socklen_t copy = have < *len ? have : *len;
            memcpy(addr, &ix_live[fd].addr, copy);
            *len = have;
            pthread_mutex_unlock(&ix_fd_mu);
            return 0;
        }
        pthread_mutex_unlock(&ix_fd_mu);
    }
    if (!ix_orig_getpeername) {
        errno = ENOSYS;
        return -1;
    }
    return ix_orig_getpeername(fd, addr, len);
}

static BOOL IXDatagramBlocked(int fd) {
    if (!IXTrafficGuardVPNOn() || !IXTrafficGuardBlockUDP()) return NO;
    if (IXTrafficGuardCallerIsSelf()) return NO;
    if (IXSocketType(fd) != SOCK_DGRAM) return NO;
    struct sockaddr_storage peer;
    socklen_t len = sizeof(peer);
    if (getpeername(fd, (struct sockaddr *)&peer, &len) == 0 && IXAddrIsLoopback((struct sockaddr *)&peer)) return NO;
    return YES;
}

static int IXClose(int fd) {
    IXUntrackFD(fd, "tunneled · closed by app");
    if (!ix_orig_close) return close(fd);
    return ix_orig_close(fd);
}

static ssize_t IXRead(int fd, void *buf, size_t len) {
    if (IXDatagramBlocked(fd)) {
        IXPushLog("udp", "", 0, 0, 0, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_read) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t n = ix_orig_read(fd, buf, len);
    if (n > 0) IXAddBytes(fd, 0, (uint64_t)n);
    return n;
}

static ssize_t IXRecv(int fd, void *buf, size_t len, int flags) {
    if (IXDatagramBlocked(fd)) {
        IXPushLog("udp", "", 0, 0, 0, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_recv) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t n = ix_orig_recv(fd, buf, len, flags);
    if (n > 0) IXAddBytes(fd, 0, (uint64_t)n);
    return n;
}

static ssize_t IXWrite(int fd, const void *buf, size_t len) {
    if (IXDatagramBlocked(fd)) {
        IXPushLog("udp", "", 0, 0, 0, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_write) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t n = ix_orig_write(fd, buf, len);
    if (n > 0) IXAddBytes(fd, (uint64_t)n, 0);
    return n;
}

static ssize_t IXSend(int fd, const void *buf, size_t len, int flags) {
    if (IXDatagramBlocked(fd)) {
        IXPushLog("udp", "", 0, 0, 0, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_send) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t n = ix_orig_send(fd, buf, len, flags);
    if (n > 0) IXAddBytes(fd, (uint64_t)n, 0);
    return n;
}

static ssize_t IXSendTo(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t destLen) {
    if (IXUDPShouldBlock(fd, dest)) {
        IXNoteAddr("udp", dest, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_sendto) {
        errno = ENOSYS;
        return -1;
    }
    return ix_orig_sendto(fd, buf, len, flags, dest, destLen);
}

static ssize_t IXSendMsg(int fd, const struct msghdr *msg, int flags) {
    const struct sockaddr *dest = msg ? msg->msg_name : NULL;
    if (IXUDPShouldBlock(fd, dest)) {
        IXNoteAddr("udp", dest, "blocked");
        errno = EPERM;
        return -1;
    }
    if (!ix_orig_sendmsg) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t n = ix_orig_sendmsg(fd, msg, flags);
    if (n > 0) IXAddBytes(fd, (uint64_t)n, 0);
    return n;
}

static void IXCapture(const char *name, void **slot) {
    if (*slot) return;
    *slot = dlsym(RTLD_DEFAULT, name);
    if (!*slot) NSLog(@"[InstagramX] traffic symbol missing: %s", name);
}

BOOL IXTrafficGuardInstall(void) {
#if IX_LITE
    return NO;
#else
    if (ix_installed) return YES;
    IXCapture("connect", (void **)&ix_orig_connect);
    IXCapture("connectx", (void **)&ix_orig_connectx);
    IXCapture("getaddrinfo", (void **)&ix_orig_getaddrinfo);
    IXCapture("gethostbyname", (void **)&ix_orig_gethostbyname);
    IXCapture("sendto", (void **)&ix_orig_sendto);
    IXCapture("sendmsg", (void **)&ix_orig_sendmsg);
    IXCapture("getpeername", (void **)&ix_orig_getpeername);
    IXCapture("close", (void **)&ix_orig_close);
    IXCapture("read", (void **)&ix_orig_read);
    IXCapture("recv", (void **)&ix_orig_recv);
    IXCapture("write", (void **)&ix_orig_write);
    IXCapture("send", (void **)&ix_orig_send);
    if (!ix_orig_connect) return NO;

    IXPathHookPrepare();
    const char *names[32];
    void *replacements[32];
    const char *baseNames[] = {
        "connect", "connectx", "getaddrinfo", "gethostbyname", "sendto", "sendmsg",
        "getpeername", "close", "read", "recv", "write", "send"
    };
    void *baseReplacements[] = {
        (void *)IXConnect,
        (void *)IXConnectX,
        (void *)IXGetAddrInfo,
        (void *)IXGetHostByName,
        (void *)IXSendTo,
        (void *)IXSendMsg,
        (void *)IXGetPeerName,
        (void *)IXClose,
        (void *)IXRead,
        (void *)IXRecv,
        (void *)IXWrite,
        (void *)IXSend
    };
    unsigned count = 0;
    for (unsigned i = 0; i < sizeof(baseNames) / sizeof(baseNames[0]) && count < 32; i++) {
        names[count] = baseNames[i];
        replacements[count] = baseReplacements[i];
        count++;
    }
    count += IXPathHookFill(names + count, replacements + count, 32 - count);
    int patched = IXSymbolRebindSlots(names, replacements, count);
    if (patched <= 0) {
        NSLog(@"[InstagramX] traffic rebind found no symbol pointers");
        return NO;
    }
    ix_installed = YES;
    IXTrafficHooksInstall();
    NSLog(@"[InstagramX] rebound %d symbol pointers", patched);
    return YES;
#endif
}

void IXTrafficGuardUninstall(void) {
    if (!ix_installed) return;
    IXSymbolRebindRestore();
    ix_installed = NO;
    for (int fd = 0; fd < IX_FD_MAX; fd++) atomic_store(&ix_live[fd].on, 0);
}

void IXTrafficGuardNoteSession(NSString *host, uint16_t port, uint64_t up, uint64_t down, NSString *reason) {
    IXPushLog("NSURLSession", host.UTF8String, port, up, down, reason.UTF8String ?: "completed");
}

void IXTrafficGuardNote(NSString *path, NSString *host, uint16_t port, NSString *reason) {
    IXPushLog(path.UTF8String ?: "path", host.UTF8String, port, 0, 0, reason.UTF8String ?: "");
}

NSArray<NSDictionary *> *IXTrafficGuardRecentConnections(void) {
    NSMutableArray *rows = [NSMutableArray array];
    pthread_mutex_lock(&ix_fd_mu);
    for (int fd = 0; fd < IX_FD_MAX; fd++) {
        if (!atomic_load(&ix_live[fd].on)) continue;
        [rows addObject:@{
            @"path": @"socket",
            @"host": [NSString stringWithUTF8String:ix_live[fd].host] ?: @"",
            @"port": @(ix_live[fd].port),
            @"up": @(atomic_load(&ix_live[fd].up)),
            @"down": @(atomic_load(&ix_live[fd].down)),
            @"reason": @"tunneled"
        }];
    }
    int start = ix_log_count == IX_LOG_MAX ? ix_log_next : 0;
    for (int i = 0; i < ix_log_count; i++) {
        IXLoggedConn *row = &ix_log[(start + i) % IX_LOG_MAX];
        [rows addObject:@{
            @"path": [NSString stringWithUTF8String:row->path] ?: @"",
            @"host": [NSString stringWithUTF8String:row->host] ?: @"",
            @"port": @(row->port),
            @"up": @(row->up),
            @"down": @(row->down),
            @"reason": [NSString stringWithUTF8String:row->reason] ?: @""
        }];
    }
    pthread_mutex_unlock(&ix_fd_mu);
    return rows;
}
