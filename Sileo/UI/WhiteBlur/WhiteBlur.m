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
// one: it stays translucent whatever the app does to its own blurs. Anything
// inside the menu's own hierarchy is left alone, so the wash below never
// reaches it.
static BOOL ApelinInsideContextMenu(UIView *view) {
    Class menuView = NSClassFromString(@"_UIContextMenuView");
    Class listView = NSClassFromString(@"_UIContextMenuListView");
    for (UIView *search = view; search; search = search.superview) {
        if ((menuView && [search isKindOfClass:menuView]) ||
            (listView && [search isKindOfClass:listView])) {
            return YES;
        }
    }
    return NO;
}

// What the system asked for before the wash replaced it. A menu's backdrop is
// often configured before it is put into the menu, so the check above can miss
// it there; the originals let it be put right once it arrives.
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

// A menu's backdrop is often configured before it is put into the menu, so the
// check above can miss it; once it has arrived, ask for what the system
// originally wanted.
static void ApelinRestoreMenuMaterial(UIView *view) {
    if (@available(iOS 13, *)) {
        if (![view isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) return;
        if (!ApelinInsideContextMenu(view)) return;
        NSArray *filters = objc_getAssociatedObject(view, &ApelinOriginalFiltersKey);
        if (filters) [(id)view setFilters:filters];
        id background = objc_getAssociatedObject(view, &ApelinOriginalBackgroundKey);
        if (background) {
            [(id)view setBackgroundColor:[background isKindOfClass:[NSNull class]] ? nil : background];
        }
    }
}

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
            // The menu may only take this view into its hierarchy after this
            // call; look again once the run loop has let that happen.
            __weak UIView *weakView = (UIView *)self;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *view = weakView;
                if (view) ApelinRestoreMenuMaterial(view);
            });
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

// A menu's backdrop that was washed before it reached the menu: once it is in
// the menu, ask for what the system originally wanted.
endhook
