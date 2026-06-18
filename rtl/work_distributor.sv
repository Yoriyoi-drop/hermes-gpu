import hermes_pkg::*;

module work_distributor (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        host_start,
  input  logic [31:0] host_kernel_addr,
  input  logic [31:0] host_arg_a,
  input  logic [31:0] host_arg_b,
  input  logic [31:0] host_arg_c,
  input  logic [1:0]  host_data_fmt,
  input  logic [31:0] host_grid_dim_x,
  input  logic [31:0] host_grid_dim_y,
  output logic        host_done,
  output logic        host_error,

  output logic        core_start [0:NUM_CORES-1],
  output logic [31:0] core_kernel_addr [0:NUM_CORES-1],
  output logic [31:0] core_arg_a [0:NUM_CORES-1],
  output logic [31:0] core_arg_b [0:NUM_CORES-1],
  output logic [31:0] core_arg_c [0:NUM_CORES-1],
  output logic [1:0]  core_data_fmt [0:NUM_CORES-1],
  output logic [31:0] core_grid_dim_x [0:NUM_CORES-1],
  output logic [31:0] core_grid_dim_y [0:NUM_CORES-1],
  input  logic        core_done [0:NUM_CORES-1],
  input  logic        core_idle [0:NUM_CORES-1]
);

  typedef enum logic [1:0] {
    WD_IDLE,
    WD_DISTRIBUTE,
    WD_WAIT,
    WD_DONE
  } wd_state_t;

  wd_state_t state;
  logic [31:0] total_ctas;
  logic [31:0] ctas_per_core [0:NUM_CORES-1];
  logic        core_assigned [0:NUM_CORES-1];
  logic [3:0]  cores_assigned_total;
  logic [3:0]  cores_done_count;
  logic        waiting;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= WD_IDLE;
      host_done <= 1'b0;
      host_error <= 1'b0;
      cores_done_count <= '0;
      cores_assigned_total <= '0;
      waiting <= 1'b0;
      for (int c = 0; c < NUM_CORES; c++) begin
        core_start[c] <= 1'b0;
        core_assigned[c] <= 1'b0;
        core_kernel_addr[c] <= '0;
        core_arg_a[c] <= '0;
        core_arg_b[c] <= '0;
        core_arg_c[c] <= '0;
        core_data_fmt[c] <= FP16;
        core_grid_dim_x[c] <= '0;
        core_grid_dim_y[c] <= '0;
        ctas_per_core[c] <= '0;
      end
    end else begin
      case (state)
        WD_IDLE: begin
          cores_done_count <= '0;
          cores_assigned_total <= '0;
          waiting <= 1'b0;
          for (int c = 0; c < NUM_CORES; c++) begin
            core_start[c] <= 1'b0;
            core_assigned[c] <= 1'b0;
          end

          if (host_start) begin
            host_done <= 1'b0;
            total_ctas = host_grid_dim_x * host_grid_dim_y;

            for (int c = 0; c < NUM_CORES; c++) begin
              ctas_per_core[c] <= (total_ctas / NUM_CORES) + ((c < (total_ctas % NUM_CORES)) ? 1'b1 : 1'b0);
              core_kernel_addr[c] <= host_kernel_addr;
              core_arg_a[c] <= host_arg_a;
              core_arg_b[c] <= host_arg_b;
              core_arg_c[c] <= host_arg_c;
              core_data_fmt[c] <= host_data_fmt;
              core_grid_dim_x[c] <= host_grid_dim_x;
              core_grid_dim_y[c] <= host_grid_dim_y;
            end

            state <= WD_DISTRIBUTE;
          end
        end

        WD_DISTRIBUTE: begin
          automatic int assign_cnt = 0;
          for (int c = 0; c < NUM_CORES; c++) begin
            if (ctas_per_core[c] > 0 && core_idle[c]) begin
              core_start[c]    <= 1'b1;
              core_assigned[c] <= 1'b1;
              assign_cnt++;
            end
          end
          cores_assigned_total <= cores_assigned_total + assign_cnt;
          state <= WD_WAIT;
        end

        WD_WAIT: begin
          for (int c = 0; c < NUM_CORES; c++)
            core_start[c] <= 1'b0;

          if (!waiting) begin
            cores_done_count <= '0;
            waiting <= 1'b1;
          end else begin
            automatic int done_cnt = 0;
            for (int c = 0; c < NUM_CORES; c++) begin
              if (core_assigned[c] && core_done[c]) begin
                core_assigned[c] <= 1'b0;
                done_cnt++;
              end
            end
            cores_done_count <= cores_done_count + done_cnt;
          end

          if (cores_assigned_total > 0 && cores_done_count >= cores_assigned_total) begin
            host_done <= 1'b1;
            state <= WD_DONE;
          end
        end

        WD_DONE: begin
          state <= WD_IDLE;
        end

        default: state <= WD_IDLE;
      endcase
    end
  end

endmodule