# M0: spikes that settle the Goose risks

Four throwaway prototypes, each answering a question that could sink the
architecture (a Goose engine behind a C ABI, inside a sandboxed IMK input
method) before M1 builds on it. All four pass.

```sh
make -C spikes test     # bootstraps the pinned compiler, builds, runs everything (~1 min)
```

| Spike | Question | Answer |
|---|---|---|
| [01-ime-host](01-ime-host) | Can a sandboxed IMK input method call a Goose engine from Swift 6? | Yes. Swift imports the generated header as is. `@MainActor` enforces Goose's thread rule. The sandbox works with one temporary-exception entitlement. Typing in real apps works (checked by hand). |
| [02-contained-worker](02-contained-worker) | Can background jobs fail without taking the IME down? | Yes. A supervisor worker reports a contained worker's abort; the host is woken from the worker thread; `goose_exit`/`goose_init` restarts cleanly. |
| [03-dict-image](03-dict-image) | Is a verified, swappable lexicon image fast and safe? | Yes. 1M entries load in about 10 ms with full verification; bad images are refused with the live lexicon intact. Memory equals image size. |
| [04-fuzz](04-fuzz) | Can the engine's entry points be fuzzed? | Yes, standalone and on libFuzzer, with ASan, UBSan and coverage guidance, once Goose's exits are routed to `abort`. No crashes found. |

## Results

One run of `make test`: Apple M4, 24 GB, macOS 27.2, Xcode 27.0, Swift 6.4,
Goose v2026.4. The libFuzzer row is from a later run, after LLVM (Homebrew
clang 23) was installed. Expect some variance between runs.

| Measurement | Result |
|---|---|
| Key → Goose engine → snapshot decoded in Swift (180k keys) | p50 375 ns, p99 1.1 µs, max 37 µs |
| Background job round trip: request → supervisor → contained worker → wake → pump | p50 62 µs, p99 120 µs |
| 1M-entry lexicon: image size, build (generate, sort, serialize, write) | 28.4 MiB, 185 ms |
| Verified load: read + header/checksum + `from_bytes` + offset validation + install | 3.6 + 3.0 + 1.8 + 0.5 + 2.8 ms ≈ 12 ms |
| Resident memory of the loaded lexicon | +28.5 MiB for 28.4 MiB of data |
| Load peak above the file buffer: scratch-then-copy / direct into the globals | +56.9 MiB / +43.6 MiB |
| Exact-code lookup over 1M entries (bounds-checked binary search) | p50 542 ns, p99 1.1 µs |
| Prefix-range lookup (1–3 letters) | p50 125 ns, p99 667 ns |
| Fuzzing, standalone loop, 20 s per target | lexicon: 3.1M runs, 104k images loaded; keys: 2.8M sequences; no crash |
| Fuzzing, libFuzzer, 20 s per target | lexicon: 4.3M runs, 637 new corpus units; keys: 0.6M runs, 1,041 new units; no crash |

## Findings

**What held up**

1. **Embedding needs no shim.** `goose --standalone --header` writes plain
   C99 (packed `_g` structs, `aligned(1)` typedefs, slices as `sl_u8`), and
   Swift 6.4 imports it directly through a bridging header.
2. **Swift enforces Goose's thread rule.** Exported calls must stay on the
   thread that ran `goose_init`. IMK's `IMKInputController` is not
   main-actor annotated, so the controller calls a `@MainActor` `Engine`
   through `MainActor.assumeIsolated`. That compiles under strict
   concurrency and traps if a call ever arrives on another thread.
3. **The sandbox needs exactly one exception.** With
   `com.apple.security.temporary-exception.mach-register.global-name`,
   IMKServer's Mach name registers. Signed with the sandbox entitlement
   alone (the automated negative control), it does not.
4. **Contained aborts carry no user data.** A worker's abort message is
   the check and its source line (`index 7 out of bounds (length 3)
   (jobs.goose:40)`), so it is safe to log.
5. **Loading is safe in depth.** The checksum, `from_bytes` and our own
   offset validation are each needed. The hostile-offset test passes the
   first two, and only validation stops it. Validation must also widen
   before adding, or a u32 offset near 2^32 wraps past the check.

**Surprises, and what M1 does about them**

1. **Goose claims host stack overflows.** After `goose_init`, a stack
   overflow in *Swift* code on the main thread lands in Goose's SIGSEGV
   handler, which reports a "native call stack overflow" and `_exit(1)`s
   with no crash report. Other host faults are passed on normally, and
   macOS reports them. M1: keep deep recursion off the main thread and log
   abnormal exits. Worth raising upstream.
2. **IMKServer hides registration failures.** It returns an object even
   when the Mach name fails to register, and only logs "could not
   register". `sandbox-test.sh` therefore looks the name up from an
   unsandboxed process, and M1's launch checks must do the same.
3. **Workers can't report their own death.** A contained worker that
   aborts sends nothing, so each job needs a supervisor that blocks in
   `thread_wait`. `goose_exit` is a runtime error while any worker runs,
   so hosts call `octo_quiesce()` first.
4. **Direct reload is only partly in place.** `g, ok = from_bytes(...)`
   into an existing global works, but its peak is still about 1.5× the
   lexicon, and a refused image empties the lexicon. Scratch-then-copy
   costs about 13 MiB more peak and keeps the old lexicon on failure.
   Either way, memory equals image size, so very large lexicons need
   sharding or memory-mapped reads (blueprint risk 8).
5. **`clock_ns()` counts whole microseconds on macOS.** The runtime uses
   `CLOCK_MONOTONIC`. The benchmark times lookups through a C helper on
   `CLOCK_UPTIME_RAW` instead. Worth raising upstream.
6. **Imports are program-wide.** `lexicon.goose` called `clock_ns` without
   importing `os` and compiled anyway, because its first importer imported
   `os`. The fuzz build, a second root, caught it. M1: compile every
   module from at least two roots (its tests and the engine).
7. **Fuzzers need Goose's exits rerouted.** Goose ends the process through
   `_Exit`/`_exit`, which skip the hooks fuzzers rely on, so a crash would
   go unrecorded. Fuzz builds compile the generated C with
   `-D_Exit=octo_fuzz_exit -D_exit=octo_fuzz_exit`, which saves the input
   and aborts. Apple's clang ships no libFuzzer runtime, so `driver.c`
   carries a small coverage-guided loop on SanitizerCoverage. With an LLVM
   clang the same driver also builds against libFuzzer, and `make test`
   runs both, each with a canary that proves a Goose abort is caught. The
   image checksum has to be re-stamped after mutation (a custom mutator
   under libFuzzer), or few mutations get past it.
8. **Toolchain notes.** A bare `xcrun --show-sdk-path` picked a newer
   Command Line Tools SDK (27.2) than the selected Xcode's compilers (27.0),
   so the Makefiles ask for `xcrun --sdk macosx`. Generated C is clean under
   `-Wall` apart from unused-symbol warnings. The pinned compiler builds
   from source in about 45 s.

## Not covered by M0

- **Typing in real apps is checked by hand only.** Install and enable the
  input method with `make -C spikes/01-ime-host install enable`, select
  OctoDot, and type `nihao` + space; it types text. Nothing tests this
  automatically yet. `make -C spikes/01-ime-host uninstall` removes it.
- Developer ID signing, notarization, App Groups (they need a team-signed
  build), Intel builds, and the encrypted user dictionary are M1 work.

## Side effects of `make test`

- The deliberate `host-segv` crash writes an `octo-smoke-*.ips` report to
  `~/Library/Logs/DiagnosticReports`.
- The sandboxed self-test creates the app's container,
  `~/Library/Containers/com.example.inputmethod.OctoDot`.
- While the self-test runs, it holds the Mach name
  `com.example.inputmethod.OctoDot_Connection` for a few seconds.

Nothing is installed as an input method unless you run `make install`.
