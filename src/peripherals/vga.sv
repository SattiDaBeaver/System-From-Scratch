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
