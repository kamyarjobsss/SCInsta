#import "IXProxyViewController.h"
#import "IXProxyManager.h"
#import "../Localization/SCILocalization.h"

typedef NS_ENUM(NSInteger, IXProxySection) {
    IXProxySectionStatus = 0,
    IXProxySectionTraffic,
    IXProxySectionControls,
    IXProxySectionProfiles,
    IXProxySectionAdd,
    IXProxySectionCount
};

static NSString *IXT(NSString *en, NSString *fa) {
    return [SCIResolvedLanguageCode() hasPrefix:@"fa"] ? fa : en;
}

static NSString *IXBytes(uint64_t n) {
    if (n < 1024) return [NSString stringWithFormat:@"%llu B", (unsigned long long)n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB", n / (1024.0 * 1024.0)];
}

@interface IXProxyLogController : UIViewController
@end

@implementation IXProxyLogController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IXT(@"Log", @"گزارش");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    text.text = IXProxyManager.shared.recentLog;
    text.textAlignment = [SCIResolvedLanguageCode() hasPrefix:@"fa"] ? NSTextAlignmentRight : NSTextAlignmentLeft;
    [self.view addSubview:text];
}
@end

@interface IXProxyViewController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation IXProxyViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IXT(@"VPN", @"فیلترشکن");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshStats) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshStats {
    if (IXProxyManager.shared.status != IXProxyStatusConnected) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:IXProxySectionTraffic] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return IXProxySectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == IXProxySectionProfiles) return MAX([IXProxyManager.shared profiles].count, 1);
    if (section == IXProxySectionControls) return 3;
    if (section == IXProxySectionAdd) return 2;
    if (section == IXProxySectionTraffic) return 4;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case IXProxySectionStatus: return IXT(@"Status", @"وضعیت");
        case IXProxySectionTraffic: return IXT(@"Traffic", @"ترافیک");
        case IXProxySectionControls: return IXT(@"Protection", @"محافظت");
        case IXProxySectionProfiles: return IXT(@"Servers", @"سرورها");
        default: return IXT(@"Add a server", @"افزودن سرور");
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != IXProxySectionAdd) return nil;
    return [NSString stringWithFormat:IXT(@"Engine: %@.\n\nConnected means a request through the tunnel reached generate_204. This is an in-app proxy, not the phone's VPN switch. UDP stays blocked so calls cannot skip the tunnel. A stack that never uses connect, connectx, or NSURLSession can still bypass it.", @"موتور: %@.\n\n«متصل» یعنی یک درخواست واقعی از تونل به generate_204 رسیده است. این فیلترشکن داخل خود اینستاگرام است و با VPN سیستم فرق دارد. UDP به‌طور پیش‌فرض بسته است تا تماس از تونل رد نشود."), IXProxyManager.shared.engineName];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    IXProxyManager *manager = IXProxyManager.shared;

    if (indexPath.section == IXProxySectionStatus) {
        NSString *status = manager.statusText;
        if ([SCIResolvedLanguageCode() hasPrefix:@"fa"]) {
            if (manager.status == IXProxyStatusConnected) status = @"متصل";
            else if (manager.status == IXProxyStatusConnecting) status = @"در حال اتصال";
            else if (manager.status == IXProxyStatusFailed) status = manager.lastError.length ? [NSString stringWithFormat:@"قطع · %@", manager.lastError] : @"قطع";
            else status = @"خاموش";
        }
        cell.textLabel.text = status;
        cell.detailTextLabel.text = manager.engineName;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIColor *color = [UIColor systemGrayColor];
        if (manager.status == IXProxyStatusConnected) color = [UIColor systemGreenColor];
        else if (manager.status == IXProxyStatusConnecting) color = [UIColor systemOrangeColor];
        else if (manager.status == IXProxyStatusFailed) color = [UIColor systemRedColor];
        cell.imageView.image = [self dot:color];
        return cell;
    }

    if (indexPath.section == IXProxySectionTraffic) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = IXT(@"Speed", @"سرعت");
            cell.detailTextLabel.text = [NSString stringWithFormat:IXT(@"Up %@/s · Down %@/s", @"ارسال %@/ث · دریافت %@/ث"), IXBytes((uint64_t)manager.speedUp), IXBytes((uint64_t)manager.speedDown)];
        } else if (indexPath.row == 1) {
            cell.textLabel.text = IXT(@"Total", @"حجم کل");
            cell.detailTextLabel.text = [NSString stringWithFormat:IXT(@"Up %@ · Down %@", @"ارسال %@ · دریافت %@"), IXBytes(manager.bytesUp), IXBytes(manager.bytesDown)];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = IXT(@"Test tunnel", @"آزمایش تونل");
            cell.detailTextLabel.text = manager.lastPingMs >= 0
                ? [NSString stringWithFormat:IXT(@"Last ping %ld ms", @"آخرین پینگ %ld میلی‌ثانیه"), (long)manager.lastPingMs]
                : IXT(@"Sends generate_204 through the tunnel.", @"یک درخواست generate_204 از داخل تونل می‌فرستد.");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = IXT(@"View log", @"دیدن گزارش");
            cell.detailTextLabel.text = IXT(@"Xray messages and the connectivity check.", @"پیام‌های Xray و نتیجهٔ آزمایش اتصال.");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }

    if (indexPath.section == IXProxySectionControls) {
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = IXT(@"Route Instagram through VLESS", @"اینستاگرام از VLESS عبور کند");
            cell.detailTextLabel.text = IXT(@"Turns the in-app proxy on for this process.", @"پروکسی داخل برنامه را برای همین اینستاگرام روشن می‌کند.");
            toggle.on = manager.isEnabled || manager.status == IXProxyStatusConnected || manager.status == IXProxyStatusConnecting;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = IXT(@"Kill switch", @"قطع اضطراری");
            cell.detailTextLabel.text = IXT(@"If the proxy is down, block Instagram instead of leaking the real IP.", @"اگر پروکسی قطع باشد، به‌جای لو رفتن IP واقعی، اینستاگرام بسته می‌شود.");
            toggle.on = manager.killSwitch;
        } else {
            cell.textLabel.text = IXT(@"Block UDP and calls", @"بستن UDP و تماس");
            cell.detailTextLabel.text = IXT(@"Stops call media from bypassing the tunnel. Turning this off can reveal your IP.", @"نمی‌گذارد صدای تماس از کنار تونل رد شود. خاموش کردنش می‌تواند IP را لو بدهد.");
            toggle.on = manager.blockUDP;
        }
        return cell;
    }

    if (indexPath.section == IXProxySectionProfiles) {
        NSArray<IXVLESSProfile *> *profiles = [manager profiles];
        if (profiles.count == 0) {
            cell.textLabel.text = IXT(@"No servers yet", @"هنوز سروری نیست");
            cell.detailTextLabel.text = IXT(@"Paste a vless:// link below.", @"یک لینک vless:// پایین بچسبانید.");
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        IXVLESSProfile *profile = profiles[indexPath.row];
        cell.textLabel.text = profile.displayName;
        cell.detailTextLabel.text = profile.endpointSummary;
        if ([profile.uri isEqualToString:manager.selectedProfile.uri]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
        return cell;
    }

    cell.textLabel.text = indexPath.row == 0 ? IXT(@"Paste from clipboard", @"چسباندن از کلیپبورد") : IXT(@"Enter a vless:// link", @"وارد کردن لینک vless://");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UIImage *)dot:(UIColor *)color {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(14, 14)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 12, 12)] fill];
    }];
}

- (void)switchChanged:(UISwitch *)sender {
    IXProxyManager *manager = IXProxyManager.shared;
    if (sender.tag == 1) {
        [manager setKillSwitch:sender.on];
        return;
    }
    if (sender.tag == 2) {
        [manager setBlockUDP:sender.on];
        return;
    }
    sender.enabled = NO;
    [manager setEnabled:sender.on completion:^(NSError *error) {
        sender.enabled = YES;
        if (error) {
            sender.on = NO;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"VPN", @"فیلترشکن") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        [self.tableView reloadData];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    IXProxyManager *manager = IXProxyManager.shared;
    if (indexPath.section == IXProxySectionTraffic) {
        if (indexPath.row == 2) {
            [manager runTunnelTest:^(NSInteger millis, NSError *error) {
                NSString *message = error ? error.localizedDescription : [NSString stringWithFormat:IXT(@"The tunnel answered in %ld ms.", @"تونل در %ld میلی‌ثانیه جواب داد."), (long)millis];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Test", @"آزمایش") message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                [self.tableView reloadData];
            }];
        } else if (indexPath.row == 3) {
            [self.navigationController pushViewController:[IXProxyLogController new] animated:YES];
        }
        return;
    }
    if (indexPath.section == IXProxySectionProfiles) {
        NSArray<IXVLESSProfile *> *profiles = [manager profiles];
        if (indexPath.row >= profiles.count) return;
        IXVLESSProfile *profile = profiles[indexPath.row];
        [manager selectProfile:profile];
        if (manager.isEnabled) {
            [manager setEnabled:YES completion:^(NSError *error) {
                [self.tableView reloadData];
            }];
        } else {
            [self.tableView reloadData];
        }
        return;
    }
    if (indexPath.section != IXProxySectionAdd) return;
    if (indexPath.row == 0) {
        NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
        [self importText:text];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"VLESS link", @"لینک VLESS") message:IXT(@"Paste one or more vless:// links.", @"یک یا چند لینک vless:// بچسبانید.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"vless://";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:IXT(@"Cancel", @"انصراف") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:IXT(@"Add", @"افزودن") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self importText:alert.textFields.firstObject.text ?: @""];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importText:(NSString *)text {
    NSError *error = nil;
    [IXProxyManager.shared addProfilesFromText:text error:&error];
    if (error) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Could not import", @"وارد نشد") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self.tableView reloadData];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == IXProxySectionProfiles && [IXProxyManager.shared profiles].count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    [IXProxyManager.shared removeProfileAtIndex:indexPath.row];
    [self.tableView reloadData];
}

@end
