#import "IXTrafficGuard.h"

#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <substrate.h>

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
    if (token == 0 || token > 0x00FFFFFFu) {
        token = ix_next_token = 1;
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

static BOOL IXCallerIsSelf(void) {
    void *ra = __builtin_return_address(0);
    Dl_info info;
    if (ra && dladdr(ra, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "SCInsta") || strstr(info.dli_fname, "InstagramX")) return YES;
    }
    return NO;
}

static BOOL IXIsNumericHost(const char *node) {
    if (!node) return NO;
    struct in_addr v4;
    struct in6_addr v6;
    return inet_pton(AF_INET, node, &v4) == 1 || inet_pton(AF_INET6, node, &v6) == 1;
}

static BOOL IXHostIsProxy(const char *host) {
    if (!host) return NO;
    pthread_mutex_lock(&ix_host_mu);
    BOOL match = ix_proxy_host[0] && strcasecmp(host, ix_proxy_host) == 0;
    pthread_mutex_unlock(&ix_host_mu);
    return match;
}

static uint32_t IXFakeIPv4(uint32_t token) {
    return htonl(0xF0000000u | (token & 0x00FFFFFFu));
}

static uint32_t IXTokenFromIPv4(uint32_t addrNetwork) {
    uint32_t host = ntohl(addrNetwork);
    if ((host & 0xF0000000u) != 0xF0000000u) return 0;
    return host & 0x00FFFFFFu;
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
    uint16_t http = IXTrafficGuardHTTPPort();
    return @{
        @"HTTPEnable": @YES,
        @"HTTPProxy": @"127.0.0.1",
        @"HTTPPort": @(http),
        @"HTTPSEnable": @YES,
        @"HTTPSProxy": @"127.0.0.1",
        @"HTTPSPort": @(http)
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
    return nil;
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
        return inet_ntop(AF_INET6, &in6->sin6_addr, host, (socklen_t)hostLen) != NULL;
    }
    return NO;
}

static BOOL IXWriteFull(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
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
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n == 0) return NO;
        if (n < 0) {
            if (errno == EINTR) continue;
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
    if (IXCallerIsSelf()) return NO;
    if (IXAddrIsLoopback(addr)) return NO;
    if (IXSocketType(fd) != SOCK_STREAM) return NO;
    char host[256];
    uint16_t port = 0;
    if (!IXDescribe(addr, host, sizeof(host), &port)) return NO;
    if (IXHostIsProxy(host) && port == atomic_load(&ix_proxy_port)) return NO;
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
    BOOL nonblock = (flags & O_NONBLOCK) != 0;
    if (nonblock) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);

    int domain = IXSocketDomain(fd);
    int rc = -1;
    if (domain == AF_INET6) {
        struct sockaddr_in6 local;
        memset(&local, 0, sizeof(local));
        local.sin6_family = AF_INET6;
        local.sin6_len = sizeof(local);
        local.sin6_port = htons(IXTrafficGuardSocksPort());
        inet_pton(AF_INET6, "::ffff:127.0.0.1", &local.sin6_addr);
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
    if (rc != 0) {
        if (nonblock) fcntl(fd, F_SETFL, flags);
        errno = ENETUNREACH;
        return -1;
    }
    BOOL ok = IXSOCKSHandshake(fd, host, port);
    if (nonblock) fcntl(fd, F_SETFL, flags);
    if (!ok) {
        errno = ECONNREFUSED;
        return -1;
    }
    return 0;
}

static int IXConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!ix_orig_connect) return connect(fd, addr, len);
    if (IXSocketType(fd) == SOCK_DGRAM) {
        if (IXTrafficGuardVPNOn() && IXTrafficGuardBlockUDP() && !IXCallerIsSelf() && !IXAddrIsLoopback(addr)) {
            errno = EPERM;
            return -1;
        }
        return ix_orig_connect(fd, addr, len);
    }
    if (!IXShouldRedirect(fd, addr)) return ix_orig_connect(fd, addr, len);
    if (!IXTrafficGuardProxyUp()) {
        if (IXTrafficGuardKillSwitch()) {
            errno = ENETUNREACH;
            return -1;
        }
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
                errno = ENETUNREACH;
                return -1;
            }
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
        }
        if (connid) *connid = SAE_CONNID_ANY;
        return 0;
    }
    if (dest && IXSocketType(fd) == SOCK_DGRAM && IXTrafficGuardVPNOn() && IXTrafficGuardBlockUDP() && !IXCallerIsSelf() && !IXAddrIsLoopback(dest)) {
        errno = EPERM;
        return -1;
    }
    return ix_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
}

static int IXGetAddrInfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (!ix_orig_getaddrinfo) return getaddrinfo(node, service, hints, res);
    BOOL vpn = IXTrafficGuardVPNOn();
    if (!vpn || !node || IXCallerIsSelf() || IXHostIsProxy(node) || IXIsNumericHost(node)) {
        return ix_orig_getaddrinfo(node, service, hints, res);
    }
    int family = hints ? hints->ai_family : AF_UNSPEC;
    if (family == AF_INET6) {
        // No public IPv6 fake range that freeaddrinfo can safely own without also
        // teaching connect() about it. Fail the v6 lookup so clients retry v4,
        // which we can rewrite. Kill-switch: do not fall through to the real resolver.
        return EAI_NONAME;
    }

    uint32_t token = IXRememberHost(node);
    if (!token) return EAI_FAIL;
    struct addrinfo *ai = calloc(1, sizeof(struct addrinfo));
    struct sockaddr_in *sa = calloc(1, sizeof(struct sockaddr_in));
    if (!ai || !sa) {
        free(ai);
        free(sa);
        return EAI_MEMORY;
    }
    sa->sin_family = AF_INET;
    sa->sin_len = sizeof(struct sockaddr_in);
    sa->sin_addr.s_addr = IXFakeIPv4(token);
    if (service && service[0]) {
        int port = atoi(service);
        if (port <= 0 || port > 65535) {
            struct servent *se = getservbyname(service, "tcp");
            if (se) port = ntohs(se->s_port);
        }
        if (port > 0 && port < 65536) sa->sin_port = htons((uint16_t)port);
    }
    ai->ai_family = AF_INET;
    ai->ai_socktype = hints && hints->ai_socktype ? hints->ai_socktype : SOCK_STREAM;
    ai->ai_protocol = hints ? hints->ai_protocol : 0;
    ai->ai_addrlen = sizeof(struct sockaddr_in);
    ai->ai_addr = (struct sockaddr *)sa;
    *res = ai;
    return 0;
}

static struct hostent *IXGetHostByName(const char *name) {
    if (!ix_orig_gethostbyname) return gethostbyname(name);
    if (!IXTrafficGuardVPNOn() || !name || IXCallerIsSelf() || IXHostIsProxy(name) || IXIsNumericHost(name)) {
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

static BOOL IXUDPShouldBlock(int fd, const struct sockaddr *dest) {
    if (!IXTrafficGuardVPNOn() || !IXTrafficGuardBlockUDP()) return NO;
    if (IXCallerIsSelf()) return NO;
    if (!dest || IXAddrIsLoopback(dest)) return NO;
    return IXSocketType(fd) == SOCK_DGRAM;
}

static ssize_t IXSendTo(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t destLen) {
    if (IXUDPShouldBlock(fd, dest)) {
        errno = EPERM;
        return -1;
    }
    if (ix_orig_sendto) return ix_orig_sendto(fd, buf, len, flags, dest, destLen);
    return sendto(fd, buf, len, flags, dest, destLen);
}

static ssize_t IXSendMsg(int fd, const struct msghdr *msg, int flags) {
    const struct sockaddr *dest = msg ? msg->msg_name : NULL;
    if (IXUDPShouldBlock(fd, dest)) {
        errno = EPERM;
        return -1;
    }
    if (ix_orig_sendmsg) return ix_orig_sendmsg(fd, msg, flags);
    return sendmsg(fd, msg, flags);
}

static void IXHook(const char *name, void *replacement, void **original) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (!symbol) {
        NSLog(@"[InstagramX] traffic hook skipped, missing %s", name);
        return;
    }
    MSHookFunction(symbol, replacement, original);
}

void IXTrafficGuardInstall(void) {
    if (ix_installed) return;
    ix_installed = YES;
    IXHook("connect", (void *)IXConnect, (void **)&ix_orig_connect);
    IXHook("connectx", (void *)IXConnectX, (void **)&ix_orig_connectx);
    IXHook("getaddrinfo", (void *)IXGetAddrInfo, (void **)&ix_orig_getaddrinfo);
    IXHook("gethostbyname", (void *)IXGetHostByName, (void **)&ix_orig_gethostbyname);
    IXHook("sendto", (void *)IXSendTo, (void **)&ix_orig_sendto);
    IXHook("sendmsg", (void *)IXSendMsg, (void **)&ix_orig_sendmsg);
    NSLog(@"[InstagramX] in-process traffic hooks installed");
}
