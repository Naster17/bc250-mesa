# RDNA2 / gfx1013 (AMD BC-250) capability audit

What the BC-250's GPU (CHIP_GFX1013, PS5 "Oberon", RDNA2-class / GFX10_3) actually
supports, what Mesa/RADV exposes, and what is gated. Verified against the ACO
opcode table (`src/amd/compiler/aco_opcodes.py`) and `vulkaninfo` on the patched
driver.

## Dot-product instructions (the LLM-relevant ones)

| Instruction | ACO opcode | gfx10 encoding | RDNA2? | Vulkan exposure |
|-------------|-----------|----------------|--------|-----------------|
| int8 dot4 signed | `v_dot4_i32_i8` | 0x16 | YES | `integerDotProduct8BitSignedAccelerated` |
| int8 dot4 unsigned | `v_dot4_u32_u8` | 0x17 | YES | `integerDotProduct8BitUnsignedAccelerated` |
| int8 dot4 accumulate | `v_dot4c_i32_i8` | 0x0d | YES | (saturating accumulate variant) |
| **int16 dot2 signed** | `v_dot2_i32_i16` | 0x14 | YES | `integerDotProduct16BitSignedAccelerated` |
| **int16 dot2 unsigned** | `v_dot2_u32_u16` | 0x15 | YES | `integerDotProduct16BitUnsignedAccelerated` |
| fp16 dot2 (f32 acc) | `v_dot2_f32_f16` | 0x13 | YES | `VK_VALVE_shader_mixed_float_dot_product` |
| fp16 dot2 accumulate | `v_dot2c_f32_f16` | 0x02 | YES | (VALVE) |
| **int4 dot8 signed** | `v_dot8_i32_i4` | 0x18 | YES | **NONE** (no 4-bit category in VK_KHR_shader_integer_dot_product) |
| **int4 dot8 unsigned** | `v_dot8_u32_u4` | 0x19 | YES | **NONE** |
| int8 mixed signedness (sudot) | `v_dot4_i32_iu8` | gfx11 only | NO | `...8BitMixedSignednessAccelerated = false` (correct) |
| int4 mixed signedness | `v_dot8_i32_iu4` | gfx11 only | NO | false (correct) |
| bf16 dot2 | `v_dot2_f32_bf16` | gfx11 only | NO | false (correct) |
| fp8 dot4 | `v_dot4_f32_fp8_*` | gfx11_7 only | NO | false (correct) |
| int32/int64 dot | — | none | NO | false (correct) |

Key point: the original Mesa bug was excluding **all** of GFX1013 from
`has_accelerated_dot_product` (lumping it with RDNA1). The `bc250-mesa` patch
removes that exclusion, enabling int8 dot4, int16 dot2 and fp16 dot2 — all of
which the hardware has. The mixed-signedness/bf16/fp8 gates (`gfx11plus`) are
**correct**: those instructions genuinely do not exist on RDNA2.

## Other features (all already exposed on gfx1013)

- `shaderFloat16`, `shaderInt8`, `shaderInt16`, `shaderInt64` = true.
- `shaderSubgroupExtendedTypes`, `subgroupSizeControl`, `shaderSubgroupRotate`,
  `shaderSubgroupRotateClustered` = true (wave32/64).
- `shaderSharedFloat32AtomicAdd` = true (LDS atomic add f32, GFX8+).
- `shaderBufferFloat32Atomics` = true (exchange/min/max), but
  **`shaderBufferFloat32AtomicAdd` = false** — `buffer_atomic_add_f32` is a
  **gfx11-only** opcode (0x56). RDNA2 has no buffer atomic-add-f32 instruction,
  so atomic-float split-K via buffer atomics is NOT possible here. (Shared/LDS
  atomic add f32 works, but that is workgroup memory, not device buffers.)
- `VK_VALVE_shader_mixed_float_dot_product` = enabled (via the int-dot patch).
- Cooperative matrix / WMMA: **none** (RDNA3+). `matrix cores: none` is correct.

## Untapped hardware instruction: int4 dot8

`v_dot8_i32_i4` / `v_dot8_u32_u4` exist on RDNA2 (gfx10 0x18/0x19) but have **no
Vulkan feature** exposing them (the integer-dot-product extension only covers
8/16/32/64-bit). To use them you must emit the SPIR-V opcode directly (custom
shader, ACO will lower it to the gfx10 instruction). Potential: 8 int4 lanes per
instruction vs 4 int8 lanes — relevant to Q4_0/Q4_K matvec if a custom kernel
packs nibbles into the dot operands. This is a llama.cpp shader project, not a
Mesa feature toggle.

## GLSL toolchain note (int16 dot2)

- `GL_EXT_integer_dot_product` (glslang) lowers int8 dot4 to `OpSDot`/`OpUDot`
  (SPV_KHR_integer_dot_product). ggml's MMQ shaders use this and work (~4.3x).
- int16 dot2 in GLSL uses **`dotEXT(i16vec2, i16vec2)`** from
  `GL_EXT_integer_dot_product` (NOT `dot()` — that resolves to the float builtin
  and is ambiguous; there is no `GL_KHR_shader_integer_dot_product` GLSL
  extension). Verified: stock Alpine glslang 16.2 emits `OpSDot` +
  `DotProductInputAll`, `spirv-val --target-env vulkan1.2` passes. No toolchain
  upgrade needed. `dotAccSatEXT` gives the accumulating-saturating form.
- ggml targets `--target-env=vulkan1.2` (SPIR-V 1.5 + SPV_KHR_integer_dot_product);
  coopmat2 shaders use vulkan1.3.

## Bottom line

After the bc250-mesa int-dot patch, Mesa exposes **everything standard that
RDNA2 supports**. There is no further standard feature to "unlock" — the
remaining gates (sudot/bf16/fp8/buffer-atomic-add-f32/coopmat) are correct
because the instructions are RDNA3+. The only extra hardware capability is
**int4 dot8**, which needs a custom SPIR-V kernel (no Vulkan feature). int16 dot2
is fully usable today via `dotEXT` (hardware + driver + stock glslang all support
it); ggml just has no int16 quant format consuming it yet.

## What ggml already exploits (verified in the fork)

- **int8 dot4**: MMQ matmul/matvec (`mul_mat_vecq.comp` / `mul_mmq*.comp`,
  `GL_EXT_integer_dot_product` -> `OpSDot`). The ~4.3x MoE matvec / +30% pp win.
- **fp16 dot2**: scalar flash-attention QK/PV dots use `dot_product()` from
  `dot_product_funcs.glsl`, which lowers to `v_dot2_f32_f16` when `DOT2_F16` is
  set (shader-gen sets it for the fp16 FA path; `device->dot2_f16` true on bc250).
- **packed fp16 FMA**: `ACC_F16` path uses `f16vec2` packed `fma` (2x rate).
- **int16 dot2**: available (`dotEXT(i16vec2,i16vec2)` -> `OpSDot`, verified) but
  no ggml quant format consumes int16 operands, so unused.
- **int4 dot8**: hardware present, but `v_dot8_i32_i4` is int4 x int4; ggml
  activations are q8_1 (int8), so the operand types do not match -> no direct use.

## Sweep of remaining `false` features (nothing else to enable)

- `*NonUniformIndexingNative` = false on **all** RADV (emulated via waterfall
  loops; not a gfx1013 gate, would need RADV implementation work).
- fp16 buffer/shared atomics (`shaderBufferFloat16AtomicAdd`,
  `shaderSharedFloat16AtomicAdd`, ...) = false; no ACO `ds_add_f16` opcode ->
  hardware/ACO does not support fp16 atomic add.
- `shaderBufferFloat32AtomicAdd` = gfx11-only opcode (confirmed).
- mixed-signedness / int32 / int64 dot, bf16/fp8 dot, coopmat = RDNA3+ (correct).

**Conclusion: every standard instruction/feature RDNA2 supports is already
exposed by Mesa (after the int-dot patch) and already used by ggml where it
applies. There is no further instruction-level feature to add. The remaining
flint tg headroom is memory-bandwidth-bound (expert weight reads), not
instruction-bound.**