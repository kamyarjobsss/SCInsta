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

// v2.4.0 and v2.4.1 hooked SecItemAdd/Copy/Update/Delete and forced an access
// group. That bypasses zxPluginsInject, which is what keeps sessions in the
// healthy sideload. A query written with one group was not found on the next
// launch, so Instagram still had the saved accounts and asked for the password.
// Those hooks are gone. Keychain items are left to the system and to zx.
//
// v2.4.2 left each group id on its own directory, and group-suite defaults
// never reached disk, so Instagram treated every launch as a fresh install
// and deleted the session. Every group id now shares Documents/InstagramX/AppGroup.
// group.com.burbn.instagram* and group.com.facebook.family suites are stored
// as instagramx.appgroup in the app sandbox, and the fresh-install keys are
// copied to Documents so the next launch can put them back before Instagram
// reads them. SecItemAdd and SecItemUpdate stay unhooked. SecItemDelete is
// logged with the caller image, symbol, and query attributes, then passed
// through the previous hook. SecItemCopyMatching retries a read with
// kSecAttrSynchronizableAny when the first partition does not contain the
// item, because Instagram stores login items as synchronizable keychain
// items and a sideload has no iCloud keychain entitlement. Access groups
// are not rewritten.

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
    // Same lookup the rest of the process uses. A system or zx URL wins.
    // The Documents folder is only used when that lookup returns nothing,
    // so this object cannot point at a different directory than the hook.
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

static NSURL *IXStableGroupURL(void) {
    static NSURL *url;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
        if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSString *path = [docs stringByAppendingPathComponent:@"InstagramX/AppGroup"];
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        url = [NSURL fileURLWithPath:path isDirectory:YES];
    });
    return url;
}

static void IXMigrateGroupDirs(NSString *destPath) {
    if (destPath.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    for (NSString *name in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (![name isKindOfClass:[NSString class]]) continue;
        if (![name hasPrefix:@"group.com.burbn.instagram"] && ![name hasPrefix:@"group.com.facebook.family"]) continue;
        IXCopyMissing(fm, [docs stringByAppendingPathComponent:name], destPath);
    }
    IXMigrateIntoFallback(destPath);
}

static NSString *IXMappedSuite(NSString *suite) {
    if (![suite isKindOfClass:[NSString class]] || suite.length == 0 || suite.length > 180) return nil;
    char out[64];
    if (!IXPrefsSharedSuite(suite.UTF8String, out, sizeof out)) return nil;
    return [NSString stringWithUTF8String:out];
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
    @synchronized (IXMarkerDict()) {
        return IXMarkerDict()[key];
    }
}

static void IXMarkerPut(NSString *key, id value) {
    if (!IXPlistValue(value)) return;
    @synchronized (IXMarkerDict()) {
        id existing = IXMarkerDict()[key];
        if (existing && [existing isEqual:value]) return;
        IXMarkerDict()[key] = value;
    }
    IXMarkerSave();
}

static BOOL IXFreshKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0 || key.length > 80) return NO;
    NSString *lower = key.lowercaseString;
    if ([lower containsString:@"password"] || [lower containsString:@"token"] || [lower containsString:@"session"]) return NO;
    return [lower containsString:@"freshinstall"];
}

static NSString *IXFreshText(id value) {
    if (!value || value == [NSNull null]) return @"missing";
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        if (text.length > 24) text = [text substringToIndex:24];
        return text;
    }
    return @"value";
}

static const void *IXSuiteAssociation = &IXSuiteAssociation;

static NSString *IXActualSuite(NSUserDefaults *defaults) {
    NSString *suite = objc_getAssociatedObject(defaults, IXSuiteAssociation);
    if ([suite isKindOfClass:[NSString class]] && suite.length) return suite;
    return [NSBundle mainBundle].bundleIdentifier ?: @"com.burbn.instagram";
}

static void IXRememberSuite(NSUserDefaults *defaults, NSString *suite) {
    if (!defaults || suite.length == 0) return;
    objc_setAssociatedObject(defaults, IXSuiteAssociation, suite, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static OSStatus (*ix_sec_delete)(CFDictionaryRef query);
static OSStatus (*ix_sec_copy)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*ix_real_delete)(CFDictionaryRef query);
static OSStatus (*ix_real_copy)(CFDictionaryRef query, CFTypeRef *result);
static int ix_delete_logs;
static __thread int ix_delete_depth;
static __thread int ix_copy_depth;

static int IXSyncMode(CFDictionaryRef query) {
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return IX_SYNC_ABSENT;
    CFTypeRef value = CFDictionaryGetValue(query, kSecAttrSynchronizable);
    if (!value) return IX_SYNC_ABSENT;
    if (CFEqual(value, kSecAttrSynchronizableAny)) return IX_SYNC_ANY;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue((CFBooleanRef)value) ? IX_SYNC_TRUE : IX_SYNC_FALSE;
    return IX_SYNC_ABSENT;
}

static NSString *IXAttrText(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)value;
        if (text.length == 0 || text.length > 32) return [NSString stringWithFormat:@"len:%lu", (unsigned long)text.length];
        NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
        if ([text rangeOfCharacterFromSet:safe.invertedSet].location != NSNotFound) return @"redacted";
        return text;
    }
    if ([value isKindOfClass:[NSData class]]) return [NSString stringWithFormat:@"data:%lu", (unsigned long)[(NSData *)value length]];
    if ([value isKindOfClass:[NSNumber class]]) return @"num";
    return @"-";
}

static NSString *IXQuerySummary(CFDictionaryRef query) {
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return @"class=- svc=- acct=- sync=absent agrp=0";
    NSDictionary *row = (__bridge NSDictionary *)query;
    id kind = row[(__bridge id)kSecClass];
    NSString *cls = @"other";
    if (kind == (__bridge id)kSecClassGenericPassword) cls = @"genp";
    else if (kind == (__bridge id)kSecClassInternetPassword) cls = @"inet";
    else if (kind == (__bridge id)kSecClassCertificate) cls = @"cert";
    else if (kind == (__bridge id)kSecClassKey) cls = @"key";
    else if (kind == (__bridge id)kSecClassIdentity) cls = @"idnt";
    int sync = IXSyncMode(query);
    NSString *syncText = sync == IX_SYNC_ANY ? @"any" : sync == IX_SYNC_TRUE ? @"true" : sync == IX_SYNC_FALSE ? @"false" : @"absent";
    int group = row[(__bridge id)kSecAttrAccessGroup] ? 1 : 0;
    return [NSString stringWithFormat:@"class=%@ svc=%@ acct=%@ sync=%@ agrp=%d",
            cls, IXAttrText(row[(__bridge id)kSecAttrService]), IXAttrText(row[(__bridge id)kSecAttrAccount]), syncText, group];
}

static CFDictionaryRef IXQueryWithSync(CFDictionaryRef query, int mode) {
    NSMutableDictionary *copy = query && CFGetTypeID(query) == CFDictionaryGetTypeID() ? [(__bridge NSDictionary *)query mutableCopy] : [NSMutableDictionary dictionary];
    id key = (__bridge id)kSecAttrSynchronizable;
    if (mode == IX_SYNC_ABSENT) [copy removeObjectForKey:key];
    else if (mode == IX_SYNC_ANY) copy[key] = (__bridge id)kSecAttrSynchronizableAny;
    else if (mode == IX_SYNC_TRUE) copy[key] = @YES;
    else copy[key] = @NO;
    return (CFDictionaryRef)CFBridgingRetain(copy);
}

static OSStatus IXObserveDelete(CFDictionaryRef query) {
    if (ix_delete_depth) return ix_real_delete ? ix_real_delete(query) : errSecParam;
    ix_delete_depth++;
    OSStatus status = ix_sec_delete ? ix_sec_delete(query) : errSecParam;
    if (ix_delete_logs < 24) {
        ix_delete_logs++;
        void *frames[8];
        int count = backtrace(frames, 8);
        NSMutableString *who = [NSMutableString string];
        for (int i = 1; i < count && who.length < 160; i++) {
            Dl_info info;
            memset(&info, 0, sizeof info);
            if (!dladdr(frames[i], &info) || !info.dli_fname) continue;
            const char *image = strrchr(info.dli_fname, '/');
            image = image ? image + 1 : info.dli_fname;
            if (strstr(image, "SCInsta") || strstr(image, "InstagramX")) continue;
            const char *symbol = info.dli_sname ?: "?";
            if (who.length) [who appendString:@" < "];
            [who appendFormat:@"%.32s:%.40s", image, symbol];
        }
        IXSessionDiagLine([NSString stringWithFormat:@"kc op=delete status=%d %@ who=%@",
                           (int)status, IXQuerySummary(query), who.length ? who : @"-"]);
    }
    ix_delete_depth--;
    return status;
}

static OSStatus IXObserveCopy(CFDictionaryRef query, CFTypeRef *result) {
    if (ix_copy_depth || !ix_sec_copy) return ix_real_copy ? ix_real_copy(query, result) : errSecParam;
    ix_copy_depth++;
    int incoming = IXSyncMode(query);
    int first = IXKeychainReadFirstSync(incoming);
    CFDictionaryRef primary = first == incoming ? query : IXQueryWithSync(query, first);
    CFTypeRef found = NULL;
    OSStatus status = ix_sec_copy(primary, result ? &found : NULL);
    int fallback = IXKeychainReadFallbackSync(incoming, (int)status);
    if (fallback >= 0) {
        if (found) {
            CFRelease(found);
            found = NULL;
        }
        CFDictionaryRef second = IXQueryWithSync(query, fallback);
        status = ix_sec_copy(second, result ? &found : NULL);
        if (second) CFRelease(second);
    }
    if (primary && primary != query) CFRelease(primary);
    if (result) *result = found;
    else if (found) CFRelease(found);
    ix_copy_depth--;
    return status;
}

static void IXInstallKeychainHooks(void) {
    ix_real_delete = (OSStatus (*)(CFDictionaryRef))dlsym(RTLD_DEFAULT, "SecItemDelete");
    ix_real_copy = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    union { OSStatus (*fn)(CFDictionaryRef); void *ptr; } deleteBits;
    union { OSStatus (*fn)(CFDictionaryRef, CFTypeRef *); void *ptr; } copyBits;
    deleteBits.fn = IXObserveDelete;
    copyBits.fn = IXObserveCopy;
    const char *names[2] = { "SecItemDelete", "SecItemCopyMatching" };
    void *replacements[2] = { deleteBits.ptr, copyBits.ptr };
    IXSymbolRebindPermanent(names, replacements, 2);
    void *deletePrev = IXSymbolPrevious("SecItemDelete");
    void *copyPrev = IXSymbolPrevious("SecItemCopyMatching");
    ix_sec_delete = deletePrev ? (OSStatus (*)(CFDictionaryRef))deletePrev : ix_real_delete;
    ix_sec_copy = copyPrev ? (OSStatus (*)(CFDictionaryRef, CFTypeRef *))copyPrev : ix_real_copy;
    IXSessionDiagLine([NSString stringWithFormat:@"kc op=hook delete=%d copy=%d",
                       deletePrev && deletePrev != (void *)ix_real_delete ? 1 : 0,
                       copyPrev && copyPrev != (void *)ix_real_copy ? 1 : 0]);
}

void IXPrefsSeedFreshMarkers(void) {
    @try {
        NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier ?: @"com.burbn.instagram";
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.burbn.instagram"];
        NSString *suiteName = IXActualSuite(suite);
        NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSetWithArray:@[
            @"mc_freshinstall_time", @"mobileconfig_freshinstall_track_version"
        ]];
        @synchronized (IXMarkerDict()) {
            for (id key in IXMarkerDict()) {
                if ([key isKindOfClass:[NSString class]]) [keys addObject:key];
            }
        }
        NSDictionary *stdDomain = [standard persistentDomainForName:bundle];
        NSDictionary *suiteDomain = [suite persistentDomainForName:suiteName];
        NSDictionary *registered = [standard dictionaryRepresentation];
        BOOL dirty = NO;
        for (NSString *key in keys) {
            if (!IXFreshKey(key)) continue;
            id file = IXMarkerGet(key);
            id std = [stdDomain isKindOfClass:[NSDictionary class]] ? stdDomain[key] : nil;
            id grp = [suiteDomain isKindOfClass:[NSDictionary class]] ? suiteDomain[key] : nil;
            id reg = [registered isKindOfClass:[NSDictionary class]] ? registered[key] : nil;
            id best = grp ?: std ?: file;
            IXSessionDiagLine([NSString stringWithFormat:@"prefs op=seed key=%@ std=%d reg=%d suite=%d file=%d value=%@",
                               key, std ? 1 : 0, (reg && !std) ? 1 : 0, grp ? 1 : 0, file ? 1 : 0, IXFreshText(best)]);
            if (!best) continue;
            if (!grp) {
                [suite setObject:best forKey:key];
                dirty = YES;
            }
            if (!std) [standard setObject:best forKey:key];
            if (!file) {
                IXMarkerPut(key, best);
                dirty = YES;
            }
        }
        if (dirty) {
            [suite synchronize];
            IXMarkerSave();
        }
        NSString *plist = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/instagramx.appgroup.plist"];
        int plistExists = [[NSFileManager defaultManager] fileExistsAtPath:plist] ? 1 : 0;
        int fileExists = [[NSFileManager defaultManager] fileExistsAtPath:IXMarkerPath()] ? 1 : 0;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs store=instagramx.appgroup plist=%d marker=%d", plistExists, fileExists]);
    } @catch (__unused NSException *exception) {
        IXSessionDiagLine(@"prefs op=seed status=error");
    }
}

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    NSURL *stable = IXStableGroupURL();
    if (depth > 0 || !stable.path.length) return stable;
    depth++;
    NSURL *url = nil;
    @try { url = %orig; }
    @catch (__unused NSException *exception) { url = nil; }
    depth--;
    static NSMutableSet *migrated;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ migrated = [NSMutableSet set]; });
    NSString *from = [url isKindOfClass:[NSURL class]] ? url.path : @"";
    @synchronized (migrated) {
        if (from.length && ![from isEqualToString:stable.path] && ![migrated containsObject:from]) {
            [migrated addObject:from];
            IXCopyMissing([NSFileManager defaultManager], from, stable.path);
        }
        if (![migrated containsObject:@"legacy"]) {
            [migrated addObject:@"legacy"];
            IXMigrateGroupDirs(stable.path);
        }
    }
    IXSessionDiagNoteContainer(stable.path, @"stable");
    NSString *group = [identifier isKindOfClass:[NSString class]] && identifier.length ? identifier : @"-";
    if (group.length > 80) group = [group substringToIndex:80];
    static NSMutableSet *logged;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{ logged = [NSMutableSet set]; });
    @synchronized (logged) {
        if (logged.count < 8 && ![logged containsObject:group]) {
            [logged addObject:group];
            IXSessionDiagLine([NSString stringWithFormat:@"container source=stable group=%@ path=%@", group, stable.path]);
        }
    }
    return stable;
}
%end

%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)suiteName {
    NSString *mapped = IXMappedSuite(suiteName);
    NSUserDefaults *defaults = %orig(mapped ?: suiteName);
    IXRememberSuite(defaults, mapped ?: suiteName);
    return defaults;
}
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
    NSString *mapped = IXMappedSuite(suiteName);
    if (!mapped) {
        NSUserDefaults *defaults = %orig(suiteName, container);
        IXRememberSuite(defaults, suiteName);
        return defaults;
    }
    NSUserDefaults *defaults = %orig(mapped, IXStableGroupURL());
    IXRememberSuite(defaults, mapped);
    return defaults;
}
- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;
    if (!IXFreshKey(defaultName)) return;
    if (value) IXMarkerPut(defaultName, value);
    IXSessionDiagLine([NSString stringWithFormat:@"prefs op=write suite=%@ key=%@ value=%@",
                       IXActualSuite(self), defaultName, IXFreshText(value)]);
}
- (void)removeObjectForKey:(NSString *)defaultName {
    %orig;
    if (!IXFreshKey(defaultName)) return;
    IXSessionDiagLine([NSString stringWithFormat:@"prefs op=remove suite=%@ key=%@", IXActualSuite(self), defaultName]);
}
- (id)objectForKey:(NSString *)defaultName {
    static __thread int filling = 0;
    if (filling || !IXFreshKey(defaultName)) return %orig;
    filling = 1;
    id value = %orig;
    NSDictionary *domain = [self persistentDomainForName:IXActualSuite(self)];
    id persisted = [domain isKindOfClass:[NSDictionary class]] ? domain[defaultName] : nil;
        if (!persisted) {
        id saved = IXMarkerGet(defaultName);
        if (saved) {
            [self setObject:saved forKey:defaultName];
            value = saved;
            persisted = saved;
        }
    } else if (!IXMarkerGet(defaultName)) {
        IXMarkerPut(defaultName, persisted);
    }
    static int reads = 0;
    if (reads < 30) {
        reads++;
        IXSessionDiagLine([NSString stringWithFormat:@"prefs op=read suite=%@ key=%@ value=%@",
                           IXActualSuite(self), defaultName, IXFreshText(persisted ?: value)]);
    }
    filling = 0;
    return value;
}
%end

%ctor {
    %init;
    IXInstallDirectAppGroup();
    IXInstallKeychainHooks();
    IXPrefsSeedFreshMarkers();
}
