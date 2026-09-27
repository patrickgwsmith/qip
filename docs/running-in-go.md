# Running QIP In Go

Go can run a QIP component with [wazero](https://wazero.io/), a WebAssembly runtime written in Go. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into a Go `string`.

wazero is the default choice for Go applications because it does not require CGO, native libraries, or platform-specific package artifacts. The `qip` command-line host uses the same runtime.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use wazero's `CompileModule` and `InstantiateModule` APIs. QIP components also have no WASI imports, so this example does not instantiate WASI or expose host capabilities.

## Create The Module

Create a Go module and add wazero. This example pins the version so the setup is reproducible:

```bash
mkdir markdown-example
cd markdown-example
go mod init example.com/markdown-example
go get github.com/tetratelabs/wazero@v1.11.0
```

Put the downloaded component next to the Go source:

```text
markdown-example/
├── go.mod
├── go.sum
├── gfm-commonmark.0.31.2.wasm
└── main.go
```

## Render Markdown

Create `main.go`:

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"unicode/utf8"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type MarkdownRenderer struct {
	runtime   wazero.Runtime
	memory    api.Memory
	inputPtr  api.Function
	inputCap  api.Function
	render    api.Function
}

func NewMarkdownRenderer(
	ctx context.Context,
	wasmPath string,
) (_ *MarkdownRenderer, returnErr error) {
	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		return nil, err
	}

	config := wazero.NewRuntimeConfig().
		WithCloseOnContextDone(true)
	runtime := wazero.NewRuntimeWithConfig(ctx, config)
	defer func() {
		if returnErr != nil {
			_ = runtime.Close(ctx)
		}
	}()

	compiled, err := runtime.CompileModule(ctx, wasm)
	if err != nil {
		return nil, fmt.Errorf("compile component: %w", err)
	}

	module, err := runtime.InstantiateModule(
		ctx,
		compiled,
		wazero.NewModuleConfig().WithName("markdown"),
	)
	if err != nil {
		return nil, fmt.Errorf("instantiate component: %w", err)
	}

	memory := module.ExportedMemory("memory")
	if memory == nil {
		return nil, errors.New("component does not export memory")
	}

	inputPtr, err := exportedFunction(module, "input_ptr")
	if err != nil {
		return nil, err
	}
	inputCap, err := exportedFunction(module, "input_utf8_cap")
	if err != nil {
		return nil, err
	}
	render, err := exportedFunction(module, "render")
	if err != nil {
		return nil, err
	}

	return &MarkdownRenderer{
		runtime:   runtime,
		memory:    memory,
		inputPtr:  inputPtr,
		inputCap:  inputCap,
		render:    render,
	}, nil
}

func (r *MarkdownRenderer) MarkdownToHTML(
	ctx context.Context,
	markdown string,
) (string, error) {
	if !utf8.ValidString(markdown) {
		return "", errors.New("Markdown input is not valid UTF-8")
	}
	source := []byte(markdown)

	capacity, err := callI32(ctx, r.inputCap)
	if err != nil {
		return "", fmt.Errorf("read input capacity: %w", err)
	}
	if uint64(len(source)) > capacity {
		return "", fmt.Errorf(
			"Markdown input exceeds component capacity: %d > %d",
			len(source),
			capacity,
		)
	}

	inputStart, err := callI32(ctx, r.inputPtr)
	if err != nil {
		return "", fmt.Errorf("read input pointer: %w", err)
	}
	if ok := r.memory.Write(uint32(inputStart), source); !ok {
		return "", errors.New("input range is outside component memory")
	}

	results, err := r.render.Call(ctx, uint64(len(source)))
	if err != nil {
		return "", fmt.Errorf("render Markdown: %w", err)
	}
	if len(results) != 1 {
		return "", errors.New("render must return one i64")
	}
	result := results[0]
	if result>>63 != 0 {
		return "", errors.New("rejected input")
	}
	outputSize := uint32(result)
	outputStart := uint32((result >> 32) & 0x7fff_ffff)
	output, ok := r.memory.Read(outputStart, outputSize)
	if !ok {
		return "", errors.New("output range is outside component memory")
	}
	if !utf8.Valid(output) {
		return "", errors.New("component returned invalid UTF-8")
	}

	return string(output), nil
}

func (r *MarkdownRenderer) Close(ctx context.Context) error {
	return r.runtime.Close(ctx)
}

func exportedFunction(
	module api.Module,
	name string,
) (api.Function, error) {
	function := module.ExportedFunction(name)
	if function == nil {
		return nil, fmt.Errorf("component does not export %s", name)
	}
	return function, nil
}

func callI32(
	ctx context.Context,
	function api.Function,
) (uint64, error) {
	results, err := function.Call(ctx)
	if err != nil {
		return 0, err
	}
	if len(results) != 1 {
		return 0, errors.New("function must return one i32")
	}
	return results[0], nil
}

func main() {
	ctx := context.Background()

	renderer, err := NewMarkdownRenderer(
		ctx,
		"gfm-commonmark.0.31.2.wasm",
	)
	if err != nil {
		panic(err)
	}
	defer renderer.Close(ctx)

	markdown := `# Project status

| Feature | Status |
| --- | --- |
| Go host | Ready |

- [x] Load the component from disk
- [x] Render **GFM**
`

	html, err := renderer.MarkdownToHTML(ctx, markdown)
	if err != nil {
		panic(err)
	}
	fmt.Print(html)
}
```

Run it from the module directory:

```bash
go run .
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

## How The Boundary Maps To Go

The loader is runtime-specific; the QIP calls are not:

1. `os.ReadFile` reads the WebAssembly bytes from disk.
2. `CompileModule` validates and compiles the WebAssembly Core module.
3. `InstantiateModule` creates an instance with no imports.
4. Go converts the Markdown to UTF-8 bytes and checks `input_utf8_cap()`.
5. `Memory.Write` copies those bytes to `input_ptr()`.
6. `render(input_size)` returns one packed `i64` value.
7. Bit 63 reports rejection. Bits 32 through 62 contain the output pointer, and
   the low 32 bits contain the output size.
8. `Memory.Read` exposes accepted output at the returned pointer, and
   conversion to `string` copies it out of component memory.

Wazero represents the raw `i64` result as `uint64`, so the host can test bit 63
directly. If `render` traps, discard the instance because memory and globals may
contain partial changes.

Converting a Go string to bytes produces valid UTF-8 only when the string itself
contains valid UTF-8; Go strings can also contain arbitrary bytes. A generic
host therefore calls `utf8.Valid` when caller-provided bytes first enter an
`input_utf8_cap` pipeline. It does not repeat that scan between known-valid
components whose output and input both use the UTF-8 exports.

`Memory.Read` returns a view into WebAssembly memory. Do not keep that byte slice across another component call or memory growth. This example validates it and converts it to a string before returning.

The example's output check is a defensive component check. A production
pipeline may rely on `output_utf8_cap`; Compliance and debug hosts can keep the
check to detect a defective component.

This wrapper trusts the known-valid GFM component and checks only the caller-controlled input size. A host accepting arbitrary Wasm has a different validation boundary; see [Known And Untrusted Components](/docs/content-component#known-and-untrusted-components).

## Cancellation, Concurrency, And Reuse

`WithCloseOnContextDone(true)` adds checks that stop WebAssembly when the context passed to `Function.Call` is canceled or reaches its deadline. This prevents a non-terminating component from occupying a goroutine indefinitely, at the cost of some execution overhead.

A canceled call closes its module instance. Discard that `MarkdownRenderer` and create another instead of trying to reuse it.

The example compiles and instantiates the component once, then reuses it. A `MarkdownRenderer` owns mutable component memory and is not safe for concurrent renders: one goroutine could overwrite another's input before `render` reads it. Serialize access, or compile the module once and create one instance per worker or pool entry.

wazero uses its compiler backend by default on supported `amd64` and `arm64` hosts and falls back to an interpreter where the compiler is unavailable. Both modes use the same public API.

## Why Wazero

wazero keeps the Go build operationally simple: no CGO, shared library, Rust toolchain, or per-platform runtime package is required. Cross-compilation remains a normal Go build, and the runtime follows `context.Context` for cancellation.

[Wasmtime Go](https://github.com/bytecodealliance/wasmtime-go) is worth benchmarking when a specific workload is CPU-bound or needs a Wasmtime feature that wazero does not provide. It introduces CGO and native-library build requirements, so measured runtime gains need to justify a more complicated build and deployment path.

## When To Use Something Else

Keep ordinary Go code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step and gives that code no access to the rest of the application.

Use a normal Go package when the transform intentionally needs Go values, callbacks, or application services throughout its execution. Use the `qip` CLI as a subprocess when multiple applications can share one installed host and the process boundary is more useful than low per-call latency.
