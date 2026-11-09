# OctoDot M0 spikes. See README.md for what each one settles.
#
#   make          build everything (bootstraps the pinned Goose compiler first)
#   make test     run every spike's checks and measurements
#   make clean

SPIKES := 01-ime-host 02-contained-worker 03-dict-image 04-fuzz

.PHONY: all test clean toolchain
all: toolchain
	@for s in $(SPIKES); do $(MAKE) -C $$s all || exit 1; done

test: toolchain
	@for s in $(SPIKES); do echo "== $$s"; $(MAKE) -s -C $$s test || exit 1; done

toolchain:
	@test -x ../.toolchain/goose-src/build/goose || ../toolchain/bootstrap-goose.sh

clean:
	@for s in $(SPIKES); do $(MAKE) -C $$s clean; done
