// ============================================================
// Hermes GPU — Macros & Defines
// ============================================================

// --- Reset Macros ---
`define HERMES_RST_IF(rst, body) \
  if (!rst) begin                 \
    body                          \
  end

`define HERMES_RST_ELSE(body) \
  end else begin               \
    body                       \
  end

// --- Standard Values ---
`define HERMES_FP16_ONE    16'h3C00
`define HERMES_FP16_ZERO   16'h0000
`define HERMES_FP16_HALF   16'h3800
`define HERMES_FP16_TWO    16'h4000
`define HERMES_BF16_ONE    16'h3F80
`define HERMES_BF16_ZERO   16'h0000

// --- All Lanes Mask ---
`define HERMES_ALL_LANES  32'hFFFF_FFFF

// --- Tensor Core Tile Dimensions ---
`define HERMES_TILE_M   32
`define HERMES_TILE_N   32
`define HERMES_TILE_K   32

// --- Pipeline Stage Counts ---
`define HERMES_FETCH_STAGES  1
`define HERMES_DECODE_STAGES 1
`define HERMES_EXEC_STAGES   4  // Tensor ops multi-cycle
`define HERMES_WB_STAGES     1

// --- Shared Memory Size (bytes) ---
`define HERMES_SMEM_SIZE_KB  64
`define HERMES_SMEM_SIZE_B   (`HERMES_SMEM_SIZE_KB * 1024)

// --- Warp Lane Debug ---
`define HERMES_LANE_ID(lane)   (lane[4:0])

// --- Assertion helpers ---
`ifndef HERMES_ASSERT
  `define HERMES_ASSERT(cond, msg) \
    assert (cond) else $error(msg)
`endif

// --- Format string helpers ---
`define HERMES_FMT_STR(f) \
  (f == 2'b00 ? "FP16" :  \
   f == 2'b01 ? "BF16" :  \
   f == 2'b10 ? "INT8" :  \
                "INVALID")

// --- VCS / Verilator compatibility ---
`ifdef VERILATOR
  `define HERMES_PRINTF $write
`else
  `define HERMES_PRINTF $display
`endif

// --- Debug display control ---
`ifdef HERMES_DEBUG
  `define HERMES_DBG(msg) $display msg
`else
  `define HERMES_DBG(msg)
`endif
