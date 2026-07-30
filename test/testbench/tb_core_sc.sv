// tests/testbench/tb_core_sc.sv
//
// Single-cycle-core-only counterpart to tb_core.sv (which wraps the
// pipelined riscv_core). Dedicated so byte/halfword sub-word access work
// can land on riscv_core_single_cycle.sv's new dmem_byteena port without
// touching tb_core.sv / test_full.py's existing pipelined-core coverage.

module tb_core_sc #(
    parameter IMEM_DEPTH = 256,   // 256 x 4 bytes = 1KB
    parameter DMEM_DEPTH = 256    // 256 x 4 bytes = 1KB
) (
    input  logic        clk,
    input  logic        rst
);

    // Memory arrays
    logic [31:0] imem [0:IMEM_DEPTH-1];
    logic [31:0] dmem [0:DMEM_DEPTH-1];

    // Core interface wires
    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_wdata;
    logic        dmem_we;
    logic [3:0]  dmem_byteena;
    logic        dmem_re;
    logic [31:0] ld_data;
    logic [4:0]  dbg_reg_addr;
    logic [31:0] dbg_reg_data;
    logic [31:0] pc_dbg;

    // Instantiate core
    riscv_core_single_cycle #(
        .ISA("RV32I")
    ) u_core (
        .clk        (clk),
        .rst        (rst),
        .halt       (1'b0),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .imem_req   (),
        .imem_vld   (1'b1),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_byteena(dmem_byteena),
        .dmem_re    (dmem_re),
        .ld_data    (ld_data),
        .dmem_req   (),
        .dmem_vld   (1'b1),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data),
        .pc_dbg     (pc_dbg),
        ._bogus     (1'b0)
    );

    // Instruction memory - async read
    assign imem_rdata = imem[imem_addr[31:2]];  // word addressed

    // Data memory - async read, sync write, per-byte masked
    assign ld_data = dmem[dmem_addr[31:2]];

    always_ff @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_byteena[0]) dmem[dmem_addr[31:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_byteena[1]) dmem[dmem_addr[31:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_byteena[2]) dmem[dmem_addr[31:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_byteena[3]) dmem[dmem_addr[31:2]][31:24] <= dmem_wdata[31:24];
        end
    end

endmodule
