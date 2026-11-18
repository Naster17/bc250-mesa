# Examples — working gfx1013 accelerators

Compute shaders for instructions **verified correct** on BC-250/gfx1013 silicon.
The integer dot examples were removed: those opcodes write zero on this chip
(see `../docs/GFX1013-DOT-HAZARD.md`).

| File | Instruction | Rate | Notes |
|------|-------------|------|-------|
| `packed_fp16.comp` | `v_pk_fma_f16` | 2× FP32 | f16vec2 fma; the real fp16 lever |
| `int24_mad.comp` | `v_mad_i32_i24` | 1× (vs 1/4× int32 mul) | 24-bit operands |

## Compile + validate

```sh
glslangValidator -V --target-env vulkan1.2 packed_fp16.comp -o packed_fp16.spv
glslangValidator -V --target-env vulkan1.2 int24_mad.comp   -o int24_mad.spv
spirv-val --target-env vulkan1.2 packed_fp16.spv
```

Enable `shaderFloat16` + `storageBuffer16BitAccess` features for the fp16 shader.
Inspect the ISA with `RADV_DEBUG=shaders` and look for `v_pk_fma_f16` /
`v_mad_i32_i24`.

## Do NOT use on gfx1013

`dotEXT` / `dotPacked4x8EXT` / `dotPacked4x8AccSatEXT` (int8/int16 dot) and
`v_dot2_f32_f16` (fp16 dot2): the opcodes retire but write zero (or legacy float
min for `v_dot4c`). They are correct on full RDNA2 (gfx1030) but **not** on this
hybrid gfx1013 part. Keep `VK_KHR_shader_integer_dot_product` disabled.