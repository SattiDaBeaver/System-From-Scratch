module riscv_core #(
    parameter ISA = "RV32I"     // For reference, not used in design
) (
    input  logic        clk,
    input  logic        rst,        // Active high
    input  logic        halt,       // Active high — freezes every pipeline stage and regfile writes

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
    output logic        dmem_req,   // MEM has an outstanding load/store this cycle
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

    // 5-stage pipeline: IF -> ID -> EX -> MEM -> WB. See docs/03_microarchitecture.md
    // and docs/04_pipeline_plan.md for the derivation/plan this follows.
    //
    // Milestone 2 (docs/04_pipeline_plan.md Sec.7): pipeline registers +
    // valid-bit reset gating only. No RAW-hazard stalling, no branch/jump
    // flush yet -- next_pc redirection exists (any program with a jump has
    // to be able to loop), but if_id/id_ex are NOT squashed on redirect, so
    // for two cycles after a taken branch/jump the wrong-path instructions
    // already in IF/ID flow through anyway. That's safe for now only
    // because every test program's post-loop imem is zero-filled (decodes
    // as addi x0,x0,0 -- a real no-op since rd=x0), not because it's
    // correct in general; flush logic (milestone 3) replaces this.

    //*************************************
    //*             Wires                 *
    //*************************************
    //********** Register File ************
    logic [31:0] wr_data;
    logic        wr_en;
    logic [31:0] src1_value;
    logic [31:0] src2_value;

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
    logic [31:0] op_val;
    logic is_mul, is_mulh, is_mulhsu, is_mulhu;

    logic [11:0] dec_bits;

    //********* Program Counter ***********
    logic [31:0] pc;
    logic [31:0] next_pc;

    //*************************************
    //*      Pipeline registers           *
    //*************************************
    // IF/ID: raw fetched instruction + its own pc, so ID can decode and EX
    // can still compute pc-relative targets (br_tgt/auipc/jal) later.
    logic [31:0] if_id_instr;
    logic [31:0] if_id_pc;
    logic        if_id_valid;

    // ID/EX: decode already happened in ID -- carry its *outputs* forward
    // (one-hot control bits packed into id_ctrl_bus, matching this file's
    // existing one-hot-boolean decode style) rather than redecoding in EX.
    // Bit order (MSB..LSB), 47 bits total:
    //   is_lb, is_lh, is_lw, is_lbu, is_lhu, is_sb, is_sh, is_sw,
    //   is_lui, is_auipc, is_jal, is_jalr,
    //   is_beq, is_bne, is_blt, is_bge, is_bltu, is_bgeu,
    //   is_addi, is_slti, is_sltiu, is_xori, is_ori, is_andi,
    //   is_slli, is_srli, is_srai,
    //   is_add, is_sub, is_sll, is_slt, is_sltu, is_xor, is_srl, is_sra, is_or, is_and,
    //   is_mul, is_mulh, is_mulhsu, is_mulhu,
    //   is_load, is_s_instr, rd_valid, is_csr, csr_optype[1:0]
    logic [46:0] id_ctrl_bus;
    logic [4:0]  id_ex_rd;
    logic [46:0] id_ex_ctrl;
    logic [31:0] id_ex_imm;
    logic [31:0] id_ex_src1_value;
    logic [31:0] id_ex_src2_value;
    logic [31:0] id_ex_pc;
    logic        id_ex_valid;

    // EX/MEM: result is the ALU result (loads/stores use it as the address,
    // everything else as the value to forward to WB). wr_en is precomputed
    // here (rd_valid && rd!=x0) rather than recomputed per-stage downstream.
    logic [31:0] ex_mem_result;
    logic [31:0] ex_mem_src2_value;
    logic [4:0]  ex_mem_rd;
    logic        ex_mem_is_load;
    logic        ex_mem_is_s_instr;
    logic        ex_mem_is_lb, ex_mem_is_lh, ex_mem_is_lw, ex_mem_is_lbu, ex_mem_is_lhu;
    logic        ex_mem_is_sb, ex_mem_is_sh, ex_mem_is_sw;
    logic        ex_mem_wr_en;
    logic        ex_mem_valid;
    logic        ex_mem_is_csr;
    logic [1:0]  ex_mem_csr_optype;
    logic [11:0] ex_mem_csr_addr;

    // MEM/WB: wr_data is already resolved to "ld_data or forwarded result"
    // -- WB just commits it.
    logic [31:0] mem_wb_wr_data;
    logic [4:0]  mem_wb_rd;
    logic        mem_wb_wr_en;
    logic        mem_wb_valid;
    logic        mem_wb_is_csr;
    logic [1:0]  mem_wb_csr_optype;
    logic [11:0] mem_wb_csr_addr;
    logic [31:0] mem_wb_csr_op_val;

    //*************************************
    //*     EX-stage (unpacked) control    *
    //*************************************
    logic ex_is_lui, ex_is_auipc, ex_is_jal, ex_is_jalr;
    logic ex_is_beq, ex_is_bne, ex_is_blt, ex_is_bge, ex_is_bltu, ex_is_bgeu;
    logic ex_is_addi, ex_is_slti, ex_is_sltiu, ex_is_xori, ex_is_ori, ex_is_andi;
    logic ex_is_slli, ex_is_srli, ex_is_srai;
    logic ex_is_add, ex_is_sub, ex_is_sll, ex_is_slt, ex_is_sltu, ex_is_xor, ex_is_srl, ex_is_sra, ex_is_or, ex_is_and;
    logic ex_is_mul, ex_is_mulh, ex_is_mulhsu, ex_is_mulhu;
    logic ex_is_load, ex_is_s_instr, ex_rd_valid;
    logic ex_is_lb, ex_is_lh, ex_is_lw, ex_is_lbu, ex_is_lhu;
    logic ex_is_sb, ex_is_sh, ex_is_sw;
    logic ex_is_csr;
    logic [1:0] ex_csr_optype;

    logic        ex_taken_br;
    logic [31:0] ex_br_tgt_pc;
    logic [31:0] ex_jalr_tgt_pc;
    logic [31:0] ex_sltu_rslt;
    logic [31:0] ex_sltiu_rslt;
    logic [63:0] ex_sext_src1;
    logic [63:0] ex_sra_rslt;
    logic [63:0] ex_srai_rslt;
    logic [31:0] ex_result;
    logic        ex_wr_en;

    //*************************************
    //*      MEM-stage wires               *
    //*************************************
    logic [31:0] mem_wr_data;

    //*************************************
    //*      Flush (milestone 3)          *
    //*************************************
    // A taken branch/jal/jalr resolves in EX -- by then IF and ID have
    // already fetched/decoded the two sequential (wrong-path) instructions
    // immediately after it. flush squashes both the instruction just
    // latched into if_id (still needs decoding) and the one already sitting
    // in id_ex (about to enter EX this same cycle) into invalid bubbles, the
    // same cycle next_pc redirects IF. See docs/03_microarchitecture.md
    // Sec.3.
    logic ex_flush;
    assign ex_flush = ex_taken_br || ex_is_jal || ex_is_jalr;

    //*************************************
    //*  RAW-hazard stall (milestone 4)   *
    //*************************************
    // Stall-only v1, no forwarding (docs/04_pipeline_plan.md Sec.3): if the
    // instruction currently in ID reads a register that an instruction
    // still in flight (id_ex/ex_mem/mem_wb) is going to write, hold IF/ID
    // in place and feed EX a bubble instead, until that write has
    // committed. Load-use is not a special case -- a load's result isn't
    // available until mem_wb, exactly like any ALU result, so this same
    // check covers it.
    logic id_stall;
    assign id_stall = if_id_valid && !ex_flush && (
        (rs1_valid && rs1 != 5'b0 && (
            (id_ex_valid  && ex_wr_en     && id_ex_rd  == rs1) ||
            (ex_mem_valid && ex_mem_wr_en && ex_mem_rd == rs1) ||
            (mem_wb_valid && mem_wb_wr_en && mem_wb_rd == rs1)
        )) ||
        (rs2_valid && rs2 != 5'b0 && (
            (id_ex_valid  && ex_wr_en     && id_ex_rd  == rs2) ||
            (ex_mem_valid && ex_mem_wr_en && ex_mem_rd == rs2) ||
            (mem_wb_valid && mem_wb_wr_en && mem_wb_rd == rs2)
        ))
    );

    //*************************************
    //*  req/vld memory handshake         *
    //*************************************
    // Real synchronous-read memory (Quartus altsyncram, see fpga/dp_ram.v)
    // never returns data the same cycle the address is presented. imem_req/
    // dmem_req tell memory "here's an address, respond when ready"; vld
    // pulses back when the corresponding rdata/ld_data is actually valid.
    // if_wait/mem_wait generalize id_stall/ex_flush's existing freeze+bubble
    // mechanism to memory latency of any length (1 cycle today, more with a
    // future cache) instead of hardcoding one extra pipeline stage.
    logic if_wait, mem_wait, front_stall;
    assign imem_req    = !halt;
    assign dmem_req     = dmem_we || dmem_re;
    assign if_wait      = imem_req  && !imem_vld;
    assign mem_wait      = dmem_req  && !dmem_vld;
    assign front_stall = id_stall  || if_wait;

    //*************************************
    //*             Logic                 *
    //*************************************
    //*************  IF stage  ************
    assign imem_addr = pc;

    always_ff @(posedge clk or posedge rst) begin : ProgramCounter
        if (rst) begin
            pc <= 32'b0;
        end
        else if (!halt) begin
            if (mem_wait) begin
                pc <= pc;
            end
            else if (ex_flush) begin
                pc <= next_pc;  // next_pc already holds the resolved branch/
                                 // jal/jalr target -- ex_flush must win over
                                 // front_stall (a same-cycle IF-side wait/
                                 // hazard is unrelated to EX's redirect and
                                 // must not drop it), matching the priority
                                 // if_id_valid/id_ex_valid already use below.
            end
            else if (front_stall) begin
                pc <= pc;
            end
            else begin
                pc <= next_pc;
            end
        end
    end

    // Driven by EX's branch/jump resolution -- IF always optimistically
    // fetches pc+4 by default (predict-not-taken) and gets redirected the
    // same cycle EX resolves otherwise. See docs/03_microarchitecture.md
    // Sec.3.
    assign next_pc =
        (ex_taken_br || ex_is_jal) ? ex_br_tgt_pc :
        ex_is_jalr                 ? ex_jalr_tgt_pc :
        pc + 32'd4;

    always_ff @(posedge clk) begin : IF_ID_Reg
        if (rst) begin
            if_id_instr <= 32'b0;
            if_id_pc    <= 32'b0;
            if_id_valid <= 1'b0;
        end
        else if (!halt) begin
            if (mem_wait) begin
                if_id_instr <= if_id_instr;
                if_id_pc    <= if_id_pc;
                if_id_valid <= if_id_valid;
            end
            else if (ex_flush) begin
                if_id_instr <= 32'b0;
                if_id_pc    <= 32'b0;
                if_id_valid <= 1'b0;
            end
            else if (front_stall) begin
                if_id_instr <= if_id_instr;
                if_id_pc    <= if_id_pc;
                if_id_valid <= if_id_valid;
            end
            else begin
                if_id_instr <= imem_rdata;
                if_id_pc    <= pc;
                if_id_valid <= 1'b1;
            end
        end
    end

    //*************  ID stage  ************
    assign instr = if_id_instr;

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
        is_mul   = 1'b0; is_mulh  = 1'b0; is_mulhsu = 1'b0; is_mulhu = 1'b0;
        is_load  = 1'b0;
        is_lb    = 1'b0; is_lh    = 1'b0; is_lw   = 1'b0; is_lbu  = 1'b0; is_lhu  = 1'b0;
        is_sb    = 1'b0; is_sh    = 1'b0; is_sw   = 1'b0;
        is_csrrw = 1'b0; is_csrrs = 1'b0; is_csrrc = 1'b0;
        is_csrrwi = 1'b0; is_csrrsi = 1'b0; is_csrrci = 1'b0;

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

    // Register file read -- async, same as before (no forwarding yet: a
    // RAW hazard here silently reads a stale value until milestone 4 adds
    // stall detection. Milestone-2 test programs avoid dependent
    // instructions specifically because of this.)
    assign src1_value = (rs1 == 5'b0) ? 32'b0 : regfile[rs1];
    assign src2_value = (rs2 == 5'b0) ? 32'b0 : regfile[rs2];
    assign op_val      = (is_csrrwi | is_csrrsi | is_csrrci) ? zimm : src1_value;

    // csr_optype: 00=RW, 01=RS, 10=RC -- the *I vs register distinction is
    // already resolved into op_val above, so EX/MEM/WB only need to know
    // RW/RS/RC, not which of the 6 original mnemonics.
    logic [1:0] csr_optype;
    assign csr_optype = (is_csrrw | is_csrrwi) ? 2'b00 :
                         (is_csrrs | is_csrrsi) ? 2'b01 :
                         2'b10;  // is_csrrc | is_csrrci

    assign id_ctrl_bus = {
        is_lb, is_lh, is_lw, is_lbu, is_lhu, is_sb, is_sh, is_sw,
        is_lui, is_auipc, is_jal, is_jalr,
        is_beq, is_bne, is_blt, is_bge, is_bltu, is_bgeu,
        is_addi, is_slti, is_sltiu, is_xori, is_ori, is_andi,
        is_slli, is_srli, is_srai,
        is_add, is_sub, is_sll, is_slt, is_sltu, is_xor, is_srl, is_sra, is_or, is_and,
        is_mul, is_mulh, is_mulhsu, is_mulhu,
        is_load, is_s_instr, rd_valid, is_csr, csr_optype
    };

    logic [11:0] id_ex_csr_addr;

    always_ff @(posedge clk) begin : ID_EX_Reg
        if (rst) begin
            id_ex_rd         <= 5'b0;
            id_ex_ctrl        <= 47'b0;
            id_ex_imm         <= 32'b0;
            id_ex_src1_value  <= 32'b0;
            id_ex_src2_value  <= 32'b0;
            id_ex_pc          <= 32'b0;
            id_ex_valid       <= 1'b0;
            id_ex_csr_addr    <= 12'b0;
        end
        else if (!halt) begin
            if (mem_wait) begin
                // MEM can't accept a new result from EX while it's still
                // waiting on the outstanding one -- hold id_ex (and
                // whatever it holds, e.g. a resolved branch) in place
                // rather than letting it advance or get bubbled.
                id_ex_rd         <= id_ex_rd;
                id_ex_ctrl        <= id_ex_ctrl;
                id_ex_imm         <= id_ex_imm;
                id_ex_src1_value  <= id_ex_src1_value;
                id_ex_src2_value  <= id_ex_src2_value;
                id_ex_pc          <= id_ex_pc;
                id_ex_valid       <= id_ex_valid;
                id_ex_csr_addr    <= id_ex_csr_addr;
            end
            else if (ex_flush) begin
                id_ex_rd         <= 5'b0;
                id_ex_ctrl        <= 47'b0;
                id_ex_imm         <= 32'b0;
                id_ex_src1_value  <= 32'b0;
                id_ex_src2_value  <= 32'b0;
                id_ex_pc          <= 32'b0;
                id_ex_valid       <= 1'b0;
                id_ex_csr_addr    <= 12'b0;
            end
            else if (front_stall) begin
                // The dependent instruction stays parked in if_id (held
                // above); EX gets a bubble instead of a second copy of
                // whatever's already in id_ex.
                id_ex_rd         <= 5'b0;
                id_ex_ctrl        <= 47'b0;
                id_ex_imm         <= 32'b0;
                id_ex_src1_value  <= 32'b0;
                id_ex_src2_value  <= 32'b0;
                id_ex_pc          <= 32'b0;
                id_ex_valid       <= 1'b0;
                id_ex_csr_addr    <= 12'b0;
            end
            else begin
                id_ex_rd         <= rd;
                id_ex_ctrl        <= id_ctrl_bus;
                id_ex_imm         <= imm;
                id_ex_src1_value  <= src1_value;
                id_ex_src2_value  <= is_csr ? op_val : src2_value;
                id_ex_pc          <= if_id_pc;
                id_ex_valid       <= if_id_valid;
                id_ex_csr_addr    <= csr_addr;
            end
        end
    end

    //*************  EX stage  ************
    assign {
        ex_is_lb, ex_is_lh, ex_is_lw, ex_is_lbu, ex_is_lhu, ex_is_sb, ex_is_sh, ex_is_sw,
        ex_is_lui, ex_is_auipc, ex_is_jal, ex_is_jalr,
        ex_is_beq, ex_is_bne, ex_is_blt, ex_is_bge, ex_is_bltu, ex_is_bgeu,
        ex_is_addi, ex_is_slti, ex_is_sltiu, ex_is_xori, ex_is_ori, ex_is_andi,
        ex_is_slli, ex_is_srli, ex_is_srai,
        ex_is_add, ex_is_sub, ex_is_sll, ex_is_slt, ex_is_sltu, ex_is_xor, ex_is_srl, ex_is_sra, ex_is_or, ex_is_and,
        ex_is_mul, ex_is_mulh, ex_is_mulhsu, ex_is_mulhu,
        ex_is_load, ex_is_s_instr, ex_rd_valid, ex_is_csr, ex_csr_optype
    } = id_ex_ctrl;

    // Set less than unsigned
    assign ex_sltu_rslt  = {31'b0, id_ex_src1_value < id_ex_src2_value};
    assign ex_sltiu_rslt = {31'b0, id_ex_src1_value < id_ex_imm};

    // Shift right arithmetic (sign-extend, then shift)
    assign ex_sext_src1 = {{32{id_ex_src1_value[31]}}, id_ex_src1_value};
    assign ex_sra_rslt  = ex_sext_src1 >> id_ex_src2_value[4:0];
    assign ex_srai_rslt = ex_sext_src1 >> id_ex_imm[4:0];

    // RV32M: 64-bit product, sign/zero-extended per variant before multiply
    logic signed [63:0] ex_mul_ss_rslt;
    logic signed [63:0] ex_mul_su_rslt;
    logic        [63:0] ex_mul_uu_rslt;

    assign ex_mul_ss_rslt = $signed(id_ex_src1_value) * $signed(id_ex_src2_value);
    assign ex_mul_su_rslt = $signed(id_ex_src1_value) * $signed({1'b0, id_ex_src2_value});
    assign ex_mul_uu_rslt = id_ex_src1_value * id_ex_src2_value;

    assign ex_result =
        ex_is_andi    ? id_ex_src1_value & id_ex_imm               :
        ex_is_ori     ? id_ex_src1_value | id_ex_imm               :
        ex_is_xori    ? id_ex_src1_value ^ id_ex_imm               :
        ex_is_addi    ? id_ex_src1_value + id_ex_imm               :
        ex_is_slli    ? id_ex_src1_value << id_ex_imm[5:0]         :
        ex_is_srli    ? id_ex_src1_value >> id_ex_imm[5:0]         :
        ex_is_and     ? id_ex_src1_value & id_ex_src2_value        :
        ex_is_or      ? id_ex_src1_value | id_ex_src2_value        :
        ex_is_xor     ? id_ex_src1_value ^ id_ex_src2_value        :
        ex_is_add     ? id_ex_src1_value + id_ex_src2_value        :
        ex_is_sub     ? id_ex_src1_value - id_ex_src2_value        :
        ex_is_sll     ? id_ex_src1_value << id_ex_src2_value[4:0]  :
        ex_is_srl     ? id_ex_src1_value >> id_ex_src2_value[4:0]  :
        ex_is_sltu    ? ex_sltu_rslt                                :
        ex_is_sltiu   ? ex_sltiu_rslt                               :
        ex_is_lui     ? {id_ex_imm[31:12], 12'b0}                   :
        ex_is_auipc   ? id_ex_pc + id_ex_imm                        :
        ex_is_jal     ? id_ex_pc + 32'd4                            :
        ex_is_jalr    ? id_ex_pc + 32'd4                            :
        ex_is_slt     ? ((id_ex_src1_value[31] == id_ex_src2_value[31]) ? ex_sltu_rslt : {31'b0, id_ex_src1_value[31]}) :
        ex_is_slti    ? ((id_ex_src1_value[31] == id_ex_imm[31]) ? ex_sltiu_rslt : {31'b0, id_ex_src1_value[31]}) :
        ex_is_sra     ? ex_sra_rslt[31:0]                           :
        ex_is_srai    ? ex_srai_rslt[31:0]                          :
        ex_is_load    ? id_ex_src1_value + id_ex_imm                :
        ex_is_s_instr ? id_ex_src1_value + id_ex_imm                :
        ex_is_mul     ? ex_mul_ss_rslt[31:0]                        :
        ex_is_mulh    ? ex_mul_ss_rslt[63:32]                       :
        ex_is_mulhsu  ? ex_mul_su_rslt[63:32]                       :
        ex_is_mulhu   ? ex_mul_uu_rslt[63:32]                       :
        32'b0;

    assign ex_wr_en = (id_ex_rd == 5'b0) ? 1'b0 : ex_rd_valid;

    assign ex_taken_br =
        ex_is_beq  ? (id_ex_src1_value == id_ex_src2_value)                                        :
        ex_is_bne  ? (id_ex_src1_value != id_ex_src2_value)                                         :
        ex_is_blt  ? ((id_ex_src1_value < id_ex_src2_value) ^ (id_ex_src1_value[31] != id_ex_src2_value[31])) :
        ex_is_bge  ? ((id_ex_src1_value >= id_ex_src2_value) ^ (id_ex_src1_value[31] != id_ex_src2_value[31])) :
        ex_is_bltu ? (id_ex_src1_value < id_ex_src2_value)                                          :
        ex_is_bgeu ? (id_ex_src1_value >= id_ex_src2_value)                                         :
        1'b0;

    assign ex_br_tgt_pc   = id_ex_pc + id_ex_imm;
    assign ex_jalr_tgt_pc = id_ex_src1_value + id_ex_imm;

    always_ff @(posedge clk) begin : EX_MEM_Reg
        if (rst) begin
            ex_mem_result      <= 32'b0;
            ex_mem_src2_value  <= 32'b0;
            ex_mem_rd          <= 5'b0;
            ex_mem_is_load     <= 1'b0;
            ex_mem_is_s_instr  <= 1'b0;
            ex_mem_is_lb       <= 1'b0;
            ex_mem_is_lh       <= 1'b0;
            ex_mem_is_lw       <= 1'b0;
            ex_mem_is_lbu      <= 1'b0;
            ex_mem_is_lhu      <= 1'b0;
            ex_mem_is_sb       <= 1'b0;
            ex_mem_is_sh       <= 1'b0;
            ex_mem_is_sw       <= 1'b0;
            ex_mem_wr_en       <= 1'b0;
            ex_mem_valid       <= 1'b0;
            ex_mem_is_csr      <= 1'b0;
            ex_mem_csr_optype  <= 2'b0;
            ex_mem_csr_addr    <= 12'b0;
        end
        else if (!halt) begin
            if (mem_wait) begin
                ex_mem_result      <= ex_mem_result;
                ex_mem_src2_value  <= ex_mem_src2_value;
                ex_mem_rd          <= ex_mem_rd;
                ex_mem_is_load     <= ex_mem_is_load;
                ex_mem_is_s_instr  <= ex_mem_is_s_instr;
                ex_mem_is_lb       <= ex_mem_is_lb;
                ex_mem_is_lh       <= ex_mem_is_lh;
                ex_mem_is_lw       <= ex_mem_is_lw;
                ex_mem_is_lbu      <= ex_mem_is_lbu;
                ex_mem_is_lhu      <= ex_mem_is_lhu;
                ex_mem_is_sb       <= ex_mem_is_sb;
                ex_mem_is_sh       <= ex_mem_is_sh;
                ex_mem_is_sw       <= ex_mem_is_sw;
                ex_mem_wr_en       <= ex_mem_wr_en;
                ex_mem_valid       <= ex_mem_valid;
                ex_mem_is_csr      <= ex_mem_is_csr;
                ex_mem_csr_optype  <= ex_mem_csr_optype;
                ex_mem_csr_addr    <= ex_mem_csr_addr;
            end
            else begin
                ex_mem_result      <= ex_result;
                ex_mem_src2_value  <= id_ex_src2_value;
                ex_mem_rd          <= id_ex_rd;
                ex_mem_is_load     <= ex_is_load;
                ex_mem_is_s_instr  <= ex_is_s_instr;
                ex_mem_is_lb       <= ex_is_lb;
                ex_mem_is_lh       <= ex_is_lh;
                ex_mem_is_lw       <= ex_is_lw;
                ex_mem_is_lbu      <= ex_is_lbu;
                ex_mem_is_lhu      <= ex_is_lhu;
                ex_mem_is_sb       <= ex_is_sb;
                ex_mem_is_sh       <= ex_is_sh;
                ex_mem_is_sw       <= ex_is_sw;
                ex_mem_wr_en       <= ex_wr_en;
                ex_mem_valid       <= id_ex_valid;
                ex_mem_is_csr      <= ex_is_csr;
                ex_mem_csr_optype  <= ex_csr_optype;
                ex_mem_csr_addr    <= id_ex_csr_addr;
            end
        end
    end

    //*************  MEM stage  ***********
    logic [1:0]  byte_off;
    logic [31:0] ld_shifted;
    logic [7:0]  ld_byte;
    logic [15:0] ld_half;
    logic [31:0] ld_extracted;

    assign byte_off   = ex_mem_result[1:0];
    assign ld_shifted = ld_data >> (byte_off * 8);
    assign ld_byte    = ld_shifted[7:0];
    assign ld_half    = ld_shifted[15:0];

    assign ld_extracted =
        ex_mem_is_lb  ? {{24{ld_byte[7]}},  ld_byte}  :
        ex_mem_is_lh  ? {{16{ld_half[15]}}, ld_half}  :
        ex_mem_is_lbu ? {24'b0, ld_byte}              :
        ex_mem_is_lhu ? {16'b0, ld_half}              :
        ld_data;  // ex_mem_is_lw

    assign dmem_addr     = ex_mem_result;        // address computed by ALU
    assign dmem_wdata    = ex_mem_src2_value << (byte_off * 8);  // shift store data into its byte lane
    assign dmem_we       = ex_mem_is_s_instr && ex_mem_valid;
    assign dmem_re       = ex_mem_is_load && ex_mem_valid;
    assign dmem_byteena  =
        ex_mem_is_sb ? (4'b0001 << byte_off) :
        ex_mem_is_sh ? (4'b0011 << byte_off) :
        ex_mem_is_sw ? 4'b1111               :
        4'b0000;

    assign mem_wr_data = ex_mem_is_load ? ld_extracted : ex_mem_result;

    always_ff @(posedge clk) begin : MEM_WB_Reg
        if (rst) begin
            mem_wb_wr_data <= 32'b0;
            mem_wb_rd      <= 5'b0;
            mem_wb_wr_en   <= 1'b0;
            mem_wb_valid   <= 1'b0;
            mem_wb_is_csr     <= 1'b0;
            mem_wb_csr_optype <= 2'b0;
            mem_wb_csr_addr   <= 12'b0;
            mem_wb_csr_op_val <= 32'b0;
        end
        else if (!halt) begin
            if (mem_wait) begin
                // ld_data/mem_wr_data isn't valid yet -- bubble instead of
                // latching garbage into mem_wb_wr_data and committing it
                // via the (ungated) regfile write port below.
                mem_wb_wr_data <= 32'b0;
                mem_wb_rd      <= 5'b0;
                mem_wb_wr_en   <= 1'b0;
                mem_wb_valid   <= 1'b0;
                mem_wb_is_csr     <= 1'b0;
                mem_wb_csr_optype <= 2'b0;
                mem_wb_csr_addr   <= 12'b0;
                mem_wb_csr_op_val <= 32'b0;
            end
            else begin
                mem_wb_wr_data <= mem_wr_data;
                mem_wb_rd      <= ex_mem_rd;
                mem_wb_wr_en   <= ex_mem_wr_en;
                mem_wb_valid   <= ex_mem_valid;
                mem_wb_is_csr     <= ex_mem_is_csr;
                mem_wb_csr_optype <= ex_mem_csr_optype;
                mem_wb_csr_addr   <= ex_mem_csr_addr;
                mem_wb_csr_op_val <= ex_mem_src2_value;
            end
        end
    end

    //*************  WB stage  ************
    // CSR read-modify-write commits atomically here (same commit point as
    // the regfile write) -- retirement is strictly in-order, so an
    // instruction reaching this stage always sees every older instruction's
    // CSR write already committed, making CSR-after-CSR RAW hazards
    // structurally impossible without any new stall-detection logic.
    logic [31:0] csr_mstatus, csr_mie, csr_mtvec, csr_mscratch;
    logic [31:0] csr_mepc, csr_mcause, csr_mtval, csr_mip;
    logic [31:0] csr_rdata_wb;
    logic [31:0] csr_new_val;

    assign csr_rdata_wb =
        mem_wb_csr_addr == 12'h300 ? csr_mstatus  :
        mem_wb_csr_addr == 12'h304 ? csr_mie      :
        mem_wb_csr_addr == 12'h305 ? csr_mtvec    :
        mem_wb_csr_addr == 12'h340 ? csr_mscratch :
        mem_wb_csr_addr == 12'h341 ? csr_mepc     :
        mem_wb_csr_addr == 12'h342 ? csr_mcause   :
        mem_wb_csr_addr == 12'h343 ? csr_mtval    :
        mem_wb_csr_addr == 12'h344 ? csr_mip      :
        32'b0;   // misa, mhartid, everything else: read as 0

    assign csr_new_val =
        (mem_wb_csr_optype == 2'b00) ? mem_wb_csr_op_val                  :
        (mem_wb_csr_optype == 2'b01) ? (csr_rdata_wb | mem_wb_csr_op_val) :
                                        (csr_rdata_wb & ~mem_wb_csr_op_val); // 2'b10 = RC

    always_ff @(posedge clk) begin
        if (mem_wb_is_csr && mem_wb_valid && !halt) begin
            case (mem_wb_csr_addr)
                12'h300: csr_mstatus  <= csr_new_val;
                12'h304: csr_mie      <= csr_new_val;
                12'h305: csr_mtvec    <= csr_new_val;
                12'h340: csr_mscratch <= csr_new_val;
                12'h341: csr_mepc     <= csr_new_val;
                12'h342: csr_mcause   <= csr_new_val;
                12'h343: csr_mtval    <= csr_new_val;
                12'h344: csr_mip      <= csr_new_val;
                default: ;  // misa/mhartid/unimplemented: write ignored
            endcase
        end
    end

    assign wr_data = mem_wb_is_csr ? csr_rdata_wb : mem_wb_wr_data;
    assign wr_en   = mem_wb_wr_en;

    // Internal Register File
    logic [31:0] regfile [31:0];

    // Write port
    always_ff @(posedge clk) begin
        if (wr_en && (mem_wb_rd != 5'b0) && mem_wb_valid && !halt)
            regfile[mem_wb_rd] <= wr_data;
    end

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
