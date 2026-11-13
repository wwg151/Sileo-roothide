// App-local approximation of glass; no render-server hooks or external tweak.
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
    UIView *_tint;
    CAGradientLayer *_rim;
    CAShapeLayer *_rimMask;
    CADisplayLink *_displayLink;
    SileoGlassDisplayTarget *_displayTarget;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    _sample = [[UIImageView alloc] initWithFrame:self.bounds];
    _sample.contentMode = UIViewContentModeScaleToFill;
    [self addSubview:_sample];
    _tint = [[UIView alloc] initWithFrame:self.bounds];
    [self addSubview:_tint];
    _rim = [CAGradientLayer layer];
    _rim.startPoint = CGPointMake(0, 0);
    _rim.endPoint = CGPointMake(1, 1);
    _rim.locations = @[@0, @0.22, @0.65, @1];
    _rimMask = [CAShapeLayer layer];
    _rimMask.fillColor = UIColor.clearColor.CGColor;
    _rimMask.strokeColor = UIColor.whiteColor.CGColor;
    _rimMask.lineWidth = 1;
    _rim.mask = _rimMask;
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
    _displayLink.preferredFramesPerSecond = 20;
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self refreshGlass];
}

- (void)dealloc { [_displayLink invalidate]; }

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _sample.frame = self.bounds;
    _tint.frame = self.bounds;
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) * 0.5;
    _rim.frame = self.bounds;
    _rimMask.frame = self.bounds;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 0.5, 0.5)
                                             cornerRadius:self.layer.cornerRadius].CGPath;
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    self.backgroundColor = dark ? [UIColor colorWithWhite:0.12 alpha:0.8]
                                : [UIColor colorWithWhite:0.95 alpha:0.8];
    _tint.backgroundColor = dark ? [UIColor colorWithWhite:0.08 alpha:0.28]
                                : [UIColor colorWithWhite:1 alpha:0.20];
    _rim.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.70].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:0.06].CGColor,
                    (id)[UIColor colorWithWhite:0 alpha:0.12].CGColor,
                    (id)[UIColor colorWithWhite:1 alpha:0.40].CGColor];
}

- (void)refreshGlass {
    UIView *excluded = self.captureExclusionView;
    UIWindow *window = self.window;
    if (!window || !excluded || CGRectIsEmpty(self.bounds) ||
        UIAccessibilityIsReduceTransparencyEnabled() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        _sample.image = nil;
        return;
    }
    for (UIView *ancestor = self; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return;
    }
    // Capture a small region of this app's own layer tree, excluding the bar
    // and its glyphs. Never capture the screen or another app's window.
    CGRect rect = [self convertRect:self.bounds toView:window];
    CGFloat pad = 12;
    CGSize size = CGSizeMake(rect.size.width + pad * 2, rect.size.height + pad * 2);
    UIGraphicsBeginImageContextWithOptions(size, NO, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return; }
    CGContextTranslateCTM(ctx, pad - rect.origin.x, pad - rect.origin.y);
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

    // Compress sampled strips toward the capsule's curved edge. The centre
    // remains readable while the outer bands bend nearby content inward.
    CGSize output = self.bounds.size;
    UIGraphicsBeginImageContextWithOptions(output, NO, 1);
    ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return; }
    CGFloat radius = output.height * 0.5;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    for (CGFloat y = 0; y < output.height; y += 2) {
        CGFloat dy = (y + 1 - radius) / MAX(radius, 1);
        CGFloat edge = pow(fabs(dy), 5);
        CGFloat zoom = 1 + 0.12 * edge;
        CGFloat sampleY = pad + radius + (y - radius) / (1 + 0.24 * edge);
        CGRect strip = CGRectMake(pad + output.width * (1 - 1 / zoom) * 0.5,
                                  sampleY, output.width / zoom, 2);
        CGImageRef crop = CGImageCreateWithImageInRect(source.CGImage, strip);
        if (!crop) continue;
        [[UIImage imageWithCGImage:crop] drawInRect:CGRectMake(0, y, output.width, MIN(2, output.height - y))];
        CGImageRelease(crop);
    }
    _sample.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
}
@end
