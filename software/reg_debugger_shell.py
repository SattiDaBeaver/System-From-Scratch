# software/reg_debugger_shell.py
#
# Interactive REPL wrapper around RegDebugger (reg_debugger.py) for poking
# at the hardware register debugger (debug_uart.sv) by hand over a serial
# port, without re-typing --port/--baud on every invocation like the
# one-shot reg_debugger.py CLI requires.

import cmd
import sys
import argparse

from reg_debugger import RegDebugger, print_dump, BAUD_RATE, TIMEOUT


class RegDebuggerShell(cmd.Cmd):
    intro = (
        "RISC-V hardware register debugger shell.\n"
        "Talks to debug_uart.sv over its own dedicated serial link (separate\n"
        "from the program UART) to halt/step/resume the CPU and read back its\n"
        "register file + PC -- without touching dmem/imem, so it can never\n"
        "corrupt the running program.\n"
        "Type 'help' for the command list, or 'help <command>' for details.\n"
    )
    prompt = "(dbg) "

    def __init__(self, port, baud=BAUD_RATE, timeout=TIMEOUT, dry_run=False):
        super().__init__()
        self.dbg = RegDebugger(port, baud, timeout, dry_run=dry_run)

    def _guard(self, fn, *args):
        try:
            fn(*args)
        except (IOError, ValueError) as e:
            print(f"[ERROR] {e}")

    def do_halt(self, arg):
        """halt
        Send CMD_HALT (0x01). Freezes the core's PC and regfile writes;
        clk keeps toggling but nothing updates until 'resume' or 'step'.
        No reply is sent back over the wire."""
        self._guard(lambda: (self.dbg.halt(), print("[INFO] Core halted")))

    def do_resume(self, arg):
        """resume
        Send CMD_RESUME (0x02). Un-freezes the core so it runs freely
        again from wherever its PC currently is. No reply is sent back."""
        self._guard(lambda: (self.dbg.resume(), print("[INFO] Core resumed")))

    def do_step(self, arg):
        """step [n]
        Send CMD_STEP (0x03) n times (default 1), one core clock cycle
        apart. Only advances exactly one instruction per step when the
        core is halted and running on the main clk (not a slow_clk
        divider) -- see debug_uart.sv's header comment. No reply."""
        n = int(arg) if arg.strip() else 1

        def run():
            self.dbg.step(n)
            print(f"[INFO] Stepped {n} cycle(s)")
        self._guard(run)

    def do_reg(self, arg):
        """reg <idx>
        Send CMD_READ_REG (0x04) followed by the register index (0-31)
        and read back regfile[idx] as 4 little-endian bytes. x0 always
        reads as 0."""
        if not arg.strip():
            print("[ERROR] usage: reg <idx>")
            return

        def run():
            idx = int(arg)
            val = self.dbg.read_reg(idx)
            print(f"x{idx}: 0x{val:08x} ({val})")
        self._guard(run)

    def do_pc(self, arg):
        """pc
        Send CMD_READ_PC (0x05) and read back the program counter as
        4 little-endian bytes."""
        def run():
            pc = self.dbg.read_pc()
            print(f"pc: 0x{pc:08x}")
        self._guard(run)

    def do_dump(self, arg):
        """dump
        Send CMD_READ_ALL (0x06) and read back all 33 words in one shot:
        regfile[0..31] followed by pc, each 4 little-endian bytes."""
        def run():
            regs, pc = self.dbg.read_all()
            print_dump(regs, pc)
        self._guard(run)

    def do_quit(self, arg):
        """quit
        Close the serial port and exit the shell. Does not resume the
        core if it's currently halted -- send 'resume' first if you want
        it running when you disconnect."""
        return True

    do_exit = do_quit
    do_EOF = do_quit

    def do_help(self, arg):
        if arg:
            super().do_help(arg)
            return
        print("Commands (type 'help <command>' for the wire-level details):")
        print("  halt         freeze the core's PC and regfile updates")
        print("  resume       un-freeze the core, let it run freely again")
        print("  step [n]     single-step n clock cycles (default 1)")
        print("  reg <idx>    read regfile[idx], idx 0-31")
        print("  pc           read the program counter")
        print("  dump         read all 32 registers + PC in one shot")
        print("  quit         close the serial port and exit")

    def postloop(self):
        self.dbg.close()


def main():
    parser = argparse.ArgumentParser(description="Interactive RISC-V hardware register debugger shell")
    parser.add_argument("--port", "-p", required=False, default=None, help="Debug UART serial port (not needed with --dry-run)")
    parser.add_argument("--baud", "-b", type=int, default=BAUD_RATE)
    parser.add_argument("--timeout", "-t", type=int, default=TIMEOUT)
    parser.add_argument("--dry-run", "-d", action="store_true",
                         help="Don't open a real serial port; print sent/received bytes as hex instead (no pyserial or hardware needed)")
    args = parser.parse_args()

    if args.port is None and not args.dry_run:
        parser.error("--port/-p is required unless --dry-run/-d is set")

    try:
        shell = RegDebuggerShell(args.port or "DRY-RUN", args.baud, args.timeout, dry_run=args.dry_run)
    except IOError as e:
        print(f"[ERROR] {e}")
        sys.exit(1)

    shell.cmdloop()


if __name__ == "__main__":
    main()
