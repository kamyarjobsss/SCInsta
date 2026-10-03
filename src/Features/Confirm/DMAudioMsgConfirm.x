#import "../../Utils.h"

// Long-press voice messages send on gesture end, which used to skip the
// confirmation hooks. Defer that end state until the user confirms. A short
// approval flag lets the lower-level send methods run once without asking again.

static BOOL ix_voiceApproved = NO;

static BOOL IXViewChainIsVoice(UIView *view) {
    BOOL mentionsVoice = NO;
    BOOL inComposer = NO;
    UIView *current = view;
    for (int i = 0; current && i < 8; i++) {
        NSString *blob = [NSString stringWithFormat:@"%@ %@ %@",
                          current.accessibilityIdentifier ?: @"",
                          current.accessibilityLabel ?: @"",
                          NSStringFromClass(current.class)].lowercaseString;
        if ([blob containsString:@"compactbar"] || [blob containsString:@"voicerecord"] || [blob containsString:@"audiorecord"]) return YES;
        if ([blob containsString:@"voice"] || [blob containsString:@"voicemessage"] || [blob containsString:@"mic"]) mentionsVoice = YES;
        if ([blob containsString:@"composer"]) inComposer = YES;
        current = current.superview;
    }
    return mentionsVoice && inComposer;
}

%hook UILongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    if (!ix_voiceApproved
        && state == UIGestureRecognizerStateEnded
        && [SCIUtils getBoolPref:@"voice_message_confirm"]
        && IXViewChainIsVoice(self.view)) {
        UILongPressGestureRecognizer *gesture = self;
        [SCIUtils showConfirmation:^{
            ix_voiceApproved = YES;
            gesture.state = UIGestureRecognizerStateEnded;
            ix_voiceApproved = NO;
        } cancelHandler:^{
            ix_voiceApproved = YES;
            gesture.state = UIGestureRecognizerStateCancelled;
            ix_voiceApproved = NO;
        } title:@"Send voice message?"];
        return;
    }
    %orig;
}
%end

// Legacy hook (for non ai voices interface)
%hook IGDirectThreadViewController
- (void)voiceRecordViewController:(id)arg1 didRecordAudioClipWithURL:(id)arg2 waveform:(id)arg3 duration:(CGFloat)arg4 entryPoint:(NSInteger)arg5 {
    if (ix_voiceApproved || ![SCIUtils getBoolPref:@"voice_message_confirm"]) {
        %orig;
        return;
    }
    NSLog(@"[SCInsta] DM audio message confirm triggered");
    [SCIUtils showConfirmation:^{
        ix_voiceApproved = YES;
        %orig;
        ix_voiceApproved = NO;
    } title:@"Send voice message?"];
}
%end

// Starting a hold should still record. Sending is gated above.
%hook IGDirectComposer
- (void)_didLongPressVoiceMessage:(id)arg1 {
    %orig;
}
%end

// Demangled name: IGDirectAIVoiceUIKit.CompactBarContentView
%hook _TtC20IGDirectAIVoiceUIKitP33_5754F7617E0D924F9A84EFA352BBD29A21CompactBarContentView
- (void)didTapSend {
    if (ix_voiceApproved || ![SCIUtils getBoolPref:@"voice_message_confirm"]) {
        %orig;
        return;
    }
    NSLog(@"[SCInsta] DM audio message confirm triggered");
    [SCIUtils showConfirmation:^{
        ix_voiceApproved = YES;
        %orig;
        ix_voiceApproved = NO;
    } title:@"Send voice message?"];
}
%end
