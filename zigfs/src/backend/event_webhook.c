#include <curl/curl.h>
#include <string.h>
#include <pthread.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
struct response { char *data; size_t capacity, used; };
static size_t receive(char *data, size_t size, size_t count, void *context) {
    if (size && count > (size_t)-1 / size) return 0;
    size_t total = size * count;
    struct response *out = context;
    size_t copied = total < out->capacity - out->used ? total : out->capacity - out->used;
    memcpy(out->data + out->used, data, copied); out->used += copied;
    return total; /* Bound captured diagnostics without misclassifying a large successful response. */
}
int zigfs_event_webhook(const char *url, const char *body, size_t body_length,
    const char *authorization, const char *event_header, const char *ca,
    const char *certificate, const char *key, int insecure, long timeout,
    char *buffer, size_t capacity, size_t *length, long *status) {
    pthread_once(&once, initialize);
    CURL *client = curl_easy_init();
    if (!client) return CURLE_OUT_OF_MEMORY;
    struct curl_slist *headers = NULL;
    struct response out = {buffer, capacity, 0};
    const char *values[] = {"Content-Type: application/json", "Expect:", authorization, event_header};
    for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
        if (!*values[i]) continue;
        struct curl_slist *next = curl_slist_append(headers, values[i]);
        if (!next) { curl_slist_free_all(headers); curl_easy_cleanup(client); return CURLE_OUT_OF_MEMORY; }
        headers = next;
    }
    curl_easy_setopt(client, CURLOPT_URL, url);
    curl_easy_setopt(client, CURLOPT_POST, 1L);
    curl_easy_setopt(client, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(client, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
    curl_easy_setopt(client, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(client, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(client, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(client, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(client, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(client, CURLOPT_CONNECTTIMEOUT, timeout);
    curl_easy_setopt(client, CURLOPT_SSL_VERIFYPEER, insecure ? 0L : 1L);
    curl_easy_setopt(client, CURLOPT_SSL_VERIFYHOST, insecure ? 0L : 2L);
    if (*ca) curl_easy_setopt(client, CURLOPT_CAINFO, ca);
    if (*certificate) curl_easy_setopt(client, CURLOPT_SSLCERT, certificate);
    if (*key) curl_easy_setopt(client, CURLOPT_SSLKEY, key);
    curl_easy_setopt(client, CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(client, CURLOPT_WRITEDATA, &out);
    CURLcode result = curl_easy_perform(client);
    curl_easy_getinfo(client, CURLINFO_RESPONSE_CODE, status);
    *length = out.used;
    curl_slist_free_all(headers); curl_easy_cleanup(client);
    return result;
}
