# Spike 04: fuzzing the engine's entry points (spikes 01 and 03) with ASan,
# UBSan, Goose's --debug checks and coverage guidance.
#
#   make            build build/fuzz-lexicon and build/fuzz-keys
#   make test       a canary run (a Goose abort must be caught as a crash and
#                   its input saved), then FUZZ_SECONDS of fuzzing per target;
#                   the same again on libFuzzer when an LLVM clang is found
#   make libfuzzer-test [LLVM=/opt/homebrew/opt/llvm]
#                   the libFuzzer half alone (Apple's clang lacks libFuzzer)
include ../common.mk

GEN          := build/gen
FUZZ_SECONDS ?= 20
SANITIZE     := -fsanitize=address,undefined -fno-omit-frame-pointer -g
# Goose ends the process through _Exit/_exit, which no fuzzer notices; send
# those calls to octo_fuzz_exit in driver.c instead.
EXIT_HOOK    := -D_Exit=octo_fuzz_exit -D_exit=octo_fuzz_exit
GEN_WARN     := -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
FUZZ_CFLAGS  := -O1 -target $(TARGET) -isysroot $(SDK) $(SANITIZE)
SOURCES      := fuzz_targets.goose ../01-ime-host/engine/engine.goose \
                ../01-ime-host/engine/toy_table.tsv ../03-dict-image/lexicon.goose

.PHONY: all test libfuzzer libfuzzer-test clean
all: build/fuzz-lexicon build/fuzz-keys

$(GEN)/fuzz_targets.c $(GEN)/fuzz_targets.h &: $(SOURCES) | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --debug --standalone --header $(GEN)/fuzz_targets.h \
	    -o $(GEN)/fuzz_targets.c fuzz_targets.goose

build/targets.o: $(GEN)/fuzz_targets.c
	$(CC) $(FUZZ_CFLAGS) -fsanitize-coverage=trace-pc-guard $(EXIT_HOOK) $(GEN_WARN) -c $< -o $@

build/fuzz-lexicon: driver.c build/targets.o $(GEN)/fuzz_targets.h
	$(CC) $(FUZZ_CFLAGS) -Wall -DTARGET_LEXICON -I $(GEN) driver.c build/targets.o $(LDLIBS) -o $@

build/fuzz-keys: driver.c build/targets.o $(GEN)/fuzz_targets.h
	$(CC) $(FUZZ_CFLAGS) -Wall -DTARGET_KEYS -I $(GEN) driver.c build/targets.o $(LDLIBS) -o $@

# Valid images of a few sizes, written by spike 03's generator.
build/seeds/lexicon/.done: ../03-dict-image/lexicon.goose ../03-dict-image/bench.goose
	$(MAKE) -C ../03-dict-image all
	@mkdir -p $(@D)
	for n in 1 3 40 300; do ../03-dict-image/build/bench --seed $(@D)/entries-$$n.img $$n; done
	@touch $@

test: all build/seeds/lexicon/.done
	@cd build && rm -f crash-*.bin && \
	  if ./fuzz-keys -canary 2>canary.log; then echo "FAIL  canary did not crash"; exit 1; fi && \
	  grep -q 'index 1000 out of bounds' canary.log && ls crash-keys-*.bin >/dev/null && \
	  rm -f crash-keys-*.bin && echo "ok    canary: a Goose abort is caught as a crash, its input saved"
	cd build && ./fuzz-lexicon -seconds=$(FUZZ_SECONDS) seeds/lexicon
	cd build && ./fuzz-keys -seconds=$(FUZZ_SECONDS)
	@if [ -x $(LF_CC) ]; then $(MAKE) -s libfuzzer-test; else echo "skip  libFuzzer: no clang at $(LF_CC)"; fi

# libFuzzer needs an LLVM clang: Apple's ships no libFuzzer runtime.
LLVM      ?= /opt/homebrew/opt/llvm
LF_CC     := $(LLVM)/bin/clang
LF_CFLAGS := -O1 -g -target $(TARGET) -isysroot $(SDK) -fno-omit-frame-pointer

libfuzzer: build/libfuzzer-lexicon build/libfuzzer-keys

build/targets-libfuzzer.o: $(GEN)/fuzz_targets.c
	@test -x $(LF_CC) || { echo "no clang at $(LF_CC): set LLVM= to an LLVM install with libFuzzer"; exit 1; }
	$(LF_CC) $(LF_CFLAGS) -fsanitize=fuzzer-no-link,address,undefined $(EXIT_HOOK) $(GEN_WARN) -c $< -o $@

build/libfuzzer-%: driver.c build/targets-libfuzzer.o $(GEN)/fuzz_targets.h
	$(LF_CC) $(LF_CFLAGS) -fsanitize=fuzzer,address,undefined -Wall -DUSE_LIBFUZZER \
	    -DTARGET_$(shell echo $* | tr a-z A-Z) -I $(GEN) driver.c build/targets-libfuzzer.o -o $@

# The canary through libFuzzer, then FUZZ_SECONDS per target. The corpora
# grow in build/libfuzzer-corpus/ across runs.
libfuzzer-test: libfuzzer build/seeds/lexicon/.done
	@cd build && rm -rf lf-canary lf-artifacts && mkdir -p lf-canary lf-artifacts && \
	  printf canary > lf-canary/canary && \
	  if OCTO_FUZZ_CANARY=1 ./libfuzzer-keys -artifact_prefix=lf-artifacts/ -runs=0 lf-canary 2>lf-canary.log; \
	  then echo "FAIL  libFuzzer canary did not crash"; exit 1; fi && \
	  grep -q 'deadly signal' lf-canary.log && ls lf-artifacts/crash-* >/dev/null && \
	  rm -rf lf-artifacts crash-keys-*.bin && \
	  echo "ok    canary: libFuzzer catches a Goose abort and writes the crashing input"
	@cd build && mkdir -p libfuzzer-corpus/lexicon libfuzzer-corpus/keys && \
	  cp seeds/lexicon/*.img libfuzzer-corpus/lexicon/ && \
	  for t in lexicon keys; do \
	    echo "libFuzzer $$t, $(FUZZ_SECONDS) s:"; \
	    ./libfuzzer-$$t -max_total_time=$(FUZZ_SECONDS) -print_final_stats=1 libfuzzer-corpus/$$t \
	      >libfuzzer-$$t.log 2>&1 || { tail -30 libfuzzer-$$t.log; exit 1; }; \
	    grep -E 'DONE|stat::(number_of_executed_units|average_exec_per_sec|new_units_added)' libfuzzer-$$t.log; \
	  done

clean:
	rm -rf build
