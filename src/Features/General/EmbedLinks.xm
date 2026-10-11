// Rewrite Instagram share links — replace domain + optionally strip tracking params.
// Waits for IG's async clipboard write via changeCount, then rewrites once.

#import "../../Utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSString *sciRewriteIGURL(NSString *url) {
    if (!url.length) return url;

    // Domain replacement
    if ([SCIUtils getBoolPref:@"embed_links"]) {
        NSString *domain = [SCIUtils getStringPref:@"embed_link_domain"];
        if (!domain.length) domain = @"kkinstagram.com";
        if (![url containsString:domain]) {
            NSArray *igDomains = @[@"www.instagram.com", @"instagram.com", @"www.instagr.am", @"instagr.am"];
            for (NSString *d in igDomains) {
                NSRange r = [url rangeOfString:d];
                if (r.location != NSNotFound) {
                    NSString *target = [d hasPrefix:@"www."]
                        ? [NSString stringWithFormat:@"www.%@", domain] : domain;
                    url = [url stringByReplacingCharactersInRange:r withString:target];
                    break;
                }
            }
        }
    }

    // Strip tracking params
    if ([SCIUtils getBoolPref:@"strip_tracking_params"]) {
        NSURLComponents *comps = [NSURLComponents componentsWithString:url];
        if (comps.queryItems.count) {
            NSArray *strip = @[@"igsh", @"ig_rid", @"utm_source", @"utm_medium", @"utm_campaign"];
            NSMutableArray *clean = [NSMutableArray array];
            for (NSURLQueryItem *q in comps.queryItems) {
                if (![strip containsObject:q.name]) [clean addObject:q];
            }
            comps.queryItems = clean.count ? clean : nil;
            NSString *result = comps.string;
            if (result) url = result;
        }
    }

    return url;
}

static BOOL sciShouldRewrite(void) {
    return [SCIUtils getBoolPref:@"embed_links"] || [SCIUtils getBoolPref:@"strip_tracking_params"];
}

// Rewrite clipboard once after IG writes
static void sciPollAndRewrite(NSInteger countBefore, int polls, double interval) {
    __block BOOL done = NO;
    for (int i = 0; i < polls; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((interval + i * interval) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (done) return;
            if ([UIPasteboard generalPasteboard].changeCount == countBefore) return;
            NSString *clip = [UIPasteboard generalPasteboard].string;
            if (!clip || ![clip containsString:@"instagram"]) return;
            NSString *rewritten = sciRewriteIGURL(clip);
            if (![rewritten isEqualToString:clip]) {
                [UIPasteboard generalPasteboard].string = rewritten;
                done = YES;
            } else {
                done = YES;
            }
        });
    }
}

// ============ Hooks ============

static void (*orig_copyLink)(id, SEL, id);
static void new_copyLink(id self, SEL _cmd, id vc) {
    if (!sciShouldRewrite()) { orig_copyLink(self, _cmd, vc); return; }
    NSInteger countBefore = [UIPasteboard generalPasteboard].changeCount;
    orig_copyLink(self, _cmd, vc);
    sciPollAndRewrite(countBefore, 30, 0.05);
}

static void (*orig_shareMore)(id, SEL, id);
static void new_shareMore(id self, SEL _cmd, id vc) {
    if (!sciShouldRewrite()) { orig_shareMore(self, _cmd, vc); return; }
    NSInteger countBefore = [UIPasteboard generalPasteboard].changeCount;
    orig_shareMore(self, _cmd, vc);
    sciPollAndRewrite(countBefore, 120, 0.1);
}

__attribute__((constructor)) static void _embedLinksInit(void) {
    Class cls = NSClassFromString(@"IGExternalShareOptionsViewController");
    if (!cls) return;
    SEL copy = NSSelectorFromString(@"_shareToClipboardFromVC:");
    if (class_getInstanceMethod(cls, copy))
        MSHookMessageEx(cls, copy, (IMP)new_copyLink, (IMP *)&orig_copyLink);
    SEL more = NSSelectorFromString(@"_shareToMoreFromVC:");
    if (class_getInstanceMethod(cls, more))
        MSHookMessageEx(cls, more, (IMP)new_shareMore, (IMP *)&orig_shareMore);
}
