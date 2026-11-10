#include <curl/curl.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK init_curl(PINIT_ONCE ignored, PVOID param, PVOID *context) {
    (void)ignored; (void)param; (void)context;
    return curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
}
#else
#include <pthread.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void init_curl(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
#endif
struct output { char *data; size_t used, capacity; };
static size_t receive(char *ptr, size_t size, size_t count, void *ctx) {
    struct output *out = ctx;
    if (size && count > (out->capacity - out->used) / size) return 0;
    size_t n = size * count;
    memcpy(out->data + out->used, ptr, n); out->used += n; return n;
}
int zigfs_kms_http(const char *url, const char *method, const char *body, const char *token, const char *ns,
    const char *ca, const char *cert, const char *key, int insecure, long timeout,
    char *buffer, size_t capacity, size_t *length, long *status) {
#ifdef _WIN32
    if (!InitOnceExecuteOnce(&once, init_curl, NULL, NULL)) return -1;
#else
    pthread_once(&once, init_curl);
#endif
    CURL *c = curl_easy_init(); if (!c) return -1;
    struct output out = {buffer, 0, capacity};
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, token);
    if (*ns) headers = curl_slist_append(headers, ns);
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, insecure ? 0L : 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, insecure ? 0L : 2L);
    if (*ca) curl_easy_setopt(c, CURLOPT_CAINFO, ca);
    if (*cert) curl_easy_setopt(c, CURLOPT_SSLCERT, cert);
    if (*key) curl_easy_setopt(c, CURLOPT_SSLKEY, key);
    if (body) curl_easy_setopt(c, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, receive);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
    CURLcode result = curl_easy_perform(c);
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, status);
    *length = out.used;
    curl_slist_free_all(headers); curl_easy_cleanup(c);
    return (int)result;
}
