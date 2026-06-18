module systolic_array_32x32 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [1:0]  fmt,          // Data format
  // Weight stationary: load weights first
  input  logic        weight_ld_en,
  input  logic [15:0] weight_ld_value,
  input  logic [9:0]  weight_cnt,
  // Input activations (shifted systolic)
  input  logic        input_valid,
  input  logic [15:0] input_data [0:31],  // 32 columns of A
  // Partial sums (shifted systolic)
  input  logic [31:0] psum_in [0:31],     // Partial sums from above
  output logic [31:0] psum_out [0:31],    // Partial sums to next row
  output logic        output_valid,
  output logic        done
);

  logic [15:0] weights [0:31][0:31];  // 32x32 weight matrix
  logic [15:0] act_shift [0:31][0:31]; // Systolic activation buffer
  logic [31:0] psums [0:31][0:31];    // Partial sum pipeline
  logic [31:0] mac_result [0:31][0:31];
  logic        mac_valid [0:31][0:31];
  logic [4:0]  cycle_cnt;
  logic [4:0]  drain_cnt;
  logic        running;
  logic        draining;
  logic        fmt_reg;

  // Weight load phase
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++)
        for (int j = 0; j < 32; j++)
          weights[i][j] <= '0;
    end else if (weight_ld_en) begin
      weights[weight_cnt[9:5]][weight_cnt[4:0]] <= weight_ld_value;
    end
  end

  // Systolic activation shifting (wavefront)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++)
        for (int j = 0; j < 32; j++)
          act_shift[i][j] <= '0;
    end else if (en && (input_valid || draining)) begin
      if (input_valid) begin
        for (int j = 0; j < 32; j++)
          act_shift[0][j] <= input_data[j];
      end
      for (int i = 1; i < 32; i++)
        for (int j = 0; j < 32; j++)
          act_shift[i][j] <= act_shift[i-1][j];
    end
  end

  // Generate 32x32 PE array
  genvar i, j;
  generate
    for (i = 0; i < 32; i++) begin : pe_row
      for (j = 0; j < 32; j++) begin : pe_col
        mac_unit u_mac (
          .clk     (clk),
          .rst_n   (rst_n),
          .en      (en && (running || draining || weight_ld_en)),
          .a       (act_shift[i][j]),
          .b       (weights[i][j]),
          .acc_in  ((i == 0) ? psum_in[j] : psums[i-1][j]),
          .fmt     (fmt),
          .accum   ((i == 0) ? 1'b1 : 1'b1),  // Always accumulate row-wise
          .result  (mac_result[i][j]),
          .valid   (mac_valid[i][j])
        );

        // Pipeline the partial sums
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            psums[i][j] <= '0;
          else if (mac_valid[i][j])
            psums[i][j] <= mac_result[i][j];
        end
      end
    end
  endgenerate

  // Output is bottom row of partial sums
  always_comb begin
    for (int j = 0; j < 32; j++)
      psum_out[j] = psums[31][j];
  end

  // Control: count cycles for full 32x32 matrix multiply
  // 32 input cycles + 32 pipeline drain cycles = 64 cycles total
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_cnt <= '0;
      drain_cnt <= '0;
      running   <= '0;
      draining  <= '0;
      done      <= '0;
    end else begin
      if (en && input_valid) begin
        running   <= 1'b1;
        cycle_cnt <= cycle_cnt + 1'b1;
      end
      if (running && cycle_cnt == 5'd31 && input_valid) begin
        running  <= 1'b0;
        draining <= 1'b1;
        drain_cnt <= '0;
      end
      if (draining) begin
        if (drain_cnt == 5'd31) begin
          draining <= 1'b0;
          done     <= 1'b1;
        end else begin
          drain_cnt <= drain_cnt + 1'b1;
        end
      end else begin
        done <= 1'b0;
      end
    end
  end

  assign output_valid = draining;

endmodule
