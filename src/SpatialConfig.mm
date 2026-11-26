#include "SpatialConfig.h"

#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <cmath>

namespace spatial {

NSString * const kSpatialConfigDidChangeNotification = @"SpatialAudioMultiHookConfigDidChange";

namespace {

NSString * const kKeyEnabled            = @"com.spatialaudiomultihook.enabled";
NSString * const kKeyMode               = @"com.spatialaudiomultihook.mode";
NSString * const kKeyMix                = @"com.spatialaudiomultihook.spatialMix";
NSString * const kKeyGainDb             = @"com.spatialaudiomultihook.outputGainDb";
NSString * const kKeyWidth              = @"com.spatialaudiomultihook.spatialWidth";
NSString * const kKeyHookMode           = @"com.spatialaudiomultihook.hookMode";
NSString * const kKeyCustomPipePrefix   = @"com.spatialaudiomultihook.customPipe.";
NSString * const kKeyHrirSource         = @"com.spatialaudiomultihook.hrirSource";
NSString * const kKeyCustomWavName      = @"com.spatialaudiomultihook.customWavName";
NSString * const kKeyButtonVisible      = @"com.spatialaudiomultihook.buttonVisible";
NSString * const kKeyButtonEdge         = @"com.spatialaudiomultihook.buttonEdge";
NSString * const kKeyButtonNormY        = @"com.spatialaudiomultihook.buttonNormalizedY";

constexpr float kDefaultMix    = 1.0f;
constexpr float kDefaultGainDb = -2.5f;
constexpr float kDefaultWidth  = 1.0f;

std::atomic<bool>  gEnabled{true};
std::atomic<int>   gMode{static_cast<int>(SpatialMode::Matrix)};
std::atomic<float> gMix{kDefaultMix};
std::atomic<float> gGainDb{kDefaultGainDb};
std::atomic<float> gWidth{kDefaultWidth};
std::atomic<int>   gHookMode{static_cast<int>(HookSelectionMode::Auto)};
std::atomic<bool>  gCustomPipes[5] = { {false}, {true}, {true}, {true}, {true} };
std::atomic<int>   gHrirSource{static_cast<int>(HrirSource::BuiltIn)};
std::atomic<bool>  gButtonVisible{true};
std::atomic<int>   gButtonEdge{static_cast<int>(ButtonEdge::Right)};
std::atomic<float> gButtonNormY{0.42f};

inline float Clamp(float v, float lo, float hi) {
    return std::max(lo, std::min(hi, v));
}

NSString *PipeKeyFor(int kindInt) {
    return [NSString stringWithFormat:@"%@%d", kKeyCustomPipePrefix, kindInt];
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

        float mix = kDefaultMix;
        if ([defaults objectForKey:kKeyMix] != nil) {
            mix = Clamp([defaults floatForKey:kKeyMix], 0.0f, 1.0f);
        }
        gMix.store(mix, std::memory_order_release);

        float gainDb = kDefaultGainDb;
        if ([defaults objectForKey:kKeyGainDb] != nil) {
            gainDb = Clamp([defaults floatForKey:kKeyGainDb], -6.0f, 4.0f);
        }
        gGainDb.store(gainDb, std::memory_order_release);

        float width = kDefaultWidth;
        if ([defaults objectForKey:kKeyWidth] != nil) {
            width = Clamp([defaults floatForKey:kKeyWidth], 0.5f, 1.8f);
        }
        gWidth.store(width, std::memory_order_release);

        int hookMode = static_cast<int>(HookSelectionMode::Auto);
        if ([defaults objectForKey:kKeyHookMode] != nil) {
            NSInteger savedHookMode = [defaults integerForKey:kKeyHookMode];
            if (savedHookMode == static_cast<NSInteger>(HookSelectionMode::Auto) ||
                savedHookMode == static_cast<NSInteger>(HookSelectionMode::ForceBridge) ||
                savedHookMode == static_cast<NSInteger>(HookSelectionMode::Custom)) {
                hookMode = static_cast<int>(savedHookMode);
            }
        }
        gHookMode.store(hookMode, std::memory_order_release);

        for (int i = 1; i <= 4; ++i) {
            bool allowed = true;
            NSString *k = PipeKeyFor(i);
            if ([defaults objectForKey:k] != nil) {
                allowed = [defaults boolForKey:k];
            }
            gCustomPipes[i].store(allowed, std::memory_order_release);
        }

        int hrirSrc = static_cast<int>(HrirSource::BuiltIn);
        if ([defaults objectForKey:kKeyHrirSource] != nil) {
            NSInteger savedSrc = [defaults integerForKey:kKeyHrirSource];
            if (savedSrc == static_cast<NSInteger>(HrirSource::CustomWav)) {
                hrirSrc = static_cast<int>(HrirSource::CustomWav);
            }
        }
        gHrirSource.store(hrirSrc, std::memory_order_release);

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
            normY = Clamp([defaults floatForKey:kKeyButtonNormY], 0.0f, 1.0f);
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

float SpatialConfig::SpatialMix() {
    return gMix.load(std::memory_order_relaxed);
}

float SpatialConfig::OutputGainDb() {
    return gGainDb.load(std::memory_order_relaxed);
}

float SpatialConfig::SpatialWidth() {
    return gWidth.load(std::memory_order_relaxed);
}

HookSelectionMode SpatialConfig::HookMode() {
    int raw = gHookMode.load(std::memory_order_relaxed);
    if (raw == static_cast<int>(HookSelectionMode::ForceBridge)) return HookSelectionMode::ForceBridge;
    if (raw == static_cast<int>(HookSelectionMode::Custom)) return HookSelectionMode::Custom;
    return HookSelectionMode::Auto;
}

bool SpatialConfig::IsPipelineAllowed(int pipelineKindInt) {
    if (pipelineKindInt == 5) {
        return HookMode() == HookSelectionMode::ForceBridge;
    }
    if (pipelineKindInt < 1 || pipelineKindInt > 4) return false;
    if (HookMode() != HookSelectionMode::Custom) return true;
    return gCustomPipes[pipelineKindInt].load(std::memory_order_relaxed);
}

bool SpatialConfig::IsPipelineEnabledInCustom(int pipelineKindInt) {
    if (pipelineKindInt < 1 || pipelineKindInt > 4) return false;
    return gCustomPipes[pipelineKindInt].load(std::memory_order_relaxed);
}

HrirSource SpatialConfig::ActiveHrirSource() {
    int raw = gHrirSource.load(std::memory_order_relaxed);
    return (raw == static_cast<int>(HrirSource::CustomWav)) ? HrirSource::CustomWav : HrirSource::BuiltIn;
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

void SpatialConfig::SetSpatialMix(float mix) {
    Initialize();
    float clamped = Clamp(mix, 0.0f, 1.0f);
    float prev = gMix.exchange(clamped, std::memory_order_acq_rel);
    if (std::fabs(prev - clamped) > 1e-4f) {
        [[NSUserDefaults standardUserDefaults] setFloat:clamped forKey:kKeyMix];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::SetOutputGainDb(float gainDb) {
    Initialize();
    float clamped = Clamp(gainDb, -6.0f, 4.0f);
    float prev = gGainDb.exchange(clamped, std::memory_order_acq_rel);
    if (std::fabs(prev - clamped) > 1e-3f) {
        [[NSUserDefaults standardUserDefaults] setFloat:clamped forKey:kKeyGainDb];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::SetSpatialWidth(float width) {
    Initialize();
    float clamped = Clamp(width, 0.5f, 1.8f);
    float prev = gWidth.exchange(clamped, std::memory_order_acq_rel);
    if (std::fabs(prev - clamped) > 1e-4f) {
        [[NSUserDefaults standardUserDefaults] setFloat:clamped forKey:kKeyWidth];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::ResetTuning() {
    Initialize();
    gMix.store(kDefaultMix, std::memory_order_release);
    gGainDb.store(kDefaultGainDb, std::memory_order_release);
    gWidth.store(kDefaultWidth, std::memory_order_release);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:kDefaultMix forKey:kKeyMix];
    [defaults setFloat:kDefaultGainDb forKey:kKeyGainDb];
    [defaults setFloat:kDefaultWidth forKey:kKeyWidth];
    PostConfigChangedOnMain();
}

void SpatialConfig::SetHookMode(HookSelectionMode mode) {
    Initialize();
    int desired = static_cast<int>(HookSelectionMode::Auto);
    if (mode == HookSelectionMode::ForceBridge) {
        desired = static_cast<int>(HookSelectionMode::ForceBridge);
    } else if (mode == HookSelectionMode::Custom) {
        desired = static_cast<int>(HookSelectionMode::Custom);
    }
    int prev = gHookMode.exchange(desired, std::memory_order_acq_rel);
    if (prev != desired) {
        [[NSUserDefaults standardUserDefaults] setInteger:desired forKey:kKeyHookMode];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::SetPipelineEnabledInCustom(int pipelineKindInt, bool enabled) {
    Initialize();
    if (pipelineKindInt < 1 || pipelineKindInt > 4) return;
    bool prev = gCustomPipes[pipelineKindInt].exchange(enabled, std::memory_order_acq_rel);
    if (prev != enabled) {
        [[NSUserDefaults standardUserDefaults] setBool:(enabled ? YES : NO) forKey:PipeKeyFor(pipelineKindInt)];
        PostConfigChangedOnMain();
    }
}

void SpatialConfig::SetActiveHrirSource(HrirSource source) {
    Initialize();
    int desired = (source == HrirSource::CustomWav) ? static_cast<int>(HrirSource::CustomWav) : static_cast<int>(HrirSource::BuiltIn);
    int prev = gHrirSource.exchange(desired, std::memory_order_acq_rel);
    if (prev != desired) {
        [[NSUserDefaults standardUserDefaults] setInteger:desired forKey:kKeyHrirSource];
        PostConfigChangedOnMain();
    }
}

NSString *SpatialConfig::CustomWavFileName() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kKeyCustomWavName];
}

void SpatialConfig::SetCustomWavFileName(NSString *fileName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (fileName && fileName.length > 0) {
        [defaults setObject:fileName forKey:kKeyCustomWavName];
    } else {
        [defaults removeObjectForKey:kKeyCustomWavName];
    }
    PostConfigChangedOnMain();
}

NSString *SpatialConfig::CustomWavStoragePath() {
    NSArray<NSString *> *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
    NSString *folder = [base stringByAppendingPathComponent:@"SpatialAudioMultiHook"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [folder stringByAppendingPathComponent:@"custom_hrir.wav"];
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
    float clampedY = Clamp(normalizedY, 0.0f, 1.0f);
    gButtonEdge.store(edgeInt, std::memory_order_relaxed);
    gButtonNormY.store(clampedY, std::memory_order_relaxed);

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:edgeInt forKey:kKeyButtonEdge];
    [defaults setFloat:clampedY forKey:kKeyButtonNormY];
}

} // namespace spatial
