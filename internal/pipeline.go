package qinternal

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"strings"
	"time"
	"unicode/utf8"
)

// --- BMP Parsing Helpers (moved from main) ---

func DecodeBMPToRGBA(input []byte) (*image.RGBA, error) {
	if len(input) < 54 {
		return nil, errors.New("BMP input too small")
	}
	if input[0] != 'B' || input[1] != 'M' {
		return nil, errors.New("Input is not a BMP file")
	}

	dataOffset := int(binary.LittleEndian.Uint32(input[10:14]))
	dibSize := int(binary.LittleEndian.Uint32(input[14:18]))
	if dibSize < 40 {
		return nil, errors.New("Unsupported BMP DIB header")
	}
	width := int32(binary.LittleEndian.Uint32(input[18:22]))
	height := int32(binary.LittleEndian.Uint32(input[22:26]))
	planes := binary.LittleEndian.Uint16(input[26:28])
	bpp := binary.LittleEndian.Uint16(input[28:30])
	compression := binary.LittleEndian.Uint32(input[30:34])

	if width <= 0 || height == 0 {
		return nil, errors.New("Unsupported BMP dimensions")
	}
	if planes != 1 {
		return nil, errors.New("Unsupported BMP planes")
	}
	if compression != 0 {
		return nil, errors.New("Unsupported BMP compression")
	}
	if bpp != 24 && bpp != 32 {
		return nil, errors.New("Unsupported BMP bit depth")
	}

	topDown := false
	absHeight := int(height)
	if height < 0 {
		topDown = true
		absHeight = -absHeight
	}
	absWidth := int(width)
	if absWidth <= 0 || absHeight <= 0 {
		return nil, errors.New("Unsupported BMP dimensions")
	}

	bytesPerPixel := int(bpp / 8)
	rowStride := absWidth * bytesPerPixel
	if bpp == 24 {
		if rem := rowStride % 4; rem != 0 {
			rowStride += 4 - rem
		}
	}

	if dataOffset < 0 || dataOffset > len(input) {
		return nil, errors.New("Invalid BMP data offset")
	}
	if dataOffset+rowStride*absHeight > len(input) {
		return nil, errors.New("BMP pixel data out of range")
	}

	img := image.NewRGBA(image.Rect(0, 0, absWidth, absHeight))
	for y := 0; y < absHeight; y++ {
		srcY := y
		if !topDown {
			srcY = absHeight - 1 - y
		}
		srcRow := dataOffset + srcY*rowStride
		for x := range absWidth {
			s := srcRow + x*bytesPerPixel
			b := input[s]
			g := input[s+1]
			r := input[s+2]
			a := byte(0xFF)
			if bytesPerPixel == 4 {
				a = input[s+3]
			}
			d := img.PixOffset(x, y)
			img.Pix[d] = r
			img.Pix[d+1] = g
			img.Pix[d+2] = b
			img.Pix[d+3] = a
		}
	}

	return img, nil
}

func EncodeRGBAToBMP(img *image.RGBA) ([]byte, error) {
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()
	if width <= 0 || height <= 0 {
		return nil, errors.New("Invalid BMP image size")
	}

	rowStride := width * 4
	dataSize := rowStride * height
	fileSize := 14 + 40 + dataSize
	buf := make([]byte, fileSize)
	buf[0] = 'B'
	buf[1] = 'M'
	binary.LittleEndian.PutUint32(buf[2:], uint32(fileSize))
	binary.LittleEndian.PutUint32(buf[10:], 54)
	binary.LittleEndian.PutUint32(buf[14:], 40)
	binary.LittleEndian.PutUint32(buf[18:], uint32(width))
	binary.LittleEndian.PutUint32(buf[22:], uint32(height))
	binary.LittleEndian.PutUint16(buf[26:], 1)
	binary.LittleEndian.PutUint16(buf[28:], 32)
	binary.LittleEndian.PutUint32(buf[30:], 0)
	binary.LittleEndian.PutUint32(buf[34:], uint32(dataSize))

	for y := range height {
		srcY := height - 1 - y
		for x := range width {
			s := img.PixOffset(bounds.Min.X+x, bounds.Min.Y+srcY)
			d := 54 + y*rowStride + x*4
			buf[d] = img.Pix[s+2]
			buf[d+1] = img.Pix[s+1]
			buf[d+2] = img.Pix[s]
			buf[d+3] = img.Pix[s+3]
		}
	}

	return buf, nil
}

type Encoding int

const (
	EncodingRawBytes Encoding = iota
	EncodingUTF8
	EncodingBMP
	EncodingRGBAF32
)

func (e Encoding) String() string {
	switch e {
	case EncodingRawBytes:
		return "raw"
	case EncodingUTF8:
		return "utf8"
	case EncodingBMP:
		return "bmp"
	case EncodingRGBAF32:
		return "rgba32float"
	default:
		return fmt.Sprintf("unknown(%d)", int(e))
	}
}

// Content is the base interface for all data flowing through the pipeline.
type Content interface {
	Encoding() Encoding
}

// RawBytesContent provides access to raw data.
type RawBytesContent interface {
	Content
	RawBytes() []byte
}

// StringContent provides access to UTF-8 string data.
type StringContent interface {
	Content
	String() string
}

// ImageContent provides metadata for image-based data.
type ImageContent interface {
	Content
	Width() int
	Height() int
}

// BMPContent is a specialization for BMP file data.
type BMPContent interface {
	RawBytesContent
	ImageContent
}

// RGBAF32Content is high-precision float pixel data used for tile processing.
type RGBAF32Content interface {
	ImageContent
	Pixels() []float32
}

type contentTypeWrapper interface {
	Content
	unwrapContent() Content
}

type rawBytesWithContentType struct {
	RawBytesContent
	contentType string
}

func (c *rawBytesWithContentType) ContentType() string { return c.contentType }
func (c *rawBytesWithContentType) unwrapContent() Content {
	return c.RawBytesContent
}

type stringWithContentType struct {
	StringContent
	contentType string
}

func (c *stringWithContentType) ContentType() string { return c.contentType }
func (c *stringWithContentType) unwrapContent() Content {
	return c.StringContent
}

type bmpWithContentType struct {
	BMPContent
	contentType string
}

func (c *bmpWithContentType) ContentType() string { return c.contentType }
func (c *bmpWithContentType) unwrapContent() Content {
	return c.BMPContent
}

type rgbaf32WithContentType struct {
	RGBAF32Content
	contentType string
}

func (c *rgbaf32WithContentType) ContentType() string { return c.contentType }
func (c *rgbaf32WithContentType) unwrapContent() Content {
	return c.RGBAF32Content
}

type contentWithContentType struct {
	Content
	contentType string
}

func (c *contentWithContentType) ContentType() string { return c.contentType }
func (c *contentWithContentType) unwrapContent() Content {
	return c.Content
}

type contentTypeCarrier interface {
	ContentType() string
}

func ContentTypeOf(content Content) string {
	if content == nil {
		return ""
	}
	if carrier, ok := content.(contentTypeCarrier); ok {
		return carrier.ContentType()
	}
	return ""
}

func ContentByteSize(content Content) int {
	if content == nil {
		return 0
	}
	if raw, ok := content.(RawBytesContent); ok {
		return len(raw.RawBytes())
	}
	if text, ok := content.(StringContent); ok {
		return len(text.String())
	}
	if rgba, ok := content.(RGBAF32Content); ok {
		return len(rgba.Pixels()) * 4
	}
	return 0
}

func contentEncoding(content Content) Encoding {
	if content == nil {
		return EncodingRawBytes
	}
	return content.Encoding()
}

func stageLabel(stage Stage) string {
	if labeled, ok := stage.(labeledStage); ok {
		return labeled.Label()
	}
	return fmt.Sprintf("stage-%T", stage)
}

func unwrapContent(content Content) Content {
	cur := content
	for {
		wrapped, ok := cur.(contentTypeWrapper)
		if !ok {
			return cur
		}
		cur = wrapped.unwrapContent()
	}
}

func WithContentType(content Content, contentType string) Content {
	if content == nil {
		return nil
	}
	base := unwrapContent(content)
	if contentType == "" {
		return base
	}

	switch c := base.(type) {
	case BMPContent:
		return &bmpWithContentType{BMPContent: c, contentType: contentType}
	case RGBAF32Content:
		return &rgbaf32WithContentType{RGBAF32Content: c, contentType: contentType}
	case StringContent:
		return &stringWithContentType{StringContent: c, contentType: contentType}
	case RawBytesContent:
		return &rawBytesWithContentType{RawBytesContent: c, contentType: contentType}
	default:
		return &contentWithContentType{Content: c, contentType: contentType}
	}
}

// --- Implementations ---

type rawBytesContent struct {
	data []byte
}

func (c *rawBytesContent) Encoding() Encoding { return EncodingRawBytes }
func (c *rawBytesContent) RawBytes() []byte   { return c.data }

func NewRawBytesContent(data []byte) RawBytesContent {
	return &rawBytesContent{data: data}
}

func NewRawBytesContentWithType(data []byte, contentType string) RawBytesContent {
	content := WithContentType(NewRawBytesContent(data), contentType)
	if wrapped, ok := content.(RawBytesContent); ok {
		return wrapped
	}
	return NewRawBytesContent(data)
}

type stringContent struct {
	data string
}

func (c *stringContent) Encoding() Encoding { return EncodingUTF8 }
func (c *stringContent) String() string     { return c.data }

func NewStringContent(data string) StringContent {
	return &stringContent{data: data}
}

func NewStringContentWithType(data string, contentType string) StringContent {
	content := WithContentType(NewStringContent(data), contentType)
	if wrapped, ok := content.(StringContent); ok {
		return wrapped
	}
	return NewStringContent(data)
}

type bmpContent struct {
	data          []byte
	width, height int
}

func (c *bmpContent) Encoding() Encoding { return EncodingBMP }
func (c *bmpContent) RawBytes() []byte   { return c.data }
func (c *bmpContent) Width() int         { return c.width }
func (c *bmpContent) Height() int        { return c.height }

func NewBMPContent(data []byte, width, height int) BMPContent {
	return &bmpContent{data: data, width: width, height: height}
}

func NewBMPContentWithType(data []byte, width, height int, contentType string) BMPContent {
	content := WithContentType(NewBMPContent(data, width, height), contentType)
	if wrapped, ok := content.(BMPContent); ok {
		return wrapped
	}
	return NewBMPContent(data, width, height)
}

type rgbaf32Content struct {
	pixels        []float32
	width, height int
}

func (c *rgbaf32Content) Encoding() Encoding { return EncodingRGBAF32 }
func (c *rgbaf32Content) Pixels() []float32  { return c.pixels }
func (c *rgbaf32Content) Width() int         { return c.width }
func (c *rgbaf32Content) Height() int        { return c.height }

func NewRGBAF32Content(pixels []float32, width, height int) RGBAF32Content {
	return &rgbaf32Content{pixels: pixels, width: width, height: height}
}

func NewRGBAF32ContentWithType(pixels []float32, width, height int, contentType string) RGBAF32Content {
	content := WithContentType(NewRGBAF32Content(pixels, width, height), contentType)
	if wrapped, ok := content.(RGBAF32Content); ok {
		return wrapped
	}
	return NewRGBAF32Content(pixels, width, height)
}

// --- Coercion Helpers ---

func AsRawBytes(c Content) ([]byte, error) {
	if b, ok := c.(RawBytesContent); ok {
		return b.RawBytes(), nil
	}
	if s, ok := c.(StringContent); ok {
		return []byte(s.String()), nil
	}
	return nil, fmt.Errorf("cannot treat %s as raw bytes", c.Encoding())
}

func ToUTF8Content(c Content) (StringContent, error) {
	if s, ok := c.(StringContent); ok {
		return s, nil
	}
	data, err := AsRawBytes(c)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("content is not valid UTF-8")
	}
	return NewStringContentWithType(string(data), ContentTypeOf(c)), nil
}

func ToBMPContent(c Content) (BMPContent, error) {
	if b, ok := c.(BMPContent); ok {
		return b, nil
	}
	if r, ok := c.(RawBytesContent); ok {
		data := r.RawBytes()
		width, height, err := GetBMPDimensions(data)
		if err != nil {
			return nil, fmt.Errorf("invalid BMP data: %w", err)
		}
		return NewBMPContentWithType(data, width, height, ContentTypeOf(c)), nil
	}
	// If it's RGBAF32, we need to encode it
	if rgba, ok := c.(RGBAF32Content); ok {
		img := RGBAF32ToRGBA(rgba)
		data, err := EncodeRGBAToBMP(img)
		if err != nil {
			return nil, err
		}
		return NewBMPContentWithType(data, rgba.Width(), rgba.Height(), ContentTypeOf(c)), nil
	}
	return nil, fmt.Errorf("cannot convert %s to BMP", c.Encoding())
}

func GetBMPDimensions(data []byte) (int, int, error) {
	if len(data) < 26 {
		return 0, 0, errors.New("BMP data too short")
	}
	if data[0] != 'B' || data[1] != 'M' {
		return 0, 0, errors.New("not a BMP file")
	}
	width := int(binary.LittleEndian.Uint32(data[18:22]))
	height := int(int32(binary.LittleEndian.Uint32(data[22:26])))
	if height < 0 {
		height = -height
	}
	return width, height, nil
}

func RGBAF32ToRGBA(rgba RGBAF32Content) *image.RGBA {
	width, height := rgba.Width(), rgba.Height()
	out := image.NewRGBA(image.Rect(0, 0, width, height))
	pixels := rgba.Pixels()
	for y := range height {
		for x := range width {
			base := (y*width + x) * 4
			d := out.PixOffset(x, y)
			out.Pix[d] = clampToUint8(pixels[base])
			out.Pix[d+1] = clampToUint8(pixels[base+1])
			out.Pix[d+2] = clampToUint8(pixels[base+2])
			out.Pix[d+3] = clampToUint8(pixels[base+3])
		}
	}
	return out
}

func clampToUint8(f float32) uint8 {
	if f <= 0 {
		return 0
	}
	if f >= 1 {
		return 255
	}
	return uint8(f*255 + 0.5)
}

func RGBAToRGBAF32(img *image.RGBA) []float32 {
	bounds := img.Bounds()
	width, height := bounds.Dx(), bounds.Dy()
	pixels := make([]float32, width*height*4)
	const inv255 = 1.0 / 255.0
	for y := range height {
		for x := range width {
			s := img.PixOffset(x, y)
			d := (y*width + x) * 4
			pixels[d] = float32(img.Pix[s]) * inv255
			pixels[d+1] = float32(img.Pix[s+1]) * inv255
			pixels[d+2] = float32(img.Pix[s+2]) * inv255
			pixels[d+3] = float32(img.Pix[s+3]) * inv255
		}
	}
	return pixels
}

type Pipeline struct {
	Stages    []Stage
	CloseFunc func(ctx context.Context) error
}

type PipelineTraceStep struct {
	StageIndex        int
	StageLabel        string
	InputEncoding     Encoding
	InputContentType  string
	InputBytes        int
	OutputEncoding    Encoding
	OutputContentType string
	OutputBytes       int
	Duration          time.Duration
}

type PipelineTraceFunc func(PipelineTraceStep)

type pipelineTraceContextKey struct{}

func WithPipelineTrace(ctx context.Context, trace PipelineTraceFunc) context.Context {
	if trace == nil {
		return ctx
	}
	return context.WithValue(ctx, pipelineTraceContextKey{}, trace)
}

func pipelineTraceFromContext(ctx context.Context) PipelineTraceFunc {
	trace, _ := ctx.Value(pipelineTraceContextKey{}).(PipelineTraceFunc)
	return trace
}

func (p *Pipeline) Process(ctx context.Context, input Content, requestID uint64) (Content, error) {
	var cur = input
	trace := pipelineTraceFromContext(ctx)
	for i, stage := range p.Stages {
		inputBytes := ContentByteSize(cur)
		inputEncoding := contentEncoding(cur)
		inputContentType := ContentTypeOf(cur)
		start := time.Now()
		next, err := stage.Process(ctx, cur, requestID)
		duration := time.Since(start)
		if err != nil {
			return nil, fmt.Errorf("step %d %s %w", i+1, stageLabel(stage), err)
		}
		if trace != nil {
			trace(PipelineTraceStep{
				StageIndex:        i,
				StageLabel:        stageLabel(stage),
				InputEncoding:     inputEncoding,
				InputContentType:  inputContentType,
				InputBytes:        inputBytes,
				OutputEncoding:    contentEncoding(next),
				OutputContentType: ContentTypeOf(next),
				OutputBytes:       ContentByteSize(next),
				Duration:          duration,
			})
		}
		cur = next
	}
	return cur, nil
}

func (p *Pipeline) Close(ctx context.Context) error {
	for _, stage := range p.Stages {
		_ = stage.Close(ctx)
	}
	if p.CloseFunc != nil {
		_ = p.CloseFunc(ctx)
	}
	return nil
}

// --- Stage Interface ---

type Stage interface {
	Process(ctx context.Context, input Content, requestID uint64) (Content, error)
	Close(ctx context.Context) error
}

type labeledStage interface {
	Label() string
}

// ModuleDriver defines the interface for executing a specific type of Wasm module.
type ModuleDriver interface {
	Execute(ctx context.Context, input Content, requestID uint64) (Content, error)
	Close(ctx context.Context) error
}

type labeledModuleDriver interface {
	Label() string
}

type RunStage struct {
	Driver ModuleDriver
}

func (s *RunStage) Process(ctx context.Context, input Content, requestID uint64) (Content, error) {
	return s.Driver.Execute(ctx, input, requestID)
}

func (s *RunStage) Close(ctx context.Context) error {
	return s.Driver.Close(ctx)
}

func (s *RunStage) Label() string {
	if labeled, ok := s.Driver.(labeledModuleDriver); ok {
		return labeled.Label()
	}
	return "run"
}

// WasmRunDriver implements ModuleDriver for a single 'run' Wasm module.
type WasmRunDriver struct {
	RunFunc   func(ctx context.Context, input []byte, requestID uint64) (Content, error)
	CloseFunc func(ctx context.Context) error
}

func (d *WasmRunDriver) Execute(ctx context.Context, input Content, requestID uint64) (Content, error) {
	data, err := AsRawBytes(input)
	if err != nil {
		return nil, err
	}
	return d.RunFunc(ctx, data, requestID)
}

func (d *WasmRunDriver) Close(ctx context.Context) error {
	return d.CloseFunc(ctx)
}

type TileModuleDriver interface {
	ExecuteTile(ctx context.Context, x, y float32, tilePixels []float32) ([]float32, error)
	SetImageSize(ctx context.Context, width, height int) error
	Close(ctx context.Context) error
	HaloPx() int
}

type labeledTileModuleDriver interface {
	Label() string
}

// WasmTileModuleDriver implements TileModuleDriver for a 'tile' Wasm module.
type WasmTileModuleDriver struct {
	TileFunc    func(ctx context.Context, x, y float32, tilePixels []float32) ([]float32, error)
	SetSizeFunc func(ctx context.Context, width, height int) error
	CloseFunc   func(ctx context.Context) error
	HaloValue   int
}

func (d *WasmTileModuleDriver) ExecuteTile(ctx context.Context, x, y float32, tilePixels []float32) ([]float32, error) {
	return d.TileFunc(ctx, x, y, tilePixels)
}

func (d *WasmTileModuleDriver) SetImageSize(ctx context.Context, width, height int) error {
	if d.SetSizeFunc == nil {
		return nil
	}
	return d.SetSizeFunc(ctx, width, height)
}

func (d *WasmTileModuleDriver) Close(ctx context.Context) error {
	return d.CloseFunc(ctx)
}

func (d *WasmTileModuleDriver) HaloPx() int {
	if d.HaloValue < 0 {
		return 0
	}
	return d.HaloValue
}

type TileGroupStage struct {
	Drivers []TileModuleDriver
}

func (s *TileGroupStage) Label() string {
	if len(s.Drivers) == 0 {
		return "tile-group"
	}
	labels := make([]string, 0, len(s.Drivers))
	for _, driver := range s.Drivers {
		if labeled, ok := driver.(labeledTileModuleDriver); ok {
			labels = append(labels, labeled.Label())
		} else {
			labels = append(labels, "tile")
		}
	}
	return strings.Join(labels, " | ")
}

func (s *TileGroupStage) Process(ctx context.Context, input Content, requestID uint64) (Content, error) {
	img, ok := input.(ImageContent)
	if !ok {
		bmp, err := ToBMPContent(input)
		if err != nil {
			return nil, fmt.Errorf("tile stage requires image input, got %s", input.Encoding())
		}
		input = bmp
		img = bmp
	}

	if len(s.Drivers) == 0 {
		return input, nil
	}

	width, height := img.Width(), img.Height()
	var pixels []float32
	if r, ok := input.(RGBAF32Content); ok {
		pixels = r.Pixels()
	} else if b, ok := input.(BMPContent); ok {
		rgba, err := DecodeBMPToRGBA(b.RawBytes())
		if err != nil {
			return nil, err
		}
		pixels = RGBAToRGBAF32(rgba)
	} else {
		return nil, fmt.Errorf("unsupported image encoding for tiling: %s", input.Encoding())
	}

	tileSize := 64
	outputPixels := make([]float32, len(pixels))

	for _, driver := range s.Drivers {
		if err := driver.SetImageSize(ctx, width, height); err != nil {
			return nil, err
		}

		halo := max(driver.HaloPx(), 0)
		tileSpan := tileSize + halo*2
		expectedLen := tileSpan * tileSpan * 4

		for y := 0; y < height; y += tileSize {
			tileH := tileSize
			if y+tileH > height {
				tileH = height - y
			}
			for x := 0; x < width; x += tileSize {
				tileW := tileSize
				if x+tileW > width {
					tileW = width - x
				}

				// Extract tile with halo
				tileBuffer := make([]float32, expectedLen)
				for row := range tileSpan {
					srcY := y + row - halo
					if srcY < 0 {
						srcY = 0
					} else if srcY >= height {
						srcY = height - 1
					}
					for col := range tileSpan {
						srcX := x + col - halo
						if srcX < 0 {
							srcX = 0
						} else if srcX >= width {
							srcX = width - 1
						}

						srcIdx := (srcY*width + srcX) * 4
						dstIdx := (row*tileSpan + col) * 4
						copy(tileBuffer[dstIdx:dstIdx+4], pixels[srcIdx:srcIdx+4])
					}
				}

				// Execute tile wasm
				processedTile, err := driver.ExecuteTile(ctx, float32(x-halo), float32(y-halo), tileBuffer)
				if err != nil {
					return nil, err
				}
				if len(processedTile) != expectedLen {
					return nil, fmt.Errorf("driver returned malformed tile: expected %d floats, got %d", expectedLen, len(processedTile))
				}

				// Copy center back to output
				srcBase := (halo*tileSpan + halo) * 4
				for row := 0; row < tileH; row++ {
					srcRowIdx := srcBase + row*tileSpan*4
					dstRowIdx := ((y+row)*width + x) * 4
					copy(outputPixels[dstRowIdx:dstRowIdx+tileW*4], processedTile[srcRowIdx:srcRowIdx+tileW*4])
				}
			}
		}
		// Swap buffers for next driver in group
		copy(pixels, outputPixels)
	}

	return NewRGBAF32ContentWithType(outputPixels, width, height, ContentTypeOf(input)), nil
}

func (s *TileGroupStage) Close(ctx context.Context) error {
	for _, d := range s.Drivers {
		_ = d.Close(ctx)
	}
	return nil
}
