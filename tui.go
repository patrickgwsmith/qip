package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"golang.org/x/term"
)

const (
	tuiFlagKeyDown = 1 << 0
	tuiFlagShift   = 1 << 2
	tuiFlagControl = 1 << 3
	tuiFlagAlt     = 1 << 4

	tuiXKBackspace = 0xff08
	tuiXKTab       = 0xff09
	tuiXKReturn    = 0xff0d
	tuiXKEscape    = 0xff1b
	tuiXKHome      = 0xff50
	tuiXKLeft      = 0xff51
	tuiXKUp        = 0xff52
	tuiXKRight     = 0xff53
	tuiXKDown      = 0xff54
	tuiXKPageUp    = 0xff55
	tuiXKPageDown  = 0xff56
	tuiXKEnd       = 0xff57
	tuiXKInsert    = 0xff63
	tuiXKDelete    = 0xffff
	tuiXKF1        = 0xffbe
)

const (
	tuiEnterScreen = "\x1b[?1049h\x1b[?25l"
	tuiLeaveScreen = "\x1b[0m\x1b[?25h\x1b[?1049l"
	tuiRedrawStart = "\x1b[H\x1b[J"
	tuiRedrawEnd   = "\x1b[0m\x1b[J"
)

type tuiDimensions struct {
	columns int
	lines   int
}

type tuiKey struct {
	keysym uint32
	flags  uint32
}

type tuiSession struct {
	opts            options
	timeout         time.Duration
	primaryName     string
	primaryUniforms map[string]string
	runtime         wazero.Runtime
	compiled        wazero.CompiledModule
	module          api.Module
	contract        runModuleContract
	input           []byte
	outputType      string
	post            *qinternal.Pipeline
	postUniforms    []map[string]string
	requestID       uint64
	beginUpdate     api.Function
	finishUpdate    api.Function
	keyEvent        api.Function
}

func tuiCmd(args []string) {
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Println(usageTUI)
		return
	}
	config, err := parseRunCommandArgs(args, "tui")
	if err != nil {
		gameOver("%v", err)
	}
	if config.outputPath != "-" {
		gameOver("qip tui writes only to terminal stdout; remove -o/--output")
	}
	if config.opts.traceWith != "" {
		gameOver("qip tui does not support --trace-with")
	}
	if config.inputPath == "-" {
		gameOver("qip tui cannot read -i - because stdin carries terminal events")
	}
	for _, value := range config.formValues {
		assignment, parseErr := parseFormAssignment(value)
		if parseErr != nil {
			gameOver("%v", parseErr)
		}
		if assignment.filePath == "-" {
			gameOver("qip tui cannot use -F name=@- or name=<- because stdin carries terminal events")
		}
	}

	var input []byte
	inputType := ""
	if len(config.formValues) > 0 {
		formPlan, planErr := planMultipartFormInput(config.formValues, config.opts.hosts)
		if planErr != nil {
			gameOver("Error reading TUI input: %v", planErr)
		}
		input, inputType, err = buildMultipartFormInputFromPlan(formPlan, nil)
	} else if config.inputPath != "" {
		input, err = os.ReadFile(config.inputPath)
	}
	if err != nil {
		gameOver("Error reading TUI input: %v", err)
	}
	if err := runTUI(context.Background(), config, input, inputType, os.Stdin, os.Stdout); err != nil {
		gameOver("%v", err)
	}
}

func runTUI(ctx context.Context, config runCommandConfig, input []byte, inputType string, stdin, stdout *os.File) error {
	if !term.IsTerminal(int(stdin.Fd())) || !term.IsTerminal(int(stdout.Fd())) {
		return errors.New("qip tui requires terminal stdin and stdout")
	}
	resolved, err := newQIPRuntime(config.opts).ResolveComponents(config.componentInvocations)
	if err != nil {
		return err
	}
	session, err := newTUISession(ctx, config, resolved, input, inputType)
	if err != nil {
		return err
	}
	defer session.close(context.Background())
	return session.play(stdin, stdout)
}

func newTUISession(ctx context.Context, config runCommandConfig, components []ResolvedComponent, input []byte, inputType string) (*tuiSession, error) {
	if len(components) == 0 {
		return nil, errors.New(usageTUI)
	}
	primary := components[0]
	if err := logAndValidateModule(primary.Name, primary.WASM, config.opts); err != nil {
		return nil, err
	}
	runtime := wasmruntime.New(ctx)
	compiled, err := runtime.CompileModule(ctx, primary.WASM)
	if err != nil {
		runtime.Close(ctx)
		return nil, fmt.Errorf("Wasm module %q could not be compiled: %w", primary.Name, err)
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("tui-primary"))
	if err != nil {
		compiled.Close(ctx)
		runtime.Close(ctx)
		return nil, fmt.Errorf("Wasm module %q could not be instantiated: %w", primary.Name, err)
	}
	cleanup := func() {
		module.Close(ctx)
		compiled.Close(ctx)
		runtime.Close(ctx)
	}
	contract, err := inspectRunModuleContract(ctx, module)
	if err != nil {
		cleanup()
		return nil, fmt.Errorf("%s: %w", primary.Name, err)
	}
	if contract.inputless && len(input) != 0 {
		cleanup()
		return nil, fmt.Errorf("%s is inputless and cannot receive TUI input", primary.Name)
	}
	if !contract.inputless && uint64(len(input)) > contract.inputCapBytes {
		cleanup()
		return nil, fmt.Errorf("%s input is too large (%d bytes > %d bytes input capacity)", primary.Name, len(input), contract.inputCapBytes)
	}
	_, outputType, err := resolveRunModuleContentType(contract, inputType, true, config.opts.contentTypeChecking, primary.Name)
	if err != nil {
		cleanup()
		return nil, err
	}
	beginUpdate, err := requireTUIFunction(module, "begin_update_at", []api.ValueType{api.ValueTypeI64}, nil)
	if err != nil {
		cleanup()
		return nil, err
	}
	finishUpdate, err := requireTUIFunction(module, "finish_update", nil, []api.ValueType{api.ValueTypeI64})
	if err != nil {
		cleanup()
		return nil, err
	}
	keyEvent, err := requireTUIFunction(module, "key_event", []api.ValueType{api.ValueTypeI32, api.ValueTypeI32}, []api.ValueType{api.ValueTypeI32})
	if err != nil {
		cleanup()
		return nil, err
	}

	var post *qinternal.Pipeline
	if len(components) > 1 {
		post, err = compileResolvedComponents(ctx, components[1:], config.opts)
		if err != nil {
			cleanup()
			return nil, err
		}
		for index, stage := range post.Stages {
			runStage, ok := stage.(*qinternal.RunStage)
			if !ok {
				post.Close(ctx)
				cleanup()
				return nil, fmt.Errorf("step %d (%s) must be a Content component after a TUI component", index+2, components[index+1].Name)
			}
			driver, ok := runStage.Driver.(*wasmRunDriver)
			if !ok {
				post.Close(ctx)
				cleanup()
				return nil, fmt.Errorf("step %d (%s) has an unsupported Content driver", index+2, components[index+1].Name)
			}
			exports := driver.compiled.ExportedFunctions()
			_, hasBeginUpdate := exports["begin_update_at"]
			_, hasFinishUpdate := exports["finish_update"]
			if hasBeginUpdate || hasFinishUpdate {
				post.Close(ctx)
				cleanup()
				return nil, fmt.Errorf("step %d (%s) must be an ordinary Content component after a TUI component", index+2, components[index+1].Name)
			}
		}
		postDescriptions, describeErr := describeRunPipeline(ctx, post)
		if describeErr != nil {
			post.Close(ctx)
			cleanup()
			return nil, describeErr
		}
		descriptions := append([]pipelineComponentDescription{{
			source:  primary.Name,
			kind:    pipelineComponentContent,
			content: describePipelineContent(contract),
		}}, postDescriptions...)
		if _, planErr := planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{
			capacitiesMustFit: config.opts.capacitiesMustFit,
		}); planErr != nil {
			post.Close(ctx)
			cleanup()
			return nil, planErr
		}
	}

	session := &tuiSession{
		opts:            config.opts,
		timeout:         time.Duration(config.timeoutMS) * time.Millisecond,
		primaryName:     primary.Name,
		primaryUniforms: maps.Clone(primary.UniformValues),
		runtime:         runtime,
		compiled:        compiled,
		module:          module,
		contract:        contract,
		input:           input,
		outputType:      outputType,
		post:            post,
		postUniforms:    make([]map[string]string, max(0, len(components)-1)),
		beginUpdate:     beginUpdate,
		finishUpdate:    finishUpdate,
		keyEvent:        keyEvent,
	}
	for index := range session.postUniforms {
		session.postUniforms[index] = maps.Clone(components[index+1].UniformValues)
	}
	if !contract.inputless && !module.Memory().Write(uint32(contract.inputPtr), input) {
		session.close(ctx)
		return nil, fmt.Errorf("could not write input to %s", primary.Name)
	}
	return session, nil
}

func requireTUIFunction(module api.Module, name string, params, results []api.ValueType) (api.Function, error) {
	fn := module.ExportedFunction(name)
	if fn == nil {
		return nil, fmt.Errorf("TUI component must export %s", name)
	}
	definition := fn.Definition()
	if !equalValueTypes(definition.ParamTypes(), params) || !equalValueTypes(definition.ResultTypes(), results) {
		return nil, fmt.Errorf("TUI component export %s has the wrong signature", name)
	}
	return fn, nil
}

func equalValueTypes(left, right []api.ValueType) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func (session *tuiSession) close(ctx context.Context) {
	if session.post != nil {
		session.post.Close(ctx)
	}
	if session.module != nil {
		session.module.Close(ctx)
	}
	if session.compiled != nil {
		session.compiled.Close(ctx)
	}
	if session.runtime != nil {
		session.runtime.Close(ctx)
	}
}

func (session *tuiSession) operationContext() (context.Context, context.CancelFunc) {
	return wasmruntime.WithExecutionTimeout(context.Background(), session.timeout)
}

func tuiUniformValues(module api.Module, explicit map[string]string, dimensions tuiDimensions) map[string]string {
	values := maps.Clone(explicit)
	if values == nil {
		values = make(map[string]string)
	}
	for key, value := range map[string]int{"columns": dimensions.columns, "lines": dimensions.lines} {
		if _, set := values[key]; !set && module.ExportedFunction("uniform_set_"+key) != nil {
			values[key] = strconv.Itoa(value)
		}
	}
	return values
}

func (session *tuiSession) renderPrimary(initial bool, dimensions tuiDimensions) (qinternal.Content, error) {
	ctx, cancel := session.operationContext()
	defer cancel()
	if err := applyModuleUniforms(ctx, session.module, tuiUniformValues(session.module, session.primaryUniforms, dimensions)); err != nil {
		return nil, fmt.Errorf("%s: %w", session.primaryName, err)
	}
	inputSize := uint64(0)
	if initial && !session.contract.inputless {
		inputSize = uint64(len(session.input))
	}
	results, err := session.module.ExportedFunction("render").Call(ctx, inputSize)
	if err != nil {
		return nil, fmt.Errorf("%s render trapped: %w", session.primaryName, wasmruntime.HumanizeExecutionError(ctx, err))
	}
	packed := results[0]
	if packed&(uint64(1)<<63) != 0 {
		return nil, fmt.Errorf("%s rejected its initial input", session.primaryName)
	}
	size := uint32(packed)
	pointer := uint32((packed >> 32) & 0x7fff_ffff)
	if uint64(size) > session.contract.outputCapBytes {
		return nil, fmt.Errorf("%s returned more bytes than its stated capacity", session.primaryName)
	}
	output, ok := session.module.Memory().Read(pointer, size)
	if !ok {
		return nil, fmt.Errorf("%s returned output outside its memory", session.primaryName)
	}
	copyOfOutput := append([]byte(nil), output...)
	if session.contract.outputEncoding == dataEncodingUTF8 {
		return qinternal.NewStringContentWithType(string(copyOfOutput), session.outputType), nil
	}
	return qinternal.NewRawBytesContentWithType(copyOfOutput, session.outputType), nil
}

func (session *tuiSession) renderFrame(initial bool, dimensions tuiDimensions) ([]byte, error) {
	content, err := session.renderPrimary(initial, dimensions)
	if err != nil {
		return nil, err
	}
	if session.post != nil {
		session.applyPostDimensions(dimensions)
		ctx, cancel := session.operationContext()
		defer cancel()
		session.requestID++
		content, err = session.post.Process(ctx, content, session.requestID)
		if err != nil {
			return nil, err
		}
	}
	if content.Encoding() != qinternal.EncodingUTF8 {
		return nil, errors.New("TUI pipeline must produce UTF-8 output")
	}
	output, err := qinternal.AsRawBytes(content)
	if err != nil {
		return nil, err
	}
	if err := validateTerminalFrame(output); err != nil {
		return nil, err
	}
	return append([]byte(nil), output...), nil
}

func (session *tuiSession) applyPostDimensions(dimensions tuiDimensions) {
	for index, stage := range session.post.Stages {
		runStage, ok := stage.(*qinternal.RunStage)
		if !ok || index >= len(session.postUniforms) {
			continue
		}
		driver, ok := runStage.Driver.(*wasmRunDriver)
		if !ok {
			continue
		}
		values := maps.Clone(session.postUniforms[index])
		if values == nil {
			values = make(map[string]string)
		}
		exports := driver.compiled.ExportedFunctions()
		for key, value := range map[string]int{"columns": dimensions.columns, "lines": dimensions.lines} {
			if _, explicit := values[key]; explicit {
				continue
			}
			if _, present := exports["uniform_set_"+key]; present {
				values[key] = strconv.Itoa(value)
			}
		}
		driver.uniforms = values
	}
}

func (session *tuiSession) update(keys []tuiKey, requestedTime int64, startedAt time.Time, lastUpdate int64, dimensions tuiDimensions) (nextWake int64, accepted bool, committed int64, err error) {
	now := time.Since(startedAt).Milliseconds() + 1
	if now <= lastUpdate {
		now = lastUpdate + 1
	}
	if now < requestedTime {
		now = requestedTime
	}
	ctx, cancel := session.operationContext()
	defer cancel()
	if _, err = session.beginUpdate.Call(ctx, uint64(now)); err != nil {
		return 0, false, lastUpdate, fmt.Errorf("%s begin_update_at trapped: %w", session.primaryName, wasmruntime.HumanizeExecutionError(ctx, err))
	}
	if err = applyModuleUniforms(ctx, session.module, tuiUniformValues(session.module, session.primaryUniforms, dimensions)); err != nil {
		return 0, false, lastUpdate, fmt.Errorf("%s: %w", session.primaryName, err)
	}
	for _, key := range keys {
		down, callErr := session.keyEvent.Call(ctx, uint64(key.keysym), uint64(key.flags|tuiFlagKeyDown))
		if callErr != nil {
			return 0, false, lastUpdate, fmt.Errorf("%s key_event trapped: %w", session.primaryName, wasmruntime.HumanizeExecutionError(ctx, callErr))
		}
		up, callErr := session.keyEvent.Call(ctx, uint64(key.keysym), uint64(key.flags))
		if callErr != nil {
			return 0, false, lastUpdate, fmt.Errorf("%s key_event trapped: %w", session.primaryName, wasmruntime.HumanizeExecutionError(ctx, callErr))
		}
		accepted = accepted || uint32(down[0]) == 1 || uint32(up[0]) == 1
	}
	finished, err := session.finishUpdate.Call(ctx)
	if err != nil {
		return 0, false, lastUpdate, fmt.Errorf("%s finish_update trapped: %w", session.primaryName, wasmruntime.HumanizeExecutionError(ctx, err))
	}
	nextWake = int64(finished[0])
	if nextWake < now {
		return 0, false, lastUpdate, fmt.Errorf("%s returned wake time %d before update time %d", session.primaryName, nextWake, now)
	}
	return nextWake, accepted, now, nil
}

func terminalDimensions(file *os.File) (tuiDimensions, error) {
	columns, lines, err := term.GetSize(int(file.Fd()))
	if err != nil {
		return tuiDimensions{}, err
	}
	if columns <= 0 || lines <= 0 {
		return tuiDimensions{}, errors.New("terminal reported invalid dimensions")
	}
	return tuiDimensions{columns: columns, lines: lines}, nil
}

func writeTUIFrame(writer io.Writer, frame []byte) error {
	if _, err := io.WriteString(writer, tuiRedrawStart); err != nil {
		return err
	}
	// term.MakeRaw disables output post-processing on Unix. Expand the already
	// validated LF bytes so each terminal line also returns to column zero.
	for len(frame) > 0 {
		lineEnd := bytes.IndexByte(frame, '\n')
		if lineEnd < 0 {
			if _, err := writer.Write(frame); err != nil {
				return err
			}
			break
		}
		if _, err := writer.Write(frame[:lineEnd]); err != nil {
			return err
		}
		if _, err := io.WriteString(writer, "\r\n"); err != nil {
			return err
		}
		frame = frame[lineEnd+1:]
	}
	_, err := io.WriteString(writer, tuiRedrawEnd)
	return err
}

func (session *tuiSession) play(stdin, stdout *os.File) error {
	dimensions, err := terminalDimensions(stdout)
	if err != nil {
		return fmt.Errorf("read terminal size: %w", err)
	}
	frame, err := session.renderFrame(true, dimensions)
	if err != nil {
		return err
	}
	startedAt := time.Now()
	nextWake, _, lastUpdate, err := session.update(nil, 0, startedAt, 0, dimensions)
	if err != nil {
		return err
	}

	oldState, err := term.MakeRaw(int(stdin.Fd()))
	if err != nil {
		return fmt.Errorf("enter terminal input mode: %w", err)
	}
	terminalActive := false
	leave := func() {
		if terminalActive {
			_, _ = io.WriteString(stdout, tuiLeaveScreen)
			terminalActive = false
		}
		_ = term.Restore(int(stdin.Fd()), oldState)
	}
	defer leave()
	if _, err := io.WriteString(stdout, tuiEnterScreen); err != nil {
		return err
	}
	terminalActive = true
	if err := writeTUIFrame(stdout, frame); err != nil {
		return err
	}

	inputBytes := make(chan []byte, 8)
	inputErrors := make(chan error, 1)
	go func() {
		buffer := make([]byte, 256)
		for {
			count, readErr := stdin.Read(buffer)
			if count > 0 {
				inputBytes <- append([]byte(nil), buffer[:count]...)
			}
			if readErr != nil {
				inputErrors <- readErr
				return
			}
		}
	}()

	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, tuiTerminationSignals()...)
	defer signal.Stop(interrupts)
	resizeTicker := time.NewTicker(100 * time.Millisecond)
	defer resizeTicker.Stop()
	decoder := tuiKeyDecoder{}
	var escapeTimer *time.Timer
	var escapeChannel <-chan time.Time
	var wakeTimer *time.Timer
	var wakeChannel <-chan time.Time

	resetWake := func() {
		if wakeTimer != nil {
			if !wakeTimer.Stop() {
				select {
				case <-wakeTimer.C:
				default:
				}
			}
		}
		wakeChannel = nil
		if nextWake <= lastUpdate {
			return
		}
		logical := time.Since(startedAt).Milliseconds() + 1
		delay := time.Duration(max(int64(0), nextWake-logical)) * time.Millisecond
		wakeTimer = time.NewTimer(delay)
		wakeChannel = wakeTimer.C
	}
	resetWake()

	handleKey := func(key tuiKey) (bool, error) {
		if key.flags&tuiFlagControl != 0 && key.keysym == 'c' {
			return true, nil
		}
		if key.flags&tuiFlagControl != 0 && (key.keysym == 'q' || key.keysym == 's') {
			return false, nil
		}
		if key.flags&tuiFlagControl != 0 && key.keysym == 'z' {
			if tuiCanSuspend() {
				leave()
				if err := tuiSuspendSelf(); err != nil {
					return false, err
				}
				if _, err := term.MakeRaw(int(stdin.Fd())); err != nil {
					return false, err
				}
				if _, err := io.WriteString(stdout, tuiEnterScreen); err != nil {
					return false, err
				}
				terminalActive = true
				current, err := session.renderFrame(false, dimensions)
				if err != nil {
					return false, err
				}
				return false, writeTUIFrame(stdout, current)
			}
			return false, nil
		}
		var accepted bool
		nextWake, accepted, lastUpdate, err = session.update([]tuiKey{key}, 0, startedAt, lastUpdate, dimensions)
		if err != nil {
			return false, err
		}
		if accepted {
			frame, err = session.renderFrame(false, dimensions)
			if err != nil {
				return false, err
			}
			if err := writeTUIFrame(stdout, frame); err != nil {
				return false, err
			}
		}
		resetWake()
		return false, nil
	}

	for {
		select {
		case chunk := <-inputBytes:
			keys, pending := decoder.push(chunk, false)
			for _, key := range keys {
				done, handleErr := handleKey(key)
				if handleErr != nil || done {
					return handleErr
				}
			}
			if escapeTimer != nil {
				escapeTimer.Stop()
			}
			escapeChannel = nil
			if pending {
				escapeTimer = time.NewTimer(30 * time.Millisecond)
				escapeChannel = escapeTimer.C
			}
		case <-escapeChannel:
			escapeChannel = nil
			keys, _ := decoder.push(nil, true)
			for _, key := range keys {
				done, handleErr := handleKey(key)
				if handleErr != nil || done {
					return handleErr
				}
			}
		case <-wakeChannel:
			wakeChannel = nil
			nextWake, _, lastUpdate, err = session.update(nil, nextWake, startedAt, lastUpdate, dimensions)
			if err != nil {
				return err
			}
			frame, err = session.renderFrame(false, dimensions)
			if err != nil {
				return err
			}
			if err := writeTUIFrame(stdout, frame); err != nil {
				return err
			}
			resetWake()
		case <-resizeTicker.C:
			resized, sizeErr := terminalDimensions(stdout)
			if sizeErr == nil && resized != dimensions {
				dimensions = resized
				frame, err = session.renderFrame(false, dimensions)
				if err != nil {
					return err
				}
				if err := writeTUIFrame(stdout, frame); err != nil {
					return err
				}
			}
		case <-interrupts:
			return nil
		case readErr := <-inputErrors:
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
	}
}

func validateTerminalFrame(frame []byte) error {
	if !utf8.Valid(frame) {
		return errors.New("terminal output is not valid UTF-8")
	}
	for index := 0; index < len(frame); {
		value := frame[index]
		if value == 0x1b {
			if index+1 >= len(frame) || frame[index+1] != '[' {
				return fmt.Errorf("terminal output contains unsupported ESC sequence at byte %d", index)
			}
			end := index + 2
			for end < len(frame) && frame[end] != 'm' {
				if (frame[end] < '0' || frame[end] > '9') && frame[end] != ';' {
					return fmt.Errorf("terminal output contains unsupported CSI sequence at byte %d", index)
				}
				end++
			}
			if end == len(frame) {
				return fmt.Errorf("terminal output contains incomplete SGR sequence at byte %d", index)
			}
			parts := strings.Split(string(frame[index+2:end]), ";")
			if len(parts) > 16 {
				return fmt.Errorf("terminal output contains too many SGR parameters at byte %d", index)
			}
			for _, part := range parts {
				parameter := 0
				if part != "" {
					parsed, err := strconv.Atoi(part)
					if err != nil {
						return fmt.Errorf("terminal output contains invalid SGR parameters at byte %d", index)
					}
					parameter = parsed
				}
				if !allowedTUISGRParameter(parameter) {
					return fmt.Errorf("terminal output contains unsupported SGR parameter %d at byte %d", parameter, index)
				}
			}
			index = end + 1
			continue
		}
		if value < 0x20 {
			if value != '\n' {
				return fmt.Errorf("terminal output contains control byte 0x%02x at byte %d", value, index)
			}
			index++
			continue
		}
		if value == 0x7f {
			return fmt.Errorf("terminal output contains DEL at byte %d", index)
		}
		r, width := utf8.DecodeRune(frame[index:])
		if r >= 0x80 && r <= 0x9f {
			return fmt.Errorf("terminal output contains C1 control U+%04X at byte %d", r, index)
		}
		index += width
	}
	return nil
}

func allowedTUISGRParameter(value int) bool {
	if value == 0 || value == 1 || value == 2 || value == 4 || value == 22 || value == 24 || value == 39 || value == 49 {
		return true
	}
	return (value >= 30 && value <= 37) || (value >= 40 && value <= 47) || (value >= 90 && value <= 97) || (value >= 100 && value <= 107)
}

type tuiKeyDecoder struct {
	pending []byte
}

func (decoder *tuiKeyDecoder) push(input []byte, final bool) ([]tuiKey, bool) {
	decoder.pending = append(decoder.pending, input...)
	var keys []tuiKey
	for len(decoder.pending) > 0 {
		key, consumed, incomplete := decodeTUIKey(decoder.pending, final)
		if incomplete {
			break
		}
		decoder.pending = decoder.pending[consumed:]
		if key != nil {
			keys = append(keys, *key)
		}
	}
	return keys, len(decoder.pending) > 0
}

func decodeTUIKey(input []byte, final bool) (*tuiKey, int, bool) {
	if len(input) == 0 {
		return nil, 0, true
	}
	first := input[0]
	if first == 0x1b {
		if len(input) == 1 {
			if !final {
				return nil, 0, true
			}
			return &tuiKey{keysym: tuiXKEscape}, 1, false
		}
		if input[1] == '[' {
			end := 2
			for end < len(input) && (input[end] < 0x40 || input[end] > 0x7e) {
				end++
			}
			if end == len(input) {
				if !final {
					return nil, 0, true
				}
				if len(input) == 2 {
					return &tuiKey{keysym: '[', flags: tuiFlagAlt}, 2, false
				}
				return &tuiKey{keysym: tuiXKEscape}, 1, false
			}
			key := decodeTUICSI(string(input[2:end]), input[end])
			return key, end + 1, false
		}
		if input[1] == 'O' {
			if len(input) < 3 {
				if !final {
					return nil, 0, true
				}
				return &tuiKey{keysym: tuiXKEscape}, 1, false
			}
			if input[2] >= 'P' && input[2] <= 'S' {
				return &tuiKey{keysym: tuiXKF1 + uint32(input[2]-'P')}, 3, false
			}
			return nil, 3, false
		}
		r, width, incomplete := decodeTUIRune(input[1:])
		if incomplete && !final {
			return nil, 0, true
		}
		if width > 0 {
			return &tuiKey{keysym: uint32(r), flags: tuiFlagAlt | tuiPrintableFlags(r)}, width + 1, false
		}
		return &tuiKey{keysym: tuiXKEscape}, 1, false
	}
	switch first {
	case 0x08, 0x7f:
		return &tuiKey{keysym: tuiXKBackspace}, 1, false
	case 0x09:
		return &tuiKey{keysym: tuiXKTab}, 1, false
	case 0x0a, 0x0d:
		return &tuiKey{keysym: tuiXKReturn}, 1, false
	}
	if first >= 1 && first <= 26 {
		return &tuiKey{keysym: uint32('a' + first - 1), flags: tuiFlagControl}, 1, false
	}
	if first < 0x20 {
		return nil, 1, false
	}
	r, width, incomplete := decodeTUIRune(input)
	if incomplete && !final {
		return nil, 0, true
	}
	if width == 0 {
		return nil, 1, false
	}
	return &tuiKey{keysym: uint32(r), flags: tuiPrintableFlags(r)}, width, false
}

func decodeTUIRune(input []byte) (rune, int, bool) {
	if !utf8.FullRune(input) {
		return 0, 0, true
	}
	r, width := utf8.DecodeRune(input)
	if r == utf8.RuneError && width == 1 {
		return 0, 0, false
	}
	return r, width, false
}

func tuiPrintableFlags(r rune) uint32 {
	if r >= 'A' && r <= 'Z' {
		return tuiFlagShift
	}
	return 0
}

func decodeTUICSI(body string, final byte) *tuiKey {
	base := uint32(0)
	switch final {
	case 'A':
		base = tuiXKUp
	case 'B':
		base = tuiXKDown
	case 'C':
		base = tuiXKRight
	case 'D':
		base = tuiXKLeft
	case 'H':
		base = tuiXKHome
	case 'F':
		base = tuiXKEnd
	case 'Z':
		if body == "" {
			return &tuiKey{keysym: tuiXKTab, flags: tuiFlagShift}
		}
	}
	if base != 0 {
		if body == "" {
			return &tuiKey{keysym: base}
		}
		parts := strings.Split(body, ";")
		if len(parts) != 2 || (parts[0] != "" && parts[0] != "1") {
			return nil
		}
		flags, ok := decodeTUIModifier(parts[1])
		if !ok {
			return nil
		}
		return &tuiKey{keysym: base, flags: flags}
	}
	if final != '~' {
		return nil
	}
	parts := strings.Split(body, ";")
	if len(parts) > 2 {
		return nil
	}
	number, err := strconv.Atoi(parts[0])
	if err != nil {
		return nil
	}
	keys := map[int]uint32{
		1: tuiXKHome, 2: tuiXKInsert, 3: tuiXKDelete, 4: tuiXKEnd,
		5: tuiXKPageUp, 6: tuiXKPageDown, 7: tuiXKHome, 8: tuiXKEnd,
		11: tuiXKF1, 12: tuiXKF1 + 1, 13: tuiXKF1 + 2, 14: tuiXKF1 + 3,
		15: tuiXKF1 + 4, 17: tuiXKF1 + 5, 18: tuiXKF1 + 6, 19: tuiXKF1 + 7,
		20: tuiXKF1 + 8, 21: tuiXKF1 + 9, 23: tuiXKF1 + 10, 24: tuiXKF1 + 11,
	}
	keysym, ok := keys[number]
	if !ok {
		return nil
	}
	flags := uint32(0)
	if len(parts) == 2 {
		flags, ok = decodeTUIModifier(parts[1])
		if !ok {
			return nil
		}
	}
	return &tuiKey{keysym: keysym, flags: flags}
}

func decodeTUIModifier(value string) (uint32, bool) {
	parameter, err := strconv.Atoi(value)
	if err != nil || parameter < 1 || parameter > 8 {
		return 0, false
	}
	encoded := parameter - 1
	flags := uint32(0)
	if encoded&1 != 0 {
		flags |= tuiFlagShift
	}
	if encoded&2 != 0 {
		flags |= tuiFlagAlt
	}
	if encoded&4 != 0 {
		flags |= tuiFlagControl
	}
	return flags, true
}
