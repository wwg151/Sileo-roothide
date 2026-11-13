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

/// Glass-like highlights over an opaque base, following light/dark appearance.
/// `frostEmphasis` (0…1) distinguishes the selection capsule from the bar.
@interface SileoTabGlassView : UIView
@property (nonatomic, assign) CGFloat frostEmphasis;
@end

@interface UIView (Hairline)

@property (nonatomic, assign, getter=_hidesShadow, setter=_setHidesShadow:) BOOL hidesShadow;

@end
