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
// type. The first match would be our copy, so a later stock font of that
// type would snap back. Selection hooks keep the chip the user actually
// landed on, and cell configuration resets reused previews.
// Nothing here writes _type or applies a format from layoutSubviews.

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
static char IXFontReloadedKey;

static NSString *IXLoggingName(id format) {
    if (![format respondsToSelector:@selector(loggingName)]) return nil;
    id logging = ((IXIdFn)objc_msgSend)(format, @selector(loggingName));
    return [logging isKindOfClass:[NSString class]] ? logging : nil;
}

static NSString *IXDisplayName(id format) {
    if (![format respondsToSelector:@selector(displayName)]) return nil;
    id name = ((IXIdFn)objc_msgSend)(format, @selector(displayName));
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

static UIFont *IXFormatFont(id format) {
    if (![format respondsToSelector:@selector(font)]) return nil;
    id font = ((IXIdFn)objc_msgSend)(format, @selector(font));
    return [font isKindOfClass:[UIFont class]] ? font : nil;
}

static id IXFormatAt(id overlay, NSIndexPath *path) {
    if (![path isKindOfClass:[NSIndexPath class]]) return nil;
    NSArray *formats = IXIvarObject(overlay, "_textFormats");
    if (![formats isKindOfClass:[NSArray class]]) return nil;
    NSUInteger idx = path.item;
    if (idx >= formats.count) return nil;
    return formats[idx];
}

// setRichTextEntryModel:animated: picks the first format whose -type matches.
// Our four copies sit in front of Instagram's fonts and share those types, so
// the search used to land on chip 0. While that method runs, the search
// returns the chip the user actually selected.
static NSInteger ixFontItem = NSNotFound;
static NSArray *ixFormatArray;
static NSUInteger (*ixOrigPassingTest)(id, SEL, id);

static NSUInteger IXIndexOfPassingTest(id self, SEL _cmd, id block) {
    NSArray *formats = ixFormatArray;
    NSInteger wanted = ixFontItem;
    BOOL same = formats && self == formats;
    if (!same && formats && wanted >= 0 && [self isKindOfClass:[NSArray class]] && (NSUInteger)wanted < formats.count && (NSUInteger)wanted < [(NSArray *)self count]) {
        id item = nil;
        @try { item = [(NSArray *)self objectAtIndex:(NSUInteger)wanted]; }
        @catch (__unused NSException *exception) { item = nil; }
        same = item && item == formats[(NSUInteger)wanted];
    }
    if (same && wanted >= 0 && (NSUInteger)wanted < formats.count && block) {
        BOOL (^test)(id, NSUInteger, BOOL *) = block;
        BOOL stop = NO;
        @try {
            if (test(formats[(NSUInteger)wanted], (NSUInteger)wanted, &stop)) return (NSUInteger)wanted;
        } @catch (__unused NSException *exception) {}
    }
    return ixOrigPassingTest(self, _cmd, block);
}

static void IXInstallFormatIndexHook(void) {
    SEL selector = @selector(indexOfObjectPassingTest:);
    for (NSString *name in @[@"NSArray", @"__NSArrayI", @"__NSArrayM", @"__NSSingleObjectArrayI", @"__NSFrozenArrayM"]) {
        Class cls = NSClassFromString(name);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method) continue;
        IMP current = method_getImplementation(method);
        if (current == (IMP)IXIndexOfPassingTest) continue;
        if (!ixOrigPassingTest) ixOrigPassingTest = (NSUInteger (*)(id, SEL, id))current;
        method_setImplementation(method, (IMP)IXIndexOfPassingTest);
    }
}

static id IXModelFormat(id model) {
    if (!model) return nil;
    Class formatClass = IXFormatClass();
    for (NSString *key in @[@"textFormat", @"format", @"richTextFormat"]) {
        id value = nil;
        @try { value = [model valueForKey:key]; }
        @catch (__unused NSException *exception) { value = nil; }
        if (formatClass && [value isKindOfClass:formatClass]) return value;
    }
    return nil;
}

static void IXApplyChipLabel(UILabel *label, id format) {
    NSString *logging = IXLoggingName(format);
    CGFloat size = label.font.pointSize > 0 ? label.font.pointSize : 18;
    if (IXIsOurLoggingName(logging)) {
        label.text = IXPreviewText;
        UIFont *font = IXFont(logging, size);
        if (font) label.font = font;
        return;
    }
    NSString *display = IXDisplayName(format);
    if (display.length) label.text = display;
    UIFont *font = IXFormatFont(format);
    if (font) label.font = [font fontWithSize:size];
}

static void IXStyleChipTree(UIView *view, id format) {
    if ([view isKindOfClass:[UILabel class]]) IXApplyChipLabel((UILabel *)view, format);
    for (UIView *sub in view.subviews) IXStyleChipTree(sub, format);
}

static id IXFormatForSelector(id selector, NSIndexPath *path) {
    Class overlayClass = objc_getClass("IGStoryTextEntryControlsOverlayView");
    id dataSource = IXIvarObject(selector, "_dataSource");
    if (!overlayClass || ![dataSource isKindOfClass:overlayClass]) return nil;
    return IXFormatAt(dataSource, path);
}

static void IXReloadFormatsOnce(UICollectionView *collection) {
    if (![collection isKindOfClass:[UICollectionView class]]) return;
    if (objc_getAssociatedObject(collection, &IXFontReloadedKey)) return;
    objc_setAssociatedObject(collection, &IXFontReloadedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UICollectionView *weakCollection = collection;
    dispatch_async(dispatch_get_main_queue(), ^{
        UICollectionView *view = weakCollection;
        if (![view isKindOfClass:[UICollectionView class]]) return;
        @try { [view reloadData]; }
        @catch (__unused NSException *exception) {}
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
        ixFontItem = NSNotFound;
        ixFormatArray = nil;
        UICollectionView *collection = IXIvarObject(selector, "_collectionView");
        if (![collection isKindOfClass:[UICollectionView class]]) return;
        if (merged != formats) IXSetIvarObject(dataSource, "_textFormats", merged);
        objc_setAssociatedObject(selector, &IXFontMergedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        IXReloadFormatsOnce(collection);
    }
}

%hook IGStoryTextEntryControlsOverlayView
- (void)setFontPresets:(NSArray *)presets {
    %orig(IXMergePresets(presets));
}
- (NSArray *)fontPresets {
    id presets = %orig;
    return [presets isKindOfClass:[NSArray class]] ? IXMergePresets(presets) : presets;
}
- (void)scrollingSelectorView:(id)selector didChangeSelectedIndexPath:(NSIndexPath *)indexPath fromUserAction:(BOOL)fromUser {
    if (fromUser && [indexPath isKindOfClass:[NSIndexPath class]]) ixFontItem = indexPath.item;
    %orig;
}
- (void)scrollingSelectorView:(id)selector didEndScrollingAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isKindOfClass:[NSIndexPath class]]) ixFontItem = indexPath.item;
    %orig;
}
- (void)scrollingSelectorView:(id)selector didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isKindOfClass:[NSIndexPath class]]) ixFontItem = indexPath.item;
    %orig;
}
- (void)setRichTextEntryModel:(id)model animated:(BOOL)animated {
    NSArray *formats = IXIvarObject(self, "_textFormats");
    id format = IXModelFormat(model);
    if ([formats isKindOfClass:[NSArray class]] && format) {
        NSUInteger identical = [formats indexOfObjectIdenticalTo:format];
        if (identical != NSNotFound) {
            ixFontItem = (NSInteger)identical;
        } else {
            NSString *name = IXLoggingName(format);
            BOOL userHasName = ixFontItem >= 0 && ixFontItem < (NSInteger)formats.count && name.length && [IXLoggingName(formats[(NSUInteger)ixFontItem]) isEqualToString:name];
            if (!userHasName && name.length) {
                for (NSUInteger i = 0; i < formats.count; i++) {
                    if ([IXLoggingName(formats[i]) isEqualToString:name]) {
                        ixFontItem = (NSInteger)i;
                        break;
                    }
                }
            }
        }
    }
    ixFormatArray = [formats isKindOfClass:[NSArray class]] ? formats : nil;
    %orig;
    ixFormatArray = nil;
}
%end

%hook IGScrollingSelectorView
- (void)layoutSubviews {
    %orig;
    IXRevealFontsOnSelector(self);
}
- (id)collectionView:(id)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    id cell = %orig;
    id format = IXFormatForSelector(self, indexPath);
    if (format && [cell isKindOfClass:[UIView class]]) IXStyleChipTree(cell, format);
    return cell;
}
- (void)collectionView:(id)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    id format = IXFormatForSelector(self, indexPath);
    if (format && [cell isKindOfClass:[UIView class]]) IXStyleChipTree(cell, format);
}
- (void)collectionView:(id)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath isKindOfClass:[NSIndexPath class]]) ixFontItem = indexPath.item;
    %orig;
}
%end

%ctor {
    %init;
    IXRegisterFonts();
    IXWrapGetTextFormats();
    IXInstallFormatIndexHook();
}
