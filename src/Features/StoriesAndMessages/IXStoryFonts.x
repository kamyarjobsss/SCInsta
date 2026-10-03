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

static NSInteger IXFormatType(id format) {
    if (![format respondsToSelector:@selector(type)]) return NSNotFound;
    return ((IXIntFn)objc_msgSend)(format, @selector(type));
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

// The story editor is main-thread only. These remember the chip the user
// scrolled to, so a nested type-equality scan cannot replace it.
static int ixFontDepth;
static int ixRestoring;
static NSInteger ixFontItem = NSNotFound;
static NSInteger ixFontSection;
static NSInteger ixFontType = NSNotFound;
static NSString *ixFontName;

static void IXRememberFont(NSIndexPath *path, id format) {
    ixFontItem = path.item;
    ixFontSection = path.section;
    ixFontType = IXFormatType(format);
    NSString *name = IXLoggingName(format);
    ixFontName = name.length ? [name copy] : nil;
}

static void IXRestoreChip(id selector, NSIndexPath *path) {
    if (ixRestoring || !selector || ![path isKindOfClass:[NSIndexPath class]]) return;
    ixRestoring = 1;
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(selector), "_selectedIndexPath");
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') object_setIvar(selector, ivar, path);
        }
        UICollectionView *collection = IXIvarObject(selector, "_collectionView");
        if (![collection isKindOfClass:[UICollectionView class]]) return;
        if (path.section >= [collection numberOfSections]) return;
        if (path.item >= [collection numberOfItemsInSection:path.section]) return;
        [collection selectItemAtIndexPath:path animated:NO scrollPosition:UICollectionViewScrollPositionNone];
    } @catch (__unused NSException *exception) {}
    ixRestoring = 0;
}

static BOOL IXIsTypeSnap(id overlay, NSIndexPath *path, id format) {
    if (ixFontItem == NSNotFound || !ixFontName.length || !format || ![path isKindOfClass:[NSIndexPath class]]) return NO;
    NSString *name = IXLoggingName(format);
    if (!name.length || [name isEqualToString:ixFontName]) return NO;
    if (IXFormatType(format) != ixFontType) return NO;
    NSArray *formats = IXIvarObject(overlay, "_textFormats");
    if (![formats isKindOfClass:[NSArray class]]) return NO;
    NSUInteger first = NSNotFound;
    for (NSUInteger i = 0; i < formats.count; i++) {
        if (IXFormatType(formats[i]) == ixFontType) {
            first = i;
            break;
        }
    }
    return first == path.item && ixFontItem != (NSInteger)first;
}

// YES means the caller should run %orig. A nested change onto a different
// logging name is the type-collision snap and is dropped.
static BOOL IXBeginSelection(id overlay, id selector, NSIndexPath *path, BOOL userDriven) {
    if (ixRestoring) return NO;
    id format = IXFormatAt(overlay, path);
    BOOL nestedClash = NO;
    if (ixFontDepth > 0 && format) {
        NSString *name = IXLoggingName(format);
        if (ixFontName.length && name.length && ![name isEqualToString:ixFontName]) nestedClash = YES;
    }
    if (nestedClash || (!userDriven && IXIsTypeSnap(overlay, path, format))) {
        if (ixFontItem != NSNotFound) {
            IXRestoreChip(selector, [NSIndexPath indexPathForItem:ixFontItem inSection:ixFontSection]);
        }
        return NO;
    }
    if (ixFontDepth == 0 && format && [path isKindOfClass:[NSIndexPath class]]) IXRememberFont(path, format);
    ixFontDepth++;
    return YES;
}

static void IXEndSelection(id selector) {
    if (ixFontDepth > 0) ixFontDepth--;
    if (ixFontDepth == 0 && ixFontItem != NSNotFound) {
        IXRestoreChip(selector, [NSIndexPath indexPathForItem:ixFontItem inSection:ixFontSection]);
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

static id IXFindSelector(UIView *view, int depth) {
    Class cls = objc_getClass("IGScrollingSelectorView");
    if (!cls || ![view isKindOfClass:[UIView class]] || depth > 6) return nil;
    if ([view isKindOfClass:cls]) return view;
    for (UIView *sub in view.subviews) {
        id found = IXFindSelector(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static id IXSelectorFromOverlay(id overlay) {
    Class cls = objc_getClass("IGScrollingSelectorView");
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([overlay class], &count);
    id found = nil;
    for (unsigned int i = 0; ivars && i < count; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        id value = object_getIvar(overlay, ivars[i]);
        if (cls && [value isKindOfClass:cls]) {
            found = value;
            break;
        }
    }
    free(ivars);
    if (!found && [overlay isKindOfClass:[UIView class]]) found = IXFindSelector(overlay, 0);
    return found;
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
        ixFontSection = 0;
        ixFontType = NSNotFound;
        ixFontName = nil;
        ixFontDepth = 0;
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
    if (![indexPath isKindOfClass:[NSIndexPath class]]) {
        %orig;
        return;
    }
    if (!IXBeginSelection(self, selector, indexPath, fromUser)) return;
    %orig;
    IXEndSelection(selector);
}
- (void)scrollingSelectorView:(id)selector didEndScrollingAtIndexPath:(NSIndexPath *)indexPath {
    if (![indexPath isKindOfClass:[NSIndexPath class]]) {
        %orig;
        return;
    }
    if (!IXBeginSelection(self, selector, indexPath, YES)) return;
    %orig;
    IXEndSelection(selector);
}
- (void)scrollingSelectorView:(id)selector didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (![indexPath isKindOfClass:[NSIndexPath class]]) {
        %orig;
        return;
    }
    if (!IXBeginSelection(self, selector, indexPath, YES)) return;
    %orig;
    IXEndSelection(selector);
}
- (void)setRichTextEntryModel:(id)model animated:(BOOL)animated {
    if (ixRestoring) return;
    id format = IXModelFormat(model);
    NSString *name = IXLoggingName(format);
    if (ixFontDepth > 0 && ixFontName.length && name.length && ![name isEqualToString:ixFontName]) return;
    BOOL outer = ixFontDepth == 0;
    if (outer && format) {
        NSArray *formats = IXIvarObject(self, "_textFormats");
        NSUInteger idx = [formats isKindOfClass:[NSArray class]] ? [formats indexOfObjectIdenticalTo:format] : NSNotFound;
        if (idx == NSNotFound && [formats isKindOfClass:[NSArray class]] && name.length) {
            for (NSUInteger i = 0; i < formats.count; i++) {
                if ([IXLoggingName(formats[i]) isEqualToString:name]) {
                    idx = i;
                    break;
                }
            }
        }
        if (idx != NSNotFound) {
            ixFontItem = (NSInteger)idx;
            ixFontSection = 0;
            ixFontType = IXFormatType(format);
            ixFontName = [name copy];
        }
    }
    ixFontDepth++;
    %orig;
    ixFontDepth--;
    if (outer && ixFontItem != NSNotFound) {
        IXRestoreChip(IXSelectorFromOverlay(self), [NSIndexPath indexPathForItem:ixFontItem inSection:ixFontSection]);
    }
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
%end

%ctor {
    %init;
    IXRegisterFonts();
    IXWrapGetTextFormats();
}
