# tests/utils.py

import subprocess
import struct
import os
from cocotb.triggers import RisingEdge


# *****************************
#  Clock
# *****************************

async def generate_clock(dut, half_period_ns=5):
    """10ns clock by default (100MHz)"""
    from cocotb.triggers import Timer
    while True:
        dut.clk.value = 0
        await Timer(half_period_ns, units="ns")
        dut.clk.value = 1
        await Timer(half_period_ns, units="ns")


# *****************************
#  Reset
# *****************************

async def reset(dut, cycles=5):
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0


# *****************************
#  Run
# *****************************

async def run_cycles(dut, n):
    for _ in range(n):
        await RisingEdge(dut.clk)


# *****************************
#  Memory
# *****************************

def load_imem(dut, words):
    """Load a list of 32-bit integers into instruction memory"""
    for i, word in enumerate(words):
        dut.imem[i].value = word


def load_dmem(dut, words, start=0):
    """Load a list of 32-bit integers into data memory from start index"""
    for i, word in enumerate(words):
        dut.dmem[start + i].value = word


def read_reg(dut, reg, core="u_core"):
    """Read a register from the internal regfile. `core` selects which
    core instance to read from -- tb_diff.sv instantiates two
    (u_core = DUT, u_core_ref = golden single-cycle model), every other
    testbench only has u_core (the default)."""
    return getattr(dut, core).regfile[reg].value.integer


def read_dmem(dut, addr_word, mem="dmem"):
    """Read one word from a testbench's dmem array by word index. `mem`
    selects which array -- tb_diff.sv has dmem (DUT) and dmem_ref
    (golden model)."""
    return getattr(dut, mem)[addr_word].value.integer


# *****************************
#  Convergence (differential testing)
# *****************************

async def await_pc_convergence(dut, pc_signal, stable_cycles=5, timeout_cycles=10000, period=1):
    """Waits until `pc_signal` (e.g. dut.pc_dbg) has settled into a
    repeating pattern of length `period`, held for `stable_cycles`
    consecutive repetitions, then returns the smallest value in that
    pattern (the loop label's own pc).

    Every test program ends in a self-loop (`loop: jal x0 loop`). On the
    single-cycle core (period=1, the default) the jump resolves the same
    cycle it's fetched, so pc simply stops changing. On the pipelined core
    there's a fixed IF->EX delay (2 register stages: IF/ID then ID/EX)
    before the jump's redirect lands, so pc optimistically fetches pc+4,
    pc+8 before snapping back -- a period-3 cycle (P, P+4, P+8, P, ...)
    that never goes exactly static, even once flush logic (milestone 3)
    is added, since flush only squashes the wrong-path *instructions*, not
    the fixed resolution latency itself. Callers on the pipelined DUT
    should pass period=3 (or more generally, IF-to-EX register stages + 1).

    Raises TimeoutError if the core never settles (e.g. a genuine hang),
    so a broken pipeline fails loudly instead of hanging the test suite.
    """
    history = []
    window_len = period * stable_cycles
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        history.append(pc_signal.value.integer)
        if len(history) >= window_len:
            window = history[-window_len:]
            if all(window[i] == window[i - period] for i in range(period, window_len)):
                return min(window[-period:])
    raise TimeoutError(
        f"pc never converged after {timeout_cycles} cycles "
        f"(last value: 0x{history[-1]:08x})"
    )


# *****************************
#  Assembler
# *****************************

ASM_DIR = os.path.join(os.path.dirname(__file__), "asm_programs")
BOOTLOADER_DIR = os.path.join(os.path.dirname(__file__), "..", "src", "bootloader")

def assemble(filename, search_dir=ASM_DIR):
    """
    Assemble a .asm file and return a list of 32-bit instruction words.
    filename: just the name, e.g. "add_test.asm"
    search_dir: directory to look in (defaults to test/asm_programs/)
    """
    src  = os.path.join(search_dir, filename)
    obj  = "/tmp/rv_test.o"
    binary = "/tmp/rv_test.bin"

    # Assemble
    subprocess.run([
        "riscv64-unknown-elf-as",
        "-march=rv32i", "-mabi=ilp32",
        src, "-o", obj
    ], check=True)

    # Strip to raw binary
    subprocess.run([
        "riscv64-unknown-elf-objcopy",
        "-O", "binary", obj, binary
    ], check=True)

    # Read and pack into 32-bit words
    with open(binary, "rb") as f:
        raw = f.read()

    # Pad to word boundary
    while len(raw) % 4 != 0:
        raw += b'\x00'

    words = list(struct.unpack(f"<{len(raw)//4}I", raw))
    return words


def assemble_source(src_text):
    """Same as assemble(), but takes assembly source text directly instead
    of a filename -- used by the fuzz generator (milestone 8), which
    builds programs in memory rather than from a checked-in .asm file."""
    src_path = "/tmp/rv_fuzz.s"
    with open(src_path, "w") as f:
        f.write(src_text)
    return assemble(os.path.basename(src_path), search_dir=os.path.dirname(src_path))


# *****************************
#  Fuzz program generator (milestone 8)
# *****************************

def generate_fuzz_program(rng, n_instr=40, n_regs=10, dmem_words=16):
    """Generate a random RV32I assembly program (as source text) that is
    guaranteed to terminate in a trailing self-loop, for the differential
    fuzz pass (docs/04_pipeline_plan.md Sec.7 milestone 8).

    Directed tests (test_pipeline_stall.asm etc.) each isolate one hazard
    shape deliberately; a fuzz pass instead throws random combinations at
    the harness to catch interactions those didn't think to construct --
    e.g. a stall immediately followed by a flush. `rng` is an already-
    seeded random.Random, so a failing run is reproducible from its seed.

    Every branch/jump is forward-only (target = current index + 1 + a
    random small skip, clamped to the trailing loop) -- this guarantees
    the program always terminates in the loop (no accidental backward
    branch could turn into a second, non-loop cycle that never
    converges), while still exercising flush on both taken and
    not-taken outcomes. Registers are drawn from a small pool (x1-x10)
    so random reuse naturally creates RAW hazards (including load-use)
    at a range of distances without needing to force it by hand; rd of a
    freshly-written instruction is also deliberately reused as an
    operand of the next instruction with 40% probability to guarantee at
    least some distance-0 hazards show up even in unlucky draws.
    """
    write_regs = list(range(1, n_regs + 1))

    def read_reg(prev_rd):
        if prev_rd is not None and rng.random() < 0.4:
            return prev_rd
        if rng.random() < 0.15:
            return 0
        return rng.choice(write_regs)

    alu_r = ["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"]
    alu_i = ["addi", "andi", "ori", "xori"]
    shift_i = ["slli", "srli", "srai"]

    filler = []  # list of (text, rd_or_None)
    prev_rd = None
    for _ in range(n_instr):
        kind = rng.choice(["alu_r", "alu_i", "shift_i", "lui", "auipc", "sw", "lw"])
        rd = rng.choice(write_regs)
        if kind == "alu_r":
            rs1 = read_reg(prev_rd)
            rs2 = read_reg(prev_rd)
            op = rng.choice(alu_r)
            filler.append((f"    {op} x{rd}, x{rs1}, x{rs2}", rd))
        elif kind == "alu_i":
            rs1 = read_reg(prev_rd)
            imm = rng.randint(-2048, 2047)
            op = rng.choice(alu_i)
            filler.append((f"    {op} x{rd}, x{rs1}, {imm}", rd))
        elif kind == "shift_i":
            rs1 = read_reg(prev_rd)
            shamt = rng.randint(0, 31)
            op = rng.choice(shift_i)
            filler.append((f"    {op} x{rd}, x{rs1}, {shamt}", rd))
        elif kind == "lui":
            imm = rng.randint(0, 0xFFFFF)
            filler.append((f"    lui x{rd}, {imm}", rd))
        elif kind == "auipc":
            imm = rng.randint(0, 0xFFFFF)
            filler.append((f"    auipc x{rd}, {imm}", rd))
        elif kind == "sw":
            rs2 = read_reg(prev_rd)
            off = rng.randrange(0, dmem_words) * 4
            filler.append((f"    sw x{rs2}, {off}(x0)", None))
        else:  # lw
            off = rng.randrange(0, dmem_words) * 4
            filler.append((f"    lw x{rd}, {off}(x0)", rd))
        prev_rd = filler[-1][1]

    # Second pass: convert a random subset of filler slots into forward
    # branches/jumps. target_of[i] = index of the instruction the branch
    # at i jumps to (i+1+skip, clamped to n_instr which means "loop").
    branch_ops = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
    target_of = {}
    n_branches = max(1, n_instr // 6)
    for i in rng.sample(range(n_instr), min(n_branches, n_instr)):
        skip = rng.randint(1, 3)
        target_of[i] = min(i + 1 + skip, n_instr)

    labels_needed = {t for t in target_of.values() if t < n_instr}
    label_name = {t: f"Lf{t}" for t in labels_needed}

    lines = [".section .text", ".globl _start", "_start:"]
    prev_rd = None
    for i in range(n_instr):
        if i in label_name:
            lines.append(f"{label_name[i]}:")
        if i in target_of:
            target = target_of[i]
            dest = "loop" if target == n_instr else label_name[target]
            rs1 = read_reg(prev_rd)
            rs2 = read_reg(prev_rd)
            op = rng.choice(branch_ops)
            lines.append(f"    {op} x{rs1}, x{rs2}, {dest}")
            prev_rd = None
        else:
            text, rd = filler[i]
            lines.append(text)
            prev_rd = rd
    lines.append("loop:")
    lines.append("    jal x0, loop")
    return "\n".join(lines) + "\n"