module vector_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [4:0]  opcode,
  input  logic [1:0]  fmt,
  input  logic [15:0] src_a [0:31],
  input  logic [15:0] src_b [0:31],
  input  logic        pred_en,
  input  logic [31:0] pred_lane,
  output logic [15:0] result [0:31],
  output logic        valid,
  output logic        done
);

  logic [3:0] stages;
  logic [15:0] result_next [0:31];

  always_comb begin
    for (int l = 0; l < 32; l++) begin
      logic [15:0] raw;
      raw = '0;
      case (opcode)
        5'b01000: begin
          case (fmt)
            2'b00, 2'b01: raw = fp16_add(src_a[l], src_b[l]);
            2'b10: raw = {8'b0, $signed(src_a[l][7:0]) + $signed(src_b[l][7:0])};
            default: raw = '0;
          endcase
        end
        5'b01001: begin
          case (fmt)
            2'b00, 2'b01: raw = fp16_sub(src_a[l], src_b[l]);
            2'b10: raw = {8'b0, $signed(src_a[l][7:0]) - $signed(src_b[l][7:0])};
            default: raw = '0;
          endcase
        end
        5'b01010: begin
          case (fmt)
            2'b00: raw = fp16_mul(src_a[l], src_b[l]);
            2'b01: raw = bf16_mul(src_a[l], src_b[l]);
            2'b10: raw = {8'b0, $signed(src_a[l][7:0]) * $signed(src_b[l][7:0])};
            default: raw = '0;
          endcase
        end
        5'b01011: begin
          if (fmt == 2'b10)
            raw = src_a[l][7] ? '0 : src_a[l];
          else
            raw = src_a[l][15] ? '0 : src_a[l];
        end
        5'b01100: raw = sigmoid_lut(src_a[l], fmt);
        5'b01101: raw = tanh_lut(src_a[l], fmt);
        5'b01110: begin
          case (fmt)
            2'b00: raw = bf16_to_fp16(src_a[l]);
            2'b01: raw = fp16_to_bf16(src_a[l]);
            2'b10: raw = fp16_to_int8(src_a[l]);
            default: raw = '0;
          endcase
        end
        default: raw = '0;
      endcase
      result_next[l] = (pred_en && !pred_lane[l]) ? '0 : raw;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid <= '0;
      done  <= '0;
      stages <= '0;
      result <= '{32{'0}};
    end else if (en) begin
      valid <= 1'b1;
      result <= result_next;
    end else begin
      valid <= '0;
    end
  end

  function automatic [15:0] fp16_add(input [15:0] x, y);
    logic [15:0] r;
    logic [4:0] exp_a, exp_b, exp_diff, exp_max;
    logic [10:0] mant_a, mant_b;
    logic [11:0] mant_sum;
    logic [4:0] norm_shift;

    exp_a = x[14:10];
    exp_b = y[14:10];

    if (exp_a > exp_b || (exp_a == exp_b && {1'b1, x[9:0]} >= {1'b1, y[9:0]})) begin
      exp_max  = exp_a;
      exp_diff = exp_a - exp_b;
      mant_a   = {1'b1, x[9:0]};
      mant_b   = (exp_diff > 10) ? '0 : ({1'b1, y[9:0]} >> exp_diff);
      r[15]    = x[15];
    end else begin
      exp_max  = exp_b;
      exp_diff = exp_b - exp_a;
      mant_a   = (exp_diff > 10) ? '0 : ({1'b1, x[9:0]} >> exp_diff);
      mant_b   = {1'b1, y[9:0]};
      r[15]    = y[15];
    end

    if (x[15] == y[15]) begin
      mant_sum = mant_a + mant_b;
      if (mant_sum[11]) begin
        r[14:10] = exp_max + 5'd1;
        r[9:0]   = mant_sum[10:1];
      end else begin
        r[14:10] = exp_max;
        r[9:0]   = mant_sum[9:0];
      end
    end else begin
      if (mant_a >= mant_b)
        mant_sum = mant_a - mant_b;
      else
        mant_sum = mant_b - mant_a;

      if (mant_sum == 0) begin
        r = 16'h0000;
      end else begin
        norm_shift = 0;
        for (int i = 10; i >= 0; i--) begin
          if (mant_sum[i]) begin
            norm_shift = 5'(10 - i);
            break;
          end
        end
        r[14:10] = exp_max - norm_shift;
        mant_sum = mant_sum << norm_shift;
        r[9:0]   = mant_sum[9:0];
      end
    end
    return r;
  endfunction

  function automatic [15:0] fp16_sub(input [15:0] x, y);
    return fp16_add(x, {~y[15], y[14:0]});
  endfunction

  function automatic [15:0] fp16_mul(input [15:0] x, y);
    logic [15:0] r;
    r[15] = x[15] ^ y[15];
    r[14:10] = x[14:10] + y[14:10] - 5'd15;
    r[9:0] = ({1'b1, x[9:0]} * {1'b1, y[9:0]}) >> 10;
    return r;
  endfunction

  function automatic [15:0] bf16_mul(input [15:0] x, y);
    logic [15:0] r;
    r[15] = x[15] ^ y[15];
    r[14:7]  = x[14:7] + y[14:7] - 8'd127;
    r[6:0] = ({1'b1, x[6:0]} * {1'b1, y[6:0]}) >> 7;
    return r;
  endfunction

  function automatic [15:0] bf16_to_fp16(input [15:0] x);
    logic [15:0] r;
    r[15]   = x[15];
    r[14:10] = x[14:10] > 5'd30 ? 5'd30 : x[14:10];
    r[9:0]  = x[6:0] << 3;
    return r;
  endfunction

  function automatic [15:0] fp16_to_bf16(input [15:0] x);
    logic [15:0] r;
    r[15]   = x[15];
    r[14:7]  = x[14:10];
    r[6:0]  = x[9:3];
    return r;
  endfunction

  function automatic [15:0] fp16_to_int8(input [15:0] x);
    logic [15:0] r;
    logic [10:0] mantissa;
    logic [4:0]  shift;
    shift = 5'd15 - x[14:10];
    mantissa = {1'b1, x[9:0]} >> shift;
    if (x[15])
      r = {8'hFF, 8'(~mantissa[7:0] + 1'b1)};
    else
      r = {8'h00, 8'(mantissa[7:0])};
    return r;
  endfunction

  function automatic [15:0] sigmoid_lut(input [15:0] x, input [1:0] fmt);
    logic [15:0] r;
    logic [3:0] idx;
    idx = x[9:6];
    r[15] = 1'b0;
    r[14:10] = 5'd15;
    case (idx)
      4'h0: r[9:0] = 10'h200;
      4'h1: r[9:0] = 10'h240;
      4'h2: r[9:0] = 10'h280;
      4'h3: r[9:0] = 10'h2C0;
      4'h4: r[9:0] = 10'h300;
      4'h5: r[9:0] = 10'h320;
      4'h6: r[9:0] = 10'h340;
      4'h7: r[9:0] = 10'h360;
      4'h8: r[9:0] = 10'h380;
      4'h9: r[9:0] = 10'h390;
      4'hA: r[9:0] = 10'h3A0;
      4'hB: r[9:0] = 10'h3B0;
      4'hC: r[9:0] = 10'h3C0;
      4'hD: r[9:0] = 10'h3D0;
      4'hE: r[9:0] = 10'h3E0;
      4'hF: r[9:0] = 10'h3F0;
    endcase
    return r;
  endfunction

  function automatic [15:0] tanh_lut(input [15:0] x, fmt);
    logic [15:0] r;
    logic [3:0] idx;
    idx = x[9:6];
    r[15] = 1'b0;
    r[14:10] = 5'd15;
    case (idx)
      4'h0: r[9:0] = 10'h000;
      4'h1: r[9:0] = 10'h100;
      4'h2: r[9:0] = 10'h180;
      4'h3: r[9:0] = 10'h200;
      4'h4: r[9:0] = 10'h250;
      4'h5: r[9:0] = 10'h280;
      4'h6: r[9:0] = 10'h2A0;
      4'h7: r[9:0] = 10'h2C0;
      4'h8: r[9:0] = 10'h2D0;
      4'h9: r[9:0] = 10'h2E0;
      4'hA: r[9:0] = 10'h2E8;
      4'hB: r[9:0] = 10'h2F0;
      4'hC: r[9:0] = 10'h2F4;
      4'hD: r[9:0] = 10'h2F8;
      4'hE: r[9:0] = 10'h2FC;
      4'hF: r[9:0] = 10'h2FF;
    endcase
    return r;
  endfunction

endmodule