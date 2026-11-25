#ifndef SPATIAL_PIPELINE_COORDINATOR_H
#define SPATIAL_PIPELINE_COORDINATOR_H

#include <stdint.h>

namespace spatial {

enum class AudioPipelineKind : int {
    None                 = 0,
    AudioUnit            = 1,  // AudioUnit / AUGraph / AVAudioEngine (RemoteIO / VoiceProcessingIO)
    AudioQueue           = 2,  // AudioToolbox AudioQueue (Linear PCM)
    AVPlayer             = 3,  // AVFoundation AVPlayer / AVQueuePlayer (MTAudioProcessingTap)
    SampleBufferRenderer = 4,  // AVFoundation AVSampleBufferAudioRenderer (PCM & in-process AAC/Opus decode)
};

// Single-Winner Exclusive Pipeline Coordinator:
// - Whichever hookable pipeline delivers real audio first becomes the sole active owner.
// - All other pipelines immediately pass through untouched while the winner is active.
// - If the active owner disposes all its streams or goes silent for >1.5s, ownership
//   releases automatically so another pipeline can take over cleanly if the app switches players.
class PipelineCoordinator {
public:
    // Call on real-time audio thread before running DSP.
    // Returns true ONLY if this pipeline owns the exclusive lock and is not re-entering.
    static bool TryAcquire(AudioPipelineKind kind);

    // Track live stream instances per pipeline for instant handoff on dispose.
    static void RegisterStream(AudioPipelineKind kind);
    static void UnregisterStream(AudioPipelineKind kind);

    // Current winning pipeline (for diagnostics/logging).
    static AudioPipelineKind ActivePipeline();
};

// RAII per-thread re-entrancy guard (prevents nested callbacks on the same thread from double-DSP).
struct ScopedDspGuard {
    bool entered = false;
    ScopedDspGuard();
    ~ScopedDspGuard();
    ScopedDspGuard(const ScopedDspGuard&) = delete;
    ScopedDspGuard& operator=(const ScopedDspGuard&) = delete;
};

} // namespace spatial

#endif // SPATIAL_PIPELINE_COORDINATOR_H
