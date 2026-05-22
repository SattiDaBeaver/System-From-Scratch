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
| `testbench.test_full` | Full RV32I coverage — all 27 checks, x5-x30 == 1 |