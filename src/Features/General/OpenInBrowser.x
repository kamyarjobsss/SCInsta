// Open links in external browser + strip IG tracking from URLs
#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Extract the real URL from l.instagram.com redirects and strip tracking params
static NSURL *sciCleanBrowserURL(NSURL *url) {
    if (![SCIUtils getBoolPref:@"strip_browser_tracking"]) return url;
    if (!url) return url;

    NSString *urlStr = url.absoluteString;

    // Unwrap l.instagram.com/?u=ENCODED_URL&e=TRACKING redirects
    if ([url.host isEqualToString:@"l.instagram.com"]) {
        NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *q in comps.queryItems) {
            if ([q.name isEqualToString:@"u"] && q.value.length) {
                NSString *decoded = [q.value stringByRemovingPercentEncoding];
                if (decoded) urlStr = decoded;
                break;
            }
        }
    }

    // Strip common tracking params from the destination URL
    NSURLComponents *comps = [NSURLComponents componentsWithString:urlStr];
    if (comps.queryItems.count) {
        NSSet *trackingParams = [NSSet setWithArray:@[
            @"utm_source", @"utm_medium", @"utm_campaign", @"utm_content",
            @"utm_term", @"utm_id", @"fbclid", @"igshid", @"igsh",
            @"ig_rid", @"campaign_id", @"ad_id", @"aem"
        ]];
        NSMutableArray *clean = [NSMutableArray array];
        for (NSURLQueryItem *q in comps.queryItems) {
            if (![trackingParams containsObject:q.name]) [clean addObject:q];
        }
        comps.queryItems = clean.count ? clean : nil;
    }

    NSURL *result = comps.URL;
    return result ?: url;
}

%hook IGBrowserNavigationController
- (void)viewWillAppear:(BOOL)animated {
    id session = ((id(*)(id,SEL))objc_msgSend)(self, @selector(browserSession));
    Ivar urlIvar = session ? class_getInstanceVariable([session class], "_urlRequest") : nil;
    NSURLRequest *req = urlIvar ? object_getIvar(session, urlIvar) : nil;
    NSURL *url = req.URL;

    if (url && [SCIUtils getBoolPref:@"open_links_external"]) {
        NSURL *cleaned = sciCleanBrowserURL(url);
        [[UIApplication sharedApplication] openURL:cleaned options:@{} completionHandler:nil];
        [(UIViewController *)self dismissViewControllerAnimated:NO completion:nil];
        return;
    }

    // For in-app browser: replace the URL request with the cleaned version
    if (url && [SCIUtils getBoolPref:@"strip_browser_tracking"]) {
        NSURL *cleaned = sciCleanBrowserURL(url);
        if (![cleaned isEqual:url]) {
            NSURLRequest *cleanReq = [NSURLRequest requestWithURL:cleaned];
            object_setIvar(session, urlIvar, cleanReq);
        }
    }

    %orig;
}
%end
