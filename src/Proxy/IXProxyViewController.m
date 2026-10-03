#import "IXProxyViewController.h"
#import "IXProxyManager.h"

typedef NS_ENUM(NSInteger, IXProxySection) {
    IXProxySectionStatus = 0,
    IXProxySectionControls,
    IXProxySectionProfiles,
    IXProxySectionAdd,
    IXProxySectionCount
};

@implementation IXProxyViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VPN";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return IXProxySectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == IXProxySectionProfiles) return MAX([IXProxyManager.shared profiles].count, 1);
    if (section == IXProxySectionControls) return 3;
    if (section == IXProxySectionAdd) return 2;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case IXProxySectionStatus: return @"Status";
        case IXProxySectionControls: return @"Protection";
        case IXProxySectionProfiles: return @"Servers";
        default: return @"Add a server";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != IXProxySectionAdd) return nil;
    return [NSString stringWithFormat:@"Engine: %@.\n\nThis is an in-app proxy, not a system VPN. It covers Instagram traffic inside this process. WebKit’s network process, system media playback, and any stack that never calls connect, connectx, or NSURLSession can still bypass it. UDP and calls are blocked by default so WebRTC cannot reveal the phone’s address. The kill switch refuses new connections when the proxy is down instead of using the real IP. A TCP test only measures the handshake to the server, not a full login through VLESS.", IXProxyManager.shared.engineName];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    IXProxyManager *manager = IXProxyManager.shared;

    if (indexPath.section == IXProxySectionStatus) {
        cell.textLabel.text = manager.statusText;
        cell.detailTextLabel.text = manager.engineName;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UIColor *color = [UIColor systemGrayColor];
        if (manager.status == IXProxyStatusConnected) color = [UIColor systemGreenColor];
        else if (manager.status == IXProxyStatusConnecting) color = [UIColor systemOrangeColor];
        else if (manager.status == IXProxyStatusFailed) color = [UIColor systemRedColor];
        cell.imageView.image = [self dot:color];
        return cell;
    }

    if (indexPath.section == IXProxySectionControls) {
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Route Instagram through VLESS";
            cell.detailTextLabel.text = @"Turns the in-app proxy on for this process.";
            toggle.on = manager.isEnabled || manager.status == IXProxyStatusConnected || manager.status == IXProxyStatusConnecting;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Kill switch";
            cell.detailTextLabel.text = @"If the proxy is down, block Instagram instead of leaking the real IP.";
            toggle.on = manager.killSwitch;
        } else {
            cell.textLabel.text = @"Block UDP and calls";
            cell.detailTextLabel.text = @"Stops WebRTC, STUN, and call media from bypassing the tunnel. Turning this off can reveal your IP.";
            toggle.on = manager.blockUDP;
        }
        return cell;
    }

    if (indexPath.section == IXProxySectionProfiles) {
        NSArray<IXVLESSProfile *> *profiles = [manager profiles];
        if (profiles.count == 0) {
            cell.textLabel.text = @"No servers yet";
            cell.detailTextLabel.text = @"Paste a vless:// link below.";
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

    cell.textLabel.text = indexPath.row == 0 ? @"Paste from clipboard" : @"Enter a vless:// link";
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
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VPN" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        [self.tableView reloadData];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    IXProxyManager *manager = IXProxyManager.shared;
    if (indexPath.section == IXProxySectionProfiles) {
        NSArray<IXVLESSProfile *> *profiles = [manager profiles];
        if (indexPath.row >= profiles.count) return;
        IXVLESSProfile *profile = profiles[indexPath.row];
        [manager selectProfile:profile];
        [manager testProfile:profile completion:^(NSInteger millis, NSError *error) {
            NSString *message = error ? error.localizedDescription : [NSString stringWithFormat:@"TCP handshake %ld ms. This does not prove the VLESS login succeeded.", (long)millis];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:profile.displayName message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VLESS link" message:@"Paste one or more vless:// links." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"vless://";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self importText:alert.textFields.firstObject.text ?: @""];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importText:(NSString *)text {
    NSError *error = nil;
    [IXProxyManager.shared addProfilesFromText:text error:&error];
    if (error) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not import" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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
