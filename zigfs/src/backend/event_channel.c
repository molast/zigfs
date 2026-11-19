#define _POSIX_C_SOURCE 200809L
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#endif
#include <curl/curl.h>
#include <stdlib.h>
#ifdef _WIN32
#define CHANNEL_POLL_IN POLLRDNORM
#define CHANNEL_POLL_OUT POLLWRNORM
static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK initialize(PINIT_ONCE ignored, PVOID parameter, PVOID *context) {
    (void)ignored;
    (void)parameter;
    (void)context;
    return curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
}
static long long now_ms(void) {
    return (long long)GetTickCount64();
}
#else
#include <poll.h>
#include <pthread.h>
#include <time.h>
#define CHANNEL_POLL_IN POLLIN
#define CHANNEL_POLL_OUT POLLOUT
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
static long long now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000; }
#endif

struct channel { CURL *curl; long long deadline; };
int zigfs_event_channel_open(const char *url, const char *ca, const char *cert, const char *key,
    int policy, int trust_leaf, long timeout, void **out) {
    *out = NULL;
#ifdef _WIN32
    if (!InitOnceExecuteOnce(&once, initialize, NULL, NULL)) return CURLE_FAILED_INIT;
#else
    pthread_once(&once, initialize);
#endif
    struct channel *channel = calloc(1, sizeof(*channel));
    if (!channel) return CURLE_OUT_OF_MEMORY;
    channel->curl = curl_easy_init();
    if (!channel->curl) { free(channel); return CURLE_OUT_OF_MEMORY; }
    channel->deadline = now_ms() + timeout * 1000;
    CURL *c = channel->curl;
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_PROTOCOLS_STR, "http,https");
    curl_easy_setopt(c, CURLOPT_CONNECT_ONLY, 1L);
    curl_easy_setopt(c, CURLOPT_PROXY, "");
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, timeout);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, policy == 2 ? 0L : 1L);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYHOST, policy == 2 ? 0L : 2L);
    if (policy == 0) curl_easy_setopt(c, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    curl_easy_setopt(c, CURLOPT_SSL_OPTIONS, trust_leaf ? 0L : (long)CURLSSLOPT_NO_PARTIALCHAIN);
    if (*ca) curl_easy_setopt(c, CURLOPT_CAINFO, ca);
    if (*cert) curl_easy_setopt(c, CURLOPT_SSLCERT, cert);
    if (*key) curl_easy_setopt(c, CURLOPT_SSLKEY, key);
    CURLcode result = curl_easy_perform(c);
    if (result) { curl_easy_cleanup(c); free(channel); return result; }
    *out = channel; return CURLE_OK;
}
static int wait_ready(struct channel *c, short events) {
    long long remaining = c->deadline - now_ms();
    if (remaining <= 0) return CURLE_OPERATION_TIMEDOUT;
    curl_socket_t socket;
    CURLcode result = curl_easy_getinfo(c->curl, CURLINFO_ACTIVESOCKET, &socket);
    if (result) return result;
#ifdef _WIN32
    WSAPOLLFD fd = {socket, events, 0};
    int rc = WSAPoll(&fd, 1, (int)remaining);
#else
    struct pollfd fd = {(int)socket, events, 0};
    int rc = poll(&fd, 1, (int)remaining);
#endif
    if (rc == 0) return CURLE_OPERATION_TIMEDOUT;
    if (rc < 0) return CURLE_RECV_ERROR;
    return CURLE_OK;
}
int zigfs_event_channel_read(void *ctx, char *buffer, size_t length, size_t *used) {
    struct channel *c = ctx;
    for (;;) {
        if (now_ms() >= c->deadline) return CURLE_OPERATION_TIMEDOUT;
        CURLcode result = curl_easy_recv(c->curl, buffer, length, used);
        if (result != CURLE_AGAIN) return result ? result : (*used ? CURLE_OK : CURLE_GOT_NOTHING);
        int rc = wait_ready(c, CHANNEL_POLL_IN);
        if (rc) return rc;
    }
}
int zigfs_event_channel_write(void *ctx, const char *data, size_t length) {
    struct channel *c = ctx;
    size_t offset = 0;
    while (offset < length) {
        if (now_ms() >= c->deadline) return CURLE_OPERATION_TIMEDOUT;
        size_t sent = 0;
        CURLcode result = curl_easy_send(c->curl, data + offset, length - offset, &sent);
        if (result == CURLE_AGAIN) {
            int rc = wait_ready(c, CHANNEL_POLL_OUT);
            if (rc) return rc;
            continue;
        }
        if (result) return result;
        if (!sent) return CURLE_SEND_ERROR;
        offset += sent;
    }
    return CURLE_OK;
}
void zigfs_event_channel_close(void *ctx) {
    struct channel *c = ctx;
    curl_easy_cleanup(c->curl); free(c);
}
