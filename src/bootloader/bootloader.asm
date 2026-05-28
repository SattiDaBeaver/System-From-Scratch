# src/bootloader/bootloader.S
# Bootloader for RISC-V SoC
# Loads a program over UART and jumps to it
#
# Memory Map:
#   0x00000000 - 0x00000FFF  Bootloader (this code)
#   0x00001000 - 0x00003FFF  Program
#
# UART Memory Map:
#   0x10000000  TX data
#   0x10000004  RX data
#   0x10000008  Status (bit0 = TX_busy, bit1 = RX_done)
#
# Protocol:
#   1. Send 0xAA (ready)
#   2. Receive 4 bytes (program size, little endian)
#   3. Receive N bytes (program binary)
#   4. Receive 1 byte (XOR checksum)
#   5. Send 0xBB (ok) or 0xEE (error)
#   6. Jump to 0x00001000

# Register conventions:
#   x1  = return address (ra)
#   x2  = stack pointer (sp)
#   x3  = UART base address
#   x4  = scratch / temp
#   x5  = scratch / temp
#   x10 = function arg / return value (a0)

.section .text
.globl _start

_start:
    # ── Setup ──────────────────────────────
    li   x2, 0x00003FFC          # stack pointer = top of BRAM
    li   x3, 0x10000000          # UART base address

    # ── Send ready byte 0xAA ───────────────
    li   x10, 0xAA
    jal  x1, uart_tx_byte

    # ── Receive 4 byte program size ────────
    jal  x1, uart_rx_byte
    mv   x20, x10                # size byte 0 (LSB)

    jal  x1, uart_rx_byte
    slli x10, x10, 8
    or   x20, x20, x10           # size byte 1

    jal  x1, uart_rx_byte
    slli x10, x10, 16
    or   x20, x20, x10           # size byte 2

    jal  x1, uart_rx_byte
    slli x10, x10, 24
    or   x20, x20, x10           # size byte 3 (MSB)
                                  # x20 = total program size in bytes

    # ── Receive program bytes ───────────────
    li   x21, 0x00001000         # load destination address
    mv   x22, x20                # byte counter
    li   x23, 0                  # checksum accumulator

recv_loop:
    beq  x22, x0, recv_done
    jal  x1, uart_rx_byte        # get byte 0
    mv   x24, x10

    jal  x1, uart_rx_byte        # get byte 1
    slli x10, x10, 8
    or   x24, x24, x10

    jal  x1, uart_rx_byte        # get byte 2
    slli x10, x10, 16
    or   x24, x24, x10

    jal  x1, uart_rx_byte        # get byte 3
    slli x10, x10, 24
    or   x24, x24, x10

    sw   x24, 0(x21)             # store word
    xor  x23, x23, x24           # update checksum over word
    addi x21, x21, 4             # increment by word
    addi x22, x22, -4            # decrement by 4
    j    recv_loop

recv_done:
    # ── Receive and verify checksum ─────────
    jal  x1, uart_rx_byte        # x10 = received checksum
    bne  x10, x23, boot_error    # checksum mismatch

    # ── Send OK and jump ────────────────────
    li   x10, 0xBB
    jal  x1, uart_tx_byte
    li   x4, 0x00001000
    jalr x0, x4, 0               # jump to program

boot_error:
    li   x10, 0xEE
    jal  x1, uart_tx_byte
error_loop:
    j    error_loop               # hang

# ────────────────────────────────────────────
#  uart_tx_byte
#  Send byte in x10 over UART
#  Clobbers: x4, x5
# ────────────────────────────────────────────
uart_tx_byte:
    # Wait until not busy
tx_wait:
    lw   x4, 8(x3)               # read status register
    andi x4, x4, 1               # check TX_busy (bit 0)
    bne  x4, x0, tx_wait         # loop if busy

    sw   x10, 0(x3)              # write byte to TX register
    ret

# ────────────────────────────────────────────
#  uart_rx_byte
#  Wait for and return received byte in x10
#  Clobbers: x4
# ────────────────────────────────────────────
uart_rx_byte:
    # Wait for RX_done
rx_wait:
    lw   x4, 8(x3)               # read status register
    andi x4, x4, 2               # check RX_done (bit 1)
    beq  x4, x0, rx_wait         # loop if not done

    lw   x10, 4(x3)              # read RX data register
    ret
