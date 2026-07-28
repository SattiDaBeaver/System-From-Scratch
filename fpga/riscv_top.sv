// CORE_TYPE selects which core RTL gets elaborated -- "PIPELINED" (default)
// for the in-development 5-stage riscv_core, or "SINGLE_CYCLE" for the
// frozen riscv_core_single_cycle golden model (see test/testbench/tb_diff.sv,
// which already differential-fuzzes the two side by side). Both modules
// share an identical port list, so this is a pure synthesis-time choice --
// no other RTL in this file depends on which one is selected. Override via
// Quartus's top-level parameter assignment (Assignment Editor, or
// `set_parameter -name CORE_TYPE "SINGLE_CYCLE"` in the QSF) before compiling.
module riscv_top #(
    parameter CORE_TYPE = "PIPELINED"
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

    output logic [3:0] VGA_R,
    output logic [3:0] VGA_G,
    output logic [3:0] VGA_B,
    output logic       VGA_HS,
    output logic       VGA_VS,

    inout  logic [15:0] ARDUINO_IO
);

    // ──────────────────────────────────────
    //  Clock and Reset
    // ──────────────────────────────────────
    // Single 25MHz system clock for everything (core, both UARTs, BRAM) --
    // the single-cycle core can't close timing at the full 50MHz CLOCK_50,
    // so rather than keep a separate core_clk/clk split (which needs a
    // clock-domain-crossing-aware STEP pulse for the debug UART), just
    // divide once and run the whole design off the divided clock. No CDC
    // anywhere in this design as a result.
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
    //  Unused outputs tied off for now
    // ──────────────────────────────────────
    // assign HEX5 = 7'h7F;
    // assign HEX4 = 7'h7F;
    // assign HEX3 = 7'h7F;
    // assign HEX2 = 7'h7F;
    // assign HEX1 = 7'h7F;
    // assign HEX0 = 7'h7F;
    // assign LEDR = 10'b0;

    assign VGA_R  = 4'b0;
    assign VGA_G  = 4'b0;
    assign VGA_B  = 4'b0;
    assign VGA_HS = 1'b1;
    assign VGA_VS = 1'b1;

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

    // req/vld memory handshake -- only riscv_core (PIPELINED) has these
    // ports; for CORE_TYPE=SINGLE_CYCLE dmem_req is tied to dmem_re below
    // so dmem_rvalid's trigger is unchanged from today for that branch.
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

    // ARDUINO_IO[0] = RX (input), ARDUINO_IO[1] = TX (output) -- single
    // external serial link, shared by both the program UART and the debug
    // UART. SW[0] picks which one is actually connected to the pins, so
    // switching between "talk to my program" and "halt/step/read regs"
    // is a switch flip instead of moving a cable between ARDUINO headers.
    assign uart_rx = SW[0] ? 1'b1 : ARDUINO_IO[0];  // idle-high when not selected
    assign dbg_rx  = SW[0] ? ARDUINO_IO[0] : 1'b1;
    assign ARDUINO_IO[1] = SW[0] ? dbg_tx : uart_tx;

    // ──────────────────────────────────────
    //  Address Decoder
    // ──────────────────────────────────────
    logic bram_sel;
    logic uart_sel;

    assign bram_sel = (dmem_addr[31:16] == 16'h0000);  // 0x00000000 - 0x00003FFF
    assign uart_sel = (dmem_addr[31:4]  == 28'h1000000); // 0x10000000 - 0x1000000F

    // ──────────────────────────────────────
    //  Memory-read valid tracking (real BRAM registers its read address,
    //  so imem_rdata/bram_rd_data lag imem_addr/dmem_addr by one cycle --
    //  see mem_stall_ctrl below.)
    // ──────────────────────────────────────
    logic imem_rvalid;
    logic dmem_rvalid;
    logic core_halt;

    always_ff @(posedge clk) begin
        imem_rvalid <= 1'b1;      // imem is read every non-halted cycle --
                                   // KNOWN BUG under REGISTERED_ADDR=1 (see
                                   // docs/04_pipeline_plan.md §6.2): doesn't
                                   // actually track the 1-cycle address-
                                   // register latency, just claims fetched
                                   // data is always valid. Can't naively fix
                                   // to "imem_rvalid <= imem_req" because
                                   // SINGLE_CYCLE's branch ties imem_req to
                                   // 1'b0 unconditionally, which would hang
                                   // mem_stall_ctrl in FETCH_WAIT forever.
        dmem_rvalid <= dmem_req;  // generalized from dmem_re so stores also
                                   // get a completion pulse (see dmem_req
                                   // generate-branch assigns below); a no-op
                                   // for mem_stall_ctrl, which only samples
                                   // dmem_rvalid while dmem_re is asserted
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
    //  DP BRAM
    // ──────────────────────────────────────
    // Port B is normally the core's data memory port; while the debug
    // UART is servicing WRITE_MEM/READ_MEM (dbg_mem_valid), it takes over
    // port B instead. debug_uart only ever asserts dbg_mem_valid while
    // halt is set (see debug_uart.sv), so this can't race a running
    // program's own dmem accesses.
    logic [31:0] bram_addr_b;
    logic [31:0] bram_data_b;
    logic        bram_we_b;

    assign bram_addr_b = dbg_mem_valid ? dbg_mem_addr  : dmem_addr;
    assign bram_data_b = dbg_mem_valid ? dbg_mem_wdata : dmem_wdata;
    assign bram_we_b   = dbg_mem_valid ? dbg_mem_we    : (dmem_we && bram_sel);
    assign dbg_mem_rdata = bram_rd_data;

    dp_ram u_bram (
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
    // core_halt (from mem_stall_ctrl above) only guarantees correct memory
    // timing for CORE_TYPE=SINGLE_CYCLE today -- freezing the whole core
    // for the BRAM's registered-address latency doesn't map onto the
    // pipelined core's per-stage IF/MEM timing, which still needs its own
    // fix (see docs/04_pipeline_plan.md §4/§6.1).
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
    // Core, program UART, and debug UART all now share one clk (25MHz) --
    // no more core_clk/clk split, so STEP's one-cycle halt-drop pulse is
    // always exactly one core clock cycle, unconditionally.
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