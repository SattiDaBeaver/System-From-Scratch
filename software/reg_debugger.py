# software/reg_debugger.py
#
# Host-side client for the FPGA hardware register debugger (debug_uart.sv).
# Talks to a dedicated debug UART (separate pins/port from the program
# link driven by uart_loader.py) to halt/step the CPU and read back its
# register file + PC, so hardware runs can be cross-checked against the
# same register snapshots produced by cocotb sim (see test/utils.py's
# read_reg()).
#
# Protocol (see src/peripherals/debug_uart.sv for the authoritative spec):
#   0x01 HALT      -> no reply
#   0x02 RESUME    -> no reply
#   0x03 STEP      -> no reply, advances exactly one core clock cycle
#   0x04 <idx>     -> 4 bytes LE, regfile[idx]  (idx 0-31)
#   0x05 READ_PC   -> 4 bytes LE, pc
#   0x06 READ_ALL  -> 33 x 4 bytes LE, regfile[0..31] then pc
#   0x07 <addr32> <data32> -> WRITE_MEM, no reply. Only accepted while
#                     halted -- silently ignored otherwise.
#   0x08 <addr32>  -> READ_MEM, 4 bytes LE, word at addr32. Only accepted
#                     while halted -- silently ignored otherwise (read
#                     will then time out, since no reply is sent).

import struct
import sys
import re
import argparse

BAUD_RATE = 115200
TIMEOUT   = 5  # seconds

CMD_HALT      = 0x01
CMD_RESUME    = 0x02
CMD_STEP      = 0x03
CMD_READ_REG  = 0x04
CMD_READ_PC   = 0x05
CMD_READ_ALL  = 0x06
CMD_WRITE_MEM = 0x07
CMD_READ_MEM  = 0x08


class _DryRunSerial:
    """Stands in for serial.Serial when --dry-run is set: prints every
    write as hex instead of touching a real port, so the protocol layer
    (RegDebugger) can be exercised on a machine with no pyserial install
    and no hardware attached. Reads return zero-filled words so callers
    that expect a reply (read_reg/read_pc/read_all) don't block forever."""

    def __init__(self, port, baud, timeout):
        print(f"[DRY-RUN] would open {port} at {baud} baud (timeout={timeout}s)")

    def write(self, data):
        print(f"[DRY-RUN] TX: {data.hex(' ')}")

    def read(self, n):
        print(f"[DRY-RUN] RX: (no hardware attached) returning {n} zero byte(s)")
        return bytes(n)

    def close(self):
        print("[DRY-RUN] closed")


class RegDebugger:
    def __init__(self, port, baud=BAUD_RATE, timeout=TIMEOUT, dry_run=False):
        if dry_run:
            self.ser = _DryRunSerial(port, baud, timeout)
        else:
            import serial
            self.ser = serial.Serial(port, baud, timeout=timeout)

    def close(self):
        self.ser.close()

    def _read_word(self):
        raw = self.ser.read(4)
        if len(raw) != 4:
            raise IOError(f"Timeout waiting for 4-byte reply, got {len(raw)} bytes")
        return struct.unpack('<I', raw)[0]

    def halt(self):
        self.ser.write(bytes([CMD_HALT]))

    def resume(self):
        self.ser.write(bytes([CMD_RESUME]))

    def step(self, n=1):
        for _ in range(n):
            self.ser.write(bytes([CMD_STEP]))

    def read_reg(self, idx):
        if not (0 <= idx <= 31):
            raise ValueError("register index must be 0-31")
        self.ser.write(bytes([CMD_READ_REG, idx]))
        return self._read_word()

    def read_pc(self):
        self.ser.write(bytes([CMD_READ_PC]))
        return self._read_word()

    def read_all(self):
        """Returns (regs, pc) where regs is a list of 32 ints (x0-x31)."""
        self.ser.write(bytes([CMD_READ_ALL]))
        regs = [self._read_word() for _ in range(32)]
        pc = self._read_word()
        return regs, pc

    def write_mem(self, addr, data):
        """WRITE_MEM. Only takes effect while the core is halted -- the
        hardware silently ignores this command otherwise, so callers must
        halt() first."""
        self.ser.write(bytes([CMD_WRITE_MEM]) + struct.pack('<I', addr) + struct.pack('<I', data))

    def read_mem(self, addr):
        """READ_MEM. Only accepted while halted; if not halted, the
        hardware sends no reply and this will time out waiting for one."""
        self.ser.write(bytes([CMD_READ_MEM]) + struct.pack('<I', addr))
        return self._read_word()

    def load_program(self, words, base_addr=0):
        """Convenience wrapper for the hardware bootloader path: HALT, then
        one WRITE_MEM per word starting at base_addr (word-addressed, so
        successive words land 4 bytes apart), then leaves the core halted
        -- caller decides when to resume()."""
        self.halt()
        for i, word in enumerate(words):
            self.write_mem(base_addr + 4 * i, word)


def parse_mif(path):
    """Parses a Quartus .mif (Memory Initialization File) -- the same
    format produced by src/bootloader/bin2mif.py -- into a list of 32-bit
    words ordered by address. Only the CONTENT BEGIN...END block's
    "<addr> : <data>;" lines are used; DEPTH/WIDTH/RADIX header lines are
    read for radix info but otherwise ignored."""
    with open(path) as f:
        text = f.read()

    addr_radix = "HEX"
    data_radix = "HEX"
    m = re.search(r"ADDRESS_RADIX\s*=\s*(\w+)", text, re.IGNORECASE)
    if m:
        addr_radix = m.group(1).upper()
    m = re.search(r"DATA_RADIX\s*=\s*(\w+)", text, re.IGNORECASE)
    if m:
        data_radix = m.group(1).upper()

    def base(radix):
        return {"HEX": 16, "DEC": 10, "BIN": 2, "OCT": 8}.get(radix, 16)

    words_by_addr = {}
    body = text.split("CONTENT BEGIN", 1)[-1] if "CONTENT BEGIN" in text else text
    body = body.split("END;", 1)[0]
    for line in body.splitlines():
        line = line.strip().rstrip(";")
        if not line or ":" not in line:
            continue
        addr_str, data_str = line.split(":", 1)
        addr = int(addr_str.strip(), base(addr_radix))
        data = int(data_str.strip(), base(data_radix))
        words_by_addr[addr] = data

    if not words_by_addr:
        return []
    return [words_by_addr.get(i, 0) for i in range(max(words_by_addr) + 1)]


def load_words_from_file(path, trim_trailing_zeros=True):
    """Reads a program image and returns a list of 32-bit words,
    auto-detecting format from the extension: .mif (Quartus Memory
    Initialization File) or raw binary (.bin or anything else, treated as
    little-endian words, zero-padded to a word boundary).

    .mif files declare a fixed DEPTH (e.g. 4096) and are zero-filled out
    to it, which would otherwise mean transmitting thousands of pointless
    WRITE_MEMs over a 115200-baud link for a handful-of-instructions
    program. trim_trailing_zeros (default True) drops trailing all-zero
    words so only the actual program image gets sent; pass False to load
    the file byte-for-byte instead (e.g. to deliberately zero out a
    memory region)."""
    if path.lower().endswith(".mif"):
        words = parse_mif(path)
    else:
        with open(path, "rb") as f:
            raw = f.read()
        if len(raw) % 4 != 0:
            raw += b"\x00" * (4 - len(raw) % 4)
        words = list(struct.unpack(f"<{len(raw)//4}I", raw)) if raw else []

    if trim_trailing_zeros:
        while words and words[-1] == 0:
            words.pop()
    return words


def print_dump(regs, pc):
    for i, val in enumerate(regs):
        print(f"x{i:<2}: 0x{val:08x}  ({val})")
    print(f"pc : 0x{pc:08x}")


def main():
    parser = argparse.ArgumentParser(description="RISC-V hardware register debugger")
    parser.add_argument("--port", "-p", required=False, default=None, help="Debug UART serial port (not needed with --dry-run)")
    parser.add_argument("--baud", "-b", type=int, default=BAUD_RATE)
    parser.add_argument("--timeout", "-t", type=int, default=TIMEOUT)
    parser.add_argument("--dry-run", "-d", action="store_true",
                         help="Don't open a real serial port; print sent/received bytes as hex instead (no pyserial or hardware needed)")

    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("halt")
    sub.add_parser("resume")
    step_p = sub.add_parser("step")
    step_p.add_argument("n", type=int, nargs="?", default=1, help="number of cycles to step")
    reg_p = sub.add_parser("read-reg")
    reg_p.add_argument("idx", type=int, help="register index 0-31")
    sub.add_parser("read-pc")
    sub.add_parser("dump", help="halt-free full register + PC dump (READ_ALL)")
    wmem_p = sub.add_parser("write-mem", help="write one 32-bit word to memory (core must be halted)")
    wmem_p.add_argument("addr", type=lambda s: int(s, 0), help="byte address (e.g. 0x1000)")
    wmem_p.add_argument("data", type=lambda s: int(s, 0), help="32-bit word value")
    rmem_p = sub.add_parser("read-mem", help="read one 32-bit word from memory (core must be halted)")
    rmem_p.add_argument("addr", type=lambda s: int(s, 0), help="byte address (e.g. 0x1000)")
    load_p = sub.add_parser("load", help="halt, load a .bin or .mif program via WRITE_MEM word-by-word, leave halted")
    load_p.add_argument("file", help="path to a raw binary (.bin) or Quartus .mif image")
    load_p.add_argument("--base", type=lambda s: int(s, 0), default=0, help="base byte address (default 0)")
    load_p.add_argument("--resume", action="store_true", help="resume the core after loading")
    load_p.add_argument("--no-trim", action="store_true",
                         help="send every word including trailing zero padding (default trims trailing zero words, useful for .mif's fixed DEPTH)")

    args = parser.parse_args()

    if args.port is None and not args.dry_run:
        parser.error("--port/-p is required unless --dry-run/-d is set")

    dbg = RegDebugger(args.port or "DRY-RUN", args.baud, args.timeout, dry_run=args.dry_run)
    try:
        if args.cmd == "halt":
            dbg.halt()
            print("[INFO] Core halted")
        elif args.cmd == "resume":
            dbg.resume()
            print("[INFO] Core resumed")
        elif args.cmd == "step":
            dbg.step(args.n)
            print(f"[INFO] Stepped {args.n} cycle(s)")
        elif args.cmd == "read-reg":
            val = dbg.read_reg(args.idx)
            print(f"x{args.idx}: 0x{val:08x} ({val})")
        elif args.cmd == "read-pc":
            pc = dbg.read_pc()
            print(f"pc: 0x{pc:08x}")
        elif args.cmd == "dump":
            regs, pc = dbg.read_all()
            print_dump(regs, pc)
        elif args.cmd == "write-mem":
            dbg.write_mem(args.addr, args.data)
            print(f"[INFO] Wrote 0x{args.data:08x} to 0x{args.addr:08x} (no-op unless core is halted)")
        elif args.cmd == "read-mem":
            val = dbg.read_mem(args.addr)
            print(f"0x{args.addr:08x}: 0x{val:08x} ({val})")
        elif args.cmd == "load":
            words = load_words_from_file(args.file, trim_trailing_zeros=not args.no_trim)
            dbg.load_program(words, base_addr=args.base)
            print(f"[INFO] Loaded {len(words)} word(s) from {args.file} at 0x{args.base:08x} (core left halted)")
            if args.resume:
                dbg.resume()
                print("[INFO] Core resumed")
    except IOError as e:
        print(f"[ERROR] {e}")
        sys.exit(1)
    finally:
        dbg.close()


if __name__ == "__main__":
    main()
