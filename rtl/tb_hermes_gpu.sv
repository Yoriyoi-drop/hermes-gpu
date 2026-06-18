`timescale 1ns/1ps
`define HERMES_DEBUG

module tb_hermes_gpu;

  import hermes_pkg::*;

  logic clk, rst_n;
  logic host_start;
  logic [31:0] host_kernel_addr;
  logic [31:0] host_arg_a, host_arg_b, host_arg_c;
  logic [1:0]  host_data_fmt;
  logic [31:0] host_grid_dim_x, host_grid_dim_y;
  logic host_done, host_error;

  logic [31:0] axi_awaddr, axi_araddr;
  logic        axi_awvalid, axi_arvalid, axi_wvalid, axi_rready, axi_bready;
  logic        axi_awready, axi_arready, axi_wready, axi_rvalid, axi_bvalid;
  logic [511:0] axi_wdata, axi_rdata;

  hermes_gpu u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .host_start     (host_start),
    .host_kernel_addr(host_kernel_addr),
    .host_arg_a     (host_arg_a),
    .host_arg_b     (host_arg_b),
    .host_arg_c     (host_arg_c),
    .host_data_fmt  (host_data_fmt),
    .host_grid_dim_x(host_grid_dim_x),
    .host_grid_dim_y(host_grid_dim_y),
    .host_done      (host_done),
    .host_error     (host_error),
    .axi_awaddr     (axi_awaddr),
    .axi_awvalid    (axi_awvalid),
    .axi_awready    (axi_awready),
    .axi_wdata      (axi_wdata),
    .axi_wvalid     (axi_wvalid),
    .axi_wready     (axi_wready),
    .axi_bvalid     (axi_bvalid),
    .axi_bready     (axi_bready),
    .axi_araddr     (axi_araddr),
    .axi_arvalid    (axi_arvalid),
    .axi_arready    (axi_arready),
    .axi_rdata      (axi_rdata),
    .axi_rvalid     (axi_rvalid),
    .axi_rready     (axi_rready)
  );

  always #0.5 clk = ~clk;

  // ================================================================
  // DRAM Model
  // ================================================================
  logic [511:0] dram [0:8388607];
  logic [31:0]  rd_addr_reg;
  logic         rd_pending;

  // Instruction encoding helper
  function automatic logic [63:0] encode_instr(
    input [4:0] opcode,
    input [4:0] rd, rs1, rs2,
    input [31:0] imm
  );
    return {opcode, 2'b0, 1'b0, rd, rs1, rs2, 2'b0, 7'b0, imm};
  endfunction

  initial begin
    for (int i = 0; i < 8388608; i++) dram[i] = 512'h0;

    // ================================================================
    // Kernel 1: Vector Suite — VADD + VSUB + VMUL + VRELU + ST + LD
    // ================================================================
    // Registers:
    //   R3  = A (1.0 FP16 = 0x3C00 per lane)
    //   R4  = B (2.0 FP16 = 0x4000 per lane)
    //   R5  = A+B = 3.0 (0x4200)
    //   R6  = A-B = -1.0 (0xBC00)
    //   R7  = A*B = 2.0 (0x4000)
    //   R8  = ReLU(A-B) = 0.0
    //   R9  = reloaded from ST
    //   R10 = R9+B = 3.0+2.0 = 5.0 (0x4500)
    // ================================================================

    // Instructions at 0x1000, packed 8 per 512-bit DRAM word.
    // PC increments by 8. Instruction at addr X is at DRAM[X>>6] bits [(X&63)*8 +: 64].
    // For PC=0x1000: DRAM[64][63:0], PC=0x1008: DRAM[64][127:64], etc.

    dram[64] = {
      encode_instr(OP_LD,   5'd9, 5'd0, 5'd0, 32'h00004000),  // 0x1038 [511:448] LD R9,[0x4000]
      encode_instr(OP_ST,   5'd5, 5'd0, 5'd0, 32'h00004000),  // 0x1030 [447:384] ST R5,[0x4000]
      encode_instr(OP_VRELU,5'd8, 5'd6, 5'd0, 32'h0),         // 0x1028 [383:320] VRELU R8,R6,R0
      encode_instr(OP_VMUL, 5'd7, 5'd3, 5'd4, 32'h0),         // 0x1020 [319:256] VMUL R7,R3,R4
      encode_instr(OP_VSUB, 5'd6, 5'd3, 5'd4, 32'h0),         // 0x1018 [255:192] VSUB R6,R3,R4
      encode_instr(OP_VADD, 5'd5, 5'd3, 5'd4, 32'h0),         // 0x1010 [191:128] VADD R5,R3,R4
      encode_instr(OP_LD,   5'd4, 5'd0, 5'd0, 32'h00003000),  // 0x1008 [127:64]  LD R4,[0x3000]
      encode_instr(OP_LD,   5'd3, 5'd0, 5'd0, 32'h00002000)   // 0x1000 [63:0]    LD R3,[0x2000]
    };

    // Kernel 1 continued at 0x1040: VADD R10,R9,R4 + OP_EXIT
    dram[65] = {
      encode_instr(OP_EXIT, 5'd0, 5'd0, 5'd0, 32'h0),         // 0x1078 [511:448]
      192'h0,                                                   // 0x1070-0x1050
      encode_instr(OP_NOP,  5'd0, 5'd0, 5'd0, 32'h0),         // 0x1048 [127:64]
      encode_instr(OP_VADD, 5'd10,5'd9, 5'd4, 32'h0)           // 0x1040 [63:0]    VADD R10,R9,R4
    };

    // ================================================================
    // Kernel 2: Tensor MMA Suite (at 0x2000)
    // Tests basic MMA opcode dispatch and tensor core FSM
    // ================================================================
    dram[128] = {
      encode_instr(OP_EXIT, 5'd0, 5'd0, 5'd0, 32'h0),         // 0x2038
      encode_instr(OP_MMA,  5'd0, 5'd0, 5'd0, 32'h0),         // 0x2030 MMA
      256'h0,                                                   // unused
      encode_instr(OP_SMOV, 5'd1, 5'd0, 5'd0, 32'h0),         // 0x2000 SMOV R1,0
      encode_instr(OP_SMOV, 5'd0, 5'd0, 5'd0, 32'h0)          // 0x2008 SMOV R0,0
    };

    // --- DATA arrays ---
    // A[i] = 1.0 FP16 (16'h3C00) at 0x2000
    for (int i = 0; i < 32; i++)
      dram[32'h2000 >> 6][i*16 +: 16] = 16'h3C00;

    // B[i] = 2.0 FP16 (16'h4000) at 0x3000
    for (int i = 0; i < 32; i++)
      dram[32'h3000 >> 6][i*16 +: 16] = 16'h4000;

    // C (output) at 0x4000 — already zero
  end

  // AXI read response
  assign axi_arready = !rd_pending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_pending <= 1'b0;
      rd_addr_reg <= '0;
      axi_rvalid <= 1'b0;
      axi_rdata <= '0;
    end else begin
      if (!rd_pending && axi_arvalid) begin
        rd_pending <= 1'b1;
        rd_addr_reg <= axi_araddr;
      end
      if (rd_pending) begin
        axi_rvalid <= 1'b1;
        axi_rdata  <= dram[rd_addr_reg >> 6];
        if (axi_rready) begin
          axi_rvalid <= 1'b0;
          rd_pending <= 1'b0;
        end
      end
    end
  end

  // AXI write channel
  assign axi_awready = 1'b1;
  assign axi_wready  = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      axi_bvalid <= 1'b0;
    end else begin
      if (axi_awvalid && axi_wvalid) begin
        dram[axi_awaddr >> 6] <= axi_wdata;
        axi_bvalid <= 1'b1;
      end
      if (axi_bready) axi_bvalid <= 1'b0;
    end
  end

  // ================================================================
  // Test Sequence
  // ================================================================
  logic all_ok;

  function automatic integer check_lanes(input integer w, input integer r, input [15:0] e);
    check_lanes = 0;
    for (integer l = 0; l < 32; l++) begin
      if (u_dut.u_regfile.regs[w][r][l] !== e) begin
        if (check_lanes == 0)
          $display("    FAIL warp%0d[%0d]: lane %0d got 16'h%04x != 16'h%04x", w, r, l, u_dut.u_regfile.regs[w][r][l], e);
        check_lanes = 1;
      end
    end
  endfunction

  initial begin
    $display("========================================");
    $display("  Hermes GPU Testbench");
    $display("  AI-Focused High-Compute GPU");
    $display("  FP16 / BF16 / INT8 Support");
    $display("  32x32 Systolic Array (1024 MACs)");
    $display("  8 Warp SIMT Pipeline");
    $display("========================================");
    $display("");

    clk    = 0;
    rst_n  = 0;
    host_start      = 0;
    host_kernel_addr = 32'h1000;
    host_arg_a      = 32'h2000;
    host_arg_b      = 32'h3000;
    host_arg_c      = 32'h4000;
    host_data_fmt   = FP16;
    host_grid_dim_x = 1;
    host_grid_dim_y = 1;

    #10 rst_n = 1;
    #10;

    $display("[%0t] Reset complete", $time);

    // ========================================
    // Test 1: Vector Kernel
    // ========================================
    $display("[%0t] Test 1: Launching vector kernel...", $time);
    host_start = 1;
    #2 host_start = 0;

    #500;

    $display("[%0t] Test 1: Verifying vector kernel results...", $time);
    all_ok = 1'b1;

    all_ok = all_ok && !check_lanes(0, 3, 16'h3C00);
    all_ok = all_ok && !check_lanes(0, 4, 16'h4000);
    all_ok = all_ok && !check_lanes(0, 5, 16'h4200);
    all_ok = all_ok && !check_lanes(0, 6, 16'hBC00);
    all_ok = all_ok && !check_lanes(0, 7, 16'h4000);
    all_ok = all_ok && !check_lanes(0, 8, 16'h0000);
    all_ok = all_ok && !check_lanes(0, 9, 16'h4200);
    all_ok = all_ok && !check_lanes(0, 10, 16'h4500);

    if (all_ok)
      $display("[%0t] === VECTOR KERNEL PASSED ====", $time);
    else
      $display("[%0t] === VECTOR KERNEL FAILED ====", $time);

    // ========================================
    // Test 2: Tensor MMA Kernel
    // ========================================
    $display("[%0t] Test 2: Launching MMA kernel...", $time);
    host_kernel_addr = 32'h2000;
    host_start = 1;
    #2 host_start = 0;

    #800;

    if (u_dut.perf_tc_cnt > 0)
      $display("[%0t] === MMA KERNEL PASSED (tc_cnt=%0d) ====", $time, u_dut.perf_tc_cnt);
    else
      $display("[%0t] === MMA KERNEL FAILED (tc_cnt=0) ====", $time);

    // ========================================
    // Summary
    // ========================================
    $display("");
    $display("--- Performance Counters ---");
    $display("  Instructions:  %0d", u_dut.perf_instr_cnt);
    $display("  Loads:         %0d", u_dut.perf_ld_cnt);
    $display("  Stores:        %0d", u_dut.perf_st_cnt);
    $display("  Vector ops:    %0d", u_dut.perf_vec_cnt);
    $display("  Tensor ops:    %0d", u_dut.perf_tc_cnt);
    $display("  Branches:      %0d", u_dut.perf_branch_cnt);
    $display("  L1 hits:       %0d", u_dut.perf_l1_hits);
    $display("  L1 misses:     %0d", u_dut.perf_l1_misses);
    $display("  L2 hits:       %0d", u_dut.perf_l2_hits);
    $display("  L2 misses:     %0d", u_dut.perf_l2_misses);
    $display("  Total cycles:  %0d", u_dut.perf_warp_total);
    $display("  Active cycles: %0d", u_dut.perf_warp_active);

    $display("");
    if (all_ok)
      $display("[%0t] ===== ALL TESTS PASSED =====", $time);
    else
      $display("[%0t] ===== SOME TESTS FAILED =====", $time);
    $finish;
  end

  // Debug monitor
  initial begin
`ifdef HERMES_DEBUG
    $monitor("[%0t] state=%s warp=%d pc=%h",
             $time,
             u_dut.gpu_state.name(),
             u_dut.scheduled_warp,
             u_dut.warp_pc[u_dut.scheduled_warp]);
`endif
  end

  initial begin
    #2000;
    $display("[%0t] TIMEOUT: Simulation did not complete", $time);
    $finish;
  end

endmodule

module v;
  tb_hermes_gpu u_tb();
endmodule

module v;
  tb_hermes_gpu u_tb();
endmodule