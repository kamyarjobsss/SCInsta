#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionLaunch.h"
#import "IXSessionPersist.h"
#import "IXSessionSource.h"

#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>

@interface NSUserDefaults (IXContainerSuite)
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

static __thread int ix_suite_depth;

static void IXAdoptSuitePlist(NSString *suite, NSURL *container);

// The original IPA is entitled to group.com.burbn.instagram and
// group.com.facebook.family. A sideload profile is not, so those
// NSUserDefaults suites and the group cookie jar do not survive a relaunch.
// Instagram then starts with no user session and clears the account.
// containerURLForSecurityApplicationGroupIdentifier: returns
// Documents/<group id> (or the entitled parent when the profile has one).
// group.* suites are opened on that same directory. The app's own domain is
// not redirected. No preference key is written here. Files already stored
// under IXAppGroup are copied across, not deleted. A nil METAAppGroup
// identifier is filled from the SecItem probe. An identifier Instagram
// already set is not replaced.

static NSString *IXText(const char *value, NSString *fallback) {
    NSString *text = value ? [NSString stringWithUTF8String:value] : nil;
    return text.length ? text : fallback;
}

static NSURL *IXEntitledGroupParent(void) {
    static NSURL *cached;
    Class cls;
    SEL sel;
    id proxy;
    NSDictionary *entitlements;
    NSArray *groups;
    NSDictionary *urls;
    id first;
    id url;
    if (cached.path.length) return cached;
    cls = objc_getClass("LSBundleProxy");
    sel = sel_registerName("bundleProxyForCurrentProcess");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    @try { proxy = ((id (*)(id, SEL))objc_msgSend)(cls, sel); }
    @catch (__unused NSException *exception) { proxy = nil; }
    if (!proxy) return nil;
    @try { entitlements = [proxy valueForKey:@"entitlements"]; }
    @catch (__unused NSException *exception) { entitlements = nil; }
    if (![entitlements isKindOfClass:[NSDictionary class]]) return nil;
    groups = entitlements[@"com.apple.security.application-groups"];
    if (![groups isKindOfClass:[NSArray class]] || groups.count == 0) return nil;
    @try { urls = [proxy valueForKey:@"groupContainerURLs"]; }
    @catch (__unused NSException *exception) { urls = nil; }
    if (![urls isKindOfClass:[NSDictionary class]]) return nil;
    first = groups.firstObject;
    url = [first isKindOfClass:[NSString class]] ? urls[first] : nil;
    if (![url isKindOfClass:[NSURL class]] || [(NSURL *)url path].length == 0) return nil;
    cached = url;
    return cached;
}

// Same directory the base helper uses. The leaf is the group identifier,
// never the team-prefixed keychain group, so the path does not move when
// the signed prefix is re-read.
static NSURL *IXContainerURL(NSString *identifier) {
    char leaf[192];
    NSString *name = @"group.com.burbn.instagram";
    NSString *path;
    NSURL *parent;
    const char *raw = [identifier isKindOfClass:[NSString class]] ? identifier.UTF8String : NULL;
    if (IXSessionContainerLeaf(raw, leaf, sizeof leaf)) {
        NSString *text = [NSString stringWithUTF8String:leaf];
        if (text.length) name = text;
    }
    parent = IXSessionUseDocumentsContainer(raw) ? nil : IXEntitledGroupParent();
    if (parent.path.length) path = [parent.path stringByAppendingPathComponent:name];
    else {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
        if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        path = [docs stringByAppendingPathComponent:name];
    }
    if (path.length == 0) return nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static NSString *IXGroupIdentifier(id name) {
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length]) return name;
    return @"group.com.burbn.instagram";
}

static NSString *IXRealKeychainAccessGroup(void) {
    static NSString *cached;
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    if (cached.length) {
        NSString *found = cached;
        [lock unlock];
        return found;
    }
    NSDictionary *base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"instagramx.keychain-group-probe",
        (__bridge id)kSecAttrAccount: @"probe"
    };
    NSMutableDictionary *add = [base mutableCopy];
    add[(__bridge id)kSecValueData] = [@"ix" dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    add[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, &result);
    if (status != errSecSuccess || !result) {
        if (result) {
            CFRelease(result);
            result = NULL;
        }
        NSMutableDictionary *query = [base mutableCopy];
        query[(__bridge id)kSecReturnAttributes] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    }
    if (result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        id group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if ([group isKindOfClass:[NSString class]] && [group length]) cached = [group copy];
    }
    if (result) CFRelease(result);
    SecItemDelete((__bridge CFDictionaryRef)base);
    NSString *found = cached;
    [lock unlock];
    return found;
}

static NSString *IXDefaultsSuite(void) {
    char suite[128];
    if (!IXSessionDefaultsSuite(NULL, suite, sizeof suite)) return @"group.com.burbn.instagram";
    return IXText(suite, @"group.com.burbn.instagram");
}

// Only used when METAAppGroup's defaults ivar is nil. A nil defaults object
// crashes the direct call. The container is the same directory the group.*
// suite hook uses. This fill does not write preference keys.
static NSUserDefaults *IXGroupDefaults(NSString *suite) {
    NSURL *container;
    NSUserDefaults *defaults = nil;
    if (suite.length == 0 || ix_suite_depth) return nil;
    container = IXContainerURL(suite);
    IXAdoptSuitePlist(suite, container);
    ix_suite_depth++;
    if (container && [NSUserDefaults instancesRespondToSelector:@selector(_initWithSuiteName:container:)]) {
        @try { defaults = [[NSUserDefaults alloc] _initWithSuiteName:suite container:container]; }
        @catch (__unused NSException *exception) { defaults = nil; }
    }
    if (!defaults) {
        @try { defaults = [[NSUserDefaults alloc] initWithSuiteName:suite]; }
        @catch (__unused NSException *exception) { defaults = nil; }
    }
    ix_suite_depth--;
    return defaults;
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
    id current = IXReadIvar(object, "_identifier");
    NSString *currentText = [current isKindOfClass:[NSString class]] ? current : @"";
    char filled[768];
    NSString *probe = currentText.length ? nil : IXRealKeychainAccessGroup();
    if (IXSessionIdentifierFill(currentText.UTF8String, IXGroupIdentifier(name).UTF8String, probe.UTF8String, filled, sizeof filled)) {
        NSString *identifier = IXText(filled, nil);
        if (identifier.length) {
            IXWriteIvar(object, "_identifier", identifier);
            current = identifier;
        }
    }
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) {
        NSUserDefaults *defaults = IXGroupDefaults(IXDefaultsSuite());
        if (defaults) IXWriteIvar(object, "_userDefaults", defaults);
    }
    NSString *groupName = IXGroupIdentifier(name);
    int forceDocuments = IXSessionUseDocumentsContainer(groupName.UTF8String);
    id existing = IXReadIvar(object, "_containerURL");
    if (!forceDocuments && [existing isKindOfClass:[NSURL class]] && [(NSURL *)existing path].length) return;
    NSURL *url = IXContainerURL(groupName);
    if (url) IXWriteIvar(object, "_containerURL", url);
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
    if (!ix_origAppGroup) return;
    union { id (*fn)(id, id); void *ptr; } bits = { ix_directAppGroup };
    const char *names[1] = { "+<METAAppGroup appGroupForGroupName:>" };
    void *replacements[1] = { bits.ptr };
    IXSymbolRebindPermanent(names, replacements, 1);
}

static void IXCopyMissing(NSFileManager *fm, NSString *src, NSString *dst) {
    BOOL srcDir = NO;
    if (src.length == 0 || dst.length == 0 || [src isEqualToString:dst]) return;
    if (![fm fileExistsAtPath:src isDirectory:&srcDir] || !srcDir) return;
    [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in [fm contentsOfDirectoryAtPath:src error:nil]) {
        if (![name isKindOfClass:[NSString class]] || [name hasPrefix:@"."]) continue;
        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to = [dst stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:from isDirectory:&isDir]) continue;
        if (isDir) IXCopyMissing(fm, from, to);
        else if (![fm fileExistsAtPath:to]) [fm copyItemAtPath:from toPath:to error:nil];
    }
}

static void IXMigrateInto(NSString *destPath) {
    static NSMutableSet *done;
    static dispatch_once_t once;
    NSFileManager *fm;
    NSMutableArray *sources;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    if (destPath.length == 0) return;
    @synchronized (done) {
        if ([done containsObject:destPath]) return;
        [done addObject:destPath];
    }
    fm = [NSFileManager defaultManager];
    sources = [NSMutableArray array];
    [sources addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup"]];
    NSString *legacyRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:legacyRoot error:nil]) {
        if ([kid isKindOfClass:[NSString class]]) [sources addObject:[legacyRoot stringByAppendingPathComponent:kid]];
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length) {
        [sources addObject:[docs stringByAppendingPathComponent:@"InstagramX/AppGroup"]];
        for (NSString *name in [fm contentsOfDirectoryAtPath:docs error:nil]) {
            if (![name isKindOfClass:[NSString class]]) continue;
            if ([name hasPrefix:@"group.com.burbn.instagram"] || [name hasPrefix:@"group.com.facebook.family"] || [name hasPrefix:@"group.com.burbn.family"]) {
                [sources addObject:[docs stringByAppendingPathComponent:name]];
            }
        }
    }
    for (NSString *src in sources) IXCopyMissing(fm, src, destPath);
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
    NSString *real = IXRealKeychainAccessGroup();
    if (real.length) return real;
    return @"group.com.burbn.instagram";
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    NSURL *url = nil;
    NSURL *systemURL = nil;
    NSString *source = @"system";
    const char *raw = [identifier isKindOfClass:[NSString class]] ? identifier.UTF8String : NULL;
    int forceDocuments = IXSessionUseDocumentsContainer(raw);
    if (depth) {
        @try { return %orig; }
        @catch (__unused NSException *exception) { return nil; }
    }
    depth++;
    @try { systemURL = %orig; }
    @catch (__unused NSException *exception) { systemURL = nil; }
    if (forceDocuments || ![systemURL isKindOfClass:[NSURL class]] || systemURL.path.length == 0) {
        @try { url = IXContainerURL(identifier); }
        @catch (__unused NSException *exception) { url = nil; }
        if ([url isKindOfClass:[NSURL class]] && url.path.length &&
            [systemURL isKindOfClass:[NSURL class]] && systemURL.path.length &&
            ![systemURL.path isEqualToString:url.path]) {
            @try { IXCopyMissing([NSFileManager defaultManager], systemURL.path, url.path); }
            @catch (__unused NSException *exception) {}
        }
        source = [url isKindOfClass:[NSURL class]] ? @"sandbox" : @"system";
        if (![url isKindOfClass:[NSURL class]]) url = systemURL;
    } else {
        url = systemURL;
    }
    depth--;
    if ([url isKindOfClass:[NSURL class]] && url.path.length) {
        @try { IXMigrateInto(url.path); }
        @catch (__unused NSException *exception) {}
        IXSessionDiagNoteContainer(url.path, source);
    }
    return [url isKindOfClass:[NSURL class]] ? url : nil;
}
%end

static void IXAdoptSuitePlist(NSString *suite, NSURL *container) {
    NSFileManager *fm;
    NSString *home;
    NSString *destDir;
    NSString *dest;
    if (suite.length == 0 || container.path.length == 0) return;
    if (!IXSessionPersistSuite(suite.UTF8String)) return;
    fm = [NSFileManager defaultManager];
    home = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", suite]];
    destDir = [container.path stringByAppendingPathComponent:@"Library/Preferences"];
    dest = [destDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", suite]];
    if (![fm fileExistsAtPath:home] || [fm fileExistsAtPath:dest]) return;
    [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm copyItemAtPath:home toPath:dest error:nil];
}

static const void *ix_suite_key = &ix_suite_key;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *ix_suite_cache;
static int ix_suite_logs;
static __thread int ix_mirror_depth;

static void IXSuiteCacheInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ix_suite_cache = [NSMutableDictionary dictionary]; });
}

static NSString *IXSuiteFile(NSString *suite) {
    char path[1024];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (![suite isKindOfClass:[NSString class]] || !docs.UTF8String) return nil;
    if (!IXSessionSuitePlist(docs.UTF8String, suite.UTF8String, path, sizeof path)) return nil;
    return [NSString stringWithUTF8String:path];
}

static unsigned long long IXFileSizeAt(NSString *path) {
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSNumber *size = [attr isKindOfClass:[NSDictionary class]] ? attr[NSFileSize] : nil;
    return [size isKindOfClass:[NSNumber class]] ? size.unsignedLongLongValue : 0;
}

static BOOL IXPlistValue(id value) {
    if (!value) return NO;
    return [value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
           [value isKindOfClass:[NSData class]] || [value isKindOfClass:[NSDate class]] ||
           [value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]];
}

static void IXLogSuiteBytes(NSString *suite, unsigned long long bytes, NSUInteger keys) {
    if (ix_suite_logs >= 32 || suite.length == 0) return;
    ix_suite_logs++;
    IXSessionDiagLine([NSString stringWithFormat:@"suite_sync name=%@ bytes=%llu keys=%lu",
                       suite.length > 96 ? [suite substringToIndex:96] : suite,
                       bytes, (unsigned long)keys]);
}

static unsigned long long IXWriteSuite(NSString *suite, NSDictionary *values) {
    NSString *path;
    NSString *dir;
    unsigned long long bytes;
    if (![values isKindOfClass:[NSDictionary class]] || values.count == 0) return 0;
    path = IXSuiteFile(suite);
    if (path.length == 0) return 0;
    dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (![values writeToFile:path atomically:YES]) return IXFileSizeAt(path);
    bytes = IXFileSizeAt(path);
    IXLogSuiteBytes(suite, bytes, values.count);
    return bytes;
}

static NSMutableDictionary *IXSuiteShadow(NSString *suite) {
    NSMutableDictionary *one;
    NSDictionary *disk;
    IXSuiteCacheInit();
    if (![suite isKindOfClass:[NSString class]] || !IXSessionPersistSuite(suite.UTF8String)) return nil;
    @synchronized (ix_suite_cache) {
        one = ix_suite_cache[suite];
        if (!one) {
            one = [NSMutableDictionary dictionary];
            disk = [NSDictionary dictionaryWithContentsOfFile:IXSuiteFile(suite)];
            if ([disk isKindOfClass:[NSDictionary class]]) [one addEntriesFromDictionary:disk];
            ix_suite_cache[suite] = one;
        }
    }
    return one;
}

static int ix_has_password(NSString *key) {
    return [key isKindOfClass:[NSString class]] && [key.lowercaseString containsString:@"password"];
}

static void IXMirrorUser(NSString *key, id value) {
    if (ix_mirror_depth || ![key isKindOfClass:[NSString class]] || !value) return;
    if (!IXSessionUserKey(key.UTF8String)) return;
    ix_mirror_depth++;
    @try { [[NSUserDefaults standardUserDefaults] setObject:value forKey:key]; }
    @catch (__unused NSException *exception) {}
    ix_mirror_depth--;
}

static void IXStoreSuiteValue(NSString *suite, NSString *key, id value) {
    NSMutableDictionary *one;
    NSDictionary *snap;
    if (![key isKindOfClass:[NSString class]] || ix_has_password(key)) return;
    one = IXSuiteShadow(suite);
    if (!one) return;
    @synchronized (ix_suite_cache) {
        if (value && IXPlistValue(value)) one[key] = value;
        else if (!value) [one removeObjectForKey:key];
        else return;
        snap = [one copy];
    }
    IXWriteSuite(suite, snap);
    if (value) IXMirrorUser(key, value);
}

static void IXLogSuite(NSString *suite, NSURL *container) {
    static int logs = 0;
    NSString *plist;
    NSString *tail;
    NSDictionary *attr;
    NSNumber *size;
    if (logs >= 16 || suite.length == 0 || container.path.length == 0) return;
    logs++;
    plist = [container.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", suite]];
    attr = [[NSFileManager defaultManager] attributesOfItemAtPath:plist error:nil];
    size = [attr isKindOfClass:[NSDictionary class]] ? attr[NSFileSize] : nil;
    tail = container.path;
    if (tail.length > 80) tail = [tail substringFromIndex:tail.length - 80];
    IXSessionDiagLine([NSString stringWithFormat:@"suite_open name=%@ plist_bytes=%llu path=%@",
                       suite.length > 80 ? [suite substringToIndex:80] : suite,
                       [size isKindOfClass:[NSNumber class]] ? size.unsignedLongLongValue : 0,
                       tail]);
}

static NSString *IXSuiteOf(id defaults) {
    NSString *suite = objc_getAssociatedObject(defaults, ix_suite_key);
    const char *names[] = {"_suiteName", "_identifier", "_containerIdentifier", NULL};
    int i;
    if ([suite isKindOfClass:[NSString class]] && suite.length) return suite;
    for (i = 0; names[i]; i++) {
        Ivar ivar = class_getInstanceVariable(object_getClass(defaults), names[i]);
        id value;
        const char *type;
        if (!ivar) continue;
        type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;
        value = object_getIvar(defaults, ivar);
        if (![value isKindOfClass:[NSString class]] || !IXSessionPersistSuite([(NSString *)value UTF8String])) continue;
        objc_setAssociatedObject(defaults, ix_suite_key, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return value;
    }
    return nil;
}

static void IXPreloadSuite(NSUserDefaults *defaults, NSString *suite) {
    NSMutableDictionary *one = IXSuiteShadow(suite);
    NSDictionary *snap;
    if (!defaults || !one) return;
    @synchronized (ix_suite_cache) { snap = [one copy]; }
    ix_suite_depth++;
    for (NSString *key in snap) {
        id value = snap[key];
        @try {
            if ([defaults objectForKey:key] == nil && value) [defaults setObject:value forKey:key];
        } @catch (__unused NSException *exception) {}
        IXMirrorUser(key, value);
    }
    ix_suite_depth--;
}

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
    NSURL *stable = nil;
    id result = nil;
    if (ix_suite_depth || ![suiteName isKindOfClass:[NSString class]] || !IXSessionPersistSuite(suiteName.UTF8String)) return %orig;
    @try { stable = IXContainerURL(suiteName); }
    @catch (__unused NSException *exception) { stable = nil; }
    if (stable.path.length == 0) return %orig;
    IXAdoptSuitePlist(suiteName, stable);
    if ([container isKindOfClass:[NSURL class]] && [container.path isEqualToString:stable.path]) return %orig;
    ix_suite_depth++;
    @try { result = %orig(suiteName, stable); }
    @catch (__unused NSException *exception) { result = nil; }
    ix_suite_depth--;
    if (!result) return %orig;
    objc_setAssociatedObject(result, ix_suite_key, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    IXPreloadSuite(result, suiteName);
    IXLogSuite(suiteName, stable);
    return result;
}
- (id)initWithSuiteName:(NSString *)suiteName {
    NSURL *stable = nil;
    id result = nil;
    if (ix_suite_depth || ![suiteName isKindOfClass:[NSString class]] || !IXSessionPersistSuite(suiteName.UTF8String)) return %orig;
    if (![self respondsToSelector:@selector(_initWithSuiteName:container:)]) return %orig;
    @try { stable = IXContainerURL(suiteName); }
    @catch (__unused NSException *exception) { stable = nil; }
    if (stable.path.length == 0) return %orig;
    IXAdoptSuitePlist(suiteName, stable);
    ix_suite_depth++;
    @try { result = [self _initWithSuiteName:suiteName container:stable]; }
    @catch (__unused NSException *exception) { result = nil; }
    ix_suite_depth--;
    if (!result) return %orig;
    objc_setAssociatedObject(result, ix_suite_key, suiteName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    IXPreloadSuite(result, suiteName);
    IXLogSuite(suiteName, stable);
    return result;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    NSString *suite = IXSuiteOf(self);
    %orig;
    if (ix_suite_depth || ix_mirror_depth) return;
    IXStoreSuiteValue(suite, key, value);
}
- (BOOL)synchronize {
    BOOL ok = %orig;
    NSString *suite = IXSuiteOf(self);
    NSDictionary *domain = nil;
    if (ix_suite_depth || ![suite isKindOfClass:[NSString class]]) return ok;
    @try { domain = [self persistentDomainForName:suite]; }
    @catch (__unused NSException *exception) { domain = nil; }
    if ([domain isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in domain) {
            if (ix_has_password(key)) continue;
            IXStoreSuiteValue(suite, key, domain[key]);
        }
    }
    return ok;
}
%end

typedef void (*IXCFSetAppFn)(CFStringRef, CFTypeRef, CFStringRef);
typedef void (*IXCFSetValueFn)(CFStringRef, CFTypeRef, CFStringRef, CFStringRef, CFStringRef);
typedef void (*IXCFSyncFn)(CFStringRef);
static IXCFSetAppFn ix_real_cf_set_app;
static IXCFSetValueFn ix_real_cf_set_value;
static IXCFSyncFn ix_real_cf_sync;

static void ix_cf_set_app(CFStringRef key, CFTypeRef value, CFStringRef app) {
    if (ix_real_cf_set_app) ix_real_cf_set_app(key, value, app);
    IXStoreSuiteValue((__bridge NSString *)app, (__bridge NSString *)key, value ? (__bridge id)value : nil);
}

static void ix_cf_set_value(CFStringRef key, CFTypeRef value, CFStringRef app, CFStringRef user, CFStringRef host) {
    if (ix_real_cf_set_value) ix_real_cf_set_value(key, value, app, user, host);
    (void)user;
    (void)host;
    IXStoreSuiteValue((__bridge NSString *)app, (__bridge NSString *)key, value ? (__bridge id)value : nil);
}

static void ix_cf_sync(CFStringRef app) {
    NSString *suite = (__bridge NSString *)app;
    NSDictionary *snap = nil;
    if (ix_real_cf_sync) ix_real_cf_sync(app);
    if (![suite isKindOfClass:[NSString class]] || !IXSessionPersistSuite(suite.UTF8String)) return;
    IXSuiteShadow(suite);
    @synchronized (ix_suite_cache) { snap = [ix_suite_cache[suite] copy]; }
    IXWriteSuite(suite, snap);
}

static void IXInstallSuiteWrites(void) {
    const char *names[3] = {"CFPreferencesSetAppValue", "CFPreferencesSetValue", "CFPreferencesAppSynchronize"};
    void *repl[3];
    ix_real_cf_set_app = (IXCFSetAppFn)dlsym(RTLD_DEFAULT, "CFPreferencesSetAppValue");
    ix_real_cf_set_value = (IXCFSetValueFn)dlsym(RTLD_DEFAULT, "CFPreferencesSetValue");
    ix_real_cf_sync = (IXCFSyncFn)dlsym(RTLD_DEFAULT, "CFPreferencesAppSynchronize");
    repl[0] = (void *)ix_cf_set_app;
    repl[1] = (void *)ix_cf_set_value;
    repl[2] = (void *)ix_cf_sync;
    IXSymbolRebindPermanent((const char *const *)names, repl, 3);
}

void IXSessionSyncGroupSuites(void) {
    NSMutableArray *names = [@[@"group.com.burbn.instagram", @"group.com.facebook.family", @"group.com.burbn.family"] mutableCopy];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    @try { [[NSUserDefaults standardUserDefaults] synchronize]; }
    @catch (__unused NSException *exception) {}
    IXSuiteCacheInit();
    @synchronized (ix_suite_cache) {
        for (NSString *name in ix_suite_cache) {
            if ([name isKindOfClass:[NSString class]] && ![names containsObject:name]) [names addObject:name];
        }
    }
    for (NSString *dir in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil]) {
        if ([dir isKindOfClass:[NSString class]] && [dir hasPrefix:@"group."] && ![names containsObject:dir]) [names addObject:dir];
    }
    for (NSString *name in names) {
        NSURL *url = IXContainerURL(name);
        NSUserDefaults *defaults = nil;
        if (!url || ix_suite_depth) continue;
        IXAdoptSuitePlist(name, url);
        ix_suite_depth++;
        @try { defaults = [[NSUserDefaults alloc] _initWithSuiteName:name container:url]; }
        @catch (__unused NSException *exception) { defaults = nil; }
        ix_suite_depth--;
        @try { [defaults synchronize]; }
        @catch (__unused NSException *exception) {}
    }
}

static void IXNoteLoadedImages(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) IXSessionLaunchNoteImage(_dyld_get_image_name(i));
}

static void IXEnableSuiteHooks(void) {
    static int once = 0;
    if (once || !IXSessionLaunchMayWalkClasses()) return;
    once = 1;
    %init;
    IXInstallDirectAppGroup();
    IXInstallSuiteWrites();
    IXSessionDiagLine(@"suite_hook ctor=1");
}

static int IXHeaderIsFramework(const struct mach_header *header);

static void IXSuiteImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!IXHeaderIsFramework(header)) return;
    IXSessionLaunchNoteImage("FBSharedFramework");
    IXEnableSuiteHooks();
}

static int IXHeaderIsFramework(const struct mach_header *header) {
    const struct mach_header_64 *image;
    const uint8_t *cursor;
    uint32_t i;
    if (!header || header->magic != MH_MAGIC_64) return 0;
    image = (const struct mach_header_64 *)header;
    cursor = (const uint8_t *)(image + 1);
    for (i = 0; i < image->ncmds && i < 256; i++) {
        const struct load_command *cmd = (const struct load_command *)cursor;
        if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > 8192) return 0;
        if (cmd->cmd == LC_ID_DYLIB && cmd->cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dylib = (const struct dylib_command *)cmd;
            if (dylib->dylib.name.offset >= sizeof(*dylib) && dylib->dylib.name.offset < cmd->cmdsize) {
                const char *name = (const char *)cmd + dylib->dylib.name.offset;
                if (IXSessionFrameworkName(name)) return 1;
            }
        }
        cursor += cmd->cmdsize;
    }
    return 0;
}

static void IXSuiteFrameworkAdded(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (!IXHeaderIsFramework(header)) return;
    IXSessionLaunchNoteImage("FBSharedFramework");
    IXEnableSuiteHooks();
}

__attribute__((constructor(101)))
static void IXSuiteEarlyCtor(void) {
    _dyld_register_func_for_add_image(&IXSuiteFrameworkAdded);
    if (IXSessionLaunchMayWalkClasses()) IXEnableSuiteHooks();
}

%ctor {
    IXSessionSourceProbeFiles("ctor");
    IXNoteLoadedImages();
    if (IXSessionLaunchMayWalkClasses()) {
        IXEnableSuiteHooks();
        return;
    }
    _dyld_register_func_for_add_image(&IXSuiteImageAdded);
}
