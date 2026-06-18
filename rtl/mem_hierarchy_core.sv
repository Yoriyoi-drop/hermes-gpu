`include "hermes_defines.svh"
import hermes_pkg::*;

module mem_hierarchy_core (
  input  logic        clk,
  input  logic        rst_n,
  input  mem_req_t    warp_req [0:NUM_WARPS-1],
  output logic        warp_req_ready [0:NUM_WARPS-1],
  output mem_rsp_t    warp_rsp [0:NUM_WARPS-1],

  output logic        l2_req_valid,
  output logic        l2_req_write,
  output logic [31:0] l2_req_addr,
  output logic [511:0] l2_req_wdata,
  input  logic        l2_req_ready,
  input  logic [511:0] l2_rsp_rdata,
  input  logic        l2_rsp_rvalid,

  output logic [31:0] perf_l1_hits,
  output logic [31:0] perf_l1_misses,
  output logic [31:0] perf_smem_conflicts
);

  mem_req_t  arb_out;
  mem_rsp_t  l1_rsp, smem_rsp, arb_mem_rsp;
  logic      arb_ready, l1_ready;
  logic      l1_rvalid;
  logic [31:0] l1_hits, l1_misses;
  logic [31:0] l1_reads, l1_writes;

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

  assign arb_ready = (arb_out.space == MEM_SHARED) ? (arb_out.valid) : l1_ready;
  assign arb_mem_rsp = (arb_out.space == MEM_SHARED) ? smem_rsp : l1_rsp;

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
    .mem_req_valid  (l2_req_valid),
    .mem_req_write  (l2_req_write),
    .mem_req_addr   (l2_req_addr),
    .mem_req_wdata  (l2_req_wdata),
    .mem_req_rdata  (l2_rsp_rdata),
    .mem_req_ready  (l2_req_ready),
    .mem_req_rvalid (l2_rsp_rvalid),
    .perf_hits      (l1_hits),
    .perf_misses    (l1_misses),
    .perf_reads     (l1_reads),
    .perf_writes    (l1_writes)
  );

  assign l1_rsp.valid   = l1_rvalid;
  assign l1_rsp.warp_id = arb_out.warp_id;

  assign perf_l1_hits = l1_hits;
  assign perf_l1_misses = l1_misses;
  assign perf_smem_conflicts = shmem_conflict_cycles;

endmodule