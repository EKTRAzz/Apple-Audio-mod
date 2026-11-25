#include "RouteMonitor.h"
#include "PipelineCoordinator.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

namespace spatial {

namespace {
std::atomic<bool> gShouldProcess{false};
std::atomic<bool> gHasObservedValidRoute{false};
std::atomic<bool> gAsyncRefreshPending{false};
std::atomic<double> gSessionSampleRate{48000.0};

std::mutex gRouteDescMutex;
std::string gRouteDesc = "Unknown";

id gRouteObserver = nil;
id gInterruptionObserver = nil;
id gMediaResetObserver = nil;
id gAppActiveObserver = nil;

void SetRouteDesc(const std::string &desc) {
    std::lock_guard<std::mutex> lock(gRouteDescMutex);
    gRouteDesc = desc;
}

bool EvaluateCurrentRoute() {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (!session) {
            SetRouteDesc("No Session");
            return false;
        }

        double sr = session.sampleRate;
        if (sr >= 44000.0 && sr <= 48100.0) {
            gSessionSampleRate.store(sr, std::memory_order_relaxed);
        }

        // Bypass during voice/video calls to avoid distorting voice communication.
        AVAudioSessionMode mode = session.mode;
        if ([mode isEqualToString:AVAudioSessionModeVoiceChat] ||
            [mode isEqualToString:AVAudioSessionModeVideoChat] ||
            [mode isEqualToString:AVAudioSessionModeVoicePrompt]) {
            SetRouteDesc("Voice/Call Mode");
            return false;
        }

        AVAudioSessionRouteDescription *route = session.currentRoute;
        if (!route || route.outputs.count == 0) {
            SetRouteDesc("No Output");
            return false;
        }

        gHasObservedValidRoute.store(true, std::memory_order_release);

        bool hasHeadphoneOutput = false;
        std::string portsSummary;
        bool blockedPort = false;

        for (AVAudioSessionPortDescription *port in route.outputs) {
            AVAudioSessionPort type = port.portType;
            const char *cType = type ? [type UTF8String] : "Unknown";
            if (!portsSummary.empty()) portsSummary += "+";
            portsSummary += cType;

            // Explicitly bypass speakers, receiver, CarPlay, AirPlay, HDMI, and HFP voice hands-free.
            if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
                [type isEqualToString:AVAudioSessionPortBuiltInReceiver] ||
                [type isEqualToString:AVAudioSessionPortCarAudio] ||
                [type isEqualToString:AVAudioSessionPortAirPlay] ||
                [type isEqualToString:AVAudioSessionPortHDMI] ||
                [type isEqualToString:AVAudioSessionPortBluetoothHFP]) {
                blockedPort = true;
            }

            // Enable on wired headphones, Bluetooth A2DP/LE, and USB DAC/headphones.
            if ([type isEqualToString:AVAudioSessionPortHeadphones] ||
                [type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
                [type isEqualToString:AVAudioSessionPortUSBAudio]) {
                hasHeadphoneOutput = true;
            }
        }

        SetRouteDesc(portsSummary.empty() ? "Unknown" : portsSummary);
        return (!blockedPort && hasHeadphoneOutput);
    }
}
} // namespace

void RouteMonitor::Initialize() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        RefreshNow();

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

bool RouteMonitor::IsHeadphoneRouteActive() {
    return gShouldProcess.load(std::memory_order_relaxed);
}

bool RouteMonitor::ShouldProcessAudio() {
    if (!PipelineCoordinator::IsMasterEnabled()) {
        return false;
    }
    if (!gHasObservedValidRoute.load(std::memory_order_acquire)) {
        bool expected = false;
        if (gAsyncRefreshPending.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                RefreshNow();
                gAsyncRefreshPending.store(false, std::memory_order_release);
            });
        }
    }
    if (PipelineCoordinator::IsForceOutput()) {
        return true;
    }
    return gShouldProcess.load(std::memory_order_relaxed);
}

double RouteMonitor::CurrentSampleRate() {
    return gSessionSampleRate.load(std::memory_order_relaxed);
}

void RouteMonitor::GetRouteDescription(char *outBuf, size_t bufSize) {
    if (!outBuf || bufSize == 0) return;
    std::lock_guard<std::mutex> lock(gRouteDescMutex);
    std::strncpy(outBuf, gRouteDesc.c_str(), bufSize - 1);
    outBuf[bufSize - 1] = '\0';
}

} // namespace spatial
