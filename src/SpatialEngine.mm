#include "SpatialEngine.h"
#include "ir_data.h"

#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

// Default headroom: -2.5 dB (prevents clipping on +2.4 dB worst-case mono peaks while matching PC HeSuVi loudness).
// Override at compile time with -DSPATIAL_HEADROOM_DB=-4.0f (or 0.0f for raw PC unity).
#ifndef SPATIAL_HEADROOM_DB
#define SPATIAL_HEADROOM_DB (-2.5f)
#endif

namespace spatial {

namespace {

constexpr uint32_t kFftN      = SPATIAL_FFT_N;               // 16384
constexpr uint32_t kHalfN     = SPATIAL_FFT_N / 2;           // 8192
constexpr uint32_t kIrLen     = SPATIAL_IR_LEN;              // 8400 (zero truncation of Apple_Pro2_Stereo.wav)
constexpr uint32_t kMaxChunk  = kFftN - kIrLen;              // 7984 frames per Overlap-Save pass

struct TrueStereoSpectrum {
    float *llRe, *llIm;
    float *lrRe, *lrIm;
    float *rlRe, *rlIm;
    float *rrRe, *rrIm;
};

FFTSetup gFftSetup = nullptr;
TrueStereoSpectrum gSpec48{};
TrueStereoSpectrum gSpec44{};

float *AllocAligned(size_t count) {
    void *ptr = nullptr;
    if (posix_memalign(&ptr, 64, count * sizeof(float)) != 0 || !ptr) {
        return nullptr;
    }
    std::memset(ptr, 0, count * sizeof(float));
    return static_cast<float *>(ptr);
}

void BuildIrSpectrum(const float *ir, float *outRe, float *outIm, float combinedScale) {
    float *padded = AllocAligned(kFftN);
    if (!padded) return;

    // Pre-scale IR by headroom / (4 * FFT_N) so forward(x) * forward(h) -> inverse(y) has exact gain.
    vDSP_vsmul(ir, 1, &combinedScale, padded, 1, kIrLen);

    DSPSplitComplex split{outRe, outIm};
    vDSP_ctoz(reinterpret_cast<const DSPComplex *>(padded), 2, &split, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &split, 1, SPATIAL_FFT_LOG2, kFFTDirection_Forward);

    std::free(padded);
}

// Multiply two packed vDSP_fft_zrip spectra cleanly, handling DC (realp[0]) and Nyquist (imagp[0]) separately.
inline void MultiplyPackedSpectra(const DSPSplitComplex &a,
                                  const DSPSplitComplex &b,
                                  DSPSplitComplex &out) {
    // Bin 0 holds {DC, Nyquist} as two independent real values.
    const float dc  = a.realp[0] * b.realp[0];
    const float nyq = a.imagp[0] * b.imagp[0];

    // Bins 1 .. kHalfN-1 are standard complex pairs.
    DSPSplitComplex aSub{a.realp + 1, a.imagp + 1};
    DSPSplitComplex bSub{b.realp + 1, b.imagp + 1};
    DSPSplitComplex oSub{out.realp + 1, out.imagp + 1};
    vDSP_zvmul(&aSub, 1, &bSub, 1, &oSub, 1, kHalfN - 1, 1);

    out.realp[0] = dc;
    out.imagp[0] = nyq;
}

// Soft clipper above +/-0.985f to protect against rare transient overs without coloring normal playback.
inline void SoftClipBuffer(float *buf, uint32_t count) {
    constexpr float kThresh = 0.985f;
    constexpr float kRange  = 1.0f - kThresh;
    for (uint32_t i = 0; i < count; ++i) {
        float x = buf[i];
        if (x > kThresh) {
            buf[i] = kThresh + kRange * std::tanhf((x - kThresh) / kRange);
        } else if (x < -kThresh) {
            buf[i] = -kThresh - kRange * std::tanhf((-x - kThresh) / kRange);
        }
    }
}

inline bool IsSupportedSampleRate(double sr, bool &outIs44k) {
    if (sr >= 47900.0 && sr <= 48100.0) {
        outIs44k = false;
        return true;
    }
    if (sr >= 44000.0 && sr <= 44200.0) {
        outIs44k = true;
        return true;
    }
    return false;
}

} // namespace

void InitializeSharedSpectra() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gFftSetup = vDSP_create_fftsetup(SPATIAL_FFT_LOG2, kFFTRadix2);
        if (!gFftSetup) return;

        // vDSP_fft_zrip forward scales by 2, so X*H scales by 4; inverse scales by N -> total 4*N.
        const float headroomLinear = std::powf(10.0f, static_cast<float>(SPATIAL_HEADROOM_DB) / 20.0f);
        const float combinedScale  = headroomLinear / (4.0f * static_cast<float>(kFftN));

        auto allocSpec = [](TrueStereoSpectrum &s) {
            s.llRe = AllocAligned(kHalfN); s.llIm = AllocAligned(kHalfN);
            s.lrRe = AllocAligned(kHalfN); s.lrIm = AllocAligned(kHalfN);
            s.rlRe = AllocAligned(kHalfN); s.rlIm = AllocAligned(kHalfN);
            s.rrRe = AllocAligned(kHalfN); s.rrIm = AllocAligned(kHalfN);
        };

        allocSpec(gSpec48);
        BuildIrSpectrum(kIR48_LL, gSpec48.llRe, gSpec48.llIm, combinedScale);
        BuildIrSpectrum(kIR48_LR, gSpec48.lrRe, gSpec48.lrIm, combinedScale);
        BuildIrSpectrum(kIR48_RL, gSpec48.rlRe, gSpec48.rlIm, combinedScale);
        BuildIrSpectrum(kIR48_RR, gSpec48.rrRe, gSpec48.rrIm, combinedScale);

        allocSpec(gSpec44);
        BuildIrSpectrum(kIR44_LL, gSpec44.llRe, gSpec44.llIm, combinedScale);
        BuildIrSpectrum(kIR44_LR, gSpec44.lrRe, gSpec44.lrIm, combinedScale);
        BuildIrSpectrum(kIR44_RL, gSpec44.rlRe, gSpec44.rlIm, combinedScale);
        BuildIrSpectrum(kIR44_RR, gSpec44.rrRe, gSpec44.rrIm, combinedScale);
    });
}

SpatialStreamProcessor::SpatialStreamProcessor() {
    InitializeSharedSpectra();

    histL_    = AllocAligned(kIrLen);
    histR_    = AllocAligned(kIrLen);
    timeL_    = AllocAligned(kFftN);
    timeR_    = AllocAligned(kFftN);
    freqL_Re_ = AllocAligned(kHalfN);
    freqL_Im_ = AllocAligned(kHalfN);
    freqR_Re_ = AllocAligned(kHalfN);
    freqR_Im_ = AllocAligned(kHalfN);
    accRe_    = AllocAligned(kHalfN);
    accIm_    = AllocAligned(kHalfN);
    tmpRe_    = AllocAligned(kHalfN);
    tmpIm_    = AllocAligned(kHalfN);
    deintL_   = AllocAligned(kMaxChunk);
    deintR_   = AllocAligned(kMaxChunk);
}

SpatialStreamProcessor::~SpatialStreamProcessor() {
    std::free(histL_);
    std::free(histR_);
    std::free(timeL_);
    std::free(timeR_);
    std::free(freqL_Re_);
    std::free(freqL_Im_);
    std::free(freqR_Re_);
    std::free(freqR_Im_);
    std::free(accRe_);
    std::free(accIm_);
    std::free(tmpRe_);
    std::free(tmpIm_);
    std::free(deintL_);
    std::free(deintR_);
}

void SpatialStreamProcessor::Reset() {
    if (histL_) std::memset(histL_, 0, kIrLen * sizeof(float));
    if (histR_) std::memset(histR_, 0, kIrLen * sizeof(float));
}

void SpatialStreamProcessor::ProcessChunk(float *left, float *right, uint32_t chunkFrames, bool is44k) {
    if (!gFftSetup || !histL_ || !histR_ || !timeL_ || !timeR_ || chunkFrames == 0 || chunkFrames > kMaxChunk) {
        return;
    }

    const TrueStereoSpectrum &spec = is44k ? gSpec44 : gSpec48;

    // 1. Assemble Overlap-Save input blocks: [hist (kIrLen) | new input (chunkFrames) | zeros]
    std::memcpy(timeL_, histL_, kIrLen * sizeof(float));
    std::memcpy(timeL_ + kIrLen, left, chunkFrames * sizeof(float));
    const uint32_t tailZeros = kFftN - (kIrLen + chunkFrames);
    if (tailZeros > 0) {
        std::memset(timeL_ + kIrLen + chunkFrames, 0, tailZeros * sizeof(float));
    }

    std::memcpy(timeR_, histR_, kIrLen * sizeof(float));
    std::memcpy(timeR_ + kIrLen, right, chunkFrames * sizeof(float));
    if (tailZeros > 0) {
        std::memset(timeR_ + kIrLen + chunkFrames, 0, tailZeros * sizeof(float));
    }

    // 2. Slide input history forward by chunkFrames (before overwriting left/right in-place).
    if (chunkFrames < kIrLen) {
        std::memmove(histL_, histL_ + chunkFrames, (kIrLen - chunkFrames) * sizeof(float));
        std::memcpy(histL_ + (kIrLen - chunkFrames), left, chunkFrames * sizeof(float));

        std::memmove(histR_, histR_ + chunkFrames, (kIrLen - chunkFrames) * sizeof(float));
        std::memcpy(histR_ + (kIrLen - chunkFrames), right, chunkFrames * sizeof(float));
    } else {
        std::memcpy(histL_, left + (chunkFrames - kIrLen), kIrLen * sizeof(float));
        std::memcpy(histR_, right + (chunkFrames - kIrLen), kIrLen * sizeof(float));
    }

    // 3. Forward real FFT of L and R blocks.
    DSPSplitComplex X_L{freqL_Re_, freqL_Im_};
    DSPSplitComplex X_R{freqR_Re_, freqR_Im_};
    vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeL_), 2, &X_L, 1, kHalfN);
    vDSP_ctoz(reinterpret_cast<const DSPComplex *>(timeR_), 2, &X_R, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &X_L, 1, SPATIAL_FFT_LOG2, kFFTDirection_Forward);
    vDSP_fft_zrip(gFftSetup, &X_R, 1, SPATIAL_FFT_LOG2, kFFTDirection_Forward);

    DSPSplitComplex acc{accRe_, accIm_};
    DSPSplitComplex tmp{tmpRe_, tmpIm_};

    // 4. OutL = IFFT(X_L * H_LL + X_R * H_RL)
    DSPSplitComplex H_LL{spec.llRe, spec.llIm};
    DSPSplitComplex H_RL{spec.rlRe, spec.rlIm};
    MultiplyPackedSpectra(X_L, H_LL, acc);
    MultiplyPackedSpectra(X_R, H_RL, tmp);
    vDSP_zvadd(&acc, 1, &tmp, 1, &acc, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &acc, 1, SPATIAL_FFT_LOG2, kFFTDirection_Inverse);
    vDSP_ztoc(&acc, 1, reinterpret_cast<DSPComplex *>(timeL_), 2, kHalfN);

    // 5. OutR = IFFT(X_L * H_LR + X_R * H_RR)
    DSPSplitComplex H_LR{spec.lrRe, spec.lrIm};
    DSPSplitComplex H_RR{spec.rrRe, spec.rrIm};
    MultiplyPackedSpectra(X_L, H_LR, acc);
    MultiplyPackedSpectra(X_R, H_RR, tmp);
    vDSP_zvadd(&acc, 1, &tmp, 1, &acc, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &acc, 1, SPATIAL_FFT_LOG2, kFFTDirection_Inverse);
    vDSP_ztoc(&acc, 1, reinterpret_cast<DSPComplex *>(timeR_), 2, kHalfN);

    // 6. Copy valid linear-convolution region [kIrLen .. kIrLen + chunkFrames - 1] & soft-clip.
    std::memcpy(left, timeL_ + kIrLen, chunkFrames * sizeof(float));
    std::memcpy(right, timeR_ + kIrLen, chunkFrames * sizeof(float));
    SoftClipBuffer(left, chunkFrames);
    SoftClipBuffer(right, chunkFrames);
}

void SpatialStreamProcessor::ProcessNonInterleavedFloat32(float *left,
                                                          float *right,
                                                          uint32_t frameCount,
                                                          double sampleRate) {
    if (!left || !right || frameCount == 0) return;

    bool is44k = false;
    if (!IsSupportedSampleRate(sampleRate, is44k)) return;

    if (std::fabs(sampleRate - lastSampleRate_) > 10.0) {
        Reset();
        lastSampleRate_ = sampleRate;
    }

    uint32_t offset = 0;
    while (offset < frameCount) {
        const uint32_t chunk = std::min(kMaxChunk, frameCount - offset);
        ProcessChunk(left + offset, right + offset, chunk, is44k);
        offset += chunk;
    }
}

void SpatialStreamProcessor::ProcessInterleavedFloat32(float *interleaved,
                                                       uint32_t frameCount,
                                                       double sampleRate) {
    if (!interleaved || !deintL_ || !deintR_ || frameCount == 0) return;

    bool is44k = false;
    if (!IsSupportedSampleRate(sampleRate, is44k)) return;

    if (std::fabs(sampleRate - lastSampleRate_) > 10.0) {
        Reset();
        lastSampleRate_ = sampleRate;
    }

    uint32_t offset = 0;
    while (offset < frameCount) {
        const uint32_t chunk = std::min(kMaxChunk, frameCount - offset);
        float *src = interleaved + (offset * 2);
        for (uint32_t i = 0; i < chunk; ++i) {
            deintL_[i] = src[2 * i];
            deintR_[i] = src[2 * i + 1];
        }
        ProcessChunk(deintL_, deintR_, chunk, is44k);
        for (uint32_t i = 0; i < chunk; ++i) {
            src[2 * i]     = deintL_[i];
            src[2 * i + 1] = deintR_[i];
        }
        offset += chunk;
    }
}

void SpatialStreamProcessor::ProcessInterleavedInt16(int16_t *interleaved,
                                                     uint32_t frameCount,
                                                     double sampleRate) {
    if (!interleaved || !deintL_ || !deintR_ || frameCount == 0) return;

    bool is44k = false;
    if (!IsSupportedSampleRate(sampleRate, is44k)) return;

    if (std::fabs(sampleRate - lastSampleRate_) > 10.0) {
        Reset();
        lastSampleRate_ = sampleRate;
    }

    constexpr float kInv32768 = 1.0f / 32768.0f;
    uint32_t offset = 0;
    while (offset < frameCount) {
        const uint32_t chunk = std::min(kMaxChunk, frameCount - offset);
        int16_t *src = interleaved + (offset * 2);
        for (uint32_t i = 0; i < chunk; ++i) {
            deintL_[i] = static_cast<float>(src[2 * i]) * kInv32768;
            deintR_[i] = static_cast<float>(src[2 * i + 1]) * kInv32768;
        }
        ProcessChunk(deintL_, deintR_, chunk, is44k);
        for (uint32_t i = 0; i < chunk; ++i) {
            float l = std::max(-1.0f, std::min(1.0f, deintL_[i])) * 32767.0f;
            float r = std::max(-1.0f, std::min(1.0f, deintR_[i])) * 32767.0f;
            src[2 * i]     = static_cast<int16_t>(std::lrintf(l));
            src[2 * i + 1] = static_cast<int16_t>(std::lrintf(r));
        }
        offset += chunk;
    }
}

void SpatialStreamProcessor::ProcessAudioBufferList(AudioBufferList *ioData,
                                                    uint32_t frameCount,
                                                    const AudioStreamBasicDescription &asbd) {
    if (!ioData || frameCount == 0) return;
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mChannelsPerFrame != 2) return;

    const bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    if (isFloat && asbd.mBitsPerChannel == 32) {
        if (isNonInterleaved && ioData->mNumberBuffers >= 2) {
            float *l = static_cast<float *>(ioData->mBuffers[0].mData);
            float *r = static_cast<float *>(ioData->mBuffers[1].mData);
            ProcessNonInterleavedFloat32(l, r, frameCount, asbd.mSampleRate);
        } else if (!isNonInterleaved && ioData->mNumberBuffers >= 1) {
            float *interleaved = static_cast<float *>(ioData->mBuffers[0].mData);
            ProcessInterleavedFloat32(interleaved, frameCount, asbd.mSampleRate);
        }
    } else if (isSignedInt && asbd.mBitsPerChannel == 16 && !isNonInterleaved && ioData->mNumberBuffers >= 1) {
        int16_t *interleaved = static_cast<int16_t *>(ioData->mBuffers[0].mData);
        ProcessInterleavedInt16(interleaved, frameCount, asbd.mSampleRate);
    }
}

} // namespace spatial
