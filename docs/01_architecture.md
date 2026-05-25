# High-level:

## Word size

## Endianness
- Little Endian

## Memory Map

| Base Address | End Address  | Size | Description          |
|--------------|--------------|------|----------------------|
| `0x00000000` | `0x00003FFF` | 16KB | DP BRAM (boot + program) |
| `0x10000000` | `0x10000000` | 4B   | UART TX data         |
| `0x10000004` | `0x10000004` | 4B   | UART RX data         |
| `0x10000008` | `0x10000008` | 4B   | UART status (bit 0 = TX_busy, bit 1 = RX_done) |

## Register count

## Address space layout

## Interrupt model

## Target clock frequency