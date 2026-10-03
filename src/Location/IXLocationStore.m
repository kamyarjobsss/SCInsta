#import "IXLocationStore.h"

NSString *const IXLocationEnabledKey = @"ix_fake_location_enabled";
NSString *const IXLocationLatitudeKey = @"ix_fake_lat";
NSString *const IXLocationLongitudeKey = @"ix_fake_lon";
NSString *const IXLocationNameKey = @"ix_fake_name";
NSString *const IXLocationTimezoneEnabledKey = @"ix_spoof_timezone";
NSString *const IXLocationTimezoneKey = @"ix_timezone_id";
NSString *const IXLocationLocaleEnabledKey = @"ix_spoof_locale";
NSString *const IXLocationLocaleKey = @"ix_locale_id";

@implementation IXLocationStore

+ (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

+ (BOOL)isEnabled {
    return [[self defaults] boolForKey:IXLocationEnabledKey] && [self hasSavedCoordinate];
}

+ (void)setEnabled:(BOOL)enabled {
    [[self defaults] setBool:enabled forKey:IXLocationEnabledKey];
}

+ (BOOL)hasSavedCoordinate {
    return [[self defaults] objectForKey:IXLocationLatitudeKey] != nil && [[self defaults] objectForKey:IXLocationLongitudeKey] != nil;
}

+ (CLLocationCoordinate2D)coordinate {
    return CLLocationCoordinate2DMake([[self defaults] doubleForKey:IXLocationLatitudeKey], [[self defaults] doubleForKey:IXLocationLongitudeKey]);
}

+ (NSString *)placeName {
    NSString *name = [[self defaults] stringForKey:IXLocationNameKey];
    if (name.length) return name;
    if (![self hasSavedCoordinate]) return @"No place saved";
    CLLocationCoordinate2D c = [self coordinate];
    return [NSString stringWithFormat:@"%.5f, %.5f", c.latitude, c.longitude];
}

+ (void)saveCoordinate:(CLLocationCoordinate2D)coordinate name:(NSString *)name timeZone:(NSTimeZone *)timeZone localeIdentifier:(NSString *)localeIdentifier {
    NSUserDefaults *defaults = [self defaults];
    [defaults setDouble:coordinate.latitude forKey:IXLocationLatitudeKey];
    [defaults setDouble:coordinate.longitude forKey:IXLocationLongitudeKey];
    if (name.length) [defaults setObject:name forKey:IXLocationNameKey];
    if (timeZone.name.length) [defaults setObject:timeZone.name forKey:IXLocationTimezoneKey];
    if (localeIdentifier.length) [defaults setObject:localeIdentifier forKey:IXLocationLocaleKey];
}

+ (CLLocation *)fakeLocation {
    CLLocationCoordinate2D coordinate = [self hasSavedCoordinate] ? [self coordinate] : CLLocationCoordinate2DMake(0, 0);
    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:0
                               horizontalAccuracy:8
                                 verticalAccuracy:12
                                           course:-1
                                            speed:-1
                                        timestamp:[NSDate date]];
}

+ (BOOL)spoofTimeZone {
    return [self isEnabled] && [[self defaults] boolForKey:IXLocationTimezoneEnabledKey] && [self timeZone] != nil;
}

+ (void)setSpoofTimeZone:(BOOL)on {
    [[self defaults] setBool:on forKey:IXLocationTimezoneEnabledKey];
}

+ (NSTimeZone *)timeZone {
    NSString *name = [[self defaults] stringForKey:IXLocationTimezoneKey];
    if (!name.length) return nil;
    return [NSTimeZone timeZoneWithName:name];
}

+ (BOOL)spoofLocale {
    return [self isEnabled] && [[self defaults] boolForKey:IXLocationLocaleEnabledKey] && [self locale] != nil;
}

+ (void)setSpoofLocale:(BOOL)on {
    [[self defaults] setBool:on forKey:IXLocationLocaleEnabledKey];
}

+ (NSLocale *)locale {
    NSString *ident = [[self defaults] stringForKey:IXLocationLocaleKey];
    if (!ident.length) return nil;
    return [NSLocale localeWithLocaleIdentifier:ident];
}

@end
