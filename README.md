# bc250-mesa

Mesa/RADV research and build notes for the **AMD BC-250** mining APU
(gfx1013 / PS5 "Oberon" die, RDNA2-class but a hybrid GFX10.1 base).

**Upstream is GitLab:** <https://gitlab.freedesktop.org/mesa/mesa>. This repo is
not a Mesa fork; it carries research, a build recipe, and verified findings about
what this silicon actually does.

## ⚠️ Headline finding: do NOT enable integer dot product on gfx1013

An earlier version of this repo shipped a patch removing the `CHIP_GFX1013`
exclusion from `has_accelerated_dot_product` (Mesa
`src/amd/common/ac_gpu_info.c`). **That patch is HARMFUL and has been removed.**

The gfx1013 dot-product opcodes do not compute dot products. Measured on real
BC-250 silicon (see [`docs/GFX1013-DOT-HAZARD.md`](docs/GFX1013-DOT-HAZARD.md)):

- `v_dot2_f32_f16`, `v_dot2_i32_i16`, `v_dot4_i32_i8`, `v_dot4_u32_u8`,
  `v_dot8_i32_i4`, `v_dot2c_f32_f16`, ... **write zero in every lane**.
- `v_dot4c_i32_i8` (VOP2 0x0d) actually executes an **SI-era legacy float
  minimum** — it returns a plausible float, which is worse than zero.
- Nothing faults: the instruction retires and the answer is quietly wrong.

Verified here with llama.cpp `test-backend-ops -o MUL_MAT_ID` on the patched
driver: **ERR ≈ 1.0 for every quant type** (q4_K/q5_K/q6_K/q8_0/iq4_xs/...),
`inf` for iq4_nl. On the **stock** driver (exclusion intact): 1160/1160 pass.

**Stock Mesa is correct.** `has_accelerated_dot_product` must stay `false` for
`CHIP_GFX1013`. The earlier reported "~4.3× MoE matvec / +30% pp" was the
*perf* mode timing garbage results; correctness was only ever checked on the
stock driver. That conclusion was wrong and is retracted.

Independent corroboration:
- D-Ogi/amdgpu-wddm `docs/gfx1013-isa.md` — silicon probe, all 9 dot opcodes
  write zero / legacy-min; positive controls `v_pk_fma_f16`, `v_fma_mix_f32`,
  `v_mul_i32_i24` are correct.
- obl1vn/Unlock-ps5-pro-memory `docs/int8-dot4.md` — PS5 Pro hardware `v_dot4`
  returns 0 for all 262144 probes.
- LLVM `D103663` gfx1013 target rejects `v_dot2_f32_f16` ("instruction not
  supported on this GPU").

## What actually works on gfx1013 (the real levers)

These were positive controls in the silicon probe — correct in all lanes:

| Instruction | Use | API exposure |
|-------------|-----|--------------|
| `v_pk_fma_f16` / `v_pk_*_f16` | packed FP16, 2× rate | `VK_KHR_shader_float16_int8` + `VK_KHR_16bit_storage` (half2) |
| `v_fma_mix_f32` / `v_fma_mixlo_f16` | FP16 inputs, FP32 acc, free conversion | shader float16 + packed math |
| `v_mul_i32_i24` / `v_mad_i32_i24` | full-rate INT24 (vs 1/4-rate INT32 mul) | compiler autogen / HIP intrinsics |
| `v_perm_b32`, `v_bfe_u32`, `v_bfi_b32`, SDWA | quant nibble/byte unpack | compiler autogen from bit ops |
| DPP16/DPP8, `v_permlane16_b32`, `ds_bpermute` | subgroup reductions / shuffles | subgroup ops / HIP `__shfl`, `mov_dpp` |

llama.cpp's Vulkan FP16 path already reaches packed FP16 / mix via generation
tests (not a chip list), so it benefits without any Mesa patch. See
[`docs/WORKING-INSTRUCTIONS.md`](docs/WORKING-INSTRUCTIONS.md).

## Build (stock Mesa, no dot patch)

```sh
./build.sh                       # upstream main -> ./mesa, RADV-only, release
MESA_REF=mesa-25.0.0 ./build.sh
```

`build.sh` applies any patches in `patches/` — there are currently **none**
(the harmful dot patch was removed). The output `libvulkan_radeon.so` is a
drop-in via `VK_ICD_FILENAMES`; for gfx1013 the stock driver is the correct one.

## Repository layout

```
bc250-mesa/
├── README.md
├── build.sh
├── LICENSE
├── docs/
│   ├── GFX1013-DOT-HAZARD.md      # the dot hazard + evidence (read first)
│   ├── RDNA2-GFX1013-CAPS.md      # corrected capability map
│   └── WORKING-INSTRUCTIONS.md    # packed fp16 / mix / INT24 / DPP + exposure
└── examples/                      # working packed-fp16 / mix / int24 shaders
```

## License

MIT (this overlay). Mesa itself is MIT/X11-style.