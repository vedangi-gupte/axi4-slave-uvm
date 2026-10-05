// Code your design here

`timescale 1ns/1ps

module axi_slave (
  input  logic        clk,
  input  logic        resetn,

  // AXI4 write address channel
  input  logic        awvalid,
  output logic        awready,
  input  logic [3:0]  awid,
  input  logic [7:0]  awlen,
  input  logic [2:0]  awsize,
  input  logic [31:0] awaddr,
  input  logic [1:0]  awburst,

  // AXI4 write data channel (AXI4 has no WID signal)
  input  logic        wvalid,
  output logic        wready,
  input  logic [31:0] wdata,
  input  logic [3:0]  wstrb,
  input  logic        wlast,

  // AXI4 write response channel
  input  logic        bready,
  output logic        bvalid,
  output logic [3:0]  bid,
  output logic [1:0]  bresp,

  // AXI4 read address channel
  input  logic        arvalid,
  output logic        arready,
  input  logic [3:0]  arid,
  input  logic [7:0]  arlen,
  input  logic [2:0]  arsize,
  input  logic [31:0] araddr,
  input  logic [1:0]  arburst,

  // AXI4 read data channel (AXI4 has no RSTRB signal)
  input  logic        rready,
  output logic        rvalid,
  output logic [3:0]  rid,
  output logic [31:0] rdata,
  output logic [1:0]  rresp,
  output logic        rlast
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  typedef enum logic [1:0] {ACTIVE_IDLE, ACTIVE_WRITE, ACTIVE_READ} active_t;
  typedef enum logic [1:0] {AW_IDLE, AW_ACCEPTED} aw_state_t;
  typedef enum logic [1:0] {W_IDLE, W_ACCEPT, W_DISCARD} w_state_t;
  typedef enum logic       {B_IDLE, B_VALID} b_state_t;
  typedef enum logic [1:0] {AR_IDLE, AR_ACCEPTED} ar_state_t;
  typedef enum logic       {R_IDLE, R_VALID} r_state_t;

  active_t  active_q;
  aw_state_t aw_state_q;
  w_state_t  w_state_q;
  b_state_t  b_state_q;
  ar_state_t ar_state_q;
  r_state_t  r_state_q;

  logic [7:0] mem [0:127];

  logic [3:0]  awid_q;
  logic [7:0]  awlen_q;
  logic [2:0]  awsize_q;
  logic [31:0] awaddr_q;
  logic [1:0]  awburst_q;
  logic [7:0]  wcount_q;
  logic [1:0]  bresp_q;

  logic [3:0]  arid_q;
  logic [7:0]  arlen_q;
  logic [2:0]  arsize_q;
  logic [31:0] araddr_q;
  logic [1:0]  arburst_q;
  logic [7:0]  rcount_q;
  logic [31:0] rdata_q;
  logic [1:0]  rresp_q;
  logic        rlast_q;

  integer reset_index;
  integer lane;

  function automatic integer bytes_for_size(input logic [2:0] size);
    begin
      case (size)
        3'd0: bytes_for_size = 1;
        3'd1: bytes_for_size = 2;
        3'd2: bytes_for_size = 4;
        default: bytes_for_size = 0;
      endcase
    end
  endfunction

  function automatic logic [31:0] burst_address(
    input logic [31:0] start_addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input integer      beat_index
  );
    integer bytes;
    integer beats;
    integer total_bytes;
    integer wrap_base;
    logic [31:0] candidate;
    begin
      bytes = bytes_for_size(size);
      beats = len + 1;
      candidate = start_addr;
      if (bytes == 0) begin
        burst_address = start_addr;
      end else begin
        case (burst)
          2'b00: candidate = start_addr;
          2'b01: candidate = start_addr + (beat_index * bytes);
          2'b10: begin
            total_bytes = beats * bytes;
            wrap_base = (start_addr / total_bytes) * total_bytes;
            candidate = start_addr + (beat_index * bytes);
            if (candidate >= (wrap_base + total_bytes))
              candidate = candidate - total_bytes;
          end
          default: candidate = start_addr;
        endcase
        burst_address = candidate;
      end
    end
  endfunction

  function automatic logic [1:0] classify_burst(
    input logic [31:0] start_addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst
  );
    integer bytes;
    integer beats;
    integer i;
    integer last_byte;
    logic [31:0] current_addr;
    begin
      bytes = bytes_for_size(size);
      beats = len + 1;
      classify_burst = RESP_OKAY;

      if ((bytes == 0) || (burst > 2'b10)) begin
        classify_burst = RESP_SLVERR;
      end else if ((start_addr % bytes) != 0) begin
        classify_burst = RESP_SLVERR;
      end else if ((burst == 2'b10) &&
                   !((beats == 2) || (beats == 4) || (beats == 8) || (beats == 16))) begin
        classify_burst = RESP_SLVERR;
      end else begin
        for (i = 0; i < beats; i = i + 1) begin
          current_addr = burst_address(start_addr, len, size, burst, i);
          last_byte = current_addr + bytes - 1;
          if (last_byte >= 128)
            classify_burst = RESP_DECERR;
        end
      end
    end
  endfunction

  function automatic logic [31:0] read_word(
    input logic [31:0] address,
    input logic [2:0]  size
  );
    integer read_lane;
    integer read_bytes;
    logic [31:0] value;
    begin
      value = 32'b0;
      read_bytes = bytes_for_size(size);
      for (read_lane = 0; read_lane < read_bytes; read_lane = read_lane + 1)
        value[8*read_lane +: 8] = mem[address + read_lane];
      read_word = value;
    end
  endfunction

  always_comb begin
    awready = 1'b0;
    wready  = 1'b0;
    bvalid  = 1'b0;
    bid     = awid_q;
    bresp   = bresp_q;
    arready = 1'b0;
    rvalid  = 1'b0;
    rid     = arid_q;
    rdata   = rdata_q;
    rresp   = rresp_q;
    rlast   = rlast_q;

    if (active_q == ACTIVE_IDLE) begin
      // Write address has arbitration priority if both address channels request together.
      awready = 1'b1;
      arready = !awvalid;
    end else if (active_q == ACTIVE_WRITE) begin
      wready = (w_state_q == W_ACCEPT) || (w_state_q == W_DISCARD);
      bvalid = (b_state_q == B_VALID);
    end else if (active_q == ACTIVE_READ) begin
      rvalid = (r_state_q == R_VALID);
    end
  end

  always_ff @(posedge clk or negedge resetn) begin
    if (!resetn) begin
      active_q   <= ACTIVE_IDLE;
      aw_state_q <= AW_IDLE;
      w_state_q  <= W_IDLE;
      b_state_q  <= B_IDLE;
      ar_state_q <= AR_IDLE;
      r_state_q  <= R_IDLE;

      awid_q     <= '0;
      awlen_q    <= '0;
      awsize_q   <= '0;
      awaddr_q   <= '0;
      awburst_q  <= '0;
      wcount_q   <= '0;
      bresp_q    <= RESP_OKAY;

      arid_q     <= '0;
      arlen_q    <= '0;
      arsize_q   <= '0;
      araddr_q   <= '0;
      arburst_q  <= '0;
      rcount_q   <= '0;
      rdata_q    <= '0;
      rresp_q    <= RESP_OKAY;
      rlast_q    <= 1'b0;

      for (reset_index = 0; reset_index < 128; reset_index = reset_index + 1)
        mem[reset_index] <= 8'h00;
    end else begin
      case (active_q)
        ACTIVE_IDLE: begin
          if (awvalid && awready) begin
            active_q   <= ACTIVE_WRITE;
            aw_state_q <= AW_ACCEPTED;
            wcount_q   <= 8'd0;
            b_state_q  <= B_IDLE;
            awid_q     <= awid;
            awlen_q    <= awlen;
            awsize_q   <= awsize;
            awaddr_q   <= awaddr;
            awburst_q  <= awburst;
            bresp_q    <= classify_burst(awaddr, awlen, awsize, awburst);
            if (classify_burst(awaddr, awlen, awsize, awburst) == RESP_OKAY)
              w_state_q <= W_ACCEPT;
            else
              w_state_q <= W_DISCARD;
          end else if (arvalid && arready) begin
            active_q   <= ACTIVE_READ;
            ar_state_q <= AR_ACCEPTED;
            r_state_q  <= R_VALID;
            rcount_q   <= 8'd0;
            arid_q     <= arid;
            arlen_q    <= arlen;
            arsize_q   <= arsize;
            araddr_q   <= araddr;
            arburst_q  <= arburst;
            rresp_q    <= classify_burst(araddr, arlen, arsize, arburst);
            rlast_q    <= (arlen == 0);
            if (classify_burst(araddr, arlen, arsize, arburst) == RESP_OKAY)
              rdata_q <= read_word(burst_address(araddr, arlen, arsize, arburst, 0), arsize);
            else
              rdata_q <= 32'b0;
          end
        end

        ACTIVE_WRITE: begin
          if (wvalid && wready) begin
            if (w_state_q == W_ACCEPT) begin
              for (lane = 0; lane < 4; lane = lane + 1) begin
                if ((lane < bytes_for_size(awsize_q)) && wstrb[lane])
                  mem[burst_address(awaddr_q, awlen_q, awsize_q, awburst_q, wcount_q) + lane]
                    <= wdata[8*lane +: 8];
              end
            end

            if (wcount_q == awlen_q) begin
              if (!wlast)
                bresp_q <= RESP_SLVERR;
              b_state_q <= B_VALID;
              w_state_q <= W_IDLE;
            end else if (wlast) begin
              bresp_q <= RESP_SLVERR;
              b_state_q <= B_VALID;
              w_state_q <= W_IDLE;
            end else begin
              wcount_q <= wcount_q + 1'b1;
            end
          end

          if (bvalid && bready) begin
            active_q   <= ACTIVE_IDLE;
            aw_state_q <= AW_IDLE;
            b_state_q  <= B_IDLE;
          end
        end

        ACTIVE_READ: begin
          if (rvalid && rready) begin
            if (rcount_q == arlen_q) begin
              active_q   <= ACTIVE_IDLE;
              ar_state_q <= AR_IDLE;
              r_state_q  <= R_IDLE;
              rlast_q    <= 1'b0;
            end else begin
              rcount_q <= rcount_q + 1'b1;
              rlast_q  <= (rcount_q + 1'b1 == arlen_q);
              if (rresp_q == RESP_OKAY)
                rdata_q <= read_word(
                  burst_address(araddr_q, arlen_q, arsize_q, arburst_q, rcount_q + 1),
                  arsize_q
                );
              else
                rdata_q <= 32'b0;
            end
          end
        end

        default: active_q <= ACTIVE_IDLE;
      endcase
    end
  end

endmodule

interface axi_if;
  logic clk;
  logic resetn;

  logic awvalid;
  logic awready;
  logic [3:0] awid;
  logic [7:0] awlen;
  logic [2:0] awsize;
  logic [31:0] awaddr;
  logic [1:0] awburst;

  logic wvalid;
  logic wready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic wlast;

  logic bready;
  logic bvalid;
  logic [3:0] bid;
  logic [1:0] bresp;

  logic arvalid;
  logic arready;
  logic [3:0] arid;
  logic [7:0] arlen;
  logic [2:0] arsize;
  logic [31:0] araddr;
  logic [1:0] arburst;

  logic rready;
  logic rvalid;
  logic [3:0] rid;
  logic [31:0] rdata;
  logic [1:0] rresp;
  logic rlast;
endinterface
