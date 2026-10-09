#import "IXTrafficGuard.h"
#import "IXPathHooks.h"
#import "IXProxyManager.h"
#import "../Utils.h"

#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static char kIXTaskWatch;
static char kIXBlocked;

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
    NSNumber *blocked = objc_getAssociatedObject(task, &kIXBlocked);
    NSString *reason = @"tunneled";
    if (blocked.boolValue) reason = @"blocked by kill switch";
    else if (task.error) reason = task.error.localizedDescription ?: @"failed";
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

static BOOL IXURLIsLocal(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"::1"];
}

static void IXApplyProxy(NSURLSessionConfiguration *config) {
    if (IXTrafficGuardThreadBypass()) return;
    if (!config || !IXTrafficGuardVPNOn()) return;
    if (!IXTrafficGuardProxyUp() && !IXTrafficGuardKillSwitch()) return;
    config.connectionProxyDictionary = IXTrafficGuardProxyDictionary();
    if (@available(iOS 17.0, *)) {
        SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
        if ([config respondsToSelector:setter]) {
            uint16_t port = IXTrafficGuardProxyUp() ? IXTrafficGuardSocksPort() : 9;
            id proxy = IXPathHookProxyObjectOnPort(port);
            if (proxy) ((void (*)(id, SEL, id))objc_msgSend)(config, setter, @[proxy]);
        }
    }
}

static BOOL IXApplyWebProxy(WKWebViewConfiguration *configuration) {
    if (!configuration || !IXTrafficGuardVPNOn()) return NO;
    if (!IXTrafficGuardProxyUp() && !IXTrafficGuardKillSwitch()) return NO;
    id store = configuration.websiteDataStore;
    SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
    if (!store || ![store respondsToSelector:setter]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            IXTrafficGuardNote(@"webview", @"", 0, @"direct (no proxy config)");
            NSLog(@"[InstagramX] WKWebView has no setProxyConfigurations:");
        });
        return NO;
    }
    uint16_t port = IXTrafficGuardProxyUp() ? IXTrafficGuardSocksPort() : 9;
    id proxy = IXPathHookProxyObjectOnPort(port);
    if (!proxy) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            IXTrafficGuardNote(@"webview", @"", 0, @"direct (no proxy object)");
            NSLog(@"[InstagramX] WKWebView proxy object was not created");
        });
        return NO;
    }
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(store, setter, @[proxy]);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[InstagramX] WKWebView proxy setup skipped: %@", exception.reason);
        return NO;
    }
}

@interface IXMediaJob : NSObject
@property (nonatomic, strong) AVAssetResourceLoadingRequest *request;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *playlist;
@property (nonatomic, assign) BOOL playlistMode;
@property (nonatomic, copy) NSString *uti;
@property (nonatomic, assign) long long total;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@end

@implementation IXMediaJob
@end

@interface IXMediaTunnel : NSObject <NSURLSessionDataDelegate, AVAssetResourceLoaderDelegate>
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMapTable<NSURLSessionTask *, IXMediaJob *> *jobs;
@end

@implementation IXMediaTunnel

+ (instancetype)shared {
    static IXMediaTunnel *tunnel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tunnel = [IXMediaTunnel new];
        tunnel.queue = dispatch_queue_create("instagramx.media", DISPATCH_QUEUE_SERIAL);
        tunnel.jobs = [NSMapTable strongToStrongObjectsMapTable];
    });
    return tunnel;
}

static BOOL IXPlaylistURL(NSURL *url) {
    NSString *path = url.path.lowercaseString ?: @"";
    return [path hasSuffix:@".m3u8"] || [path hasSuffix:@".m3u"];
}

static BOOL IXPlaylistMIME(NSString *mime) {
    NSString *lower = mime.lowercaseString ?: @"";
    return [lower containsString:@"mpegurl"] || [lower containsString:@"m3u8"];
}

static NSString *IXUTIForMIME(NSString *mime, NSURL *url, BOOL playlist) {
    if (playlist || IXPlaylistURL(url) || IXPlaylistMIME(mime)) return @"public.m3u-playlist";
    if (@available(iOS 14.0, *)) {
        UTType *type = mime.length ? [UTType typeWithMIMEType:mime] : nil;
        if (type.identifier.length) return type.identifier;
    }
    NSString *path = url.path.lowercaseString ?: @"";
    if ([path hasSuffix:@".mp4"] || [mime containsString:@"mp4"]) return @"public.mpeg-4";
    if ([path hasSuffix:@".mov"]) return @"com.apple.quicktime-movie";
    if ([mime hasPrefix:@"image/jpeg"]) return @"public.jpeg";
    if ([mime hasPrefix:@"image/png"]) return @"public.png";
    return @"public.mpeg-4";
}

static NSData *IXRewritePlaylist(NSData *data) {
    if (data.length == 0) return data;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0 || [text rangeOfString:@"#EXTM3U"].location == NSNotFound) return data;
    text = [text stringByReplacingOccurrencesOfString:@"https://" withString:@"ix-media://"];
    text = [text stringByReplacingOccurrencesOfString:@"http://" withString:@"ix-media-http://"];
    return [text dataUsingEncoding:NSUTF8StringEncoding] ?: data;
}

static NSURL *IXRestoreMediaURL(NSURL *url) {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([parts.scheme isEqualToString:@"ix-media"]) parts.scheme = @"https";
    else if ([parts.scheme isEqualToString:@"ix-media-http"]) parts.scheme = @"http";
    else return nil;
    return parts.URL;
}

static long long IXResourceLength(NSHTTPURLResponse *http) {
    if (!http) return 0;
    NSString *range = nil;
    for (NSString *key in http.allHeaderFields) {
        if ([key caseInsensitiveCompare:@"Content-Range"] == NSOrderedSame) {
            id value = http.allHeaderFields[key];
            if ([value isKindOfClass:[NSString class]]) range = value;
            break;
        }
    }
    NSRange slash = [range rangeOfString:@"/"];
    if (slash.location != NSNotFound) {
        long long total = [[range substringFromIndex:slash.location + 1] longLongValue];
        if (total > 0) return total;
    }
    return http.expectedContentLength > 0 ? http.expectedContentLength : 0;
}

- (IXMediaJob *)jobForTask:(NSURLSessionTask *)task {
    return [self.jobs objectForKey:task];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    NSURL *real = IXRestoreMediaURL(request.request.URL);
    if (!real) {
        [request finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil]];
        return YES;
    }
    uint16_t port = real.port.unsignedShortValue;
    if (IXTrafficGuardVPNOn() && IXTrafficGuardKillSwitch() && !IXTrafficGuardProxyUp()) {
        IXTrafficGuardNote(@"avplayer", real.host, port, @"blocked by kill switch");
        [request finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
        return YES;
    }
    NSMutableURLRequest *outbound = [request.request mutableCopy] ?: [NSMutableURLRequest requestWithURL:real];
    outbound.URL = real;
    if ([outbound respondsToSelector:@selector(setAssumesHTTP3Capable:)]) outbound.assumesHTTP3Capable = NO;
    BOOL playlist = IXPlaylistURL(real);
    AVAssetResourceLoadingDataRequest *data = request.dataRequest;
    if (!playlist && data) {
        long long offset = data.requestedOffset;
        if (data.requestsAllDataToEndOfResource) {
            if (offset > 0) [outbound setValue:[NSString stringWithFormat:@"bytes=%lld-", offset] forHTTPHeaderField:@"Range"];
        } else if (data.requestedLength > 0 && data.requestedLength < NSIntegerMax / 4) {
            long long end = offset + (long long)data.requestedLength - 1;
            [outbound setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", offset, end] forHTTPHeaderField:@"Range"];
        }
    } else {
        [outbound setValue:nil forHTTPHeaderField:@"Range"];
    }
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.connectionProxyDictionary = IXTrafficGuardProxyDictionary();
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    config.HTTPShouldSetCookies = YES;
    NSOperationQueue *callbacks = [NSOperationQueue new];
    callbacks.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:callbacks];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:outbound];
    IXMediaJob *job = [IXMediaJob new];
    job.request = request;
    job.session = session;
    job.playlist = [NSMutableData data];
    job.playlistMode = playlist;
    job.host = real.host;
    job.port = port;
    [self.jobs setObject:job forKey:task];
    [task resume];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)request {
    NSURLSessionTask *found = nil;
    for (NSURLSessionTask *task in self.jobs.keyEnumerator) {
        IXMediaJob *job = [self.jobs objectForKey:task];
        if (job.request == request) {
            found = task;
            break;
        }
    }
    if (!found) return;
    IXMediaJob *job = [self.jobs objectForKey:found];
    [found cancel];
    [job.session invalidateAndCancel];
    [self.jobs removeObjectForKey:found];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    __block NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
    dispatch_sync(self.queue, ^{
        IXMediaJob *job = [self jobForTask:dataTask];
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        if (!job || http.statusCode >= 400) {
            disposition = NSURLSessionResponseCancel;
            return;
        }
        BOOL playlist = job.playlistMode || IXPlaylistMIME(http.MIMEType);
        job.playlistMode = playlist;
        job.uti = IXUTIForMIME(http.MIMEType, dataTask.originalRequest.URL, playlist);
        job.total = IXResourceLength(http);
        if (!playlist && job.request.contentInformationRequest) {
            job.request.contentInformationRequest.contentType = job.uti;
            job.request.contentInformationRequest.contentLength = job.total;
            job.request.contentInformationRequest.byteRangeAccessSupported = YES;
        }
    });
    completionHandler(disposition);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    dispatch_sync(self.queue, ^{
        IXMediaJob *job = [self jobForTask:dataTask];
        if (!job.request) return;
        if (job.playlistMode) {
            [job.playlist appendData:data];
            return;
        }
        @try { [job.request.dataRequest respondWithData:data]; }
        @catch (__unused NSException *exception) {}
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_sync(self.queue, ^{
        IXMediaJob *job = [self jobForTask:task];
        [self.jobs removeObjectForKey:task];
        AVAssetResourceLoadingRequest *request = job.request;
        if (!request) {
            [session finishTasksAndInvalidate];
            return;
        }
        if (error) {
            NSString *reason = (!IXTrafficGuardProxyUp() && IXTrafficGuardKillSwitch()) ? @"blocked by kill switch" : (error.localizedDescription ?: @"failed");
            IXTrafficGuardNote(@"avplayer", job.host, job.port, reason);
            [request finishLoadingWithError:error];
            [session finishTasksAndInvalidate];
            return;
        }
        if (job.playlistMode) {
            NSData *body = IXRewritePlaylist(job.playlist);
            if (request.contentInformationRequest) {
                request.contentInformationRequest.contentType = job.uti ?: @"public.m3u-playlist";
                request.contentInformationRequest.contentLength = (long long)body.length;
                request.contentInformationRequest.byteRangeAccessSupported = YES;
            }
            AVAssetResourceLoadingDataRequest *data = request.dataRequest;
            if (data && body.length) {
                long long offset = data.requestedOffset;
                long long length = data.requestsAllDataToEndOfResource ? (long long)body.length - offset : (long long)data.requestedLength;
                if (offset < 0) offset = 0;
                if (offset > (long long)body.length) offset = (long long)body.length;
                if (length < 0) length = 0;
                if (offset + length > (long long)body.length) length = (long long)body.length - offset;
                if (length > 0) {
                    [data respondWithData:[body subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)length)]];
                }
            }
        }
        IXTrafficGuardNote(@"avplayer", job.host, job.port, @"tunneled");
        [request finishLoading];
        [session finishTasksAndInvalidate];
    });
}

@end

static NSURL *IXMediaRewrite(NSURL *url) {
    if (!url || !IXTrafficGuardVPNOn() || IXTrafficGuardCallerIsSelf()) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    if (!IXTrafficGuardProxyUp() && !IXTrafficGuardKillSwitch()) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!parts) return nil;
    parts.scheme = [scheme isEqualToString:@"https"] ? @"ix-media" : @"ix-media-http";
    return parts.URL;
}

static void IXMediaAttach(AVURLAsset *asset) {
    if (![asset isKindOfClass:[AVURLAsset class]]) return;
    IXMediaTunnel *tunnel = [IXMediaTunnel shared];
    [asset.resourceLoader setDelegate:tunnel queue:tunnel.queue];
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
    NSURL *url = self.originalRequest.URL ?: self.currentRequest.URL;
    if (IXTrafficGuardHostIsDirect(url.host.UTF8String)) {
        IXWatchTask(self);
        %orig;
        return;
    }
    if (IXTrafficGuardVPNOn() && !IXURLIsLocal(url) && IXTrafficGuardKillSwitch() && !IXTrafficGuardProxyUp()) {
        objc_setAssociatedObject(self, &kIXBlocked, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IXWatchTask(self);
        [self cancel];
        return;
    }
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
    if (IXTrafficGuardThreadBypass()) {
        %orig;
        return;
    }
    if (IXTrafficGuardVPNOn() && (IXTrafficGuardProxyUp() || IXTrafficGuardKillSwitch())) {
        %orig(IXTrafficGuardProxyDictionary());
        return;
    }
    %orig;
}
%end

%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    IXApplyWebProxy(configuration);
    return %orig;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    WKWebView *view = %orig;
    IXApplyWebProxy(view.configuration);
    return view;
}
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    BOOL configured = IXApplyWebProxy(self.configuration);
    if (IXTrafficGuardVPNOn()) {
        NSString *reason = @"direct";
        if (!IXTrafficGuardProxyUp() && IXTrafficGuardKillSwitch()) reason = configured ? @"blocked by kill switch" : @"blocked by kill switch";
        else if (IXTrafficGuardProxyUp() && configured) reason = @"tunneled";
        else if (IXTrafficGuardProxyUp()) reason = @"direct (no proxy config)";
        IXTrafficGuardNote(@"webview", request.URL.host, request.URL.port.unsignedShortValue, reason);
        if (IXTrafficGuardKillSwitch() && !IXTrafficGuardProxyUp() && !configured) return nil;
    }
    return %orig;
}
%end

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    NSURL *rewritten = IXMediaRewrite(URL);
    NSURL *finalURL = rewritten ?: URL;
    if (!rewritten && URL && IXTrafficGuardVPNOn() && !IXTrafficGuardCallerIsSelf()) {
        NSString *scheme = URL.scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) {
            IXTrafficGuardNote(@"avplayer", URL.host, URL.port.unsignedShortValue, @"direct");
        }
    }
    AVURLAsset *asset = %orig(finalURL, options);
    NSString *scheme = finalURL.scheme;
    if ([scheme isEqualToString:@"ix-media"] || [scheme isEqualToString:@"ix-media-http"]) IXMediaAttach(asset);
    return asset;
}
+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
    NSURL *rewritten = IXMediaRewrite(URL);
    return %orig(rewritten ?: URL, options);
}
%end
%end

static IMP ix_orig_web_proxy;

static void IXSetWebProxy(id self, SEL cmd, id configs) {
    if (IXTrafficGuardVPNOn() && (IXTrafficGuardProxyUp() || IXTrafficGuardKillSwitch())) {
        uint16_t port = IXTrafficGuardProxyUp() ? IXTrafficGuardSocksPort() : 9;
        id proxy = IXPathHookProxyObjectOnPort(port);
        if (proxy) configs = @[proxy];
    }
    if (ix_orig_web_proxy) ((void (*)(id, SEL, id))ix_orig_web_proxy)(self, cmd, configs);
}

void IXTrafficHooksInstall(void) {
#if IX_LITE
    return;
#else
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    %init(IXTrafficSessionHooks);
    Class store = NSClassFromString(@"WKWebsiteDataStore");
    Method method = store ? class_getInstanceMethod(store, NSSelectorFromString(@"setProxyConfigurations:")) : NULL;
    if (method) ix_orig_web_proxy = method_setImplementation(method, (IMP)IXSetWebProxy);
#endif
}
