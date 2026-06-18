# Hermes GPU — AGENTS.md

AI-focused high-compute GPU in SystemVerilog. SIMT pipeline with 8 warps, 32x32 systolic array (1024 MACs), multi-level cache hierarchy, FP16/BF16/INT8 support.

## Quick start

```bash
make lint          # Recommended: lint with Verilator
make lint-strict   # Strict lint (-Wall -Werror)
make sim           # Build Verilator C++ sim + run self-checking testbench
make wave          # Sim + open waveform (gtkwave/surfviz)
make fpga-synth    # Vivado synthesis (target: xc7a200tfbg676-2)
```

## Build system

- **Makefile** only. No package manager, npm, or language-specific build tool.
- Tools are system-installed: `verilator`, `iverilog`, `vivado`.
- Icarus (`make build-icarus`) may hang on the 32x32 systolic array generate block. Prefer Verilator.
- Verilator build outputs C++ executable at `build/Vtb_hermes_gpu`.
- VCD waveform written to `hermes_gpu.vcd` (not `build/`).
- `make distclean` removes `build/`, `reports/`, and all waveform files.

## Architecture

- **`rtl/hermes_gpu.sv`** — top module, AXI-lite host interface + AXI-full DRAM interface
- **`rtl/hermes_pkg.sv`** — all typedefs, parameters, opcodes, structs (single source of truth)
- **`rtl/warp_scheduler.sv`** — round-robin scheduler for 8 warps
- **`rtl/tensor_core.sv`** — 32x32 matrix multiply-accumulate, wraps `systolic_array_32x32`
- **`rtl/vector_unit.sv`** — per-lane VADD/VSUB/VMUL/VRELU/VSIGMOID/VTANH/VCONV
- **`rtl/scalar_unit.sv`** — scalar ops including branch (SADD/SSUB/SMUL/SMOV/SBRA)
- **`rtl/mem_hierarchy.sv`** — arbiter → TLB + shared memory + L1 → L2 → DRAM (AXI)
- **`rtl/register_file.sv`** — 8 warps × 1024 regs × 32 lanes, 3-read 1-write
- **`rtl/instruction_decoder.sv`** — 64-bit instruction word decode

## Memory hierarchy

```
Warp request → Arbiter → [TLB | Shared Memory | L1$ (16KB 4-way)]
                         → L2$ (128KB 8-way) → DRAM (AXI 512-bit)
```

## Instruction format (64-bit)

```
[63:59] opcode  | [58:57] fmt  | [56] pred  | [55:51] rd
[50:46] rs1     | [45:41] rs2  | [40:39] wgpr_sel | [31:0] imm
```

Instructions packed 8 per 512-bit DRAM word. PC increments by 8. Instruction at address X is at `DRAM[X>>6]` bits `(X[5:3] * 64) +: 64`.

## Opcodes

- **Tensor**: `OP_MMA`
- **Vector**: `OP_VADD`, `OP_VSUB`, `OP_VMUL`, `OP_VRELU`, `OP_VSIGMOID`, `OP_VTANH`, `OP_VCONV`
- **Scalar**: `OP_SADD`, `OP_SSUB`, `OP_SMUL`, `OP_SMOV`, `OP_SBRA`
- **Memory**: `OP_LD`, `OP_ST`, `OP_LDS`, `OP_STS`
- **Sync**: `OP_BAR`, `OP_EXIT`, `OP_NOP`

## Testing

- Single self-checking testbench: `rtl/tb_hermes_gpu.sv`
- Inlined test vectors (hardcoded instructions + expected register values), no external test files.
- Tests a vector kernel (VADD + VSUB + VMUL + VRELU + LD/ST loop).
- Debug display: compile with `+define+HERMES_DEBUG` or uncomment `\`define HERMES_DEBUG` in the testbench.
- Timeout at 2000 simulation time units (2000000 Verilator ticks).

## FPGA (Vivado)

- Target part: `xc7a200tfbg676-2` (Artix-7 200T)
- Scripts: `scripts/vivado_create.tcl`, `scripts/vivado_synth.tcl`
- Constraints: `constraints/hermes.xdc` (100 MHz clock, 10ns period)
- Outputs: `synth/output/` (checkpoint + timing/utilization reports)
- Create project first: `make fpga-project`, then `make fpga-synth`

## Key files

| Path | Purpose |
|---|---|
| `Makefile` | Build/lint/sim/synth orchestration |
| `rtl/hermes_pkg.sv` | Parameters, types, opcodes |
| `rtl/tb_hermes_gpu.sv` | Self-checking testbench |
| `sim_main.cpp` | Verilator C++ wrapper (VCD tracing) |
| `scripts/vivado_*.tcl` | FPGA project creation + synthesis |
| `constraints/hermes.xdc` | Timing constraints |
| `reports/lint.rpt` | Verilator lint output |

## Gotchas

- No git repo, no CI. No `.gitignore`.
- The testbench has a hardcoded `#2000` timeout — cannot simulate beyond that without patch.
- Writing new test kernels requires understanding the instruction-to-DRAM packing scheme (see tb_hermes_gpu.sv:108-164).
- `\`HERMES_DBG` debug macros are controlled by `\`define HERMES_DEBUG` (defined in testbench, not in headers).
- VCD trace files can be large (full 2000ns at 1ps resolution = 2M ticks).
