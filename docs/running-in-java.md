# Running QIP in Java

Java can run a QIP component with [Chicory](https://chicory.dev/), a WebAssembly runtime implemented in Java. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into Java.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use Chicory's `Parser` and `Instance` APIs. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Add Chicory

This Maven dependency provides the interpreter and WebAssembly parser:

```xml
<dependency>
  <groupId>com.dylibso.chicory</groupId>
  <artifactId>runtime</artifactId>
  <version>1.7.5</version>
</dependency>
```

The example uses Java 17. Put the downloaded component in the project root:

```text
markdown-example/
├── gfm-commonmark.0.31.2.wasm
├── pom.xml
└── src/main/java/MarkdownExample.java
```

## Render Markdown

This example assumes a trusted GFM component that follows the QIP Content contract. Use an artifact you built, tested, or admitted through a controlled process. The function checks caller-controlled input capacity; it does not validate arbitrary Wasm.

Create `src/main/java/MarkdownExample.java`. `markdownToHtml` returns HTML or throws an exception; it does not terminate the application itself.

```java
import com.dylibso.chicory.runtime.Instance;
import com.dylibso.chicory.wasm.Parser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

public final class MarkdownExample {
    public static String markdownToHtml(String markdown, Instance instance) {
        var memory = instance.exports().memory("memory");
        byte[] input = markdown.getBytes(StandardCharsets.UTF_8);
        int capacity = (int) instance.export("input_utf8_cap").apply()[0];
        if (input.length > capacity) {
            throw new IllegalArgumentException(
                    "Markdown input exceeds capacity: " + input.length + " > " + capacity);
        }
        int inputPtr = (int) instance.export("input_ptr").apply()[0];
        memory.write(inputPtr, input);

        long packed = instance.export("render").apply(input.length)[0];
        if (packed < 0) throw new IllegalArgumentException("component rejected input");
        int outputSize = (int) packed;
        int outputPtr = (int) (packed >>> 32);
        byte[] output = memory.readBytes(outputPtr, outputSize);
        return new String(output, StandardCharsets.UTF_8);
    }

    public static void main(String[] args) {
        var module = Parser.parse(Path.of("gfm-commonmark.0.31.2.wasm").toFile());
        var instance = Instance.builder(module).build();
        String markdown = """
                # Project status

                | Feature | Status |
                | --- | --- |
                | Java host | Ready |

                - [x] Load the component from disk
                - [x] Render **GFM**
                """;
        System.out.println(markdownToHtml(markdown, instance));
    }
}
```

Run it from the project root:

```bash
mvn compile exec:java -Dexec.mainClass=MarkdownExample
```

The output begins with the rendered HTML:

```html
<h1>Project status</h1>
<table>
<thead>
<tr>
<th>Feature</th>
<th>Status</th>
</tr>
<!-- ... -->
```

## How the boundary maps to Java

The loader is runtime-specific; the QIP calls are not:

1. `Parser.parse` reads the WebAssembly Core module from disk.
2. `Instance.builder(module).build()` instantiates it with no imports.
3. Java encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `memory.write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
6. Java copies the accepted output range and decodes UTF-8.

This wrapper trusts the known-valid GFM component and checks only the
caller-controlled input size. A host accepting arbitrary Wasm has a different
validation boundary; see [Known And Untrusted
Components](/docs/content-component#known-and-untrusted-components).

## Traps and reuse

If `render` traps, Chicory throws an exception. Treat that render as failed and
do not read the output buffer; it may contain stale or partial bytes. Discard
that instance and instantiate the module again before another render.

The example renders once. For repeated renders, keep the instance and call `markdownToHtml` again. Each instance owns mutable memory. Create one instance per worker thread, request, or pool entry, or serialize access to a shared instance.

Chicory's default interpreter keeps setup small. It also offers runtime and build-time compilation when profiling shows that interpretation is the bottleneck; those modes add build or startup work and are separate from the QIP contract.

## Run untrusted Wasm through the QIP host

Core Wasm validation does not establish the QIP contract. Use the `qip` CLI
for a module whose exports and behavior you do not trust. The host checks the
component contract and returned output range and capacity. It rejects memory
growth by default.

Install the Go QIP CLI and put `$(go env GOPATH)/bin` on `PATH`:

```bash
go install github.com/royalicing/qip@latest
```

This separate example runs `./component.wasm`, reads stdin, and writes stdout.
A failed host call raises an error. It allows 64 MiB of Wasm linear memory and
one second of component execution, with a five-second limit on the subprocess:

```java
import java.io.IOException;
import java.util.concurrent.TimeUnit;

public final class Untrusted {
    public static void main(String[] args) throws IOException, InterruptedException {
        var process = new ProcessBuilder(
                "qip", "run", "--max-memory", "67108864", "--timeout-ms", "1000",
                "--capacities-must-fit", "./component.wasm")
                .inheritIO().start();
        if (!process.waitFor(5, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new IOException("QIP host timed out");
        }
        if (process.exitValue() != 0) {
            throw new IOException("QIP host failed: " + process.exitValue());
        }
    }
}
```

The host uses the module's declared content types; this example does not
assume the output is HTML. Contract checks do not prove that the module
performs the intended transform. The memory limit covers Wasm linear memory,
not the whole host process. See [Hard limits](/docs/hard-limits) for the checks
and their limits. Hosting untrusted Wasm in process requires these validation
and resource controls before using the direct call flow.

## When to use something else

Keep ordinary Java code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step. If the transform needs Java objects, callbacks, or framework services throughout its execution, a normal Java library will usually be simpler.
