#import "SCILinksSheet.h"
#import "../Localization/SCILocalization.h"
#import "../Utils.h"

@implementation SCILinksSheet

+ (void)presentFrom:(UIViewController *)source {
    SCILinksSheet *vc = [[SCILinksSheet alloc] init];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = vc.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[[UISheetPresentationControllerDetent mediumDetent]];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 28;
    }
    [source presentViewController:vc animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.11 alpha:1.0]
            : [UIColor systemBackgroundColor];
    }];

    UIImageView *logo = [[UIImageView alloc] initWithImage:
        [[UIImage imageNamed:@"ix-mark"
                   inBundle:SCILocalizationBundle()
      compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    logo.tintColor = [UIColor labelColor];
    logo.contentMode = UIViewContentModeScaleAspectFill;
    logo.clipsToBounds = YES;
    logo.layer.cornerRadius = 18;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    [logo.widthAnchor constraintEqualToConstant:78].active = YES;
    [logo.heightAnchor constraintEqualToConstant:78].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Instagram X";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *version = [[UILabel alloc] init];
    version.text = SCIVersionString;
    version.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    version.textColor = [UIColor secondaryLabelColor];
    version.textAlignment = NSTextAlignmentCenter;

    UILabel *credit = [[UILabel alloc] init];
    credit.text = SCILocalized(@"Developed by Wexpid");
    credit.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    credit.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, title, version, credit]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    [stack setCustomSpacing:2 afterView:title];
    [stack setCustomSpacing:22 afterView:version];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-20],
        [credit.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (UIButton *)makeButtonWithTitle:(NSString *)title
                         sfSymbol:(NSString *)symbol
                             tint:(UIColor *)tint
                       background:(UIColor *)bg {
    UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
    cfg.title = title;
    cfg.image = [UIImage systemImageNamed:symbol];
    cfg.imagePadding = 10;
    cfg.imagePlacement = NSDirectionalRectEdgeLeading;
    cfg.baseForegroundColor = tint;
    cfg.baseBackgroundColor = bg;
    cfg.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);

    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/kamyarjobsss/SCInsta"];
    [self dismissViewControllerAnimated:YES completion:^{
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }];
}

- (void)openUpstream {
    NSURL *url = [NSURL URLWithString:@"https://github.com/faroukbmiled/RyukGram/tree/v1.3.2"];
    [self dismissViewControllerAnimated:YES completion:^{
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }];
}

@end
