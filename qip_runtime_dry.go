package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	qinternal "github.com/royalicing/qip/internal"
	"github.com/royalicing/qip/internal/wasmruntime"
	"github.com/tetratelabs/wazero"
)

type runPipelineStep struct {
	index          int
	source         string
	kind           string
	inputEncoding  string
	inputType      string
	outputEncoding string
	outputType     string
	inputCapBytes  uint64
	outputCapBytes uint64
	bufferBytes    uint64
	note           string
}

type runPipelinePlan struct {
	steps            []runPipelineStep
	totalBufferBytes uint64
	warnings         []string
}

type runPipelinePlanningOptions struct {
	capacitiesMustFit bool
	// initialContentType is the content type of the pipeline's input when the caller
	// knows it, such as the canonical multipart type for -F form input. It lets the
	// planner check the first stage before anything runs.
	initialContentType string
}

type pipelineComponentKind uint8

const (
	pipelineComponentContent pipelineComponentKind = iota
	pipelineComponentTile
)

type pipelineComponentDescription struct {
	source       string
	kind         pipelineComponentKind
	content      pipelineContentDescription
	tileInputCap uint64
	tileHaloPx   int
}

type pipelineContentDescription struct {
	inputless                    bool
	inputCapBytes                uint64
	inputEncoding                dataEncoding
	hasOutput                    bool
	outputCapBytes               uint64
	outputEncoding               dataEncoding
	declaredInputContentType     string
	hasDeclaredInputContentType  bool
	declaredOutputContentType    string
	hasDeclaredOutputContentType bool
}

func describePipelineContent(contract runModuleContract) pipelineContentDescription {
	return pipelineContentDescription{
		inputless:                    contract.inputless,
		inputCapBytes:                contract.inputCapBytes,
		inputEncoding:                contract.inputEncoding,
		hasOutput:                    contract.hasOutput,
		outputCapBytes:               contract.outputCapBytes,
		outputEncoding:               contract.outputEncoding,
		declaredInputContentType:     contract.declaredInputContentType,
		hasDeclaredInputContentType:  contract.hasDeclaredInputContentType,
		declaredOutputContentType:    contract.declaredOutputContentType,
		hasDeclaredOutputContentType: contract.hasDeclaredOutputContentType,
	}
}

func (description pipelineContentDescription) runContract() runModuleContract {
	return runModuleContract{
		inputless:                    description.inputless,
		inputCapBytes:                description.inputCapBytes,
		inputEncoding:                description.inputEncoding,
		hasOutput:                    description.hasOutput,
		outputCapBytes:               description.outputCapBytes,
		outputEncoding:               description.outputEncoding,
		declaredInputContentType:     description.declaredInputContentType,
		hasDeclaredInputContentType:  description.hasDeclaredInputContentType,
		declaredOutputContentType:    description.declaredOutputContentType,
		hasDeclaredOutputContentType: description.hasDeclaredOutputContentType,
	}
}

type preparedRunPipeline struct {
	pipeline *qinternal.Pipeline
	plan     runPipelinePlan
}

type multipartFileSourceObservation struct {
	assignment formAssignment
	plan       qinternal.ComponentSourcePlan
	state      string
}

func observeMultipartFileSources(plan multipartFormPlan) ([]multipartFileSourceObservation, error) {
	observations := make([]multipartFileSourceObservation, 0, len(plan.fields))
	for _, field := range plan.fields {
		assignment := field.assignment
		if assignment.filePath == "" || assignment.filePath == "-" {
			continue
		}
		state := "present (contents not read)"
		if _, err := os.Stat(assignment.filePath); err != nil {
			if !os.IsNotExist(err) {
				return nil, err
			}
			state = "missing"
		}
		observations = append(observations, multipartFileSourceObservation{
			assignment: assignment,
			plan:       field.sourcePlan,
			state:      state,
		})
	}
	return observations, nil
}

func writeMultipartFileSourceReport(out io.Writer, observations []multipartFileSourceObservation) {
	if len(observations) == 0 {
		return
	}
	fmt.Fprintln(out, "\nMultipart files:")
	for _, observation := range observations {
		fmt.Fprintf(out, "  Field %q: %s\n", observation.assignment.name, observation.plan.FilePath)
		for sourceIndex, source := range observation.plan.Sources {
			label := source.Path
			state := observation.state
			if source.Kind == "https" {
				label = source.URL
				state = "unexamined"
			}
			fmt.Fprintf(out, "    %d  %-5s  %s  %s\n", sourceIndex, source.Kind, label, state)
		}
	}
}

func dryRunCmd(args []string) {
	config, err := parseRunCommandArgs(args, "dry run")
	if err != nil {
		gameOver("%v", err)
	}
	if err := executeDryRun(context.Background(), config, os.Stdout); err != nil {
		gameOver("%v", err)
	}
}

func executeDryRun(baseCtx context.Context, config runCommandConfig, out io.Writer) error {
	formPlan, err := planMultipartFormInput(config.formValues, config.opts.hosts)
	if err != nil {
		return err
	}
	if len(config.opts.hosts) > 0 {
		return executeHostedDryRun(baseCtx, config, out, formPlan)
	}
	multipartFiles, err := observeMultipartFileSources(formPlan)
	if err != nil {
		return err
	}
	execCtx, cancel := wasmruntime.WithExecutionTimeout(baseCtx, time.Duration(config.timeoutMS)*time.Millisecond)
	defer cancel()

	prepared, err := prepareRunPipelineFromInvocations(execCtx, config.componentInvocations, config.opts, "")
	if err != nil {
		return err
	}
	defer prepared.pipeline.Close(context.Background())
	writeMultipartFileSourceReport(out, multipartFiles)
	writeDryRunReport(out, prepared.plan)
	return nil
}

func executeHostedDryRun(baseCtx context.Context, config runCommandConfig, out io.Writer, formPlan multipartFormPlan) error {
	type observation struct {
		invocation ComponentInvocation
		plan       qinternal.ComponentSourcePlan
		state      string
		body       []byte
	}
	observations := make([]observation, 0, len(config.componentInvocations))
	for _, invocation := range config.componentInvocations {
		plan := qinternal.PlanComponentSources(invocation.Source, config.opts.hosts)
		state, body, err := qinternal.ObserveLocalComponentSource(plan)
		if err != nil {
			return err
		}
		observations = append(observations, observation{invocation: invocation, plan: plan, state: state, body: body})
	}

	fmt.Fprintln(out, "Sources:")
	for componentIndex, observation := range observations {
		indent := "  "
		if len(observations) > 1 {
			fmt.Fprintf(out, "  Component %d: %s\n", componentIndex+1, observation.plan.FilePath)
			indent = "    "
		}
		for sourceIndex, source := range observation.plan.Sources {
			label := source.Path
			if source.Kind == "https" {
				label = source.URL
			}
			fmt.Fprintf(out, "%s%d  %-5s  %s\n", indent, sourceIndex, source.Kind, label)
		}
	}
	fmt.Fprintln(out, "\nResolution:")
	for componentIndex, observation := range observations {
		indent := "  "
		if len(observations) > 1 {
			fmt.Fprintf(out, "  Component %d: %s\n", componentIndex+1, observation.plan.FilePath)
			indent = "    "
		}
		fmt.Fprintf(out, "%s0  %s\n", indent, observation.state)
		for sourceIndex := 1; sourceIndex < len(observation.plan.Sources); sourceIndex++ {
			fmt.Fprintf(out, "%s%d  unexamined\n", indent, sourceIndex)
		}
	}
	multipartFiles, err := observeMultipartFileSources(formPlan)
	if err != nil {
		return err
	}
	writeMultipartFileSourceReport(out, multipartFiles)

	fmt.Fprintln(out, "\nValidation:")
	missing := 0
	for _, observation := range observations {
		if observation.state == "missing" {
			fmt.Fprintf(out, "  %s: deferred (local file missing)\n", observation.invocation.Source)
			missing++
			continue
		}
		if err := validateRunnableModuleCandidate(observation.body, observation.invocation.Source, config.opts, observation.invocation.UniformValues); err != nil {
			return err
		}
		fmt.Fprintf(out, "  %s: valid\n", observation.invocation.Source)
	}
	if missing > 0 {
		suffix := "s"
		if missing == 1 {
			suffix = ""
		}
		fmt.Fprintf(out, "Pipeline compatibility: deferred (%d component%s missing locally)\n", missing, suffix)
		return nil
	}

	execCtx, cancel := wasmruntime.WithExecutionTimeout(baseCtx, time.Duration(config.timeoutMS)*time.Millisecond)
	defer cancel()
	components := make([]ResolvedComponent, len(observations))
	for i, observation := range observations {
		components[i] = ResolvedComponent{Name: observation.invocation.Source, WASM: observation.body, UniformValues: observation.invocation.UniformValues}
	}
	pipeline, err := compileResolvedComponents(execCtx, components, config.opts)
	if err != nil {
		return err
	}
	defer pipeline.Close(context.Background())
	descriptions, err := describeRunPipeline(execCtx, pipeline)
	if err != nil {
		return err
	}
	plan, err := planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{capacitiesMustFit: config.opts.capacitiesMustFit})
	if err != nil {
		return err
	}
	writeDryRunReport(out, plan)
	return nil
}

func prepareRunPipelineFromInvocations(ctx context.Context, invocations []ComponentInvocation, opts options, initialContentType string) (preparedRunPipeline, error) {
	pipeline, err := buildPipelineFromInvocations(ctx, invocations, opts)
	if err != nil {
		return preparedRunPipeline{}, err
	}
	descriptions, err := describeRunPipeline(ctx, pipeline)
	if err != nil {
		_ = pipeline.Close(context.Background())
		return preparedRunPipeline{}, err
	}
	plan, err := planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{
		capacitiesMustFit:  opts.capacitiesMustFit,
		initialContentType: initialContentType,
	})
	if err != nil {
		_ = pipeline.Close(context.Background())
		return preparedRunPipeline{}, err
	}
	return preparedRunPipeline{pipeline: pipeline, plan: plan}, nil
}

func describeRunPipeline(ctx context.Context, pipeline *qinternal.Pipeline) ([]pipelineComponentDescription, error) {
	descriptions := make([]pipelineComponentDescription, 0, len(pipeline.Stages))
	stepIndex := 0
	for pipelineStageIndex, stage := range pipeline.Stages {
		switch typed := stage.(type) {
		case *qinternal.RunStage:
			driver, ok := typed.Driver.(*wasmRunDriver)
			if !ok {
				return nil, fmt.Errorf("stage %d: unsupported run driver", pipelineStageIndex+1)
			}
			contract, err := inspectContentPipelineStep(ctx, driver, stepIndex+1)
			if err != nil {
				return nil, err
			}
			descriptions = append(descriptions, pipelineComponentDescription{
				source:  driver.modulePath,
				kind:    pipelineComponentContent,
				content: describePipelineContent(contract),
			})
			stepIndex++

		case *qinternal.TileGroupStage:
			for _, tileDriver := range typed.Drivers {
				driver, ok := tileDriver.(*wasmTileModuleDriver)
				if !ok {
					return nil, fmt.Errorf("step %d: unsupported tile driver", stepIndex+1)
				}
				descriptions = append(descriptions, pipelineComponentDescription{
					source:       driver.modulePath,
					kind:         pipelineComponentTile,
					tileInputCap: driver.inputCap,
					tileHaloPx:   driver.haloPx,
				})
				stepIndex++
			}

		default:
			return nil, fmt.Errorf("stage %d: unsupported pipeline stage %T", pipelineStageIndex+1, stage)
		}
	}
	return descriptions, nil
}

// planRunPipeline is deliberately pure: callers provide inspected component
// descriptions, and it returns the exact ordered plan used for validation,
// reporting, and execution preparation without loading or calling Wasm.
func planRunPipeline(descriptions []pipelineComponentDescription) (runPipelinePlan, error) {
	return planRunPipelineWithOptions(descriptions, runPipelinePlanningOptions{})
}

func planRunPipelineWithOptions(descriptions []pipelineComponentDescription, planningOptions runPipelinePlanningOptions) (runPipelinePlan, error) {
	var plan runPipelinePlan
	currentContentType := strings.TrimSpace(planningOptions.initialContentType)
	var currentEncoding dataEncoding
	hasCurrentEncoding := false
	previousContentOutputCap := uint64(0)
	previousWasContent := false
	previousOutputStep := 0
	previousOutputSource := ""

	for stepIndex, description := range descriptions {
		switch description.kind {
		case pipelineComponentContent:
			contract := description.content.runContract()
			if contract.inputless && stepIndex != 0 {
				return plan, fmt.Errorf("step %d %s inputless generator must be the first pipeline stage", stepIndex+1, description.source)
			}
			if hasCurrentEncoding && !pipelineEncodingAccepted(currentEncoding, contract.inputEncoding) {
				return plan, fmt.Errorf(
					"step %d %s expected UTF-8 input, got bytes from step %d %s",
					stepIndex+1,
					description.source,
					previousOutputStep,
					previousOutputSource,
				)
			}

			capacityWarning := ""
			if !contract.inputless && previousWasContent && previousContentOutputCap > contract.inputCapBytes {
				if planningOptions.capacitiesMustFit {
					return plan, fmt.Errorf(
						"step %d %s input capacity %s cannot fit step %d %s output capacity %s",
						stepIndex+1,
						description.source,
						formatBytesWithExact(contract.inputCapBytes),
						previousOutputStep,
						previousOutputSource,
						formatBytesWithExact(previousContentOutputCap),
					)
				}
				capacityWarning = fmt.Sprintf(
					"step %d %s: previous output capacity %s exceeds this input capacity %s; the run remains valid when the actual intermediate output fits",
					stepIndex+1,
					description.source,
					formatBytesWithExact(previousContentOutputCap),
					formatBytesWithExact(contract.inputCapBytes),
				)
				plan.warnings = append(plan.warnings, capacityWarning)
			}
			if !contract.inputless && contract.hasDeclaredInputContentType && (stepIndex > 0 || currentContentType != "") {
				if currentContentType == "" {
					return plan, fmt.Errorf(
						"step %d %s expected %s, but pipeline content type is unspecified",
						stepIndex+1,
						description.source,
						contract.declaredInputContentType,
					)
				}
				if mismatch := contentTypeMismatch(contract.declaredInputContentType, currentContentType); mismatch != "" {
					source := ""
					if previousOutputStep > 0 {
						source = fmt.Sprintf(" from step %d %s", previousOutputStep, previousOutputSource)
					}
					return plan, fmt.Errorf(
						"step %d %s expected %s, got %s%s: %s",
						stepIndex+1,
						description.source,
						contract.declaredInputContentType,
						incomingForMessage(contract.declaredInputContentType, currentContentType),
						source,
						mismatch,
					)
				}
			}

			effectiveInputType, outputType, err := resolveRunModuleContentType(
				contract,
				currentContentType,
				stepIndex == 0,
				ContentTypeCheckingStrong,
				description.source,
			)
			if err != nil {
				return plan, fmt.Errorf("step %d (%s): %w", stepIndex+1, description.source, err)
			}

			step := runPipelineStep{
				index:          stepIndex + 1,
				source:         description.source,
				kind:           "Content",
				inputEncoding:  dryInputEncodingName(contract),
				inputType:      effectiveInputType,
				outputEncoding: "scalar result",
				outputType:     outputType,
				inputCapBytes:  contract.inputCapBytes,
				bufferBytes:    contract.inputCapBytes,
				note:           capacityWarning,
			}
			if contract.hasOutput {
				step.outputEncoding = dryEncodingName(contract.outputEncoding)
				step.outputCapBytes = contract.outputCapBytes
				step.bufferBytes += contract.outputCapBytes
			}
			plan.steps = append(plan.steps, step)
			plan.totalBufferBytes += step.bufferBytes
			currentContentType = outputType
			currentEncoding = contract.outputEncoding
			hasCurrentEncoding = contract.hasOutput
			previousContentOutputCap = contract.outputCapBytes
			previousWasContent = contract.hasOutput
			if contract.hasOutput {
				previousOutputStep = stepIndex + 1
				previousOutputSource = description.source
			}

		case pipelineComponentTile:
			if hasCurrentEncoding && currentEncoding != dataEncodingRaw {
				return plan, fmt.Errorf("step %d (%s): tile component requires raw image/bmp bytes, got %s", stepIndex+1, description.source, dryEncodingName(currentEncoding))
			}
			if currentContentType != "" && currentContentType != "image/bmp" {
				return plan, fmt.Errorf("step %d (%s): tile component requires image/bmp input, got %q", stepIndex+1, description.source, currentContentType)
			}
			tileSpan := tileSize + 2*description.tileHaloPx
			requiredBytes := uint64(tileSpan * tileSpan * 4 * 4)
			if description.tileInputCap < requiredBytes {
				return plan, fmt.Errorf(
					"step %d (%s): tile input capacity %d bytes is smaller than the %dx%d RGBA32Float tile buffer (%d bytes)",
					stepIndex+1, description.source, description.tileInputCap, tileSpan, tileSpan, requiredBytes,
				)
			}
			step := runPipelineStep{
				index:          stepIndex + 1,
				source:         description.source,
				kind:           "Tile",
				inputEncoding:  "RGBA32Float tile",
				inputType:      "image/bmp",
				outputEncoding: "RGBA32Float tile (in-place)",
				outputType:     "image/bmp",
				inputCapBytes:  description.tileInputCap,
				outputCapBytes: description.tileInputCap,
				bufferBytes:    description.tileInputCap,
				note:           fmt.Sprintf("%dx%d tile including %d px halo", tileSpan, tileSpan, description.tileHaloPx),
			}
			plan.steps = append(plan.steps, step)
			plan.totalBufferBytes += step.bufferBytes
			currentContentType = "image/bmp"
			currentEncoding = dataEncodingRaw
			hasCurrentEncoding = true
			previousContentOutputCap = 0
			previousWasContent = false
			previousOutputStep = stepIndex + 1
			previousOutputSource = description.source

		default:
			return plan, fmt.Errorf("step %d (%s): unsupported component kind %d", stepIndex+1, description.source, description.kind)
		}
	}
	return plan, nil
}

func inspectContentPipelineStep(ctx context.Context, driver *wasmRunDriver, stepIndex int) (runModuleContract, error) {
	name := fmt.Sprintf("plan-content-%d", stepIndex)
	mod, err := driver.runtime.InstantiateModule(ctx, driver.compiled, wazero.NewModuleConfig().WithName(name))
	if err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): Wasm module could not be instantiated", stepIndex, driver.modulePath)
	}
	defer mod.Close(ctx)
	if err := applyModuleUniforms(ctx, mod, driver.uniforms); err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): %w", stepIndex, driver.modulePath, err)
	}
	contract, err := inspectRunModuleContract(ctx, mod)
	if err != nil {
		return runModuleContract{}, fmt.Errorf("step %d (%s): %w", stepIndex, driver.modulePath, err)
	}
	return contract, nil
}

func writeDryRunReport(out io.Writer, report runPipelinePlan) {
	fmt.Fprintf(out, "Pipeline compatible: %d step(s)\n", len(report.steps))
	for _, stage := range report.steps {
		fmt.Fprintf(out, "%d. %s — %s\n", stage.index, stage.source, stage.kind)
		fmt.Fprintf(out, "   Input:  encoding=%s, type=%s, capacity=%s\n", stage.inputEncoding, dryTypeName(stage.inputType), dryCapacityName(stage.inputCapBytes))
		fmt.Fprintf(out, "   Output: encoding=%s, type=%s, capacity=%s\n", stage.outputEncoding, dryTypeName(stage.outputType), dryCapacityName(stage.outputCapBytes))
		fmt.Fprintf(out, "   Buffers: %s\n", formatBytesWithExact(stage.bufferBytes))
		if stage.note != "" {
			fmt.Fprintf(out, "   Note: %s\n", stage.note)
		}
	}
	fmt.Fprintf(out, "Total declared buffer capacity: %s\n", formatBytesWithExact(report.totalBufferBytes))
	if len(report.warnings) > 0 {
		fmt.Fprintf(out, "Warnings: %d\n", len(report.warnings))
	}
}

func dryEncodingName(encoding dataEncoding) string {
	if encoding == dataEncodingUTF8 {
		return "UTF-8"
	}
	return "bytes"
}

func dryInputEncodingName(contract runModuleContract) string {
	if contract.inputless {
		return "none"
	}
	return dryEncodingName(contract.inputEncoding)
}

func pipelineEncodingAccepted(actual, expected dataEncoding) bool {
	return actual == expected || (actual == dataEncodingUTF8 && expected == dataEncodingRaw)
}

func dryTypeName(contentType string) string {
	if strings.TrimSpace(contentType) == "" {
		return "unspecified"
	}
	return contentType
}

func dryCapacityName(bytes uint64) string {
	if bytes == 0 {
		return "none"
	}
	return formatBytesWithExact(bytes)
}

func formatBytesWithExact(bytes uint64) string {
	formatted := formatBytesIEC(bytes)
	if formatted == fmt.Sprintf("%d B", bytes) {
		return formatted
	}
	return fmt.Sprintf("%s (%d bytes)", formatted, bytes)
}
