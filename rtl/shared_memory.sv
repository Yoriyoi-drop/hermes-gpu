import hermes_pkg::*;

module shared_memory (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic        wr,
  input  logic [SHARED_ADDR_W-1:0] addr,
  input  logic [511:0] wdata,
  input  logic [31:0]  lane_mask,
  output logic [511:0] rdata,
  output logic         done,
  output logic [4:0]   conflict_cycles
);

  smem_bank_conflict u_smem (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (en),
    .wr    (wr),
    .addr  (addr),
    .wdata (wdata),
    .lane_mask (lane_mask),
    .rdata (rdata),
    .done  (done),
    .conflict_cycles (conflict_cycles)
  );

endmodule
