# Toolchain settings shared by OctoDot's Makefiles (GNU Make 3.81, as macOS
# ships it: no grouped targets).

TOOLCHAIN_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# The pinned Goose compiler (toolchain/goose.lock), never a goose on PATH;
# its caches stay inside the repo rather than in ~/.goose.
GOOSE      := $(TOOLCHAIN_ROOT)/.toolchain/goose-src/build/goose
export GOOSE_HOME := $(TOOLCHAIN_ROOT)/.toolchain/goose-home
GOOSEFLAGS := --offline

# One Xcode: the compilers xcode-select picks, with that Xcode's own SDK.
SDK        := $(shell xcrun --sdk macosx --show-sdk-path)
CC         := $(shell xcrun --find clang)
TARGET     := arm64-apple-macos14.0

# Generated C: what `goose build` gives it, -O2, and -lm -pthread to link.
GOOSE_CFLAGS := -O2 -target $(TARGET) -isysroot $(SDK) -Wall \
                -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
LDLIBS       := -lm -pthread

$(GOOSE):
	$(TOOLCHAIN_ROOT)/toolchain/bootstrap-goose.sh
