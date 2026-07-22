// test/testbench/tb_uart.sv
//
// Standalone testbench for uart.sv, with TX looped back into RX inside the
// module so a single cocotb test can push a byte in and check it comes back
// out, without any RISC-V core or assembled program involved.

module tb_uart (
    input  logic        clk,
    input  logic         rst,

    input  logic  [15:0] clk_per_bit,

    input  logic  [7:0]  TX_dataIn,
    input  logic         TX_en,
    output logic         TX_busy,
    output logic         TX_done,

    output logic  [7:0]  RX_dataOut,
    output logic         RX_done,
    output logic         RX_parityError
);

    logic tx_out;

    uart #(
        .CLK_BITS   (16),
        .DATA_WIDTH (8),
        .PARITY_BITS(0),
        .STOP_BITS  (1)
    ) u_uart (
        .clk            (clk),
        .rst            (rst),
        .clk_per_bit    (clk_per_bit),
        .TX_dataIn      (TX_dataIn),
        .TX_en          (TX_en),
        .RX_dataIn      (tx_out),   // loopback: TX_out feeds straight into RX
        .TX_out         (tx_out),
        .TX_done        (TX_done),
        .TX_busy        (TX_busy),
        .RX_dataOut     (RX_dataOut),
        .RX_done        (RX_done),
        .RX_parityError (RX_parityError)
    );

endmodule
