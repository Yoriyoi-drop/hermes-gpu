`include "hermes_defines.svh"
import hermes_pkg::*;

module hermes_gpu_core (
  input  logic        clk,
  input  logic        rst_n,
  input  core_id_t    core_id,

  input  logic        core_start,
  input  logic [31:0] core_kernel_addr,
  input  logic [31:0] core_arg_a,
  input  logic [31:0] core_arg_b,
  input  logic [31:0] core_arg_c,
  input  logic [1:0]  core_data_fmt,
  input  logic [31:0] core_grid_dim_x,
  input  logic [31:0] core_grid_dim_y,
  output logic        core_done,
  output logic        core_idle,

  output logic        l2_req_valid,
  output logic        l2_req_write,
  output logic [31:0] l2_req_addr,
  output logic [511:0] l2_req_wdata,
  input  logic        l2_req_ready,
  input  logic [511:0] l2_rsp_rdata,
  input  logic        l2_rsp_rvalid,

  output logic [31:0] perf_instr_cnt,
  output logic [31:0] perf_ld_cnt,
  output logic [31:0] perf_st_cnt,
  output logic [31:0] perf_vec_cnt,
  output logic [31:0] perf_tc_cnt,
  output logic [31:0] perf_branch_cnt,
  output logic [31:0] perf_l1_hits,
  output logic [31:0] perf_l1_misses,
  output logic [31:0] perf_smem_conflicts,
  output logic [31:0] perf_warp_active,
  output logic [31:0] perf_warp_total
);

  warp_state_e warp_states [0:NUM_WARPS-1];
  logic [4:0]  scheduled_warp;
  logic        schedule_valid;

  logic [63:0] instr_word;
  logic [4:0]  opcode;
  logic [1:0]  fmt;
  logic [1:0]  fmt_reg;
  logic        pred;
  logic [4:0]  rd, rs1, rs2;
  logic [31:0] imm;
  logic        instr_valid;
  logic        ld_flag;

  logic        rf_wr_en;
  logic [4:0]  rf_wr_addr;
  logic [15:0] rf_wr_data [0:WARP_SIZE-1];
  logic [31:0] rf_lane_mask;
  logic [15:0] rf_rd1 [0:WARP_SIZE-1], rf_rd2 [0:WARP_SIZE-1], rf_rd3 [0:WARP_SIZE-1];

  logic [31:0] warp_pc [0:NUM_WARPS-1];
  logic [31:0] warp_next_pc [0:NUM_WARPS-1];
  logic        warp_pc_update [0:NUM_WARPS-1];

  logic [511:0] ld_rsp_data;
  logic        ld_pending;
  logic        st_pending;

  logic        tc_en, tc_start, tc_weight_ld;
  logic        tc_sram_wen;
  logic [10:0] tc_sram_addr;
  logic [15:0] tc_sram_wdata;
  logic        tc_c_sram_ren;
  logic [9:0]  tc_c_sram_addr;
  logic [31:0] tc_c_sram_rdata;
  logic        tc_done, tc_busy;
  logic [4:0]  tc_state;

  logic        vu_en;
  logic [15:0] vu_src_a [0:WARP_SIZE-1], vu_src_b [0:WARP_SIZE-1];
  logic [15:0] vu_result [0:WARP_SIZE-1];
  logic        vu_valid;

  logic        su_en;
  logic [15:0] su_src_a, su_src_b;
  logic [15:0] su_result;
  logic [31:0] su_target_pc;
  logic        su_branch_taken, su_valid;

  mem_req_t    warp_req [0:NUM_WARPS-1];
  logic        warp_req_ready [0:NUM_WARPS-1];
  mem_rsp_t    warp_rsp [0:NUM_WARPS-1];

  logic [15:0] ctx_ld_data_tie [0:WARP_SIZE-1];

  logic [31:0] lane_mask_reg [0:NUM_WARPS-1];
  logic [31:0] current_lane_mask;
  logic        pred_active;

  logic [31:0] simt_stack_mask [0:NUM_WARPS-1][0:3];
  logic [31:0] simt_stack_pc  [0:NUM_WARPS-1][0:3];
  logic [1:0]  simt_sp        [0:NUM_WARPS-1];
  logic        simt_push, simt_pop;

  logic [31:0] perf_instr_cnt_r;
  logic [31:0] perf_ld_cnt_r, perf_st_cnt_r, perf_vec_cnt_r, perf_tc_cnt_r;
  logic [31:0] perf_branch_cnt_r;
  logic [31:0] perf_warp_active_r, perf_warp_total_r;

  assign perf_instr_cnt = perf_instr_cnt_r;
  assign perf_ld_cnt    = perf_ld_cnt_r;
  assign perf_st_cnt    = perf_st_cnt_r;
  assign perf_vec_cnt   = perf_vec_cnt_r;
  assign perf_tc_cnt    = perf_tc_cnt_r;
  assign perf_branch_cnt = perf_branch_cnt_r;
  assign perf_warp_active = perf_warp_active_r;
  assign perf_warp_total  = perf_warp_total_r;

  warp_scheduler u_sched (
    .clk             (clk),
    .rst_n           (rst_n),
    .en              (1'b1),
    .warp_states     (warp_states),
    .scheduled_warp  (scheduled_warp),
    .schedule_valid  (schedule_valid),
    .warp_pc         (warp_pc),
    .warp_next_pc    (warp_next_pc),
    .warp_pc_update  (warp_pc_update),
    .ctx_switch      (),
    .ctx_warp_id     (),
    .perf_active_cycles (perf_warp_active_r),
    .perf_total_cycles  (perf_warp_total_r)
  );

  instruction_decoder u_dec (
    .instr_word  (instr_word),
    .opcode      (opcode),
    .fmt         (fmt),
    .pred        (pred),
    .rd          (rd),
    .rs1         (rs1),
    .rs2         (rs2),
    .wgpr_sel    (),
    .imm         (imm),
    .valid       (instr_valid)
  );

  register_file u_regfile (
    .clk           (clk),
    .rst_n         (rst_n),
    .warp_id       (scheduled_warp),
    .rd_addr_1     (rs1),
    .rd_addr_2     (rs2),
    .rd_addr_3     (rd),
    .rd_data_1     (rf_rd1),
    .rd_data_2     (rf_rd2),
    .rd_data_3     (rf_rd3),
    .wr_en         (rf_wr_en),
    .wr_addr       (rf_wr_addr),
    .wr_data       (rf_wr_data),
    .wr_lane_mask  (rf_lane_mask),
    .ctx_ld_en     (1'b0),
    .ctx_ld_addr   ('0),
    .ctx_ld_data   (ctx_ld_data_tie),
    .ctx_rd_data   ()
  );

  tensor_core u_tensor (
    .clk          (clk),
    .rst_n        (rst_n),
    .en           (tc_en),
    .fmt          (fmt_reg),
    .start        (tc_start),
    .weight_ld    (tc_weight_ld),
    .sram_wen     (tc_sram_wen),
    .sram_addr    (tc_sram_addr),
    .sram_wdata   (tc_sram_wdata),
    .c_sram_ren   (tc_c_sram_ren),
    .c_sram_addr  (tc_c_sram_addr),
    .c_sram_rdata (tc_c_sram_rdata),
    .done         (tc_done),
    .busy         (tc_busy),
    .tc_state     (tc_state)
  );

  assign pred_active = pred;
  always_comb begin
    if (pred_active) begin
      for (int l = 0; l < 32; l++)
        current_lane_mask[l] = lane_mask_reg[scheduled_warp][l] && (rf_rd1[l] != 16'h0);
    end else begin
      current_lane_mask = lane_mask_reg[scheduled_warp];
    end
  end

  vector_unit u_vector (
    .clk      (clk),
    .rst_n    (rst_n),
    .en       (vu_en),
    .opcode   (opcode),
    .fmt      (fmt_reg),
    .src_a    (vu_src_a),
    .src_b    (vu_src_b),
    .pred_en  (pred_active),
    .pred_lane (current_lane_mask),
    .result   (vu_result),
    .valid    (vu_valid),
    .done     ()
  );

  scalar_unit u_scalar (
    .clk          (clk),
    .rst_n        (rst_n),
    .en           (su_en),
    .opcode       (opcode),
    .src_a        (su_src_a),
    .src_b        (su_src_b),
    .pc           (warp_pc[scheduled_warp]),
    .imm          (imm),
    .result       (su_result),
    .target_pc    (su_target_pc),
    .branch_taken (su_branch_taken),
    .valid        (su_valid)
  );

  mem_hierarchy_core u_mem (
    .clk            (clk),
    .rst_n          (rst_n),
    .warp_req       (warp_req),
    .warp_req_ready (warp_req_ready),
    .warp_rsp       (warp_rsp),
    .l2_req_valid   (l2_req_valid),
    .l2_req_write   (l2_req_write),
    .l2_req_addr    (l2_req_addr),
    .l2_req_wdata   (l2_req_wdata),
    .l2_req_ready   (l2_req_ready),
    .l2_rsp_rdata   (l2_rsp_rdata),
    .l2_rsp_rvalid  (l2_rsp_rvalid),
    .perf_l1_hits   (perf_l1_hits),
    .perf_l1_misses (perf_l1_misses),
    .perf_smem_conflicts (perf_smem_conflicts)
  );

  logic [31:0] kernel_cta_x, kernel_cta_y;
  logic        running;

  enum logic [3:0] {
    CORE_IDLE,
    CORE_FETCH,
    CORE_DECODE,
    CORE_EXECUTE,
    CORE_MEM_WAIT,
    CORE_TC_WAIT,
    CORE_WB,
    CORE_DONE
  } core_state, core_next;

  logic [10:0] tc_sram_cnt;
  logic [31:0] tc_load_src_addr;

  assign core_idle = (core_state == CORE_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      fmt_reg <= FP16;
    else if (core_start)
      fmt_reg <= core_data_fmt;
  end

  always_comb begin
    for (int l = 0; l < 32; l++)
      ctx_ld_data_tie[l] = '0;
  end

  assign rf_lane_mask = current_lane_mask;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      core_state  <= CORE_IDLE;
      running     <= '0;
      core_done   <= '0;

      for (int i = 0; i < NUM_WARPS; i++)
        warp_states[i] <= WARP_IDLE;

      rf_wr_en     <= '0;
      ld_pending   <= '0;
      st_pending   <= '0;
      ld_flag      <= '0;
      vu_en        <= '0;
      su_en        <= '0;
      tc_en        <= '0;
      tc_start     <= '0;
      tc_weight_ld <= '0;
      tc_sram_wen  <= '0;

      for (int w = 0; w < NUM_WARPS; w++)
        warp_req[w] <= '0;

      for (int i = 0; i < NUM_WARPS; i++)
        warp_pc_update[i] <= '0;

      for (int w = 0; w < NUM_WARPS; w++) begin
        lane_mask_reg[w] <= {32{1'b1}};
        simt_sp[w]       <= '0;
        for (int s = 0; s < 4; s++) begin
          simt_stack_mask[w][s] <= '0;
          simt_stack_pc[w][s]  <= '0;
        end
      end

      perf_instr_cnt_r <= '0;
      perf_ld_cnt_r    <= '0;
      perf_st_cnt_r    <= '0;
      perf_vec_cnt_r   <= '0;
      perf_tc_cnt_r    <= '0;
      perf_branch_cnt_r <= '0;
    end else begin
      core_state <= core_next;
      rf_wr_en  <= '0;
      tc_sram_wen <= '0;
      vu_en     <= '0;
      su_en     <= '0;

      case (core_state)
        CORE_IDLE: begin
          if (core_start) begin
            core_done <= '0;
            kernel_cta_x <= core_grid_dim_x;
            kernel_cta_y <= core_grid_dim_y;
            warp_states[0] <= WARP_READY;
            warp_next_pc[0] <= core_kernel_addr;
            warp_pc_update[0] <= 1'b1;
            running <= 1'b1;
          end
        end

        CORE_FETCH: begin
          if (simt_sp[scheduled_warp] > 0 &&
              warp_next_pc[scheduled_warp] == simt_stack_pc[scheduled_warp][simt_sp[scheduled_warp]-1]) begin
            automatic logic [1:0] sp;
            sp = simt_sp[scheduled_warp] - 1'b1;
            lane_mask_reg[scheduled_warp] <= lane_mask_reg[scheduled_warp] |
                                             simt_stack_mask[scheduled_warp][sp];
            simt_sp[scheduled_warp] <= sp;
          end

          warp_req[scheduled_warp].valid     <= 1'b1;
          warp_req[scheduled_warp].write     <= 1'b0;
          warp_req[scheduled_warp].addr      <= warp_next_pc[scheduled_warp];
          warp_req[scheduled_warp].space     <= MEM_GLOBAL;
          warp_req[scheduled_warp].warp_id   <= scheduled_warp;
          warp_req[scheduled_warp].lane_mask <= {32{1'b1}};
          if (warp_req_ready[scheduled_warp])
            warp_states[scheduled_warp] <= WARP_BLOCK;
        end

        CORE_DECODE: begin
          if (warp_rsp[scheduled_warp].valid) begin
            automatic logic [63:0] new_instr;
            new_instr = warp_rsp[scheduled_warp].data >> (warp_pc[scheduled_warp][5:3] * 64);
            instr_word <= new_instr;
            warp_pc_update[scheduled_warp] <= 1'b1;
            warp_next_pc[scheduled_warp] <= warp_pc[scheduled_warp] + 8;
            warp_req[scheduled_warp] <= '0;
            ld_flag <= 1'b0;
            if (new_instr[63:59] == OP_EXIT) begin
              rf_wr_en <= '0;
              core_state <= CORE_DONE;
            end else if (new_instr[63:59] == OP_NOP) begin
              rf_wr_en <= '0;
              core_state <= CORE_FETCH;
            end else begin
              core_state <= CORE_EXECUTE;
            end
          end
        end

        CORE_EXECUTE: begin
          perf_instr_cnt_r <= perf_instr_cnt_r + 1'b1;
          case (opcode)
            OP_MMA: begin
              perf_tc_cnt_r <= perf_tc_cnt_r + 1'b1;
              tc_en <= 1'b1;
              if (!tc_busy) begin
                tc_start <= 1'b1;
                tc_weight_ld <= 1'b1;
                core_state <= CORE_TC_WAIT;
              end
            end

            OP_VADD, OP_VSUB, OP_VMUL, OP_VRELU,
            OP_VSIGMOID, OP_VTANH, OP_VCONV: begin
              perf_vec_cnt_r <= perf_vec_cnt_r + 1'b1;
              vu_en     <= 1'b1;
              vu_src_a  <= rf_rd1;
              vu_src_b  <= rf_rd2;
              if (vu_valid) core_state <= CORE_WB;
            end

            OP_SADD, OP_SSUB, OP_SMUL, OP_SMOV, OP_SBRA: begin
              su_en    <= 1'b1;
              su_src_a <= rf_rd1[0];
              su_src_b <= rf_rd2[0];
              if (opcode == OP_SBRA) begin
                perf_branch_cnt_r <= perf_branch_cnt_r + 1'b1;
                if (pred) begin
                  automatic logic [31:0] taken_mask;
                  automatic logic [31:0] not_taken_mask;
                  automatic logic [1:0]  sp;
                  taken_mask = current_lane_mask;
                  not_taken_mask = lane_mask_reg[scheduled_warp] & ~current_lane_mask;
                  sp = simt_sp[scheduled_warp];
                  if (not_taken_mask != '0) begin
                    simt_stack_mask[scheduled_warp][sp] <= not_taken_mask;
                    simt_stack_pc[scheduled_warp][sp]  <= warp_pc[scheduled_warp] + 8;
                    simt_sp[scheduled_warp] <= sp + 1'b1;
                  end
                  if (taken_mask == '0) begin
                    if (sp > 0) begin
                      lane_mask_reg[scheduled_warp] <= simt_stack_mask[scheduled_warp][sp-1];
                      warp_next_pc[scheduled_warp] <= simt_stack_pc[scheduled_warp][sp-1];
                      warp_pc_update[scheduled_warp] <= 1'b1;
                      simt_sp[scheduled_warp] <= sp - 1'b1;
                    end
                  end else begin
                    lane_mask_reg[scheduled_warp] <= taken_mask;
                  end
                end
              end
              core_state <= CORE_WB;
            end

            OP_LD: begin
              perf_ld_cnt_r <= perf_ld_cnt_r + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b0;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_GLOBAL;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              ld_flag    <= 1'b1;
              if (warp_req_ready[scheduled_warp]) begin
                ld_pending <= 1'b1;
                core_state <= CORE_MEM_WAIT;
              end
            end

            OP_LDS: begin
              perf_ld_cnt_r <= perf_ld_cnt_r + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b0;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_SHARED;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              ld_flag    <= 1'b1;
              if (warp_req_ready[scheduled_warp]) begin
                ld_pending <= 1'b1;
                core_state <= CORE_MEM_WAIT;
              end
            end

            OP_ST: begin
              perf_st_cnt_r <= perf_st_cnt_r + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b1;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_GLOBAL;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              for (int l = 0; l < 32; l++)
                warp_req[scheduled_warp].data[l*16 +: 16] <= rf_rd3[l];
              ld_flag    <= 1'b0;
              if (warp_req_ready[scheduled_warp]) begin
                st_pending <= 1'b1;
                core_state <= CORE_MEM_WAIT;
              end
            end

            OP_STS: begin
              perf_st_cnt_r <= perf_st_cnt_r + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b1;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_SHARED;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              for (int l = 0; l < 32; l++)
                warp_req[scheduled_warp].data[l*16 +: 16] <= rf_rd3[l];
              ld_flag    <= 1'b0;
              if (warp_req_ready[scheduled_warp]) begin
                st_pending <= 1'b1;
                core_state <= CORE_MEM_WAIT;
              end
            end

            OP_BAR: begin
              warp_states[scheduled_warp] <= WARP_BLOCK;
              core_state <= CORE_WB;
            end

            default: begin
              core_state <= CORE_WB;
            end
          endcase
        end

        CORE_MEM_WAIT: begin
          if (warp_rsp[scheduled_warp].valid && ld_pending) begin
            ld_rsp_data <= warp_rsp[scheduled_warp].data;
          end
          if (st_pending) begin
            if (warp_rsp[scheduled_warp].valid) begin
              st_pending <= 1'b0;
              warp_req[scheduled_warp] <= '0;
            end
          end else if (warp_rsp[scheduled_warp].valid || !ld_pending) begin
            ld_pending <= 1'b0;
            warp_req[scheduled_warp] <= '0;
          end
        end

        CORE_TC_WAIT: begin
          tc_start <= 1'b0;
          if (tc_done) begin
            core_state <= CORE_WB;
          end
        end

        CORE_WB: begin
          rf_wr_addr  <= rd;
          ld_pending  <= '0;
          st_pending  <= '0;
          warp_req[scheduled_warp] <= '0;

          if (su_branch_taken) begin
            warp_next_pc[scheduled_warp] <= su_target_pc;
            warp_pc_update[scheduled_warp] <= 1'b1;
          end

          if (vu_valid) begin
            rf_wr_en <= 1'b1;
            for (int l = 0; l < 32; l++)
              rf_wr_data[l] <= vu_result[l];
          end else if (tc_done) begin
            rf_wr_en <= 1'b1;
            for (int l = 0; l < 32; l++)
              rf_wr_data[l] <= tc_c_sram_rdata[15:0];
          end else if (su_valid) begin
            rf_wr_en <= 1'b1;
            for (int l = 0; l < 32; l++)
              rf_wr_data[l] <= su_result;
          end else if (ld_flag) begin
            rf_wr_en <= 1'b1;
            ld_flag  <= 1'b0;
            for (int l = 0; l < 32; l++)
              rf_wr_data[l] <= ld_rsp_data[l*16 +: 16];
          end

          warp_states[scheduled_warp] <= WARP_READY;
        end

        CORE_DONE: begin
          core_done <= 1'b1;
          running   <= '0;
          warp_states[scheduled_warp] <= WARP_DONE;
        end

        default: begin
        end
      endcase
    end
  end

  always_comb begin
    core_next = core_state;
    case (core_state)
      CORE_IDLE: begin
        if (core_start) core_next = CORE_FETCH;
      end

      CORE_FETCH: begin
        if (warp_req_ready[scheduled_warp]) core_next = CORE_DECODE;
      end

      CORE_DECODE: begin
        if (warp_rsp[scheduled_warp].valid) begin
          if (instr_word[63:59] == OP_EXIT) core_next = CORE_DONE;
          else if (instr_word[63:59] == OP_NOP) core_next = CORE_FETCH;
          else core_next = CORE_EXECUTE;
        end
      end

      CORE_EXECUTE: begin
        if (opcode == OP_MMA) begin
          if (!tc_busy) core_next = CORE_TC_WAIT;
          else core_next = CORE_EXECUTE;
        end else if (opcode inside {OP_LD, OP_ST, OP_LDS, OP_STS}) begin
          if (warp_req_ready[scheduled_warp]) core_next = CORE_MEM_WAIT;
          else core_next = CORE_EXECUTE;
        end else if (opcode inside {OP_VADD, OP_VSUB, OP_VMUL, OP_VRELU,
                                     OP_VSIGMOID, OP_VTANH, OP_VCONV}) begin
          if (vu_valid) core_next = CORE_WB;
          else core_next = CORE_EXECUTE;
        end else if (opcode == OP_BAR) begin
          core_next = CORE_WB;
        end else core_next = CORE_WB;
      end

      CORE_MEM_WAIT: begin
        if (st_pending && warp_rsp[scheduled_warp].valid) core_next = CORE_WB;
        else if (!st_pending && (warp_rsp[scheduled_warp].valid || !ld_pending)) core_next = CORE_WB;
      end

      CORE_TC_WAIT: begin
        if (tc_done) core_next = CORE_WB;
      end

      CORE_WB: begin
        core_next = CORE_FETCH;
      end

      CORE_DONE: begin
        core_next = CORE_IDLE;
      end

      default: core_next = CORE_IDLE;
    endcase
  end

endmodule