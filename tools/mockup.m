// mockup.m — renders design mockups for the queue redesign (no app code).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>

typedef struct { CGFloat r, g, b, a; } C4;
static const C4 Teal   = {0.06, 0.71, 0.68, 1};
static const C4 TealHi = {0.00, 0.40, 0.40, 1};
static const C4 TealLo = {0.12, 0.80, 0.77, 1};
static const C4 White  = {1, 1, 1, 1};
static const C4 Ink    = {0.05, 0.05, 0.07, 1};
static const C4 Gray   = {0.56, 0.56, 0.60, 1};
static const C4 GrayL  = {0.88, 0.88, 0.91, 1};
static const C4 CardBg = {0.955, 0.955, 0.965, 1};
static const C4 Sep    = {0.93, 0.93, 0.95, 1};
static const C4 Red    = {0.94, 0.28, 0.26, 1};
static const C4 Green  = {0.18, 0.74, 0.36, 1};
static const C4 Dim    = {0, 0, 0, 0.28};
static const C4 Blue   = {0.20, 0.45, 0.90, 1};

static CGContextRef G;
static const CGFloat W = 390, H = 844;

static CGRect T(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return CGRectMake(x, H - y - h, w, h); }
static CGFloat TY(CGFloat y) { return H - y; }

static void fillR(CGRect r, C4 c) { CGContextSetRGBFillColor(G, c.r, c.g, c.b, c.a); CGContextFillRect(G, r); }
static void rrect(CGRect r, CGFloat rad, C4 c) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextSetRGBFillColor(G, c.r, c.g, c.b, c.a);
    CGContextAddPath(G, p); CGContextFillPath(G); CFRelease(p);
}
static void srect(CGRect r, CGFloat rad, C4 c, CGFloat w) {
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextSetRGBStrokeColor(G, c.r, c.g, c.b, c.a);
    CGContextSetLineWidth(G, w); CGContextAddPath(G, p); CGContextStrokePath(G); CFRelease(p);
}
static void seg(CGPoint a, CGPoint b, CGFloat w, C4 c) {
    CGContextSetRGBStrokeColor(G, c.r, c.g, c.b, c.a);
    CGContextSetLineWidth(G, w); CGContextSetLineCap(G, kCGLineCapRound);
    CGContextMoveToPoint(G, a.x, TY(a.y)); CGContextAddLineToPoint(G, b.x, TY(b.y)); CGContextStrokePath(G);
}
// every primitive below takes TOP-based points and converts internally
static void circle(CGPoint c, CGFloat r, BOOL fillm, C4 col, CGFloat sw) {
    CGContextSetRGBFillColor(G, col.r, col.g, col.b, col.a);
    CGContextSetRGBStrokeColor(G, col.r, col.g, col.b, col.a);
    CGContextAddArc(G, c.x, TY(c.y), r, 0, 2 * M_PI, 0);
    if (fillm) { CGContextFillPath(G); } else { CGContextSetLineWidth(G, sw); CGContextStrokePath(G); }
}
static void ring(CGPoint c, CGFloat r, CGFloat w, C4 track, C4 prog, CGFloat p) {
    CGContextSetLineCap(G, kCGLineCapRound);
    circle(c, r, NO, track, w);
    if (p > 0.001) {
        CGContextSetRGBStrokeColor(G, prog.r, prog.g, prog.b, prog.a);
        CGContextSetLineWidth(G, w);
        CGContextAddArc(G, c.x, TY(c.y), r, -M_PI / 2, -M_PI / 2 + 2 * M_PI * p, 0);
        CGContextStrokePath(G);
    }
}
static void grad(CGRect r, C4 top, C4 bottom, CGFloat rad) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[8] = {top.r, top.g, top.b, top.a, bottom.r, bottom.g, bottom.b, bottom.a};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextSaveGState(G);
    CGPathRef p = CGPathCreateWithRoundedRect(r, rad, rad, NULL);
    CGContextAddPath(G, p); CGContextClip(G);
    CGContextDrawLinearGradient(G, g, CGPointMake(CGRectGetMidX(r), CGRectGetMaxY(r)),
                                CGPointMake(CGRectGetMidX(r), CGRectGetMinY(r)), 0);
    CGPathRelease(p); CGGradientRelease(g); CGColorSpaceRelease(cs);
    CGContextRestoreGState(G);
}
static CGFloat txt(NSString *s, CGFloat x, CGFloat y, CGFloat size, int weight, C4 c, int align, CGFloat boxW) {
    NSString *name = weight == 2 ? @"PingFangSC-Semibold" : weight == 1 ? @"PingFangSC-Medium" : @"PingFangSC-Regular";
    CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGColorRef col = CGColorCreate(cs, (CGFloat[]){c.r, c.g, c.b, c.a});
    NSDictionary *attr = @{ (__bridge id)kCTFontAttributeName : (__bridge id)f,
                            (__bridge id)kCTForegroundColorAttributeName : (__bridge id)col };
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attr];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGFloat ox = x;
    if (align == 1) ox = x + (boxW - w) / 2;
    if (align == 2) ox = x + boxW - w;
    CGContextSetTextPosition(G, ox, TY(y));
    CTLineDraw(line, G);
    CFRelease(line); CFRelease(col); CGColorSpaceRelease(cs); CFRelease(f);
    return w;
}
static void save(CGContextRef ctx, NSString *path) {
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
    CFRelease(img);
}
static CGContextRef newCtx(void) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, (size_t)(W * 3), (size_t)(H * 3), 8, 0, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    CGContextScaleCTM(c, 3, 3);
    CGContextSetAllowsAntialiasing(c, true);
    CGContextSetShouldAntialias(c, true);
    return c;
}

// ---------- glyphs (top-based points) ----------
static void gStar(CGPoint c, CGFloat r, C4 col) {
    CGContextSetRGBFillColor(G, col.r, col.g, col.b, col.a);
    CGMutablePathRef p = CGPathCreateMutable();
    for (int i = 0; i < 10; i++) {
        CGFloat rr = i % 2 == 0 ? r : r * 0.45;
        CGFloat a = -M_PI / 2 + i * M_PI / 5;
        CGPoint pt = CGPointMake(c.x + rr * cos(a), TY(c.y) - rr * sin(a));
        if (i == 0) CGPathMoveToPoint(p, NULL, pt.x, pt.y); else CGPathAddLineToPoint(p, NULL, pt.x, pt.y);
    }
    CGPathCloseSubpath(p);
    CGContextAddPath(G, p); CGContextFillPath(G); CFRelease(p);
}
static void gCircleStroke(CGPoint c, CGFloat r, CGFloat w, C4 col) { circle(c, r, NO, col, w); }
static void gList(CGPoint c, C4 col) {
    seg(CGPointMake(c.x - 9, c.y + 5), CGPointMake(c.x + 9, c.y + 5), 2.4, col);
    seg(CGPointMake(c.x - 9, c.y), CGPointMake(c.x + 7, c.y), 2.4, col);
    seg(CGPointMake(c.x - 9, c.y - 5), CGPointMake(c.x + 9, c.y - 5), 2.4, col);
}
static void gSearch(CGPoint c, C4 col) {
    gCircleStroke(CGPointMake(c.x - 1.5, c.y - 1.5), 6, 2.2, col);
    seg(CGPointMake(c.x + 3, c.y + 3), CGPointMake(c.x + 8, c.y + 8), 2.4, col);
}
static void gDown(CGPoint c, C4 col) {
    seg(CGPointMake(c.x, c.y - 7), CGPointMake(c.x, c.y + 5), 2.4, col);
    CGContextSetRGBFillColor(G, col.r, col.g, col.b, col.a);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x - 5, c.y + 1);
    CGPathAddLineToPoint(p, NULL, c.x + 5, c.y + 1);
    CGPathAddLineToPoint(p, NULL, c.x, c.y + 7);
    CGPathCloseSubpath(p);
    CGContextAddPath(G, p); CGContextFillPath(G); CFRelease(p);
}
static void gPause(CGPoint c, C4 col) {
    rrect(T(c.x - 5, c.y - 7, 3.4, 14), 1.7, col);
    rrect(T(c.x + 1.6, c.y - 7, 3.4, 14), 1.7, col);
}
static void gPlay(CGPoint c, C4 col) {
    CGContextSetRGBFillColor(G, col.r, col.g, col.b, col.a);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x - 4.5, TY(c.y) + 7);
    CGPathAddLineToPoint(p, NULL, c.x + 7, TY(c.y));
    CGPathAddLineToPoint(p, NULL, c.x - 4.5, TY(c.y) - 7);
    CGPathCloseSubpath(p);
    CGContextAddPath(G, p); CGContextFillPath(G); CFRelease(p);
}
static void gX(CGPoint c, C4 col) {
    seg(CGPointMake(c.x - 5, c.y - 5), CGPointMake(c.x + 5, c.y + 5), 2.6, col);
    seg(CGPointMake(c.x - 5, c.y + 5), CGPointMake(c.x + 5, c.y - 5), 2.6, col);
}
static void gCheck(CGPoint c, C4 col) {
    CGContextSetRGBStrokeColor(G, col.r, col.g, col.b, col.a);
    CGContextSetLineWidth(G, 3); CGContextSetLineCap(G, kCGLineCapRound); CGContextSetLineJoin(G, kCGLineJoinRound);
    CGContextMoveToPoint(G, c.x - 7, TY(c.y));
    CGContextAddLineToPoint(G, c.x - 2, TY(c.y) + 5.5);
    CGContextAddLineToPoint(G, c.x + 7, TY(c.y) - 5);
    CGContextStrokePath(G);
}
static void gBack(CGPoint c, C4 col) {
    seg(CGPointMake(c.x + 4, c.y - 8), CGPointMake(c.x - 4, c.y), 2.8, col);
    seg(CGPointMake(c.x - 4, c.y), CGPointMake(c.x + 4, c.y + 8), 2.8, col);
}
static void gFolder(CGPoint c, C4 col) {
    rrect(T(c.x - 12, c.y - 8, 24, 17), 3, col);
    rrect(T(c.x - 12, c.y - 11, 12, 5), 2.5, col);
    seg(CGPointMake(c.x - 12, TY(c.y) + 1), CGPointMake(c.x + 12, TY(c.y) + 1), 1.6, White);
}

// ---------- screens ----------
static void statusbar(void) {
    txt(@"23:41", 30, 22, 15, 1, Ink, 0, 0);
    rrect(T(W - 46, 14, 24, 12), 3.5, Gray);
    fillR(T(W - 44, 16, 15, 8), Ink);
    rrect(T(W - 20, 17.5, 2, 5), 1, Gray);
}
static void listPage(void) {
    fillR(T(0, 0, W, H), White);
    grad(T(0, 54, W, 246), TealHi, TealLo, 26);
    statusbar();
    txt(@"插件包", 20, 108, 30, 2, White, 0, 0);
    NSString *rows[5][2] = {@"Filza Crack", @"mlgm · 1.0", @"libhooker", @"1.6.9-22+roothide", @"antforest", @"walt-chenp · 2.2.0", @"Sileo", @"CoolStar · 2.5.1", @"Filza", @"CoolStar · 4.0.6"};
    C4 cols[5] = {Blue, Teal, Green, {0.95,0.62,0.12,1}, {0.55,0.35,0.85,1}};
    NSString *letters[5] = {@"F", @"l", @"a", @"S", @"F"};
    CGFloat y = 316;
    for (int i = 0; i < 5; i++) {
        rrect(T(20, y + 8, 56, 56), 13, cols[i]);
        txt(letters[i], 20, y + 46, 26, 2, White, 1, 56);
        txt(rows[i][0], 90, y + 32, 17, 1, Ink, 0, 0);
        txt(rows[i][1], 90, y + 55, 13, 0, Gray, 0, 0);
        if (i < 4) fillR(T(90, y + 86, W - 110, 0.7), Sep);
        y += 96;
    }
}
static void tabbar(BOOL queueSlot) {
    rrect(T(12, H - 76, W - 24, 64), 32, White);
    srect(T(12, H - 76, W - 24, 64), 32, GrayL, 0.6);
    int n = queueSlot ? 6 : 5;
    CGFloat left = 12 + 14, inner = W - 24 - 28;
    CGFloat slot = inner / n;
    int active = queueSlot ? 4 : 3; // 插件包
    for (int i = 0; i < n; i++) {
        CGPoint c = CGPointMake(left + slot * (i + 0.5), 782);
        BOOL on = i == active;
        if (on) rrect(T(c.x - 23, c.y - 15, 46, 30), 15, Teal);
        C4 col = on ? White : Gray;
        switch (i) {
            case 0: gStar(CGPointMake(c.x, c.y), 8, col); break;
            case 1: gDown(CGPointMake(c.x, c.y), col); break;
            case 2:
                if (queueSlot) {
                    ring(CGPointMake(c.x, c.y), 8, 2.6, GrayL, Teal, 0.42);
                    circle(CGPointMake(c.x + 8, c.y - 8), 7.5, YES, Teal, 0);
                    txt(@"3", c.x + 8, c.y - 5.5, 9, 2, White, 1, 0);
                } else { gCircleStroke(CGPointMake(c.x, c.y), 8, 2.2, col); }
                break;
            case 3: gCircleStroke(CGPointMake(c.x, c.y), 8, 2.2, col); seg(CGPointMake(c.x - 8, c.y), CGPointMake(c.x + 8, c.y), 1.6, col); break;
            case 4: gList(CGPointMake(c.x, c.y), col); break;
            case 5: gSearch(CGPointMake(c.x, c.y), col); break;
        }
        NSString *lab = queueSlot ? (@[@"精选", @"更新", @"队列", @"插件源", @"插件包", @"搜索"][i]) : (@[@"精选", @"更新", @"插件源", @"插件包", @"搜索"][i]);
        txt(lab, c.x - slot / 2, H - 26, 9, on ? 2 : 0, on ? Teal : Gray, 1, slot);
    }
    rrect(T(W / 2 - 67, H - 9, 134, 5), 2.5, Ink);
}
static void capsule(CGFloat progress, BOOL done) {
    CGFloat h = 44, w = 224;
    CGFloat x = (W - w) / 2, y = H - 76 - 8 - h;
    rrect(T(x, y, w, h), 22, White);
    srect(T(x, y, w, h), 22, GrayL, 0.6);
    C4 pc = done ? Green : Teal;
    ring(CGPointMake(x + 26, y + h / 2), 9.5, 3, GrayL, pc, progress);
    if (done) gCheck(CGPointMake(x + 26, y + h / 2), Green);
    txt(done ? @"已完成 3 项" : @"下载中 3 项", x + 42, y + h / 2 + 5.5, 15, 1, Ink, 0, 0);
    txt(done ? @"✓" : @"42%", x + w - 58, y + h / 2 + 5, 13, 0, done ? Green : Gray, 2, 46);
}

// frames
static void frame1(void) { // list + capsule
    listPage();
    tabbar(NO);
    capsule(0.42, NO);
}
static void frame2(void) { // list + sheet
    listPage();
    tabbar(NO);
    capsule(0.42, NO);
    fillR(T(0, 0, W, H), Dim);
    CGFloat sy = 372;
    rrect(T(0, sy, W, H - sy), 24, White);
    rrect(T(W / 2 - 18, sy + 8, 36, 5), 2.5, GrayL);
    txt(@"下载队列", 20, sy + 44, 20, 2, Ink, 0, 0);
    txt(@"2 项进行中 · 1 项失败", 20, sy + 66, 13, 0, Gray, 0, 0);
    txt(@"全部暂停", W - 20, sy + 44, 15, 1, Teal, 2, 0);
    NSString *cards[3][2] = {@"libhooker", @"下载中 · 1.2 MB/s", @"Filza Crack", @"等待中 · 0%", @"antforest", @"失败 · 校验不一致"};
    C4 cols[3] = {Teal, Blue, Green};
    CGFloat y = sy + 88;
    for (int i = 0; i < 3; i++) {
        rrect(T(16, y, W - 32, 74), 14, CardBg);
        rrect(T(30, y + 15, 44, 44), 11, cols[i]);
        gFolder(CGPointMake(52, y + 40), White);
        txt(cards[i][0], 86, y + 28, 16, 1, Ink, 0, 0);
        txt(cards[i][1], 86, y + 48, 12, 0, i == 2 ? Red : Gray, 0, 0);
        CGFloat frac = i == 0 ? 0.62 : (i == 1 ? 0.0 : 0.3);
        C4 bc = i == 2 ? Red : (i == 1 ? GrayL : Teal);
        rrect(T(86, y + 58, W - 32 - 86 - 56, 3.5), 1.75, GrayL);
        if (frac > 0) rrect(T(86, y + 58, (W - 32 - 86 - 56) * frac, 3.5), 1.75, bc);
        CGPoint cc = CGPointMake(W - 36, y + 37);
        circle(cc, 15, NO, i == 2 ? Red : GrayL, 1.4);
        if (i == 0) gPause(CGPointMake(cc.x, cc.y), Ink);
        if (i == 1) gPlay(CGPointMake(cc.x, cc.y), Teal);
        if (i == 2) gX(CGPointMake(cc.x, cc.y), Red);
        y += 84;
    }
    rrect(T(16, H - 44 - 26, W - 32, 44), 22, Teal);
    txt(@"暂停全部", 16, H - 44 - 26 + 28, 16, 2, White, 1, W - 32);
    rrect(T(W / 2 - 67, H - 9, 134, 5), 2.5, Ink);
}
static void frame3(void) { // plugin page, in-place ring
    fillR(T(0, 0, W, H), White);
    grad(T(0, 54, W, 246), TealHi, TealLo, 26);
    statusbar();
    gBack(CGPointMake(28, 84), White);
    txt(@"插件包", W / 2, 90, 17, 1, White, 1, 0);
    rrect(T(20, 330, 96, 96), 22, Blue);
    gFolder(CGPointMake(68, 382), White);
    txt(@"Filza Crack", 132, 372, 24, 2, Ink, 0, 0);
    txt(@"mlgm · com.mlgm.filzacrack", 132, 398, 13, 0, Gray, 0, 0);
    // in-place action: the button became a ring
    ring(CGPointMake(320, 372), 26, 5, GrayL, Teal, 0.42);
    txt(@"42%", 320, 378, 13, 2, Teal, 1, 0);
    txt(@"下载中", 320, 424, 12, 0, Gray, 1, 0);
    txt(@"详情", 20, 470, 18, 2, Ink, 0, 0);
    txt(@"Filza 5.x 解锁完整版，含全部功能。", 20, 498, 14, 0, Gray, 0, 0);
    txt(@"插件源", 20, 546, 18, 2, Ink, 0, 0);
    NSString *srcn[3] = {@"Huayuarc", @"mlgm", @"莫忘专属源"};
    CGFloat y = 566;
    for (int i = 0; i < 3; i++) {
        txt(srcn[i], 20, y, 16, 0, Teal, 0, 0);
        txt(@"1.0", W - 46, y, 15, 0, Gray, 2, 0);
        seg(CGPointMake(20, y + 14), CGPointMake(W - 20, y + 14), 0.7, Sep);
        y += 40;
    }
    txt(@"已安装的插件包", 20, 706, 18, 2, Ink, 0, 0);
    txt(@"版本", 20, 736, 15, 0, Gray, 0, 0);
    txt(@"1.0", W - 20, 736, 15, 0, Ink, 2, 0);
    tabbar(NO);
}
static void frame4(void) { // plan B: queue inside the tab bar
    listPage();
    tabbar(YES);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { NSLog(@"usage: mockup OUTDIR"); return 1; }
        NSString *dir = [NSString stringWithUTF8String:argv[1]];

        void (*frames[4])(void) = {frame1, frame2, frame3, frame4};
        NSString *names[4] = {@"1", @"2", @"3", @"4"};
        for (int i = 0; i < 4; i++) {
            G = newCtx();
            frames[i]();
            save(G, [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"mockup-%@.png", names[i]]]);
            CFRelease(G);
        }

        // contact sheet 2x2
        CGFloat m = 26, label = 44;
        CGFloat cw = 2 * W + 3 * m, ch = 2 * (H + label) + 3 * m;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        G = CGBitmapContextCreate(NULL, (size_t)(cw * 3), (size_t)(ch * 3), 8, 0, cs,
                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        CGContextScaleCTM(G, 3, 3);
        CGContextSetAllowsAntialiasing(G, true);
        fillR(CGRectMake(0, 0, cw, ch), (C4){0.93, 0.93, 0.95, 1});
        NSString *caps[4] = {@"① 已安装列表 · 任务胶囊", @"② 任务面板（原生 Sheet）", @"③ 插件页 · 按钮就地进度", @"④ 方案二 · 底栏内嵌队列格"};
        for (int i = 0; i < 4; i++) {
            CGFloat ox = m + (i % 2) * (W + m);
            CGFloat oyTop = m + (i / 2) * (H + label + m);
            CGContextSaveGState(G);
            CGContextTranslateCTM(G, ox, ch - oyTop - H);
            frames[i]();
            CGContextRestoreGState(G);
            txt(caps[i], ox, oyTop + H + 30, 15, 1, Ink, 1, W);
        }
        save(G, [dir stringByAppendingPathComponent:@"mockup-all.png"]);
        CFRelease(G);
        NSLog(@"done");
    }
    return 0;
}
