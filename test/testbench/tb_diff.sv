// tests/testbench/tb_diff.sv
//
// Differential testbench: instantiates the core under active development
// (riscv_core, pipelined once that work lands) side by side with the
// frozen, verified riscv_core_single_cycle golden model. Each gets its own
// imem/dmem arrays -- imem is loaded identically into both by the test, and
// dmem starts identical -- so any divergence in dmem contents or regfile
// state after both cores converge (see utils.await_convergence) is a real
// behavioral mismatch, not a shared-state artifact.

module tb_diff #(
    parameter IMEM_DEPTH = 256,   // 256 x 4 bytes = 1KB
    parameter DMEM_DEPTH = 256    // 256 x 4 bytes = 1KB
) (
    input  logic        clk,
    input  logic        rst
);

    // ---- DUT: core under test (pipeline, once implemented) ----
    logic [31:0] imem       [0:IMEM_DEPTH-1];
    logic [31:0] dmem       [0:DMEM_DEPTH-1];
    logic [31:0] imem_addr;
    logic [31:0] imem_rdata;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_wdata;
    logic        dmem_we;
    logic        dmem_re;
    logic [31:0] ld_data;
    logic [4:0]  dbg_reg_addr;
    logic [31:0] dbg_reg_data;
    logic [31:0] pc_dbg;

    riscv_core #(
        .ISA ("RV32I")
    ) u_core (
        .clk         (clk),
        .rst         (rst),
        .halt        (1'b0),
        .imem_addr   (imem_addr),
        .imem_rdata  (imem_rdata),
        .dmem_addr   (dmem_addr),
        .dmem_wdata  (dmem_wdata),
        .dmem_we     (dmem_we),
        .dmem_re     (dmem_re),
        .ld_data     (ld_data),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data),
        .pc_dbg      (pc_dbg)
    );

    assign imem_rdata = imem[imem_addr[31:2]];
    assign ld_data    = dmem[dmem_addr[31:2]];

    always_ff @(posedge clk) begin
        if (dmem_we)
            dmem[dmem_addr[31:2]] <= dmem_wdata;
    end

    // ---- Golden model: frozen pre-pipeline single-cycle core ----
    logic [31:0] imem_ref       [0:IMEM_DEPTH-1];
    logic [31:0] dmem_ref       [0:DMEM_DEPTH-1];
    logic [31:0] imem_addr_ref;
    logic [31:0] imem_rdata_ref;
    logic [31:0] dmem_addr_ref;
    logic [31:0] dmem_wdata_ref;
    logic        dmem_we_ref;
    logic        dmem_re_ref;
    logic [31:0] ld_data_ref;
    logic [4:0]  dbg_reg_addr_ref;
    logic [31:0] dbg_reg_data_ref;
    logic [31:0] pc_dbg_ref;

    riscv_core_single_cycle #(
        .ISA ("RV32I")
    ) u_core_ref (
        .clk         (clk),
        .rst         (rst),
        .halt        (1'b0),
        .imem_addr   (imem_addr_ref),
        .imem_rdata  (imem_rdata_ref),
        .dmem_addr   (dmem_addr_ref),
        .dmem_wdata  (dmem_wdata_ref),
        .dmem_we     (dmem_we_ref),
        .dmem_re     (dmem_re_ref),
        .ld_data     (ld_data_ref),
        .dbg_reg_addr(dbg_reg_addr_ref),
        .dbg_reg_data(dbg_reg_data_ref),
        .pc_dbg      (pc_dbg_ref)
    );

    assign imem_rdata_ref = imem_ref[imem_addr_ref[31:2]];
    assign ld_data_ref    = dmem_ref[dmem_addr_ref[31:2]];

    always_ff @(posedge clk) begin
        if (dmem_we_ref)
            dmem_ref[dmem_addr_ref[31:2]] <= dmem_wdata_ref;
    end

endmodule
