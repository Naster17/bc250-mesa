# Dot-product examples (RDNA2 / gfx1013)

Minimal compute shaders exercising the integer dot instructions enabled by the
bc250-mesa patch. The builtin is **`dotEXT()`** from `GL_EXT_integer_dot_product`
(not `dot()`, which resolves to the floating-point builtin and is ambiguous).

| File | Instruction | ACO opcode | SPIR-V |
|------|-------------|-----------|--------|
| `int8_dot4.comp` | `dotEXT(i8vec4, i8vec4)` | `v_dot4_i32_i8` | `OpSDot` |
| `int16_dot2.comp` | `dotEXT(i16vec2, i16vec2)` | `v_dot2_i32_i16` | `OpSDot` + `DotProductInputAll` |

## Compile + validate

```sh
glslangValidator -V --target-env vulkan1.2 int8_dot4.comp  -o int8_dot4.spv
glslangValidator -V --target-env vulkan1.2 int16_dot2.comp -o int16_dot2.spv
spirv-val --target-env vulkan1.2 int8_dot4.spv
spirv-val --target-env vulkan1.2 int16_dot2.spv
spirv-dis int16_dot2.spv | grep -E 'OpSDot|DotProduct'   # confirm OpSDot emitted
```

Both compile with the stock Alpine glslang (16.2) and a current source-built
glslang. `--target-env vulkan1.2` maps to SPIR-V 1.5 + `SPV_KHR_integer_dot_product`.

## Notes

- `dotAccSatEXT(a, b, acc)` gives the accumulating-saturating form
  (`integerDotProductAccumulatingSaturating*Accelerated`, also enabled).
- Unsigned operands: `dotEXT(u8vec4, u8vec4)` / `dotEXT(u16vec2, u16vec2)`.
- Mixed signedness (`dotEXT(i8vec4, u8vec4)`) is **RDNA3-only** — do not use on
  gfx1013 (the feature is correctly reported false).
- fp16 dot2 uses a different path: `GL_VALVE_shader_mixed_float_dot_product`
  (`v_dot2_f32_f16`); ggml's `dot_product_funcs.glsl` wraps it as `dot_product()`.
- These are capability demonstrations; wiring them into a llama.cpp kernel is a
  separate effort (ggml currently consumes int8 dot4 via MMQ and fp16 dot2 via FA).