module riscv_core_single_cycle #(
    parameter ISA = "RV32I"     // For reference, not used in design
) (
    input  logic        clk,
    input  logic        rst,        // Active high
    input  logic        halt,       // Active high — freezes PC and regfile writes

    // Instruction memory interface (read only)
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        imem_req,   // IF is presenting imem_addr this cycle
    input  logic        imem_vld,   // imem_rdata is valid for imem_addr

    // Data memory
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    output logic [3:0]  dmem_byteena,  // per-byte write mask, valid when dmem_we
    output logic        dmem_re,
    input  logic [31:0] ld_data,
    output logic        dmem_req,   // this cycle's instruction has an outstanding load/store
    input  logic        dmem_vld,   // the op requested by dmem_req has completed

    // Debug interface (read only, no effect on core behavior)
    // Async indexed read instead of exposing the full regfile as a packed
    // array port 
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    input  logic [11:0] dbg_csr_addr,
    output logic [31:0] dbg_csr_data,
    output logic [31:0] pc_dbg,

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

    //*************************************
    //*  req/vld memory handshake         *
    //*************************************
    // Real synchronous-read memory (Quartus altsyncram, see fpga/dp_ram.v)
    // never returns data the same cycle the address is presented. imem_req/
    // dmem_req tell memory "here's an address, respond when ready"; vld
    // pulses back when the corresponding rdata/ld_data is actually valid.
    // stall holds pc/regfile writes in place for as long as either is
    // outstanding -- same contract riscv_core.sv uses (if_wait/mem_wait),
    // just collapsed to a single freeze signal since this core has no
    // pipeline stages to freeze independently.
    logic stall;
    assign imem_req = !halt;
    assign dmem_req = dmem_we || dmem_re;
    assign stall    = (imem_req && !imem_vld) || (dmem_req && !dmem_vld);

    //********** Decoder Logic ************
    logic [31:0] instr;

    logic is_u_instr;
    logic is_i_instr;
    logic is_r_instr;
    logic is_s_instr;
    logic is_b_instr;
    logic is_j_instr;
    logic is_csr_instr;

    //******** Instruction Fields *********
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic [2:0] funct3;
    logic [4:0] rd;
    logic [6:0] opcode;
    logic [11:0] csr_addr;
    logic [31:0] zimm;

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
    logic is_lb, is_lh, is_lw, is_lbu, is_lhu;
    logic is_sb, is_sh, is_sw;
    logic is_csrrw, is_csrrs, is_csrrc, is_csrrwi, is_csrrsi, is_csrrci;
    logic is_csr;
    logic is_mul, is_mulh, is_mulhsu, is_mulhu;
    logic is_ecall, is_ebreak, is_mret;

    logic [11:0] dec_bits;

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
    // assign next_pc = 
    //     taken_br    ? br_tgt_pc :
    //     is_jal      ? br_tgt_pc :
    //     is_jalr     ? jalr_tgt_pc :
    //     pc + 32'd4; // default

    always_ff @(posedge clk or posedge rst) begin : ProgramCounter
        if (rst) begin
            pc <= 32'b0;
        end
        else if (!halt && !stall) begin
            if (taken_br || is_jal)          pc <= br_tgt_pc;
            else if (is_jalr)                pc <= jalr_tgt_pc;
            else if (is_ecall || is_ebreak)  pc <= csr_mtvec;
            else if (is_mret)                pc <= csr_mepc;
            else                              pc <= pc + 32'd4;
        end
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
        is_csr_instr = 1'b0;

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
            5'b11100: is_csr_instr = 1'b1;
            default: ;
        endcase
    end

    //******** Instruction Fields *********
    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign funct3   = instr[14:12];
    assign rd       = instr[11:7];
    assign opcode   = instr[6:0];
    assign csr_addr = instr[31:20];
    assign zimm     = {27'b0, instr[19:15]};

    assign rs1_valid    = is_r_instr || is_s_instr || is_b_instr || is_i_instr ||
                           (is_csr_instr && !(is_csrrwi || is_csrrsi || is_csrrci));
    assign rs2_valid    = is_r_instr || is_s_instr || is_b_instr;
    assign funct3_valid = is_r_instr || is_s_instr || is_b_instr || is_i_instr || is_csr_instr;
    assign rd_valid     = is_r_instr || is_i_instr || is_u_instr || is_j_instr || is_csr;
    assign imm_valid    = is_i_instr || is_s_instr || is_b_instr || is_u_instr || is_j_instr;

    assign imm = 
        is_i_instr ? {{21{instr[31]}}, instr[30:20]} :
        is_s_instr ? {{21{instr[31]}}, instr[30:25], instr[11:7]} :
        is_u_instr ? {instr[31:12], 12'b0} :
        is_b_instr ? {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0} :
        is_j_instr ? {{12{instr[31]}}, instr[19:12], instr[20], instr[30:25], instr[24:21], 1'b0} :
        32'b0; 

    //*********** Instructions ************
    assign dec_bits = {instr[25], instr[30], funct3, opcode};

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
        is_lb    = 1'b0; is_lh    = 1'b0; is_lw   = 1'b0; is_lbu  = 1'b0; is_lhu  = 1'b0;
        is_sb    = 1'b0; is_sh    = 1'b0; is_sw   = 1'b0;
        is_csrrw = 1'b0; is_csrrs = 1'b0; is_csrrc = 1'b0;
        is_csrrwi = 1'b0; is_csrrsi = 1'b0; is_csrrci = 1'b0;
        is_mul   = 1'b0; is_mulh  = 1'b0; is_mulhsu = 1'b0; is_mulhu = 1'b0;

        casez (dec_bits)
            // U-type
            12'b?_?_???_0110111: is_lui   = 1'b1;
            12'b?_?_???_0010111: is_auipc = 1'b1;
            // Jumps
            12'b?_?_???_1101111: is_jal   = 1'b1;
            12'b?_?_???_1100111: is_jalr  = 1'b1;
            // Branches
            12'b?_?_000_1100011: is_beq   = 1'b1;
            12'b?_?_001_1100011: is_bne   = 1'b1;
            12'b?_?_100_1100011: is_blt   = 1'b1;
            12'b?_?_101_1100011: is_bge   = 1'b1;
            12'b?_?_110_1100011: is_bltu  = 1'b1;
            12'b?_?_111_1100011: is_bgeu  = 1'b1;
            // I-type ALU
            12'b?_?_000_0010011: is_addi  = 1'b1;
            12'b?_?_010_0010011: is_slti  = 1'b1;
            12'b?_?_011_0010011: is_sltiu = 1'b1;
            12'b?_?_100_0010011: is_xori  = 1'b1;
            12'b?_?_110_0010011: is_ori   = 1'b1;
            12'b?_?_111_0010011: is_andi  = 1'b1;
            // Shifts
            12'b?_0_001_0010011: is_slli  = 1'b1;
            12'b?_0_101_0010011: is_srli  = 1'b1;
            12'b?_1_101_0010011: is_srai  = 1'b1;
            // R-type (base RV32I, funct7[0]=instr[25]=0)
            12'b0_0_000_0110011: is_add   = 1'b1;
            12'b0_1_000_0110011: is_sub   = 1'b1;
            12'b0_0_001_0110011: is_sll   = 1'b1;
            12'b0_0_010_0110011: is_slt   = 1'b1;
            12'b0_0_011_0110011: is_sltu  = 1'b1;
            12'b0_0_100_0110011: is_xor   = 1'b1;
            12'b0_0_101_0110011: is_srl   = 1'b1;
            12'b0_1_101_0110011: is_sra   = 1'b1;
            12'b0_0_110_0110011: is_or    = 1'b1;
            12'b0_0_111_0110011: is_and   = 1'b1;
            // R-type (RV32M, funct7=0000001 i.e. instr[25]=1, instr[30]=0)
            12'b1_0_000_0110011: is_mul     = 1'b1;
            12'b1_0_001_0110011: is_mulh    = 1'b1;
            12'b1_0_010_0110011: is_mulhsu  = 1'b1;
            12'b1_0_011_0110011: is_mulhu   = 1'b1;
            // Load (opcode 0000011), funct3 selects width/signedness
            12'b?_?_000_0000011: is_lb    = 1'b1;
            12'b?_?_001_0000011: is_lh    = 1'b1;
            12'b?_?_010_0000011: is_lw    = 1'b1;
            12'b?_?_100_0000011: is_lbu   = 1'b1;
            12'b?_?_101_0000011: is_lhu   = 1'b1;
            // Store (opcode 0100011), funct3 selects width
            12'b?_?_000_0100011: is_sb    = 1'b1;
            12'b?_?_001_0100011: is_sh    = 1'b1;
            12'b?_?_010_0100011: is_sw    = 1'b1;
            // CSR (opcode 1110011), funct3 selects op (000 is PRIV/ECALL/EBREAK, not decoded)
            12'b?_?_001_1110011: is_csrrw  = 1'b1;
            12'b?_?_010_1110011: is_csrrs  = 1'b1;
            12'b?_?_011_1110011: is_csrrc  = 1'b1;
            12'b?_?_101_1110011: is_csrrwi = 1'b1;
            12'b?_?_110_1110011: is_csrrsi = 1'b1;
            12'b?_?_111_1110011: is_csrrci = 1'b1;
            default: ;
        endcase

        is_load = is_lb | is_lh | is_lw | is_lbu | is_lhu;
        is_csr  = is_csrrw | is_csrrs | is_csrrc | is_csrrwi | is_csrrsi | is_csrrci;
    end

    // PRIV (opcode 1110011, funct3=000): ECALL/EBREAK/MRET all share this
    // funct3, disambiguated by csr_addr (instr[31:20]) instead of a CSR
    // address -- kept as its own decode block, separate from the is_csrrw
    // etc. casez above, since csr_addr means something entirely different
    // for these three (an opcode-disambiguating immediate, not a real CSR
    // address).
    always_comb begin : Priv_Decode
        is_ecall  = (opcode == 7'b1110011) && (funct3 == 3'b000) && (csr_addr == 12'h000);
        is_ebreak = (opcode == 7'b1110011) && (funct3 == 3'b000) && (csr_addr == 12'h001);
        is_mret   = (opcode == 7'b1110011) && (funct3 == 3'b000) && (csr_addr == 12'h302);
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

    // RV32M: 64-bit product, sign/zero-extended per variant before multiply
    logic signed [63:0] mul_ss_rslt;
    logic signed [63:0] mul_su_rslt;
    logic        [63:0] mul_uu_rslt;

    assign mul_ss_rslt = $signed(src1_value) * $signed(src2_value);
    assign mul_su_rslt = $signed(src1_value) * $signed({1'b0, src2_value});
    assign mul_uu_rslt = src1_value * src2_value;

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
        is_mul     ? mul_ss_rslt[31:0]               :
        is_mulh    ? mul_ss_rslt[63:32]              :
        is_mulhsu  ? mul_su_rslt[63:32]              :
        is_mulhu   ? mul_uu_rslt[63:32]              :
        32'b0;

    //********** Register File ************
    // Register file write
    logic [1:0]  byte_off;
    logic [31:0] ld_shifted;
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    logic [31:0] ld_extracted;

    assign byte_off   = result[1:0];   // ALU result IS the byte address
    assign ld_shifted = ld_data >> (byte_off * 8);
    assign ld_byte    = ld_shifted[7:0];
    assign ld_half    = ld_shifted[15:0];

    assign ld_extracted =
        is_lb  ? {{24{ld_byte[7]}},  ld_byte}  :
        is_lh  ? {{16{ld_half[15]}}, ld_half}  :
        is_lbu ? {24'b0, ld_byte}              :
        is_lhu ? {16'b0, ld_half}              :
        ld_data;  // is_lw

    //************* CSR file **************
    // Zicsr instructions only -- no trap hardware yet (mstatus/mtvec/mepc/
    // mcause/mie/mip/mscratch/mtval are plain read/write storage for now,
    // no side effects). PRIV (funct3=000, ECALL/EBREAK) shares this opcode
    // but is intentionally left undecoded -- out of scope until trap entry
    // exists. csr_addr/zimm are computed above alongside the other
    // instruction fields.
    logic [31:0] csr_mstatus, csr_mie, csr_mtvec, csr_mscratch;
    logic [31:0] csr_mepc, csr_mcause, csr_mtval, csr_mip;
    logic [31:0] csr_rdata;
    logic [31:0] op_val;
    logic [31:0] csr_wdata;

    assign csr_rdata =
        csr_addr == 12'h300 ? csr_mstatus  :
        csr_addr == 12'h304 ? csr_mie      :
        csr_addr == 12'h305 ? csr_mtvec    :
        csr_addr == 12'h340 ? csr_mscratch :
        csr_addr == 12'h341 ? csr_mepc     :
        csr_addr == 12'h342 ? csr_mcause   :
        csr_addr == 12'h343 ? csr_mtval    :
        csr_addr == 12'h344 ? csr_mip      :
        32'b0;   // misa, mhartid, everything else: read as 0

    assign op_val = (is_csrrwi | is_csrrsi | is_csrrci) ? zimm : src1_value;

    assign csr_wdata =
        (is_csrrw | is_csrrwi) ? op_val                :
        (is_csrrs | is_csrrsi) ? (csr_rdata | op_val)  :
        (is_csrrc | is_csrrci) ? (csr_rdata & ~op_val) :
        32'b0;

    always_ff @(posedge clk) begin
        if (is_csr && !halt && !stall) begin
            case (csr_addr)
                12'h300: csr_mstatus  <= csr_wdata;
                12'h304: csr_mie      <= csr_wdata;
                12'h305: csr_mtvec    <= csr_wdata;
                12'h340: csr_mscratch <= csr_wdata;
                12'h341: csr_mepc     <= csr_wdata;
                12'h342: csr_mcause   <= csr_wdata;
                12'h343: csr_mtval    <= csr_wdata;
                12'h344: csr_mip      <= csr_wdata;
                default: ;  // misa/mhartid/unimplemented: write ignored
            endcase
        end
        else if ((is_ecall || is_ebreak) && !halt && !stall) begin
            csr_mepc   <= pc;
            csr_mcause <= is_ecall ? 32'd11 : 32'd3;
        end
    end

    assign wr_data = is_csr ? csr_rdata : (is_load ? ld_extracted : result);
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
    assign dmem_addr     = result;        // address computed by ALU
    assign dmem_wdata    = src2_value << (byte_off * 8);  // shift store data into its byte lane
    assign dmem_we       = is_s_instr;
    assign dmem_re       = is_load;
    assign dmem_byteena  =
        is_sb ? (4'b0001 << byte_off) :
        is_sh ? (4'b0011 << byte_off) :
        is_sw ? 4'b1111               :
        4'b0000;

    // Internal Register File
    logic [31:0] regfile [31:0];

    // Write port
    always_ff @(posedge clk) begin
        if (wr_en && (rd != 5'b0) && !halt && !stall)
            regfile[rd] <= wr_data;
    end

    // Read ports - x0 always 0
    assign src1_value = (rs1 == 5'b0) ? 32'b0 : regfile[rs1];
    assign src2_value = (rs2 == 5'b0) ? 32'b0 : regfile[rs2];

    // Debug interface
    assign dbg_reg_data = (dbg_reg_addr == 5'b0) ? 32'b0 : regfile[dbg_reg_addr];
    assign dbg_csr_data =
        dbg_csr_addr == 12'h300 ? csr_mstatus  :
        dbg_csr_addr == 12'h304 ? csr_mie      :
        dbg_csr_addr == 12'h305 ? csr_mtvec    :
        dbg_csr_addr == 12'h340 ? csr_mscratch :
        dbg_csr_addr == 12'h341 ? csr_mepc     :
        dbg_csr_addr == 12'h342 ? csr_mcause   :
        dbg_csr_addr == 12'h343 ? csr_mtval    :
        dbg_csr_addr == 12'h344 ? csr_mip      :
        32'b0;
    assign pc_dbg       = pc;

endmodule