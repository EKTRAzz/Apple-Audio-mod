#ifndef SPATIAL_CONFIG_H
#define SPATIAL_CONFIG_H

#import <Foundation/Foundation.h>
#include <stdint.h>

namespace spatial {

enum class SpatialMode : int {
    Matrix = 1,
    Front  = 2,
};

enum class ButtonEdge : int {
    Left  = 0,
    Right = 1,
};

enum class HookSelectionMode : int {
    Auto   = 0,
    Custom = 1,
};

enum class HrirSource : int {
    BuiltIn   = 0,
    CustomWav = 1,
};

extern NSString * const kSpatialConfigDidChangeNotification;

// Persisted user settings with lock-free atomic reads for real-time audio threads.
class SpatialConfig {
public:
    static void Initialize();

    // Real-time audio thread safe (lock-free atomic loads).
    static bool IsEnabled();
    static SpatialMode CurrentMode();
    static float SpatialMix();      // 0.0f .. 1.0f (default 1.0f)
    static float OutputGainDb();    // -6.0f .. +4.0f (default -2.5f)
    static float SpatialWidth();    // 0.5f .. 1.8f (default 1.0f)
    static HookSelectionMode HookMode();
    static bool IsPipelineAllowed(int pipelineKindInt);
    static bool IsPipelineEnabledInCustom(int pipelineKindInt);
    static HrirSource ActiveHrirSource();

    // UI / main thread configuration updates (persisted in NSUserDefaults).
    static void SetEnabled(bool enabled);
    static void ToggleEnabled();
    static void SetMode(SpatialMode mode);

    static void SetSpatialMix(float mix);
    static void SetOutputGainDb(float gainDb);
    static void SetSpatialWidth(float width);
    static void ResetTuning();

    static void SetHookMode(HookSelectionMode mode);
    static void SetPipelineEnabledInCustom(int pipelineKindInt, bool enabled);

    static void SetActiveHrirSource(HrirSource source);
    static NSString *CustomWavFileName();
    static void SetCustomWavFileName(NSString *fileName);
    static NSString *CustomWavStoragePath();

    static bool IsFloatingButtonVisible();
    static void SetFloatingButtonVisible(bool visible);
    static void ToggleFloatingButtonVisible();

    static void GetButtonPosition(ButtonEdge *outEdge, float *outNormalizedY);
    static void SaveButtonPosition(ButtonEdge edge, float normalizedY);
};

} // namespace spatial

#endif // SPATIAL_CONFIG_H
