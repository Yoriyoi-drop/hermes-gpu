import hermes_pkg::*;

module crossbar (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        core_req_valid [0:NUM_CORES-1],
  input  logic        core_req_write [0:NUM_CORES-1],
  input  logic [31:0] core_req_addr [0:NUM_CORES-1],
  input  logic [511:0] core_req_wdata [0:NUM_CORES-1],
  output logic        core_req_ready [0:NUM_CORES-1],
  output logic [511:0] core_rsp_rdata [0:NUM_CORES-1],
  output logic        core_rsp_rvalid [0:NUM_CORES-1],

  output logic        l2_req_valid,
  output logic        l2_req_write,
  output logic [31:0] l2_req_addr,
  output logic [511:0] l2_req_wdata,
  input  logic        l2_req_ready,
  input  logic [511:0] l2_rsp_rdata,
  input  logic        l2_rsp_rvalid
);

  logic [$clog2(NUM_CORES)-1:0] sel_core;
  logic [$clog2(NUM_CORES)-1:0] rr_ptr;
  logic                         any_req;

  always_comb begin
    any_req = 1'b0;
    sel_core = '0;
    for (int c = 0; c < NUM_CORES; c++) begin
      if (core_req_valid[(rr_ptr + c) % NUM_CORES] && !any_req) begin
        sel_core = (rr_ptr + c) % NUM_CORES;
        any_req = 1'b1;
      end
    end
  end

  logic [$clog2(NUM_CORES)-1:0] rsp_core;
  logic                         rsp_pending;

  assign l2_req_valid = any_req;
  assign l2_req_write = core_req_write[sel_core];
  assign l2_req_addr  = core_req_addr[sel_core];
  assign l2_req_wdata = core_req_wdata[sel_core];

  always_comb begin
    for (int c = 0; c < NUM_CORES; c++) begin
      core_req_ready[c]   = l2_req_ready && (c == sel_core) && core_req_valid[c];
      core_rsp_rdata[c]   = (c == rsp_core) ? l2_rsp_rdata : '0;
      core_rsp_rvalid[c]  = (c == rsp_core) ? l2_rsp_rvalid : 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr_ptr     <= '0;
      rsp_core   <= '0;
      rsp_pending <= 1'b0;
    end else begin
      if (any_req && l2_req_ready) begin
        rr_ptr     <= sel_core + 1'b1;
        rsp_core   <= sel_core;
        rsp_pending <= 1'b1;
      end
      if (l2_rsp_rvalid) begin
        rsp_pending <= 1'b0;
      end
    end
  end

endmodule