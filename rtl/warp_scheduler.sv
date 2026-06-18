import hermes_pkg::*;

module warp_scheduler (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  warp_state_e warp_states [0:NUM_WARPS-1],
  output logic [4:0]  scheduled_warp,
  output logic        schedule_valid,
  output logic [31:0] warp_pc [0:NUM_WARPS-1],
  input  logic [31:0] warp_next_pc [0:7],
  input  logic        warp_pc_update [0:7],
  output logic        ctx_switch,
  output logic [4:0]  ctx_warp_id,
  output logic [31:0] perf_active_cycles,
  output logic [31:0] perf_total_cycles
);

  logic [7:0] round_robin_ptr;
  logic [7:0] gnt;
  logic       any_ready;
  logic [4:0] selected;
  logic [31:0] active_cycles;
  logic [31:0] total_cycles;

  always_comb begin
    any_ready = 1'b0;
    gnt = '0;
    selected = '0;
    for (int i = 0; i < NUM_WARPS; i++) begin
      if (warp_states[(round_robin_ptr + i) % NUM_WARPS] == WARP_READY && !any_ready) begin
        gnt[(round_robin_ptr + i) % NUM_WARPS] = 1'b1;
        selected = (round_robin_ptr + i) % NUM_WARPS;
        any_ready = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      round_robin_ptr <= '0;
      scheduled_warp  <= '0;
      schedule_valid  <= '0;
    end else if (en) begin
      schedule_valid <= any_ready;
      scheduled_warp <= selected;
      if (any_ready)
        round_robin_ptr <= (selected + 1'b1) % NUM_WARPS;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NUM_WARPS; i++)
        warp_pc[i] <= '0;
      active_cycles <= '0;
      total_cycles  <= '0;
    end else begin
      for (int i = 0; i < NUM_WARPS; i++) begin
        if (warp_pc_update[i])
          warp_pc[i] <= warp_next_pc[i];
      end
      active_cycles <= active_cycles + (any_ready ? 1'b1 : 1'b0);
      total_cycles  <= total_cycles + 1'b1;
    end
  end

  assign perf_active_cycles = active_cycles;
  assign perf_total_cycles  = total_cycles;

endmodule