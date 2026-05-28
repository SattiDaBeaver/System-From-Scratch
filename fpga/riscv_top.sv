module riscv_top (
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
    localparam CLK_DIV_BIT = 1; 

    logic clk, slow_clk, core_clk;
    logic rst;
    logic [CLK_DIV_BIT:0] clk_div_cnt;

    assign clk = CLOCK_50;
    assign rst = ~KEY[0];

    always_ff @(posedge clk) begin
        if (rst) clk_div_cnt <= 0;
        else     clk_div_cnt <= clk_div_cnt + 1;
    end

    assign slow_clk = clk_div_cnt[CLK_DIV_BIT];

    assign core_clk = SW[0] ? slow_clk : clk;

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

    // ARDUINO_IO[0] = RX (input), ARDUINO_IO[1] = TX (output)
    assign uart_rx          = ARDUINO_IO[0];
    assign ARDUINO_IO[1]    = uart_tx;

    // clk_per_bit for 115200 baud @ 50MHz
    // 50_000_000 / 115200 = 434
    localparam CLK_PER_BIT = 16'd434;

    // ──────────────────────────────────────
    //  Address Decoder
    // ──────────────────────────────────────
    logic bram_sel;
    logic uart_sel;

    assign bram_sel = (dmem_addr[31:16] == 16'h0000);  // 0x00000000 - 0x00003FFF
    assign uart_sel = (dmem_addr[31:4]  == 28'h1000000); // 0x10000000 - 0x1000000F

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

    assign LEDR[9:0] = imem_addr[11:2];

    // ──────────────────────────────────────
    //  DP BRAM
    // ──────────────────────────────────────
    dp_ram u_bram (
        .clock      (clk),
        // Port A — instruction fetch
        .address_a  (imem_addr[13:2]),
        .data_a     (32'b0),
        .wren_a     (1'b0),
        .q_a        (imem_rdata),
        // Port B — data memory
        .address_b  (dmem_addr[13:2]),
        .data_b     (dmem_wdata),
        .wren_b     (dmem_we && bram_sel),
        .q_b        (bram_rd_data)
    );

    // dp_ram u_bram (
    //     .clock      (slow_clk),
    //     // Port A — instruction fetch
    //     .address_a  ({2'b0, SW[9:0]}),
    //     .data_a     (32'b0),
    //     .wren_a     (1'b0),
    //     .q_a        (imem_rdata),
    //     // Port B — data memory
    //     .address_b  (dmem_addr[13:2]),
    //     .data_b     (dmem_wdata),
    //     .wren_b     (dmem_we && bram_sel),
    //     .q_b        (bram_rd_data)
    // );

    // ──────────────────────────────────────
    //  UART
    // ──────────────────────────────────────
    uart #(
        .CLK_BITS    (16),
        .DATA_WIDTH  (8),
        .PARITY_BITS (0),
        .STOP_BITS   (1)
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
    riscv_core u_core (
        .clk        (core_clk),
        .rst        (rst),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_re    (dmem_re),
        .ld_data    (ld_data)
    );

endmodule

// Hex

module hex_display (
    input  logic [3:0] value,
    output logic [6:0] HEX
);

    always_comb begin
        case (value)
            4'h0: HEX = 7'b1000000;
            4'h1: HEX = 7'b1111001;
            4'h2: HEX = 7'b0100100;
            4'h3: HEX = 7'b0110000;
            4'h4: HEX = 7'b0011001;
            4'h5: HEX = 7'b0010010;
            4'h6: HEX = 7'b0000010;
            4'h7: HEX = 7'b1111000;
            4'h8: HEX = 7'b0000000;
            4'h9: HEX = 7'b0010000;
            4'hA: HEX = 7'b0001000;
            4'hB: HEX = 7'b0000011;
            4'hC: HEX = 7'b1000110;
            4'hD: HEX = 7'b0100001;
            4'hE: HEX = 7'b0000110;
            4'hF: HEX = 7'b0001110;
            default: HEX = 7'b1111111;
        endcase
    end

endmodule