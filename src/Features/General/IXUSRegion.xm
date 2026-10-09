#import "../../Proxy/IXSymbolRebind.h"
#import <substrate.h>

#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTCarrier.h>
#import <StoreKit/StoreKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Country, carrier, storefront, and location hints. Language and the time
// zone are not hooked: Accept-Language, NSLocale language, and NSTimeZone
// stay on the values the phone already has.

static int ix_us_on = 1;
static char ix_us_timer;

static void IXUSRefresh(void) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"ix_us_region"];
    ix_us_on = value ? [value boolValue] : 1;
}

static void IXUSLog(NSString *hook, NSString *change) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if ([seen containsObject:hook]) return;
        [seen addObject:hook];
    }
    NSLog(@"[InstagramX] US region %@: %@", hook, change);
}

static BOOL IXFakeLocationOwns(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:@"fake_location_enabled"] && [defaults objectForKey:@"fake_location_lat"] && [defaults objectForKey:@"fake_location_lon"];
}

static CLLocation *IXLosAngeles(void) {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(34.0522, -118.2437)
                                         altitude:35
                               horizontalAccuracy:8
                                 verticalAccuracy:12
                                           course:-1
                                            speed:-1
                                        timestamp:[NSDate date]];
}

static BOOL IXUSIdentityKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *lower = key.lowercaseString;
    if ([lower isEqualToString:@"mid"] || [lower hasSuffix:@"_mid"] || [lower hasPrefix:@"mid_"]) return YES;
    for (NSString *part in @[@"device_id", @"deviceid", @"uuid", @"guid", @"ig_did", @"phone_id", @"waterfall"]) {
        if ([lower containsString:part]) return YES;
    }
    return NO;
}

static BOOL IXUSAnalyticsKey(NSString *key) {
    if (IXUSIdentityKey(key)) return NO;
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:
            @"mcc", @"mnc", @"sim_mcc", @"sim_mnc", @"carrier_mcc", @"carrier_mnc",
            @"phone_mcc", @"phone_mnc", @"radio_mcc", @"radio_mnc",
            @"device_country", @"device_country_code",
            @"sim_country", @"sim_country_iso", @"network_country_iso", @"iso_country_code",
            @"carrier", @"carrier_name",
            @"storefront", @"storefront_country", @"app_store_storefront", @"store_country",
            nil];
    });
    if ([keys containsObject:key]) return YES;
    BOOL upper = NO;
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c >= 'A' && c <= 'Z') { upper = YES; break; }
    }
    return upper && [keys containsObject:key.lowercaseString];
}

static id IXUSAnalyticsValue(NSString *key, id current) {
    NSString *lower = key.lowercaseString;
    NSString *text = nil;
    if ([lower hasSuffix:@"mnc"] || [lower isEqualToString:@"mnc"]) text = @"410";
    else if ([lower hasSuffix:@"mcc"] || [lower isEqualToString:@"mcc"]) text = @"310";
    else if ([lower containsString:@"carrier"]) text = @"AT&T";
    else if ([current isKindOfClass:[NSString class]] && [(NSString *)current caseInsensitiveCompare:@"USA"] == NSOrderedSame) text = @"USA";
    else text = @"US";
    if ([current isKindOfClass:[NSNumber class]] && ([lower hasSuffix:@"mcc"] || [lower hasSuffix:@"mnc"] || [lower isEqualToString:@"mcc"] || [lower isEqualToString:@"mnc"])) {
        return @([text integerValue]);
    }
    return text;
}

static BOOL IXUSHeader(NSString *field) {
    if (![field isKindOfClass:[NSString class]] || field.length == 0) return NO;
    NSString *lower = field.lowercaseString;
    if ([lower isEqualToString:@"accept-language"]) return NO;
    if ([lower containsString:@"language"] || [lower containsString:@"locale"]) return NO;
    if ([lower containsString:@"timezone"] || [lower containsString:@"time-zone"] || [lower containsString:@"time_zone"]) return NO;
    return [lower containsString:@"country"] || [lower containsString:@"carrier"] || [lower containsString:@"mcc"] || [lower containsString:@"mnc"] || [lower containsString:@"storefront"];
}

static NSString *IXUSHeaderValue(NSString *field, NSString *current) {
    NSString *lower = field.lowercaseString;
    if ([lower containsString:@"mnc"]) return @"410";
    if ([lower containsString:@"mcc"]) return @"310";
    if ([lower containsString:@"carrier"]) return @"AT&T";
    if (current.length && [current caseInsensitiveCompare:@"USA"] == NSOrderedSame) return @"USA";
    return @"US";
}

static void IXUSDeliver(CLLocationManager *manager) {
    if (!manager || !ix_us_on || IXFakeLocationOwns()) return;
    id delegate = nil;
    @try { delegate = manager.delegate; } @catch (__unused NSException *exception) { return; }
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        @try { [delegate locationManager:manager didUpdateLocations:@[IXLosAngeles()]]; }
        @catch (__unused NSException *exception) {}
    }
}

static void IXUSNotifyAuth(CLLocationManager *manager) {
    id delegate = nil;
    @try { delegate = manager.delegate; } @catch (__unused NSException *exception) { return; }
    if (!delegate) return;
    @try {
        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:manager];
        }
        if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
            [delegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedWhenInUse];
        }
    } @catch (__unused NSException *exception) {}
}

static CFDictionaryRef (*ix_orig_wifi)(CFStringRef);
static CFDictionaryRef ix_wifi(CFStringRef interfaceName) {
    if (!ix_us_on) return ix_orig_wifi ? ix_orig_wifi(interfaceName) : NULL;
    IXUSLog(@"CNCopyCurrentNetworkInfo", @"SSID LAX-WiFi BSSID 02:00:00:00:00:01");
    NSDictionary *info = @{@"SSID": @"LAX-WiFi", @"BSSID": @"02:00:00:00:00:01"};
    return (CFDictionaryRef)CFBridgingRetain(info);
}

static void IXInstallWiFi(void) {
    union { CFDictionaryRef (*fn)(CFStringRef); void *ptr; } bits;
    bits.ptr = dlsym(RTLD_DEFAULT, "CNCopyCurrentNetworkInfo");
    ix_orig_wifi = bits.fn;
    if (!ix_orig_wifi) {
        NSLog(@"[InstagramX] US region CNCopyCurrentNetworkInfo was not found");
        return;
    }
    union { CFDictionaryRef (*fn)(CFStringRef); void *ptr; } repl = { ix_wifi };
    const char *names[1] = {"CNCopyCurrentNetworkInfo"};
    void *slots[1] = {repl.ptr};
    int patched = IXSymbolRebindPermanent(names, slots, 1);
    NSLog(@"[InstagramX] US region CNCopyCurrentNetworkInfo rebound (%d slots): SSID LAX-WiFi", patched);
}

static id (*ix_orig_ig_location)(id, SEL);

static id ix_ig_location(id self, SEL _cmd) {
    if (IXFakeLocationOwns()) return ix_orig_ig_location ? ix_orig_ig_location(self, _cmd) : nil;
    if (ix_us_on) {
        IXUSLog(@"IGLocationManager.location", @"34.0522,-118.2437");
        return IXLosAngeles();
    }
    return ix_orig_ig_location ? ix_orig_ig_location(self, _cmd) : nil;
}

static void IXInstallIGLocation(void) {
    Class cls = objc_getClass("IGLocationManager");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, @selector(location));
    if (!method || ix_orig_ig_location) return;
    IMP previous = method_setImplementation(method, (IMP)ix_ig_location);
    ix_orig_ig_location = (id (*)(id, SEL))previous;
    NSLog(@"[InstagramX] US region IGLocationManager.location -> 34.0522,-118.2437 when fake location is off");
}

%hook CTCarrier
- (NSString *)mobileCountryCode {
    if (!ix_us_on) return %orig;
    NSString *was = %orig;
    IXUSLog(@"CTCarrier.mobileCountryCode", [NSString stringWithFormat:@"310 (was %@)", was ?: @"nil"]);
    return @"310";
}
- (NSString *)mobileNetworkCode {
    if (!ix_us_on) return %orig;
    NSString *was = %orig;
    IXUSLog(@"CTCarrier.mobileNetworkCode", [NSString stringWithFormat:@"410 (was %@)", was ?: @"nil"]);
    return @"410";
}
- (NSString *)isoCountryCode {
    if (!ix_us_on) return %orig;
    NSString *was = %orig;
    IXUSLog(@"CTCarrier.isoCountryCode", [NSString stringWithFormat:@"us (was %@)", was ?: @"nil"]);
    return @"us";
}
- (NSString *)carrierName {
    if (!ix_us_on) return %orig;
    NSString *was = %orig;
    IXUSLog(@"CTCarrier.carrierName", [NSString stringWithFormat:@"AT&T (was %@)", was ?: @"nil"]);
    return @"AT&T";
}
%end

%hook NSLocale
- (id)objectForKey:(id)key {
    id value = %orig;
    if (!ix_us_on || ![key isKindOfClass:[NSString class]]) return value;
    if ([key isEqualToString:(NSString *)NSLocaleCountryCode]) {
        IXUSLog(@"NSLocale.country", [NSString stringWithFormat:@"US (was %@)", value ?: @"nil"]);
        return @"US";
    }
    if ([key isEqualToString:(NSString *)NSLocaleCurrencyCode]) {
        IXUSLog(@"NSLocale.currency", [NSString stringWithFormat:@"USD (was %@)", value ?: @"nil"]);
        return @"USD";
    }
    if ([key isEqualToString:(NSString *)NSLocaleCurrencySymbol]) {
        IXUSLog(@"NSLocale.currencySymbol", [NSString stringWithFormat:@"$ (was %@)", value ?: @"nil"]);
        return @"$";
    }
    return value;
}
- (NSString *)countryCode {
    if (!ix_us_on) return %orig;
    IXUSLog(@"NSLocale.countryCode", @"US");
    return @"US";
}
- (NSString *)currencyCode {
    if (!ix_us_on) return %orig;
    IXUSLog(@"NSLocale.currencyCode", @"USD");
    return @"USD";
}
%end

%group IXUSRegionCode
%hook NSLocale
- (NSString *)regionCode {
    if (!ix_us_on) return %orig;
    IXUSLog(@"NSLocale.regionCode", @"US");
    return @"US";
}
%end
%end

%hook SKStorefront
- (NSString *)countryCode {
    if (!ix_us_on) return %orig;
    NSString *was = %orig;
    IXUSLog(@"SKStorefront.countryCode", [NSString stringWithFormat:@"USA (was %@)", was ?: @"nil"]);
    return @"USA";
}
%end

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ix_us_on && IXUSHeader(field)) {
        NSString *next = IXUSHeaderValue(field, value);
        IXUSLog([NSString stringWithFormat:@"header %@", field], [NSString stringWithFormat:@"%@ (was %@)", next, value ?: @"nil"]);
        %orig(next, field);
        return;
    }
    %orig;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (ix_us_on && IXUSHeader(field)) {
        NSString *next = IXUSHeaderValue(field, value);
        IXUSLog([NSString stringWithFormat:@"header %@", field], [NSString stringWithFormat:@"%@ (was %@)", next, value ?: @"nil"]);
        %orig(next, field);
        return;
    }
    %orig;
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)fields {
    if (!ix_us_on || ![fields isKindOfClass:[NSDictionary class]]) {
        %orig;
        return;
    }
    NSMutableDictionary *copy = nil;
    for (id key in fields) {
        if (![key isKindOfClass:[NSString class]] || !IXUSHeader(key)) continue;
        if (!copy) copy = [fields mutableCopy];
        id value = fields[key];
        NSString *current = [value isKindOfClass:[NSString class]] ? value : nil;
        NSString *next = IXUSHeaderValue(key, current);
        IXUSLog([NSString stringWithFormat:@"header %@", key], [NSString stringWithFormat:@"%@ (was %@)", next, current ?: @"nil"]);
        copy[key] = next;
    }
    %orig(copy ?: fields);
}
%end

static void (*ix_dict_orig)(id, SEL, id, id);
static void ix_dict_set(id self, SEL _cmd, id obj, id key) {
    static __thread int depth;
    if (depth) {
        if (ix_dict_orig) ix_dict_orig(self, _cmd, obj, key);
        return;
    }
    depth++;
    if (ix_us_on && [key isKindOfClass:[NSString class]] && IXUSIdentityKey((NSString *)key)) {
        if (ix_dict_orig) ix_dict_orig(self, _cmd, obj, key);
        depth--;
        return;
    }
    if (ix_us_on && [key isKindOfClass:[NSString class]] &&
        ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) &&
        IXUSAnalyticsKey((NSString *)key)) {
        id next = IXUSAnalyticsValue((NSString *)key, obj);
        IXUSLog([NSString stringWithFormat:@"analytics %@", key], [NSString stringWithFormat:@"%@ (was %@)", next, obj ?: @"nil"]);
        obj = next;
    }
    if (ix_dict_orig) ix_dict_orig(self, _cmd, obj, key);
    depth--;
}

static void IXInstallAnalytics(void) {
    Class cls = objc_getClass("__NSDictionaryM");
    if (!cls) cls = objc_getClass("NSMutableDictionary");
    if (!cls) return;
    MSHookMessageEx(cls, @selector(setObject:forKey:), (IMP)ix_dict_set, (IMP *)&ix_dict_orig);
    NSLog(@"[InstagramX] US region analytics dictionary keys hooked on %s", class_getName(cls));
}

%group IXUSHotspot
%hook NEHotspotNetwork
- (NSString *)SSID {
    if (!ix_us_on) return %orig;
    IXUSLog(@"NEHotspotNetwork.SSID", @"LAX-WiFi");
    return @"LAX-WiFi";
}
- (NSString *)BSSID {
    if (!ix_us_on) return %orig;
    IXUSLog(@"NEHotspotNetwork.BSSID", @"02:00:00:00:00:01");
    return @"02:00:00:00:00:01";
}
%end
%end

%hook CLLocationManager
- (CLLocation *)location {
    if (IXFakeLocationOwns()) return %orig;
    if (ix_us_on) {
        IXUSLog(@"CLLocationManager.location", @"34.0522,-118.2437");
        return IXLosAngeles();
    }
    return %orig;
}
+ (BOOL)locationServicesEnabled {
    if (ix_us_on && !IXFakeLocationOwns()) return YES;
    return %orig;
}
- (CLAuthorizationStatus)authorizationStatus {
    if (ix_us_on && !IXFakeLocationOwns()) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
+ (CLAuthorizationStatus)authorizationStatus {
    if (ix_us_on && !IXFakeLocationOwns()) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
- (CLAccuracyAuthorization)accuracyAuthorization {
    if (ix_us_on && !IXFakeLocationOwns()) return CLAccuracyAuthorizationFullAccuracy;
    return %orig;
}
- (void)requestWhenInUseAuthorization {
    if (ix_us_on && !IXFakeLocationOwns()) { IXUSNotifyAuth(self); return; }
    %orig;
}
- (void)requestAlwaysAuthorization {
    if (ix_us_on && !IXFakeLocationOwns()) { IXUSNotifyAuth(self); return; }
    %orig;
}
- (void)startUpdatingLocation {
    if (IXFakeLocationOwns()) { %orig; return; }
    if (!ix_us_on) { %orig; return; }
    NSTimer *existing = objc_getAssociatedObject(self, &ix_us_timer);
    [existing invalidate];
    __weak CLLocationManager *weakManager = self;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:8.0 repeats:YES block:^(NSTimer *fired) {
        CLLocationManager *strong = weakManager;
        if (!strong || !ix_us_on || IXFakeLocationOwns()) {
            [fired invalidate];
            return;
        }
        IXUSDeliver(strong);
    }];
    objc_setAssociatedObject(self, &ix_us_timer, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IXUSLog(@"CLLocationManager.startUpdatingLocation", @"34.0522,-118.2437");
    IXUSDeliver(self);
    IXUSNotifyAuth(self);
}
- (void)requestLocation {
    if (IXFakeLocationOwns()) { %orig; return; }
    if (!ix_us_on) { %orig; return; }
    IXUSLog(@"CLLocationManager.requestLocation", @"34.0522,-118.2437");
    dispatch_async(dispatch_get_main_queue(), ^{ IXUSDeliver(self); });
}
- (void)stopUpdatingLocation {
    NSTimer *existing = objc_getAssociatedObject(self, &ix_us_timer);
    [existing invalidate];
    objc_setAssociatedObject(self, &ix_us_timer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (ix_us_on && !IXFakeLocationOwns()) return;
    %orig;
}
%end

#ifdef __cplusplus
extern "C" {
#endif
static int ix_us_hooks_installed;

void IXUSRegionInstall(void) {
    IXUSRefresh();
    if (ix_us_hooks_installed) return;
    ix_us_hooks_installed = 1;
    %init;
    if (class_getInstanceMethod(objc_getClass("NSLocale"), @selector(regionCode))) %init(IXUSRegionCode);
    if (objc_getClass("NEHotspotNetwork")) %init(IXUSHotspot);
    IXInstallWiFi();
    IXInstallIGLocation();
    IXInstallAnalytics();
    NSLog(@"[InstagramX] US region %@ installed after launch. CTCarrier MCC 310 MNC 410 ISO us name AT&T. NSLocale country US, currency USD, currency symbol $ (language is not hooked). SKStorefront country USA. HTTP headers whose names contain country, carrier, mcc, mnc, or storefront (Accept-Language, locale, language, and timezone headers are not hooked). Analytics keys mcc, mnc, device_country, sim_country, carrier, storefront. Device id, uuid, guid, ig_did, phone_id, waterfall, and mid are not hooked. CNCopyCurrentNetworkInfo and NEHotspotNetwork SSID LAX-WiFi. CLLocation and IGLocationManager 34.0522,-118.2437 while fake location is off. Time zone is not hooked.", ix_us_on ? @"on" : @"off");
}
#ifdef __cplusplus
}
#endif

%ctor {
    IXUSRefresh();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(__unused NSNotification *note) {
        IXUSRefresh();
    }];
}
