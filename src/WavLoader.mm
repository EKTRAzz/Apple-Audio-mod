#include "WavLoader.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

namespace spatial {
namespace {

constexpr double kPi = 3.14159265358979323846;

inline uint16_t ReadU16LE(const uint8_t *p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

inline uint32_t ReadU32LE(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

inline int32_t ReadI24LE(const uint8_t *p) {
    int32_t v = static_cast<int32_t>(p[0]) |
                (static_cast<int32_t>(p[1]) << 8) |
                (static_cast<int32_t>(p[2]) << 16);
    if (v & 0x800000) {
        v |= ~0xFFFFFF;
    }
    return v;
}

inline double BesselI0(double x) {
    double sum = 1.0;
    double term = 1.0;
    const double y = x * x * 0.25;
    for (int k = 1; k <= 20; ++k) {
        term *= y / (static_cast<double>(k) * static_cast<double>(k));
        sum += term;
        if (term < 1e-12 * sum) break;
    }
    return sum;
}

std::vector<float> ResampleChannel(const std::vector<float> &src,
                                   uint32_t srcSr,
                                   uint32_t dstSr,
                                   uint32_t targetLen) {
    std::vector<float> out(targetLen, 0.0f);
    if (src.empty()) return out;

    if (srcSr == dstSr) {
        const size_t count = std::min<size_t>(src.size(), targetLen);
        std::copy(src.begin(), src.begin() + static_cast<std::ptrdiff_t>(count), out.begin());
        return out;
    }

    const double step = static_cast<double>(srcSr) / static_cast<double>(dstSr);
    const double fc = std::min(1.0, static_cast<double>(dstSr) / static_cast<double>(srcSr));
    constexpr int kHalfWidth = 16;
    constexpr double kBeta = 7.0;
    const double invI0Beta = 1.0 / BesselI0(kBeta);

    for (uint32_t n = 0; n < targetLen; ++n) {
        const double t = static_cast<double>(n) * step;
        const int center = static_cast<int>(std::floor(t));
        const int kMin = std::max(0, center - kHalfWidth);
        const int kMax = std::min(static_cast<int>(src.size()) - 1, center + kHalfWidth);
        if (kMin > kMax) break;

        double acc = 0.0;
        double wSum = 0.0;
        for (int k = kMin; k <= kMax; ++k) {
            const double dx = t - static_cast<double>(k);
            const double norm = dx / static_cast<double>(kHalfWidth);
            if (std::fabs(norm) >= 1.0) continue;

            const double arg = fc * dx;
            const double sincVal = (std::fabs(arg) < 1e-9)
                ? 1.0
                : std::sin(kPi * arg) / (kPi * arg);
            const double kaiser = BesselI0(kBeta * std::sqrt(std::max(0.0, 1.0 - norm * norm))) * invI0Beta;
            const double w = fc * sincVal * kaiser;
            acc += static_cast<double>(src[static_cast<size_t>(k)]) * w;
            wSum += w;
        }
        if (std::fabs(wSum) > 1e-12) {
            out[n] = static_cast<float>((acc / wSum) * step);
        }
    }
    return out;
}

} // namespace

bool LoadHrirWavFile(const char *path,
                     uint32_t targetIrLen,
                     LoadedHrirSet &outSet,
                     std::string &outError) {
    outSet = LoadedHrirSet{};
    outError.clear();

    if (!path || path[0] == '\0') {
        outError = "Invalid WAV file path.";
        return false;
    }

    std::ifstream ifs(path, std::ios::binary | std::ios::ate);
    if (!ifs.is_open()) {
        outError = "Unable to open WAV file.";
        return false;
    }

    const std::streamsize fileSize = ifs.tellg();
    if (fileSize < 44 || fileSize > 64 * 1024 * 1024) {
        outError = "WAV file is empty or exceeds 64 MB limit.";
        return false;
    }

    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> buf(static_cast<size_t>(fileSize));
    if (!ifs.read(reinterpret_cast<char *>(buf.data()), fileSize)) {
        outError = "Failed to read WAV file.";
        return false;
    }

    if (std::memcmp(buf.data(), "RIFF", 4) != 0 || std::memcmp(buf.data() + 8, "WAVE", 4) != 0) {
        outError = "File is not a valid RIFF/WAVE container.";
        return false;
    }

    bool hasFmt = false;
    bool hasData = false;
    uint16_t formatTag = 0;
    uint16_t channels = 0;
    uint32_t sampleRate = 0;
    uint16_t blockAlign = 0;
    uint16_t bitsPerSample = 0;
    size_t dataOffset = 0;
    size_t dataSize = 0;

    size_t pos = 12;
    while (pos + 8 <= buf.size()) {
        const uint8_t *hdr = buf.data() + pos;
        const uint32_t chunkSize = ReadU32LE(hdr + 4);
        const size_t payloadOffset = pos + 8;
        if (payloadOffset + chunkSize > buf.size()) {
            break;
        }

        if (std::memcmp(hdr, "fmt ", 4) == 0 && chunkSize >= 16) {
            const uint8_t *fmt = buf.data() + payloadOffset;
            formatTag = ReadU16LE(fmt + 0);
            channels = ReadU16LE(fmt + 2);
            sampleRate = ReadU32LE(fmt + 4);
            blockAlign = ReadU16LE(fmt + 12);
            bitsPerSample = ReadU16LE(fmt + 14);

            // WAVE_FORMAT_EXTENSIBLE (0xFFFE)
            if (formatTag == 0xFFFE && chunkSize >= 40) {
                const uint16_t subTag = ReadU16LE(fmt + 24);
                formatTag = subTag;
            }
            hasFmt = true;
        } else if (std::memcmp(hdr, "data", 4) == 0) {
            dataOffset = payloadOffset;
            dataSize = chunkSize;
            hasData = true;
        }

        pos = payloadOffset + chunkSize + (chunkSize & 1u);
    }

    if (!hasFmt || !hasData || dataSize == 0) {
        outError = "Missing fmt or audio data chunk in WAV.";
        return false;
    }

    if (channels != 2 && channels != 4 && channels != 14) {
        outError = "Unsupported channel count (expected 14-ch HeSuVi, 4-ch True-Stereo, or 2-ch Stereo).";
        return false;
    }

    if (sampleRate < 8000 || sampleRate > 384000) {
        outError = "Unsupported WAV sample rate.";
        return false;
    }

    const bool isPcm = (formatTag == 1) && (bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32);
    const bool isFloat = (formatTag == 3) && (bitsPerSample == 32 || bitsPerSample == 64);
    if (!isPcm && !isFloat) {
        outError = "Unsupported WAV sample encoding (use 16/24/32-bit PCM or 32/64-bit Float).";
        return false;
    }

    const uint32_t bytesPerSample = bitsPerSample / 8;
    const uint32_t expectedBlockAlign = channels * bytesPerSample;
    const uint32_t stride = (blockAlign >= expectedBlockAlign) ? blockAlign : expectedBlockAlign;
    const uint32_t totalFrames = static_cast<uint32_t>(dataSize / stride);
    if (totalFrames == 0) {
        outError = "WAV contains zero audio frames.";
        return false;
    }

    // Cap decoded length to 192,000 frames (~4 seconds at 48 kHz).
    const uint32_t frames = std::min<uint32_t>(totalFrames, 192000u);
    std::vector<float> chBuf[14];
    for (uint16_t c = 0; c < channels; ++c) {
        chBuf[c].resize(frames);
    }

    const uint8_t *pcm = buf.data() + dataOffset;
    for (uint32_t i = 0; i < frames; ++i) {
        const uint8_t *framePtr = pcm + static_cast<size_t>(i) * stride;
        for (uint16_t c = 0; c < channels; ++c) {
            const uint8_t *sPtr = framePtr + static_cast<size_t>(c) * bytesPerSample;
            float val = 0.0f;
            if (isPcm) {
                if (bitsPerSample == 16) {
                    int16_t s = static_cast<int16_t>(ReadU16LE(sPtr));
                    val = static_cast<float>(s) / 32768.0f;
                } else if (bitsPerSample == 24) {
                    val = static_cast<float>(ReadI24LE(sPtr)) / 8388608.0f;
                } else {
                    int32_t s = static_cast<int32_t>(ReadU32LE(sPtr));
                    val = static_cast<float>(static_cast<double>(s) / 2147483648.0);
                }
            } else {
                if (bitsPerSample == 32) {
                    std::memcpy(&val, sPtr, sizeof(float));
                } else {
                    double d = 0.0;
                    std::memcpy(&d, sPtr, sizeof(double));
                    val = static_cast<float>(d);
                }
            }
            if (!std::isfinite(val)) val = 0.0f;
            chBuf[c][i] = val;
        }
    }

    std::vector<float> rawMatrix[4];
    std::vector<float> rawFront[4];
    for (int k = 0; k < 4; ++k) {
        rawMatrix[k].assign(frames, 0.0f);
        rawFront[k].assign(frames, 0.0f);
    }

    if (channels == 14) {
        for (uint32_t i = 0; i < frames; ++i) {
            // Exact PC HeSuVi (#2.0.0.1) Matrix collapse (matches tools/wav_to_ir.py).
            rawMatrix[0][i] = 0.50f * chBuf[0][i] + 0.45f * chBuf[2][i] - 0.25f * chBuf[10][i] +
                              0.30f * chBuf[4][i] - 0.20f * chBuf[12][i] + 0.20f * chBuf[6][i];
            rawMatrix[1][i] = 0.50f * chBuf[1][i] + 0.45f * chBuf[3][i] - 0.25f * chBuf[9][i] +
                              0.30f * chBuf[5][i] - 0.20f * chBuf[11][i] + 0.20f * chBuf[13][i];
            rawMatrix[2][i] = 0.50f * chBuf[8][i] - 0.25f * chBuf[2][i] + 0.45f * chBuf[10][i] -
                              0.20f * chBuf[4][i] + 0.30f * chBuf[12][i] + 0.20f * chBuf[6][i];
            rawMatrix[3][i] = 0.50f * chBuf[7][i] - 0.25f * chBuf[3][i] + 0.45f * chBuf[9][i] -
                              0.20f * chBuf[5][i] + 0.30f * chBuf[11][i] + 0.20f * chBuf[13][i];

            // Pure 1:1 FL/FR binaural.
            rawFront[0][i] = chBuf[0][i];
            rawFront[1][i] = chBuf[1][i];
            rawFront[2][i] = chBuf[8][i];
            rawFront[3][i] = chBuf[7][i];
        }
    } else if (channels == 4) {
        for (uint32_t i = 0; i < frames; ++i) {
            for (int k = 0; k < 4; ++k) {
                rawMatrix[k][i] = chBuf[k][i];
                rawFront[k][i]  = chBuf[k][i];
            }
        }
    } else {
        // 2-channel stereo IR: LL=ch0, RR=ch1, LR=0, RL=0
        for (uint32_t i = 0; i < frames; ++i) {
            rawMatrix[0][i] = chBuf[0][i];
            rawMatrix[3][i] = chBuf[1][i];
            rawFront[0][i]  = chBuf[0][i];
            rawFront[3][i]  = chBuf[1][i];
        }
    }

    for (int k = 0; k < 4; ++k) {
        outSet.matrix48[k] = ResampleChannel(rawMatrix[k], sampleRate, 48000, targetIrLen);
        outSet.matrix44[k] = ResampleChannel(rawMatrix[k], sampleRate, 44100, targetIrLen);
        outSet.front48[k]  = ResampleChannel(rawFront[k],  sampleRate, 48000, targetIrLen);
        outSet.front44[k]  = ResampleChannel(rawFront[k],  sampleRate, 44100, targetIrLen);
    }

    outSet.sourceSampleRate = sampleRate;
    outSet.sourceChannels = channels;
    outSet.sourceFrames = frames;
    return true;
}

} // namespace spatial
