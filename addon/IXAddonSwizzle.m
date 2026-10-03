#import "../src/Features/General/IXSettingsEntry.h"
#if !IX_ADDON_LITE
#import "../src/Location/IXLocationHooks.h"
#import "../src/Location/IXLocationStore.h"
#import "../src/Proxy/IXTrafficGuard.h"

#import <CoreLocation/CoreLocation.h>
#endif
#import <objc/runtime.h>

#if !IX_ADDON_LITE
static char kIXLocationTimerKey;
#endif

static IMP IXReplace(Class cls, SEL sel, IMP next, BOOL classMethod) {
    Method method = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) return NULL;
    return method_setImplementation(method, next);
}

#pragma mark - Settings row

static void (*ix_origSetText)(UILabel *, SEL, NSString *);
static void (*ix_origSetAttr)(UILabel *, SEL, NSAttributedString *);
static void (*ix_origAppear)(UIViewController *, SEL, BOOL);
static void (*ix_origLayout)(UIScrollView *, SEL);

static void ix_setText(UILabel *self, SEL _cmd, NSString *text) {
    if (ix_origSetText) ix_origSetText(self, _cmd, text);
    if (text.length >= 8 && text.length <= 80) [IXSettingsEntry noteLabel:self];
}
static void ix_setAttr(UILabel *self, SEL _cmd, NSAttributedString *text) {
    if (ix_origSetAttr) ix_origSetAttr(self, _cmd, text);
    if (text.length >= 8 && text.length <= 80) [IXSettingsEntry noteLabel:self];
}
static void ix_appear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (ix_origAppear) ix_origAppear(self, _cmd, animated);
    [IXSettingsEntry noteSettingsController:self];
}
static void ix_layout(UIScrollView *self, SEL _cmd) {
    if (ix_origLayout) ix_origLayout(self, _cmd);
    [IXSettingsEntry relayoutIfNeeded:self];
}

void IXSettingsEntryInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    ix_origSetText = (void *)IXReplace([UILabel class], @selector(setText:), (IMP)ix_setText, NO);
    ix_origSetAttr = (void *)IXReplace([UILabel class], @selector(setAttributedText:), (IMP)ix_setAttr, NO);
    ix_origAppear = (void *)IXReplace([UIViewController class], @selector(viewDidAppear:), (IMP)ix_appear, NO);
    ix_origLayout = (void *)IXReplace([UIScrollView class], @selector(layoutSubviews), (IMP)ix_layout, NO);
}

#if !IX_ADDON_LITE
#pragma mark - Session proxy

static NSURLSessionConfiguration *(*ix_origDefault)(id, SEL);
static NSURLSessionConfiguration *(*ix_origEphemeral)(id, SEL);
static NSURLSessionConfiguration *(*ix_origBackground)(id, SEL, NSString *);
static void (*ix_origSetProxy)(id, SEL, NSDictionary *);

static void IXApplyProxy(NSURLSessionConfiguration *config) {
    if (!config || !IXTrafficGuardVPNOn()) return;
    if (ix_origSetProxy) ix_origSetProxy(config, @selector(setConnectionProxyDictionary:), IXTrafficGuardProxyDictionary());
    else config.connectionProxyDictionary = IXTrafficGuardProxyDictionary();
}

static NSURLSessionConfiguration *ix_defaultConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = ix_origDefault ? ix_origDefault(self, _cmd) : nil;
    IXApplyProxy(config);
    return config;
}
static NSURLSessionConfiguration *ix_ephemeralConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = ix_origEphemeral ? ix_origEphemeral(self, _cmd) : nil;
    IXApplyProxy(config);
    return config;
}
static NSURLSessionConfiguration *ix_backgroundConfig(id self, SEL _cmd, NSString *identifier) {
    NSURLSessionConfiguration *config = ix_origBackground ? ix_origBackground(self, _cmd, identifier) : nil;
    IXApplyProxy(config);
    return config;
}
static void ix_setProxy(id self, SEL _cmd, NSDictionary *dict) {
    if (IXTrafficGuardVPNOn()) dict = IXTrafficGuardProxyDictionary();
    if (ix_origSetProxy) ix_origSetProxy(self, _cmd, dict);
}

void IXTrafficHooksInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Class cls = [NSURLSessionConfiguration class];
    ix_origDefault = (void *)IXReplace(cls, @selector(defaultSessionConfiguration), (IMP)ix_defaultConfig, YES);
    ix_origEphemeral = (void *)IXReplace(cls, @selector(ephemeralSessionConfiguration), (IMP)ix_ephemeralConfig, YES);
    ix_origBackground = (void *)IXReplace(cls, @selector(backgroundSessionConfigurationWithIdentifier:), (IMP)ix_backgroundConfig, YES);
    ix_origSetProxy = (void *)IXReplace(cls, @selector(setConnectionProxyDictionary:), (IMP)ix_setProxy, NO);
}

#pragma mark - Location

static void IXDeliverLocation(CLLocationManager *manager) {
    if (!manager || ![IXLocationStore isEnabled]) return;
    id delegate = nil;
    @try { delegate = manager.delegate; } @catch (NSException *exception) { return; }
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

static CLLocation *(*ix_origLocation)(CLLocationManager *, SEL);
static BOOL (*ix_origServices)(id, SEL);
static int (*ix_origAuthInst)(CLLocationManager *, SEL);
static int (*ix_origAuthClass)(id, SEL);
static int (*ix_origAccuracy)(CLLocationManager *, SEL);
static void (*ix_origWhenInUse)(CLLocationManager *, SEL);
static void (*ix_origAlways)(CLLocationManager *, SEL);
static void (*ix_origStart)(CLLocationManager *, SEL);
static void (*ix_origRequest)(CLLocationManager *, SEL);
static void (*ix_origSignificant)(CLLocationManager *, SEL);
static void (*ix_origStop)(CLLocationManager *, SEL);
static void (*ix_origStopSignificant)(CLLocationManager *, SEL);
static void (*ix_origStartHeading)(CLLocationManager *, SEL);
static void (*ix_origStopHeading)(CLLocationManager *, SEL);
static NSTimeZone *(*ix_origLocalTZ)(id, SEL);
static NSTimeZone *(*ix_origSystemTZ)(id, SEL);
static NSLocale *(*ix_origLocale)(id, SEL);
static NSLocale *(*ix_origAutoLocale)(id, SEL);
static id (*ix_origIGLocation)(id, SEL);
static id (*ix_origIGCurrent)(id, SEL);

static CLLocation *ix_location(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return ix_origLocation ? ix_origLocation(self, _cmd) : nil;
}
static BOOL ix_services(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return YES;
    return ix_origServices ? ix_origServices(self, _cmd) : NO;
}
static int ix_authInst(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return ix_origAuthInst ? ix_origAuthInst(self, _cmd) : kCLAuthorizationStatusNotDetermined;
}
static int ix_authClass(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return kCLAuthorizationStatusAuthorizedWhenInUse;
    return ix_origAuthClass ? ix_origAuthClass(self, _cmd) : kCLAuthorizationStatusNotDetermined;
}
static int ix_accuracy(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return CLAccuracyAuthorizationFullAccuracy;
    return ix_origAccuracy ? ix_origAccuracy(self, _cmd) : CLAccuracyAuthorizationReducedAccuracy;
}
static void ix_whenInUse(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) { IXNotifyAuthorization(self); return; }
    if (ix_origWhenInUse) ix_origWhenInUse(self, _cmd);
}
static void ix_always(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) { IXNotifyAuthorization(self); return; }
    if (ix_origAlways) ix_origAlways(self, _cmd);
}
static void ix_start(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) { IXStartRepeating(self); return; }
    if (ix_origStart) ix_origStart(self, _cmd);
}
static void ix_request(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) {
        dispatch_async(dispatch_get_main_queue(), ^{ IXDeliverLocation(self); });
        return;
    }
    if (ix_origRequest) ix_origRequest(self, _cmd);
}
static void ix_significant(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) {
        dispatch_async(dispatch_get_main_queue(), ^{ IXDeliverLocation(self); });
        return;
    }
    if (ix_origSignificant) ix_origSignificant(self, _cmd);
}
static void ix_stop(CLLocationManager *self, SEL _cmd) {
    IXStopRepeating(self);
    if ([IXLocationStore isEnabled]) return;
    if (ix_origStop) ix_origStop(self, _cmd);
}
static void ix_stopSignificant(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return;
    if (ix_origStopSignificant) ix_origStopSignificant(self, _cmd);
}
static void ix_startHeading(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return;
    if (ix_origStartHeading) ix_origStartHeading(self, _cmd);
}
static void ix_stopHeading(CLLocationManager *self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return;
    if (ix_origStopHeading) ix_origStopHeading(self, _cmd);
}
static NSTimeZone *ix_localTZ(id self, SEL _cmd) {
    if ([IXLocationStore spoofTimeZone]) {
        NSTimeZone *zone = [IXLocationStore timeZone];
        if (zone) return zone;
    }
    return ix_origLocalTZ ? ix_origLocalTZ(self, _cmd) : [NSTimeZone systemTimeZone];
}
static NSTimeZone *ix_systemTZ(id self, SEL _cmd) {
    if ([IXLocationStore spoofTimeZone]) {
        NSTimeZone *zone = [IXLocationStore timeZone];
        if (zone) return zone;
    }
    return ix_origSystemTZ ? ix_origSystemTZ(self, _cmd) : nil;
}
static NSLocale *ix_locale(id self, SEL _cmd) {
    if ([IXLocationStore spoofLocale]) {
        NSLocale *locale = [IXLocationStore locale];
        if (locale) return locale;
    }
    return ix_origLocale ? ix_origLocale(self, _cmd) : nil;
}
static NSLocale *ix_autoLocale(id self, SEL _cmd) {
    if ([IXLocationStore spoofLocale]) {
        NSLocale *locale = [IXLocationStore locale];
        if (locale) return locale;
    }
    return ix_origAutoLocale ? ix_origAutoLocale(self, _cmd) : nil;
}
static id ix_igLocation(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return ix_origIGLocation ? ix_origIGLocation(self, _cmd) : nil;
}
static id ix_igCurrent(id self, SEL _cmd) {
    if ([IXLocationStore isEnabled]) return [IXLocationStore fakeLocation];
    return ix_origIGCurrent ? ix_origIGCurrent(self, _cmd) : nil;
}

static void IXHookOptional(const char *className, SEL sel, IMP next, IMP *orig) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] != '@') return;
    *orig = method_setImplementation(method, next);
}

void IXLocationHooksInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Class loc = [CLLocationManager class];
    ix_origLocation = (void *)IXReplace(loc, @selector(location), (IMP)ix_location, NO);
    ix_origServices = (void *)IXReplace(loc, @selector(locationServicesEnabled), (IMP)ix_services, YES);
    ix_origAuthInst = (void *)IXReplace(loc, @selector(authorizationStatus), (IMP)ix_authInst, NO);
    ix_origAuthClass = (void *)IXReplace(loc, @selector(authorizationStatus), (IMP)ix_authClass, YES);
    ix_origAccuracy = (void *)IXReplace(loc, @selector(accuracyAuthorization), (IMP)ix_accuracy, NO);
    ix_origWhenInUse = (void *)IXReplace(loc, @selector(requestWhenInUseAuthorization), (IMP)ix_whenInUse, NO);
    ix_origAlways = (void *)IXReplace(loc, @selector(requestAlwaysAuthorization), (IMP)ix_always, NO);
    ix_origStart = (void *)IXReplace(loc, @selector(startUpdatingLocation), (IMP)ix_start, NO);
    ix_origRequest = (void *)IXReplace(loc, @selector(requestLocation), (IMP)ix_request, NO);
    ix_origSignificant = (void *)IXReplace(loc, @selector(startMonitoringSignificantLocationChanges), (IMP)ix_significant, NO);
    ix_origStop = (void *)IXReplace(loc, @selector(stopUpdatingLocation), (IMP)ix_stop, NO);
    ix_origStopSignificant = (void *)IXReplace(loc, @selector(stopMonitoringSignificantLocationChanges), (IMP)ix_stopSignificant, NO);
    ix_origStartHeading = (void *)IXReplace(loc, @selector(startUpdatingHeading), (IMP)ix_startHeading, NO);
    ix_origStopHeading = (void *)IXReplace(loc, @selector(stopUpdatingHeading), (IMP)ix_stopHeading, NO);
    ix_origLocalTZ = (void *)IXReplace([NSTimeZone class], @selector(localTimeZone), (IMP)ix_localTZ, YES);
    ix_origSystemTZ = (void *)IXReplace([NSTimeZone class], @selector(systemTimeZone), (IMP)ix_systemTZ, YES);
    ix_origLocale = (void *)IXReplace([NSLocale class], @selector(currentLocale), (IMP)ix_locale, YES);
    ix_origAutoLocale = (void *)IXReplace([NSLocale class], @selector(autoupdatingCurrentLocale), (IMP)ix_autoLocale, YES);
    @try {
        IXHookOptional("IGLocationManager", @selector(location), (IMP)ix_igLocation, (IMP *)&ix_origIGLocation);
        IXHookOptional("IGLocationManager", @selector(currentLocation), (IMP)ix_igCurrent, (IMP *)&ix_origIGCurrent);
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] optional location hook failed: %@", exception.reason);
    }
}
#endif
