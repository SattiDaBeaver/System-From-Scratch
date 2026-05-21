# Basic setup

async def reset(dut, cycles=5):
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

async def run_cycles(dut, n):
    for _ in range(n):
        await RisingEdge(dut.clk)

def load_imem(dut, words):
    for i, word in enumerate(words):
        dut.imem.mem[i].value = word  # depends on your mem model

# Helpers

async def reset(dut, cycles=5):
    dut.rst.value = 1
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

async def run_cycles(dut, n):
    for _ in range(n):
        await RisingEdge(dut.clk)

def load_imem(dut, words):
    for i, word in enumerate(words):
        dut.imem.mem[i].value = word  # depends on your mem model