#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialEngine.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include "fishhook.h"

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

namespace spatial {
namespace {

struct AudioUnitHookCtx {
    AudioUnit unit = nullptr;
    AURenderCallback originalProc = nullptr;
    void *originalRefCon = nullptr;
    std::atomic<bool> hasWrappedCallback{false};
    bool hasRenderNotify = false;
    AudioStreamBasicDescription asbd{};
    std::unique_ptr<SpatialStreamProcessor> dsp;
};

std::mutex gAuMutex;
std::unordered_map<AudioUnit, std::unique_ptr<AudioUnitHookCtx>> gAuContexts;

using FnAudioUnitSetProperty = OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
using FnAUGraphSetNodeInputCallback = OSStatus (*)(AUGraph, AUNode, UInt32, const AURenderCallbackStruct *);
using FnAudioUnitInitialize = OSStatus (*)(AudioUnit);
using FnAudioComponentInstanceDispose = OSStatus (*)(AudioComponentInstance);

FnAudioUnitSetProperty          orig_AudioUnitSetProperty = nullptr;
FnAUGraphSetNodeInputCallback   orig_AUGraphSetNodeInputCallback = nullptr;
FnAudioUnitInitialize           orig_AudioUnitInitialize = nullptr;
FnAudioComponentInstanceDispose orig_AudioComponentInstanceDispose = nullptr;

bool IsTerminalOutputUnit(AudioUnit unit) {
    if (!unit) return false;
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    if (!comp) return false;
    AudioComponentDescription desc{};
    if (AudioComponentGetDescription(comp, &desc) != noErr) return false;
    if (desc.componentType != kAudioUnitType_Output) return false;
    return (desc.componentSubType == kAudioUnitSubType_RemoteIO ||
            desc.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
}

void RefreshUnitFormat(AudioUnit unit, AudioUnitHookCtx *ctx) {
    AudioStreamBasicDescription asbd{};
    UInt32 size = sizeof(asbd);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, &size) == noErr) {
        if (asbd.mSampleRate <= 0.0) {
            asbd.mSampleRate = RouteMonitor::CurrentSampleRate();
        }
        ctx->asbd = asbd;
    }
}

AudioUnitHookCtx *GetOrCreateCtxLocked(AudioUnit unit) {
    auto it = gAuContexts.find(unit);
    if (it != gAuContexts.end()) {
        return it->second.get();
    }
    auto ctx = std::make_unique<AudioUnitHookCtx>();
    ctx->unit = unit;
    ctx->dsp = std::make_unique<SpatialStreamProcessor>();
    RefreshUnitFormat(unit, ctx.get());
    AudioUnitHookCtx *raw = ctx.get();
    gAuContexts.emplace(unit, std::move(ctx));
    PipelineCoordinator::RegisterStream(AudioPipelineKind::AudioUnit);
    return raw;
}

inline AudioStreamBasicDescription EffectiveAsbd(const AudioUnitHookCtx *ctx) {
    AudioStreamBasicDescription asbd = ctx->asbd;
    if (asbd.mSampleRate <= 0.0) {
        asbd.mSampleRate = RouteMonitor::CurrentSampleRate();
    }
    return asbd;
}

OSStatus WrappedRenderCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData) {
    auto *ctx = static_cast<AudioUnitHookCtx *>(inRefCon);
    if (!ctx || !ctx->originalProc) return noErr;

    OSStatus status = ctx->originalProc(ctx->originalRefCon,
                                        ioActionFlags,
                                        inTimeStamp,
                                        inBusNumber,
                                        inNumberFrames,
                                        ioData);
    if (status != noErr || !ioData || inNumberFrames == 0) {
        return status;
    }
    if (ioActionFlags && (*ioActionFlags & kAudioUnitRenderAction_OutputIsSilence)) {
        return status;
    }
    if (!RouteMonitor::ShouldProcessAudio()) {
        return status;
    }

    ScopedDspGuard guard;
    if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::AudioUnit)) {
        ctx->dsp->ProcessAudioBufferList(ioData, inNumberFrames, EffectiveAsbd(ctx));
    }
    return status;
}

OSStatus PostRenderNotifyCallback(void *inRefCon,
                                  AudioUnitRenderActionFlags *ioActionFlags,
                                  const AudioTimeStamp *inTimeStamp,
                                  UInt32 inBusNumber,
                                  UInt32 inNumberFrames,
                                  AudioBufferList *ioData) {
    (void)inTimeStamp;
    if (!ioActionFlags || (*ioActionFlags & kAudioUnitRenderAction_PostRender) == 0) {
        return noErr;
    }
    if (inBusNumber != 0 || !ioData || inNumberFrames == 0) {
        return noErr;
    }
    if (*ioActionFlags & kAudioUnitRenderAction_OutputIsSilence) {
        return noErr;
    }

    auto *ctx = static_cast<AudioUnitHookCtx *>(inRefCon);
    // Never double-process if this unit already uses WrappedRenderCallback.
    if (!ctx || !ctx->dsp || ctx->hasWrappedCallback.load(std::memory_order_acquire)) {
        return noErr;
    }
    if (!RouteMonitor::ShouldProcessAudio()) {
        return noErr;
    }

    ScopedDspGuard guard;
    if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::AudioUnit)) {
        ctx->dsp->ProcessAudioBufferList(ioData, inNumberFrames, EffectiveAsbd(ctx));
    }
    return noErr;
}

inline bool IsOurWrappedCallback(AURenderCallback proc) {
    return reinterpret_cast<const void *>(proc) == reinterpret_cast<const void *>(&WrappedRenderCallback);
}

inline AURenderCallback AsAURenderCallback(OSStatus (*fn)(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *)) {
    return reinterpret_cast<AURenderCallback>(fn);
}

OSStatus hooked_AudioUnitSetProperty(AudioUnit inUnit,
                                     AudioUnitPropertyID inID,
                                     AudioUnitScope inScope,
                                     AudioUnitElement inElement,
                                     const void *inData,
                                     UInt32 inDataSize) {
    if (inUnit && IsTerminalOutputUnit(inUnit)) {
        if (inID == kAudioUnitProperty_SetRenderCallback &&
            inScope == kAudioUnitScope_Input &&
            inElement == 0 &&
            inData &&
            inDataSize >= sizeof(AURenderCallbackStruct)) {
            const auto *cb = static_cast<const AURenderCallbackStruct *>(inData);
            if (cb->inputProc == nullptr) {
                std::lock_guard<std::mutex> lock(gAuMutex);
                auto it = gAuContexts.find(inUnit);
                if (it != gAuContexts.end()) {
                    it->second->originalProc = nullptr;
                    it->second->originalRefCon = nullptr;
                    it->second->hasWrappedCallback.store(false, std::memory_order_release);
                }
            } else if (!IsOurWrappedCallback(cb->inputProc)) {
                AudioUnitHookCtx *ctx = nullptr;
                bool needRemoveNotify = false;
                {
                    std::lock_guard<std::mutex> lock(gAuMutex);
                    ctx = GetOrCreateCtxLocked(inUnit);
                    ctx->originalProc = cb->inputProc;
                    ctx->originalRefCon = cb->inputProcRefCon;
                    ctx->hasWrappedCallback.store(true, std::memory_order_release);
                    if (ctx->hasRenderNotify) {
                        ctx->hasRenderNotify = false;
                        needRemoveNotify = true;
                    }
                }
                if (needRemoveNotify) {
                    AudioUnitRemoveRenderNotify(inUnit, AsAURenderCallback(&PostRenderNotifyCallback), ctx);
                }
                AURenderCallbackStruct wrapped{AsAURenderCallback(&WrappedRenderCallback), ctx};
                return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, &wrapped, sizeof(wrapped));
            }
        } else if (inID == kAudioUnitProperty_StreamFormat &&
                   inScope == kAudioUnitScope_Input &&
                   inElement == 0 &&
                   inData &&
                   inDataSize >= sizeof(AudioStreamBasicDescription)) {
            OSStatus st = orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
            if (st == noErr) {
                std::lock_guard<std::mutex> lock(gAuMutex);
                auto it = gAuContexts.find(inUnit);
                if (it != gAuContexts.end()) {
                    std::memcpy(&it->second->asbd, inData, sizeof(AudioStreamBasicDescription));
                }
            }
            return st;
        }
    }
    return orig_AudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
}

OSStatus hooked_AUGraphSetNodeInputCallback(AUGraph inGraph,
                                            AUNode inDestNode,
                                            UInt32 inDestInputNumber,
                                            const AURenderCallbackStruct *inInputCallback) {
    if (inGraph && inDestInputNumber == 0 && inInputCallback && inInputCallback->inputProc) {
        AudioUnit unit = nullptr;
        if (AUGraphNodeInfo(inGraph, inDestNode, nullptr, &unit) == noErr &&
            IsTerminalOutputUnit(unit) &&
            !IsOurWrappedCallback(inInputCallback->inputProc)) {
            AudioUnitHookCtx *ctx = nullptr;
            bool needRemoveNotify = false;
            {
                std::lock_guard<std::mutex> lock(gAuMutex);
                ctx = GetOrCreateCtxLocked(unit);
                ctx->originalProc = inInputCallback->inputProc;
                ctx->originalRefCon = inInputCallback->inputProcRefCon;
                ctx->hasWrappedCallback.store(true, std::memory_order_release);
                if (ctx->hasRenderNotify) {
                    ctx->hasRenderNotify = false;
                    needRemoveNotify = true;
                }
            }
            if (needRemoveNotify) {
                AudioUnitRemoveRenderNotify(unit, AsAURenderCallback(&PostRenderNotifyCallback), ctx);
            }
            AURenderCallbackStruct wrapped{AsAURenderCallback(&WrappedRenderCallback), ctx};
            return orig_AUGraphSetNodeInputCallback(inGraph, inDestNode, inDestInputNumber, &wrapped);
        }
    }
    return orig_AUGraphSetNodeInputCallback(inGraph, inDestNode, inDestInputNumber, inInputCallback);
}

OSStatus hooked_AudioUnitInitialize(AudioUnit inUnit) {
    OSStatus st = orig_AudioUnitInitialize(inUnit);
    if (st == noErr && inUnit && IsTerminalOutputUnit(inUnit)) {
        AudioUnitHookCtx *ctx = nullptr;
        bool needAttachNotify = false;
        {
            std::lock_guard<std::mutex> lock(gAuMutex);
            ctx = GetOrCreateCtxLocked(inUnit);
            RefreshUnitFormat(inUnit, ctx);
            // If app connected nodes (e.g. AVAudioEngine / AUGraphConnectNodeInput) instead of
            // setting a direct render callback on RemoteIO, attach a PostRender notify callback.
            if (!ctx->hasWrappedCallback.load(std::memory_order_acquire) && !ctx->hasRenderNotify) {
                ctx->hasRenderNotify = true;
                needAttachNotify = true;
            }
        }
        if (needAttachNotify) {
            AudioUnitAddRenderNotify(inUnit, AsAURenderCallback(&PostRenderNotifyCallback), ctx);
        }
    }
    return st;
}

OSStatus hooked_AudioComponentInstanceDispose(AudioComponentInstance inInstance) {
    if (inInstance) {
        std::unique_ptr<AudioUnitHookCtx> removed;
        {
            std::lock_guard<std::mutex> lock(gAuMutex);
            auto it = gAuContexts.find(static_cast<AudioUnit>(inInstance));
            if (it != gAuContexts.end()) {
                removed = std::move(it->second);
                gAuContexts.erase(it);
            }
        }
        if (removed) {
            if (removed->hasRenderNotify) {
                AudioUnitRemoveRenderNotify(static_cast<AudioUnit>(inInstance), AsAURenderCallback(&PostRenderNotifyCallback), removed.get());
            }
            PipelineCoordinator::UnregisterStream(AudioPipelineKind::AudioUnit);
        }
    }
    return orig_AudioComponentInstanceDispose(inInstance);
}

} // namespace

void InstallAudioUnitHook() {
    struct rebinding rebs[] = {
        { "AudioUnitSetProperty",           (void *)hooked_AudioUnitSetProperty,           (void **)&orig_AudioUnitSetProperty },
        { "AUGraphSetNodeInputCallback",    (void *)hooked_AUGraphSetNodeInputCallback,    (void **)&orig_AUGraphSetNodeInputCallback },
        { "AudioUnitInitialize",            (void *)hooked_AudioUnitInitialize,            (void **)&orig_AudioUnitInitialize },
        { "AudioComponentInstanceDispose",  (void *)hooked_AudioComponentInstanceDispose,  (void **)&orig_AudioComponentInstanceDispose },
    };
    rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));
}

} // namespace spatial
