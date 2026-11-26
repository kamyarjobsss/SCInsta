#import "../../Utils.h"

@interface _TtC33IGSundialViewerNavigationBarSwift28IGSundialViewerNavigationBar : UIView
@end

%hook _TtC33IGSundialViewerNavigationBarSwift28IGSundialViewerNavigationBar
- (void)didMoveToWindow {
    %orig;

    if ([SCIUtils getBoolPref:@"hide_reels_header"]) {
        NSLog(@"[SCInsta] Hiding reels header");

        [self removeFromSuperview];
    }
}
%end
