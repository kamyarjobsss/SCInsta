#import "IXBackend.h"
#import "IXCrypto.h"
#import "IXPin.h"
#import "../Launch/IXSessionDiag.h"
#import "../Proxy/IXTrafficGuard.h"

#import <stdatomic.h>

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Security/Security.h>
#if __has_include(<Security/SecProtocolTypes.h>)
#import <Security/SecProtocolTypes.h>
#endif
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdlib.h>

NSString *const IXBackendVPNUnavailableMessage = @"مشکل موقتی است، به‌زودی برطرف می‌شود، کمی بعد دوباره تلاش کنید";
NSString *const IXBackendConfigDidChangeNotification = @"IXBackendConfigDidChange";

static NSString *const kHost = @"77.110.125.217";
static NSString *const kBase = @"https://77.110.125.217:9443";
static NSString *const kPinA = @"nF3bL0hBLUH34FBfD4UJOkq/nY/a/VoH7kaD8ILcIOA=";
static NSString *const kPinB = @"3f4MhSKZEyhk7q1+RHZ/w0q54d4miKD92xZzBkIlewE=";
static NSString *const kSignKey = @"H2wbdb2he/9oeYjJYRkrAi8pZYFBLddQvXmSKbouo/0=";
static NSString *const kAppVersion = @"2.4.3";
static NSString *const kService = @"instagramx.backend";

static dispatch_queue_t ix_q;
static pthread_mutex_t ix_state_mu = PTHREAD_MUTEX_INITIALIZER;
static NSTimeInterval ix_not_before;
static NSURLSession *ix_session;
static NSString *ix_device_id;
static NSString *ix_token;
static NSData *ix_secret;
static NSDictionary *ix_payload;
static NSString *ix_etag;
static NSInteger ix_config_version;
static NSArray *ix_vpn_items;
static NSString *ix_vpn_label;
static NSArray *ix_fonts;
static NSDictionary *ix_stickers;
static NSMutableArray *ix_events;
static BOOL ix_blocked;
static BOOL ix_started;
static BOOL ix_syncing;
static BOOL ix_sync_pending;
static BOOL ix_force_retry;
static _Atomic int ix_pin_mismatch;
static NSString *ix_panel_url;
static NSString *ix_panel_result;
static NSString *ix_panel_route;
static NSString *ix_panel_when;
static NSString *ix_panel_pins;
static NSInteger ix_panel_http;
static dispatch_source_t ix_heartbeat_timer;

NSString *const IXBackendStatusDidChangeNotification = @"IXBackendStatusDidChange";

@interface IXPinnedSession : NSObject <NSURLSessionDelegate>
@end

static void IXSetPins(NSString *pins) {
    NSString *safe = pins.length ? pins : @"none";
    if (safe.length > 220) safe = [[safe substringToIndex:220] stringByAppendingString:@"…"];
    pthread_mutex_lock(&ix_state_mu);
    ix_panel_pins = [safe copy];
    pthread_mutex_unlock(&ix_state_mu);
}

static NSString *IXGetPins(void) {
    pthread_mutex_lock(&ix_state_mu);
    NSString *pins = ix_panel_pins ?: @"none";
    pthread_mutex_unlock(&ix_state_mu);
    return pins;
}

static NSString *IXPinForKey(SecKeyRef key, BOOL *matched) {
    if (!key) return @"nokey";
    CFDataRef raw = SecKeyCopyExternalRepresentation(key, NULL);
    NSString *label = @"nokey";
    if (raw && CFDataGetLength(raw) == IX_SPKI_P256_POINT_LEN) {
        uint8_t spki[IX_SPKI_P256_HEADER_LEN + IX_SPKI_P256_POINT_LEN];
        size_t n = 0;
        if (IXSPKIBuildP256(CFDataGetBytePtr(raw), (size_t)CFDataGetLength(raw), spki, sizeof spki, &n)) {
            uint8_t dig[32];
            ix_sha256(spki, n, dig);
            label = [[NSData dataWithBytes:dig length:32] base64EncodedStringWithOptions:0] ?: @"nokey";
            if (matched && IXSPKIPinAccept(label.UTF8String, kPinA.UTF8String, kPinB.UTF8String)) *matched = YES;
        }
    } else if (raw) {
        label = [NSString stringWithFormat:@"len:%ld", (long)CFDataGetLength(raw)];
    }
    if (raw) CFRelease(raw);
    return label;
}

static NSString *IXChainPins(SecTrustRef trust, BOOL *matched) {
    if (matched) *matched = NO;
    if (!trust) return @"none";
    NSMutableArray<NSString *> *pins = [NSMutableArray array];
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    CFIndex count = chain ? CFArrayGetCount(chain) : 0;
    if (count <= 0) {
        SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust, 0);
        SecKeyRef key = leaf ? SecCertificateCopyKey(leaf) : NULL;
        if (key) {
            [pins addObject:IXPinForKey(key, matched)];
            CFRelease(key);
        }
    }
    for (CFIndex i = 0; i < count && i < 4; i++) {
        SecCertificateRef cert = (SecCertificateRef)CFArrayGetValueAtIndex(chain, i);
        SecKeyRef key = cert ? SecCertificateCopyKey(cert) : NULL;
        [pins addObject:IXPinForKey(key, matched)];
        if (key) CFRelease(key);
    }
    if (chain) CFRelease(chain);
    if (!pins.count) return @"none";
    return [pins componentsJoinedByString:@"|"];
}

static void IXResolveTrust(NSURLAuthenticationChallenge *challenge, void (^completionHandler)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    BOOL matched = NO;
    NSString *pins = IXChainPins(trust, &matched);
    IXSetPins(pins);
    if (matched && trust) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
        return;
    }
    atomic_store(&ix_pin_mismatch, 1);
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

@implementation IXPinnedSession
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    (void)session;
    IXResolveTrust(challenge, completionHandler);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    (void)session;
    (void)task;
    IXResolveTrust(challenge, completionHandler);
}
@end

static NSData *IXKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFGetTypeID(result) == CFDataGetTypeID() ? (__bridge_transfer NSData *)result : nil;
    if (!data && result) CFRelease(result);
    return data;
}

static void IXKeychainWrite(NSString *account, NSData *data) {
    if (!account || !data) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account
    };
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    if (SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs) == errSecItemNotFound) {
        NSMutableDictionary *add = [query mutableCopy];
        [add addEntriesFromDictionary:attrs];
        SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
}

static NSString *IXModel(void) {
    struct utsname u;
    if (uname(&u) != 0) return @"iPhone";
    NSString *machine = [NSString stringWithUTF8String:u.machine] ?: @"iPhone";
    if (machine.length > 64) machine = [machine substringToIndex:64];
    return machine;
}

static NSString *IXIOS(void) {
    NSString *v = UIDevice.currentDevice.systemVersion ?: @"";
    if (v.length > 32) v = [v substringToIndex:32];
    return v;
}

static NSString *IXCacheDir(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"ix_files"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *IXConfigPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
    return [base stringByAppendingPathComponent:@"ix_signed_config.json"];
}

static BOOL IXUsernameOK(NSString *name) {
    if (name.length < 1 || name.length > 30) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789._"] invertedSet];
    return [name.lowercaseString rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static void IXTakeUsername(NSMutableOrderedSet *set, id value) {
    if (![value isKindOfClass:[NSString class]] || set.count >= 50) return;
    NSString *name = [(NSString *)value lowercaseString];
    if (IXUsernameOK(name)) [set addObject:name];
}

static void IXHarvestObject(id obj, NSMutableOrderedSet *set, int depth) {
    if (!obj || depth > 4 || set.count >= 50) return;
    if ([obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSSet class]]) {
        for (id item in obj) IXHarvestObject(item, set, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id item in [(NSDictionary *)obj allValues]) IXHarvestObject(item, set, depth + 1);
        return;
    }
    @try {
        if ([obj respondsToSelector:@selector(username)]) IXTakeUsername(set, [obj valueForKey:@"username"]);
    } @catch (__unused NSException *e) {}
    if (depth >= 3) return;
    for (NSString *key in @[@"user", @"loggedInUser", @"currentUser", @"accounts", @"loggedInAccounts", @"allAccounts", @"users", @"sessions"]) {
        @try {
            if (![obj respondsToSelector:NSSelectorFromString(key)]) continue;
            IXHarvestObject([obj valueForKey:key], set, depth + 1);
        } @catch (__unused NSException *e) {}
    }
}

static NSArray<NSString *> *IXInstagramUsernames(void) {
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            @try { IXHarvestObject([window valueForKey:@"userSession"], set, 0); }
            @catch (__unused NSException *e) {}
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
                IXHarvestObject(obj, set, 0);
            } @catch (__unused NSException *e) {}
        }
    }
    return set.array;
}

static void IXPublish(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IXBackendConfigDidChangeNotification object:nil];
    });
}

static BOOL IXVerifyPayload(NSData *payload, NSData *signature) {
    if (payload.length == 0 || signature.length != 64) return NO;
    NSData *pk = [[NSData alloc] initWithBase64EncodedString:kSignKey options:0];
    if (pk.length != 32) return NO;
    return ix_ed25519_verify(signature.bytes, pk.bytes, payload.bytes, payload.length) == 0;
}

static void IXDecryptVPN(NSDictionary *vpn) {
    if (![vpn isKindOfClass:[NSDictionary class]]) return;
    NSString *mode = [vpn[@"mode"] isKindOfClass:[NSString class]] ? vpn[@"mode"] : @"";
    NSArray *items = nil;
    if ([mode isEqualToString:@"plain"]) {
        items = [vpn[@"items"] isKindOfClass:[NSArray class]] ? vpn[@"items"] : nil;
    } else if ([mode isEqualToString:@"x25519-hkdf-sha256-aes256gcm"] && ix_secret.length == 32) {
        NSData *epk = [[NSData alloc] initWithBase64EncodedString:[vpn[@"epk"] isKindOfClass:[NSString class]] ? vpn[@"epk"] : @"" options:0];
        NSData *salt = [[NSData alloc] initWithBase64EncodedString:[vpn[@"salt"] isKindOfClass:[NSString class]] ? vpn[@"salt"] : @"" options:0];
        NSData *box = [[NSData alloc] initWithBase64EncodedString:[vpn[@"box"] isKindOfClass:[NSString class]] ? vpn[@"box"] : @"" options:0];
        if (epk.length == 32 && salt.length == 32 && box.length >= 28 && box.length < 256 * 1024) {
            uint8_t *plain = calloc(1, box.length);
            size_t plen = box.length;
            if (plain && ix_vpn_open(ix_secret.bytes, epk.bytes, salt.bytes, box.bytes, box.length, plain, &plen) == 0) {
                NSData *data = [NSData dataWithBytes:plain length:plen];
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([parsed isKindOfClass:[NSArray class]]) items = parsed;
            }
            if (plain) {
                memset(plain, 0, box.length);
                free(plain);
            }
        }
    } else return;
    if (![items isKindOfClass:[NSArray class]]) return;
    NSMutableArray *clean = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *link = [item[@"link"] isKindOfClass:[NSString class]] ? item[@"link"] : @"";
        NSString *label = [item[@"label"] isKindOfClass:[NSString class]] ? item[@"label"] : @"";
        if (link.length == 0 || label.length == 0) continue;
        [clean addObject:@{
            @"id": item[@"id"] ?: @0,
            @"label": label,
            @"protocol": [item[@"protocol"] isKindOfClass:[NSString class]] ? item[@"protocol"] : @"",
            @"link": link,
            @"order": item[@"order"] ?: @0
        }];
    }
    [clean sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"order"] compare:b[@"order"]];
    }];
    pthread_mutex_lock(&ix_state_mu);
    ix_vpn_items = [clean copy];
    pthread_mutex_unlock(&ix_state_mu);
}

static NSString *IXHex(const uint8_t *bytes, size_t n) {
    static const char *digits = "0123456789abcdef";
    char *out = calloc(n * 2 + 1, 1);
    if (!out) return @"";
    for (size_t i = 0; i < n; i++) {
        out[i * 2] = digits[bytes[i] >> 4];
        out[i * 2 + 1] = digits[bytes[i] & 0xf];
    }
    NSString *text = [NSString stringWithUTF8String:out] ?: @"";
    free(out);
    return text;
}

static BOOL IXFileMatches(NSString *path, NSString *sha) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || sha.length != 64) return NO;
    uint8_t dig[32];
    ix_sha256(data.bytes, data.length, dig);
    return [IXHex(dig, 32) isEqualToString:sha.lowercaseString];
}

static void IXRegisterFontFile(NSString *path, NSDictionary *font) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0 || data.length > 20 * 1024 * 1024) return;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGFontRef cg = provider ? CGFontCreateWithDataProvider(provider) : NULL;
    if (provider) CGDataProviderRelease(provider);
    if (!cg) return;
    CFErrorRef error = NULL;
    CTFontManagerRegisterGraphicsFont(cg, &error);
    if (error) CFRelease(error);
    NSString *ps = (__bridge_transfer NSString *)CGFontCopyPostScriptName(cg);
    CGFontRelease(cg);
    if (ps.length == 0) return;
    NSString *logging = [@"ixfont-" stringByAppendingString:ps];
    if (logging.length > 80) logging = [logging substringToIndex:80];
    NSMutableArray *faces = [ix_fonts mutableCopy] ?: [NSMutableArray array];
    NSNumber *order = [font[@"order"] isKindOfClass:[NSNumber class]] ? font[@"order"] : @0;
    NSString *display = [font[@"name"] isKindOfClass:[NSString class]] ? font[@"name"] : ps;
    NSDictionary *face = @{@"postScript": ps, @"display": display, @"order": order, @"logging": logging};
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < faces.count; i++) {
        if ([faces[i][@"postScript"] isEqualToString:ps]) {
            faces[i] = face;
            replaced = YES;
        }
    }
    if (!replaced) [faces addObject:face];
    pthread_mutex_lock(&ix_state_mu);
    ix_fonts = [faces copy];
    pthread_mutex_unlock(&ix_state_mu);
}

static void IXNoteSticker(NSString *path, NSDictionary *pack, NSDictionary *sticker) {
    NSString *category = [ix_payload[@"stickers"][@"category"] isKindOfClass:[NSString class]] ? ix_payload[@"stickers"][@"category"] : @"Instagram X";
    NSMutableDictionary *catalog = [ix_stickers mutableCopy] ?: [@{@"category": category, @"packs": @[]} mutableCopy];
    catalog[@"category"] = category;
    NSMutableArray *packs = [catalog[@"packs"] mutableCopy] ?: [NSMutableArray array];
    NSString *packName = [pack[@"name"] isKindOfClass:[NSString class]] ? pack[@"name"] : @"Instagram X";
    NSNumber *packOrder = [pack[@"order"] isKindOfClass:[NSNumber class]] ? pack[@"order"] : @0;
    NSNumber *packID = pack[@"id"] ?: @0;
    NSMutableDictionary *found = nil;
    for (NSMutableDictionary *row in packs) {
        if ([row[@"id"] isEqual:packID]) found = [row mutableCopy];
    }
    if (!found) found = [@{@"id": packID, @"name": packName, @"order": packOrder, @"stickers": @[]} mutableCopy];
    found[@"name"] = packName;
    found[@"order"] = packOrder;
    NSMutableArray *stickers = [found[@"stickers"] mutableCopy];
    NSDictionary *one = @{
        @"path": path,
        @"order": [sticker[@"order"] isKindOfClass:[NSNumber class]] ? sticker[@"order"] : @0,
        @"id": sticker[@"id"] ?: @0
    };
    BOOL have = NO;
    for (NSUInteger i = 0; i < stickers.count; i++) {
        if ([stickers[i][@"path"] isEqualToString:path]) {
            stickers[i] = one;
            have = YES;
        }
    }
    if (!have) [stickers addObject:one];
    [stickers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"order"] compare:b[@"order"]];
    }];
    found[@"stickers"] = stickers;
    BOOL wrote = NO;
    for (NSUInteger i = 0; i < packs.count; i++) {
        if ([packs[i][@"id"] isEqual:packID]) {
            packs[i] = found;
            wrote = YES;
        }
    }
    if (!wrote) [packs addObject:found];
    [packs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"order"] compare:b[@"order"]];
    }];
    catalog[@"packs"] = packs;
    pthread_mutex_lock(&ix_state_mu);
    ix_stickers = [catalog copy];
    pthread_mutex_unlock(&ix_state_mu);
}

static void IXWaitSeconds(NSTimeInterval seconds) {
    if (seconds <= 0) return;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
}

static NSArray<NSString *> *IXPanelBases(void) {
    // Ordered. A future hostname is inserted at the front. The IP stays reachable from Iran.
    return @[ kBase ];
}

static void IXInstallPanelExemption(void) {
    IXTrafficGuardAddDirectHost(kHost.UTF8String);
    for (NSString *base in IXPanelBases()) {
        NSString *host = [NSURL URLWithString:base].host;
        if (host.length) IXTrafficGuardAddDirectHost(host.UTF8String);
    }
}

static NSString *IXPanelWhen(void) {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss 'UTC'";
    return [fmt stringFromDate:[NSDate date]] ?: @"-";
}

static void IXNotePanel(NSString *url, NSString *result, NSInteger http, NSString *route) {
    NSString *safeURL = url.length ? url : @"-";
    if (safeURL.length > 180) safeURL = [safeURL substringToIndex:180];
    NSString *safeResult = result.length ? result : @"-";
    if (safeResult.length > 220) safeResult = [[safeResult substringToIndex:220] stringByAppendingString:@"…"];
    NSString *safeRoute = route.length ? route : @"-";
    NSString *when = IXPanelWhen();
    NSInteger config = 0;
    NSInteger announcements = 0;
    NSInteger fonts = 0;
    NSInteger stickers = 0;
    int registered = 0;
    pthread_mutex_lock(&ix_state_mu);
    ix_panel_url = [safeURL copy];
    ix_panel_result = [safeResult copy];
    ix_panel_route = [safeRoute copy];
    ix_panel_when = [when copy];
    ix_panel_http = http;
    registered = ix_token.length > 0 ? 1 : 0;
    config = ix_config_version;
    fonts = (NSInteger)ix_fonts.count;
    if ([ix_payload[@"announcements"] isKindOfClass:[NSArray class]]) announcements = (NSInteger)[ix_payload[@"announcements"] count];
    for (id pack in ix_stickers[@"packs"]) {
        if ([pack isKindOfClass:[NSDictionary class]] && [pack[@"stickers"] isKindOfClass:[NSArray class]]) stickers += (NSInteger)[pack[@"stickers"] count];
    }
    pthread_mutex_unlock(&ix_state_mu);
    IXSessionDiagLine([NSString stringWithFormat:@"panel url=%@ result=%@ http=%ld route=%@ registered=%d config=%ld announcements=%ld fonts=%ld stickers=%ld",
                       safeURL, safeResult, (long)http, safeRoute, registered, (long)config, (long)announcements, (long)fonts, (long)stickers]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IXBackendStatusDidChangeNotification object:nil];
    });
}

static void IXConfigurePanelSession(NSURLSessionConfiguration *config, BOOL direct) {
    if (direct) {
        config.connectionProxyDictionary = @{
            @"HTTPEnable": @NO,
            @"HTTPSEnable": @NO,
            @"SOCKSEnable": @NO
        };
    }
    if (@available(iOS 13.0, *)) {
        config.TLSMinimumSupportedProtocolVersion = tls_protocol_version_TLSv12;
    }
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 20;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.waitsForConnectivity = NO;
}

static NSURLSession *IXMakeDirectSession(void) {
    IXTrafficGuardSetThreadBypass(YES);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    IXConfigurePanelSession(config, YES);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:[IXPinnedSession new] delegateQueue:nil];
    IXTrafficGuardSetThreadBypass(NO);
    return session;
}

static NSURLSession *IXMakeTunnelSession(void) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    IXConfigurePanelSession(config, NO);
    return [NSURLSession sessionWithConfiguration:config delegate:[IXPinnedSession new] delegateQueue:nil];
}

static NSData *IXAttempt(NSURLSession *session, NSString *method, NSString *base, NSString *path, NSDictionary *body, NSDictionary *headers, NSString *route, NSInteger *statusOut, NSDictionary **headerOut, BOOL *reachedOut) {
    NSString *urlText = [(base ?: @"") stringByAppendingString:path ?: @""];
    NSURL *url = [NSURL URLWithString:urlText];
    if (!session || !url) {
        if (statusOut) *statusOut = 0;
        if (headerOut) *headerOut = nil;
        if (reachedOut) *reachedOut = NO;
        IXNotePanel(urlText, @"error NSURLErrorDomain -1000", 0, route);
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method.length ? method : @"GET";
    request.timeoutInterval = 15;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    if (@available(iOS 15.0, *)) request.assumesHTTP3Capable = NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSString class]]) [request setValue:obj forHTTPHeaderField:key];
    }];
    if (body) {
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        if (!encoded || encoded.length > 64 * 1024) {
            if (statusOut) *statusOut = 0;
            if (headerOut) *headerOut = nil;
            if (reachedOut) *reachedOut = NO;
            IXNotePanel(urlText, @"error IXBackend -1", 0, route);
            return nil;
        }
        request.HTTPBody = encoded;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    atomic_store(&ix_pin_mismatch, 0);
    IXSetPins(@"none");
    __block NSData *result = nil;
    __block NSURLResponse *response = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        result = data;
        response = resp;
        error = err;
        dispatch_semaphore_signal(gate);
    }] resume];
    long timedOut = dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC));
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger status = http ? (NSInteger)http.statusCode : 0;
    BOOL pinFailed = atomic_load(&ix_pin_mismatch) != 0;
    BOOL reached = http != nil && !pinFailed;
    NSString *pins = IXGetPins();
    NSString *outcome = [NSString stringWithFormat:@"OK pins=%@", pins];
    if (pinFailed) outcome = [NSString stringWithFormat:@"pin mismatch pins=%@", pins];
    else if (!http) {
        if (timedOut != 0) outcome = [NSString stringWithFormat:@"error NSURLErrorDomain -1001 pins=%@", pins];
        else if (error) outcome = [NSString stringWithFormat:@"error %@ %ld pins=%@", error.domain.length ? error.domain : @"NSURLErrorDomain", (long)error.code, pins];
        else outcome = [NSString stringWithFormat:@"error NSURLErrorDomain -1 pins=%@", pins];
    }
    if (statusOut) *statusOut = status;
    if (headerOut) *headerOut = http.allHeaderFields;
    if (reachedOut) *reachedOut = reached;
    IXNotePanel(urlText, outcome, status, route);
    return reached ? result : nil;
}

static void IXNoteHTTP(NSInteger status, NSString *path, NSDictionary *headers) {
    if (status == 429) {
        NSInteger secs = [headers[@"Retry-After"] integerValue];
        if (secs <= 0) secs = 30;
        if (secs > 300) secs = 300;
        ix_not_before = [NSDate date].timeIntervalSince1970 + secs;
    }
    if (status == 403 && [path hasPrefix:@"/api/"]) {
        ix_blocked = YES;
        [[NSUserDefaults standardUserDefaults] setObject:kAppVersion forKey:@"ix_backend_blocked"];
    }
}

static NSData *IXCall(BOOL thorough, NSString *method, NSString *path, NSDictionary *body, NSDictionary *headers, NSInteger *statusOut, NSDictionary **headerOut) {
    if (statusOut) *statusOut = 0;
    if (headerOut) *headerOut = nil;
    NSString *first = IXPanelBases().firstObject ?: @"";
    NSString *shown = [first stringByAppendingString:path ?: @""];
    if (ix_blocked) {
        IXNotePanel(shown, @"error IXBackend 403", 403, @"direct");
        if (statusOut) *statusOut = 403;
        return nil;
    }
    if ([NSDate date].timeIntervalSince1970 < ix_not_before) {
        IXNotePanel(shown, @"error IXBackend 429", 429, @"direct");
        if (statusOut) *statusOut = 429;
        return nil;
    }
    if (!ix_session) ix_session = IXMakeDirectSession();
    NSInteger status = 0;
    NSDictionary *respHeaders = nil;
    NSData *data = nil;
    BOOL reached = NO;
    BOOL pinned = NO;
    int passes = thorough ? 3 : 1;
    NSTimeInterval waits[3] = {0, 1.0, 2.0};
    for (int pass = 0; pass < passes && !reached && !ix_blocked && !pinned; pass++) {
        if (waits[pass] > 0) IXWaitSeconds(waits[pass]);
        for (NSString *base in IXPanelBases()) {
            data = IXAttempt(ix_session, method, base, path, body, headers, @"direct", &status, &respHeaders, &reached);
            IXNoteHTTP(status, path, respHeaders);
            if (atomic_load(&ix_pin_mismatch)) pinned = YES;
            if (reached || ix_blocked || pinned) break;
        }
    }
    if (!reached && !ix_blocked && !pinned && IXTrafficGuardProxyUp()) {
        NSURLSession *tunnel = IXMakeTunnelSession();
        for (NSString *base in IXPanelBases()) {
            data = IXAttempt(tunnel, method, base, path, body, headers, @"socks", &status, &respHeaders, &reached);
            IXNoteHTTP(status, path, respHeaders);
            if (reached || ix_blocked) break;
        }
        [tunnel finishTasksAndInvalidate];
    }
    if (statusOut) *statusOut = status;
    if (headerOut) *headerOut = respHeaders;
    if (status == 403 && [path hasPrefix:@"/api/"]) return nil;
    return data;
}

static NSData *IXRequest(NSString *method, NSString *path, NSDictionary *body, NSDictionary *headers, NSInteger *statusOut, NSDictionary **headerOut) {
    return IXCall(NO, method, path, body, headers, statusOut, headerOut);
}

static void IXDownloadFile(NSString *urlPath, NSString *sha, NSString *ext, void (^ready)(NSString *path)) {
    if (urlPath.length == 0 || sha.length != 64) return;
    if ([urlPath containsString:@"://"]) {
        BOOL known = NO;
        for (NSString *base in IXPanelBases()) {
            NSString *host = [NSURL URLWithString:base].host;
            if (host.length && [urlPath rangeOfString:host].location != NSNotFound) known = YES;
        }
        if (!known) return;
    }
    NSString *path = [[IXCacheDir() stringByAppendingPathComponent:sha] stringByAppendingPathExtension:ext];
    if (IXFileMatches(path, sha)) {
        if (ready) ready(path);
        return;
    }
    if (ix_blocked) return;
    NSString *rel = [urlPath hasPrefix:@"/"] ? urlPath : [@"/" stringByAppendingString:urlPath];
    NSInteger status = 0;
    NSData *data = IXRequest(@"GET", rel, nil, nil, &status, NULL);
    if (status != 200 || data.length == 0 || data.length > 20 * 1024 * 1024) return;
    uint8_t dig[32];
    ix_sha256(data.bytes, data.length, dig);
    if (![IXHex(dig, 32) isEqualToString:sha.lowercaseString]) return;
    [data writeToFile:path atomically:YES];
    if (ready) ready(path);
}

static void IXFetchFiles(void) {
    for (id font in ix_payload[@"fonts"]) {
        if (![font isKindOfClass:[NSDictionary class]]) continue;
        NSString *sha = [font[@"sha256"] isKindOfClass:[NSString class]] ? [font[@"sha256"] lowercaseString] : @"";
        NSString *fmt = [font[@"format"] isKindOfClass:[NSString class]] ? [font[@"format"] lowercaseString] : @"ttf";
        if (![fmt isEqualToString:@"otf"]) fmt = @"ttf";
        NSString *url = [font[@"url"] isKindOfClass:[NSString class]] ? font[@"url"] : @"";
        IXDownloadFile(url, sha, fmt, ^(NSString *path) { IXRegisterFontFile(path, font); });
    }
    NSDictionary *stickers = [ix_payload[@"stickers"] isKindOfClass:[NSDictionary class]] ? ix_payload[@"stickers"] : nil;
    for (id pack in stickers[@"packs"]) {
        if (![pack isKindOfClass:[NSDictionary class]]) continue;
        for (id sticker in pack[@"stickers"]) {
            if (![sticker isKindOfClass:[NSDictionary class]]) continue;
            NSString *sha = [sticker[@"sha256"] isKindOfClass:[NSString class]] ? [sticker[@"sha256"] lowercaseString] : @"";
            NSString *url = [sticker[@"url"] isKindOfClass:[NSString class]] ? sticker[@"url"] : @"";
            IXDownloadFile(url, sha, @"png", ^(NSString *path) { IXNoteSticker(path, pack, sticker); });
        }
    }
}

static BOOL IXApplyPayloadBytes(NSData *payload, NSData *signature, NSString *etag) {
    id obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *json = obj;
    if (![json[@"schema"] isKindOfClass:[NSNumber class]] || [json[@"schema"] integerValue] != 1) return NO;
    NSString *device = [json[@"device_id"] isKindOfClass:[NSString class]] ? json[@"device_id"] : @"";
    if (ix_device_id.length && ![device isEqualToString:ix_device_id]) return NO;
    NSTimeInterval exp = [json[@"expires_at"] respondsToSelector:@selector(doubleValue)] ? [json[@"expires_at"] doubleValue] : 0;
    if (exp <= 0 || [NSDate date].timeIntervalSince1970 >= exp) return NO;
    pthread_mutex_lock(&ix_state_mu);
    ix_payload = json;
    ix_etag = etag;
    ix_config_version = [json[@"config_version"] integerValue];
    pthread_mutex_unlock(&ix_state_mu);
    IXDecryptVPN([json[@"vpn"] isKindOfClass:[NSDictionary class]] ? json[@"vpn"] : nil);
    IXFetchFiles();
    NSData *wrap = [NSJSONSerialization dataWithJSONObject:@{
        @"etag": etag ?: @"",
        @"payload": [payload base64EncodedStringWithOptions:0],
        @"signature": [signature base64EncodedStringWithOptions:0] ?: @""
    } options:0 error:nil];
    if (wrap) [wrap writeToFile:IXConfigPath() atomically:YES];
    return YES;
}

static BOOL IXAcceptEnvelope(NSData *body, NSDictionary *headers) {
    id obj = [NSJSONSerialization JSONObjectWithData:body ?: [NSData data] options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    if (![obj[@"alg"] isEqualToString:@"Ed25519"]) return NO;
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:[obj[@"payload"] isKindOfClass:[NSString class]] ? obj[@"payload"] : @"" options:0];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:[obj[@"signature"] isKindOfClass:[NSString class]] ? obj[@"signature"] : @"" options:0];
    if (!IXVerifyPayload(payload, signature)) return NO;
    NSString *etag = nil;
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:@"ETag"] == NSOrderedSame) etag = headers[key];
    }
    return IXApplyPayloadBytes(payload, signature, etag ?: @"");
}

static void IXLoadCache(void) {
    NSData *wrap = [NSData dataWithContentsOfFile:IXConfigPath()];
    id obj = [NSJSONSerialization JSONObjectWithData:wrap ?: [NSData data] options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return;
    NSData *payload = [[NSData alloc] initWithBase64EncodedString:[obj[@"payload"] isKindOfClass:[NSString class]] ? obj[@"payload"] : @"" options:0];
    NSData *signature = [[NSData alloc] initWithBase64EncodedString:[obj[@"signature"] isKindOfClass:[NSString class]] ? obj[@"signature"] : @"" options:0];
    if (!IXVerifyPayload(payload, signature)) return;
    NSString *etag = [obj[@"etag"] isKindOfClass:[NSString class]] ? obj[@"etag"] : @"";
    IXApplyPayloadBytes(payload, signature, etag);
}

static BOOL IXRegister(void);
static void IXFetchConfig(void);
static void IXSendHeartbeat(void);
static void IXFlushEvents(void);

static BOOL IXRegister(void) {
    if (!ix_device_id || ix_secret.length != 32) return NO;
    uint8_t pub[32];
    ix_x25519_public(pub, ix_secret.bytes);
    NSString *b64 = [[NSData dataWithBytes:pub length:32] base64EncodedStringWithOptions:0];
    NSDictionary *body = @{
        @"device_id": ix_device_id,
        @"model": IXModel(),
        @"ios": IXIOS(),
        @"app_version": kAppVersion,
        @"enc_pubkey": b64
    };
    NSInteger status = 0;
    NSDictionary *headers = nil;
    NSData *data = IXCall(YES, @"POST", @"/api/v1/register", body, nil, &status, &headers);
    (void)headers;
    if (status == 429) return NO;
    id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
    NSString *token = [obj isKindOfClass:[NSDictionary class]] && [obj[@"device_token"] isKindOfClass:[NSString class]] ? obj[@"device_token"] : nil;
    if (status != 200 || token.length == 0) return NO;
    ix_token = token;
    IXKeychainWrite(@"device_token", [token dataUsingEncoding:NSUTF8StringEncoding]);
    return YES;
}

static void IXFetchConfig(void) {
    if (ix_blocked) return;
    if (ix_token.length == 0 && !IXRegister()) return;
    NSMutableDictionary *headers = [@{@"Authorization": [@"Bearer " stringByAppendingString:ix_token]} mutableCopy];
    if (ix_etag.length) headers[@"If-None-Match"] = ix_etag;
    NSInteger status = 0;
    NSDictionary *responseHeaders = nil;
    NSData *data = IXCall(YES, @"GET", @"/api/v1/config", nil, headers, &status, &responseHeaders);
    if (status == 401) {
        ix_token = nil;
        if (!IXRegister()) return;
        headers[@"Authorization"] = [@"Bearer " stringByAppendingString:ix_token];
        data = IXCall(YES, @"GET", @"/api/v1/config", nil, headers, &status, &responseHeaders);
    }
    if (status == 304) return;
    if (status != 200) return;
    if (IXAcceptEnvelope(data, responseHeaders)) IXPublish();
}

static void IXSendHeartbeat(void) {
    if (ix_blocked || (ix_token.length == 0 && !IXRegister())) return;
    __block NSArray *names = @[];
    if (pthread_main_np()) names = IXInstagramUsernames();
    else dispatch_sync(dispatch_get_main_queue(), ^{ names = IXInstagramUsernames(); });
    NSMutableDictionary *body = [@{
        @"vpn_label": ix_vpn_label.length ? ix_vpn_label : [NSNull null],
        @"ig_usernames": names,
        @"ig_account_count": @(names.count),
        @"app_version": kAppVersion,
        @"model": IXModel(),
        @"ios": IXIOS()
    } mutableCopy];
    (void)body;
    NSInteger status = 0;
    NSData *data = IXRequest(@"POST", @"/api/v1/heartbeat", body, @{@"Authorization": [@"Bearer " stringByAppendingString:ix_token]}, &status, NULL);
    if (status == 401) {
        ix_token = nil;
        if (!IXRegister()) return;
        data = IXRequest(@"POST", @"/api/v1/heartbeat", body, @{@"Authorization": [@"Bearer " stringByAppendingString:ix_token]}, &status, NULL);
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"config_version"] integerValue] > ix_config_version) IXFetchConfig();
    IXFlushEvents();
}

static void IXFlushEvents(void) {
    if (ix_events.count == 0 || ix_token.length == 0 || ix_blocked) return;
    NSArray *batch = [ix_events copy];
    [ix_events removeAllObjects];
    NSInteger status = 0;
    IXRequest(@"POST", @"/api/v1/events", @{@"events": batch}, @{@"Authorization": [@"Bearer " stringByAppendingString:ix_token]}, &status, NULL);
    if (status != 200 && status != 0) {
        [ix_events insertObjects:batch atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, batch.count)]];
        if (ix_events.count > 50) [ix_events removeObjectsInRange:NSMakeRange(0, ix_events.count - 50)];
    }
}

static void IXEnsureIdentity(void) {
    NSData *ident = IXKeychainRead(@"device_id");
    ix_device_id = [[NSString alloc] initWithData:ident encoding:NSUTF8StringEncoding];
    if (ix_device_id.length < 8) {
        ix_device_id = NSUUID.UUID.UUIDString;
        IXKeychainWrite(@"device_id", [ix_device_id dataUsingEncoding:NSUTF8StringEncoding]);
    }
    ix_secret = IXKeychainRead(@"x25519_private");
    if (ix_secret.length != 32) {
        uint8_t secret[32];
        if (SecRandomCopyBytes(kSecRandomDefault, 32, secret) != errSecSuccess) arc4random_buf(secret, 32);
        ix_secret = [NSData dataWithBytes:secret length:32];
        memset(secret, 0, sizeof(secret));
        IXKeychainWrite(@"x25519_private", ix_secret);
    }
    NSData *token = IXKeychainRead(@"device_token");
    ix_token = [[NSString alloc] initWithData:token encoding:NSUTF8StringEncoding];
}

static id IXCopyState(id (^block)(void)) {
    if (!block) return nil;
    pthread_mutex_lock(&ix_state_mu);
    id value = block();
    pthread_mutex_unlock(&ix_state_mu);
    return value;
}

static void IXSyncPanel(void) {
    if (!ix_started) return;
    if (ix_syncing) {
        ix_sync_pending = YES;
        return;
    }
    ix_syncing = YES;
    if (ix_force_retry) {
        ix_force_retry = NO;
        ix_blocked = NO;
        ix_not_before = 0;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"ix_backend_blocked"];
    }
    IXRegister();
    if (!ix_blocked) IXFetchConfig();
    if (!ix_blocked) IXSendHeartbeat();
    ix_syncing = NO;
    if (ix_sync_pending) {
        ix_sync_pending = NO;
        IXSyncPanel();
    }
}

void IXBackendStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ix_q = dispatch_queue_create("instagramx.backend", DISPATCH_QUEUE_SERIAL);
        IXInstallPanelExemption();
    });
    dispatch_async(ix_q, ^{
        if (!ix_started) {
            ix_started = YES;
            ix_events = [NSMutableArray array];
            ix_vpn_items = @[];
            ix_fonts = @[];
            ix_stickers = @{@"category": @"Instagram X", @"packs": @[]};
            NSString *blocked = [[NSUserDefaults standardUserDefaults] stringForKey:@"ix_backend_blocked"];
            ix_blocked = [blocked isEqualToString:kAppVersion];
            ix_session = IXMakeDirectSession();
            IXEnsureIdentity();
            IXLoadCache();
            IXPublish();
            [ix_events addObject:@{@"name": @"app_open", @"ts": @((long long)[NSDate date].timeIntervalSince1970), @"props": @{@"screen": @"home"}}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
                    IXBackendHeartbeat(@"foreground");
                }];
            });
            if (!ix_heartbeat_timer) {
                ix_heartbeat_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ix_q);
                dispatch_source_set_timer(ix_heartbeat_timer, dispatch_time(DISPATCH_TIME_NOW, 15 * 60 * NSEC_PER_SEC), 15 * 60 * NSEC_PER_SEC, 30 * NSEC_PER_SEC);
                dispatch_source_set_event_handler(ix_heartbeat_timer, ^{ IXSyncPanel(); });
                dispatch_resume(ix_heartbeat_timer);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), ix_q, ^{
                IXSyncPanel();
            });
        }
    });
}

void IXBackendHeartbeat(NSString *reason) {
    (void)reason;
    if (!ix_q) return;
    dispatch_async(ix_q, ^{ IXSyncPanel(); });
}

void IXBackendPostEvent(NSString *name, NSDictionary *props) {
    if (!ix_q || name.length == 0 || name.length > 64) return;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-"] invertedSet];
    if ([name rangeOfCharacterFromSet:bad].location != NSNotFound) return;
    dispatch_async(ix_q, ^{
        if (!ix_events) ix_events = [NSMutableArray array];
        NSMutableDictionary *event = [@{@"name": name, @"ts": @((long long)[NSDate date].timeIntervalSince1970)} mutableCopy];
        if (props.count) event[@"props"] = props;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        if (encoded.length > 2048) return;
        [ix_events addObject:event];
        if (ix_events.count > 50) [ix_events removeObjectsInRange:NSMakeRange(0, ix_events.count - 50)];
    });
}

void IXBackendSetVPNLabel(NSString *label) {
    if (!ix_q) return;
    dispatch_async(ix_q, ^{ ix_vpn_label = label.length ? [label copy] : nil; });
}

static BOOL IXAnnActive(NSDictionary *ann) {
    if (![ann isKindOfClass:[NSDictionary class]]) return NO;
    NSInteger ident = [ann[@"id"] integerValue];
    NSArray *dismissed = [[NSUserDefaults standardUserDefaults] arrayForKey:@"ix_ann_dismissed"] ?: @[];
    if ([dismissed containsObject:@(ident)] || [dismissed containsObject:[@(ident) stringValue]]) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ([ann[@"start_at"] respondsToSelector:@selector(doubleValue)] && ![ann[@"start_at"] isKindOfClass:[NSNull class]] && [ann[@"start_at"] doubleValue] > now) return NO;
    if ([ann[@"end_at"] respondsToSelector:@selector(doubleValue)] && ![ann[@"end_at"] isKindOfClass:[NSNull class]] && [ann[@"end_at"] doubleValue] <= now) return NO;
    return YES;
}

NSArray<NSDictionary *> *IXBackendAnnouncements(void) {
    return IXCopyState(^id {
        NSMutableArray *rows = [NSMutableArray array];
        for (id ann in ix_payload[@"announcements"]) {
            if (IXAnnActive(ann)) [rows addObject:ann];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [@([a[@"priority"] integerValue]) compare:@([b[@"priority"] integerValue])];
        }];
        return [rows copy];
    }) ?: @[];
}

void IXBackendDismissAnnouncement(NSInteger announcementID) {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSMutableArray *dismissed = [[defs arrayForKey:@"ix_ann_dismissed"] mutableCopy] ?: [NSMutableArray array];
    if (![dismissed containsObject:@(announcementID)]) [dismissed addObject:@(announcementID)];
    [defs setObject:dismissed forKey:@"ix_ann_dismissed"];
    IXPublish();
}

NSArray<NSDictionary *> *IXBackendFontFaces(void) {
    return IXCopyState(^id { return [ix_fonts copy] ?: @[]; }) ?: @[];
}

NSDictionary *IXBackendStickerCatalog(void) {
    return IXCopyState(^id { return [ix_stickers copy] ?: @{@"category": @"Instagram X", @"packs": @[]}; }) ?: @{@"category": @"Instagram X", @"packs": @[]};
}

NSArray<NSDictionary *> *IXBackendVPNItems(void) {
    return IXCopyState(^id { return [ix_vpn_items copy] ?: @[]; }) ?: @[];
}

static NSDictionary *IXPanelSnapshot(void) {
    __block NSDictionary *snap = nil;
    pthread_mutex_lock(&ix_state_mu);
    snap = @{
        @"url": ix_panel_url ?: [IXPanelBases().firstObject stringByAppendingString:@"/api/v1/register"],
        @"last_attempt": ix_panel_when ?: @"-",
        @"result": ix_panel_result ?: @"not yet",
        @"http_status": @(ix_panel_http),
        @"route": ix_panel_route ?: @"-",
        @"registered": ix_token.length ? @"yes" : @"no",
        @"config_version": @(ix_config_version),
        @"fonts": @(ix_fonts.count),
        @"announcements": @([ix_payload[@"announcements"] isKindOfClass:[NSArray class]] ? [ix_payload[@"announcements"] count] : 0),
        @"pins": ix_panel_pins ?: @"none"
    };
    NSInteger stickers = 0;
    for (id pack in ix_stickers[@"packs"]) {
        if ([pack isKindOfClass:[NSDictionary class]] && [pack[@"stickers"] isKindOfClass:[NSArray class]]) stickers += (NSInteger)[pack[@"stickers"] count];
    }
    NSMutableDictionary *row = [snap mutableCopy];
    row[@"stickers"] = @(stickers);
    snap = [row copy];
    pthread_mutex_unlock(&ix_state_mu);
    return snap;
}

NSDictionary *IXBackendPanelStatus(void) {
    return IXPanelSnapshot() ?: @{};
}

NSString *IXBackendPanelReport(void) {
    NSDictionary *row = IXPanelSnapshot();
    return [NSString stringWithFormat:@"Panel connection\nurl=%@\nlast_attempt=%@\nresult=%@\nhttp_status=%@\nroute=%@\nregistered=%@\nconfig_version=%@\nannouncements=%@\nfonts=%@\nstickers=%@\npins=%@\n",
            row[@"url"] ?: @"-",
            row[@"last_attempt"] ?: @"-",
            row[@"result"] ?: @"not yet",
            row[@"http_status"] ?: @0,
            row[@"route"] ?: @"-",
            row[@"registered"] ?: @"no",
            row[@"config_version"] ?: @0,
            row[@"announcements"] ?: @0,
            row[@"fonts"] ?: @0,
            row[@"stickers"] ?: @0,
            row[@"pins"] ?: @"none"];
}

void IXBackendRetryNow(void) {
    if (!ix_q) {
        IXBackendStart();
    }
    if (!ix_q) return;
    dispatch_async(ix_q, ^{
        ix_force_retry = YES;
        IXSyncPanel();
    });
}

@interface IXPanelController : UITableViewController
@end

@implementation IXPanelController
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = SCILocalized(@"Panel connection");
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadPanel) name:IXBackendStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadPanel) name:IXBackendConfigDidChangeNotification object:nil];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}
- (void)reloadPanel {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadPanel]; });
        return;
    }
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 10 : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section != 1) return nil;
    return SCILocalized(@"The report is included when you copy Diagnostics.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = IXPanelSnapshot();
    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"retry"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"retry"];
        cell.textLabel.text = SCILocalized(@"Retry now");
        cell.textLabel.textColor = self.view.tintColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"field"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"field"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *pairs = @[
        @[SCILocalized(@"URL"), row[@"url"] ?: @"-"],
        @[SCILocalized(@"Last attempt"), row[@"last_attempt"] ?: @"-"],
        @[SCILocalized(@"Result"), row[@"result"] ?: @"not yet"],
        @[SCILocalized(@"HTTP status"), [row[@"http_status"] stringValue] ?: @"0"],
        @[SCILocalized(@"Route"), row[@"route"] ?: @"-"],
        @[SCILocalized(@"Registered"), [row[@"registered"] isEqualToString:@"yes"] ? SCILocalized(@"Yes") : SCILocalized(@"No")],
        @[SCILocalized(@"Config version"), [row[@"config_version"] stringValue] ?: @"0"],
        @[SCILocalized(@"Announcements"), [row[@"announcements"] stringValue] ?: @"0"],
        @[SCILocalized(@"Fonts"), [NSString stringWithFormat:@"%@ · %@", row[@"fonts"] ?: @0, row[@"stickers"] ?: @0]]
    ];
    if (indexPath.row == 8) {
        cell.textLabel.text = SCILocalized(@"Fonts");
        cell.detailTextLabel.text = [NSString stringWithFormat:SCILocalized(@"%@ fonts · %@ stickers"), row[@"fonts"] ?: @0, row[@"stickers"] ?: @0];
    } else if (indexPath.row == 9) {
        cell.textLabel.text = SCILocalized(@"Certificate pins");
        cell.detailTextLabel.text = row[@"pins"] ?: @"none";
    } else {
        cell.textLabel.text = pairs[indexPath.row][0];
        cell.detailTextLabel.text = [pairs[indexPath.row][1] description];
    }
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) IXBackendRetryNow();
}
@end

UIViewController *IXBackendPanelController(void) {
    return [IXPanelController new];
}

__attribute__((constructor))
static void IXBackendExempt(void) {
    IXInstallPanelExemption();
}
