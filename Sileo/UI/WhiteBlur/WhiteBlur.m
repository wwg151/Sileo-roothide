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

// What the system asked for before the wash replaced it. The backdrop of a menu
// is usually configured before the menu takes it in, so the check above misses
// it there; what it had is kept here and put back once it arrives.
static char ApelinOriginalFiltersKey;
static char ApelinOriginalBackgroundKey;

static void ApelinKeep(id object, void *key, id value) {
    if (!objc_getAssociatedObject(object, key)) {
        objc_setAssociatedObject(object, key, value ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Where a menu ends up, for a look from outside.
static void ApelinAppendMenuLog(NSString *text) {
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

static NSString *ApelinFilterNames(UIView *view) {
    NSMutableArray *names = [NSMutableArray array];
    @try {
        id filters = [view valueForKey:@"filters"];
        if ([filters isKindOfClass:[NSArray class]]) {
            for (id filter in (NSArray *)filters) {
                @try {
                    [names addObject:[filter valueForKey:@"filterName"] ?: @"?"];
                } @catch (__unused NSException *exception) {
                    [names addObject:@"?"];
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return [names componentsJoinedByString:@","];
}

static void ApelinDumpView(UIView *view, int depth, NSMutableString *out) {
    if (depth > 10) return;
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ frame=%@ alpha=%.2f hidden=%d bg=%@",
     indent,
     NSStringFromClass([view class]),
     NSStringFromCGRect(view.frame),
     view.alpha,
     view.hidden,
     view.backgroundColor];
    if ([[NSStringFromClass([view class]) lowercaseString] containsString:@"backdrop"]) {
        [out appendFormat:@" filters=[%@]", ApelinFilterNames(view)];
    }
    [out appendString:@"\n"];
    for (UIView *subview in view.subviews) {
        ApelinDumpView(subview, depth + 1, out);
    }
}

@interface NSObject (ApelinVisualEffect)
- (void)setFilters:(NSArray *)filters;
@end

// What a menu is made of once it has settled, which is when its material and
// its background are all there.
hook(_UIContextMenuView)

- (void)layoutSubviews {
    _orig(void);
    UIView *menu = (UIView *)self;
    if (!menu.window) return;
    static char dumpedKey;
    if (objc_getAssociatedObject(self, &dumpedKey)) return;
    objc_setAssociatedObject(self, &dumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakMenu = menu;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *settled = weakMenu;
        if (!settled) return;
        NSMutableString *out = [NSMutableString string];
        ApelinDumpView(settled, 0, out);
        ApelinAppendMenuLog([NSString stringWithFormat:@"\n=== menu at %@ ===\n%@", [NSDate date], out]);
    });
}

endhook

hook(_UIVisualEffectSubview)

- (void)setFilters:(NSArray *)filters {
    if (@available(iOS 13, *)){
        if ([self isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
            ApelinKeep(self, &ApelinOriginalFiltersKey, filters);
            // What the backdrop has before this call is the system's; whatever
            // this method paints over it is not, so it must be kept first.
            ApelinKeep(self, &ApelinOriginalBackgroundKey, [(UIView *)self backgroundColor]);
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
        } else {
            _orig(void, filters);
        }
    } else {
        _orig(void, filters);
    }
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (@available(iOS 13, *)){
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
        ApelinAppendMenuLog([NSString stringWithFormat:@"[menu backdrop] %@ restored, bg=%@\n",
                             NSStringFromClass([self class]),
                             [(UIView *)self backgroundColor]]);
    }
}

endhook
