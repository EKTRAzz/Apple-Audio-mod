#ifndef SPATIAL_ROUTE_MONITOR_H
#define SPATIAL_ROUTE_MONITOR_H

#import <Foundation/Foundation.h>

namespace spatial {

enum class BypassReason : int {
    None = 0,
    VoiceOrVideoCall,
    BuiltInSpeaker,
    BuiltInReceiver,
    CarPlay,
    AirPlay,
    HDMI,
    BluetoothHFP,
    UnsupportedOutput,
    NoOutputRoute,
};

struct RouteSnapshot {
    bool routeEligible = false;
    BypassReason bypassReason = BypassReason::NoOutputRoute;
    double sampleRate = 48000.0;
    char routeLabel[48] = "Unknown";
    char portName[96] = "";
};

extern NSString * const kRouteMonitorDidUpdateNotification;

// Lock-free AVAudioSession route, mode, and hardware sample-rate monitor.
// Safe to query from real-time audio render callbacks without ObjC calls or locks.
class RouteMonitor {
public:
    static void Initialize();
    static void RefreshNow();

    // Hardware/session route check only (lock-free).
    static bool IsRouteEligible();

    // Combined user-enabled && route-eligible check (lock-free).
    static bool ShouldProcessAudio();

    static double CurrentSampleRate();

    // Detailed route snapshot for UI display (call on main/UI thread).
    static RouteSnapshot GetSnapshot();
};

} // namespace spatial

#endif // SPATIAL_ROUTE_MONITOR_H
