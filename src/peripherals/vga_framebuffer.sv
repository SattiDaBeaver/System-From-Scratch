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
// Clocking: this module runs directly off the board's full-rate clock
// (e.g. CLOCK_50) rather than a pre-divided clock supplied by the caller
// -- CLK_DIV generates an internal pixel-rate enable for the H/V timing
// counters and scanout only; the bus-facing register/buffer read/write
// logic below runs every `clk` edge, unthrottled (mirrors
// src/peripherals/vga_spi.sv's `vga` submodule's own CLK_DIV pattern).
// Because the caller's core/bus clock is itself derived from the same
// oscillator this module's `clk` is tied to (mesochronous, not a truly
// independent asynchronous clock), the dmem-bus inputs below (sel/addr/
// wdata/we/re) are sampled directly with no CDC synchronizers -- see
// docs/dev_log.md for this session's reasoning.
//
// Storage: both physical buffers are dp_ram_sync_read instances (see
// src/peripherals/dp_ram_sync_read.sv) instead of raw arrays read/written
// directly -- keeps every access synchronous-read so Quartus reliably
// infers block RAM rather than falling back to distributed RAM/LEs.
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
//
// Read latency: VGA_CTRL/VGA_STATUS reads are 1 cycle (plain registers).
// Draw/peek buffer reads are 2 cycles (1 for dp_ram_sync_read's own
// registered read port, 1 for the outer register/buffer read mux below)
// -- callers must hold sel/addr/re for 2 clock edges and sample rdata
// after the second, not the first.
module vga_framebuffer #(
    parameter CLK_DIV = 2   // clk / CLK_DIV = pixel-timing advance rate
) (
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
    //  Pixel-rate enable -- divides `clk` down to the actual VGA pixel
    //  clock (CLK_DIV=2 against a 50MHz `clk` -> 25MHz pixel rate, the
    //  same effective rate this design already used when the caller
    //  supplied an externally-pre-divided clk).
    // ──────────────────────────────────────
    localparam CLK_DIV_BITS = (CLK_DIV > 1) ? $clog2(CLK_DIV) : 1;

    logic                    pixel_en;
    logic [CLK_DIV_BITS-1:0] clk_div_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            pixel_en      <= 1'b0;
            clk_div_count <= '0;
        end else if (clk_div_count == CLK_DIV - 1) begin
            pixel_en      <= 1'b1;
            clk_div_count <= '0;
        end else begin
            pixel_en      <= 1'b0;
            clk_div_count <= clk_div_count + 1'b1;
        end
    end

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
        end else if (pixel_en) begin
            if (h_count == H_COUNT_MAX - 1) begin
                h_count <= '0;
                v_count <= (v_count == V_COUNT_MAX - 1) ? '0 : v_count + 1;
            end else begin
                h_count <= h_count + 1;
            end
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
    //  Each buffer is a dp_ram_sync_read: port A is the CPU draw/peek
    //  read+write port, port B is scanout-only read.
    // ──────────────────────────────────────
    localparam BUF_WORDS = 600;  // 120 rows * 5 words/row
    localparam BUF_ADDR_BITS = $clog2(BUF_WORDS);

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
    //  CPU-side buffer word address + write decode
    // ──────────────────────────────────────
    logic [9:0] buf_word_addr;
    logic       buf_word_addr_valid;
    logic [BUF_ADDR_BITS-1:0] cpu_word_addr;

    assign buf_word_addr       = addr[11:2];
    assign buf_word_addr_valid = buf_word_addr < BUF_WORDS;
    assign cpu_word_addr        = buf_word_addr_valid ? buf_word_addr[BUF_ADDR_BITS-1:0] : '0;

    logic is_draw_write;
    logic buf0_we_cpu, buf1_we_cpu;

    assign is_draw_write = sel && we && addr[15:12] == 4'h1 && buf_word_addr_valid;
    assign buf0_we_cpu    = is_draw_write && !draw_buf_sel;
    assign buf1_we_cpu    = is_draw_write && draw_buf_sel;

    // ──────────────────────────────────────
    //  Scanout word address (port B, read-only)
    // ──────────────────────────────────────
    logic [BUF_ADDR_BITS-1:0] scan_word_addr;
    logic [4:0]                scan_bit;

    assign scan_word_addr = ({3'b0, fb_y} * 5 + {2'b0, fb_x[7:5]});
    assign scan_bit       = fb_x[4:0];

    // ──────────────────────────────────────
    //  Physical buffer storage
    // ──────────────────────────────────────
    logic [31:0] buf0_cpu_dout, buf1_cpu_dout;
    logic [31:0] buf0_scan_dout, buf1_scan_dout;

    dp_ram_sync_read #(
        .DATA_WIDTH (32),
        .MEM_DEPTH  (BUF_WORDS)
    ) u_buf0 (
        .clk    (clk),
        .we_a   (buf0_we_cpu),
        .addr_a (cpu_word_addr),
        .din_a  (wdata),
        .dout_a (buf0_cpu_dout),
        .we_b   (1'b0),
        .addr_b (scan_word_addr),
        .din_b  (32'b0),
        .dout_b (buf0_scan_dout)
    );

    dp_ram_sync_read #(
        .DATA_WIDTH (32),
        .MEM_DEPTH  (BUF_WORDS)
    ) u_buf1 (
        .clk    (clk),
        .we_a   (buf1_we_cpu),
        .addr_a (cpu_word_addr),
        .din_a  (wdata),
        .dout_a (buf1_cpu_dout),
        .we_b   (1'b0),
        .addr_b (scan_word_addr),
        .din_b  (32'b0),
        .dout_b (buf1_scan_dout)
    );

    // ──────────────────────────────────────
    //  Register / draw-buffer / peek-buffer read mux
    //  buf0_cpu_dout/buf1_cpu_dout already carry dp_ram_sync_read's own
    //  1-cycle registered-read latency relative to cpu_word_addr, so the
    //  decode driving this mux must itself be registered one cycle behind
    //  the address/sel/re that produced them -- otherwise this mux would
    //  pair up "now"'s decode with "last cycle"'s buffer data. Net result:
    //  draw/peek reads take 2 cycles total; VGA_CTRL/VGA_STATUS reads
    //  (plain registers, no RAM latency) also take 2 cycles here so
    //  callers don't need to special-case which address range they hit.
    // ──────────────────────────────────────
    logic        sel_d, re_d;
    logic [15:0] addr_d;
    logic        draw_buf_sel_d, peek_buf_sel_d;
    logic        buf_word_addr_valid_d;

    always_ff @(posedge clk) begin
        if (rst) begin
            sel_d                 <= 1'b0;
            re_d                  <= 1'b0;
            addr_d                <= 16'b0;
            draw_buf_sel_d        <= 1'b0;
            peek_buf_sel_d        <= 1'b0;
            buf_word_addr_valid_d <= 1'b0;
        end else begin
            sel_d                 <= sel;
            re_d                  <= re;
            addr_d                <= addr;
            draw_buf_sel_d        <= draw_buf_sel;
            peek_buf_sel_d        <= peek_buf_sel;
            buf_word_addr_valid_d <= buf_word_addr_valid;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rdata <= 32'b0;
        end else begin
            rdata <= 32'b0;
            if (sel_d && re_d) begin
                case (addr_d[15:12])
                    4'h0: begin
                        case (addr_d[3:2])
                            2'b00: rdata <= {31'b0, double_buf_en};
                            2'b01: rdata <= {31'b0, swap_pending};
                            default: rdata <= 32'b0;
                        endcase
                    end
                    4'h1: rdata <= buf_word_addr_valid_d ?
                                  (draw_buf_sel_d ? buf1_cpu_dout : buf0_cpu_dout) : 32'b0;
                    4'h2: rdata <= buf_word_addr_valid_d ?
                                  (peek_buf_sel_d ? buf1_cpu_dout : buf0_cpu_dout) : 32'b0;
                    default: rdata <= 32'b0;
                endcase
            end
        end
    end

    // ──────────────────────────────────────
    //  Scanout -- buf0_scan_dout/buf1_scan_dout already carry
    //  dp_ram_sync_read's own registered-read latency relative to
    //  scan_word_addr, matching this block's previous manual one-cycle
    //  scan_word register -- no extra register needed here.
    // ──────────────────────────────────────
    logic [31:0] scan_word;
    assign scan_word = front_buf ? buf1_scan_dout : buf0_scan_dout;

    always_ff @(posedge clk) begin
        if (rst) begin
            mono_pixel <= 1'b0;
        end else begin
            mono_pixel <= active && scan_word[scan_bit];
        end
    end

endmodule
