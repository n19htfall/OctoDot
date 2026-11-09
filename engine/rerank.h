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
// Scoring keeps no state between calls (its buffers are its own). Like the
// rest of the engine, it runs on the thread that called goose_init.
//
// Included into the engine's generated C (engine/octo.build), so it sees
// Goose's types (sl_i32, sl_f64, ...); the extern fns in rerank.goose bind to
// it with exactly the prototypes Goose declares for them.
#ifndef OCTO_RERANK_H
#define OCTO_RERANK_H

#include <fcntl.h>
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

static inline void octo_rerank_close(void) {
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

// Scores `count` sequences, ids[starts[k] .. starts[k + 1]] each (<s> text
// </s>): bits[k] = log2 of the probability of each id after the ones before
// it. 0, or 1 if the model is not open or the input is not one it can read
// (an id outside the vocabulary, a sequence too short or too long).
//
// The model looks only backward, so a start the candidates share (一家三口后
// in 一家三口后部车票 and 一家三口后补车票) has one state and one next-character
// distribution: each distinct start is a node of a trie, computed once (40%
// of the characters, on the corpus's shortlists), its attention reading the
// nodes on its own path; each candidate sums its characters' probabilities
// along its path.
static inline gs_i32 octo_rerank_score(sl_i32 ids, sl_i32 starts, sl_f64 bits) {
    int count = (int)bits.len;
    if (!octo_rr.map || count < 1 || starts.len != count + 1 || starts.data[0] != 0 ||
        starts.data[count] != ids.len)
        return 1;
    const int d = octo_rr.dims, heads = octo_rr.heads, hd = d / heads, V = octo_rr.vocab;
    int most = 0;
    for (int k = 0; k < count; k++) {
        int n = starts.data[k + 1] - starts.data[k];
        if (n < 2 || n > octo_rr.positions + 1) return 1;
        most += n - 1;
    }
    for (int64_t t = 0; t < ids.len; t++)
        if (ids.data[t] < 0 || ids.data[t] >= V) return 1;

    int *token = malloc(sizeof(int) * most), *parent = malloc(sizeof(int) * most);
    int *depth = malloc(sizeof(int) * most), *child = malloc(sizeof(int) * most);
    int *sibling = malloc(sizeof(int) * most), *at = malloc(sizeof(int) * (size_t)ids.len);
    int rows = 0;
    for (int k = 0; k < count; k++) {
        int node = -1;
        for (int t = starts.data[k]; t < starts.data[k + 1] - 1; t++) {
            int c = node < 0 ? (rows > 0 ? 0 : -1) : child[node];
            while (c >= 0 && token[c] != ids.data[t]) c = node < 0 ? -1 : sibling[c];
            if (c < 0) {
                c = rows++;
                token[c] = ids.data[t];
                parent[c] = node;
                depth[c] = node < 0 ? 0 : depth[node] + 1;
                child[c] = -1;
                sibling[c] = node < 0 ? -1 : child[node];
                if (node >= 0) child[node] = c;
            }
            at[t] = node = c;
        }
    }
    float *x = malloc(sizeof(float) * (size_t)rows * d), *h = malloc(sizeof(float) * (size_t)rows * d);
    float *qkv = malloc(sizeof(float) * (size_t)rows * 3 * d), *att = malloc(sizeof(float) * (size_t)rows * d);
    float *up = malloc(sizeof(float) * (size_t)rows * 4 * d);
    float *logits = malloc(sizeof(float) * (size_t)OCTO_RR_ROWS_PER_BLOCK * V);
    float *lse = malloc(sizeof(float) * rows);
    float s[OCTO_RR_MAX_POSITIONS];
    int path[OCTO_RR_MAX_POSITIONS];
    for (int r = 0; r < rows; r++)
        for (int i = 0; i < d; i++)
            x[(size_t)r * d + i] = octo_rr.embed[(size_t)token[r] * d + i] + octo_rr.position[(size_t)depth[r] * d + i];
    const float scale = 1.0f / sqrtf((float)hd);
    for (int l = 0; l < octo_rr.layers; l++) {
        const octo_rr_layer *ly = &octo_rr.layer[l];
        octo_rr_norm(x, h, rows, d, ly->n1w, ly->n1b);
        octo_rr_linear(h, rows, d, ly->qkvw, ly->qkvb, 3 * d, qkv, 0);
        for (int r = 0; r < rows; r++) {
            int n = depth[r] + 1;
            for (int j = n - 1, a = r; j >= 0; j--, a = parent[a]) path[j] = a;
            for (int hh = 0; hh < heads; hh++) {
                const float *q = qkv + (size_t)r * 3 * d + hh * hd;
                float m = -1e30f, sum = 0;
                for (int j = 0; j < n; j++) {
                    const float *kk = qkv + (size_t)path[j] * 3 * d + d + hh * hd;
                    float dot = 0;
                    for (int c = 0; c < hd; c++) dot += q[c] * kk[c];
                    s[j] = dot * scale;
                    if (s[j] > m) m = s[j];
                }
                for (int j = 0; j < n; j++) { s[j] = octo_rr_exp(s[j] - m); sum += s[j]; }
                float *o = att + (size_t)r * d + hh * hd;
                for (int c = 0; c < hd; c++) o[c] = 0;
                for (int j = 0; j < n; j++) {
                    const float *vv = qkv + (size_t)path[j] * 3 * d + 2 * d + hh * hd;
                    float a = s[j] / sum;
                    for (int c = 0; c < hd; c++) o[c] += a * vv[c];
                }
            }
        }
        octo_rr_linear(att, rows, d, ly->projw, ly->projb, d, x, 1);
        octo_rr_norm(x, h, rows, d, ly->n2w, ly->n2b);
        octo_rr_linear(h, rows, d, ly->upw, ly->upb, 4 * d, up, 0);
        octo_rr_gelu(up, (size_t)rows * 4 * d);
        octo_rr_linear(up, rows, 4 * d, ly->downw, ly->downb, d, x, 1);
    }
    octo_rr_norm(x, h, rows, d, octo_rr.normw, octo_rr.normb);
    // The output, tied to the input embedding, a block of rows at a time: the
    // logits of a whole shortlist at once would be megabytes.
    for (int k = 0; k < count; k++) bits.data[k] = 0;
    for (int r0 = 0; r0 < rows; r0 += OCTO_RR_ROWS_PER_BLOCK) {
        int block = rows - r0 < OCTO_RR_ROWS_PER_BLOCK ? rows - r0 : OCTO_RR_ROWS_PER_BLOCK;
        octo_rerank_sgemm(OCTO_RR_ROW_MAJOR, OCTO_RR_NO_TRANS, OCTO_RR_TRANS, block, V, d, 1.0f,
                          h + (size_t)r0 * d, d, octo_rr.embed, d, 0.0f, logits, V);
        for (int b = 0; b < block; b++) {
            const float *row = logits + (size_t)b * V;
            float m = row[0], sum = 0;
            for (int i = 1; i < V; i++) m = row[i] > m ? row[i] : m;
            for (int i = 0; i < V; i++) sum += octo_rr_exp(row[i] - m);
            lse[r0 + b] = m + logf(sum);
        }
        for (int k = 0; k < count; k++)
            for (int t = starts.data[k]; t < starts.data[k + 1] - 1; t++)
                if (at[t] >= r0 && at[t] < r0 + block)
                    bits.data[k] += logits[(size_t)(at[t] - r0) * V + ids.data[t + 1]] - lse[at[t]];
    }
    for (int k = 0; k < count; k++) bits.data[k] /= M_LN2;
    free(token); free(parent); free(depth); free(child); free(sibling); free(at);
    free(x); free(h); free(qkv); free(att); free(up); free(logits); free(lse);
    return 0;
}

#endif
