# OctoDot. The M0 spikes build on their own: make -C spikes
#
#   make                    fetch the pinned 万象 files and Unihan, prepare them, build the images
#   make app                build the input method (macos/build/OctoDot.app)
#   make install            install it in ~/Library/Input Methods; a running IME loads it in place (FORCE=1 restarts it)
#   make test               the privacy check, octo-prep, the images, typing through the engine, and the app
#   make bench              the images against M1's gates: size, load time, memory, lookups
#   make eval               ranking quality, judged by the lexicon itself (SCHEME=flypy for 小鹤双拼)
#   make accuracy           the accuracy set (data/accuracy.lock's sources), with every miss (SCHEME=flypy for 小鹤双拼;
#                           DIAGNOSE=1 says why each sentence is missed)
#   make fuzz               fuzz the image loaders (FUZZ_SECONDS=20 per target)
#   make test-debug         typing, the images and 小鹤双拼 accuracy, built with Goose's --debug checks
#   make relock TAG=v18.2.0 pin another 万象 release and show what changed
#   make clean
include mk/toolchain.mk

WANXIANG_TAG := $(shell awk '$$1 == "tag" { print $$2 }' data/wanxiang.lock)
WANXIANG     := .data/wanxiang/$(WANXIANG_TAG)
UNIHAN       := .data/unihan/$(shell awk '$$1 == "version" { print $$2 }' data/unihan.lock)
GRAMMAR      := .data/grammar/$(shell awk '$$1 == "file" && $$3 ~ /\.gram$$/ { print $$3 }' data/grammar.lock)
PREPARED     := build/data/wanxiang
IMAGES       := build/images
RERANK_DIR   := .data/rerank
BIN          := build/bin
BIN_DEBUG    := build/bin-debug
ACCURACY     := build/accuracy
OCTO_PREP    := tools/octo-prep/.build/release/octo-prep
PREP_SOURCES := $(shell find tools/octo-prep/Sources -name '*.swift') tools/octo-prep/Package.swift
ENGINE       := $(wildcard engine/*.goose) engine/gram.h engine/rerank.h engine/blas.c engine/octo.build

.PHONY: all fetch prep images app dmg-dev dmg-release appcast release-key uninstall install test test-prep test-images test-typing test-accuracy test-app test-debug check-privacy fetch-accuracy bench bench-typing-memory eval accuracy fuzz relock clean
all: images

# Idempotent: verifies the pinned files and downloads only what is missing.
fetch:
	@tools/fetch-wanxiang.sh
	@tools/fetch-unihan.sh
	@tools/fetch-pinned.sh data/grammar.lock .data/grammar
	@tools/fetch-pinned.sh data/agid.lock .data/agid
	@tools/fetch-pinned.sh data/rerank.lock $(RERANK_DIR)

$(OCTO_PREP): $(PREP_SOURCES)
	swift build -c release --package-path tools/octo-prep

$(PREPARED)/report.json: $(OCTO_PREP) data/wanxiang.lock data/unihan.lock data/grammar.lock data/agid.lock \
        data/daily-extra.txt data/wanxiang-typo-rules.txt | fetch
	$(OCTO_PREP) --source $(WANXIANG) --out $(PREPARED) --lock data/wanxiang.lock --unihan $(UNIHAN) \
	    --daily-extra data/daily-extra.txt --grammar $(GRAMMAR) --agid .data/agid/infl.txt \
	    --drop-rules data/wanxiang-typo-rules.txt

prep: fetch $(PREPARED)/report.json

# Goose programs: the engine package plus one root file each.
$(BIN)/octo-compile: tools/octo-compile/octo-compile.goose $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

$(BIN)/images-test: engine/tests/images_test.goose $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

$(BIN)/typing-test: engine/tests/typing_test.goose $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

$(BIN)/eval: engine/tests/eval.goose $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

$(BIN)/accuracy: engine/tests/accuracy.goose $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

# --debug checks overflow and range, and builds the C at -O0. Its own
# directory, so a debug run never replaces the release binaries.
$(BIN_DEBUG)/typing-test: engine/tests/typing_test.goose $(ENGINE) | $(GOOSE)
	@mkdir -p $(BIN_DEBUG)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS) --debug

$(BIN_DEBUG)/images-test: engine/tests/images_test.goose $(ENGINE) | $(GOOSE)
	@mkdir -p $(BIN_DEBUG)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS) --debug

$(BIN_DEBUG)/accuracy: engine/tests/accuracy.goose $(ENGINE) | $(GOOSE)
	@mkdir -p $(BIN_DEBUG)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS) --debug

$(BIN)/images-bench: engine/bench/images_bench.goose engine/bench/metrics.c engine/bench/images_bench.build $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

$(BIN)/typing-memory: engine/bench/typing_memory.goose engine/bench/metrics.c engine/bench/typing_memory.build $(ENGINE) | $(GOOSE)
	$(GOOSE) build $< -o $@ $(GOOSEFLAGS)

# One octo-compile run writes every image; lexicon.img stands for them all.
# The grammar model goes beside grammar.img as it is: a hard link (one copy
# on disk), or a clone or copy across volumes. So does the reranker's
# weights file beside rerank.img: the released model data/rerank.lock pins
# (docs/rerank-design.md), fetched into $(RERANK_DIR).
$(IMAGES)/lexicon.img: $(BIN)/octo-compile $(PREPARED)/report.json data/rerank.lock | fetch
	$(BIN)/octo-compile $(PREPARED) $(IMAGES) --rerank $(RERANK_DIR)
	ln -f $(GRAMMAR) $(IMAGES)/ 2>/dev/null || cp -c $(GRAMMAR) $(IMAGES)/
	for f in rerank.weights rerank.check.tsv; do \
	    ln -f $(RERANK_DIR)/$$f $(IMAGES)/ 2>/dev/null || cp -c $(RERANK_DIR)/$$f $(IMAGES)/; done

images: prep $(IMAGES)/lexicon.img

app: images
	$(MAKE) -C macos all

# Distribution (docs/distribution-and-onboarding.md): a development-signed disk
# image, checked (mounted read-only); or a release, Developer ID signed,
# notarized and stapled, with its update archive. make appcast signs a
# release's update manifest; make release-key makes the signing key, once.
dmg-dev: images
	$(MAKE) -C macos test-dmg SIGN_PROFILE=dev

dmg-release: images
	$(MAKE) -C macos release SIGN_PROFILE=release

appcast:
	$(MAKE) -C macos appcast SIGN_PROFILE=release

release-key:
	$(MAKE) -C macos release-key

uninstall:
	$(MAKE) -C macos uninstall

install: images
	$(MAKE) -C macos install

test: check-privacy test-prep test-images test-typing test-app test-accuracy

# No typed text in any log: engine code prints nothing, aborts carry fixed
# messages, the IME logs privately (tools/check-privacy.sh).
check-privacy:
	@tools/check-privacy.sh

test-prep: fetch
	swift test --package-path tools/octo-prep

test-images: images $(BIN)/images-test
	$(BIN)/images-test $(PREPARED) $(IMAGES)

# Chinese senses of English words already in the dictionary. Missing file:
# the mixed decoder keeps its previous scores.
$(IMAGES)/semantic.tsv: tools/compile-semantic.py data/glossary_clean.tsv $(PREPARED)/english.tsv $(PREPARED)/lexicon.tsv
	python3 tools/compile-semantic.py data/glossary_clean.tsv $(PREPARED)/english.tsv $(PREPARED)/lexicon.tsv $@

test-typing: images $(IMAGES)/semantic.tsv $(BIN)/typing-test
	$(BIN)/typing-test $(IMAGES)

# The same three checks as a debug build. Full pinyin accuracy is several
# minutes with the checks on, so this runs 小鹤双拼 only. Latency gates fail
# at -O0; the flag prints them and does not fail the run.
test-debug: images $(BIN_DEBUG)/typing-test $(BIN_DEBUG)/images-test $(BIN_DEBUG)/accuracy $(ACCURACY)/words.tsv
	$(BIN_DEBUG)/typing-test $(IMAGES) --no-latency-gates
	$(BIN_DEBUG)/images-test $(PREPARED) $(IMAGES)
	$(BIN_DEBUG)/accuracy $(IMAGES) $(ACCURACY) flypy

# The accuracy set, from outside sources pinned in data/accuracy.lock and
# fetched into .data/accuracy/ for testing only (never committed or shipped).
fetch-accuracy:
	@tools/fetch-pinned.sh data/accuracy.lock .data/accuracy

$(ACCURACY)/words.tsv: $(OCTO_PREP) data/accuracy.lock $(PREPARED)/report.json | fetch-accuracy
	$(OCTO_PREP) accuracy --sources .data/accuracy --prepared $(PREPARED) --out $(ACCURACY)

# M1's accuracy gate, in both schemes: 95% of the common words and idioms first; names, places and
# sentences are metrics. The summaries only (make accuracy lists the misses).
test-accuracy: images $(IMAGES)/semantic.tsv $(BIN)/accuracy $(ACCURACY)/words.tsv
	@for scheme in fullpinyin flypy; do \
	    $(BIN)/accuracy $(IMAGES) $(ACCURACY) $$scheme >build/accuracy.$$scheme.txt; status=$$?; \
	    grep -v '^miss' build/accuracy.$$scheme.txt; \
	    test $$status -eq 0 || exit $$status; \
	done

test-app: images
	$(MAKE) -C macos test

bench: images $(BIN)/images-bench
	$(BIN)/images-bench $(IMAGES)

bench-typing-memory: images $(BIN)/typing-memory
	$(BIN)/typing-memory $(IMAGES)

eval: images $(BIN)/eval
	$(BIN)/eval $(IMAGES) $(SCHEME)

accuracy: images $(BIN)/accuracy $(ACCURACY)/words.tsv
	$(BIN)/accuracy $(IMAGES) $(ACCURACY) $(SCHEME) $(if $(DIAGNOSE),--diagnose)

fuzz: images $(BIN)/octo-compile
	$(MAKE) -C engine/fuzz test

# Moves the lock to another release, prepares it, and prints what changed:
# the report's numbers, and entries added and removed. Review before committing.
relock: prep
	@test -n "$(TAG)" || { echo "usage: make relock TAG=<release tag>"; exit 1; }
	@mkdir -p build/relock
	@cp $(PREPARED)/report.json build/relock/report.before.json
	@LC_ALL=C sort $(PREPARED)/lexicon.tsv >build/relock/lexicon.before.tsv
	tools/fetch-wanxiang.sh --relock $(TAG)
	@$(MAKE) --no-print-directory prep
	@echo "changes:"
	@$(OCTO_PREP) compare build/relock/report.before.json $(PREPARED)/report.json
	@LC_ALL=C sort $(PREPARED)/lexicon.tsv >build/relock/lexicon.after.tsv
	@echo "  lexicon lines added: $$(LC_ALL=C comm -13 build/relock/lexicon.before.tsv build/relock/lexicon.after.tsv | wc -l | tr -d ' '), removed: $$(LC_ALL=C comm -23 build/relock/lexicon.before.tsv build/relock/lexicon.after.tsv | wc -l | tr -d ' ') (build/relock/ has both)"

clean:
	rm -rf build tools/octo-prep/.build
	$(MAKE) -C engine/fuzz clean
	$(MAKE) -C macos clean
