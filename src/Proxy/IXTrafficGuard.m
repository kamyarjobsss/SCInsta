#import "IXTrafficGuard.h"
#import "IXAddrCheck.h"
#import "IXSOCKSConnect.h"
#import "../Launch/IXLaunchGuard.h"

#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <netdb.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/time.h>
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
static int (*ix_orig_socket)(int, int, int) = NULL;
static int (*ix_orig_getnameinfo)(const struct sockaddr *, socklen_t, char *, socklen_t, char *, socklen_t, int) = NULL;
static int (*ix_dns_getaddrinfo)(void **, uint32_t, uint32_t, uint32_t, const char *, void *, void *) = NULL;

static pthread_mutex_t ix_ready_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ix_ready_cv = PTHREAD_COND_INITIALIZER;

static __thread int ix_tls_bypass = 0;
static __thread int ix_depth = 0;
static BOOL ix_installed = NO;

// One hook calling back into another hook on the same thread must hit libc,
// not our replacement. folly and Tigon do that while parsing an address.
static void IXDepthLeave(int *held) {
    if (held && *held) {
        ix_depth--;
        *held = 0;
    }
}

void IXTrafficGuardSetThreadBypass(BOOL bypass) {
    ix_tls_bypass = bypass ? 1 : 0;
}

#define IX_MAP_MAX 2048

typedef struct {
    uint32_t token;
    char host[256];
} IXMapEntry;

static IXMapEntry ix_map[IX_MAP_MAX];
static int ix_map_count = 0;
static uint32_t ix_next_token = 1;
static pthread_mutex_t ix_map_mu = PTHREAD_MUTEX_INITIALIZER;

static BOOL IXHostLooksSafe(const char *host) {
    if (!host || !host[0]) return NO;
    size_t n = strlen(host);
    if (n == 0 || n > 253) return NO;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)host[i];
        if (c <= 32 || c >= 127) return NO;
        if (c == '%' || c == '[' || c == ']' || c == '/' || c == '\\' || c == ' ') return NO;
    }
    return YES;
}

static uint32_t IXRememberHost(const char *host) {
    if (!IXHostLooksSafe(host)) return 0;
    char cleaned[256];
    strlcpy(cleaned, host, sizeof(cleaned));
    size_t n = strlen(cleaned);
    while (n > 0 && cleaned[n - 1] == '.') cleaned[--n] = 0;
    if (!IXHostLooksSafe(cleaned)) return 0;
    host = cleaned;
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

static BOOL IXImageIsOurs(const char *path) {
    if (!path) return NO;
    return strstr(path, "SCInsta") || strstr(path, "InstagramX") || strstr(path, "IXRayCore") || strstr(path, "libXray");
}

BOOL IXTrafficGuardAddressIsSelf(const void *returnAddress) {
    if (ix_tls_bypass) return YES;
    Dl_info info;
    if (returnAddress && dladdr(returnAddress, &info) && IXImageIsOurs(info.dli_fname)) return YES;
    return NO;
}

BOOL IXTrafficGuardCallerIsSelf(void) {
    return IXTrafficGuardAddressIsSelf(__builtin_return_address(0));
}

static void IXCopyCallerImage(char *out, size_t outLen, const void *ra) {
    if (!out || outLen == 0) return;
    out[0] = 0;
    Dl_info info;
    if (!ra || !dladdr(ra, &info) || !info.dli_fname) {
        strlcpy(out, "unknown", outLen);
        return;
    }
    const char *base = strrchr(info.dli_fname, '/');
    strlcpy(out, base ? base + 1 : info.dli_fname, outLen);
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

// fd00::/8, token in the last 32 bits. Not a public route, so a missed hook
// cannot send the packet onto the real network as a valid destination.
static void IXFillFakeV6(struct in6_addr *out, uint32_t token) {
    memset(out, 0, sizeof(*out));
    out->s6_addr[0] = 0xfd;
    uint32_t net = htonl(token);
    memcpy(out->s6_addr + 12, &net, 4);
}

static uint32_t IXTokenFromV6(const struct in6_addr *addr) {
    if (!addr || addr->s6_addr[0] != 0xfd) return 0;
    for (int i = 1; i < 12; i++) {
        if (addr->s6_addr[i] != 0) return 0;
    }
    uint32_t net = 0;
    memcpy(&net, addr->s6_addr + 12, 4);
    return ntohl(net);
}

void IXTrafficGuardSetRuntime(BOOL vpnOn, BOOL proxyUp, BOOL killSwitch, BOOL blockUDP) {
    atomic_store(&ix_vpn_on, vpnOn ? 1 : 0);
    atomic_store(&ix_kill, killSwitch ? 1 : 0);
    atomic_store(&ix_block_udp, blockUDP ? 1 : 0);
    pthread_mutex_lock(&ix_ready_mu);
    atomic_store(&ix_proxy_up, proxyUp ? 1 : 0);
    pthread_cond_broadcast(&ix_ready_cv);
    pthread_mutex_unlock(&ix_ready_mu);
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
    struct in6_addr raw;
    IXFillFakeV6(&raw, token);
    if (v4 && IXAddrFillInet(v4, IXFakeIPv4(token), 0) != 0) return NO;
    if (v6 && IXAddrFillInet6(v6, &raw, 0) != 0) return NO;
    char numeric[INET6_ADDRSTRLEN];
    if (v4 && IXAddrWriteNumeric((struct sockaddr *)v4, sizeof(*v4), numeric, sizeof(numeric)) != 0) return NO;
    if (v6 && IXAddrWriteNumeric((struct sockaddr *)v6, sizeof(*v6), numeric, sizeof(numeric)) != 0) return NO;
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

#define IX_FD_MAX 8192
#define IX_LOG_MAX 80

typedef struct {
    _Atomic int on;
    _Atomic uint64_t up;
    _Atomic uint64_t down;
    char host[80];
    char image[48];
    char api[20];
    uint16_t port;
    struct sockaddr_storage addr;
    socklen_t addrLen;
    uint8_t bypass;
} IXLiveFD;

typedef struct {
    char path[24];
    char image[48];
    char api[20];
    char host[80];
    char reason[64];
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

static void IXPushLog(const char *image, const char *api, const char *host, uint16_t port, uint64_t up, uint64_t down, const char *reason) {
    pthread_mutex_lock(&ix_fd_mu);
    IXLoggedConn *row = &ix_log[ix_log_next];
    strlcpy(row->image, image ?: "", sizeof(row->image));
    strlcpy(row->api, api ?: "", sizeof(row->api));
    strlcpy(row->path, api ?: "", sizeof(row->path));
    strlcpy(row->host, host ?: "", sizeof(row->host));
    strlcpy(row->reason, reason ?: "", sizeof(row->reason));
    row->port = port;
    row->up = up;
    row->down = down;
    ix_log_next = (ix_log_next + 1) % IX_LOG_MAX;
    if (ix_log_count < IX_LOG_MAX) ix_log_count++;
    pthread_mutex_unlock(&ix_fd_mu);
    char line[256];
    snprintf(line, sizeof(line), "%s %s %s:%u %s", image ?: "?", api ?: "connect", host ?: "?", port, reason ?: "");
    IXLaunchGuardAppendLog(line);
}

static void IXTrackFD(int fd, const struct sockaddr *addr, socklen_t len, const char *host, uint16_t port, const char *image, const char *api) {
    if ((unsigned)fd >= IX_FD_MAX || !addr || len == 0) return;
    pthread_mutex_lock(&ix_fd_mu);
    IXLiveFD *slot = &ix_live[fd];
    atomic_store(&slot->on, 0);
    socklen_t canonLen = 0;
    if (IXAddrCanonical(addr, len, &slot->addr, &canonLen) != 0) {
        pthread_mutex_unlock(&ix_fd_mu);
        return;
    }
    slot->addrLen = canonLen;
    strlcpy(slot->host, host ?: "", sizeof(slot->host));
    strlcpy(slot->image, image ?: "", sizeof(slot->image));
    strlcpy(slot->api, api ?: "connect", sizeof(slot->api));
    slot->port = port;
    atomic_store(&slot->up, 0);
    atomic_store(&slot->down, 0);
    atomic_store(&slot->on, 1);
    pthread_mutex_unlock(&ix_fd_mu);
    NSLog(@"[InstagramX] %s %s %s:%u via SOCKS", image ?: "?", api ?: "connect", host ?: "?", port);
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
    char image[48];
    char api[20];
    strlcpy(image, slot->image, sizeof(image));
    strlcpy(api, slot->api[0] ? slot->api : "close", sizeof(api));
    atomic_store(&slot->on, 0);
    slot->bypass = 0;
    pthread_mutex_unlock(&ix_fd_mu);
    IXPushLog(image, api, host, port, up, down, reason ?: "tunneled");
}

static BOOL IXFDBypass(int fd) {
    if (ix_tls_bypass) return YES;
    if ((unsigned)fd < IX_FD_MAX && ix_live[fd].bypass) return YES;
    return NO;
}

static BOOL IXShouldRedirect(int fd, const struct sockaddr *addr) {
    if (!IXTrafficGuardVPNOn() || !addr) return NO;
    if (IXFDBypass(fd)) return NO;
    if (IXAddrIsLoopback(addr)) return NO;
    if (IXSocketType(fd) != SOCK_STREAM) return NO;
    char host[256];
    uint16_t port = 0;
    if (!IXDescribe(addr, host, sizeof(host), &port)) return NO;
    return YES;
}

// Background threads wait until the inbound is up. The main thread never waits:
// a blocked connect there is what froze the splash in 2.2.0.
static BOOL IXAwaitProxy(void) {
    if (atomic_load(&ix_proxy_up)) return YES;
#if defined(__APPLE__)
    if (pthread_main_np()) return NO;
#endif
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct timespec ts;
    ts.tv_sec = tv.tv_sec + 5;
    ts.tv_nsec = tv.tv_usec * 1000;
    pthread_mutex_lock(&ix_ready_mu);
    while (!atomic_load(&ix_proxy_up)) {
        int rc = pthread_cond_timedwait(&ix_ready_cv, &ix_ready_mu, &ts);
        if (rc == ETIMEDOUT) break;
    }
    BOOL up = atomic_load(&ix_proxy_up) != 0;
    pthread_mutex_unlock(&ix_ready_mu);
    return up;
}

static void IXProxyAddress(int fd, struct sockaddr_storage *out, socklen_t *outLen) {
    memset(out, 0, sizeof(*out));
    if (IXSocketDomain(fd) == AF_INET6) {
        struct sockaddr_in6 *local = (struct sockaddr_in6 *)out;
        local->sin6_family = AF_INET6;
        local->sin6_len = sizeof(*local);
        local->sin6_port = htons(IXTrafficGuardSocksPort());
        local->sin6_addr = in6addr_loopback;
        *outLen = sizeof(*local);
        return;
    }
    struct sockaddr_in *local = (struct sockaddr_in *)out;
    local->sin_family = AF_INET;
    local->sin_len = sizeof(*local);
    local->sin_port = htons(IXTrafficGuardSocksPort());
    local->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    *outLen = sizeof(*local);
}

static int IXProxiedConnect(int fd, const struct sockaddr *addr, socklen_t len, const char *api, const char *image) {
    char host[256];
    uint16_t port = 0;
    if (!IXDescribe(addr, host, sizeof(host), &port)) {
        errno = EAFNOSUPPORT;
        return -1;
    }
    if (len == 0) len = addr->sa_family == AF_INET6 ? (socklen_t)sizeof(struct sockaddr_in6) : (socklen_t)sizeof(struct sockaddr_in);
    if (!IXAwaitProxy()) {
        if (IXTrafficGuardKillSwitch()) {
            IXPushLog(image, api, host, port, 0, 0, "blocked");
            errno = ECONNREFUSED;
            return -1;
        }
        IXPushLog(image, api, host, port, 0, 0, "direct");
        return ix_orig_connect(fd, addr, len);
    }

    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
    struct sockaddr_storage proxy;
    socklen_t proxyLen = 0;
    IXProxyAddress(fd, &proxy, &proxyLen);
    int dialed = IXSOCKSDial(fd, (const struct sockaddr *)&proxy, proxyLen, host, port);
    if (dialed == IX_SOCKS_REFUSED) {
        IXPushLog(image, api, host, port, 0, 0, "blocked");
        NSLog(@"[InstagramX] %s %s %s:%u SOCKS failed", image ?: "?", api ?: "connect", host, port);
        errno = ECONNREFUSED;
        return -1;
    }
    IXTrackFD(fd, addr, len, host, port, image, api);
    IXPushLog(image, "connect", host, port, 0, 0, "tunneled");
    if (dialed == IX_SOCKS_IN_PROGRESS) {
        errno = EINPROGRESS;
        return -1;
    }
    return 0;
}

static void IXNoteAddr(const char *image, const char *api, const struct sockaddr *addr, const char *reason);

static BOOL IXRefuseUDP(int fd, const struct sockaddr *dest, const char *api, const char *image) {
    if (!IXTrafficGuardVPNOn() || !dest || IXAddrIsLoopback(dest)) return NO;
    if (IXFDBypass(fd)) return NO;
    if (IXSocketType(fd) != SOCK_DGRAM) return NO;
    IXNoteAddr(image, api, dest, "blocked");
    errno = EPERM;
    return YES;
}

static int IXConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (ix_depth) return ix_orig_connect ? ix_orig_connect(fd, addr, len) : (errno = ENOSYS, -1);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_connect) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    if (IXTrafficGuardAddressIsSelf(caller) || IXFDBypass(fd)) return ix_orig_connect(fd, addr, len);
    char image[48];
    IXCopyCallerImage(image, sizeof(image), caller);
    if (IXSocketType(fd) == SOCK_DGRAM) {
        if (IXRefuseUDP(fd, addr, "connect", image)) return -1;
        return ix_orig_connect(fd, addr, len);
    }
    if (!IXShouldRedirect(fd, addr)) return ix_orig_connect(fd, addr, len);
    return IXProxiedConnect(fd, addr, len, "connect", image);
}

static int IXConnectX(int fd, const sa_endpoints_t *endpoints, sae_associd_t associd, unsigned int flags, const struct iovec *iov, unsigned int iovcnt, size_t *len, sae_connid_t *connid) {
    if (ix_depth) {
        return ix_orig_connectx ? ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid) : (errno = ENOTSUP, -1);
    }
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_connectx) {
        errno = ENOTSUP;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    const struct sockaddr *dest = endpoints ? endpoints->sae_dstaddr : NULL;
    socklen_t destLen = endpoints ? endpoints->sae_dstaddrlen : 0;
    if (IXTrafficGuardAddressIsSelf(caller) || IXFDBypass(fd)) {
        return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
    }
    char image[48];
    IXCopyCallerImage(image, sizeof(image), caller);
    if (dest && IXSocketType(fd) == SOCK_DGRAM) {
        if (IXRefuseUDP(fd, dest, "connectx", image)) return -1;
        return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
    }
    if (dest && IXShouldRedirect(fd, dest)) {
        int rc = IXProxiedConnect(fd, dest, destLen, "connectx", image);
        if (rc != 0 && errno != EINPROGRESS) return rc;
        if (iov && iovcnt && len) {
            size_t wrote = 0;
            for (unsigned int i = 0; i < iovcnt; i++) {
                if (!iov[i].iov_base || iov[i].iov_len == 0) continue;
                if (IXSOCKSSendAll(fd, iov[i].iov_base, iov[i].iov_len) != 0) {
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
    return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
}

static struct addrinfo *IXMakeAddrInfo(int family, int socktype, int protocol, uint16_t port, uint32_t token) {
    struct addrinfo *ai = calloc(1, sizeof(*ai));
    if (!ai) return NULL;
    char numeric[INET6_ADDRSTRLEN];
    if (family == AF_INET) {
        struct sockaddr_in *sa = calloc(1, sizeof(*sa));
        if (!sa || IXAddrFillInet(sa, IXFakeIPv4(token), htons(port)) != 0 ||
            IXAddrWriteNumeric((struct sockaddr *)sa, sizeof(*sa), numeric, sizeof(numeric)) != 0) {
            free(sa);
            free(ai);
            return NULL;
        }
        ai->ai_addr = (struct sockaddr *)sa;
        ai->ai_addrlen = sizeof(*sa);
    } else if (family == AF_INET6) {
        struct sockaddr_in6 *sa = calloc(1, sizeof(*sa));
        struct in6_addr raw;
        IXFillFakeV6(&raw, token);
        if (!sa || IXAddrFillInet6(sa, &raw, htons(port)) != 0 ||
            IXAddrWriteNumeric((struct sockaddr *)sa, sizeof(*sa), numeric, sizeof(numeric)) != 0) {
            free(sa);
            free(ai);
            return NULL;
        }
        ai->ai_addr = (struct sockaddr *)sa;
        ai->ai_addrlen = sizeof(*sa);
    } else {
        free(ai);
        return NULL;
    }
    ai->ai_flags = 0;
    ai->ai_family = family;
    ai->ai_socktype = socktype;
    ai->ai_protocol = protocol;
    // Leave ai_canonname NULL. A hostname here is what folly::IPAddress throws on.
    ai->ai_canonname = NULL;
    ai->ai_next = NULL;
    return ai;
}

static int IXGetAddrInfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (ix_depth) return ix_orig_getaddrinfo ? ix_orig_getaddrinfo(node, service, hints, res) : EAI_FAIL;
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_getaddrinfo) return EAI_FAIL;
    BOOL vpn = IXTrafficGuardVPNOn();
    if (!vpn || !node || IXTrafficGuardAddressIsSelf(__builtin_return_address(0)) || IXIsNumericHost(node)) {
        return ix_orig_getaddrinfo(node, service, hints, res);
    }
    int family = hints ? hints->ai_family : AF_UNSPEC;
    if (family != AF_UNSPEC && family != AF_INET && family != AF_INET6) {
        return ix_orig_getaddrinfo(node, service, hints, res);
    }
    uint32_t token = IXRememberHost(node);
    if (!token) return ix_orig_getaddrinfo(node, service, hints, res);

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
    if (protocol == 0) {
        if (socktype == SOCK_STREAM) protocol = IPPROTO_TCP;
        else if (socktype == SOCK_DGRAM) protocol = IPPROTO_UDP;
    }

    struct addrinfo *v4 = NULL;
    struct addrinfo *v6 = NULL;
    if (family != AF_INET6) v4 = IXMakeAddrInfo(AF_INET, socktype, protocol, port, token);
    if (family != AF_INET) v6 = IXMakeAddrInfo(AF_INET6, socktype, protocol, port, token);
    if (!v4 && !v6) return EAI_FAIL;
    if (v4 && v6) v4->ai_next = v6;
    *res = v4 ? v4 : v6;
    return 0;
}

static struct hostent *IXGetHostByName(const char *name) {
    if (ix_depth) return ix_orig_gethostbyname ? ix_orig_gethostbyname(name) : NULL;
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_gethostbyname) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    if (!IXTrafficGuardVPNOn() || !name || IXTrafficGuardAddressIsSelf(__builtin_return_address(0)) || IXIsNumericHost(name)) {
        return ix_orig_gethostbyname(name);
    }
    uint32_t token = IXRememberHost(name);
    if (!token) return ix_orig_gethostbyname(name);
    static __thread char namebuf[256];
    static __thread uint32_t addr;
    static __thread char *addrList[2];
    static __thread char *aliases[1];
    static __thread struct hostent ent;
    char numeric[INET_ADDRSTRLEN];
    struct sockaddr_in check;
    if (IXAddrFillInet(&check, IXFakeIPv4(token), 0) != 0 ||
        IXAddrWriteNumeric((struct sockaddr *)&check, sizeof(check), numeric, sizeof(numeric)) != 0) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    // h_name is the numeric address. The original hostname stays in the map
    // and is what the SOCKS handshake sends. A domain in h_name is thrown by
    // folly::IPAddress inside isHostThirdParty.
    strlcpy(namebuf, numeric, sizeof(namebuf));
    addr = check.sin_addr.s_addr;
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

static void IXNoteAddr(const char *image, const char *api, const struct sockaddr *addr, const char *reason) {
    char host[256];
    uint16_t port = 0;
    if (!addr || IXAddrIsLoopback(addr) || !IXDescribe(addr, host, sizeof(host), &port)) return;
    IXPushLog(image, api, host, port, 0, 0, reason);
}

static BOOL IXUDPShouldBlock(int fd, const struct sockaddr *dest) {
    if (!IXTrafficGuardVPNOn()) return NO;
    if (IXFDBypass(fd)) return NO;
    if (!dest || IXAddrIsLoopback(dest)) return NO;
    return IXSocketType(fd) == SOCK_DGRAM;
}

static int IXGetPeerName(int fd, struct sockaddr *addr, socklen_t *len) {
    if (ix_depth) return ix_orig_getpeername ? ix_orig_getpeername(fd, addr, len) : (errno = ENOSYS, -1);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if ((unsigned)fd < IX_FD_MAX && addr && len && *len > 0 && atomic_load(&ix_live[fd].on)) {
        pthread_mutex_lock(&ix_fd_mu);
        struct sockaddr_storage canon;
        socklen_t have = 0;
        int ok = atomic_load(&ix_live[fd].on) && IXAddrCanonical((struct sockaddr *)&ix_live[fd].addr, ix_live[fd].addrLen, &canon, &have) == 0;
        pthread_mutex_unlock(&ix_fd_mu);
        if (ok) {
            if (*len < have && canon.ss_family == AF_INET6 && *len >= (socklen_t)sizeof(struct sockaddr_in)) {
                uint32_t token = IXTokenFromV6(&((struct sockaddr_in6 *)&canon)->sin6_addr);
                if (token) {
                    struct sockaddr_in v4;
                    IXAddrFillInet(&v4, IXFakeIPv4(token), ((struct sockaddr_in6 *)&canon)->sin6_port);
                    memcpy(addr, &v4, sizeof(v4));
                    *len = (socklen_t)sizeof(v4);
                    return 0;
                }
            }
            if (*len < have) {
                errno = ENOBUFS;
                return -1;
            }
            memcpy(addr, &canon, have);
            *len = have;
            return 0;
        }
    }
    if (!ix_orig_getpeername) {
        errno = ENOSYS;
        return -1;
    }
    return ix_orig_getpeername(fd, addr, len);
}

static int IXClose(int fd) {
    if (ix_depth) return ix_orig_close ? ix_orig_close(fd) : close(fd);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    IXUntrackFD(fd, "tunneled");
    if ((unsigned)fd < IX_FD_MAX) ix_live[fd].bypass = 0;
    if (!ix_orig_close) return close(fd);
    return ix_orig_close(fd);
}

static ssize_t IXSendTo(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t destLen) {
    if (ix_depth) return ix_orig_sendto ? ix_orig_sendto(fd, buf, len, flags, dest, destLen) : (errno = ENOSYS, -1);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_sendto) {
        errno = ENOSYS;
        return -1;
    }
    if (IXSocketType(fd) == SOCK_DGRAM && IXUDPShouldBlock(fd, dest)) {
        const void *caller = __builtin_return_address(0);
        char image[48];
        IXCopyCallerImage(image, sizeof(image), caller);
        IXNoteAddr(image, "sendto", dest, "blocked");
        errno = EPERM;
        return -1;
    }
    return ix_orig_sendto(fd, buf, len, flags, dest, destLen);
}

static ssize_t IXSendMsg(int fd, const struct msghdr *msg, int flags) {
    if (ix_depth) return ix_orig_sendmsg ? ix_orig_sendmsg(fd, msg, flags) : (errno = ENOSYS, -1);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_sendmsg) {
        errno = ENOSYS;
        return -1;
    }
    if (!msg || IXSocketType(fd) != SOCK_DGRAM) return ix_orig_sendmsg(fd, msg, flags);
    const struct sockaddr *dest = msg ? (const struct sockaddr *)msg->msg_name : NULL;
    struct sockaddr_storage peer;
    if (!dest && ix_orig_getpeername) {
        socklen_t plen = sizeof(peer);
        if (ix_orig_getpeername(fd, (struct sockaddr *)&peer, &plen) == 0) dest = (struct sockaddr *)&peer;
    }
    if (IXUDPShouldBlock(fd, dest)) {
        const void *caller = __builtin_return_address(0);
        char image[48];
        IXCopyCallerImage(image, sizeof(image), caller);
        IXNoteAddr(image, "sendmsg", dest, "blocked");
        errno = EPERM;
        return -1;
    }
    return ix_orig_sendmsg(fd, msg, flags);
}

static int IXSocket(int domain, int type, int protocol) {
    if (ix_depth) return ix_orig_socket ? ix_orig_socket(domain, type, protocol) : (errno = ENOSYS, -1);
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_orig_socket) {
        errno = ENOSYS;
        return -1;
    }
    BOOL ours = IXTrafficGuardAddressIsSelf(__builtin_return_address(0));
    int fd = ix_orig_socket(domain, type, protocol);
    if (fd >= 0 && (unsigned)fd < IX_FD_MAX) {
        atomic_store(&ix_live[fd].on, 0);
        ix_live[fd].bypass = ours ? 1 : 0;
    }
    return fd;
}

static int IXWritePort(const struct sockaddr *sa, char *serv, socklen_t servlen) {
    if (!serv) return 0;
    if (servlen == 0) return EAI_OVERFLOW;
    uint16_t port = 0;
    if (sa->sa_family == AF_INET) port = ntohs(((const struct sockaddr_in *)sa)->sin_port);
    else if (sa->sa_family == AF_INET6) port = ntohs(((const struct sockaddr_in6 *)sa)->sin6_port);
    char tmp[8];
    int n = snprintf(tmp, sizeof(tmp), "%u", port);
    if (n <= 0 || (socklen_t)n + 1 > servlen) return EAI_OVERFLOW;
    memcpy(serv, tmp, (size_t)n + 1);
    return 0;
}

static int IXGetNameInfo(const struct sockaddr *sa, socklen_t salen, char *host, socklen_t hostlen, char *serv, socklen_t servlen, int flags) {
    if (ix_depth) return ix_orig_getnameinfo ? ix_orig_getnameinfo(sa, salen, host, hostlen, serv, servlen, flags) : EAI_FAIL;
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    uint32_t token = 0;
    if (sa && sa->sa_family == AF_INET && salen >= sizeof(struct sockaddr_in)) {
        token = IXTokenFromIPv4(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
    } else if (sa && sa->sa_family == AF_INET6 && salen >= sizeof(struct sockaddr_in6)) {
        token = IXTokenFromV6(&((const struct sockaddr_in6 *)sa)->sin6_addr);
    }
    // 198.18.0.0/15 has no reverse DNS. The system would return the numeric
    // form. Returning the original hostname makes folly::IPAddress throw
    // inside facebook::tigon::helpers::isHostThirdParty.
    if (IXTrafficGuardVPNOn() && token && !IXTrafficGuardAddressIsSelf(__builtin_return_address(0))) {
        if ((flags & NI_NAMEREQD) && !(flags & NI_NUMERICHOST)) {
            char name[256];
            if (!host || hostlen == 0) return EAI_NONAME;
            if (!IXLookupToken(token, name, sizeof(name)) || !IXHostLooksSafe(name)) return EAI_NONAME;
            if (strlen(name) + 1 > hostlen) return EAI_OVERFLOW;
            memcpy(host, name, strlen(name) + 1);
            return IXWritePort(sa, serv, servlen);
        }
        if (host && hostlen) {
            int rc = IXAddrWriteNumeric(sa, salen, host, hostlen);
            if (rc != 0) return rc;
        }
        return IXWritePort(sa, serv, servlen);
    }
    if (!ix_orig_getnameinfo) return EAI_FAIL;
    return ix_orig_getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
}

typedef void (*IXDNSReply)(void *, uint32_t, uint32_t, int32_t, const char *, const struct sockaddr *, uint32_t, void *);

typedef struct {
    IXDNSReply callback;
    void *context;
    char host[256];
    uint32_t token;
    int delivered;
} IXDNSBox;

static void IXDNSIgnore(void *sdRef, uint32_t flags, uint32_t interfaceIndex, int32_t errorCode, const char *hostname, const struct sockaddr *address, uint32_t ttl, void *context) {
    (void)sdRef; (void)flags; (void)interfaceIndex; (void)errorCode; (void)hostname; (void)address; (void)ttl;
    IXDNSBox *box = context;
    if (!box) return;
    if (!box->delivered && box->callback) {
        box->delivered = 1;
        struct sockaddr_in v4;
        struct sockaddr_in6 v6;
        struct in6_addr raw;
        IXFillFakeV6(&raw, box->token);
        char v4text[INET6_ADDRSTRLEN];
        char v6text[INET6_ADDRSTRLEN];
        if (IXAddrFillInet(&v4, IXFakeIPv4(box->token), 0) != 0 ||
            IXAddrFillInet6(&v6, &raw, 0) != 0 ||
            IXAddrWriteNumeric((struct sockaddr *)&v4, sizeof(v4), v4text, sizeof(v4text)) != 0 ||
            IXAddrWriteNumeric((struct sockaddr *)&v6, sizeof(v6), v6text, sizeof(v6text)) != 0) {
            box->callback(sdRef, 0, interfaceIndex, -65563, box->host[0] ? box->host : NULL, NULL, 0, box->context);
        } else {
            // hostname is the name that was queried. It is a cleaned DNS name,
            // never a half-formatted address. The sockaddr is the IP.
            const char *name = box->host[0] ? box->host : v4text;
            box->callback(sdRef, 1, interfaceIndex, 0, name, (struct sockaddr *)&v4, 60, box->context);
            box->callback(sdRef, 0, interfaceIndex, 0, name, (struct sockaddr *)&v6, 60, box->context);
        }
    }
    if ((flags & 1) == 0) free(box);
}

static int IXDNSGetAddrInfo(void **sdRef, uint32_t flags, uint32_t interfaceIndex, uint32_t protocol, const char *hostname, IXDNSReply callback, void *context) {
    if (ix_depth) return ix_dns_getaddrinfo ? ix_dns_getaddrinfo(sdRef, flags, interfaceIndex, protocol, hostname, (void *)callback, context) : -65537;
    ix_depth++;
    __attribute__((cleanup(IXDepthLeave))) int ix_held = 1;
    if (!ix_dns_getaddrinfo) return -65537;
    if (!IXTrafficGuardVPNOn() || !hostname || IXTrafficGuardAddressIsSelf(__builtin_return_address(0)) || IXIsNumericHost(hostname)) {
        return ix_dns_getaddrinfo(sdRef, flags, interfaceIndex, protocol, hostname, (void *)callback, context);
    }
    uint32_t token = IXRememberHost(hostname);
    if (!token) return ix_dns_getaddrinfo(sdRef, flags, interfaceIndex, protocol, hostname, (void *)callback, context);
    IXDNSBox *box = calloc(1, sizeof(*box));
    if (!box) return -65537;
    box->callback = callback;
    box->context = context;
    box->token = token;
    if (!IXLookupToken(token, box->host, sizeof(box->host))) box->host[0] = 0;
    int rc = ix_dns_getaddrinfo(sdRef, flags, interfaceIndex, protocol, "localhost", (void *)IXDNSIgnore, box);
    if (rc != 0) free(box);
    return rc;
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
    IXCapture("socket", (void **)&ix_orig_socket);
    IXCapture("connect", (void **)&ix_orig_connect);
    IXCapture("connectx", (void **)&ix_orig_connectx);
    IXCapture("getaddrinfo", (void **)&ix_orig_getaddrinfo);
    IXCapture("getnameinfo", (void **)&ix_orig_getnameinfo);
    IXCapture("gethostbyname", (void **)&ix_orig_gethostbyname);
    IXCapture("sendto", (void **)&ix_orig_sendto);
    IXCapture("sendmsg", (void **)&ix_orig_sendmsg);
    IXCapture("getpeername", (void **)&ix_orig_getpeername);
    IXCapture("close", (void **)&ix_orig_close);
    IXCapture("DNSServiceGetAddrInfo", (void **)&ix_dns_getaddrinfo);
    if (!ix_orig_connect) return NO;
    IXSOCKSUseConnect(ix_orig_connect);

    IXPathHookPrepare();
    const char *names[64];
    void *replacements[64];
    // FBSharedFramework imports connect, connectx, getaddrinfo, DNSServiceGetAddrInfo,
    // getpeername, sendto, sendmsg, and close. read/write/poll/kevent/select stay
    // unbound: wrapping them stalled folly's EventBase after a few kilobytes.
    struct { const char *name; void *repl; void *orig; } rows[] = {
        {"socket", (void *)IXSocket, (void *)ix_orig_socket},
        {"connect", (void *)IXConnect, (void *)ix_orig_connect},
        {"connectx", (void *)IXConnectX, (void *)ix_orig_connectx},
        {"getaddrinfo", (void *)IXGetAddrInfo, (void *)ix_orig_getaddrinfo},
        {"getnameinfo", (void *)IXGetNameInfo, (void *)ix_orig_getnameinfo},
        {"gethostbyname", (void *)IXGetHostByName, (void *)ix_orig_gethostbyname},
        {"sendto", (void *)IXSendTo, (void *)ix_orig_sendto},
        {"sendmsg", (void *)IXSendMsg, (void *)ix_orig_sendmsg},
        {"getpeername", (void *)IXGetPeerName, (void *)ix_orig_getpeername},
        {"close", (void *)IXClose, (void *)ix_orig_close},
        {"DNSServiceGetAddrInfo", (void *)IXDNSGetAddrInfo, (void *)ix_dns_getaddrinfo},
    };
    unsigned count = 0;
    for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]) && count < 64; i++) {
        if (!rows[i].orig) continue;
        names[count] = rows[i].name;
        replacements[count] = rows[i].repl;
        count++;
    }
    count += IXPathHookFill(names + count, replacements + count, 64 - count);
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
    IXPushLog("NSURLSession", "NSURLSession", host.UTF8String, port, up, down, reason.UTF8String ?: "tunneled");
}

void IXTrafficGuardNote(NSString *path, NSString *host, uint16_t port, NSString *reason) {
    IXTrafficGuardNoteFull(path, path, host, port, reason);
}

void IXTrafficGuardNoteFull(NSString *image, NSString *api, NSString *host, uint16_t port, NSString *reason) {
    IXPushLog(image.UTF8String ?: "", api.UTF8String ?: "", host.UTF8String, port, 0, 0, reason.UTF8String ?: "");
}

NSArray<NSDictionary *> *IXTrafficGuardRecentConnections(void) {
    NSMutableArray *rows = [NSMutableArray array];
    pthread_mutex_lock(&ix_fd_mu);
    for (int fd = 0; fd < IX_FD_MAX; fd++) {
        if (!atomic_load(&ix_live[fd].on)) continue;
        NSString *api = ix_live[fd].api[0] ? [NSString stringWithUTF8String:ix_live[fd].api] : @"connect";
        NSString *reason = @"tunneled";
        [rows addObject:@{
            @"image": ix_live[fd].image[0] ? [NSString stringWithUTF8String:ix_live[fd].image] : @"",
            @"api": api ?: @"",
            @"path": api ?: @"socket",
            @"host": [NSString stringWithUTF8String:ix_live[fd].host] ?: @"",
            @"port": @(ix_live[fd].port),
            @"up": @(atomic_load(&ix_live[fd].up)),
            @"down": @(atomic_load(&ix_live[fd].down)),
            @"reason": reason
        }];
    }
    int start = ix_log_count == IX_LOG_MAX ? ix_log_next : 0;
    for (int i = 0; i < ix_log_count; i++) {
        IXLoggedConn *row = &ix_log[(start + i) % IX_LOG_MAX];
        NSString *api = row->api[0] ? [NSString stringWithUTF8String:row->api] : [NSString stringWithUTF8String:row->path];
        [rows addObject:@{
            @"image": [NSString stringWithUTF8String:row->image] ?: @"",
            @"api": api ?: @"",
            @"path": api ?: @"",
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
