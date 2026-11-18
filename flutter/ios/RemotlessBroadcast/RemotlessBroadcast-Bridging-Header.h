// Remotless: C entry points of the Rust library (src/ios_broadcast.rs) used by the
// screen-sharing broadcast extension.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*RemotlessEventCallback)(const char *event);

int32_t remotless_bc_start(const char *dir, const char *share_json,
                           RemotlessEventCallback callback);
void remotless_bc_push_frame(const uint8_t *data, size_t len, uint32_t width,
                             uint32_t height, uint32_t stride);
void remotless_bc_authorize(int32_t conn_id, bool accept);
void remotless_bc_disconnect_all(void);
void remotless_bc_stop(void);
