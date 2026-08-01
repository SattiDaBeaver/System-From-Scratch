# tests/testbench/test_diff.py
#
# Differential test: runs the same program against the core under active
# development (dut.u_core, riscv_core.sv -- currently still single-cycle,
# becomes the pipeline as that work lands) and the frozen golden model
# (dut.u_core_ref, riscv_core_single_cycle.sv), then diffs regfile + dmem
# once both have independently converged (parked on their own `loop: jal x0
# loop`). See docs/04_pipeline_plan.md Sec.7 milestone 1.
#
# Right now riscv_core.sv IS riscv_core_single_cycle.sv (pipeline work
# hasn't started), so this is a sanity check of the harness itself -- a
# trivial pass proves the comparison mechanics (convergence detection,
# regfile/dmem diffing) are correct before there's a real pipeline to
# compare against.

import cocotb
from cocotb.clock import Clock
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from utils import (
    reset, load_imem, read_reg, read_dmem, read_csr, await_pc_convergence, assemble,
    assemble_source, generate_fuzz_program,
)
from cocotb.triggers import RisingEdge
import random

DMEM_CHECK_WORDS = 16  # touched-region diff window; test programs stay well within this
CSR_NAMES = ("mstatus", "mie", "mtvec", "mscratch", "mepc", "mcause", "mtval", "mip")


def _clear_regfiles(dut):
    """regfile has no reset logic (only pc/pipeline regs do) -- multiple
    @cocotb.test() functions run sequentially against the same simulated
    instance, so a prior test's register values would otherwise leak into
    the next one. Zero both cores' regfiles before loading a new program.

    Also zero the full imem/dmem arrays (not just the touched-region
    dmem window): without flush logic (milestone 3), the pipelined DUT's
    unresolved-jump pc bounce (see await_pc_convergence's period=3 note)
    transiently fetches a couple words past the loop label. If a shorter
    program overwrites only its own instruction count, those leftover
    words from a longer previous test's imem would still be stale
    non-nop instructions there, and their transient (uncommitted-by-
    design-only-because-of-flush) side effects would actually commit."""
    IMEM_DEPTH = 256
    for i in range(32):
        dut.u_core.regfile[i].value = 0
        dut.u_core_ref.regfile[i].value = 0
    for i in range(IMEM_DEPTH):
        dut.imem[i].value = 0
        dut.imem_ref[i].value = 0
        dut.dmem[i].value = 0
        dut.dmem_ref[i].value = 0
    for name in CSR_NAMES:
        getattr(dut.u_core, f"csr_{name}").value = 0
        getattr(dut.u_core_ref, f"csr_{name}").value = 0


@cocotb.test()
async def diff_test_full(dut):
    """Runs test_full.asm (27-instruction RV32I coverage program) against
    both cores and requires identical regfile[0:31] + dmem[0:16) end-state.

    Was expect_fail=True through milestones 2-3 (mid-program JAL/JALR
    corrupted state with no flush, then back-to-back dependent
    instructions read stale values with no stall) -- now passes for real
    with milestone 4's RAW-hazard stall detection in place."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_full.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_pipeline_straight(dut):
    """Milestone 2 sanity check: straight-line, no-dependency, no-branch
    program (test_pipeline_straight.asm) through the differential harness.
    Confirms the newly-added if_id/id_ex/ex_mem/mem_wb pipeline registers
    (no stall/flush logic yet) produce the same architectural end-state as
    the frozen single-cycle golden model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_pipeline_straight.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_pipeline_stall(dut):
    """Milestone 4 sanity check: test_pipeline_stall.asm packs in
    back-to-back (distance-0) RAW dependencies -- including an rs1==rs2
    double-hazard, a branch whose compare operands are both hazards, and
    a store/load/use chain covering load-use -- with no gaps at all.
    Requires the stall-only v1 hazard-detect logic to hold if_id/pc and
    bubble id_ex until each write commits; a broken/missing stall would
    silently read stale regfile values and diverge from the golden model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_pipeline_stall.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_pipeline_load_use(dut):
    """Milestone 5 sanity check: docs/04_pipeline_plan.md Sec.3/Sec.7
    milestone 5 claims the generic RAW-stall mechanism added in milestone
    4 already covers load-use hazards with no special-case RTL, since a
    load's result isn't available until mem_wb, same timing as any ALU
    result. test_pipeline_load_use.asm exists to confirm that claim rather
    than assume it -- immediate lw-then-use as rs1, as rs2, as both rs1
    and rs2 of the same instruction, and a load whose own address depends
    on a preceding load's result."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_pipeline_load_use.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_pipeline_reset_midrun(dut):
    """Milestone 6 sanity check: docs/04_pipeline_plan.md Sec.5/Sec.7
    milestone 6 -- assert reset mid-run (mid-program, with several
    instructions already in flight across if_id/id_ex/ex_mem/mem_wb) and
    confirm two things: (1) no bogus register write commits during the
    cycles reset is held, since every pipeline register's valid bit
    (including mem_wb_valid, which gates the regfile write port) resets
    to 0 the same synchronous edge as pc -- there's no combinational path
    that could let an in-flight instruction's result sneak into the
    regfile after rst goes high; and (2) after reset is released, the
    core resumes from pc=0 exactly as a fresh run would, since resetting
    both DUT and golden model at the identical mid-run point and letting
    both reconverge should reproduce the same final architectural state
    as an uninterrupted run of the same program."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_pipeline_stall.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    # Let both cores run partway into the program -- enough cycles that
    # several instructions are in flight across the pipeline stages when
    # we yank reset, but well before either converges on its own loop.
    MIDRUN_CYCLES = 15
    for _ in range(MIDRUN_CYCLES):
        await RisingEdge(dut.clk)

    pre_reset_regs = [read_reg(dut, r, core="u_core") for r in range(32)]

    # Assert reset mid-run on both cores simultaneously.
    RESET_HOLD_CYCLES = 4
    dut.rst.value = 1
    for _ in range(RESET_HOLD_CYCLES):
        await RisingEdge(dut.clk)
        mid_reset_regs = [read_reg(dut, r, core="u_core") for r in range(32)]
        assert mid_reset_regs == pre_reset_regs, (
            f"regfile changed while reset was held: before={pre_reset_regs} "
            f"during={mid_reset_regs}"
        )
    dut.rst.value = 0

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


FUZZ_SEED_BASE = 20260724  # fixed base -- keeps the whole run reproducible; a
                            # failure's exact seed is logged so it can be
                            # replayed standalone (see the assert message below)
FUZZ_RUNS = 100


@cocotb.test()
async def diff_test_pipeline_fuzz(dut):
    """Milestone 8 sanity check: docs/04_pipeline_plan.md Sec.7 milestone 8
    -- hand-written directed tests (milestones 2-6) each isolate one
    hazard shape deliberately; they can't be expected to also cover every
    hazard *interaction* corner case (e.g. a stall immediately followed by
    a flush, or a branch whose own compare operands are still stalling).
    Runs FUZZ_RUNS randomly generated RV32I programs (utils.
    generate_fuzz_program) through the differential harness in bulk --
    each forward-branches-only by construction so it's guaranteed to
    terminate in its own trailing self-loop, but otherwise draws
    instruction kind/operands/branch targets uniformly at random, with
    register reuse biased just enough to reliably create RAW hazards
    (including load-use) at a range of distances without forcing any
    specific shape by hand.

    Every run uses a fixed, logged seed (FUZZ_SEED_BASE + run index) --
    a failure prints its exact seed so the offending program can be
    regenerated and replayed standalone for debugging, rather than being
    a one-off unreproducible random failure."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    for run in range(FUZZ_RUNS):
        seed = FUZZ_SEED_BASE + run
        rng = random.Random(seed)
        src = generate_fuzz_program(rng)

        _clear_regfiles(dut)
        words = assemble_source(src)
        load_imem(dut, words)
        for i, word in enumerate(words):
            dut.imem_ref[i].value = word

        await reset(dut)

        dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
        ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

        mismatches = []
        for reg in range(0, 32):
            dut_val = read_reg(dut, reg, core="u_core")
            ref_val = read_reg(dut, reg, core="u_core_ref")
            if dut_val != ref_val:
                mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

        for word in range(DMEM_CHECK_WORDS):
            dut_val = read_dmem(dut, word, mem="dmem")
            ref_val = read_dmem(dut, word, mem="dmem_ref")
            if dut_val != ref_val:
                mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

        assert not mismatches, (
            f"Differential mismatch on fuzz run {run} (seed={seed}, "
            f"dut_pc=0x{dut_pc:08x}, ref_pc=0x{ref_pc:08x}):\n"
            + "\n".join(mismatches) + f"\n\nprogram:\n{src}"
        )

    cocotb.log.info(f"Differential fuzz pass: {FUZZ_RUNS}/{FUZZ_RUNS} runs matched golden model")


@cocotb.test()
async def diff_test_subword(dut):
    """Stage-4 sub-word access sanity check: test_diff_subword.asm exercises
    LB/LH/LBU/LHU/SB/SH through both cores. Unlike test_subword.py (which
    checks a handful of hand-picked expected values), this diffs the full
    regfile + dmem window against the golden single-cycle model, so a
    byte-enable bug that corrupts a neighboring byte would show up as a
    raw dmem mismatch even if it happened not to trip test_subword.py's
    specific checks."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_diff_subword.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_pipeline_flush(dut):
    """Milestone 3 sanity check: test_pipeline_flush.asm exercises jal,
    jalr, and both branch directions with no RAW dependencies between any
    two instructions (isolating flush correctness from milestone 4's
    stall behavior). Every post-jump/branch instruction that should be
    squashed writes a recognizable sentinel (99) to a register that no
    other instruction touches, so any flush bug leaves detectable
    contamination in the diffed regfile."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_pipeline_flush.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)

@cocotb.test()
async def diff_test_csr(dut):
    """Zicsr sanity check: test_diff_csr.asm exercises all 6 CSRR*/CSRR*I
    variants (CSRRW/S/C register forms and CSRRWI/SI/CI immediate forms)
    against mscratch/mtvec/mepc/mie with no RAW dependencies between CSR
    ops (each op's rd is a fresh register), isolating CSR read-modify-
    write correctness from any hazard-detection concerns. Diffs regfile
    + dmem as usual, plus all 8 R/W CSRs -- a bug in the new decode/
    storage logic (e.g. zimm vs sign-extended imm confusion, or the
    read-old-value/write-new-value ordering) would show up as a regfile
    or CSR mismatch even if dmem is untouched by this program."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_diff_csr.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for name in CSR_NAMES:
        dut_val = read_csr(dut, name, core="u_core")
        ref_val = read_csr(dut, name, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"csr_{name}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_trap(dut):
    """ECALL/EBREAK/MRET coverage: test_diff_trap.asm round-trips through
    mtvec_setup, an ecall and an ebreak (each resolved in EX like a known
    jump -- see riscv_core.sv's ex_flush/next_pc), and a shared mret
    handler. Diffs regfile + CSR state (mepc/mcause included) against the
    golden single-cycle model -- this is what actually exercises the
    pipelined core's 2-stage flush/redirect timing against a reference
    that has none of that latency, unlike test_trap.py's hand-derived
    single-cycle-only check."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_diff_trap.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for name in CSR_NAMES:
        dut_val = read_csr(dut, name, core="u_core")
        ref_val = read_csr(dut, name, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"csr_{name}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)


@cocotb.test()
async def diff_test_mul(dut):
    """RV32M sanity check: test_diff_mul.asm exercises all 4 multiply
    variants (MUL, MULH, MULHSU, MULHU) with no RAW dependencies between
    ops (each op's rd is a fresh register), isolating multiply-decode/
    compute correctness from any hazard-detection concerns. Diffs regfile
    + dmem against the golden single-cycle model -- a bug in the widened
    dec_bits disambiguation (funct7 aliasing with base R-type ops) or the
    EX-stage product computation would show up as a regfile mismatch."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    _clear_regfiles(dut)
    words = assemble("test_diff_mul.asm")
    load_imem(dut, words)          # DUT imem
    for i, word in enumerate(words):
        dut.imem_ref[i].value = word

    await reset(dut)

    dut_pc = await await_pc_convergence(dut, dut.pc_dbg, period=3)
    ref_pc = await await_pc_convergence(dut, dut.pc_dbg_ref)

    cocotb.log.info(f"DUT converged at pc=0x{dut_pc:08x}, ref converged at pc=0x{ref_pc:08x}")

    mismatches = []
    for reg in range(0, 32):
        dut_val = read_reg(dut, reg, core="u_core")
        ref_val = read_reg(dut, reg, core="u_core_ref")
        if dut_val != ref_val:
            mismatches.append(f"x{reg}: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    for word in range(DMEM_CHECK_WORDS):
        dut_val = read_dmem(dut, word, mem="dmem")
        ref_val = read_dmem(dut, word, mem="dmem_ref")
        if dut_val != ref_val:
            mismatches.append(f"dmem[{word}]: dut=0x{dut_val:08x} ref=0x{ref_val:08x}")

    assert not mismatches, "Differential mismatch:\n" + "\n".join(mismatches)
