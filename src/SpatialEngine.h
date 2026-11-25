#ifndef SPATIAL_ENGINE_H
#define SPATIAL_ENGINE_H

#include "SpatialConfig.h"

#include <AudioToolbox/AudioToolbox.h>
#include <atomic>
#include <stdint.h>
#include <string>

namespace spatial {

struct SpatialDspParams {
    SpatialMode mode = SpatialMode::Matrix;
    float mix = 1.0f;       // 0.0f .. 1.0f
    float gainDb = -2.5f;   // -6.0f .. +4.0f
    float width = 1.0f;     // 0.5f .. 1.8f
};

inline SpatialDspParams CurrentDspParamsFromConfig() {
    SpatialDspParams p;
    p.mode = SpatialConfig::CurrentMode();
    p.mix = SpatialConfig::SpatialMix();
    p.gainDb = SpatialConfig::OutputGainDb();
    p.width = SpatialConfig::SpatialWidth();
    return p;
}

// Pre-compute shared 48 kHz and 44.1 kHz Matrix & Front True-Stereo HRIR FFT spectra once at load time.
void InitializeSharedSpectra();

// Load a custom 2/4/14-ch RIFF/WAVE HRIR into a double-buffered spectrum slot (lock-free switch).
bool LoadCustomWavProfile(const char *path, std::string &outError);
bool UseCustomProfile();
void UseBuiltInProfile();
bool HasLoadedCustomProfile();

// Per-stream Overlap-Save FFT True-Stereo Convolver (zero added latency, zero RT heap allocations).
// Implements exact PC HeSuVi (#2.0.0.1) convolution math:
//   OutL = (L * LL) + (R * RL)
//   OutR = (L * LR) + (R * RR)
// Supports click-free ~10 ms crossfades on On/Off bypass, Matrix/Front, and Built-in/Custom WAV switches.
class SpatialStreamProcessor {
public:
    SpatialStreamProcessor();
    ~SpatialStreamProcessor();

    SpatialStreamProcessor(const SpatialStreamProcessor&) = delete;
    SpatialStreamProcessor& operator=(const SpatialStreamProcessor&) = delete;

    // Reset overlap history and transition state (call on sample rate change or discontinuity).
    void Reset();

    // True when spatial audio is wanted OR a short fade-out to dry bypass is still completing.
    bool NeedsProcessing(bool wantSpatial) const;

    // Process stereo Float32 non-interleaved buffers in-place.
    void ProcessNonInterleavedFloat32(float *left,
                                      float *right,
                                      uint32_t frameCount,
                                      double sampleRate,
                                      bool wantSpatial = true,
                                      const SpatialDspParams &params = SpatialDspParams{});

    // Process stereo Float32 interleaved buffer in-place.
    void ProcessInterleavedFloat32(float *interleaved,
                                   uint32_t frameCount,
                                   double sampleRate,
                                   bool wantSpatial = true,
                                   const SpatialDspParams &params = SpatialDspParams{});

    // Process stereo Int16 interleaved buffer in-place.
    void ProcessInterleavedInt16(int16_t *interleaved,
                                 uint32_t frameCount,
                                 double sampleRate,
                                 bool wantSpatial = true,
                                 const SpatialDspParams &params = SpatialDspParams{});

    // Process stereo Int16 non-interleaved buffers in-place.
    void ProcessNonInterleavedInt16(int16_t *left,
                                    int16_t *right,
                                    uint32_t frameCount,
                                    double sampleRate,
                                    bool wantSpatial = true,
                                    const SpatialDspParams &params = SpatialDspParams{});

    // Process stereo Int32 interleaved buffer in-place.
    void ProcessInterleavedInt32(int32_t *interleaved,
                                 uint32_t frameCount,
                                 double sampleRate,
                                 bool wantSpatial = true,
                                 const SpatialDspParams &params = SpatialDspParams{});

    // Process stereo Int32 non-interleaved buffers in-place.
    void ProcessNonInterleavedInt32(int32_t *left,
                                    int32_t *right,
                                    uint32_t frameCount,
                                    double sampleRate,
                                    bool wantSpatial = true,
                                    const SpatialDspParams &params = SpatialDspParams{});

    // Convenience helper for CoreAudio AudioBufferList (handles Float32, Int16, and Int32 interleaved/non-interleaved).
    void ProcessAudioBufferList(AudioBufferList *ioData,
                                uint32_t frameCount,
                                const AudioStreamBasicDescription &asbd,
                                bool wantSpatial = true,
                                const SpatialDspParams &params = SpatialDspParams{});

private:
    bool PrepareForStream(double sampleRate, bool &outIs44k, bool wantSpatial, const SpatialDspParams &params);
    uint32_t NextChunkSize(uint32_t remaining, bool wantSpatial) const;
    void ProcessChunk(float *left,
                      float *right,
                      uint32_t chunkFrames,
                      bool is44k,
                      bool wantSpatial,
                      const SpatialDspParams &params);
    void ConvolveToTimeDomain(const float *xLRe,
                              const float *xLIm,
                              const float *xRRe,
                              const float *xRIm,
                              bool is44k,
                              int profileSlot,
                              SpatialMode mode);

    template <typename LoadFn, typename StoreFn>
    void ProcessFormatted(uint32_t frameCount,
                          double sampleRate,
                          bool wantSpatial,
                          const SpatialDspParams &params,
                          LoadFn &&loadChunk,
                          StoreFn &&storeChunk);

    double lastSampleRate_ = 0.0;
    std::atomic<bool> wetActive_{false};
    float wetGain_ = 0.0f;

    float smoothedMix_ = 1.0f;
    float smoothedGainLin_ = 0.7498942f; // 10^(-2.5/20)
    float smoothedWidth_ = 1.0f;

    int activeSlot_ = -1;
    int prevSlot_ = -1;
    SpatialMode activeMode_ = SpatialMode::Matrix;
    SpatialMode prevMode_ = SpatialMode::Matrix;
    uint32_t irFadeRemaining_ = 0;

    // Overlap-Save history of last SPATIAL_IR_LEN samples per channel.
    float *histL_ = nullptr;
    float *histR_ = nullptr;

    // Scratch time-domain buffers of size SPATIAL_FFT_N.
    float *timeL_ = nullptr;
    float *timeR_ = nullptr;

    // Scratch split-complex frequency-domain buffers of size SPATIAL_FFT_N / 2.
    float *freqL_Re_ = nullptr;
    float *freqL_Im_ = nullptr;
    float *freqR_Re_ = nullptr;
    float *freqR_Im_ = nullptr;
    float *accRe_    = nullptr;
    float *accIm_    = nullptr;
    float *tmpRe_    = nullptr;
    float *tmpIm_    = nullptr;

    // Scratch de-interleave buffers (for Float32/Int16/Int32 streams).
    float *deintL_ = nullptr;
    float *deintR_ = nullptr;

    // Scratch crossfade buffers (size kCrossfadeFrames) for click-free Matrix <-> Front / Profile switching.
    float *fadeOldL_ = nullptr;
    float *fadeOldR_ = nullptr;
};

} // namespace spatial

#endif // SPATIAL_ENGINE_H
