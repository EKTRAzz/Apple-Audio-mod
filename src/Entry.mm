#include "OverlayUI.h"
#include "RouteMonitor.h"
#include "SpatialConfig.h"
#include "SpatialEngine.h"

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
    // 1. Load persisted user preferences (enabled state, Matrix/Front mode, floating button state).
    spatial::SpatialConfig::Initialize();

    // 2. Pre-compute 48 kHz & 44.1 kHz Matrix + Front True-Stereo HRIR FFT spectra.
    spatial::InitializeSharedSpectra();
    if (spatial::SpatialConfig::ActiveHrirSource() == spatial::HrirSource::CustomWav) {
        NSString *savedPath = spatial::SpatialConfig::CustomWavStoragePath();
        std::string loadErr;
        if (!savedPath || !spatial::LoadCustomWavProfile([savedPath UTF8String], loadErr)) {
            spatial::SpatialConfig::SetActiveHrirSource(spatial::HrirSource::BuiltIn);
        }
    }

    // 3. Start lock-free AVAudioSession route & mode observer.
    spatial::RouteMonitor::Initialize();

    // 4. Install multi-pipeline hooks (coordinated by Single-Winner Exclusive Lock).
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

    // 5. Install in-app floating control panel UI.
#if ENABLE_OVERLAY_UI
    spatial::InstallOverlayUI();
#endif
}
