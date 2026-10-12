import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

// Every test runs against both qipx hosts. Where output is deterministic, the hosts must
// produce the same exit status, stdout, and stderr byte for byte.
const root = resolve(".");
const implementations = [
  { name: "Node", command: process.execPath, prefix: [resolve("npm/qipx/cli.mjs")] },
  { name: "Rust", command: resolve("rust/qipx/target/debug/qipx"), prefix: [] },
];

function run(implementation, args, { input = Buffer.alloc(0), cwd = root, timeout = 10000 } = {}) {
  const result = spawnSync(implementation.command, [...implementation.prefix, ...args], {
    cwd,
    input,
    timeout,
  });
  assert.equal(result.error, undefined, `${implementation.name}: ${result.error?.message}`);
  return result;
}

// expectSame runs args in every host, checks that status, stdout, and stderr match, and
// returns the shared result with text helpers.
function expectSame(args, options = {}) {
  const [first, ...rest] = implementations.map((implementation) => run(implementation, args, options));
  for (const [index, result] of rest.entries()) {
    const name = implementations[index + 1].name;
    assert.equal(result.status, first.status, `${name} status for ${args.join(" ")}: ${result.stderr}`);
    assert.deepEqual(result.stdout, first.stdout, `${name} stdout for ${args.join(" ")}`);
    assert.equal(result.stderr.toString(), first.stderr.toString(), `${name} stderr for ${args.join(" ")}`);
  }
  return { status: first.status, stdout: first.stdout, out: first.stdout.toString(), err: first.stderr.toString() };
}

function expectSuccess(args, options) {
  const result = expectSame(args, options);
  assert.equal(result.status, 0, result.err);
  return result;
}

function expectFailure(args, pattern, options) {
  const result = expectSame(args, options);
  assert.equal(result.status, 1, `${args.join(" ")} should fail`);
  assert.match(result.err, pattern);
  return result;
}

function withTemporaryDirectory(prefix, body) {
  const directory = mkdtempSync(join(tmpdir(), `qipx-parity-${prefix}-`));
  try {
    return body(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// The PTY driver writes each step's keys, or sends SIGTERM, once its marker appears, then
// waits for the CLI to exit. It prints the terminal output and reports the exit code on stderr.
const ptyScript = `import fcntl, json, os, pty, select, signal, struct, sys, termios, time
cwd, steps = sys.argv[1], json.loads(sys.argv[2])
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    os.chdir(cwd)
    os.execv(sys.argv[3], sys.argv[3:])
data = b''
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        try:
            chunk = os.read(fd, 65536)
            if chunk: data += chunk
        except OSError: pass
    if steps and steps[0][0].encode() in data:
        marker, action = steps.pop(0)
        if action == 'SIGTERM': os.kill(pid, signal.SIGTERM)
        else: os.write(fd, action.encode())
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        while select.select([fd], [], [], 0)[0]:
            try:
                chunk = os.read(fd, 65536)
                if not chunk: break
                data += chunk
            except OSError: break
        sys.stdout.buffer.write(data)
        sys.stderr.write('exit=%d' % os.waitstatus_to_exitcode(status))
        sys.exit(0)
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
sys.stderr.write('CLI did not exit before timeout\\n')
sys.exit(1)
`;

function runInTerminal(implementation, args, { cwd = root, steps = [] } = {}) {
  const result = spawnSync("python3", [
    "-c", ptyScript, cwd, JSON.stringify(steps),
    implementation.command, ...implementation.prefix, ...args,
  ], { encoding: "utf8", timeout: 8000 });
  assert.equal(result.error, undefined, `${implementation.name}: ${result.error?.message}`);
  assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}\n${result.stdout}`);
  return { output: result.stdout, exitCode: Number(/exit=(-?\d+)/.exec(result.stderr)[1]) };
}

const ctrlC = "\x03";
const downArrow = "\x1b[B";
const multipartBoundary = "--uuid-00000000-0000-0000-0000-000000000000";

test("qipx hosts print the same command help", () => {
  for (const args of [[], ["--help"], ["help"], ["run", "--help"], ["dry", "run", "--help"], ["dry", "--help"],
    ["tui", "--help"], ["bench", "--help"], ["comply", "--help"]]) {
    const result = expectSuccess(args);
    assert.match(result.out, /Usage: qipx/, args.join(" "));
  }
});

test("qipx help explains multipart form variants and terminal restrictions", () => {
  for (const [args, stdinAllowed] of [
    [["--help"], true],
    [["bench", "--help"], true],
    [["tui", "--help"], false],
  ]) {
    const { out } = expectSuccess(args);
    for (const variant of ["name=value", "name=@path", "name=<path", "name=@-", "name=<-", "Examples:"]) {
      assert.ok(out.includes(variant), `${args.join(" ")} help omits ${variant}`);
    }
    assert.match(out, /Content-Type: application\/octet-stream/);
    assert.match(out, /omits that part header/);
    assert.match(out, /quote/i);
    if (!stdinAllowed) assert.match(out, /stdin carries|stdin.*unavailable/i);
  }
});

test("qipx hosts report the same usage errors", () => {
  expectFailure(["nothing"], /^qipx: requires a subcommand: run, dry run, tui, bench, or comply\n$/);
  expectFailure(["dry"], /^qipx: dry must be followed by run\n$/);
  expectFailure(["bad_host", "run", "text/hello.wasm"], /invalid host "bad_host"/);
  expectFailure(["run"], /component/);
  expectFailure(["run", "--bogus", "text/hello.wasm"], /^qipx: unknown option --bogus\n$/);
  expectFailure(["run", "--max-memory"], /^qipx: --max-memory requires <bytes>\n$/);
  expectFailure(["run", "-u", "a", "text/hello.wasm"], /^qipx: -u must follow a component path\n$/);
  expectFailure(["run", "text/hello.wasm", "--uniform", "a"], /^qipx: --uniform requires <name=value>, got "a"\n$/);
  expectFailure(["bench", "-F", "a=b", "-r", "0", "bytes/identity.wasm"], /^qipx: -r must be a positive integer\n$/);
  expectFailure(["bench", "-F", "a=b"], /^qipx: bench requires at least one component\n$/);
  expectFailure(["bench", "bytes/identity.wasm"], /^qipx: bench requires -i <input> or -F <name=value>\n$/);
  expectFailure(["comply"], /^qipx: comply requires at least one file or directory\n$/);
  expectFailure(["comply", "--bogus", "bytes"], /^qipx: unknown option --bogus\n$/);
  expectFailure(["comply", "--with"], /^qipx: --with requires a path\n$/);
  expectFailure(["comply", "--seed"], /^qipx: --seed requires <n>\n$/);
  expectFailure(["comply", "README.md"], /^qipx: README\.md is not a \.wasm file\n$/);
  expectFailure(["comply", "missing-directory"], /^qipx: cannot read missing-directory: no such file or directory\n$/);
});

test("qipx hosts report the same file errors", () => {
  withTemporaryDirectory("file-errors", (directory) => {
    const missing = join(directory, "missing");
    expectFailure(["run", "-i", missing, "bytes/identity.wasm"], new RegExp(`cannot read ${missing}: no such file or directory`));
    expectFailure(["run", "-i", directory, "bytes/identity.wasm"], new RegExp(`cannot read ${directory}: is a directory`));
    expectFailure(["run", "-o", join(missing, "out"), "text/hello.wasm"], /cannot write .*: no such file or directory/);
    expectFailure(["run", "-F", `a=@${missing}`, "bytes/identity.wasm"], new RegExp(`read -F a=@${missing}: no such file or directory`));
    expectFailure(["run", "-F", `a=<${missing}`, "bytes/identity.wasm"], new RegExp(`read -F a=<${missing}: no such file or directory`));
    expectFailure(["bench", "-i", missing, "bytes/identity.wasm"], new RegExp(`cannot read ${missing}: no such file or directory`));
    expectFailure(["run", "README.md"], /^qipx: README\.md is not a WebAssembly binary module\n$/);
    expectFailure(["run", "missing.wasm"], /^qipx: missing\.wasm is unavailable from every source\n$/, { cwd: directory });
  });
});

test("qipx hosts agree on empty and piped Content input", () => {
  for (const component of ["text/hello.wasm", "text/hello-c.wasm"]) {
    assert.equal(expectSuccess(["run", component]).out, "Hello, World\n");
    assert.equal(expectSuccess(["run", component], { input: Buffer.from("QIP") }).out, "Hello, QIP\n");
  }
  assert.deepEqual(expectSuccess(["run", "bytes/identity.wasm"], { input: Buffer.from([0, 1, 255]) }).stdout, Buffer.from([0, 1, 255]));
  assert.equal(expectSuccess(["run", "text/trim.wasm", "bytes/identity.wasm"], { input: Buffer.from("  hello  ") }).out, "hello");
});

test("qipx hosts run a pipeline with file input and output", () => {
  withTemporaryDirectory("file", (directory) => {
    const inputPath = join(directory, "input.txt");
    writeFileSync(inputPath, "  Hello  ");
    for (const implementation of implementations) {
      const outputPath = join(directory, `${implementation.name}.txt`);
      const result = run(implementation, ["run", "-i", inputPath, "-o", outputPath, "text/trim.wasm", "bytes/identity.wasm"]);
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      assert.deepEqual(result.stdout, Buffer.alloc(0), implementation.name);
      assert.deepEqual(readFileSync(outputPath), Buffer.from("Hello"), implementation.name);
    }
  });
});

test("qipx hosts accept a component path after --", () => {
  withTemporaryDirectory("dash", (directory) => {
    writeFileSync(join(directory, "-identity.wasm"), readFileSync("bytes/identity.wasm"));
    assert.equal(expectSuccess(["run", "--", "-identity.wasm"], { input: Buffer.from("hello"), cwd: directory }).out, "hello");
  });
});

test("qipx hosts report the same rejection offset", () => {
  const result = expectFailure(["run", "text/utf8-must-be-valid.wasm"], /rejected input at input offset 2/, {
    input: Buffer.from([0x41, 0xc3, 0x28]),
  });
  assert.equal(result.out, "");
});

test("qipx hosts build the same canonical multipart body", () => {
  assert.equal(expectSuccess(["run", "-F", "mode=step", "bytes/identity.wasm"]).out,
    `${multipartBoundary}\r\n` +
    'Content-Disposition: form-data; name="mode"\r\n\r\n' +
    "step\r\n" +
    `${multipartBoundary}--\r\n`);
});

test("qipx hosts include multipart file bytes with and without a filename", () => {
  withTemporaryDirectory("form", (directory) => {
    const binary = join(directory, "data.bin");
    const text = join(directory, "data.txt");
    writeFileSync(binary, "abc");
    writeFileSync(text, "hello\n");
    assert.match(expectSuccess(["run", "-F", `upload=@${binary}`, "bytes/identity.wasm"]).out,
      /name="upload"; filename="data\.bin"\r\nContent-Type: application\/octet-stream\r\n\r\nabc\r\n/);
    assert.equal(expectSuccess(["run", "-F", `data=<${text}`, "bytes/identity.wasm"]).out,
      `${multipartBoundary}\r\n` +
      'Content-Disposition: form-data; name="data"\r\n\r\n' +
      "hello\n\r\n" +
      `${multipartBoundary}--\r\n`);
    const mixed = expectSuccess(["run", "-F", "mode=step", "-F", `data=<${text}`, "bytes/identity.wasm"]);
    assert.match(mixed.out, /name="data"\r\n\r\nhello\n\r\n/);
  });
});

test("qipx hosts read multipart fields from stdin", () => {
  assert.equal(expectSuccess(["run", "-F", "data=<-", "bytes/identity.wasm"], { input: Buffer.from("hello\n") }).out,
    `${multipartBoundary}\r\n` +
    'Content-Disposition: form-data; name="data"\r\n\r\n' +
    "hello\n\r\n" +
    `${multipartBoundary}--\r\n`);
  assert.match(expectSuccess(["run", "-F", "upload=@-", "bytes/identity.wasm"], { input: Buffer.from("abc") }).out,
    /name="upload"; filename="-"\r\nContent-Type: application\/octet-stream\r\n\r\nabc\r\n/);
});

test("qipx hosts permit only one multipart field to read stdin", () => {
  for (const command of [["run"], ["dry", "run"]]) {
    expectFailure([...command, "-F", "first=@-", "-F", "second=<-", "bytes/identity.wasm"],
      /only one -F field may read from stdin with @- or <-/, { input: Buffer.from("hello") });
  }
});

test("qipx hosts reject a multipart delimiter inside a field body", () => {
  const body = `line\r\n${multipartBoundary}\r\nother`;
  expectFailure(["run", "-F", `text=${body}`, "bytes/identity.wasm"], /contains the multipart boundary as a delimiter line/);
});

test("qipx hosts run a true inputless generator", () => {
  assert.match(expectSuccess(["run", "tui/calendar-gregorian.wasm"]).out, /January 2024/);
});

test("qipx hosts apply uniforms to the preceding stage", () => {
  withTemporaryDirectory("uniform", (directory) => {
    const outputs = implementations.map((implementation) => {
      const output = join(directory, `${implementation.name}.ktx2`);
      const result = run(implementation, ["run", "-o", output,
        "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm",
        "-u", "width=1", "-u", "height=1"]);
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      return readFileSync(output);
    });
    assert.deepEqual(outputs[1], outputs[0]);
    assert.equal(outputs[0].length, 240);
    assert.equal(outputs[0].readUInt32LE(20), 1);
    assert.equal(outputs[0].readUInt32LE(24), 1);
  });
});

test("qipx hosts agree on SVG rasterization, SIMD resizing, and WebP encoding", () => {
  const { stdout } = expectSuccess(["run",
    "image/svg+xml/svg-rasterize-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-up-mitchell-simd.wasm",
    "-u", "width=32", "-u", "height=32",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm"], { input: readFileSync("qip-logo.svg") });
  assert.equal(stdout.toString("ascii", 0, 4), "RIFF");
  assert.equal(stdout.toString("ascii", 8, 12), "WEBP");
});

test("qipx hosts agree on PNG decoding, SIMD shrinking, and WebP encoding", () => {
  const { stdout } = expectSuccess(["run",
    "image/png/png-to-ktx2-r8g8b8a8-srgb.wasm",
    "image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm",
    "-u", "width=64", "-u", "height=64",
    "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm"], { input: readFileSync("qip-logo.png") });
  assert.equal(stdout.toString("ascii", 0, 4), "RIFF");
  assert.equal(stdout.toString("ascii", 8, 12), "WEBP");
});

test("qipx hosts pass exact unsigned i32 uniforms", () => {
  for (const [value, expected] of [["0", 0], ["4294967295", 0xffffffff], ["0xffffffff", 0xffffffff], ["0x0001", 1]]) {
    const { stdout } = expectSuccess(["run", "test/fixtures/qipx-rust-uniform-u32.wasm", "-u", `value=${value}`]);
    assert.equal(stdout.readUInt32LE(0), expected, value);
  }
});

test("qipx hosts reject i32 uniforms instead of truncating or wrapping", () => {
  for (const value of ["4294967296", "0x100000000", "-1", "+1", "1.5", "1e3", "0x", "abc", ""]) {
    expectFailure(["run", "test/fixtures/qipx-rust-uniform-u32.wasm", "-u", `value=${value}`], /is not an unsigned i32 integer/);
  }
});

test("qipx hosts reject f32 uniforms that overflow to infinity", () => {
  const oklch = "image/ktx2/solid-color-oklch-to-ktx2-rgba32float-display-p3-linear.wasm";
  for (const value of ["1e39", "-1e39", "1e400"]) {
    expectFailure(["run", oklch, "-u", `lightness=${value}`], /is not a finite f32 number/);
  }
});

const sigv4GetVanilla = [
  "-F", "method=GET",
  "-F", "url=https://example.amazonaws.com/",
  "-F", "region=us-east-1",
  "-F", "service=service",
  "-F", "access_key_id=AKIDEXAMPLE",
  "-F", "secret_access_key=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
  "multipart/form-data/aws-sigv4-sign.wasm",
];

test("qipx hosts pass exact i64 uniforms", () => {
  for (const value of ["1440938160", "+1440938160", "0x55E2F8B0"]) {
    assert.match(expectSuccess(["run", ...sigv4GetVanilla, "-u", `timestamp=${value}`]).out,
      /Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31/, value);
  }
});

test("qipx hosts reject i64 uniforms instead of rounding, truncating or clamping", () => {
  for (const value of ["9223372036854775808", "-9223372036854775809", "1440938160.5", "1e3", "0x", "abc", ""]) {
    expectFailure(["run", ...sigv4GetVanilla, "-u", `timestamp=${value}`], /is not an i64 integer/);
  }
});

test("qipx hosts reject components outside the Strict Wasm Profile with the same messages", () => {
  expectFailure(["run", "test/fixtures/qipx-rust-memory-grow.wasm"], /memory\.grow/);
  expectFailure(["run", "compliance/reject-invalid-utf8.wasm"], /imports host functions or state/);
  // The compliance oracles both import host functions and declare memory without a maximum;
  // the import section comes first in the binary, so it must be reported first everywhere.
  expectFailure(["run", "compliance/base64-encode.comply.wasm"], /imports host functions or state/);
  expectFailure(["run", "test/fixtures/qipx-rust-dynamic-getter.wasm"], /static qip contract checks failed/);
  expectFailure(["run", "test/fixtures/qipx-rust-atomic.wasm"], /uses atomic instructions, which are outside the Strict Wasm Profile/);
  expectFailure(["run", "test/fixtures/qipx-rust-tail-call.wasm"], /uses unsupported Wasm opcode 0x12 at byte offset 145/);
  expectFailure(["run", "--max-memory", "1024", "bytes/identity.wasm"], /exceeding --max-memory 1024/);
});

test("qipx hosts check pipeline capacity", () => {
  assert.equal(expectSuccess(["run", "--capacities-must-fit", "text/trim.wasm", "bytes/identity.wasm"], { input: Buffer.from(" hello ") }).out, "hello");
  expectFailure(["dry", "run", "text/hello.wasm", "image/png/png-to-bmp-b8g8r8a8-srgb.wasm"],
    /expected image\/png, but pipeline content type is unspecified/);
  expectFailure(["dry", "run", "--capacities-must-fit", "text/ansi-sgr-to-svg.wasm", "text/rgb-to-hex.wasm"],
    /input capacity 64\.0 KiB \(65536 bytes\) cannot fit .* output capacity 8\.0 MiB \(8388608 bytes\)/);
});

test("qipx hosts print the same dry run plan without reading stdin", () => {
  const single = expectSuccess(["dry", "run", "bytes/identity.wasm"]);
  assert.match(single.out, /bytes\/identity\.wasm: valid/);
  assert.match(single.out, /Pipeline compatible: 1 step\(s\)/);
  const notes = expectSuccess(["dry", "run", "text/ansi-sgr-to-svg.wasm", "text/rgb-to-hex.wasm"]);
  assert.match(notes.out, /Buffers: 8\.2 MiB \(8650752 bytes\)/);
  assert.match(notes.out, /Note: step 2/);
  expectSuccess(["dry", "run", "text/hello.wasm", "bytes/identity.wasm"]);
});

test("qipx hosts plan remote components in dry run without a network request", () => {
  withTemporaryDirectory("dry", (directory) => {
    const result = expectSuccess(["qip.dev", "dry", "run", "missing.wasm"], { cwd: directory });
    assert.match(result.out, /https:\/\/qip\.dev\/missing\.wasm/);
    assert.match(result.out, /missing\.wasm: deferred \(local file missing\)/);
  });
  assert.match(expectSuccess(["qip.dev", "dry", "run", "text/a b.wasm"]).out, /https:\/\/qip\.dev\/text\/a%20b\.wasm/);
});

test("qipx hosts dry run accepts run options and observes multipart files", () => {
  withTemporaryDirectory("dry-form", (directory) => {
    const file = join(directory, "input.bin");
    writeFileSync(file, "abc");
    for (const field of [`upload=@${file}`, `data=<${file}`]) {
      const result = expectSuccess(["dry", "run", "-F", field, "--capacities-must-fit", "bytes/identity.wasm"]);
      assert.match(result.out, /Multipart files:/);
      assert.match(result.out, /present \(contents not read\)/);
      assert.match(result.out, /Pipeline compatible: 1 step\(s\)/);
    }
  });
});

test("qipx hosts benchmark a verified Content result", () => {
  withTemporaryDirectory("bench", (directory) => {
    const input = join(directory, "input.txt");
    writeFileSync(input, "hello");
    for (const implementation of implementations) {
      const result = run(implementation, ["bench", "-i", input, "--runs", "1", "--warmup", "0", "bytes/identity.wasm"]);
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      assert.match(result.stdout.toString(), /Output SHA-256: 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824/, implementation.name);
      assert.match(result.stdout.toString(), /bytes\/identity\.wasm/, implementation.name);
    }
  });
});

test("qipx hosts benchmark multipart input for a short target duration", () => {
  for (const implementation of implementations) {
    const result = run(implementation, ["bench", "-F", "message=hello", "--warmup", "0", "--benchtime=1ms", "bytes/identity.wasm"]);
    assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
    assert.match(result.stdout.toString(), /Measured: 1ms target\/component/, implementation.name);
    assert.match(result.stdout.toString(), /Output SHA-256:/, implementation.name);
  }
});

test("qipx hosts agree on Compliance outcomes", () => {
  assert.equal(expectSuccess(["comply", "text/hello.wasm"]).out, "PASS text/hello.wasm\n\npass=1 fail=0 total=1\n");
  const directory = expectSuccess(["comply", "bytes"]);
  assert.match(directory.out, /PASS bytes\/identity\.wasm/);
  assert.match(directory.out, /pass=\d+ fail=0 total=\d+/);
  const oracle = expectSuccess(["comply", "bytes/identity.wasm", "--with", "compliance/preserve-empty.wasm"]);
  assert.match(oracle.out, /PASS bytes\/identity\.wasm --with compliance\/preserve-empty\.wasm \(1 cases\)/);
  assert.match(oracle.out, /pass=2 fail=0 total=2/);
  // A declared rejection is not a trap.
  assert.match(expectSuccess(["comply", "text/utf8-must-be-valid.wasm", "--with", "compliance/reject-invalid-utf8.wasm"]).out,
    /compliance\/reject-invalid-utf8\.wasm \(10 cases\)/);
  assert.match(expectSuccess(["comply", "bytes/identity.wasm", "--with", "test/fixtures/qipx-rust-render-into.wasm"]).out,
    /render-into\.wasm \(1 cases\)/);
  assert.match(expectSuccess(["comply", "--seed", "4217", "text/currency-format-en-us.wasm", "--with", "compliance/currency-format-en-us.comply.wasm"]).out,
    /currency-format-en-us\.comply\.wasm \(\d+ cases\)/);
});

test("qipx hosts report failed Compliance checks only in the summary", () => {
  const trap = expectSame(["comply", "bytes/identity.wasm", "--with", "compliance/trap-empty-input.wasm"]);
  assert.equal(trap.status, 1);
  assert.equal(trap.err, "");
  assert.match(trap.out, /case 0: expected trap, got output/);
  assert.match(trap.out, /pass=1 fail=1 total=2/);
  // Oracles resolve before any file is checked, so a missing one fails once.
  const missing = expectFailure(["comply", "text/hello.wasm", "--with", "missing-oracle.wasm"], /^qipx: missing-oracle\.wasm is unavailable from every source\n$/);
  assert.equal(missing.out, "");
  expectFailure(["comply", "text/hello.wasm", "--with", "README.md"], /^qipx: README\.md is not a WebAssembly binary module\n$/);
});

test("qipx hosts do not follow symlinks found during Compliance scans", { skip: process.platform === "win32" }, () => {
  withTemporaryDirectory("scan", (directory) => withTemporaryDirectory("outside", (outside) => {
    const components = join(directory, "components");
    mkdirSync(components);
    writeFileSync(join(components, "identity.wasm"), readFileSync("bytes/identity.wasm"));
    writeFileSync(join(outside, "unexpected.wasm"), "invalid Wasm");
    symlinkSync(".", join(components, "loop"), "dir");
    symlinkSync(outside, join(components, "outside"), "dir");
    assert.equal(expectSuccess(["comply", "components"], { cwd: directory }).out,
      "PASS components/identity.wasm\n\npass=1 fail=0 total=1\n");
  }));
});

test("qipx hosts reject misleading remote filenames", () => {
  withTemporaryDirectory("path", (directory) => {
    for (const path of ["safe‮msaw.wasm", "evil:stream.wasm"]) {
      expectFailure(["qip.dev", "run", path], /only missing relative paths ending in \.wasm can be downloaded/, { cwd: directory });
    }
  });
});

test("qipx hosts escape terminal controls in local path reports", () => {
  withTemporaryDirectory("display", (directory) => {
    const report = expectSuccess(["dry", "run", "evil\u001b[31m‮.wasm"], { cwd: directory }).out;
    assert.ok(!report.includes("\u001b") && !report.includes("‮"));
    assert.match(report, /evil\\u\{1b\}\[31m\\u\{202e\}\.wasm/);
    const error = expectFailure(["run", "evil\u001b[31m‮.wasm"], /evil\\u\{1b\}\[31m\\u\{202e\}\.wasm/, { cwd: directory });
    assert.ok(!error.err.includes("\u001b"));
  });
});

test("qipx hosts resolve and cache a missing component over verified HTTPS", { skip: !process.env.QIPX_NETWORK_TESTS }, () => {
  for (const implementation of implementations) {
    withTemporaryDirectory("host", (directory) => {
      const result = run(implementation, ["qip.dev", "run", "bytes/identity.wasm"], { input: Buffer.from("hello"), cwd: directory, timeout: 60000 });
      assert.equal(result.status, 0, `${implementation.name}: ${result.stderr}`);
      assert.equal(result.stdout.toString(), "hello", implementation.name);
      assert.deepEqual(readFileSync(join(directory, "bytes/identity.wasm")), readFileSync("bytes/identity.wasm"), implementation.name);
    });
  }
});

test("qipx hosts reject tui options that need stdin or stdout", () => {
  expectFailure(["tui", "tui/calendar-gregorian.wasm"], /^qipx: tui requires terminal stdin and stdout\n$/);
  expectFailure(["tui", "-o", "out.txt", "missing.wasm"], /^qipx: tui writes only to terminal stdout; remove -o\/--output\n$/);
  expectFailure(["tui", "-i", "-", "missing.wasm"], /^qipx: tui cannot read -i - because stdin carries terminal events\n$/);
  expectFailure(["tui", "-F", "data=<-", "tui/calendar-gregorian.wasm"],
    /^qipx: tui cannot use -F name=@- or name=<- because stdin carries terminal events\n$/, { input: Buffer.from("hello") });
});

test("qipx hosts use empty input for an unused terminal", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    for (const component of ["../../text/hello.wasm", "../../text/hello-c.wasm"]) {
      const { output, exitCode } = runInTerminal(implementation, ["run", component], { cwd: resolve("rust/qipx") });
      assert.equal(exitCode, 0, `${implementation.name}: ${component}`);
      assert.equal(output, "Hello, World\r\n", `${implementation.name}: ${component}`);
    }
  }
});

test("qipx hosts render the same TUI rows at column zero", { skip: process.platform === "win32" }, () => {
  const frames = implementations.map((implementation) => {
    const { output } = runInTerminal(implementation, ["tui", "tui/emoji-finder-old.wasm"], {
      steps: [["Type to filter", ctrlC]],
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
  assert.equal(frames[1], frames[0]);
});

test("qipx hosts handle an arrow key in the TUI", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    const { output, exitCode } = runInTerminal(implementation, ["tui", "tui/calendar-gregorian.wasm"], {
      steps: [["January 2024", downArrow], ["February 2024", ctrlC]],
    });
    assert.equal(exitCode, 0, implementation.name);
    assert.match(output, /February 2024/, implementation.name);
    assert.match(output, /\x1b\[\?1049l/, implementation.name);
  }
});

test("qipx hosts reject unsafe TUI output and restore the screen", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    const { output } = runInTerminal(implementation, ["tui", "test/fixtures/qipx-rust-unsafe-tui.wasm"]);
    assert.match(output, /unsupported CSI sequence/, implementation.name);
    assert.match(output, /\x1b\[\?1049l/, implementation.name);
    assert.doesNotMatch(output, /\x1b\[2J/, implementation.name);
  }
});

test("qipx hosts render a scheduled TUI wake without a key", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    const { output, exitCode } = runInTerminal(implementation, ["tui", "test/fixtures/qipx-rust-wake-tui.wasm"], {
      steps: [["after", ctrlC]],
    });
    assert.equal(exitCode, 0, implementation.name);
    assert.match(output, /before/, implementation.name);
    assert.match(output, /after/, implementation.name);
    assert.match(output, /\x1b\[\?1049l/, implementation.name);
  }
});

test("qipx hosts restore the screen on SIGTERM", { skip: process.platform === "win32" }, () => {
  for (const implementation of implementations) {
    const { output, exitCode } = runInTerminal(implementation, ["tui", "tui/calendar-gregorian.wasm"], {
      steps: [["January 2024", "SIGTERM"]],
    });
    assert.match(output, /\x1b\[\?1049l/, implementation.name);
    assert.equal(exitCode, 143, implementation.name);
  }
});
