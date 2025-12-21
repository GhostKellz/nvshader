/**
 * nvshader - Shader Cache Management for Linux Gaming
 *
 * C API for managing DXVK, vkd3d-proton, NVIDIA, Mesa, and Fossilize shader caches.
 *
 * Usage:
 *   nvshader_ctx_t ctx = nvshader_init();
 *   if (ctx) {
 *       nvshader_scan(ctx);
 *       nvshader_stats_t stats;
 *       nvshader_get_stats(ctx, &stats);
 *       printf("Total cache size: %lu bytes\n", stats.total_size_bytes);
 *       nvshader_destroy(ctx);
 *   }
 */

#ifndef NVSHADER_H
#define NVSHADER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version: 0.1.0 */
#define NVSHADER_VERSION_MAJOR 0
#define NVSHADER_VERSION_MINOR 1
#define NVSHADER_VERSION_PATCH 0
#define NVSHADER_VERSION ((NVSHADER_VERSION_MAJOR << 16) | (NVSHADER_VERSION_MINOR << 8) | NVSHADER_VERSION_PATCH)

/**
 * Opaque context handle
 */
typedef void* nvshader_ctx_t;

/**
 * Result codes
 */
typedef enum {
    NVSHADER_SUCCESS = 0,
    NVSHADER_ERROR_INVALID_HANDLE = -1,
    NVSHADER_ERROR_SCAN_FAILED = -2,
    NVSHADER_ERROR_PREWARM_FAILED = -3,
    NVSHADER_ERROR_NOT_AVAILABLE = -4,
    NVSHADER_ERROR_GAME_NOT_FOUND = -5,
    NVSHADER_ERROR_INVALID_PARAM = -6,
    NVSHADER_ERROR_OUT_OF_MEMORY = -7,
    NVSHADER_ERROR_UNKNOWN = -99
} nvshader_result_t;

/**
 * Cache type enumeration
 */
typedef enum {
    NVSHADER_CACHE_DXVK = 0,
    NVSHADER_CACHE_VKD3D = 1,
    NVSHADER_CACHE_NVIDIA = 2,
    NVSHADER_CACHE_MESA = 3,
    NVSHADER_CACHE_FOSSILIZE = 4
} nvshader_cache_type_t;

/**
 * Cache statistics
 */
typedef struct {
    uint64_t total_size_bytes;    /* Total size of all caches */
    uint32_t file_count;          /* Number of cache files/directories */
    uint32_t game_count;          /* Number of games with caches */
    uint64_t dxvk_size;           /* DXVK cache size */
    uint64_t vkd3d_size;          /* vkd3d-proton cache size */
    uint64_t nvidia_size;         /* NVIDIA compute cache size */
    uint64_t mesa_size;           /* Mesa shader cache size */
    uint64_t fossilize_size;      /* Fossilize/Steam cache size */
    uint32_t oldest_days;         /* Age of oldest cache in days */
    uint32_t newest_days;         /* Age of newest cache in days */
} nvshader_stats_t;

/**
 * Pre-warm result
 */
typedef struct {
    uint32_t completed;           /* Successfully pre-warmed */
    uint32_t failed;              /* Failed to pre-warm */
    uint32_t skipped;             /* Skipped (not Fossilize) */
    uint32_t total;               /* Total entries processed */
} nvshader_prewarm_result_t;

/**
 * Cache entry information
 */
typedef struct {
    const char* path;             /* Full path to cache */
    nvshader_cache_type_t cache_type;
    uint64_t size_bytes;          /* Size in bytes */
    const char* game_name;        /* Associated game name (may be NULL) */
    const char* game_id;          /* Game ID (Steam AppID, etc.) */
    uint32_t entry_count;         /* Number of shader entries */
    bool is_directory;            /* True if directory-based cache */
} nvshader_entry_t;

/* ============================================================================
 * Context Management
 * ============================================================================ */

/**
 * Initialize nvshader context
 *
 * @return Context handle, or NULL on failure
 */
nvshader_ctx_t nvshader_init(void);

/**
 * Destroy nvshader context and free all resources
 *
 * @param ctx Context handle
 */
void nvshader_destroy(nvshader_ctx_t ctx);

/**
 * Get library version as packed integer (major << 16 | minor << 8 | patch)
 *
 * @return Version number
 */
uint32_t nvshader_get_version(void);

/* ============================================================================
 * Cache Scanning
 * ============================================================================ */

/**
 * Scan for all shader caches on the system
 *
 * Scans standard locations:
 * - ~/.cache/dxvk-cache/ (DXVK)
 * - ~/.cache/vkd3d-proton/ (vkd3d)
 * - ~/.nv/ComputeCache/ (NVIDIA)
 * - ~/.cache/mesa_shader_cache/ (Mesa)
 * - Steam shader cache directories (Fossilize)
 *
 * @param ctx Context handle
 * @return NVSHADER_SUCCESS on success, error code otherwise
 */
nvshader_result_t nvshader_scan(nvshader_ctx_t ctx);

/**
 * Get aggregated cache statistics
 *
 * @param ctx Context handle
 * @param out_stats Pointer to stats structure to fill
 * @return NVSHADER_SUCCESS on success
 */
nvshader_result_t nvshader_get_stats(nvshader_ctx_t ctx, nvshader_stats_t* out_stats);

/**
 * Get number of cache entries found
 *
 * @param ctx Context handle
 * @return Number of entries, or -1 on error
 */
int nvshader_get_entry_count(nvshader_ctx_t ctx);

/* ============================================================================
 * Pre-warming (Shader Compilation)
 * ============================================================================ */

/**
 * Check if pre-warming is available (requires fossilize_replay)
 *
 * @param ctx Context handle
 * @return true if fossilize_replay is available
 */
bool nvshader_prewarm_available(nvshader_ctx_t ctx);

/**
 * Pre-warm shader cache for a specific game
 *
 * This triggers Fossilize replay to compile shaders ahead of time,
 * eliminating shader stutter during gameplay.
 *
 * @param ctx Context handle
 * @param game_id Game identifier (Steam AppID or other ID, null-terminated)
 * @param out_result Optional result structure
 * @return NVSHADER_SUCCESS on success
 */
nvshader_result_t nvshader_prewarm_game(
    nvshader_ctx_t ctx,
    const char* game_id,
    nvshader_prewarm_result_t* out_result
);

/**
 * Pre-warm all Fossilize shader caches
 *
 * @param ctx Context handle
 * @param out_result Optional result structure
 * @return NVSHADER_SUCCESS on success
 */
nvshader_result_t nvshader_prewarm_all(
    nvshader_ctx_t ctx,
    nvshader_prewarm_result_t* out_result
);

/* ============================================================================
 * Cache Maintenance
 * ============================================================================ */

/**
 * Remove caches older than specified days
 *
 * @param ctx Context handle
 * @param days Age threshold in days
 * @return Number of entries removed, or -1 on error
 */
int nvshader_clean_older_than(nvshader_ctx_t ctx, uint32_t days);

/**
 * Shrink caches to fit within size limit
 *
 * Removes oldest caches first until total size is under limit.
 *
 * @param ctx Context handle
 * @param max_bytes Maximum total cache size in bytes
 * @return Number of entries removed, or -1 on error
 */
int nvshader_shrink_to_size(nvshader_ctx_t ctx, uint64_t max_bytes);

/**
 * Validate all cache entries
 *
 * Checks for corrupted or invalid cache files.
 *
 * @param ctx Context handle
 * @return Number of invalid entries, or -1 on error
 */
int nvshader_validate(nvshader_ctx_t ctx);

/* ============================================================================
 * Utility
 * ============================================================================ */

/**
 * Get last error message
 *
 * @param ctx Context handle
 * @return Null-terminated error string
 */
const char* nvshader_get_last_error(nvshader_ctx_t ctx);

/**
 * Check if NVIDIA GPU is present
 *
 * @return true if NVIDIA GPU detected
 */
bool nvshader_is_nvidia_gpu(void);

#ifdef __cplusplus
}
#endif

#endif /* NVSHADER_H */
