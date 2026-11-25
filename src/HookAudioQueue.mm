#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialEngine.h"

#import <AudioToolbox/AudioToolbox.h>
#include "fishhook.h"

#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

namespace spatial {
namespace {

struct AudioQueueHookCtx {
    AudioStreamBasicDescription asbd{};
    std::unique_ptr<SpatialStreamProcessor> dsp;
};

std::mutex gAqMutex;
std::unordered_map<AudioQueueRef, std::shared_ptr<AudioQueueHookCtx>> gAqContexts;

using FnAudioQueueNewOutput = OSStatus (*)(
    const AudioStreamBasicDescription *,
    AudioQueueOutputCallback,
    void *,
    CFRunLoopRef,
    CFStringRef,
    UInt32,
    AudioQueueRef *
);

using FnAudioQueueNewOutputWithDispatchQueue = OSStatus (*)(
    AudioQueueRef *,
    const AudioStreamBasicDescription *,
    UInt32,
    dispatch_queue_t,
    AudioQueueOutputCallbackBlock
);

using FnAudioQueueEnqueueBuffer = OSStatus (*)(
    AudioQueueRef,
    AudioQueueBufferRef,
    UInt32,
    const AudioStreamPacketDescription *
);

using FnAudioQueueEnqueueBufferWithParameters = OSStatus (*)(
    AudioQueueRef,
    AudioQueueBufferRef,
    UInt32,
    const AudioStreamPacketDescription *,
    UInt32,
    UInt32,
    UInt32,
    const AudioQueueParameterEvent *,
    const AudioTimeStamp *,
    AudioTimeStamp *
);

using FnAudioQueueDispose = OSStatus (*)(AudioQueueRef, Boolean);

FnAudioQueueNewOutput                   orig_AudioQueueNewOutput = nullptr;
FnAudioQueueNewOutputWithDispatchQueue  orig_AudioQueueNewOutputWithDispatchQueue = nullptr;
FnAudioQueueEnqueueBuffer               orig_AudioQueueEnqueueBuffer = nullptr;
FnAudioQueueEnqueueBufferWithParameters orig_AudioQueueEnqueueBufferWithParameters = nullptr;
FnAudioQueueDispose                     orig_AudioQueueDispose = nullptr;

bool IsSupportedPcmFormat(const AudioStreamBasicDescription *fmt) {
    if (!fmt) return false;
    if (fmt->mFormatID != kAudioFormatLinearPCM) return false;
    if (fmt->mChannelsPerFrame != 2) return false;
    if (fmt->mBytesPerFrame == 0) return false;
    bool is48k = (fmt->mSampleRate >= 47900.0 && fmt->mSampleRate <= 48100.0);
    bool is44k = (fmt->mSampleRate >= 44000.0 && fmt->mSampleRate <= 44200.0);
    return (is48k || is44k);
}

void RegisterQueueIfSupported(AudioQueueRef aq, const AudioStreamBasicDescription *fmt) {
    if (!aq || !IsSupportedPcmFormat(fmt)) return;
    auto ctx = std::make_shared<AudioQueueHookCtx>();
    ctx->asbd = *fmt;
    ctx->dsp = std::make_unique<SpatialStreamProcessor>();
    {
        std::lock_guard<std::mutex> lock(gAqMutex);
        gAqContexts[aq] = std::move(ctx);
    }
    PipelineCoordinator::RegisterStream(AudioPipelineKind::AudioQueue);
}

void ProcessQueueBufferIfWinner(AudioQueueRef aq, AudioQueueBufferRef buf) {
    if (!aq || !buf || !buf->mAudioData || buf->mAudioDataByteSize == 0) return;

    // Hold a shared_ptr ref so concurrent AudioQueueDispose cannot free ctx mid-DSP.
    std::shared_ptr<AudioQueueHookCtx> ctx;
    {
        std::lock_guard<std::mutex> lock(gAqMutex);
        auto it = gAqContexts.find(aq);
        if (it != gAqContexts.end()) {
            ctx = it->second;
        }
    }
    if (!ctx || !ctx->dsp || ctx->asbd.mBytesPerFrame == 0) return;

    const bool wantSpatial = RouteMonitor::ShouldProcessAudio() &&
                             SpatialConfig::IsPipelineAllowed(static_cast<int>(AudioPipelineKind::AudioQueue));
    if (!ctx->dsp->NeedsProcessing(wantSpatial)) return;

    ScopedDspGuard guard;
    if (!guard.entered || !PipelineCoordinator::TryAcquire(AudioPipelineKind::AudioQueue)) {
        return;
    }

    const uint32_t frameCount = buf->mAudioDataByteSize / ctx->asbd.mBytesPerFrame;
    if (frameCount == 0) return;

    const SpatialDspParams params = CurrentDspParamsFromConfig();
    const bool isFloat = (ctx->asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool isNonInterleaved = (ctx->asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool isSignedInt = (ctx->asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    if (isFloat && ctx->asbd.mBitsPerChannel == 32 && !isNonInterleaved) {
        ctx->dsp->ProcessInterleavedFloat32(static_cast<float *>(buf->mAudioData),
                                            frameCount,
                                            ctx->asbd.mSampleRate,
                                            wantSpatial,
                                            params);
    } else if (isSignedInt && ctx->asbd.mBitsPerChannel == 16 && !isNonInterleaved) {
        ctx->dsp->ProcessInterleavedInt16(static_cast<int16_t *>(buf->mAudioData),
                                          frameCount,
                                          ctx->asbd.mSampleRate,
                                          wantSpatial,
                                          params);
    } else if (isSignedInt && ctx->asbd.mBitsPerChannel == 32 && !isNonInterleaved) {
        ctx->dsp->ProcessInterleavedInt32(static_cast<int32_t *>(buf->mAudioData),
                                          frameCount,
                                          ctx->asbd.mSampleRate,
                                          wantSpatial,
                                          params);
    }
}

OSStatus hooked_AudioQueueNewOutput(const AudioStreamBasicDescription *inFormat,
                                    AudioQueueOutputCallback inCallbackProc,
                                    void *inUserData,
                                    CFRunLoopRef inCallbackRunLoop,
                                    CFStringRef inCallbackRunLoopMode,
                                    UInt32 inFlags,
                                    AudioQueueRef *outAQ) {
    OSStatus st = orig_AudioQueueNewOutput(inFormat, inCallbackProc, inUserData,
                                           inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ);
    if (st == noErr && outAQ && *outAQ) {
        RegisterQueueIfSupported(*outAQ, inFormat);
    }
    return st;
}

OSStatus hooked_AudioQueueNewOutputWithDispatchQueue(AudioQueueRef *outAQ,
                                                     const AudioStreamBasicDescription *inFormat,
                                                     UInt32 inFlags,
                                                     dispatch_queue_t inCallbackDispatchQueue,
                                                     AudioQueueOutputCallbackBlock inCallbackBlock) {
    OSStatus st = orig_AudioQueueNewOutputWithDispatchQueue(outAQ, inFormat, inFlags,
                                                            inCallbackDispatchQueue, inCallbackBlock);
    if (st == noErr && outAQ && *outAQ) {
        RegisterQueueIfSupported(*outAQ, inFormat);
    }
    return st;
}

OSStatus hooked_AudioQueueEnqueueBuffer(AudioQueueRef inAQ,
                                        AudioQueueBufferRef inBuffer,
                                        UInt32 inNumPacketDescs,
                                        const AudioStreamPacketDescription *inPacketDescs) {
    if (inNumPacketDescs == 0) {
        ProcessQueueBufferIfWinner(inAQ, inBuffer);
    }
    return orig_AudioQueueEnqueueBuffer(inAQ, inBuffer, inNumPacketDescs, inPacketDescs);
}

OSStatus hooked_AudioQueueEnqueueBufferWithParameters(AudioQueueRef inAQ,
                                                      AudioQueueBufferRef inBuffer,
                                                      UInt32 inNumPacketDescs,
                                                      const AudioStreamPacketDescription *inPacketDescs,
                                                      UInt32 inTrimFramesAtStart,
                                                      UInt32 inTrimFramesAtEnd,
                                                      UInt32 inNumParamValues,
                                                      const AudioQueueParameterEvent *inParamValues,
                                                      const AudioTimeStamp *inStartTime,
                                                      AudioTimeStamp *outActualStartTime) {
    if (inNumPacketDescs == 0) {
        ProcessQueueBufferIfWinner(inAQ, inBuffer);
    }
    return orig_AudioQueueEnqueueBufferWithParameters(inAQ, inBuffer, inNumPacketDescs, inPacketDescs,
                                                      inTrimFramesAtStart, inTrimFramesAtEnd,
                                                      inNumParamValues, inParamValues,
                                                      inStartTime, outActualStartTime);
}

OSStatus hooked_AudioQueueDispose(AudioQueueRef inAQ, Boolean inImmediate) {
    if (inAQ) {
        std::shared_ptr<AudioQueueHookCtx> removed;
        {
            std::lock_guard<std::mutex> lock(gAqMutex);
            auto it = gAqContexts.find(inAQ);
            if (it != gAqContexts.end()) {
                removed = std::move(it->second);
                gAqContexts.erase(it);
            }
        }
        if (removed) {
            PipelineCoordinator::UnregisterStream(AudioPipelineKind::AudioQueue);
        }
    }
    return orig_AudioQueueDispose(inAQ, inImmediate);
}

} // namespace

void InstallAudioQueueHook() {
    struct rebinding rebs[] = {
        { "AudioQueueNewOutput",                    (void *)hooked_AudioQueueNewOutput,                    (void **)&orig_AudioQueueNewOutput },
        { "AudioQueueNewOutputWithDispatchQueue",   (void *)hooked_AudioQueueNewOutputWithDispatchQueue,   (void **)&orig_AudioQueueNewOutputWithDispatchQueue },
        { "AudioQueueEnqueueBuffer",                (void *)hooked_AudioQueueEnqueueBuffer,                (void **)&orig_AudioQueueEnqueueBuffer },
        { "AudioQueueEnqueueBufferWithParameters",  (void *)hooked_AudioQueueEnqueueBufferWithParameters,  (void **)&orig_AudioQueueEnqueueBufferWithParameters },
        { "AudioQueueDispose",                      (void *)hooked_AudioQueueDispose,                      (void **)&orig_AudioQueueDispose },
    };
    rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
}

} // namespace spatial
