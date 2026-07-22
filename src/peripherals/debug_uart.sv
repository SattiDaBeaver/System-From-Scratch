// src/peripherals/debug_uart.sv
// Standalone hardware register debugger.
// Sits on its own UART pins, independent of the core's program UART and
// of dmem/imem — it can halt/step/read the core even if the loaded
// program (or bootloader) is hung, and can never corrupt memory.
//
// Command protocol (all commands are a single command byte, LSB-first
// multi-byte replies):
//   0x01 HALT      -> no reply. Freezes PC/regfile updates.
//   0x02 RESUME    -> no reply. Resumes normal execution.
//   0x03 STEP      -> no reply. Advances exactly one core clock cycle
//                     (only guaranteed to be exactly one instruction when
//                     the core is halted and running at core_clk == clk).
//   0x04 <idx>     -> READ_REG. idx is 0-31 (top 3 bits ignored). Replies
//                     with 4 bytes, little-endian, regfile[idx].
//   0x05 READ_PC   -> replies with 4 bytes, little-endian, pc.
//   0x06 READ_ALL  -> replies with 33 little-endian 32-bit words:
//                     regfile[0..31] followed by pc.

module debug_uart #(
    parameter CLK_BITS = 16
) (
    input  logic         clk,
    input  logic         rst,

    input  logic [CLK_BITS-1:0] clk_per_bit,

    input  logic         dbg_rx,
    output logic         dbg_tx,

    output logic [4:0]   dbg_reg_addr,
    input  logic [31:0]  dbg_reg_data,
    input  logic [31:0]  pc_dbg,

    output logic         halt
);

    localparam logic [7:0] CMD_HALT     = 8'h01;
    localparam logic [7:0] CMD_RESUME   = 8'h02;
    localparam logic [7:0] CMD_STEP     = 8'h03;
    localparam logic [7:0] CMD_READ_REG = 8'h04;
    localparam logic [7:0] CMD_READ_PC  = 8'h05;
    localparam logic [7:0] CMD_READ_ALL = 8'h06;

    typedef enum logic [2:0] {
        CMD_IDLE,
        WAIT_ARG,
        STEP_ASSERT,
        STEP_DEASSERT,
        SEND_LOAD,
        SEND_BYTE_START,
        SEND_BYTE_WAIT_BUSY,
        SEND_BYTE_WAIT_DONE
    } state_t;

    state_t state;

    logic [5:0]  word_sel;    // 0-31 = regfile index, 32 = pc
    logic [5:0]  word_count;  // words remaining to send
    logic [1:0]  byte_sel;    // byte within word, 0 = LSB
    logic [31:0] cur_word;

    logic        rx_done;
    logic [7:0]  rx_data;
    logic        tx_en;
    logic [7:0]  tx_data;
    logic        tx_busy;

    uart #(
        .CLK_BITS    (CLK_BITS),
        .DATA_WIDTH  (8),
        .PARITY_BITS (0),
        .STOP_BITS   (1)
    ) u_dbg_uart (
        .clk            (clk),
        .rst            (rst),
        .clk_per_bit    (clk_per_bit),
        .TX_dataIn      (tx_data),
        .TX_en          (tx_en),
        .RX_dataIn      (dbg_rx),
        .TX_out         (dbg_tx),
        .TX_done        (),
        .TX_busy        (tx_busy),
        .RX_dataOut     (rx_data),
        .RX_done        (rx_done),
        .RX_parityError ()
    );

    // Async indexed regfile read: word_sel doubles as the debug read
    // address whenever it selects a register (0-31); pc_dbg is read
    // directly and needs no addressing.
    assign dbg_reg_addr = word_sel[4:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            state      <= CMD_IDLE;
            halt       <= 1'b0;
            word_sel   <= 6'd0;
            word_count <= 6'd0;
            byte_sel   <= 2'd0;
            cur_word   <= 32'd0;
            tx_en      <= 1'b0;
        end
        else begin
            tx_en <= 1'b0; // default; pulsed high explicitly below

            case (state)
                CMD_IDLE: begin
                    if (rx_done) begin
                        case (rx_data)
                            CMD_HALT:     halt <= 1'b1;
                            CMD_RESUME:   halt <= 1'b0;
                            CMD_STEP:     state <= STEP_ASSERT;
                            CMD_READ_REG: state <= WAIT_ARG;
                            CMD_READ_PC: begin
                                word_sel   <= 6'd32;
                                word_count <= 6'd1;
                                state      <= SEND_LOAD;
                            end
                            CMD_READ_ALL: begin
                                word_sel   <= 6'd0;
                                word_count <= 6'd33;
                                state      <= SEND_LOAD;
                            end
                            default: ; // ignore unknown command byte
                        endcase
                    end
                end

                WAIT_ARG: begin
                    if (rx_done) begin
                        word_sel   <= {1'b0, rx_data[4:0]}; // clamp to 0-31
                        word_count <= 6'd1;
                        state      <= SEND_LOAD;
                    end
                end

                // Drop halt for exactly one clk cycle, then reassert.
                STEP_ASSERT: begin
                    halt  <= 1'b0;
                    state <= STEP_DEASSERT;
                end

                STEP_DEASSERT: begin
                    halt  <= 1'b1;
                    state <= CMD_IDLE;
                end

                SEND_LOAD: begin
                    cur_word <= (word_sel < 6'd32) ? dbg_reg_data : pc_dbg;
                    byte_sel <= 2'd0;
                    state    <= SEND_BYTE_START;
                end

                SEND_BYTE_START: begin
                    if (!tx_busy) begin
                        tx_data <= cur_word[8*byte_sel +: 8];
                        tx_en   <= 1'b1;
                        state   <= SEND_BYTE_WAIT_BUSY;
                    end
                end

                SEND_BYTE_WAIT_BUSY: begin
                    if (tx_busy) state <= SEND_BYTE_WAIT_DONE;
                end

                SEND_BYTE_WAIT_DONE: begin
                    if (!tx_busy) begin
                        if (byte_sel == 2'd3) begin
                            if (word_count == 6'd1) begin
                                state <= CMD_IDLE;
                            end
                            else begin
                                word_sel   <= word_sel + 6'd1;
                                word_count <= word_count - 6'd1;
                                state      <= SEND_LOAD;
                            end
                        end
                        else begin
                            byte_sel <= byte_sel + 2'd1;
                            state    <= SEND_BYTE_START;
                        end
                    end
                end

                default: state <= CMD_IDLE;
            endcase
        end
    end

endmodule
