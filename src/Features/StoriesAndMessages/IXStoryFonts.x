#import "../../Localization/SCILocalization.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// Story text fonts, taken from the Instagram 436 main executable.
//
// IGRichTextFormat (instance size 168) is the picker element.
//   -initWithType:animationType:accessibilityDescriptor:font:minFontSize:maxFontSize:
//    fontSizeMultiplier:defaultAlignment:lineHeightMultiple:loggingName:forceUppercaseText:
//    placeholderTextSize:autocapitalizationType:underlineThicknessMultiplier:
//    includesAtSymbolInUnderline:textV2Emphasis:textV2SecondaryEmphasis:displayName:
//    categories:supportedScripts:effectId:
//    type encoding @176@0:8q16q24@32@40d48d56d64Q72d80@88B96d100q108d116B124@128@136@144@152@160@168
//   -_copyWithAnimationType:font:defaultAlignment:textV2Emphasis:textV2SecondaryEmphasis:
//    displayName:categories:supportedScripts:
//    type encoding @80@0:8q16@24Q32@40@48@56@64@72
//   -font -animationType -categories -supportedScripts -displayName -loggingName
//   ivars _defaultAlignment (Q, no getter), _textV2Emphasis, _textV2SecondaryEmphasis, _loggingName
//
// The lists the story text tool actually installs:
//   -[IGStoryTextEntryViewControllerConfiguration setTextFormats:]
//   -[IGStoryTextEntryViewControllerConfiguration textFormats]
//   +[IGStoryTextEntryViewControllerConfiguration postcaptureTextFormatsWithEntryPoint:userSession:]
//   -[IGStoryTextEntryControlsOverlayView setFontPresets:]
//   -[IGStoryTextEntryControlsOverlayView fontPresets]
//   -getTextFormatsWithCompletionHandler:  v24@0:8@?<v@?@"NSArray"@"NSError">16
//
// Preview chips use displayName. Ours is وکسپید, with RTL on the real font-picker labels.

static NSString *const IXPreviewText = @"وکسپید";

static const char *kIXCopySel =
    "_copyWithAnimationType:font:defaultAlignment:textV2Emphasis:textV2SecondaryEmphasis:displayName:categories:supportedScripts:";
static const char *kIXInitSel =
    "initWithType:animationType:accessibilityDescriptor:font:minFontSize:maxFontSize:fontSizeMultiplier:defaultAlignment:lineHeightMultiple:loggingName:forceUppercaseText:placeholderTextSize:autocapitalizationType:underlineThicknessMultiplier:includesAtSymbolInUnderline:textV2Emphasis:textV2SecondaryEmphasis:displayName:categories:supportedScripts:effectId:";
static const char *kIXGetFormatsSel = "getTextFormatsWithCompletionHandler:";
static const char *kIXGetFormatsTypes = "v24@0:8@?<v@?@\"NSArray\"@\"NSError\">16";

typedef id (*IXCopyFn)(id, SEL, NSInteger, id, NSUInteger, id, id, id, id, id);
typedef id (*IXInitFn)(id, SEL, NSInteger, NSInteger, id, id, double, double, double, NSUInteger, double, id, BOOL, double, NSInteger, double, BOOL, id, id, id, id, id, id);
typedef id (*IXIdFn)(id, SEL);
typedef NSInteger (*IXIntFn)(id, SEL);
typedef void (*IXFormatsFn)(id, SEL, id);

static NSArray<NSString *> *IXFontNames(void) {
    return @[
        @"AbarMidNoEn-ExtraBlack",
        @"Pelak-SemiBold",
        @"AbarLow-Black",
        @"YekanBakh-Bold"
    ];
}

static BOOL IXIsOurLoggingName(NSString *name) {
    return [IXFontNames() containsObject:name ?: @""];
}

static BOOL IXIsOurFont(UIFont *font) {
    if (![font isKindOfClass:[UIFont class]]) return NO;
    return IXIsOurLoggingName(font.fontName);
}

static Class IXFormatClass(void) {
    return objc_getClass("IGRichTextFormat");
}

static id IXIvarObject(id obj, const char *name) {
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return nil;
    return object_getIvar(obj, ivar);
}

static void IXSetIvarObject(id obj, const char *name, id value) {
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) return;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return;
    object_setIvar(obj, ivar, value);
}

static NSUInteger IXReadUIntIvar(id obj, const char *name) {
    Ivar ivar = class_getInstanceVariable([obj class], name);
    if (!ivar) return 0;
    return *(NSUInteger *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(ivar));
}

static void IXRegisterFonts(void) {
    NSBundle *bundle = SCILocalizationBundle();
    NSString *dir = [bundle.bundlePath stringByAppendingPathComponent:@"Fonts"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in files) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"ttf"] && ![ext isEqualToString:@"otf"]) continue;
        NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error) && error) {
            CFRelease(error);
        }
    }
}

static UIFont *IXFont(NSString *postScript, CGFloat size) {
    if (size < 8) size = 24;
    return [UIFont fontWithName:postScript size:size];
}

static id IXMakeFormat(id template, UIFont *font, NSString *loggingName, NSArray *scripts) {
    if (!font) return nil;
    Class formatClass = IXFormatClass();
    id made = nil;
    if (template && formatClass && [template isKindOfClass:formatClass]) {
        NSInteger animation = ((IXIntFn)objc_msgSend)(template, @selector(animationType));
        NSUInteger alignment = IXReadUIntIvar(template, "_defaultAlignment");
        id emphasis = IXIvarObject(template, "_textV2Emphasis");
        id secondary = IXIvarObject(template, "_textV2SecondaryEmphasis");
        id categories = ((IXIdFn)objc_msgSend)(template, @selector(categories));
        IXCopyFn copyFn = (IXCopyFn)objc_msgSend;
        made = copyFn(template, sel_registerName(kIXCopySel), animation, font, alignment, emphasis, secondary, IXPreviewText, categories, scripts);
    } else if (formatClass) {
        id allocated = ((IXIdFn)objc_msgSend)(formatClass, @selector(alloc));
        IXInitFn initFn = (IXInitFn)objc_msgSend;
        made = initFn(allocated, sel_registerName(kIXInitSel),
                      0, 0, IXPreviewText, font,
                      12.0, 64.0, 1.0, 0, 1.0,
                      loggingName, NO, 0.0, 0, 0.0, NO,
                      nil, nil, IXPreviewText, nil, scripts, nil);
    }
    if (!made) return nil;
    IXSetIvarObject(made, "_loggingName", loggingName);
    IXSetIvarObject(made, "_displayName", IXPreviewText);
    IXSetIvarObject(made, "_accessibilityDescriptor", IXPreviewText);
    return made;
}

static NSArray *IXScriptUnion(NSArray *original, id template) {
    NSMutableOrderedSet *scripts = [NSMutableOrderedSet orderedSet];
    Class formatClass = IXFormatClass();
    for (id item in original) {
        if (!formatClass || ![item isKindOfClass:formatClass]) continue;
        id value = ((IXIdFn)objc_msgSend)(item, @selector(supportedScripts));
        if ([value isKindOfClass:[NSArray class]]) [scripts addObjectsFromArray:value];
    }
    if (scripts.count) return scripts.array;
    if (template) {
        id value = ((IXIdFn)objc_msgSend)(template, @selector(supportedScripts));
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    return nil;
}

static NSArray *IXMergeFormats(NSArray *original) {
    if (original && ![original isKindOfClass:[NSArray class]]) return original;
    @try {
    Class formatClass = IXFormatClass();
    id template = nil;
    CGFloat pointSize = 24;
    for (id item in original) {
        if (formatClass && [item isKindOfClass:formatClass]) {
            template = item;
            UIFont *existing = ((IXIdFn)objc_msgSend)(item, @selector(font));
            if ([existing isKindOfClass:[UIFont class]] && existing.pointSize > 0) pointSize = existing.pointSize;
            break;
        }
    }
    NSArray *scripts = IXScriptUnion(original, template);
    NSMutableArray *leading = [NSMutableArray array];
    for (NSString *name in IXFontNames()) {
        id made = IXMakeFormat(template, IXFont(name, pointSize), name, scripts);
        if (made) [leading addObject:made];
    }
    if (!leading.count) return original;

    NSMutableArray *rest = [NSMutableArray array];
    for (id item in original) {
        if (formatClass && [item isKindOfClass:formatClass] && [item respondsToSelector:@selector(loggingName)]) {
            id logging = ((IXIdFn)objc_msgSend)(item, @selector(loggingName));
            if ([logging isKindOfClass:[NSString class]] && IXIsOurLoggingName(logging)) continue;
        }
        [rest addObject:item];
    }
    [leading addObjectsFromArray:rest];
    // Never rewrite a list Instagram still owns. Callers keep their array.
    return [leading copy];
    } @catch (__unused NSException *exception) {
        return original;
    }
}

static NSArray *IXMergePresets(NSArray *original) {
    if (![original isKindOfClass:[NSArray class]] || original.count == 0) return original;
    id first = original.firstObject;
    Class formatClass = IXFormatClass();
    if (formatClass && [first isKindOfClass:formatClass]) return IXMergeFormats(original);
    if ([first isKindOfClass:[NSString class]]) {
        NSMutableArray *merged = [IXFontNames() mutableCopy];
        for (id item in original) {
            if (![merged containsObject:item]) [merged addObject:item];
        }
        return merged;
    }
    if ([first isKindOfClass:[UIFont class]]) {
        CGFloat size = ((UIFont *)first).pointSize > 0 ? ((UIFont *)first).pointSize : 18;
        NSMutableArray *merged = [NSMutableArray array];
        for (NSString *name in IXFontNames()) {
            UIFont *font = IXFont(name, size);
            if (font) [merged addObject:font];
        }
        for (UIFont *font in original) {
            if (![font isKindOfClass:[UIFont class]] || !IXIsOurFont(font)) [merged addObject:font];
        }
        return merged;
    }
    return original;
}

static BOOL ixPreviewing = NO;

static BOOL IXInFontPicker(UIView *view) {
    UIView *current = view;
    for (int i = 0; current && i < 10; i++) {
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"FontCell"] || [name containsString:@"FontPicker"] ||
            [name containsString:@"FontSelector"] || [name containsString:@"IGTextStyleToolFont"] ||
            [name containsString:@"fontSelector"]) {
            return YES;
        }
        current = current.superview;
    }
    return NO;
}

static void IXStylePreview(UILabel *label) {
    label.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    label.textAlignment = NSTextAlignmentRight;
}

static void IXWrapGetTextFormats(void) {
    SEL selector = sel_registerName(kIXGetFormatsSel);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Method method = class_getInstanceMethod(classes[i], selector);
        if (!method) continue;
        const char *types = method_getTypeEncoding(method);
        if (!types || strcmp(types, kIXGetFormatsTypes) != 0) continue;
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(id selfObject, id completion) {
            IXFormatsFn call = (IXFormatsFn)original;
            if (!completion) {
                call(selfObject, selector, nil);
                return;
            }
            id wrapped = [^void(NSArray *formats, NSError *error) {
                NSArray *merged = [formats isKindOfClass:[NSArray class]] ? IXMergeFormats(formats) : formats;
                ((void (^)(NSArray *, NSError *))completion)(merged, error);
            } copy];
            call(selfObject, selector, wrapped);
        });
        method_setImplementation(method, replacement);
        NSLog(@"[InstagramX] hooked %@ %@", NSStringFromClass(classes[i]), NSStringFromSelector(selector));
    }
    free(classes);
}

%hook IGStoryTextEntryViewControllerConfiguration
- (void)setTextFormats:(NSArray *)formats {
    %orig([formats isKindOfClass:[NSArray class]] ? IXMergeFormats(formats) : formats);
}
- (NSArray *)textFormats {
    id formats = %orig;
    return [formats isKindOfClass:[NSArray class]] ? IXMergeFormats(formats) : formats;
}
+ (id)postcaptureTextFormatsWithEntryPoint:(NSInteger)entryPoint userSession:(id)userSession {
    id formats = %orig;
    return [formats isKindOfClass:[NSArray class]] ? IXMergeFormats(formats) : formats;
}
%end

%hook IGStoryTextEntryControlsOverlayView
- (void)setFontPresets:(NSArray *)presets {
    %orig(IXMergePresets(presets));
}
- (NSArray *)fontPresets {
    id presets = %orig;
    return [presets isKindOfClass:[NSArray class]] ? IXMergePresets(presets) : presets;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (!ixPreviewing && self.font.pointSize > 0 && self.font.pointSize <= 32 && IXIsOurFont(self.font) && IXInFontPicker(self)) {
        ixPreviewing = YES;
        %orig(IXPreviewText);
        IXStylePreview(self);
        ixPreviewing = NO;
        return;
    }
    %orig;
}

- (void)setFont:(UIFont *)font {
    %orig;
    if (!ixPreviewing && font.pointSize > 0 && font.pointSize <= 32 && IXIsOurFont(font) && IXInFontPicker(self) && self.text.length > 0 && ![self.text isEqualToString:IXPreviewText]) {
        ixPreviewing = YES;
        self.text = IXPreviewText;
        IXStylePreview(self);
        ixPreviewing = NO;
    }
}
%end

%ctor {
    IXRegisterFonts();
    IXWrapGetTextFormats();
}
