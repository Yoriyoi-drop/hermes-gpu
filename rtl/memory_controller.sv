import hermes_pkg::*;

module memory_controller (
  input  logic        clk,
  input  logic        rst_n,
  // Request interface (from GPU core)
  input  logic        req_valid,
  input  logic        req_write,
  input  logic [1:0]  req_space,     // 0=global, 1=shared, 2=uniform
  input  logic [31:0] req_addr,
  input  logic [511:0] req_data,     // 32 x 16-bit
  input  logic [31:0] req_lane_mask,
  input  logic [4:0]  req_warp_id,
  output logic        req_ready,
  // Response interface
  output logic        rsp_valid,
  output logic [511:0] rsp_data,
  output logic [4:0]  rsp_warp_id,
  // AXI-like interface to DRAM
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
  // Shared memory interface
  output logic        shmem_en,
  output logic        shmem_wr,
  output logic [14:0] shmem_addr,
  output logic [511:0] shmem_wdata,
  input  logic [511:0] shmem_rdata
);

  typedef enum logic [2:0] {
    IDLE,
    SHARED_READ,
    SHARED_WRITE,
    GLOBAL_READ,
    GLOBAL_WRITE,
    GLOBAL_WAIT_RDATA,
    RESPONSE
  } state_t;

  state_t state, next;
  logic [511:0] rdata_q;
  logic [4:0]   warp_id_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= IDLE;
      rdata_q   <= '0;
      warp_id_q <= '0;
      rsp_valid <= '0;
      rsp_data  <= '0;
      rsp_warp_id <= '0;
    end else begin
      state <= next;
      case (state)
        IDLE: begin
          rsp_valid <= '0;
          if (req_valid) begin
            warp_id_q <= req_warp_id;
          end
        end

        SHARED_READ: begin
          rdata_q <= shmem_rdata;
        end

        GLOBAL_WAIT_RDATA: begin
          if (axi_rvalid) begin
            rdata_q <= axi_rdata;
          end
        end

        RESPONSE: begin
          rsp_valid   <= 1'b1;
          rsp_data    <= rdata_q;
          rsp_warp_id <= warp_id_q;
        end

        default: begin
          rsp_valid <= '0;
        end
      endcase
    end
  end

  always_comb begin
    next        = state;
    req_ready   = 1'b0;
    axi_awaddr  = '0;
    axi_awvalid = '0;
    axi_wdata   = '0;
    axi_wvalid  = '0;
    axi_bready  = '0;
    axi_araddr  = '0;
    axi_arvalid = '0;
    axi_rready  = '0;
    shmem_en    = '0;
    shmem_wr    = '0;
    shmem_addr  = '0;
    shmem_wdata = '0;

    case (state)
      IDLE: begin
        if (req_valid) begin
          if (req_space == MEM_SHARED) begin
            shmem_en  = 1'b1;
            shmem_wr  = req_write;
            shmem_addr = req_addr[14:0];
            shmem_wdata = req_data;
            if (req_write) begin
              next = IDLE;
              req_ready = 1'b1;
            end else begin
              next = SHARED_READ;
              req_ready = 1'b1;
            end
          end else begin // Global memory
            if (req_write) begin
              axi_awaddr  = req_addr;
              axi_awvalid = 1'b1;
              axi_wdata   = req_data;
              axi_wvalid  = 1'b1;
              if (axi_awready && axi_wready) begin
                next = IDLE;
                req_ready = 1'b1;
              end else begin
                next = GLOBAL_WRITE;
              end
            end else begin
              axi_araddr  = req_addr;
              axi_arvalid = 1'b1;
              if (axi_arready) begin
                next = GLOBAL_WAIT_RDATA;
                req_ready = 1'b1;
              end else begin
                next = GLOBAL_READ;
              end
            end
          end
        end
      end

      SHARED_READ: begin
        next = RESPONSE;
      end

      GLOBAL_WRITE: begin
        axi_awaddr  = req_addr;
        axi_awvalid = 1'b1;
        axi_wdata   = req_data;
        axi_wvalid  = 1'b1;
        if (axi_awready && axi_wready)
          next = IDLE;
      end

      GLOBAL_READ: begin
        axi_araddr  = req_addr;
        axi_arvalid = 1'b1;
        if (axi_arready)
          next = GLOBAL_WAIT_RDATA;
      end

      GLOBAL_WAIT_RDATA: begin
        axi_rready = 1'b1;
        if (axi_rvalid)
          next = RESPONSE;
      end

      RESPONSE: begin
        next = IDLE;
      end

      default: begin
        next = IDLE;
      end
    endcase
  end

endmodule
