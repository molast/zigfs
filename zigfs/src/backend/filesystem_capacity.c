#include <stdint.h>
#if defined(__linux__) || defined(__APPLE__)
#include <sys/statvfs.h>

int zigfs_filesystem_capacity(int fd, uint64_t *total, uint64_t *available, uint64_t *used) {
    struct statvfs stats;
    if (fstatvfs(fd, &stats) != 0) return -1;
    uint64_t unit = stats.f_frsize ? stats.f_frsize : stats.f_bsize;
    if (!unit || stats.f_blocks > UINT64_MAX / unit ||
        stats.f_bavail > stats.f_blocks || stats.f_bfree > stats.f_blocks) return -1;
    *total = (uint64_t)stats.f_blocks * unit;
    *available = (uint64_t)stats.f_bavail * unit;
    *used = ((uint64_t)stats.f_blocks - stats.f_bfree) * unit;
    return 0;
}
#endif
