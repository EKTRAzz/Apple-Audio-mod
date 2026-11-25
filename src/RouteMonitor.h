#ifndef SPATIAL_ROUTE_MONITOR_H
#define SPATIAL_ROUTE_MONITOR_H

#include <stddef.h>

namespace spatial {

// Lock-free AVAudioSession route monitor.
// Observes AVAudioSessionRouteChangeNotification on background/main thread and caches an atomic flag
// so real-time audio callbacks never call Objective-C or lock mutexes.
class RouteMonitor {
public:
    static void Initialize();
    static bool ShouldProcessAudio();
    static bool IsHeadphoneRouteActive();
    static double CurrentSampleRate();
    static void RefreshNow();
    // Thread-safe copy of current audio output port description (for UI display only, not RT audio).
    static void GetRouteDescription(char *outBuf, size_t bufSize);
};

} // namespace spatial

#endif // SPATIAL_ROUTE_MONITOR_H
