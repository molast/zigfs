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

int zigfs_event_webhook(const char *url, const char *body, size_t body_length,
    const char *authorization, const char *event_header, const char *ca,
    const char *certificate, const char *key, int insecure, long timeout,
    char *buffer, size_t capacity, size_t *length, long *status) {
    const char *headers[] = {"Content-Type: application/json", authorization, event_header};
    struct payload payload = {(const unsigned char *)body, body_length};
    znet_request request = {
        .url = url,
        .method = "POST",
        .headers = headers,
        .header_count = 3,
        .ca = ca,
        .certificate = certificate,
        .key = key,
        .insecure = insecure,
        .connect_ms = timeout * 1000,
        .timeout_ms = timeout * 1000,
        .has_body = 1,
        .body_size = (int64_t)body_length,
        .read = read_payload,
        .context = &payload,
        .response_body = (unsigned char *)buffer,
        .body_capacity = capacity,
        // Keep bounded diagnostics without rejecting large successful responses.
        .truncate_response = 1,
    };
    int result = znet_http(&request);
    *length = request.body_length;
    *status = request.status;
    return result;
}
