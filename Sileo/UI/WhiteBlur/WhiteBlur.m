//
//  WhiteBlur.m
//  Supercharge
//
//  Created by Kabir Oberai on 28/01/18.
//  Copyright © 2018 Kabir Oberai. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ZKSwizzle.h"
#import "WhiteBlur.h"
#import "Sileo-Swift.h"

@interface _UIVisualEffectFilterEntry : NSObject
- (NSString *)filterName;
@end

// A system menu brings its own material, and that is the whole point of using
// one: it stays translucent whatever the app does to its own blurs. A backdrop
// inside the menu's hierarchy is left alone, so the wash never reaches it.
static BOOL ApelinInsideContextMenu(UIView *view) {
    for (UIView *search = view; search; search = search.superview) {
        if ([NSStringFromClass([search class]) containsString:@"ContextMenu"]) {
            return YES;
        }
    }
    return NO;
}

// What the system asked for before the wash replaced it. A menu's backdrop is
// often configured before it is put into the menu, so the check above can miss
// it; the originals put it right once it arrives (see didMoveToWindow).
static char ApelinOriginalFiltersKey;
static char ApelinOriginalBackgroundKey;

static void ApelinRemember(id object, void *key, id value) {
    if (value && !objc_getAssociatedObject(object, key)) {
        objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@interface NSObject (ApelinVisualEffect)
- (void)setFilters:(NSArray *)filters;
@end

// A menu's own separators: iOS 16 draws one wherever it starts a new section,
// and these menus are a single section, so every line here is unwanted. They
// hide themselves rather than being removed, so the menu's layout stays as the
// system arranged it.
hook(_UIContextMenuSeparatorView)

- (void)layoutSubviews {
    _orig(void);
    [(UIView *)self setHidden:YES];
}

- (void)didMoveToWindow {
    _orig(void);
    [(UIView *)self setHidden:YES];
}

endhook

// What the menu is actually made of, written where a look from outside can
// reach it: which view carries the material, and whether the wash reached it.
static void ApelinDumpView(UIView *view, int depth, NSMutableString *out) {
    if (depth > 10) return;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@\n",
     indent,
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha,
     view.hidden,
     view.backgroundColor];
    for (UIView *subview in view.subviews) {
        ApelinDumpView(subview, depth + 1, out);
    }
}

static void ApelinAppendMenuDump(NSString *text) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"apelin_menu_dump.txt"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
            return;
        }
    }
    [data writeToFile:path atomically:YES];
}

hook(_UIContextMenuView)

- (void)layoutSubviews {
    _orig(void);
    UIView *menu = (UIView *)self;
    if (!menu.window) return;
    static char dumpedKey;
    if (objc_getAssociatedObject(self, &dumpedKey)) return;
    objc_setAssociatedObject(self, &dumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableString *out = [NSMutableString string];
    ApelinDumpView(menu, 0, out);
    ApelinAppendMenuDump([NSString stringWithFormat:@"\n=== menu at %@ ===\n%@", [NSDate date], out]);
}

endhook

hook(_UIVisualEffectSubview)

- (void)setFilters:(NSArray *)filters {
    if (@available(iOS 13, *)){
        if ([self isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
            ApelinRemember(self, &ApelinOriginalFiltersKey, filters);
            // A glass blur keeps the system's own material: no wash, no filters
            // taken away, so what is behind it really shows through.
            for (UIView *search = (UIView *)self; search; search = search.superview) {
                if (search.tag == GLASS_BLUR_TAG) {
                    _orig(void, filters);
                    return;
                }
            }
            if (ApelinInsideContextMenu((UIView *)self)) {
                ApelinAppendMenuDump([NSString stringWithFormat:@"[kept the system's material] %@\n", NSStringFromClass([self class])]);
                _orig(void, filters);
                return;
            }
            NSMutableArray *filtersMutable = [filters mutableCopy];
            for (_UIVisualEffectFilterEntry *filter in filters){
                if ([[filter filterName] isEqualToString:@"luminanceCurveMap"] ||
                    [[filter filterName] isEqualToString:@"colorBrightness"]){
                    [filtersMutable removeObject:filter];
                }
            }
            _orig(void, filtersMutable);
            UIColor *backgroundColor = nil;
            if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 0) {
                backgroundColor = [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.85];
            } else if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 1) {
               backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
            } else {
               if (@available(iOS 13.0, *)) {
                   if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                       backgroundColor = [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.85];
                   } else {
                       backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
                   }
               } else {
                   backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
               }
            }
            [self setBackgroundColor:backgroundColor];
        } else {
            _orig(void, filters);
        }
    } else {
        _orig(void, filters);
    }
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (@available(iOS 13, *)){
        if ([self isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
            ApelinRemember(self, &ApelinOriginalBackgroundKey, backgroundColor ?: [NSNull null]);
        }
    } else {
        // don't hook the blur applying view itself, only the view in front of it
        if (![self isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
            // if any superview has WHITE_BLUR_TAG as its tag, make the UIVisualEffectView pure white rather than 97%
            for (UIView *search = (UIView *)self; search; search = search.superview) {
                if (search.tag == WHITE_BLUR_TAG) {
                    if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 0) {
                        backgroundColor = [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.85];
                    } else if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 1) {
                        backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
                    } else {
                        if (@available(iOS 13.0, *)) {
                            if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                                backgroundColor = [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.85];
                            } else {
                                backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
                            }
                        } else {
                            backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
                        }
                    }
                }
            }
        }
    }
    _orig(void, backgroundColor);
}

// A menu's backdrop that was washed before the menu took it in: once it is in
// the menu, ask for what the system originally wanted.
- (void)didMoveToWindow {
    _orig(void);
    if (@available(iOS 13, *)) {
        UIView *view = (UIView *)self;
        if (![view isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) return;
        if (!ApelinInsideContextMenu(view)) return;
        NSArray *filters = objc_getAssociatedObject(self, &ApelinOriginalFiltersKey);
        if (filters) [self setFilters:filters];
        id background = objc_getAssociatedObject(self, &ApelinOriginalBackgroundKey);
        if (background) {
            [self setBackgroundColor:[background isKindOfClass:[NSNull class]] ? nil : background];
        }
    }
}

endhook
