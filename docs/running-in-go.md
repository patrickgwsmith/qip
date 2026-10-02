# Running QIP in Go

Go can run a QIP component with [wazero](https://wazero.io/), a WebAssembly runtime written in Go. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into a Go `string`.

wazero is the default choice for Go applications because it does not require CGO, native libraries, or platform-specific package artifacts. The `qip` command-line host uses the same runtime.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use wazero's `Instantiate` API to compile and instantiate the module. QIP components also have no WASI imports, so this example does not instantiate WASI or expose host capabilities.

## Create the module

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

Create `main.go` for a trusted GFM component that you built, tested, or admitted through a controlled artifact process. This example assumes its exports and behavior follow the QIP Content contract. `markdownToHTML` returns the HTML or an error. The `call` helper checks each exported function and returns its single result or an error. Only `main` uses `panic` to stop this command-line example on an error.

```go
package main

import (
	"context"
	"fmt"
	"os"
	"unicode/utf8"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func main() {
	ctx := context.Background()
	config := wazero.NewRuntimeConfig().WithCloseOnContextDone(true)
	runtime := wazero.NewRuntimeWithConfig(ctx, config)
	defer runtime.Close(ctx)

	wasm, err := os.ReadFile("gfm-commonmark.0.31.2.wasm")
	if err != nil {
		panic(err)
	}
	module, err := runtime.Instantiate(ctx, wasm)
	if err != nil {
		panic(err)
	}
	markdown := `# Project status

| Feature | Status |
| --- | --- |
| Go host | Ready |

- [x] Load the component from disk
- [x] Render **GFM**
`
	html, err := markdownToHTML(ctx, module, markdown)
	if err != nil {
		panic(err)
	}
	fmt.Print(html)
}

func markdownToHTML(ctx context.Context, module api.Module, markdown string) (string, error) {
	memory := module.ExportedMemory("memory")
	if memory == nil {
		return "", fmt.Errorf("component does not export memory")
	}
	input := []byte(markdown)
	if !utf8.Valid(input) {
		return "", fmt.Errorf("Markdown input is not valid UTF-8")
	}
	capacity, err := call(ctx, module, "input_utf8_cap")
	if err != nil {
		return "", err
	}
	if uint64(len(input)) > capacity {
		return "", fmt.Errorf("Markdown input exceeds capacity: %d > %d", len(input), capacity)
	}
	inputPtr, err := call(ctx, module, "input_ptr")
	if err != nil {
		return "", err
	}
	if !memory.Write(uint32(inputPtr), input) {
		return "", fmt.Errorf("input range is outside component memory")
	}

	result, err := call(ctx, module, "render", uint64(len(input)))
	if err != nil {
		return "", err
	}
	if result>>63 != 0 {
		return "", fmt.Errorf("component rejected input")
	}
	outputPtr, outputSize := uint32(result>>32), uint32(result)
	output, ok := memory.Read(outputPtr, outputSize)
	if !ok {
		return "", fmt.Errorf("output range is outside component memory")
	}
	if !utf8.Valid(output) {
		return "", fmt.Errorf("component returned invalid UTF-8")
	}
	return string(output), nil
}

// Each QIP function used here returns one value.
func call(ctx context.Context, module api.Module, name string, args ...uint64) (uint64, error) {
	function := module.ExportedFunction(name)
	if function == nil {
		return 0, fmt.Errorf("component does not export %s", name)
	}
	results, err := function.Call(ctx, args...)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", name, err)
	}
	if len(results) != 1 {
		return 0, fmt.Errorf("%s must return one value", name)
	}
	return results[0], nil
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

## How the boundary maps to Go

The loader is runtime-specific; the QIP calls are not:

1. `os.ReadFile` reads the WebAssembly bytes from disk.
2. `Instantiate` validates, compiles, and instantiates the WebAssembly Core module with no imports.
3. Go converts the Markdown to UTF-8 bytes and checks `input_utf8_cap()`.
4. `Memory.Write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns one packed `i64` value.
6. Bit 63 reports rejection. Bits 32 through 62 contain the output pointer, and
   the low 32 bits contain the output size.
7. `Memory.Read` exposes accepted output at the returned pointer, and
   conversion to `string` copies it out of component memory.

Wazero represents the raw `i64` result as `uint64`, so the host can test bit 63
directly. If `render` traps, discard the instance because memory and globals may
contain partial changes.

Converting a Go string to bytes produces valid UTF-8 only when the string itself
contains valid UTF-8; Go strings can also contain arbitrary bytes. A generic
host therefore calls `utf8.Valid` when caller-provided bytes first enter an
`input_utf8_cap` pipeline. It does not repeat that scan between known-valid
components whose output and input both use the UTF-8 exports.

`Memory.Read` returns a view into WebAssembly memory. Do not keep that byte slice across another component call or memory growth. This example validates it and copies it to a string before returning.

The example's output check is a defensive component check. A production
pipeline may rely on `output_utf8_cap`; Compliance and debug hosts can keep the
check to detect a defective component.

The checks above catch invalid input, rejection, traps, and invalid output ranges or UTF-8. They do not validate an arbitrary module's QIP contract or enforce a memory budget. See [Known and untrusted components](/docs/content-component#known-and-untrusted-components).

## Cancellation, concurrency, and reuse

`WithCloseOnContextDone(true)` adds checks that stop WebAssembly when the context passed to `Function.Call` is canceled or reaches its deadline. These checks add some execution overhead. The trusted example uses `context.Background()`, so it has no deadline. Use `context.WithTimeout` when a call must stop after a fixed time.

A canceled call closes its module instance. Create a new instance before rendering again.

The example renders once. For repeated renders, keep the runtime and module open and repeat the input write, render call, and output read. Each instance owns mutable memory: concurrent calls could overwrite another call's input. Serialize access to an instance. For parallel workers, use `CompileModule` once, then `InstantiateModule` to create one instance per worker or pool entry.

wazero uses its compiler backend by default on supported `amd64` and `arm64` hosts and falls back to an interpreter where the compiler is unavailable. Both modes use the same public API.

## Run untrusted Wasm through the QIP host

Core Wasm validation does not establish the QIP contract. For a module whose
exports and behavior you do not trust, use the `qip` CLI from Go. The host
checks the component contract before rendering and validates the returned
output range and capacity. It rejects memory growth by default. Set a memory
limit and an execution timeout explicitly.

Install the Go QIP CLI and put `$(go env GOPATH)/bin` on `PATH`:

```bash
go install github.com/royalicing/qip@latest
```

This separate `main.go` runs a local `component.wasm` with a 64 MiB linear-memory limit and a
one-second execution timeout. The Go context limits the whole subprocess to
five seconds:

```go
package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "qip", "run",
		"--max-memory", "67108864",
		"--timeout-ms", "1000",
		"--capacities-must-fit",
		"./component.wasm",
	)
	cmd.Stdin = strings.NewReader("# Project status\n")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		panic(err)
	}
}
```

This uses the module's declared content types; it does not assume the result
is HTML. Contract checks and timeouts do not prove that the module performs
the intended transform. The memory limit covers Wasm linear memory, not the
whole subprocess. See [Hard limits](/docs/hard-limits) for the checks and their
limits. An application that must host untrusted Wasm in process needs these
validation and resource controls before it can use the direct call flow.

## Why wazero

wazero keeps the Go build operationally simple: no CGO, shared library, Rust toolchain, or per-platform runtime package is required. Cross-compilation remains a normal Go build, and the runtime follows `context.Context` for cancellation.

[Wasmtime Go](https://github.com/bytecodealliance/wasmtime-go) is worth benchmarking when a specific workload is CPU-bound or needs a Wasmtime feature that wazero does not provide. It introduces CGO and native-library build requirements, so measured runtime gains need to justify a more complicated build and deployment path.

## When to use something else

Keep ordinary Go code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step and gives that code no access to the rest of the application.

Use a normal Go package when the transform intentionally needs Go values, callbacks, or application services throughout its execution. Use the `qip` CLI as a subprocess when multiple applications can share one installed host and the process boundary is more useful than low per-call latency.
