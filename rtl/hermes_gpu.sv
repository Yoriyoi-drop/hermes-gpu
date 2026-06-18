`include "hermes_defines.svh"

module hermes_gpu (
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
  output logic [31:0] axi_awaddr,
  output logic        axi_awvalid,
  input  logic        axi_awready,
  output logic [511:0] axi_wdata,
  output logic        axi_wvalid,
  input  logic        axi_wready,
  input  logic        axi_bvalid,
  output logic        axi_bready,
  output logic [31:0] axi_araddr,
  output logic        axi_arvalid,
  input  logic        axi_arready,
  input  logic [511:0] axi_rdata,
  input  logic        axi_rvalid,
  output logic        axi_rready
);

  import hermes_pkg::*;

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
  logic [31:0] tc_c_value [0:31];
  logic        tc_c_valid;

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

  // --- Lane masks for predication / warp divergence ---
  logic [31:0] lane_mask_reg [0:NUM_WARPS-1];
  logic [31:0] current_lane_mask;
  logic        pred_active;

  // --- SIMT stack for divergent branches ---
  logic [31:0] simt_stack_mask [0:NUM_WARPS-1][0:3];
  logic [31:0] simt_stack_pc  [0:NUM_WARPS-1][0:3];
  logic [1:0]  simt_sp        [0:NUM_WARPS-1];  // Stack pointer per warp
  logic        simt_push, simt_pop;

  // --- Performance counters ---
  logic [31:0] perf_instr_cnt;
  logic [31:0] perf_ld_cnt, perf_st_cnt, perf_vec_cnt, perf_tc_cnt;
  logic [31:0] perf_branch_cnt;

  logic [31:0] perf_warp_active, perf_warp_total;

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
    .perf_active_cycles (perf_warp_active),
    .perf_total_cycles  (perf_warp_total)
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

  // Predication: when instr has pred=1, lane l enabled if rf_rd1[l] != 0
  // Otherwise all lanes enabled
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

  logic [31:0] perf_l1_hits, perf_l1_misses, perf_l2_hits, perf_l2_misses, perf_smem_conflicts;

  mem_hierarchy u_mem (
    .clk            (clk),
    .rst_n          (rst_n),
    .warp_req       (warp_req),
    .warp_req_ready (warp_req_ready),
    .warp_rsp       (warp_rsp),
    .axi_awaddr     (axi_awaddr),
    .axi_awvalid    (axi_awvalid),
    .axi_awready    (axi_awready),
    .axi_wdata      (axi_wdata),
    .axi_wvalid     (axi_wvalid),
    .axi_wready     (axi_wready),
    .axi_bvalid     (axi_bvalid),
    .axi_bready     (axi_bready),
    .axi_araddr     (axi_araddr),
    .axi_arvalid    (axi_arvalid),
    .axi_arready    (axi_arready),
    .axi_rdata      (axi_rdata),
    .axi_rvalid     (axi_rvalid),
    .axi_rready     (axi_rready),
    .perf_l1_hits   (perf_l1_hits),
    .perf_l1_misses (perf_l1_misses),
    .perf_l2_hits   (perf_l2_hits),
    .perf_l2_misses (perf_l2_misses),
    .perf_smem_conflicts (perf_smem_conflicts)
  );

  logic [31:0] kernel_cta_x, kernel_cta_y;
  logic        running;

  enum logic [3:0] {
    GPU_IDLE,
    GPU_FETCH,
    GPU_DECODE,
    GPU_EXECUTE,
    GPU_MEM_WAIT,
    GPU_TC_WAIT,
    GPU_WB,
    GPU_DONE
  } gpu_state, gpu_next;

  // TC phase counter for weight/A loading via SRAM
  logic [10:0] tc_sram_cnt;
  logic [31:0] tc_load_src_addr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      fmt_reg <= FP16;
    else if (host_start)
      fmt_reg <= host_data_fmt;
  end

  always_comb begin
    for (int l = 0; l < 32; l++)
      ctx_ld_data_tie[l] = '0;
  end

  assign rf_lane_mask = current_lane_mask;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      gpu_state    <= GPU_IDLE;
      running      <= '0;
      host_done    <= '0;
      host_error   <= '0;

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
      // pred_active is combinational (see assign above)

      perf_instr_cnt  <= '0;
      perf_ld_cnt     <= '0;
      perf_st_cnt     <= '0;
      perf_vec_cnt    <= '0;
      perf_tc_cnt     <= '0;
      perf_branch_cnt <= '0;
    end else begin
      gpu_state <= gpu_next;
      rf_wr_en  <= '0;
      tc_sram_wen <= '0;
      vu_en     <= '0;
      su_en     <= '0;

      case (gpu_state)
        GPU_IDLE: begin
          host_done <= '0;
          if (host_start) begin
            kernel_cta_x <= host_grid_dim_x;
            kernel_cta_y <= host_grid_dim_y;
            warp_states[0] <= WARP_READY;
            warp_next_pc[0] <= host_kernel_addr;
            warp_pc_update[0] <= 1'b1;
            running <= 1'b1;
          end
        end

        GPU_FETCH: begin
          // Convergence check: if PC matches SIMT stack top, pop and restore
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

        GPU_DECODE: begin
          `HERMES_DBG(("[%0t] DECODE: scheduled_warp=%0d warp_rsp.valid=%b", $time, scheduled_warp, warp_rsp[scheduled_warp].valid));
          if (warp_rsp[scheduled_warp].valid) begin
            automatic logic [63:0] new_instr;
            new_instr = warp_rsp[scheduled_warp].data >> (warp_pc[scheduled_warp][5:3] * 64);
            `HERMES_DBG(("[%0t] DECODE: new_instr=%h opcode=%0d rd=%0d", $time, new_instr, new_instr[63:59], new_instr[58:54]));
            instr_word <= new_instr;
            warp_pc_update[scheduled_warp] <= 1'b1;
            warp_next_pc[scheduled_warp] <= warp_pc[scheduled_warp] + 8;
            warp_req[scheduled_warp] <= '0;
            ld_flag <= 1'b0;
            if (new_instr[63:59] == OP_EXIT) begin
              rf_wr_en <= '0;
              gpu_state <= GPU_DONE;
            end else if (new_instr[63:59] == OP_NOP) begin
              rf_wr_en <= '0;
              gpu_state <= GPU_FETCH;
            end else begin
              gpu_state <= GPU_EXECUTE;
            end
          end
        end

        GPU_EXECUTE: begin
          `HERMES_DBG(("[%0t] EXECUTE: opcode=%0d rd=%0d rs1=%0d rs2=%0d", $time, opcode, rd, rs1, rs2));
          perf_instr_cnt <= perf_instr_cnt + 1'b1;
          case (opcode)
            OP_MMA: begin
              `HERMES_DBG(("[%0t] EXECUTE MMA: rd=%0d rs1=%0d rs2=%0d", $time, rd, rs1, rs2));
              perf_tc_cnt <= perf_tc_cnt + 1'b1;
              tc_en <= 1'b1;
              if (!tc_busy) begin
                tc_start <= 1'b1;
                tc_weight_ld <= 1'b1;
                gpu_state <= GPU_TC_WAIT;
              end
            end

            OP_VADD, OP_VSUB, OP_VMUL, OP_VRELU,
            OP_VSIGMOID, OP_VTANH, OP_VCONV: begin
              perf_vec_cnt <= perf_vec_cnt + 1'b1;
              vu_en     <= 1'b1;
              vu_src_a  <= rf_rd1;
              vu_src_b  <= rf_rd2;
              if (vu_valid) gpu_state <= GPU_WB;
            end

            OP_SADD, OP_SSUB, OP_SMUL, OP_SMOV, OP_SBRA: begin
              su_en    <= 1'b1;
              su_src_a <= rf_rd1[0];
              su_src_b <= rf_rd2[0];
              if (opcode == OP_SBRA) begin
                perf_branch_cnt <= perf_branch_cnt + 1'b1;
                if (pred) begin
                  // Divergent branch: push fallthrough lanes to SIMT stack
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
                    // All lanes fall through — restore from stack
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
              gpu_state <= GPU_WB;
            end

            OP_LD: begin
              `HERMES_DBG(("[%0t] EXECUTE LD: imm=%h rf_rd1[0]=%h", $time, imm, rf_rd1[0]));
              perf_ld_cnt <= perf_ld_cnt + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b0;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_GLOBAL;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              ld_flag    <= 1'b1;
              if (warp_req_ready[scheduled_warp]) begin
                ld_pending <= 1'b1;
                gpu_state <= GPU_MEM_WAIT;
              end
            end

            OP_LDS: begin
              perf_ld_cnt <= perf_ld_cnt + 1'b1;
              warp_req[scheduled_warp].valid     <= 1'b1;
              warp_req[scheduled_warp].write     <= 1'b0;
              warp_req[scheduled_warp].addr      <= imm + (rf_rd1[0] << 1);
              warp_req[scheduled_warp].space     <= MEM_SHARED;
              warp_req[scheduled_warp].warp_id   <= scheduled_warp;
              warp_req[scheduled_warp].lane_mask <= current_lane_mask;
              ld_flag    <= 1'b1;
              if (warp_req_ready[scheduled_warp]) begin
                ld_pending <= 1'b1;
                gpu_state <= GPU_MEM_WAIT;
              end
            end

            OP_ST: begin
              `HERMES_DBG(("[%0t] EXECUTE ST: imm=%h rf_rd1[0]=%h", $time, imm, rf_rd1[0]));
              perf_st_cnt <= perf_st_cnt + 1'b1;
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
                gpu_state <= GPU_MEM_WAIT;
              end
            end

            OP_STS: begin
              perf_st_cnt <= perf_st_cnt + 1'b1;
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
                gpu_state <= GPU_MEM_WAIT;
              end
            end

            OP_BAR: begin
              warp_states[scheduled_warp] <= WARP_BLOCK;
              gpu_state <= GPU_WB;
            end

            default: begin
              gpu_state <= GPU_WB;
            end
          endcase
        end

        GPU_MEM_WAIT: begin
          `HERMES_DBG(("[%0t] MEM_WAIT: ld_pending=%b st_pending=%b warp_rsp.valid=%b", $time, ld_pending, st_pending, warp_rsp[scheduled_warp].valid));
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

        GPU_TC_WAIT: begin
          `HERMES_DBG(("[%0t] TC_WAIT: tc_done=%b tc_busy=%b", $time, tc_done, tc_busy));
          tc_start <= 1'b0;
          if (tc_done) begin
            gpu_state <= GPU_WB;
          end
        end

        GPU_WB: begin
          rf_wr_addr  <= rd;
          ld_pending  <= '0;
          st_pending  <= '0;
          warp_req[scheduled_warp] <= '0;

          // Branch PC update
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

        GPU_DONE: begin
          host_done <= 1'b1;
          running   <= '0;
          warp_states[scheduled_warp] <= WARP_DONE;
        end

        default: begin
        end
      endcase
    end
  end

  always_comb begin
    gpu_next = gpu_state;
    case (gpu_state)
      GPU_IDLE: begin
        if (host_start) gpu_next = GPU_FETCH;
      end

      GPU_FETCH: begin
        if (warp_req_ready[scheduled_warp]) gpu_next = GPU_DECODE;
      end

      GPU_DECODE: begin
        if (warp_rsp[scheduled_warp].valid) begin
          if (instr_word[63:59] == OP_EXIT) gpu_next = GPU_DONE;
          else if (instr_word[63:59] == OP_NOP) gpu_next = GPU_FETCH;
          else gpu_next = GPU_EXECUTE;
        end
      end

      GPU_EXECUTE: begin
        if (opcode == OP_MMA) begin
          if (!tc_busy) gpu_next = GPU_TC_WAIT;
          else gpu_next = GPU_EXECUTE;
        end else if (opcode inside {OP_LD, OP_ST, OP_LDS, OP_STS}) begin
          if (warp_req_ready[scheduled_warp]) gpu_next = GPU_MEM_WAIT;
          else gpu_next = GPU_EXECUTE;
        end else if (opcode inside {OP_VADD, OP_VSUB, OP_VMUL, OP_VRELU,
                                     OP_VSIGMOID, OP_VTANH, OP_VCONV}) begin
          if (vu_valid) gpu_next = GPU_WB;
          else gpu_next = GPU_EXECUTE;
        end else if (opcode == OP_BAR) begin
          gpu_next = GPU_WB;
        end else gpu_next = GPU_WB;
      end

      GPU_MEM_WAIT: begin
        if (st_pending && warp_rsp[scheduled_warp].valid) gpu_next = GPU_WB;
        else if (!st_pending && (warp_rsp[scheduled_warp].valid || !ld_pending)) gpu_next = GPU_WB;
      end

      GPU_TC_WAIT: begin
        if (tc_done) gpu_next = GPU_WB;
      end

      GPU_WB: begin
        gpu_next = GPU_FETCH;
      end

      GPU_DONE: begin
        gpu_next = GPU_IDLE;
      end

      default: gpu_next = GPU_IDLE;
    endcase
  end

endmodule