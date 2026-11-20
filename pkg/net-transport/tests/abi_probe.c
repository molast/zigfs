#include "bridge.h"

/* Link/run smoke test for the public C ABI and native TLS linkage. */
int main(void) {
    znet_request request = {0};
    if (znet_http(&request) != 3) return 1;
    int result = 0;
    uintptr_t handle = znet_open("https://localhost", "", "", "", 0, 0, 0, &result);
    if (handle != 0 || result != 3) return 2;
    return 0;
}
