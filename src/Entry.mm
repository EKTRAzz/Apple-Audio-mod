#include "PipelineCoordinator.h"
#include "RouteMonitor.h"
#include "SpatialEngine.h"
#include "SpatialOverlay.h"

#ifndef ENABLE_HOOK_AUDIOUNIT
#define ENABLE_HOOK_AUDIOUNIT 1
#endif

#ifndef ENABLE_HOOK_AUDIOQUEUE
#define ENABLE_HOOK_AUDIOQUEUE 1
#endif

#ifndef ENABLE_HOOK_AVPLAYER
#define ENABLE_HOOK_AVPLAYER 1
#endif

#ifndef ENABLE_HOOK_SAMPLEBUFFER
#define ENABLE_HOOK_SAMPLEBUFFER 1
#endif

#ifndef ENABLE_OVERLAY_UI
#define ENABLE_OVERLAY_UI 1
#endif

namespace spatial {
void InstallAudioUnitHook();
void InstallAudioQueueHook();
void InstallAVPlayerHook();
void InstallSampleBufferRendererHook();
} // namespace spatial

__attribute__((constructor))
static void SpatialAudioMultiHookInit() {
    // 0. Load persisted user preferences (Master ON/OFF, Preferred Pipeline, Force Route).
    spatial::PipelineCoordinator::LoadSettings();

    // 1. Pre-compute 48 kHz & 44.1 kHz True-Stereo HRIR FFT spectra.
    spatial::InitializeSharedSpectra();

    // 2. Start lock-free AVAudioSession route & mode observer.
    spatial::RouteMonitor::Initialize();

    // 3. Install multi-pipeline hooks (coordinated by Single-Winner Exclusive Lock).
#if ENABLE_HOOK_AUDIOUNIT
    spatial::InstallAudioUnitHook();
#endif
#if ENABLE_HOOK_AUDIOQUEUE
    spatial::InstallAudioQueueHook();
#endif
#if ENABLE_HOOK_AVPLAYER
    spatial::InstallAVPlayerHook();
#endif
#if ENABLE_HOOK_SAMPLEBUFFER
    spatial::InstallSampleBufferRendererHook();
#endif

    // 4. Install draggable floating status & pipeline-selector overlay window.
#if ENABLE_OVERLAY_UI
    spatial::InstallOverlayUI();
#endif
}
