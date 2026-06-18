module scalar_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [4:0]  opcode,
  input  logic [15:0] src_a,
  input  logic [15:0] src_b,
  input  logic [31:0] pc,
  input  logic [31:0] imm,
  output logic [15:0] result,
  output logic [31:0] target_pc,
  output logic        branch_taken,
  output logic        valid
);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result       <= '0;
      target_pc    <= '0;
      branch_taken <= '0;
      valid        <= '0;
    end else if (en) begin
      valid <= 1'b1;
      case (opcode)
        5'b10000: begin // SADD
          result <= src_a + src_b;
        end
        5'b10001: begin // SSUB
          result <= src_a - src_b;
        end
        5'b10010: begin // SMUL
          result <= src_a * src_b;
        end
        5'b10011: begin // SMOV
          result <= imm[15:0];
        end
        5'b10100: begin // SBRA
          target_pc    <= pc + imm - 4;
          branch_taken <= 1'b1;
          result       <= pc + 4;
        end
        default: result <= '0;
      endcase
    end else begin
      valid <= '0;
    end
  end

endmodule
