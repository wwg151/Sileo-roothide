// Opaque frosted material for the floating bar and its animated capsule.
#import <QuartzCore/QuartzCore.h>

@implementation SileoTabGlassView {
    CAGradientLayer *_surface;
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
    _rim = [CAGradientLayer layer];
    _rim.startPoint = CGPointMake(0, 0);
    _rim.endPoint = CGPointMake(1, 1);
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 1;
    _rim.mask = _rimMask;
    [self.layer addSublayer:_surface];
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
    CGFloat top = dark ? 0.16 + 0.08 * emphasis : 0.97 - 0.07 * emphasis;
    CGFloat bottom = dark ? 0.12 + 0.08 * emphasis : 0.94 - 0.07 * emphasis;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.backgroundColor = [UIColor colorWithWhite:bottom alpha:1];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    _surface.frame = self.bounds;
    _surface.colors = @[(id)[UIColor colorWithWhite:top alpha:1].CGColor,
                        (id)[UIColor colorWithWhite:bottom alpha:1].CGColor];
    _rim.frame = self.bounds;
    _rimMask.frame = self.bounds;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.5, 0.5)
                                             cornerRadius:self.layer.cornerRadius].CGPath;
    _rim.colors = @[(id)[UIColor colorWithWhite:1 alpha:dark ? 0.14 : 0.55].CGColor,
                    (id)[UIColor colorWithWhite:0 alpha:dark ? 0.18 : 0.08].CGColor];
    [CATransaction commit];
}
@end
