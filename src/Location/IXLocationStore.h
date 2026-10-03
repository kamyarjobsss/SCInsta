#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IXLocationEnabledKey;
extern NSString *const IXLocationLatitudeKey;
extern NSString *const IXLocationLongitudeKey;
extern NSString *const IXLocationNameKey;
extern NSString *const IXLocationTimezoneEnabledKey;
extern NSString *const IXLocationTimezoneKey;
extern NSString *const IXLocationLocaleEnabledKey;
extern NSString *const IXLocationLocaleKey;

@interface IXLocationStore : NSObject

+ (BOOL)isEnabled;
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)hasSavedCoordinate;
+ (CLLocationCoordinate2D)coordinate;
+ (NSString *)placeName;
+ (void)saveCoordinate:(CLLocationCoordinate2D)coordinate name:(nullable NSString *)name timeZone:(nullable NSTimeZone *)timeZone localeIdentifier:(nullable NSString *)localeIdentifier;
+ (CLLocation *)fakeLocation;

+ (BOOL)spoofTimeZone;
+ (void)setSpoofTimeZone:(BOOL)on;
+ (nullable NSTimeZone *)timeZone;

+ (BOOL)spoofLocale;
+ (void)setSpoofLocale:(BOOL)on;
+ (nullable NSLocale *)locale;

@end

NS_ASSUME_NONNULL_END
