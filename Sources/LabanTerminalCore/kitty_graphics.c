#include "session_internal.h"
#include <Accelerate/Accelerate.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdatomic.h>

/* Kitty graphics protocol support (execplans/active/kitty-graphics-rendering.md).
 *
 * libghostty-vt parses the protocol, stores images, tracks placements and
 * answers queries. This file enables it per session behind a process-wide
 * gate, installs the PNG decoder libghostty needs, flattens visible
 * placements into owned LabanImagePlacement records for the snapshot, and
 * copies one image's pixels on demand for renderer texture caches. No
 * libghostty handle leaves this file (ADR 0004). */

/* Per-screen image budget when enabled. Each tab has a primary and an
 * alternate screen; exceeding the budget evicts the oldest images. */
#define LABAN_KITTY_IMAGE_STORAGE_LIMIT ((uint64_t)64 * 1000 * 1000)

/* Refuse PNGs whose decoded size would be absurd (10k x 10k RGBA = 400 MB,
 * already past the storage budget). */
#define LABAN_KITTY_PNG_MAX_DIMENSION 10000u

/* -1 = unset (the environment decides), 0 = disabled, 1 = enabled. */
static _Atomic int g_kitty_setting = -1;

void laban_set_kitty_graphics_enabled(bool enabled) {
    atomic_store(&g_kitty_setting, enabled ? 1 : 0);
}

bool laban_kitty_graphics_enabled(void) {
    int setting = atomic_load(&g_kitty_setting);
    if (setting >= 0) return setting == 1;
    const char *env = getenv("LABAN_KITTY_GRAPHICS");
    return env && strcmp(env, "1") == 0;
}

/* Decodes PNG bytes to straight-alpha RGBA8 in a buffer from `allocator`,
 * which libghostty then owns. CoreGraphics only draws into premultiplied
 * RGBA, so draw premultiplied and convert in place. */
static bool laban_decode_png(void *userdata, const GhosttyAllocator *allocator,
                             const uint8_t *data, size_t data_len,
                             GhosttySysImage *out) {
    (void)userdata;
    if (!data || data_len == 0 || !out) return false;

    bool ok = false;
    CFDataRef cf_data = NULL;
    CGImageSourceRef source = NULL;
    CGImageRef image = NULL;
    CGColorSpaceRef color_space = NULL;
    CGContextRef context = NULL;
    uint8_t *pixels = NULL;
    size_t pixel_len = 0;

    cf_data = CFDataCreateWithBytesNoCopy(NULL, data, (CFIndex)data_len, kCFAllocatorNull);
    if (!cf_data) goto done;
    source = CGImageSourceCreateWithData(cf_data, NULL);
    if (!source) goto done;
    image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (!image) goto done;

    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0 ||
        width > LABAN_KITTY_PNG_MAX_DIMENSION || height > LABAN_KITTY_PNG_MAX_DIMENSION) {
        goto done;
    }
    pixel_len = width * height * 4;
    pixels = ghostty_alloc(allocator, pixel_len);
    if (!pixels) goto done;
    memset(pixels, 0, pixel_len);

    color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!color_space) goto done;
    context = CGBitmapContextCreate(
        pixels, width, height, 8, width * 4, color_space,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) goto done;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);

    vImage_Buffer buffer = {
        .data = pixels, .height = height, .width = width, .rowBytes = width * 4,
    };
    if (vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, kvImageNoFlags) != kvImageNoError) {
        goto done;
    }

    out->width = (uint32_t)width;
    out->height = (uint32_t)height;
    out->data = pixels;
    out->data_len = pixel_len;
    pixels = NULL;  /* ownership moved to libghostty */
    ok = true;

done:
    if (pixels) ghostty_free(allocator, pixels, pixel_len);
    if (context) CGContextRelease(context);
    if (color_space) CGColorSpaceRelease(color_space);
    if (image) CGImageRelease(image);
    if (source) CFRelease(source);
    if (cf_data) CFRelease(cf_data);
    return ok;
}

static pthread_once_t g_png_decoder_once = PTHREAD_ONCE_INIT;

static void install_png_decoder(void) {
    /* Process-global in libghostty; installed once, before any enabled
     * terminal can receive a PNG. */
    ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (const void *)laban_decode_png);
}

void laban_kitty_configure_terminal(LabanSession *s) {
    s->kitty_enabled = laban_kitty_graphics_enabled() ? 1 : 0;
    s->kitty_placement_iter = NULL;
    s->kitty_last_snapshot_signature = 0;
    s->kitty_last_rendered_signature = 0;
    s->kitty_last_snapshot_storage_generation = 0;
    s->kitty_last_rendered_storage_generation = 0;

    if (!s->kitty_enabled) {
        /* libghostty enables the protocol by default (10 MB). A zero limit
         * disables it entirely: nothing is stored and no query or transmit
         * is acknowledged, so programs fall back to text. */
        uint64_t limit = 0;
        ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                             &limit);
        return;
    }

    pthread_once(&g_png_decoder_once, install_png_decoder);

    uint64_t limit = LABAN_KITTY_IMAGE_STORAGE_LIMIT;
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit);

    /* Mediums: direct (always on) plus shared memory and temporary files,
     * which need a local same-user program to create the object. The plain
     * file medium stays off: it would let whatever writes to the PTY (a
     * remote host, a cat-ed file) make Laban read any local path. */
    bool file_medium = false;
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE,
                         &file_medium);
    bool shared_memory = true;
    ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM,
                         &shared_memory);
    char temp_dir[PATH_MAX];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, temp_dir, sizeof(temp_dir));
    if (n > 1 && n <= sizeof(temp_dir)) {
        GhosttyString dir = { .ptr = (const uint8_t *)temp_dir, .len = strlen(temp_dir) };
        ghostty_terminal_set(s->terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE,
                             &dir);
    }
}

void laban_kitty_free_resources(LabanSession *s) {
    if (s->kitty_placement_iter) {
        ghostty_kitty_graphics_placement_iterator_free(s->kitty_placement_iter);
        s->kitty_placement_iter = NULL;
    }
}

static int32_t layer_for_z(int32_t z) {
    if (z < INT32_MIN / 2) return LABAN_IMAGE_LAYER_BELOW_BACKGROUND;
    if (z < 0) return LABAN_IMAGE_LAYER_BELOW_TEXT;
    return LABAN_IMAGE_LAYER_ABOVE_TEXT;
}

static int compare_placements(const void *a, const void *b) {
    const LabanImagePlacement *pa = a, *pb = b;
    if (pa->layer != pb->layer) return pa->layer < pb->layer ? -1 : 1;
    if (pa->z != pb->z) return pa->z < pb->z ? -1 : 1;
    if (pa->image_id != pb->image_id) return pa->image_id < pb->image_id ? -1 : 1;
    if (pa->placement_id != pb->placement_id) return pa->placement_id < pb->placement_id ? -1 : 1;
    return 0;
}

/* FNV-1a over the placement records. Records are zero-initialized, so struct
 * padding hashes deterministically. */
static uint64_t placements_signature(const LabanImagePlacement *p, size_t count) {
    if (count == 0) return 0;
    uint64_t h = 1469598103934665603ULL;
    const uint8_t *bytes = (const uint8_t *)p;
    size_t len = count * sizeof(*p);
    for (size_t i = 0; i < len; i++) {
        h ^= bytes[i];
        h *= 1099511628211ULL;
    }
    return h ? h : 1;
}

static GhosttyKittyGraphics kitty_graphics_locked(LabanSession *s) {
    if (!s->kitty_enabled) return NULL;
    GhosttyKittyGraphics graphics = NULL;
    if (ghostty_terminal_get(s->terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics)
            != GHOSTTY_SUCCESS) {
        return NULL;
    }
    return graphics;
}

uint64_t laban_kitty_storage_generation_locked(LabanSession *s) {
    GhosttyKittyGraphics graphics = kitty_graphics_locked(s);
    if (!graphics) return 0;
    uint64_t generation = 0;
    ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation);
    return generation;
}

int laban_kitty_collect_placements_locked(
    LabanSession *s, LabanImagePlacement **out_placements, size_t *out_count,
    uint64_t *out_storage_generation, uint64_t *out_signature) {
    *out_placements = NULL;
    *out_count = 0;
    *out_storage_generation = 0;
    *out_signature = 0;

    GhosttyKittyGraphics graphics = kitty_graphics_locked(s);
    if (!graphics) return 0;

    uint64_t storage_generation = 0;
    ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION,
                               &storage_generation);
    *out_storage_generation = storage_generation;

    if (!s->kitty_placement_iter &&
        ghostty_kitty_graphics_placement_iterator_new(NULL, &s->kitty_placement_iter)
            != GHOSTTY_SUCCESS) {
        s->kitty_placement_iter = NULL;
        return 0;
    }
    GhosttyKittyGraphicsPlacementIterator iter = s->kitty_placement_iter;
    if (ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
                                   &iter) != GHOSTTY_SUCCESS) {
        return 0;
    }

    LabanImagePlacement *placements = NULL;
    size_t count = 0, cap = 0;
    while (ghostty_kitty_graphics_placement_next(iter)) {
        uint32_t image_id = 0, placement_id = 0, x_offset = 0, y_offset = 0;
        bool is_virtual = false;
        int32_t z = 0;
        ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
                                             &image_id);
        ghostty_kitty_graphics_placement_get(
            iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placement_id);
        ghostty_kitty_graphics_placement_get(
            iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &is_virtual);
        /* Virtual placements only render through Unicode placeholder cells,
         * which the public C API cannot resolve yet (plan Milestone 4). */
        if (is_virtual) continue;
        ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z);
        ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET,
                                             &x_offset);
        ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET,
                                             &y_offset);

        GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(graphics, image_id);
        if (!image) continue;
        uint64_t image_generation = 0;
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
                                         &image_generation);

        GhosttyKittyGraphicsPlacementRenderInfo info =
            GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo);
        if (ghostty_kitty_graphics_placement_render_info(iter, image, s->terminal, &info)
                != GHOSTTY_SUCCESS || !info.viewport_visible) {
            continue;
        }

        if (count == cap) {
            size_t new_cap = cap ? cap * 2 : 4;
            LabanImagePlacement *grown = realloc(placements, new_cap * sizeof(*grown));
            if (!grown) { free(placements); return -1; }
            placements = grown;
            cap = new_cap;
        }
        LabanImagePlacement *p = &placements[count++];
        memset(p, 0, sizeof(*p));
        p->image_id = image_id;
        p->placement_id = placement_id;
        p->image_generation = image_generation;
        p->layer = layer_for_z(z);
        p->z = z;
        p->viewport_col = info.viewport_col;
        p->viewport_row = info.viewport_row;
        p->x_offset_px = x_offset;
        p->y_offset_px = y_offset;
        p->pixel_width = info.pixel_width;
        p->pixel_height = info.pixel_height;
        p->grid_cols = info.grid_cols;
        p->grid_rows = info.grid_rows;
        p->source_x = info.source_x;
        p->source_y = info.source_y;
        p->source_width = info.source_width;
        p->source_height = info.source_height;
    }

    if (count > 1) qsort(placements, count, sizeof(*placements), compare_placements);
    *out_placements = placements;
    *out_count = count;
    *out_signature = placements_signature(placements, count);
    return 0;
}

int laban_session_kitty_image_copy(LabanSession *s, uint32_t image_id,
                                   uint64_t expected_generation,
                                   LabanKittyImage *out_image) {
    if (!out_image) return -1;
    memset(out_image, 0, sizeof(*out_image));
    if (!s) return -1;
    SESSION_LOCK(s);

    GhosttyKittyGraphics graphics = kitty_graphics_locked(s);
    if (!graphics) return -1;
    GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(graphics, image_id);
    if (!image) return -1;

    uint64_t generation = 0;
    uint32_t width = 0, height = 0;
    GhosttyKittyImageFormat format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
    const uint8_t *data = NULL;
    size_t data_len = 0;
    ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation);
    if (generation != expected_generation) return -1;
    ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width);
    ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height);
    ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format);
    /* Pending (still loading) images report no data pointer. */
    if (ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data)
            != GHOSTTY_SUCCESS || !data) {
        return -1;
    }
    ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &data_len);
    if (width == 0 || height == 0) return -1;

    size_t bytes_per_pixel;
    switch (format) {
    case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:       bytes_per_pixel = 4; break;
    case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:        bytes_per_pixel = 3; break;
    case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: bytes_per_pixel = 2; break;
    case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:       bytes_per_pixel = 1; break;
    default: return -1;  /* PNG is decoded before storage and never reported */
    }
    size_t pixel_count = (size_t)width * (size_t)height;
    if (data_len < pixel_count * bytes_per_pixel) return -1;

    uint8_t *rgba = malloc(pixel_count * 4);
    if (!rgba) return -1;
    for (size_t i = 0; i < pixel_count; i++) {
        const uint8_t *src = data + i * bytes_per_pixel;
        uint8_t *dst = rgba + i * 4;
        switch (bytes_per_pixel) {
        case 4: dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = src[3]; break;
        case 3: dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = 0xFF; break;
        case 2: dst[0] = dst[1] = dst[2] = src[0]; dst[3] = src[1]; break;
        default: dst[0] = dst[1] = dst[2] = src[0]; dst[3] = 0xFF; break;
        }
    }

    out_image->width = width;
    out_image->height = height;
    out_image->generation = generation;
    out_image->rgba = rgba;
    return 0;
}

void laban_kitty_image_free(LabanKittyImage *image) {
    if (!image) return;
    free(image->rgba);
    image->rgba = NULL;
    image->width = 0;
    image->height = 0;
}
