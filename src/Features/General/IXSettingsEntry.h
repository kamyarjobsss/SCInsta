#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void IXSettingsEntryInstall(void);

@interface IXSettingsEntry : NSObject
+ (BOOL)textIsAccountsCenter:(nullable NSString *)text;
+ (void)noteLabel:(UILabel *)label;
+ (void)noteSettingsController:(UIViewController *)controller;
+ (void)relayoutIfNeeded:(UIScrollView *)scroll;
@end

NS_ASSUME_NONNULL_END
