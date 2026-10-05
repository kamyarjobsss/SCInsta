#import "IXProxyManager.h"
#import "IXNativeEngine.h"
#import "IXTrafficGuard.h"
#import "IXRayLoader.h"
#import "../Launch/IXLaunchGuard.h"
#import "../Localization/SCILocalization.h"
#import "../Tweak.h"

#import <Security/Security.h>
#import <QuartzCore/QuartzCore.h>
#import <Network/Network.h>
#import <stdint.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <poll.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <unistd.h>

static BOOL IXUsableIPv4(const struct sockaddr *sa) {
    if (!sa || sa->sa_family != AF_INET) return NO;
    uint32_t host = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
    if (host == 0 || (host >> 24) == 127) return NO;
    if ((host & 0xFFFF0000) == 0xA9FE0000) return NO;
    if ((host & 0xFFC00000) == 0x64400000) return NO;
    return YES;
}

NSString *const IXProxyEnabledKey = @"ix_vless_enabled";
NSString *const IXProxyKillSwitchKey = @"ix_killswitch";
NSString *const IXProxyBlockUDPKey = @"ix_block_udp";
NSString *const IXProxyProfilesKey = @"ix_vless_profiles";
NSString *const IXProxySelectedKey = @"ix_vless_selected";
static NSString *const IXProxyXHTTPModeKey = @"ix_xhttp_mode";

static const uint16_t kSocksPort = 61850;
static const uint16_t kHTTPPort = 61851;
static NSString *const IXProxyKeychainService = @"instagramx.vpn.settings";
static NSString *const IXProxyKeychainAccount = @"settings";

static NSUserDefaults *IXProxySuite(void) {
    static NSUserDefaults *suite;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suite = [[NSUserDefaults alloc] initWithSuiteName:@"instagramx.vpn"];
    });
    return suite ?: [NSUserDefaults standardUserDefaults];
}

static NSDictionary *IXProxyKeychainRead(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: IXProxyKeychainService,
        (__bridge id)kSecAttrAccount: IXProxyKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFGetTypeID(result) == CFDataGetTypeID() ? (__bridge_transfer NSData *)result : nil;
    if (!data) {
        CFRelease(result);
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static void IXProxyKeychainWrite(NSDictionary *payload) {
    if (![NSJSONSerialization isValidJSONObject:payload ?: @{}]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: IXProxyKeychainService,
        (__bridge id)kSecAttrAccount: IXProxyKeychainAccount
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

static NSError *IXProxyError(NSString *message) {
    return [NSError errorWithDomain:@"InstagramX.Proxy" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Proxy error"}];
}

static dispatch_queue_t IXProxyQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("instagramx.proxy", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@interface IXDoHTrust : NSObject <NSURLSessionDelegate>
@end

@implementation IXDoHTrust
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    NSString *host = challenge.protectionSpace.host ?: @"";
    BOOL known = [host isEqualToString:@"1.1.1.1"] || [host isEqualToString:@"1.0.0.1"] || [host isEqualToString:@"8.8.8.8"] || [host isEqualToString:@"8.8.4.4"] || [host isEqualToString:@"dns.google"] || [host isEqualToString:@"cloudflare-dns.com"];
    if (known && challenge.protectionSpace.serverTrust &&
        [challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
        return;
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

@implementation IXProxyManager {
    IXNativeEngine *_native;
    BOOL _usingXray;
    IXProxyStatus _status;
    NSString *_lastError;
    NSString *_engineName;
    NSMutableArray<NSString *> *_logLines;
    uint64_t _bytesUp;
    uint64_t _bytesDown;
    double _speedUp;
    double _speedDown;
    NSInteger _lastPingMs;
    uint64_t _sampleUp;
    uint64_t _sampleDown;
    NSTimeInterval _sampleTime;
    dispatch_source_t _statsTimer;
    NSInteger _generation;
    NSInteger _pathGeneration;
    NSString *_boundInterface;
    NSString *_activeXHTTPMode;
    nw_path_monitor_t _pathMonitor;
}

+ (instancetype)shared {
    static IXProxyManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [IXProxyManager new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = IXProxyStatusOff;
        _logLines = [NSMutableArray array];
        _lastPingMs = -1;
#if IX_LITE
        _engineName = @"Lite build";
#elif IX_HAS_XRAY
        _engineName = @"Xray (loads when the VPN is on)";
#else
        _engineName = @"Built-in VLESS";
#endif
        IXTrafficGuardSetPorts(kSocksPort, kHTTPPort);
        IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
        [self startPathMonitor];
    }
    return self;
}

- (NSString *)physicalInterface {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *wifi = nil;
    NSString *cell = nil;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr) continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
        if (!IXUsableIPv4(ifa->ifa_addr)) continue;
        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        if ([name isEqualToString:@"en0"]) wifi = name;
        else if (!wifi && [name hasPrefix:@"en"]) wifi = name;
        else if (!cell && [name hasPrefix:@"pdp_ip"]) cell = name;
    }
    freeifaddrs(list);
    return wifi ?: cell;
}

- (NSString *)boundInterface {
    return _boundInterface;
}

- (void)startPathMonitor {
    if (_pathMonitor) return;
    nw_path_monitor_t monitor = nw_path_monitor_create();
    if (!monitor) return;
    _pathMonitor = monitor;
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    __weak IXProxyManager *weakSelf = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        (void)path;
        [weakSelf networkPathChanged];
    });
    nw_path_monitor_start(monitor);
}

- (void)networkPathChanged {
    if (_status != IXProxyStatusConnected) return;
    _pathGeneration += 1;
    NSInteger token = _pathGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_pathGeneration || self->_status != IXProxyStatusConnected) return;
        NSString *iface = [self physicalInterface] ?: @"";
        NSString *current = self->_boundInterface ?: @"";
        if ([iface isEqualToString:current]) return;
        [self note:[NSString stringWithFormat:@"Network changed. Binding Xray to %@.", iface.length ? iface : @"the system route"]];
        [self setEnabled:YES completion:nil];
    });
}

- (IXProxyStatus)status { return _status; }
- (NSString *)lastError { return _lastError; }
- (NSString *)engineName {
    BOOL fa = [SCIResolvedLanguageCode() hasPrefix:@"fa"];
#if IX_LITE
    return fa ? @"نسخهٔ سبک" : @"Lite build";
#else
    NSString *raw = _engineName ?: @"";
    if ([raw hasPrefix:@"Xray "]) return raw;
    if ([raw isEqualToString:@"Xray"]) return @"Xray";
    if ([raw isEqualToString:@"Built-in VLESS"]) return fa ? @"VLESS داخلی" : raw;
#if IX_HAS_XRAY
    return fa ? @"Xray، با روشن شدن فیلترشکن بارگذاری می‌شود" : @"Xray (loads when the VPN is on)";
#else
    return fa ? @"VLESS داخلی" : @"Built-in VLESS";
#endif
#endif
}
- (BOOL)xrayLinked {
#if IX_HAS_XRAY
    return YES;
#else
    return NO;
#endif
}

- (NSString *)statusText {
    BOOL fa = [SCIResolvedLanguageCode() hasPrefix:@"fa"];
    switch (_status) {
        case IXProxyStatusConnecting: return fa ? @"در حال اتصال" : @"Connecting";
        case IXProxyStatusConnected: return fa ? @"متصل" : @"Connected";
        case IXProxyStatusFailed:
            if (_lastError.length) {
                return [NSString stringWithFormat:fa ? @"قطع · %@" : @"Disconnected · %@", _lastError];
            }
            return fa ? @"قطع" : @"Disconnected";
        default: return fa ? @"خاموش" : @"Off";
    }
}

+ (NSString *)statusSubtitle {
    return [NSString stringWithFormat:@"%@ · %@", IXProxyManager.shared.statusText, IXProxyManager.shared.engineName];
}

- (void)adoptPayload:(NSDictionary *)payload {
    if (![payload isKindOfClass:[NSDictionary class]]) return;
    NSUserDefaults *suite = IXProxySuite();
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    NSArray *profiles = [payload[@"profiles"] isKindOfClass:[NSArray class]] ? payload[@"profiles"] : @[];
    [suite setObject:profiles forKey:IXProxyProfilesKey];
    [standard setObject:profiles forKey:IXProxyProfilesKey];
    NSString *selected = [payload[@"selected"] isKindOfClass:[NSString class]] ? payload[@"selected"] : @"";
    if (selected.length) {
        [suite setObject:selected forKey:IXProxySelectedKey];
        [standard setObject:selected forKey:IXProxySelectedKey];
    }
    if (payload[@"enabled"]) {
        BOOL enabled = [payload[@"enabled"] boolValue];
        [suite setBool:enabled forKey:IXProxyEnabledKey];
        [standard setBool:enabled forKey:IXProxyEnabledKey];
    }
    if (payload[@"killswitch"]) {
        BOOL on = [payload[@"killswitch"] boolValue];
        [suite setBool:on forKey:IXProxyKillSwitchKey];
        [standard setBool:on forKey:IXProxyKillSwitchKey];
    }
    if (payload[@"blockudp"]) {
        BOOL on = [payload[@"blockudp"] boolValue];
        [suite setBool:on forKey:IXProxyBlockUDPKey];
        [standard setBool:on forKey:IXProxyBlockUDPKey];
    }
    if ([payload[@"xhttpModes"] isKindOfClass:[NSDictionary class]]) {
        [suite setObject:payload[@"xhttpModes"] forKey:IXProxyXHTTPModeKey];
        [standard setObject:payload[@"xhttpModes"] forKey:IXProxyXHTTPModeKey];
    }
    [suite synchronize];
    [standard synchronize];
}

- (void)persistSettings {
    NSUserDefaults *suite = IXProxySuite();
    NSArray *profiles = [suite arrayForKey:IXProxyProfilesKey] ?: @[];
    NSString *selected = [suite stringForKey:IXProxySelectedKey] ?: @"";
    BOOL kill = [suite objectForKey:IXProxyKillSwitchKey] ? [suite boolForKey:IXProxyKillSwitchKey] : YES;
    BOOL block = [suite objectForKey:IXProxyBlockUDPKey] ? [suite boolForKey:IXProxyBlockUDPKey] : YES;
    BOOL enabled = [suite boolForKey:IXProxyEnabledKey];
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    [standard setObject:profiles forKey:IXProxyProfilesKey];
    if (selected.length) [standard setObject:selected forKey:IXProxySelectedKey];
    else [standard removeObjectForKey:IXProxySelectedKey];
    [standard setBool:enabled forKey:IXProxyEnabledKey];
    [standard setBool:kill forKey:IXProxyKillSwitchKey];
    [standard setBool:block forKey:IXProxyBlockUDPKey];
    NSDictionary *modes = [suite dictionaryForKey:IXProxyXHTTPModeKey] ?: @{};
    [standard setObject:modes forKey:IXProxyXHTTPModeKey];
    [suite synchronize];
    [standard synchronize];
    IXProxyKeychainWrite(@{
        @"profiles": profiles,
        @"selected": selected,
        @"enabled": @(enabled),
        @"killswitch": @(kill),
        @"blockudp": @(block),
        @"xhttpModes": modes
    });
}

- (void)restoreStoredSettings {
    NSUserDefaults *suite = IXProxySuite();
    NSUserDefaults *standard = [NSUserDefaults standardUserDefaults];
    NSArray *suiteProfiles = [suite arrayForKey:IXProxyProfilesKey];
    NSArray *standardProfiles = [standard arrayForKey:IXProxyProfilesKey];
    if (suiteProfiles.count == 0 && standardProfiles.count > 0) {
        [self adoptPayload:@{
            @"profiles": standardProfiles,
            @"selected": [standard stringForKey:IXProxySelectedKey] ?: @"",
            @"enabled": @([standard boolForKey:IXProxyEnabledKey]),
            @"killswitch": @([standard objectForKey:IXProxyKillSwitchKey] ? [standard boolForKey:IXProxyKillSwitchKey] : YES),
            @"blockudp": @([standard objectForKey:IXProxyBlockUDPKey] ? [standard boolForKey:IXProxyBlockUDPKey] : YES)
        }];
        [self persistSettings];
        return;
    }
    if (suiteProfiles.count == 0) {
        NSDictionary *saved = IXProxyKeychainRead();
        if ([saved[@"profiles"] isKindOfClass:[NSArray class]] && [saved[@"profiles"] count] > 0) {
            [self adoptPayload:saved];
        }
    }
}

- (NSUserDefaults *)settingsStore {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [self restoreStoredSettings];
    });
    return IXProxySuite();
}

- (BOOL)killSwitch {
    NSUserDefaults *store = [self settingsStore];
    id value = [store objectForKey:IXProxyKillSwitchKey];
    if (!value) return YES;
    return [store boolForKey:IXProxyKillSwitchKey];
}

- (BOOL)blockUDP {
    NSUserDefaults *store = [self settingsStore];
    id value = [store objectForKey:IXProxyBlockUDPKey];
    if (!value) return YES;
    return [store boolForKey:IXProxyBlockUDPKey];
}

- (BOOL)isEnabled {
    return [[self settingsStore] boolForKey:IXProxyEnabledKey];
}

- (NSString *)xhttpModeForProfile:(IXVLESSProfile *)profile {
    if (profile.uri.length == 0) return @"";
    NSDictionary *map = [[self settingsStore] dictionaryForKey:IXProxyXHTTPModeKey];
    NSString *mode = map[profile.uri];
    return [mode isKindOfClass:[NSString class]] ? mode : @"";
}

- (void)setXHTTPMode:(NSString *)mode forProfile:(IXVLESSProfile *)profile {
    if (profile.uri.length == 0) return;
    NSMutableDictionary *map = [[[self settingsStore] dictionaryForKey:IXProxyXHTTPModeKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (mode.length == 0) [map removeObjectForKey:profile.uri];
    else map[profile.uri] = mode;
    [[self settingsStore] setObject:map forKey:IXProxyXHTTPModeKey];
    [self persistSettings];
    if ([self isEnabled] && [profile.uri isEqualToString:[self selectedProfile].uri]) {
        [self setEnabled:YES completion:nil];
    }
}

- (void)setKillSwitch:(BOOL)on {
    [[self settingsStore] setBool:on forKey:IXProxyKillSwitchKey];
    [self persistSettings];
    IXTrafficGuardSetRuntime(IXTrafficGuardVPNOn(), IXTrafficGuardProxyUp(), on, [self blockUDP]);
}

- (void)setBlockUDP:(BOOL)on {
    [[self settingsStore] setBool:on forKey:IXProxyBlockUDPKey];
    [self persistSettings];
    IXTrafficGuardSetRuntime(IXTrafficGuardVPNOn(), IXTrafficGuardProxyUp(), [self killSwitch], on);
}

- (NSArray<IXVLESSProfile *> *)profiles {
    NSArray *uris = [[self settingsStore] arrayForKey:IXProxyProfilesKey];
    NSMutableArray *profiles = [NSMutableArray array];
    for (id item in uris) {
        if (![item isKindOfClass:[NSString class]]) continue;
        IXVLESSProfile *profile = [IXVLESSProfile profileFromURI:item error:nil];
        if (profile) [profiles addObject:profile];
    }
    return profiles;
}

- (void)storeURIs:(NSArray<NSString *> *)uris selected:(NSString *)selected {
    NSUserDefaults *store = [self settingsStore];
    [store setObject:uris ?: @[] forKey:IXProxyProfilesKey];
    if (selected.length) {
        [store setObject:selected forKey:IXProxySelectedKey];
    } else {
        [store removeObjectForKey:IXProxySelectedKey];
    }
    [self persistSettings];
}

- (nullable IXVLESSProfile *)selectedProfile {
    NSString *selected = [[self settingsStore] stringForKey:IXProxySelectedKey];
    NSArray<IXVLESSProfile *> *profiles = [self profiles];
    for (IXVLESSProfile *profile in profiles) {
        if ([profile.uri isEqualToString:selected]) return profile;
    }
    return profiles.firstObject;
}

- (void)addProfilesFromText:(NSString *)text error:(NSError **)error {
    NSArray<IXVLESSProfile *> *incoming = [IXVLESSProfile profilesFromPaste:text];
    if (incoming.count == 0) {
        if (error) *error = IXProxyError(@"No vless://, trojan://, vmess://, or ss:// links were found.");
        return;
    }
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (IXVLESSProfile *profile in [self profiles]) [uris addObject:profile.uri];
    NSString *selected = [[self settingsStore] stringForKey:IXProxySelectedKey];
    for (IXVLESSProfile *profile in incoming) {
        if (![uris containsObject:profile.uri]) [uris addObject:profile.uri];
        if (!selected.length) selected = profile.uri;
    }
    [self storeURIs:uris selected:selected];
}

- (void)removeProfileAtIndex:(NSUInteger)index {
    NSMutableArray<IXVLESSProfile *> *profiles = [[self profiles] mutableCopy];
    if (index >= profiles.count) return;
    BOOL removingSelected = [profiles[index].uri isEqualToString:[self selectedProfile].uri];
    [profiles removeObjectAtIndex:index];
    NSMutableArray *uris = [NSMutableArray array];
    for (IXVLESSProfile *profile in profiles) [uris addObject:profile.uri];
    NSString *selected = removingSelected ? profiles.firstObject.uri : [self selectedProfile].uri;
    [self storeURIs:uris selected:selected];
    if (removingSelected && [self isEnabled]) {
        [self setEnabled:NO completion:nil];
    }
}

- (void)selectProfile:(IXVLESSProfile *)profile {
    if (!profile) return;
    [[self settingsStore] setObject:profile.uri forKey:IXProxySelectedKey];
    [self persistSettings];
}

- (void)stopListeners {
    if (_statsTimer) {
        dispatch_source_cancel(_statsTimer);
        _statsTimer = nil;
    }
    if (_usingXray) {
        IXRayStop();
        _usingXray = NO;
    }
    [_native stop];
    _native = nil;
}

- (void)stopEngine {
    [self stopListeners];
    IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
    IXTrafficGuardUninstall();
}

- (void)rememberXHTTPMode:(NSString *)mode uri:(NSString *)uri {
    if (uri.length == 0 || mode.length == 0) return;
    NSMutableDictionary *map = [[[self settingsStore] dictionaryForKey:IXProxyXHTTPModeKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    map[uri] = mode;
    [[self settingsStore] setObject:map forKey:IXProxyXHTTPModeKey];
    [self persistSettings];
}

- (BOOL)launchXray:(IXVLESSProfile *)profile error:(NSString **)why {
#if !IX_HAS_XRAY
    (void)profile;
    if (why) *why = @"This build has no Xray core.";
    return NO;
#else
    NSString *json = [profile xrayJSONWithSocksPort:kSocksPort httpPort:kHTTPPort];
    NSString *redacted = profile.uuid.length
        ? [json stringByReplacingOccurrencesOfString:profile.uuid withString:@"<UUID>" options:NSCaseInsensitiveSearch range:NSMakeRange(0, json.length)]
        : json;
    [self note:redacted];
    char *err = IXRayStart((char *)json.UTF8String);
    if (err && profile.outboundInterface.length) {
        NSString *message = [NSString stringWithUTF8String:err];
        if ([message rangeOfString:@"interface" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            free(err);
            err = NULL;
            [self note:[NSString stringWithFormat:@"Could not bind %@, retrying on the system route.", profile.outboundInterface]];
            profile.outboundInterface = nil;
            _boundInterface = nil;
            json = [profile xrayJSONWithSocksPort:kSocksPort httpPort:kHTTPPort];
            err = IXRayStart((char *)json.UTF8String);
        }
    }
    if (err) {
        NSString *message = [NSString stringWithUTF8String:err];
        free(err);
        if (why) *why = message.length ? message : @"Xray failed to start.";
        return NO;
    }
    _usingXray = YES;
    _engineName = @"Xray";
    char *version = IXRayVersion();
    if (version) {
        _engineName = [NSString stringWithFormat:@"Xray %@", [NSString stringWithUTF8String:version]];
        free(version);
    }
    return YES;
#endif
}

- (BOOL)listenerReady:(IXVLESSProfile *)profile error:(NSError **)error {
    if ([self waitForLocalProxy:1.5]) return YES;
    [self note:@"The local proxy is not accepting connections. Restarting the listener."];
    [self stopListeners];
    usleep(250 * 1000);
    NSString *why = nil;
    if (![self launchXray:profile error:&why]) {
        if (error) *error = IXProxyError(why ?: @"Xray failed to start.");
        return NO;
    }
    if ([self waitForLocalProxy:1.5]) return YES;
    if (error) *error = IXProxyError(@"The local proxy is not accepting connections.");
    return NO;
}

- (BOOL)runEngine:(IXVLESSProfile *)profile timeout:(NSTimeInterval)timeout error:(NSError **)error {
    [self stopListeners];
#if IX_HAS_XRAY
    NSError *loadError = nil;
    if (!IXRayCoreLoad(&loadError)) {
        if (profile.needsXray) {
            if (error) *error = loadError ?: IXProxyError(@"Xray could not be loaded.");
            return NO;
        }
        NSLog(@"[InstagramX] Xray dylib unavailable (%@), trying the built-in engine", loadError.localizedDescription);
    } else {
        NSString *why = nil;
        if ([self launchXray:profile error:&why]) {
            if (![self listenerReady:profile error:error]) return NO;
            return [self confirmTunnel:error timeout:timeout];
        }
        if (profile.needsXray) {
            if (error) *error = IXProxyError(why ?: @"Xray failed to start.");
            return NO;
        }
        NSLog(@"[InstagramX] Xray failed (%@), trying the built-in engine", why);
    }
#endif
    if (profile.needsXray) {
        if (error) *error = IXProxyError(@"This link needs Xray (REALITY, Vision, gRPC, or XHTTP). This build only includes the built-in TCP/TLS/WebSocket engine.");
        return NO;
    }
    _native = [IXNativeEngine new];
    NSError *nativeError = nil;
    if (![_native startWithProfile:profile error:&nativeError]) {
        if (error) *error = nativeError;
        return NO;
    }
    _usingXray = NO;
    _engineName = @"Built-in VLESS";
    if (![self waitForLocalProxy:1.5]) {
        if (error) *error = IXProxyError(@"The local proxy is not accepting connections.");
        return NO;
    }
    return [self confirmTunnel:error timeout:timeout];
}

- (NSArray<NSString *> *)xhttpModesToTry:(IXVLESSProfile *)profile {
    NSMutableArray<NSString *> *modes = [NSMutableArray array];
    NSArray<NSString *> *order = @[@"auto", @"packet-up", @"stream-up", @"stream-one"];
    NSString *saved = [IXVLESSProfile xrayXHTTPModeFrom:[self xhttpModeForProfile:profile]];
    if (saved.length && [order containsObject:saved] && ![[self xhttpModeForProfile:profile] isEqualToString:@""]) {
        [modes addObject:saved];
    }
    for (NSString *mode in order) {
        if (![modes containsObject:mode]) [modes addObject:mode];
    }
    return modes;
}

- (BOOL)startProfile:(IXVLESSProfile *)profile error:(NSError **)error {
#if IX_LITE
    (void)profile;
    if (error) *error = IXProxyError(@"Instagram X Lite does not include the VPN.");
    return NO;
#else
    NSInteger generation = _generation;
    // Resolve before the traffic hooks exist. URLSession here is a direct
    // connection, and the IP is only written into dns.hosts. vnext stays the domain.
    if ([self hostIsAddress:profile.host]) profile.dialAddress = nil;
    else profile.dialAddress = [self resolveHost:profile.host];
    if (generation != _generation) return NO;
    NSString *iface = [self physicalInterface];
    _boundInterface = iface;
    profile.outboundInterface = iface;
    if (iface.length) [self note:[NSString stringWithFormat:@"Binding Xray to %@.", iface]];
    else [self note:@"No Wi-Fi or cellular address. Xray will use the system route."];
    if (!IXTrafficGuardInstall()) {
        if (error) *error = IXProxyError(@"Could not install the traffic hooks, so the VPN stayed off.");
        return NO;
    }
    IXTrafficGuardSetPorts(kSocksPort, kHTTPPort);
    IXTrafficGuardSetProxyHost(profile.host.UTF8String, profile.port);
    IXTrafficGuardSetRuntime(YES, NO, YES, [self blockUDP]);

    BOOL xhttp = [profile.network isEqualToString:@"xhttp"] || [profile.network isEqualToString:@"splithttp"];
    if (!xhttp) {
        _activeXHTTPMode = nil;
        return [self runEngine:profile timeout:8 error:error];
    }
    NSError *last = nil;
    for (NSString *mode in [self xhttpModesToTry:profile]) {
        if (generation != _generation) return NO;
        profile.mode = mode;
        _activeXHTTPMode = mode;
        [self note:[NSString stringWithFormat:@"XHTTP trying mode %@.", mode]];
        NSError *step = nil;
        if ([self runEngine:profile timeout:5 error:&step]) {
            [self rememberXHTTPMode:mode uri:profile.uri];
            [self note:[NSString stringWithFormat:@"XHTTP kept mode %@.", mode]];
            return YES;
        }
        last = step;
        [self note:[NSString stringWithFormat:@"XHTTP mode %@ did not answer.", mode]];
    }
    if (error) *error = last ?: IXProxyError(@"The tunnel did not pass the connectivity test.");
    return NO;
#endif
}

- (void)setEnabled:(BOOL)enabled completion:(void (^)(NSError *))completion {
#if IX_LITE
    if (enabled) {
        _status = IXProxyStatusFailed;
        _lastError = [SCIResolvedLanguageCode() hasPrefix:@"fa"] ? @"نسخهٔ سبک اینستاگرام ایکس فیلترشکن ندارد." : @"Instagram X Lite does not include the VPN.";
        [[self settingsStore] setBool:NO forKey:IXProxyEnabledKey];
        [self persistSettings];
        if (completion) completion(IXProxyError(_lastError));
        return;
    }
#endif
    NSInteger generation = ++_generation;
    if (!enabled) {
        dispatch_async(IXProxyQueue(), ^{
            if (generation != self->_generation) return;
            [self stopEngine];
            self->_activeXHTTPMode = nil;
            self->_boundInterface = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_generation) return;
                self->_status = IXProxyStatusOff;
                self->_lastError = nil;
                [[self settingsStore] setBool:NO forKey:IXProxyEnabledKey];
                [self persistSettings];
                if (completion) completion(nil);
            });
        });
        return;
    }
    IXVLESSProfile *profile = [self selectedProfile];
    if (!profile) {
        _status = IXProxyStatusFailed;
        _lastError = @"Add a vless://, trojan://, vmess://, or ss:// link first.";
        [[self settingsStore] setBool:NO forKey:IXProxyEnabledKey];
        [self persistSettings];
        if (completion) completion(IXProxyError(_lastError));
        return;
    }
    _status = IXProxyStatusConnecting;
    _lastError = nil;
    dispatch_async(IXProxyQueue(), ^{
        if (generation != self->_generation) return;
        [self stopEngine];
        NSError *error = nil;
        BOOL ok = [self startProfile:profile error:&error];
        if (!ok && generation == self->_generation) [self stopEngine];
        NSString *message = error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (ok) {
                self->_status = IXProxyStatusConnected;
                self->_lastError = nil;
                [[self settingsStore] setBool:YES forKey:IXProxyEnabledKey];
                [self persistSettings];
                IXTrafficGuardSetRuntime(YES, YES, [self killSwitch], [self blockUDP]);
            } else {
                self->_status = IXProxyStatusFailed;
                self->_lastError = message ?: @"Could not start the proxy.";
                [[self settingsStore] setBool:NO forKey:IXProxyEnabledKey];
                [self persistSettings];
            }
            if (completion) completion(ok ? nil : (error ?: IXProxyError(message ?: @"Could not start the proxy.")));
        });
    });
}

- (void)restoreOnLaunch {
    [self restoreStoredSettings];
    if (IXLaunchGuardIsSafeMode()) {
        NSLog(@"[InstagramX] safe mode: not restoring the VPN");
        return;
    }
    if (![self isEnabled]) return;
    [self setEnabled:YES completion:^(NSError *error) {
        if (error) NSLog(@"[InstagramX] proxy restore failed: %@", error.localizedDescription);
    }];
}

- (uint64_t)bytesUp { return _bytesUp; }
- (uint64_t)bytesDown { return _bytesDown; }
- (double)speedUp { return _speedUp; }
- (double)speedDown { return _speedDown; }
- (NSInteger)lastPingMs { return _lastPingMs; }

- (void)note:(NSString *)line {
    if (line.length == 0) return;
    if (!_logLines) _logLines = [NSMutableArray array];
    [_logLines addObject:line];
    if (_logLines.count > 80) [_logLines removeObjectsInRange:NSMakeRange(0, _logLines.count - 80)];
}

- (NSString *)recentLog {
    IXVLESSProfile *profile = [self selectedProfile];
    BOOL xhttp = [profile.network isEqualToString:@"xhttp"] || [profile.network isEqualToString:@"splithttp"];
    NSString *picked = _activeXHTTPMode.length ? _activeXHTTPMode : [self xhttpModeForProfile:profile];
    NSString *rawMode = picked.length ? picked : profile.mode;
    NSString *mode = xhttp ? [IXVLESSProfile xrayXHTTPModeFrom:rawMode] : @"n/a";
    NSString *header = [NSString stringWithFormat:@"Instagram X %@\nxhttp mode: %@\ninterface: %@", SCIVersionString ?: @"", mode, _boundInterface ?: @"system"];
    NSMutableArray *lines = [_logLines mutableCopy] ?: [NSMutableArray array];
    char *raw = IXRayCopyLog();
    if (raw) {
        NSString *text = [NSString stringWithUTF8String:raw];
        free(raw);
        if (text.length) [lines addObject:text];
    }
    NSString *body = lines.count ? [lines componentsJoinedByString:@"\n"] : @"No log yet.";
    return [header stringByAppendingFormat:@"\n%@", body];
}

- (void)sampleStats {
    uint64_t up = 0, down = 0;
    IXRayTraffic(&up, &down);
    NSTimeInterval now = CACurrentMediaTime();
    if (_sampleTime > 0) {
        double dt = now - _sampleTime;
        if (dt > 0.2) {
            _speedUp = (double)(up - _sampleUp) / dt;
            _speedDown = (double)(down - _sampleDown) / dt;
            if (_speedUp < 0) _speedUp = 0;
            if (_speedDown < 0) _speedDown = 0;
        }
    }
    _sampleUp = up;
    _sampleDown = down;
    _sampleTime = now;
    _bytesUp = up;
    _bytesDown = down;
}

- (void)startStats {
    if (_statsTimer) return;
    _sampleTime = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(1 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak IXProxyManager *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf sampleStats];
    });
    _statsTimer = timer;
    dispatch_resume(timer);
}

- (BOOL)hostIsAddress:(NSString *)host {
    if (host.length == 0) return NO;
    struct in_addr v4;
    struct in6_addr v6;
    return inet_pton(AF_INET, host.UTF8String, &v4) == 1 || inet_pton(AF_INET6, host.UTF8String, &v6) == 1;
}

- (NSString *)addressFromDoHJSON:(NSData *)data {
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray *answers = [obj isKindOfClass:[NSDictionary class]] ? obj[@"Answer"] : nil;
    if (![answers isKindOfClass:[NSArray class]]) return nil;
    for (id item in answers) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *type = item[@"type"];
        NSString *value = item[@"data"];
        if (type.intValue == 1 && [value isKindOfClass:[NSString class]] && [self hostIsAddress:value]) return value;
    }
    return nil;
}

- (NSString *)resolveHostBySystem:(NSString *)host {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    int gai = IXOrigGetaddrinfo(host.UTF8String, "0", &hints, &res);
    if (gai != 0 || !res || res->ai_family != AF_INET) {
        if (res) freeaddrinfo(res);
        return nil;
    }
    char buf[INET_ADDRSTRLEN];
    const char *text = inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, buf, sizeof(buf));
    NSString *ip = text ? [NSString stringWithUTF8String:text] : nil;
    freeaddrinfo(res);
    if (ip.length) [self note:[NSString stringWithFormat:@"Resolved %@ to %@ with the system resolver.", host, ip]];
    return ip.length ? ip : nil;
}

- (NSString *)resolveHost:(NSString *)host {
    if ([self hostIsAddress:host]) return host;
    NSString *escaped = [host stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: host;
    NSArray<NSString *> *urls = @[
        [NSString stringWithFormat:@"https://1.1.1.1/dns-query?name=%@&type=A", escaped],
        [NSString stringWithFormat:@"https://1.0.0.1/dns-query?name=%@&type=A", escaped],
        [NSString stringWithFormat:@"https://8.8.8.8/resolve?name=%@&type=A", escaped],
        [NSString stringWithFormat:@"https://8.8.4.4/resolve?name=%@&type=A", escaped],
        [NSString stringWithFormat:@"https://dns.google/resolve?name=%@&type=A", escaped],
        [NSString stringWithFormat:@"https://cloudflare-dns.com/dns-query?name=%@&type=A", escaped]
    ];
    IXDoHTrust *trust = [IXDoHTrust new];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.connectionProxyDictionary = @{@"HTTPEnable": @NO, @"HTTPSEnable": @NO, @"SOCKSEnable": @NO};
    config.timeoutIntervalForRequest = 4;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:trust delegateQueue:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSLock *lock = [NSLock new];
    __block NSString *found = nil;
    for (NSString *raw in urls) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:raw]];
        [request setValue:@"application/dns-json" forHTTPHeaderField:@"Accept"];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            NSString *ip = error ? nil : [self addressFromDoHJSON:data];
            if (ip.length) {
                [lock lock];
                if (!found) found = [ip copy];
                [lock unlock];
                dispatch_semaphore_signal(done);
            }
        }];
        [task resume];
    }
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)));
    [session invalidateAndCancel];
    if (found.length) {
        [self note:[NSString stringWithFormat:@"Resolved %@ to %@ by direct DNS-over-HTTPS.", host, found]];
        return found;
    }
    NSString *system = [self resolveHostBySystem:host];
    if (system.length) return system;
    [self note:[NSString stringWithFormat:@"Could not resolve %@. Xray will resolve it on the direct outbound.", host]];
    return nil;
}

- (BOOL)waitForLocalProxy:(NSTimeInterval)timeout {
    NSTimeInterval deadline = CACurrentMediaTime() + timeout;
    while (CACurrentMediaTime() < deadline) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return NO;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        struct sockaddr_in local;
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_len = sizeof(local);
        local.sin_port = htons(IXTrafficGuardHTTPPort());
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int rc = IXOrigConnect(fd, (struct sockaddr *)&local, sizeof(local));
        BOOL open = NO;
        if (rc == 0) {
            open = YES;
        } else if (errno == EINPROGRESS) {
            struct pollfd pfd = {.fd = fd, .events = POLLOUT};
            if (poll(&pfd, 1, 200) > 0) {
                int soerr = 0;
                socklen_t len = sizeof(soerr);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
                open = soerr == 0;
            }
        }
        close(fd);
        if (open) return YES;
        usleep(40 * 1000);
    }
    return NO;
}

- (NSInteger)httpProbe:(NSString *)urlString timeout:(NSTimeInterval)timeout error:(NSString **)errorOut {
    uint16_t port = IXTrafficGuardHTTPPort();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (errorOut) *errorOut = @"Could not open a socket for the connectivity test.";
        return -1;
    }
    int seconds = (int)timeout;
    if (seconds < 1) seconds = 1;
    struct timeval tv = {.tv_sec = seconds, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int nosig = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_len = sizeof(local);
    local.sin_port = htons(port);
    local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    NSTimeInterval start = CACurrentMediaTime();
    if (IXOrigConnect(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
        close(fd);
        if (errorOut) *errorOut = @"The local proxy is not accepting connections.";
        return -1;
    }
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\nUser-Agent: InstagramX\r\n\r\n", urlString, url.host ?: @"connectivitycheck.gstatic.com"];
    const char *bytes = request.UTF8String;
    size_t sent = 0;
    size_t len = strlen(bytes);
    while (sent < len) {
        ssize_t n = send(fd, bytes + sent, len - sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            if (errorOut) *errorOut = @"Could not write the connectivity test to the proxy.";
            return -1;
        }
        sent += (size_t)n;
    }
    // Read until the proxy closes. Closing after the first packet made Xray's
    // next write fail with "broken pipe" even though the status line said 204.
    NSMutableData *received = [NSMutableData data];
    char buf[1024];
    while (received.length < 16384) {
        ssize_t got = recv(fd, buf, sizeof(buf), 0);
        if (got == 0) break;
        if (got < 0) {
            if (errno == EINTR) continue;
            break;
        }
        [received appendBytes:buf length:(NSUInteger)got];
        NSData *marker = [NSData dataWithBytes:"\r\n\r\n" length:4];
        if ([received rangeOfData:marker options:0 range:NSMakeRange(0, received.length)].location != NSNotFound) {
            struct timeval drain = {.tv_sec = 1, .tv_usec = 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &drain, sizeof(drain));
        }
    }
    close(fd);
    if (received.length == 0) {
        if (errorOut) *errorOut = @"The tunnel did not answer the connectivity test. The server may be blocked, or the VLESS link was not accepted.";
        return -1;
    }
    NSString *head = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding] ?: @"";
    NSRange lineEnd = [head rangeOfString:@"\r\n"];
    NSString *status = lineEnd.location == NSNotFound ? head : [head substringToIndex:lineEnd.location];
    if ([status containsString:@" 204"]) {
        return (NSInteger)((CACurrentMediaTime() - start) * 1000.0);
    }
    if (errorOut) *errorOut = [NSString stringWithFormat:@"Connectivity test failed (%@).", status.length ? status : @"empty response"];
    return -1;
}

- (NSInteger)tunnelProbe:(NSString **)errorOut timeout:(NSTimeInterval)timeout {
    NSArray *urls = @[
        @"http://connectivitycheck.gstatic.com/generate_204",
        @"http://www.gstatic.com/generate_204"
    ];
    NSString *last = nil;
    for (NSString *url in urls) {
        NSString *why = nil;
        NSInteger ms = [self httpProbe:url timeout:timeout error:&why];
        if (ms >= 0) return ms;
        last = why;
        [self note:why ?: @"Connectivity test failed."];
    }
    if (errorOut) *errorOut = last ?: @"The tunnel did not pass the connectivity test.";
    return -1;
}

- (BOOL)confirmTunnel:(NSError **)error timeout:(NSTimeInterval)timeout {
    if (![self waitForLocalProxy:1.5]) {
        [self note:@"The local proxy is not accepting connections."];
        if (error) *error = IXProxyError(@"The local proxy is not accepting connections.");
        return NO;
    }
    NSString *why = nil;
    NSInteger ms = [self tunnelProbe:&why timeout:timeout];
    if (ms < 0) {
        if (error) *error = IXProxyError(why ?: @"The tunnel did not pass the connectivity test.");
        return NO;
    }
    _lastPingMs = ms;
    _status = IXProxyStatusConnected;
    _lastError = nil;
    IXTrafficGuardSetRuntime(YES, YES, [self killSwitch], [self blockUDP]);
    [self note:[NSString stringWithFormat:@"Tunnel answered generate_204 in %ld ms.", (long)ms]];
    [self startStats];
    return YES;
}

- (void)runTunnelTest:(void (^)(NSInteger, NSError *))completion {
    if (_status != IXProxyStatusConnected) {
        if (completion) completion(-1, IXProxyError(@"Turn the VPN on first. Connected is shown only after a request succeeds through the tunnel."));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *why = nil;
        NSInteger ms = [self tunnelProbe:&why timeout:8];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ms >= 0) self->_lastPingMs = ms;
            if (completion) completion(ms, ms >= 0 ? nil : IXProxyError(why ?: @"The test failed."));
        });
    });
}

- (NSString *)fetchExitURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    __block NSData *body = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 12;
    config.timeoutIntervalForResource = 12;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        body = data;
        error = taskError;
        dispatch_semaphore_signal(gate);
    }];
    [task resume];
    dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC));
    [session invalidateAndCancel];
    if (error || body.length == 0) return nil;
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
}

- (void)checkExitIP:(void (^)(NSString *, NSError *))completion {
    if (_status != IXProxyStatusConnected || !IXTrafficGuardProxyUp()) {
        if (completion) completion(nil, IXProxyError(@"Turn the VPN on first. The check runs through the tunnel."));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *ipify = [[self fetchExitURL:@"https://api.ipify.org"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *info = [self fetchExitURL:@"https://ifconfig.co/json"];
        NSString *v6 = [[self fetchExitURL:@"https://ipv6.icanhazip.com"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *country = @"";
        NSString *ifconfigIP = @"";
        NSData *infoData = [info dataUsingEncoding:NSUTF8StringEncoding];
        id json = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:nil] : nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            id ip = json[@"ip"];
            id place = json[@"country"];
            if ([ip isKindOfClass:[NSString class]]) ifconfigIP = ip;
            if ([place isKindOfClass:[NSString class]]) country = place;
        }
        BOOL v6ok = [v6 containsString:@":"];
        NSString *summary = [NSString stringWithFormat:@"Exit IP %@\nCountry %@\nIPv6 %@",
                             ipify.length ? ipify : (ifconfigIP.length ? ifconfigIP : @"unavailable"),
                             country.length ? country : @"unavailable",
                             v6ok ? v6 : @"none"];
        BOOL any = ipify.length || ifconfigIP.length;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!any) {
                if (completion) completion(nil, IXProxyError(@"The tunnel did not return an exit IP."));
                return;
            }
            [self note:summary];
            if (completion) completion(summary, nil);
        });
    });
}

- (void)testProfile:(IXVLESSProfile *)profile completion:(void (^)(NSInteger, NSError *))completion {
    if (!profile) {
        if (completion) completion(-1, IXProxyError(@"No server selected."));
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSInteger millis = [self tcpLatency:profile error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(millis, error);
        });
    });
}

- (NSInteger)tcpLatency:(IXVLESSProfile *)profile error:(NSError **)error {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    char port[8];
    snprintf(port, sizeof(port), "%u", profile.port);
    struct addrinfo *res = NULL;
    int gai = IXOrigGetaddrinfo(profile.host.UTF8String, port, &hints, &res);
    if (gai != 0 || !res) {
        if (error) *error = IXProxyError([NSString stringWithFormat:@"Could not resolve %@.", profile.host]);
        return -1;
    }
    int fd = -1;
    struct addrinfo *chosen = NULL;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd >= 0) {
            chosen = ai;
            break;
        }
    }
    if (fd < 0 || !chosen) {
        freeaddrinfo(res);
        if (error) *error = IXProxyError(@"Could not open a test socket.");
        return -1;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    NSTimeInterval start = CACurrentMediaTime();
    int rc = IXOrigConnect(fd, chosen->ai_addr, chosen->ai_addrlen);
    freeaddrinfo(res);
    if (rc != 0 && errno != EINPROGRESS) {
        close(fd);
        if (error) *error = IXProxyError(@"The server refused the test connection.");
        return -1;
    }
    struct pollfd pfd = {.fd = fd, .events = POLLOUT};
    rc = poll(&pfd, 1, 5000);
    NSInteger millis = (NSInteger)((CACurrentMediaTime() - start) * 1000.0);
    int soerr = 0;
    socklen_t sl = sizeof(soerr);
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
    close(fd);
    if (rc <= 0 || soerr != 0) {
        if (error) *error = IXProxyError(rc == 0 ? @"Timed out after 5 seconds." : @"The server did not accept a TCP connection.");
        return -1;
    }
    return millis;
}

@end
