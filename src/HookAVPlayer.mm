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

static const void *kSpatialObserverAssocKey = &kSpatialObserverAssocKey;
static char kSpatialKvoContext = 0;
thread_local bool tInSpatialSetAudioMix = false;

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
    auto *ctx = static_cast<AVPlayerTapCtx *>(MTAudioProcessingTapGetStorage(tap));
    if (!ctx || !ctx->dsp) return;

    const bool wantSpatial = RouteMonitor::ShouldProcessAudio();
    if (!ctx->dsp->NeedsProcessing(wantSpatial)) {
        return;
    }

    ScopedDspGuard guard;
    if (guard.entered && PipelineCoordinator::TryAcquire(AudioPipelineKind::AVPlayer)) {
        ctx->dsp->ProcessAudioBufferList(bufferListInOut,
                                         static_cast<uint32_t>(*numberFramesOut),
                                         ctx->asbd,
                                         wantSpatial,
                                         SpatialConfig::CurrentMode());
    }
}

MTAudioProcessingTapRef CreateSpatialTap() {
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
    return (st == noErr) ? tap : nullptr;
}

bool MixAlreadyHasTap(AVAudioMix *mix) {
    if (!mix) return false;
    for (AVAudioMixInputParameters *p in mix.inputParameters) {
        if (p.audioTapProcessor != nullptr) {
            return true;
        }
    }
    return false;
}

AVAssetTrack *FindAudioTrack(AVPlayerItem *item) {
    if (!item) return nil;
    // 1. Prefer AVPlayerItem.tracks (populated for HLS / streaming AVURLAssets once ready).
    for (AVPlayerItemTrack *itemTrack in item.tracks) {
        AVAssetTrack *at = itemTrack.assetTrack;
        if (at && [at.mediaType isEqualToString:AVMediaTypeAudio]) {
            return at;
        }
    }
    // 2. Fallback to AVAsset.tracks (for progressive / local assets).
    AVAsset *asset = item.asset;
    if (asset && [asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
        NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (audioTracks.count > 0) {
            return audioTracks.firstObject;
        }
    }
    return nil;
}

AVAudioMix *InjectTapIntoMix(AVAudioMix *existingMix, AVAssetTrack *audioTrack) {
    if (!audioTrack) return existingMix;
    if (MixAlreadyHasTap(existingMix)) return existingMix;

    MTAudioProcessingTapRef tap = CreateSpatialTap();
    if (!tap) return existingMix;

    AVMutableAudioMix *mutableMix = [AVMutableAudioMix audioMix];
    NSMutableArray<AVAudioMixInputParameters *> *newParams = [NSMutableArray array];
    bool attachedToExistingParam = false;

    if (existingMix) {
        for (AVAudioMixInputParameters *p in existingMix.inputParameters) {
            AVMutableAudioMixInputParameters *mp = [p mutableCopy];
            if (!attachedToExistingParam && mp.trackID == audioTrack.trackID) {
                mp.audioTapProcessor = tap;
                attachedToExistingParam = true;
            }
            [newParams addObject:mp];
        }
    }

    if (!attachedToExistingParam) {
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
        params.audioTapProcessor = tap;
        [newParams addObject:params];
    }

    CFRelease(tap);
    mutableMix.inputParameters = newParams;
    return mutableMix;
}

void ApplyTapNowIfPossible(AVPlayerItem *item) {
    if (!item) return;
    AVAsset *asset = item.asset;
    if (asset &&
        [asset statusOfValueForKey:@"hasProtectedContent" error:nil] == AVKeyValueStatusLoaded &&
        asset.hasProtectedContent) {
        return;
    }

    AVAudioMix *currentMix = item.audioMix;
    if (MixAlreadyHasTap(currentMix)) return;

    AVAssetTrack *audioTrack = FindAudioTrack(item);
    if (!audioTrack) return;

    AVAudioMix *merged = InjectTapIntoMix(currentMix, audioTrack);
    if (merged && merged != currentMix) {
        tInSpatialSetAudioMix = true;
        item.audioMix = merged;
        tInSpatialSetAudioMix = false;
    }
}

} // namespace
} // namespace spatial

// KVO helper for HLS / streaming AVPlayerItems whose audio tracks appear only when ReadyToPlay.
@interface SpatialPlayerItemObserver : NSObject
@property (nonatomic, unsafe_unretained) AVPlayerItem *observedItem;
@property (nonatomic, assign) BOOL attached;
@end

@implementation SpatialPlayerItemObserver

- (instancetype)initWithItem:(AVPlayerItem *)item {
    self = [super init];
    if (self && item) {
        _observedItem = item;
        _attached = NO;
        [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:&spatial::kSpatialKvoContext];
        [item addObserver:self forKeyPath:@"tracks" options:NSKeyValueObservingOptionNew context:&spatial::kSpatialKvoContext];
    }
    return self;
}

- (void)stopObserving {
    if (_observedItem) {
        @try {
            [_observedItem removeObserver:self forKeyPath:@"status" context:&spatial::kSpatialKvoContext];
            [_observedItem removeObserver:self forKeyPath:@"tracks" context:&spatial::kSpatialKvoContext];
        } @catch (NSException * __unused e) {
        }
        _observedItem = nil;
    }
}

- (void)dealloc {
    [self stopObserving];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    (void)keyPath;
    (void)change;
    if (context != &spatial::kSpatialKvoContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (_attached || ![object isKindOfClass:[AVPlayerItem class]]) return;
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (spatial::FindAudioTrack(item) != nil) {
        _attached = YES;
        __weak AVPlayerItem *weakItem = item;
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *strongItem = weakItem;
            if (strongItem) {
                spatial::ApplyTapNowIfPossible(strongItem);
            }
        });
    }
}

@end

namespace spatial {
namespace {

void AttachTapToPlayerItemIfEligible(AVPlayerItem *item) {
    if (!item) return;

    // Install KVO observer once per item so HLS streams attach as soon as tracks populate.
    if (!objc_getAssociatedObject(item, kSpatialObserverAssocKey)) {
        SpatialPlayerItemObserver *obs = [[SpatialPlayerItemObserver alloc] initWithItem:item];
        objc_setAssociatedObject(item, kSpatialObserverAssocKey, obs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    AVAsset *asset = item.asset;
    if (!asset) return;

    __weak AVPlayerItem *weakItem = item;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks", @"hasProtectedContent"] completionHandler:^{
        AVPlayerItem *strongItem = weakItem;
        if (!strongItem) return;

        NSError *err = nil;
        if ([asset statusOfValueForKey:@"hasProtectedContent" error:&err] == AVKeyValueStatusLoaded &&
            asset.hasProtectedContent) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *finalItem = weakItem;
            if (finalItem) {
                ApplyTapNowIfPossible(finalItem);
            }
        });
    }];
}

} // namespace
} // namespace spatial

@interface AVPlayerItem (SpatialAudioHook)
- (void)spatial_setAudioMix:(AVAudioMix *)audioMix;
@end

@implementation AVPlayerItem (SpatialAudioHook)

- (void)spatial_setAudioMix:(AVAudioMix *)audioMix {
    if (spatial::tInSpatialSetAudioMix) {
        [self spatial_setAudioMix:audioMix];
        return;
    }
    // If the app sets its own volume/loudness audioMix (without an audioTapProcessor),
    // preserve its parameters and keep our Spatial tap attached.
    AVAudioMix *finalMix = audioMix;
    if (audioMix && !spatial::MixAlreadyHasTap(audioMix)) {
        AVAsset *asset = self.asset;
        BOOL isProtected = (asset &&
                            [asset statusOfValueForKey:@"hasProtectedContent" error:nil] == AVKeyValueStatusLoaded &&
                            asset.hasProtectedContent);
        if (!isProtected) {
            AVAssetTrack *audioTrack = spatial::FindAudioTrack(self);
            if (audioTrack) {
                finalMix = spatial::InjectTapIntoMix(audioMix, audioTrack);
            }
        }
    }
    [self spatial_setAudioMix:finalMix];
}

@end

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
        swizzle([AVPlayerItem class], @selector(setAudioMix:), @selector(spatial_setAudioMix:));
        swizzle([AVPlayer class], @selector(initWithPlayerItem:), @selector(spatial_initWithPlayerItem:));
        swizzle([AVPlayer class], @selector(replaceCurrentItemWithPlayerItem:), @selector(spatial_replaceCurrentItemWithPlayerItem:));
        swizzle([AVQueuePlayer class], @selector(initWithItems:), @selector(spatial_initWithItems:));
        swizzle([AVQueuePlayer class], @selector(insertItem:afterItem:), @selector(spatial_insertItem:afterItem:));
    });
}

} // namespace spatial
