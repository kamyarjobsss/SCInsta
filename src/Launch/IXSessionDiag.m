#import "IXSessionDiag.h"
#import "IXLaunchGuard.h"
#import "../Backend/IXBackend.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdlib.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

static int IXAuthReady(void);
static int IXHasSessionCookie(void);
static NSString *IXClip(NSString *text, NSUInteger max);

static NSString *ix_container;
static NSArray<NSString *> *ix_signed_groups;
static NSString *ix_probe;
static int ix_probe_status = -1;
static unsigned long ix_entitled;
static dispatch_queue_t ix_diag_queue;
static NSMutableDictionary<NSString *, NSNumber *> *ix_kc_counts;

static dispatch_queue_t IXDiagQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ix_diag_queue = dispatch_queue_create("com.instagramx.sessiondiag", DISPATCH_QUEUE_SERIAL);
        ix_kc_counts = [NSMutableDictionary dictionary];
    });
    return ix_diag_queue;
}

static NSString *IXDiagPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *dir = [docs stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ix_session_diag.txt"];
}

static void IXDiagWrite(NSString *line) {
    if (line.length == 0 || line.length > 500) return;
    NSString *lower = line.lowercaseString;
    if ([lower containsString:@"password"] || [lower containsString:@"sessionid"] || [lower containsString:@"bearer "]) return;
    NSString *path = IXDiagPath();
    if (path.length == 0) return;
    const char *cpath = path.fileSystemRepresentation;
    if (!cpath) return;
    int fd = open(cpath, O_RDWR | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    NSString *row = [line stringByAppendingString:@"\n"];
    NSData *data = [row dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length) {
        const uint8_t *bytes = data.bytes;
        size_t left = data.length;
        while (left) {
            ssize_t n = write(fd, bytes, left);
            if (n <= 0) break;
            bytes += n;
            left -= (size_t)n;
        }
    }
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 262144) {
        size_t keep = 131072;
        if ((size_t)st.st_size < keep) keep = (size_t)st.st_size;
        char *buf = malloc(keep);
        if (buf && lseek(fd, -((off_t)keep), SEEK_END) >= 0) {
            size_t got = 0;
            while (got < keep) {
                ssize_t n = read(fd, buf + got, keep - got);
                if (n <= 0) break;
                got += (size_t)n;
            }
            close(fd);
            fd = open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
            if (fd >= 0 && got) {
                size_t off = 0;
                while (off < got) {
                    ssize_t n = write(fd, buf + off, got - off);
                    if (n < 0) break;
                    off += (size_t)n;
                }
            }
        }
        free(buf);
    }
    if (fd >= 0) close(fd);
}

void IXSessionDiagLine(NSString *line) {
    if (line.length == 0) return;
    NSString *copy = [line copy];
    dispatch_async(IXDiagQueue(), ^{ IXDiagWrite(copy); });
}

void IXSessionDiagContext(NSString *containerPath, NSString *probedGroup, int probeStatus, unsigned long entitledCount) {
    ix_container = [containerPath copy];
    ix_probe = [probedGroup copy];
    ix_probe_status = probeStatus;
    ix_entitled = entitledCount;
    NSString *line = [NSString stringWithFormat:@"context container=%@ probe=%@ probe_status=%d entitled=%lu",
                      containerPath.length ? containerPath : @"-",
                      probedGroup.length ? probedGroup : @"default",
                      probeStatus,
                      entitledCount];
    dispatch_async(IXDiagQueue(), ^{
        static NSString *last;
        if ([line isEqualToString:last]) return;
        last = [line copy];
        IXDiagWrite(line);
    });
}

void IXSessionDiagKeychain(const char *op, int status, NSString *group, int callerSuppliedGroup) {
    NSString *name = op ? [NSString stringWithUTF8String:op] : @"?";
    NSString *used = group.length ? group : @"default";
    used = [[used componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (used.length > 180) used = [used substringToIndex:180];
    NSString *key = [NSString stringWithFormat:@"%@|%d|%@|%d", name, status, used, callerSuppliedGroup ? 1 : 0];
    dispatch_async(IXDiagQueue(), ^{
        NSInteger n = [ix_kc_counts[key] integerValue] + 1;
        ix_kc_counts[key] = @(n);
        if (n == 1 || status != 0) {
            IXDiagWrite([NSString stringWithFormat:@"kc op=%@ status=%d group=%@ caller=%d n=%ld",
                         name, status, used, callerSuppliedGroup ? 1 : 0, (long)n]);
        }
    });
}

static BOOL IXUsernameOK(NSString *name) {
    if (name.length < 1 || name.length > 30) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._"] invertedSet];
    return [name.lowercaseString rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static void IXTakeUsername(NSMutableSet *set, id value) {
    if (![value isKindOfClass:[NSString class]] || set.count >= 50) return;
    NSString *name = [(NSString *)value lowercaseString];
    if (IXUsernameOK(name)) [set addObject:name];
}

static void IXHarvest(id obj, NSMutableSet *set, int depth) {
    if (!obj || depth > 4 || set.count >= 50) return;
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id item in obj) IXHarvest(item, set, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id item in [(NSDictionary *)obj allValues]) IXHarvest(item, set, depth + 1);
        return;
    }
    @try {
        if ([obj respondsToSelector:@selector(username)]) IXTakeUsername(set, [obj valueForKey:@"username"]);
    } @catch (__unused NSException *exception) {}
    if (depth >= 3) return;
    for (NSString *key in @[@"user", @"loggedInUser", @"currentUser", @"accounts", @"loggedInAccounts", @"allAccounts", @"users", @"sessions"]) {
        @try {
            if (![obj respondsToSelector:NSSelectorFromString(key)]) continue;
            IXHarvest([obj valueForKey:key], set, depth + 1);
        } @catch (__unused NSException *exception) {}
    }
}

static int IXAccountCount(void) {
    NSMutableSet *set = [NSMutableSet set];
    Class appCls = objc_getClass("UIApplication");
    id app = nil;
    if (appCls && [appCls respondsToSelector:@selector(sharedApplication)]) {
        @try { app = ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication)); }
        @catch (__unused NSException *exception) { app = nil; }
    }
    NSArray *scenes = nil;
    @try { scenes = [app valueForKey:@"connectedScenes"]; }
    @catch (__unused NSException *exception) { scenes = nil; }
    for (id scene in scenes) {
        NSArray *windows = nil;
        @try { windows = [scene valueForKey:@"windows"]; }
        @catch (__unused NSException *exception) { windows = nil; }
        for (id window in windows) {
            @try { IXHarvest([window valueForKey:@"userSession"], set, 0); }
            @catch (__unused NSException *exception) {}
        }
    }
    for (NSString *className in @[@"IGAccountStore", @"IGUserSessionStore", @"IGAuthService", @"IGAccountSwitcher"]) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) continue;
        for (NSString *selName in @[@"sharedInstance", @"sharedStore", @"shared"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![cls respondsToSelector:sel]) continue;
            @try {
                id obj = ((id (*)(id, SEL))objc_msgSend)(cls, sel);
                IXHarvest(obj, set, 0);
            } @catch (__unused NSException *exception) {}
        }
    }
    return (int)set.count;
}

static void IXFlushCounts(void) {
    if (ix_kc_counts.count == 0) return;
    NSMutableString *line = [NSMutableString stringWithString:@"kc_totals"];
    for (NSString *key in ix_kc_counts) {
        [line appendFormat:@" %@=%@", key, ix_kc_counts[key]];
        if (line.length > 450) break;
    }
    IXDiagWrite(line);
}

void IXSessionDiagAccounts(NSString *phase) {
    NSString *when = phase.length ? [phase copy] : @"?";
    void (^work)(void) = ^{
        int count = IXAccountCount();
        int auth = IXAuthReady();
        int cookie = IXHasSessionCookie();
        NSString *line = [NSString stringWithFormat:@"accounts phase=%@ count=%d auth=%d cookie=%d container=%@ hooks=off",
                          when,
                          count,
                          auth,
                          cookie,
                          ix_container.length ? ix_container : @"-"];
        dispatch_async(IXDiagQueue(), ^{
            IXFlushCounts();
            IXDiagWrite(line);
        });
    };
    if (pthread_main_np()) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static NSString *IXStatePath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *dir = [docs stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"ix_session_state.plist"];
}

static NSMutableDictionary *IXState(void) {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:IXStatePath()];
    return [saved isKindOfClass:[NSDictionary class]] ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static void IXSaveState(NSDictionary *state) {
    if (![state isKindOfClass:[NSDictionary class]]) return;
    [state writeToFile:IXStatePath() atomically:YES];
}

static int IXAuthReady(void) {
    Class appCls = objc_getClass("UIApplication");
    id app = nil;
    if (appCls && [appCls respondsToSelector:@selector(sharedApplication)]) {
        @try { app = ((id (*)(id, SEL))objc_msgSend)(appCls, @selector(sharedApplication)); }
        @catch (__unused NSException *exception) { app = nil; }
    }
    NSArray *scenes = nil;
    @try { scenes = [app valueForKey:@"connectedScenes"]; }
    @catch (__unused NSException *exception) { scenes = nil; }
    for (id scene in scenes) {
        NSArray *windows = nil;
        @try { windows = [scene valueForKey:@"windows"]; }
        @catch (__unused NSException *exception) { windows = nil; }
        for (id window in windows) {
            id session = nil;
            @try { session = [window valueForKey:@"userSession"]; }
            @catch (__unused NSException *exception) { session = nil; }
            if (!session || ![session respondsToSelector:@selector(authHeaderManager)]) continue;
            id manager = nil;
            @try { manager = ((id (*)(id, SEL))objc_msgSend)(session, @selector(authHeaderManager)); }
            @catch (__unused NSException *exception) { manager = nil; }
            if (!manager || ![manager respondsToSelector:@selector(authHeader)]) continue;
            id header = nil;
            @try { header = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(authHeader)); }
            @catch (__unused NSException *exception) { header = nil; }
            if ([header isKindOfClass:[NSString class]] && [(NSString *)header length] > 8) return 1;
        }
    }
    return 0;
}

static int IXHasSessionCookie(void) {
    NSURL *url = [NSURL URLWithString:@"https://i.instagram.com/"];
    if (!url) return 0;
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url]) {
        if ([cookie.name isEqualToString:@"sessionid"] && cookie.value.length > 8) return 1;
    }
    return 0;
}

static NSDictionary *IXProbeBase(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"instagramx.diag",
        (__bridge id)kSecAttrAccount: @"relaunch-probe"
    };
}

static void IXSelfTest(void) {
    NSMutableDictionary *read = [IXProbeBase() mutableCopy];
    read[(__bridge id)kSecReturnAttributes] = @YES;
    read[(__bridge id)kSecReturnData] = @YES;
    read[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSString *group = nil;
    BOOL bytes = NO;
    NSString *accessible = nil;
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        NSDictionary *attrs = (__bridge NSDictionary *)result;
        id found = attrs[(__bridge id)kSecAttrAccessGroup];
        if ([found isKindOfClass:[NSString class]]) group = found;
        id access = attrs[(__bridge id)kSecAttrAccessible];
        if ([access isKindOfClass:[NSString class]]) accessible = access;
        id data = attrs[(__bridge id)kSecValueData];
        bytes = [data isKindOfClass:[NSData class]] && [(NSData *)data length] > 0;
    }
    if (result) CFRelease(result);
    NSMutableDictionary *state = IXState();
    NSString *previous = [state[@"probe_group"] isKindOfClass:[NSString class]] ? state[@"probe_group"] : @"";
    BOOL groupChanged = previous.length && group.length && ![previous isEqualToString:group];
    IXSessionDiagLine([NSString stringWithFormat:@"kc op=probe_read status=%d group=%@ count=%d bytes=%d accessible=%@ group_changed=%@",
                       (int)status,
                       IXClip(group, 80),
                       status == errSecSuccess ? 1 : 0,
                       bytes ? 1 : 0,
                       IXClip(accessible, 48),
                       groupChanged ? @"yes" : @"no"]);
    NSData *stamp = [@"1" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *update = @{ (__bridge id)kSecValueData: stamp };
    OSStatus wrote = SecItemUpdate((__bridge CFDictionaryRef)IXProbeBase(), (__bridge CFDictionaryRef)update);
    if (wrote == errSecItemNotFound) {
        NSMutableDictionary *add = [IXProbeBase() mutableCopy];
        add[(__bridge id)kSecValueData] = stamp;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        wrote = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    IXSessionDiagLine([NSString stringWithFormat:@"kc op=probe_write status=%d group=%@ count=1",
                       (int)wrote, IXClip(group, 80)]);
    if (group.length) state[@"probe_group"] = group;
    state[@"probe_read"] = [NSString stringWithFormat:@"%d", (int)status];
    state[@"probe_write"] = [NSString stringWithFormat:@"%d", (int)wrote];
    state[@"probe_bytes"] = bytes ? @"yes" : @"no";
    state[@"probe_group_changed"] = groupChanged ? @"yes" : @"no";
    IXSaveState(state);
    ix_probe = [group copy];
    ix_probe_status = (int)status;
}

static NSString *IXClip(NSString *text, NSUInteger max) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @"-";
    NSString *flat = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    if (flat.length > max) flat = [flat substringToIndex:max];
    return flat;
}

static NSString *IXEntList(CFTypeRef value, int *countOut) {
    if (countOut) *countOut = -1;
    if (!value || CFGetTypeID(value) != CFArrayGetTypeID()) return @"-";
    CFIndex n = CFArrayGetCount((CFArrayRef)value);
    if (countOut) *countOut = (int)n;
    NSMutableArray *parts = [NSMutableArray array];
    for (CFIndex i = 0; i < n && parts.count < 4; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)value, i);
        if (!item || CFGetTypeID(item) != CFStringGetTypeID()) continue;
        [parts addObject:IXClip((__bridge NSString *)item, 48)];
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"-";
}

static void IXEntitlementSummary(void) {
    typedef struct __SecTask *IXSecTaskRef;
    typedef IXSecTaskRef (*IXCreate)(CFAllocatorRef);
    typedef CFTypeRef (*IXCopy)(IXSecTaskRef, CFStringRef, CFErrorRef *);
    IXCreate createFn = (IXCreate)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    IXCopy copyFn = (IXCopy)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    int keychainCount = -1;
    int appGroupCount = -1;
    NSString *keychainList = @"-";
    NSString *appList = @"-";
    NSMutableArray<NSString *> *signedGroups = [NSMutableArray array];
    if (createFn && copyFn) {
        IXSecTaskRef task = createFn(NULL);
        if (task) {
            CFTypeRef groups = copyFn(task, CFSTR("keychain-access-groups"), NULL);
            keychainList = IXEntList(groups, &keychainCount);
            if (groups && CFGetTypeID(groups) == CFArrayGetTypeID()) {
                CFIndex n = CFArrayGetCount((CFArrayRef)groups);
                for (CFIndex i = 0; i < n && signedGroups.count < 4; i++) {
                    CFTypeRef item = CFArrayGetValueAtIndex((CFArrayRef)groups, i);
                    if (!item || CFGetTypeID(item) != CFStringGetTypeID()) continue;
                    [signedGroups addObject:[(__bridge NSString *)item copy]];
                }
            }
            if (groups) CFRelease(groups);
            CFTypeRef apps = copyFn(task, CFSTR("com.apple.security.application-groups"), NULL);
            appList = IXEntList(apps, &appGroupCount);
            if (apps) CFRelease(apps);
            CFRelease((CFTypeRef)task);
        }
    }
    ix_signed_groups = [signedGroups copy];
    ix_entitled = keychainCount > 0 ? (unsigned long)keychainCount : 0;
    IXSessionDiagLine([NSString stringWithFormat:@"entitlements keychain_groups=%d [%@] app_groups=%d [%@] secitem_hooks=off",
                       keychainCount, keychainList, appGroupCount, appList]);
}

static void IXFreshMarker(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"InstagramX"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *marker = [dir stringByAppendingPathComponent:@"ix_seen_launch.txt"];
    BOOL seen = [[NSFileManager defaultManager] fileExistsAtPath:marker];
    IXSessionDiagLine([NSString stringWithFormat:@"ix_seen_launch=%@", seen ? @"existing" : @"new"]);
    NSMutableDictionary *state = IXState();
    state[@"ix_seen_launch"] = seen ? @"existing" : @"new";
    IXSaveState(state);
    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static int IXResultCount(CFTypeRef result, int status) {
    if (status == errSecItemNotFound) return 0;
    if (status != errSecSuccess || !result) return -1;
    if (CFGetTypeID(result) == CFArrayGetTypeID()) return (int)CFArrayGetCount((CFArrayRef)result);
    return 1;
}

static void IXLogGroups(NSString *op, int status, CFTypeRef result) {
    int total = IXResultCount(result, status);
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFArrayGetTypeID()) {
        CFArrayRef items = (CFArrayRef)result;
        CFIndex n = CFArrayGetCount(items);
        for (CFIndex i = 0; i < n && i < 200; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(items, i);
            NSString *group = @"-";
            if (item && CFGetTypeID(item) == CFDictionaryGetTypeID()) {
                id found = ((__bridge NSDictionary *)item)[(__bridge id)kSecAttrAccessGroup];
                if ([found isKindOfClass:[NSString class]] && [(NSString *)found length]) group = found;
            }
            counts[group] = @([counts[group] integerValue] + 1);
        }
    }
    if (counts.count == 0) {
        IXSessionDiagLine([NSString stringWithFormat:@"kc op=%@ status=%d group=- count=%d", op, status, total]);
        return;
    }
    NSInteger logged = 0;
    for (NSString *group in counts) {
        if (logged >= 6) break;
        logged++;
        IXSessionDiagLine([NSString stringWithFormat:@"kc op=%@ status=%d group=%@ count=%@",
                           op, status, IXClip(group, 80), counts[group]]);
    }
}

static CFTypeRef IXCopyGeneric(NSDictionary *extra, BOOL returnData, int *statusOut) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES
    } mutableCopy];
    if (returnData) query[(__bridge id)kSecReturnData] = @YES;
    if (extra.count) [query addEntriesFromDictionary:extra];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (statusOut) *statusOut = (int)status;
    return result;
}

static void IXKeychainCensus(void) {
    int status = 0;
    CFTypeRef result = IXCopyGeneric(nil, NO, &status);
    int count = IXResultCount(result, status);
    IXLogGroups(@"copy_attr", status, result);
    if (result) CFRelease(result);
    if (count >= 0 && count <= 80) {
        int dataStatus = 0;
        CFTypeRef dataResult = IXCopyGeneric(nil, YES, &dataStatus);
        IXLogGroups(@"copy_data", dataStatus, dataResult);
        if (dataResult) CFRelease(dataResult);
    } else {
        IXSessionDiagLine([NSString stringWithFormat:@"kc op=copy_data status=skipped group=- count=%d", count]);
    }
    int syncStatus = 0;
    CFTypeRef syncResult = IXCopyGeneric(@{ (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny }, NO, &syncStatus);
    IXLogGroups(@"copy_sync", syncStatus, syncResult);
    if (syncResult) CFRelease(syncResult);
    typedef OSStatus (*IXCopyMatching)(CFDictionaryRef, CFTypeRef *);
    IXCopyMatching realCopy = (IXCopyMatching)dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    if (!realCopy) {
        IXSessionDiagLine(@"kc op=direct_copy status=missing group=- count=-1");
        return;
    }
    NSDictionary *direct = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES
    };
    CFTypeRef directResult = NULL;
    OSStatus directStatus = realCopy((__bridge CFDictionaryRef)direct, &directResult);
    IXLogGroups(@"direct_copy", (int)directStatus, directResult);
    if (directResult) CFRelease(directResult);
    for (NSString *group in ix_signed_groups) {
        if (![group isKindOfClass:[NSString class]] || group.length == 0) continue;
        NSMutableDictionary *perGroup = [direct mutableCopy];
        perGroup[(__bridge id)kSecAttrAccessGroup] = group;
        CFTypeRef perResult = NULL;
        OSStatus perStatus = realCopy((__bridge CFDictionaryRef)perGroup, &perResult);
        if (perStatus != errSecSuccess) {
            IXSessionDiagLine([NSString stringWithFormat:@"kc op=direct_group status=%d group=%@ count=%d",
                               (int)perStatus, IXClip(group, 80), IXResultCount(perResult, (int)perStatus)]);
        } else {
            IXLogGroups(@"direct_group", (int)perStatus, perResult);
        }
        if (perResult) CFRelease(perResult);
    }
}

static void IXFreshSignals(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory() ?: @"";
    int prefs = [fm fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Preferences/com.burbn.instagram.plist"]] ? 1 : 0;
    int cookies = [fm fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"]] ? 1 : 0;
    int groupPrefs = 0;
    if (ix_container.length) {
        groupPrefs = [fm fileExistsAtPath:[ix_container stringByAppendingPathComponent:@"Library/Preferences/group.com.burbn.instagram.plist"]] ? 1 : 0;
    }
    NSArray *needles = @[@"firstlaunch", @"first_launch", @"haslaunched", @"installtime", @"installationid", @"freshinstall"];
    NSMutableArray *hits = [NSMutableArray array];
    NSDictionary *rep = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    for (id key in rep) {
        if (hits.count >= 6 || ![key isKindOfClass:[NSString class]]) continue;
        NSString *name = (NSString *)key;
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"password"] || [lower containsString:@"token"] || [lower containsString:@"session"]) continue;
        BOOL match = NO;
        for (NSString *needle in needles) {
            if ([lower containsString:needle]) { match = YES; break; }
        }
        if (!match) continue;
        [hits addObject:IXClip(name, 48)];
    }
    int safe = 0;
    @try { safe = IXLaunchGuardIsSafeMode() ? 1 : 0; }
    @catch (__unused NSException *exception) { safe = 0; }
    NSString *names = hits.count ? [hits componentsJoinedByString:@","] : @"-";
    IXSessionDiagLine([NSString stringWithFormat:@"fresh_flags prefs=%d cookies=%d group_prefs=%d safe_mode=%d names=%@",
                       prefs, cookies, groupPrefs, safe, names]);
    IXSessionDiagLine([NSString stringWithFormat:@"home=%@", IXClip(home, 220)]);
    NSMutableDictionary *state = IXState();
    state[@"safe_mode"] = safe ? @"yes" : @"no";
    state[@"ig_prefs"] = prefs ? @"yes" : @"no";
    state[@"cookie_file"] = cookies ? @"yes" : @"no";
    state[@"group_prefs"] = groupPrefs ? @"yes" : @"no";
    state[@"fresh_names"] = names;
    IXSaveState(state);
}

void IXSessionDiagNoteContainer(NSString *path, NSString *source) {
    if (path.length == 0) return;
    @synchronized(IXDiagQueue()) {
        NSString *src = source.length ? source : @"?";
        NSString *key = [NSString stringWithFormat:@"%@|%@", src, path];
        static NSString *last;
        if ([key isEqualToString:last]) return;
        last = [key copy];
        ix_container = [path copy];
        NSMutableDictionary *state = IXState();
        NSString *previous = [state[@"container"] isKindOfClass:[NSString class]] ? state[@"container"] : @"";
        BOOL changed = previous.length && ![previous isEqualToString:path];
        state[@"container"] = path;
        state[@"container_source"] = src;
        state[@"path_changed"] = changed ? @"yes" : @"no";
        IXSaveState(state);
        IXSessionDiagLine([NSString stringWithFormat:@"container source=%@ path_changed=%@ path=%@",
                           src, changed ? @"yes" : @"no", IXClip(path, 220)]);
    }
}

void IXSessionDiagBoot(void) {
    static int once = 0;
    if (once) return;
    once = 1;
    IXSessionDiagLine(@"boot secitem_hooks=off");
    IXPrefsSeedFreshMarkers();
    IXEntitlementSummary();
    IXFreshMarker();
    IXSelfTest();
    IXKeychainCensus();
    @try {
        NSURL *url = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.burbn.instagram"];
        if (![url isKindOfClass:[NSURL class]]) IXSessionDiagNoteContainer(@"-", @"missing");
    } @catch (__unused NSException *exception) {
        IXSessionDiagNoteContainer(@"-", @"error");
    }
    IXFreshSignals();
}

NSString *IXSessionDiagReport(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"Instagram X session diagnostics\n"];
    [text appendString:@"secitem_hooks=off\n"];
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:IXStatePath()];
    if ([state isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"ix_seen_launch", @"fresh_names", @"path_changed", @"container_source", @"container", @"safe_mode", @"ig_prefs", @"cookie_file", @"group_prefs", @"probe_read", @"probe_write", @"probe_bytes", @"probe_group", @"probe_group_changed"]) {
            id value = state[key];
            if (value) [text appendFormat:@"%@=%@\n", key, value];
        }
    }
    NSString *panel = IXBackendPanelReport();
    if (panel.length) {
        [text appendString:@"\n"];
        [text appendString:panel];
    }
    NSString *body = [NSString stringWithContentsOfFile:IXDiagPath() encoding:NSUTF8StringEncoding error:nil];
    if (body.length > 60000) body = [body substringFromIndex:body.length - 60000];
    if (body.length) {
        [text appendString:@"\n"];
        [text appendString:body];
    }
    return text;
}

void IXSessionDiagPresentCopy(void) {
    NSString *text = IXSessionDiagReport();
    [UIPasteboard generalPasteboard].string = text ?: @"";
    void (^show)(void) = ^{
        UIViewController *top = nil;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window.isKeyWindow) continue;
            top = window.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;
        }
        if (!top) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:SCILocalized(@"Diagnostics")
                                                                       message:SCILocalized(@"Session diagnostics are on the clipboard.")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:SCILocalized(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    };
    if (pthread_main_np()) show();
    else dispatch_async(dispatch_get_main_queue(), show);
}
