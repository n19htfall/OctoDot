# Fuzzing with ASan, UBSan, Goose's --debug checks and coverage guidance,
# and on libFuzzer too when an LLVM clang is installed: the image loaders,
# the typing path (keystrokes into a session over the real images) and the
# user dictionary's parser.
# The root Makefile's `make fuzz` builds the prerequisites first.
#
#   make -C engine/fuzz test [FUZZ_SECONDS=20]
include ../../mk/toolchain.mk

GEN          := build/gen
SEEDS        := build/seeds
FUZZ_SECONDS ?= 20
# Undefined behavior ends the run, as a crash does: a report UBSan only
# printed went by unnoticed (NaN to int in rerank.h, 2026-11-09).
SANITIZE     := -fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g
# Goose ends the process through _Exit/_exit, which no fuzzer notices; those
# calls go to octo_fuzz_exit in driver.c instead.
EXIT_HOOK    := -D_Exit=octo_fuzz_exit -D_exit=octo_fuzz_exit
GEN_WARN     := -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
FUZZ_CFLAGS  := -O1 -target $(TARGET) -isysroot $(SDK) $(SANITIZE)
ENGINE       := $(wildcard ../*.goose) ../gram.h ../rerank.h ../octo.build
OCTO_COMPILE := ../../build/bin/octo-compile
PREPARED     := ../../build/data/wanxiang
IMAGES       := $(abspath ../../build/images)
LLVM         ?= /opt/homebrew/opt/llvm
LF_CC        := $(LLVM)/bin/clang
LF_CFLAGS    := -O1 -g -target $(TARGET) -isysroot $(SDK) -fno-omit-frame-pointer

.PHONY: all test libfuzzer libfuzzer-test clean
TARGETS      := lexicon spellings aux english keys userdb phrases gram rerank rerank-weights
all: $(addprefix build/fuzz-,$(TARGETS))

# The generated C and its header come out of one goose run.
$(GEN)/fuzz_images.h: fuzz_images.goose $(ENGINE) | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --debug --standalone --header $@ -o $(GEN)/fuzz_images.c fuzz_images.goose

build/targets.o: $(GEN)/fuzz_images.h
	$(CC) $(FUZZ_CFLAGS) -fsanitize-coverage=trace-pc-guard $(EXIT_HOOK) $(GEN_WARN) -c $(GEN)/fuzz_images.c -o $@

# The engine's own C compiled apart (blas.c, the reranker's call into
# Accelerate) goes with every target.
build/blas.o: ../blas.c
	@mkdir -p build
	$(CC) $(FUZZ_CFLAGS) -c $< -o $@

build/fuzz-%: driver.c build/targets.o build/blas.o
	$(CC) $(FUZZ_CFLAGS) -Wall -DTARGET_$(shell echo $* | tr a-z- A-Z_) -I $(GEN) driver.c build/targets.o build/blas.o \
	    $(LDLIBS) -framework Accelerate -o $@

# Small valid images from the real data: the first 1, 40 and 300 entries,
# spellings and characters with auxiliary codes.
$(SEEDS)/.done: $(OCTO_COMPILE) $(PREPARED)/report.json $(wildcard seeds/*/*)
	@mkdir -p $(addprefix $(SEEDS)/,$(TARGETS))
	@cp seeds/keys/* $(SEEDS)/keys/ && cp seeds/userdb/* $(SEEDS)/userdb/ && cp seeds/phrases/* $(SEEDS)/phrases/
	@for n in 1 40 300; do \
	  mkdir -p build/seed-images/$$n && $(OCTO_COMPILE) $(PREPARED) build/seed-images/$$n --limit $$n >/dev/null || exit 1; \
	  cp build/seed-images/$$n/lexicon.img $(SEEDS)/lexicon/$$n.img; \
	  cp build/seed-images/$$n/spellings.fullpinyin.img $(SEEDS)/spellings/$$n.img; \
	  cp build/seed-images/$$n/aux.wanxiang.img $(SEEDS)/aux/$$n.img; \
	  cp build/seed-images/$$n/english.img $(SEEDS)/english/$$n.img; \
	done
	@if [ -f $(IMAGES)/rerank.img ]; then cp $(IMAGES)/rerank.img $(SEEDS)/rerank/real.img; fi
# A reranker seed for the weights target's tiny shape: the header and 1,000
# floats, a few of them not zero.
	@python3 -c 'import struct,sys; sys.stdout.buffer.write(b"OLM1" + struct.pack("<5i", 8, 1, 2, 8, 6) + \
	    struct.pack("<1000f", *[((i * 37) % 17 - 8) / 16.0 for i in range(1000)]))' > $(SEEDS)/rerank-weights/tiny.weights
	@touch $@
# Grammar seeds: an empty model, and the real model's header over its first
# 4,096 and 16,384 units (each unit past the end then reads as missing).
	@printf 'Rime::Grammar/1.0' > $(SEEDS)/gram/empty.gram && dd if=/dev/zero bs=1 count=19 2>/dev/null >> $(SEEDS)/gram/empty.gram && \
	  printf '\000\001\000\000\004\000\000\000' >> $(SEEDS)/gram/empty.gram && dd if=/dev/zero bs=1024 count=1 2>/dev/null >> $(SEEDS)/gram/empty.gram
	@for n in 4096 16384; do \
	  head -c 36 $(IMAGES)/wanxiang-lts-zh-hans.gram > $(SEEDS)/gram/real-$$n.gram && \
	  printf "$$(printf '\\%03o\\%03o\\%03o\\%03o' $$(($$n & 255)) $$((($$n >> 8) & 255)) 0 0)" >> $(SEEDS)/gram/real-$$n.gram && \
	  printf '\004\000\000\000' >> $(SEEDS)/gram/real-$$n.gram && \
	  tail -c +45 $(IMAGES)/wanxiang-lts-zh-hans.gram | head -c $$(($$n * 4)) >> $(SEEDS)/gram/real-$$n.gram; \
	done

test: all $(SEEDS)/.done
	@cd build && rm -f crash-*.bin && \
	  if ./fuzz-lexicon -canary 2>canary.log; then echo "FAIL  canary did not crash"; exit 1; fi && \
	  grep -q 'out of bounds' canary.log && ls crash-lexicon-*.bin >/dev/null && rm -f crash-lexicon-*.bin && \
	  echo "ok    canary: a Goose abort is caught as a crash, its input saved"
	cd build && ./fuzz-lexicon -seconds=$(FUZZ_SECONDS) seeds/lexicon
	cd build && ./fuzz-spellings -seconds=$(FUZZ_SECONDS) seeds/spellings
	cd build && ./fuzz-aux -seconds=$(FUZZ_SECONDS) seeds/aux
	cd build && ./fuzz-english -seconds=$(FUZZ_SECONDS) seeds/english
	cd build && OCTO_FUZZ_IMAGES=$(IMAGES) ./fuzz-keys -seconds=$(FUZZ_SECONDS) seeds/keys
	cd build && OCTO_FUZZ_IMAGES=$(IMAGES) ./fuzz-userdb -seconds=$(FUZZ_SECONDS) seeds/userdb
	cd build && OCTO_FUZZ_IMAGES=$(IMAGES) ./fuzz-phrases -seconds=$(FUZZ_SECONDS) seeds/phrases
	cd build && ./fuzz-gram -seconds=$(FUZZ_SECONDS) seeds/gram
	cd build && ./fuzz-rerank -seconds=$(FUZZ_SECONDS) seeds/rerank
	cd build && ./fuzz-rerank-weights -seconds=$(FUZZ_SECONDS) seeds/rerank-weights
	@if [ -x $(LF_CC) ]; then $(MAKE) -s libfuzzer-test; else echo "skip  libFuzzer: no clang at $(LF_CC)"; fi

libfuzzer: $(addprefix build/libfuzzer-,$(TARGETS))

build/targets-libfuzzer.o: $(GEN)/fuzz_images.h
	@test -x $(LF_CC) || { echo "no clang at $(LF_CC): set LLVM= to an LLVM install with libFuzzer"; exit 1; }
	$(LF_CC) $(LF_CFLAGS) -fsanitize=fuzzer-no-link,address,undefined $(EXIT_HOOK) $(GEN_WARN) -c $(GEN)/fuzz_images.c -o $@

build/libfuzzer-%: driver.c build/targets-libfuzzer.o ../blas.c
	$(LF_CC) $(LF_CFLAGS) -fsanitize=fuzzer,address,undefined -Wall -DUSE_LIBFUZZER \
	    -DTARGET_$(shell echo $* | tr a-z- A-Z_) -I $(GEN) driver.c build/targets-libfuzzer.o ../blas.c \
	    -framework Accelerate -o $@

# The canary through libFuzzer, then FUZZ_SECONDS per target; the corpora
# grow in build/libfuzzer-corpus/ across runs.
libfuzzer-test: libfuzzer $(SEEDS)/.done
	@cd build && rm -rf lf-canary lf-artifacts && mkdir -p lf-canary lf-artifacts && \
	  printf canary > lf-canary/canary && \
	  if OCTO_FUZZ_CANARY=1 ./libfuzzer-lexicon -artifact_prefix=lf-artifacts/ -runs=0 lf-canary 2>lf-canary.log; \
	  then echo "FAIL  libFuzzer canary did not crash"; exit 1; fi && \
	  grep -q 'deadly signal' lf-canary.log && ls lf-artifacts/crash-* >/dev/null && \
	  rm -rf lf-artifacts crash-lexicon-*.bin && \
	  echo "ok    canary: libFuzzer catches a Goose abort and writes the crashing input"
	@cd build && for t in $(TARGETS); do \
	    mkdir -p libfuzzer-corpus/$$t && cp seeds/$$t/* libfuzzer-corpus/$$t/ && \
	    echo "libFuzzer $$t, $(FUZZ_SECONDS) s:" && \
	    { OCTO_FUZZ_IMAGES=$(IMAGES) ./libfuzzer-$$t -max_total_time=$(FUZZ_SECONDS) -print_final_stats=1 libfuzzer-corpus/$$t \
	        >libfuzzer-$$t.log 2>&1 || { tail -30 libfuzzer-$$t.log; exit 1; }; } && \
	    grep -E 'DONE|stat::(number_of_executed_units|new_units_added)' libfuzzer-$$t.log; \
	  done

clean:
	rm -rf build
