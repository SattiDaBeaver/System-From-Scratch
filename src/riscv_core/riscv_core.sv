module riscv_core #(
    parameter ISA = "RV32I"     // For reference, not used in design
) (
    input  logic        clk,
    input  logic        rst,        // Active high

    // Instruction memory interface (read only)
    input  logic [31:0] imem_addr,
    output logic [31:0] imem_dout,   

    // Junk wire
    input  logic        junk
);

    
    //********* Program Counter ***********
    // Wires
    logic [31:0] pc;
    logic [31:0] next_pc;

    // Special cases
    logic [31:0] br_tgt_pc;
    logic [31:0] jalr_tgt_pc;

    // Logic
    assign next_pc = 
        rst         ? 32'b0 :
        taken_br    ? br_tgt_pc :
        is_jal      ? br_tgt_pc :
        is_jalr     ? jalr_tgt_pc :
        pc + 32'd4; // default

    //******** Instruction Memory *********
    // Wires
    logic [31:0] instr;

    // Logic
    assign imem_addr    = pc;
    assign instr        = imem_dout;

    //********** Decoder Logic ************
    // Wires
    logic is_u_instr;
    logic is_i_instr;
    logic is_r_instr;
    logic is_s_instr;
    logic is_b_instr;
    logic is_j_instr;

    // Logic
    always_comb begin : Decoder_Logic
        is_u_instr = 1'b0;
        is_i_instr = 1'b0;
        is_r_instr = 1'b0;
        is_s_instr = 1'b0;
        is_b_instr = 1'b0;
        is_j_instr = 1'b0;

        casez (instr[6:2])
            5'b0x101: is_u_instr = 1'b1;
            5'b0000x: is_i_instr = 1'b1;
            5'b001x0: is_i_instr = 1'b1;
            5'b11001: is_i_instr = 1'b1;
            5'b01011: is_r_instr = 1'b1;
            5'b01100: is_r_instr = 1'b1;
            5'b01110: is_r_instr = 1'b1;
            5'b10100: is_r_instr = 1'b1;
            5'b0100x: is_s_instr = 1'b1;
            5'b11000: is_b_instr = 1'b1;
            5'b11011: is_j_instr = 1'b1;
            default: ;
        endcase
    end

    //******** Instruction Fields *********
    // Wires
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [2:0] funct3;
    logic [4:0] rd;
    logic [6:0] opcode;

    logic rs1_valid;
    logic rs2_valid;
    logic funct3_valid;
    logic rd_valid;
    logic imm_valid;

    logic [31:0] imm;

    // Logic
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct3   = instr[14:12];
    assign rd       = instr[11:7];
    assign opcode   = instr[6:0];

    assign rs1_valid    = is_r_instr || is_s_instr || is_b_instr || is_i_instr;
    assign rs2_valid    = is_r_instr || is_s_instr || is_b_instr;
    assign funct3_valid = is_r_instr || is_s_instr || is_b_instr || is_i_instr;
    assign rd_valid     = is_r_instr || is_i_instr || is_u_instr || is_j_instr;
    assign imm_valid    = is_r_instr || is_i_instr || is_b_instr || is_u_instr || is_j_instr;

    assign imm = 
        is_i_instr ? {{21{instr[31]}}, instr[30:20]} :
        is_s_instr ? {{21{instr[31]}}, instr[30:25], instr[11:7]} :
        is_u_instr ? {instr[31:12], 12'b0} :
        is_b_instr ? {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0} :
        is_j_instr ? {{12{instr[31]}}, instr[19:12], instr[20], instr[30:25], instr[24:21], 1'b0} :
        32'b0; // default

    //*********** Instructions ************
    // Wires
    logic is_lui, is_auipc, is_jal, is_jalr;
    logic is_beq, is_bne, is_blt, is_bge, is_bltu, is_bgeu;
    logic is_addi, is_slti, is_sltiu, is_xori, is_ori, is_andi;
    logic is_slli, is_srli, is_srai;
    logic is_add, is_sub, is_sll, is_slt, is_sltu, is_xor, is_srl, is_sra, is_or, is_and;
    logic is_load;

    logic [10:0] dec_bits;

    // Logic
    assign dec_bits = {instr[30], funct3, opcode};

    always_comb begin
        // defaults
        is_lui   = 1'b0; is_auipc = 1'b0; is_jal  = 1'b0; is_jalr  = 1'b0;
        is_beq   = 1'b0; is_bne   = 1'b0; is_blt  = 1'b0; is_bge   = 1'b0;
        is_bltu  = 1'b0; is_bgeu  = 1'b0;
        is_addi  = 1'b0; is_slti  = 1'b0; is_sltiu = 1'b0; is_xori = 1'b0;
        is_ori   = 1'b0; is_andi  = 1'b0;
        is_slli  = 1'b0; is_srli  = 1'b0; is_srai = 1'b0;
        is_add   = 1'b0; is_sub   = 1'b0; is_sll  = 1'b0; is_slt  = 1'b0;
        is_sltu  = 1'b0; is_xor   = 1'b0; is_srl  = 1'b0; is_sra  = 1'b0;
        is_or    = 1'b0; is_and   = 1'b0;
        is_load  = 1'b0;

        casez (dec_bits)
            // U-type
            11'bx_xxx_0110111: is_lui   = 1'b1;
            11'bx_xxx_0010111: is_auipc = 1'b1;
            // Jumps
            11'bx_xxx_1101111: is_jal   = 1'b1;
            11'bx_xxx_1100111: is_jalr  = 1'b1;
            // Branches
            11'bx_000_1100011: is_beq   = 1'b1;
            11'bx_001_1100011: is_bne   = 1'b1;
            11'bx_100_1100011: is_blt   = 1'b1;
            11'bx_101_1100011: is_bge   = 1'b1;
            11'bx_110_1100011: is_bltu  = 1'b1;
            11'bx_111_1100011: is_bgeu  = 1'b1;
            // I-type ALU
            11'bx_000_0010011: is_addi  = 1'b1;
            11'bx_010_0010011: is_slti  = 1'b1;
            11'bx_011_0010011: is_sltiu = 1'b1;
            11'bx_100_0010011: is_xori  = 1'b1;
            11'bx_110_0010011: is_ori   = 1'b1;
            11'bx_111_0010011: is_andi  = 1'b1;
            // Shifts (instr[30] matters here)
            11'b0_001_0010011: is_slli  = 1'b1;
            11'b0_101_0010011: is_srli  = 1'b1;
            11'b1_101_0010011: is_srai  = 1'b1;
            // R-type
            11'b0_000_0110011: is_add   = 1'b1;
            11'b1_000_0110011: is_sub   = 1'b1;
            11'b0_001_0110011: is_sll   = 1'b1;
            11'b0_010_0110011: is_slt   = 1'b1;
            11'b0_011_0110011: is_sltu  = 1'b1;
            11'b0_100_0110011: is_xor   = 1'b1;
            11'b0_101_0110011: is_srl   = 1'b1;
            11'b1_101_0110011: is_sra   = 1'b1;
            11'b0_110_0110011: is_or    = 1'b1;
            11'b0_111_0110011: is_and   = 1'b1;
            // Load
            11'bx_xxx_0000011: is_load  = 1'b1;
            default: ;
        endcase
    end
    
endmodule