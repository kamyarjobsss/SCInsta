#import "../../Utils.h"
#import "../../Localization/SCILocalization.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// Own-profile header button. Instagram lays the "+" out as the first left
// button; this inserts the mark immediately after it. No floating overlay.

static id IXValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static UIImage *IXMarkImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = SCILocalizationBundle();
        UIImage *raw = [UIImage imageNamed:@"ix-mark" inBundle:bundle compatibleWithTraitCollection:nil];
        if (!raw) {
            NSString *path = [bundle pathForResource:@"ix-mark" ofType:@"png"];
            if (path) raw = [UIImage imageWithContentsOfFile:path];
        }
        image = [raw imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

static UIView *IXMarkButton(void) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *mark = IXMarkImage();
    if (mark) {
        [button setImage:mark forState:UIControlStateNormal];
    } else {
        [button setImage:[UIImage systemImageNamed:@"circle.hexagongrid"] forState:UIControlStateNormal];
    }
    button.tintColor = [UIColor labelColor];
    button.frame = CGRectMake(0, 0, 32, 32);
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.contentEdgeInsets = UIEdgeInsetsMake(5, 5, 5, 5);
    button.accessibilityIdentifier = @"ix-profile-menu-button";
    button.accessibilityLabel = [SCIResolvedLanguageCode() hasPrefix:@"fa"] ? @"اینستاگرام ایکس" : @"Instagram X";
    return button;
}

static void IXWire(UIButton *button) {
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [button addTarget:button action:@selector(ix_openMenu) forControlEvents:UIControlEventTouchUpInside];
}

static void IXOpenMenuIMP(id self, SEL _cmd) {
    UIView *view = [self isKindOfClass:[UIView class]] ? self : nil;
    [SCIUtils showSettingsVC:view.window];
}

static UIView *IXBuildButton(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        class_addMethod([UIButton class], @selector(ix_openMenu), (IMP)IXOpenMenuIMP, "v@:");
    });
    UIButton *button = (UIButton *)IXMarkButton();
    IXWire(button);
    return button;
}

static void (*ix_orig_configure)(id, SEL, id, id, id, BOOL);

static void IXConfigureHeader(id self, SEL _cmd, id titleView, id leftButtons, id rightButtons, BOOL titleIsCentered) {
    if (!titleIsCentered || !ix_orig_configure) {
        if (ix_orig_configure) ix_orig_configure(self, _cmd, titleView, leftButtons, rightButtons, titleIsCentered);
        return;
    }
    @try {
    NSArray *left = [leftButtons isKindOfClass:[NSArray class]] ? leftButtons : @[];
    BOOL already = NO;
    for (id wrapper in left) {
        UIView *view = IXValue(wrapper, @"view");
        if ([view isKindOfClass:[UIView class]] && [view.accessibilityIdentifier isEqualToString:@"ix-profile-menu-button"]) {
            already = YES;
            break;
        }
    }
    id patchedLeft = leftButtons;
    if (!already) {
        Class wrapperCls = NSClassFromString(@"IGProfileNavigationHeaderViewButtonSwift.IGProfileNavigationHeaderViewButton");
        id sample = left.firstObject ?: ([rightButtons isKindOfClass:[NSArray class]] ? [rightButtons firstObject] : nil);
        NSInteger type = 0;
        id typeVal = IXValue(sample, @"type");
        if ([typeVal respondsToSelector:@selector(integerValue)]) type = [typeVal integerValue];
        UIView *button = IXBuildButton();
        id wrapper = nil;
        if (wrapperCls) {
            id allocated = [wrapperCls alloc];
            SEL initSel = @selector(initWithType:view:);
            if ([allocated respondsToSelector:initSel]) {
                wrapper = ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(allocated, initSel, type, button);
            }
        }
        if (wrapper) {
            NSMutableArray *next = [left mutableCopy];
            NSUInteger index = MIN((NSUInteger)1, next.count);
            [next insertObject:wrapper atIndex:index];
            patchedLeft = next;
        }
    }
    ix_orig_configure(self, _cmd, titleView, patchedLeft, rightButtons, titleIsCentered);
    } @catch (__unused NSException *exception) {
        ix_orig_configure(self, _cmd, titleView, leftButtons, rightButtons, titleIsCentered);
    }
}

%ctor {
    Class cls = objc_getClass("IGProfileNavigationSwift.IGProfileNavigationHeaderView");
    if (!cls) return;
    SEL sel = @selector(configureWithTitleView:leftButtons:rightButtons:titleIsCentered:);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    // Instagram 436 does not put this selector in a relative method list, so
    // refuse any signature other than (title, left, right, centered BOOL).
    if (!types || (strcmp(types, "v36@0:8@16@24@32B36") != 0 && strcmp(types, "v36@0:8@16@24@32c36") != 0)) {
        NSLog(@"[InstagramX] profile header hook skipped, encoding %s", types ?: "?");
        return;
    }
    ix_orig_configure = (void (*)(id, SEL, id, id, id, BOOL))method_getImplementation(method);
    method_setImplementation(method, (IMP)IXConfigureHeader);
}
