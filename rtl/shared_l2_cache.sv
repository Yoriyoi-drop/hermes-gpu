`include "hermes_defines.svh"
import hermes_pkg::*;

module shared_l2_cache (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [511:0] req_wdata,
  output logic [511:0] req_rdata,
  output logic        req_ready,
  output logic        req_rvalid,
  output logic [31:0] dram_awaddr,
  output logic        dram_awvalid,
  input  logic        dram_awready,
  output logic [511:0] dram_wdata,
  output logic        dram_wvalid,
  input  logic        dram_wready,
  output logic [31:0] dram_araddr,
  output logic        dram_arvalid,
  input  logic        dram_arready,
  input  logic [511:0] dram_rdata,
  input  logic        dram_rvalid,
  output logic        dram_rready,
  output logic [31:0] perf_hits,
  output logic [31:0] perf_misses,
  output logic [31:0] perf_reads,
  output logic [31:0] perf_writes
);

  logic [L2_TAG_W-1:0]  req_tag;
  logic [L2_INDEX_W-1:0] req_index;
  logic [L2_OFFSET_W-1:0] req_offset;

  assign req_tag    = req_addr[31:14];
  assign req_index  = req_addr[13:6];
  assign req_offset = req_addr[5:0];

  logic [L2_TAG_W-1:0] tag [0:L2_SETS-1][0:L2_WAYS-1];
  logic                valid [0:L2_SETS-1][0:L2_WAYS-1];
  logic                dirty [0:L2_SETS-1][0:L2_WAYS-1];
  logic [511:0]        data [0:L2_SETS-1][0:L2_WAYS-1];

  logic [L2_WAYS-1:0] way_hit;
  logic               cache_hit;
  logic [$clog2(L2_WAYS)-1:0] hit_way, lru_way;

  always_comb begin
    cache_hit = 1'b0;
    hit_way   = '0;
    for (int w = 0; w < L2_WAYS; w++) begin
      way_hit[w] = valid[req_index][w] && (tag[req_index][w] == req_tag);
      if (way_hit[w] && !cache_hit) begin
        cache_hit = 1'b1;
        hit_way   = w;
      end
    end
  end

  always_comb begin
    lru_way = 0;
    for (int w = 0; w < L2_WAYS; w++) begin
      if (!valid[req_index][w]) begin
        lru_way = w;
        break;
      end
    end
  end

  typedef enum logic [1:0] { IDLE, AXI_READ_WAIT, READ_MISS, WRITEBACK } l2_state_t;
  l2_state_t l2_state;
  logic       miss_pending;
  logic [L2_TAG_W-1:0] wb_tag;
  logic [L2_INDEX_W-1:0] wb_index;
  logic [511:0] wb_data;
  logic [511:0] fill_data;
  logic [31:0] hits, misses, reads, writes;

  assign req_ready = (l2_state == IDLE) && !miss_pending;

  assign req_rdata = ((l2_state == READ_MISS) && dram_rvalid) ? dram_rdata : data[req_index][hit_way];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      l2_state    <= IDLE;
      miss_pending <= '0;
      req_rvalid  <= '0;
      dram_awvalid <= '0;
      dram_wvalid  <= '0;
      dram_arvalid <= '0;
      dram_rready  <= '0;
      hits <= '0; misses <= '0; reads <= '0; writes <= '0;
    end else begin
      case (l2_state)
        IDLE: begin
          dram_rready <= '0;
          req_rvalid <= '0;
          if (req_valid && cache_hit) begin
            if (req_write) begin
              data[req_index][hit_way] <= req_wdata;
              dirty[req_index][hit_way] <= 1'b1;
              writes <= writes + 1'b1;
            end else begin
              reads <= reads + 1'b1;
            end
            hits <= hits + 1'b1;
            req_rvalid <= 1'b1;
          end else if (req_valid && !cache_hit && !miss_pending) begin
            miss_pending <= 1'b1;
            misses <= misses + 1'b1;
            if (dirty[req_index][lru_way]) begin
              wb_data  <= data[req_index][lru_way];
              wb_tag   <= tag[req_index][lru_way];
              wb_index <= req_index;
              l2_state <= WRITEBACK;
            end else begin
              dram_araddr  <= {req_tag, req_index, 6'b0};
              dram_arvalid <= 1'b1;
              l2_state <= AXI_READ_WAIT;
            end
          end
        end

        AXI_READ_WAIT: begin
          if (dram_arready) begin
            dram_arvalid <= 1'b0;
            l2_state <= READ_MISS;
          end
        end

        WRITEBACK: begin
          dram_awaddr  <= {wb_tag, wb_index, 6'b0};
          dram_awvalid <= 1'b1;
          dram_wdata   <= wb_data;
          dram_wvalid  <= 1'b1;
          if (dram_awready && dram_wready) begin
            valid[wb_index][lru_way] <= 1'b0;
            dram_awvalid <= 1'b0;
            dram_wvalid  <= 1'b0;
            dram_araddr  <= {req_tag, req_index, 6'b0};
            dram_arvalid <= 1'b1;
            l2_state <= AXI_READ_WAIT;
          end
        end

        READ_MISS: begin
          dram_rready <= 1'b1;
          if (dram_rvalid && dram_rready) begin
            data[req_index][lru_way]  <= dram_rdata;
            tag[req_index][lru_way]   <= req_tag;
            valid[req_index][lru_way] <= 1'b1;
            dirty[req_index][lru_way] <= 1'b0;
            dram_rready    <= 1'b0;
            req_rvalid     <= 1'b1;
            miss_pending   <= 1'b0;
            l2_state       <= IDLE;
            reads <= reads + 1'b1;
          end
        end
      endcase
    end
  end

  assign perf_hits = hits;
  assign perf_misses = misses;
  assign perf_reads = reads;
  assign perf_writes = writes;

endmodule