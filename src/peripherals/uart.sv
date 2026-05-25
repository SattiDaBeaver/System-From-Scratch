module uart #(
    parameter CLK_BITS     = 16, // bits for adjustable BAUD rate, min BAUD = F_CLK / (2^CLK_BITS)
    parameter DATA_WIDTH   = 8,
    parameter PARITY_BITS  = 0,
    parameter STOP_BITS    = 1
) (
    input  logic                    clk,
    input  logic                    rst,

    input  logic   [CLK_BITS-1:0]   clk_per_bit,

    input  logic   [DATA_WIDTH-1:0] TX_dataIn,
    input  logic                    TX_en,

    input  logic                    RX_dataIn,

    output logic                    TX_out,
    output logic                    TX_done,
    output logic                    TX_busy,

    output logic   [DATA_WIDTH-1:0] RX_dataOut,
    output logic                    RX_done,
    output logic                    RX_parityError
);
    // UART Transmitter Module
    UART_TX #(
        .CLK_BITS(CLK_BITS),
        .DATA_WIDTH(DATA_WIDTH),
        .PARITY_BITS(PARITY_BITS),
        .STOP_BITS(STOP_BITS)
        ) 
        UART_TX1 ( 
        .clk(clk),
        .rst(rst),

        .clk_per_bit(clk_per_bit),
        .dataIn(TX_dataIn),
        .TXen(TX_en),

        .TXout(TX_out),
        .TXdone(TX_done),
        .busy(TX_busy)
    );

    // UART Receiver Module
    UART_RX #(
        .CLK_BITS(CLK_BITS),
        .DATA_WIDTH(DATA_WIDTH),
        .PARITY_BITS(PARITY_BITS),
        .STOP_BITS(STOP_BITS)
        )
        UART_RX1 (
        .clk(clk),
        .rst(rst),

        .clk_per_bit(clk_per_bit),
        .dataIn(RX_dataIn),

        .RXout(RX_dataOut),
        .RXdone(RX_done),
        .parityError(RX_parityError)
    );
endmodule

module UART_RX #(
    parameter CLK_BITS = 8,   // bits for adjustable BAUD rate, min BAUD = F_CLK / (2^CLK_BITS)
    parameter DATA_WIDTH = 8,
    parameter STOP_BITS = 2,  // either 1 or 2 stop bits
    parameter PARITY_BITS = 1,
    parameter PACKET_SIZE = DATA_WIDTH + STOP_BITS + PARITY_BITS + 1
    // Total Packet Size = DATA_WIDTH + STOP_BITS + 1 Start Bit + 1 Parity Bit
) ( 
    input  logic                                clk,
    input  logic                                rst,

    input  logic    [CLK_BITS - 1 : 0]          clk_per_bit,
    input  logic                                dataIn,

    output logic    [DATA_WIDTH - 1 : 0]         RXout,
    output logic                                RXdone,
    output logic                                parityError
);

    localparam indexBits = $clog2(PACKET_SIZE);

    logic   [indexBits - 1 : 0]     index;
    logic   [CLK_BITS - 1 : 0]      clkCount;

    logic                           regInMeta;
    logic                           regIn;
    logic                           parity;

    logic    [DATA_WIDTH - 1 : 0]    dataOut;
    logic                           dataDone;

    // Remove Problems due to Metastability
    always_ff @(posedge clk) begin
        regInMeta <= dataIn;
        regIn <= regInMeta;
    end



    typedef enum logic [1:0] {
        IDLE,
        START,
        RECEIVE,
        DONE
    } 
    state_t;

    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            dataOut <= 0;
            state <= IDLE;
            index <= 1'b0;
            clkCount <= 0;
            dataDone <= 0;
        end
        else begin
            case (state)
                IDLE: begin
                    clkCount <= 0;
                    index <= 0;
                    dataOut <= 0;
                    dataDone <= 0;

                    if (regIn == 1'b0) begin    // Start Condition
                        state <= START;
                    end
                    else begin
                        state <= IDLE;
                    end
                end

                START: begin
                    if (clkCount == ((clk_per_bit - 1) >> 1)) begin
                        clkCount <= 0;
                        state <= RECEIVE;
                    end
                    else begin
                        clkCount <= clkCount + 1;
                        state <= START;
                    end

                end

                RECEIVE: begin

                    if (clkCount < clk_per_bit - 1) begin
                        clkCount <= clkCount + 1;
                        state <= RECEIVE;
                    end

                    else begin
                        clkCount <= 0;
                        if (index < DATA_WIDTH) begin
                            dataOut[index] <= regIn;
                            index <= index + 1;
                            state <= RECEIVE;
                        end
                        else if (index == DATA_WIDTH && PARITY_BITS > 0) begin
                            parity <= regIn;
                            state <= DONE;
                        end
                        else begin
                            state <= DONE;
                        end
                    end
                end

                DONE: begin
                    if (clkCount < clk_per_bit - 1) begin
                        clkCount <= clkCount + 1;
                        state <= DONE;
                    end
                    else begin
                        clkCount <= 0;
                        state <= IDLE;
                        dataDone <= 1'b1;
                        index <= 0;
                        RXout <= dataOut;
                    end
                end

                default: begin
                    state <= IDLE;
                end
                
            endcase
        end 
    end

    always_comb begin
        RXdone = dataDone;
        if (PARITY_BITS > 0) begin
            parityError = (^RXout) ^ parity;
        end
        else begin
            parityError = 0;
        end
    end
endmodule

module UART_TX #(
    parameter CLK_BITS = 8,         // bits for adjustable BAUD rate, min BAUD = F_CLK / (2^CLK_BITS)
    parameter DATA_WIDTH = 8,
    parameter STOP_BITS = 1,        // either 1 or 2 stop bits
    parameter PARITY_BITS = 1,      // can be set to 0
    parameter PACKET_SIZE = DATA_WIDTH + STOP_BITS + PARITY_BITS + 1 
    // Total Packet Size = DATA_WIDTH + STOP_BITS + 1 Start Bit + 1 Parity Bit
) ( 
    input  logic                                clk,
    input  logic                                rst,

    input  logic      [CLK_BITS - 1 : 0]        clk_per_bit,
    input  logic      [DATA_WIDTH - 1 : 0]      dataIn,
    input  logic                                TXen,

    output logic                                TXout,
    output logic                                TXdone,
    output logic                                busy
);

    localparam indexBits = $clog2(PACKET_SIZE);

    logic   [PACKET_SIZE - 1 : 0]       packet;
    logic                               parityBit;
    logic   [indexBits - 1 : 0]         index;
    logic   [CLK_BITS - 1 : 0]          clkCount;

    typedef enum logic [1:0] {
        IDLE,
        TRANSMIT,
        DONE
    } 
    state_t;

    state_t state;

    always_comb begin
        parityBit = ^dataIn;    // 0 for even number of 1's, 1 for odd number of 1's
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            TXout       <= 1'b1;
            state       <= IDLE;
            busy        <= 1'b0;
            index       <= 1'b0;
            clkCount    <= 0;
            TXdone      <= 0;
        end
        else begin
            case (state)
                IDLE: begin
                    TXout       <= 1'b1;
                    index       <= 1'b0;
                    clkCount    <= 0;
                    TXdone      <= 0;

                    if (TXen) begin
                        if (PARITY_BITS > 0) begin
                            packet <= {{STOP_BITS{1'b1}}, parityBit, dataIn, 1'b0};
                        end 
                        else begin
                            packet <= {{STOP_BITS{1'b1}}, dataIn, 1'b0};
                        end
                        //                ^                         ^
                        //                |                         |
                        //              Stop                      Start
                        busy <= 1'b1;
                        state <= TRANSMIT;
                    end
                    else begin
                        state <= IDLE;
                    end
                end

                TRANSMIT: begin
                    TXout <= packet[index];

                    if (clkCount < clk_per_bit - 1) begin
                        clkCount <= clkCount + 1;
                        state <= TRANSMIT;
                    end

                    else begin
                        clkCount <= 0;
                        if (index == PACKET_SIZE - 1) begin
                            state <= DONE;
                        end
                        else begin
                            index <= index + 1;
                            state <= TRANSMIT;
                        end
                    end
                end

                DONE: begin
                    state       <= IDLE;
                    busy        <= 1'b0;
                    TXdone      <= 1'b1;
                    index       <= 1'b0;
                    clkCount    <= 0;
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end 
    end
endmodule

