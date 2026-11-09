//
//  WhiteBlur.h
//  Sileo
//
//  Created by Kabir Oberai on 10/09/18.
//  Copyright © 2018 CoolStar. All rights reserved.
//

#define WHITE_BLUR_TAG ((long)0x70757265)
// The floating tab bar's capsule and the queue bar: their blur keeps its own
// filters and is only tinted, so what is behind them shows through.
#define GLASS_BLUR_TAG ((long)0x676c6173)

@interface UIView (Hairline)

@property (nonatomic, assign, getter=_hidesShadow, setter=_setHidesShadow:) BOOL hidesShadow;

@end
