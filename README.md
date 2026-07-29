# System-From-Scratch
Building a 32-bit RISCV CPU, with a custom OS, all from scratch.

## Testing

Tests live in `test/` and use [cocotb](https://www.cocotb.org/) with Verilator as the simulator backend.

### Setup

```bash
# System dependencies
sudo apt install -y verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf

# Python dependencies (in venv)
python3 -m venv .venv
source .venv/bin/activate
pip install cocotb cocotb-test pytest
```

### Running Tests

```bash
cd test/
source ../.venv/bin/activate

make                                      # run default test module
make MODULE=testbench.test_basic          # run specific module
make clean                                # clean sim artifacts
```

### Structure

    test/
    ├── asm_programs/       # assembly programs loaded into simulated memory
    ├── testbench/          # cocotb test files + tb_core.sv memory wrapper
    ├── utils.py            # shared helpers (reset, load_imem, assemble, read_reg)
    └── Makefile

### Test Results

Results are appended to `log/test_results.log` after every run. Waveforms are
dumped as `.fst` files in `test/sim_build/` and can be viewed with the Surfer
extension in VSCode.

### Current Tests

| Module | Description |
|---|---|
| `testbench.test_basic` | Basic addi/add sanity check |
| `testbench.test_full` | Full RV32I coverage: all 27 checks, x5-x30 == 1 |

> Note: the hardware register debugger (`tools/reg_debugger.py` and `tools/reg_debugger_shell.py`) can be used to verify `testbench.test_full`. Continuous run via `resume` is unreliable in this setup and can make `test_full` fail, due to synchronous memory read behavior in the debugger path. The failure is not simply from batching `step` commands; it is tied to the sync read timing, so update debugger usage and tests accordingly.

# Notes for future improvement

- All inferred RAM must be synchronous read, not asynchronous. (quartus will otherwise use distributed RAM to infer async/comb read, bram is sync read only unless small (eg. regfile))
- The VGA frame buffer must instantiate vga.sv. That's why it was put there.
- The VGA frame buffer MUST take a clk divider param to divide the clock by based on input clock signal.
- VGA frame buffer should use the 50 MHz clock provided.
- In practice, the framebuffer should be written in a BRAM-friendly style: use synchronous reads and writes, and avoid combinational read muxing that prevents clean inference.
- If a divided clock is needed for display timing, keep the CPU/core side on the normal clock unless there is a clear reason to cross clock domains.
- If clock-domain crossing becomes necessary, prefer a cleaner architecture over ad hoc hand-rolled CDC: use a single-clock design where possible, or use explicit, well-defined CDC structures (for example, synchronizers or FIFOs) instead of relying on fragile timing assumptions.
- If Quartus does not infer block RAM reliably from the RTL, the framebuffer should use a dedicated, explicit RAM implementation rather than depending on inference heuristics.
- A better approach is to move the framebuffer storage into a separate RAM module (for example, a small inferred dual-port or single-port RAM block) and keep the framebuffer logic around it, since this is a cleaner pattern for Quartus inference.
- As a reference for this style of peripheral design, see src/peripherals/vga_spi.sv for an example of how to structure VGA-related logic around a more self-contained module.
- The framebuffer peripheral should remain self-contained and not depend on the main system BRAM for its storage unless that is an intentional architectural choice.