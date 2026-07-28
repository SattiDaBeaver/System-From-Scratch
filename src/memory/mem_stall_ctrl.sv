// src/memory/mem_stall_ctrl.sv
//
// Forces the core to halt for as many cycles as the memory subsystem's
// registered-address read latency actually takes, instead of the core's
// zero-latency-read assumption (imem_addr driven and imem_rdata consumed
// combinationally the same cycle). Real BRAM (fpga/dp_ram.v, Quartus
// altsyncram) always registers its read address before the array read
// happens -- true same-cycle combinational read is not achievable there,
// regardless of IP wizard settings -- so this sits between the debug UART's
// halt request and the core's halt input, holding halt asserted until the
// fetched instruction (and, for loads, the loaded data) is actually valid.
//
// Halt is the only lever available without touching either core's RTL:
// both riscv_core and riscv_core_single_cycle only gate pc/regfile updates
// on halt, and their combinational decode/ALU/address logic runs every
// cycle regardless -- so holding halt keeps pc/dmem_addr/dmem_we stable
// while imem_rvalid/dmem_rvalid (see riscv_top.sv/tb_top.sv) catch up, then
// drops halt for exactly one cycle to let pc/regfile commit.
//
// Only IDLE samples dbg_halt. debug_uart's STEP command only pulses
// dbg_halt low for a single clk cycle (STEP_ASSERT/STEP_DEASSERT), not for
// as long as this sequence actually takes -- so once a fetch is under way
// (FETCH_WAIT/DECODED/MEM_WAIT), it always runs to completion regardless of
// dbg_halt's value in later cycles. Sampling dbg_halt every state instead
// would re-park the FSM back at IDLE the cycle after STEP's pulse ends,
// before it ever reaches COMMIT -- pc would never advance on STEP at all.
//
// Only guarantees correctness for CORE_TYPE=SINGLE_CYCLE -- freezing the
// whole core doesn't map onto a pipeline's per-stage stalling, which needs
// the real IF/MEM latency fix already scoped in docs/04_pipeline_plan.md
// §4/§6.1 (5- vs 6-stage).
module mem_stall_ctrl (
    input  logic clk,
    input  logic rst,

    input  logic dbg_halt,       // debug UART's halt/step/resume request
    input  logic imem_rvalid,
    input  logic dmem_re,        // this cycle's decoded instruction is a load
    input  logic dmem_rvalid,

    output logic core_halt
);

    typedef enum logic [2:0] {
        IDLE,
        FETCH_WAIT,
        DECODED,
        MEM_WAIT,
        COMMIT
    } state_t;

    state_t state;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
        end
        else begin
            case (state)
                IDLE:       state <= dbg_halt ? IDLE : FETCH_WAIT;
                FETCH_WAIT: if (imem_rvalid) state <= DECODED;
                DECODED:    state <= dmem_re ? MEM_WAIT : COMMIT;
                MEM_WAIT:   if (dmem_rvalid) state <= COMMIT;
                COMMIT:     state <= IDLE;
                default:    state <= IDLE;
            endcase
        end
    end

    assign core_halt = (state != COMMIT);

endmodule
