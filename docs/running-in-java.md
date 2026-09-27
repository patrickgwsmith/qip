# Running QIP In Java

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
└── src/main/java/MarkdownRenderer.java
```

## Render Markdown

```java
import com.dylibso.chicory.runtime.ExportFunction;
import com.dylibso.chicory.runtime.Instance;
import com.dylibso.chicory.runtime.Memory;
import com.dylibso.chicory.wasm.Parser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

public final class MarkdownRenderer {
    private static final Path WASM_PATH =
            Path.of("gfm-commonmark.0.31.2.wasm");

    private final Memory memory;
    private final ExportFunction inputPtr;
    private final ExportFunction inputCap;
    private final ExportFunction render;

    public MarkdownRenderer() {
        var module = Parser.parse(WASM_PATH.toFile());
        var instance = Instance.builder(module).build();

        memory = instance.exports().memory("memory");
        inputPtr = instance.export("input_ptr");
        inputCap = instance.export("input_utf8_cap");
        render = instance.export("render");
    }

    private static int callI32(ExportFunction function, long... arguments) {
        return (int) function.apply(arguments)[0];
    }

    public String markdownToHtml(String markdown) {
        byte[] source = markdown.getBytes(StandardCharsets.UTF_8);

        int inputCapacity = callI32(inputCap);
        if (source.length > inputCapacity) {
            throw new IllegalArgumentException(
                    "Markdown input exceeds component capacity: "
                            + source.length + " > " + inputCapacity);
        }

        int inputStart = callI32(inputPtr);
        memory.write(inputStart, source);

        long packed = render.apply(source.length)[0];
        if (packed < 0) throw new IllegalArgumentException("rejected input");
        int outputSize = (int) packed;
        int outputStart = (int) ((packed >>> 32) & 0x7fff_ffffL);
        byte[] output = memory.readBytes(outputStart, outputSize);
        return new String(output, StandardCharsets.UTF_8);
    }

    public static void main(String[] args) {
        var renderer = new MarkdownRenderer();

        String markdown = """
                # Project status

                | Feature | Status |
                | --- | --- |
                | Java host | Ready |

                - [x] Load the component from disk
                - [x] Render **GFM**
                """;

        System.out.println(renderer.markdownToHtml(markdown));
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

## How The Boundary Maps To Java

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

## Traps And Reuse

If `render` traps, Chicory throws an exception. Treat that render as failed and
do not read the output buffer; it may contain stale or partial bytes. Discard
that instance and instantiate the module again before another render.

The example parses and instantiates the component once, then reuses it. A `MarkdownRenderer` owns mutable component memory and is not safe to call concurrently. Create one renderer per worker thread, request, or pool entry instead of sharing an instance. The application can then choose instance ownership that matches its concurrency model without paying for synchronization inside every render call.

Chicory's default interpreter keeps setup small. It also offers runtime and build-time compilation when profiling shows that interpretation is the bottleneck; those modes add build or startup work and are separate from the QIP contract.

## When To Use Something Else

Keep ordinary Java code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step. If the transform needs Java objects, callbacks, or framework services throughout its execution, a normal Java library will usually be simpler.
