import hermes_pkg::*;

module shared_memory_bank (
  input  logic        clk,
  input  logic        en,
  input  logic        wr,
  input  logic [SMEM_BANK_ADDR_W-1:0] addr,
  input  logic [15:0]  wdata,
  output logic [15:0]  rdata
);

  logic [15:0] mem [0:SMEM_BANK_WORDS-1];

  always_ff @(posedge clk) begin
    if (en) begin
      if (wr)
        mem[addr] <= wdata;
      else
        rdata <= mem[addr];
    end
  end

endmodule
