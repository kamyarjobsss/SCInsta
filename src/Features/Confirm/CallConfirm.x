#import "../../Utils.h"
#import "../../Proxy/IXTrafficGuard.h"

static BOOL IXAbortCallForVPN(void) {
    if (!(IXTrafficGuardVPNOn() && IXTrafficGuardBlockUDP())) return NO;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Instagram X"
                                                                   message:@"Calls are blocked while the in-app VPN is on, so WebRTC cannot reveal this phone’s IP address. Turn off “Block UDP and calls” in Instagram X settings to allow them. That can expose your real IP."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [topMostController() presentViewController:alert animated:YES completion:nil];
    return YES;
}

%hook IGDirectThreadCallButtonsCoordinator
// Voice Call
- (void)_didTapAudioButton:(id)arg1 {
    if (IXAbortCallForVPN()) return;
    if ([SCIUtils getBoolPref:@"call_confirm"]) {
        NSLog(@"[SCInsta] Call confirm triggered");

        [SCIUtils showConfirmation:^(void) { %orig; }];
    } else {
        return %orig;
    }
}

// Video Call
- (void)_didTapVideoButton:(id)arg1 {
    if (IXAbortCallForVPN()) return;
    if ([SCIUtils getBoolPref:@"call_confirm"]) {
        NSLog(@"[SCInsta] Call confirm triggered");
        
        [SCIUtils showConfirmation:^(void) { %orig; }];
    } else {
        return %orig;
    }
}
%end