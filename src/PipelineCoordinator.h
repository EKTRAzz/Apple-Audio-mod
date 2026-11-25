#ifndef SPATIAL_PIPELINE_COORDINATOR_H
#define SPATIAL_PIPELINE_COORDINATOR_H

#include <stdint.h>

namespace spatial {

enum class AudioPipelineKind : int {
    None                 = 0,  // Auto mode (when used as PreferredPipeline) / Inactive (when ActivePipeline)
    AudioUnit            = 1,  // AudioUnit / AUGraph / AVAudioEngine (RemoteIO / VoiceProcessingIO)
    AudioQueue           = 2,  // AudioToolbox AudioQueue (Linear PCM)
    AVPlayer             = 3,  // AVFoundation AVPlayer / AVQueuePlayer (MTAudioProcessingTap)
    SampleBufferRenderer = 4,  // AVFoundation AVSampleBufferAudioRenderer (PCM & in-process AAC/Opus decode)
};

struct PipelineTelemetry {
    bool masterEnabled = true;
    bool forceOutput = false;
    bool dspActiveNow = false;
    AudioPipelineKind preferredPipeline = AudioPipelineKind::None;
    AudioPipelineKind activePipeline = AudioPipelineKind::None;
    double activeSampleRate = 0.0;
    uint64_t seenCounts[5] = {0, 0, 0, 0, 0};
    uint64_t processedCounts[5] = {0, 0, 0, 0, 0};
    bool seenRecently[5] = {false, false, false, false, false};
    bool processedRecently[5] = {false, false, false, false, false};
};

// Single-Winner Exclusive Pipeline Coordinator + Lock-Free User Controls & Telemetry:
// - Whichever hookable pipeline delivers real audio first becomes the sole active owner (Auto mode),
//   or only the user-selected pipeline is allowed to run (Manual mode).
// - All other pipelines immediately pass through untouched while the winner is active.
// - If the active owner disposes all its streams or goes silent for >1.5s, ownership
//   releases automatically so another pipeline can take over cleanly if the app switches players.
class PipelineCoordinator {
public:
    // Load persisted user preferences (call once at startup).
    static void LoadSettings();

    // Lock-free user controls (safe to call from UI thread; read on RT audio thread).
    static void SetMasterEnabled(bool enabled);
    static bool IsMasterEnabled();

    // AudioPipelineKind::None means Auto (Single-Winner).
    static void SetPreferredPipeline(AudioPipelineKind kind);
    static AudioPipelineKind PreferredPipeline();

    static void SetForceOutput(bool force);
    static bool IsForceOutput();

    // Call on real-time audio thread whenever a hook observes incoming audio (even if bypassed).
    static void RecordPipelineSeen(AudioPipelineKind kind);

    // Call on real-time audio thread right when DSP actually processes audio frames.
    static void RecordPipelineProcessed(AudioPipelineKind kind, double sampleRate, uint32_t frames);

    // Call on real-time audio thread before running DSP.
    // Returns true ONLY if master is enabled, pipeline is allowed, and it owns the exclusive lock.
    static bool TryAcquire(AudioPipelineKind kind);

    // Track live stream instances per pipeline for instant handoff on dispose.
    static void RegisterStream(AudioPipelineKind kind);
    static void UnregisterStream(AudioPipelineKind kind);

    // Current winning pipeline (for diagnostics/UI).
    static AudioPipelineKind ActivePipeline();

    // Snapshot of telemetry for the overlay UI (called on main thread).
    static PipelineTelemetry SnapshotTelemetry();

    // Human-readable name for a pipeline.
    static const char *PipelineName(AudioPipelineKind kind);
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
