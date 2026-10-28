#import "IXBackend.h"
#import "../Localization/SCILocalization.h"
#import "../Proxy/IXProxyManager.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const NSInteger kBannerTag = 22024;
static const NSInteger kTrayButtonTag = 22025;

@interface IXStickerMover : NSObject
@property (nonatomic, assign) CGPoint start;
@property (nonatomic, assign) CGFloat scale;
@end

@implementation IXStickerMover
- (instancetype)init {
    self = [super init];
    if (self) _scale = 1;
    return self;
}
- (void)pan:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view.superview) return;
    CGPoint translation = [gesture translationInView:view.superview];
    if (gesture.state == UIGestureRecognizerStateBegan) _start = view.center;
    view.center = CGPointMake(_start.x + translation.x, _start.y + translation.y);
}
- (void)pinch:(UIPinchGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (gesture.state == UIGestureRecognizerStateBegan) _scale = view.transform.a ?: 1;
    CGFloat next = MAX(0.3, MIN(_scale * gesture.scale, 6));
    view.transform = CGAffineTransformMakeScale(next, next);
}
@end

static UIViewController *IXTopPresenter(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}

static void IXRefreshBanner(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    if (!window) return;
    NSDictionary *ann = IXBackendAnnouncements().firstObject;
    UIView *existing = [window viewWithTag:kBannerTag];
    if (![ann isKindOfClass:[NSDictionary class]]) {
        [existing removeFromSuperview];
        return;
    }
    if (!existing) {
        existing = [[UIView alloc] initWithFrame:CGRectZero];
        existing.tag = kBannerTag;
        existing.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:0.96];
        existing.layer.cornerRadius = 14;
        [window addSubview:existing];
    }
    CGFloat top = 52;
    if (@available(iOS 11.0, *)) top = MAX(window.safeAreaInsets.top, 20) + 8;
    CGFloat width = MAX(window.bounds.size.width - 24, 120);
    NSString *title = [ann[@"title"] isKindOfClass:[NSString class]] ? ann[@"title"] : @"";
    NSString *body = [ann[@"body"] isKindOfClass:[NSString class]] ? ann[@"body"] : @"";
    NSDictionary *button = [ann[@"button"] isKindOfClass:[NSDictionary class]] ? ann[@"button"] : nil;
    NSString *label = [button[@"label"] isKindOfClass:[NSString class]] ? button[@"label"] : @"";
    CGFloat height = 86 + (label.length ? 36 : 0) + MIN(body.length, 180) / 3;
    existing.frame = CGRectMake(12, top, width, height);
    for (UIView *sub in existing.subviews) [sub removeFromSuperview];
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, width - 58, 22)];
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [existing addSubview:titleLabel];
    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 34, width - 28, height - (label.length ? 78 : 46))];
    bodyLabel.text = body;
    bodyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];
    bodyLabel.font = [UIFont systemFontOfSize:13];
    bodyLabel.numberOfLines = 4;
    [existing addSubview:bodyLabel];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(width - 40, 6, 32, 32);
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightMedium];
    NSString *annID = nil;
    id rawID = ann[@"id"];
    if ([rawID isKindOfClass:[NSNumber class]]) annID = [rawID stringValue];
    else if ([rawID isKindOfClass:[NSString class]]) annID = rawID;
    objc_setAssociatedObject(close, "ix_ann_id", annID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [close addTarget:NSClassFromString(@"IXLiveActions") action:@selector(dismiss:) forControlEvents:UIControlEventTouchUpInside];
    [existing addSubview:close];
    if (label.length) {
        UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
        action.frame = CGRectMake(14, height - 40, width - 28, 30);
        [action setTitle:label forState:UIControlStateNormal];
        [action setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        action.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        objc_setAssociatedObject(action, "ix_ann", ann, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [action addTarget:NSClassFromString(@"IXLiveActions") action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [existing addSubview:action];
    }
    [window bringSubviewToFront:existing];
    if (annID.length) IXBackendNoteAnnouncementShown(annID);
}

@interface IXLiveActions : NSObject
@end

@implementation IXLiveActions
+ (void)dismiss:(UIButton *)sender {
    NSString *ident = objc_getAssociatedObject(sender, "ix_ann_id");
    if ([ident isKindOfClass:[NSString class]] && ident.length) IXBackendDismissAnnouncementID(ident);
    else IXBackendDismissAnnouncement(sender.tag);
}
+ (void)tap:(UIButton *)sender {
    NSDictionary *ann = objc_getAssociatedObject(sender, "ix_ann");
    NSDictionary *button = [ann[@"button"] isKindOfClass:[NSDictionary class]] ? ann[@"button"] : nil;
    NSString *action = [button[@"action"] isKindOfClass:[NSString class]] ? button[@"action"] : @"";
    NSString *urlText = [button[@"url"] isKindOfClass:[NSString class]] ? button[@"url"] : @"";
    if ([action isEqualToString:@"open_vpn"]) {
        [IXProxyManager.shared setEnabled:YES completion:nil];
    } else if ([action isEqualToString:@"open_url"] && urlText.length) {
        NSURL *url = [NSURL URLWithString:urlText];
        if (url && ([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }
    }
    IXBackendDismissAnnouncement([ann[@"id"] integerValue]);
}
+ (void)refresh { IXRefreshBanner(); }
@end

static UIView *IXFindHost(UIView *root) {
    if (!root) return nil;
    NSString *name = NSStringFromClass(root.class);
    if (([name containsString:@"Sticker"] && [name containsString:@"Container"]) || [name containsString:@"MediaComposition"]) return root;
    UIView *best = nil;
    CGFloat area = 0;
    for (UIView *sub in root.subviews) {
        UIView *found = IXFindHost(sub);
        if (!found) continue;
        CGFloat next = found.bounds.size.width * found.bounds.size.height;
        if (next >= area) {
            area = next;
            best = found;
        }
    }
    return best;
}

static UIViewController *IXFindEditor(UIViewController *start) {
    __block UIViewController *found = nil;
    void (^walk)(UIViewController *) = ^(UIViewController *vc) {
        if (!vc || found) return;
        NSString *name = NSStringFromClass(vc.class);
        if ([name containsString:@"Story"] && [name containsString:@"Editing"]) found = vc;
    };
    UIViewController *cursor = start;
    while (cursor) {
        walk(cursor);
        for (UIViewController *child in cursor.childViewControllers) walk(child);
        cursor = cursor.presentingViewController;
    }
    return found;
}

static void IXPlaceSticker(UIImage *image, UIViewController *tray) {
    if (!image) return;
    UIViewController *editor = IXFindEditor(tray);
    UIImageView *sticker = [[UIImageView alloc] initWithImage:image];
    sticker.frame = CGRectMake(0, 0, 150, 150);
    sticker.contentMode = UIViewContentModeScaleAspectFit;
    if (image.images.count > 1) {
        sticker.animationImages = image.images;
        sticker.animationDuration = image.duration > 0 ? image.duration : image.images.count * 0.08;
        [sticker startAnimating];
    }
    sticker.userInteractionEnabled = YES;
    IXStickerMover *mover = [IXStickerMover new];
    objc_setAssociatedObject(sticker, "ix_mover", mover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:mover action:@selector(pan:)];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:mover action:@selector(pinch:)];
    [sticker addGestureRecognizer:pan];
    [sticker addGestureRecognizer:pinch];
    SEL addSel = NSSelectorFromString(@"addStickerView:");
    if (editor && [editor respondsToSelector:addSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(editor, addSel, sticker);
        return;
    }
    UIView *host = IXFindHost(editor.view ?: tray.presentingViewController.view);
    if (!host) host = tray.presentingViewController.view;
    if (!host) return;
    sticker.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    [host addSubview:sticker];
}

@interface IXStickerSheet : UIViewController
@property (nonatomic, weak) UIViewController *tray;
@end

@implementation IXStickerSheet
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scroll];
    NSDictionary *catalog = IXBackendStickerCatalog();
    NSString *category = [catalog[@"category"] isKindOfClass:[NSString class]] ? catalog[@"category"] : @"Instagram X";
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 18, self.view.bounds.size.width - 32, 28)];
    title.text = category;
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [scroll addSubview:title];
    CGFloat y = 58;
    NSArray *packs = [catalog[@"packs"] isKindOfClass:[NSArray class]] ? catalog[@"packs"] : @[];
    for (NSDictionary *pack in packs) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(16, y, self.view.bounds.size.width - 32, 22)];
        name.text = [pack[@"name"] isKindOfClass:[NSString class]] ? pack[@"name"] : category;
        name.textColor = [UIColor colorWithWhite:1 alpha:0.8];
        name.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [scroll addSubview:name];
        y += 28;
        CGFloat x = 16;
        for (NSDictionary *sticker in pack[@"stickers"]) {
            NSString *path = [sticker[@"path"] isKindOfClass:[NSString class]] ? sticker[@"path"] : @"";
            NSData *bytes = [NSData dataWithContentsOfFile:path];
            UIImage *image = [UIImage imageWithData:bytes];
            if (!image) continue;
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.frame = CGRectMake(x, y, 84, 84);
            [button setImage:image forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            objc_setAssociatedObject(button, "ix_image", image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [button addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
            [scroll addSubview:button];
            x += 96;
            if (x > self.view.bounds.size.width - 90) {
                x = 16;
                y += 96;
            }
        }
        y += 110;
    }
    if (packs.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, self.view.bounds.size.width - 32, 40)];
        empty.text = @"Instagram X";
        empty.textColor = UIColor.whiteColor;
        [scroll addSubview:empty];
    }
    scroll.contentSize = CGSizeMake(self.view.bounds.size.width, y + 40);
}
- (void)choose:(UIButton *)sender {
    UIImage *image = objc_getAssociatedObject(sender, "ix_image");
    UIViewController *tray = self.tray;
    [self dismissViewControllerAnimated:YES completion:^{
        IXPlaceSticker(image, tray);
    }];
}
@end

static void IXInstallTrayButton(UIViewController *tray) {
    if (!tray.view) return;
    UIButton *button = (UIButton *)[tray.view viewWithTag:kTrayButtonTag];
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = kTrayButtonTag;
        [button setTitle:@"Wexpid" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        button.layer.cornerRadius = 16;
        button.accessibilityLabel = @"Wexpid";
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(button, "ix_tray", tray, OBJC_ASSOCIATION_ASSIGN);
        [button addTarget:NSClassFromString(@"IXLiveActions") action:@selector(showStickers:) forControlEvents:UIControlEventTouchUpInside];
        [tray.view addSubview:button];
    }
    button.frame = CGRectMake(12, 8, 92, 32);
    [tray.view bringSubviewToFront:button];
}

static NSString *IXPropString(id obj, NSArray<NSString *> *names) {
    if (!obj) return nil;
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(object_getClass(obj), sel);
        if (!method) continue;
        const char *types = method_getTypeEncoding(method);
        if (!types || types[0] != '@') continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] && [(NSString *)value length] <= 80) return value;
        if ([value isKindOfClass:[NSNumber class]] && [(NSNumber *)value integerValue] != 0) return [(NSNumber *)value stringValue];
    }
    return nil;
}

static UIImage *IXPropImage(id obj) {
    for (NSString *name in @[@"thumbnail", @"previewImage", @"icon", @"stickerImage"]) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(object_getClass(obj), sel);
        if (!method) continue;
        const char *types = method_getTypeEncoding(method);
        if (!types || types[0] != '@') continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        if ([value isKindOfClass:[UIImage class]]) return value;
    }
    return nil;
}

static NSString *IXStickerStableID(id obj) {
    if (!obj || [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) return nil;
    NSString *kind = IXPropString(obj, @[@"stickerType", @"modelType"]);
    NSString *name = IXPropString(obj, @[@"name", @"title", @"accessibilityLabel", @"displayName", @"stickerName"]);
    NSString *explicit = IXPropString(obj, @[@"stickerId", @"stickerID", @"identifier", @"diffIdentifier", @"pk"]);
    NSString *cls = NSStringFromClass(object_getClass(obj));
    NSString *sid = nil;
    if (kind.length && name.length) sid = [NSString stringWithFormat:@"%@/%@", kind, name];
    else if (kind.length) sid = kind;
    else if (explicit.length) sid = explicit;
    else if (name.length) sid = [NSString stringWithFormat:@"%@/%@", cls, name];
    else sid = cls;
    if (sid.length > 96) sid = [sid substringToIndex:96];
    return sid;
}

static NSString *IXThumb64(UIImage *image) {
    if (![image isKindOfClass:[UIImage class]]) return nil;
    CGSize size = image.size;
    if (size.width < 1 || size.height < 1) return nil;
    CGFloat scale = 48.0 / MAX(size.width, size.height);
    CGSize target = CGSizeMake(MAX(1, size.width * scale), MAX(1, size.height * scale));
    UIGraphicsBeginImageContextWithOptions(target, NO, 1);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *small = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    NSData *jpeg = UIImageJPEGRepresentation(small, 0.4);
    if (jpeg.length == 0 || jpeg.length > 12000) return nil;
    return [jpeg base64EncodedStringWithOptions:0];
}

static NSString *IXReportSignature;
static void IXCollectStickers(id node, NSMutableArray *report, NSMutableSet *seen, int depth) {
    if (!node || depth > 3) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)node) IXCollectStickers(item, report, seen, depth + 1);
        return;
    }
    NSString *sid = IXStickerStableID(node);
    if (!sid || [seen containsObject:sid] || report.count >= 80) return;
    [seen addObject:sid];
    NSMutableDictionary *row = [@{
        @"id": sid,
        @"type": NSStringFromClass(object_getClass(node)) ?: @"",
        @"name": IXPropString(node, @[@"name", @"title", @"accessibilityLabel", @"displayName", @"stickerName"]) ?: @""
    } mutableCopy];
    NSString *thumb = IXThumb64(IXPropImage(node));
    if (thumb.length) row[@"thumbnail"] = thumb;
    [report addObject:row];
}

static void IXReportTray(id node) {
    NSMutableArray *report = [NSMutableArray array];
    IXCollectStickers(node, report, [NSMutableSet set], 0);
    if (report.count == 0) return;
    NSMutableString *sig = [NSMutableString string];
    for (NSDictionary *row in report) {
        [sig appendString:row[@"id"] ?: @""];
        [sig appendString:@","];
    }
    if ([sig isEqualToString:IXReportSignature]) return;
    IXReportSignature = [sig copy];
    IXBackendReportStickerDefaults(report);
}

static id IXFilterNode(id node, NSSet *hidden, int depth) {
    if (!node || depth > 3) return node;
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableArray *kept = [NSMutableArray array];
        for (id item in (NSArray *)node) {
            id next = IXFilterNode(item, hidden, depth + 1);
            if (next) [kept addObject:next];
        }
        NSArray *order = IXBackendStickerOrder();
        if (order.count == 0) return kept;
        return [kept sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            NSString *ia = IXStickerStableID(a) ?: @"";
            NSString *ib = IXStickerStableID(b) ?: @"";
            NSUInteger pa = [order indexOfObject:ia];
            NSUInteger pb = [order indexOfObject:ib];
            BOOL aKnown = pa != NSNotFound;
            BOOL bKnown = pb != NSNotFound;
            if (aKnown && bKnown) return pa < pb ? NSOrderedAscending : (pa > pb ? NSOrderedDescending : NSOrderedSame);
            if (aKnown != bKnown) return aKnown ? NSOrderedAscending : NSOrderedDescending;
            NSUInteger oa = [((NSArray *)node) indexOfObjectIdenticalTo:a];
            NSUInteger ob = [((NSArray *)node) indexOfObjectIdenticalTo:b];
            if (oa < ob) return NSOrderedAscending;
            if (oa > ob) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    NSString *sid = IXStickerStableID(node);
    if (sid && [hidden containsObject:sid]) return nil;
    return node;
}

static id IXPrepareTrayList(id orig) {
    if (![orig isKindOfClass:[NSArray class]]) return orig;
    IXReportTray(orig);
    NSSet *hidden = IXBackendHiddenStickerIDs();
    NSArray *order = IXBackendStickerOrder();
    if (hidden.count == 0 && order.count == 0) return orig;
    return IXFilterNode(orig, hidden, 0);
}

@implementation IXLiveActions (Stickers)
+ (void)showStickers:(UIButton *)sender {
    UIViewController *tray = objc_getAssociatedObject(sender, "ix_tray");
    IXStickerSheet *sheet = [IXStickerSheet new];
    sheet.tray = tray;
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    [tray presentViewController:sheet animated:YES completion:nil];
}
@end

%group IXStickerTray
%hook IGStoryStickerTrayViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    IXInstallTrayButton(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    IXInstallTrayButton(self);
}
%end
%end

%group IXStickerSource
%hook IGStoryStickerDataSourceImpl
- (id)items {
    return IXPrepareTrayList(%orig);
}
- (id)sections {
    return IXPrepareTrayList(%orig);
}
%end
%end

%ctor {
    [[NSNotificationCenter defaultCenter] addObserverForName:IXBackendConfigDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        IXRefreshBanner();
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IXRefreshBanner();
    });
    if (objc_getClass("IGStoryStickerTrayViewController")) %init(IXStickerTray);
    if (objc_getClass("IGStoryStickerDataSourceImpl")) %init(IXStickerSource);
}
