#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <string.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"

// v2.4.2 device log, hooks off:
//   ix_seen_launch=existing, path_changed=no, probe_read status 0
//   fresh_flags prefs=0 group_prefs=0 names=mc_freshinstall_time,mobileconfig_freshinstall_track_version
//   accounts phase=launch count=0 auth=0 cookie=0 while the cookie file still existed
// v2.4.1, same launch window, hook installed in the constructor (after every +load):
//   kc op=delete status=0 caller=1
// caller=1 means the query already contained kSecAttrAccessGroup. The hook
// called the real SecItemDelete, so that flag is Instagram's query, not zx.
// The diagnostics item instagramx.diag / relaunch-probe was not removed.
// Several errSecItemNotFound (-25300) results were followed by a delete that
// returned success. Instagram's own keychain wrapper deletes the session
// during didFinishLaunching because those two markers are not in a preference
// plist. dictionaryRepresentation shows the names through registered defaults.
//
// The markers are stored under Documents/InstagramX, which the same log showed
// still exists, and replayed on NSUserDefaults and CFPreferences before
// didFinishLaunching. A previous install whose markers were missing cannot
// delete a generic or internet password item until that method returns,
// except for our own items. Once the markers are on disk, launch deletes
// stay allowed. After launch returns, logout still deletes. Suite names
// and access groups are not rewritten. SecItemCopyMatching is not hooked.
// A URL the system or zx already returned is not replaced.

static int ix_existing_install = -1;
static int ix_launch_finished = 0;
static int ix_marker_persisted = 0;
static int ix_before_logged = 0;
static int ix_blocked = 0;
static int ix_guards = 0;
static __thread int ix_filling = 0;

static NSString *IXGroupLeaf(id name) {
    if ([name isKindOfClass:[NSString class]] && [(NSString *)name length]) {
        char leaf[512];
        if (IXSessionContainerComponent([(NSString *)name UTF8String], leaf, sizeof leaf)) {
            NSString *text = [NSString stringWithUTF8String:leaf];
            if (text.length) return text;
        }
    }
    return @"group.com.burbn.instagram";
}

static NSURL *IXFallbackContainer(NSString *identifier, BOOL *existed) {
    if (existed) *existed = NO;
    NSString *leaf = IXGroupLeaf(identifier);
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) return nil;
    NSString *path = [docs stringByAppendingPathComponent:leaf];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    BOOL already = [fm fileExistsAtPath:path isDirectory:&isDir];
    if (existed) *existed = already && isDir;
    if (!already) {
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
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

static void IXMigrateIntoFallback(NSString *destPath) {
    if (destPath.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *sources = [NSMutableArray array];
    [sources addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup"]];
    NSString *legacyRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:legacyRoot error:nil]) {
        if ([kid isKindOfClass:[NSString class]]) [sources addObject:[legacyRoot stringByAppendingPathComponent:kid]];
    }
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length) [sources addObject:[docs stringByAppendingPathComponent:@"InstagramX/AppGroup"]];
    for (NSString *src in sources) IXCopyMissing(fm, src, destPath);
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
    NSString *requested = IXGroupLeaf(name);
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
    id existing = IXReadIvar(object, "_containerURL");
    if ([existing isKindOfClass:[NSURL class]] && [(NSURL *)existing path].length) return;
    NSURL *url = nil;
    @try {
        url = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:current];
    } @catch (__unused NSException *exception) {
        url = nil;
    }
    if ([url isKindOfClass:[NSURL class]] && url.path.length) IXWriteIvar(object, "_containerURL", url);
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

static NSString *IXSeenPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return [[docs stringByAppendingPathComponent:@"InstagramX"] stringByAppendingPathComponent:@"ix_seen_launch.txt"];
}

static void IXNoteInstall(void) {
    if (ix_existing_install >= 0) return;
    ix_existing_install = [[NSFileManager defaultManager] fileExistsAtPath:IXSeenPath()] ? 1 : 0;
}

static NSString *IXBundleID(void) {
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) return @"com.burbn.instagram";
    return bundle;
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
    @synchronized (IXMarkerDict()) {
        snapshot = [IXMarkerDict() copy];
    }
    if (snapshot) [snapshot writeToFile:IXMarkerPath() atomically:YES];
}

static id IXMarkerGet(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return nil;
    @synchronized (IXMarkerDict()) {
        return IXMarkerDict()[key];
    }
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
    const char *utf;
    if (![key isKindOfClass:[NSString class]]) return NO;
    utf = key.UTF8String;
    return utf && IXFreshInstallKey(utf);
}

static NSString *IXFreshText(id value) {
    if (!value || value == [NSNull null]) return @"missing";
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        if (text.length > 24) text = [text substringToIndex:24];
        return text;
    }
    if ([value isKindOfClass:[NSDate class]]) return @"date";
    return @"value";
}

static NSString *IXTrackVersion(void) {
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![ver isKindOfClass:[NSString class]] || ver.length == 0 || ver.length > 24) return @"436";
    return ver;
}

static id IXPlaceholder(NSString *key) {
    const char *utf = [key isKindOfClass:[NSString class]] ? key.UTF8String : NULL;
    if (!utf || !IXFreshKnownKey(utf)) return nil;
    if (strcmp(utf, "mc_freshinstall_time") == 0) return @1609459200;
    return IXTrackVersion();
}

static const void *IXSuiteAssociation = &IXSuiteAssociation;

static NSString *IXActualSuite(NSUserDefaults *defaults) {
    NSString *suite = objc_getAssociatedObject(defaults, IXSuiteAssociation);
    if ([suite isKindOfClass:[NSString class]] && suite.length) return suite;
    return IXBundleID();
}

static void IXRememberSuite(NSUserDefaults *defaults, NSString *suite) {
    if (!defaults || ![suite isKindOfClass:[NSString class]] || suite.length == 0) return;
    objc_setAssociatedObject(defaults, IXSuiteAssociation, suite, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static id IXPersisted(NSUserDefaults *defaults, NSString *suite, NSString *key) {
    NSDictionary *domain = nil;
    if (!defaults || suite.length == 0) return nil;
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

static void IXApplyMarker(NSUserDefaults *defaults, NSString *suite, NSString *key) {
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
    if (!utf || !IXFreshMarkerSeed(persisted != nil, saved != nil, IXFreshKnownKey(utf))) return;
    placeholder = IXPlaceholder(key);
    if (!placeholder) return;
    [defaults setObject:placeholder forKey:key];
    IXMarkerPut(key, placeholder);
}

static void IXPlantMarkerFiles(NSString *containerPath) {
    static NSMutableSet *done;
    static dispatch_once_t once;
    NSFileManager *fm;
    NSString *dir;
    NSDictionary *snapshot;
    dispatch_once(&once, ^{ done = [NSMutableSet set]; });
    if (containerPath.length == 0) return;
    @synchronized (IXMarkerDict()) {
        snapshot = [IXMarkerDict() copy];
    }
    if (snapshot.count == 0) return;
    @synchronized (done) {
        if ([done containsObject:containerPath] || done.count >= 8) return;
        [done addObject:containerPath];
    }
    fm = [NSFileManager defaultManager];
    dir = [containerPath stringByAppendingPathComponent:@"Library/Preferences"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *suite in @[@"group.com.burbn.instagram", IXBundleID()]) {
        NSString *path = [dir stringByAppendingPathComponent:[suite stringByAppendingString:@".plist"]];
        NSMutableDictionary *plist = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
        BOOL dirty = NO;
        if (![plist isKindOfClass:[NSMutableDictionary class]]) plist = [NSMutableDictionary dictionary];
        for (NSString *key in snapshot) {
            if (!IXFreshKey(key) || plist[key] || !IXPlistValue(snapshot[key])) continue;
            plist[key] = snapshot[key];
            dirty = YES;
        }
        if (dirty) [plist writeToFile:path atomically:YES];
    }
}

static void IXPlantRealGroup(void) {
    Class cls = objc_getClass("LSBundleProxy");
    id proxy = nil;
    NSDictionary *paths = nil;
    if (!cls || ![cls respondsToSelector:@selector(bundleProxyForCurrentProcess)]) return;
    @try { proxy = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(bundleProxyForCurrentProcess)); }
    @catch (__unused NSException *exception) { proxy = nil; }
    if (!proxy || ![proxy respondsToSelector:@selector(groupContainerURLs)]) return;
    @try { paths = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(groupContainerURLs)); }
    @catch (__unused NSException *exception) { paths = nil; }
    if (![paths isKindOfClass:[NSDictionary class]]) return;
    for (id key in paths) {
        NSURL *url = paths[key];
        if ([url isKindOfClass:[NSURL class]]) IXPlantMarkerFiles(url.path);
    }
}

void IXPrefsSeedFreshMarkers(void) {
    @try {
        NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
        NSString *bundle = IXBundleID();
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.burbn.instagram"];
        NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSetWithArray:@[
            @"mc_freshinstall_time", @"mobileconfig_freshinstall_track_version"
        ]];
        NSArray *snapshot = nil;
        int file = 0;
        int std = 0;
        int grp = 0;
        IXNoteInstall();
        IXRememberSuite(suite, @"group.com.burbn.instagram");
        @synchronized (IXMarkerDict()) {
            for (id key in IXMarkerDict()) {
                if ([key isKindOfClass:[NSString class]]) [keys addObject:key];
            }
            file = IXDictHasFresh(IXMarkerDict());
        }
        if (!ix_before_logged) {
            ix_before_logged = 1;
            std = IXDictHasFresh([standard persistentDomainForName:bundle]);
            grp = IXDictHasFresh([suite persistentDomainForName:@"group.com.burbn.instagram"]);
            ix_marker_persisted = (file || std || grp) ? 1 : 0;
            IXSessionDiagLine([NSString stringWithFormat:@"prefs op=before existing=%d file=%d std=%d suite=%d",
                               ix_existing_install, file, std, grp]);
        }
        snapshot = keys.array;
        for (NSString *key in snapshot) {
            IXApplyMarker(standard, bundle, key);
            IXApplyMarker(suite, @"group.com.burbn.instagram", key);
        }
        [standard synchronize];
        [suite synchronize];
        IXMarkerSave();
        for (NSString *key in snapshot) {
            if (!IXFreshKey(key)) continue;
            IXSessionDiagLine([NSString stringWithFormat:@"prefs op=seed key=%@ std=%d suite=%d file=%d value=%@",
                               key,
                               IXPersisted(standard, bundle, key) ? 1 : 0,
                               IXPersisted(suite, @"group.com.burbn.instagram", key) ? 1 : 0,
                               IXMarkerGet(key) ? 1 : 0,
                               IXFreshText(IXMarkerGet(key) ?: IXPersisted(standard, bundle, key))]);
        }
        IXPlantRealGroup();
    } @catch (__unused NSException *exception) {
        IXSessionDiagLine(@"prefs op=seed status=error");
    }
}

static OSStatus (*ix_sec_delete)(CFDictionaryRef query);
static OSStatus (*ix_real_delete)(CFDictionaryRef query);
static CFPropertyListRef (*ix_cf_copy_app)(CFStringRef key, CFStringRef applicationID);
static CFPropertyListRef (*ix_cf_copy_value)(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static void (*ix_cf_set_app)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID);
static void (*ix_cf_set_value)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static Boolean (*ix_cf_get_bool)(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat);
static CFIndex (*ix_cf_get_int)(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat);
static CFPropertyListRef (*ix_cf_copy_app_real)(CFStringRef key, CFStringRef applicationID);
static CFPropertyListRef (*ix_cf_copy_value_real)(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static void (*ix_cf_set_app_real)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID);
static void (*ix_cf_set_value_real)(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName);
static Boolean (*ix_cf_get_bool_real)(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat);
static CFIndex (*ix_cf_get_int_real)(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat);
static int ix_delete_logs;
static int ix_cf_logs;
static __thread int ix_delete_depth;
static __thread int ix_cf_depth;

static int IXSyncMode(CFDictionaryRef query) {
    CFTypeRef value;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return IX_SYNC_ABSENT;
    value = CFDictionaryGetValue(query, kSecAttrSynchronizable);
    if (!value) return IX_SYNC_ABSENT;
    if (CFEqual(value, kSecAttrSynchronizableAny)) return IX_SYNC_ANY;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)value) ? IX_SYNC_TRUE : IX_SYNC_FALSE;
    return IX_SYNC_ABSENT;
}

static NSString *IXAttrText(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        NSCharacterSet *safe;
        if (text.length == 0 || text.length > 32) return [NSString stringWithFormat:@"len:%lu", (unsigned long)text.length];
        safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
        if ([text rangeOfCharacterFromSet:safe.invertedSet].location != NSNotFound) return @"redacted";
        return text;
    }
    if ([value isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"data:%lu", (unsigned long)[(NSData *)value length]];
    if ([value isKindOfClass:[NSNumber class]]) return @"num";
    return @"-";
}

static NSString *IXQuerySummary(CFDictionaryRef query) {
    NSDictionary *row;
    id kind;
    NSString *cls;
    int sync;
    NSString *syncText;
    int group;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return @"class=- svc=- acct=- sync=absent agrp=0";
    row = (__bridge NSDictionary *)query;
    kind = row[(__bridge id)kSecClass];
    cls = @"other";
    if (kind == (__bridge id)kSecClassGenericPassword) cls = @"genp";
    else if (kind == (__bridge id)kSecClassInternetPassword) cls = @"inet";
    else if (kind == (__bridge id)kSecClassCertificate) cls = @"cert";
    else if (kind == (__bridge id)kSecClassKey) cls = @"key";
    else if (kind == (__bridge id)kSecClassIdentity) cls = @"idnt";
    sync = IXSyncMode(query);
    syncText = sync == IX_SYNC_ANY ? @"any" : sync == IX_SYNC_TRUE ? @"true" : sync == IX_SYNC_FALSE ? @"false" : @"absent";
    group = row[(__bridge id)kSecAttrAccessGroup] ? 1 : 0;
    return [NSString stringWithFormat:@"class=%@ svc=%@ acct=%@ sync=%@ agrp=%d",
            cls, IXAttrText(row[(__bridge id)kSecAttrService]), IXAttrText(row[(__bridge id)kSecAttrAccount]), syncText, group];
}

static NSString *IXCaller(void) {
    void *frames[8];
    int count = backtrace(frames, 8);
    NSMutableString *who = [NSMutableString string];
    int i;
    for (i = 1; i < count && who.length < 160; i++) {
        Dl_info info;
        const char *image;
        const char *symbol;
        memset(&info, 0, sizeof info);
        if (!dladdr(frames[i], &info) || !info.dli_fname) continue;
        image = strrchr(info.dli_fname, '/');
        image = image ? image + 1 : info.dli_fname;
        if (strstr(image, "SCInsta") || strstr(image, "InstagramX")) continue;
        symbol = info.dli_sname ? info.dli_sname : "?";
        if (who.length) [who appendString:@" < "];
        [who appendFormat:@"%.32s:%.40s", image, symbol];
    }
    return who.length ? who : @"-";
}

static const char *IXClassCode(id kind) {
    if (!kind) return "";
    if (kind == (__bridge id)kSecClassGenericPassword) return "genp";
    if (kind == (__bridge id)kSecClassInternetPassword) return "inet";
    if (kind == (__bridge id)kSecClassCertificate) return "cert";
    if (kind == (__bridge id)kSecClassKey) return "key";
    if (kind == (__bridge id)kSecClassIdentity) return "idnt";
    return "other";
}

static const char *IXServiceC(id value) {
    const char *utf;
    if (![value isKindOfClass:[NSString class]]) return "";
    utf = [(NSString *)value UTF8String];
    return utf ? utf : "";
}

static OSStatus IXObserveDelete(CFDictionaryRef query) {
    NSDictionary *row = nil;
    const char *service = "";
    const char *cls = "";
    int allow;
    OSStatus status;
    if (ix_delete_depth) return ix_real_delete ? ix_real_delete(query) : errSecParam;
    ix_delete_depth++;
    IXNoteInstall();
    if (query && CFGetTypeID(query) == CFDictionaryGetTypeID()) {
        row = (__bridge NSDictionary *)query;
        service = IXServiceC(row[(__bridge id)kSecAttrService]);
        cls = IXClassCode(row[(__bridge id)kSecClass]);
    }
    allow = IXSessionDeleteAllowed(ix_existing_install == 1, ix_launch_finished, ix_marker_persisted, IXSessionOurService(service), IXSessionPasswordClass(cls));
    if (!allow) {
        ix_blocked++;
        status = errSecSuccess;
    } else if (ix_sec_delete) {
        status = ix_sec_delete(query);
    } else {
        status = ix_real_delete ? ix_real_delete(query) : errSecParam;
    }
    if (ix_delete_logs < 24) {
        ix_delete_logs++;
        if (!allow) {
            IXSessionDiagLine([NSString stringWithFormat:@"kc op=delete status=blocked %@ who=%@",
                               IXQuerySummary(query), IXCaller()]);
        } else {
            IXSessionDiagLine([NSString stringWithFormat:@"kc op=delete status=%d %@ who=%@",
                               (int)status, IXQuerySummary(query), IXCaller()]);
        }
    }
    ix_delete_depth--;
    return status;
}

static NSString *IXCFKey(CFTypeRef key) {
    if (!key || CFGetTypeID(key) != CFStringGetTypeID()) return nil;
    return (__bridge NSString *)key;
}

static CFPropertyListRef IXHeld(id value) {
    if (!IXPlistValue(value)) return NULL;
    return CFBridgingRetain(value);
}

static CFPropertyListRef IXMissingMarker(NSString *key, CFPropertyListRef found) {
    id saved;
    id placeholder;
    const char *utf;
    if (found || !IXFreshKey(key)) return found;
    saved = IXMarkerGet(key);
    utf = key.UTF8String;
    if (!saved && utf && IXFreshMarkerSeed(0, 0, IXFreshKnownKey(utf))) {
        placeholder = IXPlaceholder(key);
        if (placeholder) {
            IXMarkerPut(key, placeholder);
            saved = placeholder;
        }
    }
    if (!saved) return NULL;
    return IXHeld(saved);
}

static void IXNoteCFWrite(CFTypeRef key, CFTypeRef value) {
    NSString *name = IXCFKey(key);
    id obj;
    if (!IXFreshKey(name) || !value) return;
    obj = (__bridge id)value;
    if (!IXPlistValue(obj)) return;
    IXMarkerPut(name, obj);
    if (ix_cf_logs < 12) {
        ix_cf_logs++;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=cf key=%@ value=%@", name, IXFreshText(obj)]);
    }
}

static CFPropertyListRef IXCopyApp(CFStringRef key, CFStringRef applicationID) {
    CFPropertyListRef found = NULL;
    if (ix_cf_depth) return ix_cf_copy_app_real ? ix_cf_copy_app_real(key, applicationID) : NULL;
    ix_cf_depth++;
    if (ix_cf_copy_app) found = ix_cf_copy_app(key, applicationID);
    found = IXMissingMarker(IXCFKey(key), found);
    ix_cf_depth--;
    return found;
}

static CFPropertyListRef IXCopyValue(CFStringRef key, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    CFPropertyListRef found = NULL;
    if (ix_cf_depth) return ix_cf_copy_value_real ? ix_cf_copy_value_real(key, applicationID, userName, hostName) : NULL;
    ix_cf_depth++;
    if (ix_cf_copy_value) found = ix_cf_copy_value(key, applicationID, userName, hostName);
    found = IXMissingMarker(IXCFKey(key), found);
    ix_cf_depth--;
    return found;
}

static void IXSetApp(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    if (ix_cf_depth) {
        if (ix_cf_set_app_real) ix_cf_set_app_real(key, value, applicationID);
        return;
    }
    ix_cf_depth++;
    if (ix_cf_set_app) ix_cf_set_app(key, value, applicationID);
    IXNoteCFWrite(key, value);
    ix_cf_depth--;
}

static void IXSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef applicationID, CFStringRef userName, CFStringRef hostName) {
    if (ix_cf_depth) {
        if (ix_cf_set_value_real) ix_cf_set_value_real(key, value, applicationID, userName, hostName);
        return;
    }
    ix_cf_depth++;
    if (ix_cf_set_value) ix_cf_set_value(key, value, applicationID, userName, hostName);
    IXNoteCFWrite(key, value);
    ix_cf_depth--;
}

static Boolean IXGetBool(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) {
    Boolean valid = false;
    Boolean value = false;
    NSString *name;
    id saved;
    if (ix_cf_depth) return ix_cf_get_bool_real ? ix_cf_get_bool_real(key, applicationID, keyExistsAndHasValidFormat) : false;
    ix_cf_depth++;
    if (ix_cf_get_bool) value = ix_cf_get_bool(key, applicationID, &valid);
    name = IXCFKey(key);
    saved = IXFreshKey(name) ? IXMarkerGet(name) : nil;
    if (!valid && [saved isKindOfClass:[NSNumber class]]) {
        value = [saved boolValue] ? true : false;
        valid = true;
    }
    if (keyExistsAndHasValidFormat) *keyExistsAndHasValidFormat = valid;
    ix_cf_depth--;
    return value;
}

static CFIndex IXGetInt(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) {
    Boolean valid = false;
    CFIndex value = 0;
    NSString *name;
    id saved;
    if (ix_cf_depth) return ix_cf_get_int_real ? ix_cf_get_int_real(key, applicationID, keyExistsAndHasValidFormat) : 0;
    ix_cf_depth++;
    if (ix_cf_get_int) value = ix_cf_get_int(key, applicationID, &valid);
    name = IXCFKey(key);
    saved = IXFreshKey(name) ? IXMarkerGet(name) : nil;
    if (!valid && [saved isKindOfClass:[NSNumber class]]) {
        value = (CFIndex)[saved integerValue];
        valid = true;
    }
    if (keyExistsAndHasValidFormat) *keyExistsAndHasValidFormat = valid;
    ix_cf_depth--;
    return value;
}

static void IXInstallLaunchGuards(void) {
    union { OSStatus (*fn)(CFDictionaryRef); void *ptr; } deleteBits;
    union { CFPropertyListRef (*fn)(CFStringRef, CFStringRef); void *ptr; } copyAppBits;
    union { CFPropertyListRef (*fn)(CFStringRef, CFStringRef, CFStringRef, CFStringRef); void *ptr; } copyValueBits;
    union { void (*fn)(CFStringRef, CFPropertyListRef, CFStringRef); void *ptr; } setAppBits;
    union { void (*fn)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef); void *ptr; } setValueBits;
    union { Boolean (*fn)(CFStringRef, CFStringRef, Boolean *); void *ptr; } boolBits;
    union { CFIndex (*fn)(CFStringRef, CFStringRef, Boolean *); void *ptr; } intBits;
    const char *names[7];
    void *replacements[7];
    void *deletePrev;
    if (ix_guards) return;
    ix_guards = 1;
    ix_real_delete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
    ix_cf_copy_app_real = (CFPropertyListRef (*)(CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesCopyAppValue");
    ix_cf_copy_value_real = (CFPropertyListRef (*)(CFStringRef, CFStringRef, CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesCopyValue");
    ix_cf_set_app_real = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesSetAppValue");
    ix_cf_set_value_real = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef))dlsym(RTLD_DEFAULT, "CFPreferencesSetValue");
    ix_cf_get_bool_real = (Boolean (*)(CFStringRef, CFStringRef, Boolean *))dlsym(RTLD_DEFAULT, "CFPreferencesGetAppBooleanValue");
    ix_cf_get_int_real = (CFIndex (*)(CFStringRef, CFStringRef, Boolean *))dlsym(RTLD_DEFAULT, "CFPreferencesGetAppIntegerValue");
    deleteBits.fn = IXObserveDelete;
    copyAppBits.fn = IXCopyApp;
    copyValueBits.fn = IXCopyValue;
    setAppBits.fn = IXSetApp;
    setValueBits.fn = IXSetValue;
    boolBits.fn = IXGetBool;
    intBits.fn = IXGetInt;
    names[0] = "SecItemDelete";
    names[1] = "CFPreferencesCopyAppValue";
    names[2] = "CFPreferencesCopyValue";
    names[3] = "CFPreferencesSetAppValue";
    names[4] = "CFPreferencesSetValue";
    names[5] = "CFPreferencesGetAppBooleanValue";
    names[6] = "CFPreferencesGetAppIntegerValue";
    replacements[0] = deleteBits.ptr;
    replacements[1] = copyAppBits.ptr;
    replacements[2] = copyValueBits.ptr;
    replacements[3] = setAppBits.ptr;
    replacements[4] = setValueBits.ptr;
    replacements[5] = boolBits.ptr;
    replacements[6] = intBits.ptr;
    IXSymbolRebindPermanent(names, replacements, 7);
    deletePrev = IXSymbolPrevious("SecItemDelete");
    if (deletePrev == (void *)IXObserveDelete) deletePrev = NULL;
    ix_sec_delete = deletePrev ? (OSStatus (*)(CFDictionaryRef))deletePrev : ix_real_delete;
    ix_cf_copy_app = ix_cf_copy_app_real;
    ix_cf_copy_value = ix_cf_copy_value_real;
    ix_cf_set_app = ix_cf_set_app_real;
    ix_cf_set_value = ix_cf_set_value_real;
    ix_cf_get_bool = ix_cf_get_bool_real;
    ix_cf_get_int = ix_cf_get_int_real;
    {
        void *prev = IXSymbolPrevious("CFPreferencesCopyAppValue");
        if (prev && prev != (void *)IXCopyApp) ix_cf_copy_app = (CFPropertyListRef (*)(CFStringRef, CFStringRef))prev;
        prev = IXSymbolPrevious("CFPreferencesCopyValue");
        if (prev && prev != (void *)IXCopyValue) ix_cf_copy_value = (CFPropertyListRef (*)(CFStringRef, CFStringRef, CFStringRef, CFStringRef))prev;
        prev = IXSymbolPrevious("CFPreferencesSetAppValue");
        if (prev && prev != (void *)IXSetApp) ix_cf_set_app = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef))prev;
        prev = IXSymbolPrevious("CFPreferencesSetValue");
        if (prev && prev != (void *)IXSetValue) ix_cf_set_value = (void (*)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef))prev;
        prev = IXSymbolPrevious("CFPreferencesGetAppBooleanValue");
        if (prev && prev != (void *)IXGetBool) ix_cf_get_bool = (Boolean (*)(CFStringRef, CFStringRef, Boolean *))prev;
        prev = IXSymbolPrevious("CFPreferencesGetAppIntegerValue");
        if (prev && prev != (void *)IXGetInt) ix_cf_get_int = (CFIndex (*)(CFStringRef, CFStringRef, Boolean *))prev;
    }
    IXSessionDiagLine([NSString stringWithFormat:@"kc op=hook delete=%d copy=0",
                       deletePrev && deletePrev != (void *)ix_real_delete ? 1 : 0]);
}

void IXSessionLaunchFinished(void) {
    ix_launch_finished = 1;
    IXSessionDiagLine([NSString stringWithFormat:@"kc op=guard launch_finished=1 blocked=%d existing=%d persisted=%d",
                       ix_blocked, ix_existing_install < 0 ? 0 : ix_existing_install, ix_marker_persisted]);
}

static void IXSessionArm(void) {
    IXNoteInstall();
    IXInstallLaunchGuards();
    IXPrefsSeedFreshMarkers();
}

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    NSURL *url = nil;
    if (depth > 0) return nil;
    depth++;
    @try { url = %orig; }
    @catch (__unused NSException *exception) { url = nil; }
    depth--;
    if ([url isKindOfClass:[NSURL class]] && url.path.length) {
        static NSMutableSet *migrated;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ migrated = [NSMutableSet set]; });
        @synchronized (migrated) {
            if (![migrated containsObject:url.path]) {
                [migrated addObject:url.path];
                IXMigrateIntoFallback(url.path);
            }
        }
        IXPlantMarkerFiles(url.path);
        IXSessionDiagNoteContainer(url.path, @"system");
        return url;
    }
    BOOL existed = NO;
    NSURL *fallback = IXFallbackContainer(identifier, &existed);
    if (fallback.path.length) {
        IXMigrateIntoFallback(fallback.path);
        IXPlantMarkerFiles(fallback.path);
    }
    IXSessionDiagNoteContainer(fallback.path, existed ? @"fallback-existing" : @"fallback-new");
    return fallback;
}
%end

%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)suiteName {
    NSUserDefaults *defaults = %orig;
    IXRememberSuite(defaults, suiteName);
    return defaults;
}
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
    NSUserDefaults *defaults = %orig;
    IXRememberSuite(defaults, suiteName);
    return defaults;
}
- (NSDictionary *)persistentDomainForName:(NSString *)domainName {
    static __thread int depth = 0;
    NSDictionary *domain = nil;
    NSMutableDictionary *merged = nil;
    NSDictionary *snapshot = nil;
    BOOL added = NO;
    if (depth) return %orig;
    depth = 1;
    @try { domain = %orig; }
    @catch (__unused NSException *exception) { domain = nil; }
    depth = 0;
    if (ix_filling) return domain;
    @synchronized (IXMarkerDict()) {
        snapshot = [IXMarkerDict() copy];
    }
    for (NSString *key in snapshot) {
        id saved;
        if (!IXFreshKey(key)) continue;
        if ([domain isKindOfClass:[NSDictionary class]] && domain[key]) continue;
        saved = snapshot[key];
        if (!IXPlistValue(saved)) continue;
        if (!added) {
            merged = [domain isKindOfClass:[NSDictionary class]] ? [domain mutableCopy] : [NSMutableDictionary dictionary];
            added = YES;
        }
        merged[key] = saved;
    }
    return added ? merged : domain;
}
- (void)setObject:(id)value forKey:(NSString *)defaultName {
    static int writes = 0;
    %orig;
    if (!IXFreshKey(defaultName) || !IXPlistValue(value)) return;
    IXMarkerPut(defaultName, value);
    if (writes < 24) {
        writes++;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=write suite=%@ key=%@ value=%@",
                           IXActualSuite(self), defaultName, IXFreshText(value)]);
    }
}
- (void)removeObjectForKey:(NSString *)defaultName {
    static int removes = 0;
    %orig;
    if (!IXFreshKey(defaultName)) return;
    if (removes < 12) {
        removes++;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=remove suite=%@ key=%@", IXActualSuite(self), defaultName]);
    }
}
- (id)objectForKey:(NSString *)defaultName {
    id value;
    NSDictionary *domain;
    id persisted;
    id saved;
    const char *utf;
    static int reads = 0;
    if (ix_filling || !IXFreshKey(defaultName)) return %orig;
    ix_filling = 1;
    domain = [self persistentDomainForName:IXActualSuite(self)];
    persisted = [domain isKindOfClass:[NSDictionary class]] ? domain[defaultName] : nil;
    value = persisted;
    saved = IXMarkerGet(defaultName);
    utf = defaultName.UTF8String;
    if (IXFreshMarkerRestore(persisted != nil, saved != nil)) {
        [self setObject:saved forKey:defaultName];
        value = saved;
    } else if (utf && IXFreshMarkerSeed(persisted != nil, saved != nil, IXFreshKnownKey(utf))) {
        id placeholder = IXPlaceholder(defaultName);
        if (placeholder) {
            [self setObject:placeholder forKey:defaultName];
            IXMarkerPut(defaultName, placeholder);
            value = placeholder;
        }
    } else if (persisted && !saved) {
        IXMarkerPut(defaultName, persisted);
    }
    if (!value) value = %orig;
    if (reads < 30) {
        reads++;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=read suite=%@ key=%@ value=%@",
                           IXActualSuite(self), defaultName, IXFreshText(value)]);
    }
    ix_filling = 0;
    return value;
}
%end

@interface IXSessionBoot : NSObject
@end

@implementation IXSessionBoot
+ (void)load {
    IXSessionArm();
}
@end

%ctor {
    %init;
    IXInstallDirectAppGroup();
    IXSessionArm();
}
