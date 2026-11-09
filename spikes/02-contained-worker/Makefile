# Spike 02: contained workers started from exported calls, a supervisor that
# reports aborts, a host wake-up from worker threads, and goose_exit/init.
#
#   make        build the C host test
#   make test   run it
include ../common.mk

GEN := build/gen

.PHONY: all test clean
all: build/host_test

$(GEN)/jobs.c $(GEN)/jobs.h &: jobs.goose | $(GOOSE)
	@mkdir -p $(GEN)
	$(GOOSE) $(GOOSEFLAGS) --standalone --header $(GEN)/jobs.h -o $(GEN)/jobs.c jobs.goose

build/host_test: host_test.c $(GEN)/jobs.c $(GEN)/jobs.h
	$(CC) $(GOOSE_CFLAGS) -c $(GEN)/jobs.c -o build/jobs.o
	$(CC) -O2 -target $(TARGET) -isysroot $(SDK) -Wall -I $(GEN) host_test.c build/jobs.o $(LDLIBS) -o $@

test: all
	./build/host_test

clean:
	rm -rf build
