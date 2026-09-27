# Running QIP In .NET

.NET can run a QIP component with the [Wasmtime NuGet package](https://www.nuget.org/packages/Wasmtime/). The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into a C# string.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use Wasmtime's `Module` and `Instance` APIs. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Create The Project

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
├── MarkdownRenderer.cs
└── Program.cs
```

## Render Markdown

Create `MarkdownRenderer.cs`:

```csharp
using System.Text;
using Wasmtime;

public sealed class MarkdownRenderer : IDisposable
{
    private const string WasmPath = "gfm-commonmark.0.31.2.wasm";

    private readonly Engine engine = new();
    private readonly Module module;
    private readonly Linker linker;
    private readonly Store store;
    private readonly Wasmtime.Memory memory;
    private readonly Func<int> inputPtr;
    private readonly Func<int> inputCap;
    private readonly Func<int, long> render;

    public MarkdownRenderer()
    {
        module = Module.FromFile(engine, WasmPath);
        linker = new Linker(engine);
        store = new Store(engine);

        var instance = linker.Instantiate(store, module);
        memory = instance.GetMemory("memory")
            ?? throw new InvalidOperationException(
                "Component does not export memory");
        inputPtr = instance.GetFunction<int>("input_ptr")
            ?? throw new InvalidOperationException(
                "Component does not export input_ptr");
        inputCap = instance.GetFunction<int>("input_utf8_cap")
            ?? throw new InvalidOperationException(
                "Component does not export input_utf8_cap");
        render = instance.GetFunction<int, long>("render")
            ?? throw new InvalidOperationException(
                "Component does not export render");
    }

    public string Render(string markdown)
    {
        byte[] source = Encoding.UTF8.GetBytes(markdown);

        int inputCapacity = inputCap();
        if (source.Length > inputCapacity)
        {
            throw new ArgumentException(
                $"Markdown input exceeds component capacity: " +
                $"{source.Length} > {inputCapacity}");
        }

        int inputStart = inputPtr();
        source.AsSpan().CopyTo(
            memory.GetSpan(inputStart, source.Length));

        ulong packed = unchecked((ulong)render(source.Length));
        if ((packed >> 63) != 0)
            throw new ArgumentException("rejected input");
        int outputSize = unchecked((int)(uint)packed);
        int outputStart = (int)((packed >> 32) & 0x7fff_ffffUL);
        return Encoding.UTF8.GetString(
            memory.GetSpan(outputStart, outputSize));
    }

    public void Dispose()
    {
        store.Dispose();
        linker.Dispose();
        module.Dispose();
        engine.Dispose();
    }
}
```

`Program.cs` only needs to construct the renderer and supply application input:

```csharp
using var renderer = new MarkdownRenderer();

string markdown = """
    # Project status

    | Feature | Status |
    | --- | --- |
    | .NET host | Ready |

    - [x] Load the component from disk
    - [x] Render **GFM**
    """;

Console.WriteLine(renderer.Render(markdown));
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

## How The Boundary Maps To .NET

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
during setup rather than at the first render.

This wrapper trusts the known-valid GFM component and checks only the
caller-controlled input size. A host accepting arbitrary Wasm has a different
validation boundary; see [Known And Untrusted
Components](/docs/content-component#known-and-untrusted-components).

The input span is used only before calling `render`. A span returned by Wasmtime may become invalid when WebAssembly runs and grows its memory, so the output is read through a new span after `render` returns.

## Traps And Reuse

If `render` traps, Wasmtime throws an exception. Treat that render as failed and
do not read the output buffer; it may contain stale or partial bytes. Discard
that instance and instantiate the module again before another render.

The class compiles and instantiates the component once, then reuses it until disposal. A `MarkdownRenderer` owns mutable component memory and is not safe to call concurrently.

For an ASP.NET application, extract the `Engine` and compiled `Module` into a singleton factory, then let it create a renderer with its own store and instance for each scope or pool entry. Do not register one `MarkdownRenderer` as a singleton. Scoped renderers or a small instance pool make ownership explicit and avoid synchronization inside each render call.

## When To Use Something Else

Keep ordinary .NET code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP isolates the third-party Markdown renderer from that application authority. Because this component has no imports, it cannot read environment variables, secrets, or files, make network requests, or reach other .NET objects in the process. An ordinary third-party library runs with the application's access to those resources.

Use a normal .NET library when the transform intentionally needs those capabilities and you are prepared to trust it with them. Use a QIP component when the transform can stay behind the UTF-8 input/output boundary and should not inherit the rest of the application's authority.
