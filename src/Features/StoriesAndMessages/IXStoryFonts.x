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
// Preview chips use displayName. Ours is وکسپید.
//
// The chip strip is IGScrollingSelectorView (collection view + custom layout),
// data source IGStoryTextEntryControlsOverlayView. numberOfItems and
// itemAtIndexPath read the overlay ivar _textFormats (offset 264) directly.
//
// Tapping a chip builds a model from that format, then
// setRichTextEntryModel:animated: does indexOfObjectPassingTest: and keeps the
// first format whose -type matches. -type is the q ivar at offset 24
// (ldr [self, #0x18]). A made-up type is not a Swift enum case: reading it
// while the story text tool opens traps (swift_unknownEnum / fatalError) and
// the process dies with no crash report. Copies keep the template's real
// type and are inserted first, so the first match is ours. Nothing here
// writes _type or applies a format from layoutSubviews.

static NSString *const IXPreviewText = @"وکسپید";

static const char *kIXCopySel =
    "_copyWithAnimationType:font:defaultAlignment:textV2Emphasis:textV2SecondaryEmphasis:displayName:categories:supportedScripts:";
static const char *kIXGetFormatsSel = "getTextFormatsWithCompletionHandler:";
static const char *kIXGetFormatsTypes = "v24@0:8@?<v@?@\"NSArray\"@\"NSError\">16";

typedef id (*IXCopyFn)(id, SEL, NSInteger, id, NSUInteger, id, id, id, id, id);
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
    if (!font || !template) return nil;
    Class formatClass = IXFormatClass();
    if (!formatClass || ![template isKindOfClass:formatClass]) return nil;
    if (![template respondsToSelector:sel_registerName(kIXCopySel)]) return nil;
    NSInteger animation = ((IXIntFn)objc_msgSend)(template, @selector(animationType));
    NSUInteger alignment = IXReadUIntIvar(template, "_defaultAlignment");
    id emphasis = IXIvarObject(template, "_textV2Emphasis");
    id secondary = IXIvarObject(template, "_textV2SecondaryEmphasis");
    id categories = ((IXIdFn)objc_msgSend)(template, @selector(categories));
    IXCopyFn copyFn = (IXCopyFn)objc_msgSend;
    id made = copyFn(template, sel_registerName(kIXCopySel), animation, font, alignment, emphasis, secondary, IXPreviewText, categories, scripts);
    if (!made) return nil;
    IXSetIvarObject(made, "_font", font);
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
    NSMutableArray *templates = [NSMutableArray array];
    for (id item in original) {
        if (formatClass && [item isKindOfClass:formatClass]) [templates addObject:item];
    }
    NSArray *scripts = IXScriptUnion(original, template);
    NSMutableArray *leading = [NSMutableArray array];
    NSUInteger slot = 0;
    for (NSString *name in IXFontNames()) {
        id source = templates.count ? templates[slot % templates.count] : template;
        id made = IXMakeFormat(source, IXFont(name, pointSize), name, scripts);
        if (made) [leading addObject:made];
        slot++;
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
    NSMutableArray *merged = [leading mutableCopy];
    [merged addObjectsFromArray:rest];
    return [merged copy];
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
        NSMutableArray *merged = [NSMutableArray array];
        for (NSString *name in IXFontNames()) {
            if (![merged containsObject:name]) [merged addObject:name];
        }
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

static BOOL IXFormatsIncludeOurs(NSArray *formats) {
    Class formatClass = IXFormatClass();
    for (id item in formats) {
        if (!formatClass || ![item isKindOfClass:formatClass] || ![item respondsToSelector:@selector(loggingName)]) continue;
        id logging = ((IXIdFn)objc_msgSend)(item, @selector(loggingName));
        if ([logging isKindOfClass:[NSString class]] && IXIsOurLoggingName(logging)) return YES;
    }
    return NO;
}

static char IXFontMergedKey;
static char IXFontScrolledKey;

static void IXScrollLeadingFont(UICollectionView *collection) {
    if (![collection isKindOfClass:[UICollectionView class]]) return;
    if (objc_getAssociatedObject(collection, &IXFontScrolledKey)) return;
    objc_setAssociatedObject(collection, &IXFontScrolledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UICollectionView *weakCollection = collection;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionView *view = weakCollection;
        if (![view isKindOfClass:[UICollectionView class]]) return;
        @try {
            [view reloadData];
            if ([view numberOfSections] > 0 && [view numberOfItemsInSection:0] > 0) {
                [view scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0] atScrollPosition:UICollectionViewScrollPositionLeft animated:NO];
            }
        } @catch (__unused NSException *exception) {}
    });
}

static void IXRevealFontsOnSelector(id selector) {
    Class overlayClass = objc_getClass("IGStoryTextEntryControlsOverlayView");
    id dataSource = IXIvarObject(selector, "_dataSource");
    if (!overlayClass || ![dataSource isKindOfClass:overlayClass]) return;
    if (!objc_getAssociatedObject(selector, &IXFontMergedKey)) {
        NSArray *formats = IXIvarObject(dataSource, "_textFormats");
        if (![formats isKindOfClass:[NSArray class]] || formats.count == 0) return;
        NSArray *merged = IXMergeFormats(formats);
        if (![merged isKindOfClass:[NSArray class]] || !IXFormatsIncludeOurs(merged)) return;
        UICollectionView *collection = IXIvarObject(selector, "_collectionView");
        if (![collection isKindOfClass:[UICollectionView class]]) return;
        if (merged != formats) IXSetIvarObject(dataSource, "_textFormats", merged);
        objc_setAssociatedObject(selector, &IXFontMergedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IXScrollLeadingFont(collection);
    }
}

%hook IGScrollingSelectorView
- (void)layoutSubviews {
    %orig;
    IXRevealFontsOnSelector(self);
}
%end

%ctor {
    %init;
    IXRegisterFonts();
    IXWrapGetTextFormats();
}
