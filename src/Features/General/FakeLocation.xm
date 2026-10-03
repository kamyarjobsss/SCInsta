// Fake location. Presets, the map picker, and the Friends Map button live in
// SCIFakeLocationSettingsVC. These hooks are installed only after the feature
// is turned on, and they read that screen's keys.

#import "../../Utils.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

static char kSCILocTimerKey;

static BOOL sciFakeLocOn(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:@"fake_location_enabled"] && [defaults objectForKey:@"fake_location_lat"] && [defaults objectForKey:@"fake_location_lon"];
}

static CLLocation *sciFakeLocation(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double lat = [[defaults objectForKey:@"fake_location_lat"] doubleValue];
    double lon = [[defaults objectForKey:@"fake_location_lon"] doubleValue];
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat, lon)
                                         altitude:35
                               horizontalAccuracy:8
                                 verticalAccuracy:12
                                           course:-1
                                            speed:-1
                                        timestamp:[NSDate date]];
}

static void sciDeliver(CLLocationManager *manager) {
    if (!manager || !sciFakeLocOn()) return;
    id delegate = nil;
    @try { delegate = manager.delegate; } @catch (NSException *exception) { return; }
    if (![delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
    @try {
        [delegate locationManager:manager didUpdateLocations:@[sciFakeLocation()]];
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] location callback failed: %@", exception.reason);
    }
}

static void sciNotifyAuth(CLLocationManager *manager) {
    id delegate = nil;
    @try { delegate = manager.delegate; } @catch (NSException *exception) { return; }
    if (!delegate) return;
    @try {
        if ([delegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
            [delegate locationManagerDidChangeAuthorization:manager];
        }
        if ([delegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
            [delegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedWhenInUse];
        }
    } @catch (NSException *exception) {}
}

static void sciStartRepeating(CLLocationManager *manager) {
    NSTimer *existing = objc_getAssociatedObject(manager, &kSCILocTimerKey);
    [existing invalidate];
    __weak CLLocationManager *weakManager = manager;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:8.0 repeats:YES block:^(NSTimer *timer) {
        CLLocationManager *strong = weakManager;
        if (!strong || !sciFakeLocOn()) {
            [timer invalidate];
            return;
        }
        sciDeliver(strong);
    }];
    objc_setAssociatedObject(manager, &kSCILocTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sciDeliver(manager);
    sciNotifyAuth(manager);
}

%group SCIFakeLocationHooks
%hook CLLocationManager
- (CLLocation *)location {
    if (sciFakeLocOn()) return sciFakeLocation();
    return %orig;
}
+ (BOOL)locationServicesEnabled {
    if (sciFakeLocOn()) return YES;
    return %orig;
}
- (CLAuthorizationStatus)authorizationStatus {
    if (sciFakeLocOn()) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
+ (CLAuthorizationStatus)authorizationStatus {
    if (sciFakeLocOn()) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
- (CLAccuracyAuthorization)accuracyAuthorization {
    if (sciFakeLocOn()) return CLAccuracyAuthorizationFullAccuracy;
    return %orig;
}
- (void)requestWhenInUseAuthorization {
    if (sciFakeLocOn()) { sciNotifyAuth(self); return; }
    %orig;
}
- (void)requestAlwaysAuthorization {
    if (sciFakeLocOn()) { sciNotifyAuth(self); return; }
    %orig;
}
- (void)startUpdatingLocation {
    if (sciFakeLocOn()) { sciStartRepeating(self); return; }
    %orig;
}
- (void)requestLocation {
    if (sciFakeLocOn()) {
        dispatch_async(dispatch_get_main_queue(), ^{ sciDeliver(self); });
        return;
    }
    %orig;
}
- (void)stopUpdatingLocation {
    NSTimer *existing = objc_getAssociatedObject(self, &kSCILocTimerKey);
    [existing invalidate];
    if (sciFakeLocOn()) return;
    %orig;
}
%end

%hook NSTimeZone
+ (NSTimeZone *)localTimeZone {
    if (sciFakeLocOn() && [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_spoof_tz"]) {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:@"fake_location_tz"];
        NSTimeZone *zone = name.length ? [NSTimeZone timeZoneWithName:name] : nil;
        if (zone) return zone;
    }
    return %orig;
}
+ (NSTimeZone *)systemTimeZone {
    if (sciFakeLocOn() && [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_spoof_tz"]) {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:@"fake_location_tz"];
        NSTimeZone *zone = name.length ? [NSTimeZone timeZoneWithName:name] : nil;
        if (zone) return zone;
    }
    return %orig;
}
%end

%hook NSLocale
+ (NSLocale *)currentLocale {
    if (sciFakeLocOn() && [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_spoof_locale"]) {
        NSString *ident = [[NSUserDefaults standardUserDefaults] stringForKey:@"fake_location_locale"];
        if (ident.length) return [NSLocale localeWithLocaleIdentifier:ident];
    }
    return %orig;
}
+ (NSLocale *)autoupdatingCurrentLocale {
    if (sciFakeLocOn() && [[NSUserDefaults standardUserDefaults] boolForKey:@"fake_location_spoof_locale"]) {
        NSString *ident = [[NSUserDefaults standardUserDefaults] stringForKey:@"fake_location_locale"];
        if (ident.length) return [NSLocale localeWithLocaleIdentifier:ident];
    }
    return %orig;
}
%end
%end

static id (*sci_origIGLocation)(id, SEL) = NULL;
static id sciIGLocation(id self, SEL _cmd) {
    if (sciFakeLocOn()) return sciFakeLocation();
    return sci_origIGLocation ? sci_origIGLocation(self, _cmd) : nil;
}

void SCIFakeLocationInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    %init(SCIFakeLocationHooks);
    Class cls = objc_getClass("IGLocationManager");
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, @selector(location));
    if (!method) return;
    MSHookMessageEx(cls, @selector(location), (IMP)sciIGLocation, (IMP *)&sci_origIGLocation);
}
