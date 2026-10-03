#import "../../Utils.h"

///////////////////////////////////////////////////////////

// Confirmation handlers

static BOOL ix_likeArmed = NO;

#define CONFIRMPOSTLIKE(orig)                             \
    if (ix_likeArmed) {                                   \
        orig;                                             \
    }                                                     \
    else if ([SCIUtils getBoolPref:@"like_confirm"]) {    \
        NSLog(@"[SCInsta] Confirm post like triggered");  \
        [SCIUtils showConfirmation:^{                     \
            ix_likeArmed = YES;                           \
            orig;                                         \
            ix_likeArmed = NO;                            \
        } title:@"Like this?"];                           \
    }                                                     \
    else {                                                \
        orig;                                             \
    }                                                     \

#define CONFIRMREELSLIKE(orig)                            \
    if (ix_likeArmed) {                                   \
        orig;                                             \
    }                                                     \
    else if ([SCIUtils getBoolPref:@"like_confirm_reels"]) { \
        NSLog(@"[SCInsta] Confirm reels like triggered"); \
        [SCIUtils showConfirmation:^{                     \
            ix_likeArmed = YES;                           \
            orig;                                         \
            ix_likeArmed = NO;                            \
        } title:@"Like this reel?"];                      \
    }                                                     \
    else {                                                \
        orig;                                             \
    }                                                     \

///////////////////////////////////////////////////////////

// Liking posts
%hook IGUFIButtonBarView
- (void)_onLikeButtonPressed:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
%end
%hook IGFeedPhotoView
- (void)_onDoubleTap:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
%end
%hook IGVideoPlayerOverlayContainerView
- (void)_handleDoubleTapGesture:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
%end

// Liking reels
%hook IGSundialViewerVideoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    CONFIRMREELSLIKE(%orig);
}
- (void)controlsOverlayControllerDidLongPressLikeButton:(id)arg1 gestureRecognizer:(id)arg2 {
    CONFIRMREELSLIKE(%orig);
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    CONFIRMREELSLIKE(%orig);
}
%end
%hook IGSundialViewerPhotoCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    CONFIRMREELSLIKE(%orig);
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    CONFIRMREELSLIKE(%orig);
}
%end
%hook IGSundialViewerCarouselCell
- (void)controlsOverlayControllerDidTapLikeButton:(id)arg1 {
    CONFIRMREELSLIKE(%orig);
}
- (void)gestureController:(id)arg1 didObserveDoubleTap:(id)arg2 {
    CONFIRMREELSLIKE(%orig);
}
%end

// Liking comments
%hook IGCommentCellController
- (void)commentCell:(id)arg1 didTapLikeButton:(id)arg2 {
    CONFIRMPOSTLIKE(%orig);
}
- (void)commentCell:(id)arg1 didTapLikedByButtonForUser:(id)arg2 {
    CONFIRMPOSTLIKE(%orig);
}
- (void)commentCellDidLongPressOnLikeButton:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
- (void)commentCellDidEndLongPressOnLikeButton:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
- (void)commentCellDidDoubleTap:(id)arg1 {
    CONFIRMPOSTLIKE(%orig);
}
%end
%hook IGFeedItemPreviewCommentCell
- (void)_didTapLikeButton {
    CONFIRMPOSTLIKE(%orig);
}
%end

// Liking stories
%hook IGStoryFullscreenDefaultFooterView
- (void)_handleLikeTapped {
    CONFIRMPOSTLIKE(%orig);
}
- (void)_likeTapped {
    CONFIRMPOSTLIKE(%orig);
}
- (void)inputView:(id)arg1 didTapLikeButton:(id)arg2 {
    CONFIRMPOSTLIKE(%orig);
}

// The heart control is not always reached through _handleLikeTapped / _likeTapped.
// Cover it on every layout and swallow touches that would otherwise send immediately.
- (void)layoutSubviews {
    %orig;

    UIView *likeButton = nil;
    @try { likeButton = [self valueForKey:@"likeButton"]; } @catch (NSException *exception) { likeButton = nil; }
    if (![likeButton isKindOfClass:[UIView class]]) {
        @try { likeButton = [self valueForKey:@"_likeButton"]; } @catch (NSException *exception) { likeButton = nil; }
    }
    if (![likeButton isKindOfClass:[UIView class]]) return;

    static NSInteger kOverlayTag = 129115;
    UIButton *overlay = (UIButton *)[likeButton viewWithTag:kOverlayTag];
    if (![SCIUtils getBoolPref:@"like_confirm"]) {
        [overlay removeFromSuperview];
        return;
    }

    if (![overlay isKindOfClass:[UIButton class]]) {
        overlay = [UIButton buttonWithType:UIButtonTypeCustom];
        overlay.tag = kOverlayTag;
        overlay.backgroundColor = [UIColor clearColor];
        [overlay addTarget:self action:@selector(ix_overlayTapped:) forControlEvents:UIControlEventTouchUpInside];
        [likeButton addSubview:overlay];
    }
    overlay.frame = likeButton.bounds;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [likeButton bringSubviewToFront:overlay];
    for (UIGestureRecognizer *gesture in likeButton.gestureRecognizers) {
        gesture.enabled = NO;
    }
}

%new - (void)ix_overlayTapped:(UIButton *)overlay {
    UIControl *likeButton = (UIControl *)overlay.superview;
    [SCIUtils showConfirmation:^{
        ix_likeArmed = YES;
        if ([likeButton isKindOfClass:[UIControl class]]) {
            [likeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else if ([self respondsToSelector:@selector(_handleLikeTapped)]) {
            [self performSelector:@selector(_handleLikeTapped)];
        } else if ([self respondsToSelector:@selector(_likeTapped)]) {
            [self performSelector:@selector(_likeTapped)];
        }
        ix_likeArmed = NO;
    } title:@"Like this?"];
}
%end

@interface UIControl (IXStoryLike)
- (BOOL)ix_isStoryLikeControl;
@end

%hook UIControl
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    if (!ix_likeArmed && [SCIUtils getBoolPref:@"like_confirm"] && [self ix_isStoryLikeControl]) {
        UIControl *control = self;
        SEL savedAction = action;
        id savedTarget = target;
        UIEvent *savedEvent = event;
        [SCIUtils showConfirmation:^{
            ix_likeArmed = YES;
            [control sendAction:savedAction to:savedTarget forEvent:savedEvent];
            ix_likeArmed = NO;
        } title:@"Like this?"];
        return;
    }
    %orig;
}
%new - (BOOL)ix_isStoryLikeControl {
    BOOL inFooter = NO;
    BOOL mentionsLike = NO;
    UIView *view = self;
    for (int i = 0; view && i < 8; i++) {
        if ([NSStringFromClass(view.class) containsString:@"IGStoryFullscreenDefaultFooterView"]) inFooter = YES;
        NSString *blob = [NSString stringWithFormat:@"%@ %@", view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @""].lowercaseString;
        if ([blob containsString:@"like"]) mentionsLike = YES;
        view = view.superview;
    }
    return inFooter && mentionsLike;
}
%end

// DM like button (seems to be hidden)
%hook IGDirectThreadViewController
- (void)_didTapLikeButton {
    CONFIRMPOSTLIKE(%orig);
}
%end