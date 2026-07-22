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
