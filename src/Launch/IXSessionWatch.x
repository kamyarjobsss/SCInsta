#import "IXSessionWatch.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"
#import "../Backend/IXCrypto.h"
#import "../Proxy/IXSymbolRebind.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

static pthread_mutex_t ix_watch_mu = PTHREAD_MUTEX_INITIALIZER;
static CFAbsoluteTime ix_watch_clock = 0;
static int ix_sec_logs = 0;
static int ix_file_logs = 0;
static int ix_pref_logs = 0;
static int ix_cookie_logs = 0;
static int ix_logout_logs = 0;
static int ix_http_logs = 0;
static int ix_http_seen = 0;
static NSInteger ix_http_status = 0;
static NSInteger ix_http_error = 0;
static NSString *ix_http_marker = @"none";
static NSString *ix_http_host = @"-";

typedef OSStatus (*IXSecAddFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*IXSecCopyFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*IXSecUpdateFn)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*IXSecDeleteFn)(CFDictionaryRef);
static IXSecAddFn ix_real_add;
static IXSecCopyFn ix_real_copy;
static IXSecUpdateFn ix_real_update;
static IXSecDeleteFn ix_real_delete;
static IXSecAddFn ix_raw_add;
static IXSecCopyFn ix_raw_copy;
static IXSecUpdateFn ix_raw_update;
static IXSecDeleteFn ix_raw_delete;
static NSString *ix_entitled_group;
static int ix_chain_hooked;
static int ix_mc_depth;

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
    int arity;
} IXLogoutSlot;

static IXLogoutSlot ix_logout_slots[64];
static int ix_logout_count = 0;

static NSString *IXClipC(const char *text, NSUInteger max) {
    NSString *value = text ? [NSString stringWithUTF8String:text] : nil;
    if (value.length == 0) return @"-";
    if (value.length > max) value = [value substringToIndex:max];
    return value;
}

static void IXFrames(NSString *kind) {
    void *stack[12];
    int count = backtrace(stack, 12);
    Dl_info selfInfo;
    int logged = 0;
    memset(&selfInfo, 0, sizeof selfInfo);
    dladdr((void *)&IXFrames, &selfInfo);
    for (int i = 0; i < count && logged < 6; i++) {
        Dl_info info;
        const char *image;
        memset(&info, 0, sizeof info);
        if (!dladdr(stack[i], &info)) continue;
        if (selfInfo.dli_fbase && info.dli_fbase == selfInfo.dli_fbase) continue;
        image = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
        image = image ? image + 1 : (info.dli_fname ? info.dli_fname : "?");
        IXSessionDiagLine([NSString stringWithFormat:@"bt kind=%@ i=%d image=%@ symbol=%@",
                           kind, logged, IXClipC(image, 64), IXClipC(info.dli_sname, 80)]);
        logged++;
    }
    if (logged == 0) IXSessionDiagLine([NSString stringWithFormat:@"bt kind=%@ i=0 image=- symbol=-", kind]);
}

static NSString *IXExpiryText(NSDate *date) {
    NSISO8601DateFormatter *fmt;
    NSString *text;
    if (![date isKindOfClass:[NSDate class]]) return @"session";
    fmt = [NSISO8601DateFormatter new];
    text = [fmt stringFromDate:date];
    return text.length ? text : @"session";
}

static BOOL IXHostIsIG(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"instagram.com"] || [host hasSuffix:@".instagram.com"] || [host hasSuffix:@".cdninstagram.com"];
}

static NSHTTPCookie *IXSessionCookie(void) {
    NSURL *url = [NSURL URLWithString:@"https://i.instagram.com/"];
    if (!url) return nil;
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]) {
        if ([cookie.name isEqualToString:@"sessionid"] && cookie.value.length > 0) return cookie;
    }
    return nil;
}

int IXSessionCookiePresent(void) {
    return IXSessionCookie() != nil;
}

int IXSessionWithinRestoreWindow(void) {
    CFAbsoluteTime start;
    pthread_mutex_lock(&ix_watch_mu);
    start = ix_watch_clock;
    pthread_mutex_unlock(&ix_watch_mu);
    if (start == 0) return 1;
    return (CFAbsoluteTimeGetCurrent() - start) < 90.0;
}

static NSString *IXUsersPath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ix_ig_users.plist"];
}

NSArray<NSString *> *IXSessionSavedUsernames(void) {
    NSArray *saved = [NSArray arrayWithContentsOfFile:IXUsersPath()];
    NSMutableArray *names = [NSMutableArray array];
    if (![saved isKindOfClass:[NSArray class]]) return @[];
    for (id name in saved) {
        if (![name isKindOfClass:[NSString class]] || [(NSString *)name length] == 0 || [(NSString *)name length] > 64) continue;
        [names addObject:name];
        if (names.count >= 16) break;
    }
    return names;
}

void IXSessionSaveUsernames(NSArray<NSString *> *names) {
    NSMutableArray *clean = [NSMutableArray array];
    for (id name in names) {
        if (![name isKindOfClass:[NSString class]] || [(NSString *)name length] == 0 || [(NSString *)name length] > 64) continue;
        [clean addObject:name];
        if (clean.count >= 16) break;
    }
    if (clean.count == 0) return;
    [clean writeToFile:IXUsersPath() atomically:YES];
}

void IXSessionClearUsernames(void) {
    [[NSFileManager defaultManager] removeItemAtPath:IXUsersPath() error:nil];
}

static BOOL IXDataHas(NSData *data, const char *needle) {
    size_t n;
    size_t take;
    if (![data isKindOfClass:[NSData class]] || data.length == 0 || !needle) return NO;
    n = strlen(needle);
    if (n == 0 || data.length < n) return NO;
    take = data.length > 8192 ? 8192 : data.length;
    return memmem(data.bytes, take, needle, n) != NULL;
}

static int IXAuthIsSession(NSString *auth) {
    return [auth isEqualToString:@"authorization"] || [auth isEqualToString:@"cookie"] || [auth isEqualToString:@"storage"];
}

static void IXRememberHTTP(NSURL *url, NSInteger status, NSError *error, NSData *data, NSString *auth) {
    NSString *marker = @"none";
    int interesting;
    int first = 0;
    int authenticated;
    if (!IXHostIsIG(url)) return;
    if (IXDataHas(data, "login_required")) marker = @"login_required";
    else if (IXDataHas(data, "invalid_session")) marker = @"invalid_session";
    else if (IXDataHas(data, "checkpoint")) marker = @"checkpoint";
    authenticated = IXAuthIsSession(auth);
    interesting = ![marker isEqualToString:@"none"] || status == 401 || status == 403;
    pthread_mutex_lock(&ix_watch_mu);
    if (authenticated && !ix_http_seen) {
        first = 1;
        ix_http_seen = 1;
        ix_http_status = status;
        ix_http_error = error.code;
        ix_http_host = url.host.length ? [url.host copy] : @"-";
    }
    if (interesting) ix_http_marker = [marker copy];
    if ((first || interesting) && ix_http_logs < 12) {
        ix_http_logs++;
        pthread_mutex_unlock(&ix_watch_mu);
        IXSessionDiagLine([NSString stringWithFormat:@"http first=%d host=%@ status=%ld error=%ld marker=%@ auth=%@",
                           first, url.host ?: @"-", (long)status, (long)error.code, marker, auth ?: @"unknown"]);
        return;
    }
    pthread_mutex_unlock(&ix_watch_mu);
}

static NSString *IXAuthKind(NSURLRequest *request) {
    NSString *auth = nil;
    NSString *cookie = nil;
    @try { auth = [request valueForHTTPHeaderField:@"Authorization"]; }
    @catch (__unused NSException *exception) { auth = nil; }
    @try { cookie = [request valueForHTTPHeaderField:@"Cookie"]; }
    @catch (__unused NSException *exception) { cookie = nil; }
    if (auth.length > 0) return @"authorization";
    if ([cookie rangeOfString:@"sessionid=" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"cookie";
    if (IXSessionCookiePresent()) return @"storage";
    return @"none";
}

typedef void (^IXHTTPCompletion)(NSData *data, NSURLResponse *response, NSError *error);

static IXHTTPCompletion IXWrapCompletion(NSURLRequest *request, IXHTTPCompletion completion) {
    NSURL *url;
    NSString *auth;
    if (!completion) return nil;
    url = request.URL;
    if (!IXHostIsIG(url)) return completion;
    auth = IXAuthKind(request);
    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        IXRememberHTTP(url, http ? http.statusCode : 0, error, data, auth);
        completion(data, response, error);
    };
}

static BOOL IXOwnService(NSString *service) {
    return [service isKindOfClass:[NSString class]] && [service hasPrefix:@"instagramx."];
}

static void *IXStripPtr(void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_asia);
#else
    return pointer;
#endif
}

static NSString *IXShort(id value, NSUInteger max) {
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) return @"-";
    if ([(NSString *)value length] > max) return @"len";
    return value;
}

static const char *IXChainName(void *prev, const char *symbol) {
    void *raw = symbol ? dlsym(RTLD_DEFAULT, symbol) : NULL;
    if (!prev) return "none";
    if (raw && IXStripPtr(prev) == IXStripPtr(raw)) return "real";
    return "hooked";
}

static CFDictionaryRef IXPreparedQuery(CFDictionaryRef query, int *rewrote) {
    NSDictionary *dict;
    id service;
    id group;
    NSMutableDictionary *next;
    const char *current;
    if (rewrote) *rewrote = 0;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return query;
    dict = (__bridge NSDictionary *)query;
    service = dict[(__bridge id)kSecAttrService];
    if (IXOwnService(service)) return query;
    group = dict[(__bridge id)kSecAttrAccessGroup];
    current = [group isKindOfClass:[NSString class]] ? [(NSString *)group UTF8String] : NULL;
    if (!IXSessionRewriteGroup(current, ix_entitled_group.UTF8String)) return query;
    next = [dict mutableCopy];
    if (!next) return query;
    next[(__bridge id)kSecAttrAccessGroup] = ix_entitled_group;
    if (rewrote) *rewrote = 1;
    return (CFDictionaryRef)CFBridgingRetain(next);
}

static int IXLogThisOp(const char *op, NSString *service, int rewrote) {
    NSString *lower;
    if (!op) return 0;
    if (strcmp(op, "delete") == 0) return 1;
    if (!rewrote) return 0;
    if (strcmp(op, "copy") != 0) return 1;
    if (![service isKindOfClass:[NSString class]] || service.length == 0) return 0;
    lower = service.lowercaseString;
    return [lower containsString:@"account"] || [lower containsString:@"auth"] ||
           [lower containsString:@"session"] || [lower containsString:@"token"] ||
           [lower containsString:@"user"];
}

static void IXLogGroup(const char *op, CFDictionaryRef original, OSStatus status, int rewrote, const char *chain) {
    NSDictionary *dict;
    id service;
    id group;
    int room;
    int frames;
    if (!original || CFGetTypeID(original) != CFDictionaryGetTypeID()) return;
    dict = (__bridge NSDictionary *)original;
    service = dict[(__bridge id)kSecAttrService];
    if (IXOwnService(service)) return;
    frames = op && strcmp(op, "delete") == 0;
    if (!IXLogThisOp(op, [service isKindOfClass:[NSString class]] ? service : nil, rewrote)) return;
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_sec_logs < 40;
    if (room) ix_sec_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (!room) return;
    group = dict[(__bridge id)kSecAttrAccessGroup];
    IXSessionDiagLine([NSString stringWithFormat:@"kc_group op=%s service=%@ from=%@ to=%@ status=%d chain=%s",
                       op,
                       IXShort(service, 80),
                       IXShort(group, 80),
                       rewrote ? (ix_entitled_group ?: @"-") : IXShort(group, 80),
                       (int)status,
                       chain ?: "none"]);
    if (frames) IXFrames(@"secdelete");
}

static void IXEnsureGroup(void);
static void IXProbeEntitledGroup(void);
static OSStatus ix_sec_add(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus ix_sec_copy(CFDictionaryRef queryIn, CFTypeRef *result);
static OSStatus ix_sec_update(CFDictionaryRef queryIn, CFDictionaryRef attributesToUpdate);
static OSStatus ix_sec_delete(CFDictionaryRef queryIn);

static IXSecAddFn IXRawAdd(void) {
    IXSecAddFn next = ix_raw_add;
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_add)) next = (IXSecAddFn)dlsym(RTLD_DEFAULT, "SecItemAdd");
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_add)) return NULL;
    return next;
}

static IXSecCopyFn IXRawCopy(void) {
    IXSecCopyFn next = ix_raw_copy;
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_copy)) next = (IXSecCopyFn)dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_copy)) return NULL;
    return next;
}

static IXSecUpdateFn IXRawUpdate(void) {
    IXSecUpdateFn next = ix_raw_update;
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_update)) next = (IXSecUpdateFn)dlsym(RTLD_DEFAULT, "SecItemUpdate");
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_update)) return NULL;
    return next;
}

static IXSecDeleteFn IXRawDelete(void) {
    IXSecDeleteFn next = ix_raw_delete;
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_delete)) next = (IXSecDeleteFn)dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (!next || IXStripPtr((void *)next) == IXStripPtr((void *)ix_sec_delete)) return NULL;
    return next;
}

static OSStatus ix_sec_add(CFDictionaryRef attributes, CFTypeRef *result) {
    int rewrote = 0;
    CFDictionaryRef query;
    IXSecAddFn next;
    OSStatus status;
    IXEnsureGroup();
    query = IXPreparedQuery(attributes, &rewrote);
    next = IXRawAdd();
    status = next ? next(query, result) : errSecUnimplemented;
    IXLogGroup("add", attributes, status, rewrote, "real");
    if (rewrote && query) CFRelease(query);
    return status;
}

static OSStatus ix_sec_copy(CFDictionaryRef queryIn, CFTypeRef *result) {
    int rewrote = 0;
    CFDictionaryRef query;
    IXSecCopyFn next;
    OSStatus status;
    IXEnsureGroup();
    query = IXPreparedQuery(queryIn, &rewrote);
    next = IXRawCopy();
    status = next ? next(query, result) : errSecUnimplemented;
    IXLogGroup("copy", queryIn, status, rewrote, "real");
    if (rewrote && query) CFRelease(query);
    return status;
}

static OSStatus ix_sec_update(CFDictionaryRef queryIn, CFDictionaryRef attributesToUpdate) {
    int rewrote = 0;
    CFDictionaryRef query;
    IXSecUpdateFn next;
    OSStatus status;
    IXEnsureGroup();
    query = IXPreparedQuery(queryIn, &rewrote);
    next = IXRawUpdate();
    status = next ? next(query, attributesToUpdate) : errSecUnimplemented;
    IXLogGroup("update", queryIn, status, rewrote, "real");
    if (rewrote && query) CFRelease(query);
    return status;
}

static OSStatus ix_sec_delete(CFDictionaryRef queryIn) {
    int rewrote = 0;
    CFDictionaryRef query;
    IXSecDeleteFn next;
    OSStatus status;
    IXEnsureGroup();
    query = IXPreparedQuery(queryIn, &rewrote);
    next = IXRawDelete();
    status = next ? next(query) : errSecUnimplemented;
    IXLogGroup("delete", queryIn, status, rewrote, "real");
    if (rewrote && query) CFRelease(query);
    return status;
}

static void IXCaptureRaw(void) {
    void *add = dlsym(RTLD_DEFAULT, "SecItemAdd");
    void *copy = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    void *update = dlsym(RTLD_DEFAULT, "SecItemUpdate");
    void *del = dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (add && IXStripPtr(add) != IXStripPtr((void *)ix_sec_add)) ix_raw_add = (IXSecAddFn)add;
    if (copy && IXStripPtr(copy) != IXStripPtr((void *)ix_sec_copy)) ix_raw_copy = (IXSecCopyFn)copy;
    if (update && IXStripPtr(update) != IXStripPtr((void *)ix_sec_update)) ix_raw_update = (IXSecUpdateFn)update;
    if (del && IXStripPtr(del) != IXStripPtr((void *)ix_sec_delete)) ix_raw_delete = (IXSecDeleteFn)del;
}

static void IXEnsureGroup(void) {
    static __thread int depth = 0;
    if (ix_entitled_group.length || depth) return;
    depth++;
    IXCaptureRaw();
    IXProbeEntitledGroup();
    depth--;
}

static void IXResolvePrev(void) {
    void *add = IXSymbolPrevious("SecItemAdd");
    void *copy = IXSymbolPrevious("SecItemCopyMatching");
    void *update = IXSymbolPrevious("SecItemUpdate");
    void *del = IXSymbolPrevious("SecItemDelete");
    if (!add || add == (void *)ix_sec_add) add = (void *)ix_raw_add;
    if (!copy || copy == (void *)ix_sec_copy) copy = (void *)ix_raw_copy;
    if (!update || update == (void *)ix_sec_update) update = (void *)ix_raw_update;
    if (!del || del == (void *)ix_sec_delete) del = (void *)ix_raw_delete;
    if (add && add != (void *)ix_sec_add) ix_real_add = (IXSecAddFn)add;
    if (copy && copy != (void *)ix_sec_copy) ix_real_copy = (IXSecCopyFn)copy;
    if (update && update != (void *)ix_sec_update) ix_real_update = (IXSecUpdateFn)update;
    if (del && del != (void *)ix_sec_delete) ix_real_delete = (IXSecDeleteFn)del;
    ix_chain_hooked = IXChainName((void *)ix_real_copy, "SecItemCopyMatching")[0] == 'h';
}

static void IXProbeEntitledGroup(void) {
    NSDictionary *query;
    CFTypeRef result = NULL;
    OSStatus status = errSecUnimplemented;
    id group;
    if (ix_entitled_group.length) return;
    query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"zxPluginsInjectGenericEntry",
        (__bridge id)kSecAttrService: @"",
        (__bridge id)kSecReturnAttributes: @YES
    };
    if (ix_raw_copy) status = ix_raw_copy((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound && ix_raw_add) {
        if (result) {
            CFRelease(result);
            result = NULL;
        }
        status = ix_raw_add((__bridge CFDictionaryRef)query, &result);
    }
    group = nil;
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
    }
    if ([group isKindOfClass:[NSString class]] && [(NSString *)group length] > 0 && [(NSString *)group length] <= 128) {
        ix_entitled_group = [group copy];
    }
    if (result) CFRelease(result);
}

static void IXProofQuery(NSString *phase, NSString *service, NSString *group, NSString *label) {
    NSMutableDictionary *query;
    CFTypeRef result = NULL;
    OSStatus status = errSecUnimplemented;
    int count = 0;
    IXSecCopyFn copy = ix_raw_copy;
    if (!copy || !service.length || !group.length) {
        IXSessionDiagLine([NSString stringWithFormat:@"kc_proof phase=%@ service=%@ status=%d count=0 group=%@",
                           phase ?: @"?", IXShort(service, 80), copy ? 0 : -1, label ?: @"-"]);
        return;
    }
    query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccessGroup: group,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    } mutableCopy];
    status = copy((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        if (CFGetTypeID(result) == CFArrayGetTypeID()) count = (int)CFArrayGetCount(result);
        else count = 1;
    }
    if (result) CFRelease(result);
    IXSessionDiagLine([NSString stringWithFormat:@"kc_proof phase=%@ service=%@ status=%d count=%d group=%@",
                       phase ?: @"?", IXShort(service, 80), (int)status, count, label ?: @"-"]);
}

static void IXKeychainProof(NSString *phase) {
    if (ix_entitled_group.length == 0) {
        IXSessionDiagLine([NSString stringWithFormat:@"kc_proof phase=%@ service=- status=0 count=0 group=missing", phase ?: @"?"]);
    } else {
        IXProofQuery(phase, @"instagram.activeaccount", ix_entitled_group, @"entitled");
        IXProofQuery(phase, @"instagram.inactiveloggedinaccounts", ix_entitled_group, @"entitled");
        IXProofQuery(phase, @"com.instagram.users.authheaders.service", ix_entitled_group, @"entitled");
    }
    IXProofQuery(phase, @"instagram.activeaccount", @"group.com.facebook.family", @"family");
}

static NSString *IXDocsDir(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return docs;
}

static NSString *IXMobileconfigLive(void) {
    return [IXDocsDir() stringByAppendingPathComponent:@"mobileconfig"];
}

static NSString *IXMobileconfigKeep(void) {
    return [[IXDocsDir() stringByAppendingPathComponent:@"InstagramX"] stringByAppendingPathComponent:@"mobileconfig-keep"];
}

static int IXDirExists(NSString *path) {
    BOOL dir = NO;
    if (path.length == 0) return 0;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&dir] && dir;
}

static int IXMcEnter(void) {
    int entered = 0;
    pthread_mutex_lock(&ix_watch_mu);
    if (ix_mc_depth == 0) {
        ix_mc_depth = 1;
        entered = 1;
    }
    pthread_mutex_unlock(&ix_watch_mu);
    return entered;
}

static void IXMcLeave(void) {
    pthread_mutex_lock(&ix_watch_mu);
    ix_mc_depth = 0;
    pthread_mutex_unlock(&ix_watch_mu);
}

static int IXCopyTree(NSString *from, NSString *to) {
    NSFileManager *fm;
    if (!IXDirExists(from) || to.length == 0) return 0;
    fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm fileExistsAtPath:to]) [fm removeItemAtPath:to error:nil];
    if (![fm copyItemAtPath:from toPath:to error:nil]) return 0;
    return IXDirExists(to);
}

static void IXMobileconfigSync(NSString *phase) {
    int existed;
    int restored = 0;
    if (!IXMcEnter()) return;
    existed = IXDirExists(IXMobileconfigLive());
    if (existed) IXCopyTree(IXMobileconfigLive(), IXMobileconfigKeep());
    else if (IXDirExists(IXMobileconfigKeep())) restored = IXCopyTree(IXMobileconfigKeep(), IXMobileconfigLive());
    IXMcLeave();
    IXSessionDiagLine([NSString stringWithFormat:@"mobileconfig_restore phase=%@ existed=%d restored=%d",
                       phase ?: @"?", existed, restored]);
}

static int IXLiveMobileconfig(NSString *path) {
    if (path.length == 0) return 0;
    if ([path rangeOfString:@"mobileconfig-keep"].location != NSNotFound) return 0;
    return [path rangeOfString:@"/mobileconfig"].location != NSNotFound ||
           [path.lastPathComponent isEqualToString:@"mobileconfig"];
}

static void IXNoteLogout(id object, SEL sel, long long entry, int hasEntry) {
    int room;
    const char *name = sel ? sel_getName(sel) : NULL;
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_logout_logs < 24;
    if (room) ix_logout_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (!room) return;
    if (hasEntry) {
        IXSessionDiagLine([NSString stringWithFormat:@"logout_reason class=%s sel=%s entry=%lld",
                           object_getClassName(object) ?: "?",
                           name ?: "?",
                           entry]);
    } else {
        IXSessionDiagLine([NSString stringWithFormat:@"logout_reason class=%s sel=%s entry=none",
                           object_getClassName(object) ?: "?",
                           name ?: "?"]);
    }
    IXFrames(@"logout");
}

static IMP IXLogoutOrig(id object, SEL sel) {
    Class cls = object_getClass(object);
    while (cls) {
        for (int i = 0; i < ix_logout_count; i++) {
            if (ix_logout_slots[i].cls == cls && ix_logout_slots[i].sel == sel) return ix_logout_slots[i].orig;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void ix_logout0(id self, SEL _cmd) {
    IMP orig;
    IXNoteLogout(self, _cmd, 0, 0);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

static void ix_logout1(id self, SEL _cmd, id arg) {
    IMP orig;
    (void)arg;
    IXNoteLogout(self, _cmd, 0, 0);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static void ix_logout_q(id self, SEL _cmd, long long entry) {
    IMP orig;
    IXNoteLogout(self, _cmd, entry, 1);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, long long))orig)(self, _cmd, entry);
}

static void ix_logout_i(id self, SEL _cmd, int entry) {
    IMP orig;
    IXNoteLogout(self, _cmd, entry, 1);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, int))orig)(self, _cmd, entry);
}

static void ix_logout_q_obj(id self, SEL _cmd, long long entry, id arg) {
    IMP orig;
    (void)arg;
    IXNoteLogout(self, _cmd, entry, 1);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, long long, id))orig)(self, _cmd, entry, arg);
}

static int IXLogoutClassName(const char *name) {
    if (!name) return 0;
    return strcmp(name, "IGUserAuthManager") == 0 || strcmp(name, "IGAuthService") == 0 ||
           strcmp(name, "IGAuthHelper") == 0 || strcmp(name, "IGUserSession") == 0 ||
           strcmp(name, "IGAccountStore") == 0 || strcmp(name, "IGAccountLogoutManager") == 0 ||
           strstr(name, "Logout") != NULL || strstr(name, "SessionManager") != NULL ||
           strstr(name, "AuthHelper") != NULL;
}

static int IXLogoutSelector(SEL sel) {
    const char *name = sel ? sel_getName(sel) : NULL;
    if (!name) return 0;
    return strstr(name, "logout") || strstr(name, "logOut") || strstr(name, "Logout") ||
           strstr(name, "logoff") || strstr(name, "LogOff") || strstr(name, "invalidateSession") ||
           strstr(name, "clearSession") || strstr(name, "clearAllUsers") || strstr(name, "removeUser");
}

static void IXConsiderLogout(Class cls, Method method, int forcedOnly) {
    SEL sel;
    const char *selName;
    const char *types;
    const char *className;
    IMP current;
    IMP repl;
    int arity;
    int forced;
    if (!cls || !method || ix_logout_count >= 64) return;
    sel = method_getName(method);
    selName = sel ? sel_getName(sel) : NULL;
    forced = selName && strstr(selName, "clearAllUsers");
    if (forcedOnly && !forced) return;
    className = class_getName(cls);
    if (!forced && !IXLogoutClassName(className)) return;
    if (!IXLogoutSelector(sel)) return;
    types = method_getTypeEncoding(method);
    if (!types) return;
    if (strcmp(types, "v16@0:8") == 0) {
        arity = 0;
        repl = (IMP)ix_logout0;
    } else if (strcmp(types, "v24@0:8@16") == 0) {
        arity = 1;
        repl = (IMP)ix_logout1;
    } else if (strcmp(types, "v24@0:8q16") == 0 || strcmp(types, "v24@0:8Q16") == 0) {
        arity = 2;
        repl = (IMP)ix_logout_q;
    } else if (strcmp(types, "v20@0:8i16") == 0) {
        arity = 2;
        repl = (IMP)ix_logout_i;
    } else if (strcmp(types, "v32@0:8q16@24") == 0 || strcmp(types, "v32@0:8Q16@24") == 0) {
        arity = 3;
        repl = (IMP)ix_logout_q_obj;
    } else {
        if (forced) {
            static int logs = 0;
            if (logs < 8) {
                logs++;
                IXSessionDiagLine([NSString stringWithFormat:@"logout_unhooked class=%s sel=%s types=%s",
                                   className ?: "?", selName ?: "?", types]);
            }
        }
        return;
    }
    current = method_getImplementation(method);
    if (current == (IMP)ix_logout0 || current == (IMP)ix_logout1 || current == (IMP)ix_logout_q ||
        current == (IMP)ix_logout_i || current == (IMP)ix_logout_q_obj) return;
    ix_logout_slots[ix_logout_count].cls = cls;
    ix_logout_slots[ix_logout_count].sel = sel;
    ix_logout_slots[ix_logout_count].arity = arity;
    ix_logout_slots[ix_logout_count].orig = method_setImplementation(method, repl);
    ix_logout_count++;
}

static void IXInstallLogoutHooks(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    int pass;
    if (!classes) return;
    for (pass = 0; pass < 2; pass++) {
        for (unsigned int i = 0; i < classCount && ix_logout_count < 64; i++) {
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(classes[i], &methodCount);
            for (unsigned int m = 0; m < methodCount && ix_logout_count < 64; m++) {
                IXConsiderLogout(classes[i], methods[m], pass == 0);
            }
            if (methods) free(methods);
        }
    }
    free(classes);
}

static NSString *IXHashText(NSString *value) {
    uint8_t dig[32];
    const char *utf;
    char out[9];
    static const char *hex = "0123456789abcdef";
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 256) return nil;
    utf = value.UTF8String;
    if (!utf || ix_sha256((const uint8_t *)utf, strlen(utf), dig) != 0) return nil;
    for (int i = 0; i < 4; i++) {
        out[i * 2] = hex[dig[i] >> 4];
        out[i * 2 + 1] = hex[dig[i] & 0xf];
    }
    out[8] = 0;
    return [NSString stringWithUTF8String:out];
}

static NSString *IXCookieValue(NSString *name) {
    NSURL *url = [NSURL URLWithString:@"https://i.instagram.com/"];
    if (!url || name.length == 0) return nil;
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]) {
        if ([cookie.name isEqualToString:name] && cookie.value.length > 0) return cookie.value;
    }
    return nil;
}

static NSString *IXDefaultString(NSString *key) {
    id value = nil;
    @try { value = [[NSUserDefaults standardUserDefaults] objectForKey:key]; }
    @catch (__unused NSException *exception) { value = nil; }
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) return value;
    return nil;
}

static NSString *IXPlistString(NSString *key) {
    NSString *home = NSHomeDirectory();
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"com.burbn.instagram";
    NSArray *paths = @[
        [home stringByAppendingPathComponent:[@"Library/Preferences" stringByAppendingPathComponent:[bundle stringByAppendingString:@".plist"]]],
        [home stringByAppendingPathComponent:@"Documents/group.com.burbn.instagram/Library/Preferences/group.com.burbn.instagram.plist"],
        [home stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup/Library/Preferences/group.com.burbn.instagram.plist"]
    ];
    for (NSString *path in paths) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        id value = [dict isKindOfClass:[NSDictionary class]] ? dict[key] : nil;
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) return value;
    }
    return nil;
}

static NSString *IXSignal(NSString *key, NSString *cookieName) {
    NSString *value = cookieName.length ? IXCookieValue(cookieName) : nil;
    if (!value) value = IXDefaultString(key);
    if (!value) value = IXPlistString(key);
    return IXHashText(value);
}

static NSString *IXIdStatePath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *dir = [docs stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ix_id_hash.plist"];
}

static unsigned long long IXFileBytes(NSString *path) {
    NSDictionary *attr;
    NSNumber *size;
    if (path.length == 0) return 0;
    attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    size = [attr isKindOfClass:[NSDictionary class]] ? attr[NSFileSize] : nil;
    return [size isKindOfClass:[NSNumber class]] ? size.unsignedLongLongValue : 0;
}

static void IXPersistProof(NSString *phase) {
    NSString *home = NSHomeDirectory() ?: @"";
    NSString *docs = IXDocsDir();
    NSString *ig = @"group.com.burbn.instagram";
    NSString *family = @"group.com.facebook.family";
    NSString *igSandbox = [[docs stringByAppendingPathComponent:ig] stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", ig]];
    NSString *familySandbox = [[docs stringByAppendingPathComponent:family] stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", family]];
    IXSessionDiagLine([NSString stringWithFormat:@"persist_proof phase=%@ ig_sandbox=%llu ig_home=%llu family_sandbox=%llu family_home=%llu cookie_home=%llu cookie_group=%llu",
                       phase ?: @"?",
                       IXFileBytes(igSandbox),
                       IXFileBytes([home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", ig]]),
                       IXFileBytes(familySandbox),
                       IXFileBytes([home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", family]]),
                       IXFileBytes([home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"]),
                       IXFileBytes([[docs stringByAppendingPathComponent:ig] stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"])]);
}

void IXSessionWatchSnapshot(NSString *phase) {
    NSHTTPCookie *cookie = IXSessionCookie();
    NSDictionary *previous = [NSDictionary dictionaryWithContentsOfFile:IXIdStatePath()];
    NSMutableDictionary *next = [previous isKindOfClass:[NSDictionary class]] ? [previous mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableString *ids = [NSMutableString stringWithString:@"ids"];
    NSDictionary *signals = @{
        @"phone_id": @"",
        @"ig_did": @"ig_did",
        @"device_id": @"",
        @"guid": @"",
        @"waterfall_id": @"",
        @"mid": @"mid",
        @"session": @"sessionid"
    };
    BOOL us = NO;
    BOOL tzSpoof = NO;
    BOOL fake = NO;
    NSInteger status = 0;
    NSInteger error = 0;
    NSString *marker = @"none";
    NSString *host = @"-";
    int seen = 0;
    @try { us = [[NSUserDefaults standardUserDefaults] boolForKey:@"ix_us_region"]; }
    @catch (__unused NSException *exception) { us = NO; }
    @try {
        fake = [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_enabled"];
        tzSpoof = fake && [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_spoof_tz"];
    } @catch (__unused NSException *exception) { tzSpoof = NO; }
    for (NSString *key in @[@"phone_id", @"ig_did", @"device_id", @"guid", @"waterfall_id", @"mid", @"session"]) {
        NSString *hash = IXSignal(key, signals[key]);
        NSString *prior = [previous[key] isKindOfClass:[NSString class]] ? previous[key] : nil;
        NSString *flag = @"same";
        if (!hash) {
            [ids appendFormat:@" %@=%@", key, prior.length ? @"missing" : @"absent"];
            continue;
        }
        if (prior.length && ![prior isEqualToString:hash]) flag = @"changed";
        else if (!prior.length) flag = @"new";
        next[key] = hash;
        [ids appendFormat:@" %@=%@/%@", key, hash, flag];
    }
    {
        NSString *hash = IXHashText(UIDevice.currentDevice.identifierForVendor.UUIDString);
        NSString *prior = [previous[@"vendor"] isKindOfClass:[NSString class]] ? previous[@"vendor"] : nil;
        NSString *flag = @"same";
        if (!hash) [ids appendString:prior.length ? @" vendor=missing" : @" vendor=absent"];
        else {
            if (prior.length && ![prior isEqualToString:hash]) flag = @"changed";
            else if (!prior.length) flag = @"new";
            next[@"vendor"] = hash;
            [ids appendFormat:@" vendor=%@/%@", hash, flag];
        }
    }
    [next writeToFile:IXIdStatePath() atomically:YES];
    pthread_mutex_lock(&ix_watch_mu);
    seen = ix_http_seen;
    status = ix_http_status;
    error = ix_http_error;
    marker = ix_http_marker ?: @"none";
    host = ix_http_host ?: @"-";
    pthread_mutex_unlock(&ix_watch_mu);
    IXSessionDiagLine([NSString stringWithFormat:@"session phase=%@ cookie=%@ expires=%@ http_seen=%d http_status=%@ http_error=%ld http_marker=%@ http_host=%@",
                       phase.length ? phase : @"?",
                       cookie ? @"yes" : @"no",
                       cookie ? IXExpiryText(cookie.expiresDate) : @"-",
                       seen,
                       seen ? [NSString stringWithFormat:@"%ld", (long)status] : @"none",
                       (long)error,
                       marker,
                       host]);
    IXSessionDiagLine([NSString stringWithFormat:@"%@ us_region=%d tz_spoof=%d identity_rewrite=0 tz=%@ country=%@",
                       ids,
                       us ? 1 : 0,
                       tzSpoof ? 1 : 0,
                       NSTimeZone.localTimeZone.name ?: @"-",
                       [NSLocale.currentLocale objectForKey:NSLocaleCountryCode] ?: @"-"]);
    IXMobileconfigSync(phase);
    IXKeychainProof(phase);
    IXPersistProof(phase);
}

static void IXArmSec(int probeNow) {
    const char *names[4] = { "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete" };
    void *repl[4] = { (void *)ix_sec_add, (void *)ix_sec_copy, (void *)ix_sec_update, (void *)ix_sec_delete };
    IXCaptureRaw();
    if (probeNow) IXProbeEntitledGroup();
    IXSymbolRebindPermanent(names, repl, 4);
    IXResolvePrev();
}

void IXSessionWatchArm(void) {
    static int announced = 0;
    pthread_mutex_lock(&ix_watch_mu);
    if (ix_watch_clock == 0) ix_watch_clock = CFAbsoluteTimeGetCurrent();
    pthread_mutex_unlock(&ix_watch_mu);
    IXMobileconfigSync(@"arm");
    IXArmSec(1);
    IXInstallLogoutHooks();
    if (!announced) {
        announced = 1;
        IXSessionDiagLine([NSString stringWithFormat:@"kc_chain hooked=%d call=real group=%@",
                           ix_chain_hooked, ix_entitled_group.length ? ix_entitled_group : @"-"]);
        IXSessionDiagLine(@"watch secitem_rewrite=on rewrite=1");
    }
}

static BOOL IXSensitivePath(NSString *path) {
    if (path.length == 0) return NO;
    return IXSessionSensitiveName(path.UTF8String) == 1;
}

static void IXNoteFile(NSString *path) {
    int room;
    if (!IXSensitivePath(path)) return;
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_file_logs < 30;
    if (room) ix_file_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (!room) return;
    IXSessionDiagLine([NSString stringWithFormat:@"file_remove path=%@", path.length > 180 ? [path substringFromIndex:path.length - 180] : path]);
    IXFrames(@"file_remove");
}

%hook NSHTTPCookieStorage
+ (NSHTTPCookieStorage *)sharedCookieStorageForGroupContainerIdentifier:(NSString *)identifier {
    static int logs = 0;
    if (IXSessionPersistSuite(identifier.UTF8String)) {
        if (logs < 8) {
            logs++;
            IXSessionDiagLine([NSString stringWithFormat:@"cookie_redirect suite=%@", identifier.length > 80 ? [identifier substringToIndex:80] : identifier]);
        }
        return [self sharedHTTPCookieStorage];
    }
    return %orig;
}
- (void)deleteCookie:(NSHTTPCookie *)cookie {
    int room = 0;
    if ([cookie isKindOfClass:[NSHTTPCookie class]] && (IXSessionSensitiveName(cookie.name.UTF8String) ||
        [cookie.name isEqualToString:@"mid"] || [cookie.name isEqualToString:@"rur"] || [cookie.name isEqualToString:@"csrftoken"])) {
        pthread_mutex_lock(&ix_watch_mu);
        room = ix_cookie_logs < 20;
        if (room) ix_cookie_logs++;
        pthread_mutex_unlock(&ix_watch_mu);
    }
    if (room) {
        IXSessionDiagLine([NSString stringWithFormat:@"cookie_delete name=%@ expires=%@",
                           cookie.name.length > 40 ? [cookie.name substringToIndex:40] : (cookie.name ?: @"-"),
                           IXExpiryText(cookie.expiresDate)]);
        IXFrames(@"cookie_delete");
    }
    %orig;
}
- (void)removeCookiesSinceDate:(NSDate *)date {
    int room;
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_cookie_logs < 20;
    if (room) ix_cookie_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (room) {
        IXSessionDiagLine([NSString stringWithFormat:@"cookie_bulk since=%@", IXExpiryText(date)]);
        IXFrames(@"cookie_bulk");
    }
    %orig;
}
%end

%hook NSUserDefaults
- (void)removeObjectForKey:(NSString *)key {
    int room = 0;
    if ([key isKindOfClass:[NSString class]] && IXSessionSensitiveName(key.UTF8String)) {
        pthread_mutex_lock(&ix_watch_mu);
        room = ix_pref_logs < 30;
        if (room) ix_pref_logs++;
        pthread_mutex_unlock(&ix_watch_mu);
    }
    if (room) {
        IXSessionDiagLine([NSString stringWithFormat:@"pref_remove key=%@", key.length > 80 ? [key substringToIndex:80] : key]);
        IXFrames(@"pref_remove");
    }
    %orig;
}
- (void)removePersistentDomainForName:(NSString *)name {
    int room = 0;
    if ([name isKindOfClass:[NSString class]] && IXSessionSensitiveName(name.UTF8String)) {
        pthread_mutex_lock(&ix_watch_mu);
        room = ix_pref_logs < 30;
        if (room) ix_pref_logs++;
        pthread_mutex_unlock(&ix_watch_mu);
    }
    if (room) {
        IXSessionDiagLine([NSString stringWithFormat:@"pref_domain_remove name=%@", name.length > 80 ? [name substringToIndex:80] : name]);
        IXFrames(@"pref_domain_remove");
    }
    %orig;
}
%end

%hook NSFileManager
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    int existed = 0;
    int restored = 0;
    int keep = IXLiveMobileconfig(path) && IXMcEnter();
    BOOL ok;
    IXNoteFile(path);
    if (keep) {
        existed = IXDirExists(IXMobileconfigLive());
        if (existed) IXCopyTree(IXMobileconfigLive(), IXMobileconfigKeep());
    }
    ok = %orig;
    if (keep) {
        if (IXDirExists(IXMobileconfigKeep())) restored = IXCopyTree(IXMobileconfigKeep(), IXMobileconfigLive());
        IXMcLeave();
        IXSessionDiagLine([NSString stringWithFormat:@"mobileconfig_restore phase=remove existed=%d restored=%d", existed, restored]);
    }
    return ok;
}
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
    NSString *path = url.path;
    int existed = 0;
    int restored = 0;
    int keep = IXLiveMobileconfig(path) && IXMcEnter();
    BOOL ok;
    IXNoteFile(path);
    if (keep) {
        existed = IXDirExists(IXMobileconfigLive());
        if (existed) IXCopyTree(IXMobileconfigLive(), IXMobileconfigKeep());
    }
    ok = %orig;
    if (keep) {
        if (IXDirExists(IXMobileconfigKeep())) restored = IXCopyTree(IXMobileconfigKeep(), IXMobileconfigLive());
        IXMcLeave();
        IXSessionDiagLine([NSString stringWithFormat:@"mobileconfig_restore phase=remove existed=%d restored=%d", existed, restored]);
    }
    return ok;
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    return %orig(request, IXWrapCompletion(request, completionHandler));
}
%end

%hook NSHTTPURLResponse
- (instancetype)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)version headerFields:(NSDictionary<NSString *, NSString *> *)headerFields {
    id object = %orig;
    IXRememberHTTP(url, statusCode, nil, nil, @"unknown");
    return object;
}
%end

%ctor {
    %init;
    pthread_mutex_lock(&ix_watch_mu);
    if (ix_watch_clock == 0) ix_watch_clock = CFAbsoluteTimeGetCurrent();
    pthread_mutex_unlock(&ix_watch_mu);
    IXMobileconfigSync(@"ctor");
    IXArmSec(0);
    IXInstallLogoutHooks();
    IXSessionDiagLine(@"cookie_hook ctor=1");
}
