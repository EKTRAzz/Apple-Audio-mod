#include "SpatialEngine.h"
#include "ir_data.h"

#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>

// Default headroom: -2.5 dB (prevents clipping on +2.4 dB worst-case mono peaks while matching PC HeSuVi loudness).
// Override at compile time with -DSPATIAL_HEADROOM_DB=-4.0f (or 0.0f for raw PC unity).
#ifndef SPATIAL_HEADROOM_DB
#define SPATIAL_HEADROOM_DB (-2.5f)
#endif

namespace spatial {

namespace {

constexpr uint32_t kFftN           = SPATIAL_FFT_N;               // 16384
constexpr uint32_t kHalfN          = SPATIAL_FFT_N / 2;           // 8192
constexpr uint32_t kIrLen          = SPATIAL_IR_LEN;              // 8400 (zero truncation of Apple_Pro2_Stereo.wav)
constexpr uint32_t kMaxChunk       = kFftN - kIrLen;              // 7984 frames per Overlap-Save pass
constexpr uint32_t kCrossfadeFrames = 512;                        // ~10.7 ms at 48 kHz

struct TrueStereoSpectrum {
    float *llRe, *llIm;
    float *lrRe, *lrIm;
    float *rlRe, *rlIm;
    float *rrRe, *rrIm;
};

FFTSetup gFftSetup = nullptr;
TrueStereoSpectrum gSpecMatrix48{};
TrueStereoSpectrum gSpecMatrix44{};
TrueStereoSpectrum gSpecFront48{};
TrueStereoSpectrum gSpecFront44{};

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

const TrueStereoSpectrum &SelectSpectrum(bool is44k, SpatialMode mode) {
    if (mode == SpatialMode::Front) {
        return is44k ? gSpecFront44 : gSpecFront48;
    }
    return is44k ? gSpecMatrix44 : gSpecMatrix48;
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
    static std::once_flag onceFlag;
    std::call_once(onceFlag, []() {
        gFftSetup = vDSP_create_fftsetup(SPATIAL_FFT_LOG2, kFFTRadix2);
        if (!gFftSetup) return;

        // vDSP_fft_zrip forward scales by 2, so X*H scales by 4; inverse scales by N -> total 4*N.
        const float headroomLinear = std::pow(10.0f, static_cast<float>(SPATIAL_HEADROOM_DB) / 20.0f);
        const float combinedScale  = headroomLinear / (4.0f * static_cast<float>(kFftN));

        auto allocSpec = [](TrueStereoSpectrum &s) {
            s.llRe = AllocAligned(kHalfN); s.llIm = AllocAligned(kHalfN);
            s.lrRe = AllocAligned(kHalfN); s.lrIm = AllocAligned(kHalfN);
            s.rlRe = AllocAligned(kHalfN); s.rlIm = AllocAligned(kHalfN);
            s.rrRe = AllocAligned(kHalfN); s.rrIm = AllocAligned(kHalfN);
        };

        allocSpec(gSpecMatrix48);
        BuildIrSpectrum(kIR48_Matrix_LL, gSpecMatrix48.llRe, gSpecMatrix48.llIm, combinedScale);
        BuildIrSpectrum(kIR48_Matrix_LR, gSpecMatrix48.lrRe, gSpecMatrix48.lrIm, combinedScale);
        BuildIrSpectrum(kIR48_Matrix_RL, gSpecMatrix48.rlRe, gSpecMatrix48.rlIm, combinedScale);
        BuildIrSpectrum(kIR48_Matrix_RR, gSpecMatrix48.rrRe, gSpecMatrix48.rrIm, combinedScale);

        allocSpec(gSpecMatrix44);
        BuildIrSpectrum(kIR44_Matrix_LL, gSpecMatrix44.llRe, gSpecMatrix44.llIm, combinedScale);
        BuildIrSpectrum(kIR44_Matrix_LR, gSpecMatrix44.lrRe, gSpecMatrix44.lrIm, combinedScale);
        BuildIrSpectrum(kIR44_Matrix_RL, gSpecMatrix44.rlRe, gSpecMatrix44.rlIm, combinedScale);
        BuildIrSpectrum(kIR44_Matrix_RR, gSpecMatrix44.rrRe, gSpecMatrix44.rrIm, combinedScale);

        allocSpec(gSpecFront48);
        BuildIrSpectrum(kIR48_Front_LL, gSpecFront48.llRe, gSpecFront48.llIm, combinedScale);
        BuildIrSpectrum(kIR48_Front_LR, gSpecFront48.lrRe, gSpecFront48.lrIm, combinedScale);
        BuildIrSpectrum(kIR48_Front_RL, gSpecFront48.rlRe, gSpecFront48.rlIm, combinedScale);
        BuildIrSpectrum(kIR48_Front_RR, gSpecFront48.rrRe, gSpecFront48.rrIm, combinedScale);

        allocSpec(gSpecFront44);
        BuildIrSpectrum(kIR44_Front_LL, gSpecFront44.llRe, gSpecFront44.llIm, combinedScale);
        BuildIrSpectrum(kIR44_Front_LR, gSpecFront44.lrRe, gSpecFront44.lrIm, combinedScale);
        BuildIrSpectrum(kIR44_Front_RL, gSpecFront44.rlRe, gSpecFront44.rlIm, combinedScale);
        BuildIrSpectrum(kIR44_Front_RR, gSpecFront44.rrRe, gSpecFront44.rrIm, combinedScale);
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
    fadeOldL_ = AllocAligned(kCrossfadeFrames);
    fadeOldR_ = AllocAligned(kCrossfadeFrames);
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
    std::free(fadeOldL_);
    std::free(fadeOldR_);
}

void SpatialStreamProcessor::Reset() {
    if (histL_) std::memset(histL_, 0, kIrLen * sizeof(float));
    if (histR_) std::memset(histR_, 0, kIrLen * sizeof(float));
    wetGain_ = 0.0f;
    wetActive_.store(false, std::memory_order_release);
    modeFadeRemaining_ = 0;
}

bool SpatialStreamProcessor::NeedsProcessing(bool wantSpatial) const {
    return wantSpatial || wetActive_.load(std::memory_order_acquire);
}

void SpatialStreamProcessor::ConvolveToTimeDomain(const float *xLRe,
                                                  const float *xLIm,
                                                  const float *xRRe,
                                                  const float *xRIm,
                                                  bool is44k,
                                                  SpatialMode mode) {
    const TrueStereoSpectrum &spec = SelectSpectrum(is44k, mode);

    DSPSplitComplex X_L{const_cast<float *>(xLRe), const_cast<float *>(xLIm)};
    DSPSplitComplex X_R{const_cast<float *>(xRRe), const_cast<float *>(xRIm)};
    DSPSplitComplex acc{accRe_, accIm_};
    DSPSplitComplex tmp{tmpRe_, tmpIm_};

    // OutL = IFFT(X_L * H_LL + X_R * H_RL)
    DSPSplitComplex H_LL{spec.llRe, spec.llIm};
    DSPSplitComplex H_RL{spec.rlRe, spec.rlIm};
    MultiplyPackedSpectra(X_L, H_LL, acc);
    MultiplyPackedSpectra(X_R, H_RL, tmp);
    vDSP_zvadd(&acc, 1, &tmp, 1, &acc, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &acc, 1, SPATIAL_FFT_LOG2, kFFTDirection_Inverse);
    vDSP_ztoc(&acc, 1, reinterpret_cast<DSPComplex *>(timeL_), 2, kHalfN);

    // OutR = IFFT(X_L * H_LR + X_R * H_RR)
    DSPSplitComplex H_LR{spec.lrRe, spec.lrIm};
    DSPSplitComplex H_RR{spec.rrRe, spec.rrIm};
    MultiplyPackedSpectra(X_L, H_LR, acc);
    MultiplyPackedSpectra(X_R, H_RR, tmp);
    vDSP_zvadd(&acc, 1, &tmp, 1, &acc, 1, kHalfN);
    vDSP_fft_zrip(gFftSetup, &acc, 1, SPATIAL_FFT_LOG2, kFFTDirection_Inverse);
    vDSP_ztoc(&acc, 1, reinterpret_cast<DSPComplex *>(timeR_), 2, kHalfN);
}

bool SpatialStreamProcessor::PrepareForStream(double sampleRate,
                                              bool &outIs44k,
                                              bool wantSpatial,
                                              SpatialMode desiredMode) {
    if (!IsSupportedSampleRate(sampleRate, outIs44k)) return false;

    if (std::fabs(sampleRate - lastSampleRate_) > 10.0) {
        Reset();
        lastSampleRate_ = sampleRate;
    }

    if (!wantSpatial && wetGain_ <= 0.0f) {
        wetActive_.store(false, std::memory_order_release);
        return false;
    }

    if (wantSpatial) {
        if (wetGain_ <= 0.0f) {
            // Starting cleanly from bypass: snap directly to desiredMode without crossfading from a stale mode.
            activeMode_ = desiredMode;
            prevMode_ = desiredMode;
            modeFadeRemaining_ = 0;
        } else if (modeFadeRemaining_ == 0 && activeMode_ != desiredMode) {
            prevMode_ = activeMode_;
            activeMode_ = desiredMode;
            modeFadeRemaining_ = kCrossfadeFrames;
        }
        wetActive_.store(true, std::memory_order_release);
    }

    return true;
}

uint32_t SpatialStreamProcessor::NextChunkSize(uint32_t remaining, bool wantSpatial) const {
    uint32_t maxChunk = kMaxChunk;
    if (!wantSpatial) {
        const uint32_t fadeOutRem = static_cast<uint32_t>(std::ceil(wetGain_ * static_cast<float>(kCrossfadeFrames)));
        if (fadeOutRem == 0) return 0;
        maxChunk = std::min(maxChunk, fadeOutRem);
    }
    if (modeFadeRemaining_ > 0) {
        maxChunk = std::min(maxChunk, modeFadeRemaining_);
    }
    return std::min(maxChunk, remaining);
}

void SpatialStreamProcessor::ProcessChunk(float *left,
                                          float *right,
                                          uint32_t chunkFrames,
                                          bool is44k,
                                          bool wantSpatial) {
    if (!gFftSetup || !histL_ || !histR_ || !timeL_ || !timeR_ || chunkFrames == 0 || chunkFrames > kMaxChunk) {
        return;
    }

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

    // 4. Convolve & optionally crossfade Matrix <-> Front using the shared X_L / X_R spectra.
    if (modeFadeRemaining_ > 0 && fadeOldL_ && fadeOldR_ && chunkFrames <= kCrossfadeFrames) {
        ConvolveToTimeDomain(freqL_Re_, freqL_Im_, freqR_Re_, freqR_Im_, is44k, prevMode_);
        std::memcpy(fadeOldL_, timeL_ + kIrLen, chunkFrames * sizeof(float));
        std::memcpy(fadeOldR_, timeR_ + kIrLen, chunkFrames * sizeof(float));

        ConvolveToTimeDomain(freqL_Re_, freqL_Im_, freqR_Re_, freqR_Im_, is44k, activeMode_);

        const uint32_t doneStart = kCrossfadeFrames - modeFadeRemaining_;
        for (uint32_t i = 0; i < chunkFrames; ++i) {
            const float alpha = static_cast<float>(doneStart + i + 1) / static_cast<float>(kCrossfadeFrames);
            const float invAlpha = 1.0f - alpha;
            timeL_[kIrLen + i] = fadeOldL_[i] * invAlpha + timeL_[kIrLen + i] * alpha;
            timeR_[kIrLen + i] = fadeOldR_[i] * invAlpha + timeR_[kIrLen + i] * alpha;
        }
        modeFadeRemaining_ -= chunkFrames;
    } else {
        ConvolveToTimeDomain(freqL_Re_, freqL_Im_, freqR_Re_, freqR_Im_, is44k, activeMode_);
    }

    // 5. Write valid wet output or smoothly crossfade dry <-> wet on On/Off transitions, then soft-clip.
    if (wantSpatial && wetGain_ >= 1.0f) {
        std::memcpy(left, timeL_ + kIrLen, chunkFrames * sizeof(float));
        std::memcpy(right, timeR_ + kIrLen, chunkFrames * sizeof(float));
        SoftClipBuffer(left, chunkFrames);
        SoftClipBuffer(right, chunkFrames);
    } else {
        constexpr float kFadeStep = 1.0f / static_cast<float>(kCrossfadeFrames);
        for (uint32_t i = 0; i < chunkFrames; ++i) {
            if (wantSpatial) {
                wetGain_ = std::min(1.0f, wetGain_ + kFadeStep);
            } else {
                wetGain_ = std::max(0.0f, wetGain_ - kFadeStep);
            }
            const float g = wetGain_;
            const float invG = 1.0f - g;
            left[i]  = left[i]  * invG + timeL_[kIrLen + i] * g;
            right[i] = right[i] * invG + timeR_[kIrLen + i] * g;
        }
        if (wantSpatial || wetGain_ > 0.0f) {
            SoftClipBuffer(left, chunkFrames);
            SoftClipBuffer(right, chunkFrames);
        }
    }
}

template <typename LoadFn, typename StoreFn>
void SpatialStreamProcessor::ProcessFormatted(uint32_t frameCount,
                                              double sampleRate,
                                              bool wantSpatial,
                                              SpatialMode desiredMode,
                                              LoadFn &&loadChunk,
                                              StoreFn &&storeChunk) {
    if (!deintL_ || !deintR_ || frameCount == 0) return;

    bool is44k = false;
    if (!PrepareForStream(sampleRate, is44k, wantSpatial, desiredMode)) return;

    uint32_t offset = 0;
    while (offset < frameCount) {
        const uint32_t chunk = NextChunkSize(frameCount - offset, wantSpatial);
        if (chunk == 0) {
            Reset();
            break;
        }
        loadChunk(offset, chunk, deintL_, deintR_);
        ProcessChunk(deintL_, deintR_, chunk, is44k, wantSpatial);
        storeChunk(offset, chunk, deintL_, deintR_);
        offset += chunk;
        if (!wantSpatial && wetGain_ <= 0.0f) {
            Reset();
            break;
        }
    }
}

void SpatialStreamProcessor::ProcessNonInterleavedFloat32(float *left,
                                                          float *right,
                                                          uint32_t frameCount,
                                                          double sampleRate,
                                                          bool wantSpatial,
                                                          SpatialMode desiredMode) {
    if (!left || !right || frameCount == 0) return;

    bool is44k = false;
    if (!PrepareForStream(sampleRate, is44k, wantSpatial, desiredMode)) return;

    uint32_t offset = 0;
    while (offset < frameCount) {
        const uint32_t chunk = NextChunkSize(frameCount - offset, wantSpatial);
        if (chunk == 0) {
            Reset();
            break;
        }
        ProcessChunk(left + offset, right + offset, chunk, is44k, wantSpatial);
        offset += chunk;
        if (!wantSpatial && wetGain_ <= 0.0f) {
            Reset();
            break;
        }
    }
}

void SpatialStreamProcessor::ProcessInterleavedFloat32(float *interleaved,
                                                       uint32_t frameCount,
                                                       double sampleRate,
                                                       bool wantSpatial,
                                                       SpatialMode desiredMode) {
    if (!interleaved) return;
    ProcessFormatted(
        frameCount,
        sampleRate,
        wantSpatial,
        desiredMode,
        [interleaved](uint32_t offset, uint32_t chunk, float *dstL, float *dstR) {
            const float *src = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                dstL[i] = src[2 * i];
                dstR[i] = src[2 * i + 1];
            }
        },
        [interleaved](uint32_t offset, uint32_t chunk, const float *srcL, const float *srcR) {
            float *dst = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                dst[2 * i]     = srcL[i];
                dst[2 * i + 1] = srcR[i];
            }
        }
    );
}

void SpatialStreamProcessor::ProcessInterleavedInt16(int16_t *interleaved,
                                                     uint32_t frameCount,
                                                     double sampleRate,
                                                     bool wantSpatial,
                                                     SpatialMode desiredMode) {
    if (!interleaved) return;
    constexpr float kInv32768 = 1.0f / 32768.0f;
    ProcessFormatted(
        frameCount,
        sampleRate,
        wantSpatial,
        desiredMode,
        [interleaved](uint32_t offset, uint32_t chunk, float *dstL, float *dstR) {
            const int16_t *src = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                dstL[i] = static_cast<float>(src[2 * i]) * kInv32768;
                dstR[i] = static_cast<float>(src[2 * i + 1]) * kInv32768;
            }
        },
        [interleaved](uint32_t offset, uint32_t chunk, const float *srcL, const float *srcR) {
            int16_t *dst = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                const float l = std::max(-1.0f, std::min(1.0f, srcL[i])) * 32767.0f;
                const float r = std::max(-1.0f, std::min(1.0f, srcR[i])) * 32767.0f;
                dst[2 * i]     = static_cast<int16_t>(std::lrintf(l));
                dst[2 * i + 1] = static_cast<int16_t>(std::lrintf(r));
            }
        }
    );
}

void SpatialStreamProcessor::ProcessNonInterleavedInt16(int16_t *left,
                                                        int16_t *right,
                                                        uint32_t frameCount,
                                                        double sampleRate,
                                                        bool wantSpatial,
                                                        SpatialMode desiredMode) {
    if (!left || !right) return;
    constexpr float kInv32768 = 1.0f / 32768.0f;
    ProcessFormatted(
        frameCount,
        sampleRate,
        wantSpatial,
        desiredMode,
        [left, right](uint32_t offset, uint32_t chunk, float *dstL, float *dstR) {
            const int16_t *srcL = left + offset;
            const int16_t *srcR = right + offset;
            for (uint32_t i = 0; i < chunk; ++i) {
                dstL[i] = static_cast<float>(srcL[i]) * kInv32768;
                dstR[i] = static_cast<float>(srcR[i]) * kInv32768;
            }
        },
        [left, right](uint32_t offset, uint32_t chunk, const float *srcL, const float *srcR) {
            int16_t *dstL = left + offset;
            int16_t *dstR = right + offset;
            for (uint32_t i = 0; i < chunk; ++i) {
                const float l = std::max(-1.0f, std::min(1.0f, srcL[i])) * 32767.0f;
                const float r = std::max(-1.0f, std::min(1.0f, srcR[i])) * 32767.0f;
                dstL[i] = static_cast<int16_t>(std::lrintf(l));
                dstR[i] = static_cast<int16_t>(std::lrintf(r));
            }
        }
    );
}

void SpatialStreamProcessor::ProcessInterleavedInt32(int32_t *interleaved,
                                                     uint32_t frameCount,
                                                     double sampleRate,
                                                     bool wantSpatial,
                                                     SpatialMode desiredMode) {
    if (!interleaved) return;
    constexpr double kInvMax = 1.0 / 2147483648.0;
    constexpr double kMaxPos = 2147483647.0;
    ProcessFormatted(
        frameCount,
        sampleRate,
        wantSpatial,
        desiredMode,
        [interleaved](uint32_t offset, uint32_t chunk, float *dstL, float *dstR) {
            const int32_t *src = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                dstL[i] = static_cast<float>(static_cast<double>(src[2 * i]) * kInvMax);
                dstR[i] = static_cast<float>(static_cast<double>(src[2 * i + 1]) * kInvMax);
            }
        },
        [interleaved](uint32_t offset, uint32_t chunk, const float *srcL, const float *srcR) {
            int32_t *dst = interleaved + (offset * 2);
            for (uint32_t i = 0; i < chunk; ++i) {
                const double l = std::max(-1.0, std::min(1.0, static_cast<double>(srcL[i]))) * kMaxPos;
                const double r = std::max(-1.0, std::min(1.0, static_cast<double>(srcR[i]))) * kMaxPos;
                dst[2 * i]     = static_cast<int32_t>(std::llround(l));
                dst[2 * i + 1] = static_cast<int32_t>(std::llround(r));
            }
        }
    );
}

void SpatialStreamProcessor::ProcessNonInterleavedInt32(int32_t *left,
                                                        int32_t *right,
                                                        uint32_t frameCount,
                                                        double sampleRate,
                                                        bool wantSpatial,
                                                        SpatialMode desiredMode) {
    if (!left || !right) return;
    constexpr double kInvMax = 1.0 / 2147483648.0;
    constexpr double kMaxPos = 2147483647.0;
    ProcessFormatted(
        frameCount,
        sampleRate,
        wantSpatial,
        desiredMode,
        [left, right](uint32_t offset, uint32_t chunk, float *dstL, float *dstR) {
            const int32_t *srcL = left + offset;
            const int32_t *srcR = right + offset;
            for (uint32_t i = 0; i < chunk; ++i) {
                dstL[i] = static_cast<float>(static_cast<double>(srcL[i]) * kInvMax);
                dstR[i] = static_cast<float>(static_cast<double>(srcR[i]) * kInvMax);
            }
        },
        [left, right](uint32_t offset, uint32_t chunk, const float *srcL, const float *srcR) {
            int32_t *dstL = left + offset;
            int32_t *dstR = right + offset;
            for (uint32_t i = 0; i < chunk; ++i) {
                const double l = std::max(-1.0, std::min(1.0, static_cast<double>(srcL[i]))) * kMaxPos;
                const double r = std::max(-1.0, std::min(1.0, static_cast<double>(srcR[i]))) * kMaxPos;
                dstL[i] = static_cast<int32_t>(std::llround(l));
                dstR[i] = static_cast<int32_t>(std::llround(r));
            }
        }
    );
}

void SpatialStreamProcessor::ProcessAudioBufferList(AudioBufferList *ioData,
                                                    uint32_t frameCount,
                                                    const AudioStreamBasicDescription &asbd,
                                                    bool wantSpatial,
                                                    SpatialMode desiredMode) {
    if (!ioData || frameCount == 0) return;
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mChannelsPerFrame != 2) return;

    const bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    if (isFloat && asbd.mBitsPerChannel == 32) {
        if (isNonInterleaved && ioData->mNumberBuffers >= 2) {
            float *l = static_cast<float *>(ioData->mBuffers[0].mData);
            float *r = static_cast<float *>(ioData->mBuffers[1].mData);
            ProcessNonInterleavedFloat32(l, r, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        } else if (!isNonInterleaved && ioData->mNumberBuffers >= 1) {
            float *interleaved = static_cast<float *>(ioData->mBuffers[0].mData);
            ProcessInterleavedFloat32(interleaved, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        }
    } else if (isSignedInt && asbd.mBitsPerChannel == 16) {
        if (isNonInterleaved && ioData->mNumberBuffers >= 2) {
            int16_t *l = static_cast<int16_t *>(ioData->mBuffers[0].mData);
            int16_t *r = static_cast<int16_t *>(ioData->mBuffers[1].mData);
            ProcessNonInterleavedInt16(l, r, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        } else if (!isNonInterleaved && ioData->mNumberBuffers >= 1) {
            int16_t *interleaved = static_cast<int16_t *>(ioData->mBuffers[0].mData);
            ProcessInterleavedInt16(interleaved, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        }
    } else if (isSignedInt && asbd.mBitsPerChannel == 32) {
        if (isNonInterleaved && ioData->mNumberBuffers >= 2) {
            int32_t *l = static_cast<int32_t *>(ioData->mBuffers[0].mData);
            int32_t *r = static_cast<int32_t *>(ioData->mBuffers[1].mData);
            ProcessNonInterleavedInt32(l, r, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        } else if (!isNonInterleaved && ioData->mNumberBuffers >= 1) {
            int32_t *interleaved = static_cast<int32_t *>(ioData->mBuffers[0].mData);
            ProcessInterleavedInt32(interleaved, frameCount, asbd.mSampleRate, wantSpatial, desiredMode);
        }
    }
}

} // namespace spatial
