#include "PipelineCoordinator.h"

#include <atomic>
#include <time.h>

namespace spatial {

namespace {
std::atomic<int> gActivePipeline{static_cast<int>(AudioPipelineKind::None)};
std::atomic<uint64_t> gLastAudioTimeNs{0};
std::atomic<int> gStreamCounts[5] = { {0}, {0}, {0}, {0}, {0} };

// Release exclusive lock if the winning pipeline has not processed audio for 1.5 seconds.
constexpr uint64_t kIdleReleaseTimeoutNs = 1500000000ULL;

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

bool PipelineCoordinator::TryAcquire(AudioPipelineKind kind) {
    if (kind == AudioPipelineKind::None) return false;

    const int desired = static_cast<int>(kind);
    const uint64_t now = MonotonicNowNs();

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

} // namespace spatial
