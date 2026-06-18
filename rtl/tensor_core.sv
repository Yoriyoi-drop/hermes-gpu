module tensor_core (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,
  input  logic [1:0]  fmt,
  input  logic        start,
  input  logic        weight_ld,
  // SRAM write port (load W and A matrices)
  input  logic        sram_wen,
  input  logic [10:0] sram_addr,
  input  logic [15:0] sram_wdata,
  // C SRAM read port
  input  logic        c_sram_ren,
  input  logic [9:0]  c_sram_addr,
  output logic [31:0] c_sram_rdata,
  // Status
  output logic        done,
  output logic        busy,
  output logic [4:0]  tc_state
);

  typedef enum logic [2:0] {
    IDLE,
    LOAD_WEIGHTS,
    COMPUTE_MATRIX,
    DRAIN,
    MMA_DONE
  } state_t;

  state_t state, next;

  // Weight SRAM (1024 entries) + A SRAM (1024 entries)
  logic [15:0] weight_sram [0:1023];
  logic [15:0] a_sram [0:1023];

  // C result array (32 rows x 32 cols, FP32 accumulator)
  logic [31:0] c_sram [0:1023];

  // SRAM write
  always_ff @(posedge clk) begin
    if (sram_wen) begin
      if (sram_addr[10])
        a_sram[sram_addr[9:0]] <= sram_wdata;
      else
        weight_sram[sram_addr[9:0]] <= sram_wdata;
    end
  end

  // SRAM read (combinational)
  always_comb begin
    c_sram_rdata = c_sram[c_sram_addr];
  end

  // Systolic array interface
  logic [9:0] weight_cnt;
  logic [4:0] row_cnt;
  logic [31:0] psum_out [0:31];
  logic        sa_en, sa_input_valid, sa_output_valid, sa_done;
  logic [15:0] sa_input_data [0:31];
  logic [31:0] sa_psum_in [0:31];
  logic [15:0] w_row [0:31], a_row [0:31];

  systolic_array_32x32 u_sa (
    .clk           (clk),
    .rst_n         (rst_n),
    .en            (sa_en),
    .fmt           (fmt),
    .weight_ld_en  (state == LOAD_WEIGHTS),
    .weight_ld_value (w_row[weight_cnt[4:0]]),
    .weight_cnt    (weight_cnt),
    .input_valid   (sa_input_valid),
    .input_data    (sa_input_data),
    .psum_in       (sa_psum_in),
    .psum_out      (psum_out),
    .output_valid  (sa_output_valid),
    .done          (sa_done)
  );

  always_comb begin
    for (int i = 0; i < 32; i++)
      sa_psum_in[i] = '0;
  end

  always_comb begin
    sa_en          = (state == LOAD_WEIGHTS) || (state == COMPUTE_MATRIX) || (state == DRAIN);
    sa_input_valid = (state == COMPUTE_MATRIX);
    sa_input_data  = a_row;
  end

  // Read weight row from SRAM
  always_comb begin
    for (int j = 0; j < 32; j++)
      w_row[j] = weight_sram[{weight_cnt[9:5], j[4:0]}];
  end

  // Read A row from SRAM
  always_comb begin
    for (int j = 0; j < 32; j++)
      a_row[j] = a_sram[{row_cnt, j[4:0]}];
  end

  // FSM registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= IDLE;
      weight_cnt <= '0;
      row_cnt  <= '0;
      done     <= '0;
      tc_state <= IDLE;
    end else begin
      state <= next;
      tc_state <= state;
      case (state)
        IDLE: begin
          done    <= '0;
          weight_cnt <= '0;
          row_cnt <= '0;
        end

        LOAD_WEIGHTS: begin
          if (weight_cnt == 10'd1023)
            weight_cnt <= '0;
          else
            weight_cnt <= weight_cnt + 1'b1;
        end

        COMPUTE_MATRIX: begin
          row_cnt <= row_cnt + 1'b1;
        end

        DRAIN: begin
          if (sa_output_valid) begin
            for (int c = 0; c < 32; c++)
              c_sram[{row_cnt, c[4:0]}] <= psum_out[c];
            row_cnt <= row_cnt + 1'b1;
          end
        end

        MMA_DONE: begin
          done <= 1'b1;
        end

        default: begin
        end
      endcase
    end
  end

  always_comb begin
    next = state;
    case (state)
      IDLE: begin
        if (start && weight_ld)
          next = LOAD_WEIGHTS;
        else if (start && !weight_ld)
          next = COMPUTE_MATRIX;
      end

      LOAD_WEIGHTS: begin
        if (weight_cnt == 10'd1023)
          next = COMPUTE_MATRIX;
      end

      COMPUTE_MATRIX: begin
        if (row_cnt == 5'd31)
          next = DRAIN;
      end

      DRAIN: begin
        if (sa_done)
          next = MMA_DONE;
      end

      MMA_DONE: begin
        next = IDLE;
      end

      default: next = IDLE;
    endcase
  end

  assign busy = (state != IDLE && state != MMA_DONE);

endmodule