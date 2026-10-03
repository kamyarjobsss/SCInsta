#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void IXSettingsEntryInstall(void);

@interface IXSettingsEntry : NSObject
+ (void)noteSettingsController:(UIViewController *)controller;
+ (void)relayoutSettingsRowForController:(UIViewController *)controller;
+ (void)removeSettingsRowForController:(UIViewController *)controller;
@end

NS_ASSUME_NONNULL_END
