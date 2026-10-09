#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"

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
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:IXDefaultsSuite()];
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

%ctor {
    %init;
    IXInstallDirectAppGroup();
}
