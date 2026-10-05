`timescale 1ns/1ps
`include "uvm_macros.svh"
import uvm_pkg::*;

localparam logic [1:0] TB_OKAY   = 2'b00;
localparam logic [1:0] TB_SLVERR = 2'b10;
localparam logic [1:0] TB_DECERR = 2'b11;

typedef enum bit [1:0] {TX_RESET, TX_RW} tx_kind_t;

function automatic integer tb_bytes_for_size(input bit [2:0] size);
  case (size)
    3'd0: tb_bytes_for_size = 1;
    3'd1: tb_bytes_for_size = 2;
    3'd2: tb_bytes_for_size = 4;
    default: tb_bytes_for_size = 0;
  endcase
endfunction

function automatic bit [31:0] tb_burst_address(
  input bit [31:0] start_addr,
  input bit [7:0]  len,
  input bit [2:0]  size,
  input bit [1:0]  burst,
  input integer    beat_index
);
  integer bytes;
  integer total_bytes;
  integer wrap_base;
  bit [31:0] candidate;
  begin
    bytes = tb_bytes_for_size(size);
    candidate = start_addr;
    if (bytes != 0) begin
      case (burst)
        2'b00: candidate = start_addr;
        2'b01: candidate = start_addr + beat_index * bytes;
        2'b10: begin
          total_bytes = (len + 1) * bytes;
          wrap_base = (start_addr / total_bytes) * total_bytes;
          candidate = start_addr + beat_index * bytes;
          if (candidate >= wrap_base + total_bytes)
            candidate = candidate - total_bytes;
        end
        default: candidate = start_addr;
      endcase
    end
    tb_burst_address = candidate;
  end
endfunction

function automatic bit [1:0] tb_burst_response(
  input bit [31:0] start_addr,
  input bit [7:0]  len,
  input bit [2:0]  size,
  input bit [1:0]  burst
);
  integer bytes;
  integer beats;
  integer i;
  integer last_byte;
  bit [31:0] current_addr;
  bit [1:0] response;
  begin
    bytes = tb_bytes_for_size(size);
    beats = len + 1;
    response = TB_OKAY;

    if ((bytes == 0) || (burst > 2'b10)) begin
      response = TB_SLVERR;
    end else if ((start_addr % bytes) != 0) begin
      response = TB_SLVERR;
    end else if ((burst == 2'b10) &&
                 !((beats == 2) || (beats == 4) || (beats == 8) || (beats == 16))) begin
      response = TB_SLVERR;
    end else begin
      for (i = 0; i < beats; i = i + 1) begin
        current_addr = tb_burst_address(start_addr, len, size, burst, i);
        last_byte = current_addr + bytes - 1;
        if (last_byte >= 128)
          response = TB_DECERR;
      end
    end
    tb_burst_response = response;
  end
endfunction

class axi_transaction extends uvm_sequence_item;
  `uvm_object_utils(axi_transaction)

  tx_kind_t kind;
  rand bit [3:0]  id;
  rand bit [7:0]  len;
  rand bit [2:0]  size;
  rand bit [31:0] addr;
  rand bit [1:0]  burst;
  rand bit [31:0] wdata [0:255];
  rand bit [3:0]  wstrb [0:255];

  function new(string name = "axi_transaction");
    super.new(name);
  endfunction

  constraint legal_controls {
    size inside {3'd0, 3'd1, 3'd2};
    burst inside {2'b00, 2'b01, 2'b10};
    len inside {[0:15]};
    if (burst == 2'b10) len inside {8'd1, 8'd3, 8'd7, 8'd15};
    addr < 64;
    if (size == 3'd1) addr[0] == 1'b0;
    if (size == 3'd2) addr[1:0] == 2'b00;
  }

  function void post_randomize();
    foreach (wstrb[i]) begin
      if (size == 3'd0)
        wstrb[i] &= 4'b0001;
      else if (size == 3'd1)
        wstrb[i] &= 4'b0011;
    end
  endfunction
endclass

class reset_sequence extends uvm_sequence #(axi_transaction);
  `uvm_object_utils(reset_sequence)

  function new(string name = "reset_sequence");
    super.new(name);
  endfunction

  task body();
    axi_transaction tr = axi_transaction::type_id::create("reset_item");
    start_item(tr);
    tr.kind = TX_RESET;
    finish_item(tr);
  endtask
endclass

class directed_sequence extends uvm_sequence #(axi_transaction);
  `uvm_object_utils(directed_sequence)

  function new(string name = "directed_sequence");
    super.new(name);
  endfunction

  task automatic issue_case(
    input bit [7:0]  case_len,
    input bit [2:0]  case_size,
    input bit [31:0] case_addr,
    input bit [1:0]  case_burst,
    input bit [3:0]  case_strobe
  );
    axi_transaction tr = axi_transaction::type_id::create("directed_item");
    start_item(tr);
    assert(tr.randomize());
    tr.kind  = TX_RW;
    tr.len   = case_len;
    tr.size  = case_size;
    tr.addr  = case_addr;
    tr.burst = case_burst;
    for (int i = 0; i < 256; i++)
      tr.wstrb[i] = case_strobe;
    finish_item(tr);
  endtask

  task body();
    // Basic valid burst modes and transfer sizes.
    issue_case(8'd0, 3'd2, 32'd0,  2'b00, 4'b1111);
    issue_case(8'd3, 3'd2, 32'd16, 2'b01, 4'b1111);
    issue_case(8'd3, 3'd2, 32'd12, 2'b10, 4'b1111);
    issue_case(8'd0, 3'd0, 32'd32, 2'b01, 4'b0001);
    issue_case(8'd0, 3'd1, 32'd34, 2'b01, 4'b0011);

    // Exercise every WSTRB combination for a full-width transfer.
    for (int pattern = 0; pattern < 16; pattern++)
      issue_case(8'd0, 3'd2, 32'd40, 2'b00, pattern[3:0]);

    // Invalid size/alignment, out-of-range, crossing, and illegal WRAP cases.
    issue_case(8'd0, 3'd3, 32'd0,   2'b01, 4'b1111);
    issue_case(8'd0, 3'd1, 32'd33,  2'b01, 4'b0011);
    issue_case(8'd0, 3'd2, 32'd128, 2'b01, 4'b1111);
    issue_case(8'd3, 3'd2, 32'd120, 2'b01, 4'b1111);
    issue_case(8'd2, 3'd2, 32'd0,   2'b10, 4'b1111);
  endtask
endclass

class constrained_random_sequence extends uvm_sequence #(axi_transaction);
  `uvm_object_utils(constrained_random_sequence)

  function new(string name = "constrained_random_sequence");
    super.new(name);
  endfunction

  task body();
    repeat (100) begin
      axi_transaction tr = axi_transaction::type_id::create("random_item");
      start_item(tr);
      assert(tr.randomize());
      tr.kind = TX_RW;
      finish_item(tr);
    end
  endtask
endclass

class axi_driver extends uvm_driver #(axi_transaction);
  `uvm_component_utils(axi_driver)

  virtual axi_if vif;

  function new(string name = "axi_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "AXI virtual interface was not configured")
  endfunction

  task reset_signals();
    vif.resetn  <= 1'b0;
    vif.awvalid <= 1'b0;
    vif.wvalid  <= 1'b0;
    vif.wlast   <= 1'b0;
    vif.bready  <= 1'b0;
    vif.arvalid <= 1'b0;
    vif.rready  <= 1'b0;
    repeat (3) @(posedge vif.clk);
    vif.resetn <= 1'b1;
  endtask

  task drive_write(axi_transaction tr);
    int timeout;
    vif.awid    <= tr.id;
    vif.awlen   <= tr.len;
    vif.awsize  <= tr.size;
    vif.awaddr  <= tr.addr;
    vif.awburst <= tr.burst;
    vif.awvalid <= 1'b1;

    timeout = 0;
    do begin
      @(posedge vif.clk);
      timeout++;
    end while ((vif.awready !== 1'b1) && (timeout < 1000));
    if (timeout >= 1000)
      `uvm_fatal("TIMEOUT", "AWREADY timeout")
    vif.awvalid <= 1'b0;

    for (int beat = 0; beat <= tr.len; beat++) begin
      vif.wdata  <= tr.wdata[beat];
      vif.wstrb  <= tr.wstrb[beat];
      vif.wlast  <= (beat == tr.len);
      vif.wvalid <= 1'b1;
      timeout = 0;
      do begin
        @(posedge vif.clk);
        timeout++;
      end while ((vif.wready !== 1'b1) && (timeout < 1000));
      if (timeout >= 1000)
        `uvm_fatal("TIMEOUT", "WREADY timeout")
      vif.wvalid <= 1'b0;
      vif.wlast  <= 1'b0;
    end

    vif.bready <= 1'b0;
    repeat ($urandom_range(0, 3)) @(posedge vif.clk);
    vif.bready <= 1'b1;
    timeout = 0;
    do begin
      @(posedge vif.clk);
      timeout++;
    end while ((vif.bvalid !== 1'b1) && (timeout < 1000));
    if (timeout >= 1000)
      `uvm_fatal("TIMEOUT", "BVALID timeout")
    vif.bready <= 1'b0;
    // Leave one idle cycle so the monitor/scoreboard commits the write first.
    @(posedge vif.clk);
  endtask

  task drive_read(axi_transaction tr);
    int timeout;
    vif.arid    <= tr.id;
    vif.arlen   <= tr.len;
    vif.arsize  <= tr.size;
    vif.araddr  <= tr.addr;
    vif.arburst <= tr.burst;
    vif.arvalid <= 1'b1;

    timeout = 0;
    do begin
      @(posedge vif.clk);
      timeout++;
    end while ((vif.arready !== 1'b1) && (timeout < 1000));
    if (timeout >= 1000)
      `uvm_fatal("TIMEOUT", "ARREADY timeout")
    vif.arvalid <= 1'b0;

    vif.rready <= 1'b0;
    for (int beat = 0; beat <= tr.len; beat++) begin
      repeat ($urandom_range(0, 3)) @(posedge vif.clk);
      vif.rready <= 1'b1;
      timeout = 0;
      do begin
        @(posedge vif.clk);
        timeout++;
      end while ((vif.rvalid !== 1'b1) && (timeout < 1000));
      if (timeout >= 1000)
        `uvm_fatal("TIMEOUT", "RVALID timeout")
      vif.rready <= 1'b0;
    end
    vif.rready <= 1'b0;
  endtask

  task run_phase(uvm_phase phase);
    axi_transaction tr;
    forever begin
      seq_item_port.get_next_item(tr);
      if (tr.kind == TX_RESET) begin
        reset_signals();
      end else begin
        drive_write(tr);
        drive_read(tr);
      end
      seq_item_port.item_done();
    end
  endtask
endclass

class axi_write_observed extends uvm_object;
  `uvm_object_utils(axi_write_observed)
  bit [3:0]  id;
  bit [7:0]  len;
  bit [2:0]  size;
  bit [31:0] addr;
  bit [1:0]  burst;
  int        beat_count;
  bit [31:0] data [0:255];
  bit [3:0]  strb [0:255];
  bit [3:0]  response_id;
  bit [1:0]  response;

  function new(string name = "axi_write_observed");
    super.new(name);
  endfunction
endclass

class axi_read_observed extends uvm_object;
  `uvm_object_utils(axi_read_observed)
  bit [3:0]  id;
  bit [7:0]  len;
  bit [2:0]  size;
  bit [31:0] addr;
  bit [1:0]  burst;
  int        beat_count;
  bit [3:0]  response_id [0:255];
  bit [1:0]  response [0:255];
  bit [31:0] data [0:255];
  bit        last [0:255];

  function new(string name = "axi_read_observed");
    super.new(name);
  endfunction
endclass

`uvm_analysis_imp_decl(_write_observed)
`uvm_analysis_imp_decl(_read_observed)

class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual axi_if vif;
  uvm_analysis_port #(axi_write_observed) write_ap;
  uvm_analysis_port #(axi_read_observed) read_ap;

  function new(string name = "axi_monitor", uvm_component parent = null);
    super.new(name, parent);
    write_ap = new("write_ap", this);
    read_ap  = new("read_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_if)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "AXI virtual interface was not configured")
  endfunction

  task collect_write();
    axi_write_observed obs = axi_write_observed::type_id::create("write_observation");
    obs.id = vif.awid;
    obs.len = vif.awlen;
    obs.size = vif.awsize;
    obs.addr = vif.awaddr;
    obs.burst = vif.awburst;
    obs.beat_count = 0;

    while (obs.beat_count <= obs.len) begin
      @(posedge vif.clk);
      if (vif.wvalid && vif.wready) begin
        obs.data[obs.beat_count] = vif.wdata;
        obs.strb[obs.beat_count] = vif.wstrb;
        obs.beat_count++;
      end
    end

    while (!(vif.bvalid && vif.bready))
      @(posedge vif.clk);
    obs.response_id = vif.bid;
    obs.response = vif.bresp;
    write_ap.write(obs);
  endtask

  task collect_read();
    axi_read_observed obs = axi_read_observed::type_id::create("read_observation");
    obs.id = vif.arid;
    obs.len = vif.arlen;
    obs.size = vif.arsize;
    obs.addr = vif.araddr;
    obs.burst = vif.arburst;
    obs.beat_count = 0;

    while (obs.beat_count <= obs.len) begin
      @(posedge vif.clk);
      if (vif.rvalid && vif.rready) begin
        obs.data[obs.beat_count] = vif.rdata;
        obs.response_id[obs.beat_count] = vif.rid;
        obs.response[obs.beat_count] = vif.rresp;
        obs.last[obs.beat_count] = vif.rlast;
        obs.beat_count++;
      end
    end
    read_ap.write(obs);
  endtask

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (!vif.resetn)
        continue;
      if (vif.awvalid && vif.awready)
        collect_write();
      else if (vif.arvalid && vif.arready)
        collect_read();
    end
  endtask
endclass

class axi_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axi_scoreboard)

  uvm_analysis_imp_write_observed #(axi_write_observed, axi_scoreboard) write_imp;
  uvm_analysis_imp_read_observed  #(axi_read_observed, axi_scoreboard) read_imp;
  bit [7:0] expected_mem [0:127];
  int errors;

  function new(string name = "axi_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    write_imp = new("write_imp", this);
    read_imp  = new("read_imp", this);
    errors = 0;
    foreach (expected_mem[i]) expected_mem[i] = 8'h00;
  endfunction

  function void write_write_observed(axi_write_observed obs);
    bit [1:0] expected_response;
    int bytes;
    bit [31:0] address;

    expected_response = tb_burst_response(obs.addr, obs.len, obs.size, obs.burst);
    if (obs.response_id != obs.id) begin
      `uvm_error("SCOREBOARD", "Write response ID mismatch")
      errors++;
    end
    if (obs.response != expected_response) begin
      `uvm_error("SCOREBOARD", $sformatf("BRESP mismatch: expected %0d got %0d", expected_response, obs.response))
      errors++;
    end
    if (obs.beat_count != obs.len + 1) begin
      `uvm_error("SCOREBOARD", "Write beat count mismatch")
      errors++;
    end

    if (expected_response == TB_OKAY) begin
      bytes = tb_bytes_for_size(obs.size);
      for (int beat = 0; beat <= obs.len; beat++) begin
        address = tb_burst_address(obs.addr, obs.len, obs.size, obs.burst, beat);
        for (int lane = 0; lane < bytes; lane++) begin
          if (obs.strb[beat][lane])
            expected_mem[address + lane] = obs.data[beat][8*lane +: 8];
        end
      end
    end
  endfunction

  function void write_read_observed(axi_read_observed obs);
    bit [1:0] expected_response;
    bit [31:0] expected_data;
    int bytes;
    bit [31:0] address;

    expected_response = tb_burst_response(obs.addr, obs.len, obs.size, obs.burst);
    bytes = tb_bytes_for_size(obs.size);
    if (obs.beat_count != obs.len + 1) begin
      `uvm_error("SCOREBOARD", "Read beat count mismatch")
      errors++;
    end

    for (int beat = 0; beat <= obs.len; beat++) begin
      if (obs.response_id[beat] != obs.id) begin
        `uvm_error("SCOREBOARD", "Read response ID mismatch")
        errors++;
      end
      if (obs.response[beat] != expected_response) begin
        `uvm_error("SCOREBOARD", $sformatf("RRESP mismatch: expected %0d got %0d", expected_response, obs.response[beat]))
        errors++;
      end
      if (obs.last[beat] != (beat == obs.len)) begin
        `uvm_error("SCOREBOARD", "RLAST position mismatch")
        errors++;
      end

      expected_data = 32'b0;
      if (expected_response == TB_OKAY) begin
        address = tb_burst_address(obs.addr, obs.len, obs.size, obs.burst, beat);
        for (int lane = 0; lane < bytes; lane++)
          expected_data[8*lane +: 8] = expected_mem[address + lane];
      end
      if (obs.data[beat] != expected_data) begin
        `uvm_error("SCOREBOARD", $sformatf("RDATA mismatch on beat %0d", beat))
        errors++;
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    if (errors == 0)
      `uvm_info("SCOREBOARD", "All AXI4 checks passed", UVM_LOW)
    else
      `uvm_error("SCOREBOARD", $sformatf("Total scoreboard errors: %0d", errors))
  endfunction
endclass

class axi_agent extends uvm_agent;
  `uvm_component_utils(axi_agent)
  axi_driver driver;
  axi_monitor monitor;
  uvm_sequencer #(axi_transaction) sequencer;

  function new(string name = "axi_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    driver = axi_driver::type_id::create("driver", this);
    monitor = axi_monitor::type_id::create("monitor", this);
    sequencer = uvm_sequencer #(axi_transaction)::type_id::create("sequencer", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass

class axi_env extends uvm_env;
  `uvm_component_utils(axi_env)
  axi_agent agent;
  axi_scoreboard scoreboard;

  function new(string name = "axi_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = axi_agent::type_id::create("agent", this);
    scoreboard = axi_scoreboard::type_id::create("scoreboard", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.monitor.write_ap.connect(scoreboard.write_imp);
    agent.monitor.read_ap.connect(scoreboard.read_imp);
  endfunction
endclass

class axi_test extends uvm_test;
  `uvm_component_utils(axi_test)
  axi_env env;
  reset_sequence reset_seq;
  directed_sequence directed_seq;
  constrained_random_sequence random_seq;

  function new(string name = "axi_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = axi_env::type_id::create("env", this);
    reset_seq = reset_sequence::type_id::create("reset_seq");
    directed_seq = directed_sequence::type_id::create("directed_seq");
    random_seq = constrained_random_sequence::type_id::create("random_seq");
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    reset_seq.start(env.agent.sequencer);
    directed_seq.start(env.agent.sequencer);
    random_seq.start(env.agent.sequencer);
    #20;
    phase.drop_objection(this);
  endtask
endclass

module tb;
  axi_if vif();

  axi_slave dut (
    .clk      (vif.clk),
    .resetn   (vif.resetn),
    .awvalid  (vif.awvalid),
    .awready  (vif.awready),
    .awid     (vif.awid),
    .awlen    (vif.awlen),
    .awsize   (vif.awsize),
    .awaddr   (vif.awaddr),
    .awburst  (vif.awburst),
    .wvalid   (vif.wvalid),
    .wready   (vif.wready),
    .wdata    (vif.wdata),
    .wstrb    (vif.wstrb),
    .wlast    (vif.wlast),
    .bready   (vif.bready),
    .bvalid   (vif.bvalid),
    .bid      (vif.bid),
    .bresp    (vif.bresp),
    .arvalid  (vif.arvalid),
    .arready  (vif.arready),
    .arid     (vif.arid),
    .arlen    (vif.arlen),
    .arsize   (vif.arsize),
    .araddr   (vif.araddr),
    .arburst  (vif.arburst),
    .rready   (vif.rready),
    .rvalid   (vif.rvalid),
    .rid      (vif.rid),
    .rdata    (vif.rdata),
    .rresp    (vif.rresp),
    .rlast    (vif.rlast)
  );

  initial vif.clk = 1'b0;
  always #5 vif.clk = ~vif.clk;

  initial begin
    vif.resetn  = 1'b0;
    vif.awvalid = 1'b0;
    vif.wvalid  = 1'b0;
    vif.wlast   = 1'b0;
    vif.bready  = 1'b0;
    vif.arvalid = 1'b0;
    vif.rready  = 1'b0;
    uvm_config_db #(virtual axi_if)::set(null, "*", "vif", vif);
    run_test("axi_test");
  end

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, tb);
  end
endmodule
