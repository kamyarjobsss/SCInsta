#import "IXSettingsEntry.h"

%hook UILabel
- (void)setText:(NSString *)text {
    %orig;
    if (text.length >= 8 && text.length <= 80) [IXSettingsEntry noteLabel:self];
}
- (void)setAttributedText:(NSAttributedString *)attributedText {
    %orig;
    if (attributedText.length >= 8 && attributedText.length <= 80) [IXSettingsEntry noteLabel:self];
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [IXSettingsEntry noteSettingsController:self];
}
%end

%hook UIScrollView
- (void)layoutSubviews {
    %orig;
    [IXSettingsEntry relayoutIfNeeded:self];
}
%end
