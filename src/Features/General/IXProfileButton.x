#import "../../Utils.h"
#import "../../Localization/SCILocalization.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>

// Own-profile header button.
//
// Instagram 436's header is the Swift class
// _TtC24IGProfileNavigationSwift29IGProfileNavigationHeaderView.
// configureWithTitleView:leftButtons:rightButtons:titleIsCentered: is
// v44@0:8@16@24@32B40. The dotted Swift name is not an ObjC class, which is
// why the button never appeared.
//
// The button is inserted into the same left/right button array as the "+"
// (accessibility id profile-add-button), so it is a real header item. On
// reuse the incoming array is stripped and the button is added back only
// when that "+" is present. It is never added to a window.

static const char *kIXHeaderClass = "_TtC24IGProfileNavigationSwift29IGProfileNavigationHeaderView";
static const char *kIXWrapperClass = "_TtC40IGProfileNavigationHeaderViewButtonSwift35IGProfileNavigationHeaderViewButton";
static const char *kIXConfigureSel = "configureWithTitleView:leftButtons:rightButtons:titleIsCentered:";
static NSString *const kIXMenuID = @"ix-profile-menu-button";
static NSString *const kIXAddID = @"profile-add-button";

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
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *mark = IXMarkImage();
    if (mark) {
        [button setImage:mark forState:UIControlStateNormal];
    } else {
        [button setImage:[UIImage systemImageNamed:@"circle.hexagongrid"] forState:UIControlStateNormal];
    }
    button.tintColor = [UIColor labelColor];
    button.frame = CGRectMake(0, 0, 28, 28);
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    button.accessibilityIdentifier = kIXMenuID;
    button.accessibilityLabel = [SCIResolvedLanguageCode() hasPrefix:@"fa"] ? @"اینستاگرام ایکس" : @"Instagram X";
    return button;
}

static void IXOpenMenuIMP(id self, SEL _cmd) {
    UIView *view = [self isKindOfClass:[UIView class]] ? self : nil;
    [SCIUtils showSettingsVC:view.window];
}

static void IXSettingsGesture(id self, SEL _cmd, UIGestureRecognizer *gesture) {
    if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
        if (gesture.state != UIGestureRecognizerStateBegan) return;
    } else if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }
    UIView *view = [self isKindOfClass:[UIView class]] ? (UIView *)self : nil;
    [SCIUtils showSettingsVC:view.window];
}

static void IXEnsureActions(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        class_addMethod([UIButton class], @selector(ix_openMenu), (IMP)IXOpenMenuIMP, "v@:");
        class_addMethod([UIView class], @selector(ix_settingsGesture:), (IMP)IXSettingsGesture, "v@:@");
    });
}

static UIView *IXBuildButton(void) {
    IXEnsureActions();
    UIButton *button = (UIButton *)IXMarkButton();
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [button addTarget:button action:@selector(ix_openMenu) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static BOOL IXViewContainsIdentifier(UIView *view, NSString *identifier) {
    if (![view isKindOfClass:[UIView class]] || identifier.length == 0) return NO;
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return YES;
    for (UIView *sub in view.subviews) {
        if (IXViewContainsIdentifier(sub, identifier)) return YES;
    }
    return NO;
}

static BOOL IXWrapperHasIdentifier(id wrapper, NSString *identifier) {
    UIView *view = IXValue(wrapper, @"view");
    return IXViewContainsIdentifier(view, identifier);
}

static void IXRemoveMarkViews(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return;
    if ([view.accessibilityIdentifier isEqualToString:kIXMenuID]) {
        [view removeFromSuperview];
        return;
    }
    for (UIView *sub in view.subviews.copy) IXRemoveMarkViews(sub);
}

static id IXMakeWrapper(id sample, UIView *button) {
    Class wrapperCls = objc_getClass(kIXWrapperClass);
    if (!wrapperCls) wrapperCls = NSClassFromString(@(kIXWrapperClass));
    if (!wrapperCls) return nil;
    NSInteger type = 0;
    id typeVal = IXValue(sample, @"type");
    if ([typeVal respondsToSelector:@selector(integerValue)]) type = [typeVal integerValue];
    id allocated = [wrapperCls alloc];
    SEL initSel = @selector(initWithType:view:);
    if (![allocated respondsToSelector:initSel]) return nil;
    return ((id (*)(id, SEL, NSInteger, id))objc_msgSend)(allocated, initSel, type, button);
}

static NSArray *IXButtonsByStrippingOurs(id buttons) {
    if (![buttons isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *next = [NSMutableArray array];
    for (id wrapper in buttons) {
        if (IXWrapperHasIdentifier(wrapper, kIXMenuID)) continue;
        [next addObject:wrapper];
    }
    return next;
}

static NSArray *IXButtonsInsertingMenu(NSArray *buttons) {
    if (buttons.count == 0) return buttons;
    NSUInteger addIndex = NSNotFound;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        if (IXWrapperHasIdentifier(buttons[i], kIXAddID)) {
            addIndex = i;
            break;
        }
    }
    if (addIndex == NSNotFound) return buttons;
    id wrapper = IXMakeWrapper(buttons[addIndex], IXBuildButton());
    if (!wrapper) return buttons;
    NSMutableArray *next = [buttons mutableCopy];
    [next insertObject:wrapper atIndex:addIndex + 1];
    return next;
}

static void (*ix_orig_configure)(id, SEL, id, id, id, BOOL);

static void IXConfigureHeader(id self, SEL _cmd, id titleView, id leftButtons, id rightButtons, BOOL titleIsCentered) {
    if (!ix_orig_configure) return;
    @try {
        NSArray *left = IXButtonsByStrippingOurs(leftButtons);
        NSArray *right = IXButtonsByStrippingOurs(rightButtons);
        BOOL own = NO;
        for (id wrapper in left) {
            if (IXWrapperHasIdentifier(wrapper, kIXAddID)) { own = YES; break; }
        }
        if (!own) {
            for (id wrapper in right) {
                if (IXWrapperHasIdentifier(wrapper, kIXAddID)) { own = YES; break; }
            }
        }
        id patchedLeft = left ?: leftButtons;
        id patchedRight = right ?: rightButtons;
        if (own) {
            NSArray *withMenu = IXButtonsInsertingMenu(left);
            if (withMenu != left && withMenu.count == (left.count + 1)) {
                patchedLeft = withMenu;
            } else {
                withMenu = IXButtonsInsertingMenu(right);
                if (withMenu != right && right && withMenu.count == (right.count + 1)) patchedRight = withMenu;
            }
        }
        ix_orig_configure(self, _cmd, titleView, patchedLeft, patchedRight, titleIsCentered);
        if (!own && [self isKindOfClass:[UIView class]]) IXRemoveMarkViews((UIView *)self);
    } @catch (__unused NSException *exception) {
        ix_orig_configure(self, _cmd, titleView, leftButtons, rightButtons, titleIsCentered);
    }
}

static BOOL ixHeaderHooked = NO;

static void IXInstallHeaderHook(void) {
    if (ixHeaderHooked) return;
    Class cls = objc_getClass(kIXHeaderClass);
    if (!cls) cls = NSClassFromString(@(kIXHeaderClass));
    if (!cls) return;
    SEL sel = sel_registerName(kIXConfigureSel);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        NSLog(@"[InstagramX] profile header hook skipped, missing %s", kIXConfigureSel);
        return;
    }
    const char *types = method_getTypeEncoding(method);
    if (!types || (strcmp(types, "v44@0:8@16@24@32B40") != 0 &&
                   strcmp(types, "v36@0:8@16@24@32B36") != 0 &&
                   strcmp(types, "v36@0:8@16@24@32c36") != 0)) {
        NSLog(@"[InstagramX] profile header hook skipped, encoding %s", types ?: "?");
        return;
    }
    ix_orig_configure = (void (*)(id, SEL, id, id, id, BOOL))method_getImplementation(method);
    method_setImplementation(method, (IMP)IXConfigureHeader);
    ixHeaderHooked = YES;
    NSLog(@"[InstagramX] profile header hook installed on %s", kIXHeaderClass);
}

static id IXIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static char kIXTabGestures;

static void IXArmTabButton(UIView *button, BOOL home) {
    if (![button isKindOfClass:[UIView class]]) return;
    if (![button respondsToSelector:@selector(addGestureRecognizer:)]) return;
    if (objc_getAssociatedObject(button, &kIXTabGestures)) return;
    IXEnsureActions();
    objc_setAssociatedObject(button, &kIXTabGestures, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:button action:@selector(ix_settingsGesture:)];
    press.minimumPressDuration = 0.45;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    [button addGestureRecognizer:press];
    if (!home) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:button action:@selector(ix_settingsGesture:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    [button addGestureRecognizer:tap];
}

static void IXArmTabButtons(id controller) {
    IXInstallHeaderHook();
    IXArmTabButton(IXIvar(controller, "_profileButton"), NO);
    IXArmTabButton(IXIvar(controller, "_timelineButton"), YES);
}

// The configure-array insert is not enough: Instagram rebuilds the visible
// header later, and the own-profile "+" is the view whose accessibility
// identifier is profile-add-button. Place a real button in that view's
// superview, immediately beside it, and drop it when the "+" leaves.
static char kIXBesideAdd;

static UIButton *IXMenuBeside(UIView *addButton) {
    UIButton *existing = objc_getAssociatedObject(addButton, &kIXBesideAdd);
    if ([existing isKindOfClass:[UIButton class]]) return existing;
    UIButton *button = (UIButton *)IXBuildButton();
    objc_setAssociatedObject(addButton, &kIXBesideAdd, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

static CGRect IXInkNorm(UIImage *image) {
    if (!image || image.size.width < 1 || image.size.height < 1) return CGRectZero;
    CGFloat scale = image.scale > 0 ? image.scale : 1;
    size_t w = (size_t)lrint(image.size.width * scale);
    size_t h = (size_t)lrint(image.size.height * scale);
    if (w < 1 || h < 1 || w > 400 || h > 400) return CGRectZero;
    uint8_t *pixels = calloc(w * h, 4);
    if (!pixels) return CGRectZero;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) {
        free(pixels);
        return CGRectZero;
    }
    CGContextTranslateCTM(ctx, 0, (CGFloat)h);
    CGContextScaleCTM(ctx, scale, -scale);
    UIGraphicsPushContext(ctx);
    [[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    size_t minX = w, minY = h, maxX = 0, maxY = 0;
    BOOL any = NO;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            if (pixels[(y * w + x) * 4 + 3] < 24) continue;
            any = YES;
            if (x < minX) minX = x;
            if (y < minY) minY = y;
            if (x > maxX) maxX = x;
            if (y > maxY) maxY = y;
        }
    }
    free(pixels);
    if (!any) return CGRectZero;
    return CGRectMake((CGFloat)minX / (CGFloat)w, (CGFloat)minY / (CGFloat)h,
                      (CGFloat)(maxX - minX + 1) / (CGFloat)w, (CGFloat)(maxY - minY + 1) / (CGFloat)h);
}

static void IXInstaRGB(CGFloat t, CGFloat out[3]) {
    static const CGFloat pal[5][3] = {
        {254.f / 255.f, 218.f / 255.f, 117.f / 255.f},
        {250.f / 255.f, 126.f / 255.f, 30.f / 255.f},
        {214.f / 255.f, 41.f / 255.f, 118.f / 255.f},
        {150.f / 255.f, 47.f / 255.f, 191.f / 255.f},
        {79.f / 255.f, 91.f / 255.f, 213.f / 255.f}
    };
    t -= floor(t);
    CGFloat scaled = t * 5.f;
    int index = (int)scaled;
    if (index < 0) index = 0;
    if (index > 4) index = 4;
    int next = (index + 1) % 5;
    CGFloat blend = scaled - (CGFloat)index;
    blend = blend * blend * (3.f - 2.f * blend);
    for (int channel = 0; channel < 3; channel++) {
        out[channel] = pal[index][channel] + (pal[next][channel] - pal[index][channel]) * blend;
    }
}

static UIImage *IXMarkMatchedToPlus(UIImage *plus, CGSize glyph, CGFloat phase) {
    UIImage *mark = IXMarkImage();
    if (!mark || glyph.width < 8 || glyph.height < 8) return mark;
    CGRect plusInk = IXInkNorm(plus);
    if (CGRectIsEmpty(plusInk)) plusInk = CGRectMake(0.15, 0.15, 0.7, 0.7);
    CGRect ourInk = IXInkNorm(mark);
    if (CGRectIsEmpty(ourInk)) ourInk = CGRectMake(0, 0, 1, 1);
    CGRect plusBox;
    if (plus.size.width < 1 || plus.size.height < 1) {
        plusBox = CGRectInset((CGRect){CGPointZero, glyph}, glyph.width * 0.15, glyph.height * 0.15);
    } else {
        CGFloat fit = MIN(glyph.width / plus.size.width, glyph.height / plus.size.height);
        CGSize drawnPlus = CGSizeMake(plus.size.width * fit, plus.size.height * fit);
        plusBox = CGRectMake((glyph.width - drawnPlus.width) / 2.0, (glyph.height - drawnPlus.height) / 2.0, drawnPlus.width, drawnPlus.height);
    }
    CGRect target = CGRectMake(plusBox.origin.x + plusInk.origin.x * plusBox.size.width,
                               plusBox.origin.y + plusInk.origin.y * plusBox.size.height,
                               plusInk.size.width * plusBox.size.width,
                               plusInk.size.height * plusBox.size.height);
    CGFloat scale = MIN(target.size.width / MAX(ourInk.size.width * mark.size.width, 0.01),
                        target.size.height / MAX(ourInk.size.height * mark.size.height, 0.01));
    CGSize drawn = CGSizeMake(mark.size.width * scale, mark.size.height * scale);
    CGRect ourBox = CGRectMake(CGRectGetMidX(target) - (ourInk.origin.x * drawn.width + ourInk.size.width * drawn.width / 2.0),
                               CGRectGetMidY(target) - (ourInk.origin.y * drawn.height + ourInk.size.height * drawn.height / 2.0),
                               drawn.width, drawn.height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    CGFloat screenScale = UIScreen.mainScreen.scale;
    format.scale = screenScale >= 1 ? screenScale : 3;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:glyph format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextSaveGState(ctx);
        CGFloat mid[3];
        IXInstaRGB(phase + 0.12f, mid);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 2.0, [UIColor colorWithRed:mid[0] green:mid[1] blue:mid[2] alpha:0.22].CGColor);
        [[mark imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:ourBox];
        CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
        CGContextBeginTransparencyLayer(ctx, NULL);
        [[mark imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:ourBox];
        CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat stops[3][3];
        IXInstaRGB(phase, stops[0]);
        IXInstaRGB(phase + 0.12f, stops[1]);
        IXInstaRGB(phase + 0.24f, stops[2]);
        CGFloat colors[] = {
            stops[0][0], stops[0][1], stops[0][2], 1.f,
            stops[1][0], stops[1][1], stops[1][2], 1.f,
            stops[2][0], stops[2][1], stops[2][2], 1.f
        };
        CGFloat locations[] = {0.f, 0.5f, 1.f};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, locations, 3);
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(CGRectGetMinX(ourBox), CGRectGetMaxY(ourBox)), CGPointMake(CGRectGetMaxX(ourBox), CGRectGetMinY(ourBox)), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static char kIXGlyph;
static char kIXPlusImage;
static NSHashTable *ix_marks;
static CADisplayLink *ix_markLink;

@interface IXMarkPulse : NSObject
@end

@implementation IXMarkPulse
+ (void)tick {
    CGFloat phase = fmod(CACurrentMediaTime(), 10.0) / 10.0;
    for (UIButton *button in ix_marks.allObjects) {
        if (![button isKindOfClass:[UIButton class]] || button.window == nil) continue;
        NSValue *glyph = objc_getAssociatedObject(button, &kIXGlyph);
        if (![glyph isKindOfClass:[NSValue class]]) continue;
        id plus = objc_getAssociatedObject(button, &kIXPlusImage);
        UIImage *image = IXMarkMatchedToPlus([plus isKindOfClass:[UIImage class]] ? plus : nil, glyph.CGSizeValue, phase);
        if (image) [button setImage:image forState:UIControlStateNormal];
    }
}
@end

static void IXPlaceMenuBesideAddButton(UIView *addButton) {
    static __thread int placing = 0;
    if (placing) return;
    if (![addButton isKindOfClass:[UIView class]]) return;
    placing = 1;
    if (addButton.window == nil) {
        UIButton *existing = objc_getAssociatedObject(addButton, &kIXBesideAdd);
        [existing removeFromSuperview];
        placing = 0;
        return;
    }
    UIView *host = addButton.superview;
    if (![host isKindOfClass:[UIView class]] || [host isKindOfClass:[UIWindow class]]) {
        placing = 0;
        return;
    }
    UIButton *button = IXMenuBeside(addButton);
    if (button.superview != host) {
        [button removeFromSuperview];
        [host insertSubview:button aboveSubview:addButton];
    }
    CGRect addFrame = addButton.frame;
    UIButton *add = [addButton isKindOfClass:[UIButton class]] ? (UIButton *)addButton : nil;
    CGRect glyph = add.imageView ? [add.imageView convertRect:add.imageView.bounds toView:host] : CGRectZero;
    if (glyph.size.width < 8 || glyph.size.height < 8) {
        CGFloat side = MIN(addFrame.size.width, addFrame.size.height);
        if (side < 16 || side > 44) side = 22;
        glyph = CGRectMake(0, CGRectGetMidY(addFrame) - side / 2.0, side, side);
    }
    UIImage *plus = [add imageForState:UIControlStateNormal];
    if (!ix_marks) ix_marks = [NSHashTable weakObjectsHashTable];
    [ix_marks addObject:button];
    NSValue *previous = objc_getAssociatedObject(button, &kIXGlyph);
    BOOL sameGlyph = [previous isKindOfClass:[NSValue class]] && CGSizeEqualToSize(previous.CGSizeValue, glyph.size);
    objc_setAssociatedObject(button, &kIXGlyph, [NSValue valueWithCGSize:glyph.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(button, &kIXPlusImage, plus, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ix_markLink) {
        ix_markLink = [CADisplayLink displayLinkWithTarget:[IXMarkPulse class] selector:@selector(tick)];
        if ([ix_markLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) ix_markLink.preferredFramesPerSecond = 30;
        [ix_markLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    if (!sameGlyph || button.currentImage == nil) {
        UIImage *matched = IXMarkMatchedToPlus(plus, glyph.size, fmod(CACurrentMediaTime(), 10.0) / 10.0);
        if (matched) [button setImage:matched forState:UIControlStateNormal];
    }
    button.contentEdgeInsets = UIEdgeInsetsZero;
    button.imageEdgeInsets = UIEdgeInsetsZero;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    CGFloat x = CGRectGetMidX(addFrame) <= CGRectGetMidX(host.bounds)
        ? CGRectGetMaxX(addFrame) + 2
        : CGRectGetMinX(addFrame) - 2 - glyph.size.width;
    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.frame = CGRectMake(x, glyph.origin.y, glyph.size.width, glyph.size.height);
    placing = 0;
}

static char kIXHamburger;

static void IXArmHamburger(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) return;
    if (objc_getAssociatedObject(view, &kIXHamburger)) return;
    IXEnsureActions();
    objc_setAssociatedObject(view, &kIXHamburger, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:view action:@selector(ix_settingsGesture:)];
    press.minimumPressDuration = 0.45;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    [view addGestureRecognizer:press];
}

%hook IGTabBarController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    IXArmTabButtons(self);
}
- (void)_createAndConfigureProfileButtonIfNeeded {
    %orig;
    IXArmTabButtons(self);
}
- (void)_createAndConfigureTimelineButtonIfNeeded {
    %orig;
    IXArmTabButtons(self);
}
%end

%hook UIView
- (void)didMoveToWindow {
    %orig;
    NSString *identifier = self.accessibilityIdentifier;
    if (identifier.length == 0) return;
    if ([identifier isEqualToString:kIXAddID]) IXPlaceMenuBesideAddButton(self);
    else if ([identifier isEqualToString:@"profile-more-button"]) IXArmHamburger(self);
}
- (void)layoutSubviews {
    %orig;
    NSString *identifier = self.accessibilityIdentifier;
    if (identifier.length == 0) return;
    if ([identifier isEqualToString:kIXAddID]) IXPlaceMenuBesideAddButton(self);
    else if ([identifier isEqualToString:@"profile-more-button"]) IXArmHamburger(self);
}
%end

%ctor {
    %init;
    IXInstallHeaderHook();
}
