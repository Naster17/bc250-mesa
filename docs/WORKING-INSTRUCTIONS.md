# Working accelerators on gfx1013 (BC-250) — practical guide

The dot instructions are a hazard (`GFX1013-DOT-HAZARD.md`). These instructions
are verified correct on the silicon and are the real compute levers. Most are
reached by compiler *generation tests*, not a chip feature list, so they work
without any Mesa patch.

## 1. Packed FP16 (2× rate) — the main LLM lever

`v_pk_fma_f16` does two FP16 FMAs per lane per cycle (256 FLOPs/cycle/CU vs 128
FP32). Requires packing two f16 into one 32-bit VGPR (f16x2); a scalar
`v_fma_f16` is NOT faster (RDNA2 has no True16).

- **Vulkan:** `VK_KHR_shader_float16_int8` (`shaderFloat16`) +
  `VK_KHR_16bit_storage` (`storageBuffer16BitAccess`). Use `f16vec2` arithmetic
  so ACO emits `v_pk_fma_f16`. ggml's `ACC_F16` path (`dot_product_funcs.glsl`)
  already does packed `fma(f16vec2, f16vec2, f16vec2)`.
- **HIP/ROCm:** `half2` / `__half2`, `__hfma2`. ROCm gfx1013 support is limited
  (RDNA2 iGPU); check `__builtin_amdgcn_*` availability per target.
- **llama.cpp:** the FP16 Vulkan path benefits already. Do NOT enable `DOT2_F16`
  (`v_dot2_f32_f16` writes zero on gfx1013) — packed FMA is the working route.

## 2. Mixed-precision FMA (free f16→f32)

`v_fma_mix_f32` takes three operands each independently FP32 / low-f16 / high-f16
(`op_sel`/`op_sel_hi`), widens to FP32 in hardware, FMA in FP32, one cycle. Removes
`v_cvt_f32_f16` overhead. `v_fma_mixlo_f16`/`mixhi` round to f16 into a VGPR half.

- Ideal for quantized inference: weights stored f16, accumulate in f32.
- Reached by ACO/LLVM from f16→f32 conversion + FMA patterns; no explicit API.
- ggml's dequant-to-f16 + f32-acc matmul maps here.

## 3. INT24 (full-rate integer multiply)

`v_mul_lo_u32` is 1/4 rate on RDNA2 (16 ops/cycle/CU). `v_mul_i32_i24` /
`v_mad_i32_i24` use the FP32 mantissa multiplier at FULL rate (64 MAD/cycle/CU).
Use for array offsets, quant block scaling, address math where operands fit 24
bits.

- Compiler autogen when it can prove 24-bit range; HIP
  `__builtin_amdgcn_mad_i32_i24` / `mul_i32_i24`.
- Relevant to quantized kernel index/scale arithmetic.

## 4. Bit/byte unpack (quant decode)

Q4/Q5/Q6/Q8 decoding is bit manipulation. These are full-rate and compiler-
friendly:

- `v_bfe_u32`/`v_bfe_i32` — extract a bit range (e.g. a 4-bit weight) with sign
  extension, one cycle.
- `v_bfi_b32` — bitfield insert `(S0&S1)|(~S0&S2)`, replaces mask/branch.
- `v_perm_b32` — byte permute/LUT (4 bytes from two regs + 0x00/0xFF/sign),
  ideal for INT8/INT4 repack and table lookups. HIP `__builtin_amdgcn_perm`.
- `v_alignbyte_b32`/`v_alignbit_b32` — unaligned word extract.
- **SDWA** — read/write byte/word halves of a VGPR with auto sext/zero, no manual
  shifts. ACO uses it automatically.

llama.cpp's quant dequant shaders already emit these via shift/mask patterns.

## 5. Packed conversions / quantize

`v_cvt_pkrtz_f16_f32` (2×f32→f16x2), `v_pack_b32_f16`, `v_cvt_pk_u8_f32`,
`v_cvt_pk_i16_f32`/`pknorm` — hardware packing with saturation for activation
quantization. Compiler autogen.

## 6. Subgroup / cross-lane (reductions, softmax, norm)

- **DPP16** — modifier on VALU ops, neighbor-lane src0 (shift/rotate 1–15, butterfly,
  quad_perm, row_bcast) with zero extra instructions. HIP
  `__builtin_amdgcn_mov_dpp`/`update_dpp`.
- **DPP8** — gfx10 8-lane swizzle. HIP `__builtin_amdgcn_mov_dpp8`.
- `v_permlane16_b32`/`v_permlanex16_b32` — exchange across the two 16-lane halves
  of a wave32 (DPP16 only sees its own half). HIP `__builtin_amdgcn_permlane16`.
- `ds_bpermute_b32`/`ds_permute_b32`/`ds_swizzle_b32` — full-wave gather/scatter
  via LDS crossbar. HIP `__shfl_xor` etc.
- `v_readfirstlane_b32`/`v_readlane_b32` (VGPR→SGPR), `v_mbcnt_lo_u32_b32`
  (active-lane count, stream compaction).

Vulkan: `VK_KHR_shader_subgroup_extended_types`, subgroup arithmetic/shuffle/ballot.
These accelerate Softmax/RMSNorm/LayerNorm/FlashAttention reductions and matmul
data reuse. ggml's subgroup reduction paths use them.

## 7. Memory streaming

- D16 loads (`global_load_short_d16`/`ubyte_d16`) load 8/16-bit into a VGPR half.
- `s_clause` groups consecutive loads (GFX10+) — better weight-stream arbitration.
- Separate vmcnt/vscnt wait counters — finer latency hiding.
- GLC/SLC/DLC cache hints. No Infinity Cache on the APU (shared GDDR6).

## What this means for projects

- **llama.cpp (Vulkan):** keep stock Mesa (int dot off). The FP16 packed/mix path
  and quant bit-unpack already use the working instructions. The remaining tg
  headroom is GDDR6 bandwidth (expert weight reads), not compute — pursue
  bandwidth/parallelism (split-K with a *software* reduce, smaller quants, expert
  pruning, RPC row-split), not dot instructions.
- **torch / ROCm (HIP):** gfx1013 is a limited ROCm target. Use `half2` packed
  math, INT24 intrinsics, DPP/permlane shuffles. Avoid `__builtin_amdgcn_sdot4`/
  `sdot2`/`sdot8`/`fdot2` — they map to the broken dot opcodes. Do not force
  `+dot*-insts` target features (clang silently drops the kernel).
- **Custom kernels:** the untapped upside is hand-written packed-FP16 GEMV +
  SDWA/PERM quant decode + DPP reductions, not integer dot.

## Sources

- D-Ogi/amdgpu-wddm `docs/gfx1013-isa.md` (silicon positive controls).
- AMD RDNA2 Shader ISA (GPUOpen, Nov 2020) — instruction rates/encodings.
- LLVM `VOP3PInstructions.td`, `AMDGPUAsmGFX1011` (gfx1013 rejects dot).
- This repo `GFX1013-DOT-HAZARD.md` (llama.cpp correctness verification).