#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <substrate.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <string.h>

#import "IXSessionPersist.h"

/* Loads before FBSharedFramework. Instagram treats a Sideloadly install as
   brand new when its keychain install marker is missing, then deletes
   preferences and Documents. This image plants a marker in the team
   keychain group and refuses that wipe. It does not look up Instagram
   classes. SCInsta and zxPluginsInject still load after the framework. */

static BOOL (*ix_orig_remove_path)(id, SEL, NSString *, NSError **);
static BOOL (*ix_orig_remove_url)(id, SEL, NSURL *, NSError **);
static void (*ix_orig_remove_domain)(id, SEL, NSString *);
static void (*ix_orig_set_domain)(id, SEL, NSDictionary *, NSString *);
static void (*ix_orig_remove_key)(id, SEL, NSString *);
static void (*ix_orig_reset)(id, SEL);
static int ix_block;
static int ix_logs;

static NSString *IXDocs(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    return docs ?: @"";
}

static void IXLog(NSString *line) {
    NSString *path;
    NSString *dir;
    NSData *data;
    NSFileHandle *handle;
    if (line.length == 0 || line.length > 500) return;
    dir = [IXDocs() stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    path = [dir stringByAppendingPathComponent:@"ix_session_diag.txt"];
    data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static void IXStack(NSString *kind) {
    void *frames[8];
    int count = backtrace(frames, 8);
    int logged = 0;
    for (int i = 0; i < count && logged < 4; i++) {
        Dl_info info;
        const char *image;
        memset(&info, 0, sizeof info);
        if (!dladdr(frames[i], &info) || !info.dli_fname) continue;
        image = strrchr(info.dli_fname, '/');
        image = image ? image + 1 : info.dli_fname;
        if (strcmp(image, "IXInstallGuard.dylib") == 0) continue;
        IXLog([NSString stringWithFormat:@"bt kind=%@ i=%d image=%s symbol=%s",
               kind, logged, image, info.dli_sname ?: "-"]);
        logged++;
    }
}

static void IXWipe(NSString *kind, NSString *detail, int blocked) {
    NSString *tail;
    if (ix_logs >= 24) return;
    ix_logs++;
    tail = detail.length > 120 ? [detail substringFromIndex:detail.length - 120] : (detail ?: @"-");
    IXLog([NSString stringWithFormat:@"wipe_%@ kind=%@ detail=%@", blocked ? @"block" : @"allow", kind, tail]);
    IXStack(blocked ? @"wipe_block" : @"wipe_allow");
}

static NSString *IXMarkerPath(void) {
    char path[1024];
    if (!IXSessionInstallMarkerPath(IXDocs().UTF8String, path, sizeof path)) return nil;
    return [NSString stringWithUTF8String:path];
}

static int IXFileMarker(void) {
    NSString *path = IXMarkerPath();
    return path.length && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static int IXWriteFileMarker(void) {
    NSString *path = IXMarkerPath();
    if (path.length == 0) return 0;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    return [@"1\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] ? 1 : 0;
}

static NSDictionary *IXMarkerQuery(BOOL returning) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"instagramx.install",
        (__bridge id)kSecAttrAccount: @"marker"
    } mutableCopy];
    if (returning) {
        query[(__bridge id)kSecReturnAttributes] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    }
    return query;
}

static NSString *IXReadTeamGroup(int *present) {
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)IXMarkerQuery(YES), &result);
    NSString *group = nil;
    if (present) *present = status == errSecSuccess;
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        id found = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if ([found isKindOfClass:[NSString class]]) group = found;
    }
    if (result) CFRelease(result);
    return group;
}

static NSString *IXWriteTeamGroup(void) {
    NSMutableDictionary *add = [IXMarkerQuery(YES) mutableCopy];
    CFTypeRef result = NULL;
    id group = nil;
    add[(__bridge id)kSecValueData] = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    if (SecItemAdd((__bridge CFDictionaryRef)add, &result) == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        group = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
    }
    if (result) CFRelease(result);
    return [group isKindOfClass:[NSString class]] ? group : nil;
}

static BOOL ix_remove_path(id self, SEL _cmd, NSString *path, NSError **error) {
    if (ix_block && IXSessionStatePath(NSHomeDirectory().UTF8String, path.UTF8String)) {
        IXWipe(@"file", path, 1);
        return YES;
    }
    return ix_orig_remove_path ? ix_orig_remove_path(self, _cmd, path, error) : YES;
}

static BOOL ix_remove_url(id self, SEL _cmd, NSURL *url, NSError **error) {
    if (ix_block && IXSessionStatePath(NSHomeDirectory().UTF8String, url.path.UTF8String)) {
        IXWipe(@"file", url.path, 1);
        return YES;
    }
    return ix_orig_remove_url ? ix_orig_remove_url(self, _cmd, url, error) : YES;
}

static void ix_remove_domain(id self, SEL _cmd, NSString *name) {
    if (ix_block && IXSessionDomainWipe(name.UTF8String, NSBundle.mainBundle.bundleIdentifier.UTF8String)) {
        IXWipe(@"domain", name, 1);
        return;
    }
    if (ix_orig_remove_domain) ix_orig_remove_domain(self, _cmd, name);
}

static void ix_set_domain(id self, SEL _cmd, NSDictionary *domain, NSString *name) {
    if (ix_block && domain.count == 0 && IXSessionDomainWipe(name.UTF8String, NSBundle.mainBundle.bundleIdentifier.UTF8String)) {
        IXWipe(@"domain_empty", name, 1);
        return;
    }
    if (ix_orig_set_domain) ix_orig_set_domain(self, _cmd, domain, name);
}

static void ix_remove_key(id self, SEL _cmd, NSString *key) {
    if (ix_block && IXSessionKeepKey(key.UTF8String)) {
        IXWipe(@"pref", key, 1);
        return;
    }
    if (ix_orig_remove_key) ix_orig_remove_key(self, _cmd, key);
}

static void ix_reset(id self, SEL _cmd) {
    IXWipe(@"reset_defaults", @"standard", ix_block);
    if (ix_block) return;
    if (ix_orig_reset) ix_orig_reset(self, _cmd);
}

static void IXHook(Class cls, SEL sel, IMP repl, IMP *orig) {
    if (!cls || !sel) return;
    MSHookMessageEx(cls, sel, repl, orig);
}

__attribute__((constructor))
static void IXInstallGuardCtor(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"-";
    NSString *home = NSHomeDirectory() ?: @"";
    NSString *tail = home.lastPathComponent.length ? home.lastPathComponent : @"-";
    int fileMarker = IXFileMarker();
    int keychainMarker = 0;
    NSString *group = IXReadTeamGroup(&keychainMarker);
    int first = IXSessionFirstInstall(fileMarker, keychainMarker);
    Class files = objc_getClass("NSFileManager");
    Class defaults = objc_getClass("NSUserDefaults");
    if (!fileMarker) IXWriteFileMarker();
    if (!keychainMarker) {
        NSString *written = IXWriteTeamGroup();
        int again = 0;
        if (written.length) group = written;
        IXReadTeamGroup(&again);
        keychainMarker = again || written.length > 0;
    }
    ix_block = (IXFileMarker() || keychainMarker) ? 1 : 0;
    IXHook(files, @selector(removeItemAtPath:error:), (IMP)ix_remove_path, (IMP *)&ix_orig_remove_path);
    IXHook(files, @selector(removeItemAtURL:error:), (IMP)ix_remove_url, (IMP *)&ix_orig_remove_url);
    IXHook(defaults, @selector(removePersistentDomainForName:), (IMP)ix_remove_domain, (IMP *)&ix_orig_remove_domain);
    IXHook(defaults, @selector(setPersistentDomain:forName:), (IMP)ix_set_domain, (IMP *)&ix_orig_set_domain);
    IXHook(defaults, @selector(removeObjectForKey:), (IMP)ix_remove_key, (IMP *)&ix_orig_remove_key);
    IXHook(object_getClass((id)defaults), @selector(resetStandardUserDefaults), (IMP)ix_reset, (IMP *)&ix_orig_reset);
    IXLog([NSString stringWithFormat:@"identity bundle=%@ container=%@ kc_group=%@ file_marker=%d kc_marker=%d first_install=%d block_wipes=%d",
           bundle.length > 96 ? [bundle substringToIndex:96] : bundle,
           tail.length > 64 ? [tail substringToIndex:64] : tail,
           group.length ? (group.length > 96 ? [group substringToIndex:96] : group) : @"-",
           fileMarker, keychainMarker, first, ix_block]);
}
