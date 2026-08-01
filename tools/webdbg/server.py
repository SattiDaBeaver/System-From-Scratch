#!/usr/bin/env python3
# tools/webdbg/server.py
#
# Local web dashboard for the FPGA hardware register debugger
# (src/peripherals/debug_uart.sv). Browsers can't open a serial port, so
# this is a 3-tier setup: browser <-WebSocket-> this Flask process
# <-pyserial-> FPGA debug UART. This file is purely a translation layer --
# all protocol knowledge lives in tools/reg_debugger.py's RegDebugger,
# reused here unmodified.
#
# Usage (inside the repo's .venv -- see tools/webdbg/README.md):
#   pip install -r tools/webdbg/requirements.txt
#   python tools/webdbg/server.py --port /dev/ttyUSB1   # connect at startup
#   python tools/webdbg/server.py --dry-run             # connect at startup, no hardware needed
#   python tools/webdbg/server.py                       # start disconnected, pick a port from the dashboard
#
# Binds 127.0.0.1 by default -- this is meant as a local tool. Pass
# --host 0.0.0.0 to reach it from other machines on your network (e.g. a
# work laptop), same as any other locally-run dashboard -- there's no
# auth on top of this, so only do that on a network you trust.

import argparse
import base64
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time

from flask import Flask, send_from_directory
from flask_sock import Sock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from reg_debugger import RegDebugger, BAUD_RATE, TIMEOUT, parse_mif

app = Flask(__name__, static_folder=None)
sock = Sock(app)

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
POLL_HZ = 10
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LINK_DBG_LD = os.path.join(REPO_ROOT, "src", "libc_port", "link_dbg.ld")
AS_TOOL = "riscv64-unknown-elf-as"
LD_TOOL = "riscv64-unknown-elf-ld"
OBJCOPY_TOOL = "riscv64-unknown-elf-objcopy"
OBJDUMP_TOOL = "riscv64-unknown-elf-objdump"

@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "index.html")


@sock.route('/ws')
def ws_handler(ws):
    with clients_lock:
        clients.add(ws)
    with dbg_lock:
        connected = dbg is not None
    ws.send(json.dumps({"type": "conn_status", "connected": connected}))
    try:
        while True:
            raw = ws.receive()
            if raw is None:
                break
            _handle_message(ws, raw)
    finally:
        with clients_lock:
            clients.discard(ws)


@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(STATIC_DIR, filename)

# Set up on connect/disconnect (via CLI args at startup, or the `connect`/
# `disconnect` WS commands) -- module-level so the poll thread and every WS
# route can reach it without threading it through Flask's app context.
# None means "not connected to any port yet" -- the dashboard starts up
# without a hard-coded port and lets the browser pick one.
dbg = None
dbg_lock = threading.Lock()
# Cleared whenever the core is halted, set on resume -- the poll loop only
# needs to run fast while there's something changing to observe; polling
# a halted core at 10Hz is harmless but pointless.
core_running = threading.Event()
# WebSocket connections the poll loop broadcasts to. flask-sock hands each
# route invocation a fresh `ws` per client; the poll thread doesn't get one
# for free, so connected clients register themselves here.
clients = set()
clients_lock = threading.Lock()
# Defaults baked in at startup from CLI args, reused when the browser asks
# to connect without specifying baud/timeout explicitly.
default_baud = BAUD_RATE
default_timeout = TIMEOUT


def _list_serial_ports():
    """Best-effort port scan for the browser's port picker. Falls back to
    an empty list if pyserial's tools submodule isn't available for some
    reason -- the manual text field still works either way."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return []
    return [{"device": p.device, "description": p.description} for p in list_ports.comports()]


def _connect(port, baud, timeout, dry_run):
    global dbg
    new_dbg = RegDebugger(port, baud, timeout, dry_run=dry_run)
    with dbg_lock:
        old_dbg = dbg
        dbg = new_dbg
    if old_dbg is not None:
        try:
            old_dbg.close()
        except Exception:
            pass
    core_running.clear()


def _disconnect():
    global dbg
    with dbg_lock:
        old_dbg = dbg
        dbg = None
    core_running.clear()
    if old_dbg is not None:
        try:
            old_dbg.close()
        except Exception:
            pass


def _words_to_bin_bytes(words):
    return struct.pack(f"<{len(words)}I", *words) if words else b""


def _bytes_to_words(raw, trim_trailing_zeros=True):
    """Mirrors reg_debugger.load_words_from_file's raw-binary branch and
    trailing-zero trim, but operating on in-memory bytes (from the
    browser's file upload) instead of a path on disk -- reg_debugger.py
    is left unmodified per the plan, so this is a small, deliberate
    duplication of its trim logic rather than a refactor of that file."""
    if len(raw) % 4 != 0:
        raw += b"\x00" * (4 - len(raw) % 4)
    words = list(struct.unpack(f"<{len(raw)//4}I", raw)) if raw else []
    if trim_trailing_zeros:
        while words and words[-1] == 0:
            words.pop()
    return words


def _mif_bytes_to_words(raw, trim_trailing_zeros=True):
    """parse_mif() takes a path, not bytes -- .mif uploads are rare enough
    (the browser flash flow is mainly for .bin) that round-tripping
    through a temp file here is simpler than duplicating parse_mif's text
    parsing logic."""
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".mif", mode="wb", delete=False) as f:
        f.write(raw)
        tmp_path = f.name
    try:
        words = parse_mif(tmp_path)
    finally:
        os.unlink(tmp_path)
    if trim_trailing_zeros:
        while words and words[-1] == 0:
            words.pop()
    return words


class BuildError(Exception):
    """Raised for expected user-input failures (assembler/linker errors,
    missing toolchain) -- caught in _handle_message and turned into a
    build_error reply instead of propagating as a traceback."""
    def __init__(self, stage, message):
        super().__init__(message)
        self.stage = stage
        self.message = message


def _assemble_build(source):
    """Run source (RV32 assembly text) through as/ld/objcopy/objdump in a
    temp dir, per the debug-UART upload path (link_dbg.ld, no bootloader,
    no crt0/libc -- same raw-assembly convention test/asm_programs/*.asm
    already uses). Returns (words, disasm_text). Raises BuildError on any
    toolchain-missing or assembler/linker failure."""
    for tool in (AS_TOOL, LD_TOOL, OBJCOPY_TOOL, OBJDUMP_TOOL):
        if shutil.which(tool) is None:
            raise BuildError("toolchain", f"{tool} not found on PATH -- source test/env.sh "
                              "before starting server.py, or add the riscv toolchain dir to PATH")

    tmpdir = tempfile.mkdtemp(prefix="webdbg_build_")
    try:
        src_path = os.path.join(tmpdir, "prog.s")
        obj_path = os.path.join(tmpdir, "prog.o")
        elf_path = os.path.join(tmpdir, "prog.elf")
        bin_path = os.path.join(tmpdir, "prog.bin")

        with open(src_path, "w") as f:
            f.write(source)

        r = subprocess.run([AS_TOOL, "-march=rv32im", "-mabi=ilp32", src_path, "-o", obj_path],
                            capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise BuildError("as", r.stderr)

        r = subprocess.run([LD_TOOL, "-m", "elf32lriscv", "-T", LINK_DBG_LD, "-o", elf_path, obj_path],
                            capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise BuildError("ld", r.stderr)

        r = subprocess.run([OBJCOPY_TOOL, "-O", "binary", elf_path, bin_path],
                            capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise BuildError("objcopy", r.stderr)

        r = subprocess.run([OBJDUMP_TOOL, "-d", elf_path], capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise BuildError("objdump", r.stderr)
        disasm = r.stdout

        with open(bin_path, "rb") as f:
            raw = f.read()
        words = _bytes_to_words(raw)
        return words, disasm
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def poll_loop():
    """Background thread: while any client is connected AND a port is
    open, read_all() at POLL_HZ and broadcast {regs, pc} as JSON. This is
    polling dressed up as "live" -- debug_uart.sv has no unsolicited-push
    capability, so there is no way to do real hardware-driven streaming
    over this wire protocol. Polling fast while resumed is the honest
    version of that."""
    while True:
        time.sleep(1.0 / POLL_HZ)
        with clients_lock:
            if not clients:
                continue
        with dbg_lock:
            active = dbg
        if active is None:
            continue
        try:
            with dbg_lock:
                regs, pc = active.read_all()
        except IOError as e:
            _broadcast({"type": "error", "message": str(e)})
            continue
        _broadcast({"type": "state", "regs": regs, "pc": pc})


def _broadcast(msg):
    data = json.dumps(msg)
    dead = []
    with clients_lock:
        for ws in clients:
            try:
                ws.send(data)
            except Exception:
                dead.append(ws)
        for ws in dead:
            clients.discard(ws)

def _handle_message(ws, raw):
    try:
        msg = json.loads(raw)
        cmd = msg.get("cmd")
    except (json.JSONDecodeError, AttributeError):
        ws.send(json.dumps({"type": "error", "message": "malformed message"}))
        return

    print(f"[WS] cmd={cmd!r} msg={msg}", flush=True)

    if cmd == "list_ports":
        ports = _list_serial_ports()
        print(f"[WS] ports={ports}", flush=True)
        ws.send(json.dumps({"type": "ports", "ports": ports}))
        return

    if cmd == "connect":
        try:
            port = msg.get("port") or "DRY-RUN"
            dry_run = bool(msg.get("dry_run", False))
            baud = int(msg.get("baud", default_baud))
            timeout = int(msg.get("timeout", default_timeout))
            _connect(port, baud, timeout, dry_run)
            ws.send(json.dumps({"type": "ack", "cmd": "connect", "port": port, "dry_run": dry_run}))
            _broadcast({"type": "conn_status", "connected": True})
        except (IOError, ValueError) as e:
            ws.send(json.dumps({"type": "error", "message": str(e)}))
        return

    if cmd == "disconnect":
        _disconnect()
        ws.send(json.dumps({"type": "ack", "cmd": "disconnect"}))
        _broadcast({"type": "conn_status", "connected": False})
        return

    if cmd == "build":
        # Assemble-only works disconnected (no hardware needed); flashing
        # needs a connected port, checked below rather than up front.
        try:
            flash = bool(msg.get("flash", False))
            words, disasm = _assemble_build(msg["source"])
        except BuildError as e:
            ws.send(json.dumps({"type": "build_error", "stage": e.stage, "message": e.message}))
            return

        flashed = False
        resumed = False
        if flash:
            with dbg_lock:
                active = dbg
            if active is None:
                ws.send(json.dumps({"type": "error", "message": "not connected to a port -- use the connection panel"}))
                return
            base_addr = int(msg.get("base_addr", 0))
            do_resume = bool(msg.get("resume", False))
            try:
                with dbg_lock:
                    active.load_program(words, base_addr=base_addr)
                    if do_resume:
                        active.resume()
                        core_running.set()
            except (IOError, ValueError) as e:
                ws.send(json.dumps({"type": "error", "message": str(e)}))
                return
            flashed = True
            resumed = do_resume

        ws.send(json.dumps({
            "type": "build_result", "words_loaded": len(words),
            "disasm": disasm, "flashed": flashed, "resumed": resumed,
        }))
        return

    with dbg_lock:
        active = dbg
    if active is None:
        ws.send(json.dumps({"type": "error", "message": "not connected to a port -- use the connection panel"}))
        return

    try:
        if cmd == "halt":
            with dbg_lock:
                active.halt()
            core_running.clear()
            ws.send(json.dumps({"type": "ack", "cmd": "halt"}))

        elif cmd == "resume":
            with dbg_lock:
                active.resume()
            core_running.set()
            ws.send(json.dumps({"type": "ack", "cmd": "resume"}))

        elif cmd == "step":
            n = int(msg.get("n", 1))
            with dbg_lock:
                active.step(n)
            ws.send(json.dumps({"type": "ack", "cmd": "step", "n": n}))

        elif cmd == "read_mem":
            addr = int(msg["addr"])
            n = int(msg.get("n", 1))
            with dbg_lock:
                words = active.read_mem_range(addr, n)
            ws.send(json.dumps({"type": "mem", "addr": addr, "words": words}))

        elif cmd == "read_csr":
            addr = int(msg["addr"])
            with dbg_lock:
                value = active.read_csr(addr)
            ws.send(json.dumps({"type": "csr", "addr": addr, "value": value}))

        elif cmd == "read_mmio":
            addr = int(msg["addr"])
            with dbg_lock:
                value = active.read_mmio(addr)
            ws.send(json.dumps({"type": "mmio", "addr": addr, "value": value}))

        elif cmd == "write_mem":
            addr = int(msg["addr"])
            data = int(msg["data"])
            with dbg_lock:
                active.write_mem(addr, data)
            ws.send(json.dumps({"type": "ack", "cmd": "write_mem", "addr": addr}))

        elif cmd == "flash":
            # bytes_b64: base64-encoded file contents read client-side via
            # the browser File API. filename only used to pick .mif vs raw
            # binary parsing, same auto-detect load_words_from_file uses.
            raw_bytes = base64.b64decode(msg["bytes_b64"])
            filename = msg.get("filename", "")
            base_addr = int(msg.get("base_addr", 0))
            do_resume = bool(msg.get("resume", False))
            if filename.lower().endswith(".mif"):
                words = _mif_bytes_to_words(raw_bytes)
            else:
                words = _bytes_to_words(raw_bytes)
            with dbg_lock:
                active.load_program(words, base_addr=base_addr)
                if do_resume:
                    active.resume()
                    core_running.set()
            ws.send(json.dumps({
                "type": "ack", "cmd": "flash",
                "words_loaded": len(words), "base_addr": base_addr,
                "resumed": do_resume,
            }))

        else:
            ws.send(json.dumps({"type": "error", "message": f"unknown cmd {cmd!r}"}))

    except (IOError, ValueError, KeyError) as e:
        ws.send(json.dumps({"type": "error", "message": str(e)}))


def main():
    global default_baud, default_timeout

    parser = argparse.ArgumentParser(description="Web dashboard for the FPGA hardware register debugger")
    parser.add_argument("--port", "-p", default=None,
                         help="Debug UART serial port to connect to at startup (optional -- if omitted, "
                              "connect from the dashboard's connection panel instead)")
    parser.add_argument("--baud", "-b", type=int, default=BAUD_RATE)
    parser.add_argument("--timeout", "-t", type=int, default=TIMEOUT)
    parser.add_argument("--dry-run", "-d", action="store_true",
                         help="If starting connected (--port given, or no --port at all), don't open a "
                              "real serial port; log sent/received bytes instead")
    parser.add_argument("--http-port", type=int, default=5000, help="local port to serve the dashboard on")
    parser.add_argument("--host", default="127.0.0.1",
                         help="interface to bind the dashboard to (default 127.0.0.1, local-only; "
                              "use 0.0.0.0 to reach it from other machines on your network -- this "
                              "exposes halt/resume/write-mem/flash to anyone who can reach this host)")
    args = parser.parse_args()

    default_baud = args.baud
    default_timeout = args.timeout

    if args.port is not None or args.dry_run:
        _connect(args.port or "DRY-RUN", args.baud, args.timeout, dry_run=args.dry_run)

    poll_thread = threading.Thread(target=poll_loop, daemon=True)
    poll_thread.start()

    print(f"[INFO] web debugger dashboard: http://{args.host}:{args.http_port}")
    app.run(host=args.host, port=args.http_port)


if __name__ == "__main__":
    main()
