/* The C host for jobs.goose. It plays the IME's part: one main thread makes
   every engine call, and workers reach it only through octo_host_wake(),
   which signals and does nothing else. */
#include "jobs.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { KIND_SUM = 1, KIND_OOB = 2, KIND_ASSERT = 3 };
enum { PENDING = 0, SUCCEEDED = 1, FAILED = 2 };

static pthread_mutex_t wake_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake_cv = PTHREAD_COND_INITIALIZER;
static long wakes;

/* Called on worker threads. The IME's version signals a CFRunLoopSource. */
void octo_host_wake(void) {
    pthread_mutex_lock(&wake_mu);
    wakes++;
    pthread_cond_signal(&wake_cv);
    pthread_mutex_unlock(&wake_mu);
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* Pumps on every wake-up until `id` leaves PENDING; -1 on timeout. The wake
   count is read before pumping, so a wake-up that lands in between is not
   missed. */
static int wait_for(int64_t id, int timeout_ms) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    for (;;) {
        pthread_mutex_lock(&wake_mu);
        long seen = wakes;
        pthread_mutex_unlock(&wake_mu);
        octo_pump();
        int state = octo_job_state(id);
        if (state != PENDING) return state;
        pthread_mutex_lock(&wake_mu);
        while (wakes == seen) {
            if (pthread_cond_timedwait(&wake_cv, &wake_mu, &deadline) == ETIMEDOUT) {
                pthread_mutex_unlock(&wake_mu);
                return -1;
            }
        }
        pthread_mutex_unlock(&wake_mu);
    }
}

static int failures;
static void check(int ok, const char *what) {
    printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

static void why(int64_t id, char *out, size_t cap) {
    int64_t n = 0;
    const uint8_t *p = octo_job_why(id, &n);
    size_t len = n < 0 ? 0 : (size_t)n < cap - 1 ? (size_t)n : cap - 1;
    memcpy(out, p, len);
    out[len] = 0;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    char msg[256];
    goose_init(argc, argv);

    int64_t id = octo_request(KIND_SUM, 1000);
    check(wait_for(id, 5000) == SUCCEEDED && octo_job_value(id) == 500500,
          "a job runs in a worker and its result reaches the main thread");

    id = octo_request(KIND_OOB, 7);
    check(wait_for(id, 5000) == FAILED, "a bounds-check failure in a contained worker fails only that job");
    why(id, msg, sizeof msg);
    printf("      why: %s\n", msg);
    check(strstr(msg, "index 7 out of bounds (length 3)") && strstr(msg, "jobs.goose:"),
          "the abort message names the check and its source line, and nothing else");

    id = octo_request(KIND_ASSERT, 1);
    check(wait_for(id, 5000) == FAILED, "a failed assert in a contained worker fails only that job");
    why(id, msg, sizeof msg);
    printf("      why: %s\n", msg);

    id = octo_request(KIND_SUM, 10);
    check(wait_for(id, 5000) == SUCCEEDED && octo_job_value(id) == 55,
          "the engine keeps working after contained aborts");

    enum { BURST = 64 };
    int64_t ids[BURST];
    for (int i = 0; i < BURST; i++) ids[i] = octo_request(i % 2 ? KIND_OOB : KIND_SUM, i % 2 ? 5 : 100);
    int right = 0;
    for (int i = 0; i < BURST; i++) {
        int state = wait_for(ids[i], 10000);
        right += (i % 2) ? state == FAILED : (state == SUCCEEDED && octo_job_value(ids[i]) == 5050);
    }
    check(right == BURST, "64 concurrent jobs, half aborting, all end in the right state");

    enum { ROUNDS = 500 };
    static uint64_t samples[ROUNDS];
    for (int i = 0; i < ROUNDS; i++) {
        uint64_t start = now_ns();
        id = octo_request(KIND_SUM, 10);
        wait_for(id, 5000);
        samples[i] = now_ns() - start;
    }
    qsort(samples, ROUNDS, sizeof samples[0], cmp_u64);
    printf("latency  request → supervisor + contained worker → wake → pump, %d jobs: "
           "p50 %llu us, p99 %llu us\n", ROUNDS,
           (unsigned long long)(samples[ROUNDS / 2] / 1000),
           (unsigned long long)(samples[ROUNDS * 99 / 100] / 1000));

    octo_quiesce();
    goose_exit();
    check(1, "goose_exit after octo_quiesce: no worker left running");

    goose_init(argc, argv);
    id = octo_request(KIND_SUM, 3);
    check(id == 1 && wait_for(id, 5000) == SUCCEEDED && octo_job_value(id) == 6,
          "goose_init again starts a fresh program (the reload path)");
    octo_quiesce();
    goose_exit();

    return failures ? 1 : 0;
}
