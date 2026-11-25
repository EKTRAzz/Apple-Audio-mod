#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

namespace spatial {
namespace {

static const void *kSpatialSbrCtxKey = &kSpatialSbrCtxKey;

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
    CMSampleBufferRef ProcessSampleBuffer(CMSampleBufferRef sb) {
        if (!sb || !CMSampleBufferIsValid(sb) || !CMSampleBufferDataIsReady(sb)) {
            return nullptr;
        }

        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sb);
        if (!fmtDesc || CMFormatDescriptionGetMediaType(fmtDesc) != kCMMediaType_Audio) {
            return nullptr;
        }

        const AudioStreamBasicDescription *inAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc);
        if (!inAsbd) return nullptr;

        PipelineCoordinator::RecordPipelineSeen(AudioPipelineKind::SampleBufferRenderer);
        std::lock_guard<std::mutex> lock(mutex_);

        if (inAsbd->mFormatID == kAudioFormatLinearPCM) {
            return ProcessLinearPcmLocked(sb, fmtDesc, *inAsbd);
        }

        if (IsSupportedCompressedFormat(inAsbd->mFormatID)) {
            return ProcessCompressedLocked(sb, fmtDesc, *inAsbd);
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
                                             const AudioStreamBasicDescription &asbd) {
        if (asbd.mChannelsPerFrame != 2 || !IsSupportedPcmSampleRate(asbd.mSampleRate)) {
            return nullptr;
        }
        if (!RouteMonitor::ShouldProcessAudio()) {
            return nullptr;
        }

        CMItemCount numSamples = CMSampleBufferGetNumSamples(sb);
        if (numSamples <= 0) return nullptr;

        ScopedDspGuard guard;
        if (!guard.entered || !PipelineCoordinator::TryAcquire(AudioPipelineKind::SampleBufferRenderer)) {
            return nullptr;
        }

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
        if (st != noErr || srcAbl.mNumberBuffers == 0 || srcAbl.mNumberBuffers > 2) {
            if (retainedBlock) CFRelease(retainedBlock);
            return nullptr;
        }

        size_t totalBytes = 0;
        for (UInt32 i = 0; i < srcAbl.mNumberBuffers; ++i) {
            totalBytes += srcAbl.mBuffers[i].mDataByteSize;
        }
        if (totalBytes == 0) {
            if (retainedBlock) CFRelease(retainedBlock);
            return nullptr;
        }

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

        StereoABL dstAbl{};
        dstAbl.mNumberBuffers = srcAbl.mNumberBuffers;
        size_t offset = 0;
        for (UInt32 i = 0; i < srcAbl.mNumberBuffers; ++i) {
            UInt32 sz = srcAbl.mBuffers[i].mDataByteSize;
            std::memcpy(dstPtr + offset, srcAbl.mBuffers[i].mData, sz);
            dstAbl.mBuffers[i].mNumberChannels = srcAbl.mBuffers[i].mNumberChannels;
            dstAbl.mBuffers[i].mDataByteSize = sz;
            dstAbl.mBuffers[i].mData = dstPtr + offset;
            offset += sz;
        }

        if (retainedBlock) CFRelease(retainedBlock);

        const uint32_t frames = dsp_->ProcessAudioBufferList(reinterpret_cast<AudioBufferList *>(&dstAbl),
                                     static_cast<uint32_t>(numSamples),
                                     asbd);

        CMSampleBufferRef outSb = nullptr;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            kCFAllocatorDefault,
            outBlock,
            fmtDesc,
            numSamples,
            pts,
            nullptr,
            &outSb
        );
        CFRelease(outBlock);
        if (st != noErr || !outSb) {
            return nullptr;
        }

        PipelineCoordinator::RecordPipelineProcessed(AudioPipelineKind::SampleBufferRenderer, asbd.mSampleRate, frames);
        CMPropagateAttachments(sb, outSb);
        return outSb;
    }

    CMSampleBufferRef ProcessCompressedLocked(CMSampleBufferRef sb,
                                              CMFormatDescriptionRef fmtDesc,
                                              const AudioStreamBasicDescription &inAsbd) {
        // Only decode stereo (or implicit-channel) streams; pass through multichannel/mono untouched.
        if (inAsbd.mChannelsPerFrame != 0 && inAsbd.mChannelsPerFrame != 2) {
            return nullptr;
        }

        // If we haven't started decoding on this renderer yet and headphones aren't active,
        // pass the original compressed buffer straight through.
        if (!converter_ && !RouteMonitor::ShouldProcessAudio()) {
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

        uint32_t frames = 0;
        if (RouteMonitor::ShouldProcessAudio()) {
            ScopedDspGuard guard;
            if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::SampleBufferRenderer)) {
                frames = dsp_->ProcessNonInterleavedFloat32(pcmL_.data(),
                                                   pcmR_.data(),
                                                   static_cast<uint32_t>(pcmL_.size()),
                                                   converterOutAsbd_.mSampleRate);
            }
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

        std::memcpy(dstPtr, pcmL_.data(), chanBytes);
        std::memcpy(dstPtr + chanBytes, pcmR_.data(), chanBytes);

        CMSampleBufferRef outSb = nullptr;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            kCFAllocatorDefault,
            outBlock,
            pcmFmtDesc_,
            static_cast<CMItemCount>(pcmL_.size()),
            pts,
            nullptr,
            &outSb
        );
        CFRelease(outBlock);
        if (st != noErr || !outSb) {
            return nullptr;
        }

        PipelineCoordinator::RecordPipelineProcessed(AudioPipelineKind::SampleBufferRenderer, converterOutAsbd_.mSampleRate, frames);
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
}
@end

@implementation SpatialSBRHolder
- (instancetype)init {
    self = [super init];
    if (self) {
        ctx = std::make_unique<spatial::SampleBufferRendererCtx>();
    }
    return self;
}
@end

namespace spatial {
namespace {

SampleBufferRendererCtx *GetRendererCtx(AVSampleBufferAudioRenderer *renderer) {
    if (!renderer) return nullptr;
    @synchronized(renderer) {
        SpatialSBRHolder *holder = objc_getAssociatedObject(renderer, kSpatialSbrCtxKey);
        if (!holder) {
            holder = [[SpatialSBRHolder alloc] init];
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
@end

@implementation AVSampleBufferAudioRenderer (SpatialAudioHook)

- (void)spatial_enqueueSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    spatial::SampleBufferRendererCtx *ctx = spatial::GetRendererCtx(self);
    CMSampleBufferRef processed = ctx ? ctx->ProcessSampleBuffer(sampleBuffer) : nullptr;
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
    [self spatial_flush];
}

- (void)spatial_flushFromSourceTime:(CMTime)time completionHandler:(void (^)(BOOL flushSucceeded))completionHandler {
    spatial::SampleBufferRendererCtx *ctx = spatial::GetRendererCtx(self);
    if (ctx) {
        ctx->Reset();
    }
    [self spatial_flushFromSourceTime:time completionHandler:completionHandler];
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
    });
}

} // namespace spatial
