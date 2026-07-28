25 Feb 2026
- Came up with project idea
- Added basic docs
- Ideation with ChatGPT and Claude

22 Apr 2026
- Added RV32I CPU in transaction level verilog (TLV) from RISCV CPU Core Course (by Linux Foundation)
- Idea is to use the logic from the course and translate to system verilog.

19 May 2026
- Started TLV to SV translation. Completed translation up to "Instructions". Need to implement "ALU" onwards.
- Design in src/riscv_core/riscv_core.sv

21 May 2026
- Finished v1 of RV32I RTL.
- Started work on the cocotb testbench suite.
- Finished testbench suite v1
- Fully verfied all 27 instructions

24 May 2026
- Added UART module
- Created DPRAM module from Quartus IP
- Created riscv wrapper with UART and DPRAM
- TODO: Test top wrapper and write bootloader

22 Jul 2026
- Added hardware register debugger (src/peripherals/debug_uart.sv): a second,
  independent UART peripheral on its own pins that can halt/step/resume the
  core and read back regfile/PC over serial, without touching dmem/imem.
- Switched riscv_core's debug port from a packed regfile_dbg[31:0] array to
  an address+data indexed interface (dbg_reg_addr in, dbg_reg_data out) --
  Quartus doesn't support multi-dim packed arrays on top-level synthesis
  I/O, so the array port would have blocked hardware builds even though it
  worked fine in simulation.
- Found and fixed a real bug in UART_RX (src/peripherals/uart.sv): the DONE
  state was waiting a full extra bit period after the receiver had already
  settled at mid-stop-bit, so two bytes sent back-to-back (no idle gap --
  exactly what the debug UART's READ_REG <idx> command does) had the second
  byte's start bit silently eaten during that wait, corrupting every bit
  sampled afterward. Fixed by waiting only a half bit period in DONE,
  mirroring START's own half-period mid-bit alignment.
- Fixed test_debugger.py's STEP assertions: it assumed PC advances by 4 on
  every STEP, but sending a debug command takes far longer than
  test_basic.asm takes to run, so by the time HALT lands the core is
  already parked on `loop: j loop` -- stepping a self-jump correctly leaves
  PC unchanged.
- Verified via cocotb: test_uart (loopback), test_debugger
  (halt/step/read/resume), test_bootloader all pass.

24 Jul 2026
- Renamed fpga/dp_ram_model.v -> .sv (hand-authored files must be .sv per
  Quartus always_comb-in-.v error hit previously); updated test/Makefile
  and tb_top.sv comment references.
- Hardware bug triage session (issues reported from real board testing):
  - .bin load corruption ("01500093" -> "xxb00093") + unreliable
    read/dump: traced via reg_debugger.py --dry-run byte tracing, confirmed
    host-side framing was correct -- root cause is UART RX timing margin
    at 25MHz/115200 (tight back-to-back byte timing, clk_per_bit=217 isn't
    an exact divisor). Fixed by switching to 2 stop bits everywhere:
    fpga/riscv_top.sv, src/peripherals/debug_uart.sv, plus matching
    stopbits=STOPBITS_TWO in software/uart_loader.py and
    software/reg_debugger.py. Also updated test/testbench/tb_soc.sv,
    tb_top.sv, tb_uart.sv STOP_BITS params to keep sim honest.
  - READ_MEM hang on nonzero offset: root-caused as debug_uart.sv's
    multi-byte argument states (WAIT_ARG, RECV_MEM_ADDR, RECV_MEM_DATA)
    having no timeout -- a single dropped/garbled byte (more likely with
    real bit transitions vs. an all-zero address) wedges the FSM waiting
    forever. Fixed by adding rx_timeout_cnt (TIMEOUT_BIT_PERIODS=20)
    abort-to-CMD_IDLE logic to all three states.
  - PC incrementing but jumps never taking effect on hardware: root-caused
    as a fundamental BRAM read-latency mismatch. riscv_core.sv assumes
    0-cycle combinational instruction fetch; real altsyncram IP
    (fpga/dp_ram.v) has registered address capture on both ports
    regardless of outdata_reg_a/b wizard settings (only the *output*
    register was ever set to UNREGISTERED; address_reg_a/b were never
    touched, and even UNREGISTERED only removes an *extra* register on
    top of M9K's inherent address-capture-on-clock-edge behavior -- true
    zero-latency async read isn't achievable on real block RAM at all).
    Conclusion: this is architectural, not an IP misconfiguration -- fix
    is to pipeline the core, not regenerate the IP. Secondary gotcha
    found: debug_uart.sv halts the core on every reset
    (`if (rst) halt <= 1'b1`), so a bare reset with no RESUME/KEY[1] held
    leaves the core permanently parked at PC=0 -- separate from the BRAM
    bug, easy to mistake for one.
- Wrote docs/03_microarchitecture.md (was a stub) covering pipeline stage
  derivation (resource conflicts / sequential dependency / critical-path
  balance), prefetch+flush+reset design, a full mapping of the proposed
  5-stage layout onto existing riscv_core.sv signal names, and a section
  on this codebase's SV idioms (one-hot decode booleans, casez wildcards,
  enum+case FSMs, always_comb total-assignment discipline, restate-safe-
  value-per-state pattern) so the pipeline is written in the same style.
- Wrote docs/04_pipeline_plan.md (new) as the concrete, committable
  implementation plan: pipeline register field lists, hazard-by-hazard
  handling strategy (stall-only v1, no forwarding), the open BRAM-latency
  question (5- vs 6-stage, needs real Quartus confirmation), and reset
  behavior reusing the flush valid-gating mechanism.
- Confirmed DE10-Lite board (10M50DAF484C7G, via fpga/riscv_top.qsf) has
  64MB on-board SDRAM (not discrete SRAM as originally guessed) --
  deferred as a later integration issue, unrelated to the current
  pipeline work.
- Verified current single-cycle core still fully passes before starting
  any pipeline RTL: test_full 27/27, test_top 3/3, tb_uart 1/1. Backed it
  up as src/riscv_core/riscv_core_single_cycle.sv (module renamed to
  riscv_core_single_cycle so it can coexist with the pipeline once that's
  also named riscv_core) -- this is now the permanent golden reference
  model for differential testing, not a throwaway snapshot. Deleted a
  stale untracked riscv_core.sv.bak left over from before the halt/debug
  interface existed (predated this backup, not useful as a reference).
- Planned the pipeline build as 9 verifiable milestones (harness infra ->
  plumbing-only pipeline registers -> flush -> RAW stall -> load-use ->
  reset gating -> full regression -> fuzz -> hardware bring-up), written
  into docs/04_pipeline_plan.md Sec.7, replacing the old short
  verification-plan section.
- Milestone 1 (differential harness infra) done and verified:
  - Added test/testbench/tb_diff.sv: instantiates riscv_core (DUT) and
    riscv_core_single_cycle (golden model) side by side, each with its own
    imem/dmem arrays.
  - Added utils.await_pc_convergence() (test/utils.py): waits for a core's
    pc to hold steady for N consecutive cycles rather than comparing after
    a fixed cycle count, since the pipeline will take a variable number of
    cycles per program once stalls/flush bubbles exist. Also added
    read_dmem() and made read_reg() take a `core=` kwarg (defaults to
    "u_core", so all existing call sites are unaffected) so both harness
    testbenches with two core instances can be inspected without duplicate
    helper functions.
  - Added test/testbench/test_diff.py (diff_test_full): runs test_full.asm
    against both cores, waits for both to converge, diffs regfile[0:31] +
    dmem[0:16). Currently trivially passes (riscv_core.sv IS still the
    single-cycle core -- pipeline RTL hasn't started), which is the point:
    proves the harness/convergence/diff mechanics work before there's a
    real pipeline to catch mismatches. Ran via `make sim TOPLEVEL=tb_diff
    MODULE=testbench.test_diff` -- both cores converged at pc=0x000000ec,
    zero mismatches.
  - Re-ran full existing suite after the Makefile/utils.py changes to
    confirm no regressions: test_full 27/27, test_top 3/3, tb_uart 1/1,
    all still pass.
- Starting milestone 2 next (pipeline registers, no hazard handling) --
  user stepped away for lunch, continuing solo and will report back.
- Milestone 2 (pipeline registers, no hazard handling) done and verified:
  - Rewrote src/riscv_core/riscv_core.sv into a 5-stage IF/ID/EX/MEM/WB
    pipeline per 04_pipeline_plan.md Sec.2's field-list table: added
    if_id_instr/pc/valid, id_ex_rd/ctrl/imm/src1_value/src2_value/pc/valid,
    ex_mem_result/src2_value/rd/is_load/is_s_instr/wr_en/valid, and
    mem_wb_wr_data/rd/wr_en/valid pipeline registers. Decode moved into ID
    (reads if_id_instr), one-hot control bits packed into id_ctrl_bus and
    carried through id_ex_ctrl rather than redecoded in EX. ALU/branch
    compute moved into EX (reads id_ex_* registers). MEM stage drives
    dmem_addr/wdata/we/re off ex_mem_* registers. WB commits off mem_wb_*
    registers. All four pipeline registers reset to 0/invalid on rst and
    hold on halt, matching the existing pc/regfile gating pattern. No
    stall detection or flush logic yet -- next_pc redirection still exists
    (any branch/jump-containing program needs it to loop), but if_id/id_ex
    are not squashed on redirect, so wrong-path instructions already
    in-flight after a taken branch/jump commit through regardless. Port
    list unchanged, so tb_core.sv/tb_soc.sv/tb_top.sv/tb_diff.sv's
    instantiations all still connect without modification.
  - Wrote test/asm_programs/test_pipeline_straight.asm: a hand-written
    straight-line, no-branch program where every instruction writes a
    distinct destination register and reads only x0/immediates, so no
    instruction depends on a value still in flight -- isolates the
    plumbing/latching timing from hazard behavior per the milestone's
    explicit goal.
  - Added diff_test_pipeline_straight to test/testbench/test_diff.py,
    running that program through the tb_diff.sv harness against the
    frozen single-cycle golden model.
  - Hit and fixed three harness bugs surfaced by actually exercising the
    new pipeline (all in test infra, not riscv_core.sv):
    1. await_pc_convergence assumed pc becomes exactly static once a core
       finishes. True for the single-cycle golden model, but the
       pipelined DUT's `loop: jal x0 loop` resolves 2 cycles after fetch
       (IF/ID then ID/EX register stages), so pc optimistically fetches
       pc+4/pc+8 before snapping back to the loop label -- a period-3
       cycle (P, P+4, P+8, P, ...) that will never go static, even after
       flush logic (milestone 3) lands, since flush only squashes
       wrong-path *instructions*, not this fixed resolution latency.
       Fixed by generalizing the helper to accept a `period` parameter and
       check for a repeating window rather than an exactly-static value;
       callers pass period=3 for the pipelined DUT (period=1, the
       default, still applies to the single-cycle golden model).
    2. Both diff tests failing when run together despite passing
       individually: riscv_core.sv's regfile has no reset logic (by
       design -- only pc and the new pipeline registers reset), so
       running multiple @cocotb.test() functions against the same
       simulated instance let register values leak from one test into
       the next. Fixed with a _clear_regfiles() helper called at the
       start of every diff test.
    3. Same leak, but for imem/dmem: a shorter program (21 words) loaded
       after a longer one (test_full.asm, 60 words) left stale
       non-nop instructions sitting past the shorter program's own loop
       label. Because milestone 2 has no flush yet, the pipelined DUT's
       period-3 pc bounce transiently fetches a couple words past the
       loop label every iteration -- normally harmless if those words are
       zero (decodes as a real no-op), but here they were leftover real
       instructions from the previous test, and their transient
       (should-be-squashed-by-future-flush) side effects actually
       committed. Fixed by zeroing the full imem/dmem arrays (all 256
       words each core), not just the touched-region dmem window, in
       _clear_regfiles() before every test.
  - Ran diff_test_pipeline_straight in isolation: passes, both cores
    converge on identical regfile end-state (DUT pc bounces per the
    period-3 pattern above, golden model static -- both report the same
    loop-label pc via the convergence helper's return value).
  - Ran diff_test_full (test_full.asm, has mid-program JAL/JALR, not just
    the trailing loop) through the same harness against the pipelined
    DUT: fails, as expected -- confirmed this is milestone 3's test (flush
    logic doesn't exist yet, so the JAL/JALR's wrong-path instructions
    corrupt DUT-only state), not a milestone 2 regression. Marked
    @cocotb.test(expect_fail=True) with a comment explaining why and when
    to remove the marker (once flush lands), so the suite stays green
    without silently losing the signal for when flush actually fixes it.
  - Ran the full pre-existing suite against the pipelined core to check
    for regressions: test_full.py (fixed 100-cycle wait, timed for
    single-cycle latency) now fails 20/27 -- expected, not a milestone-2
    bug: the pipeline takes more cycles per instruction than 100-cycle
    single-cycle timing assumes, and 04_pipeline_plan.md Sec.7 explicitly
    scopes "full regression on existing suites" as milestone 7, after
    stall/flush are both in place. tb_uart (no core dependency) still
    passes 1/1, confirming the pipeline changes didn't affect unrelated
    infra. test_top/test_debugger not yet re-run this pass (same
    fixed-cycle-timing issue expected; deferred to milestone 7 alongside
    test_full.py).
  - Milestone 2 marked complete. Its own explicit test
    (diff_test_pipeline_straight, the no-hazard/no-branch case it was
    scoped to prove) passes; the fixed-cycle-timed suites' failures are
    the anticipated, documented consequence of moving to variable pipeline
    timing, not a correctness regression -- they're milestone 7's job to
    fix (likely by switching them to convergence-based waits like
    test_diff.py, or bumping their cycle budgets, decided when that
    milestone starts).
- Starting milestone 3 next (flush on taken branch/jump) -- continuing
  solo, user still away.
- Milestone 3 (flush on taken branch/jump) done and verified:
  - Added flush logic to src/riscv_core/riscv_core.sv per
    03_microarchitecture.md Sec.3: a new ex_flush wire
    (`ex_taken_br || ex_is_jal || ex_is_jalr`) gates the IF_ID_Reg and
    ID_EX_Reg always_ff blocks -- when set, both squash their outputs to
    the all-zero/invalid bubble state that cycle instead of latching the
    next real fetch/decode result, the same cycle next_pc redirects IF.
    This drains the two wrong-path instructions that predict-not-taken
    prefetch already pulled in before EX resolved the jump/branch,
    without touching reset's own squash path (kept as a separate `if
    (rst)` branch, per the doc's "same mechanism, different trigger"
    framing -- not merged into one conditional, to keep reset's
    async-clear semantics distinct from flush's synchronous one).
  - Wrote test/asm_programs/test_pipeline_flush.asm: exercises jal, jalr,
    and both branch directions (beq taken, bne taken) with zero RAW
    dependencies anywhere in the program -- every operand-setup
    instruction is followed by 3 filler instructions before it's read
    anywhere (jalr's base register, both branches' compared register),
    clearing the 5-stage no-forwarding RAW hazard window so a stale
    register read can't corrupt a branch decision and produce a false
    flush-logic failure. Every instruction that a working flush must
    prevent from executing (the two wrong-path instructions after each
    jump/branch) writes a recognizable sentinel value (99) to a register
    no other instruction touches, so any flush bug leaves an obviously
    wrong, easy-to-spot value in the diffed regfile rather than a subtle
    one.
  - Added diff_test_pipeline_flush to test/testbench/test_diff.py running
    that program through the differential harness.
  - Hit and fixed a false failure while writing the test program itself
    (not a flush bug): the first two versions of
    test_pipeline_flush.asm used only 1-2 filler instructions between an
    operand's setup and its use before a branch (e.g. `addi x14,x0,1`
    immediately or nearly-immediately followed by `bne x14,x0,...`).
    With no forwarding until milestone 4, that's a live RAW hazard --
    the branch reads x14 in ID before the addi's writeback has committed,
    silently getting a stale value and making a wrong branch decision
    that has nothing to do with flush correctness. Root-caused via the
    mismatch's register number lining up exactly with the hazard window
    (x15's post-branch sentinel leaking through), not a flush-squash bug.
    Fixed by widening every operand-to-use gap in the test program to 3
    filler instructions, confirmed sufficient for this 5-stage
    (IF/ID/EX/MEM/WB) depth.
  - Ran the full differential suite (diff_test_full [expect_fail, still
    correctly failing on milestone 4's RAW hazards --unaffected by this
    milestone's change], diff_test_pipeline_straight, and the new
    diff_test_pipeline_flush): all 3 tests report their expected
    outcome, TESTS=3 PASS=3 FAIL=0 (diff_test_full's "pass" is its
    expect_fail marker correctly firing). Both cores converged on
    identical end-state for test_pipeline_flush.asm (DUT pc=0x6c bouncing
    per its period-3 pattern, golden model static at the same address),
    confirming every jal/jalr/branch target landed correctly and every
    sentinel-99 write was successfully squashed.
  - Re-ran tb_uart (no core dependency): still 1/1 pass, confirming no
    regression to unrelated infra from this change.
  - Milestone 3 marked complete. test_full.py/test_top/test_debugger
    (fixed-cycle-timed, pre-existing suites) remain deferred to milestone
    7 as before -- unaffected by today's change since that gap is a test-
    harness timing assumption, not a correctness issue with flush itself.
- Starting milestone 4 next (RAW-hazard stall detection) -- continuing
  solo, user still away.
- Milestone 4 (RAW-hazard stall detection) done and verified:
  - Added stall-only v1 hazard detection to src/riscv_core/riscv_core.sv
    per 04_pipeline_plan.md Sec.3/Sec.6: a new id_stall wire compares the
    ID-stage instruction's rs1/rs2 (gated on rs1_valid/rs2_valid and
    != x0) against id_ex_rd, ex_mem_rd, and mem_wb_rd, each gated on that
    stage's own valid/wr_en, using ex_wr_en (not id_ex's own precomputed
    field, since id_ex doesn't carry one) for the id_ex comparison. No
    forwarding -- a hazard just stalls until the writing instruction's
    result has committed to the regfile.
  - Wired id_stall to hold both pc (ProgramCounter always_ff: pc <= pc
    instead of next_pc) and if_id (IF_ID_Reg: re-latch if_id_instr/pc/
    valid instead of re-fetching) in place for one or more cycles, and to
    force id_ex to a zeroed/invalid bubble (ID_EX_Reg) each stalled cycle
    so EX doesn't see a duplicate of whatever it already consumed. Same
    valid-bit-gating pattern as reset/flush, added as a third `else if`
    branch alongside `if (rst)` / `if (ex_flush)` in each register block
    -- not merged into flush, since id_stall and ex_flush are gated
    mutually exclusive by construction (id_stall's own expression includes
    `&& !ex_flush`) but conceptually distinct triggers.
  - Wrote test/asm_programs/test_pipeline_stall.asm: deliberately
    zero-gap RAW dependencies (the opposite discipline from every
    milestone 2/3 test program) -- distance-0 register reuse immediately
    after a write, a chain of several back-to-back dependent
    instructions, an rs1==rs2 double-hazard on the same register, a
    branch whose both compare operands are themselves distance-0 hazards,
    and a store/load/use chain (sw x10,0(x9) / lw x11,0(x9) / add
    x12,x11,x11) covering load-use a cycle early (milestone 5 gets its
    own dedicated test, but this one costs nothing extra and would have
    caught an obvious break immediately).
  - Added diff_test_pipeline_stall to test/testbench/test_diff.py running
    that program through the differential harness. Passed on the first
    run with no debugging needed -- both cores converged at pc=0x38 with
    zero regfile mismatches.
  - Re-ran the full diff suite: with stall logic in place, diff_test_full
    (test_full.asm, previously expect_fail=True since milestone 2 --
    originally for missing flush, then for missing stall once flush
    landed) now genuinely passes. Removed the expect_fail=True marker and
    rewrote its stale docstring to describe both historical failure
    reasons and confirm milestone 4 is what finally fixed it. Full suite:
    TESTS=4 PASS=4 FAIL=0 (diff_test_full, diff_test_pipeline_straight,
    diff_test_pipeline_stall, diff_test_pipeline_flush all genuinely
    passing now, no expect_fail markers left in the file).
  - Re-ran tb_uart (no core dependency): still 1/1 pass, confirming no
    regression to unrelated infra from this change.
  - Milestone 4 marked complete. test_full.py/test_top/test_debugger
    (fixed-cycle-timed, pre-existing suites) remain deferred to milestone
    7 as before.
- Starting milestone 5 next (load-use hazard verification) -- continuing
  solo, user still away.
- Milestone 5 (load-use hazard verification) done and verified:
  - No RTL changes -- per 04_pipeline_plan.md Sec.3/Sec.7, this milestone
    is purely a test that confirms milestone 4's generic RAW-stall
    mechanism already covers load-use with no special case, rather than
    assuming it.
  - Wrote test/asm_programs/test_pipeline_load_use.asm: four load-use
    shapes back to back -- lw result used immediately as rs1, as rs2, as
    both rs1 and rs2 of the same instruction, and a second lw whose own
    address operand is the first lw's just-loaded result (chained
    load-use, the tightest case: the dependency crosses straight from one
    load's mem_wb commit into the very next instruction's address
    computation in EX).
  - Added diff_test_pipeline_load_use to test/testbench/test_diff.py.
    Passed on the first run, no debugging needed -- both cores converged
    at pc=0x58, zero regfile/dmem mismatches. Confirms milestone 4's
    hazard-detect logic (which treats id_ex_rd/ex_wr_en identically
    regardless of whether the producing instruction is a load or an ALU
    op) needed no load-specific special case, as the plan predicted.
  - Re-ran the full diff suite: TESTS=5 PASS=5 FAIL=0 (diff_test_full,
    diff_test_pipeline_straight, diff_test_pipeline_stall,
    diff_test_pipeline_load_use, diff_test_pipeline_flush).
  - Re-ran tb_uart: still 1/1 pass, no regression to unrelated infra.
  - Milestone 5 marked complete.
- Starting milestone 6 next (reset/valid-bit gating correctness) --
  continuing solo, user still away.
- Milestone 6 (reset/valid-bit gating correctness) done and verified:
  - No RTL changes -- the valid-bit gating this milestone tests already
    exists (reset zeroes every pipeline register's valid bit, including
    mem_wb_valid which gates the regfile write port, the same synchronous
    edge pc resets on), added incidentally while building milestones 2-4.
    This milestone is the first test that actually exercises reset
    mid-run with real in-flight instructions, rather than only at time 0
    before any instruction has entered the pipeline.
  - Added diff_test_pipeline_reset_midrun to test/testbench/test_diff.py:
    runs test_pipeline_stall.asm (already has multiple in-flight
    dependent instructions and a stall in progress, a good stress case)
    on both cores for 15 cycles, snapshots the regfile, then asserts rst
    on both cores for 4 cycles while re-checking every cycle that the
    regfile hasn't changed (catching a bogus write immediately rather
    than only at the end), then releases reset and lets both cores
    reconverge and diffs the final state as usual.
  - Ran in isolation: passed first try -- no bogus writes committed
    during the 4 held-reset cycles, and both cores reconverged on
    identical end-state (pc=0x38) after release, confirming reset
    correctly resumes execution from pc=0 exactly as a fresh run would.
  - Re-ran the full diff suite: TESTS=6 PASS=6 FAIL=0 (adds
    diff_test_pipeline_reset_midrun to the five existing milestone
    tests).
  - Re-ran tb_uart: still 1/1 pass, no regression to unrelated infra.
  - Milestone 6 marked complete.
- Starting milestone 7 next (full regression on existing suites) --
  continuing solo, user still away.
- Milestone 7 (full regression on existing pre-pipeline suites) done and
  verified. Went through each pre-existing testbench one at a time:
  - test/testbench/test_full.py (tb_core): its run_program test used a
    fixed `await run_cycles(dut, 100)` budget sized for single-cycle
    latency -- no longer reliable now that RAW stalls and flush bubbles
    can stretch a program's cycle count unpredictably. Swapped it for
    `await await_pc_convergence(dut, dut.pc_dbg, period=3)`, the same
    helper the differential harness already relies on. Re-ran: all 27
    sub-tests (register-snapshot checks for every RV32I op in
    test_full.asm) still pass -- TESTS=27 PASS=27 FAIL=0.
  - test/testbench/test_top.py (tb_top): read through it -- it tests the
    CLOCK_50/2 clock divider, the SW[0] program/debug UART mux, and
    KEY[1]'s halt override, none of which depend on fixed
    program-completion timing. No changes needed. Re-ran: still 3/3 pass
    unchanged.
  - test/testbench/test_debugger.py (tb_soc): this one surfaced a real
    bug, not just a stale timing assumption. test_halt_step_resume
    failed with pc_before_halt read back as 0x00000000 -- i.e. the core
    had executed nothing at all, not even reached the loop label of a
    4-instruction program. Root cause: src/peripherals/debug_uart.sv
    resets to `halt <= 1'b1` (a deliberate "core starts halted until a
    debugger attaches" default, per its own inline comment) and nothing
    in tb_soc.sv clears it -- unlike fpga/riscv_top.sv, which ties
    KEY[1] to an always-on override forcing halt low regardless of the
    debug UART. tb_soc has no such override, so the core was frozen at
    pc=0 for the entire test, and the old test's `run_cycles(dut, 20)`
    wait before HALT was even sent was just watching a halted core sit
    still -- previously invisible because it happened to look identical
    to "core ran and parked on its own self-loop", which single-cycle
    execution made indistinguishable without closer inspection.
    Fixed by sending CMD_RESUME immediately after reset, before the
    settle-in wait, so the core actually starts running:
      await reset(dut)
      await dbg_send_byte(dut, CMD_RESUME)
      await run_cycles(dut, 20)
    Also reworked the STEP-verification block, which assumed 3x STEP
    from a halted self-loop leaves pc exactly unchanged each time (true
    for single-cycle, false for the pipeline: a self-jump doesn't
    resolve until EX, 2 stages after fetch, so STEP walks pc through the
    same predict-not-taken period-3 bounce {loop_pc, loop_pc+4,
    loop_pc+8} that await_pc_convergence's period=3 already accounts for
    elsewhere). Computed loop_pc directly from test_basic.asm's known
    length (0x10, its trailing `loop: j loop` word), derived which of
    the 3 bounce phases pc_before_halt landed on, and asserted each STEP
    advances to the next phase in that fixed cycle. Updated the RESUME
    check similarly, to assert the resumed pc lands somewhere in the
    3-phase bounce set rather than at one exact value.
    Two earlier fix attempts (assuming pc_before_halt was always the
    minimum of its bounce triple; then correctly deriving loop_pc but
    without first fixing the halted-from-reset bug) both failed for
    the reasons above before this fix -- the real problem was the core
    never running at all, not the phase-tracking math, which turned out
    to be correct once the core was actually executing.
    Re-ran after the fix: TESTS=1 PASS=1 FAIL=0.
  - Full cross-suite regression, everything in one pass: tb_core/
    test_full 27/27, tb_top/test_top 3/3, tb_uart/test_uart 1/1,
    tb_diff/test_diff 6/6, tb_soc/test_debugger 1/1. No regressions
    anywhere from the milestone 4-7 changes.
  - Milestone 7 marked complete.
- Starting milestone 8 next (differential fuzz pass) -- continuing solo,
  user still away.
- Milestone 8 (differential fuzz pass) done and verified:
  - Added generate_fuzz_program(rng, ...) to test/utils.py: builds a
    random RV32I program as assembly source text (not a checked-in
    .asm file). Draws instruction kind (ALU R/I-type, shifts, lui,
    auipc, sw, lw) and operands uniformly from a small register pool
    (x1-x10), with a 40% bias toward reusing the immediately preceding
    instruction's rd as the next instruction's operand -- this reliably
    produces distance-0 RAW hazards (including load-use) across many
    runs without hand-picking any specific shape. A second pass
    converts a random subset of instruction slots into forward-only
    branches (target = current index + small random skip, clamped to
    the trailing loop) -- forward-only by construction guarantees every
    generated program terminates in its own self-loop (no accidental
    backward branch could create a second, non-loop cycle that never
    converges), while still exercising flush on both taken/not-taken
    outcomes and stall-into-branch (a branch's own compare operands
    can themselves still be mid-stall). Also added assemble_source() to
    utils.py, a thin wrapper around the existing assemble() that writes
    a temp .s file first, since the existing assembler helper only took
    a checked-in filename.
  - Added diff_test_pipeline_fuzz to test/testbench/test_diff.py: runs
    FUZZ_RUNS (100) generated programs through the differential harness
    in one test, each with its own fixed, logged seed
    (FUZZ_SEED_BASE=20260724 + run index) so a failure is reproducible
    standalone from its seed rather than being a one-off unrepeatable
    random failure -- the assert message includes the seed, both cores'
    converged pc, and the full generated source on any mismatch.
  - Ran in isolation at 25 runs first (fast iteration while debugging
    the generator): initial attempt failed to assemble --
    `auipc x6` alone is not a valid instruction (GNU as requires an
    immediate operand, unlike lui's optional-looking single-operand
    look), fixed by always emitting a random immediate:
    `auipc x{rd}, {imm}`. After that fix, all 25/25 runs matched the
    golden model on the first genuine attempt.
  - Scaled FUZZ_RUNS up to 100 (each run only costs ~20 more simulated
    ns and comfortably parallelizes with the fixed per-run reset/
    convergence overhead) -- re-ran, still 100/100 match, ~2s wall time
    total for the whole fuzz test.
  - Re-ran the full diff suite: TESTS=7 PASS=7 FAIL=0 (adds
    diff_test_pipeline_fuzz to the six existing milestone tests).
  - Re-ran the full cross-suite regression once more to confirm no
    interactions from the fuzz-generator addition: tb_core/test_full
    27/27, tb_top/test_top 3/3, tb_uart/test_uart 1/1, tb_soc/
    test_debugger 1/1 -- all still pass unchanged.
  - No RTL changes this milestone (as expected -- this is a test-only
    milestone, exercising interaction coverage the directed tests
    couldn't reach by construction).
  - Milestone 8 marked complete.
- Milestone 9 (hardware bring-up) remains -- requires physical board
  access, which this autonomous session cannot perform. Deferred until
  the user returns and can drive the real Quartus/hardware flow
  (resolving the still-open 5-stage vs 6-stage BRAM-latency question
  per docs/04_pipeline_plan.md Sec.4/Sec.6 item 1 against real hardware
  timing, not just simulation). All simulation-only work through
  milestone 8 is now complete and passing.

21 Jul 2026
- Added a `CORE_TYPE` synthesis-time parameter (`"PIPELINED"` (default) /
  `"SINGLE_CYCLE"`) to `fpga/riscv_top.sv` and its sim counterpart
  `test/testbench/tb_top.sv`, so the frozen `riscv_core_single_cycle`
  golden model can be hardware-bring-up-tested too, independent of the
  in-development pipeline. Confirmed the two cores are pin-compatible
  (identical port lists, already proven by `tb_diff.sv`'s side-by-side
  instantiation), so this is a pure `generate if` swap -- no other
  wrapper logic (BRAM mux, debug UART, halt semantics) depends on which
  core is behind it.
  - Both generate branches use the same block label (`g_core`), so the
    hierarchical instance path (`g_core.u_core`) stays stable regardless
    of which `CORE_TYPE` is elaborated -- updated `test_top.py`'s
    `dut.u_core.pc` references (3 sites, `test_halt_override`) to
    `dut.g_core.u_core.pc` accordingly.
  - Also tied the previously-unconnected `_bogus` port explicitly to
    `1'b0` in both new instantiation sites (was implicitly zero-filled by
    Verilator before; harmless but worth closing while touching these
    instantiations anyway).
  - `fpga/riscv_top.qsf`: added `riscv_core_single_cycle.sv` to the
    source-file list (both cores must be present for Quartus to resolve
    the generate-if at synth time) and documented the
    `set_parameter -name CORE_TYPE "SINGLE_CYCLE"` override.
  - `test/Makefile`: added a `CORE_TYPE` variable forwarded to Verilator
    via `-GCORE_TYPE`, gated behind `ifeq ($(TOPLEVEL),tb_top)` --
    discovered the hard way that passing `-G` unconditionally breaks
    every other testbench (`tb_core`, `tb_soc`, etc.) with a
    "Parameters... were not found" error, since only `tb_top` declares
    that parameter.
  - Added `test_single_cycle_core_smoke` to `test_top.py`: runs
    `test_basic.asm` and asserts the core parks on the trailing
    self-loop. Since cocotb can't introspect the elaborated Verilog
    parameter value, this test doesn't self-skip under the wrong
    `CORE_TYPE` -- running `test_top.py` once per `CORE_TYPE` value is
    documented as the full regression matrix for that testbench.
  - While debugging this new test failing only when run after
    `test_halt_override` in the same suite (but passing in isolation),
    found and fixed a real, pre-existing race in `test_top.py`'s
    `set_key()` helper: two back-to-back `set_key()` calls (as
    `reset_top()` made, one for `KEY[0]` and one for `KEY[1]`) both read
    `dut.KEY.value` before either write had taken effect, so the second
    call silently clobbered the first -- meaning `reset_top()` could
    fail to actually assert reset depending on `KEY`'s leftover value
    from whatever ran before it. Fixed by setting both bits in one
    combined write (`dut.KEY.value = 0b10`) instead of two sequential
    read-modify-writes.
  - Verified: `tb_top`/`test_top` 4/4 pass under both `CORE_TYPE=PIPELINED`
    (default) and `CORE_TYPE=SINGLE_CYCLE`; re-ran `tb_core`/`test_full`
    (27/27) and `tb_diff`/`test_diff` (7/7) to confirm no regressions from
    the `_bogus` tie-off or QSF file-list change -- both no-ops as
    expected, since those testbenches instantiate the cores directly, not
    through `riscv_top`/`tb_top`.
  - Hardware-only, not verifiable in this environment: actually setting
    `CORE_TYPE` via Quartus's parameter-override UI/QSF and confirming the
    fitter picks the right generate branch on the real DE10-Lite.

27 Jul 2026
- Root-caused the real-hardware bug where `CORE_TYPE=SINGLE_CYCLE` only ever
  completed `test_full` via repeated single STEPs (never RESUME), and even
  STEP only "took" roughly 1/3 of the time: Quartus's `altsyncram` BRAM
  (`fpga/dp_ram.v`) always registers its read address before the array read
  happens -- true same-cycle combinational reads are architecturally
  impossible there, regardless of IP wizard settings -- while both cores and
  `fpga/dp_ram_model.sv` (at its default `REGISTERED_ADDR=0`) assumed
  zero-latency reads. This is the same root cause `04_pipeline_plan.md` §4/§6
  already flagged as an open question for the pipelined core; this session's
  fix targets the frozen `riscv_core_single_cycle` golden model specifically
  (milestone 9, hardware bring-up), leaving the pipelined core's own
  per-stage IF/MEM latency fix as that still-open follow-up.
- Fix (approved design: a general req/vld-style synchronous memory
  interface, external to both cores, so a future cache/slower memory can
  extend it later without touching either core or the top-level wiring
  again):
  - New module `src/memory/mem_stall_ctrl.sv`: an FSM (`IDLE` ->
    `FETCH_WAIT` -> `DECODED` -> [`MEM_WAIT` if the decoded instruction is a
    load] -> `COMMIT` -> back to `IDLE`) that holds `core_halt` asserted
    until the fetched instruction (and, for loads, the loaded data) is
    actually valid, then drops it for exactly one cycle to let `pc`/regfile
    commit. Only `IDLE` samples the debug UART's `dbg_halt` request --
    critical, since `debug_uart`'s STEP only pulses `dbg_halt` low for a
    single clk cycle, not for as long as a full fetch-to-commit sequence
    actually takes; sampling `dbg_halt` in every state would re-park the FSM
    the cycle after STEP's pulse ends, before it ever reaches `COMMIT`, and
    `pc` would never advance on STEP at all.
  - Added `imem_rvalid`/`dmem_rvalid` registers next to the existing
    `bram_sel`/`uart_sel` decode logic in `fpga/riscv_top.sv` and
    `test/testbench/tb_top.sv` (`imem_rvalid <= 1'b1` unconditionally,
    `dmem_rvalid <= dmem_re`), feeding `mem_stall_ctrl`. This is the
    intended future extension point: swapping in a cache or larger/slower
    memory later only means changing how these two `rvalid` signals are
    generated -- `mem_stall_ctrl` and both cores stay untouched.
  - Wired `mem_stall_ctrl`'s `core_halt` into `.halt(core_halt & KEY[1])` on
    the `SINGLE_CYCLE` generate branch only, in both `riscv_top.sv` and
    `tb_top.sv`; the `PIPELINED` branch is unchanged (`halt & KEY[1]`) since
    whole-core-freeze doesn't map onto per-stage pipeline stalling (still
    needs the real fix from `04_pipeline_plan.md` §4/§6.1).
  - `riscv_core_single_cycle.sv` itself was NOT modified (it's the frozen
    golden reference `tb_diff.sv` differentially fuzzes against) -- both it
    and `riscv_core.sv` already exposed a `halt` input that freezes `pc` and
    gates the regfile write port without gating their combinational
    decode/ALU/address logic, which was sufficient to build the whole fix as
    an external wrapper with zero core RTL changes.
  - `test/testbench/tb_top.sv`'s `dp_ram_model` instantiation flipped
    `.REGISTERED_ADDR(0)` -> `.REGISTERED_ADDR(1)`, matching real BRAM's
    latency -- this is what makes the original bug reproducible (and the fix
    verifiable) in simulation, closing the gap that let it ship to hardware
    undetected in the first place.
  - Added `test_step_reliability` and `test_resume_correctness` to
    `test/testbench/test_top.py` as the regression tests for this exact bug
    (200 consecutive STEPs must each advance `pc` by exactly 4; a RESUME run
    must still converge to `test_full.asm`'s correct final register state).
  - Explicitly out of scope for this session (deferred at the user's
    request): reset synchronization/double-flopping, and `debug_uart`'s
    halt-on-reset default -- see below, this is exactly what tripped up
    verification.
- Environment note: got the full cocotb + Verilator regression suite
  actually running end-to-end inside the repo's own `.venv` for the first
  time (`test/testbench/test_top.py` via
  `make sim TOPLEVEL=tb_top MODULE=testbench.test_top CORE_TYPE=SINGLE_CYCLE
  CFG_LDLIBS_THREADS=-lpthread`, with a newer system GCC
  (`/pkg/qct/software/gnu64/gcc/11.2.0/bin`) and the RISC-V assembler
  (`/pkg/qct/software/gnu/riscv/riscv64-unknown-elf-gcc-10.2.0/bin`) added to
  `PATH` -- both pre-existing system toolchains, nothing installed). Had to
  fix a pip-installed-package misconfiguration to get there: the venv's
  `verilator` package's `verilated.mk` had `CFG_CXXFLAGS_PCH_I` (the compiler
  flag to consume a precompiled header, e.g. `-include` for GCC) left blank
  from whatever toolchain it was pip-built against, so the PCH filename was
  passed to `c++` as a bare positional argument instead of via `-include`.
  Fixed directly in `.venv/lib/python3.9/site-packages/verilator/include/
  verilated.mk` (`CFG_CXXFLAGS_PCH_I = -include`) -- editing inside the venv
  is fine, installing anything outside it is not.
- Ran the fixed suite under `CORE_TYPE=SINGLE_CYCLE`,
  `REGISTERED_ADDR=1`: `test_clock_divider` and `test_uart_mux` PASS,
  `test_resume_correctness` PASS (strong positive signal that
  `mem_stall_ctrl`'s core design is sound for the free-run/RESUME case), but
  `test_halt_override`, `test_single_cycle_core_smoke`, and
  `test_step_reliability` FAIL.
- Diagnosed the 3 failures with a throwaway cycle-by-cycle instrumented
  cocotb test (logging `halt`/`core_halt`/`mem_stall_ctrl.state`/`pc` every
  clk, not checked in) rather than guessing from the failure asserts alone.
  All three turned out to share one root cause, and it isn't
  `mem_stall_ctrl`: `debug_uart.sv`'s `halt` register resets *synchronously*
  (`always_ff @(posedge clk) if (rst) halt <= 1'b1; ...`), but `clk` itself
  is generated by a divider (`clk_div_toggle`) that is held frozen at 0 for
  as long as `rst` is asserted -- so `clk` never ticks during reset, meaning
  `debug_uart`'s synchronous reset block never actually fires. `halt` is left
  at whatever value simulation/hardware happens to power up with (0 in
  Verilator) instead of the intended halt-on-reset default, so the core free
  -runs from t=0 with no halt ever asserted. Confirmed via the instrumented
  run: `halt=0` from the very first `CLOCK_50` edge post-reset, well before
  any debug-UART command was ever sent. This explains all three failures
  without any bug in the new stall controller:
  - `test_step_reliability`: the program is already running freely before
    STEP is even sent, so `pc` jumps by far more than 4 per STEP.
  - `test_halt_override`/`test_single_cycle_core_smoke`: the core free-runs
    on its own straight into `test_basic.asm`'s trailing self-loop before the
    test ever checks anything, so `pc_before == pc_after` (or the smoke
    test's phase-index check) trivially "passes/fails" for reasons that have
    nothing to do with whether the `KEY[1]` override itself works.
  `mem_stall_ctrl` resets correctly regardless (it uses `posedge clk or
  posedge rst`, i.e. async reset), so this bug is entirely isolated to
  `debug_uart.sv`'s reset style interacting with the divided `clk`.
- This is precisely the "reset synchronization/double-flopping" and
  "`debug_uart` halt-on-reset default" topic the user asked to defer to a
  separate discussion -- confirmed here as a real, load-bearing bug (not a
  hypothetical), rather than fixed. **Not yet fixed. Next step once resumed:
  decide the fix (e.g. give `debug_uart`'s `halt` an async reset like
  `mem_stall_ctrl` already uses, or drive `debug_uart`'s reset off `clk50`
  instead of the divided `clk`) and re-run the full `test_top.py` suite under
  `CORE_TYPE=SINGLE_CYCLE`/`REGISTERED_ADDR=1` to confirm all 6 tests pass.**
- Still pending after that: hardware bring-up itself (flash
  `CORE_TYPE=SINGLE_CYCLE` with the stall controller, re-run the STEP-200/
  RESUME sequence on the real board), confirming `tb_diff.sv` is unaffected
  (expected no-op, doesn't route through `riscv_top`/`mem_stall_ctrl`), and
  a `README.md` update -- none of this done yet.

## req/vld memory handshake for the pipelined core

- Implemented per-port req/vld handshaking (`imem_req`/`imem_vld`,
  `dmem_req`/`dmem_vld`) directly on `riscv_core.sv`, generalizing the
  existing `id_stall`/`ex_flush` freeze+bubble mechanism to memory latency
  of any length via new `if_wait`/`mem_wait`/`front_stall` signals. Two
  correctness bugs caught by review before implementation (see
  `docs/04_pipeline_plan.md` §4): `mem_wait` must outrank `ex_flush` in the
  `if_id`/`id_ex` mux chains (else a branch held in `id_ex` during a MEM
  stall re-squashes `if_id` every stall cycle), and `MEM_WB_Reg` needed a
  net-new `mem_wait` bubble (it had zero gating before, and was latching
  invalid `ld_data` into the regfile write port during a stall).
- Wired through `fpga/riscv_top.sv` and `test/testbench/tb_top.sv`
  (PIPELINED branch only); zero-latency testbenches (`tb_core.sv`,
  `tb_diff.sv`, `tb_soc.sv`) tie the new ports to `1'b1`/unused.
- Regression: `test_full` (27/27), `test_diff` (7/7), `test_uart`,
  `test_debugger` all pass unchanged. `test_bootloader` fails, but
  confirmed via `git stash` to fail identically on unmodified `main` --
  pre-existing, unrelated.
- **Found a real bug, not yet fixed**, while running `test_top.py`
  against `tb_top` (which now defaults to `dp_ram_model`'s
  `REGISTERED_ADDR=1`, real BRAM timing): `imem_rvalid` in both
  `riscv_top.sv` and `tb_top.sv` is hardwired `<= 1'b1` every cycle -- a
  leftover from before `REGISTERED_ADDR` was flipped to 1, when that was
  actually true. It doesn't track the real one-cycle address-register
  latency the way `dmem_rvalid <= dmem_req` correctly does, so both cores
  get fed stale `imem_rdata` on effectively every fetch. Confirmed it's
  this shared wiring bug and not core-specific logic: `test_top.py` fails
  the same way for both `CORE_TYPE=PIPELINED` and `CORE_TYPE=SINGLE_CYCLE`.
  Full detail and why the obvious fix isn't a drop-in (breaks
  `SINGLE_CYCLE`'s `mem_stall_ctrl` path) is in
  `docs/04_pipeline_plan.md` §6.2. **Next step: fix `imem_rvalid`, confirm
  `test_top.py` passes for both core types, then write the
  PIPELINED-specific req/vld tests (load-then-branch stall sequence,
  target the two review-caught bug classes directly) and re-run the full
  suite once more before calling this done.**

27 Jul 2026 (later)
- Small, unrelated tooling additions to the debug terminal while the
  `imem_rvalid` fix above is still pending -- no RTL touched:
  - `tools/reg_debugger.py`/`reg_debugger_shell.py`: added a `hexdump
    <addr> <n>` command (CLI subcommand and shell command) that issues n
    sequential `READ_MEM` round-trips starting at `addr` and prints them
    4-words-per-line, address-labeled. There's no burst-read in the wire
    protocol (`debug_uart.sv`), so this is just a client-side loop over
    the existing single-word `READ_MEM` -- no protocol change.
  - Fixed a real shell bug in `do_step` (`reg_debugger_shell.py`): it
    called `int(arg)` *before* entering the `self._guard(...)` try/except,
    so a bad argument (e.g. `step 30n`) raised an uncaught `ValueError`
    instead of printing a clean `[ERROR]`. Moved the parse inside the
    guarded closure and switched to `int(arg, 0)` so hex step counts
    (`step 0x1e`) also work, matching every other command's addr/data
    parsing convention in this file.
  - Verified both via `--dry-run` (no hardware needed): `hexdump`
    produces correctly-addressed 4-per-line output on both the CLI and
    shell entry points; `step 30n` now errors cleanly, `step 0x5` and
    `step 3` both step correctly.
