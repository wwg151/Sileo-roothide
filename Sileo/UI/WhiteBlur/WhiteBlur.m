//
//  WhiteBlur.m
//  Supercharge
//
//  Created by Kabir Oberai on 28/01/18.
//  Copyright © 2018 Kabir Oberai. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "ZKSwizzle.h"
#import "WhiteBlur.h"
#import "Sileo-Swift.h"

@interface _UIVisualEffectFilterEntry : NSObject
- (NSString *)filterName;
@end

// The tint a glass blur gets: the same colour the white blur uses, at a much
// lower opacity, so what is behind it still reads through.
static UIColor *SileoGlassTint(CGFloat alpha) {
    if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 0) {
        return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:alpha];
    }
    if (SileoThemeManager.shared.currentTheme.preferredUserInterfaceStyle == 1) {
        return [UIColor colorWithWhite:1 alpha:alpha];
    }
    if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:alpha];
    }
    return [UIColor colorWithWhite:1 alpha:alpha];
}

hook(_UIVisualEffectSubview)

- (void)setFilters:(NSArray *)filters {
    if (@available(iOS 13, *)){
        if ([self isKindOfClass:NSClassFromString(@"_UIVisualEffectBackdropView")]) {
            // Glass: the blur keeps its own filters and is only tinted, so the
            // content behind the floating tab bar and the queue bar shows
            // through instead of a near-solid white.
            BOOL glass = NO;
            for (UIView *search = (UIView *)self; search; search = search.superview) {
                if (search.tag == GLASS_BLUR_TAG) {
                    glass = YES;
                    break;
                }
            }
            if (glass) {
                _orig(void, filters);
                [self setBackgroundColor:SileoGlassTint(0.28)];
                NSLog(@"SileoLog: glass blur tinted");
                // Landed where the shell can read it: proof the glass branch
                // runs, and that the running binary carries it.
                NSDictionary *info = @{ @"hit": @YES,
                                        @"date": [NSDate date],
                                        @"alpha": @0.28 };
                [info writeToURL:[NSURL fileURLWithPath:@"/var/mobile/Documents/SileoGlassDebug.txt"]
                        atomically:YES];
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

endhook
