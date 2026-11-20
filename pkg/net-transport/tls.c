/* TLS only: sockets, HTTP framing, deadlines and buffer ownership live in Zig. */
#include <stdlib.h>
#include <string.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/threading.h>
#include <psa/crypto.h>

extern int znet_socket_read(void *, unsigned char *, size_t);
extern int znet_socket_write(void *, const unsigned char *, size_t);

static void mutex_init(mbedtls_threading_mutex_t *mutex) {
#ifdef _WIN32
    InitializeCriticalSection(&mutex->native);
    mutex->initialized = 1;
#else
    mutex->initialized = pthread_mutex_init(&mutex->native, NULL) == 0;
#endif
}
static void mutex_free(mbedtls_threading_mutex_t *mutex) {
    if (!mutex->initialized) return;
#ifdef _WIN32
    DeleteCriticalSection(&mutex->native);
#else
    pthread_mutex_destroy(&mutex->native);
#endif
    mutex->initialized = 0;
}
static int mutex_lock(mbedtls_threading_mutex_t *mutex) {
    if (!mutex->initialized) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
#ifdef _WIN32
    EnterCriticalSection(&mutex->native);
    return 0;
#else
    return pthread_mutex_lock(&mutex->native);
#endif
}
static int mutex_unlock(mbedtls_threading_mutex_t *mutex) {
    if (!mutex->initialized) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
#ifdef _WIN32
    LeaveCriticalSection(&mutex->native);
    return 0;
#else
    return pthread_mutex_unlock(&mutex->native);
#endif
}
/* Called exactly once before concurrent connections are permitted. */
int ztls_init(void) {
    mbedtls_threading_set_alt(mutex_init, mutex_free, mutex_lock, mutex_unlock);
    return psa_crypto_init() == PSA_SUCCESS ? 0 : 35;
}
struct ztls {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config config;
    mbedtls_x509_crt roots, certificate;
    mbedtls_pk_context key;
    mbedtls_ctr_drbg_context random;
    mbedtls_entropy_context entropy;
};
void ztls_free(struct ztls *tls) {
    if (!tls) return;
    mbedtls_ssl_free(&tls->ssl);
    mbedtls_ssl_config_free(&tls->config);
    mbedtls_x509_crt_free(&tls->roots);
    mbedtls_x509_crt_free(&tls->certificate);
    mbedtls_pk_free(&tls->key);
    mbedtls_ctr_drbg_free(&tls->random);
    mbedtls_entropy_free(&tls->entropy);
    free(tls);
}
static int receive(void *context, unsigned char *buffer, size_t capacity) {
    int result = znet_socket_read(context, buffer, capacity);
    return result < 0 ? MBEDTLS_ERR_SSL_INTERNAL_ERROR : result;
}
static int send_bytes(void *context, const unsigned char *buffer, size_t length) {
    int result = znet_socket_write(context, buffer, length);
    return result < 0 ? MBEDTLS_ERR_SSL_INTERNAL_ERROR : result;
}
/* Explicit leaf pins may replace issuer trust, but never hostname, validity,
 * key usage or signature-algorithm checks. Require byte-identical certificates. */
static int verify_pinned_leaf(void *context, mbedtls_x509_crt *certificate,
                              int depth, uint32_t *flags) {
    if (depth != 0) return 0;
    struct ztls *tls = context;
    for (mbedtls_x509_crt *root = &tls->roots; root; root = root->next) {
        if (root->raw.len == certificate->raw.len &&
            memcmp(root->raw.p, certificate->raw.p, root->raw.len) == 0) {
            *flags &= ~MBEDTLS_X509_BADCERT_NOT_TRUSTED;
            break;
        }
    }
    return 0;
}

struct ztls *ztls_new(void *connection, const char *hostname,
    const unsigned char *roots, size_t roots_len, const char *certificate,
    const char *key, int insecure, int require_ca, int *result) {
    *result = 35;
    struct ztls *tls = calloc(1, sizeof(*tls));
    if (!tls) return NULL;
    mbedtls_ssl_init(&tls->ssl);
    mbedtls_ssl_config_init(&tls->config);
    mbedtls_x509_crt_init(&tls->roots);
    mbedtls_x509_crt_init(&tls->certificate);
    mbedtls_pk_init(&tls->key);
    mbedtls_ctr_drbg_init(&tls->random);
    mbedtls_entropy_init(&tls->entropy);
    if (mbedtls_ctr_drbg_seed(&tls->random, mbedtls_entropy_func, &tls->entropy,
                             (const unsigned char *)"zigfs", 5) != 0) goto fail;
    if (mbedtls_ssl_config_defaults(&tls->config, MBEDTLS_SSL_IS_CLIENT,
        MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) goto fail;
    mbedtls_ssl_conf_min_tls_version(&tls->config, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_rng(&tls->config, mbedtls_ctr_drbg_random, &tls->random);
    *result = 60;
    if (roots_len) {
        /* DER roots are supplied one at a time through a length-prefixed bundle. */
        size_t offset = 0;
        while (offset < roots_len) {
            if (roots_len - offset < 4) goto fail;
            size_t size = ((size_t)roots[offset] << 24) | ((size_t)roots[offset + 1] << 16) |
                          ((size_t)roots[offset + 2] << 8) | roots[offset + 3];
            offset += 4;
            if (size > roots_len - offset) goto fail;
            if (mbedtls_x509_crt_parse_der(&tls->roots, roots + offset, size) != 0) goto fail;
            offset += size;
        }
        if (require_ca) {
            for (mbedtls_x509_crt *root = &tls->roots; root; root = root->next) {
                if (!root->MBEDTLS_PRIVATE(ca_istrue)) goto fail;
            }
        }
    }
    if (!insecure && !tls->roots.raw.p) goto fail;
    if (*certificate || *key) {
        if (!*certificate || !*key) goto fail;
        if (mbedtls_x509_crt_parse(&tls->certificate,
            (const unsigned char *)certificate, strlen(certificate) + 1) != 0) goto fail;
        if (mbedtls_pk_parse_key(&tls->key, (const unsigned char *)key,
            strlen(key) + 1, NULL, 0, mbedtls_ctr_drbg_random, &tls->random) != 0) goto fail;
        if (mbedtls_pk_check_pair(&tls->certificate.pk, &tls->key,
                                  mbedtls_ctr_drbg_random, &tls->random) != 0) goto fail;
        if (mbedtls_ssl_conf_own_cert(&tls->config, &tls->certificate, &tls->key) != 0) goto fail;
    }
    mbedtls_ssl_conf_ca_chain(&tls->config, &tls->roots, NULL);
    if (!require_ca) mbedtls_ssl_conf_verify(&tls->config, verify_pinned_leaf, tls);
    mbedtls_ssl_conf_authmode(&tls->config, insecure ? MBEDTLS_SSL_VERIFY_NONE : MBEDTLS_SSL_VERIFY_REQUIRED);
    *result = 35;
    if (mbedtls_ssl_setup(&tls->ssl, &tls->config) != 0) goto fail;
    /* SNI remains enabled even when the caller disables certificate validation. */
    if (mbedtls_ssl_set_hostname(&tls->ssl, hostname) != 0) goto fail;
    mbedtls_ssl_set_bio(&tls->ssl, connection, send_bytes, receive, NULL);
    int code = mbedtls_ssl_handshake(&tls->ssl);
    if (code != 0) {
        if (mbedtls_ssl_get_verify_result(&tls->ssl) != 0) *result = 60;
        goto fail;
    }
    *result = 0;
    return tls;
fail:
    ztls_free(tls);
    return NULL;
}
int ztls_read(struct ztls *tls, unsigned char *buffer, size_t capacity) {
    int result = mbedtls_ssl_read(&tls->ssl, buffer, capacity);
    if (result == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
    return result;
}
int ztls_write(struct ztls *tls, const unsigned char *buffer, size_t length) {
    return mbedtls_ssl_write(&tls->ssl, buffer, length);
}
