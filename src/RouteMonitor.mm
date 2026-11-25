#include "RouteMonitor.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <atomic>

namespace spatial {

namespace {
std::atomic<bool> gShouldProcess{false};
std::atomic<bool> gHasObservedValidRoute{false};
std::atomic<bool> gAsyncRefreshPending{false};
std::atomic<double> gSessionSampleRate{48000.0};
id gRouteObserver = nil;
id gInterruptionObserver = nil;
id gMediaResetObserver = nil;
id gAppActiveObserver = nil;

bool EvaluateCurrentRoute() {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (!session) return false;

        double sr = session.sampleRate;
        if (sr >= 44000.0 && sr <= 48100.0) {
            gSessionSampleRate.store(sr, std::memory_order_relaxed);
        }

        // Bypass during voice/video calls to avoid distorting voice communication.
        AVAudioSessionMode mode = session.mode;
        if ([mode isEqualToString:AVAudioSessionModeVoiceChat] ||
            [mode isEqualToString:AVAudioSessionModeVideoChat] ||
            [mode isEqualToString:AVAudioSessionModeVoicePrompt]) {
            return false;
        }

        AVAudioSessionRouteDescription *route = session.currentRoute;
        if (!route || route.outputs.count == 0) return false;

        gHasObservedValidRoute.store(true, std::memory_order_release);

        bool hasHeadphoneOutput = false;
        for (AVAudioSessionPortDescription *port in route.outputs) {
            AVAudioSessionPort type = port.portType;

            // Explicitly bypass speakers, receiver, CarPlay, AirPlay, HDMI, and HFP voice hands-free.
            if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
                [type isEqualToString:AVAudioSessionPortBuiltInReceiver] ||
                [type isEqualToString:AVAudioSessionPortCarAudio] ||
                [type isEqualToString:AVAudioSessionPortAirPlay] ||
                [type isEqualToString:AVAudioSessionPortHDMI] ||
                [type isEqualToString:AVAudioSessionPortBluetoothHFP]) {
                return false;
            }

            // Enable on wired headphones, Bluetooth A2DP/LE, and USB DAC/headphones.
            if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
                [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
                [type isEqualToString:AVAudioSessionPortUSBAudio]) {
                hasHeadphoneOutput = true;
            }
        }
        return hasHeadphoneOutput;
    }
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
        });

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        gRouteObserver = [nc addObserverForName:AVAudioSessionRouteChangeNotification
                                         object:nil
                                          queue:nil
                                     usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
        }];

        gInterruptionObserver = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                                object:nil
                                                 queue:nil
                                            usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
        }];

        gMediaResetObserver = [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                              object:nil
                                               queue:nil
                                          usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
        }];

        // Use string literal to avoid adding a UIKit link dependency.
        gAppActiveObserver = [nc addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                                             object:nil
                                              queue:nil
                                         usingBlock:^(NSNotification * _Nonnull note) {
            (void)note;
            RefreshNow();
        }];
    });
}

void RouteMonitor::RefreshNow() {
    gShouldProcess.store(EvaluateCurrentRoute(), std::memory_order_relaxed);
}

bool RouteMonitor::ShouldProcessAudio() {
    if (!gHasObservedValidRoute.load(std::memory_order_acquire)) {
        bool expected = false;
        if (gAsyncRefreshPending.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                RefreshNow();
                gAsyncRefreshPending.store(false, std::memory_order_release);
            });
        }
    }
    return gShouldProcess.load(std::memory_order_relaxed);
}

double RouteMonitor::CurrentSampleRate() {
    return gSessionSampleRate.load(std::memory_order_relaxed);
}

} // namespace spatial
