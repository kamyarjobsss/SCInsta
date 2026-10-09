#import "IXSessionDiag.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdlib.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

static NSString *ix_container;
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
    if ([lower containsString:@"password"] || [lower containsString:@"token"] || [lower containsString:@"sessionid"]) return;
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
        NSString *line = [NSString stringWithFormat:@"accounts phase=%@ count=%d container=%@ probe=%@ probe_status=%d entitled=%lu",
                          when,
                          count,
                          ix_container.length ? ix_container : @"-",
                          ix_probe.length ? ix_probe : @"default",
                          ix_probe_status,
                          ix_entitled];
        dispatch_async(IXDiagQueue(), ^{
            IXFlushCounts();
            IXDiagWrite(line);
        });
    };
    if (pthread_main_np()) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}
