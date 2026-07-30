// src/peripherals/dp_ram_sync_read.sv
//
// Simple dual-port, fully-synchronous-read/write RAM. Both ports register
// their address and data every clock -- no combinational read path -- so
// Quartus reliably infers this as block RAM instead of falling back to
// distributed RAM/LEs (see README.md's "Notes for future improvement").
// Extracted from src/peripherals/vga_spi.sv so vga_framebuffer.sv and
// vga_spi.sv can share one definition instead of duplicating it.
module dp_ram_sync_read #(
    parameter DATA_WIDTH = 8,
    parameter MEM_DEPTH  = 1024,
    parameter ADDR_WIDTH = $clog2(MEM_DEPTH)
) (
    input  logic                    clk,

    // Port A
    input  logic                    we_a,
    input  logic [ADDR_WIDTH-1:0]   addr_a,
    input  logic [DATA_WIDTH-1:0]   din_a,
    output logic [DATA_WIDTH-1:0]   dout_a,

    // Port B
    input  logic                    we_b,
    input  logic [ADDR_WIDTH-1:0]   addr_b,
    input  logic [DATA_WIDTH-1:0]   din_b,
    output logic [DATA_WIDTH-1:0]   dout_b
);

    logic [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    always_ff @(posedge clk) begin
        if (we_a) begin
            mem[addr_a] <= din_a;
        end
        dout_a <= mem[addr_a];
    end

    always_ff @(posedge clk) begin
        if (we_b) begin
            mem[addr_b] <= din_b;
        end
        dout_b <= mem[addr_b];
    end

endmodule
