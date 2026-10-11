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

typedef OSStatus (*IXSecDeleteFn)(CFDictionaryRef);
static IXSecDeleteFn ix_real_delete;

typedef struct {
    Class cls;
    SEL sel;
    IMP orig;
    int arity;
} IXLogoutSlot;

static IXLogoutSlot ix_logout_slots[48];
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
    return (CFAbsoluteTimeGetCurrent() - start) < 20.0;
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

static void IXNoteSecDelete(CFDictionaryRef query) {
    NSDictionary *dict;
    NSString *service;
    NSString *group;
    int room;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return;
    dict = (__bridge NSDictionary *)query;
    service = dict[(__bridge id)kSecAttrService];
    if (IXOwnService(service)) return;
    group = dict[(__bridge id)kSecAttrAccessGroup];
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_sec_logs < 30;
    if (room) ix_sec_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (!room) return;
    IXSessionDiagLine([NSString stringWithFormat:@"secdelete class=%@ service=%@ acct_len=%lu group=%@",
                       [dict[(__bridge id)kSecClass] isKindOfClass:[NSString class]] ? dict[(__bridge id)kSecClass] : @"-",
                       [service isKindOfClass:[NSString class]] && service.length > 0 && service.length <= 80 ? service : (service ? @"len" : @"-"),
                       (unsigned long)([dict[(__bridge id)kSecAttrAccount] isKindOfClass:[NSString class]] ? [(NSString *)dict[(__bridge id)kSecAttrAccount] length] : 0),
                       [group isKindOfClass:[NSString class]] && group.length > 0 && group.length <= 80 ? group : (group ? @"len" : @"-")]);
    IXFrames(@"secdelete");
}

static OSStatus ix_log_sec_delete(CFDictionaryRef query) {
    IXSecDeleteFn next;
    IXNoteSecDelete(query);
    next = ix_real_delete;
    if (!next) next = (IXSecDeleteFn)dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (!next) return errSecUnimplemented;
    return next(query);
}

static void IXNoteLogout(id object, SEL sel) {
    int room;
    const char *name = sel ? sel_getName(sel) : NULL;
    pthread_mutex_lock(&ix_watch_mu);
    room = ix_logout_logs < 20;
    if (room) ix_logout_logs++;
    pthread_mutex_unlock(&ix_watch_mu);
    if (!room) return;
    IXSessionDiagLine([NSString stringWithFormat:@"logout class=%s sel=%s",
                       object_getClassName(object) ?: "?",
                       name ?: "?"]);
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
    IXNoteLogout(self, _cmd);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
}

static void ix_logout1(id self, SEL _cmd, id arg) {
    IMP orig;
    IXNoteLogout(self, _cmd);
    orig = IXLogoutOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
}

static int IXLogoutClassName(const char *name) {
    if (!name) return 0;
    return strcmp(name, "IGUserAuthManager") == 0 || strcmp(name, "IGAuthService") == 0 ||
           strcmp(name, "IGUserSession") == 0 || strcmp(name, "IGAccountStore") == 0 ||
           strcmp(name, "IGAccountLogoutManager") == 0 || strstr(name, "Logout") != NULL;
}

static int IXLogoutSelector(SEL sel) {
    const char *name = sel ? sel_getName(sel) : NULL;
    if (!name) return 0;
    return strstr(name, "logout") || strstr(name, "logOut") || strstr(name, "logoff") ||
           strstr(name, "LogOff") || strstr(name, "invalidateSession") || strstr(name, "clearSession");
}

static void IXInstallLogoutHooks(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    for (unsigned int i = 0; i < classCount && ix_logout_count < 48; i++) {
        unsigned int methodCount = 0;
        Method *methods;
        const char *name = class_getName(classes[i]);
        if (!IXLogoutClassName(name)) continue;
        methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int m = 0; m < methodCount && ix_logout_count < 48; m++) {
            SEL sel = method_getName(methods[m]);
            const char *types;
            IMP current;
            IMP repl;
            int arity;
            if (!IXLogoutSelector(sel)) continue;
            types = method_getTypeEncoding(methods[m]);
            if (!types) continue;
            if (strcmp(types, "v16@0:8") == 0) {
                arity = 0;
                repl = (IMP)ix_logout0;
            } else if (strcmp(types, "v24@0:8@16") == 0) {
                arity = 1;
                repl = (IMP)ix_logout1;
            } else continue;
            current = method_getImplementation(methods[m]);
            if (current == (IMP)ix_logout0 || current == (IMP)ix_logout1) continue;
            ix_logout_slots[ix_logout_count].cls = classes[i];
            ix_logout_slots[ix_logout_count].sel = sel;
            ix_logout_slots[ix_logout_count].arity = arity;
            ix_logout_slots[ix_logout_count].orig = method_setImplementation(methods[m], repl);
            ix_logout_count++;
        }
        if (methods) free(methods);
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
}

static void IXArmDelete(void) {
    const char *names[1] = { "SecItemDelete" };
    void *repl[1] = { (void *)ix_log_sec_delete };
    void *prev;
    IXSymbolRebindPermanent(names, repl, 1);
    prev = IXSymbolPrevious("SecItemDelete");
    if (!prev || prev == (void *)ix_log_sec_delete) prev = dlsym(RTLD_DEFAULT, "SecItemDelete");
    if (prev && prev != (void *)ix_log_sec_delete) ix_real_delete = (IXSecDeleteFn)prev;
}

void IXSessionWatchArm(void) {
    static int announced = 0;
    pthread_mutex_lock(&ix_watch_mu);
    if (ix_watch_clock == 0) ix_watch_clock = CFAbsoluteTimeGetCurrent();
    pthread_mutex_unlock(&ix_watch_mu);
    IXArmDelete();
    IXInstallLogoutHooks();
    if (!announced) {
        announced = 1;
        IXSessionDiagLine(@"watch secitem_delete_log=on rewrite=0");
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
    IXNoteFile(path);
    return %orig;
}
- (BOOL)removeItemAtURL:(NSURL *)url error:(NSError **)error {
    IXNoteFile(url.path);
    return %orig;
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
