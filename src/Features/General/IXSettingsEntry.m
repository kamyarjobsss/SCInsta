#import "IXSettingsEntry.h"
#import "../../Brand/IXBrand.h"
#import "../../Utils.h"
#import <objc/runtime.h>

// A normal row inside Instagram's settings list only.
// It is an arranged subview of that list's stack, a tableHeaderView of that
// list's table, or a content subview of that list's scroll view. It is never
// added to a window, and it is removed when the settings screen disappears.

static char kIXRowKey;
static NSString *const kIXRowID = @"ix-settings-row";
static CGFloat const kIXRowHeight = 52.0;

@interface IXSettingsRowOwner : NSObject
@property (nonatomic, weak) UIViewController *owner;
@property (nonatomic, weak) UIScrollView *list;
@property (nonatomic, strong) UIControl *row;
@property (nonatomic) UIEdgeInsets baseInset;
@property (nonatomic) BOOL adjustsInset;
@property (nonatomic) BOOL didShiftOffset;
@end

@implementation IXSettingsRowOwner
@end

@interface IXSettingsRow : UIControl
@property (nonatomic) UILabel *titleLabel;
@end

@implementation IXSettingsRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.accessibilityIdentifier = kIXRowID;
    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[IXBrand iconImage]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.layer.cornerRadius = 6;
    icon.clipsToBounds = YES;
    icon.contentMode = UIViewContentModeScaleAspectFill;

    BOOL persian = [[NSLocale preferredLanguages].firstObject hasPrefix:@"fa"];
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.text = persian ? @"اینستاگرام ایکس" : @"Instagram X";
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = [UIColor tertiaryLabelColor];

    [self addSubview:icon];
    [self addSubview:self.titleLabel];
    [self addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [self.heightAnchor constraintEqualToConstant:kIXRowHeight],
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:28],
        [icon.heightAnchor constraintEqualToConstant:28],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-8],
        [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ]];
    [self addTarget:self action:@selector(ix_open) forControlEvents:UIControlEventTouchUpInside];
    self.accessibilityLabel = self.titleLabel.text;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)ix_open {
    UIView *view = self;
    while (view && ![view isKindOfClass:[UIWindow class]]) view = view.superview;
    if ([view isKindOfClass:[UIWindow class]]) [SCIUtils showSettingsVC:(UIWindow *)view];
}

@end

@implementation IXSettingsEntry

+ (BOOL)text:(NSString *)text containsAny:(NSArray<NSString *> *)needles {
    if (text.length == 0) return NO;
    NSString *folded = text.lowercaseString;
    for (NSString *needle in needles) {
        if ([folded containsString:needle.lowercaseString] || [text containsString:needle]) return YES;
    }
    return NO;
}

+ (BOOL)textIsSettingsHome:(NSString *)text {
    return [self text:text containsAny:@[
        @"settings and activity",
        @"تنظیمات و فعالیت",
        @"accounts center",
        @"accounts centre",
        @"مرکز حساب",
        @"centro de cuentas",
        @"centre des comptes"
    ]];
}

+ (BOOL)view:(UIView *)view containsSettingsHome:(BOOL *)matched {
    if (matched) *matched = NO;
    if (!view || [view.accessibilityIdentifier isEqualToString:kIXRowID]) return NO;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if ([self textIsSettingsHome:label.text] || [self textIsSettingsHome:label.attributedText.string]) {
                if (matched) *matched = YES;
                return YES;
            }
        }
        for (UIView *sub in view.subviews) {
            if ([self view:sub containsSettingsHome:matched]) return YES;
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return NO;
}

+ (BOOL)view:(UIView *)view containsRow:(BOOL *)found {
    if (found) *found = NO;
    if (!view) return NO;
    if ([view.accessibilityIdentifier isEqualToString:kIXRowID]) {
        if (found) *found = YES;
        return YES;
    }
    for (UIView *sub in view.subviews) {
        if ([self view:sub containsRow:found]) return YES;
    }
    return NO;
}

+ (BOOL)controllerIsSettingsList:(UIViewController *)controller {
    if (!controller || !controller.isViewLoaded) return NO;
    NSString *cls = NSStringFromClass(controller.class);
    if ([cls containsString:@"SCISettings"] || [cls containsString:@"IXProxy"] || [cls containsString:@"IXLocation"]) return NO;
    NSString *title = controller.navigationItem.title ?: controller.title ?: @"";
    BOOL classMatch = [cls containsString:@"Settings2"] || [cls containsString:@"SettingScreen"] ||
                      [cls containsString:@"SettingsHosting"] || [cls containsString:@"IGSettings"];
    BOOL titleMatch = [self textIsSettingsHome:title] || [title.lowercaseString containsString:@"setting"] || [title containsString:@"تنظیمات"];
    BOOL homeLabel = NO;
    [self view:controller.view containsSettingsHome:&homeLabel];
    if (!(classMatch || titleMatch || homeLabel)) return NO;
    // Subpages are pushed. The accounts-center list is the root of that navigation.
    UINavigationController *nav = controller.navigationController;
    if (nav && nav.viewControllers.firstObject != controller && !homeLabel && ![self textIsSettingsHome:title]) return NO;
    return YES;
}

+ (UIView *)arrangedRowContainingHome:(UIStackView *)stack {
    for (UIView *row in stack.arrangedSubviews) {
        BOOL matched = NO;
        if ([self view:row containsSettingsHome:&matched] && matched) return row;
    }
    return nil;
}

+ (BOOL)scrollIsList:(UIScrollView *)scroll {
    if (!scroll || scroll.bounds.size.width < 200 || scroll.bounds.size.height < 160) return NO;
    if (scroll.bounds.size.height < 100 && scroll.contentSize.width > scroll.bounds.size.width * 1.5) return NO;
    return YES;
}

+ (void)findIn:(UIView *)view stack:(UIStackView *__strong *)stack anchor:(UIView *__strong *)anchor table:(UITableView *__strong *)table scroll:(UIScrollView *__strong *)scroll depth:(int)depth {
    if (!view || depth > 14) return;
    if ([view.accessibilityIdentifier isEqualToString:kIXRowID]) return;
    if ([view isKindOfClass:[UIStackView class]]) {
        UIStackView *candidate = (UIStackView *)view;
        if (candidate.axis == UILayoutConstraintAxisVertical && candidate.bounds.size.width > 180 && candidate.arrangedSubviews.count > 0) {
            UIView *row = [self arrangedRowContainingHome:candidate];
            if (row) {
                *stack = candidate;
                *anchor = row;
            } else if (!*anchor && (!*stack || candidate.arrangedSubviews.count > (*stack).arrangedSubviews.count)) {
                *stack = candidate;
            }
        }
    }
    if ([view isKindOfClass:[UITableView class]] && [self scrollIsList:(UIScrollView *)view]) {
        BOOL matched = NO;
        [self view:view containsSettingsHome:&matched];
        if (matched || !*table) *table = (UITableView *)view;
    } else if ([view isKindOfClass:[UIScrollView class]] && [self scrollIsList:(UIScrollView *)view]) {
        BOOL matched = NO;
        [self view:view containsSettingsHome:&matched];
        if (matched || !*scroll) *scroll = (UIScrollView *)view;
    }
    for (UIView *sub in view.subviews) {
        [self findIn:sub stack:stack anchor:anchor table:table scroll:scroll depth:depth + 1];
    }
}

+ (IXSettingsRow *)makeRow {
    return [[IXSettingsRow alloc] initWithFrame:CGRectMake(0, 0, 10, kIXRowHeight)];
}

+ (void)place:(IXSettingsRowOwner *)owner {
    UIControl *row = owner.row;
    if (!row) return;
    if (owner.adjustsInset && [owner.list isKindOfClass:[UIScrollView class]]) {
        UIScrollView *list = owner.list;
        UIEdgeInsets inset = owner.baseInset;
        inset.top += kIXRowHeight;
        if (!UIEdgeInsetsEqualToEdgeInsets(list.contentInset, inset)) list.contentInset = inset;
        row.translatesAutoresizingMaskIntoConstraints = YES;
        row.frame = CGRectMake(0, -inset.top, MAX(list.bounds.size.width, 1), kIXRowHeight);
        if (!owner.didShiftOffset && list.contentOffset.y <= -owner.baseInset.top + 1) {
            list.contentOffset = CGPointMake(list.contentOffset.x, -inset.top);
            owner.didShiftOffset = YES;
        }
        return;
    }
    if ([owner.list isKindOfClass:[UITableView class]]) {
        UITableView *table = (UITableView *)owner.list;
        CGFloat width = MAX(table.bounds.size.width, 1);
        if (table.tableHeaderView != row || fabs(row.bounds.size.width - width) > 1) {
            row.translatesAutoresizingMaskIntoConstraints = YES;
            row.frame = CGRectMake(0, 0, width, kIXRowHeight);
            table.tableHeaderView = row;
        }
    }
}

+ (void)removeSettingsRowForController:(UIViewController *)controller {
    IXSettingsRowOwner *owner = objc_getAssociatedObject(controller, &kIXRowKey);
    if (!owner) return;
    if (owner.adjustsInset && owner.list) owner.list.contentInset = owner.baseInset;
    if ([owner.list isKindOfClass:[UITableView class]] && ((UITableView *)owner.list).tableHeaderView == owner.row) {
        ((UITableView *)owner.list).tableHeaderView = nil;
    }
    [owner.row removeFromSuperview];
    objc_setAssociatedObject(controller, &kIXRowKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

+ (void)relayoutSettingsRowForController:(UIViewController *)controller {
    IXSettingsRowOwner *owner = objc_getAssociatedObject(controller, &kIXRowKey);
    if (!owner.row || !owner.list) return;
    if (owner.list.window == nil) return;
    [self place:owner];
}

+ (void)noteSettingsController:(UIViewController *)controller {
    if (![self controllerIsSettingsList:controller]) return;
    BOOL already = NO;
    [self view:controller.view containsRow:&already];
    IXSettingsRowOwner *existing = objc_getAssociatedObject(controller, &kIXRowKey);
    if (already && existing.row.superview) {
        [self relayoutSettingsRowForController:controller];
        return;
    }
    if (existing.row.superview) return;

    UIStackView *stack = nil;
    UIView *anchor = nil;
    UITableView *table = nil;
    UIScrollView *scroll = nil;
    [self findIn:controller.view stack:&stack anchor:&anchor table:&table scroll:&scroll depth:0];

    IXSettingsRow *row = [self makeRow];
    IXSettingsRowOwner *owner = [IXSettingsRowOwner new];
    owner.owner = controller;
    owner.row = row;

    if (stack && [stack isDescendantOfView:controller.view]) {
        NSUInteger index = 0;
        if (anchor) {
            NSUInteger found = [stack.arrangedSubviews indexOfObject:anchor];
            if (found != NSNotFound) index = found + 1;
        }
        if (index > stack.arrangedSubviews.count) index = stack.arrangedSubviews.count;
        [stack insertArrangedSubview:row atIndex:index];
        owner.list = [self enclosingScroll:stack];
        owner.adjustsInset = NO;
        NSLog(@"[InstagramX] settings row inserted in stack %@", NSStringFromClass(stack.class));
    } else if (table && [table isDescendantOfView:controller.view]) {
        owner.list = table;
        owner.adjustsInset = NO;
        [self place:owner];
        NSLog(@"[InstagramX] settings row inserted as table header");
    } else if (scroll && [scroll isDescendantOfView:controller.view] && ![scroll isKindOfClass:[UIWindow class]]) {
        owner.list = scroll;
        owner.baseInset = scroll.contentInset;
        owner.adjustsInset = YES;
        [scroll addSubview:row];
        [self place:owner];
        NSLog(@"[InstagramX] settings row inserted in %@", NSStringFromClass(scroll.class));
    } else {
        return;
    }
    if (row.superview == nil && !owner.adjustsInset && ![owner.list isKindOfClass:[UITableView class]]) return;
    if ([row.superview isKindOfClass:[UIWindow class]]) {
        [row removeFromSuperview];
        return;
    }
    objc_setAssociatedObject(controller, &kIXRowKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (UIScrollView *)enclosingScroll:(UIView *)view {
    UIView *current = view;
    for (int i = 0; current && i < 8; i++) {
        if ([current isKindOfClass:[UIScrollView class]]) return (UIScrollView *)current;
        current = current.superview;
    }
    return nil;
}

@end
