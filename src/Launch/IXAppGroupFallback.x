#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"
#import "IXSessionDiag.h"
#import "IXSessionPersist.h"

// v2.4.0 and v2.4.1 hooked SecItemAdd/Copy/Update/Delete and forced an access
// group. That bypasses zxPluginsInject, which is what keeps sessions in the
// healthy sideload. A query written with one group was not found on the next
// launch, so Instagram still had the saved accounts and asked for the password.
// Those hooks are gone. Keychain items are left to the system and to zx.
//
// This file only fills a missing app-group container. A URL the system or zx
// already returned is not replaced, because a different directory each launch
// looks like a fresh install and Instagram then drops the session.

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

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    static __thread int depth = 0;
    if (depth > 0) return nil;
    depth++;
    NSURL *url = nil;
    @try { url = %orig; }
    @catch (__unused NSException *exception) { url = nil; }
    depth--;
    if ([url isKindOfClass:[NSURL class]] && url.path.length) {
        IXSessionDiagNoteContainer(url.path, @"system");
        return url;
    }
    BOOL existed = NO;
    NSURL *fallback = IXFallbackContainer(identifier, &existed);
    if (fallback.path.length) IXMigrateIntoFallback(fallback.path);
    IXSessionDiagNoteContainer(fallback.path, existed ? @"fallback-existing" : @"fallback-new");
    return fallback;
}
%end

%ctor {
    %init;
    IXInstallDirectAppGroup();
}
