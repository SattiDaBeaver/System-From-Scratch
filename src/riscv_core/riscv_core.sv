module riscv_core #(
    parameter ISA = "RV32I"     // For reference, not used in design
) (
    input  logic        clk,
    input  logic        rst,        // Active high

    // Instruction memory interface (read only)
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,   

    // Data memory
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    output logic        dmem_re,
    input  logic [31:0] ld_data,

    // Junk wire
    input  logic        _bogus
);

    //*************************************
    //*             Wires                 *
    //*************************************
    //********** Register File ************
    // Wires
    logic [31:0] wr_data;
    logic        wr_en;
    logic [31:0] src1_value;
    logic [31:0] src2_value;

    // Branch/jump targets
    logic        taken_br;

    //********** Decoder Logic ************
    logic [31:0] instr;

    logic is_u_instr;
    logic is_i_instr;
    logic is_r_instr;
    logic is_s_instr;
    logic is_b_instr;
    logic is_j_instr;

    //******** Instruction Fields *********
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

    //*********** Instructions ************
    logic is_lui, is_auipc, is_jal, is_jalr;
    logic is_beq, is_bne, is_blt, is_bge, is_bltu, is_bgeu;
    logic is_addi, is_slti, is_sltiu, is_xori, is_ori, is_andi;
    logic is_slli, is_srli, is_srai;
    logic is_add, is_sub, is_sll, is_slt, is_sltu, is_xor, is_srl, is_sra, is_or, is_and;
    logic is_load;

    logic [10:0] dec_bits;

    //******* Arithmetic Logic Unit *******
    logic [31:0] sltu_rslt;
    logic [31:0] sltiu_rslt;
    logic [63:0] sext_src1;
    logic [63:0] sra_rslt;
    logic [63:0] srai_rslt;
    logic [31:0] result;

    //********* Program Counter ***********
    // Wires
    logic [31:0] pc;
    logic [31:0] next_pc;

    // Special cases
    logic [31:0] br_tgt_pc;
    logic [31:0] jalr_tgt_pc;


    //*************************************
    //*             Logic                 *
    //*************************************
    //********** Register File ************
    assign next_pc = 
        rst         ? 32'b0 :
        taken_br    ? br_tgt_pc :
        is_jal      ? br_tgt_pc :
        is_jalr     ? jalr_tgt_pc :
        pc + 32'd4; // default

    always_ff @(posedge clk) begin : ProgramCounter
        pc <= next_pc;
    end

    //******** Instruction Memory *********
    assign imem_addr    = pc;
    assign instr        = imem_rdata;

    always_comb begin : Decoder_Logic
        is_u_instr = 1'b0;
        is_i_instr = 1'b0;
        is_r_instr = 1'b0;
        is_s_instr = 1'b0;
        is_b_instr = 1'b0;
        is_j_instr = 1'b0;

        casez (instr[6:2])
            5'b0?101: is_u_instr = 1'b1;
            5'b0000?: is_i_instr = 1'b1;
            5'b001?0: is_i_instr = 1'b1;
            5'b11001: is_i_instr = 1'b1;
            5'b01011: is_r_instr = 1'b1;
            5'b01100: is_r_instr = 1'b1;
            5'b01110: is_r_instr = 1'b1;
            5'b10100: is_r_instr = 1'b1;
            5'b0100?: is_s_instr = 1'b1;
            5'b11000: is_b_instr = 1'b1;
            5'b11011: is_j_instr = 1'b1;
            default: ;
        endcase
    end

    //******** Instruction Fields *********
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct3   = instr[14:12];
    assign rd       = instr[11:7];
    assign opcode   = instr[6:0];

    assign rs1_valid    = is_r_instr || is_s_instr || is_b_instr || is_i_instr;
    assign rs2_valid    = is_r_instr || is_s_instr || is_b_instr;
    assign funct3_valid = is_r_instr || is_s_instr || is_b_instr || is_i_instr;
    assign rd_valid     = is_r_instr || is_i_instr || is_u_instr || is_j_instr;
    assign imm_valid    = is_i_instr || is_s_instr || is_b_instr || is_u_instr || is_j_instr;

    assign imm = 
        is_i_instr ? {{21{instr[31]}}, instr[30:20]} :
        is_s_instr ? {{21{instr[31]}}, instr[30:25], instr[11:7]} :
        is_u_instr ? {instr[31:12], 12'b0} :
        is_b_instr ? {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0} :
        is_j_instr ? {{12{instr[31]}}, instr[19:12], instr[20], instr[30:25], instr[24:21], 1'b0} :
        32'b0; 

    //*********** Instructions ************
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
            11'b?_???_0110111: is_lui   = 1'b1;
            11'b?_???_0010111: is_auipc = 1'b1;
            // Jumps
            11'b?_???_1101111: is_jal   = 1'b1;
            11'b?_???_1100111: is_jalr  = 1'b1;
            // Branches
            11'b?_000_1100011: is_beq   = 1'b1;
            11'b?_001_1100011: is_bne   = 1'b1;
            11'b?_100_1100011: is_blt   = 1'b1;
            11'b?_101_1100011: is_bge   = 1'b1;
            11'b?_110_1100011: is_bltu  = 1'b1;
            11'b?_111_1100011: is_bgeu  = 1'b1;
            // I-type ALU
            11'b?_000_0010011: is_addi  = 1'b1;
            11'b?_010_0010011: is_slti  = 1'b1;
            11'b?_011_0010011: is_sltiu = 1'b1;
            11'b?_100_0010011: is_xori  = 1'b1;
            11'b?_110_0010011: is_ori   = 1'b1;
            11'b?_111_0010011: is_andi  = 1'b1;
            // Shifts 
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
            11'b?_???_0000011: is_load  = 1'b1;
            default: ;
        endcase
    end

    //******* Arithmetic Logic Unit *******
    // Set less than unsigned
    assign sltu_rslt = {31'b0, src1_value < src2_value};
    assign sltiu_rslt = {31'b0, src1_value < imm};

    // Shift right arithmetic
    // Sign extend
    assign sext_src1 = {{32{src1_value[31]}}, src1_value};
    // Shift sign-extended results
    assign sra_rslt = sext_src1 >> src2_value[4:0];
    assign srai_rslt = sext_src1 >> imm[4:0];

    // ALU result
    assign result = 
        is_andi    ? src1_value & imm               :
        is_ori     ? src1_value | imm               :
        is_xori    ? src1_value ^ imm               :
        is_addi    ? src1_value + imm               :
        is_slli    ? src1_value << imm[5:0]         :
        is_srli    ? src1_value >> imm[5:0]         :
        is_and     ? src1_value & src2_value        :
        is_or      ? src1_value | src2_value        :
        is_xor     ? src1_value ^ src2_value        :
        is_add     ? src1_value + src2_value        :
        is_sub     ? src1_value - src2_value        :
        is_sll     ? src1_value << src2_value[4:0]  :
        is_srl     ? src1_value >> src2_value[4:0]  :
        is_sltu    ? sltu_rslt                      :
        is_sltiu   ? sltiu_rslt                     :
        is_lui     ? {imm[31:12], 12'b0}            :
        is_auipc   ? pc + imm                       :
        is_jal     ? pc + 32'd4                     :
        is_jalr    ? pc + 32'd4                     :
        is_slt     ? ((src1_value[31] == src2_value[31]) ? sltu_rslt : {31'b0, src1_value[31]}) :
        is_slti    ? ((src1_value[31] == imm[31]) ? sltiu_rslt : {31'b0, src1_value[31]}) :
        is_sra     ? sra_rslt[31:0]                 :
        is_srai    ? srai_rslt[31:0]                :
        is_load    ? src1_value + imm               :
        is_s_instr ? src1_value + imm               :
        32'b0;

    //********** Register File ************
    // Register file write
    assign wr_data = is_load ? ld_data : result;
    assign wr_en   = (rd == 5'b0) ? 1'b0 : rd_valid;

    // Branch logic
    assign taken_br =
        is_beq  ? (src1_value == src2_value)                                :
        is_bne  ? (src1_value != src2_value)                                :
        is_blt  ? ((src1_value < src2_value) ^ (src1_value[31] != src2_value[31])) :
        is_bge  ? ((src1_value >= src2_value) ^ (src1_value[31] != src2_value[31])) :
        is_bltu ? (src1_value < src2_value)                                 :
        is_bgeu ? (src1_value >= src2_value)                                :
        1'b0;

    assign br_tgt_pc   = pc + imm;
    assign jalr_tgt_pc = src1_value + imm;

    // Data memory interface
    assign dmem_addr  = result;        // address computed by ALU
    assign dmem_wdata = src2_value;    // rs2 is always the store data
    assign dmem_we    = is_s_instr;
    assign dmem_re    = is_load;

    // Internal Register File
    logic [31:0] regfile [31:0];

    // Write port
    always_ff @(posedge clk) begin
        if (wr_en && (rd != 5'b0))
            regfile[rd] <= wr_data;
    end

    // Read ports - x0 always 0
    assign src1_value = (rs1 == 5'b0) ? 32'b0 : regfile[rs1];
    assign src2_value = (rs2 == 5'b0) ? 32'b0 : regfile[rs2];
    
endmodule