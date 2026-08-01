// src/peripherals/timer.sv
// Simple periodic down-counter timer -- the first real interrupt source in
// this design (see docs/01_architecture.md "Interrupt model"). Deliberately
// not the RISC-V-standard 64-bit mtime/mtimecmp CSR pair: a single 32-bit
// reload-and-auto-restart counter is simpler and is all a first scheduler
// tick needs.
//
// Register map (word-addressed, byte offsets from the peripheral's base):
//   +0x0 RELOAD (rw)  -- value the countdown reloads to on enable or on
//                        underflow auto-reload.
//   +0x4 CTRL   (rw)  -- bit 0 = EN. Writing 0 halts the counter (holds its
//                        current value); writing 1 resumes counting down
//                        from whatever value it currently holds -- NOT from
//                        RELOAD, so re-enabling doesn't implicitly reset an
//                        in-progress count. Software writes RELOAD
//                        explicitly whenever it wants to (re)set the count.
//   +0x8 STATUS (rw)  -- bit 0 = pending. Set the cycle the counter
//                        underflows; cleared only by an explicit software
//                        write of 1 to this bit (write-1-to-clear), never
//                        by a read. Drives the irq output directly.
module timer (
    input  logic        clk,
    input  logic        rst,

    input  logic         sel,
    input  logic [3:0]   addr,     // byte address within the peripheral
    input  logic [31:0]  wdata,
    input  logic         we,
    input  logic         re,
    output logic [31:0]  rdata,

    output logic         irq
);

    logic [31:0] reload_val;
    logic        en;
    logic        pending;
    logic [31:0] count;

    assign irq = pending;

    always_comb begin
        rdata = 32'b0;
        if (re && sel) begin
            case (addr[3:2])
                2'b00: rdata = reload_val;
                2'b01: rdata = {31'b0, en};
                2'b10: rdata = {31'b0, pending};
                default: rdata = 32'b0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            reload_val <= 32'd0;
            en         <= 1'b0;
            pending    <= 1'b0;
            count      <= 32'd0;
        end
        else begin
            if (sel && we) begin
                case (addr[3:2])
                    2'b00: reload_val <= wdata;
                    2'b01: en         <= wdata[0];
                    2'b10: if (wdata[0]) pending <= 1'b0; // write-1-to-clear
                    default: ;
                endcase
            end

            if (en) begin
                if (count == 32'd0) begin
                    count   <= reload_val;
                    pending <= 1'b1;
                end
                else begin
                    count <= count - 32'd1;
                end
            end
        end
    end

endmodule
