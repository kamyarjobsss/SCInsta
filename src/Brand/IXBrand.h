#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// User-facing product name. The injected library stays SCInsta.dylib so existing
/// sideload tooling keeps finding it.
extern NSString *const IXProductName;

@interface IXBrand : NSObject
+ (UIImage *)iconImage;
@end

NS_ASSUME_NONNULL_END
