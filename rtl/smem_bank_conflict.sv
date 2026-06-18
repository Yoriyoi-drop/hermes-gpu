import hermes_pkg::*;

// 32-bank shared memory with bank conflict resolution
// Lane l accesses bank (l + addr) % 32
module smem_bank_conflict (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic        wr,
  input  logic [SHARED_ADDR_W-1:0] addr,
  input  logic [511:0] wdata,       // 32 lanes × 16-bit
  input  logic [31:0]  lane_mask,
  output logic [511:0] rdata,
  output logic         done,
  output logic [4:0]   conflict_cycles  // Number of cycles due to conflicts
);

  logic [15:0] bank_rdata [0:31];
  logic [4:0]  bank_hits [0:31];       // Number of lanes hitting each bank
  logic [4:0]  max_conflict;
  logic [4:0]  conflict_cnt;
  logic        busy;
  logic [4:0]  lane_bank [0:31];

  // Compute bank assignment per lane
  always_comb begin
    for (int l = 0; l < 32; l++)
      lane_bank[l] = (addr + l) % 32;

    for (int b = 0; b < 32; b++)
      bank_hits[b] = '0;

    for (int l = 0; l < 32; l++) begin
      if (lane_mask[l])
        bank_hits[lane_bank[l]] = bank_hits[lane_bank[l]] + 1;
    end

    max_conflict = 0;
    for (int b = 0; b < 32; b++) begin
      if (bank_hits[b] > max_conflict)
        max_conflict = bank_hits[b];
    end
  end

  assign conflict_cycles = max_conflict > 1 ? max_conflict - 1 : '0;

  // Generate 32 banks
  genvar b;
  generate
    for (b = 0; b < 32; b++) begin : bank_gen
      shared_memory_bank u_bank (
        .clk   (clk),
        .en    (en && busy),
        .wr    (wr),
        .addr  (addr[SMEM_BANK_ADDR_W-1:0]),
        .wdata (bank_rdata[b]),  // placeholder
        .rdata (bank_rdata[b])
      );
    end
  endgenerate

  // Conflict resolution FSM
  typedef enum logic [0:0] { IDLE, ACCESS } conflict_state_t;
  conflict_state_t state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      busy   <= '0;
      done   <= '0;
      conflict_cnt <= '0;
    end else begin
      case (state)
        IDLE: begin
          done <= '0;
          if (en) begin
            busy   <= 1'b1;
            conflict_cnt  <= max_conflict;
            state <= ACCESS;
          end
        end

        ACCESS: begin
          if (conflict_cnt == 0 || conflict_cnt == 1) begin
            // Single cycle access (no conflict) or final cycle
            busy  <= '0;
            done  <= 1'b1;
            state <= IDLE;
          end else begin
            conflict_cnt <= conflict_cnt - 1;
          end
        end
      endcase
    end
  end

  // Output mux
  always_comb begin
    for (int l = 0; l < 32; l++) begin
      int bank = (addr + l) % 32;
      rdata[l*16 +: 16] = bank_rdata[bank];
    end
  end

endmodule
