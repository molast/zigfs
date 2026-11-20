#include "bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

static int cancel_request(void *context, int64_t total_down, int64_t downloaded,
                          int64_t total_up, int64_t uploaded) {
    (void)context;
    (void)total_down;
    (void)downloaded;
    (void)total_up;
    (void)uploaded;
    return 1;
}

static void run_requests(char **argv, int rounds) {
    for (int index = 0; index < rounds; index++) {
        unsigned char body[256], headers[4096];
        znet_request request = {
            .url = argv[1], .method = "GET", .ca = argv[2],
            .certificate = argv[3], .key = argv[4], .insecure = atoi(argv[5]),
            .connect_ms = atol(argv[6]), .timeout_ms = atol(argv[6]),
            .response_body = body, .body_capacity = sizeof(body),
            .response_headers = headers, .header_capacity = sizeof(headers),
            .truncate_response = atoi(argv[8]),
            .progress = atoi(argv[9]) ? cancel_request : NULL,
        };
        int result = znet_http(&request);
        printf("%d %ld %zu\n", result, request.status, request.body_length);
    }
}

#ifdef _WIN32
static DWORD WINAPI worker(void *arguments) {
    run_requests(arguments, 2);
    return 0;
}
#else
static void *worker(void *arguments) {
    run_requests(arguments, 2);
    return NULL;
}
#endif

/* URL CA CERT KEY INSECURE TIMEOUT_MS ROUNDS TRUNCATE CANCEL.
 * ROUNDS=0 starts four threads to exercise shared TLS initialization and pools. */
int main(int argc, char **argv) {
    if (argc != 10) return 2;
    int rounds = atoi(argv[7]);
    if (rounds < 0 || rounds > 8) return 2;
    if (rounds != 0) {
        run_requests(argv, rounds);
        return 0;
    }
#ifdef _WIN32
    HANDLE threads[4];
    for (int index = 0; index < 4; index++) {
        threads[index] = CreateThread(NULL, 0, worker, argv, 0, NULL);
        if (!threads[index]) return 2;
    }
    WaitForMultipleObjects(4, threads, TRUE, INFINITE);
    for (int index = 0; index < 4; index++) CloseHandle(threads[index]);
#else
    pthread_t threads[4];
    for (int index = 0; index < 4; index++) {
        if (pthread_create(&threads[index], NULL, worker, argv) != 0) return 2;
    }
    for (int index = 0; index < 4; index++) pthread_join(threads[index], NULL);
#endif
    return 0;
}
