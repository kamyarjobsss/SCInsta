#import "../../Localization/SCILocalization.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

// Persian story fonts. Registered for this process, then prepended to any
// story-text font list Instagram exposes. Preview chips render وکسپید.

static NSArray<NSString *> *IXFontNames(void) {
    return @[
        @"AbarMidNoEn-ExtraBlack",
        @"Pelak-SemiBold",
        @"AbarLow-Black",
        @"YekanBakh-Bold"
    ];
}

static BOOL IXIsOurFont(UIFont *font) {
    if (![font isKindOfClass:[UIFont class]]) return NO;
    NSString *name = font.fontName ?: @"";
    for (NSString *ours in IXFontNames()) {
        if ([name isEqualToString:ours]) return YES;
    }
    return NO;
}

static BOOL IXInStoryEditor(UIView *view) {
    UIView *current = view;
    for (int i = 0; current && i < 14; i++) {
        NSString *cls = NSStringFromClass(current.class);
        if ([cls containsString:@"StoryText"] || [cls containsString:@"TextEntry"]) return YES;
        UIResponder *next = current.nextResponder;
        if ([next isKindOfClass:[UIViewController class]]) {
            NSString *vc = NSStringFromClass(next.class);
            if ([vc containsString:@"StoryText"] || [vc containsString:@"TextEntry"]) return YES;
        }
        current = current.superview;
    }
    return NO;
}

static void IXRegisterFonts(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSBundle *bundle = SCILocalizationBundle();
    NSString *dir = [bundle.bundlePath stringByAppendingPathComponent:@"Fonts"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in files) {
        if ([[name pathExtension].lowercaseString isEqualToString:@"ttf"] || [[name pathExtension].lowercaseString isEqualToString:@"otf"]) {
            [paths addObject:[dir stringByAppendingPathComponent:name]];
        }
    }
    for (NSString *path in paths) {
        CFErrorRef error = NULL;
        NSURL *url = [NSURL fileURLWithPath:path];
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            if (error) CFRelease(error);
        }
    }
}

static NSArray *IXPrepend(NSArray *original) {
    NSMutableArray *merged = [IXFontNames() mutableCopy];
    for (id item in original) {
        if (![merged containsObject:item]) [merged addObject:item];
    }
    return merged;
}

static void IXWrapFontLists(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSSet *selectors = [NSSet setWithObjects:@"fontNames", @"availableFonts", @"textFonts", @"fontList", @"supportedFonts", @"storyFonts", nil];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name containsString:@"Story"] || !([name containsString:@"Text"] || [name containsString:@"Font"])) continue;
        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            Method method = class_getInstanceMethod(classes[i], sel);
            BOOL classMethod = NO;
            if (!method) {
                method = class_getClassMethod(classes[i], sel);
                classMethod = YES;
            }
            if (!method || method_getNumberOfArguments(method) != 2) continue;
            const char *types = method_getTypeEncoding(method);
            if (!types || types[0] != '@') continue;
            IMP original = method_getImplementation(method);
            IMP replacement = imp_implementationWithBlock(^id(id selfObject) {
                id result = ((id (*)(id, SEL))original)(selfObject, sel);
                if (![result isKindOfClass:[NSArray class]]) return result;
                NSArray *merged = IXPrepend(result);
                if ([result isKindOfClass:[NSMutableArray class]]) {
                    NSMutableArray *mutable = result;
                    [mutable removeAllObjects];
                    [mutable addObjectsFromArray:merged];
                    return mutable;
                }
                return merged;
            });
            if (classMethod) {
                Class meta = object_getClass(classes[i]);
                Method metaMethod = class_getClassMethod(meta, sel);
                if (metaMethod) method_setImplementation(metaMethod, replacement);
            } else {
                method_setImplementation(method, replacement);
            }
            NSLog(@"[InstagramX] story font list wrapped: %@ %@", name, selName);
        }
    }
    free(classes);
}

%hook UILabel
- (void)setText:(NSString *)text {
    if (self.font.pointSize > 0 && self.font.pointSize <= 28 && IXIsOurFont(self.font) && IXInStoryEditor(self)) {
        %orig(@"وکسپید");
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentRight;
        return;
    }
    %orig;
}

- (void)setFont:(UIFont *)font {
    %orig;
    if (font.pointSize > 0 && font.pointSize <= 28 && IXIsOurFont(font) && IXInStoryEditor(self) && self.text.length > 0) {
        self.text = @"وکسپید";
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentRight;
    }
}
%end

%ctor {
    IXRegisterFonts();
    IXWrapFontLists();
}
