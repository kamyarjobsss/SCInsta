#import "IXTrafficGuard.h"
#import "IXProxyManager.h"
#import "../Utils.h"

#import <WebKit/WebKit.h>

static void IXApplyProxy(NSURLSessionConfiguration *config) {
    if (!config || !IXTrafficGuardVPNOn()) return;
    config.connectionProxyDictionary = IXTrafficGuardProxyDictionary();
}

%group IXTrafficSessionHooks
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    IXApplyProxy(config);
    return config;
}
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    IXApplyProxy(config);
    return config;
}
+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *config = %orig;
    IXApplyProxy(config);
    return config;
}
- (void)setConnectionProxyDictionary:(NSDictionary *)dict {
    if (IXTrafficGuardVPNOn()) {
        %orig(IXTrafficGuardProxyDictionary());
        return;
    }
    %orig;
}
%end

%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (configuration && IXTrafficGuardVPNOn()) {
        @try {
            id store = configuration.websiteDataStore;
            SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
            if (store && [store respondsToSelector:setter]) {
                NSLog(@"[InstagramX] WKWebView proxy setter exists but no public proxy object was built; socket hooks still apply in-process");
            }
        } @catch (NSException *exception) {
            NSLog(@"[InstagramX] WKWebView proxy setup skipped: %@", exception.reason);
        }
    }
    return %orig;
}
%end
%end

void IXTrafficHooksInstall(void) {
#if IX_LITE
    return;
#else
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    %init(IXTrafficSessionHooks);
#endif
}
