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

/// App-local glass: samples only Sileo's content underneath the tab bar.
@interface SileoTabGlassView : UIView
@property (nonatomic, weak) UIView *captureExclusionView;
@end

@interface UIView (Hairline)

@property (nonatomic, assign, getter=_hidesShadow, setter=_setHidesShadow:) BOOL hidesShadow;

@end
