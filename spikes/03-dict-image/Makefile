# Spike 03: a 1M-entry lexicon image: build, verified load, lookups, rollback.
#
#   make        build the benchmark
#   make test   run it (writes build/lexicon.img, about 30 MB)
include ../common.mk

GEN := build/gen

.PHONY: all test clean
all: build/bench

$(GEN)/bench.c: bench.goose lexicon.goose | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --standalone -o $@ bench.goose

build/bench: $(GEN)/bench.c metrics.c
	$(CC) $(GOOSE_CFLAGS) $(GEN)/bench.c metrics.c $(LDLIBS) -o $@

test: all
	./build/bench

clean:
	rm -rf build
