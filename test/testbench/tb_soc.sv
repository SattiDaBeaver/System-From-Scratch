module tb_soc (
    input logic clk,
    input logic rst,

    // Debug UART pins, mirroring fpga/riscv_top.sv's ARDUINO_IO[2:3]
    input  logic dbg_rx,
    output logic dbg_tx
);
    // UART wires
    logic uart_tx;
    logic uart_rx;

    // Core interface wires
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

    // Debug-UART-driven dmem access (hardware bootloader) -- see the
    // dmem port B mux below.
    logic [31:0] dbg_mem_addr;
    logic [31:0] dbg_mem_wdata;
    logic        dbg_mem_we;
    logic        dbg_mem_valid;
    logic [31:0] dbg_mem_rdata;

    // UART signals
    logic        uart_tx_en;
    logic        uart_tx_busy;
    logic        uart_tx_done;
    logic        uart_rx_done;
    logic [7:0]  uart_tx_data;
    logic [7:0]  uart_rx_data;

    // Address decoder
    logic bram_sel;
    logic uart_sel;

    assign bram_sel = (dmem_addr[31:16] == 16'h0000);
    assign uart_sel = (dmem_addr[31:4]  == 28'h1000000);

    // Load data mux
    logic [31:0] bram_rd_data;
    logic [31:0] uart_rd_data;

    always_comb begin
        uart_rd_data = 32'b0;
        casez (dmem_addr[3:2])
            2'b00: uart_rd_data = {24'b0, uart_tx_data};
            2'b01: uart_rd_data = {24'b0, uart_rx_data};
            2'b10: uart_rd_data = {30'b0, uart_rx_done, uart_tx_busy};
            default: uart_rd_data = 32'b0;
        endcase
    end

    always_comb begin
        if      (bram_sel) ld_data = bram_rd_data;
        else if (uart_sel) ld_data = uart_rd_data;
        else               ld_data = 32'b0;
    end

    // UART write decode
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

    // Memory arrays for sim (no Quartus IP)
    logic [31:0] imem [0:4095];
    logic [31:0] dmem [0:4095];

    // dmem port is normally the core's; while the debug UART is
    // servicing WRITE_MEM/READ_MEM (dbg_mem_valid), it takes over
    // instead -- see fpga/riscv_top.sv for the hardware equivalent.
    logic [31:0] dmem_addr_b;
    logic [31:0] dmem_wdata_b;
    logic        dmem_we_b;

    assign dmem_addr_b  = dbg_mem_valid ? dbg_mem_addr  : dmem_addr;
    assign dmem_wdata_b = dbg_mem_valid ? dbg_mem_wdata : dmem_wdata;
    assign dmem_we_b    = dbg_mem_valid ? dbg_mem_we    : (dmem_we && bram_sel);
    assign dbg_mem_rdata = bram_rd_data;

    assign imem_rdata  = imem[imem_addr[13:2]];
    assign bram_rd_data = dmem[dmem_addr_b[13:2]];

    always_ff @(posedge clk) begin
        if (dmem_we_b)
            dmem[dmem_addr_b[13:2]] <= dmem_wdata_b;
    end

    // UART
    uart #(
        .CLK_BITS    (16),
        .DATA_WIDTH  (8),
        .PARITY_BITS (0),
        .STOP_BITS   (2)
    ) u_uart (
        .clk            (clk),
        .rst            (rst),
        .clk_per_bit    (16'd434),
        .TX_dataIn      (uart_tx_data),
        .TX_en          (uart_tx_en),
        .RX_dataIn      (uart_rx),
        .TX_out         (uart_tx),
        .TX_done        (uart_tx_done),
        .TX_busy        (uart_tx_busy),
        .RX_dataOut     (uart_rx_data),
        .RX_done        (uart_rx_done),
        .RX_parityError ()
    );

    // Core
    riscv_core u_core (
        .clk        (clk),
        .rst        (rst),
        .halt       (halt),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_re    (dmem_re),
        .ld_data    (ld_data),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data),
        .pc_dbg     (pc_dbg)
    );

    // Tie off UART RX for now
    assign uart_rx = 1'b1;

    // Debug UART
    debug_uart #(
        .CLK_BITS (16)
    ) u_debug_uart (
        .clk          (clk),
        .rst          (rst),
        .clk_per_bit  (16'd434),
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