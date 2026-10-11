#import "IXBrand.h"
#import "IXIconData.h"

NSString *const IXProductName = @"Instagram X";

@implementation IXBrand

+ (UIImage *)iconImage {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithBytes:kIXIconPNG length:kIXIconPNGLength];
        image = [UIImage imageWithData:data scale:3.0];
    });
    return image;
}

@end
