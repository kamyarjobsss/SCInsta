#import "../../InstagramHeaders.h"
#import "../../Settings/SCISettingsViewController.h"

// Show SCInsta tweak settings by holding on the settings/more icon under profile for ~1 second
%hook IGBadgedNavigationButton
- (void)didMoveToWindow {
    %orig;

    if ([self.accessibilityIdentifier isEqualToString:@"profile-more-button"]) {
        [self addLongPressGestureRecognizer];
    }

    return;
}

%new - (void)addLongPressGestureRecognizer {
    for (UIGestureRecognizer *existing in self.gestureRecognizers) {
        if ([existing isKindOfClass:[UILongPressGestureRecognizer class]] && ((UILongPressGestureRecognizer *)existing).minimumPressDuration >= 0.4) return;
    }
    NSLog(@"[SCInsta] Adding tweak settings long press gesture recognizer");
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.45;
    longPress.cancelsTouchesInView = NO;
    longPress.delaysTouchesBegan = NO;
    [self addGestureRecognizer:longPress];
}
%new - (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    
    NSLog(@"[SCInsta] Tweak settings gesture activated");

    [SCIUtils showSettingsVC:[self window]];
}
%end

// Quick access to tweak settings by holding on the home tab button.
// In messages-only mode the home tab is gone — fall back to the inbox tab.
%hook IGTabBarButton
- (void)didMoveToSuperview {
    %orig;

    BOOL msgOnly = [SCIUtils getBoolPref:@"messages_only"];
    NSString *target = msgOnly ? @"direct-inbox-tab" : @"mainfeed-tab";
    if (![self.accessibilityIdentifier isEqualToString:target]) return;

    if ([SCIUtils getBoolPref:@"settings_shortcut"]) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.3;
        
        // Take precidence over existing gesture recognizers
        for (UIGestureRecognizer *existing in self.gestureRecognizers) {
            [existing requireGestureRecognizerToFail:longPress];
        }
        
        [self addGestureRecognizer:longPress];
    }
}
%new - (void)handleLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;

    [SCIUtils showSettingsVC:[self window]];
}
%end