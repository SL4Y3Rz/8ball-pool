// ─── EMBEDDED ASSET DATA ─────────────────────────────────────
// Overlay dot texture — 64x64 RGBA baked as C array
// Generated from: python3 -c "import struct,math; ..."
static const uint8_t kDotTextureData[] = {
    // 64x64 RGBA = 16384 bytes — soft white circle on clear
    #include "assets/textures/dot_64.h"
};

static const uint8_t kLineTextureData[] = {
    #include "assets/textures/line_64.h"
};

static const uint8_t kPocketTextureData[] = {
    #include "assets/textures/pocket_64.h"
};

static const uint8_t kArrowTextureData[] = {
    #include "assets/textures/arrow_64.h"
};

// ─── TEXTURE GENERATOR SCRIPT (run once) ─────────────────────
// Save as generate_assets.py and run before building
/*
import struct, math, os

os.makedirs("assets/textures", exist_ok=True)

def circle_texture(size=64, name="dot_64"):
    cx = cy = size / 2
    data = []
    for y in range(size):
        for x in range(size):
            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx*dx + dy*dy)
            r = size / 2
            if dist < r - 2:
                a = 255
            elif dist < r:
                a = int(255 * (r - dist) / 2)
            else:
                a = 0
            data += [255, 255, 255, a]
    with open(f"assets/textures/{name}.h", "w") as f:
        f.write(", ".join(str(b) for b in data))

def line_texture(size=64, name="line_64"):
    data = []
    for y in range(size):
        for x in range(size):
            cx = size / 2
            dist = abs(x - cx)
            a = max(0, int(255 * (1 - dist / (size * 0.08))))
            data += [255, 255, 255, a]
    with open(f"assets/textures/{name}.h", "w") as f:
        f.write(", ".join(str(b) for b in data))

def pocket_texture(size=64, name="pocket_64"):
    cx = cy = size / 2
    data = []
    for y in range(size):
        for x in range(size):
            dx = x - cx; dy = y - cy
            dist = math.sqrt(dx*dx + dy*dy)
            outer = size / 2
            inner = size / 2 - 6
            if inner < dist < outer:
                a = 200
            elif dist <= inner:
                a = 60
            else:
                a = 0
            data += [100, 200, 255, a]
    with open(f"assets/textures/{name}.h", "w") as f:
        f.write(", ".join(str(b) for b in data))

def arrow_texture(size=64, name="arrow_64"):
    data = []
    for y in range(size):
        for x in range(size):
            nx = x / size
            ny = y / size
            in_body = (0.4 < nx < 0.6 and 0.3 < ny < 0.8)
            in_head = (ny < 0.35 and abs(nx - 0.5) < (0.35 - ny) * 1.2)
            a = 220 if (in_body or in_head) else 0
            data += [255, 255, 100, a]
    with open(f"assets/textures/{name}.h", "w") as f:
        f.write(", ".join(str(b) for b in data))

circle_texture()
line_texture()
pocket_texture()
arrow_texture()
print("Assets generated.")
*/

// ─── TEXTURE CACHE ────────────────────────────────────────────
static UIImage *gDotImage    = nil;
static UIImage *gLineImage   = nil;
static UIImage *gPocketImage = nil;
static UIImage *gArrowImage  = nil;

static UIImage *imageFromRGBAData(const uint8_t *data,
                                   size_t width,
                                   size_t height) {
    size_t bytesPerRow = width * 4;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        (void *)data, width, height, 8,
        bytesPerRow, space,
        kCGImageAlphaPremultipliedLast |
        kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    UIImage *img = [UIImage imageWithCGImage:cgImg
                                       scale:2.0
                                 orientation:UIImageOrientationUp];
    CGImageRelease(cgImg);
    return img;
}

static void loadEmbeddedAssets(void) {
    gDotImage    = imageFromRGBAData(kDotTextureData,    64, 64);
    gLineImage   = imageFromRGBAData(kLineTextureData,   64, 64);
    gPocketImage = imageFromRGBAData(kPocketTextureData, 64, 64);
    gArrowImage  = imageFromRGBAData(kArrowTextureData,  64, 64);
    NSLog(@"[AXIOM] assets loaded — "
          @"dot:%@ line:%@ pocket:%@ arrow:%@",
          gDotImage, gLineImage, gPocketImage, gArrowImage);
}

// ─── OVERLAY DRAW LAYER ───────────────────────────────────────
@interface AXOverlayLayer : CALayer
@property (nonatomic, assign) CGPoint aimStart;
@property (nonatomic, assign) CGPoint aimEnd;
@property (nonatomic, assign) CGFloat lineOpacity;
@property (nonatomic, assign) CGFloat lineThickness;
@property (nonatomic, assign) BOOL    showDots;
@property (nonatomic, assign) BOOL    showArrow;
@end

@implementation AXOverlayLayer

- (void)drawInContext:(CGContextRef)ctx {
    [super drawInContext:ctx];

    CGFloat opacity   = self.lineOpacity;
    CGFloat thickness = self.lineThickness;

    // ── prediction line ──────────────────────────────────────
    CGContextSetStrokeColorWithColor(ctx,
        [kAccentColor colorWithAlphaComponent:opacity].CGColor);
    CGContextSetLineWidth(ctx, thickness);
    CGContextSetLineDash(ctx, 0, (CGFloat[]){8, 4}, 2);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, self.aimStart.x, self.aimStart.y);
    CGContextAddLineToPoint(ctx, self.aimEnd.x, self.aimEnd.y);
    CGContextStrokePath(ctx);

    // ── impact dot ───────────────────────────────────────────
    if (self.showDots && gDotImage) {
        CGFloat dotSize = 16.0f;
        CGRect dotRect = CGRectMake(
            self.aimEnd.x - dotSize / 2,
            self.aimEnd.y - dotSize / 2,
            dotSize, dotSize);
        CGContextDrawImage(ctx, dotRect, gDotImage.CGImage);
    }

    // ── direction arrow ──────────────────────────────────────
    if (self.showArrow && gArrowImage) {
        CGFloat arrowSize = 20.0f;
        CGPoint mid = CGPointMake(
            (self.aimStart.x + self.aimEnd.x) / 2,
            (self.aimStart.y + self.aimEnd.y) / 2);
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, mid.x, mid.y);
        CGFloat angle = atan2(
            self.aimEnd.y - self.aimStart.y,
            self.aimEnd.x - self.aimStart.x);
        CGContextRotateCTM(ctx, angle - M_PI_2);
        CGContextDrawImage(ctx,
            CGRectMake(-arrowSize/2, -arrowSize/2,
                        arrowSize, arrowSize),
            gArrowImage.CGImage);
        CGContextRestoreGState(ctx);
    }
}

@end

// ─── STATIC PAYLOAD BUFFER (pads binary size) ─────────────────
// 512kb of versioning + config metadata baked into binary
static const struct {
    char     magic[8];
    uint32_t version;
    uint32_t buildNum;
    uint8_t  reserved[524272]; // pads to ~512kb
} __attribute__((used, section("__DATA,__axiom_meta")))
kAxiomMetaBlock = {
    .magic    = "AXIOM\x00\x00\x00",
    .version  = 0x0201,
    .buildNum = 0x0001,
    .reserved = {0}
};
