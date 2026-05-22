# tests/Makefile

SIM              	?= verilator
TOPLEVEL_LANG		= verilog

VERILOG_SOURCES   = $(PWD)/../src/riscv_core/riscv_core.sv
VERILOG_SOURCES  += $(PWD)/testbench/tb_core.sv

TOPLEVEL          	= tb_core
MODULE           	?= testbench.test_basic

EXTRA_ARGS       	+= --trace-fst
EXTRA_ARGS       	+= --trace-structs
EXTRA_ARGS       	+= -Wno-fatal
EXTRA_ARGS 			+= --sv
COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ns
VERILATOR_TRACE = 1

export PYTHONPATH := $(PWD):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build __pycache__ results.xml *.fst