`include "hermes_defines.svh"
import hermes_pkg::*;

module hermes_multi_gpu (
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

  logic        core_start [0:NUM_CORES-1];
  logic [31:0] core_kernel_addr [0:NUM_CORES-1];
  logic [31:0] core_arg_a [0:NUM_CORES-1];
  logic [31:0] core_arg_b [0:NUM_CORES-1];
  logic [31:0] core_arg_c [0:NUM_CORES-1];
  logic [1:0]  core_data_fmt [0:NUM_CORES-1];
  logic [31:0] core_grid_dim_x [0:NUM_CORES-1];
  logic [31:0] core_grid_dim_y [0:NUM_CORES-1];
  logic        core_done [0:NUM_CORES-1];
  logic        core_idle [0:NUM_CORES-1];

  logic        l2_req_valid, l2_req_write;
  logic [31:0] l2_req_addr;
  logic [511:0] l2_req_wdata;
  logic        l2_req_ready;
  logic [511:0] l2_rsp_rdata;
  logic        l2_rsp_rvalid;

  logic        core_l2_req_valid [0:NUM_CORES-1];
  logic        core_l2_req_write [0:NUM_CORES-1];
  logic [31:0] core_l2_req_addr [0:NUM_CORES-1];
  logic [511:0] core_l2_req_wdata [0:NUM_CORES-1];
  logic        core_l2_req_ready [0:NUM_CORES-1];
  logic [511:0] core_l2_rsp_rdata [0:NUM_CORES-1];
  logic        core_l2_rsp_rvalid [0:NUM_CORES-1];

  work_distributor u_wd (
    .clk              (clk),
    .rst_n            (rst_n),
    .host_start       (host_start),
    .host_kernel_addr (host_kernel_addr),
    .host_arg_a       (host_arg_a),
    .host_arg_b       (host_arg_b),
    .host_arg_c       (host_arg_c),
    .host_data_fmt    (host_data_fmt),
    .host_grid_dim_x  (host_grid_dim_x),
    .host_grid_dim_y  (host_grid_dim_y),
    .host_done        (host_done),
    .host_error       (host_error),
    .core_start       (core_start),
    .core_kernel_addr (core_kernel_addr),
    .core_arg_a       (core_arg_a),
    .core_arg_b       (core_arg_b),
    .core_arg_c       (core_arg_c),
    .core_data_fmt    (core_data_fmt),
    .core_grid_dim_x  (core_grid_dim_x),
    .core_grid_dim_y  (core_grid_dim_y),
    .core_done        (core_done),
    .core_idle        (core_idle)
  );

  genvar c;
  generate
    for (c = 0; c < NUM_CORES; c++) begin : core
      hermes_gpu_core u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .core_id         (core_id_t'(c)),
        .core_start      (core_start[c]),
        .core_kernel_addr(core_kernel_addr[c]),
        .core_arg_a      (core_arg_a[c]),
        .core_arg_b      (core_arg_b[c]),
        .core_arg_c      (core_arg_c[c]),
        .core_data_fmt   (core_data_fmt[c]),
        .core_grid_dim_x (core_grid_dim_x[c]),
        .core_grid_dim_y (core_grid_dim_y[c]),
        .core_done       (core_done[c]),
        .core_idle       (core_idle[c]),
        .l2_req_valid    (core_l2_req_valid[c]),
        .l2_req_write    (core_l2_req_write[c]),
        .l2_req_addr     (core_l2_req_addr[c]),
        .l2_req_wdata    (core_l2_req_wdata[c]),
        .l2_req_ready    (core_l2_req_ready[c]),
        .l2_rsp_rdata    (core_l2_rsp_rdata[c]),
        .l2_rsp_rvalid   (core_l2_rsp_rvalid[c]),
        .perf_instr_cnt  (),
        .perf_ld_cnt     (),
        .perf_st_cnt     (),
        .perf_vec_cnt    (),
        .perf_tc_cnt     (),
        .perf_branch_cnt (),
        .perf_l1_hits    (),
        .perf_l1_misses  (),
        .perf_smem_conflicts (),
        .perf_warp_active (),
        .perf_warp_total ()
      );
    end
  endgenerate

  crossbar u_xbar (
    .clk             (clk),
    .rst_n           (rst_n),
    .core_req_valid  (core_l2_req_valid),
    .core_req_write  (core_l2_req_write),
    .core_req_addr   (core_l2_req_addr),
    .core_req_wdata  (core_l2_req_wdata),
    .core_req_ready  (core_l2_req_ready),
    .core_rsp_rdata  (core_l2_rsp_rdata),
    .core_rsp_rvalid (core_l2_rsp_rvalid),
    .l2_req_valid    (l2_req_valid),
    .l2_req_write    (l2_req_write),
    .l2_req_addr     (l2_req_addr),
    .l2_req_wdata    (l2_req_wdata),
    .l2_req_ready    (l2_req_ready),
    .l2_rsp_rdata    (l2_rsp_rdata),
    .l2_rsp_rvalid   (l2_rsp_rvalid)
  );

  assign axi_bready = 1'b1;

  shared_l2_cache u_l2 (
    .clk           (clk),
    .rst_n         (rst_n),
    .req_valid     (l2_req_valid),
    .req_write     (l2_req_write),
    .req_addr      (l2_req_addr),
    .req_wdata     (l2_req_wdata),
    .req_rdata     (l2_rsp_rdata),
    .req_ready     (l2_req_ready),
    .req_rvalid    (l2_rsp_rvalid),
    .dram_awaddr   (axi_awaddr),
    .dram_awvalid  (axi_awvalid),
    .dram_awready  (axi_awready),
    .dram_wdata    (axi_wdata),
    .dram_wvalid   (axi_wvalid),
    .dram_wready   (axi_wready),
    .dram_araddr   (axi_araddr),
    .dram_arvalid  (axi_arvalid),
    .dram_arready  (axi_arready),
    .dram_rdata    (axi_rdata),
    .dram_rvalid   (axi_rvalid),
    .dram_rready   (axi_rready),
    .perf_hits     (),
    .perf_misses   (),
    .perf_reads    (),
    .perf_writes   ()
  );

endmodule