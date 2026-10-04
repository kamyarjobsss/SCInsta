#import "IXPathHooks.h"
#import "IXTrafficGuard.h"

#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>

// Network.framework connections do not call connect(). On iOS 17 the public
// proxy config makes that stack dial the local SOCKS inbound itself, so TLS
// still uses the original hostname. When the tunnel is down and the kill
// switch is on, start() never reaches the real stack.
//
// CFHost resolves through the system resolver, not getaddrinfo. It is answered
// with the same fake addresses so the name never leaves the process.

typedef void *ix_nw_t;
typedef void (^IXNWStateBlock)(int state, void *error);
typedef ix_nw_t (*ix_nw_create_f)(ix_nw_t endpoint, ix_nw_t parameters);
typedef void (*ix_nw_start_f)(ix_nw_t connection);
typedef void (*ix_nw_set_handler_f)(ix_nw_t connection, void *handler);
typedef void (*ix_nw_set_queue_f)(ix_nw_t connection, dispatch_queue_t queue);
typedef void (*ix_nw_cancel_f)(ix_nw_t connection);
typedef ix_nw_t (*ix_nw_endpoint_host_f)(const char *host, const char *port);
typedef const char *(*ix_nw_hostname_f)(ix_nw_t endpoint);
typedef uint16_t (*ix_nw_port_f)(ix_nw_t endpoint);
typedef const struct sockaddr *(*ix_nw_address_f)(ix_nw_t endpoint);
typedef ix_nw_t (*ix_nw_proxy_f)(ix_nw_t endpoint, const char *user, const char *pass);
typedef ix_nw_t (*ix_nw_copy_f)(ix_nw_t parameters);
typedef void (*ix_nw_set_proxies_f)(ix_nw_t parameters, NSArray *configs);
typedef void (*ix_nw_release_f)(ix_nw_t object);
typedef ix_nw_t (*ix_nw_error_f)(int code);
typedef CFDictionaryRef (*ix_proxy_settings_f)(void);
typedef CFArrayRef (*ix_proxies_for_url_f)(CFURLRef url, CFDictionaryRef settings);
typedef CFArrayRef (*ix_pac_f)(CFStringRef script, CFURLRef url, CFErrorRef *error);
typedef void *(*ix_host_create_f)(CFAllocatorRef allocator, CFStringRef name);
typedef void (*ix_host_cb)(void *host, int type, const void *error, void *info);
typedef struct {
    long version;
    void *info;
    void *retain;
    void *release;
    void *copyDescription;
} ix_host_ctx;
typedef void (*ix_host_setclient_f)(void *host, ix_host_cb callback, ix_host_ctx *context);
typedef void (*ix_host_sched_f)(void *host, CFRunLoopRef runLoop, CFStringRef mode);
typedef Boolean (*ix_host_start_f)(void *host, int info, void *error);
typedef CFArrayRef (*ix_host_addrs_f)(void *host, Boolean *resolved);
typedef void (*ix_host_cancel_f)(void *host);

static ix_nw_create_f ix_orig_create;
static ix_nw_start_f ix_orig_start;
static ix_nw_set_handler_f ix_orig_handler;
static ix_nw_set_queue_f ix_orig_queue;
static ix_nw_cancel_f ix_orig_cancel;
static ix_nw_endpoint_host_f ix_endpoint_host;
static ix_nw_hostname_f ix_hostname;
static ix_nw_port_f ix_port;
static ix_nw_address_f ix_address;
static ix_nw_proxy_f ix_socks_proxy;
static ix_nw_proxy_f ix_http_proxy;
static ix_nw_copy_f ix_params_copy;
static ix_nw_set_proxies_f ix_set_proxies;
static ix_nw_release_f ix_nw_release;
static ix_nw_error_f ix_error_posix;
static ix_proxy_settings_f ix_orig_settings;
static ix_proxies_for_url_f ix_orig_proxies;
static ix_pac_f ix_orig_pac;
static ix_host_create_f ix_orig_host_create;
static ix_host_setclient_f ix_orig_host_client;
static ix_host_sched_f ix_orig_host_sched;
static ix_host_start_f ix_orig_host_start;
static ix_host_addrs_f ix_orig_host_addrs;
static ix_host_cancel_f ix_orig_host_cancel;
static BOOL ix_proxy_ready;

#define IX_NW_MAX 160
#define IX_HOST_MAX 64

typedef struct {
    ix_nw_t conn;
    char host[192];
    uint16_t port;
    int blocked;
    int failed;
} IXNWSlot;

typedef struct {
    void *host;
    char name[256];
    ix_host_cb callback;
    void *info;
    CFRunLoopRef runLoop;
    CFStringRef mode;
    CFArrayRef addresses;
} IXHostSlot;

static IXNWSlot ix_nw[IX_NW_MAX];
static id ix_nw_handlers[IX_NW_MAX];
static dispatch_queue_t ix_nw_queues[IX_NW_MAX];
static IXHostSlot ix_hosts[IX_HOST_MAX];
static pthread_mutex_t ix_nw_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t ix_host_mu = PTHREAD_MUTEX_INITIALIZER;

static void *IXLoad(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) {
        void *net = dlopen("/System/Library/Frameworks/Network.framework/Network", RTLD_LAZY);
        if (net) sym = dlsym(net, name);
    }
    if (!sym) {
        void *cf = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY);
        if (cf) sym = dlsym(cf, name);
    }
    return sym;
}

static BOOL IXLoopbackName(const char *host) {
    if (!host || !host[0]) return NO;
    if (strcmp(host, "localhost") == 0 || strcmp(host, "127.0.0.1") == 0 || strcmp(host, "::1") == 0) return YES;
    struct in_addr v4;
    if (inet_pton(AF_INET, host, &v4) == 1) return (ntohl(v4.s_addr) >> 24) == 127;
    return NO;
}

static BOOL IXNumericName(const char *host) {
    if (!host) return NO;
    struct in_addr v4;
    struct in6_addr v6;
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1;
}

static BOOL IXDescribeEndpoint(ix_nw_t endpoint, char *host, size_t hostLen, uint16_t *port) {
    if (!endpoint || !host || !port) return NO;
    host[0] = 0;
    *port = 0;
    if (ix_hostname) {
        const char *name = ix_hostname(endpoint);
        if (name && name[0]) {
            strlcpy(host, name, hostLen);
            if (ix_port) *port = ix_port(endpoint);
            return YES;
        }
    }
    if (!ix_address) return NO;
    const struct sockaddr *sa = ix_address(endpoint);
    if (!sa) return NO;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)sa;
        *port = ntohs(in->sin_port);
        return inet_ntop(AF_INET, &in->sin_addr, host, (socklen_t)hostLen) != NULL;
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
        *port = ntohs(in6->sin6_port);
        return inet_ntop(AF_INET6, &in6->sin6_addr, host, (socklen_t)hostLen) != NULL;
    }
    return NO;
}

static int IXNWIndex(ix_nw_t conn, BOOL create) {
    int freeIndex = -1;
    for (int i = 0; i < IX_NW_MAX; i++) {
        if (ix_nw[i].conn == conn) return i;
        if (freeIndex < 0 && !ix_nw[i].conn) freeIndex = i;
    }
    if (!create) return -1;
    return freeIndex >= 0 ? freeIndex : 0;
}

static void IXNWRemember(ix_nw_t conn, const char *host, uint16_t port, int blocked) {
    if (!conn) return;
    pthread_mutex_lock(&ix_nw_mu);
    int index = IXNWIndex(conn, YES);
    BOOL same = ix_nw[index].conn == conn;
    id keptQueue = same ? ix_nw_queues[index] : nil;
    ix_nw_handlers[index] = nil;
    ix_nw_queues[index] = nil;
    memset(&ix_nw[index], 0, sizeof(ix_nw[index]));
    ix_nw[index].conn = conn;
    ix_nw_queues[index] = keptQueue;
    strlcpy(ix_nw[index].host, host ?: "", sizeof(ix_nw[index].host));
    ix_nw[index].port = port;
    ix_nw[index].blocked = blocked;
    pthread_mutex_unlock(&ix_nw_mu);
}

static void IXNWForget(ix_nw_t conn) {
    if (!conn) return;
    pthread_mutex_lock(&ix_nw_mu);
    int index = IXNWIndex(conn, NO);
    if (index >= 0) {
        ix_nw_handlers[index] = nil;
        ix_nw_queues[index] = nil;
        memset(&ix_nw[index], 0, sizeof(ix_nw[index]));
    }
    pthread_mutex_unlock(&ix_nw_mu);
}

static void IXFailBlocked(ix_nw_t connection) {
    pthread_mutex_lock(&ix_nw_mu);
    int index = IXNWIndex(connection, NO);
    if (index < 0 || !ix_nw[index].blocked || ix_nw[index].failed || !ix_nw_handlers[index]) {
        pthread_mutex_unlock(&ix_nw_mu);
        return;
    }
    ix_nw[index].failed = 1;
    id handler = ix_nw_handlers[index];
    dispatch_queue_t queue = ix_nw_queues[index];
    pthread_mutex_unlock(&ix_nw_mu);
    dispatch_queue_t target = queue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_async(target, ^{
        IXNWStateBlock block = (__bridge IXNWStateBlock)(__bridge void *)handler;
        if (!block) return;
        void *nwError = ix_error_posix ? ix_error_posix(51) : NULL;
        block(4, nwError);
    });
}

static BOOL IXApplyProxyPort(ix_nw_t params, uint16_t port) {
    if (!params || !port || !ix_endpoint_host || (!ix_socks_proxy && !ix_http_proxy)) return NO;
    char portText[8];
    BOOL socks = ix_socks_proxy != NULL;
    snprintf(portText, sizeof(portText), "%u", port);
    ix_nw_t endpoint = ix_endpoint_host("127.0.0.1", portText);
    if (!endpoint) return NO;
    ix_nw_t config = socks ? ix_socks_proxy(endpoint, NULL, NULL) : ix_http_proxy(endpoint, NULL, NULL);
    if (ix_nw_release) ix_nw_release(endpoint);
    if (!config) return NO;
    id object = (__bridge_transfer id)config;
    NSArray *list = @[object];
    if (ix_set_proxies) {
        ix_set_proxies(params, list);
        return YES;
    }
    id parameters = (__bridge id)params;
    SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
    if ([parameters respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(parameters, setter, list);
        return YES;
    }
    return NO;
}

static ix_nw_t IXCopyParams(ix_nw_t parameters) {
    if (!parameters) return NULL;
    if (ix_params_copy) return ix_params_copy(parameters);
    id object = (__bridge id)parameters;
    if ([object respondsToSelector:@selector(copy)]) {
        id copied = [object copy];
        if (!copied) return NULL;
        return (__bridge_retained ix_nw_t)copied;
    }
    return NULL;
}

static void IXReleaseNW(ix_nw_t object) {
    if (!object) return;
    if (ix_nw_release) ix_nw_release(object);
    else CFRelease(object);
}

static ix_nw_t IXRewrite(ix_nw_t endpoint, char *host, size_t hostLen, uint16_t *port) {
    if (!ix_endpoint_host || !host || !host[0]) return NULL;
    NSString *name = IXTrafficGuardLookupHost([NSString stringWithUTF8String:host]);
    if (name.length == 0) return NULL;
    strlcpy(host, name.UTF8String, hostLen);
    char portText[8];
    snprintf(portText, sizeof(portText), "%u", *port);
    return ix_endpoint_host(host, portText);
}

static ix_nw_t IXNWCreate(ix_nw_t endpoint, ix_nw_t parameters) {
    if (!ix_orig_create) return NULL;
    char host[192];
    uint16_t port = 0;
    BOOL remote = IXDescribeEndpoint(endpoint, host, sizeof(host), &port);
    if (!IXTrafficGuardVPNOn() || IXTrafficGuardCallerIsSelf() || !remote || IXLoopbackName(host)) {
        return ix_orig_create(endpoint, parameters);
    }
    if (!IXTrafficGuardProxyUp()) {
        if (IXTrafficGuardKillSwitch() && ix_orig_start) {
            ix_nw_t params = parameters;
            ix_nw_t copied = IXCopyParams(parameters);
            if (copied) params = copied;
            IXApplyProxyPort(params, 9);
            ix_nw_t conn = ix_orig_create(endpoint, params);
            if (copied) IXReleaseNW(copied);
            IXNWRemember(conn, host, port, 1);
            IXTrafficGuardNote(@"nw_connection", @(host), port, @"blocked by kill switch");
            return conn;
        }
        IXTrafficGuardNote(@"nw_connection", @(host), port, @"direct");
        return ix_orig_create(endpoint, parameters);
    }
    ix_nw_t params = parameters;
    ix_nw_t copied = IXCopyParams(parameters);
    if (copied) params = copied;
    BOOL applied = IXApplyProxyPort(params, ix_socks_proxy ? IXTrafficGuardSocksPort() : IXTrafficGuardHTTPPort());
    ix_nw_t rewritten = IXRewrite(endpoint, host, sizeof(host), &port);
    ix_nw_t conn = ix_orig_create(rewritten ?: endpoint, params);
    if (rewritten) IXReleaseNW(rewritten);
    if (copied) IXReleaseNW(copied);
    IXNWRemember(conn, host, port, 0);
    IXTrafficGuardNote(@"nw_connection", @(host), port, applied ? @"tunneled" : @"direct (no proxy config)");
    return conn;
}

static void IXNWStart(ix_nw_t connection) {
    pthread_mutex_lock(&ix_nw_mu);
    int blocked = 0;
    for (int i = 0; i < IX_NW_MAX; i++) {
        if (ix_nw[i].conn == connection) {
            blocked = ix_nw[i].blocked;
            break;
        }
    }
    pthread_mutex_unlock(&ix_nw_mu);
    if (blocked) {
        IXFailBlocked(connection);
        return;
    }
    if (ix_orig_start) ix_orig_start(connection);
}

static void IXNWSetHandler(ix_nw_t connection, void *handler) {
    pthread_mutex_lock(&ix_nw_mu);
    int index = IXNWIndex(connection, NO);
    int blocked = index >= 0 && ix_nw[index].blocked;
    if (index >= 0) {
        ix_nw[index].failed = 0;
        ix_nw_handlers[index] = nil;
        if (blocked && handler) ix_nw_handlers[index] = [(__bridge id)handler copy];
    }
    pthread_mutex_unlock(&ix_nw_mu);
    if (blocked) {
        IXFailBlocked(connection);
        return;
    }
    if (ix_orig_handler) ix_orig_handler(connection, handler);
}

static void IXNWSetQueue(ix_nw_t connection, dispatch_queue_t queue) {
    pthread_mutex_lock(&ix_nw_mu);
    int index = IXNWIndex(connection, NO);
    if (index >= 0) ix_nw_queues[index] = queue;
    pthread_mutex_unlock(&ix_nw_mu);
    if (ix_orig_queue) ix_orig_queue(connection, queue);
}

static void IXNWCancel(ix_nw_t connection) {
    IXNWForget(connection);
    if (ix_orig_cancel) ix_orig_cancel(connection);
}

static uint16_t IXForcedHTTPPort(void) {
    return IXTrafficGuardProxyUp() ? IXTrafficGuardHTTPPort() : 9;
}

static BOOL IXForceProxy(void) {
    return IXTrafficGuardVPNOn() && !IXTrafficGuardCallerIsSelf() && (IXTrafficGuardProxyUp() || IXTrafficGuardKillSwitch());
}

static CFDictionaryRef IXProxyDictionary(uint16_t port) {
    NSDictionary *dict = @{
        @"HTTPEnable": @1,
        @"HTTPProxy": @"127.0.0.1",
        @"HTTPPort": @(port),
        @"HTTPSEnable": @1,
        @"HTTPSProxy": @"127.0.0.1",
        @"HTTPSPort": @(port),
        @"SOCKSEnable": @0
    };
    return (CFDictionaryRef)CFBridgingRetain(dict);
}

static CFArrayRef IXProxyList(uint16_t port, BOOL secure) {
    NSDictionary *one = @{
        @"kCFProxyTypeKey": secure ? @"kCFProxyTypeHTTPS" : @"kCFProxyTypeHTTP",
        @"kCFProxyHostNameKey": @"127.0.0.1",
        @"kCFProxyPortNumberKey": @(port)
    };
    return (CFArrayRef)CFBridgingRetain(@[one]);
}

static CFDictionaryRef IXSystemProxy(void) {
    if (!IXForceProxy()) return ix_orig_settings ? ix_orig_settings() : NULL;
    return IXProxyDictionary(IXForcedHTTPPort());
}

static CFArrayRef IXProxiesForURL(CFURLRef url, CFDictionaryRef settings) {
    NSURL *nsurl = (__bridge NSURL *)url;
    if (!IXTrafficGuardVPNOn() || IXTrafficGuardCallerIsSelf()) {
        return ix_orig_proxies ? ix_orig_proxies(url, settings) : NULL;
    }
    if (!IXTrafficGuardProxyUp() && !IXTrafficGuardKillSwitch()) {
        IXTrafficGuardNote(@"cfnetwork", nsurl.host, nsurl.port.unsignedShortValue, @"direct");
        return ix_orig_proxies ? ix_orig_proxies(url, settings) : NULL;
    }
    if (!IXTrafficGuardProxyUp()) {
        IXTrafficGuardNote(@"cfnetwork", nsurl.host, nsurl.port.unsignedShortValue, @"blocked by kill switch");
    }
    BOOL secure = [nsurl.scheme.lowercaseString isEqualToString:@"https"];
    return IXProxyList(IXForcedHTTPPort(), secure);
}

static CFArrayRef IXProxiesForPAC(CFStringRef script, CFURLRef url, CFErrorRef *error) {
    if (!IXForceProxy()) return ix_orig_pac ? ix_orig_pac(script, url, error) : NULL;
    if (error) *error = NULL;
    NSURL *nsurl = (__bridge NSURL *)url;
    BOOL secure = [nsurl.scheme.lowercaseString isEqualToString:@"https"];
    if (!IXTrafficGuardProxyUp()) {
        IXTrafficGuardNote(@"cfnetwork", nsurl.host, nsurl.port.unsignedShortValue, @"blocked by kill switch");
    }
    return IXProxyList(IXForcedHTTPPort(), secure);
}

static IXHostSlot *IXHostFind(void *host, BOOL create) {
    IXHostSlot *freeSlot = NULL;
    for (int i = 0; i < IX_HOST_MAX; i++) {
        if (ix_hosts[i].host == host) return &ix_hosts[i];
        if (!freeSlot && !ix_hosts[i].host) freeSlot = &ix_hosts[i];
    }
    if (!create) return NULL;
    if (!freeSlot) freeSlot = &ix_hosts[0];
    if (freeSlot->addresses) CFRelease(freeSlot->addresses);
    if (freeSlot->runLoop) CFRelease(freeSlot->runLoop);
    if (freeSlot->mode) CFRelease(freeSlot->mode);
    freeSlot->host = host;
    freeSlot->name[0] = 0;
    freeSlot->callback = NULL;
    freeSlot->info = NULL;
    freeSlot->runLoop = NULL;
    freeSlot->mode = NULL;
    freeSlot->addresses = NULL;
    return freeSlot;
}

static void IXHostClear(void *host) {
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    if (slot) {
        if (slot->addresses) CFRelease(slot->addresses);
        if (slot->runLoop) CFRelease(slot->runLoop);
        if (slot->mode) CFRelease(slot->mode);
        slot->host = NULL;
        slot->name[0] = 0;
        slot->callback = NULL;
        slot->info = NULL;
        slot->runLoop = NULL;
        slot->mode = NULL;
        slot->addresses = NULL;
    }
    pthread_mutex_unlock(&ix_host_mu);
}

static CFArrayRef IXFakeAddressArray(const char *name) {
    struct sockaddr_in v4;
    struct sockaddr_in6 v6;
    if (!IXTrafficGuardFakeSockaddrs(name, &v4, &v6)) return NULL;
    CFDataRef a = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&v4, sizeof(v4));
    CFDataRef b = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&v6, sizeof(v6));
    const void *values[2] = {a, b};
    CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, values, 2, &kCFTypeArrayCallBacks);
    if (a) CFRelease(a);
    if (b) CFRelease(b);
    return array;
}

static void IXFireHost(void *host, int type) {
    ix_host_cb callback = NULL;
    void *info = NULL;
    CFRunLoopRef runLoop = NULL;
    CFStringRef mode = NULL;
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    if (slot) {
        callback = slot->callback;
        info = slot->info;
        if (slot->runLoop) runLoop = (CFRunLoopRef)CFRetain(slot->runLoop);
        if (slot->mode) mode = (CFStringRef)CFRetain(slot->mode);
    }
    pthread_mutex_unlock(&ix_host_mu);
    if (!callback) {
        if (runLoop) CFRelease(runLoop);
        if (mode) CFRelease(mode);
        return;
    }
    if (runLoop) {
        void *infoKeep = info;
        ix_host_cb cbKeep = callback;
        CFTypeRef kept = CFRetain((CFTypeRef)host);
        CFRunLoopPerformBlock(runLoop, mode ?: kCFRunLoopDefaultMode, ^{
            struct { long domain; int error; } err = {0, 0};
            cbKeep((void *)kept, type, &err, infoKeep);
            CFRelease(kept);
        });
        CFRunLoopWakeUp(runLoop);
        CFRelease(runLoop);
        if (mode) CFRelease(mode);
        return;
    }
    struct { long domain; int error; } err = {0, 0};
    callback(host, type, &err, info);
}

static void *IXHostCreate(CFAllocatorRef allocator, CFStringRef name) {
    void *host = ix_orig_host_create ? ix_orig_host_create(allocator, name) : NULL;
    if (!host || !IXTrafficGuardVPNOn() || IXTrafficGuardCallerIsSelf()) return host;
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, YES);
    slot->name[0] = 0;
    if (name) {
        NSString *text = (__bridge NSString *)name;
        strlcpy(slot->name, text.UTF8String ?: "", sizeof(slot->name));
    }
    pthread_mutex_unlock(&ix_host_mu);
    return host;
}

static void IXHostSetClient(void *host, ix_host_cb callback, ix_host_ctx *context) {
    if (ix_orig_host_client) ix_orig_host_client(host, callback, context);
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    if (slot) {
        slot->callback = callback;
        slot->info = context ? context->info : NULL;
    }
    pthread_mutex_unlock(&ix_host_mu);
}

static void IXHostSchedule(void *host, CFRunLoopRef runLoop, CFStringRef mode) {
    if (ix_orig_host_sched) ix_orig_host_sched(host, runLoop, mode);
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    if (slot && runLoop) {
        if (slot->runLoop) CFRelease(slot->runLoop);
        if (slot->mode) CFRelease(slot->mode);
        slot->runLoop = (CFRunLoopRef)CFRetain(runLoop);
        slot->mode = mode ? (CFStringRef)CFRetain(mode) : NULL;
    }
    pthread_mutex_unlock(&ix_host_mu);
}

static Boolean IXHostStart(void *host, int info, void *error) {
    char name[256];
    name[0] = 0;
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    if (slot) strlcpy(name, slot->name, sizeof(name));
    pthread_mutex_unlock(&ix_host_mu);
    if (!IXTrafficGuardVPNOn() || IXTrafficGuardCallerIsSelf()) {
        return ix_orig_host_start ? ix_orig_host_start(host, info, error) : FALSE;
    }
    BOOL named = name[0] && !IXNumericName(name);
    if (!named) {
        if (name[0] == 0 && IXTrafficGuardKillSwitch()) return FALSE;
        return ix_orig_host_start ? ix_orig_host_start(host, info, error) : FALSE;
    }
    if (info != 0) {
        IXFireHost(host, info);
        return TRUE;
    }
    CFArrayRef addresses = IXFakeAddressArray(name);
    pthread_mutex_lock(&ix_host_mu);
    slot = IXHostFind(host, NO);
    if (slot) {
        if (slot->addresses) CFRelease(slot->addresses);
        slot->addresses = addresses;
        addresses = NULL;
    }
    pthread_mutex_unlock(&ix_host_mu);
    if (addresses) CFRelease(addresses);
    IXFireHost(host, info);
    return TRUE;
}

static CFArrayRef IXHostAddresses(void *host, Boolean *resolved) {
    pthread_mutex_lock(&ix_host_mu);
    IXHostSlot *slot = IXHostFind(host, NO);
    CFArrayRef addresses = slot ? slot->addresses : NULL;
    pthread_mutex_unlock(&ix_host_mu);
    if (addresses) {
        if (resolved) *resolved = TRUE;
        return addresses;
    }
    if (IXTrafficGuardVPNOn() && IXTrafficGuardKillSwitch() && !IXTrafficGuardCallerIsSelf()) {
        if (resolved) *resolved = FALSE;
        return NULL;
    }
    return ix_orig_host_addrs ? ix_orig_host_addrs(host, resolved) : NULL;
}

static void IXHostCancel(void *host) {
    IXHostClear(host);
    if (ix_orig_host_cancel) ix_orig_host_cancel(host);
}

void IXPathHookPrepare(void) {
    ix_orig_create = IXLoad("nw_connection_create");
    ix_orig_start = IXLoad("nw_connection_start");
    ix_orig_handler = IXLoad("nw_connection_set_state_changed_handler");
    ix_orig_queue = IXLoad("nw_connection_set_queue");
    ix_orig_cancel = IXLoad("nw_connection_cancel");
    ix_endpoint_host = IXLoad("nw_endpoint_create_host");
    ix_hostname = IXLoad("nw_endpoint_get_hostname");
    ix_port = IXLoad("nw_endpoint_get_port");
    ix_address = IXLoad("nw_endpoint_get_address");
    ix_socks_proxy = IXLoad("nw_proxy_config_create_socksv5");
    ix_http_proxy = IXLoad("nw_proxy_config_create_http_connect");
    ix_params_copy = IXLoad("nw_parameters_copy");
    ix_set_proxies = IXLoad("nw_parameters_set_proxy_configurations");
    ix_nw_release = IXLoad("nw_release");
    ix_error_posix = IXLoad("nw_error_posix_create");
    if (!ix_error_posix) ix_error_posix = IXLoad("nw_error_create_posix");
    ix_orig_settings = IXLoad("CFNetworkCopySystemProxySettings");
    ix_orig_proxies = IXLoad("CFNetworkCopyProxiesForURL");
    ix_orig_pac = IXLoad("CFNetworkCopyProxiesForAutoConfigurationScript");
    ix_orig_host_create = IXLoad("CFHostCreateWithName");
    ix_orig_host_client = IXLoad("CFHostSetClient");
    ix_orig_host_sched = IXLoad("CFHostScheduleWithRunLoop");
    ix_orig_host_start = IXLoad("CFHostStartInfoResolution");
    ix_orig_host_addrs = IXLoad("CFHostGetAddressing");
    ix_orig_host_cancel = IXLoad("CFHostCancelInfoResolution");
    ix_proxy_ready = (ix_socks_proxy || ix_http_proxy) && ix_set_proxies;
    NSLog(@"[InstagramX] network proxy config %@, setter %@, ready %@",
          ix_socks_proxy ? @"socks" : (ix_http_proxy ? @"http" : @"missing"),
          ix_set_proxies ? @"yes" : @"objc",
          ix_proxy_ready ? @"yes" : @"no");
}

BOOL IXPathHookProxyReady(void) {
    return (ix_socks_proxy || ix_http_proxy) && ix_orig_create != NULL;
}

id IXPathHookProxyObjectOnPort(uint16_t port) {
    if (!ix_endpoint_host || port == 0 || (!ix_socks_proxy && !ix_http_proxy)) return nil;
    char portText[8];
    BOOL socks = ix_socks_proxy != NULL;
    snprintf(portText, sizeof(portText), "%u", port);
    ix_nw_t endpoint = ix_endpoint_host("127.0.0.1", portText);
    if (!endpoint) return nil;
    ix_nw_t config = socks ? ix_socks_proxy(endpoint, NULL, NULL) : ix_http_proxy(endpoint, NULL, NULL);
    if (ix_nw_release) ix_nw_release(endpoint);
    if (!config) return nil;
    return (__bridge_transfer id)config;
}

id IXPathHookProxyObject(void) {
    uint16_t port = ix_socks_proxy ? IXTrafficGuardSocksPort() : IXTrafficGuardHTTPPort();
    return IXPathHookProxyObjectOnPort(port);
}

unsigned IXPathHookFill(const char **names, void **replacements, unsigned capacity) {
    struct {
        const char *name;
        void *repl;
        void *orig;
    } rows[] = {
        {"nw_connection_create", (void *)IXNWCreate, (void *)ix_orig_create},
        {"nw_connection_start", (void *)IXNWStart, (void *)ix_orig_start},
        {"nw_connection_set_state_changed_handler", (void *)IXNWSetHandler, (void *)ix_orig_handler},
        {"nw_connection_set_queue", (void *)IXNWSetQueue, (void *)ix_orig_queue},
        {"nw_connection_cancel", (void *)IXNWCancel, (void *)ix_orig_cancel},
        {"CFNetworkCopySystemProxySettings", (void *)IXSystemProxy, (void *)ix_orig_settings},
        {"CFNetworkCopyProxiesForURL", (void *)IXProxiesForURL, (void *)ix_orig_proxies},
        {"CFNetworkCopyProxiesForAutoConfigurationScript", (void *)IXProxiesForPAC, (void *)ix_orig_pac},
        {"CFHostCreateWithName", (void *)IXHostCreate, (void *)ix_orig_host_create},
        {"CFHostSetClient", (void *)IXHostSetClient, (void *)ix_orig_host_client},
        {"CFHostScheduleWithRunLoop", (void *)IXHostSchedule, (void *)ix_orig_host_sched},
        {"CFHostStartInfoResolution", (void *)IXHostStart, (void *)ix_orig_host_start},
        {"CFHostGetAddressing", (void *)IXHostAddresses, (void *)ix_orig_host_addrs},
        {"CFHostCancelInfoResolution", (void *)IXHostCancel, (void *)ix_orig_host_cancel},
    };
    unsigned count = 0;
    unsigned total = (unsigned)(sizeof(rows) / sizeof(rows[0]));
    for (unsigned i = 0; i < total && count < capacity; i++) {
        if (!rows[i].orig) continue;
        names[count] = rows[i].name;
        replacements[count] = rows[i].repl;
        count++;
    }
    return count;
}

BOOL IXTrafficGuardNWProxyReady(void) {
    return IXPathHookProxyReady();
}
