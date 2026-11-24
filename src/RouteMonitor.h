#ifndef SPATIAL_ROUTE_MONITOR_H
#define SPATIAL_ROUTE_MONITOR_H

namespace spatial {

// Lock-free AVAudioSession route, mode, and hardware sample-rate monitor.
// Safe to query from real-time audio render callbacks without ObjC calls or locks.
class RouteMonitor {
public:
    static void Initialize();
    static void RefreshNow();
    static bool ShouldProcessAudio();
    static double CurrentSampleRate();
};

} // namespace spatial

#endif // SPATIAL_ROUTE_MONITOR_H
