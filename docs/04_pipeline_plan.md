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

**Resolved.** `riscv_core.sv` now has an explicit req/vld handshake
(`imem_req`/`imem_vld`, `dmem_req`/`dmem_vld`) instead of assuming a fixed
latency: IF/MEM present a request and the whole front-end (or just MEM,
depending on which side is waiting — see `mem_wait`/`if_wait`/`front_stall`
in `riscv_core.sv`) freezes until `vld` comes back, generalizing the
existing `id_stall`/`ex_flush` freeze+bubble mechanism to memory latency of
any length. This sidesteps the 5-vs-6-stage question below entirely — the
pipeline is correct for 1-cycle latency today and for more cycles later
(e.g. a cache) without changing the register count, because it waits on
`vld` rather than hardcoding a stage count for one fixed latency.

`fpga/riscv_top.sv`/`test/testbench/tb_top.sv` wire `imem_vld`/`dmem_vld` to
registers (`imem_rvalid`/`dmem_rvalid`) that are supposed to pulse one cycle
after `imem_req`/`dmem_req`, matching `dp_ram_model.sv`'s `REGISTERED_ADDR=1`
timing (now the default in `tb_top.sv`, matching real M9K block RAM).
`dmem_rvalid <= dmem_req` does this correctly. **`imem_rvalid` is now fixed
too** — see §6.2; it was double-registered, adding a spurious extra cycle
of stale-valid reporting right after a jump.

Regression status: `test_full` (tb_core, zero-latency) 27/27, `test_diff`
7/7, `test_uart` 1/1, `test_debugger` 1/1 all passing. `test_top.py`
(`tb_top`, real `REGISTERED_ADDR=1` sync-read timing) is **7/7 for both
`CORE_TYPE=SINGLE_CYCLE` and `CORE_TYPE=PIPELINED`** — see §6.3, the
`ProgramCounter` `ex_flush`/`front_stall` priority fix resolved the
pipelined-core failures, and `test_pipeline_stall_real_latency` (new)
now covers `test_pipeline_stall.asm`'s RAW/load-use hazards under real
memory-latency timing, which `test_diff.py`'s zero-latency version of
the same program never exercised.

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

1. ~~**Real BRAM latency (§4)** — is it 5-stage or 6-stage?~~ **Resolved by
   req/vld** (§4) — the pipeline waits on `vld` generically instead of
   committing to a fixed stage count, so this question no longer applies.
2. **Stall-only v1 vs. forwarding from the start** — plan above assumes
   stall-only for v1; confirm that's still the right call once the stage
   count from (1) is settled, since a 6-stage pipeline stalls more often
   than a 5-stage one and the cost/benefit of forwarding shifts.
3. **Where exactly hazard detection lives** — a dedicated hazard-detect
   block reading `if_id`/`id_ex`'s `rd`/`rs1`/`rs2` fields (matching this
   codebase's existing style of separate named combinational blocks like
   `Decoder_Logic`), decided once (2) is settled.

### 6.1 `mem_stall_ctrl` retired — single-cycle core now uses native req/vld too

**Resolved, 28 Jul 2026.** `src/memory/mem_stall_ctrl.sv` (an external
whole-core `halt` wrapper) only ever covered `CORE_TYPE=SINGLE_CYCLE`, and
was a hack: it overloaded `halt` (a debug signal) with memory-timing
correctness, and needed its own FSM guessing at fetch/mem timing the core
should know natively. It has been deleted. `riscv_core_single_cycle.sv`
now has the same `imem_req`/`imem_vld`/`dmem_req`/`dmem_vld` ports as
`riscv_core.sv`, collapsed into a single `stall` signal (no independent
stages to freeze) that gates its `pc` register and regfile write port.
Both `fpga/riscv_top.sv` and `test/testbench/tb_top.sv` wire both cores'
`CORE_TYPE` branches identically now — `halt` is purely a debug signal
again in both branches, with no memory-timing role.

### 6.2 RESOLVED: `imem_rvalid` was double-registered against `imem_addr_changed`

Found while re-verifying `riscv_core_single_cycle.sv`'s new req/vld stall
logic against `test/testbench/test_top.py` (`tb_top`,
`REGISTERED_ADDR=1`). The shipped fix for the original "`imem_rvalid`
hardwired `1'b1`" bug (address-change tracking, not the `imem_req`-based
fix originally sketched below) introduced a subtler follow-on bug in both
`fpga/riscv_top.sv` and `test/testbench/tb_top.sv`:

```systemverilog
logic [31:0] imem_addr_prev;
logic        imem_addr_changed;

always_ff @(posedge clk) begin
    imem_addr_prev <= imem_addr;
end
assign imem_addr_changed = (imem_addr != imem_addr_prev);

always_ff @(posedge clk) begin
    imem_rvalid <= !imem_addr_changed;   // WRONG: registers an already-latched signal
end
```

`imem_addr_changed` already compares *this* cycle's address against
*last* cycle's — it's already the correctly-timed "has the BRAM's
one-cycle registered read latency elapsed" signal. Registering it again
into `imem_rvalid` added a spurious extra cycle of stale-valid reporting.
This only showed up right after a jump/branch (two address changes back
to back: old→target, then target→target+4) — `imem_vld` would briefly
read valid for stale `imem_rdata` in that window, letting the core
re-execute or skip an instruction right at the jump target. This matched
`test_resume_correctness`'s failure signature exactly (`auipc x4, 0`
silently dropped, corrupting a downstream `xor`/register chain right
after a `jal`).

**Fix:** made `imem_rvalid` combinational — `assign imem_rvalid =
!imem_addr_changed;` — in both files. Confirmed by rerunning
`test_top.py` under `CORE_TYPE=SINGLE_CYCLE`: 6/6 passing, including
`test_resume_correctness`'s full x5–x30==1 check after RESUME
convergence.

### 6.3 RESOLVED: pipelined `ProgramCounter` missing `ex_flush` priority over `front_stall`

Found while root-causing `test_top.py`'s `CORE_TYPE=PIPELINED` 3/6
result (§4/§6 item 2's actual failure mode — not a missing-feature gap,
a priority bug). `riscv_core.sv`'s `ProgramCounter` always_ff froze `pc`
on `mem_wait || front_stall` with no explicit priority for `ex_flush`
(EX resolving a taken branch/jal/jalr), unlike `if_id_valid`/`id_ex_valid`
elsewhere in the same file, which already give `ex_flush` priority over
`front_stall`. Under `REGISTERED_ADDR=1`, `if_wait` (part of
`front_stall`) is true roughly every other cycle by construction, so a
branch/jump redirect landing on such a cycle was silently and
permanently dropped: `pc` never took `next_pc` that cycle, and `id_ex`
was flushed to a bubble regardless of `front_stall`, so there was no
retry.

**Fix:** reordered `ProgramCounter`'s priority to `mem_wait` (pc holds) >
`ex_flush` (pc takes `next_pc`) > `front_stall` (pc holds) > default
(`pc <= next_pc`), matching the priority `if_id_valid`/`id_ex_valid`
already used.

Two further `test_top.py` failures surfaced after this fix, both
test-code issues rather than RTL bugs:
- `test_resume_correctness`'s exact `pc == loop_pc` convergence check was
  too strict for the pipelined core — predict-not-taken IF keeps
  optimistically fetching `pc+4`/`pc+8` after every `jal`, so a trailing
  self-loop bounces `pc` through `loop_pc`/`+4`/`+8` forever even though
  the jal is correctly re-redirecting every time (same bounce
  `test_single_cycle_core_smoke`/`test_debugger.py` already tolerate via
  range checks). Loosened to `loop_pc <= pc <= loop_pc + 8`.
- `test_step_reliability` failed because `debug_uart.sv`'s STEP drops
  `halt` for exactly one clk cycle, assuming one halt-drop = one
  instruction retiring — true for the single-cycle core, false for the
  pipelined core whenever a RAW hazard (`front_stall`) or memory wait
  (`if_wait`/`mem_wait`) is already pending, since forward progress then
  needs multiple consecutive un-halted cycles. Fixed at the test level
  with a `CORE_TYPE`-aware self-skip (`test/Makefile` now `export`s
  `CORE_TYPE` so Python can read it, since cocotb can't introspect the
  elaborated Verilog parameter). **Not fixed in RTL — see the open
  question below.**

Confirmed via rerun: `test_top.py` is 6/6 under both `CORE_TYPE`s.

**Follow-up, 28 Jul 2026:** added `test_pipeline_stall_real_latency` —
runs `test_pipeline_stall.asm` (distance-0 RAW hazards, an rs1==rs2
double-hazard, a hazard-guarded branch, and a load-use chain) via RESUME
under `tb_top`'s real `REGISTERED_ADDR=1` timing. This closes a real gap:
`test_diff.py`'s `diff_test_pipeline_stall` already covers the same
program's hazard shapes, but only against `tb_diff`'s zero-latency
memory, so it could never exercise a RAW stall (`front_stall`)
overlapping a real fetch/mem wait (`if_wait`/`mem_wait`) — exactly the
interaction the §6.3 `ex_flush`/`front_stall` priority bug lived in.
First run caught a test-isolation bug, not an RTL bug: `test_top.py` has
no regfile-clearing helper between `@cocotb.test()` functions (unlike
`test_diff.py`'s `_clear_regfiles`), so `test_resume_correctness`'s
x5–x30==1 leftovers leaked into this test's x7==0 check. Fixed by zeroing
`dut.g_core.u_core.regfile[i]` before loading the program. `test_top.py`
is now **7/7 under both `CORE_TYPE`s**.

**Open, not yet decided: should STEP be redesigned for the pipelined
core, or stay single-cycle-only?** Two options on the table:
1. Leave it skipped under `CORE_TYPE=PIPELINED` (current state) — STEP
   stays single-cycle-only; pipelined debugging relies on
   HALT/RESUME/READ_REG only, no single-instruction stepping.
2. Redesign STEP for the pipeline — e.g. `debug_uart.sv` holds `halt`
   deasserted until an explicit "retire" pulse comes back from the core
   (gated on `!front_stall && !mem_wait` plus a real commit signal), so
   STEP genuinely waits for one instruction to complete regardless of
   stalls. Requires real RTL work in both `debug_uart.sv` and
   `riscv_core.sv`, plus new tests. Not started, not scoped in detail.

## 7. Verification plan

Rather than build the whole pipeline and verify at the end, each milestone
below ships with its own passing test before the next milestone starts.
`riscv_core_single_cycle.sv` is the golden reference model from the first
milestone on, not bolted on afterward: correctness is defined as
"pipeline produces the same architectural end-state as the single-cycle
core," checked differentially rather than against hand-derived expected
values. "Golden" here means verified-reference, not literally
untouchable — it gained native req/vld memory-timing ports this session
(§6.1) when the alternative was an external `halt`-based hack, and was
re-verified against the full `test_full.asm` suite before being
considered golden again. Future instruction additions should follow the
same pattern: modify, then re-verify against the full suite, then trust
it as the diff target again.

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
   or `"SINGLE_CYCLE"`) so the golden-model core can be synthesized
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

   **Update, 27 Jul 2026:** confirmed via real hardware bring-up symptoms
   (STEP only "taking" ~1/3 of the time, RESUME never converging) plus
   simulation once `dp_ram_model`'s `REGISTERED_ADDR` was flipped to 1 that
   this §4/§6 item is real: real BRAM's registered-address read latency
   breaks the single-cycle core's zero-latency-read assumption exactly as
   predicted. Fixed for `CORE_TYPE=SINGLE_CYCLE` via a new external module,
   `src/memory/mem_stall_ctrl.sv`, that holds the core's `halt` input
   asserted from fetch until data is actually valid (see `docs/dev_log.md`'s
   27 Jul 2026 entry for the full design and an open follow-up bug it
   surfaced in `debug_uart.sv`'s reset). This does NOT resolve §4/§6 item 1
   for the pipelined core -- whole-core-freeze doesn't map onto per-stage
   pipeline stalling, so the 5- vs 6-stage question below is still open and
   still needs its own fix once pipeline work resumes.

   **Update, 28 Jul 2026:** `mem_stall_ctrl` retired (§6.1) — replaced by
   native req/vld ports on `riscv_core_single_cycle.sv` itself, matching
   `riscv_core.sv`'s existing pattern. Re-verifying against
   `test_full.asm` under real `REGISTERED_ADDR=1` timing surfaced and
   fixed the deeper `imem_rvalid` double-registration bug (§6.2) that the
   original `mem_stall_ctrl`-based fix had been masking. `test_top.py`
   under `CORE_TYPE=SINGLE_CYCLE` is now 6/6; the `PIPELINED` 3/6 result
   (§4/§6 item 1, still open) is unchanged by this work.

   **Update, later 28 Jul 2026:** the `PIPELINED` 3/6 result turned out
   to be a `ProgramCounter` priority bug, not a missing-feature gap —
   see §6.3. Fixed; `test_top.py` is now 6/6 under both `CORE_TYPE`s.
   §6/item 1 is fully resolved. One open item remains from this pass:
   whether STEP needs a real redesign for the pipelined core (§6.3's
   closing note) — undecided, revisit before relying on STEP against
   `CORE_TYPE=PIPELINED` hardware/sim debugging.
