import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const rustCLI = resolve("rust/qipx/target/debug/qipx");

function run(command, args, input = "", options = {}) {
  return spawnSync(command, args, { input, encoding: "utf8", ...options });
}

test("Rust qipx provides command help", () => {
  for (const args of [["--help"], ["tui", "--help"], ["bench", "--help"], ["comply", "--help"]]) {
    const rust = run(rustCLI, args);
    assert.equal(rust.status, 0, `${args.join(" ")}: ${rust.stderr}`);
    assert.match(rust.stdout, /Usage: qipx/);
  }
});

test("Rust qipx help explains multipart form variants and terminal restrictions", () => {
  for (const [args, stdinAllowed] of [
    [["--help"], true],
    [["bench", "--help"], true],
    [["tui", "--help"], false],
  ]) {
    const rust = run(rustCLI, args);
    assert.equal(rust.status, 0, rust.stderr);
    for (const variant of ["name=value", "name=@path", "name=<path", "name=@-", "name=<-", "Examples:"]) {
      assert.ok(rust.stdout.includes(variant), `${args.join(" ")} help omits ${variant}`);
    }
    assert.match(rust.stdout, /Content-Type: application\/octet-stream/);
    assert.match(rust.stdout, /omits that part header/);
    assert.match(rust.stdout, /quote/i);
    if (!stdinAllowed) assert.match(rust.stdout, /stdin carries|stdin.*unavailable/i);
  }
});

test("Rust qipx runs a local Content component from stdin", () => {
  const args = ["run", "bytes/identity.wasm"];
  const node = run(process.execPath, ["npm/qipx/cli.mjs", ...args], "hello");
  assert.equal(node.status, 0, node.stderr);
  assert.equal(node.stdout, "hello");

  const rust = run(rustCLI, args, "hello");
  assert.equal(rust.error, undefined, rust.error?.message);
  assert.equal(rust.status, 0, rust.stderr);
  assert.equal(rust.stdout, "hello");
});

test("Rust qipx runs a pipeline with file input and output", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-"));
  try {
    const input = join(directory, "input.txt");
    const output = join(directory, "output.txt");
    writeFileSync(input, "  hello  ");
    const args = ["run", "-i", input, "-o", output, "text/trim.wasm", "bytes/identity.wasm"];
    const rust = run(rustCLI, args);
    assert.equal(rust.status, 0, rust.stderr);
    assert.equal(readFileSync(output, "utf8"), "hello");
    assert.equal(rust.stdout, "");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx accepts a component path after --", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-dash-"));
  try {
    writeFileSync(join(directory, "-identity.wasm"), readFileSync("bytes/identity.wasm"));
    const rust = run(rustCLI, ["run", "--", "-identity.wasm"], "hello", { cwd: directory });
    assert.equal(rust.status, 0, rust.stderr);
    assert.equal(rust.stdout, "hello");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx reports a recoverable Content rejection with its input offset", () => {
  const args = ["run", "text/utf8-must-be-valid.wasm"];
  const rust = run(rustCLI, args, Buffer.from([0x41, 0xc3, 0x28]));
  assert.equal(rust.status, 1);
  assert.equal(rust.stdout, "");
  assert.match(rust.stderr, /rejected input at input offset 2/);
});

test("Rust qipx builds the canonical multipart body", () => {
  const args = ["run", "-F", "mode=step", "bytes/identity.wasm"];
  const rust = run(rustCLI, args);
  assert.equal(rust.status, 0, rust.stderr);
  assert.equal(rust.stdout,
    "--uuid-00000000-0000-0000-0000-000000000000\r\n" +
    'Content-Disposition: form-data; name="mode"\r\n\r\n' +
    "step\r\n" +
    "--uuid-00000000-0000-0000-0000-000000000000--\r\n");
});

test("Rust qipx includes file bytes and filename in multipart input", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-form-"));
  try {
    const file = join(directory, "data.bin");
    writeFileSync(file, "abc");
    const rust = run(rustCLI, ["run", "-F", `upload=@${file}`, "bytes/identity.wasm"]);
    assert.equal(rust.status, 0, rust.stderr);
    assert.match(rust.stdout, /name="upload"; filename="data\.bin"\r\nContent-Type: application\/octet-stream\r\n\r\nabc\r\n/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx includes file bytes without a filename for -F name=<path", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-form-text-"));
  try {
    const file = join(directory, "data.txt");
    writeFileSync(file, "hello\n");
    const rust = run(rustCLI, ["run", "-F", `data=<${file}`, "bytes/identity.wasm"]);
    assert.equal(rust.status, 0, rust.stderr);
    assert.equal(rust.stdout,
      "--uuid-00000000-0000-0000-0000-000000000000\r\n" +
      'Content-Disposition: form-data; name="data"\r\n\r\n' +
      "hello\n\r\n" +
      "--uuid-00000000-0000-0000-0000-000000000000--\r\n");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx reads -F name=<- from stdin without a filename", () => {
  const rust = run(rustCLI, ["run", "-F", "data=<-", "bytes/identity.wasm"], "hello\n");
  assert.equal(rust.status, 0, rust.stderr);
  assert.equal(rust.stdout,
    "--uuid-00000000-0000-0000-0000-000000000000\r\n" +
    'Content-Disposition: form-data; name="data"\r\n\r\n' +
    "hello\n\r\n" +
    "--uuid-00000000-0000-0000-0000-000000000000--\r\n");
});

test("Rust qipx tui reserves stdin for keys when -F uses <-", () => {
  const rust = run(rustCLI, ["tui", "-F", "data=<-", "components/interactive/calendar-gregorian.wasm"], "hello");
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /cannot use -F name=@- or name=<- because stdin carries terminal events/);
});

test("Rust qipx permits only one multipart field to read stdin", () => {
  for (const command of [["run"], ["dry", "run"]]) {
    const rust = run(rustCLI, [...command, "-F", "first=@-", "-F", "second=<-", "bytes/identity.wasm"], "hello");
    assert.equal(rust.status, 1);
    assert.match(rust.stderr, /only one -F field may read from stdin with @- or <-/);
  }
});

test("Rust qipx runs a component with empty input", () => {
  const rust = run(rustCLI, ["run", "text/hello.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.equal(rust.stdout, "Hello, World\n");
});

test("Rust qipx runs a true inputless generator", () => {
  const rust = run(rustCLI, ["run", "components/interactive/calendar-gregorian.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /January 2024/);
});

test("Rust qipx applies uniforms to the preceding stage", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-uniform-"));
  try {
    const output = join(directory, "one-pixel.ktx2");
    const rust = run(rustCLI, ["run", "-o", output,
      "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm",
      "-u", "width=1", "-u", "height=1"]);
    assert.equal(rust.status, 0, rust.stderr);
    const bytes = readFileSync(output);
    assert.equal(bytes.length, 240);
    assert.equal(bytes.readUInt32LE(20), 1);
    assert.equal(bytes.readUInt32LE(24), 1);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx matches Node for SVG rasterization, SIMD resizing, and WebP encoding", () => {
  const args = ["run",
    "image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm",
    "-u", "width=32", "-u", "height=32",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm"];
  const input = readFileSync("qip-logo.svg");
  const node = spawnSync(process.execPath, ["npm/qipx/cli.mjs", ...args], { input });
  const rust = spawnSync(rustCLI, args, { input });
  assert.equal(node.status, 0, node.stderr.toString());
  assert.equal(rust.status, 0, rust.stderr.toString());
  assert.equal(rust.stdout.toString("ascii", 0, 4), "RIFF");
  assert.equal(rust.stdout.toString("ascii", 8, 12), "WEBP");
  assert.deepEqual(rust.stdout, node.stdout);
});

test("Rust qipx matches Node for PNG decoding, SIMD shrinking, and WebP encoding", () => {
  const args = ["run",
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm",
    "-u", "width=64", "-u", "height=64",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm"];
  const input = readFileSync("qip-logo.png");
  const node = spawnSync(process.execPath, ["npm/qipx/cli.mjs", ...args], { input });
  const rust = spawnSync(rustCLI, args, { input });
  assert.equal(node.status, 0, node.stderr.toString());
  assert.equal(rust.status, 0, rust.stderr.toString());
  assert.equal(rust.stdout.toString("ascii", 0, 4), "RIFF");
  assert.equal(rust.stdout.toString("ascii", 8, 12), "WEBP");
  assert.deepEqual(rust.stdout, node.stdout);
});

test("Rust qipx converts unsigned and hex i32 uniforms like the Node CLI", () => {
  for (const value of ["4294967295", "0xffffffff", "4294967296"]) {
    const args = ["run", "test/fixtures/qipx-rust-uniform-u32.wasm", "-u", `value=${value}`];
    const node = spawnSync(process.execPath, ["npm/qipx/cli.mjs", ...args]);
    const rust = spawnSync(rustCLI, args);
    assert.equal(node.status, 0, node.stderr.toString());
    assert.equal(rust.status, 0, rust.stderr.toString());
    assert.deepEqual(rust.stdout, node.stdout);
  }
});

test("Rust qipx dry run validates a local component without reading stdin", () => {
  const rust = run(rustCLI, ["dry", "run", "bytes/identity.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /bytes\/identity\.wasm: valid/);
  assert.match(rust.stdout, /Pipeline compatible: 1 step\(s\)/);
});

test("Rust qipx rejects memory.grow before running a component", () => {
  const rust = run(rustCLI, ["run", "test/fixtures/qipx-rust-memory-grow.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /memory\.grow/);
});

test("Rust qipx rejects host imports in Content components", () => {
  const rust = run(rustCLI, ["run", "compliance/reject-invalid-utf8.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /imports host functions or state/);
});

test("Rust qipx rejects dynamic ABI capacity getters", () => {
  const rust = run(rustCLI, ["run", "test/fixtures/qipx-rust-dynamic-getter.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /static qip contract checks failed/);
});

test("Rust qipx enforces the declared memory cap", () => {
  const rust = run(rustCLI, ["run", "--max-memory", "1024", "bytes/identity.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /exceeding --max-memory 1024/);
});

test("Rust qipx dry run plans hosts without a network request", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-dry-"));
  try {
    const rust = run(rustCLI, ["qip.dev", "dry", "run", "missing.wasm"], "", { cwd: directory });
    assert.equal(rust.status, 0, rust.stderr);
    assert.match(rust.stdout, /https:\/\/qip\.dev\/missing\.wasm/);
    assert.match(rust.stdout, /missing\.wasm: deferred \(local file missing\)/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx dry run percent-encodes remote path segments", () => {
  const rust = run(rustCLI, ["qip.dev", "dry", "run", "text/a b.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /https:\/\/qip\.dev\/text\/a%20b\.wasm/);
});

test("Rust qipx dry run accepts run options and observes multipart files", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-dry-form-"));
  try {
    const file = join(directory, "input.bin");
    writeFileSync(file, "abc");
    const rust = run(rustCLI, ["dry", "run", "-F", `upload=@${file}`, "--capacities-must-fit", "bytes/identity.wasm"]);
    assert.equal(rust.status, 0, rust.stderr);
    assert.match(rust.stdout, /Multipart files:/);
    assert.match(rust.stdout, /present \(contents not read\)/);
    assert.match(rust.stdout, /Pipeline compatible: 1 step\(s\)/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx dry run plans files supplied as multipart text fields", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-dry-text-field-"));
  try {
    const file = join(directory, "input.txt");
    writeFileSync(file, "hello");
    const rust = run(rustCLI, ["dry", "run", "-F", `data=<${file}`, "bytes/identity.wasm"]);
    assert.equal(rust.status, 0, rust.stderr);
    assert.match(rust.stdout, /Multipart files:/);
    assert.match(rust.stdout, /present \(contents not read\)/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx benchmarks a verified Content result", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-bench-"));
  try {
    const input = join(directory, "input.txt");
    writeFileSync(input, "hello");
    const rust = run(rustCLI, ["bench", "-i", input, "--runs", "1", "--warmup", "0", "bytes/identity.wasm"]);
    assert.equal(rust.status, 0, rust.stderr);
    assert.match(rust.stdout, /Output SHA-256: 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824/);
    assert.match(rust.stdout, /bytes\/identity\.wasm/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx benchmarks multipart input for a short target duration", () => {
  const rust = run(rustCLI, ["bench", "-F", "message=hello", "--warmup", "0", "--benchtime=1ms", "bytes/identity.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /Measured: 1ms target\/component/);
  assert.match(rust.stdout, /Output SHA-256:/);
});

test("Rust qipx recursively checks a directory in comply mode", () => {
  const rust = run(rustCLI, ["comply", "bytes"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /PASS bytes\/identity\.wasm/);
  assert.match(rust.stdout, /pass=\d+ fail=0 total=\d+/);
});

test("Rust qipx executes a Compliance oracle against a Content component", () => {
  const rust = run(rustCLI, ["comply", "bytes/identity.wasm", "--with", "compliance/preserve-empty.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /PASS bytes\/identity\.wasm --with compliance\/preserve-empty\.wasm \(1 cases\)/);
  assert.match(rust.stdout, /pass=2 fail=0 total=2/);
});

test("Rust qipx distinguishes a declared rejection from a trap", () => {
  const rust = run(rustCLI, ["comply", "text/utf8-must-be-valid.wasm", "--with", "compliance/reject-invalid-utf8.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /compliance\/reject-invalid-utf8\.wasm \(10 cases\)/);
});

test("Rust qipx reports a failed trap assertion from a Compliance oracle", () => {
  const rust = run(rustCLI, ["comply", "bytes/identity.wasm", "--with", "compliance/trap-empty-input.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stdout, /case 0: expected trap, got output/);
  assert.match(rust.stdout, /pass=1 fail=1 total=2/);
});

test("Rust qipx supports render-into Compliance cases", () => {
  const rust = run(rustCLI, ["comply", "bytes/identity.wasm", "--with", "test/fixtures/qipx-rust-render-into.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /render-into\.wasm \(1 cases\)/);
});

test("Rust qipx supports oracle-controlled uniforms", () => {
  const rust = run(rustCLI, ["comply", "--seed", "4217", "text/currency-format-en-us.wasm", "--with", "compliance/currency-format-en-us.comply.wasm"]);
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /currency-format-en-us\.comply\.wasm \(\d+ cases\)/);
});

test("Rust qipx accepts one multipart file from stdin", () => {
  const rust = run(rustCLI, ["run", "-F", "upload=@-", "bytes/identity.wasm"], "abc");
  assert.equal(rust.status, 0, rust.stderr);
  assert.match(rust.stdout, /name="upload"; filename="-"\r\nContent-Type: application\/octet-stream\r\n\r\nabc\r\n/);
});

test("Rust qipx rejects a multipart delimiter inside a field body", () => {
  const body = "line\r\n--uuid-00000000-0000-0000-0000-000000000000\r\nother";
  const rust = run(rustCLI, ["run", "-F", `text=${body}`, "bytes/identity.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /contains the multipart boundary as a delimiter line/);
});

test("Rust qipx accepts capacity validation for a compatible pipeline", () => {
  const rust = run(rustCLI, ["run", "--capacities-must-fit", "text/trim.wasm", "bytes/identity.wasm"], " hello ");
  assert.equal(rust.status, 0, rust.stderr);
  assert.equal(rust.stdout, "hello");
});

test("Rust qipx explains MIME and capacity pipeline failures", () => {
  const mime = run(rustCLI, ["dry", "run", "text/hello.wasm", "image/png/png-to-bmp-b8g8r8a8-srgb.wasm"]);
  assert.equal(mime.status, 1);
  assert.match(mime.stderr, /expects image\/png, but pipeline content type is unspecified/);
  const capacity = run(rustCLI, ["dry", "run", "--capacities-must-fit", "text/ansi-sgr-to-svg.wasm", "text/rgb-to-hex.wasm"]);
  assert.equal(capacity.status, 1);
  assert.match(capacity.stderr, /output capacity 8388608 exceeds .* input capacity 65536/);
});

test("Rust qipx resolves and caches a missing component over verified HTTPS", { skip: !process.env.QIPX_NETWORK_TESTS }, () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-rust-host-"));
  try {
    const rust = run(rustCLI, ["qip.dev", "run", "bytes/identity.wasm"], "hello", { cwd: directory });
    assert.equal(rust.status, 0, rust.stderr);
    assert.equal(rust.stdout, "hello");
    assert.deepEqual(readFileSync(join(directory, "bytes/identity.wasm")), readFileSync("bytes/identity.wasm"));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Rust qipx tui requires a terminal", () => {
  const rust = run(rustCLI, ["tui", "components/interactive/calendar-gregorian.wasm"]);
  assert.equal(rust.status, 1);
  assert.match(rust.stderr, /requires terminal stdin and stdout/);
});

test("Rust qipx tui renders and handles an arrow key in a terminal", { skip: process.platform === "win32" }, () => {
  const script = `import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'tui', 'components/interactive/calendar-gregorian.wasm'])
data = b''
deadline = time.monotonic() + 5
sent_down = False
sent_exit = False
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try: data += os.read(fd, 65536)
        except OSError: break
    if b'January 2024' in data and not sent_down:
        os.write(fd, b'\\x1b[B')
        sent_down = True
    if b'February 2024' in data and not sent_exit:
        os.write(fd, b'\\x03')
        sent_exit = True
    if sent_exit:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done: break
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
sys.stdout.buffer.write(data)
`;
  const result = run("python3", ["-c", script, rustCLI], "", { timeout: 8000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /January 2024/);
  assert.match(result.stdout, /February 2024/);
  assert.match(result.stdout, /\x1b\[\?1049l/);
});

test("Rust qipx tui rejects unsafe terminal output and restores the screen", { skip: process.platform === "win32" }, () => {
  const script = `import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'tui', 'test/fixtures/qipx-rust-unsafe-tui.wasm'])
data = b''
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try: data += os.read(fd, 65536)
        except OSError: break
    done, status = os.waitpid(pid, os.WNOHANG)
    if done: break
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
sys.stdout.buffer.write(data)
`;
  const result = run("python3", ["-c", script, rustCLI], "", { timeout: 8000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /unsupported CSI sequence/);
  assert.match(result.stdout, /\x1b\[\?1049l/);
  assert.doesNotMatch(result.stdout, /\x1b\[2J/);
});

test("Rust qipx tui renders a scheduled wake without a key", { skip: process.platform === "win32" }, () => {
  const script = `import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'tui', 'test/fixtures/qipx-rust-wake-tui.wasm'])
data = b''
deadline = time.monotonic() + 5
sent_exit = False
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try: data += os.read(fd, 65536)
        except OSError: break
    if b'after' in data and not sent_exit:
        os.write(fd, b'\\x03')
        sent_exit = True
    if sent_exit:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done: break
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
sys.stdout.buffer.write(data)
`;
  const result = run("python3", ["-c", script, rustCLI], "", { timeout: 8000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /before/);
  assert.match(result.stdout, /after/);
  assert.match(result.stdout, /\x1b\[\?1049l/);
});

test("Rust qipx tui restores the screen on SIGTERM", { skip: process.platform === "win32" }, () => {
  const script = `import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], [sys.argv[1], 'tui', 'components/interactive/calendar-gregorian.wasm'])
data = b''
deadline = time.monotonic() + 5
sent = False
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try: data += os.read(fd, 65536)
        except OSError: break
    if b'January 2024' in data and not sent:
        os.kill(pid, signal.SIGTERM)
        sent = True
    if sent:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            data += ('exit=%d' % os.waitstatus_to_exitcode(status)).encode()
            break
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
sys.stdout.buffer.write(data)
`;
  const result = run("python3", ["-c", script, rustCLI], "", { timeout: 8000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\x1b\[\?1049l/);
  assert.match(result.stdout, /exit=143/);
});
