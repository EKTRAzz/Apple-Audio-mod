#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialEngine.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/runtime.h>

#include <memory>

namespace spatial {
namespace {

struct AVPlayerTapCtx {
    AudioStreamBasicDescription asbd{};
    std::unique_ptr<SpatialStreamProcessor> dsp;
};

void TapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    (void)tap;
    (void)clientInfo;
    auto *ctx = new AVPlayerTapCtx();
    ctx->dsp = std::make_unique<SpatialStreamProcessor>();
    *tapStorageOut = ctx;
    PipelineCoordinator::RegisterStream(AudioPipelineKind::AVPlayer);
}

void TapFinalize(MTAudioProcessingTapRef tap) {
    auto *ctx = static_cast<AVPlayerTapCtx *>(MTAudioProcessingTapGetStorage(tap));
    if (ctx) {
        delete ctx;
        PipelineCoordinator::UnregisterStream(AudioPipelineKind::AVPlayer);
    }
}

void TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat) {
    (void)maxFrames;
    auto *ctx = static_cast<AVPlayerTapCtx *>(MTAudioProcessingTapGetStorage(tap));
    if (ctx && processingFormat) {
        ctx->asbd = *processingFormat;
        ctx->dsp->Reset();
    }
}

void TapUnprepare(MTAudioProcessingTapRef tap) {
    auto *ctx = static_cast<AVPlayerTapCtx *>(MTAudioProcessingTapGetStorage(tap));
    if (ctx && ctx->dsp) {
        ctx->dsp->Reset();
    }
}

void TapProcess(MTAudioProcessingTapRef tap,
                CMItemCount numberFrames,
                MTAudioProcessingTapFlags flags,
                AudioBufferList *bufferListInOut,
                CMItemCount *numberFramesOut,
                MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nullptr, numberFramesOut);
    if (status != noErr || !bufferListInOut || !numberFramesOut || *numberFramesOut <= 0) {
        return;
    }
    if (!RouteMonitor::ShouldProcessAudio()) {
        return;
    }

    auto *ctx = static_cast<AVPlayerTapCtx *>(MTAudioProcessingTapGetStorage(tap));
    if (!ctx || !ctx->dsp) return;

    ScopedDspGuard guard;
    if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::AVPlayer)) {
        ctx->dsp->ProcessAudioBufferList(bufferListInOut, static_cast<uint32_t>(*numberFramesOut), ctx->asbd);
    }
}

void AttachTapToPlayerItemIfEligible(AVPlayerItem *item) {
    if (!item || item.audioMix != nil) return;
    AVAsset *asset = item.asset;
    if (!asset) return;

    __weak AVPlayerItem *weakItem = item;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"hasProtectedContent"] completionHandler:^{
        AVPlayerItem *strongItem = weakItem;
        if (!strongItem || strongItem.audioMix != nil) return;

        // Safely skip FairPlay DRM protected streams (MTAudioProcessingTap is unsupported by iOS on DRM).
        NSError *err = nil;
        if ([asset statusOfValueForKey:@"hasProtectedContent" error:&err] == AVKeyValueStatusLoaded &&
            asset.hasProtectedContent) {
            return;
        }
        if ([asset statusOfValueForKey:@"tracks" error:&err] != AVKeyValueStatusLoaded) {
            return;
        }

        NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count == 0) return;

        MTAudioProcessingTapCallbacks callbacks{};
        callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
        callbacks.clientInfo = nullptr;
        callbacks.init = TapInit;
        callbacks.finalize = TapFinalize;
        callbacks.prepare = TapPrepare;
        callbacks.unprepare = TapUnprepare;
        callbacks.process = TapProcess;

        MTAudioProcessingTapRef tap = nullptr;
        OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault,
                                                 &callbacks,
                                                 kMTAudioProcessingTapCreationFlag_PostEffects,
                                                 &tap);
        if (st != noErr || !tap) return;

        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTracks.firstObject];
        params.audioTapProcessor = tap;
        CFRelease(tap);

        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        mix.inputParameters = @[params];

        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *finalItem = weakItem;
            if (finalItem && finalItem.audioMix == nil) {
                finalItem.audioMix = mix;
            }
        });
    }];
}

} // namespace
} // namespace spatial

@interface AVPlayer (SpatialAudioHook)
- (instancetype)spatial_initWithPlayerItem:(AVPlayerItem *)item;
- (void)spatial_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item;
@end

@implementation AVPlayer (SpatialAudioHook)

- (instancetype)spatial_initWithPlayerItem:(AVPlayerItem *)item {
    if (item) {
        spatial::AttachTapToPlayerItemIfEligible(item);
    }
    return [self spatial_initWithPlayerItem:item];
}

- (void)spatial_replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    if (item) {
        spatial::AttachTapToPlayerItemIfEligible(item);
    }
    [self spatial_replaceCurrentItemWithPlayerItem:item];
}

@end

@interface AVQueuePlayer (SpatialAudioHook)
- (instancetype)spatial_initWithItems:(NSArray<AVPlayerItem *> *)items;
- (void)spatial_insertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem;
@end

@implementation AVQueuePlayer (SpatialAudioHook)

- (instancetype)spatial_initWithItems:(NSArray<AVPlayerItem *> *)items {
    for (AVPlayerItem *item in items) {
        spatial::AttachTapToPlayerItemIfEligible(item);
    }
    return [self spatial_initWithItems:items];
}

- (void)spatial_insertItem:(AVPlayerItem *)item afterItem:(AVPlayerItem *)afterItem {
    if (item) {
        spatial::AttachTapToPlayerItemIfEligible(item);
    }
    [self spatial_insertItem:item afterItem:afterItem];
}

@end

namespace spatial {

void InstallAVPlayerHook() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        auto swizzle = [](Class cls, SEL origSel, SEL newSel) {
            Method m1 = class_getInstanceMethod(cls, origSel);
            Method m2 = class_getInstanceMethod(cls, newSel);
            if (m1 && m2) {
                method_exchangeImplementations(m1, m2);
            }
        };
        swizzle([AVPlayer class], @selector(initWithPlayerItem:), @selector(spatial_initWithPlayerItem:));
        swizzle([AVPlayer class], @selector(replaceCurrentItemWithPlayerItem:), @selector(spatial_replaceCurrentItemWithPlayerItem:));
        swizzle([AVQueuePlayer class], @selector(initWithItems:), @selector(spatial_initWithItems:));
        swizzle([AVQueuePlayer class], @selector(insertItem:afterItem:), @selector(spatial_insertItem:afterItem:));
    });
}

} // namespace spatial
