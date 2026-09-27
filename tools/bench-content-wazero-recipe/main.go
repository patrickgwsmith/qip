package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"syscall"
	"time"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

type stage struct {
	module api.Module
}

type summary struct {
	Samples int     `json:"samples"`
	MeanMS  float64 `json:"mean_ms"`
	P50MS   float64 `json:"p50_ms"`
	P95MS   float64 `json:"p95_ms"`
	MaxMS   float64 `json:"max_ms"`
}

func exportedI32(ctx context.Context, module api.Module, name string) (uint32, error) {
	fn := module.ExportedFunction(name)
	if fn == nil {
		return 0, fmt.Errorf("missing i32 export %s", name)
	}
	values, err := fn.Call(ctx)
	if err != nil {
		return 0, err
	}
	return uint32(values[0]), nil
}

func render(ctx context.Context, s stage, input []byte) ([]byte, error) {
	memory := s.module.Memory()
	inputPtr, err := exportedI32(ctx, s.module, "input_ptr")
	if err != nil {
		return nil, err
	}
	if !memory.Write(inputPtr, input) {
		return nil, fmt.Errorf("input write exceeds memory")
	}
	values, err := s.module.ExportedFunction("render").Call(ctx, uint64(len(input)))
	if err != nil {
		return nil, err
	}
	result := values[0]
	if result>>63 != 0 {
		return nil, fmt.Errorf("rejected input")
	}
	outputPtr := uint32((result >> 32) & 0x7fff_ffff)
	outputSize := uint32(result)
	output, ok := memory.Read(outputPtr, outputSize)
	if !ok {
		return nil, fmt.Errorf("output read exceeds memory")
	}
	return output, nil
}

func renderRecipe(ctx context.Context, stages []stage, input []byte) ([]byte, error) {
	var err error
	output := input
	for _, s := range stages {
		output, err = render(ctx, s, output)
		if err != nil {
			return nil, err
		}
	}
	return output, nil
}

func summarize(samples []float64) summary {
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	var sum float64
	for _, sample := range samples {
		sum += sample
	}
	return summary{
		Samples: len(samples),
		MeanMS:  sum / float64(len(samples)),
		P50MS:   sorted[len(sorted)/2],
		P95MS:   sorted[len(sorted)*95/100],
		MaxMS:   sorted[len(sorted)-1],
	}
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: bench-content-wazero-recipe input duration-ms [--warmup N] module.wasm ...")
		os.Exit(2)
	}
	input, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	durationMS, err := strconv.ParseFloat(os.Args[2], 64)
	if err != nil {
		panic(err)
	}
	warmup := 20
	modulePaths := os.Args[3:]
	if len(modulePaths) >= 2 && modulePaths[0] == "--warmup" {
		warmup, err = strconv.Atoi(modulePaths[1])
		if err != nil || warmup < 1 {
			panic("--warmup requires a positive integer")
		}
		modulePaths = modulePaths[2:]
	}
	if len(modulePaths) == 0 {
		panic("at least one module is required")
	}

	ctx := context.Background()
	runtime := wasmruntime.New(ctx)
	defer runtime.Close(ctx)
	stages := make([]stage, 0, len(modulePaths))
	var wasmBytes int
	var linearMemoryBytes uint64
	compileStart := time.Now()
	compiled := make([]wazero.CompiledModule, 0, len(modulePaths))
	for _, path := range modulePaths {
		bytes, readErr := os.ReadFile(path)
		if readErr != nil {
			panic(readErr)
		}
		wasmBytes += len(bytes)
		module, compileErr := runtime.CompileModule(ctx, bytes)
		if compileErr != nil {
			panic(compileErr)
		}
		compiled = append(compiled, module)
	}
	compileMS := float64(time.Since(compileStart).Nanoseconds()) / 1e6
	instantiateStart := time.Now()
	for i, module := range compiled {
		instance, instantiateErr := runtime.InstantiateModule(
			ctx,
			module,
			wazero.NewModuleConfig().WithName(fmt.Sprintf("recipe-step-%d", i+1)),
		)
		if instantiateErr != nil {
			panic(instantiateErr)
		}
		stages = append(stages, stage{module: instance})
		linearMemoryBytes += uint64(instance.Memory().Size())
	}
	instantiateMS := float64(time.Since(instantiateStart).Nanoseconds()) / 1e6
	initialRSSBytes := currentRSS()

	output, err := renderRecipe(ctx, stages, input)
	if err != nil {
		panic(err)
	}
	firstRSSBytes := currentRSS()
	for i := 1; i < warmup; i++ {
		output, err = renderRecipe(ctx, stages, input)
		if err != nil {
			panic(err)
		}
	}
	samples := make([]float64, 0, 1000000)
	deadline := time.Now().Add(time.Duration(durationMS * float64(time.Millisecond)))
	for time.Now().Before(deadline) {
		start := time.Now()
		output, err = renderRecipe(ctx, stages, input)
		if err != nil {
			panic(err)
		}
		samples = append(samples, float64(time.Since(start).Nanoseconds())/1e6)
	}

	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	digest := sha256.Sum256(output)
	result := map[string]any{
		"runtime":             "qip-wazero-warmed-recipe",
		"steps":               len(stages),
		"input_bytes":         len(input),
		"output_bytes":        len(output),
		"output_sha256":       hex.EncodeToString(digest[:]),
		"wasm_bytes":          wasmBytes,
		"linear_memory_bytes": linearMemoryBytes,
		"compile_ms":          compileMS,
		"instantiate_ms":      instantiateMS,
		"initial_rss_bytes":   initialRSSBytes,
		"first_rss_bytes":     firstRSSBytes,
		"final_rss_bytes":     currentRSS(),
		"max_rss_bytes":       usage.Maxrss,
		"warm_recipe":         summarize(samples),
	}
	encoder := json.NewEncoder(os.Stdout)
	if err := encoder.Encode(result); err != nil {
		panic(err)
	}
}
