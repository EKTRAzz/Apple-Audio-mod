#ifndef SPATIAL_WAV_LOADER_H
#define SPATIAL_WAV_LOADER_H

#include <stdint.h>
#include <string>
#include <vector>

namespace spatial {

struct LoadedHrirSet {
    uint32_t sourceSampleRate = 0;
    uint32_t sourceChannels = 0;
    uint32_t sourceFrames = 0;

    // Order: [0]=LL, [1]=LR, [2]=RL, [3]=RR, each sized targetIrLen (8400).
    std::vector<float> matrix48[4];
    std::vector<float> matrix44[4];
    std::vector<float> front48[4];
    std::vector<float> front44[4];
};

// Loads a 14-ch HeSuVi, 4-ch True-Stereo, or 2-ch Stereo RIFF/WAVE file
// (16/24/32-bit PCM or 32/64-bit IEEE Float), collapses to True-Stereo, and
// resamples cleanly to 48 kHz & 44.1 kHz with targetIrLen frames each.
bool LoadHrirWavFile(const char *path,
                     uint32_t targetIrLen,
                     LoadedHrirSet &outSet,
                     std::string &outError);

} // namespace spatial

#endif // SPATIAL_WAV_LOADER_H
