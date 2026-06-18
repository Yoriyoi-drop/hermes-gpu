module mac_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [15:0] a,
  input  logic [15:0] b,
  input  logic [31:0] acc_in,
  input  logic [1:0]  fmt,        // 0=FP16, 1=BF16, 2=INT8
  input  logic        accum,      // 1 = accumulate, 0 = overwrite
  output logic [31:0] result,
  output logic        valid
);

  logic [31:0] product;
  logic [31:0] mult_out;
  logic [31:0] adder_out;
  logic [15:0] a_aligned, b_aligned;
  logic        a_sign, b_sign;
  logic [4:0]  a_exp_fp16, b_exp_fp16;
  logic [7:0]  a_exp_bf16, b_exp_bf16;
  logic [9:0]  a_mant_fp16, b_mant_fp16;
  logic [6:0]  a_mant_bf16, b_mant_bf16;
  logic [15:0] a_int8_ext, b_int8_ext;
  logic [31:0] int8_product;
  logic [7:0]  a_int8, b_int8;

  always_comb begin
    a_aligned = a;
    b_aligned = b;
    product   = '0;
    mult_out  = '0;

    case (fmt)
      2'b00: begin // FP16: 1-5-10
        a_sign = a[15];
        b_sign = b[15];
        a_exp_fp16  = a[14:10];
        b_exp_fp16  = b[14:10];
        a_mant_fp16 = {1'b1, a[9:0]};
        b_mant_fp16 = {1'b1, b[9:0]};

        // FP16 multiply: sign xor, exp add, mant multiply
        // Result in FP32 format for accumulator
        product[31] = a_sign ^ b_sign;
        product[30:23] = a_exp_fp16 + b_exp_fp16 + 8'd112;  // Bias adjust
        product[22:0]  = (a_mant_fp16 * b_mant_fp16) >> 10;

        // Handle subnormals / zero
        if (a[14:10] == 5'b00000 || b[14:10] == 5'b00000)
          product = '0;
        if (a[14:10] == 5'b11111 || b[14:10] == 5'b11111)
          product = {a_sign ^ b_sign, 8'hFF, 23'h0};  // NaN/Inf
      end

      2'b01: begin // BF16: 1-8-7
        a_sign = a[15];
        b_sign = b[15];
        a_exp_bf16  = a[14:7];
        b_exp_bf16  = b[14:7];
        a_mant_bf16 = {1'b1, a[6:0]};
        b_mant_bf16 = {1'b1, b[6:0]};

        product[31] = a_sign ^ b_sign;
        product[30:23] = a_exp_bf16 + b_exp_bf16 - 8'd127;  // Bias: 127+127-127
        product[22:0]  = {a_mant_bf16 * b_mant_bf16, 9'b0};

        if (a[14:7] == 8'b00000000 || b[14:7] == 8'b00000000)
          product = '0;
        if (a[14:7] == 8'b11111111 || b[14:7] == 8'b11111111)
          product = {a_sign ^ b_sign, 8'hFF, 23'h0};
      end

      2'b10: begin // INT8
        a_int8 = a[7:0];
        b_int8 = b[7:0];
        int8_product = $signed(a_int8) * $signed(b_int8);
        product = int8_product;
      end

      default: begin
        product = '0;
      end
    endcase

    mult_out = product;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result <= '0;
      valid  <= '0;
    end else if (en) begin
      if (accum)
        result <= acc_in + mult_out;
      else
        result <= mult_out;
      valid <= 1'b1;
    end else begin
      valid <= '0;
    end
  end

endmodule
