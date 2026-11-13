// App-local frosted glass: samples only Sileo's content underneath the bar.
// No render-server hooks, no external tweak.
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface SileoGlassDisplayTarget : NSObject
@property (nonatomic, weak) SileoTabGlassView *view;
- (void)tick:(CADisplayLink *)link;
@end

@interface SileoTabGlassView ()
- (void)refreshGlass;
@end

@implementation SileoGlassDisplayTarget
- (void)tick:(CADisplayLink *)link { [self.view refreshGlass]; }
@end

@implementation SileoTabGlassView {
    UIImageView *_sample;
    UIView *_frost;
    CAGradientLayer *_sheen;
    CAGradientLayer *_rim;
    CAShapeLayer *_rimMask;
    CADisplayLink *_displayLink;
    SileoGlassDisplayTarget *_displayTarget;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    // The frosted base is this view's own background, so the side is opaque
    // enough to read as material instead of a hole onto the list.
    _sample = [[UIImageView alloc] initWithFrame:self.bounds];
    _sample.contentMode = UIViewContentModeScaleToFill;
    [self addSubview:_sample];
    _frost = [[UIView alloc] initWithFrame:self.bounds];
    [self addSubview:_frost];
    _sheen = [CAGradientLayer layer];
    _sheen.startPoint = CGPointMake(0.5, 0);
    _sheen.endPoint = CGPointMake(0.5, 1);
    _sheen.locations = @[@0, @0.42, @1];
    _rim = [CAGradientLayer layer];
    _rim.startPoint = CGPointMake(0, 0);
    _rim.endPoint = CGPointMake(1, 1);
    _rim.locations = @[@0, @0.22, @0.65, @1];
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 1;
    _rim.mask = _rimMask;
    [self.layer addSublayer:_sheen];
    [self.layer addSublayer:_rim];
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_displayLink invalidate];
    _displayLink = nil;
    if (!self.window) return;
    _displayTarget = [SileoGlassDisplayTarget new];
    _displayTarget.view = self;
    _displayLink = [CADisplayLink displayLinkWithTarget:_displayTarget selector:@selector(tick:)];
    _displayLink.preferredFramesPerSecond = 12;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self refreshGlass];
}

- (void)dealloc { [_displayLink invalidate]; }

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
    [self refreshGlass];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _sample.frame = self.bounds;
    _frost.frame = self.bounds;
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    _sheen.frame = self.bounds;
    _rim.frame = self.bounds;
    _rimMask.frame = self.bounds;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.5, 0.5)
                                             cornerRadius:self.layer.cornerRadius].CGPath;

    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGFloat emphasis = self.frostEmphasis;
    // Frosted material: an almost solid base, then the blurred sample let
    // through just enough to colour the frost with what is behind it.
    self.backgroundColor = dark
        ? [UIColor colorWithWhite:0.11 + 0.04 * emphasis alpha:0.74]
        : [UIColor colorWithWhite:0.97 alpha:0.68];
    _frost.backgroundColor = dark
        ? [UIColor colorWithWhite:1 alpha:0.07 + 0.05 * emphasis]
        : [UIColor colorWithWhite:1 alpha:0.38 + 0.14 * emphasis];
    _sample.alpha = dark ? 0.46 : 0.52;
    // The glass: a soft white sheen across the upper half of the bar.
    _sheen.colors = dark
        ? @[(id)[UIColor colorWithWhite:1 alpha:0.10 + 0.05 * emphasis].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.02].CGColor,
            (id)[UIColor clearColor].CGColor]
        : @[(id)[UIColor colorWithWhite:1 alpha:0.55].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor,
            (id)[UIColor clearColor].CGColor];
    _rim.colors = dark
        ? @[(id)[UIColor colorWithWhite:1 alpha:0.24].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.05].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0.30].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.14].CGColor]
        : @[(id)[UIColor colorWithWhite:1 alpha:0.80].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.10].CGColor,
            (id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,
            (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor];
}

- (void)refreshGlass {
    UIView *excluded = self.captureExclusionView;
    UIWindow *window = self.window;
    if (!window || !excluded || CGRectIsEmpty(self.bounds) ||
        UIAccessibilityIsReduceTransparencyEnabled() ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        _sample.image = nil;
        return;
    }
    for (UIView *ancestor = self; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return;
    }
    // Capture a small region of this app's own layer tree, excluding the bar
    // and its glyphs. Never capture the screen or another app's window.
    CGSize output = self.bounds.size;
    CGRect rect = [self convertRect:self.bounds toView:window];
    CGFloat pad = 12;
    CGSize captureSize = CGSizeMake(rect.size.width + pad * 2, rect.size.height + pad * 2);
    UIGraphicsBeginImageContextWithOptions(captureSize, NO, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return; }
    CGContextTranslateCTM(ctx, pad - rect.origin.x, pad - rect.origin.y);
    // Only the bar's own strip is rasterised: the rest of the window is walked
    // but clipped away, which keeps the 12 fps capture affordable.
    CGContextClipToRect(ctx, CGRectInset(rect, -pad, -pad));
    BOOL hidden = excluded.layer.hidden;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    @try {
        excluded.layer.hidden = YES;
        [window.layer renderInContext:ctx];
    } @finally {
        excluded.layer.hidden = hidden;
        [CATransaction commit];
    }
    UIImage *source = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!source) return;

    // Draw the sampled strips into a context a ninth of the size, compressing
    // rows toward the capsule's curved edges. Down at that size the content
    // loses its detail, and the single upscale afterwards turns that into the
    // even blur a frosted material has.
    const CGFloat kBlurScale = 9;
    CGSize small = CGSizeMake(MAX(2, ceil(output.width / kBlurScale)),
                              MAX(2, ceil(output.height / kBlurScale)));
    UIImage *refracted = nil;
    UIGraphicsBeginImageContextWithOptions(small, NO, 1);
    ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextScaleCTM(ctx, small.width / output.width, small.height / output.height);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
        CGFloat radius = output.height * 0.5;
        CGFloat row = output.height / small.height;
        for (CGFloat y = 0; y < output.height; y += row) {
            CGFloat dy = (y + row * 0.5 - radius) / MAX(radius, 1);
            CGFloat edge = pow(fabs(dy), 5);
            CGFloat zoom = 1 + 0.12 * edge;
            CGFloat sampleY = pad + radius + (y - radius) / (1 + 0.24 * edge);
            CGRect strip = CGRectMake(pad + output.width * (1 - 1 / zoom) * 0.5,
                                      sampleY, output.width / zoom, row);
            CGImageRef crop = CGImageCreateWithImageInRect(source.CGImage, strip);
            if (!crop) continue;
            [[UIImage imageWithCGImage:crop]
                drawInRect:CGRectMake(output.width * (1 - 1 / zoom) * 0.5, y,
                                      output.width / zoom, row)];
            CGImageRelease(crop);
        }
        refracted = UIGraphicsGetImageFromCurrentImageContext();
    }
    UIGraphicsEndImageContext();
    if (!refracted) return;

    UIGraphicsBeginImageContextWithOptions(output, NO, 1);
    ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    [refracted drawInRect:CGRectMake(0, 0, output.width, output.height)];
    _sample.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}
@end
