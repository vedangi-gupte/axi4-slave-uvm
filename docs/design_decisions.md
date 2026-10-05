# AXI4 Subset Implementation Decisions

This document records the architecture and verification decisions for the implemented AXI4 slave subset. It describes the current design behavior and intentionally does not claim full AXI4 compliance.

## 1. RTL Architecture

### 1.1 AXI4 interface subset

- 32-bit address bus.
- 32-bit data bus.
- 4-bit transaction IDs.
- 8-bit `AWLEN` and `ARLEN` fields.
- Burst length is interpreted as `LEN + 1` transfers.
- No `WID` signal.
- No `RSTRB` signal.

### 1.2 Memory model

- The slave implements 128 byte-addressable memory locations, `mem[0:127]`.
- Memory is initialized to zero during reset.
- Memory updates occur only on accepted W-channel transfers.
- Read data is assembled from individual memory bytes.

### 1.3 Transaction concurrency

- One transaction is active at a time.
- Read and write transactions do not overlap.
- Transactions are not reordered or interleaved.
- AW has priority over AR if both address channels request a transfer in the same cycle.

### 1.4 Channel control

- Address information is captured only on `VALID && READY`.
- Write data is accepted only on `WVALID && WREADY`.
- `BVALID` remains asserted until `BREADY` is accepted.
- `RVALID`, `RDATA`, `RID`, `RRESP`, and `RLAST` remain stable until `RREADY` is accepted.
- The channel control is represented by W, B, and R phase state machines coordinated by a central transaction arbiter.
- AW and AR acceptance are controlled directly by the central arbiter.
- The state machines do not provide independent parallel read/write operation.

## 2. Burst and Address Decisions

### 2.1 Supported burst types

- FIXED bursts keep the same beat address.
- INCR bursts advance by the number of bytes transferred per beat.
- WRAP bursts are supported for 2, 4, 8, and 16 beats.
- The same address rules are used for read and write prediction.

### 2.2 Transfer sizes and alignment

- `AxSIZE=0` represents a 1-byte transfer.
- `AxSIZE=1` represents a 2-byte transfer.
- `AxSIZE=2` represents a 4-byte transfer.
- Addresses must be aligned to the selected transfer size.
- Unsupported sizes and misaligned addresses return `SLVERR`.

### 2.3 Memory boundaries

- The complete burst address range is checked before a valid write modifies memory.
- A burst touching any address outside byte range 0–127 returns `DECERR`.
- An invalid write burst is discarded atomically; no memory bytes are modified.
- Invalid read bursts return zero data with the corresponding error response for every response beat.

## 3. Byte-Lane Decisions

- Each `WSTRB` bit enables its corresponding data-bus byte lane.
- The active bus lanes are determined by the transfer address modulo the 4-byte data width.
- For a 1-byte transfer, one lane is active; for a 2-byte transfer, two adjacent lanes are active; for a 4-byte transfer, all four lanes are active.
- Four-byte transfers support all 16 `WSTRB` combinations.
- One- and two-byte transactions constrain strobes to their address-selected active lanes.
- Disabled byte lanes retain their previous memory contents.
- Sparse strobes do not pack bytes together; each enabled lane maps to its corresponding byte address.

## 4. Verification Architecture

### 4.1 UVM components

The verification environment contains:

- UVM test
- UVM environment
- UVM agent
- Sequencer
- Transaction-based driver
- Interface monitor
- Self-checking byte-array scoreboard

The monitor observes interface handshakes only and does not use DUT internal address counters or state variables.

### 4.2 Directed tests

Directed transactions cover:

- FIXED, INCR, and WRAP bursts.
- 1-, 2-, and 4-byte transfer sizes.
- All 16 full-width `WSTRB` patterns.
- Unsupported transfer sizes.
- Misaligned addresses.
- Out-of-range addresses.
- Bursts crossing the memory boundary.
- Illegal WRAP lengths.
- Response IDs and `RLAST` placement.

### 4.3 Constrained-random testing

- The constrained-random sequence generates 100 transactions.
- Randomized fields include transaction ID, burst type, burst length, transfer size, aligned address, write data, and write strobes.
- WRAP lengths are constrained to 2, 4, 8, or 16 beats.
- Legal randomized transactions are constrained to fit within the 128-byte memory.

### 4.4 Scoreboard behavior

- The scoreboard maintains an independent 128-byte reference memory.
- Valid write observations update the reference model according to burst addresses and `WSTRB`.
- Read observations are compared byte by byte against the reference model.
- The scoreboard checks response IDs, response codes, beat counts, read data, and `RLAST`.
- Invalid writes must leave the reference memory unchanged.

### 4.5 Backpressure and timeout behavior

- Driver channel tasks wait for handshakes using bounded timeouts.
- The driver applies randomized response-channel backpressure by holding `BREADY` and `RREADY` low for 0–3 clock cycles before each response handshake.
- The driver also inserts randomized 0–3 cycle gaps between W-channel beats by holding `WVALID` low.
- The RTL holds valid response and data signals while the receiving side is not ready.
- The scoreboard observes the responses after the randomized delays and checks their IDs, data, response codes, and `RLAST` behavior.
- A timeout is reported as a fatal verification failure instead of allowing an infinite simulation.

## 5. Intentional Scope Limits

This implementation does not claim to provide:

- Multiple outstanding transactions.
- Transaction reordering.
- Read/write interleaving.
- AXI QoS, cache, lock, region, or user sideband behavior.
- Full AXI4 compliance.
- Functional coverage or assertion-based protocol checking in the current testbench.

## 6. Validation Goals

The implementation is considered successful when:

- Xcelium compiles the RTL and UVM testbench without interface mismatches.
- Directed transactions complete without timeout.
- Constrained-random transactions complete without timeout.
- The scoreboard reports zero mismatches.
- Invalid writes leave memory unchanged.
- Response IDs, response codes, and `RLAST` behavior are correct.
