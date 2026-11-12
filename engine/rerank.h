// The reranker's forward pass (engine/rerank.goose): a small character-level
// Transformer (docs/rerank-design.md) that scores each of the decoder's best
// sentences as log2 P(<s> text </s>).
//
// The weights are memory-mapped from rerank.weights, read-only, so their
// pages stay clean and file-backed and are not part of the IME's memory
// footprint (as the grammar model's are, gram.h). Goose cannot hold a slice
// into mapped memory, and the dense layers want the CPU's matrix unit
// (Accelerate's sgemm, through blas.c), so this is the second piece of the
// engine written in C; what is scored, when, and what is done with the
// scores are Goose.
//
// rerank.weights: six int32 (magic "OLM1", dims, layers, heads, vocab,
// positions), then float32 tensors in the order opening takes them. Opening
// checks the header against what rerank.img recorded and the size against
// the header, so every tensor lies inside the mapping; ids and lengths from
// Goose are checked against vocab and positions. A damaged file gives wrong
// scores, never a read outside the mapping.
//
// octo_rerank_score keeps no state between calls. The session's incremental
// entry keeps one trie, the previous successful score of the current
// composition, on the thread that called goose_init. That state is process
// local and is dropped when the composition, the model, or the reranker goes.
//
// Included into the engine's generated C (engine/octo.build), so it sees
// Goose's types (sl_i32, sl_f64, ...); the extern fns in rerank.goose bind to
// it with exactly the prototypes Goose declares for them.
#ifndef OCTO_RERANK_H
#define OCTO_RERANK_H

#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Accelerate's sgemm (blas.c), row-major: c = alpha a b' + beta c.
void octo_rerank_sgemm(int order, int trans_a, int trans_b, int m, int n, int k, float alpha, const float *a,
                       int lda, const float *b, int ldb, float beta, float *c, int ldc);
enum { OCTO_RR_ROW_MAJOR = 101, OCTO_RR_NO_TRANS = 111, OCTO_RR_TRANS = 112 };

enum { OCTO_RR_HEADER = 24, OCTO_RR_MAX_POSITIONS = 64, OCTO_RR_ROWS_PER_BLOCK = 64 };

typedef struct {
    const float *n1w, *n1b, *qkvw, *qkvb, *projw, *projb, *n2w, *n2b, *upw, *upb, *downw, *downb;
} octo_rr_layer;

static struct {
    void *map;
    size_t map_size;
    int dims, layers, heads, vocab, positions;
    const float *embed, *position, *normw, *normb;
    octo_rr_layer layer[16];
} octo_rr;

// One published trie: the last successful score of the composition. A slot
// holds, per layer, K and V after bias (dims each), then the final
// LayerNorm vector h and lse = logsumexp over the vocabulary. The index
// (token, parent, child, sibling) is how the next score finds a slot: the
// child of the old parent with this token id. 8 MiB covers the floats and
// that index. Slots grow with the trie, up to the budget, and are reused
// once a branch is no longer in the published trie.
enum { OCTO_RR_CACHE_BUDGET = 8 * 1024 * 1024 };

static struct {
    void *block;
    size_t block_bytes;
    int capacity;
    int stride;
    int live;
    int root;
    float *state;
    int *token, *parent, *child, *sibling;
    int last_nodes, last_hits, last_forward, last_vocab, last_used, last_fallback;
    int64_t cum_hits, cum_nodes, cum_forward, cum_vocab;
    size_t peak;
} octo_cache;

static int octo_cache_max_override;
static int octo_cache_fail_point; // 1: the next cache-block grow, 2: the next forward workspace
static int octo_rr_honor_fail;    // the cache entry, so a cold rescore is not the call that fails

enum { OCTO_RR_FAIL_BLOCK = 1, OCTO_RR_FAIL_WORK = 2 };

static inline void octo_rerank_cache_free(void) {
    free(octo_cache.block);
    octo_cache.block = NULL;
    octo_cache.state = NULL;
    octo_cache.token = octo_cache.parent = octo_cache.child = octo_cache.sibling = NULL;
    octo_cache.block_bytes = 0;
    octo_cache.capacity = 0;
    octo_cache.stride = 0;
    octo_cache.live = 0;
    octo_cache.root = -1;
}

static inline void octo_rerank_cache_clear(void) {
    octo_cache.live = 0;
    octo_cache.root = -1;
}

static inline void octo_rerank_close(void) {
    octo_rerank_cache_free();
    if (octo_rr.map) munmap(octo_rr.map, octo_rr.map_size);
    memset(&octo_rr, 0, sizeof octo_rr);
}

// Maps `path`, which must be `size` bytes and hold a model of exactly this
// shape. 0, or 1 if it cannot be read, 2 if it is not that model.
static inline gs_i32 octo_rerank_open(sl_u8 path, gs_u64 size, gs_i32 dims, gs_i32 layers, gs_i32 heads,
                                      gs_i32 vocab, gs_i32 positions) {
    octo_rerank_close();
    if (dims < 8 || dims > 4096 || heads < 1 || dims % heads != 0 || layers < 1 || layers > 16 || vocab < 4 ||
        vocab > 1000000 || positions < 3 || positions > OCTO_RR_MAX_POSITIONS)
        return 2;
    uint64_t d = (uint64_t)dims, per_layer = 12 * d * d + 13 * d;
    uint64_t floats = (uint64_t)vocab * d + (uint64_t)positions * d + (uint64_t)layers * per_layer + 2 * d;
    if (size != OCTO_RR_HEADER + 4 * floats) return 2;
    char name[1024];
    if (path.len <= 0 || path.len >= (int64_t)sizeof name) return 1;
    memcpy(name, path.data, (size_t)path.len);
    name[path.len] = 0;
    int fd = open(name, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 1;
    struct stat st;
    if (fstat(fd, &st) != 0 || (uint64_t)st.st_size != size) { close(fd); return 2; }
    void *map = mmap(NULL, (size_t)size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return 1;
    int32_t h[6];
    memcpy(h, map, sizeof h);
    if (memcmp(map, "OLM1", 4) != 0 || h[1] != dims || h[2] != layers || h[3] != heads || h[4] != vocab ||
        h[5] != positions) {
        munmap(map, (size_t)size);
        return 2;
    }
    octo_rr.map = map;
    octo_rr.map_size = (size_t)size;
    octo_rr.dims = dims; octo_rr.layers = layers; octo_rr.heads = heads;
    octo_rr.vocab = vocab; octo_rr.positions = positions;
    const float *p = (const float *)((const char *)map + OCTO_RR_HEADER);
    octo_rr.embed = p; p += (size_t)vocab * d;
    octo_rr.position = p; p += (size_t)positions * d;
    for (int i = 0; i < layers; i++) {
        octo_rr_layer *l = &octo_rr.layer[i];
        l->n1w = p; p += d; l->n1b = p; p += d;
        l->qkvw = p; p += 3 * d * d; l->qkvb = p; p += 3 * d;
        l->projw = p; p += d * d; l->projb = p; p += d;
        l->n2w = p; p += d; l->n2b = p; p += d;
        l->upw = p; p += 4 * d * d; l->upb = p; p += 4 * d;
        l->downw = p; p += 4 * d * d; l->downb = p; p += d;
    }
    octo_rr.normw = p; p += d;
    octo_rr.normb = p;
    return 0;
}

static inline void octo_rr_norm(const float *x, float *y, int rows, int d, const float *w, const float *b) {
    for (int r = 0; r < rows; r++) {
        const float *a = x + (size_t)r * d;
        float *o = y + (size_t)r * d;
        float mean = 0, var = 0;
        for (int i = 0; i < d; i++) mean += a[i];
        mean /= d;
        for (int i = 0; i < d; i++) { float t = a[i] - mean; var += t * t; }
        float inv = 1.0f / sqrtf(var / d + 1e-5f);
        for (int i = 0; i < d; i++) o[i] = (a[i] - mean) * inv * w[i] + b[i];
    }
}

// y[rows, out] (=, or += when accumulate) x[rows, in] . w[out, in]^T + b
static inline void octo_rr_linear(const float *x, int rows, int in, const float *w, const float *b, int out,
                                  float *y, int accumulate) {
    octo_rerank_sgemm(OCTO_RR_ROW_MAJOR, OCTO_RR_NO_TRANS, OCTO_RR_TRANS, rows, out, in, 1.0f, x, in, w, in,
                      accumulate ? 1.0f : 0.0f, y, out);
    for (int r = 0; r < rows; r++) {
        float *o = y + (size_t)r * out;
        for (int i = 0; i < out; i++) o[i] += b[i];
    }
}

// e^x for x <= 0 (all this file needs), to about 2e-7 relative, written so
// the loops around it vectorize: libm's expf does not, and took most of a
// score's time in the softmax over the characters. x = n ln2 + r, |r| <=
// ln2 / 2; e^r by its Taylor series to r^6; 2^n through the exponent bits.
// x is first held to [-87, 0], NaN to -87 (damaged weights give NaN), so n
// always converts to an int: a wrong score, never undefined behavior.
static inline float octo_rr_exp(float x) {
    x = x >= -87.0f ? x : -87.0f;
    x = x <= 0.0f ? x : 0.0f;
    float n = floorf(x * 1.44269504f + 0.5f);
    float r = x - n * 0.693145752f - n * 1.42860677e-6f;
    float p = 1.0f + r * (1.0f + r * (0.5f + r * (0.166666672f + r * (0.0416666679f + r * (0.00833333377f +
              r * 0.00138888892f)))));
    union { float f; int32_t i; } scale = { .i = ((int32_t)n + 127) << 23 };
    return p * scale.f;
}

// GELU as MLX's (0.5 x (1 + erf(x / sqrt 2))), erf by Abramowitz and Stegun
// 7.1.26 (error under 1.5e-7): libm's erff, one value at a time, took a third
// of a score's time.
static inline void octo_rr_gelu(float *x, size_t n) {
    for (size_t i = 0; i < n; i++) {
        float v = x[i], z = fabsf(v) * 0.707106781f;
        float t = 1.0f / (1.0f + 0.3275911f * z);
        float poly = ((((1.061405429f * t - 1.453152027f) * t + 1.421413741f) * t - 0.284496736f) * t +
                      0.254829592f) * t;
        float e = 1.0f - poly * octo_rr_exp(-z * z);
        x[i] = 0.5f * v * (1.0f + (v < 0 ? -e : e));
    }
}

// 0 when `ids` / `starts` / `bits` are a shortlist this model can read.
// Lengths are checked before any narrowing, subtraction, or size product.
// `all_bos` is set when every sequence starts at id 1.
static int octo_rr_check(sl_i32 ids, sl_i32 starts, sl_f64 bits, int *count, int *all_bos) {
    if (!octo_rr.map || bits.len < 1 || bits.len > INT32_MAX) return 1;
    int nseq = (int)bits.len;
    if (starts.len != (int64_t)nseq + 1 || ids.len < 0 || ids.len > INT32_MAX) return 1;
    if (!starts.data || !ids.data || !bits.data) return 1;
    if (starts.data[0] != 0 || (int64_t)starts.data[nseq] != ids.len) return 1;
    int64_t most = 0;
    int bos = 1;
    for (int k = 0; k < nseq; k++) {
        int64_t a = starts.data[k], b = starts.data[k + 1];
        if (a < 0 || b < a || b > ids.len) return 1;
        int64_t n = b - a;
        if (n < 2 || n > (int64_t)octo_rr.positions + 1) return 1;
        most += n - 1;
        if (most > INT32_MAX) return 1;
    }
    int V = octo_rr.vocab;
    for (int64_t t = 0; t < ids.len; t++) {
        int id = ids.data[t];
        if (id < 0 || id >= V) return 1;
    }
    for (int k = 0; k < nseq; k++)
        if (ids.data[starts.data[k]] != 1) bos = 0;
    *count = nseq;
    if (all_bos) *all_bos = bos;
    return 0;
}

static int octo_rr_mul(size_t a, size_t b, size_t *out) {
    if (a != 0 && b > SIZE_MAX / a) return 0;
    *out = a * b;
    return 1;
}

static void *octo_rr_alloc(size_t n, size_t elem) {
    size_t bytes;
    if (!octo_rr_mul(n, elem, &bytes) || bytes == 0) return NULL;
    return malloc(bytes);
}

// Model workspace (x, h, qkv, att, up, logits, lse). The cache entry can ask
// the next one of these to fail; a cold rescore leaves that switch off.
static void *octo_rr_work_alloc(size_t bytes) {
    if (bytes == 0) return NULL;
    if (octo_rr_honor_fail && octo_cache_fail_point == OCTO_RR_FAIL_WORK) {
        octo_cache_fail_point = 0;
        return NULL;
    }
    return malloc(bytes);
}

// Each distinct start is a node. Sequences share a root only when they share
// their first id; the session's jobs all start at BOS, so there is one.
static int octo_rr_build(const int32_t *ids, const int32_t *starts, int count, int *token, int *parent, int *depth,
                         int *child, int *sibling, int *at) {
    int rows = 0;
    for (int k = 0; k < count; k++) {
        int node = -1;
        for (int t = starts[k]; t < starts[k + 1] - 1; t++) {
            int c = node < 0 ? (rows > 0 ? 0 : -1) : child[node];
            while (c >= 0 && token[c] != ids[t]) c = node < 0 ? -1 : sibling[c];
            if (c < 0) {
                c = rows++;
                token[c] = ids[t];
                parent[c] = node;
                depth[c] = node < 0 ? 0 : depth[node] + 1;
                child[c] = -1;
                sibling[c] = node < 0 ? -1 : child[node];
                if (node >= 0) child[node] = c;
            }
            at[t] = node = c;
        }
    }
    return rows;
}

static int octo_cache_stride(void) {
    return 2 * octo_rr.layers * octo_rr.dims + octo_rr.dims + 1;
}

static int octo_cache_max_slots(void) {
    int stride = octo_cache_stride();
    size_t per = (size_t)stride * sizeof(float) + 4u * sizeof(int);
    if (per == 0) return 1;
    size_t n = (size_t)OCTO_RR_CACHE_BUDGET / per;
    if (n < 1) n = 1;
    if (n > 1000000) n = 1000000;
    if (octo_cache_max_override > 0 && octo_cache_max_override < (int)n) return octo_cache_max_override;
    return (int)n;
}

static void octo_cache_bind(void *block, int capacity, int stride) {
    octo_cache.block = block;
    octo_cache.capacity = capacity;
    octo_cache.stride = stride;
    octo_cache.state = (float *)block;
    int *idx = (int *)(octo_cache.state + (size_t)capacity * (size_t)stride);
    octo_cache.token = idx;
    octo_cache.parent = idx + capacity;
    octo_cache.child = idx + 2 * (size_t)capacity;
    octo_cache.sibling = idx + 3 * (size_t)capacity;
}

static int octo_cache_grow(int need) {
    int stride = octo_cache_stride();
    if (need <= octo_cache.capacity && octo_cache.stride == stride) return 1;
    if (need > octo_cache_max_slots()) return 0;
    size_t state_n = 0, state_bytes = 0, index_bytes = 0;
    if (!octo_rr_mul((size_t)need, (size_t)stride, &state_n)) return -1;
    if (!octo_rr_mul(state_n, sizeof(float), &state_bytes)) return -1;
    if (!octo_rr_mul((size_t)need, 4u * sizeof(int), &index_bytes)) return -1;
    if (index_bytes > SIZE_MAX - state_bytes) return -1;
    if (octo_cache_fail_point == OCTO_RR_FAIL_BLOCK) {
        octo_cache_fail_point = 0;
        return -1;
    }
    void *block = malloc(state_bytes + index_bytes);
    if (!block) return -1;
    float *nstate = (float *)block;
    int *nidx = (int *)(nstate + state_n);
    int old_cap = 0;
    if (octo_cache.block && octo_cache.capacity > 0 && octo_cache.stride == stride) {
        old_cap = octo_cache.capacity;
        memcpy(nstate, octo_cache.state, (size_t)old_cap * (size_t)stride * sizeof(float));
        size_t oldn = (size_t)old_cap * sizeof(int);
        memcpy(nidx, octo_cache.token, oldn);
        memcpy(nidx + need, octo_cache.parent, oldn);
        memcpy(nidx + 2 * (size_t)need, octo_cache.child, oldn);
        memcpy(nidx + 3 * (size_t)need, octo_cache.sibling, oldn);
    }
    for (int s = old_cap; s < need; s++) {
        nidx[s] = -1;
        nidx[(size_t)need + s] = -1;
        nidx[2 * (size_t)need + s] = -1;
        nidx[3 * (size_t)need + s] = -1;
    }
    free(octo_cache.block);
    octo_cache_bind(block, need, stride);
    octo_cache.block_bytes = state_bytes + index_bytes;
    if (octo_cache.block_bytes > octo_cache.peak) octo_cache.peak = octo_cache.block_bytes;
    return 1;
}

static float *octo_cache_at(int slot, int layer, int part) {
    return octo_cache.state + (size_t)slot * (size_t)octo_cache.stride +
           ((size_t)layer * 2u + (size_t)part) * (size_t)octo_rr.dims;
}

static float *octo_cache_h(int slot) {
    return octo_cache.state + (size_t)slot * (size_t)octo_cache.stride +
           (size_t)octo_rr.layers * 2u * (size_t)octo_rr.dims;
}

static float *octo_cache_lse(int slot) { return octo_cache_h(slot) + octo_rr.dims; }

static void octo_cache_fallback(int rows) {
    octo_rerank_cache_clear();
    octo_cache.last_nodes = rows > 0 ? rows : 0;
    octo_cache.last_hits = 0;
    octo_cache.last_forward = 0;
    octo_cache.last_vocab = 0;
    octo_cache.last_used = 0;
    octo_cache.last_fallback = 1;
}

static int octo_cache_usable(const double *bits, int count) {
    for (int k = 0; k < count; k++) {
        double b = bits[k];
        if (!(b == b) || b > 0.0 || b < -100000.0) return 0;
    }
    return 1;
}

static int octo_rr_batch(const int *batch_of, int row) { return batch_of ? batch_of[row] : row; }

// The forward both entries share. `batch_of` maps a trie row to its dense
// row, or -1 when that row is a cache hit and is not in the batch. NULL
// means every trie row is in the batch at the same index, which is a cold
// score: nothing is read from or written to the cache. `slot_of` is each
// trie row's cache slot; NULL is the cold score. A hit's next-token score
// is one dot product against the cached h and lse. Every candidate then
// adds its edges from <s> to </s>, in that order. 0, or -1 when a model
// workspace cannot be allocated. `nbatch == 0` skips the forward entirely.
static int octo_rr_eval(const int32_t *ids, const int32_t *starts, int count, const int *token, const int *parent,
                        const int *depth, const int *at, int rows, const int *batch_of, const int *slot_of,
                        int nbatch, double *bits) {
    const int d = octo_rr.dims, heads = octo_rr.heads, hd = d / heads, V = octo_rr.vocab;
    const int nids = starts[count];
    float *x = NULL, *h = NULL, *qkv = NULL, *att = NULL, *up = NULL, *logits = NULL, *lse = NULL, *edge = NULL;
    float s[OCTO_RR_MAX_POSITIONS];
    int path[OCTO_RR_MAX_POSITIONS];
    size_t edge_bytes = 0;
    int rc = -1;
    if (!octo_rr_mul((size_t)nids, sizeof(float), &edge_bytes)) return -1;
    edge = malloc(edge_bytes);
    if (!edge) return -1;
    memset(edge, 0, edge_bytes);
    if (nbatch > 0) {
        int logit_rows = nbatch < OCTO_RR_ROWS_PER_BLOCK ? nbatch : OCTO_RR_ROWS_PER_BLOCK;
        size_t nd = 0, n3 = 0, n4 = 0, lg = 0, xb = 0, hb = 0, qb = 0, ab = 0, ub = 0, lb = 0, lseb = 0;
        if (!octo_rr_mul((size_t)nbatch, (size_t)d, &nd) || !octo_rr_mul(nd, 3, &n3) || !octo_rr_mul(nd, 4, &n4) ||
            !octo_rr_mul((size_t)logit_rows, (size_t)V, &lg) || !octo_rr_mul(nd, sizeof(float), &xb) ||
            !octo_rr_mul(nd, sizeof(float), &hb) || !octo_rr_mul(n3, sizeof(float), &qb) ||
            !octo_rr_mul(nd, sizeof(float), &ab) || !octo_rr_mul(n4, sizeof(float), &ub) ||
            !octo_rr_mul(lg, sizeof(float), &lb) || !octo_rr_mul((size_t)nbatch, sizeof(float), &lseb))
            goto done;
        x = octo_rr_work_alloc(xb);
        h = octo_rr_work_alloc(hb);
        qkv = octo_rr_work_alloc(qb);
        att = octo_rr_work_alloc(ab);
        up = octo_rr_work_alloc(ub);
        logits = octo_rr_work_alloc(lb);
        lse = octo_rr_work_alloc(lseb);
        if (!x || !h || !qkv || !att || !up || !logits || !lse) goto done;
        if (slot_of) {
            octo_cache.live = 0;
            octo_cache.root = -1;
        }
        for (int r = 0; r < rows; r++) {
            int br = octo_rr_batch(batch_of, r);
            if (br < 0) continue;
            for (int i = 0; i < d; i++)
                x[(size_t)br * d + i] = octo_rr.embed[(size_t)token[r] * d + i] +
                                        octo_rr.position[(size_t)depth[r] * d + i];
        }
        const float scale = 1.0f / sqrtf((float)hd);
        for (int l = 0; l < octo_rr.layers; l++) {
            const octo_rr_layer *ly = &octo_rr.layer[l];
            octo_rr_norm(x, h, nbatch, d, ly->n1w, ly->n1b);
            octo_rr_linear(h, nbatch, d, ly->qkvw, ly->qkvb, 3 * d, qkv, 0);
            if (slot_of) {
                for (int r = 0; r < rows; r++) {
                    int br = octo_rr_batch(batch_of, r);
                    if (br < 0) continue;
                    memcpy(octo_cache_at(slot_of[r], l, 0), qkv + (size_t)br * 3 * d + d, (size_t)d * sizeof(float));
                    memcpy(octo_cache_at(slot_of[r], l, 1), qkv + (size_t)br * 3 * d + 2 * d,
                           (size_t)d * sizeof(float));
                }
            }
            for (int r = 0; r < rows; r++) {
                int br = octo_rr_batch(batch_of, r);
                if (br < 0) continue;
                int n = depth[r] + 1;
                for (int j = n - 1, a = r; j >= 0; j--, a = parent[a]) path[j] = a;
                for (int hh = 0; hh < heads; hh++) {
                    const float *q = qkv + (size_t)br * 3 * d + hh * hd;
                    float m = -1e30f, sum = 0;
                    for (int j = 0; j < n; j++) {
                        int pr = path[j], pbr = octo_rr_batch(batch_of, pr);
                        const float *kk = pbr >= 0 ? qkv + (size_t)pbr * 3 * d + d + hh * hd
                                                   : octo_cache_at(slot_of[pr], l, 0) + hh * hd;
                        float dot = 0;
                        for (int c = 0; c < hd; c++) dot += q[c] * kk[c];
                        s[j] = dot * scale;
                        if (s[j] > m) m = s[j];
                    }
                    for (int j = 0; j < n; j++) { s[j] = octo_rr_exp(s[j] - m); sum += s[j]; }
                    float *o = att + (size_t)br * d + hh * hd;
                    for (int c = 0; c < hd; c++) o[c] = 0;
                    for (int j = 0; j < n; j++) {
                        int pr = path[j], pbr = octo_rr_batch(batch_of, pr);
                        const float *vv = pbr >= 0 ? qkv + (size_t)pbr * 3 * d + 2 * d + hh * hd
                                                   : octo_cache_at(slot_of[pr], l, 1) + hh * hd;
                        float a = s[j] / sum;
                        for (int c = 0; c < hd; c++) o[c] += a * vv[c];
                    }
                }
            }
            octo_rr_linear(att, nbatch, d, ly->projw, ly->projb, d, x, 1);
            octo_rr_norm(x, h, nbatch, d, ly->n2w, ly->n2b);
            octo_rr_linear(h, nbatch, d, ly->upw, ly->upb, 4 * d, up, 0);
            octo_rr_gelu(up, n4);
            octo_rr_linear(up, nbatch, 4 * d, ly->downw, ly->downb, d, x, 1);
        }
        octo_rr_norm(x, h, nbatch, d, octo_rr.normw, octo_rr.normb);
        if (slot_of) {
            for (int r = 0; r < rows; r++) {
                int br = octo_rr_batch(batch_of, r);
                if (br < 0) continue;
                memcpy(octo_cache_h(slot_of[r]), h + (size_t)br * d, (size_t)d * sizeof(float));
            }
        }
        // The output, tied to the input embedding, a block of the batch at a
        // time: the logits of a whole shortlist at once would be megabytes.
        for (int r0 = 0; r0 < nbatch; r0 += OCTO_RR_ROWS_PER_BLOCK) {
            int block = nbatch - r0 < OCTO_RR_ROWS_PER_BLOCK ? nbatch - r0 : OCTO_RR_ROWS_PER_BLOCK;
            octo_rerank_sgemm(OCTO_RR_ROW_MAJOR, OCTO_RR_NO_TRANS, OCTO_RR_TRANS, block, V, d, 1.0f,
                              h + (size_t)r0 * d, d, octo_rr.embed, d, 0.0f, logits, V);
            for (int b = 0; b < block; b++) {
                const float *row = logits + (size_t)b * V;
                float m = row[0], sum = 0;
                for (int i = 1; i < V; i++) m = row[i] > m ? row[i] : m;
                for (int i = 0; i < V; i++) sum += octo_rr_exp(row[i] - m);
                lse[r0 + b] = m + logf(sum);
                if (slot_of) {
                    for (int r = 0; r < rows; r++)
                        if (octo_rr_batch(batch_of, r) == r0 + b) *octo_cache_lse(slot_of[r]) = lse[r0 + b];
                }
            }
            for (int k = 0; k < count; k++)
                for (int t = starts[k]; t < starts[k + 1] - 1; t++) {
                    int br = octo_rr_batch(batch_of, at[t]);
                    if (br >= r0 && br < r0 + block)
                        edge[t] = logits[(size_t)(br - r0) * V + ids[t + 1]] - lse[br];
                }
        }
    }
    if (batch_of && slot_of) {
        for (int k = 0; k < count; k++)
            for (int t = starts[k]; t < starts[k + 1] - 1; t++) {
                int row = at[t];
                if (batch_of[row] >= 0) continue;
                const float *hh = octo_cache_h(slot_of[row]);
                const float *e = octo_rr.embed + (size_t)ids[t + 1] * d;
                float dot = 0;
                for (int i = 0; i < d; i++) dot += hh[i] * e[i];
                edge[t] = dot - *octo_cache_lse(slot_of[row]);
            }
    }
    for (int k = 0; k < count; k++) {
        double sum = 0;
        for (int t = starts[k]; t < starts[k + 1] - 1; t++) sum += edge[t];
        bits[k] = sum / M_LN2;
    }
    rc = 0;
done:
    free(edge); free(x); free(h); free(qkv); free(att); free(up); free(logits); free(lse);
    return rc;
}

// Scores `count` sequences, ids[starts[k] .. starts[k + 1]] each (<s> text
// </s>): bits[k] = log2 of the probability of each id after the ones before
// it. 0, or 1 if the model is not open, the input is not one it can read, or
// a workspace cannot be allocated. No trie is kept for the next call. The
// model looks only backward, so a start the candidates share is one node.
static inline gs_i32 octo_rerank_score(sl_i32 ids, sl_i32 starts, sl_f64 bits) {
    int count = 0;
    if (octo_rr_check(ids, starts, bits, &count, NULL)) return 1;
    int64_t most64 = 0;
    for (int k = 0; k < count; k++) most64 += (int64_t)starts.data[k + 1] - starts.data[k] - 1;
    int most = (int)most64;
    int *token = octo_rr_alloc((size_t)most, sizeof(int)), *parent = octo_rr_alloc((size_t)most, sizeof(int));
    int *depth = octo_rr_alloc((size_t)most, sizeof(int)), *child = octo_rr_alloc((size_t)most, sizeof(int));
    int *sibling = octo_rr_alloc((size_t)most, sizeof(int)), *at = octo_rr_alloc((size_t)ids.len, sizeof(int));
    int rows = 0, ev = -1;
    if (token && parent && depth && child && sibling && at) {
        rows = octo_rr_build(ids.data, starts.data, count, token, parent, depth, child, sibling, at);
        free(child); free(sibling);
        child = sibling = NULL;
        if (rows >= 1)
            ev = octo_rr_eval(ids.data, starts.data, count, token, parent, depth, at, rows, NULL, NULL, rows, bits.data);
    }
    free(token); free(parent); free(depth); free(child); free(sibling); free(at);
    return ev < 0 ? 1 : 0;
}

// The session's score. 0, bits usable and this trie published; 1, the input
// is not readable (the cache is left as it was); 2, this call could not keep
// a trie (over the budget, or an allocation failed, or the weights did not
// yield a usable score). The caller then scores with octo_rerank_score.
// A request whose first id is not BOS is scored cold and does not touch the
// trie: that entry accepts any ids the cold path does.
static inline gs_i32 octo_rerank_cache_score(sl_i32 ids, sl_i32 starts, sl_f64 bits) {
    int count = 0, all_bos = 0;
    if (octo_rr_check(ids, starts, bits, &count, &all_bos)) return 1;
    if (!all_bos) {
        octo_cache.last_nodes = octo_cache.last_hits = octo_cache.last_forward = octo_cache.last_vocab = 0;
        octo_cache.last_used = octo_cache.last_fallback = 0;
        return octo_rerank_score(ids, starts, bits);
    }
    int64_t most64 = 0;
    for (int k = 0; k < count; k++) most64 += (int64_t)starts.data[k + 1] - starts.data[k] - 1;
    int most = (int)most64;
    int *token = octo_rr_alloc((size_t)most, sizeof(int));
    int *parent = octo_rr_alloc((size_t)most, sizeof(int));
    int *depth = octo_rr_alloc((size_t)most, sizeof(int));
    int *child = octo_rr_alloc((size_t)most, sizeof(int));
    int *sibling = octo_rr_alloc((size_t)most, sizeof(int));
    int *at = octo_rr_alloc((size_t)ids.len, sizeof(int));
    int *old_of = NULL, *slot = NULL, *miss_of = NULL;
    int rows = 0, nmiss = 0, rc = 2, alloc_failed = 0;
    if (octo_cache.capacity > 0 && octo_cache.stride != octo_cache_stride()) octo_rerank_cache_free();
    if (!token || !parent || !depth || !child || !sibling || !at) { alloc_failed = 1; goto fail; }
    rows = octo_rr_build(ids.data, starts.data, count, token, parent, depth, child, sibling, at);
    if (rows < 1 || rows > octo_cache_max_slots()) goto fail;
    old_of = octo_rr_alloc((size_t)rows, sizeof(int));
    slot = octo_rr_alloc((size_t)rows, sizeof(int));
    miss_of = octo_rr_alloc((size_t)rows, sizeof(int));
    if (!old_of || !slot || !miss_of) { alloc_failed = 1; goto fail; }
    for (int r = 0; r < rows; r++) old_of[r] = -1;
    if (octo_cache.live && octo_cache.root >= 0 && octo_cache.root < octo_cache.capacity) {
        for (int r = 0; r < rows; r++) {
            if (parent[r] < 0) {
                if (octo_cache.token[octo_cache.root] == token[r]) old_of[r] = octo_cache.root;
                continue;
            }
            int op = old_of[parent[r]];
            if (op < 0 || op >= octo_cache.capacity) continue;
            int c = octo_cache.child[op];
            int guard = 0;
            while (c >= 0 && c < octo_cache.capacity && octo_cache.token[c] != token[r] &&
                   guard++ < octo_cache.capacity)
                c = octo_cache.sibling[c];
            if (c >= 0 && c < octo_cache.capacity && octo_cache.token[c] == token[r]) old_of[r] = c;
        }
    }
    {
        int grew = octo_cache_grow(rows);
        if (grew < 0) { alloc_failed = 1; goto fail; }
        if (!grew) goto fail;
    }
    {
        uint8_t *reserved = octo_rr_alloc((size_t)octo_cache.capacity, 1);
        int *free_slots = octo_rr_alloc((size_t)octo_cache.capacity, sizeof(int));
        if (!reserved || !free_slots) {
            free(reserved);
            free(free_slots);
            alloc_failed = 1;
            goto fail;
        }
        memset(reserved, 0, (size_t)octo_cache.capacity);
        for (int r = 0; r < rows; r++)
            if (old_of[r] >= 0 && old_of[r] < octo_cache.capacity) reserved[old_of[r]] = 1;
        int nfree = 0;
        for (int s = 0; s < octo_cache.capacity; s++)
            if (!reserved[s]) free_slots[nfree++] = s;
        int u = 0, bad = 0;
        for (int r = 0; r < rows; r++) {
            if (old_of[r] >= 0) slot[r] = old_of[r];
            else if (u < nfree) slot[r] = free_slots[u++];
            else bad = 1;
        }
        free(reserved);
        free(free_slots);
        if (bad) goto fail;
    }
    nmiss = 0;
    for (int r = 0; r < rows; r++) {
        if (old_of[r] < 0) miss_of[r] = nmiss++;
        else miss_of[r] = -1;
    }
    octo_rr_honor_fail = 1;
    {
        int ev = octo_rr_eval(ids.data, starts.data, count, token, parent, depth, at, rows, miss_of, slot, nmiss,
                              bits.data);
        octo_rr_honor_fail = 0;
        if (ev < 0) { alloc_failed = 1; goto fail; }
    }
    if (!octo_cache_usable(bits.data, count)) goto fail;
    octo_cache.live = 0;
    for (int r = 0; r < rows; r++) {
        int s = slot[r];
        octo_cache.token[s] = token[r];
        octo_cache.parent[s] = parent[r] < 0 ? -1 : slot[parent[r]];
        octo_cache.child[s] = -1;
        octo_cache.sibling[s] = -1;
    }
    for (int r = 0; r < rows; r++) {
        if (parent[r] < 0) continue;
        int s = slot[r], p = slot[parent[r]];
        octo_cache.sibling[s] = octo_cache.child[p];
        octo_cache.child[p] = s;
    }
    octo_cache.root = slot[0];
    octo_cache.live = 1;
    {
        int hits = rows - nmiss;
        octo_cache.last_nodes = rows;
        octo_cache.last_hits = hits;
        octo_cache.last_forward = nmiss;
        octo_cache.last_vocab = nmiss;
        octo_cache.last_used = hits > 0;
        octo_cache.last_fallback = 0;
        octo_cache.cum_hits += hits;
        octo_cache.cum_nodes += rows;
        octo_cache.cum_forward += nmiss;
        octo_cache.cum_vocab += nmiss;
    }
    rc = 0;
    goto done;
fail:
    octo_cache_fallback(rows);
    if (alloc_failed) octo_rerank_cache_free();
    rc = 2;
done:
    octo_rr_honor_fail = 0;
    free(token); free(parent); free(depth); free(child); free(sibling); free(at);
    free(old_of); free(slot); free(miss_of);
    return rc;
}

static inline void octo_rerank_cache_set_max_slots(gs_i32 n) { octo_cache_max_override = n > 0 ? n : 0; }

static inline void octo_rerank_cache_fail_alloc(gs_i32 point) {
    octo_cache_fail_point = point == OCTO_RR_FAIL_BLOCK || point == OCTO_RR_FAIL_WORK ? point : 0;
}

static inline gs_i32 octo_rerank_cache_last_nodes(void) { return octo_cache.last_nodes; }
static inline gs_i32 octo_rerank_cache_last_hits(void) { return octo_cache.last_hits; }
static inline gs_i32 octo_rerank_cache_last_forward(void) { return octo_cache.last_forward; }
static inline gs_i32 octo_rerank_cache_last_vocab(void) { return octo_cache.last_vocab; }
static inline gs_i32 octo_rerank_cache_last_used(void) { return octo_cache.last_used; }
static inline gs_i32 octo_rerank_cache_last_fallback(void) { return octo_cache.last_fallback; }
static inline gs_i32 octo_rerank_cache_live(void) { return octo_cache.live; }
static inline gs_i64 octo_rerank_cache_cum_hits(void) { return octo_cache.cum_hits; }
static inline gs_i64 octo_rerank_cache_cum_nodes(void) { return octo_cache.cum_nodes; }
static inline gs_i64 octo_rerank_cache_cum_forward(void) { return octo_cache.cum_forward; }
static inline gs_i64 octo_rerank_cache_cum_vocab(void) { return octo_cache.cum_vocab; }
static inline gs_i64 octo_rerank_cache_bytes(void) { return (gs_i64)octo_cache.block_bytes; }
static inline gs_i64 octo_rerank_cache_peak(void) { return (gs_i64)octo_cache.peak; }

static inline void octo_rerank_cache_reset_stats(void) {
    octo_cache.last_nodes = octo_cache.last_hits = octo_cache.last_forward = octo_cache.last_vocab = 0;
    octo_cache.last_used = octo_cache.last_fallback = 0;
    octo_cache.cum_hits = octo_cache.cum_nodes = octo_cache.cum_forward = octo_cache.cum_vocab = 0;
    octo_cache.peak = octo_cache.block_bytes;
}

#endif
