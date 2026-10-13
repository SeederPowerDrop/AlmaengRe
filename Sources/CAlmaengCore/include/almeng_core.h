#ifndef ALMENG_CORE_H
#define ALMENG_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
// A returned allocation must be released exactly once by am_buffer_free.
// Input memory is borrowed only for the duration of the call. No callback/thread owns it.
typedef struct { uint8_t *ptr; size_t len; } AmBuffer;
typedef struct { AmBuffer pixels; AmBuffer error; uint32_t width; uint32_t height; uint32_t linear; } AmRaster;
AmBuffer am_engine_json(const uint8_t *input, size_t len);
AmRaster am_decode(const uint8_t *input, size_t len, uint32_t format);
void am_buffer_free(AmBuffer buffer);
int64_t am_decode_concurrency(uint64_t memory, int64_t cores, bool apple);
uint64_t am_render_cache_bytes(uint64_t memory);
int64_t am_pixel_bucket(int64_t value);
int64_t am_maximum_tile_pixels(int64_t count, uint64_t memory);
int64_t am_requested_pixels(double width, double height, double scale, double zoom, bool actual, int64_t count, uint64_t memory);
int64_t am_preview_pixels(int64_t value);
#endif
