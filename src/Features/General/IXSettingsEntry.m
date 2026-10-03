#import "IXSettingsEntry.h"
#import "../../Brand/IXBrand.h"
#import "../../Proxy/IXProxyManager.h"
#import "../../Utils.h"
#import <objc/runtime.h>

static char kIXAnchorKey;
static char kIXBaseInsetKey;

@interface IXSettingsAnchor : NSObject
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic, strong) UIControl *row;
@property (nonatomic) BOOL placeAbove;
@end

@implementation IXSettingsAnchor
@end

@interface IXHoloRow : UIControl
@property (nonatomic) UIImageView *iconView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *detailLabel;
@property (nonatomic) CAGradientLayer *glow;
@end

@implementation IXHoloRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.94];
    self.layer.cornerRadius = 14;
    self.layer.masksToBounds = NO;

    self.glow = [CAGradientLayer layer];
    self.glow.colors = @[
        (id)[UIColor colorWithRed:0.25 green:0.85 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.55 green:0.35 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0.35 blue:0.75 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0.85 blue:0.35 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.25 green:0.85 blue:1 alpha:1].CGColor
    ];
    self.glow.startPoint = CGPointMake(0, 0.5);
    self.glow.endPoint = CGPointMake(1, 0.5);
    self.glow.cornerRadius = 14;
    [self.layer addSublayer:self.glow];

    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"locations"];
    slide.fromValue = @[@(-0.4), @(-0.2), @(0.0), @(0.2), @(0.4)];
    slide.toValue = @[@(0.6), @(0.8), @(1.0), @(1.2), @(1.4)];
    slide.duration = 2.8;
    slide.repeatCount = HUGE_VALF;
    [self.glow addAnimation:slide forKey:@"ix-holo"];

    self.iconView = [[UIImageView alloc] initWithImage:[IXBrand iconImage]];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.layer.cornerRadius = 8;
    self.iconView.clipsToBounds = YES;
    self.iconView.contentMode = UIViewContentModeScaleAspectFill;

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = @"Instagram X settings";
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];

    self.detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.detailLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.8];

    [self addSubview:self.iconView];
    [self addSubview:self.titleLabel];
    [self addSubview:self.detailLabel];
    [self addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:32],
        [self.iconView.heightAnchor constraintEqualToConstant:32],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:10],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:1],
        [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    self.accessibilityLabel = @"Instagram X settings";
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glow.frame = self.bounds;
    CAShapeLayer *mask = [CAShapeLayer layer];
    CGRect inset = CGRectInset(self.bounds, 1.5, 1.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:14];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:inset cornerRadius:12.5]];
    mask.path = path.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    self.glow.mask = mask;
    self.detailLabel.text = [IXProxyManager statusSubtitle];
}

- (void)open {
    UIWindow *window = self.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) window = candidate;
            }
        }
    }
    if (window) [SCIUtils showSettingsVC:window];
}

@end

@implementation IXSettingsEntry

+ (BOOL)textIsAccountsCenter:(NSString *)text {
    if (text.length < 8 || text.length > 80) return NO;
    NSString *folded = text.lowercaseString;
    if ([folded containsString:@"accounts center"] || [folded containsString:@"accounts centre"]) return YES;
    if ([text containsString:@"مرکز حساب"]) return YES;
    if ([folded containsString:@"centro de cuentas"] || [folded containsString:@"centre des comptes"] || [folded containsString:@"accountcenter"]) return YES;
    return NO;
}

+ (BOOL)view:(UIView *)view containsAccountsCenter:(BOOL *)matched {
    if (matched) *matched = NO;
    if (!view) return NO;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if ([self textIsAccountsCenter:label.text] || [self textIsAccountsCenter:label.attributedText.string]) {
                if (matched) *matched = YES;
                return YES;
            }
        }
        for (UIView *sub in view.subviews) {
            if ([self view:sub containsAccountsCenter:matched]) return YES;
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return NO;
}

+ (UIView *)rowContainerFor:(UIView *)view {
    UIView *current = view;
    UIView *fallback = view.superview;
    for (int i = 0; current && i < 12; i++) {
        if ([current isKindOfClass:[UITableViewCell class]] || [current isKindOfClass:[UICollectionViewCell class]]) return current;
        current = current.superview;
    }
    return fallback;
}

+ (UIScrollView *)scrollViewFor:(UIView *)view {
    UIScrollView *table = nil;
    UIView *current = view;
    for (int i = 0; current && i < 16; i++) {
        if ([current isKindOfClass:[UITableView class]] || [current isKindOfClass:[UICollectionView class]]) return (UIScrollView *)current;
        if (!table && [current isKindOfClass:[UIScrollView class]]) table = (UIScrollView *)current;
        current = current.superview;
    }
    return table;
}

+ (void)attachToScroll:(UIScrollView *)scroll anchor:(UIView *)anchor placeAbove:(BOOL)placeAbove {
    if (!scroll || !anchor || scroll.bounds.size.width < 200 || scroll.bounds.size.height < 160) return;
    if ([NSStringFromClass(anchor.class) containsString:@"IXHolo"]) return;
    IXSettingsAnchor *existing = objc_getAssociatedObject(scroll, &kIXAnchorKey);
    if (!existing) {
        existing = [IXSettingsAnchor new];
        existing.row = [[IXHoloRow alloc] initWithFrame:CGRectMake(0, 0, 10, 58)];
        objc_setAssociatedObject(scroll, &kIXAnchorKey, existing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scroll addSubview:existing.row];
        NSLog(@"[InstagramX] settings row inserted in %@", NSStringFromClass(scroll.class));
    }
    existing.anchor = anchor;
    existing.placeAbove = placeAbove;
    [self relayout:scroll];
}

+ (void)noteLabel:(UILabel *)label {
    if (![self textIsAccountsCenter:label.text] && ![self textIsAccountsCenter:label.attributedText.string]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIView *row = [self rowContainerFor:label];
            UIScrollView *scroll = [self scrollViewFor:row];
            [self attachToScroll:scroll anchor:row placeAbove:NO];
        } @catch (NSException *exception) {
            NSLog(@"[InstagramX] settings row skipped: %@", exception.reason);
        }
    });
}

+ (BOOL)controllerLooksLikeSettings:(UIViewController *)controller {
    // The profile header button is the entry point. This row is only placed
    // under Accounts Center, never as a floating overlay on other screens.
    if (!controller) return NO;
    NSString *cls = NSStringFromClass(controller.class);
    if ([cls containsString:@"SCISettings"] || [cls containsString:@"IXProxy"] || [cls containsString:@"IXLocation"]) return NO;
    NSString *title = controller.title.lowercaseString ?: @"";
    return [title containsString:@"setting"] || [title containsString:@"تنظیمات"];
}

+ (void)noteSettingsController:(UIViewController *)controller {
    if (![self controllerLooksLikeSettings:controller]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIScrollView *scroll = [self firstScrollIn:controller.view];
            if (!scroll) return;
            if (objc_getAssociatedObject(scroll, &kIXAnchorKey)) {
                [self relayout:scroll];
                return;
            }
            UIView *anchor = nil;
            BOOL above = NO;
            for (UIView *cell in [self candidateRows:scroll]) {
                BOOL matched = NO;
                if ([self view:cell containsAccountsCenter:&matched] && matched) {
                    anchor = cell;
                    above = NO;
                    break;
                }
            }
            if (!anchor) return;
            [self attachToScroll:scroll anchor:anchor placeAbove:above];
        } @catch (NSException *exception) {
            NSLog(@"[InstagramX] settings scan skipped: %@", exception.reason);
        }
    });
}

+ (UIScrollView *)firstScrollIn:(UIView *)view {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) return (UIScrollView *)view;
    for (UIView *sub in view.subviews) {
        UIScrollView *found = [self firstScrollIn:sub];
        if (found) return found;
    }
    return nil;
}

+ (NSArray<UIView *> *)candidateRows:(UIScrollView *)scroll {
    if ([scroll isKindOfClass:[UITableView class]]) return ((UITableView *)scroll).visibleCells ?: @[];
    if ([scroll isKindOfClass:[UICollectionView class]]) return ((UICollectionView *)scroll).visibleCells ?: @[];
    return scroll.subviews ?: @[];
}

+ (void)relayoutIfNeeded:(UIScrollView *)scroll {
    if (!scroll || !objc_getAssociatedObject(scroll, &kIXAnchorKey)) return;
    static char kIXLayingOut;
    if (objc_getAssociatedObject(scroll, &kIXLayingOut)) return;
    objc_setAssociatedObject(scroll, &kIXLayingOut, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self relayout:scroll];
    objc_setAssociatedObject(scroll, &kIXLayingOut, nil, OBJC_ASSOCIATION_ASSIGN);
}

+ (void)relayout:(UIScrollView *)scroll {
    IXSettingsAnchor *anchor = objc_getAssociatedObject(scroll, &kIXAnchorKey);
    if (!anchor.row) return;
    BOOL stillThere = NO;
    if (anchor.anchor.window) {
        [self view:anchor.anchor containsAccountsCenter:&stillThere];
    }
    if (!anchor.placeAbove && !stillThere) {
        for (UIView *cell in [self candidateRows:scroll]) {
            BOOL matched = NO;
            if ([self view:cell containsAccountsCenter:&matched] && matched) {
                anchor.anchor = cell;
                stillThere = YES;
                break;
            }
        }
    }
    UIView *rowView = anchor.anchor;
    if (!rowView) {
        anchor.row.hidden = YES;
        return;
    }
    anchor.row.hidden = NO;
    CGRect frame = [rowView convertRect:rowView.bounds toView:scroll];
    CGFloat height = 62.0;
    CGFloat y = anchor.placeAbove ? CGRectGetMinY(frame) : CGRectGetMaxY(frame) + 6.0;
    CGFloat x = CGRectGetMinX(frame) + 8.0;
    CGFloat width = MAX(120.0, CGRectGetWidth(frame) - 16.0);
    anchor.row.frame = CGRectMake(x, y, width, height);
    [scroll bringSubviewToFront:anchor.row];

    for (UIView *cell in [self candidateRows:scroll]) {
        if (cell == anchor.row) continue;
        CGRect cellFrame = [cell convertRect:cell.bounds toView:scroll];
        BOOL shift = anchor.placeAbove ? CGRectGetMinY(cellFrame) >= y - 1 : CGRectGetMinY(cellFrame) >= CGRectGetMaxY(frame) - 1;
        CGAffineTransform next = shift ? CGAffineTransformMakeTranslation(0, height + 8) : CGAffineTransformIdentity;
        if (!CGAffineTransformEqualToTransform(cell.transform, next)) cell.transform = next;
    }

    NSValue *stored = objc_getAssociatedObject(scroll, &kIXBaseInsetKey);
    UIEdgeInsets base = stored ? stored.UIEdgeInsetsValue : scroll.contentInset;
    if (!stored) {
        objc_setAssociatedObject(scroll, &kIXBaseInsetKey, [NSValue valueWithUIEdgeInsets:base], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIEdgeInsets inset = base;
    inset.bottom += height + 12;
    if (!UIEdgeInsetsEqualToEdgeInsets(scroll.contentInset, inset)) {
        scroll.contentInset = inset;
    }
}

@end
