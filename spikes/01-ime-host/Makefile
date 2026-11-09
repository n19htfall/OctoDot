# Spike 01: a sandboxed IMK input method calling a Goose engine from @MainActor.
#
#   make            build the engine, OctoDot.app and the octo-smoke test tool
#   make test       functional checks + latency, crash behaviour, sandboxed self-test
#   make install    copy to ~/Library/Input Methods and register (changes your system)
#   make enable     add the input mode to your input sources
#   make uninstall  disable, quit and remove it
include ../common.mk

# Placeholder: before distributing, use a reverse-DNS name you control.
# macOS expects input method bundle IDs to contain ".inputmethod.".
BUNDLE_ID     ?= com.example.inputmethod.OctoDot
# "-" signs ad hoc (no keychain prompt). Set an identity for a team-signed build.
SIGN_IDENTITY ?= -

GEN := build/gen
APP := build/OctoDot.app
INSTALL_DIR := $(HOME)/Library/Input Methods

SHARED_SWIFT := $(wildcard Sources/Shared/*.swift)
IME_SWIFT    := $(wildcard Sources/IME/*.swift)
SMOKE_SWIFT  := $(wildcard Sources/Smoke/*.swift)
SWIFTFLAGS   := -swift-version 6 -O -parse-as-library -target $(TARGET) -sdk $(SDK) \
                -import-objc-header Sources/Shared/Bridging.h -I $(GEN)

.PHONY: all test install enable uninstall clean
all: $(APP) build/octo-smoke build/machlookup

build/machlookup: tools/machlookup.c
	@mkdir -p build
	$(CC) -O2 -target $(TARGET) -isysroot $(SDK) -Wall $< -o $@

$(GEN)/engine.c $(GEN)/engine.h &: engine/engine.goose engine/toy_table.tsv | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --standalone --header $(GEN)/engine.h -o $(GEN)/engine.c engine/engine.goose

build/libocto_engine.a: $(GEN)/engine.c
	$(CC) $(GOOSE_CFLAGS) -c $< -o build/engine.o
	libtool -static -o $@ build/engine.o

build/octo-smoke: $(SHARED_SWIFT) $(SMOKE_SWIFT) build/libocto_engine.a $(GEN)/engine.h
	$(SWIFTC) $(SWIFTFLAGS) $(SHARED_SWIFT) $(SMOKE_SWIFT) build/libocto_engine.a -o $@

build/make-icon: make-icon.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 6 -O -target $(TARGET) -sdk $(SDK) $< -o $@

build/MenuIcon.tiff: build/make-icon
	build/make-icon $@

$(APP): $(SHARED_SWIFT) $(IME_SWIFT) build/libocto_engine.a $(GEN)/engine.h \
        Info.plist.in OctoDot.entitlements.in build/MenuIcon.tiff
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	sed 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' Info.plist.in > $(APP)/Contents/Info.plist
	plutil -lint -s $(APP)/Contents/Info.plist
	cp build/MenuIcon.tiff $(APP)/Contents/Resources/
	$(SWIFTC) $(SWIFTFLAGS) $(SHARED_SWIFT) $(IME_SWIFT) build/libocto_engine.a \
	    -framework InputMethodKit -framework Carbon -o $(APP)/Contents/MacOS/OctoDot
	sed 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' OctoDot.entitlements.in > build/OctoDot.entitlements
	codesign --force --options runtime --timestamp=none \
	    --entitlements build/OctoDot.entitlements --sign "$(SIGN_IDENTITY)" $(APP)
	codesign --verify --strict $(APP)

test: all
	./build/octo-smoke
	./crash-tests.sh
	./sandbox-test.sh
	@echo "entitlements:"
	@codesign -d --entitlements - --xml $(APP) 2>/dev/null | plutil -convert json -o - - ; echo

install: $(APP)
	-pkill -x OctoDot
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/OctoDot.app"
	ditto $(APP) "$(INSTALL_DIR)/OctoDot.app"
	"$(INSTALL_DIR)/OctoDot.app/Contents/MacOS/OctoDot" --register
	@echo "Next: make enable (or System Settings > Keyboard > Input Sources > + > Chinese, Simplified > OctoDot)"

enable:
	"$(INSTALL_DIR)/OctoDot.app/Contents/MacOS/OctoDot" --enable

uninstall:
	-"$(INSTALL_DIR)/OctoDot.app/Contents/MacOS/OctoDot" --disable
	-pkill -x OctoDot
	rm -rf "$(INSTALL_DIR)/OctoDot.app"

clean:
	rm -rf build
