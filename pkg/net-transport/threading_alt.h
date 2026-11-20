#ifndef ZIGFS_TLS_THREADING_ALT_H
#define ZIGFS_TLS_THREADING_ALT_H

#ifdef _WIN32
#include <windows.h>
typedef struct {
    CRITICAL_SECTION native;
    int initialized;
} mbedtls_threading_mutex_t;
#else
#include <pthread.h>
typedef struct {
    pthread_mutex_t native;
    int initialized;
} mbedtls_threading_mutex_t;
#endif

#endif
