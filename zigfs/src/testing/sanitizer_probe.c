/* Isolated C positive controls and real telemetry bridge exercise; never linked
 * into the server. Build separately for each sanitizer. */
#include "../backend/host_metrics.c"
#include "../backend/process_metrics.c"
#include "../backend/filesystem_capacity.c"
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>

static volatile int shared_counter;
static atomic_int ready;
static void *race(void *unused) {
    (void)unused;
    atomic_fetch_add(&ready, 1);
    while (atomic_load(&ready) < 2) {}
    for (int i = 0; i < 10000; ++i) shared_counter++;
    return NULL;
}
static void *bridge(void *unused) {
    (void)unused;
    for (int i = 0; i < 100; ++i) {
        struct zigfs_host_metrics metrics;
        uint64_t rss, total, available, used;
        double cpu, sampled;
        zigfs_host_metrics_read(&metrics);
        if (zigfs_process_metrics(&rss, &cpu, &sampled) != 0) abort();
        int fd = open(".", O_RDONLY);
        if (fd < 0 || zigfs_filesystem_capacity(fd, &total, &available, &used) != 0) abort();
        int readonly;
        if (zigfs_filesystem_health(fd, &readonly) != 0) abort();
        close(fd);
        if (rss == 0 || total == 0 || available > total) abort();
    }
    return NULL;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "clean") == 0 || strcmp(argv[1], "race") == 0) {
        pthread_t a, b;
        void *(*fn)(void *) = strcmp(argv[1], "clean") == 0 ? bridge : race;
        if (pthread_create(&a, NULL, fn, NULL) || pthread_create(&b, NULL, fn, NULL)) return 3;
        pthread_join(a, NULL); pthread_join(b, NULL);
    } else if (strcmp(argv[1], "overflow") == 0) {
        volatile int max = INT_MAX;
        volatile int result = max + 1;
        (void)result;
    } else {
        volatile unsigned char *bytes = malloc(16);
        if (!bytes) return 3;
        bytes[0] = 42;
        if (strcmp(argv[1], "use-after-free") == 0) {
            free((void *)bytes); bytes[0] = 17;
        } else if (strcmp(argv[1], "buffer-overflow") == 0) {
            bytes[16] = 17; free((void *)bytes);
        } else if (strcmp(argv[1], "double-free") == 0) {
            free((void *)bytes); free((void *)bytes);
        } else return 2;
    }
    return 0;
}
