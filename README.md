# bc250-mesa

Mesa patch overlay for the **AMD BC-250** mining APU (gfx1013 / PS5 "Oberon" die).

**Upstream is GitLab:** <https://gitlab.freedesktop.org/mesa/mesa>.
This repository is **not a Mesa fork**. It is a small set of patches plus a build
recipe that fetches upstream Mesa, applies the BC-250 fixes, and builds the RADV
Vulkan driver. Keep upstream as the source of truth; this repo only carries the
BC-250-specific delta.

## Why

The BC-250 is a salvaged PS5 APU: RDNA2-class GPU (gfx1013), 16 GB unified GDDR6,
no matrix cores. It is popular for cheap local LLM inference (llama.cpp Vulkan).

Upstream Mesa conservatively excluded `CHIP_GFX1013` from accelerated integer dot
product, grouping it with RDNA1. The hardware actually executes the RDNA2 packed
int8 dot instructions correctly, so this exclusion leaves performance on the table.

## Patches

| Patch | File | Effect |
|-------|------|--------|
| `0001-ac-gpu_info-enable-int-dot-gfx1013` | `src/amd/common/ac_gpu_info.c` | Enable `has_accelerated_dot_product` on GFX1013 → RADV advertises `VK_KHR_shader_integer_dot_product`, ACO emits accelerated int8 dot opcodes. |

### Verified on real BC-250 hardware (RADV GFX1013)

- `int dot: 1` reported by llama.cpp (was `0`).
- Vulkan `MUL_MAT_ID` correctness tests pass against the CPU reference (no
  illegal-instruction faults, no garbage). A software fallback would not speed up,
  so the gain confirms a genuine hardware instruction.
- MoE expert matvec (q4_K, batch 1): **86.16 µs → 20.14 µs (~4.3×)**,
  292 GFLOPS → 1.25 TFLOPS.
- llama.cpp flint MoE prompt processing: **662 → 862 tok/s (+30%)** (both RPC nodes
  patched). Token generation is bandwidth-bound and gains less (~+2%).

## Features

- Fetches upstream Mesa (GitLab) at a configurable ref (default `main`).
- Applies the BC-250 patch set idempotently (re-runnable).
- Configures a minimal RADV-only build (no OpenGL/gallium), LLVM enabled, release.
- Handles the Python `packaging` dependency (Python 3.12+ dropped `distutils`).
- Produces a drop-in `libvulkan_radeon.so` usable via `VK_ICD_FILENAMES` — no system
  install or root required.

## Build

Dependencies: `git`, `meson`, `ninja`, `gcc/g++`, `llvm`, `libdrm`, `wayland`,
`vulkan-headers`, `spirv-headers`, `glslang`, `flex`, `bison`, `python3` + `mako`.
On Alpine: `apk add meson ninja gcc g++ llvm-dev libdrm-dev wayland-dev
vulkan-headers spirv-headers glslang-dev flex bison py3-mako python3-dev`.

```sh
./build.sh                       # upstream main -> ./mesa, install prefix ~/.local
MESA_REF=mesa-25.0.0 ./build.sh  # pin a tag/branch
PREFIX=/opt/bc250-mesa ./build.sh
```

Output:

```
mesa/build/src/amd/vulkan/libvulkan_radeon.so
mesa/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json
```

## Use

Point the Vulkan loader at the patched driver (no root, no system change):

```sh
export VK_ICD_FILENAMES=$PWD/mesa/build/src/amd/vulkan/radeon_devenv_icd.x86_64.json
vulkaninfo --summary        # confirm RADV GFX1013 loads
llama-server -m model.gguf -ngl 99 ...   # llama.cpp now sees int dot: 1
```

For multi-node RPC inference, run the patched driver on **every** node (set
`VK_ICD_FILENAMES` for each `ggml-rpc-server` too).

## Repository layout

```
bc250-mesa/
├── README.md
├── build.sh                 # fetch upstream + apply patches + meson + ninja
└── patches/
    └── 0001-ac-gpu_info-enable-int-dot-gfx1013.patch
```

## Notes

- The patch is a one-line change; if upstream moves the surrounding code, rebase
  with `git apply --3way patches/0001-*.patch`.
- This enables the *advertised* feature and the ACO codegen path. Quantized-KV
  flash-attention MMQ and MoE MMQ matvec in llama.cpp consume it automatically.
- BC-250 specifics (40-CU unlock, SMU governor, custom kernel) live outside Mesa;
  see the BC-250 community docs.

## License

The patch is against Mesa (MIT/X11-style). This overlay repo: MIT.