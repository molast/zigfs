#include "bridge.h"
#include <string.h>

struct payload {
    const unsigned char *data;
    size_t length;
};

static size_t read_payload(void *context, unsigned char *buffer, size_t capacity) {
    struct payload *payload = context;
    size_t count = payload->length < capacity ? payload->length : capacity;
    if (count) memcpy(buffer, payload->data, count);
    payload->data += count;
    payload->length -= count;
    return count;
}

int zigfs_kms_http(const char *url, const char *method, const char *body,
    const char *token, const char *ns, const char *ca, const char *cert,
    const char *key, int insecure, long timeout, char *buffer, size_t capacity,
    size_t *length, long *status) {
    const char *headers[] = {"Content-Type: application/json", token, ns};
    struct payload payload = {(const unsigned char *)body, body ? strlen(body) : 0};
    znet_request request = {
        .url = url,
        .method = method,
        .headers = headers,
        .header_count = 3,
        .ca = ca,
        .certificate = cert,
        .key = key,
        .insecure = insecure,
        .connect_ms = timeout * 1000,
        .timeout_ms = timeout * 1000,
        .has_body = body != NULL,
        .body_size = (int64_t)payload.length,
        .read = read_payload,
        .context = &payload,
        .response_body = (unsigned char *)buffer,
        .body_capacity = capacity,
    };
    int result = znet_http(&request);
    *length = request.body_length;
    *status = request.status;
    return result;
}
