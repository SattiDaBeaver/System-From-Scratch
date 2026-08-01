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
//   0x09 <addr16>  -> READ_CSR. addr16 is a 2-byte little-endian CSR
//                     address (only the low 12 bits are meaningful --
//                     RISC-V CSR addresses are 12 bits). Replies with 4
//                     bytes, little-endian, the core's dbg_csr_data for
//                     that address (mstatus/mie/mtvec/mscratch/mepc/
//                     mcause/mtval/mip; anything else reads as 0, same
//                     "unimplemented CSR reads 0" contract the core's own
//                     CSR instructions already use). Unlike READ_MEM this
//                     is not halt-gated -- CSR reads are a plain
//                     combinational core output, no memory-arbitration
//                     hazard to avoid.
//   0x0A <addr32>  -> READ_MMIO. Only accepted while halted; ignored
//                     otherwise (same restriction as READ_MEM -- this
//                     shares its host-side pacing contract). Replies with
//                     4 bytes, little-endian, the peripheral register at
//                     addr32 (UART TX/RX/STATUS at 0x1000_0000-0x0C,
//                     Timer RELOAD/CTRL/STATUS at 0x3000_0000-0x08 -- see
//                     docs/01_architecture.md's memory map). Read-only:
//                     there is deliberately no WRITE_MMIO, since poking
//                     live peripheral registers over this side-channel
//                     while a program may resume any moment has real
//                     side effects unlike BRAM (which WRITE_MEM already
//                     restricts to halted-only for the same reason).
//                     Addresses outside the covered peripherals read as
//                     0. VGA framebuffer is intentionally not covered by
//                     this command -- it already exposes a software-side
//                     debug-peek buffer address instead (see
//                     docs/01_architecture.md), and folding its
//                     multi-cycle read pipeline into this single-cycle
//                     command would risk disturbing its scanout/swap
//                     timing for no real benefit.
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

    // Debug-driven CSR read (async, combinational on the core side -- no
    // halt/timing hazard the way memory access has, see READ_CSR above).
    output logic [11:0]  dbg_csr_addr,
    input  logic [31:0]  dbg_csr_data,

    // Debug-driven BRAM port B access (hardware bootloader). dbg_mem_valid
    // tells the top-level mux to route BRAM port B's address/data/write
    // lines to these signals instead of the core's this cycle.
    output logic [31:0]  dbg_mem_addr,
    output logic [31:0]  dbg_mem_wdata,
    output logic         dbg_mem_we,
    output logic         dbg_mem_valid,
    input  logic [31:0]  dbg_mem_rdata,

    // Debug-driven MMIO peripheral read (READ_MMIO above). Top level
    // steers its uart_sel/vga_sel/timer_sel-style decoder off
    // dbg_mmio_addr instead of dmem_addr while dbg_mmio_valid is high,
    // mirroring how dbg_mem_valid already steers BRAM port B.
    output logic [31:0]  dbg_mmio_addr,
    output logic         dbg_mmio_valid,
    input  logic [31:0]  dbg_mmio_rdata,

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
    localparam logic [7:0] CMD_READ_CSR  = 8'h09;
    localparam logic [7:0] CMD_READ_MMIO = 8'h0A;

    // Widened from [3:0] to [4:0] -- the original 13 states fit in 4 bits,
    // but the 4 new CSR/MMIO states below push the count to 17, one past
    // what 4 bits can hold.
    typedef enum logic [4:0] {
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
        MEM_READ_LATCH,
        WAIT_ARG_CSR,
        RECV_MMIO_ADDR,
        MMIO_READ_WAIT,
        MMIO_READ_LATCH
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

    logic [15:0] csr_addr_pending;  // READ_CSR's 2-byte arg, assembled byte-by-byte
    logic        csr_byte_idx;      // byte within csr_addr_pending, 0 = LSB (1 bit: only 2 bytes)
    logic        reading_csr;       // SEND_LOAD mux select: word_sel can't hold a 12-bit
                                     // CSR address, so this latch picks dbg_csr_data instead
                                     // of dbg_reg_data/pc_dbg for the current SEND_LOAD pass.

    logic [31:0] mmio_addr;   // READ_MMIO target address, being assembled byte-by-byte

    // Multi-byte commands (WAIT_ARG, RECV_MEM_ADDR, RECV_MEM_DATA) assemble
    // their argument one UART byte at a time with no upper bound on how
    // long that can take. A single dropped/garbled byte on the wire (e.g.
    // a marginal RX sample) then leaves the FSM waiting forever for a byte
    // that's never coming -- permanently wedging the debugger until a
    // fresh HALT/reset. rx_timeout_cnt aborts back to CMD_IDLE instead if
    // too many clocks pass without a new byte, so a glitch costs one
    // command retry rather than the whole session.
    localparam int TIMEOUT_BIT_PERIODS = 20;
    logic [31:0] rx_timeout_cnt;

    logic        rx_done;
    logic [7:0]  rx_data;
    logic        tx_en;
    logic [7:0]  tx_data;
    logic        tx_busy;

    uart #(
        .CLK_BITS    (CLK_BITS),
        .DATA_WIDTH  (8),
        .PARITY_BITS (0),
        .STOP_BITS   (2)
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

    // Async CSR read, same style as dbg_reg_addr above -- csr_addr_pending
    // holds whatever READ_CSR's 2-byte arg assembled to, continuously
    // driving the core's combinational dbg_csr_data output.
    assign dbg_csr_addr = csr_addr_pending[11:0];

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

    // dbg_mmio_* mirror dbg_mem_* above, but for the read-only MMIO peek
    // path -- top level steers its peripheral sel decoder off
    // dbg_mmio_addr instead of dmem_addr while dbg_mmio_valid is high.
    assign dbg_mmio_addr  = mmio_addr;
    assign dbg_mmio_valid = (state == MMIO_READ_WAIT) ||
                             (state == MMIO_READ_LATCH);

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
            csr_addr_pending <= 16'd0;
            csr_byte_idx     <= 1'b0;
            reading_csr      <= 1'b0;
            mmio_addr        <= 32'd0;
            rx_timeout_cnt <= 32'd0;
        end
        else begin
            tx_en <= 1'b0; // default; pulsed high explicitly below

            // Multi-byte commands reset the counter on entry/each received
            // byte below; any other cycle just lets it free-run so it's
            // always ticking while genuinely waiting on rx_done.
            rx_timeout_cnt <= rx_timeout_cnt + 32'd1;

            case (state)
                CMD_IDLE: begin
                    if (rx_done) begin
                        case (rx_data)
                            CMD_HALT:     halt <= 1'b1;
                            CMD_RESUME:   halt <= 1'b0;
                            CMD_STEP:     state <= STEP_ASSERT;
                            CMD_READ_REG: begin
                                rx_timeout_cnt <= 32'd0;
                                state          <= WAIT_ARG;
                            end
                            CMD_READ_PC: begin
                                word_sel    <= 6'd32;
                                word_count  <= 6'd1;
                                reading_csr <= 1'b0;
                                state       <= SEND_LOAD;
                            end
                            CMD_READ_ALL: begin
                                word_sel    <= 6'd0;
                                word_count  <= 6'd33;
                                reading_csr <= 1'b0;
                                state       <= SEND_LOAD;
                            end
                            CMD_READ_CSR: begin
                                csr_byte_idx   <= 1'b0;
                                rx_timeout_cnt <= 32'd0;
                                state          <= WAIT_ARG_CSR;
                            end
                            CMD_WRITE_MEM: begin
                                // Only accepted while halted -- silently
                                // ignore otherwise so a stray byte can
                                // never write memory out from under a
                                // running program.
                                if (halt) begin
                                    mem_is_write   <= 1'b1;
                                    rx_byte_idx    <= 2'd0;
                                    rx_timeout_cnt <= 32'd0;
                                    state          <= RECV_MEM_ADDR;
                                end
                            end
                            CMD_READ_MEM: begin
                                if (halt) begin
                                    mem_is_write   <= 1'b0;
                                    rx_byte_idx    <= 2'd0;
                                    rx_timeout_cnt <= 32'd0;
                                    state          <= RECV_MEM_ADDR;
                                end
                            end
                            CMD_READ_MMIO: begin
                                // Only accepted while halted -- shares
                                // READ_MEM's host-side pacing contract.
                                if (halt) begin
                                    rx_byte_idx    <= 2'd0;
                                    rx_timeout_cnt <= 32'd0;
                                    state          <= RECV_MMIO_ADDR;
                                end
                            end
                            default: ; // ignore unknown command byte
                        endcase
                    end
                end

                WAIT_ARG: begin
                    if (rx_done) begin
                        word_sel    <= {1'b0, rx_data[4:0]}; // clamp to 0-31
                        word_count  <= 6'd1;
                        reading_csr <= 1'b0;
                        state       <= SEND_LOAD;
                    end
                    else if (rx_timeout_cnt >= clk_per_bit * TIMEOUT_BIT_PERIODS) begin
                        state <= CMD_IDLE; // arg byte never arrived -- give up and re-sync
                    end
                end

                // Assemble READ_CSR's 2-byte little-endian CSR address,
                // same byte-at-a-time style as RECV_MEM_ADDR below but
                // half the width.
                WAIT_ARG_CSR: begin
                    if (rx_done) begin
                        csr_addr_pending[8*csr_byte_idx +: 8] <= rx_data;
                        rx_timeout_cnt <= 32'd0;
                        if (csr_byte_idx == 1'b1) begin
                            word_count  <= 6'd1;
                            reading_csr <= 1'b1;
                            state       <= SEND_LOAD;
                        end
                        else begin
                            csr_byte_idx <= 1'b1;
                        end
                    end
                    else if (rx_timeout_cnt >= clk_per_bit * TIMEOUT_BIT_PERIODS) begin
                        state <= CMD_IDLE; // arg byte never arrived -- give up and re-sync
                    end
                end
                STEP_ASSERT: begin
                    halt  <= 1'b0;
                    state <= STEP_DEASSERT;
                end

                STEP_DEASSERT: begin
                    halt  <= 1'b1;
                    state <= CMD_IDLE;
                end

                SEND_LOAD: begin
                    cur_word <= reading_csr    ? dbg_csr_data :
                                (word_sel < 6'd32) ? dbg_reg_data : pc_dbg;
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
                        rx_timeout_cnt <= 32'd0;
                        if (rx_byte_idx == 2'd3) begin
                            rx_byte_idx <= 2'd0;
                            state       <= mem_is_write ? RECV_MEM_DATA : MEM_READ_WAIT;
                        end
                        else begin
                            rx_byte_idx <= rx_byte_idx + 2'd1;
                        end
                    end
                    else if (rx_timeout_cnt >= clk_per_bit * TIMEOUT_BIT_PERIODS) begin
                        state <= CMD_IDLE; // stalled mid-address -- give up and re-sync
                    end
                end

                // WRITE_MEM only: assemble the 4-byte little-endian data
                // word, then pulse the write for one cycle.
                RECV_MEM_DATA: begin
                    if (rx_done) begin
                        mem_wdata[8*rx_byte_idx +: 8] <= rx_data;
                        rx_timeout_cnt <= 32'd0;
                        if (rx_byte_idx == 2'd3) begin
                            rx_byte_idx <= 2'd0;
                            state       <= MEM_WRITE_PULSE;
                        end
                        else begin
                            rx_byte_idx <= rx_byte_idx + 2'd1;
                        end
                    end
                    else if (rx_timeout_cnt >= clk_per_bit * TIMEOUT_BIT_PERIODS) begin
                        state <= CMD_IDLE; // stalled mid-data -- give up and re-sync
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

                // Assemble the 4-byte little-endian address for
                // READ_MMIO. No write branch -- there is deliberately no
                // WRITE_MMIO (see header comment above).
                RECV_MMIO_ADDR: begin
                    if (rx_done) begin
                        mmio_addr[8*rx_byte_idx +: 8] <= rx_data;
                        rx_timeout_cnt <= 32'd0;
                        if (rx_byte_idx == 2'd3) begin
                            rx_byte_idx <= 2'd0;
                            state       <= MMIO_READ_WAIT;
                        end
                        else begin
                            rx_byte_idx <= rx_byte_idx + 2'd1;
                        end
                    end
                    else if (rx_timeout_cnt >= clk_per_bit * TIMEOUT_BIT_PERIODS) begin
                        state <= CMD_IDLE; // stalled mid-address -- give up and re-sync
                    end
                end

                // dbg_mmio_valid steers the top level's peripheral decoder
                // to mmio_addr this cycle (see assign above); wait one
                // cycle before latching dbg_mmio_rdata, same reasoning as
                // MEM_READ_WAIT above.
                MMIO_READ_WAIT: begin
                    state <= MMIO_READ_LATCH;
                end

                MMIO_READ_LATCH: begin
                    cur_word    <= dbg_mmio_rdata;
                    word_count  <= 6'd1;
                    byte_sel    <= 2'd0;
                    reading_csr <= 1'b0;
                    state       <= SEND_BYTE_START;
                end

                default: state <= CMD_IDLE;
            endcase
        end
    end

endmodule
