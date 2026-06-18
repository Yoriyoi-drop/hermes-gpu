import hermes_pkg::*;

// 8-warp memory request arbiter (round-robin)
module mem_arbiter (
  input  logic        clk,
  input  logic        rst_n,
  // Request ports from warps
  input  mem_req_t    warp_req [0:7],
  output logic        warp_req_ready [0:7],
  // Response ports to warps
  output mem_rsp_t    warp_rsp [0:7],
  // Single output to memory subsystem
  output mem_req_t    mem_req,
  input  logic        mem_req_ready,
  input  mem_rsp_t    mem_rsp,
  output logic        mem_rsp_ready
);

  logic [7:0] rr_ptr;
  logic [7:0] gnt;
  logic       any_req;
  logic [4:0] selected_warp;
  logic       has_rsp;

  // Round-robin arbitration
  always_comb begin
    any_req = 1'b0;
    gnt = '0;
    selected_warp = '0;
    for (int i = 0; i < 8; i++) begin
      int idx = (rr_ptr + i) & 7;
      if (warp_req[idx].valid && !any_req) begin
        gnt[idx] = 1'b1;
        selected_warp = idx;
        any_req = 1'b1;
      end
    end
  end

  // Request mux
  always_comb begin
    mem_req.valid = 1'b0;
    mem_req.write = '0;
    mem_req.space = MEM_GLOBAL;
    mem_req.addr  = '0;
    mem_req.data  = '0;
    mem_req.lane_mask = '0;
    mem_req.warp_id = '0;
    mem_req.size  = '0;

    for (int i = 0; i < 8; i++) begin
      warp_req_ready[i] = 1'b0;
      if (gnt[i]) begin
        mem_req.valid    = warp_req[i].valid;
        mem_req.write    = warp_req[i].write;
        mem_req.space    = warp_req[i].space;
        mem_req.addr     = warp_req[i].addr;
        mem_req.data     = warp_req[i].data;
        mem_req.lane_mask = warp_req[i].lane_mask;
        mem_req.warp_id  = warp_req[i].warp_id;
        mem_req.size     = warp_req[i].size;
        warp_req_ready[i] = mem_req_ready;
      end
    end
  end

  // Response demux — persistent valid until warp issues next request
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rr_ptr <= '0;
      for (int i = 0; i < 8; i++)
        warp_rsp[i] <= '0;
    end else begin
      // Clear response when the warp sends a new request (old response consumed)
      for (int i = 0; i < 8; i++) begin
        if (warp_req[i].valid && warp_req_ready[i])
          warp_rsp[i].valid <= 1'b0;
      end

      if (any_req && mem_req_ready)
        rr_ptr <= selected_warp[2:0] + 1'b1;

      if (mem_rsp.valid) begin
        warp_rsp[mem_rsp.warp_id] <= mem_rsp;
      end
    end
  end

endmodule
