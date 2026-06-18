`include "hermes_defines.svh"
import hermes_pkg::*;

module mem_hierarchy (
  input  logic        clk,
  input  logic        rst_n,
  input  mem_req_t    warp_req [0:7],
  output logic        warp_req_ready [0:7],
  output mem_rsp_t    warp_rsp [0:7],
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
  output logic        axi_rready,
  output logic [31:0] perf_l1_hits,
  output logic [31:0] perf_l1_misses,
  output logic [31:0] perf_l2_hits,
  output logic [31:0] perf_l2_misses,
  output logic [31:0] perf_smem_conflicts
);

  mem_req_t  arb_out;
  mem_rsp_t  l1_rsp, l2_rsp, smem_rsp, arb_mem_rsp;
  logic      arb_ready, l1_ready;
  logic      l1_rvalid, l2_rvalid;
  logic [31:0] l1_hits, l1_misses, l2_hits, l2_misses;
  logic [31:0] l1_reads, l1_writes, l2_reads, l2_writes;

  mem_arbiter u_arb (
    .clk           (clk),
    .rst_n         (rst_n),
    .warp_req      (warp_req),
    .warp_req_ready(warp_req_ready),
    .warp_rsp      (warp_rsp),
    .mem_req       (arb_out),
    .mem_req_ready (arb_ready),
    .mem_rsp       (arb_mem_rsp),
    .mem_rsp_ready ()
  );

  tlb u_tlb (
    .clk          (clk),
    .rst_n        (rst_n),
    .lookup_valid (arb_out.valid && arb_out.space == MEM_GLOBAL),
    .lookup_vaddr (arb_out.addr),
    .lookup_hit   (),
    .lookup_paddr (),
    .fill_valid   (1'b0),
    .fill_vpn     ('0),
    .fill_ppn     ('0),
    .fill_dirty   (1'b0),
    .inv_all      (1'b0),
    .inv_valid    (1'b0),
    .inv_vpn      ('0),
    .full         ()
  );

  logic [4:0] shmem_conflict_cycles;

  shared_memory u_smem (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (arb_out.valid && arb_out.space == MEM_SHARED),
    .wr    (arb_out.write),
    .addr  (arb_out.addr[SHARED_ADDR_W-1:0]),
    .wdata (arb_out.data),
    .lane_mask (arb_out.lane_mask),
    .rdata (smem_rsp.data),
    .done  (smem_rsp.valid),
    .conflict_cycles (shmem_conflict_cycles)
  );

  assign smem_rsp.warp_id = arb_out.warp_id;

  assign arb_mem_rsp = (arb_out.space == MEM_SHARED) ? smem_rsp : l1_rsp;

  assign arb_ready = (arb_out.space == MEM_SHARED) ? (arb_out.valid) : l1_ready;

  logic        l1_mem_req_valid;
  logic        l1_mem_req_write;
  logic [31:0] l1_mem_req_addr;
  logic [511:0] l1_mem_req_wdata;
  logic        l2_req_ready;
  logic [511:0] l2_rsp_data;
  logic        l2_rvalid_int;

  l1_cache u_l1 (
    .clk            (clk),
    .rst_n          (rst_n),
    .req_valid      (arb_out.valid && arb_out.space == MEM_GLOBAL),
    .req_write      (arb_out.write),
    .req_addr       (arb_out.addr),
    .req_wdata      (arb_out.data),
    .req_rdata      (l1_rsp.data),
    .req_ready      (l1_ready),
    .req_rvalid     (l1_rvalid),
    .mem_req_valid  (l1_mem_req_valid),
    .mem_req_write  (l1_mem_req_write),
    .mem_req_addr   (l1_mem_req_addr),
    .mem_req_wdata  (l1_mem_req_wdata),
    .mem_req_rdata  (l2_rsp_data),
    .mem_req_ready  (l2_req_ready),
    .mem_req_rvalid (l2_rvalid_int),
    .perf_hits      (l1_hits),
    .perf_misses    (l1_misses),
    .perf_reads     (l1_reads),
    .perf_writes    (l1_writes)
  );

  assign l1_rsp.valid   = l1_rvalid;
  assign l1_rsp.warp_id = arb_out.warp_id;

  l2_cache u_l2 (
    .clk           (clk),
    .rst_n         (rst_n),
    .req_valid     (l1_mem_req_valid),
    .req_write     (l1_mem_req_write),
    .req_addr      (l1_mem_req_addr),
    .req_wdata     (l1_mem_req_wdata),
    .req_rdata     (l2_rsp_data),
    .req_ready     (l2_req_ready),
    .req_rvalid    (l2_rvalid_int),
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
    .perf_hits     (l2_hits),
    .perf_misses   (l2_misses),
    .perf_reads    (l2_reads),
    .perf_writes   (l2_writes)
  );

  assign perf_l1_hits = l1_hits;
  assign perf_l1_misses = l1_misses;
  assign perf_l2_hits = l2_hits;
  assign perf_l2_misses = l2_misses;
  assign perf_smem_conflicts = shmem_conflict_cycles;

  assign axi_bready = 1'b1;  // Always ready for write response

endmodule