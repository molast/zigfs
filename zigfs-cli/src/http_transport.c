#define _POSIX_C_SOURCE 200809L
/* HTTP transport and terminal rendering. Zig controls signing and output policy. */
#include <curl/curl.h>
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

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int init_result;
static pthread_mutex_t pool_mutex = PTHREAD_MUTEX_INITIALIZER;
static CURL *connection_pool[32];
static size_t pool_count;

static void close_connection_pool(void) {
    for (size_t i = 0; i < pool_count; i++) curl_easy_cleanup(connection_pool[i]);
}
static void init_curl(void) {
    init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (init_result == CURLE_OK) atexit(close_connection_pool);
}
static CURL *acquire_connection(void) {
    pthread_mutex_lock(&pool_mutex);
    CURL *connection = pool_count ? connection_pool[--pool_count] : NULL;
    pthread_mutex_unlock(&pool_mutex);
    return connection ? connection : curl_easy_init();
}
static void release_connection(CURL *connection) {
    /* Reset request-specific headers, callbacks, credentials and TLS options. */
    curl_easy_reset(connection);
    pthread_mutex_lock(&pool_mutex);
    if (pool_count < sizeof(connection_pool) / sizeof(connection_pool[0])) {
        connection_pool[pool_count++] = connection;
        connection = NULL;
    }
    pthread_mutex_unlock(&pool_mutex);
    if (connection) curl_easy_cleanup(connection);
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
static int progress(void *ctx, curl_off_t total_down, curl_off_t down, curl_off_t total_up, curl_off_t up) {
    (void)ctx;
    if (display.active) {
        if (strcmp(display.label, "Uploading") == 0) {
            if (total_up > 0) display.total = (uint64_t)total_up;
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
            if (total_down > 0) display.total = (uint64_t)total_down;
            zc_progress_update(down > 0 ? (uint64_t)down : 0);
        } else render_progress(0, -1);
    }
    return interrupted ? 1 : 0;
}
typedef size_t (*read_fn)(void *, unsigned char *, size_t);
typedef int (*write_fn)(void *, const unsigned char *, size_t);
struct response {
    CURL *curl;
    unsigned char *headers, *body;
    size_t header_cap, header_len, body_cap, body_len;
    void *context;
    read_fn read;
    write_fn write;
    int overflow;
};
static size_t read_body(char *p, size_t size, size_t count, void *opaque) {
    struct response *r = opaque;
    if (size && count > SIZE_MAX / size) return CURL_READFUNC_ABORT;
    size_t n = r->read(r->context, (unsigned char *)p, size * count);
    return n == SIZE_MAX ? CURL_READFUNC_ABORT : n;
}
static size_t receive_header(char *p, size_t size, size_t count, void *opaque) {
    struct response *r = opaque;
    if (size && count > (r->header_cap - r->header_len) / size) { r->overflow = 1; return 0; }
    size_t n = size * count;
    memcpy(r->headers + r->header_len, p, n); r->header_len += n;
    return n;
}
static size_t receive_body(char *p, size_t size, size_t count, void *opaque) {
    struct response *r = opaque;
    if (size && count > SIZE_MAX / size) return 0;
    size_t n = size * count;
    long status = 0;
    curl_easy_getinfo(r->curl, CURLINFO_RESPONSE_CODE, &status);
    if (status >= 200 && status < 300 && r->write)
        return r->write(r->context, (const unsigned char *)p, n) ? 0 : n;
    if (n > r->body_cap - r->body_len) { r->overflow = 1; return 0; }
    memcpy(r->body + r->body_len, p, n); r->body_len += n;
    return n;
}
int zc_http(const char *url, const char *method, const char **header_values, size_t header_count,
    const char *ca, int insecure, long connect_ms, long total_ms,
    int64_t rate_limit, int has_body, int64_t body_size, read_fn reader, write_fn writer, void *context,
    unsigned char *headers, size_t header_cap, size_t *header_len,
    unsigned char *body, size_t body_cap, size_t *body_len, long *status) {
    if (interrupted) return 42;
    pthread_once(&once, init_curl);
    if (init_result != CURLE_OK) return -1;
    CURL *c = acquire_connection();
    if (!c) return -1;
    struct response r = { .curl=c, .headers=headers, .header_cap=header_cap,
        .body=body, .body_cap=body_cap, .context=context, .read=reader, .write=writer };
    struct curl_slist *list = NULL;
    int result = 0;
    for (size_t i = 0; i < header_count; ++i) {
        struct curl_slist *next = curl_slist_append(list, header_values[i]);
        if (!next) { result = -1; goto cleanup; }
        list = next;
    }
#define SET(option, value) do { CURLcode e = curl_easy_setopt(c, option, value); if (e != CURLE_OK) { result = e; goto cleanup; } } while (0)
    SET(CURLOPT_URL, url);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, progress);
    if (rate_limit > 0) {
        SET(CURLOPT_MAX_SEND_SPEED_LARGE, (curl_off_t)rate_limit);
        SET(CURLOPT_MAX_RECV_SPEED_LARGE, (curl_off_t)rate_limit);
    }
    SET(CURLOPT_PROTOCOLS_STR, "http,https");
    SET(CURLOPT_PROXY, ""); /* Do not silently route credentials through ambient proxies. */
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_PATH_AS_IS, 1L); /* S3 keys must not undergo dot-segment normalization. */
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS, connect_ms);
    SET(CURLOPT_TIMEOUT_MS, total_ms);
    SET(CURLOPT_SSL_VERIFYPEER, insecure ? 0L : 1L);
    SET(CURLOPT_SSL_VERIFYHOST, insecure ? 0L : 2L);
    if (*ca) SET(CURLOPT_CAINFO, ca);
    SET(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_HTTPHEADER, list);
    SET(CURLOPT_HEADERFUNCTION, receive_header);
    SET(CURLOPT_HEADERDATA, &r);
    SET(CURLOPT_WRITEFUNCTION, receive_body);
    SET(CURLOPT_WRITEDATA, &r);
    if (has_body) {
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)body_size);
        SET(CURLOPT_READFUNCTION, read_body);
        SET(CURLOPT_READDATA, &r);
    }
    if (strcmp(method, "HEAD") == 0) SET(CURLOPT_NOBODY, 1L);
    SET(CURLOPT_CUSTOMREQUEST, method);
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
    result = (int)curl_easy_perform(c);
    render_progress(1, -1);
    curl_off_t sent = 0, received = 0;
    curl_easy_getinfo(c, CURLINFO_SIZE_UPLOAD_T, &sent);
    curl_easy_getinfo(c, CURLINFO_SIZE_DOWNLOAD_T, &received);
    pthread_mutex_lock(&progress_mutex);
    if (uploading && sent > 0) progress_uploaded += (uint64_t)sent;
    if (writer && received > 0) progress_downloaded += (uint64_t)received;
    pthread_mutex_unlock(&progress_mutex);
    if (r.overflow) result = -2;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, status);
cleanup:
    *header_len = r.header_len; *body_len = r.body_len;
    curl_slist_free_all(list);
    release_connection(c);
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
