// src/peripherals/vga_framebuffer.sv
//
// Self-contained 160x120 1bpp (monochrome) VGA framebuffer peripheral --
// see docs/01_architecture.md for the memory map and design rationale.
// Single/double-buffer mode, tear-safe vsync-edge-gated swap, and all
// draw/debug-peek buffer-select muxing live entirely in this module so it
// can be dropped into other CPU-driven-VGA projects unmodified: the
// caller (e.g. riscv_top.sv) only needs to wire in a dmem bus slice plus
// a pixel clock/reset and hsync/vsync/mono_pixel out -- no VGA-specific
// logic of its own. Board-specific RGB bit-width replication (e.g. this
// project's 4-bit VGA_R/G/B) is left to the caller, deliberately, so this
// module doesn't assume any particular RGB DAC width.
//
// Single clock domain throughout (matches the rest of this SoC -- see
// riscv_top.sv's "Single 25MHz system clock for everything" comment): the
// caller's dmem bus and the VGA timing generator both run off the same
// `clk`/`rst`, so there's no CDC anywhere in this module. 25MHz also
// happens to be the correct pixel clock for standard 640x480@60Hz timing,
// which is what the internal H/V counters below generate, scaled 4x to
// map the 160x120 framebuffer onto a 640x480 display 1 framebuffer pixel
// -> 4x4 screen pixels.
//
// Register map (relative to whatever base address the caller decodes --
// see docs/01_architecture.md for the concrete 0x2000_0000-based addresses
// used in this project):
//   offset 0x0000        VGA_CTRL   bit0 = DOUBLE_BUF_EN, bit1 = SWAP (write-1-to-request)
//   offset 0x0004        VGA_STATUS bit0 = SWAP_PENDING (read-only)
//   offset 0x1000-0x1FFF VGA draw buffer       -- fixed logical address, remapped
//                                                  internally to whichever physical
//                                                  buffer software should draw into
//   offset 0x2000-0x2FFF VGA debug-peek buffer -- fixed logical address, always the
//                                                  physical buffer NOT mapped at the
//                                                  draw address
module vga_framebuffer (
    input  logic        clk,
    input  logic        rst,

    // ── dmem bus slice (caller has already decoded that this peripheral's
    //    address range is selected -- `sel` gates writes/reads same as
    //    uart_sel/bram_sel do for their peripherals in riscv_top.sv) ──
    input  logic         sel,
    input  logic [15:0]  addr,      // offset within this peripheral's region
    input  logic [31:0]  wdata,
    input  logic         we,
    input  logic         re,
    output logic [31:0]  rdata,

    // ── VGA timing/scanout output -- caller replicates mono_pixel out to
    //    however many RGB DAC bits its board has ──
    output logic         hsync,
    output logic         vsync,
    output logic         mono_pixel
);

    // ──────────────────────────────────────
    //  Timing generator (640x480@60Hz, standard front/back porch numbers)
    // ──────────────────────────────────────
    localparam H_COUNT_MAX = 800;
    localparam V_COUNT_MAX = 525;
    localparam H_BITS = $clog2(H_COUNT_MAX);
    localparam V_BITS = $clog2(V_COUNT_MAX);

    logic [H_BITS-1:0] h_count;
    logic [V_BITS-1:0] v_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            h_count <= '0;
            v_count <= '0;
        end else if (h_count == H_COUNT_MAX - 1) begin
            h_count <= '0;
            v_count <= (v_count == V_COUNT_MAX - 1) ? '0 : v_count + 1;
        end else begin
            h_count <= h_count + 1;
        end
    end

    assign hsync = (h_count < 96) ? 1'b0 : 1'b1;  // active low
    assign vsync = (v_count < 2)  ? 1'b0 : 1'b1;  // active low

    // 640x480 active window, 4x4 upscale onto the 160x120 framebuffer.
    logic       active;
    logic [9:0] screen_x, screen_y;  // 0..639, 0..479 within the active window
    logic [7:0] fb_x;                // 0..159
    logic [6:0] fb_y;                // 0..119

    assign active   = (h_count >= 144 && h_count < 784) &&
                       (v_count >= 35  && v_count < 515);
    assign screen_x = active ? (h_count - 144) : '0;
    assign screen_y = active ? (v_count - 35)  : '0;
    assign fb_x     = screen_x[9:2];  // /4
    assign fb_y     = screen_y[8:2];  // /4

    // Pulses once per frame, at the vsync edge that starts the next frame
    // -- the single point a pending swap is ever allowed to apply, so a
    // swap can never land mid-scanout (tear-free by construction).
    logic frame_start;
    assign frame_start = (h_count == '0) && (v_count == '0);

    // ──────────────────────────────────────
    //  Physical buffers -- two 160x120x1bpp buffers, row stride 5 words
    //  (20B) per 160-pixel row: pixel (x,y) -> word y*5 + x/32, bit x%32.
    // ──────────────────────────────────────
    localparam BUF_WORDS = 600;  // 120 rows * 5 words/row

    logic [31:0] buffer0 [0:BUF_WORDS-1];
    logic [31:0] buffer1 [0:BUF_WORDS-1];

    // ──────────────────────────────────────
    //  Mode/swap control state
    // ──────────────────────────────────────
    logic double_buf_en;
    logic front_buf;      // 0 = buffer0 currently scanned out, 1 = buffer1
    logic swap_pending;

    // Single-buffer mode: draws go straight to the buffer being scanned
    // out (real-time, tearing possible). Double-buffer mode: draws go to
    // the back buffer only, swap is explicit and vsync-gated.
    logic draw_buf_sel;  // which physical buffer the draw address maps to
    logic peek_buf_sel;  // always the OTHER physical buffer

    assign draw_buf_sel = double_buf_en ? !front_buf : front_buf;
    assign peek_buf_sel = !draw_buf_sel;

    always_ff @(posedge clk) begin
        if (rst) begin
            double_buf_en <= 1'b0;
            front_buf     <= 1'b0;
            swap_pending  <= 1'b0;
        end else begin
            if (sel && we && addr[15:0] == 16'h0000) begin
                double_buf_en <= wdata[0];
                // A SWAP request in single-buffer mode is a no-op -- there's
                // no back buffer to bring forward, not an error -- so
                // software can leave SWAP=1 in place across a DOUBLE_BUF_EN
                // toggle without special-casing it.
                if (wdata[1] && wdata[0]) swap_pending <= 1'b1;
            end

            // Applied only at the frame boundary, never mid-scanout.
            if (frame_start && swap_pending) begin
                front_buf    <= !front_buf;
                swap_pending <= 1'b0;
            end
        end
    end

    // ──────────────────────────────────────
    //  Register / draw-buffer / peek-buffer write decode
    // ──────────────────────────────────────
    logic [9:0] buf_word_addr;
    assign buf_word_addr = addr[11:2];

    always_ff @(posedge clk) begin
        if (sel && we) begin
            if (addr[15:12] == 4'h1 && buf_word_addr < BUF_WORDS) begin
                if (draw_buf_sel) buffer1[buf_word_addr] <= wdata;
                else              buffer0[buf_word_addr] <= wdata;
            end
        end
    end

    // ──────────────────────────────────────
    //  Register / draw-buffer / peek-buffer read mux
    //  CHANGED: this path is now registered so `rdata` updates on clock
    //  edges instead of being purely combinational. A reset value is also
    //  provided so the bus reads return 0 until the first valid cycle.
    // ──────────────────────────────────────
    always_ff @(posedge clk) begin
        if (rst) begin
            rdata <= 32'b0;
        end else begin
            rdata <= 32'b0;
            if (sel && re) begin
                case (addr[15:12])
                    4'h0: begin
                        case (addr[3:2])
                            2'b00: rdata <= {31'b0, double_buf_en};
                            2'b01: rdata <= {31'b0, swap_pending};
                            default: rdata <= 32'b0;
                        endcase
                    end
                    4'h1: rdata <= (buf_word_addr < BUF_WORDS) ?
                                  (draw_buf_sel ? buffer1[buf_word_addr] : buffer0[buf_word_addr]) : 32'b0;
                    4'h2: rdata <= (buf_word_addr < BUF_WORDS) ?
                                  (peek_buf_sel ? buffer1[buf_word_addr] : buffer0[buf_word_addr]) : 32'b0;
                    default: rdata <= 32'b0;
                endcase
            end
        end
    end

    // ──────────────────────────────────────
    //  Scanout -- CHANGED: the framebuffer read is now registered so the
    //  read path is synchronous as well. This makes the memory access more
    //  BRAM-friendly and matches the style Quartus prefers for inference.
    //  The pixel output is delayed by one clock cycle, which is the usual
    //  tradeoff for a synchronous read port.
    // ──────────────────────────────────────
    logic [31:0] scan_word;
    logic [4:0]  scan_bit;
    logic [9:0]  scan_word_addr;

    assign scan_word_addr = {3'b0, fb_y} * 5 + {2'b0, fb_x[7:5]};
    assign scan_bit       = fb_x[4:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            scan_word <= 32'b0;
            mono_pixel <= 1'b0;
        end else begin
            scan_word <= front_buf ? buffer1[scan_word_addr] : buffer0[scan_word_addr];
            mono_pixel <= active && scan_word[scan_bit];
        end
    end

endmodule
