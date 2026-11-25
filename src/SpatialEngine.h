#ifndef SPATIAL_ENGINE_H
#define SPATIAL_ENGINE_H

#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>

namespace spatial {

// Pre-compute shared 48 kHz and 44.1 kHz True-Stereo HRIR FFT spectra once at load time.
void InitializeSharedSpectra();

// Per-stream Overlap-Save FFT True-Stereo Convolver (zero added latency, zero RT heap allocations).
// Implements exact PC HeSuVi (#2.0.0.1) convolution math:
//   OutL = (L * LL) + (R * RL)
//   OutR = (L * LR) + (R * RR)
class SpatialStreamProcessor {
public:
    SpatialStreamProcessor();
    ~SpatialStreamProcessor();

    SpatialStreamProcessor(const SpatialStreamProcessor&) = delete;
    SpatialStreamProcessor& operator=(const SpatialStreamProcessor&) = delete;

    // Reset overlap history (call on sample rate change or discontinuity).
    void Reset();

    // Process stereo Float32 non-interleaved buffers in-place.
    uint32_t ProcessNonInterleavedFloat32(float *left, float *right, uint32_t frameCount, double sampleRate);

    // Process stereo Float32 interleaved buffer in-place.
    uint32_t ProcessInterleavedFloat32(float *interleaved, uint32_t frameCount, double sampleRate);

    // Process stereo Int16 interleaved buffer in-place.
    uint32_t ProcessInterleavedInt16(int16_t *interleaved, uint32_t frameCount, double sampleRate);

    // Process stereo Int16 non-interleaved buffers in-place.
    uint32_t ProcessNonInterleavedInt16(int16_t *left, int16_t *right, uint32_t frameCount, double sampleRate);

    // Process stereo Int32 interleaved buffer in-place.
    uint32_t ProcessInterleavedInt32(int32_t *interleaved, uint32_t frameCount, double sampleRate);

    // Process stereo Int32 non-interleaved buffers in-place.
    uint32_t ProcessNonInterleavedInt32(int32_t *left, int32_t *right, uint32_t frameCount, double sampleRate);

    // Convenience helper for CoreAudio AudioBufferList (handles Float32, Int16, and Int32 interleaved/non-interleaved).
    uint32_t ProcessAudioBufferList(AudioBufferList *ioData,
                                uint32_t frameCount,
                                const AudioStreamBasicDescription &asbd);

private:
    uint32_t ProcessChunk(float *left, float *right, uint32_t chunkFrames, bool is44k);

    double lastSampleRate_ = 0.0;

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
};

} // namespace spatial

#endif // SPATIAL_ENGINE_H
