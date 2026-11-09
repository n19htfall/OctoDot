// Accelerate's single-precision matrix product, for the reranker's forward
// pass (rerank.h). Its own file, compiled apart from the generated C, so that
// the engine links libcblas, which re-exports Accelerate's BLAS: Goose links
// a package's libraries (octo.build) with its separately compiled C only.
// The LAPACK 3.9.1 interface, declared here rather than by including
// Accelerate, whose other parts are not linked.
void octo_cblas_sgemm(int order, int trans_a, int trans_b, int m, int n, int k, float alpha, const float *a,
                      int lda, const float *b, int ldb, float beta, float *c, int ldc)
    __asm__("_cblas_sgemm$NEWLAPACK");

void octo_rerank_sgemm(int order, int trans_a, int trans_b, int m, int n, int k, float alpha, const float *a,
                       int lda, const float *b, int ldb, float beta, float *c, int ldc) {
    octo_cblas_sgemm(order, trans_a, trans_b, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}
