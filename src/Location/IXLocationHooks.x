#import "IXLocationStore.h"
#import <objc/runtime.h>
#import <substrate.h>

static char kIXLocationTimerKey;

static void IXDeliverLocation(CLLocationManager *manager) {
    if (!manager || ![IXLocationStore isEnabled]) return;
    id delegate = nil;
    @try {
        delegate = manager.delegate;
    } @catch (NSException *exception) {
        return;
    }
    if (!delegate) return;
    CLLocation *location = [IXLocationStore fakeLocation];
    @try {
        if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:manager didUpdateLocations:@[location]];
        }
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] location callback failed: %@", exception.reason);
    }
}

static void IXNotifyAuthorization(CLLocationManager *manager) {
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
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] location authorization callback failed: %@", exception.reason);
    }
}

static void IXStartRepeating(CLLocationManager *manager) {
    NSTimer *existing = objc_getAssociatedObject(manager, &kIXLocationTimerKey);
    [existing invalidate];
    __weak CLLocationManager *weakManager = manager;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:8.0 repeats:YES block:^(NSTimer *timer) {
        CLLocationManager *strong = weakManager;
        if (!strong || ![IXLocationStore isEnabled]) {
            [timer invalidate];
            return;
        }
        IXDeliverLocation(strong);
    }];
    objc_setAssociatedObject(manager, &kIXLocationTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    IXDeliverLocation(manager);
    IXNotifyAuthorization(manager);
}

static void IXStopRepeating(CLLocationManager *manager) {
    NSTimer *existing = objc_getAssociatedObject(manager, &kIXLocationTimerKey);
    [existing invalidate];
    objc_setAssociatedObject(manager, &kIXLocationTimerKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

%hook CLLocationManager
- (CLLocation *)location {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return %orig;
}
+ (BOOL)locationServicesEnabled {
    if ([IXLocationStore isEnabled]) return YES;
    return %orig;
}
- (CLAuthorizationStatus)authorizationStatus {
    if ([IXLocationStore isEnabled]) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
+ (CLAuthorizationStatus)authorizationStatus {
    if ([IXLocationStore isEnabled]) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return %orig;
}
- (CLAccuracyAuthorization)accuracyAuthorization {
    if ([IXLocationStore isEnabled]) return CLAccuracyAuthorizationFullAccuracy;
    return %orig;
}
- (void)requestWhenInUseAuthorization {
    if ([IXLocationStore isEnabled]) {
        IXNotifyAuthorization(self);
        return;
    }
    %orig;
}
- (void)requestAlwaysAuthorization {
    if ([IXLocationStore isEnabled]) {
        IXNotifyAuthorization(self);
        return;
    }
    %orig;
}
- (void)startUpdatingLocation {
    if ([IXLocationStore isEnabled]) {
        IXStartRepeating(self);
        return;
    }
    %orig;
}
- (void)requestLocation {
    if ([IXLocationStore isEnabled]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IXDeliverLocation(self);
        });
        return;
    }
    %orig;
}
- (void)startMonitoringSignificantLocationChanges {
    if ([IXLocationStore isEnabled]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IXDeliverLocation(self);
        });
        return;
    }
    %orig;
}
- (void)stopUpdatingLocation {
    IXStopRepeating(self);
    if ([IXLocationStore isEnabled]) return;
    %orig;
}
- (void)stopMonitoringSignificantLocationChanges {
    if ([IXLocationStore isEnabled]) return;
    %orig;
}
- (void)startUpdatingHeading {
    if ([IXLocationStore isEnabled]) return;
    %orig;
}
- (void)stopUpdatingHeading {
    if ([IXLocationStore isEnabled]) return;
    %orig;
}
%end

%hook NSTimeZone
+ (NSTimeZone *)localTimeZone {
    if ([IXLocationStore spoofTimeZone]) {
        NSTimeZone *zone = [IXLocationStore timeZone];
        if (zone) return zone;
    }
    return %orig;
}
+ (NSTimeZone *)systemTimeZone {
    if ([IXLocationStore spoofTimeZone]) {
        NSTimeZone *zone = [IXLocationStore timeZone];
        if (zone) return zone;
    }
    return %orig;
}
%end

%hook NSLocale
+ (NSLocale *)currentLocale {
    if ([IXLocationStore spoofLocale]) {
        NSLocale *locale = [IXLocationStore locale];
        if (locale) return locale;
    }
    return %orig;
}
+ (NSLocale *)autoupdatingCurrentLocale {
    if ([IXLocationStore spoofLocale]) {
        NSLocale *locale = [IXLocationStore locale];
        if (locale) return locale;
    }
    return %orig;
}
%end

static id (*ix_origIGLocation)(id, SEL) = NULL;
static id (*ix_origIGCurrentLocation)(id, SEL) = NULL;

static id IXIGLocation(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return ix_origIGLocation ? ix_origIGLocation(self, _cmd) : nil;
}
static id IXIGCurrentLocation(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return ix_origIGCurrentLocation ? ix_origIGCurrentLocation(self, _cmd) : nil;
}

static void IXHookOptionalLocation(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] != '@') return;
    MSHookMessageEx(cls, selector, replacement, original);
    NSLog(@"[InstagramX] hooked optional location method %s %s", className, sel_getName(selector));
}

%ctor {
    @try {
        IXHookOptionalLocation("IGLocationManager", @selector(location), (IMP)IXIGLocation, (IMP *)&ix_origIGLocation);
        IXHookOptionalLocation("IGLocationManager", @selector(currentLocation), (IMP)IXIGCurrentLocation, (IMP *)&ix_origIGCurrentLocation);
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] optional location hook failed: %@", exception.reason);
    }
}
