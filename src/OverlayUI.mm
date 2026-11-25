#include "OverlayUI.h"
#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialConfig.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>

namespace {
static const void *kHostTapInstalledKey = &kHostTapInstalledKey;
constexpr CGFloat kButtonSize = 44.0;
constexpr CGFloat kEdgeMargin = 10.0;
} // namespace

@class SpatialOverlayController;

// Passthrough overlay window: forwards all touches outside the floating button
// (and outside the modal panel when open) straight through to the host app.
@interface SpatialPassthroughWindow : UIWindow
@property (nonatomic, weak) SpatialOverlayController *overlayController;
@end

// Gesture delegate allowing the 3-finger tap recognizer on host windows to fire
// simultaneously without ever blocking host app gestures or scrolling.
@interface SpatialHostGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@implementation SpatialHostGestureDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}
@end

@interface SpatialPanelBackdropDelegate : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *cardContainer;
@end

@implementation SpatialPanelBackdropDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    if (!self.cardContainer) return YES;
    return ![touch.view isDescendantOfView:self.cardContainer];
}
@end

@interface SpatialOverlayController : UIViewController

// Floating button views
@property (nonatomic, strong) UIView *floatingButtonContainer;
@property (nonatomic, strong) UIVisualEffectView *floatingButtonBlur;
@property (nonatomic, strong) UIView *statusDotView;

// Control panel views
@property (nonatomic, strong) UIView *panelBackdropView;
@property (nonatomic, strong) UIView *panelCardShadowView;
@property (nonatomic, strong) UIVisualEffectView *panelCardBlurView;
@property (nonatomic, strong) SpatialPanelBackdropDelegate *backdropDelegate;

// Control panel interactive elements & status labels
@property (nonatomic, strong) UILabel *headerBadgeLabel;
@property (nonatomic, strong) UIView *headerBadgeContainer;
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UISegmentedControl *modeSegmentedControl;
@property (nonatomic, strong) UILabel *modeDescriptionLabel;
@property (nonatomic, strong) UIView *statusBoxView;

@property (nonatomic, strong) UILabel *stateValueLabel;
@property (nonatomic, strong) UILabel *routeValueLabel;
@property (nonatomic, strong) UILabel *pipelineValueLabel;
@property (nonatomic, strong) UILabel *sampleRateValueLabel;

// Toast pill
@property (nonatomic, strong) UIVisualEffectView *toastBlurView;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, assign) NSUInteger toastToken;

// State & timers
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) BOOL isDraggingButton;
@property (nonatomic, assign) CGSize lastLayoutSize;
@property (nonatomic, assign) UIEdgeInsets lastSafeInsets;
@property (nonatomic, assign) NSUInteger dimToken;
@property (nonatomic, strong) NSTimer *liveRefreshTimer;
@property (nonatomic, strong) SpatialHostGestureDelegate *selfThreeFingerDelegate;

- (void)togglePanel;
- (void)hidePanelAnimated:(BOOL)animated;
- (void)handleThreeFingerTap;
- (void)refreshAllState;
- (BOOL)shouldCaptureHitAtWindowPoint:(CGPoint)point;

@end

@implementation SpatialPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.overlayController && ![self.overlayController shouldCaptureHitAtWindowPoint:point]) {
        return nil;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}

@end

@implementation SpatialOverlayController

- (void)dealloc {
    [self stopLiveRefreshTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self buildFloatingButton];
    [self buildControlPanel];
    [self buildToastView];

    self.selfThreeFingerDelegate = [[SpatialHostGestureDelegate alloc] init];
    UITapGestureRecognizer *tap3 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleThreeFingerTap)];
    tap3.numberOfTouchesRequired = 3;
    tap3.numberOfTapsRequired = 1;
    tap3.cancelsTouchesInView = NO;
    tap3.delaysTouchesBegan = NO;
    tap3.delaysTouchesEnded = NO;
    tap3.delegate = self.selfThreeFingerDelegate;
    [self.view addGestureRecognizer:tap3];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleExternalStateUpdate:)
                                                 name:spatial::kSpatialConfigDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleExternalStateUpdate:)
                                                 name:spatial::kRouteMonitorDidUpdateNotification
                                               object:nil];

    [self applyFloatingButtonVisibilityAnimated:NO];
    [self refreshAllState];
    [self scheduleIdleDim];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.isDraggingButton) {
        CGSize sz = self.view.bounds.size;
        UIEdgeInsets ins = self.view.safeAreaInsets;
        if (!CGSizeEqualToSize(sz, self.lastLayoutSize) || !UIEdgeInsetsEqualToEdgeInsets(ins, self.lastSafeInsets)) {
            self.lastLayoutSize = sz;
            self.lastSafeInsets = ins;
            [self layoutFloatingButtonFromSavedPosition];
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refreshBorderColors];
}

#pragma mark - UI Construction

- (void)buildFloatingButton {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kButtonSize, kButtonSize)];
    container.backgroundColor = [UIColor clearColor];
    container.layer.shadowColor = [UIColor blackColor].CGColor;
    container.layer.shadowOpacity = 0.28f;
    container.layer.shadowRadius = 8.0f;
    container.layer.shadowOffset = CGSizeMake(0.0, 3.0);

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = container.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = kButtonSize * 0.5;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.75;
    [container addSubview:blurView];

    UIImageSymbolConfiguration *symCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [UIImage systemImageNamed:@"headphones" withConfiguration:symCfg];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.tintColor = [UIColor labelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.frame = CGRectMake(10.0, 10.0, kButtonSize - 20.0, kButtonSize - 20.0);
    [blurView.contentView addSubview:iconView];

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(kButtonSize - 11.0, 3.0, 9.0, 9.0)];
    dot.layer.cornerRadius = 4.5;
    dot.layer.borderWidth = 1.5;
    dot.backgroundColor = [UIColor systemGreenColor];
    [container addSubview:dot];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onFloatingButtonTapped:)];
    [container addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onFloatingButtonLongPressed:)];
    longPress.minimumPressDuration = 0.45;
    [container addGestureRecognizer:longPress];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onFloatingButtonPanned:)];
    [container addGestureRecognizer:pan];

    [self.view addSubview:container];
    self.floatingButtonContainer = container;
    self.floatingButtonBlur = blurView;
    self.statusDotView = dot;
    [self refreshBorderColors];
}

- (void)buildControlPanel {
    UIView *backdrop = [[UIView alloc] initWithFrame:self.view.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.38];
    backdrop.alpha = 0.0;
    backdrop.hidden = YES;

    SpatialPanelBackdropDelegate *delegate = [[SpatialPanelBackdropDelegate alloc] init];
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackdropTapped:)];
    dismissTap.delegate = delegate;
    [backdrop addGestureRecognizer:dismissTap];

    UIView *shadowContainer = [[UIView alloc] init];
    shadowContainer.translatesAutoresizingMaskIntoConstraints = NO;
    shadowContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowContainer.layer.shadowOpacity = 0.30f;
    shadowContainer.layer.shadowRadius = 20.0f;
    shadowContainer.layer.shadowOffset = CGSizeMake(0.0, 10.0);
    delegate.cardContainer = shadowContainer;

    UIBlurEffect *panelBlur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:panelBlur];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 20.0;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.5;
    [shadowContainer addSubview:blurView];
    [backdrop addSubview:shadowContainer];

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = YES;
    scrollView.alwaysBounceVertical = NO;
    [blurView.contentView addSubview:scrollView];

    UIStackView *rootStack = [[UIStackView alloc] init];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.axis = UILayoutConstraintAxisVertical;
    rootStack.spacing = 14.0;
    [scrollView addSubview:rootStack];

    // 1. Header row
    UIView *headerIconWrap = [[UIView alloc] init];
    headerIconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    headerIconWrap.backgroundColor = [UIColor secondarySystemFillColor];
    headerIconWrap.layer.cornerRadius = 18.0;
    [NSLayoutConstraint activateConstraints:@[
        [headerIconWrap.widthAnchor constraintEqualToConstant:36.0],
        [headerIconWrap.heightAnchor constraintEqualToConstant:36.0],
    ]];

    UIImageSymbolConfiguration *hdrCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *hdrIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"headphones" withConfiguration:hdrCfg]];
    hdrIcon.translatesAutoresizingMaskIntoConstraints = NO;
    hdrIcon.tintColor = [UIColor labelColor];
    [headerIconWrap addSubview:hdrIcon];
    [NSLayoutConstraint activateConstraints:@[
        [hdrIcon.centerXAnchor constraintEqualToAnchor:headerIconWrap.centerXAnchor],
        [hdrIcon.centerYAnchor constraintEqualToAnchor:headerIconWrap.centerYAnchor],
    ]];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Spatial Audio";
    titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightBold];
    titleLabel.textColor = [UIColor labelColor];

    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.text = @"HeSuVi • Apple Pro 2";
    subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    subtitleLabel.textColor = [UIColor secondaryLabelColor];

    UIStackView *titleStack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, subtitleLabel]];
    titleStack.axis = UILayoutConstraintAxisVertical;
    titleStack.spacing = 1.0;

    UIView *badgeWrap = [[UIView alloc] init];
    badgeWrap.translatesAutoresizingMaskIntoConstraints = NO;
    badgeWrap.layer.cornerRadius = 9.0;
    badgeWrap.layer.masksToBounds = YES;

    UILabel *badgeLabel = [[UILabel alloc] init];
    badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    badgeLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold];
    badgeLabel.text = @"ACTIVE";
    [badgeWrap addSubview:badgeLabel];
    [NSLayoutConstraint activateConstraints:@[
        [badgeLabel.topAnchor constraintEqualToAnchor:badgeWrap.topAnchor constant:4.0],
        [badgeLabel.bottomAnchor constraintEqualToAnchor:badgeWrap.bottomAnchor constant:-4.0],
        [badgeLabel.leadingAnchor constraintEqualToAnchor:badgeWrap.leadingAnchor constant:8.0],
        [badgeLabel.trailingAnchor constraintEqualToAnchor:badgeWrap.trailingAnchor constant:-8.0],
    ]];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *closeCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0 weight:UIImageSymbolWeightMedium];
    [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:closeCfg]
                 forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor tertiaryLabelColor];
    [closeButton addTarget:self action:@selector(onCloseButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [closeButton.widthAnchor constraintEqualToConstant:28.0],
        [closeButton.heightAnchor constraintEqualToConstant:28.0],
    ]];

    UIStackView *headerRow = [[UIStackView alloc] initWithArrangedSubviews:@[headerIconWrap, titleStack, badgeWrap, closeButton]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 10.0;
    [titleStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [badgeWrap setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [badgeWrap setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [rootStack addArrangedSubview:headerRow];

    // Divider
    UIView *divider = [[UIView alloc] init];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor separatorColor];
    [divider.heightAnchor constraintEqualToConstant:0.5].active = YES;
    [rootStack addArrangedSubview:divider];

    // 2. Enable Spatial Audio toggle row
    UILabel *enableLabel = [[UILabel alloc] init];
    enableLabel.text = @"Enable Spatial Audio";
    enableLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    enableLabel.textColor = [UIColor labelColor];

    UISwitch *enableSw = [[UISwitch alloc] init];
    enableSw.onTintColor = [UIColor systemGreenColor];
    [enableSw addTarget:self action:@selector(onEnableSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    UIStackView *enableRow = [[UIStackView alloc] initWithArrangedSubviews:@[enableLabel, enableSw]];
    enableRow.axis = UILayoutConstraintAxisHorizontal;
    enableRow.alignment = UIStackViewAlignmentCenter;
    enableRow.spacing = 10.0;
    [rootStack addArrangedSubview:enableRow];

    // 3. Mode segmented control
    UILabel *modeTitle = [[UILabel alloc] init];
    modeTitle.text = @"Processing Mode";
    modeTitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    modeTitle.textColor = [UIColor secondaryLabelColor];

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Matrix (Upmix)", @"Front (1:1)"]];
    [seg addTarget:self action:@selector(onModeSegmentChanged:) forControlEvents:UIControlEventValueChanged];

    UILabel *modeDesc = [[UILabel alloc] init];
    modeDesc.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    modeDesc.textColor = [UIColor secondaryLabelColor];
    modeDesc.numberOfLines = 2;

    UIStackView *modeStack = [[UIStackView alloc] initWithArrangedSubviews:@[modeTitle, seg, modeDesc]];
    modeStack.axis = UILayoutConstraintAxisVertical;
    modeStack.spacing = 6.0;
    [rootStack addArrangedSubview:modeStack];

    // 4. Live Status box
    UIView *statusBox = [[UIView alloc] init];
    statusBox.translatesAutoresizingMaskIntoConstraints = NO;
    statusBox.backgroundColor = [UIColor secondarySystemFillColor];
    statusBox.layer.cornerRadius = 12.0;

    UIStackView *statusStack = [[UIStackView alloc] init];
    statusStack.translatesAutoresizingMaskIntoConstraints = NO;
    statusStack.axis = UILayoutConstraintAxisVertical;
    statusStack.spacing = 8.0;
    [statusBox addSubview:statusStack];

    UILabel *statusHeader = [[UILabel alloc] init];
    statusHeader.text = @"LIVE STATUS";
    statusHeader.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
    statusHeader.textColor = [UIColor secondaryLabelColor];
    [statusStack addArrangedSubview:statusHeader];

    UILabel *stateVal = nil;
    UILabel *routeVal = nil;
    UILabel *pipeVal  = nil;
    UILabel *srVal    = nil;
    [statusStack addArrangedSubview:[self makeStatusRowWithTitle:@"State" valueLabelOut:&stateVal]];
    [statusStack addArrangedSubview:[self makeStatusRowWithTitle:@"Output Route" valueLabelOut:&routeVal]];
    [statusStack addArrangedSubview:[self makeStatusRowWithTitle:@"Pipeline" valueLabelOut:&pipeVal]];
    [statusStack addArrangedSubview:[self makeStatusRowWithTitle:@"Sample Rate" valueLabelOut:&srVal]];
    srVal.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightMedium];

    [NSLayoutConstraint activateConstraints:@[
        [statusStack.topAnchor constraintEqualToAnchor:statusBox.topAnchor constant:11.0],
        [statusStack.bottomAnchor constraintEqualToAnchor:statusBox.bottomAnchor constant:-11.0],
        [statusStack.leadingAnchor constraintEqualToAnchor:statusBox.leadingAnchor constant:12.0],
        [statusStack.trailingAnchor constraintEqualToAnchor:statusBox.trailingAnchor constant:-12.0],
    ]];
    [rootStack addArrangedSubview:statusBox];

    // 5. Footer: Hide button & tip
    UIButton *hideBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hideBtn.backgroundColor = [UIColor tertiarySystemFillColor];
    hideBtn.layer.cornerRadius = 10.0;
    hideBtn.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    [hideBtn setTitle:@"Hide Floating Button" forState:UIControlStateNormal];
    [hideBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [hideBtn addTarget:self action:@selector(onHideButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [hideBtn.heightAnchor constraintEqualToConstant:36.0].active = YES;
    [rootStack addArrangedSubview:hideBtn];

    UILabel *tipLabel = [[UILabel alloc] init];
    tipLabel.text = @"3-finger tap anywhere to show/hide button • Long-press button to toggle";
    tipLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    tipLabel.textColor = [UIColor tertiaryLabelColor];
    tipLabel.textAlignment = NSTextAlignmentCenter;
    tipLabel.numberOfLines = 2;
    [rootStack addArrangedSubview:tipLabel];

    // Layout constraints for panel card inside safe area
    UILayoutGuide *safe = backdrop.safeAreaLayoutGuide;
    NSLayoutConstraint *cardWidth = [shadowContainer.widthAnchor constraintEqualToConstant:340.0];
    cardWidth.priority = UILayoutPriorityDefaultHigh;

    NSLayoutConstraint *cardHeightMatch = [shadowContainer.heightAnchor constraintEqualToAnchor:rootStack.heightAnchor constant:36.0];
    cardHeightMatch.priority = UILayoutPriorityDefaultLow;

    [NSLayoutConstraint activateConstraints:@[
        [shadowContainer.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [shadowContainer.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        cardWidth,
        [shadowContainer.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
        [shadowContainer.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24.0],
        cardHeightMatch,

        [blurView.topAnchor constraintEqualToAnchor:shadowContainer.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:shadowContainer.bottomAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:shadowContainer.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:shadowContainer.trailingAnchor],

        [scrollView.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],

        [rootStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:18.0],
        [rootStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-18.0],
        [rootStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:18.0],
        [rootStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-18.0],
        [rootStack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-36.0],
    ]];

    [self.view addSubview:backdrop];

    self.panelBackdropView = backdrop;
    self.panelCardShadowView = shadowContainer;
    self.panelCardBlurView = blurView;
    self.backdropDelegate = delegate;
    self.headerBadgeContainer = badgeWrap;
    self.headerBadgeLabel = badgeLabel;
    self.enableSwitch = enableSw;
    self.modeSegmentedControl = seg;
    self.modeDescriptionLabel = modeDesc;
    self.statusBoxView = statusBox;
    self.stateValueLabel = stateVal;
    self.routeValueLabel = routeVal;
    self.pipelineValueLabel = pipeVal;
    self.sampleRateValueLabel = srVal;

    [self refreshBorderColors];
}

- (UIStackView *)makeStatusRowWithTitle:(NSString *)title valueLabelOut:(UILabel **)valueOut {
    UILabel *keyLabel = [[UILabel alloc] init];
    keyLabel.text = title;
    keyLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    keyLabel.textColor = [UIColor secondaryLabelColor];
    [keyLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [keyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *valLabel = [[UILabel alloc] init];
    valLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    valLabel.textColor = [UIColor labelColor];
    valLabel.textAlignment = NSTextAlignmentRight;
    valLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [valLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[keyLabel, valLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;

    if (valueOut) {
        *valueOut = valLabel;
    }
    return row;
}

- (void)buildToastView {
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *toast = [[UIVisualEffectView alloc] initWithEffect:blur];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.layer.cornerRadius = 16.0;
    toast.layer.masksToBounds = YES;
    toast.layer.borderWidth = 0.5;
    toast.userInteractionEnabled = NO;
    toast.alpha = 0.0;
    toast.hidden = YES;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor labelColor];
    lbl.textAlignment = NSTextAlignmentCenter;
    [toast.contentView addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.topAnchor constraintEqualToAnchor:toast.contentView.topAnchor constant:7.0],
        [lbl.bottomAnchor constraintEqualToAnchor:toast.contentView.bottomAnchor constant:-7.0],
        [lbl.leadingAnchor constraintEqualToAnchor:toast.contentView.leadingAnchor constant:14.0],
        [lbl.trailingAnchor constraintEqualToAnchor:toast.contentView.trailingAnchor constant:-14.0],
    ]];

    [self.view addSubview:toast];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [toast.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10.0],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32.0],
    ]];

    self.toastBlurView = toast;
    self.toastLabel = lbl;
    [self refreshBorderColors];
}

- (void)refreshBorderColors {
    CGColorRef border = [[UIColor labelColor] colorWithAlphaComponent:0.16].CGColor;
    self.floatingButtonBlur.layer.borderColor = border;
    self.statusDotView.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
    self.panelCardBlurView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.45].CGColor;
    self.toastBlurView.layer.borderColor = border;
}

#pragma mark - Hit Testing & Floating Button Layout

- (BOOL)shouldCaptureHitAtWindowPoint:(CGPoint)point {
    if (self.panelVisible) {
        return YES;
    }
    if (!self.floatingButtonContainer.hidden && self.floatingButtonContainer.alpha > 0.01) {
        return CGRectContainsPoint(self.floatingButtonContainer.frame, point);
    }
    return NO;
}

- (CGRect)safeFloatingFrameBounds {
    UIEdgeInsets insets = self.view.safeAreaInsets;
    CGSize size = self.view.bounds.size;
    CGFloat minX = insets.left + kEdgeMargin;
    CGFloat maxX = std::max(minX, size.width - insets.right - kEdgeMargin - kButtonSize);
    CGFloat minY = insets.top + kEdgeMargin;
    CGFloat maxY = std::max(minY, size.height - insets.bottom - kEdgeMargin - kButtonSize);
    return CGRectMake(minX, minY, maxX - minX, maxY - minY);
}

- (void)layoutFloatingButtonFromSavedPosition {
    if (self.view.bounds.size.width <= 0.0 || self.view.bounds.size.height <= 0.0) return;

    spatial::ButtonEdge edge = spatial::ButtonEdge::Right;
    float normY = 0.42f;
    spatial::SpatialConfig::GetButtonPosition(&edge, &normY);

    CGRect track = [self safeFloatingFrameBounds];
    CGFloat x = (edge == spatial::ButtonEdge::Left) ? CGRectGetMinX(track) : CGRectGetMaxX(track);
    CGFloat y = CGRectGetMinY(track) + static_cast<CGFloat>(normY) * CGRectGetHeight(track);
    self.floatingButtonContainer.frame = CGRectMake(x, y, kButtonSize, kButtonSize);
}

- (void)scheduleIdleDim {
    self.dimToken += 1;
    NSUInteger token = self.dimToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.dimToken != token) return;
        if (strongSelf.panelVisible || strongSelf.isDraggingButton || strongSelf.floatingButtonContainer.hidden) return;
        [UIView animateWithDuration:0.35 animations:^{
            strongSelf.floatingButtonContainer.alpha = 0.38;
        }];
    });
}

- (void)wakeFloatingButton {
    self.dimToken += 1;
    if (!self.floatingButtonContainer.hidden) {
        [UIView animateWithDuration:0.15 animations:^{
            self.floatingButtonContainer.alpha = 0.96;
        }];
    }
    [self scheduleIdleDim];
}

- (void)applyFloatingButtonVisibilityAnimated:(BOOL)animated {
    BOOL shouldShow = spatial::SpatialConfig::IsFloatingButtonVisible();
    BOOL currentlyShown = !self.floatingButtonContainer.hidden;
    if (shouldShow == currentlyShown && (!shouldShow || self.floatingButtonContainer.alpha > 0.01)) {
        return;
    }
    if (shouldShow) {
        self.floatingButtonContainer.hidden = NO;
        [self layoutFloatingButtonFromSavedPosition];
        if (animated) {
            self.floatingButtonContainer.alpha = 0.0;
            self.floatingButtonContainer.transform = CGAffineTransformMakeScale(0.75, 0.75);
            [UIView animateWithDuration:0.25
                                  delay:0.0
                 usingSpringWithDamping:0.75
                  initialSpringVelocity:0.5
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                self.floatingButtonContainer.alpha = 0.96;
                self.floatingButtonContainer.transform = CGAffineTransformIdentity;
            } completion:^(__unused BOOL finished) {
                [self scheduleIdleDim];
            }];
        } else {
            self.floatingButtonContainer.alpha = 0.96;
            self.floatingButtonContainer.transform = CGAffineTransformIdentity;
            [self scheduleIdleDim];
        }
    } else {
        if (animated && !self.floatingButtonContainer.hidden) {
            [UIView animateWithDuration:0.18 animations:^{
                self.floatingButtonContainer.alpha = 0.0;
                self.floatingButtonContainer.transform = CGAffineTransformMakeScale(0.75, 0.75);
            } completion:^(__unused BOOL finished) {
                if (!spatial::SpatialConfig::IsFloatingButtonVisible()) {
                    self.floatingButtonContainer.hidden = YES;
                    self.floatingButtonContainer.transform = CGAffineTransformIdentity;
                }
            }];
        } else {
            self.floatingButtonContainer.hidden = YES;
            self.floatingButtonContainer.alpha = 0.0;
        }
    }
}

#pragma mark - State Formatting & Refresh

- (NSString *)formatBypassStateText:(BOOL)enabled snapshot:(const spatial::RouteSnapshot &)snap {
    if (!enabled) {
        return @"Bypassed (Disabled)";
    }
    if (snap.routeEligible) {
        return @"Active";
    }
    switch (snap.bypassReason) {
        case spatial::BypassReason::VoiceOrVideoCall:
            return @"Bypassed (Voice/Video Call)";
        case spatial::BypassReason::BuiltInSpeaker:
            return @"Bypassed (Built-in Speaker)";
        case spatial::BypassReason::BuiltInReceiver:
            return @"Bypassed (Receiver)";
        case spatial::BypassReason::CarPlay:
            return @"Bypassed (CarPlay)";
        case spatial::BypassReason::AirPlay:
            return @"Bypassed (AirPlay)";
        case spatial::BypassReason::HDMI:
            return @"Bypassed (HDMI)";
        case spatial::BypassReason::BluetoothHFP:
            return @"Bypassed (Bluetooth HFP)";
        case spatial::BypassReason::NoOutputRoute:
            return @"Bypassed (No Output)";
        case spatial::BypassReason::UnsupportedOutput:
        case spatial::BypassReason::None:
        default:
            return @"Bypassed (Unsupported Output)";
    }
}

- (NSString *)formatPipelineText {
    spatial::AudioPipelineKind kind = spatial::AudioPipelineKind::None;
    bool streaming = false;
    spatial::PipelineCoordinator::GetStatus(&kind, &streaming);

    NSString *name = nil;
    switch (kind) {
        case spatial::AudioPipelineKind::AudioUnit:
            name = @"AudioUnit / AVAudioEngine";
            break;
        case spatial::AudioPipelineKind::AudioQueue:
            name = @"AudioQueue";
            break;
        case spatial::AudioPipelineKind::AVPlayer:
            name = @"AVPlayer (Tap)";
            break;
        case spatial::AudioPipelineKind::SampleBufferRenderer:
            name = @"SampleBufferRenderer";
            break;
        case spatial::AudioPipelineKind::None:
        default:
            return @"Idle (None)";
    }
    return streaming ? [name stringByAppendingString:@" • Streaming"] : [name stringByAppendingString:@" • Idle"];
}

- (NSString *)formatSampleRateText:(double)sampleRate {
    long rounded = std::lround(sampleRate);
    if (rounded == 48000) return @"48,000 Hz";
    if (rounded == 44100) return @"44,100 Hz";
    if (rounded <= 0) return @"Unknown";
    return [NSString stringWithFormat:@"%ld Hz", rounded];
}

- (void)refreshAllState {
    const bool enabled = spatial::SpatialConfig::IsEnabled();
    const spatial::SpatialMode mode = spatial::SpatialConfig::CurrentMode();
    const spatial::RouteSnapshot snap = spatial::RouteMonitor::GetSnapshot();
    const bool active = enabled && snap.routeEligible;

    // 1. Floating button dot color
    if (!enabled) {
        self.statusDotView.backgroundColor = [UIColor systemGrayColor];
    } else if (active) {
        self.statusDotView.backgroundColor = [UIColor systemGreenColor];
    } else {
        self.statusDotView.backgroundColor = [UIColor systemOrangeColor];
    }

    // 2. Panel controls
    if (self.enableSwitch.isOn != (enabled ? YES : NO)) {
        [self.enableSwitch setOn:(enabled ? YES : NO) animated:self.panelVisible];
    }
    NSInteger segIdx = (mode == spatial::SpatialMode::Front) ? 1 : 0;
    if (self.modeSegmentedControl.selectedSegmentIndex != segIdx) {
        self.modeSegmentedControl.selectedSegmentIndex = segIdx;
    }
    self.modeDescriptionLabel.text = (mode == spatial::SpatialMode::Front)
        ? @"Pure 1:1 front left/right binaural HRIR without surround upmix."
        : @"14-channel surround upmix with full HeSuVi binaural room cues.";

    // 3. Header badge
    if (!enabled) {
        self.headerBadgeLabel.text = @"OFF";
        self.headerBadgeLabel.textColor = [UIColor secondaryLabelColor];
        self.headerBadgeContainer.backgroundColor = [UIColor tertiarySystemFillColor];
    } else if (active) {
        self.headerBadgeLabel.text = @"ACTIVE";
        self.headerBadgeLabel.textColor = [UIColor systemGreenColor];
        self.headerBadgeContainer.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.16];
    } else {
        self.headerBadgeLabel.text = @"BYPASSED";
        self.headerBadgeLabel.textColor = [UIColor systemOrangeColor];
        self.headerBadgeContainer.backgroundColor = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.16];
    }

    // 4. Live status labels
    self.stateValueLabel.text = [self formatBypassStateText:enabled snapshot:snap];
    if (!enabled) {
        self.stateValueLabel.textColor = [UIColor secondaryLabelColor];
    } else if (active) {
        self.stateValueLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.stateValueLabel.textColor = [UIColor systemOrangeColor];
    }

    NSString *routeLabel = [NSString stringWithUTF8String:snap.routeLabel] ?: @"Unknown";
    NSString *portName = [NSString stringWithUTF8String:snap.portName] ?: @"";
    if (portName.length > 0 && ![portName isEqualToString:routeLabel]) {
        self.routeValueLabel.text = [NSString stringWithFormat:@"%@ (%@)", routeLabel, portName];
    } else {
        self.routeValueLabel.text = routeLabel;
    }

    self.pipelineValueLabel.text = [self formatPipelineText];
    self.sampleRateValueLabel.text = [self formatSampleRateText:snap.sampleRate];
}

#pragma mark - Panel & Toast Presentation

- (void)togglePanel {
    if (self.panelVisible) {
        [self hidePanelAnimated:YES];
    } else {
        [self showPanelAnimated:YES];
    }
}

- (void)showPanelAnimated:(BOOL)animated {
    if (self.panelVisible) return;
    self.panelVisible = YES;
    [self refreshAllState];
    [self startLiveRefreshTimer];

    self.panelBackdropView.hidden = NO;
    if (animated) {
        self.panelBackdropView.alpha = 0.0;
        self.panelCardShadowView.transform = CGAffineTransformMakeScale(0.94, 0.94);
        [UIView animateWithDuration:0.24
                              delay:0.0
             usingSpringWithDamping:0.84
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            self.panelBackdropView.alpha = 1.0;
            self.panelCardShadowView.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        self.panelBackdropView.alpha = 1.0;
        self.panelCardShadowView.transform = CGAffineTransformIdentity;
    }
}

- (void)hidePanelAnimated:(BOOL)animated {
    if (!self.panelVisible) return;
    self.panelVisible = NO;
    [self stopLiveRefreshTimer];

    if (animated) {
        [UIView animateWithDuration:0.18 animations:^{
            self.panelBackdropView.alpha = 0.0;
            self.panelCardShadowView.transform = CGAffineTransformMakeScale(0.95, 0.95);
        } completion:^(__unused BOOL finished) {
            if (!self.panelVisible) {
                self.panelBackdropView.hidden = YES;
                self.panelCardShadowView.transform = CGAffineTransformIdentity;
            }
        }];
    } else {
        self.panelBackdropView.alpha = 0.0;
        self.panelBackdropView.hidden = YES;
    }
    [self scheduleIdleDim];
}

- (void)showToast:(NSString *)message {
    self.toastToken += 1;
    NSUInteger token = self.toastToken;
    self.toastLabel.text = message;
    self.toastBlurView.hidden = NO;

    [UIView animateWithDuration:0.18 animations:^{
        self.toastBlurView.alpha = 1.0;
    }];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.toastToken != token) return;
        [UIView animateWithDuration:0.25 animations:^{
            strongSelf.toastBlurView.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            if (strongSelf.toastToken == token) {
                strongSelf.toastBlurView.hidden = YES;
            }
        }];
    });
}

- (void)startLiveRefreshTimer {
    [self stopLiveRefreshTimer];
    __weak typeof(self) weakSelf = self;
    self.liveRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf.panelVisible) {
            [strongSelf refreshAllState];
        }
    }];
}

- (void)stopLiveRefreshTimer {
    if (self.liveRefreshTimer) {
        [self.liveRefreshTimer invalidate];
        self.liveRefreshTimer = nil;
    }
}

#pragma mark - Actions & Gestures

- (void)handleExternalStateUpdate:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self applyFloatingButtonVisibilityAnimated:YES];
        [self refreshAllState];
        [self wakeFloatingButton];
    });
}

- (void)onFloatingButtonTapped:(UITapGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateEnded) return;
    [self wakeFloatingButton];
    [self togglePanel];
}

- (void)onFloatingButtonLongPressed:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    spatial::SpatialConfig::ToggleEnabled();

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic prepare];
    [haptic impactOccurred];

    [self wakeFloatingButton];
    [self refreshAllState];

    [UIView animateWithDuration:0.12 animations:^{
        self.floatingButtonContainer.transform = CGAffineTransformMakeScale(1.16, 1.16);
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.22
                              delay:0.0
             usingSpringWithDamping:0.65
              initialSpringVelocity:0.6
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            self.floatingButtonContainer.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    const bool enabled = spatial::SpatialConfig::IsEnabled();
    const spatial::RouteSnapshot snap = spatial::RouteMonitor::GetSnapshot();
    if (!enabled) {
        [self showToast:@"Spatial Audio: OFF"];
    } else if (snap.routeEligible) {
        const char *modeStr = (spatial::SpatialConfig::CurrentMode() == spatial::SpatialMode::Front) ? "Front" : "Matrix";
        [self showToast:[NSString stringWithFormat:@"Spatial Audio: ON (%s)", modeStr]];
    } else {
        [self showToast:@"Spatial Audio: ON (Auto-Bypassed)"];
    }
}

- (void)onFloatingButtonPanned:(UIPanGestureRecognizer *)gr {
    CGPoint translation = [gr translationInView:self.view];
    [gr setTranslation:CGPointZero inView:self.view];

    CGRect track = [self safeFloatingFrameBounds];

    if (gr.state == UIGestureRecognizerStateBegan) {
        self.isDraggingButton = YES;
        [self wakeFloatingButton];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGRect f = self.floatingButtonContainer.frame;
        f.origin.x = std::max(CGRectGetMinX(track), std::min(CGRectGetMaxX(track), f.origin.x + translation.x));
        f.origin.y = std::max(CGRectGetMinY(track), std::min(CGRectGetMaxY(track), f.origin.y + translation.y));
        self.floatingButtonContainer.frame = f;
        [self wakeFloatingButton];
    } else if (gr.state == UIGestureRecognizerStateEnded ||
               gr.state == UIGestureRecognizerStateCancelled ||
               gr.state == UIGestureRecognizerStateFailed) {
        self.isDraggingButton = NO;
        CGRect f = self.floatingButtonContainer.frame;
        CGFloat midX = CGRectGetMidX(f);
        CGFloat trackMidX = CGRectGetMidX(track) + kButtonSize * 0.5;
        spatial::ButtonEdge edge = (midX < trackMidX) ? spatial::ButtonEdge::Left : spatial::ButtonEdge::Right;

        CGFloat targetX = (edge == spatial::ButtonEdge::Left) ? CGRectGetMinX(track) : CGRectGetMaxX(track);
        CGFloat targetY = std::max(CGRectGetMinY(track), std::min(CGRectGetMaxY(track), f.origin.y));
        float normY = (CGRectGetHeight(track) > 1.0)
            ? static_cast<float>((targetY - CGRectGetMinY(track)) / CGRectGetHeight(track))
            : 0.42f;
        spatial::SpatialConfig::SaveButtonPosition(edge, normY);

        [UIView animateWithDuration:0.32
                              delay:0.0
             usingSpringWithDamping:0.78
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            self.floatingButtonContainer.frame = CGRectMake(targetX, targetY, kButtonSize, kButtonSize);
        } completion:^(__unused BOOL finished) {
            [self scheduleIdleDim];
        }];
    }
}

- (void)onBackdropTapped:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateEnded) {
        [self hidePanelAnimated:YES];
    }
}

- (void)onCloseButtonTapped:(UIButton *)sender {
    (void)sender;
    [self hidePanelAnimated:YES];
}

- (void)onEnableSwitchChanged:(UISwitch *)sender {
    spatial::SpatialConfig::SetEnabled(sender.isOn);
    [self refreshAllState];
    [self wakeFloatingButton];
}

- (void)onModeSegmentChanged:(UISegmentedControl *)sender {
    spatial::SpatialMode mode = (sender.selectedSegmentIndex == 1)
        ? spatial::SpatialMode::Front
        : spatial::SpatialMode::Matrix;
    spatial::SpatialConfig::SetMode(mode);
    [self refreshAllState];
    [self wakeFloatingButton];
}

- (void)onHideButtonTapped:(UIButton *)sender {
    (void)sender;
    [self hidePanelAnimated:YES];
    spatial::SpatialConfig::SetFloatingButtonVisible(false);
    [self showToast:@"Button hidden • 3-finger tap anywhere to show"];
}

- (void)handleThreeFingerTap {
    if (self.panelVisible) {
        [self hidePanelAnimated:YES];
    }
    spatial::SpatialConfig::ToggleFloatingButtonVisible();

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic prepare];
    [haptic impactOccurred];

    if (spatial::SpatialConfig::IsFloatingButtonVisible()) {
        [self showToast:@"Spatial Audio button shown"];
    } else {
        [self showToast:@"Button hidden • 3-finger tap anywhere to show"];
    }
}

@end

// Global coordinator living on the main thread for scene/window observation.
@interface SpatialOverlayCoordinator : NSObject
@property (nonatomic, strong) SpatialPassthroughWindow *overlayWindow;
@property (nonatomic, strong) SpatialOverlayController *overlayController;
@property (nonatomic, strong) SpatialHostGestureDelegate *hostGestureDelegate;
@end

@implementation SpatialOverlayCoordinator

+ (instancetype)shared {
    static SpatialOverlayCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SpatialOverlayCoordinator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hostGestureDelegate = [[SpatialHostGestureDelegate alloc] init];
    }
    return self;
}

- (void)startObserving {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onLifecycleNotification:) name:UIApplicationDidFinishLaunchingNotification object:nil];
    [nc addObserver:self selector:@selector(onLifecycleNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onLifecycleNotification:) name:UISceneDidActivateNotification object:nil];
    [nc addObserver:self selector:@selector(onLifecycleNotification:) name:UIWindowDidBecomeKeyNotification object:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureOverlayAttached];
    });
}

- (void)onLifecycleNotification:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureOverlayAttached];
    });
}

- (UIWindowScene *)findActiveApplicationScene {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    UIWindowScene *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.session.role && ![ws.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
            continue;
        }
        if (ws.activationState == UISceneActivationStateForegroundActive) {
            return ws;
        }
        if (ws.activationState == UISceneActivationStateForegroundInactive && !fallback) {
            fallback = ws;
        }
    }
    return fallback;
}

- (void)attachThreeFingerTapToWindow:(UIWindow *)window {
    if (!window || [window isKindOfClass:[SpatialPassthroughWindow class]]) return;
    if (objc_getAssociatedObject(window, kHostTapInstalledKey)) return;

    UITapGestureRecognizer *tap3 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onHostThreeFingerTap:)];
    tap3.numberOfTouchesRequired = 3;
    tap3.numberOfTapsRequired = 1;
    tap3.cancelsTouchesInView = NO;
    tap3.delaysTouchesBegan = NO;
    tap3.delaysTouchesEnded = NO;
    tap3.delegate = self.hostGestureDelegate;
    [window addGestureRecognizer:tap3];

    objc_setAssociatedObject(window, kHostTapInstalledKey, tap3, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)onHostThreeFingerTap:(UITapGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateEnded) {
        [self.overlayController handleThreeFingerTap];
    }
}

- (void)ensureOverlayAttached {
    UIWindowScene *scene = [self findActiveApplicationScene];
    if (!scene) return;

    if (!self.overlayWindow || self.overlayWindow.windowScene != scene) {
        if (self.overlayWindow) {
            self.overlayWindow.hidden = YES;
        }
        SpatialOverlayController *vc = [[SpatialOverlayController alloc] init];
        SpatialPassthroughWindow *win = [[SpatialPassthroughWindow alloc] initWithWindowScene:scene];
        win.windowLevel = UIWindowLevelStatusBar + 100.0;
        win.backgroundColor = [UIColor clearColor];
        win.overlayController = vc;
        win.rootViewController = vc;
        win.hidden = NO;

        self.overlayController = vc;
        self.overlayWindow = win;
    } else if (self.overlayWindow.hidden) {
        self.overlayWindow.hidden = NO;
    }

    for (UIWindow *win in scene.windows) {
        [self attachThreeFingerTapToWindow:win];
    }
}

@end

namespace spatial {

void InstallOverlayUI() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [[SpatialOverlayCoordinator shared] startObserving];
        });
    });
}

} // namespace spatial
