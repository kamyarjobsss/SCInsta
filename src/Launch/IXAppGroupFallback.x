#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"

// v2.4.0 rewrote kSecAttrAccessGroup only when the caller set a group the
// signed task did not list. Instagram often omits the group, and the
// entitled list can be unread on one launch and present on the next, so a
// write and the following read landed in different groups. The unmodded
// sideload (zxPluginsInject) probes SecItem once with no access group and
// then forces that same group on every add, copy, update, and delete.
// This file does that, and it does not change kSecAttrAccessible.
//
// The container path matches that sideload too: the first real app-group
// directory plus the identifier Instagram passed, or Documents/<identifier>
// with the team prefix left on. A nil container used to be filled with the
// prefix stripped, so the folder changed when the prefix was re-read.

static NSString *ix_probed_group;
static int ix_probe_status = errSecUnimplemented;
static NSString *ix_app_id;
static NSArray *ix_entitled;

static void IXLoadEntitlements(void) {
    ix_entitled = @[];
    typedef struct __SecTask *IXSecTaskRef;
    typedef IXSecTaskRef (*IXSecTaskCreate)(CFAllocatorRef);
    typedef CFTypeRef (*IXSecTaskCopy)(IXSecTaskRef, CFStringRef, CFErrorRef *);
    IXSecTaskCreate createFn = (IXSecTaskCreate)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    IXSecTaskCopy copyFn = (IXSecTaskCopy)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (createFn && copyFn) {
        IXSecTaskRef task = createFn(NULL);
        if (task) {
            CFTypeRef app = copyFn(task, CFSTR("application-identifier"), NULL);
            if (!app) app = copyFn(task, CFSTR("com.apple.application-identifier"), NULL);
            if (app && CFGetTypeID(app) == CFStringGetTypeID()) ix_app_id = [(__bridge NSString *)app copy];
            if (app) CFRelease(app);
            CFTypeRef groups = copyFn(task, CFSTR("keychain-access-groups"), NULL);
            if (groups && CFGetTypeID(groups) == CFArrayGetTypeID()) {
                NSMutableArray *list = [NSMutableArray array];
                CFIndex count = CFArrayGetCount(groups);
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef item = CFArrayGetValueAtIndex(groups, i);
                    if (item && CFGetTypeID(item) == CFStringGetTypeID()) [list addObject:(__bridge NSString *)item];
                }
                ix_entitled = [list copy];
            }
            if (groups) CFRelease(groups);
            CFRelease((CFTypeRef)task);
        }
    }
    if (ix_app_id.length == 0 || ix_entitled.count == 0) {
        Class cls = objc_getClass("LSBundleProxy");
        id proxy = nil;
        if (cls && [cls respondsToSelector:sel_registerName("bundleProxyForCurrentProcess")]) {
            @try { proxy = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("bundleProxyForCurrentProcess")); }
            @catch (__unused NSException *exception) { proxy = nil; }
        }
        NSDictionary *ent = nil;
        if (proxy && [proxy respondsToSelector:sel_registerName("entitlements")]) {
            @try { ent = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("entitlements")); }
            @catch (__unused NSException *exception) { ent = nil; }
        }
        if ([ent isKindOfClass:[NSDictionary class]]) {
            if (ix_app_id.length == 0) {
                id app = ent[@"application-identifier"] ?: ent[@"com.apple.application-identifier"];
                if ([app isKindOfClass:[NSString class]] && [app length]) ix_app_id = [app copy];
            }
            if (ix_entitled.count == 0) {
                id groups = ent[@"keychain-access-groups"];
                if ([groups isKindOfClass:[NSArray class]]) ix_entitled = [groups copy];
            }
        }
    }
}

static void IXProbeAccessGroup(void) {
    OSStatus (*copyFn)(CFDictionaryRef, CFTypeRef *) = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    OSStatus (*addFn)(CFDictionaryRef, CFTypeRef *) = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
    if (!copyFn || !addFn) {
        ix_probe_status = errSecUnimplemented;
        return;
    }
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"zxPluginsInjectGenericEntry",
        (__bridge id)kSecAttrService: @"",
        (__bridge id)kSecReturnAttributes: (__bridge id)kCFBooleanTrue
    };
    CFTypeRef result = NULL;
    OSStatus status = copyFn((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        if (result) CFRelease(result);
        result = NULL;
        status = addFn((__bridge CFDictionaryRef)query, &result);
        if (status == errSecDuplicateItem) {
            if (result) CFRelease(result);
            result = NULL;
            status = copyFn((__bridge CFDictionaryRef)query, &result);
        }
    }
    ix_probe_status = (int)status;
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        id group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:[NSString class]] && [group length]) {
            char forced[768];
            if (IXSessionProbedGroup([(NSString *)group UTF8String], forced, sizeof forced)) {
                ix_probed_group = [[NSString alloc] initWithUTF8String:forced];
            }
        }
    }
    if (result) CFRelease(result);
    IXSessionDiagKeychain("probe", ix_probe_status, ix_probed_group, 0);
}

static OSStatus (*ix_orig_add)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*ix_orig_copy)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*ix_orig_update)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*ix_orig_delete)(CFDictionaryRef);

static CFDictionaryRef IXForceGroup(CFDictionaryRef query, int *owned, int *callerHad, NSString **used) {
    if (owned) *owned = 0;
    if (callerHad) *callerHad = 0;
    if (used) *used = ix_probed_group;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return query;
    NSDictionary *dict = (__bridge NSDictionary *)query;
    id existing = dict[(__bridge id)kSecAttrAccessGroup];
    BOOL had = [existing isKindOfClass:[NSString class]] && [(NSString *)existing length] > 0;
    if (callerHad) *callerHad = had ? 1 : 0;
    if (ix_probed_group.length) {
        if (had && [existing isEqualToString:ix_probed_group]) return query;
        NSMutableDictionary *copy = [dict mutableCopy];
        if (!copy) return query;
        copy[(__bridge id)kSecAttrAccessGroup] = ix_probed_group;
        if (owned) *owned = 1;
        return (CFDictionaryRef)CFBridgingRetain(copy);
    }
    if (!had) return query;
    NSMutableDictionary *copy = [dict mutableCopy];
    if (!copy) return query;
    [copy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    if (owned) *owned = 1;
    if (used) *used = nil;
    return (CFDictionaryRef)CFBridgingRetain(copy);
}

static OSStatus ix_sec_add(CFDictionaryRef query, CFTypeRef *result) {
    int owned = 0, had = 0;
    NSString *used = nil;
    CFDictionaryRef fixed = IXForceGroup(query, &owned, &had, &used);
    OSStatus status = ix_orig_add ? ix_orig_add(fixed, result) : errSecUnimplemented;
    IXSessionDiagKeychain("add", (int)status, used, had);
    if (owned) CFRelease(fixed);
    return status;
}
static OSStatus ix_sec_copy(CFDictionaryRef query, CFTypeRef *result) {
    int owned = 0, had = 0;
    NSString *used = nil;
    CFDictionaryRef fixed = IXForceGroup(query, &owned, &had, &used);
    OSStatus status = ix_orig_copy ? ix_orig_copy(fixed, result) : errSecUnimplemented;
    IXSessionDiagKeychain("copy", (int)status, used, had);
    if (owned) CFRelease(fixed);
    return status;
}
static OSStatus ix_sec_update(CFDictionaryRef query, CFDictionaryRef attrs) {
    int owned = 0, had = 0;
    NSString *used = nil;
    CFDictionaryRef fixed = IXForceGroup(query, &owned, &had, &used);
    OSStatus status = ix_orig_update ? ix_orig_update(fixed, attrs) : errSecUnimplemented;
    IXSessionDiagKeychain("update", (int)status, used, had);
    if (owned) CFRelease(fixed);
    return status;
}
static OSStatus ix_sec_delete(CFDictionaryRef query) {
    int owned = 0, had = 0;
    NSString *used = nil;
    CFDictionaryRef fixed = IXForceGroup(query, &owned, &had, &used);
    OSStatus status = ix_orig_delete ? ix_orig_delete(fixed) : errSecUnimplemented;
    IXSessionDiagKeychain("delete", (int)status, used, had);
    if (owned) CFRelease(fixed);
    return status;
}

static void IXInstallKeychainRewrite(void) {
    ix_orig_add = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemAdd");
    ix_orig_copy = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    ix_orig_update = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemUpdate");
    ix_orig_delete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
    const char *names[4] = {"SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete"};
    void *replacements[4] = {(void *)ix_sec_add, (void *)ix_sec_copy, (void *)ix_sec_update, (void *)ix_sec_delete};
    int slots = IXSymbolRebindPermanent(names, replacements, 4);
    NSLog(@"[InstagramX] keychain probe status %d group %@ slots %d", ix_probe_status, ix_probed_group ?: @"default", slots);
}

static NSURL *IXRealGroupBase(void) {
    static NSURL *cached = nil;
    static int ready = 0;
    if (ready) return cached;
    ready = 1;
    Class cls = objc_getClass("LSBundleProxy");
    if (!cls || ![cls respondsToSelector:sel_registerName("bundleProxyForCurrentProcess")]) return nil;
    id proxy = nil;
    @try { proxy = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("bundleProxyForCurrentProcess")); }
    @catch (__unused NSException *exception) { return nil; }
    if (!proxy) return nil;
    NSDictionary *ent = nil;
    if ([proxy respondsToSelector:sel_registerName("entitlements")]) {
        @try { ent = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("entitlements")); }
        @catch (__unused NSException *exception) { ent = nil; }
    }
    NSArray *groups = [ent isKindOfClass:[NSDictionary class]] ? ent[@"com.apple.security.application-groups"] : nil;
    if (![groups isKindOfClass:[NSArray class]] || groups.count == 0) return nil;
    id paths = nil;
    if ([proxy respondsToSelector:sel_registerName("groupContainerURLs")]) {
        @try { paths = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("groupContainerURLs")); }
        @catch (__unused NSException *exception) { paths = nil; }
    }
    if (![paths isKindOfClass:[NSDictionary class]]) return nil;
    id first = groups.firstObject;
    id url = [first isKindOfClass:[NSString class]] ? ((NSDictionary *)paths)[first] : nil;
    if ([url isKindOfClass:[NSURL class]]) cached = url;
    else if ([url isKindOfClass:[NSString class]] && [(NSString *)url length]) cached = [NSURL fileURLWithPath:url isDirectory:YES];
    return cached;
}

static NSString *IXGroupIdentifier(id name) {
    if ([name isKindOfClass:[NSString class]] && [name length]) {
        char leaf[512];
        if (IXSessionContainerComponent([(NSString *)name UTF8String], leaf, sizeof leaf)) {
            return [NSString stringWithUTF8String:leaf] ?: @"group.com.burbn.instagram";
        }
    }
    return @"group.com.burbn.instagram";
}

static NSURL *IXZXContainerURL(NSString *identifier) {
    NSString *leaf = IXGroupIdentifier(identifier);
    NSURL *base = IXRealGroupBase();
    NSString *path = nil;
    if (base.path.length) path = [base.path stringByAppendingPathComponent:leaf];
    else {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
        if (docs.length == 0) return nil;
        path = [docs stringByAppendingPathComponent:leaf];
    }
    if (path.length == 0) return nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static void IXCopyMissing(NSFileManager *fm, NSString *src, NSString *dst) {
    BOOL srcDir = NO;
    if (![fm fileExistsAtPath:src isDirectory:&srcDir] || !srcDir) return;
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *items = [fm contentsOfDirectoryAtPath:src error:nil];
    for (NSString *name in items) {
        if (![name isKindOfClass:[NSString class]] || [name hasPrefix:@"."]) continue;
        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to = [dst stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:from isDirectory:&isDir]) continue;
        if (isDir) IXCopyMissing(fm, from, to);
        else if (![fm fileExistsAtPath:to]) [fm copyItemAtPath:from toPath:to error:nil];
    }
}

static void IXMigrateAccountFiles(void) {
    NSURL *dest = IXZXContainerURL(@"group.com.burbn.instagram");
    if (dest.path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *sources = [NSMutableArray array];
    [sources addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup"]];
    NSString *legacyRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:legacyRoot error:nil]) {
        if ([kid isKindOfClass:[NSString class]]) [sources addObject:[legacyRoot stringByAppendingPathComponent:kid]];
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (![kid isKindOfClass:[NSString class]]) continue;
        if ([kid isEqualToString:@"group.com.burbn.instagram"] || [kid hasSuffix:@".group.com.burbn.instagram"]) {
            [sources addObject:[docs stringByAppendingPathComponent:kid]];
        }
    }
    for (NSString *src in sources) {
        if (src.length == 0 || [src isEqualToString:dest.path]) continue;
        IXCopyMissing(fm, src, dest.path);
    }
}

static id IXReadIvar(id object, const char *name) {
    if (!object || !name) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static void IXWriteIvar(id object, const char *name, id value) {
    if (!object || !name || !value) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return;
    object_setIvar(object, ivar, value);
}

static BOOL IXGroupIsUsable(id object) {
    if (!object) return NO;
    id identifier = IXReadIvar(object, "_identifier");
    if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) return NO;
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) return NO;
    if (![IXReadIvar(object, "_containerURL") isKindOfClass:[NSURL class]]) return NO;
    return YES;
}

static void IXFillAppGroup(id object, id name) {
    if (!object) return;
    NSString *requested = IXGroupIdentifier(name);
    id current = IXReadIvar(object, "_identifier");
    if (![current isKindOfClass:[NSString class]] || [current length] == 0) {
        IXWriteIvar(object, "_identifier", requested);
        current = requested;
    }
    if (![current isKindOfClass:[NSString class]] || [current length] == 0) return;
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:current];
        if (defaults) IXWriteIvar(object, "_userDefaults", defaults);
    }
    NSURL *url = IXZXContainerURL(current);
    id existing = IXReadIvar(object, "_containerURL");
    if (url && (![existing isKindOfClass:[NSURL class]] || ![existing path].length || ![((NSURL *)existing).path isEqualToString:url.path])) {
        IXWriteIvar(object, "_containerURL", url);
    }
    NSURL *logged = [url isKindOfClass:[NSURL class]] ? url : ([existing isKindOfClass:[NSURL class]] ? existing : nil);
    IXSessionDiagContext(logged.path, ix_probed_group, ix_probe_status, (unsigned long)ix_entitled.count);
}

static id IXMakeAppGroup(Class cls, id name) {
    if (!cls) cls = objc_getClass("METAAppGroup");
    if (!cls) return nil;
    id object = [[cls alloc] init];
    if (!object) return nil;
    IXFillAppGroup(object, name);
    return object;
}

static id IXEnsureAppGroup(id cls, id name, id existing) {
    if (existing) {
        IXFillAppGroup(existing, name);
        if (IXGroupIsUsable(existing)) return existing;
    }
    id made = IXMakeAppGroup((Class)cls, name);
    return IXGroupIsUsable(made) ? made : (made ?: existing);
}

static id (*ix_origAppGroup)(id cls, id name);

static id ix_directAppGroup(id cls, id name) {
    id object = nil;
    @try {
        if (ix_origAppGroup) object = ix_origAppGroup(cls, name);
    } @catch (__unused NSException *exception) {
        object = nil;
    }
    return IXEnsureAppGroup(cls, name, object);
}

static void IXInstallDirectAppGroup(void) {
    union { id (*fn)(id, id); void *ptr; } groupBits;
    groupBits.ptr = dlsym(RTLD_DEFAULT, "+<METAAppGroup appGroupForGroupName:>");
    ix_origAppGroup = groupBits.fn;
    if (!ix_origAppGroup) {
        NSLog(@"[InstagramX] app group symbol was not found; the direct abort path is unchanged");
        return;
    }
    union { id (*fn)(id, id); void *ptr; } bits = { ix_directAppGroup };
    const char *names[1] = { "+<METAAppGroup appGroupForGroupName:>" };
    void *replacements[1] = { bits.ptr };
    int slots = IXSymbolRebindPermanent(names, replacements, 1);
    NSLog(@"[InstagramX] app group direct call rebound (%d slots)", slots);
}

%hook METAAppGroup
+ (id)appGroupForGroupName:(id)name {
    id object = nil;
    @try { object = %orig; }
    @catch (__unused NSException *exception) { object = nil; }
    return IXEnsureAppGroup(self, name, object);
}
- (NSString *)identifier {
    NSString *value = nil;
    @try { value = %orig; }
    @catch (__unused NSException *exception) { value = nil; }
    if ([value isKindOfClass:[NSString class]] && value.length) return value;
    id filled = IXReadIvar(self, "_identifier");
    if ([filled isKindOfClass:[NSString class]] && [filled length]) return filled;
    return @"group.com.burbn.instagram";
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    NSURL *url = IXZXContainerURL(identifier);
    if (url) return url;
    @try { return %orig; }
    @catch (__unused NSException *exception) { return nil; }
}
%end

%ctor {
    IXProbeAccessGroup();
    IXLoadEntitlements();
    IXInstallKeychainRewrite();
    IXMigrateAccountFiles();
    NSURL *primary = IXZXContainerURL(@"group.com.burbn.instagram");
    IXSessionDiagContext(primary.path, ix_probed_group, ix_probe_status, (unsigned long)ix_entitled.count);
    %init;
    IXInstallDirectAppGroup();
}
