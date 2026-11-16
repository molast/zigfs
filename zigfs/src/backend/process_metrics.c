#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

/* Current resident memory, not getrusage's lifetime peak. No shared sampler state. */
int zigfs_process_metrics(uint64_t *rss, double *cpu, double *sampled) {
#if defined(__linux__) || defined(__APPLE__)
    struct timespec usage, now;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &usage) != 0 ||
        clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
#if defined(__APPLE__)
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    *rss = info.resident_size;
#else
    FILE *file = fopen("/proc/self/statm", "r");
    if (!file) return -1;
    unsigned long long pages;
    int fields = fscanf(file, "%*s %llu", &pages);
    fclose(file);
    long page_size = sysconf(_SC_PAGESIZE);
    if (fields != 1 || page_size <= 0 || pages > UINT64_MAX / (uint64_t)page_size) return -1;
    *rss = pages * (uint64_t)page_size;
#endif
    *cpu = (double)usage.tv_sec + (double)usage.tv_nsec / 1e9;
    *sampled = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
    return 0;
#else
    return -1;
#endif
}
