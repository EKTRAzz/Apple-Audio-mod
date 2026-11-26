#include "AudioUnitBridge.h"
#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialConfig.h"
#include "SpatialEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <time.h>

namespace spatial {

// Implemented in HookAudioUnit.mm so our bridge's RemoteIO unit is never double-hooked.
void RegisterBridgeAudioUnit(AudioUnit unit);
void UnregisterBridgeAudioUnit(AudioUnit unit);

void BridgeTimedQueue::Push(double startPtsSec,
                            double sampleRate,
                            const float *left,
                            const float *right,
                            uint32_t frameCount) {
    if (!left || !right || frameCount == 0 || !std::isfinite(startPtsSec) || sampleRate <= 0.0) {
        return;
    }

    TimedPcmChunk chunk;
    chunk.startPtsSec = startPtsSec;
    chunk.sampleRate = sampleRate;
    chunk.readOffset = 0;
    chunk.left.assign(left, left + frameCount);
    chunk.right.assign(right, right + frameCount);

    std::lock_guard<std::mutex> lock(mutex_);
    while (totalFrames_ + frameCount > kMaxBufferedFrames && !chunks_.empty()) {
        const auto &front = chunks_.front();
        const size_t rem = (front.left.size() > front.readOffset) ? (front.left.size() - front.readOffset) : 0;
        totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
        chunks_.pop_front();
        fracOffset_ = 0.0;
    }

    // If new chunk jumps backward in PTS (re-enqueue / seek without flush), trim overlapping tail.
    while (!chunks_.empty() && chunks_.back().startPtsSec >= startPtsSec - 0.001) {
        const auto &back = chunks_.back();
        const size_t rem = (back.left.size() > back.readOffset) ? (back.left.size() - back.readOffset) : 0;
        totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
        chunks_.pop_back();
    }

    totalFrames_ += frameCount;
    chunks_.push_back(std::move(chunk));
    hasAudio_.store(true, std::memory_order_release);
}

void BridgeTimedQueue::FlushAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    chunks_.clear();
    totalFrames_ = 0;
    fracOffset_ = 0.0;
    hasAudio_.store(false, std::memory_order_release);
}

void BridgeTimedQueue::FlushFromTime(double fromPtsSec) {
    if (!std::isfinite(fromPtsSec)) {
        FlushAll();
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    while (!chunks_.empty()) {
        auto &back = chunks_.back();
        if (back.startPtsSec >= fromPtsSec) {
            const size_t rem = (back.left.size() > back.readOffset) ? (back.left.size() - back.readOffset) : 0;
            totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
            chunks_.pop_back();
            continue;
        }
        const double endPts = back.startPtsSec + static_cast<double>(back.left.size()) / back.sampleRate;
        if (endPts > fromPtsSec) {
            const size_t keepFrames = static_cast<size_t>(std::max(0.0, (fromPtsSec - back.startPtsSec) * back.sampleRate));
            if (keepFrames <= back.readOffset) {
                const size_t rem = (back.left.size() > back.readOffset) ? (back.left.size() - back.readOffset) : 0;
                totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
                chunks_.pop_back();
            } else if (keepFrames < back.left.size()) {
                const size_t trimmed = back.left.size() - keepFrames;
                back.left.resize(keepFrames);
                back.right.resize(keepFrames);
                totalFrames_ = (totalFrames_ >= trimmed) ? (totalFrames_ - trimmed) : 0;
            }
        }
        break;
    }
    if (chunks_.empty()) {
        fracOffset_ = 0.0;
        hasAudio_.store(false, std::memory_order_release);
    }
}

void BridgeTimedQueue::PullFrames(double syncTimeSec,
                                  double rate,
                                  float *outL,
                                  float *outR,
                                  uint32_t outFrames,
                                  double outSampleRate,
                                  bool *outHadAudio) {
    if (outHadAudio) *outHadAudio = false;
    if (!outL || !outR || outFrames == 0) return;

    std::memset(outL, 0, outFrames * sizeof(float));
    std::memset(outR, 0, outFrames * sizeof(float));

    if (std::fabs(rate) < 0.01 || !std::isfinite(syncTimeSec) || outSampleRate <= 0.0) {
        return;
    }

    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) {
        return;
    }

    // 1. Drop stale chunks that ended >80ms behind current timeline time.
    while (!chunks_.empty()) {
        const auto &front = chunks_.front();
        const double endPts = front.startPtsSec + static_cast<double>(front.left.size()) / front.sampleRate;
        if (endPts < syncTimeSec - 0.080) {
            const size_t rem = (front.left.size() > front.readOffset) ? (front.left.size() - front.readOffset) : 0;
            totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
            chunks_.pop_front();
            fracOffset_ = 0.0;
        } else {
            break;
        }
    }

    if (chunks_.empty()) {
        hasAudio_.store(false, std::memory_order_release);
        return;
    }

    // 2. Check alignment of head frame vs syncTimeSec.
    {
        auto &front = chunks_.front();
        const double headPts = front.startPtsSec + (static_cast<double>(front.readOffset) + fracOffset_) / front.sampleRate;
        const double delta = headPts - syncTimeSec;

        // Head audio belongs >80ms in the future (e.g. native renderer draining earlier buffers): wait silently.
        if (delta > 0.080) {
            return;
        }

        // Head audio is >80ms behind timeline (seek or startup jump): catch up to syncTimeSec.
        if (delta < -0.080) {
            double targetPts = syncTimeSec;
            while (!chunks_.empty()) {
                auto &f = chunks_.front();
                const double fEnd = f.startPtsSec + static_cast<double>(f.left.size()) / f.sampleRate;
                if (fEnd <= targetPts) {
                    const size_t rem = (f.left.size() > f.readOffset) ? (f.left.size() - f.readOffset) : 0;
                    totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
                    chunks_.pop_front();
                    fracOffset_ = 0.0;
                } else {
                    const uint32_t newOff = static_cast<uint32_t>(std::max(0.0, (targetPts - f.startPtsSec) * f.sampleRate));
                    if (newOff > f.readOffset && newOff < f.left.size()) {
                        const size_t skipped = newOff - f.readOffset;
                        f.readOffset = newOff;
                        totalFrames_ = (totalFrames_ >= skipped) ? (totalFrames_ - skipped) : 0;
                    }
                    fracOffset_ = 0.0;
                    break;
                }
            }
        }
    }

    if (chunks_.empty()) {
        hasAudio_.store(false, std::memory_order_release);
        return;
    }

    // 3. Pull outFrames sequentially across chunks.
    uint32_t written = 0;
    while (written < outFrames && !chunks_.empty()) {
        auto &front = chunks_.front();
        const uint32_t avail = (front.left.size() > front.readOffset)
            ? static_cast<uint32_t>(front.left.size() - front.readOffset)
            : 0;
        if (avail == 0) {
            chunks_.pop_front();
            fracOffset_ = 0.0;
            continue;
        }

        const bool directCopy = (std::fabs(front.sampleRate - outSampleRate) < 10.0) &&
                                (std::fabs(rate - 1.0) < 0.005) &&
                                (fracOffset_ < 1e-4);
        if (directCopy) {
            const uint32_t take = std::min(avail, outFrames - written);
            std::memcpy(outL + written, front.left.data() + front.readOffset, take * sizeof(float));
            std::memcpy(outR + written, front.right.data() + front.readOffset, take * sizeof(float));
            front.readOffset += take;
            totalFrames_ = (totalFrames_ >= take) ? (totalFrames_ - take) : 0;
            written += take;
            if (front.readOffset >= front.left.size()) {
                chunks_.pop_front();
                fracOffset_ = 0.0;
            }
        } else {
            const double step = (front.sampleRate / outSampleRate) * rate;
            double pos = static_cast<double>(front.readOffset) + fracOffset_;
            while (written < outFrames && pos + 1.0 < static_cast<double>(front.left.size())) {
                const uint32_t idx0 = static_cast<uint32_t>(pos);
                const float frac = static_cast<float>(pos - static_cast<double>(idx0));
                const uint32_t idx1 = idx0 + 1;
                outL[written] = front.left[idx0] * (1.0f - frac) + front.left[idx1] * frac;
                outR[written] = front.right[idx0] * (1.0f - frac) + front.right[idx1] * frac;
                written += 1;
                pos += step;
            }
            const uint32_t consumed = static_cast<uint32_t>(std::floor(pos));
            if (consumed >= front.left.size() - 1) {
                const size_t rem = (front.left.size() > front.readOffset) ? (front.left.size() - front.readOffset) : 0;
                totalFrames_ = (totalFrames_ >= rem) ? (totalFrames_ - rem) : 0;
                chunks_.pop_front();
                fracOffset_ = 0.0;
            } else {
                const size_t adv = (consumed > front.readOffset) ? (consumed - front.readOffset) : 0;
                front.readOffset = consumed;
                fracOffset_ = pos - static_cast<double>(consumed);
                totalFrames_ = (totalFrames_ >= adv) ? (totalFrames_ - adv) : 0;
            }
        }
    }

    hasAudio_.store(!chunks_.empty(), std::memory_order_release);
    if (outHadAudio) *outHadAudio = (written > 0);
}

bool BridgeTimedQueue::HasQueuedAudio() const {
    return hasAudio_.load(std::memory_order_acquire);
}

size_t BridgeTimedQueue::BufferedFrames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return totalFrames_;
}

namespace {

struct BridgeState {
    BridgeTimedQueue queue;
    std::unique_ptr<SpatialStreamProcessor> dsp;

    std::mutex unitMutex;
    AudioUnit remoteIO = nullptr;
    bool initialized = false;
    std::atomic<bool> running{false};
    std::atomic<double> unitSampleRate{48000.0};

    std::mutex tbMutex;
    CMTimebaseRef timebase = nullptr;

    std::atomic<float> volume{1.0f};
    std::atomic<bool> muted{false};
    std::atomic<uint64_t> lastAudioNs{0};

    id interruptionObserver = nil;
    id mediaResetObserver = nil;
    bool observersInstalled = false;

    BridgeState() : dsp(std::make_unique<SpatialStreamProcessor>()) {}
};

BridgeState &State() {
    static BridgeState s;
    return s;
}

inline uint64_t NowNs() {
#if defined(CLOCK_UPTIME_RAW)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ULL + static_cast<uint64_t>(ts.tv_nsec);
#endif
}

OSStatus BridgeRenderCallback(void *inRefCon,
                              AudioUnitRenderActionFlags *ioActionFlags,
                              const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames,
                              AudioBufferList *ioData) {
    (void)inRefCon;
    (void)inTimeStamp;
    (void)inBusNumber;

    if (!ioData || ioData->mNumberBuffers < 2 || inNumberFrames == 0) {
        return noErr;
    }

    float *outL = static_cast<float *>(ioData->mBuffers[0].mData);
    float *outR = static_cast<float *>(ioData->mBuffers[1].mData);
    if (!outL || !outR) return noErr;

    BridgeState &s = State();

    double syncTimeSec = 0.0;
    double rate = 0.0;
    bool haveClock = false;
    {
        std::unique_lock<std::mutex> lk(s.tbMutex, std::try_to_lock);
        if (lk.owns_lock() && s.timebase) {
            rate = CMTimebaseGetRate(s.timebase);
            syncTimeSec = CMTimeGetSeconds(CMTimebaseGetTime(s.timebase));
            haveClock = std::isfinite(syncTimeSec);
        }
    }

    if (!haveClock) {
        std::memset(outL, 0, inNumberFrames * sizeof(float));
        std::memset(outR, 0, inNumberFrames * sizeof(float));
        if (ioActionFlags) *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    const double unitSr = s.unitSampleRate.load(std::memory_order_relaxed);
    bool hadAudio = false;
    s.queue.PullFrames(syncTimeSec, rate, outL, outR, inNumberFrames, unitSr, &hadAudio);

    if (!hadAudio) {
        if (ioActionFlags) *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    s.lastAudioNs.store(NowNs(), std::memory_order_relaxed);

    const bool isMuted = s.muted.load(std::memory_order_relaxed);
    const float vol = isMuted ? 0.0f : s.volume.load(std::memory_order_relaxed);
    if (isMuted) {
        std::memset(outL, 0, inNumberFrames * sizeof(float));
        std::memset(outR, 0, inNumberFrames * sizeof(float));
        if (ioActionFlags) *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    if (std::fabs(vol - 1.0f) > 1e-4f) {
        for (UInt32 i = 0; i < inNumberFrames; ++i) {
            outL[i] *= vol;
            outR[i] *= vol;
        }
    }

    const HookSelectionMode hmode = SpatialConfig::HookMode();
    const bool allowBridgeDsp = (hmode == HookSelectionMode::ForceBridge) ||
                                (hmode == HookSelectionMode::Auto) ||
                                SpatialConfig::IsPipelineAllowed(static_cast<int>(AudioPipelineKind::SampleBufferRenderer));
    const bool wantSpatial = RouteMonitor::ShouldProcessAudio() && allowBridgeDsp;

    if (s.dsp && s.dsp->NeedsProcessing(wantSpatial)) {
        ScopedDspGuard guard;
        if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::AudioUnitBridge)) {
            s.dsp->ProcessNonInterleavedFloat32(outL,
                                                outR,
                                                inNumberFrames,
                                                unitSr,
                                                wantSpatial,
                                                CurrentDspParamsFromConfig());
        }
    }

    return noErr;
}

bool EnsureAudioUnitLocked(BridgeState &s, double desiredSr) {
    if (!s.observersInstalled) {
        s.observersInstalled = true;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        s.interruptionObserver = [nc addObserverForName:AVAudioSessionInterruptionNotification
                                                 object:nil
                                                  queue:nil
                                             usingBlock:^(NSNotification * _Nonnull note) {
            NSNumber *typeVal = note.userInfo[AVAudioSessionInterruptionTypeKey];
            if (typeVal && typeVal.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
                AudioUnitBridge::Shared().Stop();
            } else if (typeVal && typeVal.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
                if (State().queue.HasQueuedAudio()) {
                    std::lock_guard<std::mutex> lk(State().unitMutex);
                    if (State().remoteIO && State().initialized && !State().running.load()) {
                        if (AudioOutputUnitStart(State().remoteIO) == noErr) {
                            State().running.store(true, std::memory_order_release);
                        }
                    }
                }
            }
        }];
        s.mediaResetObserver = [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                                               object:nil
                                                queue:nil
                                           usingBlock:^(__unused NSNotification * _Nonnull note) {
            std::lock_guard<std::mutex> lk(State().unitMutex);
            if (State().remoteIO) {
                UnregisterBridgeAudioUnit(State().remoteIO);
                AudioComponentInstanceDispose(State().remoteIO);
                State().remoteIO = nullptr;
            }
            State().initialized = false;
            State().running.store(false, std::memory_order_release);
        }];
    }

    double hwSr = RouteMonitor::CurrentSampleRate();
    if (hwSr < 44000.0 || hwSr > 48100.0) {
        hwSr = (desiredSr >= 44000.0 && desiredSr <= 48100.0) ? desiredSr : 48000.0;
    }

    if (s.remoteIO && s.initialized) {
        return true;
    }

    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp) return false;

    AudioUnit unit = nullptr;
    if (AudioComponentInstanceNew(comp, &unit) != noErr || !unit) {
        return false;
    }

    // Mark as our bridge unit before setting properties / initializing so HookAudioUnit ignores it.
    RegisterBridgeAudioUnit(unit);

    UInt32 enableOut = 1;
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, sizeof(enableOut));

    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = hwSr;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = sizeof(float);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(float);
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;

    if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, sizeof(asbd)) != noErr) {
        UnregisterBridgeAudioUnit(unit);
        AudioComponentInstanceDispose(unit);
        return false;
    }

    AURenderCallbackStruct cb{};
    cb.inputProc = BridgeRenderCallback;
    cb.inputProcRefCon = &s;
    if (AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb)) != noErr) {
        UnregisterBridgeAudioUnit(unit);
        AudioComponentInstanceDispose(unit);
        return false;
    }

    if (AudioUnitInitialize(unit) != noErr) {
        UnregisterBridgeAudioUnit(unit);
        AudioComponentInstanceDispose(unit);
        return false;
    }

    s.remoteIO = unit;
    s.unitSampleRate.store(hwSr, std::memory_order_release);
    s.initialized = true;
    PipelineCoordinator::RegisterStream(AudioPipelineKind::AudioUnitBridge);
    return true;
}

} // namespace

AudioUnitBridge &AudioUnitBridge::Shared() {
    static AudioUnitBridge instance;
    return instance;
}

void AudioUnitBridge::SetSynchronizerTimebase(CMTimebaseRef timebase) {
    if (!timebase) return;
    BridgeState &s = State();
    std::lock_guard<std::mutex> lock(s.tbMutex);
    if (s.timebase == timebase) return;
    if (s.timebase) {
        CFRelease(s.timebase);
    }
    s.timebase = static_cast<CMTimebaseRef>(CFRetain(timebase));
}

void AudioUnitBridge::ClearSynchronizerTimebase(CMTimebaseRef expectedTimebase) {
    BridgeState &s = State();
    std::lock_guard<std::mutex> lock(s.tbMutex);
    if (!expectedTimebase || s.timebase == expectedTimebase) {
        if (s.timebase) {
            CFRelease(s.timebase);
            s.timebase = nullptr;
        }
    }
}

void AudioUnitBridge::SetVolume(float volume) {
    State().volume.store(std::max(0.0f, std::min(1.0f, volume)), std::memory_order_relaxed);
}

void AudioUnitBridge::SetMuted(bool muted) {
    State().muted.store(muted, std::memory_order_relaxed);
}

void AudioUnitBridge::PushAudio(double startPtsSec,
                                double sampleRate,
                                const float *left,
                                const float *right,
                                uint32_t frameCount) {
    BridgeState &s = State();
    s.queue.Push(startPtsSec, sampleRate, left, right, frameCount);

    std::lock_guard<std::mutex> lock(s.unitMutex);
    if (EnsureAudioUnitLocked(s, sampleRate) && !s.running.load(std::memory_order_acquire)) {
        if (AudioOutputUnitStart(s.remoteIO) == noErr) {
            s.running.store(true, std::memory_order_release);
        }
    }
}

void AudioUnitBridge::FlushAll() {
    BridgeState &s = State();
    s.queue.FlushAll();
    if (s.dsp) s.dsp->Reset();
}

void AudioUnitBridge::FlushFromTime(double fromPtsSec) {
    BridgeState &s = State();
    s.queue.FlushFromTime(fromPtsSec);
    if (s.dsp) s.dsp->Reset();
}

void AudioUnitBridge::Stop() {
    BridgeState &s = State();
    std::lock_guard<std::mutex> lock(s.unitMutex);
    if (s.remoteIO && s.running.load(std::memory_order_acquire)) {
        AudioOutputUnitStop(s.remoteIO);
        s.running.store(false, std::memory_order_release);
    }
}

bool AudioUnitBridge::IsActive() const {
    return State().running.load(std::memory_order_acquire);
}

bool AudioUnitBridge::HasQueuedAudio() const {
    return State().queue.HasQueuedAudio();
}

double AudioUnitBridge::OutputSampleRate() const {
    return State().unitSampleRate.load(std::memory_order_relaxed);
}

} // namespace spatial
