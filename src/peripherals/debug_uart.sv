// src/peripherals/debug_uart.sv
// Standalone hardware register debugger, doubling as a hardware bootloader.
// Sits on its own UART pins, independent of the core's program UART — it
// can halt/step/read the core even if the loaded program (or the software
// UART bootloader) is hung. Memory writes are only ever accepted while the
// core is halted, so it can never corrupt memory out from under a running
// program.
//
// Command protocol (all commands are a single command byte, LSB-first
// multi-byte args/replies):
//   0x01 HALT      -> no reply. Freezes PC/regfile updates.
//   0x02 RESUME    -> no reply. Resumes normal execution.
//   0x03 STEP      -> no reply. Advances exactly one core clock cycle
//                     (exactly one instruction, since debug_uart and
//                     riscv_core now always share the same clk).
//   0x04 <idx>     -> READ_REG. idx is 0-31 (top 3 bits ignored). Replies
//                     with 4 bytes, little-endian, regfile[idx].
//   0x05 READ_PC   -> replies with 4 bytes, little-endian, pc.
//   0x06 READ_ALL  -> replies with 33 little-endian 32-bit words:
//                     regfile[0..31] followed by pc.
//   0x07 <addr32> <data32> -> WRITE_MEM. Only accepted while halted (see
//                     above); ignored otherwise. addr/data are 4 bytes
//                     each, little-endian. Writes data32 to dmem/imem
//                     BRAM at addr32 (word-addressed via the shared
//                     dp_ram port B). No reply -- host paces itself, same
//                     as HALT/RESUME/STEP.
//   0x08 <addr32>  -> READ_MEM. Only accepted while halted; ignored
//                     otherwise. Replies with 4 bytes, little-endian,
//                     the word at addr32.
//
// A host can therefore load a whole program with HALT, a WRITE_MEM per
// word, then RESUME -- no assembly running on the core required, unlike
// the software UART bootloader in src/bootloader/.

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

    // Debug-driven BRAM port B access (hardware bootloader). dbg_mem_valid
    // tells the top-level mux to route BRAM port B's address/data/write
    // lines to these signals instead of the core's this cycle.
    output logic [31:0]  dbg_mem_addr,
    output logic [31:0]  dbg_mem_wdata,
    output logic         dbg_mem_we,
    output logic         dbg_mem_valid,
    input  logic [31:0]  dbg_mem_rdata,

    output logic         halt
);

    localparam logic [7:0] CMD_HALT      = 8'h01;
    localparam logic [7:0] CMD_RESUME    = 8'h02;
    localparam logic [7:0] CMD_STEP      = 8'h03;
    localparam logic [7:0] CMD_READ_REG  = 8'h04;
    localparam logic [7:0] CMD_READ_PC   = 8'h05;
    localparam logic [7:0] CMD_READ_ALL  = 8'h06;
    localparam logic [7:0] CMD_WRITE_MEM = 8'h07;
    localparam logic [7:0] CMD_READ_MEM  = 8'h08;

    typedef enum logic [3:0] {
        CMD_IDLE,
        WAIT_ARG,
        STEP_ASSERT,
        STEP_DEASSERT,
        SEND_LOAD,
        SEND_BYTE_START,
        SEND_BYTE_WAIT_BUSY,
        SEND_BYTE_WAIT_DONE,
        RECV_MEM_ADDR,
        RECV_MEM_DATA,
        MEM_WRITE_PULSE,
        MEM_READ_WAIT,
        MEM_READ_LATCH
    } state_t;

    state_t state;

    logic [5:0]  word_sel;    // 0-31 = regfile index, 32 = pc
    logic [5:0]  word_count;  // words remaining to send
    logic [1:0]  byte_sel;    // byte within word, 0 = LSB
    logic [31:0] cur_word;

    logic [31:0] mem_addr;    // WRITE_MEM/READ_MEM target address, being assembled byte-by-byte
    logic [31:0] mem_wdata;   // WRITE_MEM data, being assembled byte-by-byte
    logic [1:0]  rx_byte_idx; // byte within mem_addr/mem_wdata, 0 = LSB
    logic        mem_is_write;

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

    // dbg_mem_* are continuous outputs of the currently-assembled
    // address/data registers and the FSM state -- top-level only needs to
    // look at dbg_mem_valid to know whether to steer BRAM port B here
    // instead of the core this cycle.
    assign dbg_mem_addr  = mem_addr;
    assign dbg_mem_wdata = mem_wdata;
    assign dbg_mem_we    = (state == MEM_WRITE_PULSE);
    assign dbg_mem_valid = (state == MEM_WRITE_PULSE) ||
                            (state == MEM_READ_WAIT)  ||
                            (state == MEM_READ_LATCH);

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= CMD_IDLE;
            halt         <= 1'b1; // Temporarily halt on reset (change later to rest to 0 but be persistent at 1)
            word_sel     <= 6'd0;
            word_count   <= 6'd0;
            byte_sel     <= 2'd0;
            cur_word     <= 32'd0;
            tx_en        <= 1'b0;
            mem_addr     <= 32'd0;
            mem_wdata    <= 32'd0;
            rx_byte_idx  <= 2'd0;
            mem_is_write <= 1'b0;
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
                            CMD_WRITE_MEM: begin
                                // Only accepted while halted -- silently
                                // ignore otherwise so a stray byte can
                                // never write memory out from under a
                                // running program.
                                if (halt) begin
                                    mem_is_write <= 1'b1;
                                    rx_byte_idx  <= 2'd0;
                                    state        <= RECV_MEM_ADDR;
                                end
                            end
                            CMD_READ_MEM: begin
                                if (halt) begin
                                    mem_is_write <= 1'b0;
                                    rx_byte_idx  <= 2'd0;
                                    state        <= RECV_MEM_ADDR;
                                end
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

                // Assemble the 4-byte little-endian address for
                // WRITE_MEM/READ_MEM. Bottom 2 bits of the address are
                // discarded by the word-addressed dp_ram port, matching
                // dmem_addr/imem_addr elsewhere in the design.
                RECV_MEM_ADDR: begin
                    if (rx_done) begin
                        mem_addr[8*rx_byte_idx +: 8] <= rx_data;
                        if (rx_byte_idx == 2'd3) begin
                            rx_byte_idx <= 2'd0;
                            state       <= mem_is_write ? RECV_MEM_DATA : MEM_READ_WAIT;
                        end
                        else begin
                            rx_byte_idx <= rx_byte_idx + 2'd1;
                        end
                    end
                end

                // WRITE_MEM only: assemble the 4-byte little-endian data
                // word, then pulse the write for one cycle.
                RECV_MEM_DATA: begin
                    if (rx_done) begin
                        mem_wdata[8*rx_byte_idx +: 8] <= rx_data;
                        if (rx_byte_idx == 2'd3) begin
                            rx_byte_idx <= 2'd0;
                            state       <= MEM_WRITE_PULSE;
                        end
                        else begin
                            rx_byte_idx <= rx_byte_idx + 2'd1;
                        end
                    end
                end

                // dbg_mem_we is asserted combinationally off this state
                // (see dbg_mem_we assign above) -- one clk cycle is
                // enough for the dp_ram write port, same timing the core
                // itself relies on for stores.
                MEM_WRITE_PULSE: begin
                    state <= CMD_IDLE;
                end

                // dbg_mem_valid steers BRAM port B to mem_addr this cycle
                // (see assign above); dp_ram's read data lags by the
                // memory's read latency, so wait one cycle before
                // latching dbg_mem_rdata.
                MEM_READ_WAIT: begin
                    state <= MEM_READ_LATCH;
                end

                MEM_READ_LATCH: begin
                    cur_word   <= dbg_mem_rdata;
                    word_count <= 6'd1;
                    byte_sel   <= 2'd0;
                    state      <= SEND_BYTE_START;
                end

                default: state <= CMD_IDLE;
            endcase
        end
    end

endmodule
