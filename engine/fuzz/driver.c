/* Fuzz driver for fuzz_images.goose (adapted from the M0 spike's driver).
 *
 * Two builds:
 *   - standalone (Apple clang ships no libFuzzer runtime): main() below runs
 *     a small coverage-guided loop on SanitizerCoverage's trace-pc-guard
 *     callbacks, with ASan and UBSan on;
 *   - libFuzzer (LLVM clang, -DUSE_LIBFUZZER -fsanitize=fuzzer), which calls
 *     LLVMFuzzerInitialize and LLVMFuzzerTestOneInput.
 *
 * Goose ends the process through _Exit on a failed check, and through _exit
 * from its stack-overflow signal handler. Neither runs atexit handlers, so a
 * fuzzer would not notice and the input would be lost. Fuzz builds compile
 * the generated C with -D_Exit=octo_fuzz_exit -D_exit=octo_fuzz_exit: the
 * input is saved, then abort() turns it into a crash any fuzzer recognizes.
 *
 * Canary: with OCTO_FUZZ_CANARY set, the 6-byte input "canary" triggers a
 * known Goose abort, so `make test` can prove that crashes are caught in
 * either build.
 */
#include "fuzz_images.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if __has_include(<sanitizer/common_interface_defs.h>)
#include <sanitizer/common_interface_defs.h>
#define HAVE_DEATH_CALLBACK 1
#endif

#if defined(TARGET_LEXICON)
#define TARGET octo_fuzz_lexicon
#define TARGET_NAME "lexicon"
#elif defined(TARGET_SPELLINGS)
#define TARGET octo_fuzz_spellings
#define TARGET_NAME "spellings"
#elif defined(TARGET_AUX)
#define TARGET octo_fuzz_aux
#define TARGET_NAME "aux"
#elif defined(TARGET_ENGLISH)
#define TARGET octo_fuzz_english
#define TARGET_NAME "english"
#elif defined(TARGET_KEYS)
#define TARGET octo_fuzz_keys
#define TARGET_NAME "keys"
#define NOT_AN_IMAGE 1
#elif defined(TARGET_USERDB)
#define TARGET octo_fuzz_userdb
#define TARGET_NAME "userdb"
#define NOT_AN_IMAGE 1
#elif defined(TARGET_PHRASES)
#define TARGET octo_fuzz_phrases
#define TARGET_NAME "phrases"
#define NOT_AN_IMAGE 1
#elif defined(TARGET_GRAM)
#define TARGET octo_fuzz_gram
#define TARGET_NAME "gram"
#define NOT_AN_IMAGE 1
#elif defined(TARGET_RERANK)
#define TARGET octo_fuzz_rerank
#define TARGET_NAME "rerank"
#elif defined(TARGET_RERANK_WEIGHTS)
#define TARGET octo_fuzz_rerank_weights
#define TARGET_NAME "rerank-weights"
#define NOT_AN_IMAGE 1
#else
#error "define TARGET_LEXICON, TARGET_SPELLINGS, TARGET_AUX, TARGET_ENGLISH, TARGET_KEYS, TARGET_USERDB, TARGET_PHRASES, TARGET_GRAM, TARGET_RERANK or TARGET_RERANK_WEIGHTS"
#endif

static const uint8_t *g_input;  /* the input being run, saved on a crash */
static size_t g_input_len;
static char g_crash_path[64];
static int g_canary;            /* OCTO_FUZZ_CANARY is set */

/* Async-signal-safe: also reached from Goose's stack-overflow handler. */
static void save_input(void) {
    int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t written = g_input_len ? write(fd, g_input, g_input_len) : 0;
    close(fd);
    static const char msg[] = "octo-fuzz: crashing input saved\n";
    written = write(2, msg, sizeof msg - 1);
    (void)written;
}

__attribute__((noreturn)) void octo_fuzz_exit(int code) {
    (void)code;
    save_input();
    abort();
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    snprintf(g_crash_path, sizeof g_crash_path, "crash-%s-%d.bin", TARGET_NAME, (int)getpid());
#ifdef HAVE_DEATH_CALLBACK
    __sanitizer_set_death_callback(save_input);  /* ASan and UBSan reports */
#endif
    g_canary = getenv("OCTO_FUZZ_CANARY") != NULL;
    goose_init(*argc, *argv);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    g_input = data;
    g_input_len = size;
    if (g_canary && size == 6 && !memcmp(data, "canary", 6)) octo_fuzz_canary();
    TARGET((sl_u8){(uint8_t *)data, (int64_t)size});
    return 0;
}

#if defined(USE_LIBFUZZER)
/* libFuzzer's own mutations, then, half the time, the image checksum
   re-stamped, as the standalone loop does: otherwise few mutations would
   get past the checksum to from_bytes and validation. Runs on libFuzzer's
   main thread, the one that called goose_init. */
size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size);

size_t LLVMFuzzerCustomMutator(uint8_t *data, size_t size, size_t max_size, unsigned int seed) {
    size = LLVMFuzzerMutate(data, size, max_size);
#ifndef NOT_AN_IMAGE
    if (seed & 1) octo_fuzz_restamp((sl_u8){data, (int64_t)size});
#endif
    return size;
}
#endif

#ifndef USE_LIBFUZZER

/* Coverage: SanitizerCoverage numbers every edge of the instrumented code
   (the generated C), and the callback marks the edges each run takes. */
static uint32_t g_edges;
static uint8_t *g_run_hits, *g_seen;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (start == stop || *start) return;
    for (uint32_t *guard = start; guard < stop; guard++) *guard = ++g_edges;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    if (g_run_hits) g_run_hits[*guard] = 1;
}

/* How many edges the last run reached for the first time. */
static size_t new_edges(void) {
    size_t fresh = 0;
    for (uint32_t i = 1; i <= g_edges; i++) {
        if (!g_run_hits[i]) continue;
        g_run_hits[i] = 0;
        if (!g_seen[i]) { g_seen[i] = 1; fresh++; }
    }
    return fresh;
}

static size_t seen_edges(void) {
    size_t n = 0;
    for (uint32_t i = 1; i <= g_edges; i++) n += g_seen[i];
    return n;
}

#define MAX_INPUT (1u << 20)
#define MAX_CORPUS 4096
typedef struct { uint8_t *data; size_t len; } Input;
static Input g_corpus[MAX_CORPUS];
static size_t g_ncorpus;

static void corpus_add(const uint8_t *data, size_t len) {
    if (g_ncorpus == MAX_CORPUS) return;
    uint8_t *copy = malloc(len ? len : 1);
    memcpy(copy, data, len);
    g_corpus[g_ncorpus++] = (Input){copy, len};
}

static uint64_t g_rng;
static uint64_t rnd(void) {  /* splitmix64 */
    uint64_t z = (g_rng += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static const uint32_t interesting[] = {0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0xFFFF,
                                       0x7FFFFFFF, 0x80000000u, 0xFFFFFFF0u, 0xFFFFFFFFu};

static size_t mutate(uint8_t *buf, size_t len) {
    int rounds = 1 + (int)(rnd() % 4);
    for (int r = 0; r < rounds; r++) {
        size_t at = len ? rnd() % len : 0;
        switch (rnd() % 9) {
        case 0: if (len) buf[at] ^= (uint8_t)(1u << (rnd() % 8)); break;            /* flip a bit */
        case 1: if (len) buf[at] = (uint8_t)rnd(); break;                           /* random byte */
        case 2:                                                                     /* insert a byte */
            if (len < MAX_INPUT) { memmove(buf + at + 1, buf + at, len - at); buf[at] = (uint8_t)rnd(); len++; }
            break;
        case 3:                                                                     /* delete a run */
            if (len) { size_t n = 1 + rnd() % (len - at); memmove(buf + at, buf + at + n, len - at - n); len -= n; }
            break;
        case 4:                                                                     /* an interesting u32 */
            if (len >= 4) {
                at = (len >= 64 && rnd() % 2) ? (rnd() % 16) * 4 : rnd() % (len - 3);  /* often a header field */
                uint32_t v = interesting[rnd() % (sizeof interesting / sizeof interesting[0])];
                if (rnd() % 4 == 0) v = (uint32_t)(len - rnd() % 80);
                memcpy(buf + at, &v, 4);
            }
            break;
        case 5: if (len) len = rnd() % len; break;                                  /* truncate */
        case 6:                                                                     /* duplicate a run */
            if (len) {
                size_t n = 1 + rnd() % (len - at);
                if (len + n <= MAX_INPUT) { memmove(buf + at + n, buf + at, len - at); len += n; }
            }
            break;
        case 7:                                                                     /* splice another input */
            if (g_ncorpus) {
                const Input *other = &g_corpus[rnd() % g_ncorpus];
                if (other->len) {
                    size_t from = rnd() % other->len, n = 1 + rnd() % (other->len - from);
                    if (at + n <= MAX_INPUT) { memcpy(buf + at, other->data + from, n); if (at + n > len) len = at + n; }
                }
            }
            break;
        case 8:                                                                     /* nudge a u32 */
            if (len >= 4) {
                uint32_t v;
                at = rnd() % (len - 3);
                memcpy(&v, buf + at, 4);
                v += (uint32_t)(rnd() % 33) - 16;
                memcpy(buf + at, &v, 4);
            }
            break;
        }
    }
    return len;
}

static int g_accepted;  /* runs the target reported as accepted (a lexicon that loaded) */

static void run(const uint8_t *data, size_t len) {
    g_input = data;
    g_input_len = len;
    g_accepted += TARGET((sl_u8){(uint8_t *)data, (int64_t)len}) != 0;
}

static void run_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    static uint8_t buf[MAX_INPUT];
    size_t len = fread(buf, 1, MAX_INPUT, f);
    fclose(f);
    run(buf, len);
    new_edges();
    corpus_add(buf, len);  /* every seed joins the corpus */
}

static void run_path(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) { fprintf(stderr, "no such input: %s\n", path); return; }
    if (!S_ISDIR(st.st_mode)) { run_file(path); return; }
    DIR *dir = opendir(path);
    for (struct dirent *e; dir && (e = readdir(dir));) {
        if (e->d_name[0] == '.') continue;
        char child[1024];
        snprintf(child, sizeof child, "%s/%s", path, e->d_name);
        run_file(child);
    }
    if (dir) closedir(dir);
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* octo-fuzz [-seconds=N] [-seed=N] [-replay] [-canary] [inputs or dirs...] */
int main(int argc, char **argv) {
    double seconds = 10;
    int replay = 0, canary = 0;
    g_rng = (uint64_t)time(NULL);
    g_run_hits = calloc(g_edges + 1, 1);
    g_seen = calloc(g_edges + 1, 1);
    LLVMFuzzerInitialize(&argc, &argv);

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "-seconds=", 9)) seconds = atof(argv[i] + 9);
        else if (!strncmp(argv[i], "-seed=", 6)) g_rng = strtoull(argv[i] + 6, NULL, 10);
        else if (!strcmp(argv[i], "-replay")) replay = 1;
        else if (!strcmp(argv[i], "-canary")) canary = 1;
        else run_path(argv[i]);
    }
    if (canary) {  /* a known Goose abort: must be caught, with its input saved */
        g_canary = 1;
        LLVMFuzzerTestOneInput((const uint8_t *)"canary", 6);
        fprintf(stderr, "canary did not crash\n");
        return 3;
    }
    if (g_ncorpus == 0) {  /* built-in seeds */
        static const char *seeds[] = {"", "nihao ", "zhongwen1", "wenx\x24\x25"};
        for (size_t i = 0; i < sizeof seeds / sizeof seeds[0]; i++) {
            run((const uint8_t *)seeds[i], strlen(seeds[i]));
            new_edges();
            corpus_add((const uint8_t *)seeds[i], strlen(seeds[i]));
        }
    }
    if (replay) {
        printf("%s: replayed %zu inputs, no crash\n", TARGET_NAME, g_ncorpus);
        return 0;
    }

    static uint8_t buf[MAX_INPUT];
    uint64_t start = now_ns(), deadline = start + (uint64_t)(seconds * 1e9);
    unsigned long long execs = 0;
    /* The deadline after every input: a slow target (keystrokes through the
       whole engine) can take seconds per input under the sanitizers. */
    while (now_ns() < deadline) {
        for (int i = 0; i < 1 && now_ns() < deadline; i++) {
            const Input *base = &g_corpus[rnd() % g_ncorpus];
            memcpy(buf, base->data, base->len);
            size_t len = mutate(buf, base->len);
#ifndef NOT_AN_IMAGE
            if (rnd() % 2) octo_fuzz_restamp((sl_u8){buf, (int64_t)len});
#endif
            run(buf, len);
            execs++;
            if (new_edges()) corpus_add(buf, len);
        }
    }
    double elapsed = (double)(now_ns() - start) / 1e9;
    printf("%s: %llu runs in %.0f s (%.0f/s), corpus %zu, edges %zu of %u, %d accepted, no crash\n",
           TARGET_NAME, execs, elapsed, (double)execs / elapsed, g_ncorpus, seen_edges(), g_edges,
           g_accepted);
    return 0;
}

#endif /* USE_LIBFUZZER */
