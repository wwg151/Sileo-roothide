//
//  WhiteBlur.h
//  Sileo
//
//  Created by Kabir Oberai on 10/09/18.
//  Copyright © 2018 CoolStar. All rights reserved.
//

#define WHITE_BLUR_TAG ((long)0x70757265)
// A blur with this tag keeps the system's own material instead of the white
// wash: the menus' glass cards use it.
#define GLASS_BLUR_TAG ((long)0x676c6173)

/// App-local frosted glass: samples only Sileo's content underneath the bar.
/// `frostEmphasis` (0…1) thickens the material, for the selection capsule.
@interface SileoTabGlassView : UIView
@property (nonatomic, weak) UIView *captureExclusionView;
@property (nonatomic, assign) CGFloat frostEmphasis;
@end

@interface UIView (Hairline)

@property (nonatomic, assign, getter=_hidesShadow, setter=_setHidesShadow:) BOOL hidesShadow;

@end
