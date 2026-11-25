#include "SpatialConfig.h"

#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>

namespace spatial {

NSString * const kSpatialConfigDidChangeNotification = @"SpatialAudioMultiHookConfigDidChange";

namespace {

NSString * const kKeyEnabled         = @"com.spatialaudiomultihook.enabled";
NSString * const kKeyMode            = @"com.spatialaudiomultihook.mode";
NSString * const kKeyButtonVisible   = @"com.spatialaudiomultihook.buttonVisible";
NSString * const kKeyButtonEdge      = @"com.spatialaudiomultihook.buttonEdge";
NSString * const kKeyButtonNormY     = @"com.spatialaudiomultihook.buttonNormalizedY";

std::atomic<bool> gEnabled{true};
std::atomic<int>  gMode{static_cast<int>(SpatialMode::Matrix)};
std::atomic<bool> gButtonVisible{true};
std::atomic<int>  gButtonEdge{static_cast<int>(ButtonEdge::Right)};
std::atomic<float> gButtonNormY{0.42f};

inline float ClampNormY(float y) {
    return std::max(0.0f, std::min(1.0f, y));
}

void PostConfigChangedOnMain() {
    auto post = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kSpatialConfigDidChangeNotification object:nil];
    };
    if ([NSThread isMainThread]) {
        post();
    } else {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

} // namespace

void SpatialConfig::Initialize() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        bool enabled = true;
        if ([defaults objectForKey:kKeyEnabled] != nil) {
            enabled = [defaults boolForKey:kKeyEnabled];
        }
        gEnabled.store(enabled, std::memory_order_release);

        int rawMode = static_cast<int>(SpatialMode::Matrix);
        if ([defaults objectForKey:kKeyMode] != nil) {
            NSInteger savedMode = [defaults integerForKey:kKeyMode];
            if (savedMode == static_cast<NSInteger>(SpatialMode::Matrix) ||
                savedMode == static_cast<NSInteger>(SpatialMode::Front)) {
                rawMode = static_cast<int>(savedMode);
            }
        }
        gMode.store(rawMode, std::memory_order_release);

        bool visible = true;
        if ([defaults objectForKey:kKeyButtonVisible] != nil) {
            visible = [defaults boolForKey:kKeyButtonVisible];
        }
        gButtonVisible.store(visible, std::memory_order_release);

        int edge = static_cast<int>(ButtonEdge::Right);
        if ([defaults objectForKey:kKeyButtonEdge] != nil) {
            NSInteger savedEdge = [defaults integerForKey:kKeyButtonEdge];
            if (savedEdge == static_cast<NSInteger>(ButtonEdge::Left) ||
                savedEdge == static_cast<NSInteger>(ButtonEdge::Right)) {
                edge = static_cast<int>(savedEdge);
            }
        }
        gButtonEdge.store(edge, std::memory_order_release);

        float normY = 0.42f;
        if ([defaults objectForKey:kKeyButtonNormY] != nil) {
            normY = ClampNormY([defaults floatForKey:kKeyButtonNormY]);
        }
        gButtonNormY.store(normY, std::memory_order_release);
    });
}

bool SpatialConfig::IsEnabled() {
    return gEnabled.load(std::memory_order_relaxed);
}

SpatialMode SpatialConfig::CurrentMode() {
    int raw = gMode.load(std::memory_order_relaxed);
    return (raw == static_cast<int>(SpatialMode::Front)) ? SpatialMode::Front : SpatialMode::Matrix;
}

void SpatialConfig::SetEnabled(bool enabled) {
    Initialize();
    bool prev = gEnabled.exchange(enabled, std::memory_order_acq_rel);
    if (prev != enabled) {
        [[NSUserDefaults standardUserDefaults] setBool:(enabled ? YES : NO) forKey:kKeyEnabled];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::ToggleEnabled() {
    Initialize();
    SetEnabled(!IsEnabled());
}

void SpatialConfig::SetMode(SpatialMode mode) {
    Initialize();
    int desired = (mode == SpatialMode::Front) ? static_cast<int>(SpatialMode::Front) : static_cast<int>(SpatialMode::Matrix);
    int prev = gMode.exchange(desired, std::memory_order_acq_rel);
    if (prev != desired) {
        [[NSUserDefaults standardUserDefaults] setInteger:desired forKey:kKeyMode];
        PostConfigChangedOnMain();
    }
}

bool SpatialConfig::IsFloatingButtonVisible() {
    Initialize();
    return gButtonVisible.load(std::memory_order_relaxed);
}

void SpatialConfig::SetFloatingButtonVisible(bool visible) {
    Initialize();
    bool prev = gButtonVisible.exchange(visible, std::memory_order_acq_rel);
    if (prev != visible) {
        [[NSUserDefaults standardUserDefaults] setBool:(visible ? YES : NO) forKey:kKeyButtonVisible];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::ToggleFloatingButtonVisible() {
    Initialize();
    SetFloatingButtonVisible(!IsFloatingButtonVisible());
}

void SpatialConfig::GetButtonPosition(ButtonEdge *outEdge, float *outNormalizedY) {
    Initialize();
    if (outEdge) {
        int rawEdge = gButtonEdge.load(std::memory_order_relaxed);
        *outEdge = (rawEdge == static_cast<int>(ButtonEdge::Left)) ? ButtonEdge::Left : ButtonEdge::Right;
    }
    if (outNormalizedY) {
        *outNormalizedY = gButtonNormY.load(std::memory_order_relaxed);
    }
}

void SpatialConfig::SaveButtonPosition(ButtonEdge edge, float normalizedY) {
    Initialize();
    int edgeInt = (edge == ButtonEdge::Left) ? static_cast<int>(ButtonEdge::Left) : static_cast<int>(ButtonEdge::Right);
    float clampedY = ClampNormY(normalizedY);
    gButtonEdge.store(edgeInt, std::memory_order_relaxed);
    gButtonNormY.store(clampedY, std::memory_order_relaxed);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:edgeInt forKey:kKeyButtonEdge];
    [defaults setFloat:clampedY forKey:kKeyButtonNormY];
}

} // namespace spatial
