#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXKeychainGroup.h"

// Instagram 436 calls +[METAAppGroup appGroupForGroupName:] as an objc_direct
// import (no _cmd). v2.1.1 declared the replacement as (id, SEL, id) and
// SIGSEGV'd. A nil identifier aborts the direct-message loader.
//
// Diff against the build that kept one session and the unmodded sideload that
// kept every account:
// 2.1.4 wrote the SecItem probe group (TEAMID.com.burbn.instagram) over
// Instagram's own identifier. The session file is keyed by the name Instagram
// passed, so the next launch fell through to one-tap login. 2.1.4 through
// 2.2.4 stopped doing that, but they also returned as soon as the identifier
// was non-nil and left a nil containerURL and userDefaults in place. The
// account switcher list lives in that container. The active token lives in
// the keychain. Force-close kept only the last token, and Instagram showed
// "Logging you in..." for that account. Unmodded sideload (zxPluginsInject
// only) always has a container, so both accounts were on disk.
// A non-nil identifier is still not replaced with the probe group. A nil
// container is filled with Documents/<bare group>, the same directory
// zxPluginsInject uses when the process has no real app-group container.
// The directory name has the team prefix removed, so Sideloadly and
// LiveContainer can change the keychain prefix without moving the files.
// SecItem groups that the signed task is not allowed to use are rewritten
// from the application-identifier prefix read at runtime.

static NSString *ix_appId;
static NSString *ix_prefix;
static NSArray<NSString *> *ix_entitled;

static int IXEntitledList(const char **out, int cap) {
    int n = 0;
    for (NSString *group in ix_entitled) {
        if (n >= cap) break;
        if (![group isKindOfClass:[NSString class]] || group.length == 0) continue;
        out[n++] = group.UTF8String;
    }
    return n;
}

static NSString *IXCanonicalGroup(NSString *requested) {
    const char *ents[32];
    int n = IXEntitledList(ents, 32);
    char out[768];
    const char *req = [requested isKindOfClass:[NSString class]] ? requested.UTF8String : NULL;
    if (!IXKeychainCanonicalGroup(ix_appId.UTF8String, req, n ? ents : NULL, n, out, sizeof out)) {
        return [requested isKindOfClass:[NSString class]] ? requested : nil;
    }
    return [NSString stringWithUTF8String:out] ?: requested;
}

static NSString *IXStaleIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return nil;
    const char *ents[32];
    int n = IXEntitledList(ents, 32);
    char out[768];
    if (!IXKeychainStalePrefixedGroup(ix_appId.UTF8String, identifier.UTF8String, n ? ents : NULL, n, out, sizeof out)) {
        return nil;
    }
    return [NSString stringWithUTF8String:out];
}

static NSString *IXBareGroup(NSString *identifier) {
    const char *src = [identifier isKindOfClass:[NSString class]] ? identifier.UTF8String : NULL;
    char bare[512];
    if (!src || !IXKeychainStripTeamPrefix(src, bare, sizeof bare) || !bare[0]) {
        return @"group.com.burbn.instagram";
    }
    return [NSString stringWithUTF8String:bare] ?: @"group.com.burbn.instagram";
}

static NSString *IXGroupIdentifier(id name) {
    if ([name isKindOfClass:[NSString class]] && [name length]) return name;
    return @"group.com.burbn.instagram";
}

static void IXLoadSignedIdentity(void) {
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
            if (app && CFGetTypeID(app) == CFStringGetTypeID()) ix_appId = [(__bridge NSString *)app copy];
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
    if (ix_appId.length == 0 || ix_entitled.count == 0) {
        Class cls = objc_getClass("LSBundleProxy");
        id proxy = nil;
        if (cls) {
            @try { proxy = ((id (*)(id, SEL))objc_msgSend)(cls, sel_registerName("bundleProxyForCurrentProcess")); }
            @catch (__unused NSException *exception) { proxy = nil; }
        }
        NSDictionary *ent = nil;
        if (proxy && [proxy respondsToSelector:sel_registerName("entitlements")]) {
            @try { ent = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("entitlements")); }
            @catch (__unused NSException *exception) { ent = nil; }
        }
        if ([ent isKindOfClass:[NSDictionary class]]) {
            if (ix_appId.length == 0) {
                id app = ent[@"application-identifier"] ?: ent[@"com.apple.application-identifier"];
                if ([app isKindOfClass:[NSString class]] && [app length]) ix_appId = [app copy];
            }
            if (ix_entitled.count == 0) {
                id groups = ent[@"keychain-access-groups"];
                if ([groups isKindOfClass:[NSArray class]]) ix_entitled = [groups copy];
            }
        }
    }
    char prefix[11];
    if (IXKeychainTeamPrefix(ix_appId.UTF8String, prefix)) ix_prefix = [[NSString alloc] initWithUTF8String:prefix];
    NSLog(@"[InstagramX] accounts: signed %@ prefix %@ entitled %lu. Identifier group.com.burbn.instagram is kept (2.1.4 replaced it with the SecItem probe group and the next launch missed the session). Nil container is filled. Keychain group for the bare name is %@.",
          ix_appId ?: @"unread",
          ix_prefix ?: @"none",
          (unsigned long)ix_entitled.count,
          IXCanonicalGroup(@"group.com.burbn.instagram") ?: @"unchanged");
}

static void IXNoteRewrite(NSString *from, NSString *to) {
    if (!from.length || !to.length || [from isEqualToString:to]) return;
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@ -> %@", from, to];
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    NSLog(@"[InstagramX] keychain group %@ -> %@ (signed prefix %@)", from, to, ix_prefix ?: @"none");
}

static CFDictionaryRef IXRewriteQuery(CFDictionaryRef query, int *owned) {
    if (owned) *owned = 0;
    if (!query || CFGetTypeID(query) != CFDictionaryGetTypeID()) return query;
    NSDictionary *dict = (__bridge NSDictionary *)query;
    id group = dict[(__bridge id)kSecAttrAccessGroup];
    if (![group isKindOfClass:[NSString class]] || [group length] == 0) return query;
    NSString *canonical = IXCanonicalGroup(group);
    if (!canonical.length || [canonical isEqualToString:group]) return query;
    IXNoteRewrite(group, canonical);
    NSMutableDictionary *copy = [dict mutableCopy];
    copy[(__bridge id)kSecAttrAccessGroup] = canonical;
    if (owned) *owned = 1;
    return (CFDictionaryRef)CFBridgingRetain(copy);
}

static OSStatus (*ix_orig_add)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*ix_orig_copy)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*ix_orig_update)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*ix_orig_delete)(CFDictionaryRef);

static OSStatus ix_sec_add(CFDictionaryRef query, CFTypeRef *result) {
    int owned = 0;
    CFDictionaryRef fixed = IXRewriteQuery(query, &owned);
    OSStatus status = ix_orig_add ? ix_orig_add(fixed, result) : errSecUnimplemented;
    if (owned) CFRelease(fixed);
    return status;
}
static OSStatus ix_sec_copy(CFDictionaryRef query, CFTypeRef *result) {
    int owned = 0;
    CFDictionaryRef fixed = IXRewriteQuery(query, &owned);
    OSStatus status = ix_orig_copy ? ix_orig_copy(fixed, result) : errSecUnimplemented;
    if (owned) CFRelease(fixed);
    return status;
}
static OSStatus ix_sec_update(CFDictionaryRef query, CFDictionaryRef attrs) {
    int ownedQ = 0, ownedA = 0;
    CFDictionaryRef fixedQ = IXRewriteQuery(query, &ownedQ);
    CFDictionaryRef fixedA = IXRewriteQuery(attrs, &ownedA);
    OSStatus status = ix_orig_update ? ix_orig_update(fixedQ, fixedA) : errSecUnimplemented;
    if (ownedQ) CFRelease(fixedQ);
    if (ownedA) CFRelease(fixedA);
    return status;
}
static OSStatus ix_sec_delete(CFDictionaryRef query) {
    int owned = 0;
    CFDictionaryRef fixed = IXRewriteQuery(query, &owned);
    OSStatus status = ix_orig_delete ? ix_orig_delete(fixed) : errSecUnimplemented;
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
    NSLog(@"[InstagramX] keychain group rewrite installed (%d slots)", slots);
}

static NSString *IXPathLeaf(NSString *identifier) {
    NSString *bare = IXBareGroup(identifier);
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    NSString *leaf = [[bare componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    return leaf.length ? leaf : @"group.com.burbn.instagram";
}

static NSURL *IXStableContainerURL(NSString *identifier) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) return nil;
    NSString *path = [docs stringByAppendingPathComponent:IXPathLeaf(identifier)];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static void IXCopyMissing(NSFileManager *fm, NSString *src, NSString *dst) {
    NSArray *items = [fm contentsOfDirectoryAtPath:src error:nil];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *from = [src stringByAppendingPathComponent:name];
        NSString *to = [dst stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:from isDirectory:&isDir]) continue;
        if (isDir) {
            [fm createDirectoryAtPath:to withIntermediateDirectories:YES attributes:nil error:nil];
            IXCopyMissing(fm, from, to);
        } else if (![fm fileExistsAtPath:to]) {
            NSError *error = nil;
            [fm copyItemAtPath:from toPath:to error:&error];
        }
    }
}

static void IXMigrateAccountFiles(void) {
    NSURL *dest = IXStableContainerURL(@"group.com.burbn.instagram");
    if (dest.path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *sources = [NSMutableArray array];
    [sources addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup"]];
    NSString *legacyRoot = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    for (NSString *kid in [fm contentsOfDirectoryAtPath:legacyRoot error:nil]) {
        [sources addObject:[legacyRoot stringByAppendingPathComponent:kid]];
    }
    for (NSString *src in sources) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) continue;
        if ([src isEqualToString:dest.path]) continue;
        IXCopyMissing(fm, src, dest.path);
    }
}

static NSString *IXPersistentSuiteName(NSString *identifier) {
    return IXBareGroup(identifier);
}

static id IXReadIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

static void IXWriteIvar(id object, const char *name, id value) {
    if (!object || !value) return;
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
    NSString *requested = IXGroupIdentifier(name);
    id current = IXReadIvar(object, "_identifier");
    if (![current isKindOfClass:[NSString class]] || [current length] == 0) {
        IXWriteIvar(object, "_identifier", requested);
        current = requested;
    } else {
        NSString *stale = IXStaleIdentifier(current);
        if (stale.length && ![stale isEqualToString:current]) {
            NSLog(@"[InstagramX] app group prefix %@ -> %@", current, stale);
            IXWriteIvar(object, "_identifier", stale);
            current = stale;
        }
    }
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) {
        IXWriteIvar(object, "_userDefaults", [[NSUserDefaults alloc] initWithSuiteName:IXPersistentSuiteName(current)]);
    }
    if (![IXReadIvar(object, "_containerURL") isKindOfClass:[NSURL class]]) {
        NSURL *url = IXStableContainerURL(current);
        if (url) {
            IXWriteIvar(object, "_containerURL", url);
            NSLog(@"[InstagramX] app group %@ container %@", current, url.path);
        }
    }
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
    if ([value isKindOfClass:[NSString class]] && value.length) {
        NSString *stale = IXStaleIdentifier(value);
        return stale.length ? stale : value;
    }
    id filled = IXReadIvar(self, "_identifier");
    if ([filled isKindOfClass:[NSString class]] && [filled length]) return filled;
    return @"group.com.burbn.instagram";
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    if (depth) {
        @try { return %orig; }
        @catch (__unused NSException *exception) { return nil; }
    }
    depth++;
    NSURL *url = nil;
    @try { url = %orig; }
    @catch (__unused NSException *exception) { url = nil; }
    if (![url isKindOfClass:[NSURL class]]) {
        url = IXStableContainerURL(identifier);
        if (url) NSLog(@"[InstagramX] app group %@ has no container; using %@", identifier, url.path);
    }
    depth--;
    return url;
}
%end

%ctor {
    IXLoadSignedIdentity();
    IXInstallKeychainRewrite();
    IXMigrateAccountFiles();
    %init;
    IXInstallDirectAppGroup();
}
