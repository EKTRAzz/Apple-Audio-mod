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

extern NSString * const kSpatialConfigDidChangeNotification;

// Persisted user settings with lock-free atomic reads for real-time audio threads.
class SpatialConfig {
public:
    static void Initialize();

    // Real-time audio thread safe (lock-free atomic loads).
    static bool IsEnabled();
    static SpatialMode CurrentMode();

    // UI / main thread configuration updates (persisted in NSUserDefaults).
    static void SetEnabled(bool enabled);
    static void ToggleEnabled();
    static void SetMode(SpatialMode mode);

    static bool IsFloatingButtonVisible();
    static void SetFloatingButtonVisible(bool visible);
    static void ToggleFloatingButtonVisible();

    static void GetButtonPosition(ButtonEdge *outEdge, float *outNormalizedY);
    static void SaveButtonPosition(ButtonEdge edge, float normalizedY);
};

} // namespace spatial

#endif // SPATIAL_CONFIG_H
