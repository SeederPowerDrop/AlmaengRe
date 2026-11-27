#ifndef ALMENG_CORE_H
#define ALMENG_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
// A returned allocation must be released exactly once by am_buffer_free.
// Input memory is borrowed only for the duration of the call. No callback/thread owns it.
typedef struct { uint8_t *ptr; size_t len; } AmBuffer;
typedef struct { AmBuffer pixels; AmBuffer error; uint32_t width; uint32_t height; uint32_t linear; } AmRaster;
// Query inputs are borrowed during the call. Strings are UTF-8 spans into a
// single arena; offset SIZE_MAX with length zero denotes an absent string.
typedef struct { size_t offset; size_t len; } AmQueryString;
typedef struct {
  AmQueryString path, name, camera_make, camera_model, color_space;
  int64_t size, pixel_width, pixel_height;
  double modified, created, latitude, longitude, captured, exposure_time, aperture;
  uint32_t present;
} AmQueryRecord;
// Present bits: size=1, modified=2, created=4, latitude=8, longitude=16,
// width=32, height=64, captured=128, exposure=256, aperture=512.
typedef struct { size_t *ptr; size_t len; AmBuffer error; } AmQueryIndices;
AmQueryIndices am_query_records(const AmQueryRecord *records, size_t count,
  const uint8_t *strings, size_t strings_len, const uint8_t *options, size_t options_len);
void am_query_indices_free(AmQueryIndices result);
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
