# tests/Makefile
.DEFAULT_GOAL := run

SIM              	?= verilator
TOPLEVEL_LANG		= verilog

VERILOG_SOURCES   = $(PWD)/../src/riscv_core/riscv_core.sv
VERILOG_SOURCES  += $(PWD)/testbench/tb_core.sv

TOPLEVEL          	= tb_core
MODULE           	?= testbench.test_full

EXTRA_ARGS       	+= --trace-fst
EXTRA_ARGS       	+= --trace-structs
EXTRA_ARGS       	+= -Wno-fatal
EXTRA_ARGS 			+= --sv
COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ns
VERILATOR_TRACE = 1

LOG_FILE = ../log/test_results.log

export PYTHONPATH := $(PWD):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

run:
	-$(MAKE) sim
	$(MAKE) post-sim

post-sim:
	@TOTAL=$$(grep -c '<testcase ' results.xml); \
	FAIL=$$(grep -c '<failure' results.xml); \
	PASS=$$((TOTAL - FAIL)); \
	echo "[$(shell date '+%Y-%m-%d %H:%M')] $(MODULE) - $$TOTAL total, $$PASS passed, $$FAIL failed" >> $(LOG_FILE)

clean::
	rm -rf sim_build __pycache__ results.xml *.fst