# Hermes GPU

AI-focused high-compute GPU in SystemVerilog. A SIMT (Single-Instruction, Multiple-Thread) pipeline with 8 warps, a 32×32 systolic array (1024 MACs), multi-level cache hierarchy, and FP16/BF16/INT8 support.

## Features

- **SIMT pipeline** — 8 warps × 32 lanes, round-robin scheduling, predicated execution, SIMT stack for divergent branches
- **Tensor core** — 32×32 systolic array of MAC units for matrix multiply-accumulate (FP16/BF16/INT8)
- **Vector unit** — per-lane VADD/VSUB/VMUL/VRELU/VSIGMOID/VTANH/VCONV
- **Scalar unit** — SADD/SSUB/SMUL/SMOV/SBRA with branching support
- **Memory hierarchy** — warp arbiter → TLB + shared memory → L1$ (16KB 4-way) → L2$ (128KB 8-way) → DRAM (AXI 512-bit)
- **Register file** — 8 warps × 1024 registers × 32 lanes, 3-read 1-write
- **64-bit instruction format** — opcode, format, predication, 3 register operands, 32-bit immediate
- **FPGA-ready** — Vivado synthesis targeting Artix-7 200T (xc7a200tfbg676-2)

## Quick start

```bash
# Lint with Verilator (recommended)
make lint

# Run simulation (builds Verilator C++ sim + self-checking testbench)
make sim

# Simulate + view waveform
make wave

# Vivado synthesis
make fpga-project && make fpga-synth
```

## Requirements

- **Verilator** — for linting and simulation (`sudo apt install verilator`)
- **Vivado** — for FPGA synthesis (optional)
- **gtkwave** or **surfviz** — for waveform viewing (optional)
- **Icarus Verilog** — alternative simulator (may hang on large designs)

## Documentation

See [AGENTS.md](AGENTS.md) for detailed architecture, build system reference, and operational gotchas.

## Project structure

```
Makefile              # Build/lint/sim/synth orchestration
AGENTS.md             # Agent instructions (architecture + workflow)
rtl/
├── hermes_pkg.sv     # Parameters, types, opcodes (single source of truth)
├── hermes_gpu.sv     # Top module
├── tb_hermes_gpu.sv  # Self-checking testbench
├── warp_scheduler.sv # Round-robin warp scheduler
├── tensor_core.sv    # Matrix multiply-accumulate
├── systolic_array_32x32.sv  # 32×32 systolic MAC array
├── vector_unit.sv    # Vector ALU
├── scalar_unit.sv    # Scalar ALU + branch
├── mem_hierarchy.sv  # Memory system arbiter
├── l1_cache.sv       # L1 cache (16KB 4-way)
├── l2_cache.sv       # L2 cache (128KB 8-way)
├── shared_memory.sv  # Shared memory (32 banks)
├── tlb.sv            # TLB (64 entries)
├── register_file.sv  # Warp register file
└── instruction_decoder.sv  # 64-bit instruction decoder
sim_main.cpp          # Verilator C++ wrapper (VCD tracing)
scripts/              # Vivado TCL scripts
constraints/          # Timing constraints
```

## License

MIT
