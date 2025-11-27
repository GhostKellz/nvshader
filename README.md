# nvshader

**NVIDIA Shader Cache Management & Optimization for Linux**

A comprehensive shader cache management system that eliminates stuttering, enables cache sharing, and provides pre-compilation tools for Linux gaming.

## Overview

nvshader solves the notorious "shader compilation stutter" problem on Linux by providing:

- **Unified Cache Management** - Single interface for DXVK, vkd3d-proton, and driver caches
- **Pre-warming Tools** - Compile shaders before gameplay
- **P2P Cache Sharing** - Share compiled shaders with other users
- **Cache Analytics** - Understand and optimize shader performance
- **Automatic Optimization** - GPU-specific shader compilation flags

## The Problem

```
Without nvshader:
┌────────────────────────────────────────────────────────┐
│  Frame 1: 16ms  │  Frame 2: 250ms (stutter!)  │ ...   │
│  ████████       │  ████████████████████████████████   │
│                 │  ^ Shader compilation mid-game      │
└────────────────────────────────────────────────────────┘

With nvshader:
┌────────────────────────────────────────────────────────┐
│  Frame 1: 16ms  │  Frame 2: 16ms  │  Frame 3: 16ms    │
│  ████████       │  ████████       │  ████████         │
│  All shaders pre-compiled before game launch          │
└────────────────────────────────────────────────────────┘
```

## Features

### Cache Types Managed

| Cache Type | Location | Purpose |
|------------|----------|---------|
| **NVIDIA Driver** | `~/.nv/ComputeCache/` | GPU binary cache |
| **DXVK** | `~/.cache/dxvk/` | DX9/10/11 → Vulkan |
| **vkd3d-proton** | `~/.cache/vkd3d-proton/` | DX12 → Vulkan |
| **Mesa** | `~/.cache/mesa_shader_cache/` | OpenGL shaders |
| **Fossilize** | Steam's shader pre-caching | Vulkan pipeline cache |

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      nvshader                            │
├───────────┬───────────┬───────────┬────────────────────┤
│  manager  │  prewarm  │   share   │     optimize       │
│  (cache)  │  (compile)│   (p2p)   │     (flags)        │
├───────────┴───────────┴───────────┴────────────────────┤
│              Fossilize Integration Layer                 │
├─────────────────────────────────────────────────────────┤
│     DXVK Cache    │   vkd3d Cache   │   Driver Cache    │
└─────────────────────────────────────────────────────────┘
```

## Usage

### CLI Tool

```bash
# View cache statistics
nvshader status

# Pre-warm shaders for a game
nvshader prewarm --game "Cyberpunk 2077"

# Export cache for sharing
nvshader export --game "Elden Ring" --output elden-ring-rtx4090.nvcache

# Import shared cache
nvshader import rtx4090-cache.nvcache

# Clean old/invalid cache entries
nvshader clean --older-than 30d

# Optimize cache for current GPU
nvshader optimize --gpu auto

# Watch shader compilation in real-time
nvshader watch --pid $(pgrep game)
```

### Library API (Zig)

```zig
const nvshader = @import("nvshader");

pub fn main() !void {
    var cache = try nvshader.CacheManager.init(.{
        .gpu_id = try nvshader.detectGpu(),
        .cache_paths = .auto,
    });
    defer cache.deinit();

    // Pre-warm shaders for a game
    const game = try cache.findGame("Cyberpunk 2077");
    try cache.prewarm(game, .{
        .parallel_jobs = 8,
        .progress_callback = progressFn,
    });

    // Get cache statistics
    const stats = try cache.getStats(game);
    std.log.info("Shaders cached: {d}/{d}", .{
        stats.cached_count,
        stats.total_count,
    });
}
```

### C API

```c
#include <nvshader/nvshader.h>

nvshader_cache_t* cache = nvshader_init(NVSHADER_AUTO_DETECT);

// Pre-warm game shaders
nvshader_prewarm(cache, "Cyberpunk 2077", NULL);

// Get statistics
nvshader_stats_t stats;
nvshader_get_stats(cache, "Cyberpunk 2077", &stats);
printf("Cached: %d/%d shaders\n", stats.cached, stats.total);

nvshader_cleanup(cache);
```

## P2P Cache Sharing

Share shader caches with the community:

```bash
# Upload your cache to the nvshader network
nvshader share upload --game "Elden Ring"

# Download community caches for your GPU
nvshader share download --game "Elden Ring" --gpu rtx4090

# Browse available caches
nvshader share list --game "Elden Ring"
```

### Cache Compatibility

Caches are organized by:
- GPU architecture (Ampere, Ada, etc.)
- Driver version range
- Game version
- DXVK/vkd3d-proton version

## Steam Integration

```bash
# Pre-warm all installed Steam games
nvshader steam prewarm --all

# Watch for new shader compilations
nvshader steam watch

# Add to Steam launch options for status display
NVSHADER_OVERLAY=1 %command%
```

## Building

```bash
# Build CLI and library
zig build -Doptimize=ReleaseFast

# Build with P2P sharing support
zig build -Doptimize=ReleaseFast -Dp2p=true

# Run tests
zig build test
```

## Installation

```bash
# System-wide install
sudo zig build install --prefix /usr/local

# User install
zig build install --prefix ~/.local

# Enable systemd service for background pre-warming
systemctl --user enable nvshader-prewarm.service
```

## Related Projects

| Project | Purpose | Integration |
|---------|---------|-------------|
| **nvcontrol** | GUI control center | Cache management UI |
| **nvproton** | Proton integration | Automatic pre-warming |
| **Fossilize** | Valve's shader cache | Backend support |

## Requirements

- NVIDIA driver 470+
- Vulkan 1.2+
- Zig 0.12+
- Optional: Fossilize for enhanced caching

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

See [TODO.md](TODO.md) for the development roadmap.
