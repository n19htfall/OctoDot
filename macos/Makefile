# OctoDot for macOS (docs/distribution-and-onboarding.md): two bundles.
#
#   OctoDotIME.app   the input method: the Goose engine as a static library,
#                    the Swift host and the images, sandboxed, no network.
#                    Its executable is a small launcher (Sources/Launcher)
#                    that serves IMK and loads the core, a library in
#                    Contents/Frameworks; an update loads a new core into the
#                    running process (OctoDotIME --reload), because apps that
#                    lose their input method's process often stop typing until
#                    they are restarted. Each build of the core has its own
#                    file and Swift module name, OctoDotCore-<hash of its
#                    inputs>, so a new one loads beside the old one.
#   OctoDot.app      the companion the user drags to /Applications: onboarding,
#                    updates, uninstall (Sources/Companion), sandboxed, with
#                    the installer (Sources/Installer), an XPC service, inside
#                    it, and OctoDotIME.app in its Resources, which it installs
#                    in ~/Library/Input Methods.
#
# Run it from the root Makefile, which builds the images first.
#   make             build/OctoDot.app (with the IME inside), build/octo-smoke, build/octo-setup-test
#   make test        the bridge, the setup and update logic, the sandboxed
#                    self-test, the window release test, the entitlement audit
#   make install     the companion into /Applications and, through it, the
#                    input method into ~/Library/Input Methods (in place when it
#                    can, removing the old com.example install when it is there)
#   make enable      add it to your input sources
#   make uninstall   remove it (your data stays) and the companion
#   make dmg         build/OctoDot-<version>[-dev].dmg; make test-dmg checks it
#   make release     SIGN_PROFILE=release: Developer ID, notarized and stapled
include ../mk/toolchain.mk

# Identity (section 2). The team signs every bundle. The IME was
# com.example.inputmethod.OctoDot until 2026-11-09: installing removes that
# install (its data is not carried over).
TEAM_ID       ?= G4JRQAX252
IME_ID        ?= io.github.n19htfall.inputmethod.OctoDot
COMPANION_ID  ?= io.github.n19htfall.OctoDot
INSTALLER_ID  ?= $(COMPANION_ID).Installer
APP_GROUP     ?= $(TEAM_ID).io.github.n19htfall.octodot
LEGACY_IME_ID := com.example.inputmethod.OctoDot
URL_SCHEME    := octodot
RELEASES      := https://github.com/n19htfall/OctoDot/releases
VERSION       := $(shell cat ../VERSION)
BUILD_NUMBER  ?= $(shell git -C .. rev-list --count HEAD 2>/dev/null || echo 1)
# The Ed25519 public key releases are signed with (tools/release-key.sh); a
# build without one checks for no updates.
UPDATE_KEY    := $(shell cat update-public-key.txt 2>/dev/null)

# Signing (section 7). dev: Apple Development, no timestamp, quick to repeat;
# release: Developer ID, timestamped, for notarization. Either way the
# Hardened Runtime, and never get-task-allow.
SIGN_PROFILE  ?= dev
ifeq ($(SIGN_PROFILE),release)
ifndef SIGN_IDENTITY
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application: .*\($(TEAM_ID)\)/ { print $$2; exit }')
endif
TIMESTAMP     := --timestamp
DMG_SUFFIX    :=
else
ifndef SIGN_IDENTITY
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk '/"Apple Development: / { print $$2; exit }')
endif
TIMESTAMP     := --timestamp=none
DMG_SUFFIX    := -dev
endif
CODESIGN       = codesign --force --options runtime $(TIMESTAMP) --sign "$(SIGN_IDENTITY)"
NOTARY_PROFILE ?= OctoDot
# The identity the bundles were last signed with. When it changes (dev to
# release, or another certificate) they are built again, so a release never
# keeps the development signature of an earlier build.
SIGNING      := build/signing
GEN          := build/gen
IME_APP      := build/OctoDotIME.app
APP          := build/OctoDot.app
# An update's companion: the app without the grammar model, which lives
# outside the bundles (Sources/Setup/GrammarPin.swift) and changes only with
# data/grammar.lock. The disk image's app carries it; an update brings it,
# from its own release (make grammar-release), only when it changed.
UPDATE_APP   := build/update/OctoDot.app
XPC          := $(APP)/Contents/XPCServices/OctoDotInstaller.xpc
DMG          := build/OctoDot-$(VERSION)$(DMG_SUFFIX).dmg
IMAGES       := ../build/images
GRAMMAR_NAME := $(shell awk '$$1 == "file" && $$3 ~ /\.gram$$/ { print $$3 }' ../data/grammar.lock)
GRAMMAR_SHA  := $(shell awk '$$1 == "file" && $$3 ~ /\.gram$$/ { print $$2 }' ../data/grammar.lock)
GRAMMAR_TAG  := grammar-$(shell printf %.12s $(GRAMMAR_SHA))
GRAMMAR_URL  := $(RELEASES)/download/$(GRAMMAR_TAG)/$(GRAMMAR_NAME)
WANXIANG_TAG := $(shell awk '$$1 == "tag" { print $$2 }' ../data/wanxiang.lock)
UNIHAN_VERSION := $(shell awk '$$1 == "version" { print $$2 }' ../data/unihan.lock)
SWIFTC       := $(shell xcrun --find swiftc)
ENGINE       := $(wildcard ../engine/*.goose) ../engine/gram.h ../engine/rerank.h ../engine/blas.c \
                ../engine/octo.build engine/ime.goose
SHARED_SWIFT := $(wildcard Sources/Shared/*.swift)
IME_SWIFT    := $(wildcard Sources/IME/*.swift) Sources/Setup/Transfer.swift Sources/Setup/GrammarPin.swift \
                Sources/Setup/AppRulesDocument.swift $(GEN)/Identity.swift
LAUNCHER_SWIFT := $(wildcard Sources/Launcher/*.swift)
SMOKE_SWIFT  := $(wildcard Sources/Smoke/*.swift)
SETUP_SWIFT  := $(wildcard Sources/Setup/*.swift) $(GEN)/Identity.swift
COMPANION_SWIFT := $(wildcard Sources/Companion/*.swift)
INSTALLER_SWIFT := $(wildcard Sources/Installer/*.swift)
# The binaries record the SDK they were built with, and AppKit draws an app
# in the design of that SDK: macOS 26's Liquid Glass only for one built with
# the macOS 26 SDK or later. The Swift driver leaves the linker to work the
# version out, and with a beta Xcode it wrote the deployment target (14.0)
# instead, so every window came out in the old design. So it is passed.
SDK_VERSION  := $(shell xcrun --sdk macosx --show-sdk-version)
MACOS_MIN    := $(patsubst arm64-apple-macos%,%,$(TARGET))
MAINFLAGS    := -swift-version 6 -O -target $(TARGET) -sdk $(SDK) \
                -Xlinker -platform_version -Xlinker macos -Xlinker $(MACOS_MIN) -Xlinker $(SDK_VERSION)
BASEFLAGS    := $(MAINFLAGS) -parse-as-library
SWIFTFLAGS   := $(BASEFLAGS) -import-objc-header Sources/Shared/Bridging.h -I $(GEN)
CORE_INPUTS  := $(SHARED_SWIFT) $(IME_SWIFT) Sources/IME/Core.h Sources/Shared/Bridging.h \
                Sources/Launcher/CoreABI.h build/libocto_engine.a
GLOSSARY_TSV    := ../data/glossary_clean.tsv
GLOSSARY_WEIGHTS := ../build/data/wanxiang/lexicon.tsv
GLOSSARY_BUILDER := scripts/build-glossary.py
GLOSSARY_INPUTS := $(GLOSSARY_TSV) $(GLOSSARY_WEIGHTS) $(GLOSSARY_BUILDER)
GLOSSARY_INDEX  := build/glossary.sqlite3
GLOSSARY_STAMP  := build/glossary.inputs
# Every file copied into Resources/data, plus the grammar pin's inputs. The
# core filename identifies both code and data, so a data-only update reloads.
CORE_DATA    := $(sort $(wildcard $(IMAGES)/lexicon*.img $(IMAGES)/spellings.*.img $(IMAGES)/aux.*.img \
                $(IMAGES)/grammar.img $(IMAGES)/english.img $(IMAGES)/syllables.tsv \
                $(IMAGES)/rerank.img $(IMAGES)/rerank.weights) $(GLOSSARY_INDEX) $(IMAGES)/semantic.tsv)
CORE_ID      := build/core.identity

.PHONY: all test install enable uninstall clean dmg test-dmg release audit check-identity release-key appcast \
        grammar-release FORCE
all: $(APP) build/octo-smoke build/octo-setup-test build/octo-reload-test build/octo-translation-test build/octo-layout-test

check-identity:
	@test -n "$(SIGN_IDENTITY)" || { echo "no $(SIGN_PROFILE) signing identity of team $(TEAM_ID) in the Keychain" \
	    "(release: a Developer ID Application certificate; or set SIGN_IDENTITY)"; exit 1; }

# Rewritten only when the identity changed, so its date says when that was.
$(SIGNING): FORCE
	@mkdir -p build
	@echo '$(SIGN_IDENTITY) $(TIMESTAMP)' | cmp -s - $@ || echo '$(SIGN_IDENTITY) $(TIMESTAMP)' > $@

# One source for the identity, which every bundle's Swift reads.
$(GEN)/Identity.swift: Makefile ../VERSION
	@mkdir -p $(GEN)
	@{ echo '// Generated by macos/Makefile from its identity variables: edit those, not this.'; \
	   echo 'enum Identity {'; \
	   echo '    static let team = "$(TEAM_ID)"'; \
	   echo '    static let ime = "$(IME_ID)"'; \
	   echo '    static let companion = "$(COMPANION_ID)"'; \
	   echo '    static let installer = "$(INSTALLER_ID)"'; \
	   echo '    static let appGroup = "$(APP_GROUP)"'; \
	   echo '    static let legacyIME = "$(LEGACY_IME_ID)"'; \
	   echo '    static let urlScheme = "$(URL_SCHEME)"'; \
	   echo '    static let releasesPrefix = "$(RELEASES)/download/"'; \
	   echo '    static let appcastURL = "$(RELEASES)/latest/download/appcast.json"'; \
	   echo '}'; } > $@

# ---- the input method ---------------------------------------------------------

# Check content even when timestamps were preserved or two builds happen
# within one timestamp interval. Rebuild here rather than relying on make to
# notice a changed stamp's modification time.
$(GLOSSARY_INDEX): $(GLOSSARY_INPUTS) FORCE
	@mkdir -p $(dir $@) $(dir $(GLOSSARY_STAMP))
	@shasum -a 256 $(GLOSSARY_INPUTS) > $(GLOSSARY_STAMP).tmp
	@if [ ! -f $@ ] || ! cmp -s $(GLOSSARY_STAMP).tmp $(GLOSSARY_STAMP); then \
	    python3 $(GLOSSARY_BUILDER) $(GLOSSARY_TSV) $(GLOSSARY_WEIGHTS) $@.tmp && \
	    mv $@.tmp $@ && mv $(GLOSSARY_STAMP).tmp $(GLOSSARY_STAMP); \
	else rm $(GLOSSARY_STAMP).tmp; fi

# Check even when timestamps are unchanged: an optional image may have been
# added or removed. Only rewrite the stamp when the identity actually changes.
# The system make compares times to the second; if a bundle was just built,
# wait for the next second so a changed identity forces that bundle to rebuild.
$(CORE_ID): $(CORE_INPUTS) $(CORE_DATA) $(IMAGES)/$(GRAMMAR_NAME) ../data/grammar.lock scripts/core-identity.sh FORCE
	@mkdir -p build
	@./scripts/core-identity.sh $(IMAGES)/$(GRAMMAR_NAME) $(CORE_INPUTS) ../data/grammar.lock $(CORE_DATA) > $@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else \
	    if [ -e "$(IME_APP)" ] && [ "$$(stat -f %m "$(IME_APP)")" = "$$(date +%s)" ]; then sleep 1; fi; \
	    touch $@.tmp && mv $@.tmp $@; \
	fi

# The generated C and its header come out of one goose run.
$(GEN)/ime.h: $(ENGINE) | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --standalone --header $@ -o $(GEN)/ime.c engine/ime.goose

# The engine: its generated C, and its own C compiled apart (engine/blas.c,
# the reranker's one call into Accelerate, which whatever links the engine
# links: -framework Accelerate).
build/libocto_engine.a: $(GEN)/ime.h ../engine/blas.c
	$(CC) $(GOOSE_CFLAGS) -c $(GEN)/ime.c -o build/ime.o
	$(CC) $(GOOSE_CFLAGS) -c ../engine/blas.c -o build/blas.o
	libtool -static -o $@ build/ime.o build/blas.o

build/octo-smoke: $(SHARED_SWIFT) $(SMOKE_SWIFT) build/libocto_engine.a
	$(SWIFTC) $(SWIFTFLAGS) $(SHARED_SWIFT) $(SMOKE_SWIFT) build/libocto_engine.a -framework Accelerate -o $@

build/launcher/OctoDotIME: $(LAUNCHER_SWIFT) Sources/Launcher/CoreABI.h
	@mkdir -p build/launcher
	$(SWIFTC) $(BASEFLAGS) -import-objc-header Sources/Launcher/CoreABI.h $(LAUNCHER_SWIFT) \
	    -framework InputMethodKit -o $@

build/make-icon: make-icon.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 6 -O -target $(TARGET) -sdk $(SDK) $< -o $@

# The menu bar's badge (outlined) and the input menu's (filled), from one run.
build/BadgeOutlined.tiff: build/make-icon
	build/make-icon $@ build/BadgeFilled.tiff

$(IME_APP): $(CORE_INPUTS) $(CORE_DATA) $(CORE_ID) $(IMAGES)/$(GRAMMAR_NAME) scripts/core-identity.sh build/launcher/OctoDotIME Info.plist.in InfoPlist.strings.in IME.entitlements.in \
            build/BadgeOutlined.tiff $(IMAGES)/lexicon.img ../data/grammar.lock ../NOTICE ../LICENSE ../LICENSE-weights \
            ../VERSION $(SIGNING) | check-identity
	rm -rf $@.partial $@
	mkdir -p $@.partial/Contents/MacOS $@.partial/Contents/Frameworks $@.partial/Contents/Resources/data
	id=$$(cat $(CORE_ID)) && \
	$(SWIFTC) $(BASEFLAGS) -import-objc-header Sources/IME/Core.h -I $(GEN) \
	    -emit-library -module-name OctoDotCore_$$id $(SHARED_SWIFT) $(IME_SWIFT) build/libocto_engine.a \
	    -framework InputMethodKit -framework Carbon -framework SwiftUI -framework Accelerate -lsqlite3 \
	    -Xlinker -weak_framework -Xlinker Translation \
	    -Xlinker -exported_symbol -Xlinker _octodot_core_v1 \
	    -o $@.partial/Contents/Frameworks/OctoDotCore-$$id.dylib && \
	sed -e 's/@BUNDLE_ID@/$(IME_ID)/g' -e "s/@CORE@/OctoDotCore-$$id.dylib/g" \
	    -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUILD@/$(BUILD_NUMBER)/g' Info.plist.in > $@.partial/Contents/Info.plist
	plutil -lint -s $@.partial/Contents/Info.plist
	cp build/launcher/OctoDotIME $@.partial/Contents/MacOS/OctoDotIME
	shasum -a 256 build/launcher/OctoDotIME | cut -d' ' -f1 > $@.partial/Contents/Resources/launcher.sha256
	cp build/BadgeOutlined.tiff build/BadgeFilled.tiff $@.partial/Contents/Resources/
	for lang in en zh-Hans; do \
	    mkdir -p $@.partial/Contents/Resources/$$lang.lproj && \
	    sed 's/@BUNDLE_ID@/$(IME_ID)/g' InfoPlist.strings.in > $@.partial/Contents/Resources/$$lang.lproj/InfoPlist.strings; \
	done
	cp $(IMAGES)/lexicon*.img $(IMAGES)/spellings.*.img $(IMAGES)/aux.*.img $(IMAGES)/grammar.img \
	    $(IMAGES)/english.img $(IMAGES)/semantic.tsv \
	    $(IMAGES)/syllables.tsv $@.partial/Contents/Resources/data/
	cp $(GLOSSARY_INDEX) $@.partial/Contents/Resources/data/glossary.sqlite3
	printf '%s %s %s\n' $(GRAMMAR_SHA) $$(stat -f %z $(IMAGES)/$(GRAMMAR_NAME)) $(GRAMMAR_NAME) \
	    > $@.partial/Contents/Resources/data/grammar.pin
	for f in rerank.img rerank.weights; do \
	    if [ -f $(IMAGES)/$$f ]; then cp -c $(IMAGES)/$$f $@.partial/Contents/Resources/data/ 2>/dev/null || \
	        cp $(IMAGES)/$$f $@.partial/Contents/Resources/data/; fi; \
	done
	cp ../LICENSE $@.partial/Contents/Resources/LICENSE.txt
	cp ../LICENSE-weights $@.partial/Contents/Resources/LICENSE-weights.txt
	cp ../.data/grammar/LICENSE $@.partial/Contents/Resources/LICENSE-grammar.txt
	cp ../NOTICE $@.partial/Contents/Resources/NOTICE.txt
	cp ../.data/wanxiang/$(WANXIANG_TAG)/LICENSE $@.partial/Contents/Resources/LICENSE-wanxiang.txt
	cp ../.data/unihan/$(UNIHAN_VERSION)/license.txt $@.partial/Contents/Resources/LICENSE-unicode.txt
	cp ../.toolchain/goose-src/LICENSE $@.partial/Contents/Resources/LICENSE-goose.txt
	sed -e 's/@BUNDLE_ID@/$(IME_ID)/g' -e 's/@APP_GROUP@/$(APP_GROUP)/g' IME.entitlements.in > build/IME.entitlements
	$(CODESIGN) $@.partial/Contents/Frameworks/*.dylib
	$(CODESIGN) --entitlements build/IME.entitlements $@.partial
	codesign --verify --strict $@.partial
	mv $@.partial $@

# ---- the companion ------------------------------------------------------------

build/companion/OctoDot: $(SETUP_SWIFT) $(COMPANION_SWIFT)
	@mkdir -p build/companion
	$(SWIFTC) $(MAINFLAGS) $(SETUP_SWIFT) $(COMPANION_SWIFT) -framework SwiftUI -framework Network -o $@

build/installer/OctoDotInstaller: $(SETUP_SWIFT) $(INSTALLER_SWIFT)
	@mkdir -p build/installer
	$(SWIFTC) $(MAINFLAGS) $(SETUP_SWIFT) $(INSTALLER_SWIFT) -framework Carbon -o $@

build/octo-setup-test: $(SETUP_SWIFT) $(wildcard Sources/SetupTests/*.swift)
	$(SWIFTC) $(MAINFLAGS) $(SETUP_SWIFT) $(wildcard Sources/SetupTests/*.swift) -o $@

build/octo-reload-test: Sources/Launcher/ReloadCoordinator.swift $(wildcard Sources/ReloadTests/*.swift)
	$(SWIFTC) $(BASEFLAGS) $^ -o $@

build/octo-translation-test: Sources/IME/CandidateTranslations.swift $(wildcard Sources/TranslationTests/*.swift) $(GLOSSARY_INDEX)
	$(SWIFTC) $(BASEFLAGS) Sources/IME/CandidateTranslations.swift $(wildcard Sources/TranslationTests/*.swift) \
	    -lsqlite3 -Xlinker -weak_framework -Xlinker Translation -o $@

build/octo-layout-test: Sources/Shared/Snapshot.swift Sources/IME/CandidatePanel.swift Sources/IME/CandidateBar.swift \
                        Sources/IME/CandidateTypesetter.swift Sources/IME/CandidateStyle.swift \
                        Sources/IME/CandidateTranslations.swift Sources/IME/TranslationModifier.swift $(wildcard Sources/CandidateLayoutTests/*.swift)
	$(SWIFTC) $(BASEFLAGS) $^ -framework AppKit -lsqlite3 -Xlinker -weak_framework -Xlinker Translation -o $@

build/make-app-icon: make-app-icon.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 6 -O -target $(TARGET) -sdk $(SDK) $< -o $@

build/AppIcon.icns: build/make-app-icon
	rm -rf build/AppIcon.iconset && build/make-app-icon build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

# Signed inside out (section 7): the IME (above, with its entitlements), then
# the installer, then the companion around both.
$(APP): $(IME_APP) build/companion/OctoDot build/installer/OctoDotInstaller build/AppIcon.icns \
        Companion.plist.in Installer.plist.in Companion.entitlements.in Installer.entitlements.in update-public-key.txt \
        $(SIGNING)
	rm -rf $@.partial $@
	mkdir -p $@.partial/Contents/MacOS $@.partial/Contents/Resources $@.partial/Contents/XPCServices/OctoDotInstaller.xpc/Contents/MacOS
	cp build/companion/OctoDot $@.partial/Contents/MacOS/OctoDot
	cp build/installer/OctoDotInstaller $@.partial/Contents/XPCServices/OctoDotInstaller.xpc/Contents/MacOS/OctoDotInstaller
	sed -e 's/@INSTALLER_ID@/$(INSTALLER_ID)/g' -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUILD@/$(BUILD_NUMBER)/g' \
	    Installer.plist.in > $@.partial/Contents/XPCServices/OctoDotInstaller.xpc/Contents/Info.plist
	sed -e 's/@COMPANION_ID@/$(COMPANION_ID)/g' -e 's/@VERSION@/$(VERSION)/g' -e 's/@BUILD@/$(BUILD_NUMBER)/g' \
	    -e 's/@URL_SCHEME@/$(URL_SCHEME)/g' -e 's|@UPDATE_KEY@|$(UPDATE_KEY)|g' Companion.plist.in > $@.partial/Contents/Info.plist
	plutil -lint -s $@.partial/Contents/Info.plist $@.partial/Contents/XPCServices/OctoDotInstaller.xpc/Contents/Info.plist
	cp build/AppIcon.icns $@.partial/Contents/Resources/AppIcon.icns
	cp ../LICENSE $@.partial/Contents/Resources/LICENSE.txt
	cp ../NOTICE $@.partial/Contents/Resources/NOTICE.txt
	ditto $(IME_APP) $@.partial/Contents/Resources/OctoDotIME.app
	mkdir -p $@.partial/Contents/Resources/Grammar
	cp -c $(IMAGES)/$(GRAMMAR_NAME) $@.partial/Contents/Resources/Grammar/ 2>/dev/null || \
	    cp $(IMAGES)/$(GRAMMAR_NAME) $@.partial/Contents/Resources/Grammar/
	sed -e 's/@APP_GROUP@/$(APP_GROUP)/g' Companion.entitlements.in > build/Companion.entitlements
	cp Installer.entitlements.in build/Installer.entitlements
	$(CODESIGN) --entitlements build/Installer.entitlements $@.partial/Contents/XPCServices/OctoDotInstaller.xpc
	$(CODESIGN) --entitlements build/Companion.entitlements $@.partial
	codesign --verify --deep --strict $@.partial
	mv $@.partial $@

# The update's companion: the same bundles without the grammar model, the
# companion signed again around them (the IME and the installer keep theirs).
$(UPDATE_APP): $(APP)
	rm -rf $@.partial $@
	@mkdir -p $(dir $@)
	ditto $(APP) $@.partial
	rm -rf $@.partial/Contents/Resources/Grammar
	$(CODESIGN) --entitlements build/Companion.entitlements $@.partial
	codesign --verify --deep --strict $@.partial
	mv $@.partial $@

update-public-key.txt:
	@touch $@

# ---- tests --------------------------------------------------------------------

audit: $(APP)
	../tools/audit-bundle.sh $(APP) $(TEAM_ID) $(SIGN_PROFILE)

test: all audit
	./build/octo-smoke $(IMAGES)
	./build/octo-setup-test
	./build/octo-reload-test
	./build/octo-translation-test
	./build/octo-layout-test
	./scripts/test-core-identity.sh
	@echo "sandboxed self-test:"
	$(IME_APP)/Contents/MacOS/OctoDotIME --selftest
	@echo "a stopping core frees its windows (out of sight):"
	$(IME_APP)/Contents/MacOS/OctoDotIME --release-test

# ---- installing (development) ---------------------------------------------------

# The companion goes to /Applications, and installs the input method the way
# it does for users: in place when only the core changed (the running IME
# loads the new core; no app is disturbed), restarting the IME only for a new
# launcher, and removing the old com.example install the first time.
install: all
	mkdir -p /Applications/OctoDot.app
	rsync -a --delete $(APP)/ /Applications/OctoDot.app/
	/Applications/OctoDot.app/Contents/MacOS/OctoDot --install

enable:
	/Applications/OctoDot.app/Contents/MacOS/OctoDot --enable

uninstall:
	/Applications/OctoDot.app/Contents/MacOS/OctoDot --uninstall

# ---- distribution (section 7) -----------------------------------------------------

dmg: $(APP) build/dmg-background.tiff
	../tools/build-dmg.sh $(APP) $(DMG) build/dmg-background.tiff "$(SIGN_IDENTITY)" $(TIMESTAMP)

test-dmg: dmg
	../tools/test-dmg.sh $(DMG) $(COMPANION_ID) $(IME_ID) $(TEAM_ID)

build/make-dmg-background: ../tools/dmg-background.swift
	@mkdir -p build
	$(SWIFTC) -swift-version 6 -O -target $(TARGET) -sdk $(SDK) $< -o $@

build/dmg-background.tiff: build/make-dmg-background
	build/make-dmg-background build/dmg-background.png build/dmg-background@2x.png
	tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png -out $@

# A release: the app notarized and stapled, then the disk image around it,
# signed, notarized and stapled too, and the update archive of the stapled
# app. Needs SIGN_PROFILE=release and a notarytool Keychain profile
# (xcrun notarytool store-credentials $(NOTARY_PROFILE)).
release:
	@test "$(SIGN_PROFILE)" = release || { echo "make release needs SIGN_PROFILE=release"; exit 1; }
	@test -n "$(UPDATE_KEY)" || { echo "no update key in macos/update-public-key.txt: make release-key and commit" \
	    "the key first; a release built without it can never update itself"; exit 1; }
	@test -z "$$(git -C .. status --porcelain)" || { echo "commit or stash these first: a release is built from" \
	    "a commit, whose count is its build number"; git -C .. status --short; exit 1; }
	$(MAKE) check-identity $(APP) $(UPDATE_APP) audit
	../tools/audit-bundle.sh $(UPDATE_APP) $(TEAM_ID) $(SIGN_PROFILE)
	../tools/notarize.sh $(APP) $(NOTARY_PROFILE)
	../tools/notarize.sh $(UPDATE_APP) $(NOTARY_PROFILE)
	$(MAKE) dmg
	../tools/notarize.sh $(DMG) $(NOTARY_PROFILE)
	spctl -a -t open --context context:primary-signature -v $(DMG)
	../tools/test-dmg.sh $(DMG) $(COMPANION_ID) $(IME_ID) $(TEAM_ID)
	rm -f build/OctoDot-$(VERSION).zip && ditto -c -k --keepParent $(UPDATE_APP) build/OctoDot-$(VERSION).zip
	@echo "release: $(DMG), and build/OctoDot-$(VERSION).zip for the update (make appcast)"
	@curl -sfIL -o /dev/null $(GRAMMAR_URL) || echo "the grammar model is not published yet: make grammar-release"

# The grammar model's own release, once per data/grammar.lock: what an update
# downloads when the model it brings is not on the Mac yet (GrammarStore).
grammar-release:
	@if curl -sfIL -o /dev/null $(GRAMMAR_URL); then echo "$(GRAMMAR_TAG) is published"; else \
	    test "$$(shasum -a 256 ../.data/grammar/$(GRAMMAR_NAME) | cut -d' ' -f1)" = $(GRAMMAR_SHA) && \
	    gh release create $(GRAMMAR_TAG) ../.data/grammar/$(GRAMMAR_NAME) ../.data/grammar/LICENSE \
	        --repo $(patsubst https://github.com/%/releases,%,$(RELEASES)) --title "Grammar model $(GRAMMAR_TAG)" \
	        --notes "万象's grammar model (RIME-LMDG, by amzxyz; CC BY 4.0), as data/grammar.lock pins it. OctoDot updates download it from here when it changes." \
	        --latest=false; fi

# The update signing key, once (tools/release-key.sh), and a release's
# signed appcast.json, from the update archive `make release` made.
UPDATE_KEY_SERVICE := io.github.n19htfall.OctoDot.update-signing
build/octo-update-sign: ../tools/update-sign/main.swift Sources/Setup/UpdateManifest.swift
	@mkdir -p build
	$(SWIFTC) $(MAINFLAGS) $^ -o $@

release-key: build/octo-update-sign
	../tools/release-key.sh build/octo-update-sign

appcast: build/octo-update-sign
	@test -f build/OctoDot-$(VERSION).zip || { echo "no build/OctoDot-$(VERSION).zip: make release first"; exit 1; }
	@# The build the archive holds, not the commit count now: the installer
	@# refuses an update whose app is not the build its manifest names.
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(UPDATE_APP)/Contents/Info.plist) && \
	security find-generic-password -s $(UPDATE_KEY_SERVICE) -w | build/octo-update-sign sign --version $(VERSION) \
	    --build $$build --min $(MACOS_MIN) --url $(RELEASES)/download/v$(VERSION)/OctoDot-$(VERSION).zip \
	    --file build/OctoDot-$(VERSION).zip --notes "$(NOTES)" > build/appcast.json
	build/octo-update-sign verify --public "$(UPDATE_KEY)" --running 0 --prefix $(RELEASES)/download/ < build/appcast.json
	@echo "attach build/OctoDot-$(VERSION).dmg, build/OctoDot-$(VERSION).zip and build/appcast.json to the v$(VERSION) release"
	@curl -sfIL -o /dev/null $(GRAMMAR_URL) || echo "and publish the grammar model first: make grammar-release"

clean:
	rm -rf build
