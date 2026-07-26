# Pipeline Plan (proposal, not yet implemented)

This is the concrete plan for turning `src/riscv_core/riscv_core.sv` from
single-cycle into a 5-stage pipeline. See `03_microarchitecture.md` for the
general reasoning (why 5 stages, why flush costs 2 cycles, SV coding
patterns to reuse); this doc is the specific commitment of what gets built,
in what order, and how it'll be verified. Nothing in `riscv_core.sv` has
been changed yet — this is the design to review before writing RTL.

## 0. Why now, not incidentally

The trigger is real, not aesthetic: the single-cycle core assumes
zero-latency combinational memory reads, and Quartus's `altsyncram` (M9K
block RAM) cannot provide that regardless of IP wizard settings — block RAM
always captures its address on a clock edge before the array read happens.
This is why hardware runs showed PC/address/data incrementing but jumps
never redirecting: MAX10 was never going to work with a single-cycle
core's timing assumption. `fpga/dp_ram_model.v`'s `REGISTERED_ADDR=0`
sim-only mode hid this completely — it's the reason this bug was invisible
in every cocotb run to date. Pipelining is the fix that actually matches
real BRAM instead of continuing to fight it.

## 1. Target stage layout

```
   IF          ID              EX                  MEM              WB
┌─────────┐ ┌───────────┐  ┌──────────────┐    ┌──────────────┐  ┌───────────┐
│ pc      │ │ decode    │  │ ALU / branch │    │ dmem access  │  │ regfile   │
│ imem rd │→│ regfile rd│→ │ compute      │→   │ (dp_ram      │→ │ writeback │
│ (port A)│ │ (comb)    │  │ br_tgt/jalr  │    │  port B)     │  │           │
└─────────┘ └───────────┘  └──────────────┘    └──────────────┘  └───────────┘
```

Full derivation and per-stage signal mapping is in
`03_microarchitecture.md` §2 and §5 — not repeated here. Short version:
IF/MEM split is forced by BRAM port assignment (imem=port A, dmem=port B,
already true today); ID/EX/WB splits are forced by data dependency and
critical-path balance (decode+regfile-read is cheap, ALU/branch-compare is
the deep combinational block and gets isolated into its own stage).

## 2. Pipeline registers to add

Four new register stages, each with an explicit `valid` bit (see §5,
reset). Field lists below are the *minimum* needed; anything already
computed combinationally downstream (e.g. `imm`, individual `is_*`
booleans) can be recomputed in the later stage from carried-forward raw
fields instead of being carried forward itself, as long as the source data
(`instr`) is still available — carrying `instr` itself through to ID is
simplest and keeps decode logic centralized in one place rather than
duplicated across stages.

| Register | Fields carried | Consumed by |
|----------|----------------|-------------|
| `if_id`  | `instr`, `pc`, `valid` | ID (decode + regfile read) |
| `id_ex`  | `rd`, control signals (`is_addi`, `is_load`, ..., or a packed encoding), `imm`, `src1_value`, `src2_value`, `pc`, `valid` | EX |
| `ex_mem` | `result` (ALU result / computed address), `src2_value` (store data), `rd`, `is_load`, `dmem_we`, `valid` | MEM |
| `mem_wb` | `wr_data` (`ld_data` or forwarded `result`), `rd`, `wr_en`, `valid` | WB (regfile write port) |

Naming convention: `<stage>_<stage>` for the register itself (e.g.
`if_id`), matching how `riscv_core.sv` already names cross-module wires
(`dbg_reg_addr`, `dbg_mem_valid`) — descriptive, boundary-first names, no
abbreviation beyond the stage tags themselves.

## 3. Hazards this pipeline must handle, and how

**Structural hazards: none new.** The dual-port BRAM already gives IF and
MEM independent physical ports; no resource is shared between any two
stages that need it in the same cycle.

**Control hazards (branches/jumps): handled by flush, not prediction.**
Predict-not-taken (`next_pc = pc + 4` by default). When EX resolves
`taken_br`/`is_jal`/`is_jalr` as true:
- `next_pc` is overridden that same cycle to `br_tgt_pc` or `jalr_tgt_pc`.
- `if_id` and `id_ex` (the two stages holding instructions fetched from
  the wrong path) have their `valid` bit forced to 0 that same cycle —
  every downstream control signal derived from `valid` (mainly `wr_en`,
  `dmem_we`, `dmem_re`) is gated off, so the wrong-path instructions drain
  through EX/MEM/WB as harmless no-ops instead of committing anything.
- Cost: exactly 2 bubble cycles per taken branch/jump, always. No branch
  predictor in v1 — out of scope per `00_manifesto.md`'s "no
  high-performance optimization in v1."

**Data hazards (RAW dependencies between nearby instructions): NOT solved
in v1 by forwarding.** This is the one open design decision (see §6) —
the plan for v1 is to detect a RAW hazard (an instruction in ID reads a
register that an instruction currently in EX/MEM/WB is about to write) and
stall (insert a bubble in ID) until the dependency clears, rather than
building bypass/forwarding paths. Simpler to implement and verify first;
forwarding is the natural v2 optimization once the stall-only version is
proven correct on hardware.

**Load-use hazard: same stall mechanism as any other RAW hazard**, no
special case — a load's result isn't available until it's latched out of
MEM/WB, exactly like any ALU result, so the generic RAW-stall logic in §3
already covers it without extra logic.

## 4. Memory-timing contract with the real BRAM

Both `dp_ram.v` (`address_reg_a` should be regenerated to UNREGISTERED per
the earlier IP audit) and `dp_ram_model.v` (already defaults
`REGISTERED_ADDR=0`) need to agree with whatever latency the pipeline
actually assumes. Two sub-decisions, to be settled before RTL starts:

- If the regenerated `dp_ram.v` genuinely achieves the same-cycle
  address-in/data-out behavior `dp_ram_model.v` models at
  `REGISTERED_ADDR=0`, IF/MEM stay exactly as drawn above (address
  presented in IF/MEM's own cycle, data consumed that same cycle by the
  *next* stage's pipeline register).
- If MAX10 M9K genuinely cannot avoid a 1-cycle address-to-data latency
  (likely, per the hardware-issue discussion — block RAM read latency is
  usually not eliminable, only the *extra* wizard-added register is),
  IF and MEM each effectively need one more cycle of latency than drawn
  here, i.e. IF's `imem_rdata` isn't valid until the cycle *after*
  `imem_addr` changes. This turns the diagram in §1 into a 6-stage
  pipeline (IF1/IF2, or equivalently a 1-cycle IF stall built into IF
  itself) rather than 5. **This needs to be confirmed against Quartus
  timing/simulation before the register count is finalized** — flagged
  here explicitly so it isn't silently assumed away.

## 5. Reset behavior

- `pc` resets to 0, unchanged from the current single-cycle design.
- Every pipeline register's `valid` bit resets to 0. On the first 4 cycles
  after reset, stages downstream of IF have nothing real in them yet;
  gating `wr_en`/`dmem_we`/`dmem_re` on `valid` means those cycles are
  automatically safe no-ops rather than needing separate reset-specific
  logic. This reuses the exact same mechanism as a branch flush (§3) —
  one `valid`-gating mechanism, two different triggers (reset vs.
  misprediction), not two separate implementations.

## 6. Open questions / decisions still needed before RTL starts

1. **Real BRAM latency (§4)** — is it 5-stage or 6-stage? Needs a Quartus
   answer, not a simulation-only answer, since this is precisely the class
   of bug that's invisible in sim today.
2. **Stall-only v1 vs. forwarding from the start** — plan above assumes
   stall-only for v1; confirm that's still the right call once the stage
   count from (1) is settled, since a 6-stage pipeline stalls more often
   than a 5-stage one and the cost/benefit of forwarding shifts.
3. **Where exactly hazard detection lives** — a dedicated hazard-detect
   block reading `if_id`/`id_ex`'s `rd`/`rs1`/`rs2` fields (matching this
   codebase's existing style of separate named combinational blocks like
   `Decoder_Logic`), decided once (2) is settled.

## 7. Verification plan

Rather than build the whole pipeline and verify at the end, each milestone
below ships with its own passing test before the next milestone starts.
`riscv_core_single_cycle.sv` (a verified, frozen copy of the pre-pipeline
core — see dev log) is the golden reference model from the first
milestone on, not bolted on afterward: correctness is defined as
"pipeline produces the same architectural end-state as the single-cycle
core," checked differentially rather than against hand-derived expected
values.

**Differential comparison is convergence-based, not fixed-cycle-count.**
The pipeline takes a different (larger, variable) number of cycles than
the single-cycle core to run the same program, once stalls and 2-cycle
flush bubbles are added — so the harness cannot wait "N cycles" and then
compare. Every test program already ends in a self-loop (`loop: jal x0
loop`), so instead each core is run independently until its own `pc`
stops changing across consecutive cycles (i.e. it has parked on the
loop), with a timeout as a safety net against a genuine hang. Only once
*both* cores have independently converged does the harness diff
regfile[0:31] and the touched dmem words between them.

### Milestones

1. **Differential harness infra.** No pipeline changes. New test
   infrastructure (`test/utils.py` convergence helper + a differential
   testbench) that runs a program against two DUT instances and diffs
   regfile+dmem once both converge. Sanity-checked by running the
   single-cycle core against itself first (trivial pass) — proves the
   harness before there's a real pipeline to compare against.
2. **Pipeline registers, no hazard handling.** Add `if_id`/`id_ex`/
   `ex_mem`/`mem_wb` + valid bits per §2, wired straight through — no
   stall detection, no flush logic yet. Test: a hand-written
   straight-line program with no register dependencies and no branches,
   diffed against the single-cycle core. Goal is to prove the
   plumbing/latching timing alone, isolated from hazard logic.
3. **Flush on taken branch/jump.** Add the 2-cycle squash logic (§3).
   Test: the existing `test_full.asm` (already exercises JAL/JALR/
   branches) run through the differential harness — first time an
   existing program serves as a pipeline regression test rather than a
   new hand-written one.
4. **RAW-hazard stall detection.** Add the hazard-detect block (§3,
   stall-only v1). Test: a dedicated program with back-to-back dependent
   instructions (e.g. `add x1, ...` immediately followed by an
   instruction reading `x1`), diffed against single-cycle to confirm the
   stall reproduces identical architectural results, just slower.
5. **Load-use hazard verification.** No new RTL expected — §3 claims the
   generic RAW-stall mechanism already covers load-use with no special
   case. Test: a program with a load immediately followed by a use of the
   loaded register, to confirm that claim holds rather than assume it.
6. **Reset/valid-bit gating correctness.** Test asserting reset mid-run
   and checking no bogus register/memory writes commit in the first few
   post-reset cycles — same `valid`-gating mechanism as flush (§5),
   exercised via the reset trigger instead of the branch-resolution
   trigger.
7. **Full regression on existing suites.** `test_full` (27/27),
   `test_top`, `tb_uart` must all still pass against the now-complete
   pipeline — they check architectural end-state, not cycle-exact timing,
   so a correct pipeline should reproduce the same results even though
   the cycle count per instruction changes.
8. **Differential fuzz pass.** Randomized instruction sequences
   (constrained to stay within imem bounds) run through the differential
   harness in bulk — hand-written directed tests won't catch every
   hazard-interaction corner case (e.g. a stall immediately followed by a
   flush).
9. **Hardware bring-up.** Real-board test via the existing debug_uart
   halt/step/read-regfile infrastructure. This is also where §4's open
   question (5-stage vs. 6-stage, depending on real M9K read latency) has
   to be resolved for real, since that's a hardware-only fact simulation
   cannot expose.

   `riscv_top.sv` exposes a `CORE_TYPE` parameter (`"PIPELINED"` (default)
   or `"SINGLE_CYCLE"`) so the frozen golden-model core can be synthesized
   and bring-up-tested on real hardware too, independent of the pipeline's
   own progress — the two cores share an identical port list (confirmed by
   `test/testbench/tb_diff.sv`'s side-by-side instantiation), so this is a
   pure `generate if` choice, not a rewiring. Override it in Quartus via
   `set_parameter -name CORE_TYPE "SINGLE_CYCLE"` in `fpga/riscv_top.qsf`
   (both `riscv_core.sv` and `riscv_core_single_cycle.sv` are listed as
   source files so either branch can elaborate). In simulation, the mirror
   parameter on `test/testbench/tb_top.sv` is set via
   `make sim TOPLEVEL=tb_top MODULE=testbench.test_top CORE_TYPE=SINGLE_CYCLE`
   — `test_top.py` runs unchanged against either value except for
   `test_single_cycle_core_smoke`, which is only meaningful under that
   build (cocotb can't introspect the elaborated Verilog parameter from
   Python, so running the file twice, once per `CORE_TYPE`, is the full
   regression matrix for that testbench).
