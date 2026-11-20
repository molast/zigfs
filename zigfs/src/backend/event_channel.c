#include "bridge.h"
#include <stdlib.h>

/* This allocation owns a language-neutral handle, never a Go pointer. */
struct channel {
    uintptr_t handle;
};

int zigfs_event_channel_open(const char *url, const char *ca, const char *cert,
    const char *key, int policy, int trust_leaf, long timeout, void **out) {
    *out = NULL;
    struct channel *channel = calloc(1, sizeof(*channel));
    if (!channel) return 27;
    int result = 0;
    channel->handle = znet_open((char *)url, (char *)ca, (char *)cert, (char *)key,
                               policy, trust_leaf, timeout, &result);
    if (result != 0) {
        free(channel);
        return result;
    }
    *out = channel;
    return 0;
}

int zigfs_event_channel_read(void *context, char *buffer, size_t length, size_t *used) {
    struct channel *channel = context;
    return znet_read(channel->handle, buffer, length, used);
}

int zigfs_event_channel_write(void *context, const char *data, size_t length) {
    struct channel *channel = context;
    return znet_write(channel->handle, (void *)data, length);
}

void zigfs_event_channel_close(void *context) {
    struct channel *channel = context;
    znet_close(channel->handle);
    free(channel);
}
