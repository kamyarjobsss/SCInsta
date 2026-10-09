#import "IXProxyViewController.h"
#import "IXProxyManager.h"
#import "IXTrafficGuard.h"
#import "../Launch/IXLaunchGuard.h"
#import "../Localization/SCILocalization.h"
#import "../Tweak.h"

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

static NSString *IXDiagnosticsReport(void) {
    IXProxyManager *manager = IXProxyManager.shared;
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"Instagram X %@\n", SCIVersionString ?: @""];
    [text appendFormat:@"status: %@\n", manager.statusText ?: @""];
    if (manager.lastError.length) [text appendFormat:@"error: %@\n", manager.lastError];
    IXVLESSProfile *profile = manager.selectedProfile;
    NSString *picked = [manager xhttpModeForProfile:profile];
    NSString *rawMode = picked.length ? picked : profile.mode;
    BOOL xhttp = [profile.network isEqualToString:@"xhttp"] || [profile.network isEqualToString:@"splithttp"];
    [text appendFormat:@"xhttpMode: %@\n", xhttp ? [IXVLESSProfile xrayXHTTPModeFrom:rawMode] : @"n/a"];
    [text appendFormat:@"interface: %@\n", manager.boundInterface ?: @"system"];
    [text appendFormat:@"server: %@\n", IXTrafficGuardProxyHost() ?: @""];
    [text appendFormat:@"killSwitch: %@\n", manager.killSwitch ? @"on" : @"off"];
    [text appendFormat:@"blockUDP: %@\n", manager.blockUDP ? @"on" : @"off"];
    [text appendFormat:@"vpnOn: %@\n", IXTrafficGuardVPNOn() ? @"yes" : @"no"];
    [text appendFormat:@"proxyUp: %@\n", IXTrafficGuardProxyUp() ? @"yes" : @"no"];
    [text appendFormat:@"nwProxy: %@\n", IXTrafficGuardNWProxyReady() ? @"yes" : @"no"];
    NSArray<NSDictionary *> *rows = IXTrafficGuardRecentConnections() ?: @[];
    [text appendFormat:@"safeMode: %@\n", IXLaunchGuardIsSafeMode() ? @"yes" : @"no"];
    [text appendFormat:@"connections: %lu\n", (unsigned long)rows.count];
    for (NSDictionary *row in rows) {
        [text appendFormat:@"%@ %@ %@:%@ up=%@ down=%@ %@\n",
            row[@"image"] ?: @"",
            row[@"api"] ?: row[@"path"] ?: @"",
            row[@"host"] ?: @"",
            row[@"port"] ?: @0,
            row[@"up"] ?: @0,
            row[@"down"] ?: @0,
            row[@"reason"] ?: @""];
    }
    if (manager.recentLog.length) {
        [text appendString:@"\n"];
        [text appendString:manager.recentLog];
    }
    return text;
}

static void IXCopyDiagnostics(UIViewController *presenter) {
    [UIPasteboard generalPasteboard].string = IXDiagnosticsReport();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Copied", @"کپی شد") message:IXT(@"Diagnostics are on the clipboard. They list which connections were tunneled, blocked, or direct.", @"گزارش در کلیپبورد است. معلوم است کدام اتصال از تونل رفته، بسته شده، یا مستقیم بوده.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static NSString *IXBytes(uint64_t n) {
    if (n < 1024) return [NSString stringWithFormat:@"%llu B", (unsigned long long)n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB", n / (1024.0 * 1024.0)];
}

@interface IXProxyConnectionsController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation IXProxyConnectionsController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IXT(@"Connections", @"اتصال‌ها");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:IXT(@"Copy", @"کپی") style:UIBarButtonItemStylePlain target:self action:@selector(copyDiagnostics)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = IXT(@"Copy diagnostics", @"کپی گزارش");
}
- (void)copyDiagnostics {
    IXCopyDiagnostics(self);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRows];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(reloadRows) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)reloadRows {
    self.rows = IXTrafficGuardRecentConnections() ?: @[];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.rows.count, 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return IXT(@"tunneled went through the in-app proxy. blocked was refused by the kill switch or the UDP block. direct left the phone on your real route. Copy sends this list.", @"tunneled از پروکسی داخل برنامه گذشته است. blocked را قطع اضطراری یا بستن UDP رد کرده است. direct از مسیر واقعی گوشی بیرون رفته. کپی همین فهرست را می‌فرستد.");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.rows.count == 0) {
        cell.textLabel.text = IXT(@"No connections yet", @"هنوز اتصالی نیست");
        cell.detailTextLabel.text = IXT(@"Open the feed with the VPN on.", @"با فیلترشکن روشن، فید را باز کنید.");
        return cell;
    }
    NSDictionary *row = self.rows[self.rows.count - 1 - indexPath.row];
    NSString *host = row[@"host"] ?: @"";
    NSNumber *port = row[@"port"];
    cell.textLabel.text = port.unsignedIntegerValue ? [NSString stringWithFormat:@"%@:%@", host, port] : host;
    NSString *image = row[@"image"] ?: @"";
    NSString *api = row[@"api"] ?: row[@"path"] ?: @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@%@ · ↑%@ · ↓%@ · %@", image, image.length ? @" · " : @"", api, IXBytes([row[@"up"] unsignedLongLongValue]), IXBytes([row[@"down"] unsignedLongLongValue]), row[@"reason"] ?: @""];
    return cell;
}
@end

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
@property (nonatomic, copy) NSString *exitSummary;
@property (nonatomic) BOOL checkingIP;
@property (nonatomic) BOOL developerMode;
@property (nonatomic) NSInteger versionTaps;
@property (nonatomic) NSTimeInterval lastVersionTap;
@end

@implementation IXProxyViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)ixUpdateChrome {
    if (!self.developerMode) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:IXT(@"Copy", @"کپی") style:UIBarButtonItemStylePlain target:self action:@selector(copyDiagnostics)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = IXT(@"Copy diagnostics", @"کپی گزارش");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IXT(@"VPN", @"فیلترشکن");
    self.developerMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"ix_vpn_developer"];
    [IXProxyManager.shared setKillSwitch:YES];
    [self ixUpdateChrome];
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
    if (!self.developerMode) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        NSString *now = IXProxyManager.shared.statusText ?: @"";
        if (cell && ![cell.detailTextLabel.text isEqualToString:now]) [self.tableView reloadData];
        return;
    }
    if (IXProxyManager.shared.status != IXProxyStatusConnected) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:IXProxySectionTraffic] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (!self.developerMode) return 1;
    return IXProxySectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.developerMode) return 1;
    if (section == IXProxySectionProfiles) return MAX([IXProxyManager.shared profiles].count, 1);
    if (section == IXProxySectionControls) return IXLaunchGuardIsSafeMode() ? 5 : 4;
    if (section == IXProxySectionAdd) return 2;
    if (section == IXProxySectionTraffic) return 6;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.developerMode) return nil;
    switch (section) {
        case IXProxySectionStatus: return IXT(@"Status", @"وضعیت");
        case IXProxySectionTraffic: return IXT(@"Traffic", @"ترافیک");
        case IXProxySectionControls: return IXT(@"Protection", @"محافظت");
        case IXProxySectionProfiles: return IXT(@"Servers", @"سرورها");
        default: return IXT(@"Add a server", @"افزودن سرور");
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (self.developerMode || section != 0) return nil;
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 44)];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = wrap.bounds;
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button setTitle:SCIVersionString ?: @"" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    [button addTarget:self action:@selector(versionTapped) forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = IXT(@"Version", @"نسخه");
    [wrap addSubview:button];
    return wrap;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    if (!self.developerMode && section == 0) return 44;
    return UITableViewAutomaticDimension;
}

- (void)versionTapped {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - self.lastVersionTap > 2.0) self.versionTaps = 0;
    self.lastVersionTap = now;
    self.versionTaps += 1;
    if (self.versionTaps < 7) return;
    self.versionTaps = 0;
    self.developerMode = YES;
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ix_vpn_developer"];
    [self ixUpdateChrome];
    [self.tableView reloadData];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.developerMode) return nil;
    if (section != IXProxySectionAdd) return nil;
    return [NSString stringWithFormat:IXT(@"Engine: %@.\n\nConnected means a request through the tunnel reached generate_204. This is an in-app proxy, not the phone's VPN switch. With the kill switch on, every other path fails until the tunnel is up. UDP stays blocked so QUIC falls back to TCP. Copy sends tunneled, blocked, and direct connections.", @"موتور: %@.\n\n«متصل» یعنی یک درخواست واقعی از تونل به generate_204 رسیده است. این فیلترشکن داخل خود اینستاگرام است و با VPN سیستم فرق دارد. با قطع اضطراری، تا وقتی تونل بالا نیامده هیچ مسیر دیگری وصل نمی‌شود. UDP بسته است تا QUIC به TCP برگردد. کپی فهرست تونل، بسته‌شده و مستقیم را می‌فرستد."), IXProxyManager.shared.engineName];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    IXProxyManager *manager = IXProxyManager.shared;

    if (!self.developerMode) {
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.tag = 0;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = IXT(@"VPN", @"فیلترشکن");
        cell.detailTextLabel.text = manager.statusText;
        toggle.on = manager.isEnabled || manager.status == IXProxyStatusConnected || manager.status == IXProxyStatusConnecting;
        return cell;
    }

    if (indexPath.section == IXProxySectionStatus) {
        NSString *status = manager.statusText;
        if ([SCIResolvedLanguageCode() hasPrefix:@"fa"]) {
            if (manager.status == IXProxyStatusConnected) status = @"متصل";
            else if (manager.status == IXProxyStatusConnecting) status = @"در حال اتصال";
            else if (manager.status == IXProxyStatusFailed) status = manager.lastError.length ? [NSString stringWithFormat:@"قطع · %@", manager.lastError] : @"قطع";
            else status = @"خاموش";
        }
        cell.textLabel.text = status;
        NSString *kill = manager.killSwitch ? IXT(@"Kill switch on", @"قطع اضطراری روشن") : IXT(@"Kill switch off", @"قطع اضطراری خاموش");
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", manager.engineName, kill];
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
            cell.textLabel.text = IXT(@"Check IP", @"بررسی IP");
            cell.detailTextLabel.text = self.exitSummary.length ? self.exitSummary : IXT(@"Fetches the exit IP and country through the tunnel.", @"IP خروجی و کشور را از داخل تونل می‌گیرد.");
            cell.selectionStyle = self.checkingIP ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = IXT(@"Test tunnel", @"آزمایش تونل");
            cell.detailTextLabel.text = manager.lastPingMs >= 0
                ? [NSString stringWithFormat:IXT(@"Last ping %ld ms", @"آخرین پینگ %ld میلی‌ثانیه"), (long)manager.lastPingMs]
                : IXT(@"Sends generate_204 through the tunnel.", @"یک درخواست generate_204 از داخل تونل می‌فرستد.");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = IXT(@"View log", @"دیدن گزارش");
            cell.detailTextLabel.text = IXT(@"Xray messages and the connectivity check.", @"پیام‌های Xray و نتیجهٔ آزمایش اتصال.");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = IXT(@"Connections", @"اتصال‌ها");
            cell.detailTextLabel.text = IXT(@"Which path each request took, the bytes, and why it closed.", @"هر درخواست از کدام مسیر رفته، حجمش، و چرا بسته شده است.");
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
            cell.accessoryView = nil;
            cell.textLabel.text = IXT(@"Kill switch", @"قطع اضطراری");
            cell.detailTextLabel.text = IXT(@"Always on.", @"همیشه روشن است.");
        } else if (indexPath.row == 2) {
            cell.textLabel.text = IXT(@"Block UDP and calls", @"بستن UDP و تماس");
            cell.detailTextLabel.text = IXT(@"Stops call media from bypassing the tunnel. Turning this off can reveal your IP.", @"نمی‌گذارد صدای تماس از کنار تونل رد شود. خاموش کردنش می‌تواند IP را لو بدهد.");
            toggle.on = manager.blockUDP;
        } else if (indexPath.row == 4) {
            cell.accessoryView = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.textLabel.text = IXT(@"Exit safe mode", @"خروج از حالت امن");
            cell.detailTextLabel.text = IXT(@"Installs the VPN hooks on this launch when the switch is on.", @"اگر کلید روشن باشد، هوک‌های فیلترشکن را در همین اجرا نصب می‌کند.");
        } else {
            cell.accessoryView = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            IXVLESSProfile *selected = manager.selectedProfile;
            BOOL xhttp = [selected.network isEqualToString:@"xhttp"] || [selected.network isEqualToString:@"splithttp"];
            NSString *override = [manager xhttpModeForProfile:selected];
            NSString *effective = [IXVLESSProfile xrayXHTTPModeFrom:override.length ? override : selected.mode];
            cell.textLabel.text = IXT(@"XHTTP mode", @"حالت XHTTP");
            cell.detailTextLabel.text = xhttp
                ? (override.length
                    ? [effective stringByAppendingString:IXT(@" (saved)", @" (ذخیره شده)")]
                    : IXT(@"Tries auto, then packet-up, stream-up, and stream-one.", @"اول auto، بعد packet-up، stream-up و stream-one."))
                : IXT(@"Applies when the selected server is xhttp.", @"وقتی سرور انتخاب‌شده xhttp باشد اثر دارد.");
        }
        return cell;
    }

    if (indexPath.section == IXProxySectionProfiles) {
        NSArray<IXVLESSProfile *> *profiles = [manager profiles];
        if (profiles.count == 0) {
            cell.textLabel.text = IXT(@"No servers yet", @"هنوز سروری نیست");
            cell.detailTextLabel.text = IXT(@"Paste a vless://, trojan://, vmess://, or ss:// link below.", @"یک لینک vless://، trojan://، vmess:// یا ss:// پایین بچسبانید.");
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

    cell.textLabel.text = indexPath.row == 0 ? IXT(@"Paste from clipboard", @"چسباندن از کلیپبورد") : IXT(@"Enter a server link", @"وارد کردن لینک سرور");
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

- (void)copyDiagnostics {
    IXCopyDiagnostics(self);
}

- (void)switchChanged:(UISwitch *)sender {
    IXProxyManager *manager = IXProxyManager.shared;
    if (sender.tag == 1) {
        sender.on = YES;
        [manager setKillSwitch:YES];
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
    if (!self.developerMode) return;
    IXProxyManager *manager = IXProxyManager.shared;
    if (indexPath.section == IXProxySectionTraffic) {
        if (indexPath.row == 2) {
            if (self.checkingIP) return;
            self.checkingIP = YES;
            self.exitSummary = IXT(@"Checking…", @"در حال بررسی…");
            [self.tableView reloadData];
            [manager checkExitIP:^(NSString *summary, NSError *error) {
                self.checkingIP = NO;
                self.exitSummary = summary;
                NSString *message = error ? error.localizedDescription : summary;
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Check IP", @"بررسی IP") message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                [self.tableView reloadData];
            }];
        } else if (indexPath.row == 3) {
            [manager runTunnelTest:^(NSInteger millis, NSError *error) {
                NSString *message = error ? error.localizedDescription : [NSString stringWithFormat:IXT(@"The tunnel answered in %ld ms.", @"تونل در %ld میلی‌ثانیه جواب داد."), (long)millis];
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Test", @"آزمایش") message:message preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:IXT(@"OK", @"باشه") style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                [self.tableView reloadData];
            }];
        } else if (indexPath.row == 4) {
            [self.navigationController pushViewController:[IXProxyLogController new] animated:YES];
        } else if (indexPath.row == 5) {
            [self.navigationController pushViewController:[IXProxyConnectionsController new] animated:YES];
        }
        return;
    }
    if (indexPath.section == IXProxySectionControls && indexPath.row == 4) {
        [manager exitSafeMode];
        [self.tableView reloadData];
        return;
    }
    if (indexPath.section == IXProxySectionControls && indexPath.row == 3) {
        IXVLESSProfile *selected = manager.selectedProfile;
        if (!selected) return;
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:IXT(@"XHTTP mode", @"حالت XHTTP") message:IXT(@"A mode that does not answer is replaced by the next one. The mode that answers is saved for this server.", @"اگر یک حالت جواب ندهد، حالت بعدی امتحان می‌شود. حالتی که جواب بدهد برای این سرور ذخیره می‌شود.") preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *modes = @[@"", @"stream-one", @"stream-up", @"packet-up"];
        NSArray *titles = @[
            IXT(@"Link default", @"پیش‌فرض لینک"),
            @"stream-one",
            @"stream-up",
            @"packet-up"
        ];
        for (NSUInteger i = 0; i < modes.count; i++) {
            NSString *mode = modes[i];
            [sheet addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [manager setXHTTPMode:mode forProfile:selected];
                [self.tableView reloadData];
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:IXT(@"Cancel", @"انصراف") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:sheet animated:YES completion:nil];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:IXT(@"Server link", @"لینک سرور") message:IXT(@"Paste a vless://, trojan://, vmess://, or ss:// link.", @"یک لینک vless://، trojan://، vmess:// یا ss:// بچسبانید.") preferredStyle:UIAlertControllerStyleAlert];
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
    if (!self.developerMode) return NO;
    return indexPath.section == IXProxySectionProfiles && [IXProxyManager.shared profiles].count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    [IXProxyManager.shared removeProfileAtIndex:indexPath.row];
    [self.tableView reloadData];
}

@end
