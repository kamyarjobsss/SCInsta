#import "IXBetaGate.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>

static const void *IXBetaDropKey = &IXBetaDropKey;

static BOOL IXBetaClassBlocks(id object) {
    if (!object) return NO;
    return IXBetaBlockerClassName(class_getName(object_getClass(object))) ? YES : NO;
}

static BOOL IXBetaControllerBlocks(id controller) {
    if (IXBetaClassBlocks(controller)) return YES;
    if (![controller isKindOfClass:[UINavigationController class]]) return NO;
    for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
        if (IXBetaClassBlocks(child)) return YES;
    }
    return NO;
}

static void IXDropBetaBlocker(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    if (objc_getAssociatedObject(vc, IXBetaDropKey)) return;
    objc_setAssociatedObject(vc, IXBetaDropKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (vc.isViewLoaded) {
        vc.view.hidden = YES;
        vc.view.userInteractionEnabled = NO;
    }
    UIViewController *presenter = vc.presentingViewController;
    if (presenter) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    UINavigationController *nav = vc.navigationController;
    if (nav && nav.topViewController == vc && nav.viewControllers.count > 1) {
        [nav popViewControllerAnimated:NO];
        return;
    }
    if (vc.parentViewController) {
        [vc willMoveToParentViewController:nil];
        [vc.view removeFromSuperview];
        [vc removeFromParentViewController];
        return;
    }
    UIWindow *window = vc.isViewLoaded ? vc.view.window : nil;
    if (window && window.rootViewController == vc) {
        window.hidden = YES;
        return;
    }
    if (vc.isViewLoaded) [vc.view removeFromSuperview];
}

static void IXNudgeViewDidLoad(id self, SEL _cmd) {
    (void)_cmd;
    IXDropBetaBlocker((UIViewController *)self);
}

static void IXNudgeViewDidAppear(id self, SEL _cmd, BOOL animated) {
    (void)_cmd;
    (void)animated;
    IXDropBetaBlocker((UIViewController *)self);
}

static BOOL IXReturnNo(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return NO;
}

static void IXHookBoolGetter(Class cls, const char *selName) {
    if (!cls || !selName) return;
    SEL sel = sel_registerName(selName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    if (!types || (types[0] != 'B' && types[0] != 'c' && types[0] != 'C')) return;
    if (strcmp(types, "B16@0:8") != 0 && strcmp(types, "c16@0:8") != 0 && strcmp(types, "C16@0:8") != 0) return;
    MSHookMessageEx(cls, sel, (IMP)IXReturnNo, NULL);
}

static void IXHookTestFlightFlags(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        IXHookBoolGetter(classes[i], "isTestFlightApp");
        IXHookBoolGetter(object_getClass((id)classes[i]), "isTestFlightApp");
    }
    free(classes);
}

static void IXArmNudge(void) {
    Class cls = objc_getClass("_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController");
    if (!cls) return;
    MSHookMessageEx(cls, @selector(viewDidLoad), (IMP)IXNudgeViewDidLoad, NULL);
    MSHookMessageEx(cls, @selector(viewDidAppear:), (IMP)IXNudgeViewDidAppear, NULL);
}

%hook UIViewController
- (void)presentViewController:(UIViewController *)viewController animated:(BOOL)flag completion:(void (^)(void))completion {
    if (IXBetaControllerBlocks(viewController)) {
        if (completion) completion();
        return;
    }
    %orig;
}
- (void)addChildViewController:(UIViewController *)childController {
    if (IXBetaControllerBlocks(childController)) return;
    %orig;
}
%end

%hook UIWindow
- (void)setRootViewController:(UIViewController *)rootViewController {
    if (IXBetaControllerBlocks(rootViewController)) return;
    %orig;
}
%end

%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    NSURL *url = %orig;
    if (self != [NSBundle mainBundle] || !url) return url;
    NSString *last = url.lastPathComponent;
    if (!IXBetaSandboxReceiptName(last.UTF8String)) return url;
    NSURL *directory = [url URLByDeletingLastPathComponent];
    return directory ? [directory URLByAppendingPathComponent:@"receipt"] : url;
}
%end

%hook IGUserSession
- (id)testFlightNag {
    return nil;
}
%end

%ctor {
    IXArmNudge();
    IXHookTestFlightFlags();
}
