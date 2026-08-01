// tools/webdbg/static/app.js
//
// Vanilla JS, no framework/build step -- see tools/webdbg/README.md and
// the plan this was built from for why. Talks to server.py's /ws endpoint,
// which is the only thing that actually touches the FPGA's debug UART.

let ws = null;
let lastRegs = new Array(32).fill(null);

const ABI_NAMES = [
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
  "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
  "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
  "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6",
];

// Mirrors reg_debugger.py's CSR_NAMES/MMIO_NAMES -- kept as a static
// client-side table rather than fetched from the server, since it's a
// fixed, small, documented set (see debug_uart.sv's header comment).
const CSRS = [
  { addr: 0x300, name: "mstatus" },
  { addr: 0x304, name: "mie" },
  { addr: 0x305, name: "mtvec" },
  { addr: 0x340, name: "mscratch" },
  { addr: 0x341, name: "mepc" },
  { addr: 0x342, name: "mcause" },
  { addr: 0x343, name: "mtval" },
  { addr: 0x344, name: "mip" },
];
const MMIO_REGS = [
  { addr: 0x10000000, name: "UART_TX" },
  { addr: 0x10000004, name: "UART_RX" },
  { addr: 0x10000008, name: "UART_STATUS" },
  { addr: 0x30000000, name: "TIMER_RELOAD" },
  { addr: 0x30000004, name: "TIMER_CTRL" },
  { addr: 0x30000008, name: "TIMER_STATUS" },
];

// VGA addresses -- reference-only, NOT wired into the "Read MMIO" button.
// riscv_top.sv's dbg_mmio_data mux (and the debug READ_MEM path) both
// deliberately exclude VGA (see the comment block at riscv_top.sv:166-170)
// -- vga_sel is only ever derived from the live core's dmem_addr, never
// from dbg_mem_addr/dbg_mmio_addr, so there is no debug-UART command that
// can actually read these live. Listed here purely so code targeting VGA
// has the addresses to write against.
const VGA_REFS = [
  { addr: 0x20000000, name: "VGA_CTRL", note: "bit0 DOUBLE_BUF_EN, bit1 SWAP (write 1)" },
  { addr: 0x20000004, name: "VGA_STATUS", note: "bit0 SWAP_PENDING (read-only)" },
  { addr: 0x20001000, name: "VGA_DRAW_BUF", note: "4KB window, 2400B used, active draw buffer" },
  { addr: 0x20002000, name: "VGA_PEEK_BUF", note: "4KB window, 2400B used, debug peek of inactive buffer" },
];

// RV32IM mnemonics (base ISA + M extension) plus the common pseudo-ops
// riscv64-unknown-elf-as accepts (li/la/mv/j/call/nop/...) -- purely for
// the editor's syntax highlighter, not used for validation. The
// assembler is still the source of truth for what's actually legal.
const ASM_MNEMONICS = new Set([
  "add", "addi", "sub", "sll", "slli", "srl", "srli", "sra", "srai",
  "and", "andi", "or", "ori", "xor", "xori", "slt", "slti", "sltu", "sltiu",
  "lui", "auipc", "jal", "jalr", "beq", "bne", "blt", "bge", "bltu", "bgeu",
  "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw",
  "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu",
  "ecall", "ebreak", "fence", "fence.i",
  "csrr", "csrw", "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci",
  "mret", "sret", "uret", "wfi",
  "li", "la", "mv", "not", "neg", "seqz", "snez", "sltz", "sgtz",
  "beqz", "bnez", "blez", "bgez", "bltz", "bgtz",
  "j", "jr", "call", "tail", "ret", "nop",
]);

const ASM_DIRECTIVES = new Set([
  ".text", ".data", ".bss", ".rodata", ".section", ".globl", ".global",
  ".word", ".half", ".byte", ".ascii", ".asciiz", ".string", ".align",
  ".equ", ".set", ".size", ".type", ".skip", ".zero", ".org",
]);

const ASM_REGISTERS = new Set([
  ...Array.from({ length: 32 }, (_, i) => `x${i}`),
  ...ABI_NAMES,
]);

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Line-oriented tokenizer: split off a trailing comment first (RV32 asm
// comments run to end-of-line, never nested), then walk the remainder
// splitting on word boundaries so mnemonics/registers/directives/numbers
// each get their own <span>, leaving punctuation (commas, parens, colons)
// unstyled between them.
function highlightAsmLine(line) {
  const commentIdx = line.indexOf("#");
  const code = commentIdx === -1 ? line : line.slice(0, commentIdx);
  const comment = commentIdx === -1 ? "" : line.slice(commentIdx);

  let out = "";
  const re = /(\.[A-Za-z_][\w.]*)|([A-Za-z_.][\w.]*:)|(-?\b0[xX][0-9a-fA-F]+\b|-?\b\d+\b)|("(?:[^"\\]|\\.)*")|([A-Za-z_][\w.]*)|(\s+)|(.)/g;
  let m;
  while ((m = re.exec(code)) !== null) {
    const [, directive, label, number, str, word, space, other] = m;
    if (directive) {
      out += `<span class="tok-directive">${escapeHtml(directive)}</span>`;
    } else if (label) {
      out += `<span class="tok-label">${escapeHtml(label)}</span>`;
    } else if (number) {
      out += `<span class="tok-number">${escapeHtml(number)}</span>`;
    } else if (str) {
      out += `<span class="tok-string">${escapeHtml(str)}</span>`;
    } else if (word) {
      const lower = word.toLowerCase();
      if (ASM_MNEMONICS.has(lower)) {
        out += `<span class="tok-mnemonic">${escapeHtml(word)}</span>`;
      } else if (ASM_REGISTERS.has(lower)) {
        out += `<span class="tok-register">${escapeHtml(word)}</span>`;
      } else {
        out += escapeHtml(word);
      }
    } else {
      out += escapeHtml(space || other);
    }
  }
  if (comment) out += `<span class="tok-comment">${escapeHtml(comment)}</span>`;
  return out;
}

function refreshAsmHighlight() {
  const src = $("asm-source").value;
  const html = src.split("\n").map(highlightAsmLine).join("\n");
  // Trailing newline needed so the overlay's last empty line still takes
  // up a line of height, matching the textarea (a lone trailing "\n"
  // collapses to nothing in a <pre><code> otherwise).
  $("asm-highlight").querySelector("code").innerHTML = html + "\n";
}

function syncAsmScroll() {
  const src = $("asm-source");
  const hl = $("asm-highlight");
  hl.scrollTop = src.scrollTop;
  hl.scrollLeft = src.scrollLeft;
}

const $ = (id) => document.getElementById(id);

function log(msg) {
  const out = $("log-output");
  const line = document.createElement("div");
  line.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`;
  out.appendChild(line);
  out.scrollTop = out.scrollHeight;
}

function setConnStatus(connected) {
  const el = $("conn-status");
  el.textContent = connected ? "connected" : "disconnected";
  el.className = "status " + (connected ? "connected" : "disconnected");
}

function buildRegGrid() {
  const body = $("reg-table-body");
  body.innerHTML = "";
  for (let i = 0; i < 32; i++) {
    const row = document.createElement("tr");
    row.id = `reg-${i}`;
    row.innerHTML = `
      <td class="reg-name">x${i}</td>
      <td class="reg-abi">${ABI_NAMES[i]}</td>
      <td class="reg-hex">0x00000000</td>
      <td class="reg-uint">0</td>
      <td class="reg-int">0</td>
      <td class="reg-ascii">....</td>`;
    body.appendChild(row);
  }
}

function buildCsrGrid() {
  const body = $("csr-table-body");
  body.innerHTML = "";
  for (const { addr, name } of CSRS) {
    const row = document.createElement("tr");
    row.id = `csr-${addr.toString(16)}`;
    row.innerHTML = `<td class="csr-name">${name}</td><td class="csr-hex">--</td>`;
    body.appendChild(row);
  }
}

function buildMmioGrid() {
  const body = $("mmio-table-body");
  body.innerHTML = "";
  for (const { addr, name } of MMIO_REGS) {
    const row = document.createElement("tr");
    row.id = `mmio-${addr.toString(16)}`;
    row.innerHTML = `<td class="mmio-name">${name}</td><td class="mmio-hex">--</td>`;
    body.appendChild(row);
  }
}

// Static reference table, not live-read -- see the VGA_REFS comment above
// for why (no debug-UART path reaches these).
function buildVgaRefGrid() {
  const body = $("vga-ref-table-body");
  body.innerHTML = "";
  for (const { addr, name, note } of VGA_REFS) {
    const row = document.createElement("tr");
    row.innerHTML = `<td class="mmio-name">${name}</td>` +
      `<td class="mmio-hex">0x${addr.toString(16).padStart(8, "0")}</td>` +
      `<td class="vga-ref-note">${escapeHtml(note)}</td>`;
    body.appendChild(row);
  }
}

function setRunState(running) {
  const el = $("run-state");
  el.textContent = running ? "running" : "halted";
  el.className = "status " + (running ? "running" : "halted");
}

function updateRegs(regs) {
  for (let i = 0; i < 32; i++) {
    const row = $(`reg-${i}`);
    const w = regs[i];
    row.querySelector(".reg-hex").textContent = "0x" + w.toString(16).padStart(8, "0");
    row.querySelector(".reg-uint").textContent = (w >>> 0).toString(10);
    row.querySelector(".reg-int").textContent = (w | 0).toString(10);
    row.querySelector(".reg-ascii").textContent = wordToAscii(w);
    if (lastRegs[i] !== null && lastRegs[i] !== w) {
      row.classList.add("changed");
      // Brief flash: drop the highlight class shortly after, rather than
      // leaving every register that ever changed permanently highlighted.
      setTimeout(() => row.classList.remove("changed"), 400);
    }
  }
  lastRegs = regs.slice();
}

function updatePc(pc) {
  $("pc-display").textContent = "pc: 0x" + pc.toString(16).padStart(8, "0");
}

function connect() {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${proto}//${location.host}/ws`);

  ws.onopen = () => {
    setConnStatus(true);
    log("connected");
    send({ cmd: "list_ports" });
  };

  ws.onclose = () => {
    setConnStatus(false);
    $("run-state").textContent = "unknown";
    $("run-state").className = "status unknown";
    log("disconnected -- retrying in 2s");
    setTimeout(connect, 2000);
  };

  ws.onerror = () => {
    // onclose fires right after in the browser's WebSocket state machine,
    // which already handles the retry -- nothing extra needed here beyond
    // a log line for visibility.
    log("websocket error");
  };

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    switch (msg.type) {
      case "state":
        updateRegs(msg.regs);
        updatePc(msg.pc);
        break;
      case "mem":
        renderMemDump(msg.addr, msg.words);
        break;
      case "csr": {
        const row = $(`csr-${msg.addr.toString(16)}`);
        if (row) row.querySelector(".csr-hex").textContent = "0x" + msg.value.toString(16).padStart(8, "0");
        break;
      }
      case "mmio": {
        const row = $(`mmio-${msg.addr.toString(16)}`);
        if (row) row.querySelector(".mmio-hex").textContent = "0x" + msg.value.toString(16).padStart(8, "0");
        break;
      }
      case "ack":
        log(`ack: ${msg.cmd}` + (msg.words_loaded !== undefined ? ` (${msg.words_loaded} words @ 0x${msg.base_addr.toString(16)})` : ""));
        if (msg.cmd === "halt") setRunState(false);
        if (msg.cmd === "resume") setRunState(true);
        if (msg.cmd === "flash") setRunState(msg.resumed);
        if (msg.cmd === "connect") setPortStatus(`connected: ${msg.dry_run ? "dry-run" : msg.port}`, true);
        if (msg.cmd === "disconnect") setPortStatus("not connected", false);
        break;
      case "ports":
        renderPortList(msg.ports);
        break;
      case "conn_status":
        setPortStatus(msg.connected ? "connected" : "not connected", msg.connected);
        if (!msg.connected) {
          $("run-state").textContent = "unknown";
          $("run-state").className = "status unknown";
        }
        break;
      case "build_result":
        $("asm-disasm").textContent = msg.disasm;
        log(`build ok: ${msg.words_loaded} words` +
            (msg.flashed ? ` -- flashed${msg.resumed ? ", resumed" : ""}` : ""));
        break;
      case "build_error":
        log(`build error (${msg.stage}): ${msg.message}`);
        break;
      case "error":
        log(`error: ${msg.message}`);
        break;
      default:
        log(`unknown message type: ${msg.type}`);
    }
  };
}

function send(obj) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    log("not connected, dropped: " + JSON.stringify(obj));
    return;
  }
  ws.send(JSON.stringify(obj));
}

function wordToAscii(w) {
  // Little-endian byte order, matching how these words land in memory.
  let out = "";
  for (let b = 0; b < 4; b++) {
    const byte = (w >>> (8 * b)) & 0xff;
    out += (byte >= 0x20 && byte < 0x7f) ? String.fromCharCode(byte) : ".";
  }
  return out;
}

function renderMemDump(addr, words) {
  const wordsPerLine = 4;
  const lines = [];
  for (let i = 0; i < words.length; i += wordsPerLine) {
    const lineAddr = addr + 4 * i;
    const chunk = words.slice(i, i + wordsPerLine);
    const hexPart = chunk
      .map((w) => w.toString(16).padStart(8, "0"))
      .join("  ")
      .padEnd(wordsPerLine * 10 - 2, " ");
    const asciiPart = chunk.map(wordToAscii).join("");
    lines.push(`0x${lineAddr.toString(16).padStart(8, "0")}:  ${hexPart}  |${asciiPart}|`);
  }
  $("mem-dump").textContent = lines.join("\n");
}

function parseIntFlexible(s) {
  s = s.trim();
  return s.toLowerCase().startsWith("0x") ? parseInt(s, 16) : parseInt(s, 10);
}

function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      // dataURL is "data:<mime>;base64,<payload>" -- strip the prefix.
      const b64 = reader.result.split(",", 2)[1];
      resolve(b64);
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

function setPortStatus(text, connected) {
  const el = $("port-status");
  el.textContent = text;
  el.style.color = connected ? "var(--status-ok)" : "var(--muted)";
}

function renderPortList(ports) {
  const select = $("port-select");
  select.innerHTML = '<option value="">-- select detected port --</option>';
  for (const p of ports) {
    const opt = document.createElement("option");
    opt.value = p.device;
    opt.textContent = `${p.device} (${p.description})`;
    select.appendChild(opt);
  }
  log(`found ${ports.length} port(s)`);
}

function applyTheme(light) {
  document.body.classList.toggle("light-theme", light);
  $("btn-theme").innerHTML = light ? "&#9790;" : "&#9788;";
  localStorage.setItem("webdbg-light-theme", light ? "1" : "0");
}

function setupUI() {
  buildRegGrid();
  buildCsrGrid();
  buildMmioGrid();
  buildVgaRefGrid();

  $("btn-scan-ports").onclick = () => send({ cmd: "list_ports" });

  $("port-select").onchange = () => {
    if ($("port-select").value) $("port-manual").value = $("port-select").value;
  };

  $("btn-connect").onclick = () => {
    const dryRun = $("dry-run-toggle").checked;
    const port = $("port-manual").value.trim() || $("port-select").value;
    if (!dryRun && !port) {
      setPortStatus("pick a port or enable dry-run", false);
      return;
    }
    const baud = parseInt($("conn-baud").value, 10) || 115200;
    send({ cmd: "connect", port, dry_run: dryRun, baud });
  };

  $("btn-disconnect").onclick = () => send({ cmd: "disconnect" });

  $("btn-theme").onclick = () => applyTheme(!document.body.classList.contains("light-theme"));

  $("btn-halt").onclick = () => send({ cmd: "halt" });
  $("btn-resume").onclick = () => send({ cmd: "resume" });
  $("btn-step").onclick = () => {
    const n = parseInt($("step-count").value, 10) || 1;
    send({ cmd: "step", n });
  };

  $("btn-read-mem").onclick = () => {
    const addr = parseIntFlexible($("mem-addr").value);
    const n = parseInt($("mem-count").value, 10) || 1;
    send({ cmd: "read_mem", addr, n });
  };

  $("btn-write-mem").onclick = () => {
    const addr = parseIntFlexible($("wmem-addr").value);
    const data = parseIntFlexible($("wmem-data").value);
    send({ cmd: "write_mem", addr, data });
  };

  $("btn-read-csrs").onclick = () => {
    for (const { addr } of CSRS) send({ cmd: "read_csr", addr });
  };

  $("btn-read-mmio").onclick = () => {
    for (const { addr } of MMIO_REGS) send({ cmd: "read_mmio", addr });
  };

  $("btn-clear-log").onclick = () => {
    $("log-output").innerHTML = "";
  };

  $("btn-flash").onclick = async () => {
    const fileInput = $("flash-file");
    if (!fileInput.files.length) {
      $("flash-status").textContent = "no file selected";
      return;
    }
    const file = fileInput.files[0];
    const base_addr = parseIntFlexible($("flash-base").value);
    const doResume = $("flash-resume").checked;
    $("flash-status").textContent = `reading ${file.name}...`;
    const bytes_b64 = await fileToBase64(file);
    $("flash-status").textContent = `sending ${file.name}...`;
    send({ cmd: "flash", bytes_b64, filename: file.name, base_addr, resume: doResume });
    $("flash-status").textContent = `sent ${file.name}`;
  };

  $("btn-assemble").onclick = () => {
    send({ cmd: "build", source: $("asm-source").value, flash: false });
  };

  $("btn-assemble-flash").onclick = () => {
    send({
      cmd: "build",
      source: $("asm-source").value,
      flash: true,
      resume: $("ide-resume").checked,
      base_addr: 0,
    });
  };

  const asmSource = $("asm-source");
  refreshAsmHighlight();
  asmSource.addEventListener("input", refreshAsmHighlight);
  asmSource.addEventListener("scroll", syncAsmScroll);
  asmSource.addEventListener("keydown", (ev) => {
    // Plain browser Tab behavior moves focus to the next control -- for a
    // code editor that's a UX bug, not a feature, so intercept it and
    // insert 4 spaces at the caret instead (Shift+Tab still moves focus,
    // since there's no de-indent story here worth building for a single-
    // level assembly editor).
    if (ev.key === "Tab" && !ev.shiftKey) {
      ev.preventDefault();
      const start = asmSource.selectionStart;
      const end = asmSource.selectionEnd;
      const value = asmSource.value;
      asmSource.value = value.slice(0, start) + "    " + value.slice(end);
      asmSource.selectionStart = asmSource.selectionEnd = start + 4;
      refreshAsmHighlight();
    }
  });
}

document.addEventListener("DOMContentLoaded", () => {
  applyTheme(localStorage.getItem("webdbg-light-theme") === "1");
  setupUI();
  connect();
});
