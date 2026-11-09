/* Measurements the benchmark takes through extern fn. */
#include <mach/mach.h>
#include <stdint.h>
#include <time.h>

/* The process's physical footprint, the number Activity Monitor's Memory
   column and `footprint` report: dirty memory, compressed memory included. */
uint64_t octo_phys_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

/* A nanosecond clock. Goose's clock_ns() uses CLOCK_MONOTONIC, which macOS
   reports in whole microseconds: too coarse to time one lookup. */
uint64_t octo_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
