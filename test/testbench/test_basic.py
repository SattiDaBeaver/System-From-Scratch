@cocotb.test()
async def test_add(dut):
    # assemble inline or load from .S file
    program = assemble("add_test.S")
    load_imem(dut, program)
    
    await reset(dut)
    await run_cycles(dut, 50)
    
    assert dut.regfile[1].value == 0x42