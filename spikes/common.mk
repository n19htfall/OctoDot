# Settings shared by every M0 spike. Each spike's Makefile includes this.

SPIKES_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT       := $(abspath $(SPIKES_DIR)/..)

# The pinned compiler (toolchain/goose.lock), never a goose on PATH. Its
# caches stay inside the repo rather than in ~/.goose.
GOOSE      := $(ROOT)/.toolchain/goose-src/build/goose
export GOOSE_HOME := $(ROOT)/.toolchain/goose-home
GOOSEFLAGS := --offline

# One Xcode for everything: the compilers xcode-select picks, with that
# Xcode's own SDK. (A bare `xcrun --show-sdk-path` may pick a different
# Command Line Tools SDK than the compilers belong to.)
SDK        := $(shell xcrun --sdk macosx --show-sdk-path)
CC         := $(shell xcrun --find clang)
SWIFTC     := $(shell xcrun --find swiftc)
MACOS_MIN  := 14.0
TARGET     := arm64-apple-macos$(MACOS_MIN)

# Generated C gets what `goose build` gives it (-O2; -lm -pthread to link).
# Unused runtime helpers are expected in the generated file.
GOOSE_CFLAGS := -O2 -target $(TARGET) -isysroot $(SDK) -Wall -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
LDLIBS       := -lm -pthread

$(GOOSE):
	$(ROOT)/toolchain/bootstrap-goose.sh
