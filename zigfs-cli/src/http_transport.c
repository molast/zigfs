#define _POSIX_C_SOURCE 200809L
/* HTTP transport and terminal rendering. Zig controls signing and output policy. */
#include "cli_transport.h"
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>

/* Each worker owns its counters. Rendering and aggregate totals are serialized.
 * The UI never contains URLs, object names or credentials. */
static pthread_mutex_t progress_mutex = PTHREAD_MUTEX_INITIALIZER;
static int progress_enabled, progress_color, progress_active;
static size_t progress_width;
static double progress_started;
static uint64_t progress_uploaded, progress_downloaded;
struct object_progress {
    uint64_t total, resumed, done, parts;
    double started;
    uint64_t *part_bytes;
};
static __thread struct object_progress *current_object;
static __thread uint64_t current_part;
static __thread struct {
    int enabled, color, active;
    const char *label;
    uint64_t done, total, part, parts, offset, object_size;
    double started, updated;
    unsigned int frame;
} display;

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void format_bytes(char *out, size_t capacity, double bytes) {
    const char *units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
    size_t unit = 0;
    while (bytes >= 1024.0 && unit < 4) {
        bytes /= 1024.0;
        unit++;
    }
    snprintf(out, capacity, "%.1f %s", bytes, units[unit]);
}

static void render_progress_locked(int force, int final_code) {
    if (!display.enabled || !display.active) return;
    double now = monotonic_seconds();
    if (!progress_active) {
        progress_active = 1;
        progress_started = now;
    }
    if (!force && now - display.updated < 0.1) return;
    display.updated = now;
    double elapsed = now - display.started;
    double speed = elapsed > 0.001 ? (double)display.done / elapsed : 0;
    uint64_t done = display.done;
    uint64_t total = display.total;
    int uploading = strcmp(display.label, "Uploading") == 0;
    if (current_object) {
        done = current_object->done;
        total = current_object->total;
        elapsed = now - current_object->started;
        speed = elapsed > 0.001 ? (double)(done - current_object->resumed) / elapsed : 0;
    } else if (uploading && display.part) {
        done += display.offset;
        total = display.object_size;
    }
    char transferred[32], size[32], rate[32], eta[32], line[256];
    format_bytes(transferred, sizeof(transferred), (double)done);
    format_bytes(size, sizeof(size), (double)total);
    format_bytes(rate, sizeof(rate), speed);
    snprintf(eta, sizeof(eta), "ETA --");
    if (speed > 0 && total > done) {
        /* Speed is measured for this attempt, never including resumed bytes. */
        snprintf(eta, sizeof(eta), "ETA %.0fs", (double)(total - done) / speed);
    }
    const char *label = display.label;
    if (current_object && current_part) label = "Uploading";
    if (final_code >= 0) label = final_code == 0 ? "Done" : final_code == 130 ? "Cancelled" : "Failed";
    else if (total && done >= total &&
             (uploading || strcmp(label, "Downloading") == 0)) label = "Waiting for server";
    char fraction[72];
    char bar[13] = "[----------]";
    if (total) {
        double percentage = (double)done * 100.0 / (double)total;
        if (percentage > 100.0) percentage = 100.0;
        size_t filled = (size_t)(percentage / 10.0);
        for (size_t i = 0; i < filled; i++) bar[i + 1] = '#';
        snprintf(fraction, sizeof(fraction), "%5.1f%% %s/%s", percentage, transferred, size);
    } else {
        bar[1 + display.frame % 10] = '=';
        snprintf(fraction, sizeof(fraction), "%s / ?", transferred);
    }
    snprintf(line, sizeof(line), "%c %s %s %s | %s/s | %.0fs %s",
             final_code >= 0 ? (final_code == 0 ? '+' : '!') : "|/-\\"[display.frame++ % 4],
             label, bar, fraction, rate, elapsed, eta);
    if (final_code >= 0) {
        char sent[32], received[32], average[32];
        double duration = now - progress_started;
        format_bytes(sent, sizeof(sent), (double)progress_uploaded);
        format_bytes(received, sizeof(received), (double)progress_downloaded);
        format_bytes(average, sizeof(average), duration > 0.001 ?
                     (double)(progress_uploaded + progress_downloaded) / duration : 0);
        snprintf(line, sizeof(line), "%c %s | sent %s | received %s | %.1fs | avg %s/s",
                 final_code == 0 ? '+' : '!', label, sent, received, duration, average);
    }
    struct winsize window;
    size_t columns = 120;
    if (ioctl(STDERR_FILENO, TIOCGWINSZ, &window) == 0 && window.ws_col > 1) columns = window.ws_col;
    if (columns > sizeof(line)) columns = sizeof(line);
    line[columns - 1] = '\0';
    size_t length = strlen(line);
    fputc('\r', stderr);
    if (display.color) fputs(final_code < 0 ? "\033[36m" : final_code == 0 ? "\033[32m" : "\033[31m", stderr);
    fputs(line, stderr);
    if (display.color) fputs("\033[0m", stderr);
    for (size_t i = length; i < progress_width && i < columns - 1; i++) fputc(' ', stderr);
    progress_width = length;
    if (final_code >= 0) fputc('\n', stderr);
    fflush(stderr);
}

static void render_progress(int force, int final_code) {
    pthread_mutex_lock(&progress_mutex);
    render_progress_locked(force, final_code);
    pthread_mutex_unlock(&progress_mutex);
}

void zc_progress_configure(int enabled, int color) {
    pthread_mutex_lock(&progress_mutex);
    memset(&display, 0, sizeof(display));
    progress_enabled = enabled && isatty(STDERR_FILENO);
    progress_color = color;
    progress_active = 0;
    progress_width = 0;
    progress_uploaded = 0;
    progress_downloaded = 0;
    pthread_mutex_unlock(&progress_mutex);
}
void zc_progress_stage(const char *label, uint64_t total) {
    if (!progress_enabled) return;
    display.enabled = progress_enabled;
    display.color = progress_color;
    display.label = label;
    display.total = total;
    display.done = 0;
    display.started = monotonic_seconds();
    display.active = 1;
    render_progress(1, -1);
}
void zc_progress_update(uint64_t done) {
    display.done = done;
    render_progress(0, -1);
}
void zc_progress_part(uint64_t number, uint64_t count, uint64_t offset, uint64_t total) {
    display.part = number;
    display.parts = count;
    display.offset = offset;
    display.object_size = total;
}
/* Context lives until every worker is joined; per-part maxima avoid double
 * counting a retried request and preserve a monotonic whole-object bar. */
void *zc_progress_object_begin(uint64_t total, uint64_t resumed, uint64_t parts) {
    if (!progress_enabled || parts > 10000) return NULL;
    struct object_progress *object = calloc(1, sizeof(*object));
    if (!object) return NULL;
    object->part_bytes = calloc((size_t)parts, sizeof(uint64_t));
    if (!object->part_bytes) {
        free(object);
        return NULL;
    }
    object->total = total;
    object->resumed = resumed;
    object->done = resumed;
    object->parts = parts;
    object->started = monotonic_seconds();
    current_object = object;
    current_part = 0;
    return object;
}
void zc_progress_object_attach(void *object, uint64_t part) {
    current_object = object;
    current_part = part;
}
void zc_progress_object_end(void *context) {
    struct object_progress *object = context;
    current_object = NULL;
    current_part = 0;
    if (object) {
        free(object->part_bytes);
        free(object);
    }
}

void zc_progress_finish(int code) {
    pthread_mutex_lock(&progress_mutex);
    display.enabled = progress_enabled;
    display.color = progress_color;
    display.active = progress_active;
    if (!display.label) display.label = "Request";
    render_progress_locked(1, code);
    display.active = 0;
    progress_active = 0;
    pthread_mutex_unlock(&progress_mutex);
}

static volatile sig_atomic_t interrupted = 0;
static struct sigaction prior_int;
void zc_bulk_begin(void) {
    interrupted = 0;
    sigaction(SIGINT, NULL, &prior_int);
}
static void on_interrupt(int signum) { (void)signum; interrupted = 1; }
void zc_bulk_listen(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_interrupt;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
}
void zc_bulk_end(void) { sigaction(SIGINT, &prior_int, NULL); interrupted = 0; }
int zc_interrupted(void) { return interrupted; }
static int progress(void *ctx, int64_t total_down, int64_t down, int64_t total_up, int64_t up) {
    (void)ctx;
    if (display.active) {
        if (strcmp(display.label, "Uploading") == 0) {
            if (total_up > 0) {
                display.total = (uint64_t)total_up;
            }
            display.done = up > 0 ? (uint64_t)up : 0;
            pthread_mutex_lock(&progress_mutex);
            if (current_object && current_part > 0 && current_part <= current_object->parts) {
                uint64_t *previous = &current_object->part_bytes[current_part - 1];
                if (display.done > *previous) {
                    current_object->done += display.done - *previous;
                    *previous = display.done;
                }
            }
            render_progress_locked(0, -1);
            pthread_mutex_unlock(&progress_mutex);
        } else if (strcmp(display.label, "Downloading") == 0) {
            if (total_down > 0) {
                display.total = (uint64_t)total_down;
            }
            zc_progress_update(down > 0 ? (uint64_t)down : 0);
        } else {
            render_progress(0, -1);
        }
    }
    return interrupted ? 1 : 0;
}
typedef size_t (*read_fn)(void *, unsigned char *, size_t);
typedef int (*write_fn)(void *, const unsigned char *, size_t);
int zc_http(const char *url, const char *method, const char **header_values,
    size_t header_count, const char *ca, int insecure, long connect_ms, long total_ms,
    int64_t rate_limit, int has_body, int64_t body_size, read_fn reader,
    write_fn writer, void *context, unsigned char *headers, size_t header_cap,
    size_t *header_len, unsigned char *body, size_t body_cap, size_t *body_len,
    long *status) {
    if (interrupted) return 42;
    int uploading = has_body && (strcmp(method, "PUT") == 0 || body_size > 65536);
    const char *phase = "Request";
    if (uploading) {
        phase = "Uploading";
    } else if (writer) {
        phase = "Downloading";
    } else if (strcmp(method, "POST") == 0 && strstr(url, "uploadId=")) {
        phase = "Completing upload";
    }
    zc_progress_stage(phase, uploading ? (uint64_t)body_size : 0);
    zc_transport_request request = {
        .url = url,
        .method = method,
        .headers = header_values,
        .header_count = header_count,
        .ca = ca,
        .insecure = insecure,
        .connect_ms = connect_ms,
        .timeout_ms = total_ms,
        .rate_limit = rate_limit,
        .has_body = has_body,
        .body_size = body_size,
        .read = reader,
        .write = writer,
        .progress = progress,
        .context = context,
        .response_headers = headers,
        .header_capacity = header_cap,
        .response_body = body,
        .body_capacity = body_cap,
    };
    int result = zc_native_http(&request);
    render_progress(1, -1);
    pthread_mutex_lock(&progress_mutex);
    if (uploading && request.uploaded > 0) {
        progress_uploaded += (uint64_t)request.uploaded;
    }
    if (writer && request.downloaded > 0) {
        progress_downloaded += (uint64_t)request.downloaded;
    }
    pthread_mutex_unlock(&progress_mutex);
    *header_len = request.header_length;
    *body_len = request.body_length;
    *status = request.status;
    return result;
}

/* POSIX extended regular expressions for find; never execute shell commands. */
#include <regex.h>
int zc_regex(const char *pattern, const char *value) {
    regex_t expression;
    if (regcomp(&expression, pattern, REG_EXTENDED | REG_NOSUB) != 0) return -1;
    int result = regexec(&expression, value, 0, NULL, 0);
    regfree(&expression);
    return result == 0 ? 1 : result == REG_NOMATCH ? 0 : -1;
}
