# Running QIP in Swift

Swift can run a QIP component with [WasmKit](https://github.com/swiftwasm/WasmKit), a WebAssembly runtime implemented in Swift. The app loads the `.wasm` bytes from its bundle, writes UTF-8 input into component memory, calls `render`, and copies the UTF-8 output back into a `String`.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use WasmKit's `parseWasm` and `Module.instantiate` APIs. QIP components also have no WASI imports, so this example does not add `WasmKitWASI` or expose host capabilities.

## Create the package

This example uses Swift 6.3 and WasmKit 0.3.1:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MarkdownExample",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftwasm/WasmKit.git",
            .upToNextMinor(from: "0.3.1")
        ),
    ],
    targets: [
        .executableTarget(
            name: "MarkdownExample",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
            ],
            resources: [
                .copy("Resources/gfm-commonmark.0.31.2.wasm"),
            ]
        ),
    ]
)
```

WasmKit 0.3.1's package manifest requires Swift 6.3 and declares macOS 15 and iOS 18 as its minimum Apple platforms. Confirm those deployment targets fit the app before adopting this version. Once the example works in your app, keep the resolved version in `Package.resolved`.

Put the component in the target's resources:

```text
markdown-example/
├── Package.swift
└── Sources/MarkdownExample/
    ├── MarkdownExample.swift
    └── Resources/
        └── gfm-commonmark.0.31.2.wasm
```

## Render Markdown

Create `Sources/MarkdownExample/MarkdownExample.swift` for a trusted GFM component that you built, tested, or admitted through a controlled artifact process. This example assumes its exports and behavior follow the QIP Content contract. `markdownToHTML` returns a `String` on success and throws on failure; the caller uses `try`.

```swift
import Foundation
import WasmKit

enum MarkdownRendererError: Error {
    case missingResource
    case missingExport(String)
    case invalidResult(String)
    case rejectedInput
    case inputTooLarge(actual: Int, capacity: Int)
}

func markdownToHTML(_ markdown: String, instance: Instance) throws -> String {
    guard let memory = instance.exports[memory: "memory"] else {
        throw MarkdownRendererError.missingExport("memory")
    }
    guard let render = instance.exports[function: "render"] else {
        throw MarkdownRendererError.missingExport("render")
    }
    let source = Array(markdown.utf8)
    let capacity = try callI32(instance, "input_utf8_cap")

    guard source.count <= capacity else {
        throw MarkdownRendererError.inputTooLarge(actual: source.count, capacity: capacity)
    }

    let inputStart = try callI32(instance, "input_ptr")
    memory.withUnsafeMutableBufferPointer(
        offset: UInt(inputStart),
        count: source.count
    ) { destination in
        source.withUnsafeBytes { sourceBytes in
            destination.copyMemory(from: sourceBytes)
        }
    }

    let results = try render([.i32(UInt32(source.count))])
    guard results.count == 1, case .i64(let packed) = results[0] else {
        throw MarkdownRendererError.invalidResult("render")
    }
    guard packed >> 63 == 0 else {
        throw MarkdownRendererError.rejectedInput
    }
    let outputSize = Int(UInt32(truncatingIfNeeded: packed))
    let outputStart = Int((packed >> 32) & 0x7fff_ffff)

    return memory.withUnsafeBufferPointer(
        offset: UInt(outputStart),
        count: outputSize
    ) { output in
        String(decoding: output.bindMemory(to: UInt8.self), as: UTF8.self)
    }
}

func callI32(_ instance: Instance, _ name: String) throws -> Int {
    guard let function = instance.exports[function: name] else {
        throw MarkdownRendererError.missingExport(name)
    }
    let results = try function([])
    guard results.count == 1, case .i32(let result) = results[0] else {
        throw MarkdownRendererError.invalidResult(name)
    }
    return Int(result)
}

guard let wasmURL = Bundle.module.url(
    forResource: "gfm-commonmark.0.31.2",
    withExtension: "wasm"
) else {
    throw MarkdownRendererError.missingResource
}

let bytes = Array(try Data(contentsOf: wasmURL))
let module = try parseWasm(bytes: bytes)
let store = Store(engine: Engine())
let instance = try module.instantiate(store: store)
let html = try markdownToHTML(
    """
    # Project status

    | Feature | Status |
    | --- | --- |
    | Swift host | Ready |

    - [x] Load the component from the app bundle
    - [x] Render **GFM**
    """,
    instance: instance
)
print(html)
```

Run it from the package directory:

```bash
swift run
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

In an Xcode app target, add the `.wasm` file to the target's Copy Bundle Resources phase and use `Bundle.main` instead of `Bundle.module`.

## How the boundary maps to Swift

The loader is runtime-specific; the QIP calls are not:

1. `Data(contentsOf:)` reads the bundled WebAssembly bytes.
2. `parseWasm` validates and parses the WebAssembly Core module.
3. `module.instantiate` creates an instance with no imports.
4. Swift encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
5. `withUnsafeMutableBufferPointer` copies those bytes to `input_ptr()`.
6. `render(input_size)` returns the rejection bit, output pointer, and size in
   one packed `i64` value.
7. Swift copies the accepted output range into a `String`.

The unsafe buffer pointers do not escape their closures. In particular, the input view is gone before calling `render`; WebAssembly execution may grow memory and invalidate an earlier view.

The function checks input capacity and render rejection. It relies on the trusted component's memory-range and UTF-8 output promises. `String(decoding:as:)` copies the output but replaces invalid UTF-8; it is not a validator. Do not use this direct call flow to validate arbitrary Wasm. See [Known and untrusted components](/docs/content-component#known-and-untrusted-components).

## Traps and reuse

If `render` traps, WasmKit throws a `Trap`. Treat that render as failed and do
not read the output buffer; it may contain stale or partial bytes. Discard that
instance and instantiate the module again before another render.

The example renders once. For repeated renders, keep the store and instance and call `markdownToHTML` again. Each instance owns mutable memory; concurrent calls could overwrite another call's input. Keep an instance on one actor or serial executor, or create one instance per worker or pool entry.

WasmKit is an interpreter. Its Swift implementation and cross-platform packaging keep integration straightforward, but a JIT or ahead-of-time runtime may be faster for sustained high-throughput transforms. Benchmark the actual component and device before adding a more complex runtime bridge.

## Run untrusted Wasm through the QIP host

Core Wasm validation does not establish the QIP contract. On macOS, a separate
example can use the `qip` CLI to check an arbitrary module before rendering.
The host checks the component contract and returned output range and capacity.
It rejects memory growth by default.

Install the Go QIP CLI and put `$(go env GOPATH)/bin` on `PATH`:

```bash
go install github.com/royalicing/qip@latest
```

Save this as `Untrusted.swift`. It reads input from stdin, writes output to
stdout, and throws if the host rejects the module or the render fails. The
limits allow 64 MiB of Wasm linear memory and one second of component execution:

```swift
import Foundation

enum QIPRunError: Error {
    case failed(status: Int32)
}

func runUntrustedComponent(at path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "qip", "run",
        "--max-memory", "67108864",
        "--timeout-ms", "1000",
        "--capacities-must-fit",
        path,
    ]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
        throw QIPRunError.failed(status: process.terminationStatus)
    }
}

try runUntrustedComponent(at: "./component.wasm")
```

Run it with a local component:

```bash
printf '# Project status\n' | swift Untrusted.swift
```

This uses the module's declared content types; it does not assume the output
is HTML. The timeout covers component execution, and the memory limit covers
Wasm linear memory. They do not bound the whole subprocess or prove that the
module performs the intended transform. See [Hard limits](/docs/hard-limits).

`Process` is unavailable on iOS. An iOS app that accepts untrusted Wasm needs
an in-process host that checks the QIP contract and enforces memory and
execution limits before using the direct call flow. WasmKit's unsafe memory
accessors can fail a precondition for an invalid range; they do not return an
error that `markdownToHTML` can catch.

## Wasmtime for maximum performance

When interpreter overhead is measurable, [Wasmtime](https://docs.wasmtime.dev/) can use the optimizing Cranelift compiler to turn WebAssembly into native machine code. That makes it a strong option for high-throughput macOS and server workloads, although the result still needs to be benchmarked against WasmKit with the app's real components and inputs.

Swift integrates with Wasmtime through its [C API](https://docs.wasmtime.dev/c-api/), not a first-party Swift package. The build must provide the headers and a module map, link a static or dynamic Wasmtime library for each target architecture, and wrap the C ownership and error APIs in Swift. Wasmtime publishes prebuilt C API archives, or it can be built from source with CMake or Cargo. Dynamic libraries must also be distributed with the app. Cranelift's JIT and AOT modes require executable memory support, so confirm that the chosen mode fits every deployment platform before standardizing on it.

### iOS is a different runtime decision

Wasmtime lists `aarch64-apple-ios` as a [Tier 3 target](https://docs.wasmtime.dev/stability-tiers.html): it is supported, but does not receive the CI coverage or dedicated maintenance required for a higher tier.

Cranelift and Winch require the host to create executable memory in both JIT and AOT modes. Wasmtime does not currently support statically linking one precompiled module as ordinary native code, so AOT does not turn a QIP component into code that can simply be signed into an iOS app. See Wasmtime's [platform support](https://docs.wasmtime.dev/stability-platform-support.html) for the current compiler and interpreter boundaries.

Wasmtime's Pulley interpreter avoids the native-code compiler requirement and is the plausible Wasmtime configuration on iOS. It also gives up the main performance reason to choose Wasmtime over WasmKit while retaining the C build and integration work.

| Target and priority | Runtime choice |
| --- | --- |
| iOS or iPadOS | WasmKit |
| macOS or server, simpler integration | WasmKit |
| macOS or server, measured CPU bottleneck | Wasmtime with Cranelift |
| iOS where Wasmtime is specifically required | Wasmtime with Pulley, accepting Tier 3 support and additional build work |

Apple's [App Review Guideline 2.5.2](https://developer.apple.com/app-store/review/guidelines/) restricts downloading or executing code that introduces or changes app functionality. Keeping fixed QIP components in the submitted app bundle is a different boundary from downloading new modules after release, but App Review remains the authority for a particular product.

The QIP wrapper does not otherwise change: load a Core module with no imports,
write bytes at `input_ptr()`, call `render`, and read the returned output range.

## When to use something else

Keep ordinary Swift code in charge of networking, persistence, authentication, logging, app lifecycle, and platform APIs. QIP fits the deterministic Markdown-to-HTML step and gives that code no access to the rest of the app.

Use a normal Swift library when the transform intentionally needs app objects, callbacks, or Apple frameworks throughout its execution. Use another WebAssembly runtime when WasmKit's deployment targets or interpreter performance do not fit the product.
