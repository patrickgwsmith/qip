package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const (
	nodeBenchRequestMagic  = "QIPNODE1"
	nodeBenchResponseMagic = "QIPNODER"
)

type nodeBenchWireSample struct {
	TotalMS float64 `json:"total_ms"`
	RunMS   float64 `json:"run_ms"`
}

type nodeBenchWireResult struct {
	CompileMS       float64               `json:"compile_ms"`
	InstantiationMS float64               `json:"instantiation_ms"`
	MemoryBytes     uint64                `json:"memory_bytes"`
	InputCapBytes   uint64                `json:"input_cap_bytes"`
	OutputCapBytes  uint64                `json:"output_cap_bytes"`
	Encoding        string                `json:"encoding"`
	Samples         []nodeBenchWireSample `json:"samples"`
}

type nodeBenchWireResponse struct {
	NodeVersion string                `json:"node_version"`
	V8Version   string                `json:"v8_version"`
	Results     []nodeBenchWireResult `json:"results"`
}

type nodeBenchResult struct {
	compileDuration       time.Duration
	instantiationDuration time.Duration
	summary               benchSummary
	sampleCount           int
	inputCapBytes         uint64
	outputCapBytes        uint64
	output                contentData
}

type nodeBenchResponse struct {
	nodeVersion string
	v8Version   string
	results     []nodeBenchResult
}

func durationFromMilliseconds(ms float64) time.Duration {
	return time.Duration(ms * float64(time.Millisecond))
}

func appendNodeBenchUint32(dst *bytes.Buffer, value int) error {
	if value < 0 || uint64(value) > uint64(^uint32(0)) {
		return fmt.Errorf("Node benchmark payload is too large: %d bytes", value)
	}
	return binary.Write(dst, binary.LittleEndian, uint32(value))
}

func buildNodeBenchRequest(moduleBodies [][]byte, input []byte, runs int) ([]byte, error) {
	var request bytes.Buffer
	request.WriteString(nodeBenchRequestMagic)
	if err := appendNodeBenchUint32(&request, runs); err != nil {
		return nil, err
	}
	if err := appendNodeBenchUint32(&request, len(moduleBodies)); err != nil {
		return nil, err
	}
	if err := appendNodeBenchUint32(&request, len(input)); err != nil {
		return nil, err
	}
	request.Write(input)
	for _, body := range moduleBodies {
		if err := appendNodeBenchUint32(&request, len(body)); err != nil {
			return nil, err
		}
		request.Write(body)
	}
	return request.Bytes(), nil
}

func parseNodeBenchResponse(data []byte, moduleCount int) (nodeBenchResponse, error) {
	if len(data) < len(nodeBenchResponseMagic)+4 ||
		string(data[:len(nodeBenchResponseMagic)]) != nodeBenchResponseMagic {
		return nodeBenchResponse{}, errors.New("Node benchmark returned an invalid response")
	}
	offset := len(nodeBenchResponseMagic)
	jsonSize := int(binary.LittleEndian.Uint32(data[offset : offset+4]))
	offset += 4
	if jsonSize > len(data)-offset {
		return nodeBenchResponse{}, errors.New("Node benchmark returned truncated metadata")
	}

	var wire nodeBenchWireResponse
	if err := json.Unmarshal(data[offset:offset+jsonSize], &wire); err != nil {
		return nodeBenchResponse{}, fmt.Errorf("Node benchmark returned invalid metadata: %w", err)
	}
	offset += jsonSize
	if len(wire.Results) != moduleCount {
		return nodeBenchResponse{}, fmt.Errorf(
			"Node benchmark returned %d module results, expected %d",
			len(wire.Results),
			moduleCount,
		)
	}

	response := nodeBenchResponse{
		nodeVersion: wire.NodeVersion,
		v8Version:   wire.V8Version,
		results:     make([]nodeBenchResult, moduleCount),
	}
	for i, result := range wire.Results {
		if len(data)-offset < 4 {
			return nodeBenchResponse{}, errors.New("Node benchmark returned a truncated output header")
		}
		outputSize := int(binary.LittleEndian.Uint32(data[offset : offset+4]))
		offset += 4
		if outputSize > len(data)-offset {
			return nodeBenchResponse{}, errors.New("Node benchmark returned truncated output bytes")
		}
		outputEncoding := dataEncodingRaw
		switch result.Encoding {
		case "raw":
		case "utf8":
			outputEncoding = dataEncodingUTF8
		default:
			return nodeBenchResponse{}, fmt.Errorf(
				"Node benchmark returned unknown output encoding %q",
				result.Encoding,
			)
		}

		samples := make([]benchSample, len(result.Samples))
		for sampleIndex, sample := range result.Samples {
			samples[sampleIndex] = benchSample{
				total:       durationFromMilliseconds(sample.TotalMS),
				run:         durationFromMilliseconds(sample.RunMS),
				memoryBytes: result.MemoryBytes,
			}
		}
		response.results[i] = nodeBenchResult{
			compileDuration:       durationFromMilliseconds(result.CompileMS),
			instantiationDuration: durationFromMilliseconds(result.InstantiationMS),
			summary:               summarizeBench(samples),
			sampleCount:           len(samples),
			inputCapBytes:         result.InputCapBytes,
			outputCapBytes:        result.OutputCapBytes,
			output: contentData{
				bytes:    bytes.Clone(data[offset : offset+outputSize]),
				encoding: outputEncoding,
			},
		}
		offset += outputSize
	}
	if offset != len(data) {
		return nodeBenchResponse{}, errors.New("Node benchmark returned trailing response bytes")
	}
	return response, nil
}

func runNodeBench(
	parent context.Context,
	moduleBodies [][]byte,
	input []byte,
	runs int,
	timeout time.Duration,
) (nodeBenchResponse, error) {
	nodePath, err := exec.LookPath("node")
	if err != nil {
		return nodeBenchResponse{}, errors.New("--node requires the Node.js executable \"node\" on PATH")
	}
	request, err := buildNodeBenchRequest(moduleBodies, input, runs)
	if err != nil {
		return nodeBenchResponse{}, err
	}

	ctx := parent
	cancel := func() {}
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(parent, timeout)
	}
	defer cancel()

	cmd := exec.CommandContext(ctx, nodePath, "--eval", nodeBenchProgram)
	cmd.Stdin = bytes.NewReader(request)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return nodeBenchResponse{}, fmt.Errorf("Node benchmark exceeded its aggregate time limit (%s)", timeout)
		}
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			return nodeBenchResponse{}, fmt.Errorf("Node benchmark failed: %w", err)
		}
		return nodeBenchResponse{}, fmt.Errorf("Node benchmark failed: %s", detail)
	}
	return parseNodeBenchResponse(stdout.Bytes(), len(moduleBodies))
}

func printNodeBenchBenchmarkReport(
	index int,
	modulePath string,
	nodeVersion string,
	v8Version string,
	result nodeBenchResult,
	wazeroSummary benchSummary,
) {
	fmt.Printf("Node.js/V8 %d: %s\n", index, modulePath)
	fmt.Printf("  Time (mean ± stddev): %s ± %s [min: %s, p95: %s, max: %s]\n",
		result.summary.total.mean,
		result.summary.total.stddev,
		result.summary.total.min,
		result.summary.total.p95,
		result.summary.total.max,
	)
	fmt.Printf("  Runtime: Node.js %s, V8 %s\n", nodeVersion, v8Version)
	fmt.Printf("  Boundary: input/output copies plus render on one reused instance\n")
	fmt.Printf("  Breakdown: render mean %s, one instantiation %s, one compile %s\n",
		result.summary.run.mean,
		result.instantiationDuration,
		result.compileDuration,
	)
	fmt.Printf("  Linear memory: %s\n", formatBytesIEC(result.summary.peakMem))
	fmt.Printf("  Capacity: input %s, output %s\n",
		formatBytesIEC(result.inputCapBytes),
		formatBytesIEC(result.outputCapBytes),
	)
	if result.summary.total.mean > 0 && wazeroSummary.total.mean > 0 {
		ratio := float64(wazeroSummary.total.mean) / float64(result.summary.total.mean)
		fmt.Printf(
			"  Observed mean ratio: %.2fx (wazero fresh-instance total / Node reused-instance request)\n",
			ratio,
		)
	}
	fmt.Printf("\n")
}

const nodeBenchProgram = `
"use strict";
const fs = require("node:fs");

const REQUEST_MAGIC = "QIPNODE1";
const RESPONSE_MAGIC = Buffer.from("QIPNODER");
const request = fs.readFileSync(0);
let offset = 0;

function fail(message) {
  throw new Error(message);
}

function take(size) {
  if (!Number.isSafeInteger(size) || size < 0 || size > request.length - offset) {
    fail("truncated benchmark request");
  }
  const value = request.subarray(offset, offset + size);
  offset += size;
  return value;
}

function u32() {
  const value = take(4).readUInt32LE(0);
  return value;
}

if (take(REQUEST_MAGIC.length).toString("ascii") !== REQUEST_MAGIC) {
  fail("invalid benchmark request");
}
const runs = u32();
const moduleCount = u32();
const input = take(u32());
const moduleBytes = [];
for (let i = 0; i < moduleCount; i += 1) moduleBytes.push(take(u32()));
if (offset !== request.length || runs === 0 || moduleCount === 0) {
  fail("invalid benchmark request fields");
}

function exportedI32(exports, name) {
  const value = exports[name];
  if (typeof value !== "function") fail("Wasm module must export " + name + "() -> i32");
  return value() >>> 0;
}

function capacityName(exports, prefix) {
  const utf8 = prefix + "_utf8_cap";
  const bytes = prefix + "_bytes_cap";
  if (exports[utf8] !== undefined) return [utf8, "utf8"];
  if (exports[bytes] !== undefined) return [bytes, "raw"];
  fail("missing " + prefix + " capacity export");
}

function prepare(instance) {
  const exports = instance.exports;
  if (!(exports.memory instanceof WebAssembly.Memory)) fail("missing memory export");
  if (typeof exports.render !== "function") fail("missing render export");
  const [inputCapName] = capacityName(exports, "input");
  const [outputCapName, encoding] = capacityName(exports, "output");
  const inputPointer = exportedI32(exports, "input_ptr");
  const inputCapacity = exportedI32(exports, inputCapName);
  const outputCapacity = exportedI32(exports, outputCapName);
  if (input.length > inputCapacity ||
      inputPointer + input.length > exports.memory.buffer.byteLength) {
    fail("input exceeds component capacity");
  }
  return {
    exports,
    inputPointer,
    inputCapacity,
    outputCapacity,
    encoding,
  };
}

function render(prepared) {
  const { exports } = prepared;
  const memory = new Uint8Array(exports.memory.buffer);
  memory.set(input, prepared.inputPointer);
  const runStart = process.hrtime.bigint();
  const renderResult = exports.render(input.length);
  const runEnd = process.hrtime.bigint();
  if (typeof renderResult !== "bigint") fail("render export must have signature render(i32) -> i64");
  const bits = BigInt.asUintN(64, renderResult);
  if ((bits & (1n << 63n)) !== 0n) fail("rejected input");
  const outputSize = Number(bits & 0xffff_ffffn);
  const outputPointer = Number((bits >> 32n) & 0x7fff_ffffn);
  if (outputSize > prepared.outputCapacity ||
      outputPointer + outputSize > exports.memory.buffer.byteLength) {
    fail("component returned output outside its capacity");
  }
  return {
    runMS: Number(runEnd - runStart) / 1e6,
    output: new Uint8Array(exports.memory.buffer, outputPointer, outputSize).slice(),
  };
}

const compiled = [];
const compileMS = [];
for (const bytes of moduleBytes) {
  const start = process.hrtime.bigint();
  compiled.push(new WebAssembly.Module(bytes));
  compileMS.push(Number(process.hrtime.bigint() - start) / 1e6);
}

const prepared = [];
const instantiationMS = [];
for (const module of compiled) {
  const start = process.hrtime.bigint();
  const instance = new WebAssembly.Instance(module, {});
  instantiationMS.push(Number(process.hrtime.bigint() - start) / 1e6);
  prepared.push(prepare(instance));
}

const outputs = [];
for (let i = 0; i < moduleCount; i += 1) outputs.push(render(prepared[i]).output);
const expectedOutputs = outputs.map((output) => output.slice());

const samples = Array.from({ length: moduleCount }, () => []);
for (let run = 0; run < runs; run += 1) {
  const startIndex = run % moduleCount;
  for (let j = 0; j < moduleCount; j += 1) {
    const moduleIndex = (startIndex + j) % moduleCount;
    const start = process.hrtime.bigint();
    const result = render(prepared[moduleIndex]);
    const totalMS = Number(process.hrtime.bigint() - start) / 1e6;
    if (!Buffer.from(result.output).equals(Buffer.from(expectedOutputs[moduleIndex]))) {
      fail("component output changed between repeated renders");
    }
    outputs[moduleIndex] = result.output;
    samples[moduleIndex].push({ total_ms: totalMS, run_ms: result.runMS });
  }
}

const metadata = {
  node_version: process.versions.node,
  v8_version: process.versions.v8,
  results: prepared.map((item, index) => ({
    compile_ms: compileMS[index],
    instantiation_ms: instantiationMS[index],
    memory_bytes: item.exports.memory.buffer.byteLength,
    input_cap_bytes: item.inputCapacity,
    output_cap_bytes: item.outputCapacity,
    encoding: item.encoding,
    samples: samples[index],
  })),
};
const metadataBytes = Buffer.from(JSON.stringify(metadata));
const responseParts = [RESPONSE_MAGIC, Buffer.allocUnsafe(4), metadataBytes];
responseParts[1].writeUInt32LE(metadataBytes.length, 0);
for (const output of outputs) {
  const header = Buffer.allocUnsafe(4);
  header.writeUInt32LE(output.length, 0);
  responseParts.push(header, Buffer.from(output.buffer, output.byteOffset, output.byteLength));
}
fs.writeFileSync(1, Buffer.concat(responseParts));
`
