#import <Foundation/Foundation.h>
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
    if (identifier.length == 0) identifier = @"group.com.burbn.instagram";
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    NSString *leaf = [[identifier componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    NSString *path = [root stringByAppendingPathComponent:leaf];
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
    NSString *identifier = IXGroupIdentifier(IXReadIvar(object, "_identifier") ?: name);
    if (![IXReadIvar(object, "_identifier") isKindOfClass:[NSString class]] || [IXReadIvar(object, "_identifier") length] == 0) {
        IXWriteIvar(object, "_identifier", [identifier copy]);
    }
    identifier = IXReadIvar(object, "_identifier");
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) identifier = IXGroupIdentifier(name);
    if (![IXReadIvar(object, "_userDefaults") isKindOfClass:[NSUserDefaults class]]) {
        IXWriteIvar(object, "_userDefaults", [[NSUserDefaults alloc] initWithSuiteName:identifier]);
    }
    if (![IXReadIvar(object, "_containerURL") isKindOfClass:[NSURL class]]) {
        IXWriteIvar(object, "_containerURL", IXSandboxGroupURL(identifier));
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
static id IXEnsureAppGroup(id cls, id name, id existing) {
    if (IXGroupIsUsable(existing)) return existing;
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
