# tools/crit_path_estimate.py
#
# Fast, iterative critical-path *estimator* for MAX10 RTL development.
#
# This is NOT a replacement for Quartus's Fitter + TimeQuest timing
# analyzer -- there is no open place-and-route for Intel/Altera devices
# (nextpnr doesn't support them), so Yosys can only get you to a
# post-synthesis, pre-placement netlist. What this tool reports is the
# longest topological path (in cell hops) through that netlist, under
# Yosys's `ltp` pass -- a proxy for "how much combinational logic is
# stacked between registers", not a routed number in nanoseconds. Two
# designs with the same logic-level depth can still close timing very
# differently in real silicon once routing delay is added. Use this to
# catch obviously-bad, newly-introduced long combinational chains between
# RTL edits; use Quartus/TimeQuest before flashing anything to hardware.
#
# Internally this shells out to the `yowasp-yosys` console script (a
# WASM build of Yosys, no system install needed -- see CLAUDE.md) running
# roughly:
#
#   read_verilog -sv <files...>
#   synth_intel -family max10 -top <top> -run begin:map_ffs
#   stat
#   ltp -noff
#
# `-run begin:map_ffs` stops synth_intel right before ABC's LUT-mapping
# pass (`abc -lut 4`, the map_luts label). That last stage is where nearly
# all the runtime goes -- ABC running under wasmtime took 10+ minutes on
# riscv_core.sv and still hadn't finished when this tool was built, vs.
# ~15 seconds through map_ffs -- and it collapses many primitive cells
# into fewer, wider LUTs, which *shortens* the hop count without changing
# what RTL edit caused a given path to lengthen. The pre-LUT-map topology
# (primitive $_AND_/$_OR_/$_MUX_/$_XOR_/full-adder cells) is what
# synth_intel produces from a technology-independent `synth -run coarse`
# pass, and its relative depth from one RTL edit to the next is what this
# tool is actually useful for. Pass --full to run the complete
# synth_intel + `abc -lut 4` flow anyway (accurate LUT count, real depth
# in mapped 4-LUTs, but slow -- budget several minutes).
#
# `ltp -noff` (see `yowasp-yosys -p "help ltp"`) excludes FF cell types so
# the reported path is purely combinational logic between two registers
# (or a register and a top-level port), which is what actually has to fit
# in one clock period.

import argparse
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Default file list for the pipelined core (the active development target
# per CLAUDE.md) -- riscv_core.sv is currently self-contained (no
# submodules to pull in), but this is a list, not a single path, so that
# changes later (or a run against riscv_top.sv) don't require reshaping
# this script.
DEFAULT_FILES = [REPO_ROOT / "src" / "riscv_core" / "riscv_core.sv"]
DEFAULT_TOP = "riscv_core"

LOG_FILE = REPO_ROOT / "log" / "crit_path_estimate.log"

LTP_HEADER_RE = re.compile(
    r"^Longest topological path in \S+ \(length=(\d+)\):"
)
STAT_CELLS_RE = re.compile(r"^\s*Number of cells:\s*(\d+)")


def _display_path(f):
    """Relative to repo root when possible -- keeps yosys's ltp trace
    (which echoes back read_verilog's paths verbatim) readable instead of
    a full /prj/.../System-From-Scratch/... prefix on every hop."""
    try:
        return str(f.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(f)


def build_yosys_script(files, top, full):
    read_cmd = "read_verilog -sv " + " ".join(_display_path(f) for f in files)
    run_range = "" if full else " -run begin:map_ffs"
    synth_cmd = f"synth_intel -family max10 -top {top}{run_range}"
    return f"{read_cmd}; {synth_cmd}; stat; ltp -noff"


def run_yosys(script, timeout):
    cmd = ["yowasp-yosys", "-p", script]
    try:
        # cwd=REPO_ROOT so the relative paths build_yosys_script() puts in
        # the read_verilog command (used purely to keep ltp's trace output
        # readable) actually resolve.
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO_ROOT
        )
    except FileNotFoundError:
        print(
            "[ERROR] 'yowasp-yosys' not found on PATH. Install it into the "
            "repo's .venv (source .venv/bin/activate; pip install "
            "yowasp-yosys wasmtime) -- see CLAUDE.md, no system-wide "
            "installs on this host.",
            file=sys.stderr,
        )
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print(
            f"[ERROR] yosys did not finish within {timeout}s. If you passed "
            "--full, the ABC LUT-mapping pass is slow under the WASM "
            "runtime (10+ minutes on riscv_core.sv) -- try again without "
            "--full, or raise --timeout.",
            file=sys.stderr,
        )
        sys.exit(1)
    return result


def parse_output(stdout):
    """Pull the cell count and longest-path length/trace out of yosys's
    stdout. Returns (num_cells, path_length, path_lines)."""
    lines = stdout.splitlines()
    num_cells = None
    path_length = None
    path_lines = []

    for i, line in enumerate(lines):
        m = STAT_CELLS_RE.match(line)
        if m:
            num_cells = int(m.group(1))
        m = LTP_HEADER_RE.match(line)
        if m:
            path_length = int(m.group(1))
            # ltp prints one "    N: <cell/wire name>" line per hop right
            # after the header, until a blank line or the next section.
            for j in range(i + 1, len(lines)):
                if not lines[j].strip():
                    break
                path_lines.append(lines[j])

    return num_cells, path_length, path_lines


# Matches an RTL source location Yosys embeds in a cell/wire's auto-generated
# name whenever that cell came from a specific line of the original
# SystemVerilog (ternary muxes, $add/$mul cells, etc.) -- e.g.
# "$ternary$src/riscv_core/riscv_core.sv:667$181_Y". Cells produced by a
# *techmap* pass instead (full-adder/carry-lookahead expansion of a `*` or
# `+`, one $auto$maccmap.cc:.../$auto$alumacc.cc:... cell per bit) carry no
# source location of their own -- see _classify_hop below for how those get
# attributed instead.
SRC_LOC_RE = re.compile(r"([./\w-]+\.sv):(\d+)")

# Coarse "what kind of hardware is this hop" bucket, derived from the cell
# name Yosys prints (not the source location, which techmap-expanded cells
# lack). Order matters: checked top-to-bottom, first match wins.
HOP_CATEGORY_RULES = [
    (re.compile(r"maccmap|alumacc"), "multiply/add carry-chain (from a `*` or `+` operator)"),
    (re.compile(r"\bfulladd\b"), "multiply/add carry-chain (from a `*` or `+` operator)"),
    (re.compile(r"\blcu\b"), "multiply/add carry-chain (from a `*` or `+` operator)"),
    (re.compile(r"\$ternary\$"), "ternary (?:) mux chain"),
    (re.compile(r"\$mux\$|simplemap_mux"), "mux chain"),
    (re.compile(r"\$eq\$|\$ne\$|\$lt\$|\$le\$|\$gt\$|\$ge\$"), "comparator"),
    (re.compile(r"\$logic_and\$|\$logic_or\$|\$and\$|\$or\$|\$not\$|\$xor\$"), "boolean logic"),
    (re.compile(r"\$shl\$|\$shr\$|\$sshr\$|\$shift"), "shifter"),
]


def _classify_hop(line):
    """Return (category, src_file, src_line) for one ltp trace line. src_file/
    src_line are None when the cell carries no source annotation (typical for
    techmap-expanded carry-chain cells -- attribute those to the category
    alone, not a bogus line number)."""
    m = SRC_LOC_RE.search(line)
    src_file, src_line = (m.group(1), int(m.group(2))) if m else (None, None)

    for pattern, category in HOP_CATEGORY_RULES:
        if pattern.search(line):
            return category, src_file, src_line

    # No rule matched and no $-prefixed cell -- likely a plain named
    # reg/wire boundary (path start/end), not a "logic section" at all.
    return None, src_file, src_line


def summarize_path_sections(path_lines):
    """Collapse a raw ltp hop-by-hop trace into contiguous same-category
    runs, e.g. "hops 1-43: multiply/add carry-chain" -- this is the piece
    that answers 'which RTL construct is actually the longest path', since
    the raw trace is 70+ lines of auto-generated techmap cell names that
    don't read as RTL on their own. Returns a list of dicts with
    category/start/end/count/src_lines (sorted src :line refs seen in that
    run, since techmap-expanded hops often carry none)."""
    runs = []
    for line in path_lines:
        # ltp's own numbering: "   12: <name>..." -- reuse it as the hop
        # index instead of re-deriving one from enumerate(), so a
        # --full/mapped-LUT trace (which can skip/repeat differently) still
        # reports the hop number ltp itself printed.
        idx_m = re.match(r"\s*(\d+):", line)
        hop_idx = int(idx_m.group(1)) if idx_m else None
        category, src_file, src_line = _classify_hop(line)
        if category is None:
            continue
        if runs and runs[-1]["category"] == category:
            runs[-1]["end"] = hop_idx
            runs[-1]["count"] += 1
            if src_line is not None:
                runs[-1]["src_lines"].add((src_file, src_line))
        else:
            runs.append({
                "category": category,
                "start": hop_idx,
                "end": hop_idx,
                "count": 1,
                "src_lines": {(src_file, src_line)} if src_line is not None else set(),
            })
    return runs


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Fast Yosys-based critical-path *estimator* for MAX10 RTL "
            "(logic-level depth, not a routed Quartus/TimeQuest number -- "
            "see the module docstring in this file for the distinction)."
        )
    )
    parser.add_argument(
        "files",
        nargs="*",
        type=Path,
        default=DEFAULT_FILES,
        help=(
            "SV source file(s) to synthesize (default: "
            f"{DEFAULT_FILES[0].relative_to(REPO_ROOT)})"
        ),
    )
    parser.add_argument(
        "--top",
        default=DEFAULT_TOP,
        help=f"top-level module name (default: {DEFAULT_TOP})",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help=(
            "run the complete synth_intel flow including ABC's LUT-4 "
            "mapping (real mapped-LUT depth, but slow -- minutes, not "
            "seconds, under the WASM runtime). Default stops just before "
            "that pass and reports pre-LUT-map primitive-cell depth "
            "instead, which is fast and still tracks relative RTL changes."
        ),
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=120,
        help="seconds to wait for yosys before giving up (default: 120; "
        "raise this if using --full)",
    )
    parser.add_argument(
        "--log",
        action="store_true",
        help=f"append a one-line summary to {LOG_FILE.relative_to(REPO_ROOT)}",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="print the full yosys stdout instead of just the summary",
    )
    args = parser.parse_args()

    missing = [f for f in args.files if not f.exists()]
    if missing:
        for f in missing:
            print(f"[ERROR] no such file: {f}", file=sys.stderr)
        sys.exit(1)

    script = build_yosys_script(args.files, args.top, args.full)

    print(f"[INFO] top module   : {args.top}")
    print(f"[INFO] source files : {', '.join(str(f) for f in args.files)}")
    print(f"[INFO] mode         : {'full (with LUT-4 mapping)' if args.full else 'fast (pre-LUT-map, default)'}")
    print(f"[INFO] yosys script : {script}")
    print("[INFO] running yowasp-yosys (this can take a while)...")

    result = run_yosys(script, args.timeout)

    if args.verbose:
        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)

    if result.returncode != 0:
        print(f"[ERROR] yosys exited with code {result.returncode}", file=sys.stderr)
        if not args.verbose:
            # Surface the tail of stdout/stderr even without -v, since a
            # failure with no diagnostic output is useless.
            tail = "\n".join(result.stdout.splitlines()[-40:])
            print(tail, file=sys.stderr)
            print(result.stderr, file=sys.stderr)
        sys.exit(1)

    num_cells, path_length, path_lines = parse_output(result.stdout)

    if path_length is None:
        print(
            "[ERROR] couldn't find an 'ltp' result in yosys output -- "
            "re-run with -v to see the full log and diagnose.",
            file=sys.stderr,
        )
        sys.exit(1)

    print()
    print("=" * 70)
    print(f"Critical-path estimate for '{args.top}'")
    print("=" * 70)
    print(f"  Synthesized cells      : {num_cells}")
    print(f"  Longest topological path (combinational hops between regs/ports): {path_length}")
    print()

    sections = summarize_path_sections(path_lines)
    if sections:
        print("  Breakdown by RTL construct (contiguous same-kind hops):")
        for s in sections:
            span = f"hops {s['start']}-{s['end']}" if s['start'] != s['end'] else f"hop {s['start']}"
            src_refs = ", ".join(
                f"{f}:{l}" if f else f"line {l}"
                for f, l in sorted(s["src_lines"], key=lambda t: (t[0] or "", t[1] or 0))
            )
            src_suffix = f" [{src_refs}]" if src_refs else " [no source annotation -- techmap-expanded]"
            print(f"    {span:<12} ({s['count']:>2} hops)  {s['category']}{src_suffix}")
        print()

    print("  Path (reg/port -> ... -> reg/port), one cell per hop:")
    # path_lines already indented like "    0: \\foo [3]" etc. -- print
    # start/end plus a capped middle so this stays readable for a ~70-hop
    # path without dumping the whole thing every run.
    if len(path_lines) > 12:
        for line in path_lines[:5]:
            print(f"  {line.strip()}")
        print(f"    ... ({len(path_lines) - 10} hops omitted, re-run with -v for the full trace) ...")
        for line in path_lines[-5:]:
            print(f"  {line.strip()}")
    else:
        for line in path_lines:
            print(f"  {line.strip()}")
    print("=" * 70)
    print(
        "NOTE: this is Yosys logic-level depth on a "
        f"{'LUT-4-mapped' if args.full else 'pre-LUT-map primitive-cell'} "
        "netlist, not a routed MAX10 timing number. There is no open "
        "place-and-route for Intel/Altera FPGAs, so this cannot reproduce "
        "Quartus/TimeQuest's Fmax. Treat it as a relative signal between "
        "RTL edits, not an absolute ns figure -- run a full Quartus "
        "compile before trusting any real timing closure."
    )

    if args.log:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        mode = "full" if args.full else "fast"
        with open(LOG_FILE, "a") as f:
            f.write(
                f"[{ts}] top={args.top} mode={mode} cells={num_cells} "
                f"ltp_length={path_length}\n"
            )
        print(f"[INFO] appended summary to {LOG_FILE}")


if __name__ == "__main__":
    main()
