# nvshader

**NVIDIA Shader Cache Management & Optimization for Linux**

A comprehensive shader cache management system that eliminates stuttering, enables cache sharing, and provides pre-compilation tools for Linux gaming.

## Overview

nvshader solves the notorious "shader compilation stutter" problem on Linux by providing:

- **Unified Cache Management** - Single interface for DXVK, vkd3d-proton, Mesa, and NVIDIA driver caches
- **Pre-warming Tools** - Compile Fossilize shaders before gameplay
- **Real-time Monitoring** - Watch shader compilation in real-time with inotify
- **Cache Sharing** - Export/import .nvcache packages with GPU compatibility checking
- **Steam Integration** - Steam Deck support, per-game cache status
- **JSON API** - Scriptable output for integration with nvcontrol

## The Problem

```
Without nvshader:
+--------------------------------------------------------+
|  Frame 1: 16ms  |  Frame 2: 250ms (stutter!)  | ...   |
|  ========       |  ================================== |
|                 |  ^ Shader compilation mid-game      |
+--------------------------------------------------------+

With nvshader:
+--------------------------------------------------------+
|  Frame 1: 16ms  |  Frame 2: 16ms  |  Frame 3: 16ms    |
|  ========       |  ========       |  ========         |
|  All shaders pre-compiled before game launch          |
+--------------------------------------------------------+
```

## Features

### Cache Types Managed

| Cache Type | Location | Purpose |
|------------|----------|---------|
| **NVIDIA Driver** | `~/.nv/ComputeCache/` | GPU binary cache |
| **DXVK** | `~/.cache/dxvk/` | DX9/10/11 -> Vulkan |
| **vkd3d-proton** | `~/.cache/vkd3d-proton/` | DX12 -> Vulkan |
| **Mesa** | `~/.cache/mesa_shader_cache/` | OpenGL shaders |
| **Fossilize/Steam** | `~/.steam/.../shadercache/` | Vulkan pipeline cache |

## Installation

### From Source (Zig 0.16+)

```bash
git clone https://github.com/yourname/nvshader
cd nvshader
zig build -Doptimize=ReleaseFast
sudo cp zig-out/bin/nvshader /usr/local/bin/
```

### Arch Linux (AUR)

```bash
yay -S nvshader
```

## Usage

### Basic Commands

```bash
# View cache statistics
nvshader status

# Show GPU profile (architecture, driver version)
nvshader gpu

# List detected games with cache info
nvshader games

# Monitor shader compilation in real-time
nvshader watch

# Pre-warm Fossilize shader caches
nvshader prewarm --threads 8

# Validate cache integrity
nvshader validate

# Clean old cache entries
nvshader clean --older-than 30 --max-size 10G
```

### Steam Integration

```bash
# Show Steam installation info
nvshader steam info

# Per-game shader cache status
nvshader steam cache

# Clear shader cache for a specific game
nvshader steam clear 570

# Steam Deck info and recommendations
nvshader steam deck
```

### Export/Import Caches

```bash
# Export all caches to a directory
nvshader export ~/shader-backup --game "Elden Ring"

# Import caches from directory
nvshader import ~/shader-backup --dest ~/.cache/dxvk/

# Create .nvcache package for sharing
nvshader pack ~/elden-ring.nvcache --game "Elden Ring"
```

### JSON Output (for scripting/nvcontrol)

```bash
# Status as JSON
nvshader json status

# GPU info as JSON
nvshader json gpu

# Steam info as JSON
nvshader json steam

# Games list as JSON
nvshader json games
```

### IPC Daemon (for nvcontrol integration)

```bash
# Start daemon for GUI integration
nvshader daemon
```

## GPU Compatibility

nvshader detects your GPU architecture for cache compatibility:

| Architecture | GPUs |
|-------------|------|
| Blackwell | RTX 50 series |
| Ada Lovelace | RTX 40 series |
| Ampere | RTX 30 series |
| Turing | RTX 20 series |
| Pascal | GTX 10 series |

## nvcontrol Integration

nvshader integrates with [nvcontrol](https://github.com/yourname/nvcontrol) via:

1. **JSON CLI** - `nvshader json <command>` for GUI data binding
2. **IPC Daemon** - Unix socket at `/tmp/nvshader.sock`
3. **Future**: `nvctl shader` alias in nvcontrol

## Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## Requirements

- Linux x86_64
- NVIDIA driver 470+ (for NVIDIA features)
- Zig 0.16+ (for building)
- Optional: fossilize_replay (for pre-warming)

## Architecture

```
+--------------------------------------------------------+
|                      nvshader v0.1.0                     |
+------------+------------+------------+-----------------+
|   cache    |  prewarm   |   watch    |     steam       |
|  (manager) | (fossilize)|  (inotify) |   (integration) |
+------------+------------+------------+-----------------+
|              sharing       |         ipc              |
|         (.nvcache format)  |    (JSON + socket)       |
+----------------------------+--------------------------+
|     DXVK    |   vkd3d    |   Mesa    |   NVIDIA      |
+----------------------------+--------------------------+
```

## Related Projects

| Project | Purpose | Integration |
|---------|---------|-------------|
| **nvcontrol** | GUI control center | Full integration via IPC |
| **nvproton** | Proton optimization | Future integration |
| **Fossilize** | Valve's shader cache | Pre-warming backend |

## License

MIT License - See [LICENSE](LICENSE)
