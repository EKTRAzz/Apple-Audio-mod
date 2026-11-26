# SpatialAudioMultiHook - iOS arm64 Spatial Audio DSP (.dylib)
# Requires macOS with Xcode Command Line Tools (or GitHub Actions macos-latest).

SDK       := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC        := xcrun --sdk iphoneos clang
CXX       := xcrun --sdk iphoneos clang++

ARCH      := -arch arm64
MIN_IOS   := -miphoneos-version-min=15.0

# Tuneable compile-time options
HEADROOM_DB              ?= -2.5f
ENABLE_HOOK_AUDIOUNIT    ?= 1
ENABLE_HOOK_AUDIOQUEUE   ?= 1
ENABLE_HOOK_AVPLAYER     ?= 1
ENABLE_HOOK_SAMPLEBUFFER ?= 1
ENABLE_OVERLAY_UI        ?= 1

FISHHOOK_DIR ?= third_party/fishhook

COMMON_FLAGS := $(ARCH) $(MIN_IOS) -isysroot $(SDK) -O3 -fPIC -fobjc-arc \
	-Isrc -I$(FISHHOOK_DIR) \
	-DSPATIAL_HEADROOM_DB=$(HEADROOM_DB) \
	-DENABLE_HOOK_AUDIOUNIT=$(ENABLE_HOOK_AUDIOUNIT) \
	-DENABLE_HOOK_AUDIOQUEUE=$(ENABLE_HOOK_AUDIOQUEUE) \
	-DENABLE_HOOK_AVPLAYER=$(ENABLE_HOOK_AVPLAYER) \
	-DENABLE_HOOK_SAMPLEBUFFER=$(ENABLE_HOOK_SAMPLEBUFFER) \
	-DENABLE_OVERLAY_UI=$(ENABLE_OVERLAY_UI)

CXXFLAGS := $(COMMON_FLAGS) -std=c++17 -Wall -Wextra -Wno-deprecated-declarations
CFLAGS   := $(ARCH) $(MIN_IOS) -isysroot $(SDK) -O3 -fPIC -I$(FISHHOOK_DIR)

FRAMEWORKS := \
	-framework Foundation \
	-framework UIKit \
	-framework UniformTypeIdentifiers \
	-framework CoreGraphics \
	-framework QuartzCore \
	-framework AVFoundation \
	-framework AudioToolbox \
	-framework Accelerate \
	-framework CoreMedia \
	-framework MediaToolbox

SRCS_MM := \
	src/PipelineCoordinator.mm \
	src/SpatialConfig.mm \
	src/RouteMonitor.mm \
	src/WavLoader.mm \
	src/SpatialEngine.mm \
	src/AudioUnitBridge.mm \
	src/OverlayUI.mm \
	src/HookAudioUnit.mm \
	src/HookAudioQueue.mm \
	src/HookAVPlayer.mm \
	src/HookSampleBufferRenderer.mm \
	src/Entry.mm

FISHHOOK_C := $(FISHHOOK_DIR)/fishhook.c

OUT_DIR := build
TARGET  := $(OUT_DIR)/SpatialDSP_ApplePro2.dylib

.PHONY: all clean ir

all: $(TARGET)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

$(OUT_DIR)/fishhook.o: $(FISHHOOK_C) | $(OUT_DIR)
	$(CC) $(CFLAGS) -c $(FISHHOOK_C) -o $@

$(TARGET): $(SRCS_MM) src/ir_data.h $(OUT_DIR)/fishhook.o | $(OUT_DIR)
	$(CXX) $(CXXFLAGS) -dynamiclib \
		-install_name @rpath/SpatialDSP_ApplePro2.dylib \
		$(SRCS_MM) $(OUT_DIR)/fishhook.o \
		$(FRAMEWORKS) -o $@
	codesign --force --sign - $@

# Regenerate src/ir_data.h from assets/Apple_Pro2_Stereo.wav
ir:
	python3 tools/wav_to_ir.py assets/Apple_Pro2_Stereo.wav src/ir_data.h

clean:
	rm -rf $(OUT_DIR)
