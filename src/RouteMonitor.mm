#include "RouteMonitor.h"
#include "SpatialConfig.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <mutex>

namespace spatial {

NSString * const kRouteMonitorDidUpdateNotification = @"SpatialAudioMultiHookRouteDidUpdate";

namespace {
std::atomic<bool> gRouteEligible{false};
std::atomic<bool> gHasObservedValidRoute{false};
std::atomic<bool> gAsyncRefreshPending{false};
std::atomic<double> gSessionSampleRate{48000.0};

std::mutex gSnapshotMutex;
RouteSnapshot gSnapshot{};

id gRouteObserver = nil;
id gInterruptionObserver = nil;
id gMediaResetObserver = nil;
id gAppActiveObserver = nil;

template <size_t N>
void CopyString(char (&dst)[N], const char *src) {
    if (!src) {
        dst[0] = '\0';
        return;
    }
    std::strncpy(dst, src, N - 1);
    dst[N - 1] = '\0';
}

template <size_t N>
void CopyNSString(char (&dst)[N], NSString *src) {
    if (!src || src.length == 0) {
        dst[0] = '\0';
        return;
    }
    CopyString(dst, [src UTF8String]);
}

void DescribePort(AVAudioSessionPortDescription *port,
                  char (&labelOut)[48],
                  BypassReason *disallowedReasonOut,
                  bool *isDisallowedOut,
                  bool *isHeadphoneOut) {
    AVAudioSessionPort type = port.portType;
    *disallowedReasonOut = BypassReason::UnsupportedOutput;
    *isDisallowedOut = false;
    *isHeadphoneOut = false;

    if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        CopyString(labelOut, "Built-in Speaker");
        *disallowedReasonOut = BypassReason::BuiltInSpeaker;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        CopyString(labelOut, "Built-in Receiver");
        *disallowedReasonOut = BypassReason::BuiltInReceiver;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortCarAudio]) {
        CopyString(labelOut, "CarPlay");
        *disallowedReasonOut = BypassReason::CarPlay;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortAirPlay]) {
        CopyString(labelOut, "AirPlay");
        *disallowedReasonOut = BypassReason::AirPlay;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortHDMI]) {
        CopyString(labelOut, "HDMI");
        *disallowedReasonOut = BypassReason::HDMI;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        CopyString(labelOut, "Bluetooth HFP");
        *disallowedReasonOut = BypassReason::BluetoothHFP;
        *isDisallowedOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortHeadphones]) {
        CopyString(labelOut, "Wired Headphones");
        *isHeadphoneOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP]) {
        CopyString(labelOut, "Bluetooth A2DP");
        *isHeadphoneOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortBluetoothLE]) {
        CopyString(labelOut, "Bluetooth LE");
        *isHeadphoneOut = true;
    } else if ([type isEqualToString:AVAudioSessionPortUSBAudio]) {
        CopyString(labelOut, "USB Audio");
        *isHeadphoneOut = true;
    } else {
        CopyNSString(labelOut, type);
        if (labelOut[0] == '\0') {
            CopyString(labelOut, "Unknown Output");
        }
    }
}

bool EvaluateCurrentRoute() {
    @autoreleasepool {
        RouteSnapshot snap{};
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (!session) {
            snap.routeEligible = false;
            snap.bypassReason = BypassReason::NoOutputRoute;
            CopyString(snap.routeLabel, "Unavailable");
            std::lock_guard<std::mutex> lock(gSnapshotMutex);
            gSnapshot = snap;
            return false;
        }

        double sr = session.sampleRate;
        if (sr >= 44000.0 && sr <= 48100.0) {
            gSessionSampleRate.store(sr, std::memory_order_relaxed);
            snap.sampleRate = sr;
        } else {
            snap.sampleRate = gSessionSampleRate.load(std::memory_order_relaxed);
        }

        AVAudioSessionRouteDescription *route = session.currentRoute;
        AVAudioSessionMode mode = session.mode;
        const bool isVoiceMode =
            [mode isEqualToString:AVAudioSessionModeVoiceChat] ||
            [mode isEqualToString:AVAudioSessionModeVideoChat] ||
            [mode isEqualToString:AVAudioSessionModeVoicePrompt];

        if (!route || route.outputs.count == 0) {
            snap.routeEligible = false;
            snap.bypassReason = isVoiceMode ? BypassReason::VoiceOrVideoCall : BypassReason::NoOutputRoute;
            CopyString(snap.routeLabel, "No Output");
            std::lock_guard<std::mutex> lock(gSnapshotMutex);
            gSnapshot = snap;
            return false;
        }

        gHasObservedValidRoute.store(true, std::memory_order_release);

        bool hasHeadphoneOutput = false;
        bool hasDisallowed = false;
        BypassReason disallowedReason = BypassReason::UnsupportedOutput;
        char chosenLabel[48] = "";
        char chosenPortName[96] = "";

        for (AVAudioSessionPortDescription *port in route.outputs) {
            char label[48] = "";
            BypassReason reason = BypassReason::UnsupportedOutput;
            bool isDisallowed = false;
            bool isHeadphone = false;
            DescribePort(port, label, &reason, &isDisallowed, &isHeadphone);

            if (isDisallowed) {
                // Disallowed explicit port (Speaker, Receiver, CarPlay, AirPlay, HDMI, HFP).
                hasDisallowed = true;
                disallowedReason = reason;
                CopyString(chosenLabel, label);
                CopyNSString(chosenPortName, port.portName);
                break;
            }

            if (isHeadphone) {
                hasHeadphoneOutput = true;
                CopyString(chosenLabel, label);
                CopyNSString(chosenPortName, port.portName);
            } else if (chosenLabel[0] == '\0') {
                CopyString(chosenLabel, label);
                CopyNSString(chosenPortName, port.portName);
            }
        }

        CopyString(snap.routeLabel, chosenLabel[0] ? chosenLabel : "Unknown Output");
        CopyString(snap.portName, chosenPortName);

        if (isVoiceMode) {
            snap.routeEligible = false;
            snap.bypassReason = BypassReason::VoiceOrVideoCall;
        } else if (hasDisallowed) {
            snap.routeEligible = false;
            snap.bypassReason = disallowedReason;
        } else if (hasHeadphoneOutput) {
            snap.routeEligible = true;
            snap.bypassReason = BypassReason::None;
        } else {
            snap.routeEligible = false;
            snap.bypassReason = BypassReason::UnsupportedOutput;
        }

        {
            std::lock_guard<std::mutex> lock(gSnapshotMutex);
            gSnapshot = snap;
        }
        return snap.routeEligible;
    }
}

void PostRouteUpdatedOnMain() {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kRouteMonitorDidUpdateNotification object:nil];
    });
}
} // namespace

void RouteMonitor::Initialize() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RefreshNow();

        // Re-evaluate once the app finishes launching on the main queue (during dyld
        // constructor time, AVAudioSession.currentRoute can still be empty/stale).
        dispatch_async(dispatch_get_main_queue(), ^{
            RefreshNow();
            PostRouteUpdatedOnMain();
        });

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        gRouteObserver = [nc addObserverForName:AVAudioSessionRouteChangeNotification
                                         object:nil
                                          queue:nil
                                     usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
            PostRouteUpdatedOnMain();
        }];

        gInterruptionObserver = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                                object:nil
                                                 queue:nil
                                            usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
            PostRouteUpdatedOnMain();
        }];

        gMediaResetObserver = [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                              object:nil
                                               queue:nil
                                          usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
            PostRouteUpdatedOnMain();
        }];

        // Use string literal to avoid adding an unnecessary dependency here.
        gAppActiveObserver = [nc addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                                             object:nil
                                              queue:nil
                                         usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
            PostRouteUpdatedOnMain();
        }];
    });
}

void RouteMonitor::RefreshNow() {
    gRouteEligible.store(EvaluateCurrentRoute(), std::memory_order_relaxed);
}

bool RouteMonitor::IsRouteEligible() {
    if (!gHasObservedValidRoute.load(std::memory_order_acquire)) {
        bool expected = false;
        if (gAsyncRefreshPending.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                RefreshNow();
                gAsyncRefreshPending.store(false, std::memory_order_release);
                PostRouteUpdatedOnMain();
            });
        }
    }
    return gRouteEligible.load(std::memory_order_relaxed);
}

bool RouteMonitor::ShouldProcessAudio() {
    return SpatialConfig::IsEnabled() && IsRouteEligible();
}

double RouteMonitor::CurrentSampleRate() {
    return gSessionSampleRate.load(std::memory_order_relaxed);
}

RouteSnapshot RouteMonitor::GetSnapshot() {
    RefreshNow();
    std::lock_guard<std::mutex> lock(gSnapshotMutex);
    return gSnapshot;
}

} // namespace spatial
