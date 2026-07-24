# tests/Makefile
.DEFAULT_GOAL := run

SIM              	?= verilator
TOPLEVEL_LANG		= verilog

VERILOG_SOURCES     = $(PWD)/../src/riscv_core/riscv_core.sv
VERILOG_SOURCES     += $(PWD)/../src/peripherals/uart.sv
VERILOG_SOURCES     += $(PWD)/../src/peripherals/debug_uart.sv
VERILOG_SOURCES     += $(PWD)/testbench/tb_core.sv
VERILOG_SOURCES     += $(PWD)/testbench/tb_soc.sv
VERILOG_SOURCES     += $(PWD)/testbench/tb_uart.sv
VERILOG_SOURCES     += $(PWD)/../fpga/hex_display.v
VERILOG_SOURCES     += $(PWD)/../fpga/dp_ram_model.v
VERILOG_SOURCES     += $(PWD)/testbench/tb_top.sv

TOPLEVEL          	?= tb_core
MODULE           	?= testbench.test_full

EXTRA_ARGS       	+= --trace-fst
EXTRA_ARGS       	+= --trace-structs
EXTRA_ARGS       	+= -Wno-fatal
EXTRA_ARGS 			+= --sv
COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ns
VERILATOR_TRACE = 1

LOG_FILE = ../log/test_results.log
ELAPSED ?= 0

export PYTHONPATH := $(PWD):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

run:
	@START=$$(date +%s); \
	$(MAKE) sim || true; \
	END=$$(date +%s); \
	$(MAKE) post-sim ELAPSED=$$((END - START))

post-sim:
	@TOTAL=$$(grep -c '<testcase ' results.xml); \
	FAIL=$$(grep -c '<failure' results.xml); \
	PASS=$$((TOTAL - FAIL)); \
	SECS=$(ELAPSED); \
	ELAPSED_FMT=$$(printf '%dm%02ds' $$((SECS/60)) $$((SECS%60))); \
	echo "[$(shell date '+%Y-%m-%d %H:%M')] $(MODULE) - $$TOTAL total, $$PASS passed, $$FAIL failed, elapsed $$ELAPSED_FMT ($${SECS}s)" >> $(LOG_FILE)

clean::
	rm -rf sim_build __pycache__ results.xml *.fst