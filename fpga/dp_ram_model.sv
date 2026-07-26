// fpga/dp_ram_model.v
//
// Behavioral stand-in for dp_ram.v (the Quartus altsyncram megafunction
// wrapper), used only in simulation. Verilator can't simulate altsyncram
// directly (no altera_mf support), so any testbench that instantiates the
// real riscv_top.sv wiring needs a drop-in replacement with the same port
// list.
//
// dp_ram.v's actual altsyncram defparams (address_reg_b = "CLOCK0") imply
// a registered address / 1-cycle read latency, but the current core and
// its existing sim testbenches (tb_core.sv, tb_soc.sv) assume zero-latency
// combinational reads. REGISTERED_ADDR picks which behavior this model
// exhibits, so it stays a 1:1 swap for dp_ram today (REGISTERED_ADDR=0)
// and can be flipped to the real IP's timing later once the core has a
// read handshake / pipeline stage to tolerate it.
module dp_ram_model #(
    parameter REGISTERED_ADDR = 0
) (
    input  [11:0] address_a,
    input  [11:0] address_b,
    input         clock,
    input  [31:0] data_a,
    input  [31:0] data_b,
    input         wren_a,
    input         wren_b,
    output [31:0] q_a,
    output [31:0] q_b
);

    reg [31:0] mem [0:4095];

    generate
        if (REGISTERED_ADDR) begin : g_registered
            reg [11:0] address_a_r, address_b_r;

            always @(posedge clock) begin
                address_a_r <= address_a;
                address_b_r <= address_b;
                if (wren_a) mem[address_a] <= data_a;
                if (wren_b) mem[address_b] <= data_b;
            end

            // OLD_DATA read-during-write, delayed one cycle by the address
            // register itself -- q reflects mem[] as of the *previous*
            // clock edge, matching altsyncram's address_reg_b=CLOCK0.
            assign q_a = mem[address_a_r];
            assign q_b = mem[address_b_r];
        end
        else begin : g_combinational
            // OLD_DATA read-during-write: q reflects mem[] as it was
            // before this cycle's write, since mem[] itself only updates
            // at the end of the clock edge (non-blocking assignment) --
            // the combinational read below reads the pre-update value.
            assign q_a = mem[address_a];
            assign q_b = mem[address_b];

            always @(posedge clock) begin
                if (wren_a) mem[address_a] <= data_a;
                if (wren_b) mem[address_b] <= data_b;
            end
        end
    endgenerate

endmodule
