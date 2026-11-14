CC = clang
CXX = clang++

SYSROOT := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
ifeq ($(SYSROOT),)
  SYSROOT := /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
endif

ARCHS = -arch arm64
MIN_IOS = -miphoneos-version-min=14.0

CFLAGS = $(ARCHS) -isysroot $(SYSROOT) $(MIN_IOS) -O3 -fobjc-arc -Iinclude -Isrc -Wall
CXXFLAGS = $(CFLAGS) -std=c++17
LDFLAGS = $(ARCHS) -isysroot $(SYSROOT) $(MIN_IOS) -dynamiclib \
          -install_name @rpath/HeSuVi.dylib \
          -framework Foundation \
          -framework UIKit \
          -framework AudioToolbox \
          -framework Accelerate \
          -framework UniformTypeIdentifiers

TARGET = HeSuVi.dylib

C_SRCS = src/fishhook.c
CXX_SRCS = src/AudioEngine.mm src/HRIRLoader.mm src/HeSuViManager.mm src/HeSuViUI.mm src/TweakMain.mm

OBJS = $(C_SRCS:.c=.o) $(CXX_SRCS:.mm=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(LDFLAGS) -o $@ $^
	@echo "Build complete: $(TARGET)"

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.mm
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f src/*.o $(TARGET)

.PHONY: all clean
