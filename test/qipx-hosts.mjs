import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { main } from "../npm/qipx/cli.mjs";

const repository = join(dirname(fileURLToPath(import.meta.url)), "..");
const trimWasm = await readFile(join(repository, "text/trim.wasm"));
const identityWasm = await readFile(join(repository, "bytes/identity.wasm"));
const debuggerWasm = await readFile(join(repository, "components/interactive/qipdb.wasm"));
const validUTF8Wasm = await readFile(join(repository, "text/utf8-must-be-valid.wasm"));
const rejectInvalidUTF8Wasm = await readFile(join(repository, "compliance/reject-invalid-utf8.wasm"));

async function inTemporaryDirectory(run) {
  const previousDirectory = process.cwd();
  const directory = await mkdtemp(join(tmpdir(), "qipx-hosts-"));
  process.chdir(directory);
  try {
    return await run(directory);
  } finally {
    process.chdir(previousDirectory);
    await rm(directory, { recursive: true, force: true });
  }
}

async function withFetch(mock, run) {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = mock;
  try {
    return await run();
  } finally {
    globalThis.fetch = previousFetch;
  }
}

async function withConsoleLog(run) {
  const previousLog = console.log;
  const lines = [];
  console.log = (...values) => lines.push(values.join(" "));
  try {
    await run();
  } finally {
    console.log = previousLog;
  }
  return lines.join("\n");
}

test("qipx plans hosts without network access during dry run", async () => {
  await inTemporaryDirectory(async () => {
    let requests = 0;
    const output = await withFetch(async () => {
      requests += 1;
      throw new Error("dry run requested the network");
    }, () => withConsoleLog(() => main([
      "QIP.DEV",
      "mirror.example:8443",
      "dry",
      "run",
      "-F", "component=@targets/debug-me.wasm",
      "-F", "input=hello",
      "text/markdown/to-html.wasm",
    ])));

    assert.equal(requests, 0);
    assert.match(output, /https:\/\/qip\.dev\/text\/markdown\/to-html\.wasm/);
    assert.match(output, /https:\/\/mirror\.example:8443\/text\/markdown\/to-html\.wasm/);
    assert.match(output, /Multipart files:/);
    assert.match(output, /Field "component": targets\/debug-me\.wasm/);
    assert.match(output, /https:\/\/qip\.dev\/targets\/debug-me\.wasm  unexamined/);
    assert.match(output, /targets\/debug-me\.wasm  missing/);
    assert.match(output, /0  missing/);
    assert.match(output, /1  unexamined/);
    assert.match(output, /Validation:[\s\S]*deferred \(local file missing\)/);
    await assert.rejects(readFile("text/markdown/to-html.wasm"), { code: "ENOENT" });
    await assert.rejects(readFile("targets/debug-me.wasm"), { code: "ENOENT" });
  });
});

test("qipx dry run observes multipart paths without reading their contents", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("trim.wasm", trimWasm);
    await mkdir("target.wasm");
    const output = await withFetch(async () => {
      throw new Error("dry run requested the network");
    }, () => withConsoleLog(() => main([
      "qip.dev",
      "dry",
      "run",
      "-F", "component=@target.wasm",
      "trim.wasm",
    ])));
    assert.match(output, /target\.wasm  present \(contents not read\)/);
    assert.match(output, /trim\.wasm: valid/);
  });
});

test("qipx falls back, vendors atomically, and then stays local", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("input.txt", "  hello  ");
    const requests = [];
    await withFetch(async (url, options) => {
      requests.push([url, options]);
      if (url.startsWith("https://qip.dev/")) return new Response("missing", { status: 404 });
      return new Response(trimWasm, { status: 200, headers: { "content-length": String(trimWasm.byteLength) } });
    }, () => main([
      "qip.dev",
      "mirror.example",
      "run",
      "-i",
      "input.txt",
      "-o",
      "output.txt",
      "text/trim.wasm",
    ]));

    assert.deepEqual(requests.map(([url]) => url), [
      "https://qip.dev/text/trim.wasm",
      "https://mirror.example/text/trim.wasm",
    ]);
    assert.equal(requests[0][1].redirect, "manual");
    assert.equal(await readFile("output.txt", "utf8"), "hello");
    assert.deepEqual(await readFile("text/trim.wasm"), trimWasm);

    await withFetch(async () => {
      throw new Error("existing local component requested the network");
    }, () => main([
      "qip.dev",
      "run",
      "-i",
      "input.txt",
      "-o",
      "second-output.txt",
      "text/trim.wasm",
    ]));
    assert.equal(await readFile("second-output.txt", "utf8"), "hello");
  });
});

test("qipx resolves missing multipart Wasm files through hosts", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("identity.wasm", identityWasm);
    const requests = [];
    await withFetch(async (url) => {
      requests.push(url);
      return new Response(trimWasm, { status: 200 });
    }, () => main([
      "qip.dev",
      "run",
      "-F", "component=@text/trim.wasm",
      "-o", "form.bin",
      "identity.wasm",
    ]));

    assert.deepEqual(requests, ["https://qip.dev/text/trim.wasm"]);
    assert.deepEqual(await readFile("text/trim.wasm"), trimWasm);
    const form = await readFile("form.bin");
    assert.match(form.toString("latin1"), /name="component"; filename="trim\.wasm"/);
    assert.ok(form.includes(trimWasm));

    await withFetch(async () => {
      throw new Error("existing multipart file requested the network");
    }, () => main([
      "qip.dev",
      "run",
      "-F", "component=@text/trim.wasm",
      "-o", "second-form.bin",
      "identity.wasm",
    ]));
    assert.deepEqual(await readFile("second-form.bin"), form);
  });
});

test("qipx lightly validates remote multipart Wasm without validating local fields", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("identity.wasm", identityWasm);
    await writeFile("local-invalid.wasm", "intentionally malformed");
    await withFetch(async () => {
      throw new Error("local multipart file requested the network");
    }, () => main([
      "qip.dev",
      "run",
      "-F", "component=@local-invalid.wasm",
      "-o", "local-form.bin",
      "identity.wasm",
    ]));
    assert.match((await readFile("local-form.bin")).toString(), /intentionally malformed/);

    const invalidRequests = [];
    await assert.rejects(withFetch(
      async (url) => {
        invalidRequests.push(url);
        return new Response("not Wasm", { status: 200 });
      },
      () => main([
        "qip.dev",
        "mirror.example",
        "run",
        "-F", "component=@remote-invalid.wasm",
        "identity.wasm",
      ]),
    ), /does not have a WebAssembly 1\.0 header/);
    assert.deepEqual(invalidRequests, ["https://qip.dev/remote-invalid.wasm"]);
    await assert.rejects(readFile("remote-invalid.wasm"), { code: "ENOENT" });

    let requests = 0;
    await assert.rejects(withFetch(
      async () => {
        requests += 1;
        return new Response(trimWasm, { status: 200 });
      },
      () => main([
        "qip.dev",
        "run",
        "-F", "component=@../unsafe.wasm",
        "identity.wasm",
      ]),
    ), /read -F component=@\.\.\/unsafe\.wasm/);
    assert.equal(requests, 0);
  });
});

test("qipx tui resolves a missing multipart component before opening the terminal", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("debugger.wasm", debuggerWasm);
    const requests = [];
    await assert.rejects(withFetch(
      async (url) => {
        requests.push(url);
        return new Response(trimWasm, { status: 200 });
      },
      () => main([
        "qip.dev",
        "tui",
        "-F", "component=@text/trim.wasm",
        "debugger.wasm",
      ]),
    ), /requires terminal stdin and stdout/);
    assert.deepEqual(requests, ["https://qip.dev/text/trim.wasm"]);
    assert.deepEqual(await readFile("text/trim.wasm"), trimWasm);
  });
});

test("qipx follows same-origin HTTPS redirects", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("input.txt", "  hello  ");
    const requests = [];
    await withFetch(async (url) => {
      requests.push(url);
      if (requests.length === 1) {
        return new Response(null, {
          status: 302,
          headers: { location: "/text/trim.wasm" },
        });
      }
      return new Response(trimWasm, { status: 200 });
    }, () => main([
      "qip.dev",
      "run",
      "-i",
      "input.txt",
      "-o",
      "output.txt",
      "text/trim.wasm",
    ]));

    assert.deepEqual(requests, [
      "https://qip.dev/text/trim.wasm",
      "https://qip.dev/text/trim.wasm",
    ]);
    assert.equal(await readFile("output.txt", "utf8"), "hello");
    assert.deepEqual(await readFile("text/trim.wasm"), trimWasm);
  });
});

test("qipx rejects redirects outside the source HTTPS origin", async () => {
  await inTemporaryDirectory(async () => {
    await assert.rejects(withFetch(
      async () => new Response(null, {
        status: 302,
        headers: { location: "https://mirror.example/text/trim.wasm" },
      }),
      () => main(["qip.dev", "run", "text/trim.wasm"]),
    ), /redirected outside its HTTPS origin/);
    await assert.rejects(readFile("text/trim.wasm"), { code: "ENOENT" });
  });
});

test("qipx follows no more than two same-origin redirects", async () => {
  await inTemporaryDirectory(async () => {
    const requests = [];
    await assert.rejects(withFetch(async (url) => {
      requests.push(url);
      return new Response(null, {
        status: 302,
        headers: { location: `/redirect-${requests.length}.wasm` },
      });
    }, () => main([
      "qip.dev",
      "run",
      "text/redirect.wasm",
    ])), /exceeded the 2-redirect limit/);
    assert.deepEqual(requests, [
      "https://qip.dev/text/redirect.wasm",
      "https://qip.dev/redirect-1.wasm",
      "https://qip.dev/redirect-2.wasm",
    ]);
  });
});

test("qipx does not fall back after a selected host returns invalid Wasm", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("input.txt", "hello");
    const requests = [];
    await assert.rejects(withFetch(async (url) => {
      requests.push(url);
      return new Response("not wasm", { status: 200 });
    }, () => main([
      "bad.example",
      "unused.example",
      "run",
      "-i",
      "input.txt",
      "text/invalid.wasm",
    ])), /not a WebAssembly binary module/);
    assert.deepEqual(requests, ["https://bad.example/text/invalid.wasm"]);
    await assert.rejects(readFile("text/invalid.wasm"), { code: "ENOENT" });
  });
});

test("qipx rejects downloads larger than 16 MiB without saving them", async () => {
  await inTemporaryDirectory(async () => {
    await assert.rejects(withFetch(
      async () => new Response(trimWasm, {
        status: 200,
        headers: { "content-length": String(16 * 1024 * 1024 + 1) },
      }),
      () => main(["qip.dev", "run", "text/oversized.wasm"]),
    ), /exceeds the 16777216-byte download limit/);
    await assert.rejects(readFile("text/oversized.wasm"), { code: "ENOENT" });
  });
});

test("qipx never replaces an existing local file", async () => {
  await inTemporaryDirectory(async () => {
    await mkdir("text");
    await writeFile("text/local.wasm", "local but invalid");
    let requests = 0;
    await assert.rejects(withFetch(async () => {
      requests += 1;
      return new Response(trimWasm);
    }, () => main(["qip.dev", "run", "text/local.wasm"])), /not a WebAssembly binary module/);
    assert.equal(requests, 0);
    assert.equal(await readFile("text/local.wasm", "utf8"), "local but invalid");
  });
});

test("qipx refuses to vendor through a parent symlink outside the working directory", async () => {
  const outside = await mkdtemp(join(tmpdir(), "qipx-hosts-outside-"));
  try {
    await inTemporaryDirectory(async () => {
      await symlink(outside, "linked", "dir");
      await assert.rejects(withFetch(
        async () => new Response(trimWasm),
        () => main(["qip.dev", "run", "linked/nested/trim.wasm"]),
      ), /refusing to vendor outside the current directory/);
      await assert.rejects(stat(join(outside, "nested")), { code: "ENOENT" });
    });
  } finally {
    await rm(outside, { recursive: true, force: true });
  }
});

test("qipx resolves bench components and comply oracles through the same hosts", async () => {
  await inTemporaryDirectory(async () => {
    await writeFile("input.txt", " hello ");
    const requested = [];
    await withFetch(async (url) => {
      requested.push(url);
      if (url.endsWith("reject-invalid-utf8.wasm")) return new Response(rejectInvalidUTF8Wasm);
      if (url.endsWith("impl/utf8-must-be-valid.wasm")) return new Response(validUTF8Wasm);
      return new Response(trimWasm);
    }, async () => {
      await withConsoleLog(() => main([
        "components.example",
        "bench",
        "-i",
        "input.txt",
        "--runs",
        "1",
        "--warmup",
        "0",
        "bench/trim.wasm",
      ]));
      await withConsoleLog(() => main([
        "components.example",
        "comply",
        "impl/utf8-must-be-valid.wasm",
        "--with",
        "oracles/reject-invalid-utf8.wasm",
      ]));
    });
    assert.deepEqual(requested, [
      "https://components.example/bench/trim.wasm",
      "https://components.example/oracles/reject-invalid-utf8.wasm",
      "https://components.example/impl/utf8-must-be-valid.wasm",
    ]);
  });
});

test("qipx requires a subcommand and rejects unsafe remote paths", async () => {
  await assert.rejects(main(["qip.dev", "text/trim.wasm"]), /requires a subcommand/);
  await assert.rejects(main(["https://qip.dev", "run", "text/trim.wasm"]), /invalid host/);
  await assert.rejects(main(["127.0.0.1", "run", "text/trim.wasm"]), /IP addresses are not supported/);
  await assert.rejects(main(["localhost", "run", "text/trim.wasm"]), /invalid host/);
  await inTemporaryDirectory(() => withFetch(async () => {
    throw new Error("unsafe path requested the network");
  }, () => assert.rejects(
    main(["qip.dev", "run", "../escape.wasm"]),
    /only missing relative paths ending in \.wasm can be downloaded/,
  )));
});
