package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type stageKind uint8

const (
	stageKindRun stageKind = iota
	stageKindTile
)

// ComponentInvocation describes user intent: resolve this component source
// and run it with these uniform values.
type ComponentInvocation struct {
	Source        string
	UniformValues map[string]string
}

// ResolvedComponent is the runtime input produced by resolving an invocation
// or by loading a recipe from RouterFileState.
type ResolvedComponent struct {
	Name          string
	WASM          []byte
	UniformValues map[string]string
}

func buildPipeline(ctx context.Context, modules []string, opts options) (*qinternal.Pipeline, error) {
	invocations := make([]ComponentInvocation, len(modules))
	for i, modulePath := range modules {
		invocations[i] = ComponentInvocation{
			Source:        modulePath,
			UniformValues: make(map[string]string),
		}
	}
	return newQIPRuntime(opts).CompileInvocations(ctx, invocations)
}

func buildPipelineFromInvocations(ctx context.Context, invocations []ComponentInvocation, opts options) (*qinternal.Pipeline, error) {
	return newQIPRuntime(opts).CompileInvocations(ctx, invocations)
}

func resolveComponentInvocations(invocations []ComponentInvocation) ([]ResolvedComponent, error) {
	return newQIPRuntime(options{}).ResolveComponents(invocations)
}

func buildPipelineFromResolvedComponents(ctx context.Context, components []ResolvedComponent, opts options) (*qinternal.Pipeline, error) {
	return newQIPRuntime(opts).CompilePipeline(ctx, components)
}

func compileResolvedComponents(ctx context.Context, components []ResolvedComponent, opts options) (*qinternal.Pipeline, error) {
	if len(components) == 0 {
		return &qinternal.Pipeline{}, nil
	}

	runtime := wasmruntime.New(ctx)

	type moduleInfo struct {
		path     string
		body     []byte
		cm       wazero.CompiledModule
		kind     stageKind
		uniforms map[string]string
	}
	infos := make([]moduleInfo, len(components))

	var stages []qinternal.Stage
	cleanup := func() {
		for _, stage := range stages {
			_ = stage.Close(ctx)
		}
		for _, info := range infos {
			if info.cm != nil {
				_ = info.cm.Close(ctx)
			}
		}
		_ = runtime.Close(ctx)
	}

	for i, component := range components {
		if err := logAndValidateModule(component.Name, component.WASM, opts); err != nil {
			cleanup()
			return nil, err
		}
		cm, err := runtime.CompileModule(ctx, component.WASM)
		if err != nil {
			cleanup()
			return nil, fmt.Errorf("wasm module %q could not be compiled: %w", component.Name, err)
		}

		kind := stageKindRun
		if _, ok := cm.ExportedFunctions()["tile_rgba32float_64x64"]; ok {
			kind = stageKindTile
		}
		infos[i] = moduleInfo{path: component.Name, body: component.WASM, cm: cm, kind: kind, uniforms: maps.Clone(component.UniformValues)}
	}

	for i := 0; i < len(infos); {
		info := infos[i]
		if info.kind == stageKindRun {
			driver := &wasmRunDriver{
				runtime:                      runtime,
				compiled:                     info.cm,
				instanceName:                 fmt.Sprintf("stage-%d", i),
				modulePath:                   info.path,
				moduleBody:                   info.body,
				opts:                         opts,
				uniforms:                     info.uniforms,
				allowMissingInputContentType: opts.trustFirstStageContent && i == 0,
			}
			stages = append(stages, &qinternal.RunStage{Driver: driver})
			i++
		} else {
			// Group contiguous tile modules
			var tileDrivers []qinternal.TileModuleDriver
			for i < len(infos) && infos[i].kind == stageKindTile {
				driver := &wasmTileModuleDriver{
					runtime:      runtime,
					compiled:     infos[i].cm,
					instanceName: fmt.Sprintf("tile-%d", i),
					modulePath:   infos[i].path,
					uniforms:     infos[i].uniforms,
				}
				// Pre-instantiate to get halo
				if err := driver.init(ctx); err != nil {
					cleanup()
					return nil, err
				}
				tileDrivers = append(tileDrivers, driver)
				i++
			}
			stages = append(stages, &qinternal.TileGroupStage{Drivers: tileDrivers})
		}
	}

	return &qinternal.Pipeline{
		Stages: stages,
		CloseFunc: func(closeCtx context.Context) error {
			return runtime.Close(closeCtx)
		},
	}, nil
}

type wasmRunDriver struct {
	runtime                      wazero.Runtime
	compiled                     wazero.CompiledModule
	instanceName                 string
	modulePath                   string
	moduleBody                   []byte
	opts                         options
	uniforms                     map[string]string
	allowMissingInputContentType bool

	idleMu sync.Mutex
	idle   []api.Module
}

// Instance names must be unique among live modules within a wazero runtime,
// and pipelines are shared across concurrent requests, so each execution gets
// its own name.
var wasmRunInstanceCounter atomic.Uint64

func (d *wasmRunDriver) Execute(ctx context.Context, input qinternal.Content, requestID uint64) (qinternal.Content, error) {
	inputBytes, err := qinternal.AsRawBytes(input)
	if err != nil {
		bmp, bmpErr := qinternal.ToBMPContent(input)
		if bmpErr != nil {
			return nil, err
		}
		inputBytes = bmp.RawBytes()
	}

	instanceName := fmt.Sprintf("%s-r%d-e%d", d.instanceName, requestID, wasmRunInstanceCounter.Add(1))

	var exec moduleExecutionResult
	if d.opts.reuseInstances {
		exec, err = d.executeOnIdleInstance(ctx, inputBytes, instanceName, qinternal.ContentTypeOf(input))
	} else {
		exec, err = executeModuleWithInput(
			ctx,
			d.runtime,
			d.compiled,
			inputBytes,
			d.opts,
			instanceName,
			d.uniforms,
			qinternal.ContentTypeOf(input),
			d.allowMissingInputContentType,
		)
	}
	if err != nil {
		var renderTrap *contentRenderTrapError
		if d.opts.traceWith != "" && errors.As(err, &renderTrap) {
			traceReport, traceErr := traceRunModuleAfterTrap(ctx, d.opts.traceWith, d.moduleBody, inputBytes, d.opts, instanceName+"-trace", d.uniforms, qinternal.ContentTypeOf(input), d.allowMissingInputContentType)
			if traceErr != nil {
				err = fmt.Errorf("%w\ntrace retry failed: %v", err, traceErr)
			} else if traceReport != "" {
				err = fmt.Errorf("%w\ntrace retry with %s:\n%s", err, d.opts.traceWith, traceReport)
			}
		}
		return nil, err
	}

	switch exec.output.encoding {
	case dataEncodingUTF8:
		return qinternal.NewStringContentWithType(string(exec.output.bytes), exec.outputContentType), nil
	default:
		// Check if it's a BMP
		if w, h, err := qinternal.GetBMPDimensions(exec.output.bytes); err == nil {
			return qinternal.NewBMPContentWithType(exec.output.bytes, w, h, exec.outputContentType), nil
		}
		return qinternal.NewRawBytesContentWithType(exec.output.bytes, exec.outputContentType), nil
	}
}

// executeOnIdleInstance renders on an instance left by an earlier render,
// instantiating one if none is idle. Instantiation allocates and zeroes the
// module's whole declared memory, which for a whole-site WARC recipe is
// hundreds of megabytes, so reuse matters when one stage renders many times.
// An instance returns to the idle list only after a successful render.
func (d *wasmRunDriver) executeOnIdleInstance(ctx context.Context, inputBytes []byte, instanceName string, incomingContentType string) (moduleExecutionResult, error) {
	start := time.Now()
	var exec moduleExecutionResult
	d.idleMu.Lock()
	var mod api.Module
	if n := len(d.idle); n > 0 {
		mod = d.idle[n-1]
		d.idle = d.idle[:n-1]
	}
	d.idleMu.Unlock()
	if mod == nil {
		var err error
		mod, err = d.runtime.InstantiateModule(ctx, d.compiled, wazero.NewModuleConfig().WithName(instanceName))
		if err != nil {
			return exec, errors.New("Wasm module could not be instantiated")
		}
		if err := applyModuleUniforms(ctx, mod, d.uniforms); err != nil {
			_ = mod.Close(ctx)
			return exec, err
		}
		exec.instantiation = time.Since(start)
	}
	exec, err := renderModuleInstance(ctx, mod, inputBytes, d.opts, d.modulePath, incomingContentType, d.allowMissingInputContentType, exec)
	exec.total = time.Since(start)
	if err != nil {
		_ = mod.Close(ctx)
		return exec, err
	}
	d.idleMu.Lock()
	d.idle = append(d.idle, mod)
	d.idleMu.Unlock()
	return exec, nil
}

func (d *wasmRunDriver) Label() string {
	return d.modulePath
}

func (d *wasmRunDriver) Close(ctx context.Context) error {
	d.idleMu.Lock()
	idle := d.idle
	d.idle = nil
	d.idleMu.Unlock()
	for _, mod := range idle {
		_ = mod.Close(ctx)
	}
	return d.compiled.Close(ctx)
}

type traceEventKind string

const (
	traceEventBeforeLoad  traceEventKind = "before_load"
	traceEventBeforeStore traceEventKind = "before_store"
	traceEventAfterStore  traceEventKind = "after_store"
)

type traceEvent struct {
	kind        traceEventKind
	funcID      uint32
	opID        uint32
	memoryIndex uint32
	addr        uint32
	width       uint32
	inBounds    bool
	bytes       []byte
}

type wasmMemoryTrace struct {
	events []traceEvent
	limit  int
}

func (t *wasmMemoryTrace) record(kind traceEventKind, mod api.Module, funcID, opID, memoryIndex, addr, width uint32) {
	if t.limit <= 0 {
		t.limit = 256
	}
	event := traceEvent{
		kind:        kind,
		funcID:      funcID,
		opID:        opID,
		memoryIndex: memoryIndex,
		addr:        addr,
		width:       width,
	}
	if memoryIndex == 0 && width > 0 {
		if mem := mod.Memory(); mem != nil {
			if bytes, ok := mem.Read(addr, width); ok {
				event.inBounds = true
				event.bytes = slices.Clone(bytes)
			}
		}
	}
	if len(t.events) >= t.limit {
		copy(t.events, t.events[1:])
		t.events[len(t.events)-1] = event
		return
	}
	t.events = append(t.events, event)
}

func (t *wasmMemoryTrace) format(runErr error) string {
	var b strings.Builder
	if runErr != nil {
		fmt.Fprintf(&b, "instrumented retry trapped: %v\n", runErr)
	} else {
		b.WriteString("instrumented retry completed without trapping\n")
	}
	if len(t.events) == 0 {
		b.WriteString("  no memory trace events recorded")
		return b.String()
	}

	const maxLines = 16
	start := 0
	if len(t.events) > maxLines {
		start = len(t.events) - maxLines
		fmt.Fprintf(&b, "  ... %d earlier memory events omitted\n", start)
	}
	for _, event := range t.events[start:] {
		fmt.Fprintf(&b, "  %s func=%d op=%d mem=%d addr=0x%08x width=%d", event.kind, event.funcID, event.opID, event.memoryIndex, event.addr, event.width)
		if event.inBounds {
			fmt.Fprintf(&b, " bytes=%x", event.bytes)
		} else {
			b.WriteString(" bytes=<out-of-bounds>")
		}
		b.WriteByte('\n')
	}
	return strings.TrimRight(b.String(), "\n")
}

func traceRunModuleAfterTrap(ctx context.Context, traceWith string, originalModule []byte, inputBytes []byte, opts options, moduleName string, uniforms map[string]string, incomingContentType string, allowMissingInputContentType bool) (string, error) {
	instrumented, err := runTraceInstrumenter(ctx, traceWith, originalModule, opts)
	if err != nil {
		return "", err
	}

	traceRuntime := wasmruntime.New(ctx)
	defer traceRuntime.Close(context.Background())

	trace := &wasmMemoryTrace{limit: 256}
	traceHost, err := instantiateTraceHost(ctx, traceRuntime, trace)
	if err != nil {
		return "", err
	}
	defer traceHost.Close(ctx)

	compiled, err := traceRuntime.CompileModule(ctx, instrumented)
	if err != nil {
		return "", fmt.Errorf("instrumented Wasm could not be compiled: %w", err)
	}
	defer compiled.Close(ctx)

	_, runErr := executeModuleWithInput(
		ctx,
		traceRuntime,
		compiled,
		inputBytes,
		opts,
		moduleName,
		uniforms,
		incomingContentType,
		allowMissingInputContentType,
	)
	return trace.format(runErr), nil
}

func runTraceInstrumenter(ctx context.Context, traceWith string, originalModule []byte, opts options) ([]byte, error) {
	body, err := readModulePath(traceWith, opts)
	if err != nil {
		return nil, err
	}

	traceRuntime := wasmruntime.New(ctx)
	defer traceRuntime.Close(context.Background())

	compiled, err := traceRuntime.CompileModule(ctx, body)
	if err != nil {
		return nil, fmt.Errorf("trace instrumenter %q could not be compiled: %w", traceWith, err)
	}
	defer compiled.Close(ctx)

	exec, err := executeModuleWithInput(
		ctx,
		traceRuntime,
		compiled,
		originalModule,
		opts,
		"trace-instrumenter",
		nil,
		"application/wasm",
		false,
	)
	if err != nil {
		return nil, fmt.Errorf("trace instrumenter %q failed: %w", traceWith, err)
	}
	if exec.output.encoding != dataEncodingRaw {
		return nil, fmt.Errorf("trace instrumenter %q must output application/wasm bytes", traceWith)
	}
	if exec.outputContentType != "" && exec.outputContentType != "application/wasm" {
		return nil, fmt.Errorf("trace instrumenter %q output content type %q, want application/wasm", traceWith, exec.outputContentType)
	}
	return exec.output.bytes, nil
}

func instantiateTraceHost(ctx context.Context, runtime wazero.Runtime, trace *wasmMemoryTrace) (api.Module, error) {
	return runtime.NewHostModuleBuilder("qip_trace").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, funcID, opID, memoryIndex, addr, width uint32) {
			trace.record(traceEventBeforeLoad, mod, funcID, opID, memoryIndex, addr, width)
		}).
		Export("before_load").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, funcID, opID, memoryIndex, addr, width uint32) {
			trace.record(traceEventBeforeStore, mod, funcID, opID, memoryIndex, addr, width)
		}).
		Export("before_store").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, mod api.Module, funcID, opID, memoryIndex, addr, width uint32) {
			trace.record(traceEventAfterStore, mod, funcID, opID, memoryIndex, addr, width)
		}).
		Export("after_store").
		Instantiate(ctx)
}

type wasmTileModuleDriver struct {
	runtime      wazero.Runtime
	compiled     wazero.CompiledModule
	instanceName string
	modulePath   string
	uniforms     map[string]string

	mod         api.Module
	tileFunc    api.Function
	uniformFunc api.Function
	inputPtr    uint32
	inputCap    uint64
	haloPx      int
}

func (d *wasmTileModuleDriver) init(ctx context.Context) error {
	mod, err := d.runtime.InstantiateModule(ctx, d.compiled, wazero.NewModuleConfig().WithName(d.instanceName))
	if err != nil {
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}
	d.mod = mod

	stage, err := loadTileStage(ctx, mod)
	if err != nil {
		mod.Close(ctx)
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}

	if err := applyModuleUniforms(ctx, mod, d.uniforms); err != nil {
		mod.Close(ctx)
		return fmt.Errorf("%s: %w", d.modulePath, err)
	}

	d.tileFunc = stage.tileFunc
	d.uniformFunc = stage.uniformFunc
	d.inputPtr = stage.inputPtr
	d.inputCap = stage.inputCap
	if stage.haloFunc != nil {
		values, err := stage.haloFunc.Call(ctx)
		if err != nil {
			mod.Close(ctx)
			return fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
		}
		if len(values) > 0 {
			d.haloPx = int(int32(values[0]))
		}
	}
	if d.haloPx < 0 {
		d.haloPx = 0
	}
	return nil
}

func (d *wasmTileModuleDriver) ExecuteTile(ctx context.Context, x, y float32, tilePixels []float32) ([]float32, error) {
	// Convert float32 pixels to bytes for Wasm
	pixelBytes := unsafe.Slice((*byte)(unsafe.Pointer(&tilePixels[0])), len(tilePixels)*4)
	if uint64(len(pixelBytes)) > d.inputCap {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("tile too large for Wasm module capacity"))
	}

	mem := d.mod.Memory()
	if !mem.Write(d.inputPtr, pixelBytes) {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("failed to write tile to Wasm memory"))
	}

	if _, err := d.tileFunc.Call(ctx, api.EncodeF32(x), api.EncodeF32(y)); err != nil {
		return nil, fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
	}

	outBytes, ok := mem.Read(d.inputPtr, uint32(len(pixelBytes)))
	if !ok {
		return nil, fmt.Errorf("%s: %w", d.modulePath, errors.New("failed to read tile from Wasm memory"))
	}

	// Copy back to float32 slice
	outPixels := make([]float32, len(tilePixels))
	copy(unsafe.Slice((*byte)(unsafe.Pointer(&outPixels[0])), len(outPixels)*4), outBytes)
	return outPixels, nil
}

func (d *wasmTileModuleDriver) Label() string {
	return d.modulePath
}

func (d *wasmTileModuleDriver) Close(ctx context.Context) error {
	if d.mod != nil {
		d.mod.Close(ctx)
	}
	return d.compiled.Close(ctx)
}

func (d *wasmTileModuleDriver) HaloPx() int {
	return d.haloPx
}

func (d *wasmTileModuleDriver) SetImageSize(ctx context.Context, width, height int) error {
	if d.uniformFunc == nil {
		return nil
	}
	if _, err := d.uniformFunc.Call(
		ctx,
		api.EncodeF32(float32(width)),
		api.EncodeF32(float32(height)),
	); err != nil {
		return fmt.Errorf("%s: %w", d.modulePath, wasmruntime.HumanizeExecutionError(ctx, err))
	}
	return nil
}
