#import "../../Utils.h"
#import "../../Localization/SCILocalization.h"
#import <objc/runtime.h>
#import <objc/message.h>
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

%ctor {
    %init;
    IXInstallHeaderHook();
}
