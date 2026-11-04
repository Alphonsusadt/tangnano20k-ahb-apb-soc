# Ibex integration

- `ibex_ahb_cpu.sv` configures `ibex_top` and connects its two OBI ports to `obi_to_ahb_adapter`.
- `prim_clock_gating.sv` passes the clock straight through, because a latch-based gate adds skew on the FPGA fabric.

The Ibex source is in [`third_party/ibex`](../../third_party/ibex/VENDORED.md).
