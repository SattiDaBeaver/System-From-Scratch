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

import struct
import sys
import argparse

BAUD_RATE = 115200
TIMEOUT   = 5  # seconds

CMD_HALT     = 0x01
CMD_RESUME   = 0x02
CMD_STEP     = 0x03
CMD_READ_REG = 0x04
CMD_READ_PC  = 0x05
CMD_READ_ALL = 0x06


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
    except IOError as e:
        print(f"[ERROR] {e}")
        sys.exit(1)
    finally:
        dbg.close()


if __name__ == "__main__":
    main()
