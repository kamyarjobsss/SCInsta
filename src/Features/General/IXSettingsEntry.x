#import "IXSettingsEntry.h"

%group IXSettingsEntryHooks
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [IXSettingsEntry noteSettingsController:self];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [IXSettingsEntry removeSettingsRowForController:self];
}
- (void)viewDidLayoutSubviews {
    %orig;
    [IXSettingsEntry relayoutSettingsRowForController:self];
}
%end
%end

void IXSettingsEntryInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    %init(IXSettingsEntryHooks);
}
