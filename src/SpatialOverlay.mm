#include "SpatialOverlay.h"
#include "PipelineCoordinator.h"
#include "RouteMonitor.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdio>

@interface SpatialOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *pillView;
@property (nonatomic, weak) UIView *panelView;
@end

@implementation SpatialOverlayWindow

// Pass through all touches outside our floating pill and open control panel
// so the host app (Spotify, YouTube Music, etc.) remains 100% interactive.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.panelView && !self.panelView.hidden) {
        CGPoint p = [self convertPoint:point toView:self.panelView];
        if ([self.panelView pointInside:p withEvent:event]) {
            return [self.panelView hitTest:p withEvent:event];
        }
    }
    if (self.pillView && !self.pillView.hidden) {
        CGPoint p = [self convertPoint:point toView:self.pillView];
        if ([self.pillView pointInside:p withEvent:event]) {
            return [self.pillView hitTest:p withEvent:event];
        }
    }
    return nil;
}

@end

@interface SpatialOverlayViewController : UIViewController
@property (nonatomic, strong) UIButton *pillButton;
@property (nonatomic, strong) UIView *pillDot;
@property (nonatomic, strong) UIView *panelCard;
@property (nonatomic, strong) UILabel *statusBadgeLabel;
@property (nonatomic, strong) UILabel *detailInfoLabel;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *forceRouteSwitch;
@property (nonatomic, strong) UISegmentedControl *pipelineSegment;
@property (nonatomic, strong) UILabel *pipelineActivityLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation SpatialOverlayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self buildFloatingPill];
    [self buildControlPanel];
    [self syncControlsFromState];
    [self updateLiveStatus];

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                         target:self
                                                       selector:@selector(updateLiveStatus)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [self.refreshTimer invalidate];
}

- (void)buildFloatingPill {
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    UIButton *pill = [UIButton buttonWithType:UIButtonTypeCustom];
    pill.frame = CGRectMake(screenW - 102.0, 96.0, 90.0, 32.0);
    pill.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    pill.layer.cornerRadius = 16.0;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22].CGColor;
    pill.titleLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightBold];
    pill.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 4);
    [pill setTitle:@"DSP" forState:UIControlStateNormal];
    [pill setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [pill addTarget:self action:@selector(onPillTapped) forControlEvents:UIControlEventTouchUpInside];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(10.0, 11.0, 10.0, 10.0)];
    dot.layer.cornerRadius = 5.0;
    dot.userInteractionEnabled = NO;
    dot.backgroundColor = [UIColor systemOrangeColor];
    [pill addSubview:dot];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPillDragged:)];
    [pill addGestureRecognizer:pan];

    [self.view addSubview:pill];
    self.pillButton = pill;
    self.pillDot = dot;
}

- (void)buildControlPanel {
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    CGFloat screenH = UIScreen.mainScreen.bounds.size.height;
    CGFloat cardW = MIN(336.0, screenW - 24.0);
    CGFloat cardH = 342.0;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((screenW - cardW) * 0.5,
                                                            MAX(84.0, (screenH - cardH) * 0.35),
                                                            cardW,
                                                            cardH)];
    card.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.11 alpha:0.95];
    card.layer.cornerRadius = 16.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.45f;
    card.layer.shadowRadius = 14.0;
    card.layer.shadowOffset = CGSizeMake(0, 6);
    card.hidden = YES;

    UIPanGestureRecognizer *cardPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPanelDragged:)];
    [card addGestureRecognizer:cardPan];

    CGFloat pad = 14.0;
    CGFloat innerW = cardW - pad * 2.0;
    CGFloat y = 12.0;

    // Header title + Close button
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, innerW - 36.0, 24.0)];
    titleLbl.text = @"Spatial Audio DSP";
    titleLbl.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    titleLbl.textColor = [UIColor whiteColor];
    [card addSubview:titleLbl];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(cardW - pad - 28.0, y - 2.0, 28.0, 28.0);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    [closeBtn addTarget:self action:@selector(onClosePanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];
    y += 30.0;

    // Live status badge
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, innerW, 24.0)];
    badge.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 7.0;
    badge.layer.masksToBounds = YES;
    badge.backgroundColor = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
    [card addSubview:badge];
    self.statusBadgeLabel = badge;
    y += 30.0;

    // Route & Active Pipeline detail line
    UILabel *detail = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, innerW, 34.0)];
    detail.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    detail.textColor = [UIColor colorWithWhite:0.84 alpha:1.0];
    detail.numberOfLines = 2;
    [card addSubview:detail];
    self.detailInfoLabel = detail;
    y += 40.0;

    // Master ON/OFF switch
    UILabel *masterLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y + 4.0, innerW - 60.0, 22.0)];
    masterLbl.text = @"เปิดใช้งาน Spatial DSP";
    masterLbl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    masterLbl.textColor = [UIColor whiteColor];
    [card addSubview:masterLbl];

    UISwitch *mSw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - pad - 51.0, y, 51.0, 31.0)];
    mSw.onTintColor = [UIColor systemGreenColor];
    [mSw addTarget:self action:@selector(onMasterSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:mSw];
    self.masterSwitch = mSw;
    y += 36.0;

    // Force Route switch (bypass headphone check if needed)
    UILabel *forceLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y + 4.0, innerW - 60.0, 22.0)];
    forceLbl.text = @"บังคับทำงานทุกอุปกรณ์ (Force)";
    forceLbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    forceLbl.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    [card addSubview:forceLbl];

    UISwitch *fSw = [[UISwitch alloc] initWithFrame:CGRectMake(cardW - pad - 51.0, y, 51.0, 31.0)];
    fSw.onTintColor = [UIColor systemOrangeColor];
    [fSw addTarget:self action:@selector(onForceSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:fSw];
    self.forceRouteSwitch = fSw;
    y += 40.0;

    // Pipeline selector title
    UILabel *pipeTitle = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, innerW, 18.0)];
    pipeTitle.text = @"เลือกท่อเสียง (Audio Pipeline):";
    pipeTitle.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    pipeTitle.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    [card addSubview:pipeTitle];
    y += 22.0;

    // 5-way segmented control: Auto | AU | AQ | AVP | SBR
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Auto", @"AU", @"AQ", @"AVP", @"SBR"]];
    seg.frame = CGRectMake(pad, y, innerW, 30.0);
    seg.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    seg.selectedSegmentTintColor = [UIColor systemBlueColor];
    NSDictionary *normalAttrs = @{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:1.0],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]
    };
    NSDictionary *selectedAttrs = @{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold]
    };
    [seg setTitleTextAttributes:normalAttrs forState:UIControlStateNormal];
    [seg setTitleTextAttributes:selectedAttrs forState:UIControlStateSelected];
    [seg addTarget:self action:@selector(onPipelineChanged:) forControlEvents:UIControlEventValueChanged];
    [card addSubview:seg];
    self.pipelineSegment = seg;
    y += 38.0;

    // Per-pipeline live traffic monitor
    UILabel *actLbl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, innerW, 74.0)];
    actLbl.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    actLbl.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    actLbl.numberOfLines = 5;
    [card addSubview:actLbl];
    self.pipelineActivityLabel = actLbl;

    [self.view addSubview:card];
    self.panelCard = card;
}

- (void)syncControlsFromState {
    self.masterSwitch.on = spatial::PipelineCoordinator::IsMasterEnabled();
    self.forceRouteSwitch.on = spatial::PipelineCoordinator::IsForceOutput();
    NSInteger pref = static_cast<NSInteger>(spatial::PipelineCoordinator::PreferredPipeline());
    if (pref >= 0 && pref < self.pipelineSegment.numberOfSegments) {
        self.pipelineSegment.selectedSegmentIndex = pref;
    } else {
        self.pipelineSegment.selectedSegmentIndex = 0;
    }
}

- (void)onPillTapped {
    self.panelCard.hidden = !self.panelCard.hidden;
    if (!self.panelCard.hidden) {
        [self syncControlsFromState];
        [self updateLiveStatus];
    }
}

- (void)onClosePanel {
    self.panelCard.hidden = YES;
}

- (void)onPillDragged:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self.view];
    CGPoint center = self.pillButton.center;
    center.x += delta.x;
    center.y += delta.y;

    CGRect bounds = self.view.bounds;
    CGFloat halfW = self.pillButton.bounds.size.width * 0.5;
    CGFloat halfH = self.pillButton.bounds.size.height * 0.5;
    center.x = MAX(halfW + 6.0, MIN(bounds.size.width - halfW - 6.0, center.x));
    center.y = MAX(halfH + 44.0, MIN(bounds.size.height - halfH - 24.0, center.y));
    self.pillButton.center = center;
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)onPanelDragged:(UIPanGestureRecognizer *)pan {
    CGPoint delta = [pan translationInView:self.view];
    CGPoint center = self.panelCard.center;
    center.x += delta.x;
    center.y += delta.y;

    CGRect bounds = self.view.bounds;
    CGFloat halfW = self.panelCard.bounds.size.width * 0.5;
    CGFloat halfH = self.panelCard.bounds.size.height * 0.5;
    center.x = MAX(halfW + 6.0, MIN(bounds.size.width - halfW - 6.0, center.x));
    center.y = MAX(halfH + 44.0, MIN(bounds.size.height - halfH - 20.0, center.y));
    self.panelCard.center = center;
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)onMasterSwitchChanged:(UISwitch *)sw {
    spatial::PipelineCoordinator::SetMasterEnabled(sw.on);
    [self updateLiveStatus];
}

- (void)onForceSwitchChanged:(UISwitch *)sw {
    spatial::PipelineCoordinator::SetForceOutput(sw.on);
    [self updateLiveStatus];
}

- (void)onPipelineChanged:(UISegmentedControl *)seg {
    NSInteger idx = seg.selectedSegmentIndex;
    if (idx < 0 || idx > 4) idx = 0;
    spatial::PipelineCoordinator::SetPreferredPipeline(static_cast<spatial::AudioPipelineKind>(idx));
    [self updateLiveStatus];
}

- (void)updateLiveStatus {
    spatial::PipelineTelemetry t = spatial::PipelineCoordinator::SnapshotTelemetry();
    bool routeOk = spatial::RouteMonitor::IsHeadphoneRouteActive() || t.forceOutput;
    char routeBuf[96] = {};
    spatial::RouteMonitor::GetRouteDescription(routeBuf, sizeof(routeBuf));

    // 1. Update compact floating pill indicator
    if (!t.masterEnabled) {
        self.pillDot.backgroundColor = [UIColor systemGrayColor];
        [self.pillButton setTitle:@"OFF" forState:UIControlStateNormal];
    } else if (t.dspActiveNow) {
        self.pillDot.backgroundColor = [UIColor systemGreenColor];
        [self.pillButton setTitle:@"ON" forState:UIControlStateNormal];
    } else if (!routeOk) {
        self.pillDot.backgroundColor = [UIColor systemOrangeColor];
        [self.pillButton setTitle:@"BYP" forState:UIControlStateNormal];
    } else {
        self.pillDot.backgroundColor = [UIColor systemYellowColor];
        [self.pillButton setTitle:@"IDLE" forState:UIControlStateNormal];
    }

    if (self.panelCard.hidden) {
        return;
    }

    // 2. Update detailed status badge
    if (!t.masterEnabled) {
        self.statusBadgeLabel.text = @"⚪ ปิดใช้งาน (Master OFF)";
        self.statusBadgeLabel.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1.0];
    } else if (t.dspActiveNow) {
        NSString *activeName = [NSString stringWithUTF8String:spatial::PipelineCoordinator::PipelineName(t.activePipeline)];
        self.statusBadgeLabel.text = [NSString stringWithFormat:@"🟢 กำลังทำงานผ่าน %@", activeName];
        self.statusBadgeLabel.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:0.22 alpha:1.0];
    } else if (!routeOk) {
        self.statusBadgeLabel.text = @"🟠 Bypass (ไม่ได้ต่อหูฟัง/DAC)";
        self.statusBadgeLabel.backgroundColor = [UIColor colorWithRed:0.65 green:0.36 blue:0.06 alpha:1.0];
    } else {
        bool anySeenNow = (t.seenRecently[1] || t.seenRecently[2] || t.seenRecently[3] || t.seenRecently[4]);
        if (anySeenNow && t.preferredPipeline != spatial::AudioPipelineKind::None) {
            self.statusBadgeLabel.text = @"🟡 รอเสียง (ท่อที่เลือกไม่ตรงกับแอป)";
        } else {
            self.statusBadgeLabel.text = @"🟡 พร้อมทำงาน (รอเสียงจากแอป)";
        }
        self.statusBadgeLabel.backgroundColor = [UIColor colorWithRed:0.45 green:0.38 blue:0.08 alpha:1.0];
    }

    // 3. Route & Sample Rate details
    double sr = t.activeSampleRate > 0.0 ? t.activeSampleRate : spatial::RouteMonitor::CurrentSampleRate();
    const char *modeName = spatial::PipelineCoordinator::PipelineName(t.preferredPipeline);
    self.detailInfoLabel.text = [NSString stringWithFormat:@"Route: %s  (%.1f kHz)\nMode: %s | Active: %s",
                                 routeBuf,
                                 sr / 1000.0,
                                 modeName,
                                 t.dspActiveNow ? spatial::PipelineCoordinator::PipelineName(t.activePipeline) : "None"];

    // 4. Live traffic table per pipeline (shows which pipeline the app is actually using!)
    auto lineFor = [&](int idx, const char *label) -> NSString * {
        const char *dot = t.processedRecently[idx] ? "🟢" : (t.seenRecently[idx] ? "🟡" : "⚪");
        return [NSString stringWithFormat:@"%s %-13s seen:%llu  frames:%llu",
                dot,
                label,
                static_cast<unsigned long long>(t.seenCounts[idx]),
                static_cast<unsigned long long>(t.processedCounts[idx])];
    };

    self.pipelineActivityLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@\n%@",
                                       lineFor(1, "AU (AudioUnit)"),
                                       lineFor(2, "AQ (AudioQueue)"),
                                       lineFor(3, "AVP (AVPlayer)"),
                                       lineFor(4, "SBR (SampleBuf)")];
}

@end

namespace spatial {
namespace {

SpatialOverlayWindow *gOverlayWindow = nil;
id gActiveSceneObserver = nil;

void AttachOverlayIfNeeded() {
    if (gOverlayWindow != nil) return;

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;

    UIWindowScene *targetScene = nil;
    for (UIScene *scene in app.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                targetScene = ws;
                break;
            }
            if (!targetScene) {
                targetScene = ws;
            }
        }
    }

    if (!targetScene) return;

    SpatialOverlayWindow *win = [[SpatialOverlayWindow alloc] initWithWindowScene:targetScene];
    win.windowLevel = UIWindowLevelStatusBar + 100.0;
    win.backgroundColor = [UIColor clearColor];

    SpatialOverlayViewController *vc = [[SpatialOverlayViewController alloc] init];
    win.rootViewController = vc;
    [vc loadViewIfNeeded];
    win.pillView = vc.pillButton;
    win.panelView = vc.panelCard;
    win.hidden = NO;

    gOverlayWindow = win;
}

} // namespace

void InstallOverlayUI() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        gActiveSceneObserver = [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                                               object:nil
                                                queue:[NSOperationQueue mainQueue]
                                           usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            AttachOverlayIfNeeded();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AttachOverlayIfNeeded();
        });
    });
}

} // namespace spatial
