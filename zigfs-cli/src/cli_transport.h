#ifndef ZC_NATIVE_TRANSPORT_H
#define ZC_NATIVE_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>

/* Callbacks execute synchronously on the calling OS thread. All buffers and
 * callback contexts are borrowed for the duration of zc_native_http only.
 * Error codes retain the existing application transport ABI: 3 configuration,
 * 6 DNS, 7 connection, 18 truncated, 28 timeout, 35 TLS, 42 cancelled,
 * 60 certificate, -2 response/callback bounds. No provider diagnostics escape. */
typedef size_t (*zc_transport_read_fn)(void *, unsigned char *, size_t);
typedef int (*zc_transport_write_fn)(void *, const unsigned char *, size_t);
typedef int (*zc_transport_progress_fn)(void *, int64_t, int64_t, int64_t, int64_t);
typedef struct {
    const char *url, *method;
    const char **headers;
    size_t header_count;
    const char *ca;
    int insecure, has_body;
    int64_t connect_ms, timeout_ms, rate_limit, body_size;
    zc_transport_read_fn read;
    zc_transport_write_fn write;
    zc_transport_progress_fn progress;
    void *context;
    unsigned char *response_headers, *response_body;
    size_t header_capacity, body_capacity, header_length, body_length;
    int64_t uploaded, downloaded;
    long status;
} zc_transport_request;

int zc_native_http(zc_transport_request *request);

#endif
