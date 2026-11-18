# gfx1013 dot-product hazard (verified)

**The AMD BC-250 (gfx1013) does not implement the RDNA2 dot-product
instructions. Enabling them produces silently wrong results. Keep
`has_accelerated_dot_product = false` for `CHIP_GFX1013` in Mesa.**

## What the silicon does

gfx1013 is described by LLVM/Mesa as "GFX10.1 (RDNA1) plus ray tracing". That is
a target definition, not a measurement. Direct silicon probes (D-Ogi/amdgpu-wddm
`docs/gfx1013-isa.md`, BC-250 "unit A") issued the GFX10.1 dot opcodes and read
back every lane with a sentinel preload:

| Instruction | Encoding | LLVM feature | Result on gfx1013 |
|-------------|----------|--------------|-------------------|
| `v_dot2_f32_f16` | VOP3P 0x13 | dot10-insts | zero, every lane |
| `v_dot2_i32_i16` | VOP3P 0x14 | dot2-insts | zero, every lane |
| `v_dot2_u32_u16` | VOP3P 0x15 | dot2-insts | zero, every lane |
| `v_dot4_i32_i8` | VOP3P 0x16 | dot1-insts | zero, every lane |
| `v_dot4_u32_u8` | VOP3P 0x17 | dot7-insts | zero, every lane |
| `v_dot8_i32_i4` | VOP3P 0x18 | dot1-insts | zero, every lane |
| `v_dot8_u32_u4` | VOP3P 0x19 | dot7-insts | zero, every lane |
| `v_dot2c_f32_f16` | VOP2 0x02 | dot5-insts | zero, every lane |
| `v_dot4c_i32_i8` | VOP2 0x0d | dot6-insts | **SI legacy float MINIMUM** |

The VOP2 0x0d/0x0e slots still hold the SI/CI `V_MIN_LEGACY_F32` /
`V_MAX_LEGACY_F32` on this part; GFX10.1 reassigned them to dot opcodes "in the
documentation alone". So `v_dot4c_i32_i8` returns `(S0 < S1) ? S0 : S1`
interpreted as floats — a plausible number, not a dot product. **Worse than
zero.** No fault, no TDR, no timeout: the instruction retires and writes garbage.

Positive controls in the same probe (correct in all 4096 lanes):
`v_pk_fma_f16`, `v_fma_mix_f32`, `v_mul_i32_i24` (with SDWA). Packed FP16, mixed
precision and INT24 are real and usable; dot is not.

## Independent verification in this repo

llama.cpp `test-backend-ops -o MUL_MAT_ID -b Vulkan0` on the BC-250:

- **Stock driver** (`has_accelerated_dot_product=false`, int dot: 0):
  1160/1160 tests pass.
- **Patched driver** (exclusion removed, int dot: 1): ERR ≈ 1.0 for
  q4_K/q5_K/q6_K/q8_0/q3_K/iq3_s/iq4_xs, ERR = inf for iq4_nl. Essentially every
  result wrong.

A standalone Vulkan compute shader doing `dotPacked4x8EXT` /
`dotPacked4x8AccSatEXT` on gfx1013 returns 0 (the packed bytes are correct via
`pack32`, verified separately; the dot opcode itself writes zero). ACO emits
`v_dot4_i32_i8` / `v_dot4c_i32_i8` for these — the hardware just does not execute
them as dots.

**Side-by-side proof** (`examples/dot_hw_vs_manual.comp`, one shader emits both
hardware and manual dot per lane, inputs `a[i]=(i%7)-3`, `b[i]=(i%5)-2`):

| Driver | int8 pairs (hw, manual) per lane | int16 pairs (hw, manual) |
|--------|----------------------------------|--------------------------|
| int-dot ENABLED | (0,8) (0,-5) (0,-5) (0,1) (0,6) (0,-4) (0,-4) (0,-5) | (0,8) (0,0) (0,-2) (0,-3) (0,-4) (0,-1) (0,3) (0,-2) |
| STOCK (control) | (8,8) (-5,-5) (-5,-5) (1,1) (6,6) (-4,-4) (-4,-4) (-5,-5) | hw==manual (software) |

ISA dump confirms `v_dot4_i32_i8` / `v_dot2_i32_i16` are emitted on the enabled
driver. The manual column (same shader, same operands, same lanes) is correct;
the hardware column is **zero in every lane**. On stock, dot is lowered to
software so hw==manual — the positive control proving the harness is sound.

The earlier "~4.3× MoE matvec, +30% pp" claim came from `test-backend-ops perf`
(which times but does not check correctness) on the patched driver. Correctness
had only been checked on the stock driver. **Retracted.**

## Corroboration

- D-Ogi/amdgpu-wddm `docs/gfx1013-isa.md` + `facts/hardware.md` M865/M866.
- obl1vn/Unlock-ps5-pro-memory `docs/int8-dot4.md`: PS5 Pro hardware `v_dot4`
  returns 0 for all 262144 random probes; driver default (off) is correct.
- LLVM review D103663 (gfx1013 target): `v_dot2_f32_f16` → "instruction not
  supported on this GPU".
- Mesa `src/amd/compiler/aco_elf.cpp` asserts `!has_accelerated_dot_product` for
  this chip.

## Consequences

- **Do not** remove the `CHIP_GFX1013` exclusion in `ac_gpu_info.c`.
- **Do not** force `+dot1-insts`/`+dot2-insts`/... target features for gfx1013 in
  HIP/LLVM either — clang silently drops the kernel (D-Ogi toolchain trap M867).
- `VK_KHR_shader_integer_dot_product` and `VK_VALVE_shader_mixed_float_dot_product`
  must remain unavailable on gfx1013. llama.cpp then uses its correct software
  dot / FP16 paths.
- The real compute levers on this part are packed FP16, mixed-precision FMA and
  INT24 — see `WORKING-INSTRUCTIONS.md`.

## Open questions (from D-Ogi, unverified)

- Other undefined VOP1/VOP2/VOPC/VOP3/VOP3P opcode slots (a sweep may find more
  live SI-era instructions).
- The `op_sel` / VOP3P modifier forms of the dot opcodes (probe used plain forms).
- PS5-specific image/ML instructions public tools do not name (PSSR "300 TOPS"
  on PS5 Pro are separate, unknown instructions).