#import "IXTrafficGuard.h"
#import "IXProxyManager.h"
#import "../Utils.h"

#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static char kIXTaskWatch;

@interface IXTaskWatch : NSObject
@property (nonatomic, weak) NSURLSessionTask *task;
@end

@implementation IXTaskWatch
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kIXTaskWatch) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    NSURLSessionTask *task = object;
    if (![task isKindOfClass:[NSURLSessionTask class]]) return;
    if (task.state != NSURLSessionTaskStateCompleted && task.state != NSURLSessionTaskStateCanceling) return;
    @try { [task removeObserver:self forKeyPath:@"state" context:&kIXTaskWatch]; }
    @catch (__unused NSException *exception) {}
    objc_setAssociatedObject(task, &kIXTaskWatch, nil, OBJC_ASSOCIATION_ASSIGN);
    NSURL *url = task.originalRequest.URL ?: task.currentRequest.URL;
    NSString *reason = @"completed";
    if (task.error) reason = task.error.localizedDescription ?: @"failed";
    else if (task.state == NSURLSessionTaskStateCanceling) reason = @"cancelled";
    IXTrafficGuardNoteSession(url.host ?: url.absoluteString, url.port.unsignedShortValue, (uint64_t)MAX(task.countOfBytesSent, 0), (uint64_t)MAX(task.countOfBytesReceived, 0), reason);
}
@end

static void IXWatchTask(NSURLSessionTask *task) {
    if (![task isKindOfClass:[NSURLSessionTask class]] || !IXTrafficGuardVPNOn()) return;
    if (objc_getAssociatedObject(task, &kIXTaskWatch)) return;
    IXTaskWatch *watch = [IXTaskWatch new];
    watch.task = task;
    objc_setAssociatedObject(task, &kIXTaskWatch, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try { [task addObserver:watch forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:&kIXTaskWatch]; }
    @catch (__unused NSException *exception) {
        objc_setAssociatedObject(task, &kIXTaskWatch, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

static void IXApplyProxy(NSURLSessionConfiguration *config) {
    if (!config || !IXTrafficGuardVPNOn()) return;
    config.connectionProxyDictionary = IXTrafficGuardProxyDictionary();
}

%group IXTrafficSessionHooks
%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    IXApplyProxy(configuration);
    return %orig;
}
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue {
    IXApplyProxy(configuration);
    return %orig;
}
%end

%hook NSURLSessionTask
- (void)resume {
    IXWatchTask(self);
    %orig;
}
%end

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
