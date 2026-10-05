# AXI4 Slave with UVM Verification

A SystemVerilog AXI4 slave with a 128-byte memory, verified with a layered UVM environment and a self-checking scoreboard.

![WRAP burst](results/1.%20wrap_burst.png)
*WRAP burst at 0x0C (4 beats × 4 bytes): the address wraps 0x0C → 0x00 → 0x04 → 0x08, and the read data comes back in write order.*

---

## Design (`rtl/`)

**Interface:** a subset of AXI4: 32-bit address and data, 4-bit IDs, 8-bit `AxLEN`, no `WID`.

**Features**
- FIXED, INCR, and WRAP bursts (WRAP lengths of 2, 4, 8, and 16 beats)
- 1-, 2-, and 4-byte transfer sizes
- Byte-lane writes using `WSTRB`; disabled lanes keep their previous contents
- Error responses:
  - **SLVERR** for an unsupported size, a misaligned address, an illegal WRAP length, or a `WLAST` mismatch
  - **DECERR** for any burst that touches an address outside 0–127
- Invalid write bursts are discarded as a whole, so no memory bytes change
- `BVALID`, `RVALID`, `RDATA`, and `RLAST` hold steady until the matching `READY`

**Architecture:** AW, W, B, AR, and R channel state machines, coordinated by a central read/write arbiter. One transaction is active at a time, and AW wins over AR when both arrive in the same cycle.

## Verification (`tb/`)

A UVM environment with these parts: test → env → agent (sequencer, driver, monitor) → scoreboard.

- **Driver:** takes every field from the randomized transaction, and uses bounded timeouts on each handshake.
- **Monitor:** watches only the interface handshakes, never the DUT's internal state.
- **Scoreboard:** keeps its own 128-byte reference memory and checks read data byte by byte, along with response codes, response IDs, beat counts, and where `RLAST` falls.

**Tests**
- **26 directed transactions:**
  - every burst type at every transfer size
  - all 16 `WSTRB` patterns
  - an unsupported size and a misaligned address
  - an out-of-range address and a burst crossing the memory boundary
  - an illegal WRAP length
- **100 constrained-random transactions:** random ID, burst type, length, size, aligned address, data, and strobes.

## Results

The simulation passes with **0 UVM errors and 0 fatals**; the full log is in [`results/sim.log`](results/sim.log).

| Partial strobe | Error responses |
|---|---|
| ![WSTRB](results/2.%20wstrb_partial.png) | ![SLVERR](results/4.%20slverr.png) |
| `WSTRB = 0101` updates only byte lanes 0 and 2; readback `0x00C5_5413` shows lanes 1 and 3 kept their old values. | SLVERR for an unsupported size (`AxSIZE=3`) and a misaligned address (`0x21`). |

![DECERR](results/3.%20decerr_boundary.png)
*DECERR for an out-of-range address (`0x80`) and a 4-beat burst crossing the 128-byte boundary (`0x78`). Read data is zero, and RVALID and RLAST stay steady while RREADY is low.*

## How to run

**On EDA Playground** (Cadence Xcelium, UVM 1.2):
1. Paste `rtl/axi_slave.sv` (the slave module and the `axi_if` interface) into the design pane.
2. Paste `tb/axi_tb.sv` into the testbench pane.
3. Tick **UVM 1.2** and click **Run**.

**Locally:**
```
xrun -sv -uvm rtl/axi_slave.sv tb/axi_tb.sv
```

## Scope

What this design leaves out, on purpose:
- Multiple outstanding transactions
- Running reads and writes concurrently or interleaved
- Reordering
- The QoS, cache, lock, region, and user signals
- Functional coverage and assertion-based protocol checks

It is not a full AXI4-compliant implementation. More detail is in [`docs/design_decisions.md`](docs/design_decisions.md).
