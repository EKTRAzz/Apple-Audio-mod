#ifndef SPATIAL_AUDIO_UNIT_BRIDGE_H
#define SPATIAL_AUDIO_UNIT_BRIDGE_H

#include <CoreMedia/CoreMedia.h>
#include <atomic>
#include <deque>
#include <mutex>
#include <stdint.h>
#include <vector>

namespace spatial {

struct TimedPcmChunk {
    double startPtsSec = 0.0;
    double sampleRate = 48000.0;
    uint32_t readOffset = 0;
    std::vector<float> left;
    std::vector<float> right;
};

// Thread-safe bounded PTS-indexed PCM queue.
// Push/Flush run on media enqueue threads; PullFrames uses try_lock on RT audio thread.
class BridgeTimedQueue {
public:
    static constexpr size_t kMaxBufferedFrames = 48000u * 45u; // ~45s cap (~17 MB worst case)

    void Push(double startPtsSec,
              double sampleRate,
              const float *left,
              const float *right,
              uint32_t frameCount);

    void FlushAll();
    void FlushFromTime(double fromPtsSec);

    // Pull outFrames aligned to syncTimeSec/rate. Never blocks RT thread (outputs silence on contention).
    void PullFrames(double syncTimeSec,
                    double rate,
                    float *outL,
                    float *outR,
                    uint32_t outFrames,
                    double outSampleRate,
                    bool *outHadAudio);

    bool HasQueuedAudio() const;
    size_t BufferedFrames() const;

private:
    mutable std::mutex mutex_;
    std::deque<TimedPcmChunk> chunks_;
    size_t totalFrames_ = 0;
    double fracOffset_ = 0.0;
    std::atomic<bool> hasAudio_{false};
};

// Singleton RemoteIO AudioUnit bridge for low-latency playback of SampleBufferRenderer streams.
class AudioUnitBridge {
public:
    static AudioUnitBridge &Shared();

    void SetSynchronizerTimebase(CMTimebaseRef timebase);
    void ClearSynchronizerTimebase(CMTimebaseRef expectedTimebase);

    void SetVolume(float volume);
    void SetMuted(bool muted);

    void PushAudio(double startPtsSec,
                   double sampleRate,
                   const float *left,
                   const float *right,
                   uint32_t frameCount);

    void FlushAll();
    void FlushFromTime(double fromPtsSec);
    void Stop();

    bool IsActive() const;
    bool HasQueuedAudio() const;
    double OutputSampleRate() const;
};

} // namespace spatial

#endif // SPATIAL_AUDIO_UNIT_BRIDGE_H
