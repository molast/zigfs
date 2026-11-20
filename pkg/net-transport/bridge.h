#ifndef ZIGFS_NET_TRANSPORT_H
#define ZIGFS_NET_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>

/* Callbacks execute synchronously on the calling OS thread. All buffers and
 * callback contexts are borrowed for the duration of znet_http only.
 * Error codes retain the existing application transport ABI: 3 configuration,
 * 6 DNS, 7 connection, 18 truncated, 28 timeout, 35 TLS, 42 cancelled,
 * 60 certificate, -2 response/callback bounds. No provider diagnostics escape. */
typedef size_t (*znet_read_fn)(void *, unsigned char *, size_t);
typedef int (*znet_write_fn)(void *, const unsigned char *, size_t);
typedef int (*znet_progress_fn)(void *, int64_t, int64_t, int64_t, int64_t);
typedef struct {
    const char *url, *method;
    const char **headers;
    size_t header_count;
    const char *ca, *certificate, *key;
    int insecure, has_body, truncate_response;
    int64_t connect_ms, timeout_ms, rate_limit, body_size;
    znet_read_fn read;
    znet_write_fn write;
    znet_progress_fn progress;
    void *context;
    unsigned char *response_headers, *response_body;
    size_t header_capacity, body_capacity, header_length, body_length;
    int64_t uploaded, downloaded;
    long status;
} znet_request;

int znet_http(znet_request *request);
uintptr_t znet_open(char *url, char *ca, char *cert, char *key,
                    int policy, int trust_leaf, long timeout, int *result);
int znet_read(uintptr_t handle, void *buffer, size_t capacity, size_t *used);
int znet_write(uintptr_t handle, void *buffer, size_t length);
void znet_close(uintptr_t handle);

static inline size_t znet_call_read(znet_request *r, unsigned char *p, size_t n) {
    return r->read(r->context, p, n);
}
static inline int znet_call_write(znet_request *r, unsigned char *p, size_t n) {
    return r->write(r->context, p, n);
}
static inline int znet_call_progress(znet_request *r, int64_t total) {
    return r->progress ? r->progress(r->context, total, r->downloaded,
                                    r->body_size, r->uploaded) : 0;
}
#endif
