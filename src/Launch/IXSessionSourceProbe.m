#import "IXSessionSource.h"
#import "IXSessionPersist.h"
#import "IXSessionDiag.h"

#import <Security/Security.h>
#import <dlfcn.h>
#import <string.h>

/* Records which session stores exist. It does not create group containers,
   write preference keys, or read cookie and keychain values. */

static int ix_source_lines;

static void IXEmit(const char *phase, const char *kind, const char *name, int present, unsigned long long bytes, const char *detail) {
    char line[384];
    if (ix_source_lines >= 180) {
        if (ix_source_lines == 180) {
            ix_source_lines++;
            IXSessionDiagLine(@"source phase=cap kind=truncated name=log present=1 bytes=180 detail=cap");
        }
        return;
    }
    if (!IXSessionSourceLine(phase, kind, name, present ? 1 : 0, bytes, detail, line, sizeof line)) return;
    ix_source_lines++;
    IXSessionDiagLine([NSString stringWithUTF8String:line]);
}

static NSString *IXHome(void) {
    NSString *home = NSHomeDirectory();
    return [home isKindOfClass:[NSString class]] ? home : @"";
}

static NSString *IXDocs(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    if (docs.length == 0) docs = [IXHome() stringByAppendingPathComponent:@"Documents"];
    return docs ?: @"";
}

static unsigned long long IXBytes(NSString *path, int *exists) {
    NSDictionary *attr;
    NSNumber *size;
    if (exists) *exists = 0;
    if (path.length == 0) return 0;
    attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (![attr isKindOfClass:[NSDictionary class]]) return 0;
    if (exists) *exists = 1;
    size = attr[NSFileSize];
    return [size isKindOfClass:[NSNumber class]] ? size.unsignedLongLongValue : 0;
}

static unsigned long long IXEntries(NSString *path) {
    NSArray *items;
    if (path.length == 0) return 0;
    items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
    return [items isKindOfClass:[NSArray class]] ? (unsigned long long)items.count : 0;
}

static NSString *IXShortGroup(int index) {
    if (index == 0) return @"ig";
    if (index == 1) return @"family";
    return @"burbn";
}

static void IXNoteFile(const char *phase, const char *kind, const char *name, NSString *path, const char *detail) {
    int exists = 0;
    unsigned long long bytes = IXBytes(path, &exists);
    IXEmit(phase, kind, name, exists, bytes, detail);
}

static void IXNotePref(const char *phase, NSString *logName, id value, const char *where) {
    char detail[64];
    const char *state = "absent";
    int present = 0;
    if ([value isKindOfClass:[NSString class]]) {
        if ([(NSString *)value length] > 0) {
            state = "set";
            present = 1;
        } else {
            state = "len0";
        }
    } else if (value) {
        state = "set";
        present = 1;
    }
    snprintf(detail, sizeof detail, "%s.%s", state, where);
    IXEmit(phase, "pref", logName.UTF8String, present, 0, detail);
}

static void IXNotePlistKeys(const char *phase, NSString *path, const char *where) {
    NSDictionary *dict;
    int exists = 0;
    IXBytes(path, &exists);
    if (!exists) return;
    dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dict isKindOfClass:[NSDictionary class]]) dict = @{};
    IXNotePref(phase, @"user_id", dict[@"logged_in_user_id"], where);
    IXNotePref(phase, @"fresh_time", dict[@"mc_freshinstall_time"], where);
}

static void IXNoteArchives(const char *phase, NSString *dir, const char *detail, int depth) {
    NSArray *items;
    int seen = 0;
    char logName[64];
    if (depth > 3 || dir.length == 0) return;
    items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (![items isKindOfClass:[NSArray class]]) return;
    for (NSString *name in items) {
        NSString *child;
        BOOL isDir = NO;
        if (seen++ > 200) break;
        if (![name isKindOfClass:[NSString class]]) continue;
        child = [dir stringByAppendingPathComponent:name];
        if (IXSessionArchiveLogName(name.UTF8String, logName, sizeof logName)) IXNoteFile(phase, "archive", logName, child, detail);
        if (depth < 3 && IXSessionScanDirectory(name.UTF8String) &&
            [[NSFileManager defaultManager] fileExistsAtPath:child isDirectory:&isDir] && isDir) {
            IXNoteArchives(phase, child, detail, depth + 1);
        }
    }
}

static int IXJarHas(NSHTTPCookieStorage *jar, NSString *name) {
    if (![jar isKindOfClass:[NSHTTPCookieStorage class]] || name.length == 0) return 0;
    @try {
        for (NSHTTPCookie *cookie in jar.cookies) {
            if ([cookie.name isEqualToString:name]) return 1;
        }
    } @catch (__unused NSException *exception) {
        return 0;
    }
    return 0;
}

static void IXNoteJar(const char *phase, NSHTTPCookieStorage *jar, const char *detail) {
    static const char *kNames[] = {"sessionid", "ds_user_id", "csrftoken", "mid", "rur"};
    int i;
    for (i = 0; i < 5; i++) {
        char log[32];
        if (!IXSessionCookieLogName(kNames[i], log, sizeof log)) continue;
        IXEmit(phase, "cookie", log, IXJarHas(jar, [NSString stringWithUTF8String:kNames[i]]), 0, detail);
    }
}

static void IXNoteContainers(const char *phase) {
    NSString *docs = IXDocs();
    int i;
    for (i = 0; i < 3; i++) {
        const char *ident = IXSessionGroupIdentifier(i);
        NSString *name;
        NSURL *url = nil;
        BOOL dir = NO;
        NSString *sandbox;
        if (!ident) continue;
        name = [NSString stringWithUTF8String:ident];
        @try { url = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:name]; }
        @catch (__unused NSException *exception) { url = nil; }
        if ([url isKindOfClass:[NSURL class]] && url.path.length) {
            unsigned long long entries = 0;
            if ([[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&dir] && dir) entries = IXEntries(url.path);
            IXEmit(phase, "container", ident, 1, entries, IXSessionPathClassName(IXSessionPathClass(url.path.UTF8String)));
        } else {
            IXEmit(phase, "container", ident, 0, 0, "missing");
        }
        sandbox = [docs stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sandbox isDirectory:&dir] && dir) {
            IXEmit(phase, "sandbox", ident, 1, IXEntries(sandbox), "documents");
        } else {
            IXEmit(phase, "sandbox", ident, 0, 0, "missing");
        }
    }
}

static void IXNoteSuites(const char *phase) {
    NSString *home = IXHome();
    NSString *docs = IXDocs();
    NSString *support = [home stringByAppendingPathComponent:@"Library/Application Support/IXAppGroup/Library/Preferences"];
    int i;
    for (i = 0; i < 3; i++) {
        const char *ident = IXSessionGroupIdentifier(i);
        NSString *name;
        NSString *plist;
        NSString *shortName;
        char where[32];
        if (!ident) continue;
        name = [NSString stringWithUTF8String:ident];
        shortName = IXShortGroup(i);
        plist = [NSString stringWithFormat:@"%@.plist", name];
        IXNoteFile(phase, "suite", ident, [[home stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:plist], "home");
        IXNoteFile(phase, "suite", ident, [[[docs stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:plist], "docs");
        IXNoteFile(phase, "suite", ident, [support stringByAppendingPathComponent:plist], "ixapp");
        snprintf(where, sizeof where, "%s_home", shortName.UTF8String);
        IXNotePlistKeys(phase, [[home stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:plist], where);
        snprintf(where, sizeof where, "%s_docs", shortName.UTF8String);
        IXNotePlistKeys(phase, [[[docs stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:plist], where);
    }
    for (NSString *dir in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil]) {
        NSString *plist;
        if (![dir isKindOfClass:[NSString class]] || ![dir hasPrefix:@"group."]) continue;
        if (!IXSessionPersistSuite(dir.UTF8String)) continue;
        plist = [[[docs stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", dir]];
        IXNoteFile(phase, "suite", dir.UTF8String, plist, "docs");
    }
}

static void IXNoteCookies(const char *phase) {
    NSString *home = IXHome();
    NSString *docs = IXDocs();
    NSHTTPCookieStorage *shared = nil;
    int i;
    IXNoteFile(phase, "cookie_file", "Cookies.binarycookies", [home stringByAppendingPathComponent:@"Library/Cookies/Cookies.binarycookies"], "home");
    for (i = 0; i < 3; i++) {
        const char *ident = IXSessionGroupIdentifier(i);
        NSString *name;
        if (!ident) continue;
        name = [NSString stringWithUTF8String:ident];
        IXNoteFile(phase, "cookie_file", "Cookies.binarycookies",
                   [[[docs stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Library/Cookies"] stringByAppendingPathComponent:@"Cookies.binarycookies"],
                   IXShortGroup(i).UTF8String);
    }
    @try { shared = [NSHTTPCookieStorage sharedHTTPCookieStorage]; }
    @catch (__unused NSException *exception) { shared = nil; }
    IXNoteJar(phase, shared, "shared");
    for (i = 0; i < 3; i++) {
        const char *ident = IXSessionGroupIdentifier(i);
        NSHTTPCookieStorage *group = nil;
        NSString *name;
        char detail[32];
        if (!ident) continue;
        name = [NSString stringWithUTF8String:ident];
        @try { group = [NSHTTPCookieStorage sharedCookieStorageForGroupContainerIdentifier:name]; }
        @catch (__unused NSException *exception) { group = nil; }
        snprintf(detail, sizeof detail, "%s_%s", IXShortGroup(i).UTF8String, group == shared ? "same" : "distinct");
        IXEmit(phase, "cookie_store", ident, group != nil, 0, detail);
        if (group && group != shared) IXNoteJar(phase, group, IXShortGroup(i).UTF8String);
    }
}

static void IXNoteStandard(const char *phase) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"com.burbn.instagram";
    NSString *domain = [[IXHome() stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:[bundle stringByAppendingString:@".plist"]];
    @try {
        IXNotePref(phase, @"user_id", [defaults objectForKey:@"logged_in_user_id"], "standard");
        IXNotePref(phase, @"user_obj", [defaults objectForKey:@"logged_in_user"], "standard");
        IXNotePref(phase, @"user_ids", [defaults objectForKey:@"logged_in_user_ids"], "standard");
        IXNotePref(phase, @"fresh_time", [defaults objectForKey:@"mc_freshinstall_time"], "standard");
    } @catch (__unused NSException *exception) {}
    IXNotePlistKeys(phase, domain, "domain");
    IXNotePref(phase, @"user_obj", [NSDictionary dictionaryWithContentsOfFile:domain][@"logged_in_user"], "domain");
}

void IXSessionSourceProbeFiles(const char *phase) {
    static int ctorDone = 0;
    if (!phase || !phase[0]) return;
    if (strcmp(phase, "ctor") == 0) {
        if (ctorDone) return;
        ctorDone = 1;
    }
    @try {
        IXNoteContainers(phase);
        IXNoteSuites(phase);
        IXNoteCookies(phase);
        IXNoteStandard(phase);
        IXNoteArchives(phase, IXDocs(), "docs", 0);
        IXNoteArchives(phase, [IXHome() stringByAppendingPathComponent:@"Library"], "library", 0);
    } @catch (__unused NSException *exception) {
        IXEmit(phase, "probe", "files", 0, 0, "threw");
    }
}

typedef OSStatus (*IXSecCopyFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*IXSecAddFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*IXSecDeleteFn)(CFDictionaryRef);

static IXSecCopyFn IXRawCopy(void) {
    return (IXSecCopyFn)dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
}

static NSString *IXEntitledGroup(int *statusOut) {
    IXSecCopyFn copy = IXRawCopy();
    IXSecAddFn add = (IXSecAddFn)dlsym(RTLD_DEFAULT, "SecItemAdd");
    IXSecDeleteFn del = (IXSecDeleteFn)dlsym(RTLD_DEFAULT, "SecItemDelete");
    NSDictionary *base;
    NSMutableDictionary *query;
    CFTypeRef result = NULL;
    OSStatus status = errSecUnimplemented;
    NSString *group = nil;
    if (statusOut) *statusOut = (int)status;
    if (!copy) return nil;
    base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"instagramx.keychain-group-probe",
        (__bridge id)kSecAttrAccount: @"probe"
    };
    query = [base mutableCopy];
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    status = copy((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound && add) {
        NSMutableDictionary *insert = [base mutableCopy];
        insert[(__bridge id)kSecValueData] = [@"ix" dataUsingEncoding:NSUTF8StringEncoding];
        insert[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        insert[(__bridge id)kSecReturnAttributes] = @YES;
        if (result) {
            CFRelease(result);
            result = NULL;
        }
        status = add((__bridge CFDictionaryRef)insert, &result);
        if (del) del((__bridge CFDictionaryRef)base);
    }
    if (status == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
        id found = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
        if ([found isKindOfClass:[NSString class]] && [(NSString *)found length] > 0 && [(NSString *)found length] <= 128) group = found;
    }
    if (result) CFRelease(result);
    if (statusOut) *statusOut = (int)status;
    return group;
}

static void IXKc(const char *phase, const char *logName, NSString *service, NSString *group, const char *label, int anySync) {
    IXSecCopyFn copy = IXRawCopy();
    NSMutableDictionary *query;
    CFTypeRef result = NULL;
    OSStatus status = errSecUnimplemented;
    int count = 0;
    char detail[64];
    if (!copy || service.length == 0) {
        IXEmit(phase, "keychain", logName, 0, 0, "noreal");
        return;
    }
    query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
    } mutableCopy];
    if (group.length) query[(__bridge id)kSecAttrAccessGroup] = group;
    if (anySync) query[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
    status = copy((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        if (CFGetTypeID(result) == CFArrayGetTypeID()) count = (int)CFArrayGetCount(result);
        else count = 1;
    }
    if (result) CFRelease(result);
    snprintf(detail, sizeof detail, "st%d.%s", (int)status, label);
    IXEmit(phase, "keychain", logName, count > 0, (unsigned long long)count, detail);
}

void IXSessionSourceProbeKeychain(const char *phase) {
    NSString *entitled;
    int probeStatus = -1;
    int i;
    static const struct { const char *log; const char *service; } kServices[] = {
        {"activeaccount", "instagram.activeaccount"},
        {"inactive", "instagram.inactiveloggedinaccounts"},
        {"authheaders", "com.instagram.users.authheaders.service"},
        {"tokenshare", "group.com.facebook.family.instagramtokenshare.service"},
        {"tokenshare_key", "group.com.facebook.family.instagramtokenshare.key"}
    };
    if (!phase || !phase[0]) return;
    @try {
        entitled = IXEntitledGroup(&probeStatus);
        {
            char detail[64];
            snprintf(detail, sizeof detail, "st%d.%s", probeStatus, entitled.length ? "entitled" : "missing");
            IXEmit(phase, "keychain", "probe", entitled.length > 0, 0, detail);
        }
        for (i = 0; i < 5; i++) {
            NSString *service = [NSString stringWithUTF8String:kServices[i].service];
            IXKc(phase, kServices[i].log, service, nil, "default", 0);
            if (entitled.length) IXKc(phase, kServices[i].log, service, entitled, "entitled", 0);
            IXKc(phase, kServices[i].log, service, @"group.com.burbn.instagram", "ig", 0);
            IXKc(phase, kServices[i].log, service, @"group.com.facebook.family", "family", 0);
            IXKc(phase, kServices[i].log, service, @"group.com.burbn.family", "burbn", 0);
        }
        IXKc(phase, "authheaders", @"com.instagram.users.authheaders.service", entitled, "entitled_any", 1);
        (void)probeStatus;
    } @catch (__unused NSException *exception) {
        IXEmit(phase, "probe", "keychain", 0, 0, "threw");
    }
}
