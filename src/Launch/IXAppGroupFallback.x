#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#import "../Proxy/IXSymbolRebind.h"

// Instagram 436 aborts (SIGABRT) after login inside
// -[IGDirectMDCoreSyncAccountSessionHolder _completeLoadWithAuthData:andCompletion:]
// when +[METAAppGroup appGroupForGroupName:] has a nil identifier. A sideloaded
// bundle does not own group.com.burbn.instagram, and that loader treats the
// missing container as fatal. Point the group at a directory in this app's
// sandbox so the same load can finish.

@interface IXAppGroupStandIn : NSObject
+ (instancetype)standInForName:(NSString *)name;
- (NSString *)identifier;
- (NSString *)groupName;
@end

@implementation IXAppGroupStandIn {
    NSString *_name;
}
+ (instancetype)standInForName:(NSString *)name {
    IXAppGroupStandIn *object = [IXAppGroupStandIn new];
    object->_name = name.length ? [name copy] : @"group.com.burbn.instagram";
    return object;
}
- (NSString *)identifier { return _name; }
- (NSString *)groupName { return _name; }
@end

static NSURL *IXSandboxGroupURL(NSString *identifier) {
    if (identifier.length == 0) identifier = @"group.com.burbn.instagram";
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"/:\\"];
    NSString *leaf = [[identifier componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/IXAppGroups"];
    NSString *path = [root stringByAppendingPathComponent:leaf];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) return nil;
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

static NSString *IXGroupName(id object) {
    if (!object) return nil;
    @try {
        if ([object respondsToSelector:@selector(groupName)]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, @selector(groupName));
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

%hook METAAppGroup
+ (id)appGroupForGroupName:(NSString *)name {
    id object = nil;
    @try { object = %orig; }
    @catch (__unused NSException *exception) { object = nil; }
    if (object) return object;
    return [IXAppGroupStandIn standInForName:name];
}
- (NSString *)identifier {
    NSString *value = nil;
    @try { value = %orig; }
    @catch (__unused NSException *exception) { value = nil; }
    if ([value isKindOfClass:[NSString class]] && value.length) return value;
    NSString *name = IXGroupName(self);
    return name.length ? name : @"group.com.burbn.instagram";
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

static id (*ix_origIdentifier)(id, SEL);
static id (*ix_origAppGroup)(id, SEL, id);

static id ix_directIdentifier(id self, SEL cmd) {
    id value = nil;
    @try {
        if (ix_origIdentifier) value = ix_origIdentifier(self, cmd);
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    NSString *name = IXGroupName(self);
    return name.length ? name : @"group.com.burbn.instagram";
}

static id ix_directAppGroup(id self, SEL cmd, id name) {
    id object = nil;
    @try {
        if (ix_origAppGroup) object = ix_origAppGroup(self, cmd, name);
    } @catch (__unused NSException *exception) {
        object = nil;
    }
    if (object) return object;
    return [IXAppGroupStandIn standInForName:[name isKindOfClass:[NSString class]] ? name : nil];
}

static void IXInstallDirectAppGroup(void) {
    // Instagram calls these as imported functions, not objc_msgSend, then abort()s
    // when the identifier is nil. A method hook never sees that call.
    union { id (*fn)(id, SEL); void *ptr; } identBits;
    identBits.ptr = dlsym(RTLD_DEFAULT, "-<METAAppGroup identifier>");
    ix_origIdentifier = identBits.fn;
    union { id (*fn)(id, SEL, id); void *ptr; } groupBits;
    groupBits.ptr = dlsym(RTLD_DEFAULT, "+<METAAppGroup appGroupForGroupName:>");
    ix_origAppGroup = groupBits.fn;
    const char *names[2];
    void *replacements[2];
    unsigned count = 0;
    if (ix_origIdentifier) {
        union { id (*fn)(id, SEL); void *ptr; } bits = { ix_directIdentifier };
        names[count] = "-<METAAppGroup identifier>";
        replacements[count] = bits.ptr;
        count++;
    }
    if (ix_origAppGroup) {
        union { id (*fn)(id, SEL, id); void *ptr; } bits = { ix_directAppGroup };
        names[count] = "+<METAAppGroup appGroupForGroupName:>";
        replacements[count] = bits.ptr;
        count++;
    }
    if (!count) {
        NSLog(@"[InstagramX] app group symbols were not found; the direct abort path is unchanged");
        return;
    }
    int slots = IXSymbolRebindPermanent(names, replacements, count);
    NSLog(@"[InstagramX] app group direct calls rebound (%d slots)", slots);
}

%ctor {
    %init;
    IXInstallDirectAppGroup();
}
