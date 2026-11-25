#include "PipelineCoordinator.h"

#import <Foundation/Foundation.h>
#include <atomic>
#include <time.h>

namespace spatial {

namespace {
NSString *const kPrefMasterEnabled = @"SpatialAudioMod_MasterEnabled";
NSString *const kPrefPipeline      = @"SpatialAudioMod_PreferredPipeline";
NSString *const kPrefForceOutput   = @"SpatialAudioMod_ForceOutput";

std::atomic<bool> gMasterEnabled{true};
std::atomic<int>  gPreferredPipeline{static_cast<int>(AudioPipelineKind::None)};
std::atomic<bool> gForceOutput{false};

std::atomic<int> gActivePipeline{static_cast<int>(AudioPipelineKind::None)};
std::atomic<uint64_t> gLastAudioTimeNs{0};
std::atomic<uint64_t> gLastProcessedTimeNs{0};
std::atomic<double> gLastProcessedSampleRate{0.0};

std::atomic<int> gStreamCounts[5] = { {0}, {0}, {0}, {0}, {0} };
std::atomic<uint64_t> gSeenCounts[5] = { {0}, {0}, {0}, {0}, {0} };
std::atomic<uint64_t> gProcessedCounts[5] = { {0}, {0}, {0}, {0}, {0} };
std::atomic<uint64_t> gLastSeenNs[5] = { {0}, {0}, {0}, {0}, {0} };
std::atomic<uint64_t> gLastProcNs[5] = { {0}, {0}, {0}, {0}, {0} };

// Release exclusive lock if the winning pipeline has not processed audio for 1.5 seconds.
constexpr uint64_t kIdleReleaseTimeoutNs = 1500000000ULL;
// Consider a pipeline "recently active" in the UI if seen/processed within the last 1.5 seconds.
constexpr uint64_t kRecentActivityWindowNs = 1500000000ULL;

thread_local int tDspDepth = 0;

inline uint64_t MonotonicNowNs() {
#if defined(CLOCK_UPTIME_RAW)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL + static_cast<uint64_t>(ts.tv_nsec);
#endif
}
} // namespace

ScopedDspGuard::ScopedDspGuard() {
    if (tDspDepth == 0) {
        tDspDepth = 1;
        entered = true;
    }
}

ScopedDspGuard::~ScopedDspGuard() {
    if (entered) {
        tDspDepth = 0;
    }
}

void PipelineCoordinator::LoadSettings() {
    @autoreleasepool {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([ud objectForKey:kPrefMasterEnabled] != nil) {
            gMasterEnabled.store([ud boolForKey:kPrefMasterEnabled], std::memory_order_relaxed);
        }
        if ([ud objectForKey:kPrefPipeline] != nil) {
            NSInteger raw = [ud integerForKey:kPrefPipeline];
            if (raw >= 0 && raw <= 4) {
                gPreferredPipeline.store(static_cast<int>(raw), std::memory_order_relaxed);
            }
        }
        if ([ud objectForKey:kPrefForceOutput] != nil) {
            gForceOutput.store([ud boolForKey:kPrefForceOutput], std::memory_order_relaxed);
        }
    }
}

void PipelineCoordinator::SetMasterEnabled(bool enabled) {
    gMasterEnabled.store(enabled, std::memory_order_release);
    if (!enabled) {
        gActivePipeline.store(static_cast<int>(AudioPipelineKind::None), std::memory_order_release);
    }
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefMasterEnabled];
    }
}

bool PipelineCoordinator::IsMasterEnabled() {
    return gMasterEnabled.load(std::memory_order_acquire);
}

void PipelineCoordinator::SetPreferredPipeline(AudioPipelineKind kind) {
    int val = static_cast<int>(kind);
    if (val < 0 || val > 4) val = 0;
    gPreferredPipeline.store(val, std::memory_order_release);
    // Reset current winner so the newly selected pipeline can acquire immediately without waiting.
    gActivePipeline.store(static_cast<int>(AudioPipelineKind::None), std::memory_order_release);
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setInteger:val forKey:kPrefPipeline];
    }
}

AudioPipelineKind PipelineCoordinator::PreferredPipeline() {
    return static_cast<AudioPipelineKind>(gPreferredPipeline.load(std::memory_order_acquire));
}

void PipelineCoordinator::SetForceOutput(bool force) {
    gForceOutput.store(force, std::memory_order_release);
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:force forKey:kPrefForceOutput];
    }
}

bool PipelineCoordinator::IsForceOutput() {
    return gForceOutput.load(std::memory_order_acquire);
}

void PipelineCoordinator::RecordPipelineSeen(AudioPipelineKind kind) {
    int idx = static_cast<int>(kind);
    if (idx < 1 || idx > 4) return;
    gSeenCounts[idx].fetch_add(1, std::memory_order_relaxed);
    gLastSeenNs[idx].store(MonotonicNowNs(), std::memory_order_relaxed);
}

void PipelineCoordinator::RecordPipelineProcessed(AudioPipelineKind kind, double sampleRate) {
    int idx = static_cast<int>(kind);
    if (idx < 1 || idx > 4) return;
    const uint64_t now = MonotonicNowNs();
    gProcessedCounts[idx].fetch_add(1, std::memory_order_relaxed);
    gLastProcNs[idx].store(now, std::memory_order_relaxed);
    gLastProcessedTimeNs.store(now, std::memory_order_relaxed);
    if (sampleRate > 0.0) {
        gLastProcessedSampleRate.store(sampleRate, std::memory_order_relaxed);
    }
}

bool PipelineCoordinator::TryAcquire(AudioPipelineKind kind) {
    if (kind == AudioPipelineKind::None) return false;
    if (!gMasterEnabled.load(std::memory_order_acquire)) return false;

    const int desired = static_cast<int>(kind);
    const uint64_t now = MonotonicNowNs();

    // Manual pipeline lock: only allow the user-selected pipeline.
    const int preferred = gPreferredPipeline.load(std::memory_order_acquire);
    if (preferred != static_cast<int>(AudioPipelineKind::None)) {
        if (desired != preferred) {
            return false;
        }
        gActivePipeline.store(desired, std::memory_order_release);
        gLastAudioTimeNs.store(now, std::memory_order_relaxed);
        return true;
    }

    int current = gActivePipeline.load(std::memory_order_acquire);

    // Fast path: already the winning primary pipeline.
    if (current == desired) {
        gLastAudioTimeNs.store(now, std::memory_order_relaxed);
        return true;
    }

    // No active winner yet: claim ownership.
    if (current == static_cast<int>(AudioPipelineKind::None)) {
        if (gActivePipeline.compare_exchange_strong(current, desired, std::memory_order_acq_rel)) {
            gLastAudioTimeNs.store(now, std::memory_order_relaxed);
            return true;
        }
        return false;
    }

    // Another pipeline owns the lock. Only take over if the previous winner has been idle.
    const uint64_t last = gLastAudioTimeNs.load(std::memory_order_relaxed);
    if (now > last && (now - last) > kIdleReleaseTimeoutNs) {
        if (gActivePipeline.compare_exchange_strong(current, desired, std::memory_order_acq_rel)) {
            gLastAudioTimeNs.store(now, std::memory_order_relaxed);
            return true;
        }
    }

    return false;
}

void PipelineCoordinator::RegisterStream(AudioPipelineKind kind) {
    int idx = static_cast<int>(kind);
    if (idx >= 1 && idx <= 4) {
        gStreamCounts[idx].fetch_add(1, std::memory_order_relaxed);
    }
}

void PipelineCoordinator::UnregisterStream(AudioPipelineKind kind) {
    int idx = static_cast<int>(kind);
    if (idx < 1 || idx > 4) return;

    int prev = gStreamCounts[idx].fetch_sub(1, std::memory_order_acq_rel);
    if (prev <= 1) {
        if (prev < 1) {
            gStreamCounts[idx].store(0, std::memory_order_relaxed);
        }
        // Immediately release exclusive ownership so another pipeline can take over without waiting.
        int expected = idx;
        gActivePipeline.compare_exchange_strong(
            expected,
            static_cast<int>(AudioPipelineKind::None),
            std::memory_order_acq_rel
        );
    }
}

AudioPipelineKind PipelineCoordinator::ActivePipeline() {
    return static_cast<AudioPipelineKind>(gActivePipeline.load(std::memory_order_acquire));
}

PipelineTelemetry PipelineCoordinator::SnapshotTelemetry() {
    PipelineTelemetry t{};
    const uint64_t now = MonotonicNowNs();
    t.masterEnabled = gMasterEnabled.load(std::memory_order_acquire);
    t.forceOutput = gForceOutput.load(std::memory_order_acquire);
    t.preferredPipeline = static_cast<AudioPipelineKind>(gPreferredPipeline.load(std::memory_order_acquire));
    t.activePipeline = static_cast<AudioPipelineKind>(gActivePipeline.load(std::memory_order_acquire));
    t.activeSampleRate = gLastProcessedSampleRate.load(std::memory_order_relaxed);

    const uint64_t lastProc = gLastProcessedTimeNs.load(std::memory_order_relaxed);
    t.dspActiveNow = t.masterEnabled && (lastProc > 0 && now >= lastProc && (now - lastProc) <= kRecentActivityWindowNs);

    for (int i = 1; i <= 4; ++i) {
        t.seenCounts[i] = gSeenCounts[i].load(std::memory_order_relaxed);
        t.processedCounts[i] = gProcessedCounts[i].load(std::memory_order_relaxed);
        uint64_t ls = gLastSeenNs[i].load(std::memory_order_relaxed);
        uint64_t lp = gLastProcNs[i].load(std::memory_order_relaxed);
        t.seenRecently[i] = (ls > 0 && now >= ls && (now - ls) <= kRecentActivityWindowNs);
        t.processedRecently[i] = (lp > 0 && now >= lp && (now - lp) <= kRecentActivityWindowNs);
    }
    return t;
}

const char *PipelineCoordinator::PipelineName(AudioPipelineKind kind) {
    switch (kind) {
        case AudioPipelineKind::AudioUnit:            return "AudioUnit";
        case AudioPipelineKind::AudioQueue:           return "AudioQueue";
        case AudioPipelineKind::AVPlayer:             return "AVPlayer";
        case AudioPipelineKind::SampleBufferRenderer: return "SampleBuffer";
        case AudioPipelineKind::None:
        default:                                      return "Auto";
    }
}

} // namespace spatial
