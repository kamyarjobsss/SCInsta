#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"

@interface NSUserDefaults (IXContainerSuite)
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

static __thread int ix_suite_depth;

// v2.2.4 kept the login. Commit e0b8495 (2.3.0, multi-account) changed three
// things that the next launch depends on:
//   the missing container became a directory named after the group id, instead
//   of one directory for every id;
//   a nil METAAppGroup identifier was filled with the requested name instead
//   of the access group SecItem actually assigned;
//   SecItem queries were rewritten, which bypasses the sideload helper.
// keychainAccessAppGroup returns the identifier ivar. Replacing an identifier
// Instagram already set makes the next launch miss the session. The SecItem
// rewrite was removed in 2.4.2. The directory and the identifier fill stayed,
// and 2.4.2 still logged out.
//
// This is the v2.2.4 behavior again. A nil container and nil user defaults are
// still filled, including when the identifier is already set, so the account
// list has a directory. The directory is the same one for every group. The
// suite name is group.com.burbn.instagram. A non-empty identifier is not
// rewritten. SecItem is not hooked.

static NSString *IXText(const char *value, NSString *fallback) {
    NSString *text = value ? [NSString stringWithUTF8String:value] : nil;
    return text.length ? text : fallback;
}

static NSURL *IXSandboxGroupURL(void) {
    char leaf[64];
    NSString *name = @"IXAppGroup";
    if (IXSessionFallbackLeaf("", leaf, sizeof leaf)) {
        NSString *text = [NSString stringWithUTF8String:leaf];
        if (text.length) name = text;
    }
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/Application Support" stringByAppendingPathComponent:name]];
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

// A group.com.* suite without a container is not written on a sideload:
// cfprefsd rejects it, the next launch looks like a fresh install, and
// Instagram deletes the session. The container makes the plist a file
// inside IXAppGroup, which is the same idea as the base sideload helper.
static NSUserDefaults *IXGroupDefaults(NSString *suite) {
    NSURL *container;
    NSUserDefaults *defaults = nil;
    if (suite.length == 0 || ix_suite_depth) return nil;
    container = IXSandboxGroupURL();
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
    id existing = IXReadIvar(object, "_containerURL");
    if ([existing isKindOfClass:[NSURL class]] && [(NSURL *)existing path].length) return;
    NSURL *url = IXSandboxGroupURL();
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
            if ([name hasPrefix:@"group.com.burbn.instagram"] || [name hasPrefix:@"group.com.facebook.family"]) {
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

static NSString *IXBundleID(void) {
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) return @"com.burbn.instagram";
    return bundle;
}

static NSString *IXSeenPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [[docs stringByAppendingPathComponent:@"InstagramX"] stringByAppendingPathComponent:@"ix_seen_launch.txt"];
}

static NSString *IXMarkerPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *dir = [docs stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"freshinstall.plist"];
}

static NSMutableDictionary *IXMarkerDict(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:IXMarkerPath()];
        dict = [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    });
    return dict;
}

static BOOL IXPlistValue(id value) {
    return [value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ||
           [value isKindOfClass:[NSDate class]] || [value isKindOfClass:[NSData class]];
}

static void IXMarkerSave(void) {
    NSDictionary *snapshot = nil;
    @synchronized (IXMarkerDict()) { snapshot = [IXMarkerDict() copy]; }
    if (snapshot) [snapshot writeToFile:IXMarkerPath() atomically:YES];
}

static id IXMarkerGet(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return nil;
    @synchronized (IXMarkerDict()) { return IXMarkerDict()[key]; }
}

static void IXMarkerPut(NSString *key, id value) {
    if (![key isKindOfClass:[NSString class]] || !IXPlistValue(value)) return;
    @synchronized (IXMarkerDict()) {
        id existing = IXMarkerDict()[key];
        if (existing && [existing isEqual:value]) return;
        IXMarkerDict()[key] = value;
    }
    IXMarkerSave();
}

static BOOL IXFreshKey(NSString *key) {
    const char *utf = [key isKindOfClass:[NSString class]] ? key.UTF8String : NULL;
    return utf && IXFreshInstallKey(utf);
}

static BOOL IXGroupSuiteName(NSString *suite) {
    if (![suite isKindOfClass:[NSString class]] || suite.length == 0) return NO;
    return [suite hasPrefix:@"group.com.burbn.instagram"] || [suite hasPrefix:@"group.com.facebook.family"];
}

static id IXPlaceholder(NSString *key) {
    const char *utf = [key isKindOfClass:[NSString class]] ? key.UTF8String : NULL;
    if (!utf || !IXFreshKnownKey(utf)) return nil;
    if (strcmp(utf, "mc_freshinstall_time") == 0) return @1609459200;
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![ver isKindOfClass:[NSString class]] || ver.length == 0 || ver.length > 24) return @"436";
    return ver;
}

static const void *IXSuiteAssociation = &IXSuiteAssociation;

static void IXRememberSuite(NSUserDefaults *defaults, NSString *suite) {
    if (!defaults || ![suite isKindOfClass:[NSString class]] || suite.length == 0) return;
    objc_setAssociatedObject(defaults, IXSuiteAssociation, suite, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static NSString *IXActualSuite(NSUserDefaults *defaults) {
    NSString *suite = objc_getAssociatedObject(defaults, IXSuiteAssociation);
    if ([suite isKindOfClass:[NSString class]] && suite.length) return suite;
    return IXBundleID();
}

static id IXPersisted(NSUserDefaults *defaults, NSString *suite, NSString *key) {
    NSDictionary *domain = nil;
    if (!defaults || suite.length == 0 || key.length == 0) return nil;
    @try { domain = [defaults persistentDomainForName:suite]; }
    @catch (__unused NSException *exception) { domain = nil; }
    if (![domain isKindOfClass:[NSDictionary class]]) return nil;
    return domain[key];
}

static int IXDictHasFresh(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return 0;
    for (id key in dict) {
        if (IXFreshKey(key)) return 1;
    }
    return 0;
}

static void IXMergePlist(NSString *path, NSDictionary *markers) {
    NSMutableDictionary *plist;
    BOOL dirty = NO;
    if (path.length == 0 || markers.count == 0) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    plist = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (![plist isKindOfClass:[NSMutableDictionary class]]) plist = [NSMutableDictionary dictionary];
    for (NSString *key in markers) {
        if (!IXFreshKey(key) || !IXPlistValue(markers[key]) || plist[key]) continue;
        plist[key] = markers[key];
        dirty = YES;
    }
    if (dirty) [plist writeToFile:path atomically:YES];
}

static void IXPlantMarkerFiles(NSDictionary *markers) {
    NSURL *container;
    NSString *home;
    if (markers.count == 0) return;
    home = NSHomeDirectory() ?: @"";
    IXMergePlist([home stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", IXBundleID()]], markers);
    if (![IXBundleID() isEqualToString:@"com.burbn.instagram"]) {
        IXMergePlist([home stringByAppendingPathComponent:@"Library/Preferences/com.burbn.instagram.plist"], markers);
    }
    container = IXSandboxGroupURL();
    if (container.path.length) {
        IXMergePlist([container.path stringByAppendingPathComponent:@"Library/Preferences/group.com.burbn.instagram.plist"], markers);
        IXSessionDiagNoteContainer(container.path, @"fallback");
    }
}

static CFPropertyListRef (*ix_cf_copy_app)(CFStringRef, CFStringRef);
static CFPropertyListRef (*ix_cf_copy_value)(CFStringRef, CFStringRef, CFStringRef, CFStringRef);
static void (*ix_cf_set_app)(CFStringRef, CFPropertyListRef, CFStringRef);
static void (*ix_cf_set_value)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef);
static CFIndex (*ix_cf_get_int)(CFStringRef, CFStringRef, Boolean *);
static int ix_cf_ready;

static NSString *IXCFKey(CFTypeRef key) {
    if (!key || CFGetTypeID(key) != CFStringGetTypeID()) return nil;
    return (__bridge NSString *)key;
}

static CFPropertyListRef IXHeldMarker(NSString *key, CFPropertyListRef found) {
    id saved;
    if (found || !IXFreshKey(key)) return found;
    saved = IXMarkerGet(key);
    if (!IXPlistValue(saved)) return found;
    return CFBridgingRetain(saved);
}

static CFPropertyListRef IXCopyApp(CFStringRef key, CFStringRef applicationID) {
    CFPropertyListRef found = ix_cf_copy_app ? ix_cf_copy_app(key, applicationID) : NULL;
    return IXHeldMarker(IXCFKey(key), found);
}

static CFPropertyListRef IXCopyValue(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    CFPropertyListRef found = ix_cf_copy_value ? ix_cf_copy_value(key, applicationID, userName, hostName) : NULL;
    return IXHeldMarker(IXCFKey(key), found);
}

static void IXNoteCFWrite(CFTypeRef key, CFTypeRef value) {
    NSString *name = IXCFKey(key);
    id obj;
    if (!IXFreshKey(name) || !value) return;
    obj = (__bridge id)value;
    if (IXPlistValue(obj)) IXMarkerPut(name, obj);
}

static void IXSetApp(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    if (ix_cf_set_app) ix_cf_set_app(key, value, applicationID);
    IXNoteCFWrite(key, value);
}

static void IXSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (ix_cf_set_value) ix_cf_set_value(key, value, applicationID, userName, hostName);
    IXNoteCFWrite(key, value);
}

static CFIndex IXGetInt(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) {
    Boolean valid = false;
    CFIndex value = ix_cf_get_int ? ix_cf_get_int(key, applicationID, &valid) : 0;
    NSString *name = IXCFKey(key);
    id saved;
    if (!valid && IXFreshKey(name)) {
        saved = IXMarkerGet(name);
        if ([saved isKindOfClass:[NSNumber class]]) {
            value = (CFIndex)[(NSNumber *)saved integerValue];
            valid = true;
        }
    }
    if (keyExistsAndHasValidFormat) *keyExistsAndHasValidFormat = valid;
    return value;
}

static void IXInstallPrefsHooks(void) {
    union { CFPropertyListRef (*fn)(CFStringRef, CFStringRef); void *ptr; } copyAppBits;
    union { CFPropertyListRef (*fn)(CFStringRef, CFStringRef, CFStringRef, CFStringRef); void *ptr; } copyValueBits;
    union { void (*fn)(CFStringRef, CFPropertyListRef, CFStringRef); void *ptr; } setAppBits;
    union { void (*fn)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef); void *ptr; } setValueBits;
    union { CFIndex (*fn)(CFStringRef, CFStringRef, Boolean *); void *ptr; } intBits;
    const char *names[5];
    void *replacements[5];
    void *prev;
    if (ix_cf_ready) return;
    ix_cf_ready = 1;
    ix_cf_copy_app = (CFPropertyListRef (*)(CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesCopyAppValue");
    ix_cf_copy_value = (CFPropertyListRef (*)(CFStringRef, CFStringRef, CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesCopyValue");
    ix_cf_set_app = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesSetAppValue");
    ix_cf_set_value = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesSetValue");
    ix_cf_get_int = (CFIndex (*)(CFStringRef, CFStringRef, Boolean *))dlsym(RTLD_DEFAULT, "CFPreferencesGetAppIntegerValue");
    copyAppBits.fn = IXCopyApp;
    copyValueBits.fn = IXCopyValue;
    setAppBits.fn = IXSetApp;
    setValueBits.fn = IXSetValue;
    intBits.fn = IXGetInt;
    names[0] = "CFPreferencesCopyAppValue";
    names[1] = "CFPreferencesCopyValue";
    names[2] = "CFPreferencesSetAppValue";
    names[3] = "CFPreferencesSetValue";
    names[4] = "CFPreferencesGetAppIntegerValue";
    replacements[0] = copyAppBits.ptr;
    replacements[1] = copyValueBits.ptr;
    replacements[2] = setAppBits.ptr;
    replacements[3] = setValueBits.ptr;
    replacements[4] = intBits.ptr;
    IXSymbolRebindPermanent(names, replacements, 5);
    prev = IXSymbolPrevious("CFPreferencesCopyAppValue");
    if (prev && prev != (void *)IXCopyApp) ix_cf_copy_app = (CFPropertyListRef (*)(CFStringRef, CFStringRef))prev;
    prev = IXSymbolPrevious("CFPreferencesCopyValue");
    if (prev && prev != (void *)IXCopyValue) ix_cf_copy_value = (CFPropertyListRef (*)(CFStringRef, CFStringRef, CFStringRef, CFStringRef))prev;
    prev = IXSymbolPrevious("CFPreferencesSetAppValue");
    if (prev && prev != (void *)IXSetApp) ix_cf_set_app = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef))prev;
    prev = IXSymbolPrevious("CFPreferencesSetValue");
    if (prev && prev != (void *)IXSetValue) ix_cf_set_value = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef))prev;
    prev = IXSymbolPrevious("CFPreferencesGetAppIntegerValue");
    if (prev && prev != (void *)IXGetInt) ix_cf_get_int = (CFIndex (*)(CFStringRef, CFStringRef, Boolean *))prev;
}

static void IXApplyMarker(NSUserDefaults *defaults, NSString *suite, NSString *key, int allowPlaceholder) {
    id saved;
    id persisted;
    id placeholder;
    const char *utf;
    if (!IXFreshKey(key) || !defaults) return;
    saved = IXMarkerGet(key);
    persisted = IXPersisted(defaults, suite, key);
    utf = key.UTF8String;
    if (IXFreshMarkerRestore(persisted != nil, saved != nil)) {
        [defaults setObject:saved forKey:key];
        return;
    }
    if (persisted && !saved) {
        IXMarkerPut(key, persisted);
        return;
    }
    if (!allowPlaceholder || !utf || !IXFreshMarkerSeed(persisted != nil, saved != nil, IXFreshKnownKey(utf))) return;
    placeholder = IXPlaceholder(key);
    if (!placeholder) return;
    [defaults setObject:placeholder forKey:key];
    IXMarkerPut(key, placeholder);
}

void IXPrefsSeedFreshMarkers(void) {
    @try {
        NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
        NSString *bundle = IXBundleID();
        NSUserDefaults *suite = IXGroupDefaults(@"group.com.burbn.instagram");
        NSString *home = NSHomeDirectory() ?: @"";
        NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSetWithArray:@[
            @"mc_freshinstall_time", @"mobileconfig_freshinstall_track_version"
        ]];
        int seen = [[NSFileManager defaultManager] fileExistsAtPath:IXSeenPath()] ? 1 : 0;
        int cookies = [[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"]] ? 1 : 0;
        int file = 0;
        int allow;
        IXInstallPrefsHooks();
        IXRememberSuite(suite, @"group.com.burbn.instagram");
        @synchronized (IXMarkerDict()) {
            for (id key in IXMarkerDict()) {
                if ([key isKindOfClass:[NSString class]]) [keys addObject:key];
            }
            file = IXDictHasFresh(IXMarkerDict());
        }
        allow = IXSessionSeedFresh(seen, cookies, file);
        for (NSString *key in keys.array) {
            IXApplyMarker(standard, bundle, key, allow);
            IXApplyMarker(suite, @"group.com.burbn.instagram", key, allow);
        }
        [standard synchronize];
        [suite synchronize];
        IXMarkerSave();
        @synchronized (IXMarkerDict()) { IXPlantMarkerFiles([IXMarkerDict() copy]); }
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=seed seen=%d cookies=%d file=%d allow=%d std=%d suite=%d",
                           seen, cookies, file, allow,
                           IXPersisted(standard, bundle, @"mc_freshinstall_time") ? 1 : 0,
                           IXPersisted(suite, @"group.com.burbn.instagram", @"mc_freshinstall_time") ? 1 : 0]);
    } @catch (__unused NSException *exception) {
        IXSessionDiagLine(@"prefs op=seed status=error");
    }
}

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    NSURL *url = nil;
    (void)identifier;
    if (depth) {
        @try { return %orig; }
        @catch (__unused NSException *exception) { return nil; }
    }
    depth++;
    @try { url = %orig; }
    @catch (__unused NSException *exception) { url = nil; }
    NSString *source = @"system";
    if (![url isKindOfClass:[NSURL class]] || url.path.length == 0) {
        url = IXSandboxGroupURL();
        source = @"fallback";
    }
    depth--;
    if (url.path.length) {
        IXMigrateInto(url.path);
        IXSessionDiagNoteContainer(url.path, source);
    }
    return url;
}
%end

%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)suiteName {
    NSUserDefaults *made = nil;
    if (!ix_suite_depth && IXGroupSuiteName(suiteName)) {
        NSURL *container = IXSandboxGroupURL();
        if (container && [self respondsToSelector:@selector(_initWithSuiteName:container:)]) {
            ix_suite_depth++;
            @try { made = [self _initWithSuiteName:suiteName container:container]; }
            @catch (__unused NSException *exception) { made = nil; }
            ix_suite_depth--;
        }
    }
    if (!made) {
        @try { made = %orig; }
        @catch (__unused NSException *exception) { made = nil; }
    }
    IXRememberSuite(made, suiteName);
    return made;
}
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
    NSUserDefaults *made = nil;
    NSURL *used = container;
    if (IXGroupSuiteName(suiteName) && (![used isKindOfClass:[NSURL class]] || used.path.length == 0)) {
        used = IXSandboxGroupURL();
    }
    @try { made = %orig(suiteName, used); }
    @catch (__unused NSException *exception) { made = nil; }
    IXRememberSuite(made, suiteName);
    return made;
}
- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;
    if (IXFreshKey(defaultName) && IXPlistValue(value)) IXMarkerPut(defaultName, value);
}
- (id)objectForKey:(NSString *)defaultName {
    static __thread int depth = 0;
    id persisted;
    id saved;
    if (depth || !IXFreshKey(defaultName)) return %orig;
    depth++;
    persisted = IXPersisted(self, IXActualSuite(self), defaultName);
    if (persisted) {
        if (!IXMarkerGet(defaultName)) IXMarkerPut(defaultName, persisted);
        depth--;
        return persisted;
    }
    saved = IXMarkerGet(defaultName);
    if (IXPlistValue(saved)) {
        [self setObject:saved forKey:defaultName];
        depth--;
        return saved;
    }
    depth--;
    return %orig;
}
%end

%ctor {
    %init;
    IXInstallDirectAppGroup();
    IXPrefsSeedFreshMarkers();
}
