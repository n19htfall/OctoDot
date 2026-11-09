// The grammar model's trie, read in place from a memory-mapped .gram file
// (librime-octagram's format; 万象's is 418 MB). Mapped read-only, its pages
// stay clean and file-backed: the system drops them under pressure and they
// are not part of the IME's memory footprint, as they would be if the file
// were read into the heap. Goose cannot hold a slice into mapped memory, so
// this walk is the one piece of the engine written in C; which file, its
// settings and the sentence search around it are Goose (grammar.goose).
//
// Nothing here trusts the file. Opening checks its header and that the
// array lies inside it; every unit is read through unit(), which checks the
// index against the array's size, so a damaged file gives wrong scores,
// never a read outside the mapping. Inputs from Goose are slices that may
// hold any bytes: malformed UTF-8 ends the text there.
//
// The format and the query are librime-octagram's (BSD-3-Clause, by the
// RIME developers), ported: gram_db.cc (the header and Lookup),
// gram_encoding.cc (the key encoding), octagram.cc (Query), over
// darts-clone's double array (BSD-2-Clause, Susumu Yata).
//
// Included into the engine's generated C (engine/octo.build), so it sees
// Goose's types (sl_u8, gs_i32, ...); the extern fns in grammar.goose bind
// to it, with exactly the prototypes Goose declares for them (a bool is a
// uint8_t).
#ifndef OCTO_GRAM_H
#define OCTO_GRAM_H

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { OCTO_GRAM_HEADER = 44, OCTO_GRAM_SPAN_MAX = 8, OCTO_GRAM_RESULTS = 8 };

static struct {
    void *map;                      // the whole file, or NULL
    size_t map_size;
    const uint32_t *units;          // the double array inside it
    uint32_t count;
    int span;                       // characters of context, and of the word, a query reads
    int min_length;
    double collocation, non_collocation, weak_collocation, rear;
} octo_gram;

// The settings of librime-octagram's GrammarConfig.
static inline void octo_gram_settings(gs_i32 max_length, gs_i32 min_length, gs_f64 collocation,
                                      gs_f64 non_collocation, gs_f64 weak_collocation, gs_f64 rear) {
    int span = max_length - 1;
    octo_gram.span = span < 1 ? 1 : span > OCTO_GRAM_SPAN_MAX ? OCTO_GRAM_SPAN_MAX : span;
    octo_gram.min_length = min_length;
    octo_gram.collocation = collocation;
    octo_gram.non_collocation = non_collocation;
    octo_gram.weak_collocation = weak_collocation;
    octo_gram.rear = rear;
}

static inline void octo_gram_close(void) {
    if (octo_gram.map) munmap(octo_gram.map, octo_gram.map_size);
    octo_gram.map = NULL;
    octo_gram.units = NULL;
    octo_gram.count = 0;
}

// Maps the .gram file at `path` and makes it the one queried, replacing any
// other: 0, or 1 if it cannot be opened or mapped, 2 if it is not a .gram
// file, 3 if its array lies outside it, 4 if its size is not `size`.
static inline gs_i32 octo_gram_open(sl_u8 path, gs_u64 size) {
    char name[1024];
    if (path.len <= 0 || path.len >= (int64_t)sizeof name) return 1;
    memcpy(name, path.data, (size_t)path.len);
    name[path.len] = 0;
    int fd = open(name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < OCTO_GRAM_HEADER) { close(fd); return 1; }
    size_t length = (size_t)st.st_size;
    void *map = mmap(NULL, length, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return 1;
    const uint8_t *bytes = map;
    int32_t code = 0;
    uint32_t count = 0;
    int32_t offset = 0;
    memcpy(&count, bytes + 36, 4);
    memcpy(&offset, bytes + 40, 4);
    int64_t start = 40 + (int64_t)offset;
    if (memcmp(bytes, "Rime::Grammar/", 14) != 0) code = 2;
    else if (count < 256 || start < OCTO_GRAM_HEADER || start % 4 != 0 ||
             start + (int64_t)count * 4 > (int64_t)length) code = 3;
    else if (size != 0 && (uint64_t)length != size) code = 4;
    if (code != 0) { munmap(map, length); return code; }
    madvise(map, length, MADV_RANDOM);       // queries jump around; read no pages ahead
    octo_gram_close();
    octo_gram.map = map;
    octo_gram.map_size = length;
    octo_gram.units = (const uint32_t *)(bytes + start);
    octo_gram.count = count;
    return 0;
}

static inline bool octo_gram_loaded(void) { return octo_gram.units != NULL; }

// darts-clone's unit, read with its index checked: one past the end reads
// as 0, whose label (0) no key byte has and which has no leaf.
static inline uint32_t octo_gram_unit(uint64_t i) { return i < octo_gram.count ? octo_gram.units[i] : 0; }
static inline uint32_t octo_gram_label(uint32_t u) { return u & ((1u << 31) | 0xFFu); }
static inline bool octo_gram_has_leaf(uint32_t u) { return ((u >> 8) & 1) == 1; }
static inline uint64_t octo_gram_offset(uint32_t u) { return (uint64_t)(u >> 10) << ((u & (1u << 9)) >> 6); }

// One code point from UTF-8 at s[*i], or -1 if none or malformed.
static inline int32_t octo_gram_next_utf8(const uint8_t *s, int64_t n, int64_t *i) {
    if (*i >= n) return -1;
    uint8_t b = s[*i];
    int extra = b < 0x80 ? 0 : (b & 0xE0) == 0xC0 ? 1 : (b & 0xF0) == 0xE0 ? 2 : (b & 0xF8) == 0xF0 ? 3 : -1;
    if (extra < 0 || *i + extra >= n) return -1;
    int32_t c = extra == 0 ? b : extra == 1 ? (b & 0x1F) : extra == 2 ? (b & 0x0F) : (b & 0x07);
    for (int k = 1; k <= extra; k++) {
        uint8_t x = s[*i + k];
        if ((x & 0xC0) != 0x80) return -1;
        c = (c << 6) | (x & 0x3F);
    }
    *i += extra + 1;
    return c;
}

// Appends octagram's encoding of code point u (gram_encoding.cc) to out at
// *n, which has room for at least 6 more bytes.
static inline void octo_gram_encode(uint32_t u, uint8_t *out, int *n) {
    if (u < 0x80) {
        out[(*n)++] = u == 0 ? 0xE0 : (uint8_t)u;
    } else if (u >= 0x4000 && u < 0xA000) {
        if ((u & 0xFF) == 0) {
            out[(*n)++] = 0xE1;
            out[(*n)++] = (uint8_t)((u >> 8) + 0x40);
        } else {
            out[(*n)++] = (uint8_t)((u >> 8) + 0x40);
            out[(*n)++] = (uint8_t)(u & 0xFF);
        }
    } else {
        int bits = 32;
        while (bits > 0 && (u & 0xFE000000u) == 0) {
            bits -= 7;
            u <<= 7;
        }
        int bytes = (bits + 6) / 7;
        out[(*n)++] = (uint8_t)(0xE0 | bytes);
        while (bytes > 0) {
            --bytes;
            out[(*n)++] = (uint8_t)(((u >> 25) & 0x7F) | 0x80);
            u <<= 7;
        }
    }
}

// The node reached from `node` by `key`, or -1 (darts-clone's traverse).
static inline int64_t octo_gram_walk(uint64_t node, const uint8_t *key, int n) {
    uint32_t unit = octo_gram_unit(node);
    for (int i = 0; i < n; i++) {
        uint64_t next = node ^ octo_gram_offset(unit) ^ key[i];
        unit = octo_gram_unit(next);
        if (octo_gram_label(unit) != key[i]) return -1;
        node = next;
    }
    return (int64_t)node;
}

// The keys that continue from `node` with a prefix of `key`: each one's
// length in bytes and value, at most OCTO_GRAM_RESULTS (darts-clone's
// commonPrefixSearch).
static inline int octo_gram_prefixes(uint64_t node, const uint8_t *key, int n, int *lengths, int32_t *values) {
    int found = 0;
    uint32_t unit = octo_gram_unit(node);
    node ^= octo_gram_offset(unit);
    for (int i = 0; i < n && found < OCTO_GRAM_RESULTS; i++) {
        node ^= key[i];
        unit = octo_gram_unit(node);
        if (octo_gram_label(unit) != key[i]) break;
        node ^= octo_gram_offset(unit);
        if (octo_gram_has_leaf(unit) && node < octo_gram.count) {
            lengths[found] = i + 1;
            values[found] = (int32_t)(octo_gram_unit(node) & 0x7FFFFFFFu);
            found++;
        }
    }
    return found;
}

// How well `word` follows `context`, in natural log units: librime-octagram's
// Query, with `rear` true when the word ends the input. Without a model, or
// without context, the non-collocation penalty.
static inline gs_f64 octo_gram_query(sl_u8 context, sl_u8 word, uint8_t rear) {
    double result = octo_gram.non_collocation;
    if (!octo_gram.units || context.len <= 0) return result;
    const int span = octo_gram.span;

    // The context's last `span` code points, and the word's first `span`.
    int32_t ctx[OCTO_GRAM_SPAN_MAX];
    int ctx_count = 0;
    for (int64_t i = 0; i < context.len;) {
        int32_t c = octo_gram_next_utf8(context.data, context.len, &i);
        if (c < 0) break;
        if (ctx_count == span) {
            memmove(ctx, ctx + 1, sizeof ctx[0] * (size_t)(span - 1));
            ctx_count--;
        }
        ctx[ctx_count++] = c;
    }
    int32_t w[OCTO_GRAM_SPAN_MAX];
    int w_count = 0;
    int word_chars = 0;
    for (int64_t i = 0; i < word.len;) {
        int32_t c = octo_gram_next_utf8(word.data, word.len, &i);
        if (c < 0) break;
        if (w_count < span) w[w_count++] = c;
        word_chars++;
    }
    if (ctx_count == 0 || w_count == 0) return result;

    // Encoded, with where each character starts.
    uint8_t cq[OCTO_GRAM_SPAN_MAX * 6], wq[OCTO_GRAM_SPAN_MAX * 6];
    int c_at[OCTO_GRAM_SPAN_MAX + 1], w_at[OCTO_GRAM_SPAN_MAX + 1];
    int cn = 0, wn = 0;
    for (int k = 0; k < ctx_count; k++) { c_at[k] = cn; octo_gram_encode((uint32_t)ctx[k], cq, &cn); }
    c_at[ctx_count] = cn;
    for (int k = 0; k < w_count; k++) { w_at[k] = wn; octo_gram_encode((uint32_t)w[k], wq, &wn); }
    w_at[w_count] = wn;

    int lengths[OCTO_GRAM_RESULTS];
    int32_t values[OCTO_GRAM_RESULTS];
    for (int k = 0; k < ctx_count; k++) {                 // the longest context first
        int context_len = ctx_count - k;
        int64_t node = octo_gram_walk(0, cq + c_at[k], cn - c_at[k]);
        if (node < 0) continue;
        int found = octo_gram_prefixes((uint64_t)node, wq, wn, lengths, values);
        for (int r = 0; r < found; r++) {
            int match_len = 0;                            // characters of the word matched
            while (match_len < w_count && w_at[match_len + 1] <= lengths[r]) match_len++;
            bool whole = k == 0 && lengths[r] == wn;
            double penalty = context_len + match_len >= octo_gram.min_length || whole
                                 ? octo_gram.collocation : octo_gram.weak_collocation;
            double score = values[r] / 10000.0 + penalty;
            if (score > result) result = score;
        }
    }
    if (rear && w_count == word_chars) {                  // how likely the word ends the input
        int64_t node = octo_gram_walk(0, wq, wn);
        const uint8_t end = '$';
        if (node >= 0 && octo_gram_prefixes((uint64_t)node, &end, 1, lengths, values) > 0) {
            double score = values[0] / 10000.0 + octo_gram.rear;
            if (score > result) result = score;
        }
    }
    return result;
}

#endif
