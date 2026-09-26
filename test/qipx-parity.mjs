import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const root = resolve(".");
const implementations = [
  { name: "Node", command: process.execPath, prefix: [resolve("npm/qipx/cli.mjs")] },
  { name: "Rust", command: resolve("rust/qipx/target/debug/qipx"), prefix: [] },
];

function run(implementation, args, { input = Buffer.alloc(0), cwd = root } = {}) {
  const result = spawnSync(implementation.command, [...implementation.prefix, ...args], {
    cwd,
    input,
    timeout: 10000,
  });
  assert.equal(result.error, undefined, `${implementation.name}: ${result.error?.message}`);
  return result;
}

function expectSameOutput(args, input, expected) {
  for (const implementation of implementations) {
    const result = run(implementation, args, { input });
    assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
    assert.deepEqual(result.stdout, expected, implementation.name);
  }
}

const ptyScript = `import fcntl, os, pty, select, signal, struct, sys, termios, time
mode, cwd, marker = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    os.chdir(cwd)
    os.execv(sys.argv[4], sys.argv[4:])
data = b''
sent_exit = False
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(fd, 65536)
            if chunk: data += chunk
        except OSError: pass
    if mode == 'tui' and marker.encode() in data and not sent_exit:
        os.write(fd, b'\x03')
        sent_exit = True
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        while select.select([fd], [], [], 0)[0]:
            try:
                chunk = os.read(fd, 65536)
                if not chunk: break
                data += chunk
            except OSError: break
        sys.stdout.buffer.write(data)
        sys.exit(os.waitstatus_to_exitcode(status))
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
sys.stderr.write('CLI did not exit before timeout\\n')
sys.exit(1)
`;

function runInTerminal(implementation, args, { cwd = root, mode = "run", marker = "" } = {}) {
  const result = spawnSync("python3", [
    "-c", ptyScript, mode, cwd, marker,
    implementation.command, ...implementation.prefix, ...args,
  ], { encoding: "utf8", timeout: 8000 });
  assert.equal(result.error, undefined, `${implementation.name}: ${result.error?.message}`);
  assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}\n${result.stdout}`);
  return result.stdout;
}

test("Node and Rust qipx agree on empty and piped Content input", () => {
  for (const component of ["text/hello.wasm", "text/hello-c.wasm"]) {
    expectSameOutput(["run", component], Buffer.alloc(0), Buffer.from("Hello, World\n"));
    expectSameOutput(["run", component], Buffer.from("QIP"), Buffer.from("Hello, QIP\n"));
  }
  expectSameOutput(["run", "bytes/identity.wasm"], Buffer.from([0, 1, 255]), Buffer.from([0, 1, 255]));
  expectSameOutput(["run", "text/trim.wasm", "bytes/identity.wasm"], Buffer.from("  hello  "), Buffer.from("hello"));
});

test("Node and Rust qipx agree on file and multipart input", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-parity-"));
  try {
    const inputPath = join(directory, "input.txt");
    writeFileSync(inputPath, "  Hello  ");
    for (const implementation of implementations) {
      const outputPath = join(directory, `${implementation.name}.txt`);
      const result = run(implementation, ["run", "-i", inputPath, "-o", outputPath, "text/trim.wasm"]);
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      assert.deepEqual(readFileSync(outputPath), Buffer.from("Hello"), implementation.name);
    }
    const args = ["run", "-F", "mode=step", "-F", `data=<${inputPath}`, "bytes/identity.wasm"];
    const outputs = implementations.map((implementation) => {
      const result = run(implementation, args);
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      return result.stdout;
    });
    assert.deepEqual(outputs[0], outputs[1]);
    assert.match(outputs[0].toString(), /name="data"\r\n\r\n  Hello  \r\n/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Node and Rust qipx report the same rejection offset", () => {
  const input = Buffer.from([0x41, 0xc3, 0x28]);
  for (const implementation of implementations) {
    const result = run(implementation, ["run", "text/utf8-must-be-valid.wasm"], { input });
    assert.equal(result.status, 1, implementation.name);
    assert.deepEqual(result.stdout, Buffer.alloc(0), implementation.name);
    assert.match(result.stderr.toString(), /rejected input at input offset 2/, implementation.name);
  }
});

test("Node and Rust qipx agree on dry run and Compliance outcomes", () => {
  for (const implementation of implementations) {
    const dry = run(implementation, ["dry", "run", "text/hello.wasm"]);
    assert.equal(dry.status, 0, `${implementation.name}: ${dry.stderr}`);
    assert.match(dry.stdout.toString(), /text\/hello\.wasm: valid/, implementation.name);
    assert.match(dry.stdout.toString(), /Pipeline compatible: 1 step\(s\)/, implementation.name);

    const comply = run(implementation, ["comply", "text/hello.wasm"]);
    assert.equal(comply.status, 0, `${implementation.name}: ${comply.stderr}`);
    assert.deepEqual(comply.stdout, Buffer.from("PASS text/hello.wasm\n\npass=1 fail=0 total=1\n"), implementation.name);
  }
});

test("Node and Rust qipx do not follow symlinks found during Compliance scans", { skip: process.platform === "win32" }, () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-parity-scan-"));
  const outside = mkdtempSync(join(tmpdir(), "qipx-parity-outside-"));
  try {
    const components = join(directory, "components");
    mkdirSync(components);
    writeFileSync(join(components, "identity.wasm"), readFileSync("bytes/identity.wasm"));
    writeFileSync(join(outside, "unexpected.wasm"), "invalid Wasm");
    symlinkSync(".", join(components, "loop"), "dir");
    symlinkSync(outside, join(components, "outside"), "dir");
    for (const implementation of implementations) {
      const result = run(implementation, ["comply", "components"], { cwd: directory });
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      assert.deepEqual(result.stdout, Buffer.from("PASS components/identity.wasm\n\npass=1 fail=0 total=1\n"));
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("Node and Rust qipx reject misleading remote filenames", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-parity-path-"));
  try {
    for (const implementation of implementations) {
      for (const path of ["safe\u202Emsaw.wasm", "evil:stream.wasm"]) {
        const result = run(implementation, ["qip.dev", "run", path], { cwd: directory });
        assert.equal(result.status, 1, `${implementation.name}: ${path}`);
        assert.match(result.stderr.toString(), /only missing relative paths ending in \.wasm can be downloaded/);
      }
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Node and Rust qipx escape terminal controls in local path reports", () => {
  const directory = mkdtempSync(join(tmpdir(), "qipx-parity-display-"));
  try {
    for (const implementation of implementations) {
      const result = run(implementation, ["dry", "run", "evil\u001b[31m\u202E.wasm"], { cwd: directory });
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      const report = result.stdout.toString();
      assert.ok(!report.includes("\u001b") && !report.includes("\u202E"), implementation.name);
      assert.match(report, /evil\\u\{1b\}\[31m\\u\{202e\}\.wasm/, implementation.name);
      const error = run(implementation, ["run", "evil\u001b[31m\u202E.wasm"], { cwd: directory });
      assert.equal(error.status, 1, implementation.name);
      assert.ok(!error.stderr.includes(0x1b), implementation.name);
      assert.match(error.stderr.toString(), /evil\\u\{1b\}\[31m\\u\{202e\}\.wasm/, implementation.name);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Node and Rust qipx use empty input for an unused terminal", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    for (const component of ["../../text/hello.wasm", "../../text/hello-c.wasm"]) {
      const output = runInTerminal(implementation, ["run", component], { cwd: resolve("rust/qipx") });
      assert.equal(output, "Hello, World\r\n", `${implementation.name}: ${component}`);
    }
  }
});

test("Node and Rust qipx render the same TUI rows at column zero", { skip: process.platform === "win32" }, () => {
  const frames = implementations.map((implementation) => {
    const output = runInTerminal(implementation, ["tui", "tui/emoji-finder.wasm"], {
      mode: "tui", marker: "Type to filter",
    });
    assert.match(output, /\x1b\[\?1049l/, implementation.name);
    const start = output.indexOf("EMOJI FINDER");
    const end = output.indexOf("Type to filter", start);
    assert.ok(start >= 0 && end > start, implementation.name);
    const frame = output.slice(start, end + "Type to filter  Tab combine  Enter details  Esc clear".length);
    assert.match(frame, /EMOJI FINDER[^\r\n]*\r\nFind: /, implementation.name);
    assert.match(frame, /Unicode name[^\r\n]*\r\n> /, implementation.name);
    return frame;
  });
  assert.equal(frames[0], frames[1]);
});
