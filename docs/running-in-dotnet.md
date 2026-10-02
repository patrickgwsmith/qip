# Running QIP in .NET

.NET can run a QIP component with the [Wasmtime NuGet package](https://www.nuget.org/packages/Wasmtime/). The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into a C# string.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use Wasmtime's `Module` and `Instance` APIs. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Create the project

Create a .NET 8 console application and add Wasmtime:

```bash
dotnet new console --framework net8.0 --output markdown-example
cd markdown-example
dotnet add package Wasmtime --version 44.0.0
```

Put the downloaded component next to the project file:

```text
markdown-example/
├── gfm-commonmark.0.31.2.wasm
├── markdown-example.csproj
└── Program.cs
```

## Render Markdown

This example assumes a trusted GFM component that follows the QIP Content contract. Use an artifact you built, tested, or admitted through a controlled process. The function checks caller-controlled input capacity; it does not validate arbitrary Wasm.

Create `Program.cs`. `MarkdownToHtml` returns HTML or throws an exception. The `using` declarations dispose the runtime resources when the program exits.

```csharp
using System.Text;
using Wasmtime;

using var engine = new Engine();
using var module = Module.FromFile(engine, "gfm-commonmark.0.31.2.wasm");
using var linker = new Linker(engine);
using var store = new Store(engine);
var instance = linker.Instantiate(store, module);

string markdown = """
    # Project status

    | Feature | Status |
    | --- | --- |
    | .NET host | Ready |

    - [x] Load the component from disk
    - [x] Render **GFM**
    """;
Console.WriteLine(MarkdownToHtml(markdown, instance));

static string MarkdownToHtml(string markdown, Instance instance)
{
    var memory = instance.GetMemory("memory")
        ?? throw new InvalidOperationException("Component does not export memory");
    var inputPtr = instance.GetFunction<int>("input_ptr")
        ?? throw new InvalidOperationException("Component does not export input_ptr");
    var inputCap = instance.GetFunction<int>("input_utf8_cap")
        ?? throw new InvalidOperationException("Component does not export input_utf8_cap");
    var render = instance.GetFunction<int, long>("render")
        ?? throw new InvalidOperationException("Component does not export render");

    byte[] input = Encoding.UTF8.GetBytes(markdown);
    int capacity = inputCap();
    if (input.Length > capacity)
        throw new ArgumentException($"Markdown input exceeds capacity: {input.Length} > {capacity}");
    input.AsSpan().CopyTo(memory.GetSpan(inputPtr(), input.Length));

    ulong packed = unchecked((ulong)render(input.Length));
    if ((packed >> 63) != 0)
        throw new ArgumentException("Component rejected input");
    int outputSize = unchecked((int)(uint)packed);
    int outputPtr = (int)(packed >> 32);
    return Encoding.UTF8.GetString(memory.GetSpan(outputPtr, outputSize));
}
```

Run it from the project directory:

```bash
dotnet run
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

## How the boundary maps to .NET

The loader is runtime-specific; the QIP calls are not:

1. `Module.FromFile` compiles the WebAssembly Core module from disk.
2. `linker.Instantiate` instantiates it with no imports.
3. .NET encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `Memory.GetSpan` exposes the range at `input_ptr()` so the app can copy in the bytes.
5. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
6. .NET copies the accepted output range and decodes UTF-8.

The code asks for typed delegates such as `Func<int, long>` when resolving
exports. A missing export or mismatched WebAssembly signature therefore fails
before copying input or calling `render`.

This wrapper trusts the known-valid GFM component and checks only the
caller-controlled input size. A host accepting arbitrary Wasm has a different
validation boundary; see [Known And Untrusted
Components](/docs/content-component#known-and-untrusted-components).

The input span is used only before calling `render`. A span returned by Wasmtime may become invalid when WebAssembly runs and grows its memory, so the output is read through a new span after `render` returns.

## Traps and reuse

If `render` traps, Wasmtime throws an exception. Treat that render as failed and
do not read the output buffer; it may contain stale or partial bytes. Discard
that instance and instantiate the module again before another render.

The example renders once. For repeated renders, keep the runtime resources
open and call `MarkdownToHtml` again. Each instance owns mutable memory and
must not receive concurrent calls.

For an ASP.NET application, keep the `Engine` and compiled `Module` in a
factory, then create a store and instance for each scope or pool entry. Do not
share one instance across concurrent requests.

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

```csharp
using System.Diagnostics;

var start = new ProcessStartInfo("qip") { UseShellExecute = false };
foreach (var argument in new[] {
    "run", "--max-memory", "67108864", "--timeout-ms", "1000",
    "--capacities-must-fit", "./component.wasm"
})
    start.ArgumentList.Add(argument);
using var process = Process.Start(start)
    ?? throw new InvalidOperationException("Could not start QIP host");
if (!process.WaitForExit(5000))
{
    process.Kill(entireProcessTree: true);
    throw new TimeoutException("QIP host timed out");
}
if (process.ExitCode != 0)
    throw new InvalidOperationException($"QIP host failed: {process.ExitCode}");
```

The host uses the module's declared content types; this example does not
assume the output is HTML. Contract checks do not prove that the module
performs the intended transform. The memory limit covers Wasm linear memory,
not the whole host process. See [Hard limits](/docs/hard-limits) for the checks
and their limits. Hosting untrusted Wasm in process requires these validation
and resource controls before using the direct call flow.

## When to use something else

Keep ordinary .NET code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP isolates the third-party Markdown renderer from that application authority. Because this component has no imports, it cannot read environment variables, secrets, or files, make network requests, or reach other .NET objects in the process. An ordinary third-party library runs with the application's access to those resources.

Use a normal .NET library when the transform intentionally needs those capabilities and you are prepared to trust it with them. Use a QIP component when the transform can stay behind the UTF-8 input/output boundary and should not inherit the rest of the application's authority.
