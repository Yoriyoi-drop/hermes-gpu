module register_file (
  input  logic        clk,
  input  logic        rst_n,
  // Warp select
  input  logic [4:0]  warp_id,
  // Read ports (3-read for SIMT: rs1, rs2, rs3)
  input  logic [4:0]  rd_addr_1,
  input  logic [4:0]  rd_addr_2,
  input  logic [4:0]  rd_addr_3,
  output logic [15:0] rd_data_1 [0:31],  // Per-lane
  output logic [15:0] rd_data_2 [0:31],
  output logic [15:0] rd_data_3 [0:31],
  // Write port
  input  logic        wr_en,
  input  logic [4:0]  wr_addr,
  input  logic [15:0] wr_data [0:31],
  input  logic [31:0] wr_lane_mask,    // Which lanes write
  // Context save/restore
  input  logic        ctx_ld_en,
  input  logic [9:0]  ctx_ld_addr,     // 0..1023
  input  logic [15:0] ctx_ld_data [0:31],
  output logic [15:0] ctx_rd_data [0:31]
);

  // Register file storage: NUM_WARPS x 1024 x 32 lanes
  logic [15:0] regs [0:NUM_WARPS-1][0:REGS_PER_WARP-1][0:WARP_SIZE-1];

  // Read: combinational (async read, sync write)
  always_comb begin
    for (int l = 0; l < 32; l++) begin
      rd_data_1[l] = regs[warp_id[2:0]][rd_addr_1][l];
      rd_data_2[l] = regs[warp_id[2:0]][rd_addr_2][l];
      rd_data_3[l] = regs[warp_id[2:0]][rd_addr_3][l];
      ctx_rd_data[l] = regs[warp_id[2:0]][ctx_ld_addr][l];
    end
  end

  // Write: sequential (same warp_id as read)
  always_ff @(posedge clk) begin
    if (wr_en) begin
      for (int l = 0; l < 32; l++) begin
        if (wr_lane_mask[l])
          regs[warp_id[2:0]][wr_addr][l] <= wr_data[l];
      end
    end
    if (ctx_ld_en) begin
      for (int l = 0; l < 32; l++)
        regs[warp_id[2:0]][ctx_ld_addr][l] <= ctx_ld_data[l];
    end
  end

endmodule
