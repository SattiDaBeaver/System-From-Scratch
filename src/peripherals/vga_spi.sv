/*
Code modified from my other projects: 
SattiDaBeaver, “SystemVerilog Module Library (SVML).” 
GitHub. Accessed: Apr. 5, 2026. [Online]. 
Available: https://github.com/SattiDaBeaver/SVML/tree/main/Module-Library/VGA_SPI
*/

module vga_spi #(
    parameter RES_X = 320,
    parameter RES_Y = 240,
    parameter RES_DIV = 2,
    parameter MEM_WIDTH = 8,
    parameter MEM_DEPTH = RES_X * RES_Y,
    parameter ADDR_WIDTH = $clog2(MEM_DEPTH),
    parameter PIXEL_WIDTH = 4
) (
    // Default wires
    input  logic                    clk, 
    input  logic                    rst,

    // SPI wires
    input  logic                    sclk,
    input  logic                    cs_n,
    input  logic                    mosi,
    output logic                    miso,

    // VGA wires
    output logic [PIXEL_WIDTH-1:0]  vga_r,
    output logic [PIXEL_WIDTH-1:0]  vga_g,
    output logic [PIXEL_WIDTH-1:0]  vga_b,
    output logic                    h_sync,
    output logic                    v_sync,

    // Debug memory wires
    output logic [ADDR_WIDTH-1:0]   addr_count,
    output logic [MEM_WIDTH-1:0]    spi_dout_debug
);

    // Local parameters
    localparam 
        CLK_DIV     = 2,
        H_COUNT_MAX = 800,
        V_COUNT_MAX = 525,
        H_BITS      = $clog2(H_COUNT_MAX),
        V_BITS      = $clog2(V_COUNT_MAX),
        CLK_BITS    = 8,
        DATA_WIDTH  = MEM_WIDTH;

    // Helper wires
    // Memory helper wires
    logic [ADDR_WIDTH-1:0]  mem_addr;
    logic [MEM_WIDTH-1:0]   din;
    logic                   wen;
    logic                   swap_buf;
    logic                   swap_done;
    logic [MEM_WIDTH-1:0]   dout; // unused
    logic                   addr_delay;

    // SPI helper wires
    logic [MEM_WIDTH-1:0]   din_spi; // unused
    logic                   d_valid_spi;
    logic [MEM_WIDTH-1:0]   dout_spi;

    // Helper assignments
    assign mem_addr         = addr_count;
    assign spi_dout_debug   = din;
    assign din_spi          = 8'h00;

    /* Pixel logic
    -  pixel[7] == 1        => control bit
        -  pixel[0] == 1    => swap buffer
        -  else             => align counter
    -  else                 => pixel in RGB
        -  0b00RRGGBB       => format (6-bits)
    */ 

    always_ff @(posedge clk) begin
        if (rst) begin
            addr_count <= 0;
            wen        <= 1'b0;
            addr_delay <= 1'b0;
            swap_buf   <= 1'b0;
        end
        else begin
            wen        <= 1'b0;
            swap_buf   <= 1'b0;
            if (d_valid_spi) begin
                if (dout_spi[7] == 1'b1) begin   // control bit
                    case (dout_spi[6:0])
                        7'h00: begin
                            addr_count  <= 0;
                            wen         <= 1'b0;
                            addr_delay  <= 1'b0;
                        end
                        7'h01: begin
                            swap_buf    <= 1'b1;
                        end 
                        default: begin
                            addr_count  <= 0;
                            wen         <= 1'b0;
                            addr_delay  <= 1'b0;
                            swap_buf    <= 1'b0;
                        end
                    endcase
                end
                else begin
                    din         <= dout_spi;
                    wen         <= 1'b1;
                    if (addr_count >= MEM_DEPTH - 1) begin
                        addr_count  <= 0;
                    end
                    else begin
                        if (addr_delay == 1'b1) begin
                            addr_count  <= addr_count + 1;
                            // addr_delay  <= 1'b0;
                        end
                        else begin
                            addr_delay  <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    // Module instantiation
	vga_double_buf #(
        .RES_X(RES_X),
        .RES_Y(RES_Y),
        .MEM_WIDTH(DATA_WIDTH)
    ) VGA (
        .clk(clk),
        .rst(rst),
        .mem_addr(mem_addr),
        .din(din),
        .wen(wen),
        .swap_buf(swap_buf),
        .swap_done(swap_done),
        .dout(dout),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .h_sync(h_sync),
        .v_sync(v_sync)
    );

    spi_slave #(
        .WIDTH(MEM_WIDTH)
        ) SPI (
        .clk(clk),
        .rst(rst),
        .sclk(sclk),
        .cs_n(cs_n),
        .mosi(mosi),
        .miso(miso),
        .din(din_spi),
        .d_valid(d_valid_spi),
        .dout(dout_spi)
    );
    
endmodule

module vga_double_buf #(
    parameter RES_X = 320,
    parameter RES_Y = 240,
    parameter RES_DIV = 2,
    parameter MEM_WIDTH = 8,
    parameter MEM_DEPTH = RES_X * RES_Y,
    parameter ADDR_WIDTH = $clog2(MEM_DEPTH),
    parameter PIXEL_WIDTH = 4
) (
    // Default wires
    input  logic                    clk, 
    input  logic                    rst,

    // Memory wires
    input  logic [ADDR_WIDTH-1:0]   mem_addr,
    input  logic [MEM_WIDTH-1:0]    din,
    input  logic                    wen,
    input  logic                    swap_buf,
    output logic                    swap_done,
    output logic [MEM_WIDTH-1:0]    dout, // unused

    // VGA wires
    output logic [PIXEL_WIDTH-1:0]  vga_r,
    output logic [PIXEL_WIDTH-1:0]  vga_g,
    output logic [PIXEL_WIDTH-1:0]  vga_b,
    output logic                    h_sync,
    output logic                    v_sync
);

    // Local parameters
    localparam 
        CLK_DIV     = 2,
        H_COUNT_MAX = 800,
        V_COUNT_MAX = 525,
        H_BITS      = $clog2(H_COUNT_MAX),
        V_BITS      = $clog2(V_COUNT_MAX);

    // Double buffer helper wires
    logic                       curr_buffer;
    logic                       swap_latch;

    // VGA helper wires
    logic [$clog2(RES_X)-1:0]   mem_x;
    logic [$clog2(RES_Y)-1:0]   mem_y;
    logic [H_BITS-1:0]          vga_x;
    logic [V_BITS-1:0]          vga_y;
    logic                       vga_active;
    logic                       frame_start;

    // Memory helper wires
    // Memory assignment helpers
    // Port A
    logic                       we_a;
    logic [ADDR_WIDTH-1:0]      addr_a;
    logic [MEM_WIDTH-1:0]       din_a;
    logic [MEM_WIDTH-1:0]       dout_a;

    // Port B
    // logic                       we_b;
    logic [ADDR_WIDTH-1:0]      addr_b;
    // logic [MEM_WIDTH-1:0]      din_b;
    logic [MEM_WIDTH-1:0]       dout_b;

    // Memory 0
    // Port A
    logic                       we_a_0;
    logic [ADDR_WIDTH-1:0]      addr_a_0;
    logic [MEM_WIDTH-1:0]       din_a_0;
    logic [MEM_WIDTH-1:0]       dout_a_0;

    // Port B
    // logic                       we_b_0;
    logic [ADDR_WIDTH-1:0]      addr_b_0;
    // logic [MEM_WIDTH-1:0]      din_b_0;
    logic [MEM_WIDTH-1:0]       dout_b_0;

    // Memory 1
    // Port A
    logic                       we_a_1;
    logic [ADDR_WIDTH-1:0]      addr_a_1;
    logic [MEM_WIDTH-1:0]       din_a_1;
    logic [MEM_WIDTH-1:0]       dout_a_1;

    // Port B
    // logic                       we_b_1;
    logic [ADDR_WIDTH-1:0]      addr_b_1;
    // logic [MEM_WIDTH-1:0]      din_b_1;
    logic [MEM_WIDTH-1:0]       dout_b_1;

    // Internal wires
    logic [ADDR_WIDTH-1:0]      mem_addr_vga;
    logic [MEM_WIDTH-1:0]       mem_d_out_vga;    

    // Wire assignment
    // Memory inputs
    assign addr_a   = mem_addr;
    assign din_a    = din;
    assign we_a     = wen;
    // Memory output
    assign dout     = dout_a;

    // VGA output
    // Using 0b00RRGGBB format
    assign vga_r    = vga_active ? {dout_b[5:4], 2'b00} : 4'b0000;
    assign vga_g    = vga_active ? {dout_b[3:2], 2'b00} : 4'b0000;
    assign vga_b    = vga_active ? {dout_b[1:0], 2'b00} : 4'b0000;

    // VGA memory assignments
    // Assuming smart synthesizer
    assign mem_x    = vga_x / RES_DIV; 
    assign mem_y    = vga_y / RES_DIV;
    assign addr_b   = mem_x + mem_y * RES_X;

    // // Assuming dumb synthesizer
    // assign mem_x    = vga_x >> 1;
    // assign mem_y    = vga_y >> 1;
    // assign addr_b   = mem_x + (vga_y << 6) + (vga_x << 8);  

    // Double Buffer MUX
    // Read mux (combinational)
    assign dout_a = (curr_buffer == 0) ? dout_a_1 : dout_a_0;
    assign dout_b = (curr_buffer == 0) ? dout_b_1 : dout_b_0;

    // Write mux (controlled)
    assign we_a_0   = (curr_buffer == 0) ? we_a : 0;
    assign din_a_0  = (curr_buffer == 0) ? din_a : 0;
    assign addr_a_0 = (curr_buffer == 0) ? addr_a : 0;

    assign we_a_1   = (curr_buffer == 1) ? we_a : 0;
    assign din_a_1  = (curr_buffer == 1) ? din_a : 0;
    assign addr_a_1 = (curr_buffer == 1) ? addr_a : 0;

    // Port B is always VGA read
    assign addr_b_0 = addr_b;
    assign addr_b_1 = addr_b;

    // Swap buffer logic
    always_ff @(posedge clk) begin
        if (rst) begin
            swap_latch  <= 1'b0;
            curr_buffer <= 1'b0;
            swap_done   <= 1'b0;
        end
        else begin
            swap_done   <= 1'b0;
            if (swap_buf) begin
                swap_latch  <= 1'b1;
            end
            if (frame_start) begin
                if (swap_latch) begin
                    curr_buffer <= curr_buffer ^ 1; // toggle current buffer
                    swap_latch  <= 1'b0;
                    swap_done   <= 1'b1;
                end
            end 
        end
    end

    // Module instantiation
    vga #(
        .PIXEL_BITS(PIXEL_WIDTH),
        .CLK_DIV(CLK_DIV),
        .H_COUNT_MAX(H_COUNT_MAX),
        .V_COUNT_MAX(V_COUNT_MAX)
    ) VGA (
        .clk(clk),
        .rst(rst),
        .vga_r(),
        .vga_g(),
        .vga_b(),
        .h_sync(h_sync),
        .v_sync(v_sync),
        .vga_x(vga_x),
        .vga_y(vga_y),
        .vga_active(vga_active),
        .frame_start(frame_start)
    );

    dp_ram_sync_read #(
        .DATA_WIDTH(MEM_WIDTH),
        .MEM_DEPTH(MEM_DEPTH)
    ) RAM_0 (
        .clk(clk),
        .we_a(we_a_0),
        .addr_a(addr_a_0),
        .din_a(din_a_0),
        .dout_a(dout_a_0),
        .we_b(),
        .addr_b(addr_b_0),
        .din_b(),
        .dout_b(dout_b_0)
    );

    dp_ram_sync_read #(
        .DATA_WIDTH(MEM_WIDTH),
        .MEM_DEPTH(MEM_DEPTH)
    ) RAM_1 (
        .clk(clk),
        .we_a(we_a_1),
        .addr_a(addr_a_1),
        .din_a(din_a_1),
        .dout_a(dout_a_1),
        .we_b(),
        .addr_b(addr_b_1),
        .din_b(),
        .dout_b(dout_b_1)
    );
    
endmodule

module vga #(
    parameter PIXEL_BITS    = 4,
    parameter CLK_DIV       = 2,
    parameter H_COUNT_MAX   = 800,
    parameter V_COUNT_MAX   = 525,
    parameter H_BITS        = $clog2(H_COUNT_MAX),
    parameter V_BITS        = $clog2(V_COUNT_MAX)

) (
    input  logic                  clk, 
    input  logic                  rst,

    output logic [PIXEL_BITS-1:0] vga_r,
    output logic [PIXEL_BITS-1:0] vga_g,
    output logic [PIXEL_BITS-1:0] vga_b,
    
    output logic                  h_sync,
    output logic                  v_sync,
    output logic [H_BITS-1:0]     vga_x,
    output logic [V_BITS-1:0]     vga_y,
    output logic                  vga_active,
    output logic                  frame_start
);

    // Clock divider (25MHz enable logic)
    localparam CLK_DIV_BITS = $clog2(CLK_DIV);

    logic                       vga_en; // 25 MHz enable
    logic [CLK_DIV_BITS-1:0]    clk_div_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            vga_en          <= 0;
            clk_div_count   <= 0;
        end
        else begin
            if (clk_div_count == CLK_DIV - 1) begin
                vga_en          <= 1;
                clk_div_count   <= 0;
            end
            else begin
                vga_en          <= 0;
                clk_div_count   <= clk_div_count + 1;
            end
        end
    end

    // Horizontal and Vertical Counter
    logic [H_BITS-1:0]  h_count;
    logic [V_BITS-1:0]  v_count;

    always_ff @(posedge clk) begin
        if (rst) begin
            h_count <= 0;
            v_count <= 0;
        end
        else if (vga_en) begin
            // Horizontal Counter
            if (h_count == H_COUNT_MAX - 1) begin
                h_count <= 0;

                // Vertical Counter
                if (v_count == V_COUNT_MAX - 1) begin
                    v_count <= 0;
                end
                else begin
                    v_count <= v_count + 1;
                end
            end
            else begin
                h_count <= h_count + 1;
            end
        end
    end

    // H-Sync and V-Sync signals
    assign h_sync = (h_count < 96) ? 0 : 1; // active low
    assign v_sync = (v_count < 2) ? 0 : 1;  // active low

    // RGB colors
    assign vga_active = (h_count < 784 && h_count > 143) && (v_count < 515 && v_count > 34) ? 1 : 0;

    assign vga_r = vga_active ? {PIXEL_BITS{1'b1}} : 0;
    assign vga_g = vga_active ? {PIXEL_BITS{1'b1}} : 0;
    assign vga_b = vga_active ? {PIXEL_BITS{1'b1}} : 0;

    // X and Y coordinates
    assign vga_x = vga_active ? (h_count - 144) : 0;
    assign vga_y = vga_active ? (v_count - 35) : 0;

    assign frame_start = ((h_count == 0) && (v_count == 0));
endmodule

// dp_ram_sync_read is now defined in src/peripherals/dp_ram_sync_read.sv,
// shared with vga_framebuffer.sv.

module spi_slave #(
    parameter WIDTH = 8
) (
    input  logic             clk,    
    input  logic             rst,     

    // SPI wires
    input  logic             sclk,     
    input  logic             cs_n,     
    input  logic             mosi,     
    output logic             miso,     

    // Data wires
    input  logic [WIDTH-1:0] din,      
    output logic             d_valid,  
    output logic [WIDTH-1:0] dout      
);

    logic [WIDTH-1:0]       shift_in;
    logic [$clog2(WIDTH):0] bit_count;
    logic [WIDTH-1:0]       captured_data;
    logic                   data_ready_toggle;

    always_ff @(posedge sclk or posedge rst or posedge cs_n) begin
        if (rst || cs_n) begin
            shift_in          <= '0;
            bit_count         <= '0;
            data_ready_toggle <= '0;
            captured_data     <= '0;
        end else begin
            shift_in <= {shift_in[WIDTH-2:0], mosi};
            
            if (bit_count == WIDTH - 1) begin
                captured_data     <= {shift_in[WIDTH-2:0], mosi};
                data_ready_toggle <= ~data_ready_toggle;
                bit_count         <= '0;
            end else begin
                bit_count <= bit_count + 1;
            end
        end
    end

    logic [WIDTH-1:0] shift_out;
    logic             cs_n_prev;
    
    always_ff @(negedge sclk or posedge rst) begin
        if (rst) begin
            shift_out <= '0;
            cs_n_prev <= 1'b1;
        end else begin
            cs_n_prev <= cs_n;
            
            // Detect falling edge of cs_n 
            if (!cs_n && cs_n_prev) begin
                shift_out <= din;
            end else if (!cs_n) begin
                shift_out <= {shift_out[WIDTH-2:0], 1'b0};
            end
        end
    end

    assign miso = shift_out[WIDTH-1];

    logic toggle_sync1, toggle_sync2, toggle_sync3;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            toggle_sync1 <= '0;
            toggle_sync2 <= '0;
            toggle_sync3 <= '0;
        end else begin
            toggle_sync1 <= data_ready_toggle;
            toggle_sync2 <= toggle_sync1;
            toggle_sync3 <= toggle_sync2;
        end
    end

    logic [WIDTH-1:0] captured_sync1, captured_sync2;
    
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            captured_sync1 <= '0;
            captured_sync2 <= '0;
        end else begin
            captured_sync1 <= captured_data;
            captured_sync2 <= captured_sync1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dout    <= '0;
            d_valid <= 1'b0;
        end else begin
            if (toggle_sync2 ^ toggle_sync3) begin
                // New data available
                dout    <= captured_sync2;
                d_valid <= 1'b1;
            end else begin
                d_valid <= 1'b0;
            end
        end
    end

endmodule
