#import "IXAddonSettings.h"
#import "../src/Launch/IXLaunchGuard.h"
#import "../src/Location/IXLocationHooks.h"
#import "../src/Location/IXLocationPickerViewController.h"
#import "../src/Location/IXLocationStore.h"
#import "../src/Proxy/IXProxyManager.h"
#import "../src/Proxy/IXProxyViewController.h"

@interface IXAddonSettingsViewController : UITableViewController
@end

@implementation IXAddonSettingsViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Instagram X";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? 2 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"VLESS proxy" : @"Fake location";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) {
        return @"Off until you turn it on. Socket hooks are installed only while it is on, and they are removed when you turn it off. This does not change the other tweak in this app.";
    }
    return @"Off until you turn it on. While it is on, this add-on answers location requests with the place you pick.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"Use proxy";
        cell.detailTextLabel.text = [IXProxyManager statusSubtitle];
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [IXProxyManager.shared isEnabled];
        [toggle addTarget:self action:@selector(proxyToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Proxy settings";
        cell.detailTextLabel.text = IXProxyManager.shared.engineName;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (indexPath.row == 0) {
        cell.textLabel.text = @"Spoof location";
        cell.detailTextLabel.text = [IXLocationStore isEnabled] ? [IXLocationStore placeName] : @"Off";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [IXLocationStore isEnabled];
        [toggle addTarget:self action:@selector(locationToggled:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    cell.textLabel.text = @"Choose a place";
    cell.detailTextLabel.text = [IXLocationStore hasSavedCoordinate] ? [IXLocationStore placeName] : @"Map";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)proxyToggled:(UISwitch *)sender {
    __weak typeof(self) weakSelf = self;
    [IXProxyManager.shared setEnabled:sender.on completion:^(NSError *error) {
        if (error) sender.on = NO;
        [weakSelf.tableView reloadData];
    }];
}

- (void)locationToggled:(UISwitch *)sender {
    [IXLocationStore setEnabled:sender.on];
    if (sender.on) IXLocationHooksInstall();
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    if (indexPath.section == 0 && indexPath.row == 1) next = [IXProxyViewController new];
    if (indexPath.section == 1 && indexPath.row == 1) next = [IXLocationPickerViewController new];
    if (next) [self.navigationController pushViewController:next animated:YES];
}

@end

static UIViewController *IXTopPresenter(UIView *from) {
    UIWindow *window = from.window;
    if (!window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) window = candidate;
            }
        }
    }
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    return presenter;
}

void IXAddonPresentSettings(UIView *from) {
    IXAddonSettingsViewController *root = [IXAddonSettingsViewController new];
    if (IXLaunchGuardIsSafeMode()) {
        root.navigationItem.prompt = @"Safe mode: extras stayed off until you opened this page.";
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    UIViewController *presenter = IXTopPresenter(from);
    if (presenter) [presenter presentViewController:nav animated:YES completion:nil];
}
