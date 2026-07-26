# Microarchitecture

## 1. Where we are today: single-cycle

`src/riscv_core/riscv_core.sv` is a classic single-cycle RV32I core: fetch,
decode, execute, memory access, and writeback all happen combinationally
within one clock period, and `pc` is the only pipeline register in the
whole design.

```
        ┌─────────────────────────── 1 clock period ───────────────────────────┐
clk  ───┘                                                                       └───
        │  IF (imem_addr=pc)   │  decode/ALU/branch (comb)   │  MEM (comb)   │  WB (regfile <= wr_data, on next edge)
        └──────────────────────┴─────────────────────────────┴───────────────┘
pc  ────────────────┐                                                    ┌─── pc+4 or br_tgt_pc or jalr_tgt_pc
                     └────────────────────────────────────────────────────┘
```

This works today because `dp_ram_model.v`/`.sv`'s sim stand-in defaults to
`REGISTERED_ADDR=0` — a purely combinational, zero-latency memory. It
breaks on real hardware because Quartus's `altsyncram` (`fpga/dp_ram.v`)
cannot actually provide that: block RAM (M9K on MAX 10) always captures its
address on a clock edge before the array is read, regardless of the
`address_reg_a/b`/`outdata_reg_a/b` wizard settings — those settings only
control whether there's an *extra* register on top of that inherent
capture, not whether the capture happens at all. So `imem_addr = pc` this
cycle can only ever produce `imem_rdata` from *some* earlier cycle's
address — a real RAM read is fundamentally at least 1 cycle deep.

That's not a bug to patch around — it's the actual reason real CPUs
pipeline. A single-cycle design assuming 0-cycle memory just doesn't map
onto real block RAM, full stop. The fix is architectural: give the design
enough cycles between "ask memory for something" and "need memory's
answer" that the real latency fits without stalling everything.

## 2. How to derive pipeline stages, in general

Stage boundaries are not a matter of taste. Three forces decide them, and
you apply them in this order:

**1. Shared-resource conflicts force separation.** If two things a single
instruction needs to do both want the same physical port in the same
cycle, they cannot be the same stage unless you duplicate the port. This
project's BRAM already has two independent ports (`address_a`/`q_a` for
imem, `address_b`/`q_b` for dmem) specifically so instruction fetch and
data memory access can happen *in the same cycle for two different
in-flight instructions*. That single fact is what makes a 5-stage split
free (in the hardware-resource sense) rather than something you'd need to
build extra ports for.

**2. Sequential dependency within one instruction forces ordering.** You
cannot decode before you've fetched (you don't have the instruction bits
yet), cannot execute before decode (you need `rs1`/`rs2`/`imm`/opcode
class), cannot access memory before you've computed an address (EX must
run first), cannot write back before you have a result (from EX or MEM).
This ordering is not optional — it's just "what data is available when."
The *only* real design choice here is how finely to cut it. Register-file
reads are just async lookups (`src1_value = regfile[rs1]`, already how
this core reads today), not real computation, so they conventionally ride
along with decode rather than getting their own stage.

**3. Once (1) and (2) fix the rough stage boundaries, balance critical
path length across stages.** The pipeline's achievable clock period is
bounded by its *slowest* stage, so you don't want e.g. decode+ALU+branch
compare all crammed into one stage while another stage does almost
nothing. This is why EX is conventionally split out on its own even though
nothing *forces* it to be separate from decode the way memory-port sharing
forces IF/MEM apart — the ALU/comparator/address-adder logic is real
combinational depth (see `sra_rslt`/`srai_rslt`'s 64-bit shift, the giant
`result` mux, `taken_br`'s comparator tree in the current code) and
deserves its own cycle so it isn't the thing that sets your clock period
twice as high as it needs to be.

Classic **IF → ID → EX → MEM → WB** is exactly this reasoning applied to a
simple RV32I core: cut 1 (memory ports) separates IF from MEM; cut 2/3
(dependency + balance) separates ID, EX, and WB from each other and from
IF/MEM. It isn't a convention you follow because everyone else does — it's
the minimal, resource-respecting cut for *this specific* instruction set
and memory topology. A core with a multi-cycle divide, a cache, or more
memory ports would legitimately end up with a different stage count.

### What actually moves into a pipeline register

Between every pair of adjacent stages you need a register that carries
forward whatever the *later* stage needs but the *earlier* stage already
computed and would otherwise lose. Concretely, using this core's existing
signal names as the running example:

| Boundary  | Must carry forward | Why |
|-----------|--------------------|-----|
| IF/ID     | `instr`, `pc`      | ID needs the raw instruction to decode; EX needs `pc` for `br_tgt_pc = pc + imm`, `auipc`, `jal`'s `pc+4` |
| ID/EX     | `rd`, decoded control signals (`is_addi`, `is_load`, ..., or a compact encoded form), `imm`, `src1_value`, `src2_value`, `pc` | EX needs operands + which op to perform; WB later needs `rd` |
| EX/MEM    | `result` (address for loads/stores, or the ALU result to forward to WB), `src2_value` (store data), `rd`, `is_load`, `dmem_we` | MEM needs an address and (for stores) data; WB downstream still needs `rd` |
| MEM/WB    | `wr_data` (either `ld_data` or the carried-forward `result`), `rd`, `wr_en` | WB just commits this to the regfile |

Nothing here is invented — every one of those fields already exists as a
signal in today's single-cycle `riscv_core.sv`. Pipelining is mechanically
"draw 4 register boundaries through the existing combinational logic,"
not "redesign the ALU/decoder."

## 3. Prefetch, misprediction, and flushing

"Optimistic prefetch" means IF never waits to find out whether the
previous instruction was a branch — it always fetches at whatever
`next_pc` is *right now*, under the default assumption **predict
not-taken**: `next_pc = pc + 4` unless something later overrides it.
There's no branch predictor state here, just the simplest possible
default.

The problem: `taken_br`/`is_jal`/`is_jalr` don't resolve until EX (they
need the ALU/comparator). With IF→ID→EX→MEM→WB, by the time EX discovers
"actually, we should have jumped to `br_tgt_pc`", IF and ID have *already*
fetched and decoded the two sequential instructions immediately after the
branch — and those are wrong.

**Flushing** is how you recover: the same cycle EX resolves a taken
branch/jump,
1. `next_pc` is overridden to `br_tgt_pc`/`jalr_tgt_pc` — IF fetches
   correctly starting next cycle.
2. The IF/ID and ID/EX pipeline registers (the two stages holding
   instructions fetched from the wrong path) are squashed into NOPs —
   every control signal that could write state (`wr_en`, `dmem_we`,
   `dmem_re`) forced to 0, `rd` forced to `x0` — so garbage in-flight
   instructions drain out without corrupting the regfile or memory.

With branch resolution in EX and this stage count, a taken branch/jump
always costs exactly 2 bubble cycles. That's the cost of predict-not-taken
with no earlier resolution point; it's not a bug, it's the price of this
specific pipeline depth, and it's a well-understood, bounded cost (as
opposed to, say, a cache miss, which is unbounded).

## 4. Reset and startup

Two independent things need to be correct on reset, not just one:

- `pc` resets to 0 — unchanged from the current design.
- Every pipeline register (IF/ID, ID/EX, EX/MEM, MEM/WB) needs an explicit
  **valid bit**, reset to 0, alongside its data fields. For the first few
  cycles after reset, the stages downstream of IF haven't received a real
  fetched instruction yet — without a valid bit gating `wr_en`/`dmem_we`/
  `dmem_re`, whatever's in those registers at power-up (X's in sim, or
  literal undefined SRAM contents on hardware) could be misinterpreted as
  a real instruction and fire a bogus write before the pipeline has
  actually filled. This is the *same mechanism* as a branch flush (force
  the control signals to their "do nothing" state) triggered by a
  different event (reset vs. a resolved branch) — worth implementing once,
  reusably, rather than as two separate ad-hoc paths.

## 5. Proposed 5-stage layout for this core

```
        IF          ID              EX                  MEM              WB
   ┌─────────┐ ┌───────────┐  ┌──────────────┐    ┌──────────────┐  ┌───────────┐
   │ pc      │ │ decode    │  │ ALU / branch │    │ dmem access  │  │ regfile   │
   │ imem rd │→│ regfile rd│→ │ compute      │→   │ (dp_ram      │→ │ writeback │
   │ (port A)│ │ (comb)    │  │ br_tgt/jalr  │    │  port B)     │  │           │
   └─────────┘ └───────────┘  └──────────────┘    └──────────────┘  └───────────┘
        │            │               │                    │               │
      IF/ID        ID/EX          EX/MEM               MEM/WB          (regfile
      reg          reg            reg                  reg              write port)
        │            │               │                    │
   instr,pc    rd,ctrl,imm,    result,src2_value,    wr_data,rd,
               src1,src2,pc    rd,is_load,dmem_we     wr_en

   flush: EX branch/jump resolution forces IF/ID and ID/EX registers to
          NOP (valid=0) the same cycle it redirects next_pc.
```

Mapped onto today's `riscv_core.sv` signal names, per stage:

- **IF**: `imem_addr = pc`; `pc` update logic (currently in the
  `ProgramCounter always_ff` block) moves here, driven by `next_pc` from
  EX's flush/branch logic instead of computing `taken_br`/`is_jal` locally
  — IF doesn't know yet whether it's fetching correctly.
- **ID**: everything currently in `Decoder_Logic`, the `is_*_instr`/
  `is_lui`/`is_addi`/... decode, `rs1`/`rs2`/`funct3`/`rd`/`opcode` field
  extraction, `imm` construction, and the regfile read
  (`src1_value`/`src2_value`) — all of this is already purely
  combinational off `instr` today, so it moves into ID largely unchanged.
- **EX**: the ALU `result` mux, `sltu_rslt`/`sra_rslt`/etc., `taken_br`,
  `br_tgt_pc`, `jalr_tgt_pc` — unchanged logic, just fed from the ID/EX
  register's carried operands instead of directly from decode.
- **MEM**: `dmem_addr = result`, `dmem_wdata = src2_value`, `dmem_we`,
  `dmem_re`, and the incoming `ld_data` — unchanged, just now clearly a
  separate stage instead of "the same cycle as EX."
- **WB**: `regfile[rd] <= wr_data` — unchanged logic, now explicitly one
  more cycle downstream of MEM instead of the same cycle.

None of the ALU/decode/branch *logic itself* needs to be rewritten. The
work is: add the 4 pipeline registers above (with valid bits), move the
`pc` update to depend on EX's resolution instead of local combinational
signals, and add the 2-cycle flush path.

## 6. SV coding patterns used/expected in this codebase

A few idioms recur across `riscv_core.sv`, `uart.sv`, and `debug_uart.sv`
that are worth naming explicitly, since they're the vocabulary the
pipeline should be written in too.

### Decode as parallel one-hot booleans, not an enum

```systemverilog
logic is_lui, is_auipc, is_jal, is_jalr;
logic is_beq, is_bne, is_blt, is_bge, is_bltu, is_bgeu;
...
always_comb begin
    is_lui = 1'b0; is_auipc = 1'b0; ...   // defaults, every branch of the case below
    casez (dec_bits)
        11'b?_???_0110111: is_lui   = 1'b1;
        11'b?_???_0010111: is_auipc = 1'b1;
        ...
    endcase
end
```

Why one-hot booleans instead of a single `typedef enum {LUI, AUIPC, ...}
instr_t`: the downstream logic (the `result` mux, `wr_en`, `dmem_we`) reads
far more naturally as `is_addi ? ... : is_slli ? ... : ...` than as a
`case (instr_type)` that has to be repeated at every use site. It also
means "this instruction behaves like a load for register-file purposes"
can be expressed as `is_load` alone without a big `case` arm duplicated
wherever that fact matters. The cost is more signals; the benefit is every
use site is a flat ternary instead of a nested case, which is why RV32I
cores in general lean this way rather than a single opcode enum. `dec_bits
= {instr[30], funct3, opcode}` packing multiple instruction fields into one
`casez` key is the same technique applied at the *classification* level
(is_r_instr/is_i_instr/etc.) before the *specific-operation* level
(is_add/is_addi/etc.) — two decode passes, coarse then fine, both using
the same one-hot-boolean output style.

### `casez` with `?` wildcards over exact `case`

RV32I's opcode space is deliberately structured so whole instruction
classes share bit patterns with "don't care" positions (e.g. all I-type
ALU ops share `opcode=0010011`, differing only in `funct3`). `casez`'s `?`
lets you match "any value in these don't-care bit positions" directly
against the ISA's actual bit-field structure, instead of writing out every
concrete encoding — see `5'b0?101: is_u_instr = 1'b1;` matching both LUI
(`0110111`) and AUIPC (`0010111`) with one line, since bit 3 is the only
difference and it's irrelevant to "is this a U-type."

### FSMs: `typedef enum` + a single `case` in one `always_ff`

```systemverilog
typedef enum logic [1:0] {
    IDLE, START, RECEIVE, DONE
} state_t;
state_t state;

always_ff @(posedge clk) begin
    if (rst) begin
        state <= IDLE;
        ... // every other reset value
    end
    else begin
        case (state)
            IDLE: begin ... end
            START: begin ... end
            ...
            default: state <= IDLE;   // always have a recovery path
        endcase
    end
end
```

`UART_RX`/`UART_TX` (`uart.sv`) and the whole command protocol in
`debug_uart.sv` follow this shape: one `state_t` enum, one `always_ff` with
an `if (rst) / else case (state)` split, and every state explicitly
transitions somewhere (including a `default:` fallback to a safe state —
see `debug_uart.sv`'s `rx_timeout_cnt` logic for the same "don't trust the
outside world to always cooperate" instinct applied to a wait state
instead of just the top-level `default`). A pipeline's stage-valid tracking
doesn't need a state enum (each stage is just "did IF/ID/EX/MEM/WB fire
this cycle," not a multi-state wait), but the reset-then-case structure
and the discipline of *always* having an explicit fallback/recovery
transition is the same habit to keep.

### Combinational blocks always assign every output, every branch

```systemverilog
always_comb begin
    RXdone = dataDone;
    if (PARITY_BITS > 0) begin
        parityError = (^RXout) ^ parity;
    end
    else begin
        parityError = 0;
    end
end
```

Every `always_comb` in this codebase assigns all of its outputs on every
path (including default assignments at the top of decode blocks before a
`casez`, as seen in `Decoder_Logic` and the instruction-type block). This
isn't style preference — an `always_comb` with a path that doesn't assign
an output infers a latch in synthesis, which is virtually never what you
want and is exactly the kind of bug that's invisible in behavioral sim but
appears as a timing/functional mismatch on real hardware. Keep this
discipline in every new decode/control block the pipeline adds.

### Registered outputs default to their "safe" value at the top of the block, then get overridden

```systemverilog
always_ff @(posedge clk) begin
    if (rst) begin
        TXout <= 1'b1;
        ...
    end
    else begin
        case (state)
            IDLE: begin
                TXout    <= 1'b1;   // restated every state, not just reset
                ...
```

`TXout` is pulled back to its idle-line value (`1'b1`) explicitly in the
`IDLE` case arm, not just on reset — so a stray mid-transmission glitch
that lands the FSM back in `IDLE` can't leave `TXout` stuck at whatever it
last was. The pipeline's flush logic (Section 3) is this same pattern:
don't just handle the "reset" case, restate the safe/NOP values whenever
you're re-entering a state from an unexpected path (a flush is exactly
"unexpectedly re-entering a known-good state mid-stream").
