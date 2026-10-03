#import <UIKit/UIKit.h>
#import "../Localization/SCILocalization.h"

@interface IXLicensesViewController : UITableViewController
@end

@implementation IXLicensesViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL fa = [SCIResolvedLanguageCode() hasPrefix:@"fa"];
    self.title = fa ? @"مجوزهای متن‌باز" : @"Open-source licenses";
    if (fa) {
        self.view.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.tableView.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = [UIColor secondaryLabelColor];
    BOOL fa = [SCIResolvedLanguageCode() hasPrefix:@"fa"];
    label.textAlignment = fa ? NSTextAlignmentRight : NSTextAlignmentLeft;
    label.text = fa
        ? @"اینستاگرام ایکس تحت GPL-3.0 منتشر شده است. این ساخت بر پایهٔ کد پروژه‌های متن‌باز زیر است و فایل LICENSE در مخزن منبع حفظ شده است.\n\n• RyukGram نسخهٔ 1.3.2، GPL-3.0\n• SCInsta، GPL-3.0\n• Xray-core، MPL-2.0\n• fishhook\n• FFmpegKit، در صورت بسته‌شدن در این ساخت"
        : @"Instagram X is released under GPL-3.0. This build is based on the open-source projects below, and the LICENSE file stays in the source tree.\n\n• RyukGram v1.3.2, GPL-3.0\n• SCInsta, GPL-3.0\n• Xray-core, MPL-2.0\n• fishhook\n• FFmpegKit, when this build includes it";
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
    ]];
    return cell;
}

@end
