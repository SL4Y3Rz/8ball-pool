// ============================================================
// Tweak.xm — 80pool.dylib MobileSubstrate Tweak
// Full UI, battery bypass, prediction overlay + detection bypass
// ============================================================

#import <substrate.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <unistd.h>

// ─── CONSTANTS ───────────────────────────────────────────────
#define kTweakID @"com.axiom.80pool"
#define kMenuWidth 280.0f
#define kMenuHeight 520.0f
#define kCornerRadius 16.0f
#define kAccentColor [UIColor colorWithRed:0.18 green:0.62 blue:1.0 alpha:1.0]
#define kBGColor [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.97]
#define kCardColor [UIColor colorWithRed:0.13 green:0.13 blue:0.18 alpha:1.0]
#define kTextColor [UIColor whiteColor]
#define kSubtextColor [UIColor colorWithWhite:0.6 alpha:1.0]
#define kGreenColor [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1.0]
#define kRedColor [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0]

// ─── PREFERENCES KEYS ────────────────────────────────────────
static NSString *kPrediction      = @"prediction";
static NSString *kOpponent        = @"opponent";
static NSString *kTableBorders    = @"tableBorders";
static NSString *kPocketHints     = @"pocketHints";
static NSString *kImpactDots      = @"impactDots";
static NSString *kAutoAim         = @"autoAim";
static NSString *kAutoPlay        = @"autoPlay";
static NSString *kAutoBallInHand  = @"autoBallInHand";
static NSString *kScratchAlert    = @"scratchAlert";
static NSString *kWrongBallAlert  = @"wrongBallAlert";
static NSString *kLineThickness   = @"lineThickness";
static NSString *kLineOpacity     = @"lineOpacity";
static NSString *kAutoAimStrength = @"autoAimStrength";

// ─── STATE ───────────────────────────────────────────────────
static NSMutableDictionary *gPrefs;

static BOOL prefBool(NSString *key, BOOL def) {
    id val = gPrefs[key];
    return val ? [val boolValue] : def;
}
static float prefFloat(NSString *key, float def) {
    id val = gPrefs[key];
    return val ? [val floatValue] : def;
}
static void setPref(NSString *key, id value) {
    gPrefs[key] = value;
    [gPrefs writeToFile:
        [NSString stringWithFormat:
            @"/var/mobile/Library/Preferences/%@.plist", kTweakID]
        atomically:YES];
}

// ─── DETECTION BYPASS ────────────────────────────────────────
// ptrace hook — kills PT_DENY_ATTACH (31)
static int (*orig_ptrace)(int, pid_t, caddr_t, int);
static int hooked_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (request == 31) {
        NSLog(@"[AXIOM] ptrace PT_DENY_ATTACH blocked");
        return 0;
    }
    return orig_ptrace(request, pid, addr, data);
}

// sysctl hook — strips P_TRACED flag
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int hooked_sysctl(int *name, u_int namelen, void *info,
                         size_t *infosize, void *newinfo, size_t newinfosize) {
    int ret = orig_sysctl(name, namelen, info, infosize, newinfo, newinfosize);
    if (namelen >= 4 &&
        name[0] == CTL_KERN &&
        name[1] == KERN_PROC &&
        name[2] == KERN_PROC_PID &&
        info && infosize && *infosize == sizeof(struct kinfo_proc)) {
        struct kinfo_proc *proc = (struct kinfo_proc *)info;
        if (proc->kp_proc.p_flag & P_TRACED) {
            NSLog(@"[AXIOM] sysctl P_TRACED cleared");
            proc->kp_proc.p_flag &= ~P_TRACED;
        }
    }
    return ret;
}

// getppid hook — debugger detection bypass
static pid_t hooked_getppid(void) {
    return 1; // always launchd
}

static void installBypassHooks(void) {
    void *ptracePtr = dlsym(RTLD_DEFAULT, "ptrace");
    void *sysctlPtr = dlsym(RTLD_DEFAULT, "sysctl");
    void *getppidPtr = dlsym(RTLD_DEFAULT, "getppid");

    if (ptracePtr)
        MSHookFunction(ptracePtr,
                       (void *)hooked_ptrace,
                       (void **)&orig_ptrace);

    if (sysctlPtr)
        MSHookFunction(sysctlPtr,
                       (void *)hooked_sysctl,
                       (void **)&orig_sysctl);

    if (getppidPtr)
        MSHookFunction(getppidPtr,
                       (void *)hooked_getppid,
                       NULL);

    NSLog(@"[AXIOM] bypass hooks installed — ptrace/sysctl/getppid patched");
}

// ─── FORWARD DECLARATIONS ────────────────────────────────────
@interface GBModMenu : NSObject
- (void)startBatteryRefreshTimer;
- (void)stopBatteryRefreshTimer;
- (void)setBatteryRefreshTimer:(id)timer;
- (id)batteryRefreshTimer;
- (BOOL)requirePremiumForAutomationToggle:(id)toggle;
- (void)refreshPremiumBatteryUI;
- (NSString *)premiumStatusText;
- (void)applyPremiumLockState;
@end

@interface GBPredictionDrawView : UIView
- (void)updateWithResult:(id)result
       predictionRevision:(NSInteger)rev
               tableScale:(CGFloat)scale
             drawBorders:(BOOL)borders
             drawPockets:(BOOL)pockets
          drawImpactDots:(BOOL)dots
           lineThickness:(CGFloat)thickness
             lineOpacity:(CGFloat)opacity
               tableRect:(CGRect)rect
     scratchAlertEnabled:(BOOL)scratch
   wrongBallAlertEnabled:(BOOL)wrongBall
              flashPhase:(CGFloat)flash;
@end

// ─── UI COMPONENTS ───────────────────────────────────────────
@interface AXToggleRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy)   NSString *prefKey;
@property (nonatomic, copy)   void (^onChange)(BOOL);
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                      prefKey:(NSString *)key
                      default:(BOOL)def
                     onChange:(void(^)(BOOL))block;
@end

@implementation AXToggleRow
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                      prefKey:(NSString *)key
                      default:(BOOL)def
                     onChange:(void(^)(BOOL))block {
    self = [super init];
    if (!self) return nil;
    self.prefKey  = key;
    self.onChange = block;
    self.backgroundColor = kCardColor;
    self.layer.cornerRadius = 10.0f;
    self.layer.masksToBounds = YES;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = title;
    _titleLabel.textColor = kTextColor;
    _titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.text = subtitle;
    _subtitleLabel.textColor = kSubtextColor;
    _subtitleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _toggle = [[UISwitch alloc] init];
    _toggle.onTintColor = kAccentColor;
    _toggle.on = prefBool(key, def);
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [_toggle addTarget:self
                action:@selector(toggled:)
      forControlEvents:UIControlEventValueChanged];

    [self addSubview:_titleLabel];
    [self addSubview:_subtitleLabel];
    [self addSubview:_toggle];
    self.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
        [_toggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_toggle.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    return self;
}
- (void)toggled:(UISwitch *)sw {
    setPref(self.prefKey, @(sw.isOn));
    if (self.onChange) self.onChange(sw.isOn);
}
@end

// ─── SLIDER ROW ──────────────────────────────────────────────
@interface AXSliderRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, copy)   NSString *prefKey;
@end

@implementation AXSliderRow
- (instancetype)initWithTitle:(NSString *)title
                      prefKey:(NSString *)key
                          min:(float)minV
                          max:(float)maxV
                      default:(float)def {
    self = [super init];
    if (!self) return nil;
    self.prefKey = key;
    self.backgroundColor = kCardColor;
    self.layer.cornerRadius = 10.0f;
    self.layer.masksToBounds = YES;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = title;
    _titleLabel.textColor = kTextColor;
    _titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    float current = prefFloat(key, def);
    _valueLabel = [[UILabel alloc] init];
    _valueLabel.text = [NSString stringWithFormat:@"%.2f", current];
    _valueLabel.textColor = kAccentColor;
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _slider = [[UISlider alloc] init];
    _slider.minimumValue = minV;
    _slider.maximumValue = maxV;
    _slider.value = current;
    _slider.minimumTrackTintColor = kAccentColor;
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [_slider addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];

    [self addSubview:_titleLabel];
    [self addSubview:_valueLabel];
    [self addSubview:_slider];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_slider.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
        [_slider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
    ]];
    return self;
}
- (void)slid:(UISlider *)sl {
    setPref(self.prefKey, @(sl.value));
    self.valueLabel.text = [NSString stringWithFormat:@"%.2f", sl.value];
}
@end

// ─── SECTION HEADER ──────────────────────────────────────────
@interface AXSectionHeader : UIView
@end

@implementation AXSectionHeader
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon {
    self = [super init];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = [NSString stringWithFormat:@"%@ %@", icon, title];
    lbl.textColor = kAccentColor;
    lbl.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    lbl.alpha = 0.8;
    [self addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
        [lbl.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:28],
    ]];
    return self;
}
@end

// ─── STATUS BAR ──────────────────────────────────────────────
@interface AXStatusBar : UIView
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *dot;
@end

@implementation AXStatusBar
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor colorWithRed:0.1 green:0.4 blue:0.1 alpha:0.8];
    self.layer.cornerRadius = 8.0f;
    self.layer.masksToBounds = YES;

    _dot = [[UIView alloc] init];
    _dot.backgroundColor = kGreenColor;
    _dot.layer.cornerRadius = 4.0f;
    _dot.translatesAutoresizingMaskIntoConstraints = NO;

    // ── updated status text reflects bypass too ──
    _statusLabel = [[UILabel alloc] init];
    _statusLabel.text = @"AXIOM ACTIVE — BYPASS + BATTERY DEAD";
    _statusLabel.textColor = kGreenColor;
    _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.0 weight:UIFontWeightBold];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self addSubview:_dot];
    [self addSubview:_statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_dot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_dot.widthAnchor constraintEqualToConstant:8],
        [_dot.heightAnchor constraintEqualToConstant:8],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:8],
        [_statusLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:30],
    ]];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.3;
    pulse.duration = 1.2;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [_dot.layer addAnimation:pulse forKey:@"pulse"];
    return self;
}
@end

// ─── MAIN MENU WINDOW ────────────────────────────────────────
@interface AXMenuWindow : UIWindow
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) AXStatusBar *statusBar;
@property (nonatomic, assign) CGPoint dragOffset;
@property (nonatomic, assign) BOOL menuVisible;
- (void)buildUI;
- (void)toggleMenu;
@end

@implementation AXMenuWindow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.windowLevel = UIWindowLevelAlert + 100;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;
    [self buildUI];
    return self;
}

- (void)buildUI {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    fab.frame = CGRectMake(20, 120, 48, 48);
    fab.backgroundColor = [UIColor colorWithRed:0.18 green:0.62 blue:1.0 alpha:0.9];
    fab.layer.cornerRadius = 24.0f;
    fab.layer.masksToBounds = YES;
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOffset = CGSizeMake(0, 4);
    fab.layer.shadowRadius = 8.0f;
    fab.layer.shadowOpacity = 0.5f;
    [fab setTitle:@"⚡" forState:UIControlStateNormal];
    fab.titleLabel.font = [UIFont systemFontOfSize:20.0];
    [fab addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *fabPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleFabPan:)];
    [fab addGestureRecognizer:fabPan];
    [self addSubview:fab];

    _card = [[UIView alloc] initWithFrame:CGRectMake(80, 80, kMenuWidth, kMenuHeight)];
    _card.backgroundColor = kBGColor;
    _card.layer.cornerRadius = kCornerRadius;
    _card.layer.masksToBounds = YES;
    _card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    _card.layer.borderWidth = 0.5f;
    _card.hidden = YES;
    _card.alpha = 0.0f;

    UIView *shadowHost = [[UIView alloc] initWithFrame:_card.frame];
    shadowHost.backgroundColor = [UIColor clearColor];
    shadowHost.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowHost.layer.shadowOffset = CGSizeMake(0, 8);
    shadowHost.layer.shadowRadius = 20.0f;
    shadowHost.layer.shadowOpacity = 0.6f;
    shadowHost.userInteractionEnabled = NO;
    [self insertSubview:shadowHost belowSubview:_card];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kMenuWidth, 52)];
    header.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:1.0];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = @"⚡ AXIOM";
    titleLbl.textColor = kTextColor;
    titleLbl.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    titleLbl.frame = CGRectMake(16, 0, 180, 52);
    [header addSubview:titleLbl];

    UILabel *verLbl = [[UILabel alloc] init];
    verLbl.text = @"v2.1";
    verLbl.textColor = kAccentColor;
    verLbl.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    verLbl.frame = CGRectMake(kMenuWidth - 50, 0, 40, 52);
    [header addSubview:verLbl];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(kMenuWidth - 44, 12, 30, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:kSubtextColor forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:14.0];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:closeBtn];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 51.5, kMenuWidth, 0.5)];
    sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.1];
    [header addSubview:sep];
    [_card addSubview:header];

    _statusBar = [[AXStatusBar alloc] init];
    _statusBar.frame = CGRectMake(12, 60, kMenuWidth - 24, 30);
    [_card addSubview:_statusBar];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 98, kMenuWidth, kMenuHeight - 98)];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.contentInset = UIEdgeInsetsMake(8, 0, 20, 0);
    [_card addSubview:_scroll];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 6.0f;
    _stack.layoutMargins = UIEdgeInsetsMake(0, 12, 0, 12);
    _stack.layoutMarginsRelativeArrangement = YES;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor],
    ]];

    [self buildRows];

    UIPanGestureRecognizer *cardPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleCardPan:)];
    [_card addGestureRecognizer:cardPan];
    [self addSubview:_card];
}

- (void)buildRows {
    [_stack addArrangedSubview:[[AXSectionHeader alloc] initWithTitle:@"FEATURES" icon:@"🎯"]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Prediction Line" subtitle:@"Show shot trajectory" prefKey:kPrediction default:YES onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Opponent Prediction" subtitle:@"Show opponent trajectory" prefKey:kOpponent default:NO onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Table Borders" subtitle:@"Highlight table edges" prefKey:kTableBorders default:YES onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Pocket Hints" subtitle:@"Show pocket markers" prefKey:kPocketHints default:YES onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Impact Dots" subtitle:@"Show ball impact points" prefKey:kImpactDots default:YES onChange:nil]];

    [_stack addArrangedSubview:[[AXSectionHeader alloc] initWithTitle:@"AUTOMATION" icon:@"🤖"]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Auto Aim" subtitle:@"Automatic aim alignment" prefKey:kAutoAim default:NO onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Auto Play" subtitle:@"Automatic shot execution" prefKey:kAutoPlay default:NO onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Auto Ball In Hand" subtitle:@"Auto place ball in hand" prefKey:kAutoBallInHand default:NO onChange:nil]];

    [_stack addArrangedSubview:[[AXSectionHeader alloc] initWithTitle:@"ALERTS" icon:@"⚠️"]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Scratch Alert" subtitle:@"Warn on scratch risk" prefKey:kScratchAlert default:YES onChange:nil]];
    [_stack addArrangedSubview:[[AXToggleRow alloc] initWithTitle:@"Wrong Ball Alert" subtitle:@"Warn on wrong ball hit" prefKey:kWrongBallAlert default:YES onChange:nil]];

    [_stack addArrangedSubview:[[AXSectionHeader alloc] initWithTitle:@"TUNING" icon:@"🔧"]];
    [_stack addArrangedSubview:[[AXSliderRow alloc] initWithTitle:@"Line Thickness" prefKey:kLineThickness min:0.5f max:4.0f default:1.5f]];
    [_stack addArrangedSubview:[[AXSliderRow alloc] initWithTitle:@"Line Opacity" prefKey:kLineOpacity min:0.1f max:1.0f default:0.85f]];
    [_stack addArrangedSubview:[[AXSliderRow alloc] initWithTitle:@"Auto Aim Strength" prefKey:kAutoAimStrength min:0.1f max:1.0f default:0.7f]];
}

- (void)toggleMenu {
    if (_menuVisible) {
        [UIView animateWithDuration:0.25 delay:0
            options:UIViewAnimationOptionCurveEaseIn
            animations:^{
                self->_card.alpha = 0.0f;
                self->_card.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
            } completion:^(BOOL done) {
                self->_card.hidden = YES;
                self->_card.transform = CGAffineTransformIdentity;
            }];
    } else {
        _card.hidden = NO;
        _card.transform = CGAffineTransformMakeScale(0.92f, 0.92f);
        [UIView animateWithDuration:0.3 delay:0
            usingSpringWithDamping:0.75f
            initialSpringVelocity:0.5f
            options:0
            animations:^{
                self->_card.alpha = 1.0f;
                self->_card.transform = CGAffineTransformIdentity;
            } completion:nil];
    }
    _menuVisible = !_menuVisible;
}

- (void)handleFabPan:(UIPanGestureRecognizer *)pan {
    UIView *fab = pan.view;
    CGPoint t = [pan translationInView:self];
    fab.center = CGPointMake(fab.center.x + t.x, fab.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)handleCardPan:(UIPanGestureRecognizer *)pan {
    if (pan.state == UIGestureRecognizerStateBegan)
        _dragOffset = [pan locationInView:_card];
    CGPoint loc = [pan locationInView:self];
    _card.frame = CGRectMake(loc.x - _dragOffset.x,
                             loc.y - _dragOffset.y,
                             kMenuWidth, kMenuHeight);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

// ─── GLOBAL WINDOW ───────────────────────────────────────────
static AXMenuWindow *gMenuWindow;

// ─── GBMODMENU HOOKS ─────────────────────────────────────────
%hook GBModMenu
- (void)startBatteryRefreshTimer { /* dead */ }
- (void)stopBatteryRefreshTimer  { %orig; }
- (void)setBatteryRefreshTimer:(id)timer { %orig(nil); }
- (id)batteryRefreshTimer { return nil; }
- (BOOL)requirePremiumForAutomationToggle:(id)toggle { return NO; }
- (void)refreshPremiumBatteryUI { /* dead */ }
- (NSString *)premiumStatusText { return @"Active"; }
- (void)applyPremiumLockState   { /* dead */ }
%end

// ─── PREDICTION DRAW HOOKS ───────────────────────────────────
%hook GBPredictionDrawView
- (void)updateWithResult:(id)result
       predictionRevision:(NSInteger)rev
               tableScale:(CGFloat)scale
             drawBorders:(BOOL)borders
             drawPockets:(BOOL)pockets
          drawImpactDots:(BOOL)dots
           lineThickness:(CGFloat)thickness
             lineOpacity:(CGFloat)opacity
               tableRect:(CGRect)rect
     scratchAlertEnabled:(BOOL)scratch
   wrongBallAlertEnabled:(BOOL)wrongBall
              flashPhase:(CGFloat)flash {
    %orig(result, rev, scale,
          prefBool(kTableBorders, YES),
          prefBool(kPocketHints,  YES),
          prefBool(kImpactDots,   YES),
          prefFloat(kLineThickness, 1.5f),
          prefFloat(kLineOpacity,   0.85f),
          rect,
          prefBool(kScratchAlert,   YES),
          prefBool(kWrongBallAlert, YES),
          flash);
}
%end

// ─── CONSTRUCTOR ─────────────────────────────────────────────
static void loadPrefs(void) {
    NSString *path = [NSString stringWithFormat:
        @"/var/mobile/Library/Preferences/%@.plist", kTweakID];
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:path];
    gPrefs = loaded ? [loaded mutableCopy] : [NSMutableDictionary dictionary];
}

%ctor {
    loadPrefs();

    // %init FIRST — then hooks after process settles
    %init;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{

            // bypass installs after runtime is stable
            installBypassHooks();
        });

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{

            UIWindowScene *scene = nil;
            for (UIWindowScene *s in
                 [UIApplication sharedApplication]
                 .connectedScenes) {
                if (s.activationState ==
                    UISceneActivationStateForegroundActive) {
                    scene = s;
                    break;
                }
            }

            CGRect screen = [UIScreen mainScreen].bounds;
            gMenuWindow   = [[AXMenuWindow alloc]
                initWithFrame:screen];

            if (scene) {
                gMenuWindow.windowScene = scene;
            }

            gMenuWindow.hidden = NO;
            [gMenuWindow makeKeyAndVisible];

            NSLog(@"[AXIOM] v2.2 loaded — "
                  @"bypass active, battery dead, UI live");
        });
}
