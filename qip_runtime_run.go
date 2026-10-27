package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"mime"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

func getExportedValue(ctx context.Context, mod api.Module, name string) (uint64, bool, error) {
	fn := mod.ExportedFunction(name)
	if fn == nil {
		if mod.ExportedGlobal(name) != nil {
			return 0, true, fmt.Errorf("Wasm module must export %s() -> i32", name)
		}
		return 0, false, nil
	}
	params := fn.Definition().ParamTypes()
	results := fn.Definition().ResultTypes()
	if len(params) != 0 || len(results) != 1 || results[0] != api.ValueTypeI32 {
		return 0, true, fmt.Errorf("Wasm module must export %s() -> i32", name)
	}
	result, err := fn.Call(ctx)
	if err != nil {
		return 0, true, fmt.Errorf("%s() call failed: %w", name, err)
	}
	return result[0], true, nil
}

func hasExportedValue(mod api.Module, name string) bool {
	return mod.ExportedFunction(name) != nil || mod.ExportedGlobal(name) != nil
}

func normalizeIncomingContentType(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if isCanonicalMultipartFormDataContentType(value) || isCanonicalMultipartRelatedContentType(value) {
		return value
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err == nil && mediaType != "" {
		return strings.ToLower(mediaType)
	}
	if cut := strings.IndexByte(value, ';'); cut != -1 {
		value = strings.TrimSpace(value[:cut])
	}
	return strings.ToLower(value)
}

const multipartFormDataContentTypePrefix = "multipart/form-data;boundary=uuid-"

func isCanonicalMultipartFormDataContentType(value string) bool {
	uuid, ok := strings.CutPrefix(value, multipartFormDataContentTypePrefix)
	return ok && isCanonicalBoundaryUUID(uuid)
}

// isCanonicalBoundaryUUID reports whether uuid is a canonical lowercase 8-4-4-4-12 UUID.
func isCanonicalBoundaryUUID(uuid string) bool {
	if len(uuid) != 36 {
		return false
	}
	for i := range uuid {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if uuid[i] != '-' {
				return false
			}
			continue
		}
		if !((uuid[i] >= '0' && uuid[i] <= '9') || (uuid[i] >= 'a' && uuid[i] <= 'f')) {
			return false
		}
	}
	return true
}

func validateDeclaredContentType(value string) (string, error) {
	if value == "" {
		return "", errors.New("content type is empty")
	}
	if strings.TrimSpace(value) != value {
		return "", fmt.Errorf("content type %q must not include leading or trailing whitespace", value)
	}
	if strings.Contains(value, ",") {
		return "", errors.New("content type must contain exactly one MIME type")
	}
	if isCanonicalMultipartFormDataContentType(value) || isCanonicalMultipartRelatedContentType(value) {
		return value, nil
	}
	mediaType, _, err := mime.ParseMediaType(value)
	if err != nil {
		return "", fmt.Errorf("invalid content type %q: %w", value, err)
	}
	if mediaType == "" {
		return "", errors.New("content type is empty")
	}
	if strings.Contains(mediaType, "*") {
		return "", fmt.Errorf("content type %q must not include media ranges", value)
	}
	if mediaType == "multipart/form-data" {
		return "", fmt.Errorf("content type %q must use the canonical multipart/form-data boundary form", value)
	}
	if mediaType == "multipart/related" {
		return "", fmt.Errorf("content type %q must use the canonical multipart/related form multipart/related;type=\"<type>/<subtype>\";boundary=uuid-<uuid>", value)
	}
	// Canonical form: the lowercase media type, then each parameter as ";name=value" with no
	// whitespace anywhere. Parameter names are case-insensitive but declared once in their
	// specification's spelling; values are case-sensitive and kept verbatim, for example
	// "image/ktx2;vkFormat=R32G32B32A32_SFLOAT;colorPrimaries=BT709;transferFunction=LINEAR".
	segments := strings.Split(value, ";")
	if segments[0] != mediaType {
		return "", fmt.Errorf("content type %q must begin with the lowercase media type %q", value, mediaType)
	}
	for _, parameter := range segments[1:] {
		name, parameterValue, ok := strings.Cut(parameter, "=")
		if !ok || name == "" || parameterValue == "" || strings.ContainsAny(parameter, " \t\"") {
			return "", fmt.Errorf("content type %q parameter %q must be name=value without whitespace or quotes", value, parameter)
		}
	}
	return value, nil
}

// declaredContentTypeAccepts reports whether an incoming content type satisfies a module's
// declared one. Media types must match; a parameter the module declares must match when the
// incoming type also carries it, and is not required otherwise. Values compare verbatim.
func declaredContentTypeAccepts(declared, incoming string) error {
	if mismatch := contentTypeMismatch(declared, incoming); mismatch != "" {
		return fmt.Errorf("expected %s, got %s: %s", declared, incomingForMessage(declared, incoming), mismatch)
	}
	return nil
}

// incomingForMessage renders the incoming type for an "expected A, got B" message. When both
// share the media type only the incoming parameters are shown, since repeating the media type
// adds nothing; otherwise the whole incoming type is shown.
func incomingForMessage(declared, incoming string) string {
	declaredType, _, _ := strings.Cut(declared, ";")
	incomingType, _, _ := strings.Cut(incoming, ";")
	if !strings.EqualFold(strings.TrimSpace(declaredType), strings.TrimSpace(incomingType)) {
		return incoming
	}
	if cut := strings.IndexByte(incoming, ';'); cut != -1 {
		return strings.TrimSpace(incoming[cut+1:])
	}
	return incoming
}

// contentTypeMismatch explains why incoming does not satisfy declared, or returns "" when it
// does: the media types differ, or every parameter both declare with different values. The
// wording is shared across QIP hosts.
func contentTypeMismatch(declared, incoming string) string {
	declaredType, declaredParams, err := mime.ParseMediaType(declared)
	if err != nil {
		declaredType, declaredParams = normalizeIncomingContentType(declared), nil
	}
	incomingType, incomingParams, err := mime.ParseMediaType(incoming)
	if err != nil {
		incomingType, incomingParams = normalizeIncomingContentType(incoming), nil
	}
	if incomingType != declaredType {
		return fmt.Sprintf("media type expected %s got %s", declaredType, incomingType)
	}
	// Report in declared order with the declared spelling, so messages read the same as
	// the other QIP hosts' and show `vkFormat` rather than `vkformat`.
	var details []string
	for _, shown := range declaredParameterNames(declared) {
		name := strings.ToLower(shown)
		if got, ok := incomingParams[name]; ok && got != declaredParams[name] {
			details = append(details, fmt.Sprintf("%s expected %s got %s", shown, declaredParams[name], got))
		}
	}
	return strings.Join(details, "; ")
}

// declaredParameterNames lists a content type's parameter names in declared order and spelling.
func declaredParameterNames(contentType string) []string {
	var names []string
	for _, segment := range strings.Split(contentType, ";")[1:] {
		name, _, ok := strings.Cut(segment, "=")
		if ok && strings.TrimSpace(name) != "" {
			names = append(names, strings.TrimSpace(name))
		}
	}
	return names
}

func readOptionalModuleContentType(ctx context.Context, mod api.Module, prefix string) (string, bool, error) {
	ptrName := prefix + "_content_type_ptr"
	sizeName := prefix + "_content_type_size"

	ptr, hasPtr, err := getExportedValue(ctx, mod, ptrName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	size, hasSize, err := getExportedValue(ctx, mod, sizeName)
	if err != nil {
		return "", false, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if hasPtr != hasSize {
		return "", false, fmt.Errorf("module must export both %s and %s together", ptrName, sizeName)
	}
	if !hasPtr {
		return "", false, nil
	}
	if size == 0 {
		return "", false, fmt.Errorf("module export %s must be non-empty when present", sizeName)
	}

	mem := mod.Memory()
	raw, ok := mem.Read(uint32(ptr), uint32(size))
	if !ok {
		return "", false, fmt.Errorf("failed to read %s bytes from module memory", prefix)
	}
	mediaType, err := validateDeclaredContentType(string(raw))
	if err != nil {
		return "", false, fmt.Errorf("invalid %s content type metadata: %w", prefix, err)
	}
	return mediaType, true, nil
}

type runModuleContract struct {
	inputless                    bool
	inputPtr                     uint64
	inputCapBytes                uint64
	inputEncoding                dataEncoding
	hasOutput                    bool
	outputCapBytes               uint64
	outputEncoding               dataEncoding
	declaredInputContentType     string
	hasDeclaredInputContentType  bool
	declaredOutputContentType    string
	hasDeclaredOutputContentType bool
	hasFailure                   bool
	failureModesPerInputOffset   uint32
}

func inspectRunModuleContract(ctx context.Context, mod api.Module) (runModuleContract, error) {
	var contract runModuleContract
	if mod.Memory() == nil {
		return contract, errors.New("Wasm module must export memory")
	}

	renderFunc := mod.ExportedFunction("render")
	if renderFunc == nil {
		return contract, errors.New("Wasm module must export render(i32) -> i64")
	}
	params := renderFunc.Definition().ParamTypes()
	results := renderFunc.Definition().ResultTypes()
	if len(params) != 1 || params[0] != api.ValueTypeI32 || len(results) != 1 || results[0] != api.ValueTypeI64 {
		return contract, errors.New("Wasm module must export render(i32) -> i64")
	}

	failureModes, ok, err := getExportedValue(ctx, mod, "failure_modes_per_input_offset")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if ok {
		contract.hasFailure = true
		contract.failureModesPerInputOffset = uint32(failureModes)
	}

	inputPtr, hasInputPtr, err := getExportedValue(ctx, mod, "input_ptr")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	inputUTF8Cap, hasInputUTF8Cap, err := getExportedValue(ctx, mod, "input_utf8_cap")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	inputBytesCap, hasInputBytesCap, err := getExportedValue(ctx, mod, "input_bytes_cap")
	if err != nil {
		return contract, wasmruntime.HumanizeExecutionError(ctx, err)
	}
	if hasInputPtr {
		if hasInputUTF8Cap == hasInputBytesCap {
			return contract, errors.New("Wasm transform must export exactly one input capacity: input_utf8_cap or input_bytes_cap")
		}
		contract.inputPtr = inputPtr
		if hasInputUTF8Cap {
			contract.inputEncoding = dataEncodingUTF8
			contract.inputCapBytes = inputUTF8Cap
		} else {
			contract.inputEncoding = dataEncodingRaw
			contract.inputCapBytes = inputBytesCap
		}
	} else {
		if hasInputUTF8Cap || hasInputBytesCap {
			return contract, errors.New("inputless generator must not export an input capacity")
		}
		contract.inputless = true
	}

	hasOutputUTF8Cap := hasExportedValue(mod, "output_utf8_cap")
	hasOutputBytesCap := hasExportedValue(mod, "output_bytes_cap")
	if hasOutputUTF8Cap && hasOutputBytesCap {
		return contract, errors.New("Wasm module must export exactly one output capacity")
	}
	if hasOutputUTF8Cap || hasOutputBytesCap {
		contract.hasOutput = true
		outputCap, ok, err := getExportedValue(ctx, mod, "output_utf8_cap")
		if err != nil {
			return contract, wasmruntime.HumanizeExecutionError(ctx, err)
		}
		if ok {
			contract.outputEncoding = dataEncodingUTF8
		} else if outputCap, ok, err = getExportedValue(ctx, mod, "output_bytes_cap"); err != nil {
			return contract, wasmruntime.HumanizeExecutionError(ctx, err)
		} else if ok {
			contract.outputEncoding = dataEncodingRaw
		} else {
			return contract, errors.New("Wasm module must export output_utf8_cap() -> i32 or output_bytes_cap() -> i32")
		}
		contract.outputCapBytes = outputCap
	}

	contract.declaredInputContentType, contract.hasDeclaredInputContentType, err = readOptionalModuleContentType(ctx, mod, "input")
	if err != nil {
		return contract, err
	}
	if contract.inputless && contract.hasDeclaredInputContentType {
		return contract, errors.New("inputless generator must not declare an input content type")
	}
	contract.declaredOutputContentType, contract.hasDeclaredOutputContentType, err = readOptionalModuleContentType(ctx, mod, "output")
	if err != nil {
		return contract, err
	}
	return contract, nil
}

func resolveRunModuleContentType(contract runModuleContract, incomingContentType string, allowMissingInputContentType bool, checking contentTypeCheckingMode, moduleName string) (effectiveInputType string, outputType string, err error) {
	if contract.inputless {
		if contract.hasDeclaredOutputContentType {
			return "", contract.declaredOutputContentType, nil
		}
		return "", "", nil
	}
	incomingFull := strings.TrimSpace(incomingContentType)
	effectiveInputType = normalizeIncomingContentType(incomingContentType)
	if effectiveInputType == "" && contract.hasDeclaredInputContentType && allowMissingInputContentType {
		incomingFull = contract.declaredInputContentType
		effectiveInputType = normalizeIncomingContentType(incomingFull)
	}

	if checking == ContentTypeCheckingStrong && contract.hasDeclaredInputContentType {
		if effectiveInputType == "" {
			return "", "", fmt.Errorf("expected %s, but pipeline content type is unspecified", contract.declaredInputContentType)
		}
		if err := declaredContentTypeAccepts(contract.declaredInputContentType, incomingFull); err != nil {
			return "", "", err
		}
	}

	switch {
	case contract.hasDeclaredOutputContentType:
		outputType = contract.declaredOutputContentType
	case contract.hasOutput && contract.outputEncoding == dataEncodingUTF8 && contract.inputEncoding != dataEncodingUTF8:
		outputType = ""
	case contract.hasOutput:
		outputType = effectiveInputType
	}
	return effectiveInputType, outputType, nil
}

type moduleExecutionResult struct {
	output            contentData
	outputContentType string
	instantiation     time.Duration
	run               time.Duration
	total             time.Duration
	memoryBytes       uint64
	inputCapBytes     uint64
	outputCapBytes    uint64
}

type contentRenderTrapError struct {
	cause error
}

func (e *contentRenderTrapError) Error() string {
	return fmt.Sprintf("trapped: %v", e.cause)
}

func (e *contentRenderTrapError) Unwrap() error {
	return e.cause
}

func runModuleWithInput(ctx context.Context, runtime wazero.Runtime, compiled wazero.CompiledModule, inputBytes []byte, opts options, moduleName string) (output contentData, instantiation time.Duration, returnErr error) {
	exec, err := executeModuleWithInput(ctx, runtime, compiled, inputBytes, opts, moduleName, nil, "", opts.trustFirstStageContent)
	if err != nil {
		return contentData{}, 0, err
	}
	return exec.output, exec.instantiation, nil
}

func executeModuleWithInput(
	ctx context.Context,
	runtime wazero.Runtime,
	compiled wazero.CompiledModule,
	inputBytes []byte,
	opts options,
	moduleName string,
	uniforms map[string]string,
	incomingContentType string,
	allowMissingInputContentType bool,
) (exec moduleExecutionResult, returnErr error) {
	totalStart := time.Now()
	defer func() {
		exec.total = time.Since(totalStart)
	}()

	instStart := time.Now()
	mod, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName(moduleName))
	if err != nil {
		returnErr = errors.New("Wasm module could not be instantiated")
		return
	}
	defer mod.Close(ctx)
	exec.instantiation = time.Since(instStart)

	if err := applyModuleUniforms(ctx, mod, uniforms); err != nil {
		returnErr = err
		return
	}

	return renderModuleInstance(ctx, mod, inputBytes, opts, moduleName, incomingContentType, allowMissingInputContentType, exec)
}

// renderModuleInstance runs one render on an instance whose uniforms are
// already set. The instance may have rendered before: hosts may reuse an
// instance after a successful or rejected render, but not after a trap,
// which is returned as *contentRenderTrapError.
func renderModuleInstance(
	ctx context.Context,
	mod api.Module,
	inputBytes []byte,
	opts options,
	moduleName string,
	incomingContentType string,
	allowMissingInputContentType bool,
	exec moduleExecutionResult,
) (_ moduleExecutionResult, returnErr error) {
	contract, err := inspectRunModuleContract(ctx, mod)
	if err != nil {
		returnErr = err
		return exec, returnErr
	}
	exec.inputCapBytes = contract.inputCapBytes
	exec.outputCapBytes = contract.outputCapBytes
	exec.output.encoding = contract.outputEncoding
	_, exec.outputContentType, err = resolveRunModuleContentType(contract, incomingContentType, allowMissingInputContentType, opts.contentTypeChecking, moduleName)
	if err != nil {
		returnErr = err
		return exec, returnErr
	}

	inputPtr := contract.inputPtr
	inputCap := contract.inputCapBytes
	outputCap := uint32(contract.outputCapBytes)
	runFunc := mod.ExportedFunction("render")

	var inputSize = uint64(len(inputBytes))
	if contract.inputless && inputSize != 0 {
		returnErr = fmt.Errorf("inputless generator cannot receive %d input bytes", inputSize)
		return exec, returnErr
	}
	if !contract.inputless && inputSize > inputCap {
		returnErr = fmt.Errorf("input is too large (%d bytes > %d bytes input capacity)", inputSize, inputCap)
		return exec, returnErr
	}
	// The pipeline's own input is validated for a UTF-8 first stage, because nothing before it
	// established the guarantee. Later stages trust the preceding stage's UTF-8 output.
	if allowMissingInputContentType && contract.inputEncoding == dataEncodingUTF8 {
		if offset := firstInvalidUTF8Offset(inputBytes); offset >= 0 {
			returnErr = fmt.Errorf("expected UTF-8 input, got invalid UTF-8 at input offset %d", offset)
			return exec, returnErr
		}
	}

	mem := mod.Memory()
	if !contract.inputless && !mem.Write(uint32(inputPtr), inputBytes) {
		returnErr = errors.New("Could not write input")
		return exec, returnErr
	}

	runStart := time.Now()
	runResult, returnErr := runFunc.Call(ctx, inputSize)
	exec.run = time.Since(runStart)
	if returnErr != nil {
		returnErr = &contentRenderTrapError{cause: wasmruntime.HumanizeExecutionError(ctx, returnErr)}
		return exec, returnErr
	}
	renderResult := runResult[0]
	if renderResult&(uint64(1)<<63) != 0 {
		if !contract.hasFailure {
			returnErr = errors.New("render returned failure but failure_modes_per_input_offset is not exported")
			return exec, returnErr
		}
		detail := uint32(renderResult)
		if contract.failureModesPerInputOffset == 0 {
			returnErr = errors.New("rejected input")
			return exec, returnErr
		}
		inputOffset := detail / contract.failureModesPerInputOffset
		mode := detail % contract.failureModesPerInputOffset
		if uint64(inputOffset) > inputSize {
			returnErr = fmt.Errorf("render returned input failure offset %d beyond input size %d", inputOffset, inputSize)
			return exec, returnErr
		}
		location := describeInputOffset(inputBytes, int(inputOffset), contract.declaredInputContentType)
		if contract.failureModesPerInputOffset == 1 {
			returnErr = fmt.Errorf("rejected input at input offset %d%s", inputOffset, location)
		} else {
			returnErr = fmt.Errorf("rejected input at input offset %d with mode %d%s", inputOffset, mode, location)
		}
		return exec, returnErr
	}

	outputCount := uint32(renderResult)
	outputPtr := uint32((renderResult >> 32) & 0x7fff_ffff)

	if contract.hasOutput {

		if outputCount > outputCap {
			returnErr = errors.New("Module returned more bytes than its stated capacity")
			return exec, returnErr
		}
		outputBytes, ok := mem.Read(outputPtr, outputCount)
		if !ok {
			returnErr = errors.New("Could not read output")
			return exec, returnErr
		}
		// Copy out of wasm memory so callers can safely use the bytes after module close.
		exec.output.bytes = slices.Clone(outputBytes)
		if opts.verbose && len(exec.output.bytes) > 0 {
			sum := sha256.Sum256(exec.output.bytes)
			vlogf(opts, "output sha256: %x", sum)
		}
	} else {
		fmt.Printf("Ran: %d\n", outputCount)
	}

	exec.memoryBytes = memorySizeBytes(mem)
	return exec, returnErr
}

func memorySizeBytes(mem api.Memory) uint64 {
	size := mem.Size()
	if size != 0 {
		return uint64(size)
	}
	// Work around wazero's uint32 overflow behavior on max memory.
	pages, ok := mem.Grow(0)
	if !ok {
		return 0
	}
	return uint64(pages) * 65536
}

// describeInputOffset locates a rejected input offset for people reading the error. For WARC input
// it names the enclosing record's target URI, because offsets into a whole-site archive are otherwise
// hard to trace back to a page. For text it quotes the surrounding line. It returns "" when neither
// applies, such as for binary input.
func describeInputOffset(input []byte, offset int, contentType string) string {
	if offset < 0 || offset > len(input) {
		return ""
	}
	var b strings.Builder
	if mediaTypeEssence(contentType) == "application/warc" {
		if target := warcTargetURIBefore(input, offset); target != "" {
			fmt.Fprintf(&b, " in WARC record %s", target)
		}
	}
	if snippet, ok := inputSnippet(input, offset); ok {
		fmt.Fprintf(&b, " near %s", snippet)
	}
	return b.String()
}

func mediaTypeEssence(contentType string) string {
	essence, _, _ := strings.Cut(contentType, ";")
	return strings.ToLower(strings.TrimSpace(essence))
}

// warcTargetURIBefore returns the WARC-Target-URI of the last record header starting at or before
// offset. It scans back for a "WARC/" version line at the start of a line, so a payload that happens
// to contain one can misattribute the offset; the result is only a hint in an error message.
func warcTargetURIBefore(input []byte, offset int) string {
	end := min(offset+1, len(input))
	for search := end; search > 0; {
		start := strings.LastIndex(string(input[:search]), "WARC/")
		if start < 0 {
			return ""
		}
		if start == 0 || input[start-1] == '\n' {
			headerEnd := len(input)
			if i := strings.Index(string(input[start:]), "\r\n\r\n"); i >= 0 {
				headerEnd = start + i
			}
			for _, line := range strings.Split(string(input[start:headerEnd]), "\n") {
				key, value, found := strings.Cut(strings.TrimRight(line, "\r"), ":")
				if found && strings.EqualFold(strings.TrimSpace(key), "WARC-Target-URI") {
					return strings.TrimSpace(value)
				}
			}
			return ""
		}
		search = start
	}
	return ""
}

const (
	inputSnippetBefore = 24
	inputSnippetAfter  = 48
)

// inputSnippet quotes the text around offset on its line, marking truncation with "…". It declines
// input that is not printable UTF-8 near the offset.
func inputSnippet(input []byte, offset int) (string, bool) {
	start := max(offset-inputSnippetBefore, 0)
	end := min(offset+inputSnippetAfter, len(input))
	if i := strings.LastIndexByte(string(input[start:offset]), '\n'); i >= 0 {
		start += i + 1
	}
	if i := strings.IndexByte(string(input[offset:end]), '\n'); i >= 0 {
		end = offset + i
	}
	for start < offset && !utf8.RuneStart(input[start]) {
		start++
	}
	for end > offset && end < len(input) && !utf8.RuneStart(input[end]) {
		end--
	}
	window := strings.TrimRight(string(input[start:end]), "\r")
	if window == "" || !utf8.ValidString(window) {
		return "", false
	}
	for _, r := range window {
		if r != '\t' && (r < 0x20 || r == 0x7f) {
			return "", false
		}
	}
	prefix, suffix := "", ""
	if start > 0 && input[start-1] != '\n' {
		prefix = "…"
	}
	if end < len(input) && input[end] != '\n' && input[end] != '\r' {
		suffix = "…"
	}
	snippet := prefix + window + suffix
	if strconv.CanBackquote(snippet) {
		return "`" + snippet + "`", true
	}
	return strconv.Quote(snippet), true
}

// firstInvalidUTF8Offset returns the byte offset of the first invalid UTF-8 sequence, or -1.
func firstInvalidUTF8Offset(b []byte) int {
	for i := 0; i < len(b); {
		r, size := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && size == 1 {
			return i
		}
		i += size
	}
	return -1
}
