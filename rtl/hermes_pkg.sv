package hermes_pkg;

  // ============================================================
  // Hermes GPU — Parameter & Type Definitions
  // ============================================================

  // --- Data Format ---
  typedef enum logic [1:0] {
    FP16 = 2'b00,
    BF16 = 2'b01,
    INT8 = 2'b10
  } data_format_e;

  // --- Opcodes ---
  typedef enum logic [4:0] {
    // Tensor ops
    OP_MMA       = 5'b00000,  // Matrix multiply-accumulate
    // Vector ops
    OP_VADD      = 5'b01000,
    OP_VSUB      = 5'b01001,
    OP_VMUL      = 5'b01010,
    OP_VRELU     = 5'b01011,
    OP_VSIGMOID  = 5'b01100,
    OP_VTANH     = 5'b01101,
    OP_VCONV     = 5'b01110,  // Format conversion
    // Scalar ops
    OP_SADD      = 5'b10000,
    OP_SSUB      = 5'b10001,
    OP_SMUL      = 5'b10010,
    OP_SMOV      = 5'b10011,
    OP_SBRA      = 5'b10100,  // Branch
    // Memory ops
    OP_LD        = 5'b11000,
    OP_ST        = 5'b11001,
    OP_LDS       = 5'b11010,  // Load shared
    OP_STS       = 5'b11011,  // Store shared
    // Sync ops
    OP_BAR       = 5'b11100,  // Barrier
    OP_EXIT      = 5'b11110,  // Kernel exit
    OP_NOP       = 5'b11111
  } opcode_e;

  // --- Warp State ---
  typedef enum logic [1:0] {
    WARP_IDLE   = 2'b00,
    WARP_READY  = 2'b01,
    WARP_BLOCK  = 2'b10,  // Blocked on memory/barrier
    WARP_DONE   = 2'b11
  } warp_state_e;

  // --- Memory Space ---
  typedef enum logic [1:0] {
    MEM_GLOBAL  = 2'b00,
    MEM_SHARED  = 2'b01,
    MEM_UNIFORM = 2'b10
  } mem_space_e;

  // ============================================================
  // Parameters — Core
  // ============================================================
  localparam int WARP_SIZE       = 32;
  localparam int NUM_WARPS       = 8;
  localparam int NUM_CORES       = 2;
  localparam int SYSTOLIC_SIZE   = 32;
  localparam int REGS_PER_WARP   = 1024;
  localparam int REG_BANKS       = 32;

  localparam int SYS_ADDR_W      = 32;
  localparam int DATA_W          = 16;

  // ============================================================
  // Multi-Core Types
  // ============================================================
  typedef logic [3:0] core_id_t;

  typedef struct packed {
    logic        valid;
    core_id_t    core_id;
    logic [SYS_ADDR_W-1:0] kernel_addr;
    logic [31:0] arg_a, arg_b, arg_c;
    data_format_e fmt;
    logic [31:0] grid_dim_x, grid_dim_y;
    logic [31:0] cta_start_x, cta_start_y;
    logic [31:0] num_ctas;
  } workgroup_desc_t;

  // ============================================================
  // Parameters — Shared Memory
  // ============================================================
  localparam int SMEM_BANKS      = 32;
  localparam int SMEM_BANK_WORDS = 1024;
  localparam int SMEM_BANK_ADDR_W = 10;
  localparam int SHARED_ADDR_W   = 15;  // SMEM_BANK_ADDR_W + log2(BANKS) = 10+5

  // ============================================================
  // Parameters — Cache Hierarchy
  // ============================================================
  // L1: 16 KB, 4-way, 32B line → 128 sets
  localparam int L1_SIZE        = 16384;
  localparam int L1_LINE_BYTES  = 32;
  localparam int L1_WAYS        = 4;
  localparam int L1_SETS        = 128;    // 16KB / 4-way / 32B
  localparam int L1_TAG_W       = 20;     // 32 - (7+5) = 20
  localparam int L1_INDEX_W     = 7;      // log2(128 sets)
  localparam int L1_OFFSET_W    = 5;      // log2(32 bytes)

  // L2: 128 KB, 8-way, 64B line → 256 sets
  localparam int L2_SIZE        = 131072;
  localparam int L2_LINE_BYTES  = 64;
  localparam int L2_WAYS        = 8;
  localparam int L2_SETS        = 256;
  localparam int L2_TAG_W       = 18;     // 32 - (8+6) = 18
  localparam int L2_INDEX_W     = 8;      // log2(256)
  localparam int L2_OFFSET_W    = 6;      // log2(64)

  // ============================================================
  // Parameters — TLB
  // ============================================================
  localparam int TLB_ENTRIES    = 64;
  localparam int PAGE_SIZE      = 4096;
  localparam int PAGE_OFFSET_W  = 12;
  localparam int VPN_W          = 20;     // 32 - 12
  localparam int PPN_W          = 20;

  // ============================================================
  // Types
  // ============================================================
  typedef logic [15:0] fp16_t;
  typedef logic [15:0] bf16_t;
  typedef logic [7:0]  int8_t;
  typedef logic [31:0] fp32_t;

  typedef logic [4:0]  warp_id_t;
  typedef logic [4:0]  reg_idx_t;   // 32 regs visible per thread
  typedef logic [5:0]  thread_lane_t; // 0-31

  // --- Instruction Word (64-bit) ---
  typedef struct packed {
    opcode_e   opcode;
    data_format_e fmt;
    logic      pred;          // Predicated execution
    reg_idx_t  rd;            // Destination register
    reg_idx_t  rs1;           // Source register 1
    reg_idx_t  rs2;           // Source register 2
    logic [1:0] wgpr_sel;     // Which GPR bank (for >32 regs)
    logic [SYS_ADDR_W-1:0] imm; // Immediate / address offset
  } instr_t;

  // --- Warp Context ---
  typedef struct packed {
    warp_state_e state;
    logic [SYS_ADDR_W-1:0] pc;         // Program counter
    logic [SYS_ADDR_W-1:0] next_pc;
    logic [4:0]  warp_id;
    logic [SYS_ADDR_W-1:0] cta_id;     // Thread block ID
    logic [31:0] lane_mask;            // Active lane mask
    logic [REGS_PER_WARP-1:0][DATA_W-1:0] regfile;
  } warp_ctx_t;

  // --- Memory Transaction ---
  typedef struct packed {
    logic      valid;
    logic      write;
    mem_space_e space;
    logic [SYS_ADDR_W-1:0] addr;
    logic [DATA_W*WARP_SIZE-1:0] data;
    logic [3:0]  size;
    logic [WARP_SIZE-1:0] lane_mask;
    warp_id_t  warp_id;
  } mem_req_t;

  typedef struct packed {
    logic      valid;
    logic [DATA_W*WARP_SIZE-1:0] data;
    warp_id_t  warp_id;
  } mem_rsp_t;

  // --- Cache Line State ---
  typedef enum logic [1:0] {
    CACHE_INVALID = 2'b00,
    CACHE_SHARED  = 2'b01,
    CACHE_EXCLUSIVE = 2'b10,
    CACHE_MODIFIED  = 2'b11
  } cache_state_e;

  // --- TLB Entry ---
  typedef struct packed {
    logic      valid;
    logic      dirty;
    logic [VPN_W-1:0] vpn;
    logic [PPN_W-1:0] ppn;
  } tlb_entry_t;

  // --- Cache Miss Queue Entry ---
  typedef struct packed {
    logic      valid;
    logic      write;
    logic [SYS_ADDR_W-1:0] addr;
    logic [DATA_W*WARP_SIZE-1:0] data;
    warp_id_t  warp_id;
  } cache_miss_t;

endpackage
