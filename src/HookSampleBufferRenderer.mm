#include "AudioUnitBridge.h"
#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialConfig.h"
#include "SpatialEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace spatial {
namespace {

static const void *kSpatialSbrCtxKey = &kSpatialSbrCtxKey;
static const void *kSpatialSyncKey = &kSpatialSyncKey;
static const void *kSpatialParentRendererKey = &kSpatialParentRendererKey;

bool IsSupportedPcmSampleRate(double sr) {
    return (sr >= 47900.0 && sr <= 48100.0) || (sr >= 44000.0 && sr <= 44200.0);
}

bool IsSupportedCompressedFormat(AudioFormatID fmtId) {
    return (fmtId == kAudioFormatMPEG4AAC ||
            fmtId == kAudioFormatMPEG4AAC_HE ||
            fmtId == kAudioFormatMPEG4AAC_HE_V2 ||
            fmtId == kAudioFormatMPEG4AAC_LD ||
            fmtId == kAudioFormatMPEG4AAC_ELD ||
            fmtId == kAudioFormatOpus ||
            fmtId == kAudioFormatMPEGLayer3);
}

OSStatus CreatePcmSampleBuffer(CMBlockBufferRef data,
                               CMFormatDescriptionRef format,
                               const AudioStreamBasicDescription &asbd,
                               CMItemCount frameCount,
                               CMTime pts,
                               CMSampleBufferRef *outBuffer) {
    if ((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0) {
        return CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            kCFAllocatorDefault, data, format, frameCount, pts, nullptr, outBuffer);
    }

    // One frame spans the channel planes, so Core Media cannot use a sample size array.
    const CMSampleTimingInfo timing{
        CMTimeMake(1, static_cast<int32_t>(asbd.mSampleRate)), pts, kCMTimeInvalid
    };
    return CMSampleBufferCreateReady(
        kCFAllocatorDefault, data, format, frameCount, 1, &timing, 0, nullptr, outBuffer);
}

struct CompressedDecodeFeed {
    const uint8_t *data = nullptr;
    size_t dataSize = 0;
    const AudioStreamPacketDescription *packetDescs = nullptr;
    UInt32 bytesPerPacket = 0;
    UInt32 packetCount = 0;
    UInt32 nextPacket = 0;
    AudioStreamPacketDescription singlePacketDesc{};
};

OSStatus DecodeInputDataProc(AudioConverterRef inAudioConverter,
                             UInt32 *ioNumberDataPackets,
                             AudioBufferList *ioData,
                             AudioStreamPacketDescription **outDataPacketDescription,
                             void *inUserData) {
    (void)inAudioConverter;
    auto *feed = static_cast<CompressedDecodeFeed *>(inUserData);
    if (!feed || feed->nextPacket >= feed->packetCount) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    UInt32 idx = feed->nextPacket++;
    if (feed->packetDescs) {
        const AudioStreamPacketDescription &desc = feed->packetDescs[idx];
        ioData->mBuffers[0].mData = const_cast<uint8_t *>(feed->data + desc.mStartOffset);
        ioData->mBuffers[0].mDataByteSize = desc.mDataByteSize;
        if (outDataPacketDescription) {
            feed->singlePacketDesc = desc;
            feed->singlePacketDesc.mStartOffset = 0;
            *outDataPacketDescription = &feed->singlePacketDesc;
        }
    } else if (feed->bytesPerPacket > 0) {
        const size_t offset = static_cast<size_t>(idx) * feed->bytesPerPacket;
        const size_t remaining = (offset < feed->dataSize) ? (feed->dataSize - offset) : 0;
        const UInt32 pktBytes = static_cast<UInt32>(remaining < feed->bytesPerPacket ? remaining : feed->bytesPerPacket);
        ioData->mBuffers[0].mData = const_cast<uint8_t *>(feed->data + offset);
        ioData->mBuffers[0].mDataByteSize = pktBytes;
        if (outDataPacketDescription) {
            feed->singlePacketDesc.mStartOffset = 0;
            feed->singlePacketDesc.mVariableFramesInPacket = 0;
            feed->singlePacketDesc.mDataByteSize = pktBytes;
            *outDataPacketDescription = &feed->singlePacketDesc;
        }
    } else {
        ioData->mBuffers[0].mData = const_cast<uint8_t *>(feed->data);
        ioData->mBuffers[0].mDataByteSize = static_cast<UInt32>(feed->dataSize);
        if (outDataPacketDescription) {
            feed->singlePacketDesc.mStartOffset = 0;
            feed->singlePacketDesc.mVariableFramesInPacket = 0;
            feed->singlePacketDesc.mDataByteSize = static_cast<UInt32>(feed->dataSize);
            *outDataPacketDescription = &feed->singlePacketDesc;
        }
    }

    *ioNumberDataPackets = 1;
    return noErr;
}

bool ExtractFloatPlanarFromAudioBufferList(const AudioBufferList *abl,
                                           const AudioStreamBasicDescription &asbd,
                                           uint32_t frameCount,
                                           std::vector<float> &outL,
                                           std::vector<float> &outR) {
    if (!abl || frameCount == 0 || asbd.mChannelsPerFrame != 2) return false;
    const bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    const bool signedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;

    outL.resize(frameCount);
    outR.resize(frameCount);

    if (isFloat && asbd.mBitsPerChannel == 32) {
        if (planar && abl->mNumberBuffers >= 2) {
            std::memcpy(outL.data(), abl->mBuffers[0].mData, frameCount * sizeof(float));
            std::memcpy(outR.data(), abl->mBuffers[1].mData, frameCount * sizeof(float));
            return true;
        }
        if (!planar && abl->mNumberBuffers >= 1) {
            const float *src = static_cast<const float *>(abl->mBuffers[0].mData);
            for (uint32_t i = 0; i < frameCount; ++i) {
                outL[i] = src[2 * i];
                outR[i] = src[2 * i + 1];
            }
            return true;
        }
    } else if (signedInt && asbd.mBitsPerChannel == 16) {
        constexpr float kInv32768 = 1.0f / 32768.0f;
        if (planar && abl->mNumberBuffers >= 2) {
            const int16_t *l = static_cast<const int16_t *>(abl->mBuffers[0].mData);
            const int16_t *r = static_cast<const int16_t *>(abl->mBuffers[1].mData);
            for (uint32_t i = 0; i < frameCount; ++i) {
                outL[i] = static_cast<float>(l[i]) * kInv32768;
                outR[i] = static_cast<float>(r[i]) * kInv32768;
            }
            return true;
        }
        if (!planar && abl->mNumberBuffers >= 1) {
            const int16_t *src = static_cast<const int16_t *>(abl->mBuffers[0].mData);
            for (uint32_t i = 0; i < frameCount; ++i) {
                outL[i] = static_cast<float>(src[2 * i]) * kInv32768;
                outR[i] = static_cast<float>(src[2 * i + 1]) * kInv32768;
            }
            return true;
        }
    } else if (signedInt && asbd.mBitsPerChannel == 32) {
        constexpr double kInvMax = 1.0 / 2147483648.0;
        if (planar && abl->mNumberBuffers >= 2) {
            const int32_t *l = static_cast<const int32_t *>(abl->mBuffers[0].mData);
            const int32_t *r = static_cast<const int32_t *>(abl->mBuffers[1].mData);
            for (uint32_t i = 0; i < frameCount; ++i) {
                outL[i] = static_cast<float>(static_cast<double>(l[i]) * kInvMax);
                outR[i] = static_cast<float>(static_cast<double>(r[i]) * kInvMax);
            }
            return true;
        }
        if (!planar && abl->mNumberBuffers >= 1) {
            const int32_t *src = static_cast<const int32_t *>(abl->mBuffers[0].mData);
            for (uint32_t i = 0; i < frameCount; ++i) {
                outL[i] = static_cast<float>(static_cast<double>(src[2 * i]) * kInvMax);
                outR[i] = static_cast<float>(static_cast<double>(src[2 * i + 1]) * kInvMax);
            }
            return true;
        }
    }

    return false;
}

} // namespace
} // namespace spatial

@interface SpatialSyncHolder : NSObject
@property (nonatomic, weak) AVSampleBufferRenderSynchronizer *synchronizer;
@end

@implementation SpatialSyncHolder
@end

@interface SpatialParentRendererHolder : NSObject
@property (nonatomic, weak) AVSampleBufferAudioRenderer *renderer;
@end

@implementation SpatialParentRendererHolder
@end

namespace spatial {
namespace {

void BindSynchronizerToRenderer(AVSampleBufferAudioRenderer *renderer, AVSampleBufferRenderSynchronizer *sync) {
    if (!renderer || !sync) return;
    @synchronized(renderer) {
        SpatialSyncHolder *holder = objc_getAssociatedObject(renderer, kSpatialSyncKey);
        if (!holder) {
            holder = [[SpatialSyncHolder alloc] init];
            objc_setAssociatedObject(renderer, kSpatialSyncKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        holder.synchronizer = sync;
    }
    CMTimebaseRef tb = sync.timebase;
    if (tb) {
        AudioUnitBridge::Shared().SetSynchronizerTimebase(tb);
    }
    AudioUnitBridge::Shared().SetVolume(renderer.volume);
    AudioUnitBridge::Shared().SetMuted(renderer.muted);
}

void UnbindSynchronizerFromRenderer(AVSampleBufferAudioRenderer *renderer, AVSampleBufferRenderSynchronizer *sync, CMTime atTime) {
    if (!renderer) return;
    @synchronized(renderer) {
        SpatialSyncHolder *holder = objc_getAssociatedObject(renderer, kSpatialSyncKey);
        if (holder && (!sync || holder.synchronizer == sync)) {
            holder.synchronizer = nil;
        }
    }
    if (sync) {
        if (CMTIME_IS_NUMERIC(atTime)) {
            AudioUnitBridge::Shared().FlushFromTime(CMTimeGetSeconds(atTime));
        } else {
            AudioUnitBridge::Shared().FlushAll();
        }
        AudioUnitBridge::Shared().ClearSynchronizerTimebase(sync.timebase);
    }
}

AVSampleBufferRenderSynchronizer *GetBoundSynchronizer(AVSampleBufferAudioRenderer *renderer) {
    if (!renderer) return nil;
    @synchronized(renderer) {
        SpatialSyncHolder *holder = objc_getAssociatedObject(renderer, kSpatialSyncKey);
        return holder ? holder.synchronizer : nil;
    }
}

bool ShouldBridgeSampleBuffer(AVSampleBufferAudioRenderer *renderer) {
    if (!renderer) return false;
    if (SpatialConfig::HookMode() != HookSelectionMode::ForceBridge) return false;
    if (!RouteMonitor::IsRouteEligible()) return false;

    AVSampleBufferRenderSynchronizer *sync = GetBoundSynchronizer(renderer);
    if (!sync || !sync.timebase) return false;

    const float rate = sync.rate;
    // Allow pre-buffering at rate == 0.0 and normal 1.0x playback; fall back natively for variable speed.
    const bool normalSpeed = (std::fabs(rate) < 0.01f) || (std::fabs(rate - 1.0f) <= 0.05f);
    if (!normalSpeed) return false;

    AudioUnitBridge::Shared().SetSynchronizerTimebase(sync.timebase);
    AudioUnitBridge::Shared().SetVolume(renderer.volume);
    AudioUnitBridge::Shared().SetMuted(renderer.muted);
    return true;
}

class SampleBufferRendererCtx {
public:
    SampleBufferRendererCtx() : dsp_(std::make_unique<SpatialStreamProcessor>()) {
        PipelineCoordinator::RegisterStream(AudioPipelineKind::SampleBufferRenderer);
    }

    ~SampleBufferRendererCtx() {
        DisposeConverterLocked();
        PipelineCoordinator::UnregisterStream(AudioPipelineKind::SampleBufferRenderer);
    }

    void Reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (dsp_) dsp_->Reset();
        if (converter_) AudioConverterReset(converter_);
    }

    // Returns a newly retained CMSampleBufferRef if transformed, or nullptr to pass original untouched.
    CMSampleBufferRef ProcessSampleBuffer(CMSampleBufferRef sb, bool useBridge) {
        if (!sb || !CMSampleBufferIsValid(sb) || !CMSampleBufferDataIsReady(sb)) {
            return nullptr;
        }

        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
        if (!fmtDesc || CMFormatDescriptionGetMediaType(fmtDesc) != kCMMediaType_Audio) {
            return nullptr;
        }

        const AudioStreamBasicDescription *inAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
        if (!inAsbd) return nullptr;

        std::lock_guard<std::mutex> lock(mutex_);

        if (inAsbd->mFormatID == kAudioFormatLinearPCM) {
            return ProcessLinearPcmLocked(sb, fmtDesc, *inAsbd, useBridge);
        }

        if (IsSupportedCompressedFormat(inAsbd->mFormatID)) {
            return ProcessCompressedLocked(sb, fmtDesc, *inAsbd, useBridge);
        }

        return nullptr;
    }

private:
    void DisposeConverterLocked() {
        if (converter_) {
            AudioConverterDispose(converter_);
            converter_ = nullptr;
        }
        if (pcmFmtDesc_) {
            CFRelease(pcmFmtDesc_);
            pcmFmtDesc_ = nullptr;
        }
        std::memset(&converterInAsbd_, 0, sizeof(converterInAsbd_));
        converterCookie_.clear();
    }

    bool EnsureConverterLocked(CMFormatDescriptionRef fmtDesc, const AudioStreamBasicDescription &inAsbd) {
        size_t cookieSize = 0;
        const void *cookiePtr = CMAudioFormatDescriptionGetMagicCookie(fmtDesc, &cookieSize);

        bool sameFormat = (converter_ != nullptr &&
                           std::memcmp(&converterInAsbd_, &inAsbd, sizeof(inAsbd)) == 0 &&
                           converterCookie_.size() == cookieSize &&
                           (cookieSize == 0 || std::memcmp(converterCookie_.data(), cookiePtr, cookieSize) == 0));
        if (sameFormat) {
            return true;
        }

        DisposeConverterLocked();

        double outSr = inAsbd.mSampleRate;
        // HE-AAC (SBR) often reports base sample rate (e.g. 24000 / 22050) while decoding to 2x.
        if (inAsbd.mFormatID == kAudioFormatMPEG4AAC_HE || inAsbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2) {
            if (outSr >= 22000.0 && outSr <= 24100.0) {
                outSr *= 2.0;
            }
        }
        if (!IsSupportedPcmSampleRate(outSr)) {
            return false;
        }

        AudioStreamBasicDescription outAsbd{};
        outAsbd.mSampleRate       = outSr;
        outAsbd.mFormatID         = kAudioFormatLinearPCM;
        outAsbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        outAsbd.mBytesPerPacket   = sizeof(float);
        outAsbd.mFramesPerPacket  = 1;
        outAsbd.mBytesPerFrame    = sizeof(float);
        outAsbd.mChannelsPerFrame = 2;
        outAsbd.mBitsPerChannel   = 32;

        AudioConverterRef conv = nullptr;
        OSStatus st = AudioConverterNew(&inAsbd, &outAsbd, &conv);
        if (st != noErr || !conv) {
            return false;
        }

        if (cookiePtr && cookieSize > 0) {
            AudioConverterSetProperty(conv,
                                      kAudioConverterDecompressionMagicCookie,
                                      static_cast<UInt32>(cookieSize),
                                      cookiePtr);
            converterCookie_.assign(static_cast<const uint8_t *>(cookiePtr),
                                    static_cast<const uint8_t *>(cookiePtr) + cookieSize);
        }

        CMAudioFormatDescriptionRef outFmt = nullptr;
        st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                            &outAsbd,
                                            0,
                                            nullptr,
                                            0,
                                            nullptr,
                                            nullptr,
                                            &outFmt);
        if (st != noErr || !outFmt) {
            AudioConverterDispose(conv);
            return false;
        }

        converter_ = conv;
        converterInAsbd_ = inAsbd;
        converterOutAsbd_ = outAsbd;
        pcmFmtDesc_ = outFmt;
        if (dsp_) dsp_->Reset();
        return true;
    }

    CMSampleBufferRef ProcessLinearPcmLocked(CMSampleBufferRef sb,
                                             CMFormatDescriptionRef fmtDesc,
                                             const AudioStreamBasicDescription &asbd,
                                             bool useBridge) {
        const auto flags = asbd.mFormatFlags;
        const bool planar = (flags & kAudioFormatFlagIsNonInterleaved) != 0;
        const bool float32 = (flags & kAudioFormatFlagIsFloat) && asbd.mBitsPerChannel == 32;
        const bool signedInt = (flags & kAudioFormatFlagIsSignedInteger) &&
                               (asbd.mBitsPerChannel == 16 || asbd.mBitsPerChannel == 32);
        const UInt32 channelsPerBuffer = planar ? 1 : 2;
        if (asbd.mChannelsPerFrame != 2 || !IsSupportedPcmSampleRate(asbd.mSampleRate) ||
            (!float32 && !signedInt) || (flags & kAudioFormatFlagIsBigEndian) ||
            asbd.mBytesPerFrame != channelsPerBuffer * (asbd.mBitsPerChannel / 8)) {
            return nullptr;
        }

        const bool wantSpatial = RouteMonitor::ShouldProcessAudio() &&
                                 SpatialConfig::IsPipelineAllowed(static_cast<int>(AudioPipelineKind::SampleBufferRenderer));
        if (!useBridge && (!dsp_ || !dsp_->NeedsProcessing(wantSpatial))) {
            return nullptr;
        }

        CMItemCount numSamples = CMSampleBufferGetNumSamples(sb);
        if (numSamples <= 0 || static_cast<uint64_t>(numSamples) > UINT32_MAX / asbd.mBytesPerFrame) {
            return nullptr;
        }
        const size_t bytesPerBuffer = static_cast<size_t>(numSamples) * asbd.mBytesPerFrame;

        struct StereoABL {
            UInt32 mNumberBuffers;
            AudioBuffer mBuffers[2];
        } srcAbl{};

        CMBlockBufferRef retainedBlock = nullptr;
        OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb,
            nullptr,
            reinterpret_cast<AudioBufferList *>(&srcAbl),
            sizeof(srcAbl),
            nullptr,
            nullptr,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &retainedBlock
        );
        if (st != noErr || srcAbl.mNumberBuffers != (planar ? 2 : 1)) {
            if (retainedBlock) CFRelease(retainedBlock);
            return nullptr;
        }

        for (UInt32 i = 0; i < srcAbl.mNumberBuffers; ++i) {
            const AudioBuffer &buffer = srcAbl.mBuffers[i];
            if (!buffer.mData || buffer.mNumberChannels != channelsPerBuffer ||
                buffer.mDataByteSize < bytesPerBuffer) {
                if (retainedBlock) CFRelease(retainedBlock);
                return nullptr;
            }
        }
        const size_t totalBytes = bytesPerBuffer * srcAbl.mNumberBuffers;

        CMBlockBufferRef outBlock = nullptr;
        st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                nullptr,
                                                totalBytes,
                                                kCFAllocatorDefault,
                                                nullptr,
                                                0,
                                                totalBytes,
                                                kCMBlockBufferAssureMemoryNowFlag,
                                                &outBlock);
        if (st != noErr || !outBlock) {
            if (retainedBlock) CFRelease(retainedBlock);
            return nullptr;
        }

        char *dstPtr = nullptr;
        size_t dstLen = 0;
        st = CMBlockBufferGetDataPointer(outBlock, 0, nullptr, &dstLen, &dstPtr);
        if (st != noErr || !dstPtr || dstLen < totalBytes) {
            CFRelease(outBlock);
            if (retainedBlock) CFRelease(retainedBlock);
            return nullptr;
        }

        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);

        if (useBridge) {
            const double ptsSec = CMTimeGetSeconds(pts);
            if (std::isfinite(ptsSec) &&
                ExtractFloatPlanarFromAudioBufferList(reinterpret_cast<const AudioBufferList *>(&srcAbl),
                                                      asbd,
                                                      static_cast<uint32_t>(numSamples),
                                                      pcmL_,
                                                      pcmR_)) {
                if (retainedBlock) CFRelease(retainedBlock);
                AudioUnitBridge::Shared().PushAudio(ptsSec,
                                                    asbd.mSampleRate,
                                                    pcmL_.data(),
                                                    pcmR_.data(),
                                                    static_cast<uint32_t>(numSamples));
                // Enqueue silent PCM buffer to keep AVSampleBufferRenderSynchronizer timeline/A-V sync intact.
                std::memset(dstPtr, 0, totalBytes);
                CMSampleBufferRef outSb = nullptr;
                st = CreatePcmSampleBuffer(outBlock, fmtDesc, asbd, numSamples, pts, &outSb);
                CFRelease(outBlock);
                if (st != noErr || !outSb) {
                    return nullptr;
                }
                CMPropagateAttachments(sb, outSb);
                return outSb;
            }
        }

        StereoABL dstAbl{};
        dstAbl.mNumberBuffers = srcAbl.mNumberBuffers;
        size_t offset = 0;
        for (UInt32 i = 0; i < srcAbl.mNumberBuffers; ++i) {
            std::memcpy(dstPtr + offset, srcAbl.mBuffers[i].mData, bytesPerBuffer);
            dstAbl.mBuffers[i].mNumberChannels = channelsPerBuffer;
            dstAbl.mBuffers[i].mDataByteSize = static_cast<UInt32>(bytesPerBuffer);
            dstAbl.mBuffers[i].mData = dstPtr + offset;
            offset += bytesPerBuffer;
        }

        if (retainedBlock) CFRelease(retainedBlock);

        CMSampleBufferRef outSb = nullptr;
        st = CreatePcmSampleBuffer(outBlock, fmtDesc, asbd, numSamples, pts, &outSb);
        CFRelease(outBlock);
        if (st != noErr || !outSb) {
            return nullptr;
        }

        // Claim the pipeline only after Core Media has accepted our replacement.
        ScopedDspGuard guard;
        if (!guard.entered || !PipelineCoordinator::TryAcquire(AudioPipelineKind::SampleBufferRenderer)) {
            CFRelease(outSb);
            return nullptr;
        }
        dsp_->ProcessAudioBufferList(reinterpret_cast<AudioBufferList *>(&dstAbl),
                                     static_cast<uint32_t>(numSamples),
                                     asbd,
                                     wantSpatial,
                                     CurrentDspParamsFromConfig());
        CMPropagateAttachments(sb, outSb);
        return outSb;
    }

    CMSampleBufferRef ProcessCompressedLocked(CMSampleBufferRef sb,
                                              CMFormatDescriptionRef fmtDesc,
                                              const AudioStreamBasicDescription &inAsbd,
                                              bool useBridge) {
        // Only decode stereo (or implicit-channel) streams; pass through multichannel/mono untouched.
        if (inAsbd.mChannelsPerFrame != 0 && inAsbd.mChannelsPerFrame != 2) {
            return nullptr;
        }

        const bool pipeAllowed = SpatialConfig::IsPipelineAllowed(static_cast<int>(AudioPipelineKind::SampleBufferRenderer));
        const bool wantDecode = useBridge || (pipeAllowed && RouteMonitor::ShouldProcessAudio());
        if (!converter_ && !wantDecode) {
            return nullptr;
        }

        if (!EnsureConverterLocked(fmtDesc, inAsbd)) {
            return nullptr;
        }

        CMBlockBufferRef dataBuf = CMSampleBufferGetDataBuffer(sb);
        if (!dataBuf) return nullptr;

        size_t totalLen = CMBlockBufferGetDataLength(dataBuf);
        if (totalLen == 0) return nullptr;

        compressedBuf_.resize(totalLen);
        if (CMBlockBufferCopyDataBytes(dataBuf, 0, totalLen, compressedBuf_.data()) != noErr) {
            return nullptr;
        }

        CMItemCount numPackets = CMSampleBufferGetNumSamples(sb);
        if (numPackets <= 0) return nullptr;

        size_t descSizeNeeded = 0;
        OSStatus st = CMSampleBufferGetAudioStreamPacketDescriptions(sb, 0, nullptr, &descSizeNeeded);
        packetDescs_.clear();
        if (st == noErr && descSizeNeeded > 0) {
            packetDescs_.resize(descSizeNeeded / sizeof(AudioStreamPacketDescription));
            if (CMSampleBufferGetAudioStreamPacketDescriptions(sb, descSizeNeeded, packetDescs_.data(), nullptr) != noErr) {
                packetDescs_.clear();
            }
        }

        CompressedDecodeFeed feed{};
        feed.data = compressedBuf_.data();
        feed.dataSize = compressedBuf_.size();
        feed.packetDescs = packetDescs_.empty() ? nullptr : packetDescs_.data();
        feed.bytesPerPacket = inAsbd.mBytesPerPacket;
        if (!packetDescs_.empty()) {
            feed.packetCount = static_cast<UInt32>(packetDescs_.size());
        } else if (inAsbd.mBytesPerPacket > 0) {
            feed.packetCount = static_cast<UInt32>(compressedBuf_.size() / inAsbd.mBytesPerPacket);
        } else {
            feed.packetCount = 1;
        }
        feed.nextPacket = 0;

        pcmL_.clear();
        pcmR_.clear();

        constexpr UInt32 kDecodeChunkFrames = 2048;
        float chunkL[kDecodeChunkFrames];
        float chunkR[kDecodeChunkFrames];

        while (feed.nextPacket < feed.packetCount) {
            UInt32 outFrames = kDecodeChunkFrames;
            struct StereoABL {
                UInt32 mNumberBuffers;
                AudioBuffer mBuffers[2];
            } outAbl{};
            outAbl.mNumberBuffers = 2;
            outAbl.mBuffers[0].mNumberChannels = 1;
            outAbl.mBuffers[0].mDataByteSize = kDecodeChunkFrames * sizeof(float);
            outAbl.mBuffers[0].mData = chunkL;
            outAbl.mBuffers[1].mNumberChannels = 1;
            outAbl.mBuffers[1].mDataByteSize = kDecodeChunkFrames * sizeof(float);
            outAbl.mBuffers[1].mData = chunkR;

            OSStatus convSt = AudioConverterFillComplexBuffer(
                converter_,
                DecodeInputDataProc,
                &feed,
                &outFrames,
                reinterpret_cast<AudioBufferList *>(&outAbl),
                nullptr
            );

            if (outFrames > 0) {
                pcmL_.insert(pcmL_.end(), chunkL, chunkL + outFrames);
                pcmR_.insert(pcmR_.end(), chunkR, chunkR + outFrames);
            }
            if (convSt != noErr || outFrames == 0) {
                break;
            }
        }

        if (pcmL_.empty()) {
            return nullptr;
        }

        const size_t chanBytes = pcmL_.size() * sizeof(float);
        const size_t totalOutBytes = chanBytes * 2;

        CMBlockBufferRef outBlock = nullptr;
        st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                nullptr,
                                                totalOutBytes,
                                                kCFAllocatorDefault,
                                                nullptr,
                                                0,
                                                totalOutBytes,
                                                kCMBlockBufferAssureMemoryNowFlag,
                                                &outBlock);
        if (st != noErr || !outBlock) return nullptr;

        char *dstPtr = nullptr;
        size_t dstLen = 0;
        st = CMBlockBufferGetDataPointer(outBlock, 0, nullptr, &dstLen, &dstPtr);
        if (st != noErr || !dstPtr || dstLen < totalOutBytes) {
            CFRelease(outBlock);
            return nullptr;
        }

        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);

        if (useBridge) {
            const double ptsSec = CMTimeGetSeconds(pts);
            if (std::isfinite(ptsSec)) {
                AudioUnitBridge::Shared().PushAudio(ptsSec,
                                                    converterOutAsbd_.mSampleRate,
                                                    pcmL_.data(),
                                                    pcmR_.data(),
                                                    static_cast<uint32_t>(pcmL_.size()));
                std::memset(dstPtr, 0, totalOutBytes);
                CMSampleBufferRef outSb = nullptr;
                st = CreatePcmSampleBuffer(outBlock, pcmFmtDesc_, converterOutAsbd_,
                                           static_cast<CMItemCount>(pcmL_.size()), pts, &outSb);
                CFRelease(outBlock);
                if (st != noErr || !outSb) {
                    return nullptr;
                }
                CMPropagateAttachments(sb, outSb);
                return outSb;
            }
        }

        std::memcpy(dstPtr, pcmL_.data(), chanBytes);
        std::memcpy(dstPtr + chanBytes, pcmR_.data(), chanBytes);

        CMSampleBufferRef outSb = nullptr;
        st = CreatePcmSampleBuffer(outBlock, pcmFmtDesc_, converterOutAsbd_,
                                   static_cast<CMItemCount>(pcmL_.size()), pts, &outSb);
        CFRelease(outBlock);
        if (st != noErr || !outSb) {
            return nullptr;
        }

        const bool wantSpatial = RouteMonitor::ShouldProcessAudio() && pipeAllowed;
        if (dsp_ && dsp_->NeedsProcessing(wantSpatial)) {
            ScopedDspGuard guard;
            if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::SampleBufferRenderer)) {
                dsp_->ProcessNonInterleavedFloat32(reinterpret_cast<float *>(dstPtr),
                                                   reinterpret_cast<float *>(dstPtr + chanBytes),
                                                   static_cast<uint32_t>(pcmL_.size()),
                                                   converterOutAsbd_.mSampleRate,
                                                   wantSpatial,
                                                   CurrentDspParamsFromConfig());
            }
        }

        CMPropagateAttachments(sb, outSb);
        return outSb;
    }

    std::mutex mutex_;
    std::unique_ptr<SpatialStreamProcessor> dsp_;
    AudioConverterRef converter_ = nullptr;
    AudioStreamBasicDescription converterInAsbd_{};
    AudioStreamBasicDescription converterOutAsbd_{};
    CMAudioFormatDescriptionRef pcmFmtDesc_ = nullptr;
    std::vector<uint8_t> converterCookie_;
    std::vector<uint8_t> compressedBuf_;
    std::vector<AudioStreamPacketDescription> packetDescs_;
    std::vector<float> pcmL_;
    std::vector<float> pcmR_;
};

} // namespace
} // namespace spatial

@interface SpatialSBRHolder : NSObject {
@public
    std::unique_ptr<spatial::SampleBufferRendererCtx> ctx;
    id autoFlushObserver;
}
@end

@implementation SpatialSBRHolder
- (instancetype)initWithRenderer:(AVSampleBufferAudioRenderer *)renderer {
    self = [super init];
    if (self) {
        ctx = std::make_unique<spatial::SampleBufferRendererCtx>();
        if (renderer) {
            autoFlushObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
                            object:renderer
                             queue:nil
                        usingBlock:^(__unused NSNotification * _Nonnull note) {
                spatial::AudioUnitBridge::Shared().FlushAll();
            }];
        }
    }
    return self;
}
- (void)dealloc {
    if (autoFlushObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:autoFlushObserver];
        autoFlushObserver = nil;
    }
}
@end

namespace spatial {
namespace {

SampleBufferRendererCtx *GetRendererCtx(AVSampleBufferAudioRenderer *renderer) {
    if (!renderer) return nullptr;
    @synchronized(renderer) {
        SpatialSBRHolder *holder = objc_getAssociatedObject(renderer, kSpatialSbrCtxKey);
        if (!holder) {
            holder = [[SpatialSBRHolder alloc] initWithRenderer:renderer];
            objc_setAssociatedObject(renderer, kSpatialSbrCtxKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return holder->ctx.get();
    }
}

} // namespace
} // namespace spatial

@interface AVSampleBufferAudioRenderer (SpatialAudioHook)
- (void)spatial_enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer;
- (void)spatial_flush;
- (void)spatial_flushFromSourceTime:(CMTime)time completionHandler:(void (^)(BOOL flushSucceeded))completionHandler;
- (void)spatial_setVolume:(float)volume;
- (void)spatial_setMuted:(BOOL)muted;
- (id)spatial_sampleBufferReceiver;
@end

@implementation AVSampleBufferAudioRenderer (SpatialAudioHook)

- (void)spatial_enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    spatial::SampleBufferRendererCtx *ctx = spatial::GetRendererCtx(self);
    const bool useBridge = spatial::ShouldBridgeSampleBuffer(self);
    CMSampleBufferRef processed = ctx ? ctx->ProcessSampleBuffer(sampleBuffer, useBridge) : nullptr;
    if (processed) {
        [self spatial_enqueueSampleBuffer:processed];
        CFRelease(processed);
    } else {
        [self spatial_enqueueSampleBuffer:sampleBuffer];
    }
}

- (void)spatial_flush {
    spatial::SampleBufferRendererCtx *ctx = spatial::GetRendererCtx(self);
    if (ctx) {
        ctx->Reset();
    }
    spatial::AudioUnitBridge::Shared().FlushAll();
    [self spatial_flush];
}

- (void)spatial_flushFromSourceTime:(CMTime)time completionHandler:(void (^)(BOOL flushSucceeded))completionHandler {
    spatial::SampleBufferRendererCtx *ctx = spatial::GetRendererCtx(self);
    if (ctx) {
        ctx->Reset();
    }
    if (CMTIME_IS_NUMERIC(time)) {
        spatial::AudioUnitBridge::Shared().FlushFromTime(CMTimeGetSeconds(time));
    } else {
        spatial::AudioUnitBridge::Shared().FlushAll();
    }
    [self spatial_flushFromSourceTime:time completionHandler:completionHandler];
}

- (void)spatial_setVolume:(float)volume {
    spatial::AudioUnitBridge::Shared().SetVolume(volume);
    [self spatial_setVolume:volume];
}

- (void)spatial_setMuted:(BOOL)muted {
    spatial::AudioUnitBridge::Shared().SetMuted(muted ? true : false);
    [self spatial_setMuted:muted];
}

- (id)spatial_sampleBufferReceiver {
    id receiver = [self spatial_sampleBufferReceiver];
    if (receiver) {
        SpatialParentRendererHolder *holder = objc_getAssociatedObject(receiver, spatial::kSpatialParentRendererKey);
        if (!holder) {
            holder = [[SpatialParentRendererHolder alloc] init];
            objc_setAssociatedObject(receiver, spatial::kSpatialParentRendererKey, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        holder.renderer = self;
    }
    return receiver;
}

@end

@interface AVSampleBufferRenderSynchronizer (SpatialAudioHook)
- (void)spatial_addRenderer:(id<AVQueuedSampleBufferRendering>)renderer;
- (void)spatial_removeRenderer:(id<AVQueuedSampleBufferRendering>)renderer
                        atTime:(CMTime)time
             completionHandler:(void (^)(BOOL didRemoveRenderer))completionHandler;
- (void)spatial_addReceiver:(id)receiver;
- (void)spatial_removeReceiver:(id)receiver
                        atTime:(CMTime)time
             completionHandler:(void (^)(BOOL didRemoveReceiver))completionHandler;
@end

@implementation AVSampleBufferRenderSynchronizer (SpatialAudioHook)

- (void)spatial_addRenderer:(id<AVQueuedSampleBufferRendering>)renderer {
    [self spatial_addRenderer:renderer];
    if ([renderer isKindOfClass:[AVSampleBufferAudioRenderer class]]) {
        spatial::BindSynchronizerToRenderer((AVSampleBufferAudioRenderer *)renderer, self);
    }
}

- (void)spatial_removeRenderer:(id<AVQueuedSampleBufferRendering>)renderer
                        atTime:(CMTime)time
             completionHandler:(void (^)(BOOL didRemoveRenderer))completionHandler {
    if ([renderer isKindOfClass:[AVSampleBufferAudioRenderer class]]) {
        spatial::UnbindSynchronizerFromRenderer((AVSampleBufferAudioRenderer *)renderer, self, time);
    }
    [self spatial_removeRenderer:renderer atTime:time completionHandler:completionHandler];
}

- (void)spatial_addReceiver:(id)receiver {
    [self spatial_addReceiver:receiver];
    if (receiver) {
        SpatialParentRendererHolder *holder = objc_getAssociatedObject(receiver, spatial::kSpatialParentRendererKey);
        if (holder && holder.renderer) {
            spatial::BindSynchronizerToRenderer(holder.renderer, self);
        }
    }
}

- (void)spatial_removeReceiver:(id)receiver
                        atTime:(CMTime)time
             completionHandler:(void (^)(BOOL didRemoveReceiver))completionHandler {
    if (receiver) {
        SpatialParentRendererHolder *holder = objc_getAssociatedObject(receiver, spatial::kSpatialParentRendererKey);
        if (holder && holder.renderer) {
            spatial::UnbindSynchronizerFromRenderer(holder.renderer, self, time);
        }
    }
    [self spatial_removeReceiver:receiver atTime:time completionHandler:completionHandler];
}

@end

namespace spatial {

void InstallSampleBufferRendererHook() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        auto swizzle = [](Class cls, SEL origSel, SEL newSel) {
            Method m1 = class_getInstanceMethod(cls, origSel);
            Method m2 = class_getInstanceMethod(cls, newSel);
            if (m1 && m2) {
                method_exchangeImplementations(m1, m2);
            }
        };
        swizzle([AVSampleBufferAudioRenderer class], @selector(enqueueSampleBuffer:), @selector(spatial_enqueueSampleBuffer:));
        swizzle([AVSampleBufferAudioRenderer class], @selector(flush), @selector(spatial_flush));
        swizzle([AVSampleBufferAudioRenderer class], @selector(flushFromSourceTime:completionHandler:), @selector(spatial_flushFromSourceTime:completionHandler:));
        swizzle([AVSampleBufferAudioRenderer class], @selector(setVolume:), @selector(spatial_setVolume:));
        swizzle([AVSampleBufferAudioRenderer class], @selector(setMuted:), @selector(spatial_setMuted:));
        if ([AVSampleBufferAudioRenderer instancesRespondToSelector:@selector(sampleBufferReceiver)]) {
            swizzle([AVSampleBufferAudioRenderer class], @selector(sampleBufferReceiver), @selector(spatial_sampleBufferReceiver));
        }

        swizzle([AVSampleBufferRenderSynchronizer class], @selector(addRenderer:), @selector(spatial_addRenderer:));
        swizzle([AVSampleBufferRenderSynchronizer class], @selector(removeRenderer:atTime:completionHandler:), @selector(spatial_removeRenderer:atTime:completionHandler:));
        if ([AVSampleBufferRenderSynchronizer instancesRespondToSelector:@selector(addReceiver:)]) {
            swizzle([AVSampleBufferRenderSynchronizer class], @selector(addReceiver:), @selector(spatial_addReceiver:));
        }
        if ([AVSampleBufferRenderSynchronizer instancesRespondToSelector:@selector(removeReceiver:atTime:completionHandler:)]) {
            swizzle([AVSampleBufferRenderSynchronizer class], @selector(removeReceiver:atTime:completionHandler:), @selector(spatial_removeReceiver:atTime:completionHandler:));
        }
    });
}

} // namespace spatial
