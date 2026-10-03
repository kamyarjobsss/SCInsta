#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"

// Instagram 436 calls +[METAAppGroup appGroupForGroupName:] as an objc_direct
// import (no _cmd). The crashing site (VA 0x10941c448) is:
//   x0 = METAAppGroup class, x1 = group name, then
//   objc_claimAutoreleasedReturnValue, then the direct userDefaults getter,
//   which is `ldr x0, [x0, #0x10]`. identifier is [x0, #8], containerURL is
//   [x0, #0x18], and keychainAccessAppGroup autoreleases the identifier ivar.
// v2.1.1 declared the replacement as (id, SEL, id), so ARC retained the
// garbage third register and SIGSEGV'd on the jobs queue.
// A sideloaded app also has no group.com.burbn.instagram container, and the
// direct-message loader aborts when identifier comes back nil.

static NSURL *IXSandboxGroupURL(NSString *identifier) {
    (void)identifier;
    // One directory for every launch. A path that includes the access-group
    // string changes when that string changes, and the session files move with it.
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup"];
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    [lock unlock];
    if (error || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static NSString *IXGroupIdentifier(id name) {
    if ([name isKindOfClass:[NSString class]] && [name length]) return name;
    return @"group.com.burbn.instagram";
}

// Sideload entitlements do not contain the App Store group name. SecItem's
// default access group is the team-prefixed one. keychainAccessAppGroup
// returns the identifier ivar, so that ivar has to be this group or the
// session written at login cannot be read on the next launch.
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
    if (found.length) NSLog(@"[InstagramX] keychain access group %@", found);
    else NSLog(@"[InstagramX] keychain access group probe failed (%d)", (int)status);
    return found;
}

static NSString *IXPersistentSuiteName(void) {
    // Preferences file inside the app container. Independent of the keychain
    // access group, and the same suite 2.1.3 already wrote.
    return @"group.com.burbn.instagram";
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
    // A non-nil identifier is Instagram's own. Replacing it makes the next
    // launch miss the session and fall through to saved-login one-tap.
    if (![identifier isKindOfClass:[NSString class]] || [identifier length] == 0) return NO;
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) return NO;
    if (![IXReadIvar(object, "_containerURL") isKindOfClass:[NSURL class]]) return NO;
    return YES;
}

static void IXFillAppGroup(id object, id name) {
    id current = IXReadIvar(object, "_identifier");
    if (![current isKindOfClass:[NSString class]] || [current length] == 0) {
        NSString *real = IXRealKeychainAccessGroup();
        NSString *identifier = real.length ? real : IXGroupIdentifier(name);
        IXWriteIvar(object, "_identifier", identifier);
    }
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) {
        IXWriteIvar(object, "_userDefaults", [[NSUserDefaults alloc] initWithSuiteName:IXPersistentSuiteName()]);
    }
    if (![IXReadIvar(object, "_containerURL") isKindOfClass:[NSURL class]]) {
        IXWriteIvar(object, "_containerURL", IXSandboxGroupURL(nil));
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

// `existing` is the original function's return value, already retained by ARC.
// A non-nil identifier means Instagram already built the object. Leave it,
// including its defaults and container. Only a nil identifier is filled.
static id IXEnsureAppGroup(id cls, id name, id existing) {
    id identifier = IXReadIvar(existing, "_identifier");
    if ([identifier isKindOfClass:[NSString class]] && [identifier length] > 0) return existing;
    if (existing) {
        IXFillAppGroup(existing, name);
        if (IXGroupIsUsable(existing)) return existing;
    }
    id made = IXMakeAppGroup((Class)cls, name);
    return IXGroupIsUsable(made) ? made : (made ?: existing);
}

static id (*ix_origAppGroup)(id cls, id name);

// objc_direct class method: x0 is the Class, x1 is the group name. There is no _cmd.
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
    NSString *real = IXRealKeychainAccessGroup();
    if (real.length) return real;
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
        url = IXSandboxGroupURL(identifier);
        if (url) {
            NSLog(@"[InstagramX] app group %@ has no container; using %@", identifier, url.path);
        }
    }
    depth--;
    return url;
}
%end

%ctor {
    %init;
    IXInstallDirectAppGroup();
}
