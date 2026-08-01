// tests/testbench/tb_core.sv

module tb_core #(
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
    logic        dmem_re;
    logic [3:0]  dmem_byteena;
    logic [31:0] ld_data;
    logic [4:0]  dbg_reg_addr;
    logic [31:0] dbg_reg_data;
    logic [31:0] pc_dbg;

    // Debug CSR read -- no debug_uart instance in this testbench, so just
    // expose these for direct signal access (dut.u_core.dbg_csr_data)
    // rather than driving them from anywhere.
    logic [11:0] dbg_csr_addr;
    logic [31:0] dbg_csr_data;

    // Instantiate core
    riscv_core #(
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
        .dmem_re    (dmem_re),
        .dmem_byteena(dmem_byteena),
        .ld_data    (ld_data),
        .dmem_req   (),
        .dmem_vld   (1'b1),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data),
        .dbg_csr_addr(dbg_csr_addr),
        .dbg_csr_data(dbg_csr_data),
        .pc_dbg     (pc_dbg),
        .timer_irq  (1'b0)
    );

    // Instruction memory - async read
    assign imem_rdata = imem[imem_addr[31:2]];  // word addressed

    // Data memory - async read, sync write
    assign ld_data = dmem[dmem_addr[31:2]];

    // Byte-masked write, mirrors dp_ram_model.sv's write_masked -- each set
    // bit in dmem_byteena overwrites only that byte lane, so SB/SH stores
    // don't clobber adjacent bytes/halfwords sharing the same word.
    always_ff @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_byteena[0]) dmem[dmem_addr[31:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_byteena[1]) dmem[dmem_addr[31:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_byteena[2]) dmem[dmem_addr[31:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_byteena[3]) dmem[dmem_addr[31:2]][31:24] <= dmem_wdata[31:24];
        end
    end

endmodule