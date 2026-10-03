#import "IXProxyManager.h"
#import "IXNativeEngine.h"
#import "IXTrafficGuard.h"
#import "IXRayLoader.h"
#import "../Launch/IXLaunchGuard.h"

#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <netdb.h>
#import <poll.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <unistd.h>

NSString *const IXProxyEnabledKey = @"ix_vless_enabled";
NSString *const IXProxyKillSwitchKey = @"ix_killswitch";
NSString *const IXProxyBlockUDPKey = @"ix_block_udp";
NSString *const IXProxyProfilesKey = @"ix_vless_profiles";
NSString *const IXProxySelectedKey = @"ix_vless_selected";

static const uint16_t kSocksPort = 61850;
static const uint16_t kHTTPPort = 61851;

static NSError *IXProxyError(NSString *message) {
    return [NSError errorWithDomain:@"InstagramX.Proxy" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Proxy error"}];
}

@implementation IXProxyManager {
    IXNativeEngine *_native;
    BOOL _usingXray;
    IXProxyStatus _status;
    NSString *_lastError;
    NSString *_engineName;
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
#if IX_LITE
        _engineName = @"Lite build";
#elif IX_HAS_XRAY
        _engineName = @"Xray (loads when the VPN is on)";
#else
        _engineName = @"Built-in VLESS";
#endif
        IXTrafficGuardSetPorts(kSocksPort, kHTTPPort);
        IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
    }
    return self;
}

- (IXProxyStatus)status { return _status; }
- (NSString *)lastError { return _lastError; }
- (NSString *)engineName { return _engineName ?: @"Built-in VLESS"; }
- (BOOL)xrayLinked {
#if IX_HAS_XRAY
    return YES;
#else
    return NO;
#endif
}

- (NSString *)statusText {
    switch (_status) {
        case IXProxyStatusConnecting: return @"Connecting";
        case IXProxyStatusConnected: return @"Connected";
        case IXProxyStatusFailed: return _lastError.length ? [NSString stringWithFormat:@"Disconnected · %@", _lastError] : @"Disconnected";
        default: return @"Off";
    }
}

+ (NSString *)statusSubtitle {
    return [NSString stringWithFormat:@"%@ · %@", IXProxyManager.shared.statusText, IXProxyManager.shared.engineName];
}

- (BOOL)killSwitch {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:IXProxyKillSwitchKey];
    if (!value) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:IXProxyKillSwitchKey];
}

- (BOOL)blockUDP {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:IXProxyBlockUDPKey];
    if (!value) return YES;
    return [[NSUserDefaults standardUserDefaults] boolForKey:IXProxyBlockUDPKey];
}

- (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:IXProxyEnabledKey];
}

- (void)setKillSwitch:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:IXProxyKillSwitchKey];
    IXTrafficGuardSetRuntime(IXTrafficGuardVPNOn(), IXTrafficGuardProxyUp(), on, [self blockUDP]);
}

- (void)setBlockUDP:(BOOL)on {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:IXProxyBlockUDPKey];
    IXTrafficGuardSetRuntime(IXTrafficGuardVPNOn(), IXTrafficGuardProxyUp(), [self killSwitch], on);
}

- (NSArray<IXVLESSProfile *> *)profiles {
    NSArray *uris = [[NSUserDefaults standardUserDefaults] arrayForKey:IXProxyProfilesKey];
    NSMutableArray *profiles = [NSMutableArray array];
    for (id item in uris) {
        if (![item isKindOfClass:[NSString class]]) continue;
        IXVLESSProfile *profile = [IXVLESSProfile profileFromURI:item error:nil];
        if (profile) [profiles addObject:profile];
    }
    return profiles;
}

- (void)storeURIs:(NSArray<NSString *> *)uris selected:(NSString *)selected {
    [[NSUserDefaults standardUserDefaults] setObject:uris forKey:IXProxyProfilesKey];
    if (selected.length) {
        [[NSUserDefaults standardUserDefaults] setObject:selected forKey:IXProxySelectedKey];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:IXProxySelectedKey];
    }
}

- (nullable IXVLESSProfile *)selectedProfile {
    NSString *selected = [[NSUserDefaults standardUserDefaults] stringForKey:IXProxySelectedKey];
    NSArray<IXVLESSProfile *> *profiles = [self profiles];
    for (IXVLESSProfile *profile in profiles) {
        if ([profile.uri isEqualToString:selected]) return profile;
    }
    return profiles.firstObject;
}

- (void)addProfilesFromText:(NSString *)text error:(NSError **)error {
    NSArray<IXVLESSProfile *> *incoming = [IXVLESSProfile profilesFromPaste:text];
    if (incoming.count == 0) {
        if (error) *error = IXProxyError(@"No vless:// links were found. Paste one link, several lines, or a base64 subscription.");
        return;
    }
    NSMutableArray<NSString *> *uris = [NSMutableArray array];
    for (IXVLESSProfile *profile in [self profiles]) [uris addObject:profile.uri];
    NSString *selected = [[NSUserDefaults standardUserDefaults] stringForKey:IXProxySelectedKey];
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
    [[NSUserDefaults standardUserDefaults] setObject:profile.uri forKey:IXProxySelectedKey];
}

- (void)stopEngine {
    if (_usingXray) {
        IXRayStop();
        _usingXray = NO;
    }
    [_native stop];
    _native = nil;
    IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
    IXTrafficGuardUninstall();
    _status = IXProxyStatusOff;
}

- (BOOL)startProfile:(IXVLESSProfile *)profile error:(NSError **)error {
#if IX_LITE
    (void)profile;
    if (error) *error = IXProxyError(@"Instagram X Lite does not include the VPN.");
    return NO;
#else
    if (!IXTrafficGuardInstall()) {
        if (error) *error = IXProxyError(@"Could not install the traffic hooks, so the VPN stayed off.");
        return NO;
    }
    IXTrafficGuardSetPorts(kSocksPort, kHTTPPort);
    IXTrafficGuardSetProxyHost(profile.host.UTF8String, profile.port);
    // Fail closed while the listener is coming up.
    IXTrafficGuardSetRuntime(YES, NO, YES, [self blockUDP]);

#if IX_HAS_XRAY
    NSError *loadError = nil;
    if (!IXRayCoreLoad(&loadError)) {
        if (profile.needsXray) {
            IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
            IXTrafficGuardUninstall();
            if (error) *error = loadError ?: IXProxyError(@"Xray could not be loaded.");
            return NO;
        }
        NSLog(@"[InstagramX] Xray dylib unavailable (%@), trying the built-in engine", loadError.localizedDescription);
    } else {
        NSString *json = [profile xrayJSONWithSocksPort:kSocksPort httpPort:kHTTPPort];
        char *err = IXRayStart((char *)json.UTF8String);
        if (!err) {
            _usingXray = YES;
            _engineName = @"Xray";
            char *version = IXRayVersion();
            if (version) {
                _engineName = [NSString stringWithFormat:@"Xray %@", [NSString stringWithUTF8String:version]];
                free(version);
            }
            IXTrafficGuardSetRuntime(YES, YES, [self killSwitch], [self blockUDP]);
            return YES;
        }
        NSString *message = [NSString stringWithUTF8String:err];
        free(err);
        if (profile.needsXray) {
            IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
            IXTrafficGuardUninstall();
            if (error) *error = IXProxyError(message.length ? message : @"Xray failed to start.");
            return NO;
        }
        NSLog(@"[InstagramX] Xray failed (%@), trying the built-in engine", message);
    }
#endif

    if (profile.needsXray) {
        IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
        IXTrafficGuardUninstall();
        if (error) *error = IXProxyError(@"This link needs Xray (REALITY, Vision, gRPC, or XHTTP). This build only includes the built-in TCP/TLS/WebSocket engine.");
        return NO;
    }
    _native = [IXNativeEngine new];
    NSError *nativeError = nil;
    if (![_native startWithProfile:profile error:&nativeError]) {
        IXTrafficGuardSetRuntime(NO, NO, [self killSwitch], [self blockUDP]);
        IXTrafficGuardUninstall();
        if (error) *error = nativeError;
        return NO;
    }
    _usingXray = NO;
    _engineName = @"Built-in VLESS";
    IXTrafficGuardSetRuntime(YES, YES, [self killSwitch], [self blockUDP]);
    return YES;
#endif
}

- (void)setEnabled:(BOOL)enabled completion:(void (^)(NSError *))completion {
#if IX_LITE
    if (enabled) {
        _status = IXProxyStatusFailed;
        _lastError = @"Instagram X Lite does not include the VPN.";
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IXProxyEnabledKey];
        if (completion) completion(IXProxyError(_lastError));
        return;
    }
#endif
    if (!enabled) {
        [self stopEngine];
        _lastError = nil;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IXProxyEnabledKey];
        if (completion) completion(nil);
        return;
    }
    IXVLESSProfile *profile = [self selectedProfile];
    if (!profile) {
        _status = IXProxyStatusFailed;
        _lastError = @"Add a vless:// link first.";
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IXProxyEnabledKey];
        if (completion) completion(IXProxyError(_lastError));
        return;
    }
    _status = IXProxyStatusConnecting;
    _lastError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self stopEngine];
        NSError *error = nil;
        BOOL ok = [self startProfile:profile error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                self->_status = IXProxyStatusConnected;
                self->_lastError = nil;
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:IXProxyEnabledKey];
            } else {
                [self stopEngine];
                self->_status = IXProxyStatusFailed;
                self->_lastError = error.localizedDescription ?: @"Could not start the proxy.";
                [[NSUserDefaults standardUserDefaults] setBool:NO forKey:IXProxyEnabledKey];
            }
            if (completion) completion(ok ? nil : error);
        });
    });
}

- (void)restoreOnLaunch {
    if (IXLaunchGuardIsSafeMode()) {
        NSLog(@"[InstagramX] safe mode: not restoring the VPN");
        return;
    }
    if (![self isEnabled]) return;
    [self setEnabled:YES completion:^(NSError *error) {
        if (error) NSLog(@"[InstagramX] proxy restore failed: %@", error.localizedDescription);
    }];
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
