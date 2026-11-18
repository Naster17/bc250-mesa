# RDNA2 / gfx1013 (AMD BC-250) capability map — CORRECTED

Supersedes the earlier version of this file, which wrongly claimed the int-dot
patch enabled working hardware dot. See `GFX1013-DOT-HAZARD.md` for the evidence.

gfx1013 = PS5 "Oberon" / BC-250, a hybrid: GFX10.1 (RDNA1) ISA base + ray tracing,
**not** full GFX10.3 (RX 6000) RDNA2. Many "RDNA2" instructions are absent or
remapped on this part.

## Dot products — NOT functional (do not enable)

| Instruction | Full RDNA2 (gfx1030) | gfx1013 silicon |
|-------------|----------------------|-----------------|
| `v_dot4_i32_i8` / `v_dot4_u32_u8` (int8 dot4) | works | **writes zero** |
| `v_dot2_i32_i16` / `v_dot2_u32_u16` (int16 dot2) | works | **writes zero** |
| `v_dot8_i32_i4` / `v_dot8_u32_u4` (int4 dot8) | works | **writes zero** |
| `v_dot2_f32_f16` / `v_dot2c_f32_f16` (fp16 dot2) | works | **writes zero** |
| `v_dot4c_i32_i8` (int8 dot4 accumulate) | works | **SI legacy float min** |

`has_accelerated_dot_product` must stay **false** for `CHIP_GFX1013`.
`VK_KHR_shader_integer_dot_product` and `VK_VALVE_shader_mixed_float_dot_product`
are correctly unavailable. Enabling them makes llama.cpp produce ERR≈1.0 garbage
(verified). The stock Mesa exclusion is correct.

Note: this also means the FP16 `dot2` path (`v_dot2_f32_f16`) is NOT a usable
accelerator on gfx1013, despite being a real RDNA2 instruction. llama.cpp's
`DOT2_F16` codegen must not be relied on here; the packed-FMA fp16 path below is
the working one.

## Packed / mixed / integer math — WORKING (positive controls)

| Instruction | Rate vs FP32 | Use | Exposure |
|-------------|--------------|-----|----------|
| `v_pk_fma_f16`, `v_pk_add/mul/min/max_f16` | 2× | packed FP16 FMA | `VK_KHR_shader_float16_int8` + `VK_KHR_16bit_storage`; HIP half2 |
| `v_pk_add_i16`, `v_pk_mul_lo_u16`, `v_pk_*_i16` | 2× | packed INT16 | shaderInt16 + 16bit storage; HIP short2 |
| `v_fma_mix_f32`, `v_fma_mixlo/mixhi_f16` | 1× (free f16→f32) | mixed precision | shader float16; compiler autogen |
| `v_mul_i32_i24`, `v_mad_i32_i24` | 1× (vs 1/4× int32 mul) | INT24 address/scale math | compiler autogen; HIP `__builtin_amdgcn_mad_i32_i24` |
| `v_add3_u32`, `v_lshl_add_u32`, `v_and_or_b32`, `v_or3_b32` | 1× | 3-input address/bit math | compiler autogen |
| `v_bfe_u32/i32`, `v_bfi_b32`, `v_perm_b32`, `v_alignbyte_b32` | 1× | quant nibble/byte unpack, LUT | compiler autogen from shifts/masks; HIP `__builtin_amdgcn_perm`/`bfe` |
| SDWA (byte/word sub-dword addressing) | — | unpack without shifts | compiler autogen |
| `v_cvt_pkrtz_f16_f32`, `v_pack_b32_f16`, `v_cvt_pk_u8_f32`, `v_cvt_pk_i16_f32` | 1× | packed conversions / quantize | compiler autogen |
| `v_sad_u8`, `v_qsad_pk_u16_u8`, `v_mqsad_u32_u8`, `v_lerp_u8` | 1× | SAD / motion estimation | HIP `__builtin_amdgcn_sad` |

## Cross-lane / subgroup — WORKING

| Instruction | Use | Exposure |
|-------------|-----|----------|
| DPP16 (row shift/bcast/quad_perm/butterfly) | wave reductions, softmax/norm | subgroup ops; HIP `__builtin_amdgcn_mov_dpp`/`update_dpp` |
| DPP8 (gfx10 8-lane swizzle) | fine-grained shuffle | HIP `__builtin_amdgcn_mov_dpp8` |
| `v_permlane16_b32`, `v_permlanex16_b32` | cross-16-lane exchange | subgroup shuffle; HIP `__builtin_amdgcn_permlane16` |
| `ds_bpermute_b32`, `ds_permute_b32`, `ds_swizzle_b32` | full-wave gather/scatter | subgroup ops; HIP `__shfl`/`ds_bpermute` |
| `v_readfirstlane_b32`, `v_readlane_b32`, `v_mbcnt_lo_u32_b32` | VGPR→SGPR, compaction | compiler autogen |

## Memory / cache

- D16 loads (`global_load_short_d16`, `global_load_ubyte_d16`, ...) load 8/16-bit
  straight into a VGPR half — fewer registers, no unpack.
- `s_clause` groups consecutive VMEM/SMEM loads (GFX10+) — better weight streaming.
- Separate `s_waitcnt` vmcnt/vscnt — finer memory latency hiding.
- GLC/SLC/DLC cache flags; `s_inst_prefetch`.
- LDS: 128 KB/WGP, `ds_read_b128`/`ds_write_b128`, `ds_add_f32` (FP32 LDS atomic
  add works). **Global `atomic_add_f32` is RDNA3+** (absent here); global
  fmin/fmax/fcmpswap exist.
- **No Infinity Cache on BC-250** (that's discrete RX 6000; the APU shares GDDR6).

## Absent on gfx1013 (RDNA3+/CDNA only)

- BF16 (`v_dot2_f32_bf16`, packed bf16), FP8 dot, WMMA/cooperative matrix.
- Global buffer `atomic_add_f32` (`buffer_atomic_add_f32` is gfx11).
- fp16 buffer/shared atomics (no ACO `ds_add_f16`).
- True16 (independent 16-bit register halves) — RDNA3.
- `*NonUniformIndexingNative` — false on all RADV (emulated), not gfx1013-specific.

## Ray tracing

`image_bvh_intersect_ray` / `image_bvh64_intersect_ray` present (the RT addition
that distinguishes gfx1013 from plain GFX10.1). `VK_KHR_ray_query` /
`ray_tracing_pipeline`. Not relevant to LLM compute.

## Bottom line

The usable compute accelerators on gfx1013 are **packed FP16, mixed-precision
FMA, INT24, bit/byte unpack (BFE/PERM/SDWA), and DPP/permlane subgroup ops** —
all reached by compiler generation tests, no Mesa patch required. The dot
instructions are a hazard, not a feature. llama.cpp's FP16 path already uses the
working packed/mix instructions; its integer-dot MMQ path must stay disabled on
this chip (stock Mesa does this correctly).