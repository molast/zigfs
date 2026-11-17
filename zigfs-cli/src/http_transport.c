#define _POSIX_C_SOURCE 200809L
/* Transport only. Signing, validation and output policy stay in Zig. */
#include <curl/curl.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int init_result;
static void init_curl(void) { init_result = curl_global_init(CURL_GLOBAL_DEFAULT); }

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
    (void)ctx; (void)total_down; (void)down; (void)total_up; (void)up;
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
    CURL *c = curl_easy_init(); if (!c) return -1;
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
    result = (int)curl_easy_perform(c);
    if (r.overflow) result = -2;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, status);
cleanup:
    *header_len = r.header_len; *body_len = r.body_len;
    curl_slist_free_all(list);
    curl_easy_cleanup(c);
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
