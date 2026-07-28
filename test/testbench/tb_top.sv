// test/testbench/tb_top.sv
//
// Simulation counterpart to fpga/riscv_top.sv, for testing the top-level
// wrapper's own logic (clock divider, program/debug UART mux on SW[0],
// halt gating on KEY[1]) rather than just the core in isolation (that's
// what tb_core.sv/tb_soc.sv already cover).
//
// Two differences from riscv_top.sv, both purely to make this simulatable
// and testable with cocotb -- everything else is a straight copy, so
// porting future riscv_top.sv changes here should be mechanical:
//   1. dp_ram (Quartus altsyncram megafunction, no Verilator support) is
//      swapped for dp_ram_model (fpga/dp_ram_model.sv), a behavioral
//      equivalent.
//   2. ARDUINO_IO's inout bundle is split into separate ext_rx (input) /
//      ext_tx (output) ports instead of a single inout, so cocotb can
//      drive/observe each side without inout-net gymnastics. ext_rx/ext_tx
//      map 1:1 onto ARDUINO_IO[0]/ARDUINO_IO[1] on real hardware.

module tb_top #(
    parameter CORE_TYPE = "PIPELINED"  // mirrors fpga/riscv_top.sv's CORE_TYPE
) (
    input  logic [9:0] SW,
    input  logic [1:0] KEY,
    input  logic       CLOCK_50,

    output logic [6:0] HEX5,
    output logic [6:0] HEX4,
    output logic [6:0] HEX3,
    output logic [6:0] HEX2,
    output logic [6:0] HEX1,
    output logic [6:0] HEX0,
    output logic [9:0] LEDR,

    input  logic        ext_rx,  // mirrors ARDUINO_IO[0]
    output logic        ext_tx   // mirrors ARDUINO_IO[1]
);

    // ──────────────────────────────────────
    //  Clock and Reset
    // ──────────────────────────────────────
    logic clk50;
    logic clk;
    logic rst;
    logic clk_div_toggle;

    assign clk50 = CLOCK_50;
    assign rst   = ~KEY[0];

    always_ff @(posedge clk50) begin
        if (rst) clk_div_toggle <= 1'b0;
        else     clk_div_toggle <= ~clk_div_toggle;
    end

    assign clk = clk_div_toggle;  // CLOCK_50 / 2 = 25MHz

    // ──────────────────────────────────────
    //  Core Interface Wires
    // ──────────────────────────────────────
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
    logic        halt;

    // req/vld memory handshake -- mirrors fpga/riscv_top.sv
    logic        imem_req;
    logic        dmem_req;

    // Debug-UART-driven BRAM port B access (hardware bootloader) -- see
    // the BRAM port B mux below.
    logic [31:0] dbg_mem_addr;
    logic [31:0] dbg_mem_wdata;
    logic        dbg_mem_we;
    logic        dbg_mem_valid;
    logic [31:0] dbg_mem_rdata;

    // ──────────────────────────────────────
    //  UART Wires
    // ──────────────────────────────────────
    logic        uart_tx;
    logic        uart_rx;
    logic        uart_tx_en;
    logic        uart_tx_busy;
    logic        uart_tx_done;
    logic        uart_rx_done;
    logic        uart_rx_parity_err;
    logic [7:0]  uart_tx_data;
    logic [7:0]  uart_rx_data;

    // clk_per_bit for 115200 baud @ 25MHz
    // 25_000_000 / 115200 = 217
    localparam CLK_PER_BIT = 16'd217;

    // ──────────────────────────────────────
    //  Debug UART Wires
    // ──────────────────────────────────────
    logic dbg_rx;
    logic dbg_tx;

    // ext_rx/ext_tx = ARDUINO_IO[0]/[1] -- single external serial link,
    // shared by both the program UART and the debug UART. SW[0] picks
    // which one is actually connected to the pins.
    assign uart_rx = SW[0] ? 1'b1 : ext_rx;  // idle-high when not selected
    assign dbg_rx  = SW[0] ? ext_rx : 1'b1;
    assign ext_tx  = SW[0] ? dbg_tx : uart_tx;

    // ──────────────────────────────────────
    //  Address Decoder
    // ──────────────────────────────────────
    logic bram_sel;
    logic uart_sel;

    assign bram_sel = (dmem_addr[31:16] == 16'h0000);  // 0x00000000 - 0x00003FFF
    assign uart_sel = (dmem_addr[31:4]  == 28'h1000000); // 0x10000000 - 0x1000000F

    // ──────────────────────────────────────
    //  Memory-read valid tracking (mirrors fpga/riscv_top.sv -- see
    //  mem_stall_ctrl below.)
    // ──────────────────────────────────────
    logic imem_rvalid;
    logic dmem_rvalid;
    logic core_halt;

    always_ff @(posedge clk) begin
        imem_rvalid <= 1'b1;      // imem is read every non-halted cycle
        dmem_rvalid <= dmem_req;  // generalized from dmem_re -- see fpga/riscv_top.sv
    end

    mem_stall_ctrl u_mem_stall_ctrl (
        .clk         (clk),
        .rst         (rst),
        .dbg_halt    (halt),
        .imem_rvalid (imem_rvalid),
        .dmem_re     (dmem_re),
        .dmem_rvalid (dmem_rvalid),
        .core_halt   (core_halt)
    );

    // ──────────────────────────────────────
    //  Load Data Mux
    // ──────────────────────────────────────
    logic [31:0] bram_rd_data;
    logic [31:0] uart_rd_data;

    // UART read data mux
    always_comb begin
        uart_rd_data = 32'b0;
        casez (dmem_addr[3:2])
            2'b00: uart_rd_data = {24'b0, uart_tx_data};           // TX data
            2'b01: uart_rd_data = {24'b0, uart_rx_data};           // RX data
            2'b10: uart_rd_data = {30'b0, uart_rx_done,
                                           uart_tx_busy};           // status
            default: uart_rd_data = 32'b0;
        endcase
    end

    // Final load data mux
    always_comb begin
        if      (bram_sel) ld_data = bram_rd_data;
        else if (uart_sel) ld_data = uart_rd_data;
        else               ld_data = 32'b0;
    end

    // ──────────────────────────────────────
    //  UART Write Decode
    // ──────────────────────────────────────
    always_comb begin
        uart_tx_en   = 1'b0;
        uart_tx_data = 8'b0;
        if (uart_sel && dmem_we) begin
            casez (dmem_addr[3:2])
                2'b00: begin
                    uart_tx_data = dmem_wdata[7:0];
                    uart_tx_en   = 1'b1;
                end
                default: ;
            endcase
        end
    end

    // 7 seg display
    logic [3:0] h0;
    logic [3:0] h1;
    logic [3:0] h2;
    logic [3:0] h3;
    logic [3:0] h4;
    logic [3:0] h5;

    hex_display u_hex0 (.value(h0), .HEX(HEX0));
    hex_display u_hex1 (.value(h1), .HEX(HEX1));
    hex_display u_hex2 (.value(h2), .HEX(HEX2));
    hex_display u_hex3 (.value(h3), .HEX(HEX3));
    hex_display u_hex4 (.value(h4), .HEX(HEX4));
    hex_display u_hex5 (.value(h5), .HEX(HEX5));

    assign h0 = imem_rdata[3:0];
    assign h1 = imem_rdata[7:4];
    assign h2 = imem_rdata[11:8];
    assign h3 = imem_rdata[15:12];
    assign h4 = imem_rdata[19:16];
    assign h5 = imem_rdata[23:20];

    assign LEDR[9:0] = {~dbg_rx, ~dbg_tx, 1'b0, imem_addr[8:2]};

    // ──────────────────────────────────────
    //  DP BRAM (behavioral model -- see fpga/dp_ram_model.sv)
    // ──────────────────────────────────────
    // Port B is normally the core's data memory port; while the debug
    // UART is servicing WRITE_MEM/READ_MEM (dbg_mem_valid), it takes over
    // port B instead -- see fpga/riscv_top.sv for the hardware copy of
    // this mux.
    logic [31:0] bram_addr_b;
    logic [31:0] bram_data_b;
    logic        bram_we_b;

    assign bram_addr_b = dbg_mem_valid ? dbg_mem_addr  : dmem_addr;
    assign bram_data_b = dbg_mem_valid ? dbg_mem_wdata : dmem_wdata;
    assign bram_we_b   = dbg_mem_valid ? dbg_mem_we    : (dmem_we && bram_sel);
    assign dbg_mem_rdata = bram_rd_data;

    dp_ram_model #(
        .REGISTERED_ADDR (1)
    ) u_bram (
        .clock      (clk),
        // Port A — instruction fetch
        .address_a  (imem_addr[13:2]),
        .data_a     (32'b0),
        .wren_a     (1'b0),
        .q_a        (imem_rdata),
        // Port B — data memory / debug-UART hardware bootloader
        .address_b  (bram_addr_b[13:2]),
        .data_b     (bram_data_b),
        .wren_b     (bram_we_b),
        .q_b        (bram_rd_data)
    );

    // ──────────────────────────────────────
    //  UART
    // ──────────────────────────────────────
    uart #(
        .CLK_BITS    (16),
        .DATA_WIDTH  (8),
        .PARITY_BITS (0),
        .STOP_BITS   (2)
    ) u_uart (
        .clk            (clk),
        .rst            (rst),
        .clk_per_bit    (CLK_PER_BIT),
        .TX_dataIn      (uart_tx_data),
        .TX_en          (uart_tx_en),
        .RX_dataIn      (uart_rx),
        .TX_out         (uart_tx),
        .TX_done        (uart_tx_done),
        .TX_busy        (uart_tx_busy),
        .RX_dataOut     (uart_rx_data),
        .RX_done        (uart_rx_done),
        .RX_parityError (uart_rx_parity_err)
    );

    // ──────────────────────────────────────
    //  RISC-V Core
    // ──────────────────────────────────────
    // core_halt only guarantees correct memory timing for
    // CORE_TYPE=SINGLE_CYCLE -- see fpga/riscv_top.sv.
    generate
        if (CORE_TYPE == "SINGLE_CYCLE") begin : g_core
            assign imem_req = 1'b0;
            assign dmem_req = dmem_re;  // preserves dmem_rvalid's original trigger
            riscv_core_single_cycle u_core (
                .clk        (clk),
                .rst        (rst),
                .halt       (core_halt & KEY[1]),
                .imem_addr  (imem_addr),
                .imem_rdata (imem_rdata),
                .dmem_addr  (dmem_addr),
                .dmem_wdata (dmem_wdata),
                .dmem_we    (dmem_we),
                .dmem_re    (dmem_re),
                .ld_data    (ld_data),
                .dbg_reg_addr(dbg_reg_addr),
                .dbg_reg_data(dbg_reg_data),
                .pc_dbg     (pc_dbg),
                ._bogus     (1'b0)
            );
        end else begin : g_core
            riscv_core u_core (
                .clk        (clk),
                .rst        (rst),
                .halt       (halt & KEY[1]),
                .imem_addr  (imem_addr),
                .imem_rdata (imem_rdata),
                .imem_req   (imem_req),
                .imem_vld   (imem_rvalid),
                .dmem_addr  (dmem_addr),
                .dmem_wdata (dmem_wdata),
                .dmem_we    (dmem_we),
                .dmem_re    (dmem_re),
                .ld_data    (ld_data),
                .dmem_req   (dmem_req),
                .dmem_vld   (dmem_rvalid),
                .dbg_reg_addr(dbg_reg_addr),
                .dbg_reg_data(dbg_reg_data),
                .pc_dbg     (pc_dbg),
                ._bogus     (1'b0)
            );
        end
    endgenerate

    // ──────────────────────────────────────
    //  Debug UART
    // ──────────────────────────────────────
    debug_uart #(
        .CLK_BITS (16)
    ) u_debug_uart (
        .clk          (clk),
        .rst          (rst),
        .clk_per_bit  (CLK_PER_BIT),
        .dbg_rx       (dbg_rx),
        .dbg_tx       (dbg_tx),
        .dbg_reg_addr (dbg_reg_addr),
        .dbg_reg_data (dbg_reg_data),
        .pc_dbg       (pc_dbg),
        .dbg_mem_addr  (dbg_mem_addr),
        .dbg_mem_wdata (dbg_mem_wdata),
        .dbg_mem_we    (dbg_mem_we),
        .dbg_mem_valid (dbg_mem_valid),
        .dbg_mem_rdata (dbg_mem_rdata),
        .halt         (halt)
    );

endmodule
