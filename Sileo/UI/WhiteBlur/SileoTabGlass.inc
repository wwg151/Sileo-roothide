// Glass-like surface over an opaque base: never samples page content.
#import <QuartzCore/QuartzCore.h>

@implementation SileoTabGlassView {
    CAGradientLayer *_surface;
    CAGradientLayer *_sheen;
    CAGradientLayer *_lowerGlow;
    CAGradientLayer *_rim;
    CAShapeLayer *_rimMask;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.opaque = YES;
    _surface = [CAGradientLayer layer];
    _surface.startPoint = CGPointMake(0.5, 0);
    _surface.endPoint = CGPointMake(0.5, 1);
    _surface.locations = @[@0, @0.48, @1];
    _sheen = [CAGradientLayer layer];
    _sheen.startPoint = CGPointMake(0.25, 0);
    _sheen.endPoint = CGPointMake(0.75, 1);
    _sheen.locations = @[@0, @0.42, @1];
    _lowerGlow = [CAGradientLayer layer];
    _lowerGlow.startPoint = CGPointMake(0.5, 0);
    _lowerGlow.endPoint = CGPointMake(0.5, 1);
    _lowerGlow.locations = @[@0, @0.72, @1];
    _rim = [CAGradientLayer layer];
    _rim.startPoint = CGPointMake(0, 0);
    _rim.endPoint = CGPointMake(1, 1);
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 1;
    _rim.mask = _rimMask;
    [self.layer addSublayer:_surface];
    [self.layer addSublayer:_sheen];
    [self.layer addSublayer:_lowerGlow];
    [self.layer addSublayer:_rim];
    return self;
}

- (void)setFrostEmphasis:(CGFloat)frostEmphasis {
    _frostEmphasis = MIN(1, MAX(0, frostEmphasis));
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat emphasis = self.frostEmphasis;
    BOOL reduced = UIAccessibilityIsReduceTransparencyEnabled();
    CGFloat top = dark ? 0.17 + 0.06 * emphasis : 0.96 - 0.06 * emphasis;
    CGFloat middle = dark ? 0.12 + 0.06 * emphasis : 0.90 - 0.06 * emphasis;
    CGFloat bottom = dark ? 0.15 + 0.06 * emphasis : 0.95 - 0.06 * emphasis;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // The alpha-one foundation completely blocks the scrolling page. Only
    // the decorative layers above it are translucent.
    self.backgroundColor = [UIColor colorWithWhite:middle alpha:1];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    _surface.frame = self.bounds;
    _surface.colors = @[(id)[UIColor colorWithWhite:top alpha:1].CGColor,
                        (id)[UIColor colorWithWhite:middle alpha:1].CGColor,
                        (id)[UIColor colorWithWhite:bottom alpha:1].CGColor];
    _sheen.frame = self.bounds;
    _sheen.colors = @[(id)[UIColor colorWithWhite:1 alpha:dark ? 0.16 : 0.48].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:dark ? 0.025 : 0.06].CGColor,
                      (id)UIColor.clearColor.CGColor];
    _lowerGlow.frame = self.bounds;
    _lowerGlow.colors = @[(id)UIColor.clearColor.CGColor,
                          (id)UIColor.clearColor.CGColor,
                          (id)[UIColor colorWithWhite:1 alpha:dark ? 0.065 : 0.20].CGColor];
    _sheen.hidden = reduced;
    _lowerGlow.hidden = reduced;
    _rim.frame = self.bounds;
    _rim.locations = @[@0, @0.24, @0.65, @1];
    _rimMask.frame = self.bounds;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.5, 0.5)
                                             cornerRadius:self.layer.cornerRadius].CGPath;
    _rim.colors = @[(id)[UIColor colorWithWhite:1 alpha:dark ? 0.38 : 0.90].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:dark ? 0.08 : 0.24].CGColor,
                    (id)[UIColor colorWithWhite:0 alpha:dark ? 0.28 : 0.12].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:dark ? 0.20 : 0.65].CGColor];
    [CATransaction commit];
}
@end
