import hermes_pkg::*;

module tlb (
  input  logic        clk,
  input  logic        rst_n,
  // Lookup
  input  logic        lookup_valid,
  input  logic [31:0] lookup_vaddr,
  output logic        lookup_hit,
  output logic [31:0] lookup_paddr,
  // Fill (from page table walker / software)
  input  logic        fill_valid,
  input  logic [VPN_W-1:0] fill_vpn,
  input  logic [PPN_W-1:0] fill_ppn,
  input  logic        fill_dirty,
  // Invalidate
  input  logic        inv_all,
  input  logic        inv_valid,
  input  logic [VPN_W-1:0] inv_vpn,
  output logic        full
);

  tlb_entry_t entries [0:TLB_ENTRIES-1];
  logic [$clog2(TLB_ENTRIES)-1:0] repl_ptr;
  logic [VPN_W-1:0] req_vpn;
  logic [PAGE_OFFSET_W-1:0] req_offset;

  assign req_vpn    = lookup_vaddr[31:12];
  assign req_offset = lookup_vaddr[11:0];

  // Tag match
  logic [TLB_ENTRIES-1:0] tag_match;
  logic                   any_hit;
  logic [$clog2(TLB_ENTRIES)-1:0] hit_idx;

  always_comb begin
    any_hit = 1'b0;
    hit_idx = '0;
    tag_match = '0;
    for (int i = 0; i < TLB_ENTRIES; i++) begin
      tag_match[i] = entries[i].valid && (entries[i].vpn == req_vpn);
      if (tag_match[i] && !any_hit) begin
        any_hit = 1'b1;
        hit_idx = i;
      end
    end
  end

  assign lookup_hit = lookup_valid && any_hit;
  assign lookup_paddr = {entries[hit_idx].ppn, req_offset};

  // Fill / replace
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < TLB_ENTRIES; i++) begin
        entries[i].valid <= 1'b0;
        entries[i].dirty <= 1'b0;
        entries[i].vpn   <= '0;
        entries[i].ppn   <= '0;
      end
      repl_ptr <= '0;
    end else begin
      if (inv_all) begin
        for (int i = 0; i < TLB_ENTRIES; i++)
          entries[i].valid <= 1'b0;
      end else if (inv_valid) begin
        for (int i = 0; i < TLB_ENTRIES; i++)
          if (entries[i].vpn == inv_vpn)
            entries[i].valid <= 1'b0;
      end else if (fill_valid) begin
        entries[repl_ptr].valid <= 1'b1;
        entries[repl_ptr].dirty <= fill_dirty;
        entries[repl_ptr].vpn   <= fill_vpn;
        entries[repl_ptr].ppn   <= fill_ppn;
        repl_ptr <= repl_ptr + 1'b1;
      end
    end
  end

  // Full detection
  logic [TLB_ENTRIES-1:0] valid_bits;
  always_comb begin
    for (int i = 0; i < TLB_ENTRIES; i++)
      valid_bits[i] = entries[i].valid;
  end
  assign full = &valid_bits;

endmodule
