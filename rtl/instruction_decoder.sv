module instruction_decoder (
  input  logic [63:0] instr_word,
  output logic [4:0]  opcode,
  output logic [1:0]  fmt,
  output logic        pred,
  output logic [4:0]  rd,
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [1:0]  wgpr_sel,
  output logic [31:0] imm,
  output logic        valid
);

  assign opcode   = instr_word[63:59];
  assign fmt      = instr_word[58:57];
  assign pred     = instr_word[56];
  assign rd       = instr_word[55:51];
  assign rs1      = instr_word[50:46];
  assign rs2      = instr_word[45:41];
  assign wgpr_sel = instr_word[40:39];
  assign imm      = instr_word[31:0];
  assign valid    = (opcode != 5'b11111);

endmodule
