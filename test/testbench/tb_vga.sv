// test/testbench/tb_vga.sv
//
// Minimal pass-through wrapper around vga_framebuffer.sv so cocotb can
// drive its dmem-bus-slice ports directly, without needing a full core/
// riscv_top stack in the loop -- test_vga.py exercises draw/peek buffer
// addressing, DOUBLE_BUF_EN/SWAP/SWAP_PENDING timing, and hsync/vsync
// generation against this module in isolation.
module tb_vga (
    input  logic        clk,
    input  logic        rst,

    input  logic         sel,
    input  logic [15:0]  addr,
    input  logic [31:0]  wdata,
    input  logic         we,
    input  logic         re,
    output logic [31:0]  rdata,

    output logic         hsync,
    output logic         vsync,
    output logic         mono_pixel
);

    vga_framebuffer u_vga (
        .clk        (clk),
        .rst        (rst),
        .sel        (sel),
        .addr       (addr),
        .wdata      (wdata),
        .we         (we),
        .re         (re),
        .rdata      (rdata),
        .hsync      (hsync),
        .vsync      (vsync),
        .mono_pixel (mono_pixel)
    );

endmodule
