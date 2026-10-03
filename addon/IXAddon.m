#import "../src/Launch/IXLaunchGuard.h"
#import "../src/Location/IXLocationHooks.h"
#import "../src/Location/IXLocationStore.h"
#import "../src/Proxy/IXProxyManager.h"
#import "../src/Features/General/IXSettingsEntry.h"

#import <UIKit/UIKit.h>

static void IXAddonShowSafeAlert(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) window = candidate;
            }
        }
        UIViewController *presenter = window.rootViewController;
        if (!presenter) return;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Instagram X safe mode"
                                                                       message:@"The last launch closed before Instagram X was ready, so the settings row, proxy, and fake location stayed off. Open Instagram X settings from Accounts Center on the next launch, or turn a feature on after this one stays open."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Show settings row" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            IXSettingsEntryInstall();
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void IXAddonDidLaunch(void) {
    BOOL safe = IXLaunchGuardIsSafeMode();
    if (!safe) {
        IXSettingsEntryInstall();
        if ([IXLocationStore isEnabled]) IXLocationHooksInstall();
        [IXProxyManager.shared restoreOnLaunch];
    } else {
        IXAddonShowSafeAlert();
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IXLaunchGuardMarkReady();
    });
}

__attribute__((constructor(200)))
static void IXAddonStart(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        IXAddonDidLaunch();
    }];
}
