`include "hermes_defines.svh"
import hermes_pkg::*;

module l1_cache (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [511:0] req_wdata,
  output logic [511:0] req_rdata,
  output logic        req_ready,
  output logic        req_rvalid,
  output logic        mem_req_valid,
  output logic        mem_req_write,
  output logic [31:0] mem_req_addr,
  output logic [511:0] mem_req_wdata,
  input  logic [511:0] mem_req_rdata,
  input  logic        mem_req_ready,
  input  logic        mem_req_rvalid,
  output logic [31:0] perf_hits,
  output logic [31:0] perf_misses,
  output logic [31:0] perf_reads,
  output logic [31:0] perf_writes
);

  logic [L1_TAG_W-1:0] tag [0:L1_SETS-1][0:L1_WAYS-1];
  logic                valid [0:L1_SETS-1][0:L1_WAYS-1];
  logic                dirty [0:L1_SETS-1][0:L1_WAYS-1];
  logic [511:0]        data [0:L1_SETS-1][0:L1_WAYS-1];

  logic [L1_TAG_W-1:0]  req_tag;
  logic [L1_INDEX_W-1:0] req_index;
  logic [L1_OFFSET_W-1:0] req_offset;

  assign req_tag    = req_addr[31:12];
  assign req_index  = req_addr[11:5];
  assign req_offset = req_addr[4:0];

  logic [L1_WAYS-1:0] way_hit;
  logic               cache_hit;
  logic [$clog2(L1_WAYS)-1:0] hit_way, lru_way;

  always_comb begin
    cache_hit = 1'b0;
    hit_way   = '0;
    for (int w = 0; w < L1_WAYS; w++) begin
      way_hit[w] = valid[req_index][w] && (tag[req_index][w] == req_tag);
      if (way_hit[w] && !cache_hit) begin
        cache_hit = 1'b1;
        hit_way   = w;
      end
    end
  end

  always_comb begin
    lru_way = 0;
    for (int w = 0; w < L1_WAYS; w++) begin
      if (!valid[req_index][w]) begin
        lru_way = w;
        break;
      end
    end
  end

  assign req_rdata = cache_hit ? data[req_index][hit_way] : '0;

  typedef enum logic [0:0] { IDLE, MISS_FILL } miss_state_t;
  miss_state_t miss_state;
  logic        miss_pending;
  logic        miss_write;
  logic [511:0] miss_wdata;
  logic [L1_TAG_W-1:0] miss_tag;
  logic [L1_INDEX_W-1:0] miss_index;
  logic [$clog2(L1_WAYS)-1:0] miss_lru_way;

  logic [31:0] hits, misses, reads, writes;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      miss_state <= IDLE;
      miss_pending <= '0;
      req_rvalid  <= '0;
      req_ready   <= '0;
      hits <= '0; misses <= '0; reads <= '0; writes <= '0;
    end else begin
      case (miss_state)
        IDLE: begin
          req_ready  <= 1'b1;
          req_rvalid <= 1'b0;
          if (req_valid && !cache_hit && !miss_pending) begin
            `HERMES_DBG(("[%0t] L1_MISS: addr=%h tag=%h idx=%h req_ready_before=%b",
                     $time, req_addr, req_tag, req_index, req_ready));
            req_ready      <= 1'b0;
            mem_req_addr   <= {req_tag, req_index, 5'b0};
            mem_req_write  <= 1'b0;
            miss_write     <= req_write;
            miss_wdata     <= req_wdata;
            miss_tag       <= req_tag;
            miss_index     <= req_index;
            miss_lru_way   <= lru_way;
            miss_pending   <= 1'b1;
            miss_state     <= MISS_FILL;
            misses <= misses + 1'b1;
          end else if (req_valid && cache_hit && req_write) begin
            data[req_index][hit_way] <= req_wdata;
            dirty[req_index][hit_way] <= 1'b1;
            req_rvalid <= 1'b1;
            hits <= hits + 1'b1;
            writes <= writes + 1'b1;
          end else if (req_valid && cache_hit && !req_write) begin
            req_rvalid <= 1'b1;
            hits <= hits + 1'b1;
            reads <= reads + 1'b1;
          end
        end

        MISS_FILL: begin
          if (mem_req_rvalid) begin
            if (miss_write) begin
              data[miss_index][miss_lru_way] <= miss_wdata;
              dirty[miss_index][miss_lru_way] <= 1'b1;
            end else begin
              data[miss_index][miss_lru_way] <= mem_req_rdata;
              dirty[miss_index][miss_lru_way] <= 1'b0;
            end
            tag[miss_index][miss_lru_way]   <= miss_tag;
            valid[miss_index][miss_lru_way] <= 1'b1;
            req_rvalid  <= 1'b1;
            miss_pending <= 1'b0;
            miss_state  <= IDLE;
          end
        end
      endcase
    end
  end

  assign mem_req_valid = miss_pending && (miss_state == MISS_FILL);
  assign perf_hits = hits;
  assign perf_misses = misses;
  assign perf_reads = reads;
  assign perf_writes = writes;

endmodule