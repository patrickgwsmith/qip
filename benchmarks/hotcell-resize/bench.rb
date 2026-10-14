#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "tmpdir"
require "wasmtime"

options = { width: 1024, height: 768, warmups: 2, runs: 10, format: "png", qip_only: false }
OptionParser.new do |parser|
  parser.banner = "usage: ruby bench.rb [--qip-only] [--format png|webp-lossless|webp-lossy] [--width N] [--height N] [--warmups N] [--runs N]"
  parser.on("--qip-only") { options[:qip_only] = true }
  parser.on("--format FORMAT", %w[png webp-lossless webp-lossy]) { |value| options[:format] = value }
  parser.on("--width N", Integer) { |value| options[:width] = value }
  parser.on("--height N", Integer) { |value| options[:height] = value }
  parser.on("--warmups N", Integer) { |value| options[:warmups] = value }
  parser.on("--runs N", Integer) { |value| options[:runs] = value }
end.parse!
raise "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
raise "width and height must be positive and at most 8192" unless (1..8192).cover?(options[:width]) && (1..8192).cover?(options[:height])
raise "warmups must be nonnegative and runs must be positive" if options[:warmups].negative? || options[:runs] < 1

QIP_ONLY = options[:qip_only]

unless QIP_ONLY
  require "image_processing/vips"
  require "hot_cell/client"
end

ROOT = File.expand_path("../..", __dir__)
INPUT = File.join(ROOT, "fixtures/j-g-d-uP-haUp0YQw-unsplash.jpg")
WIDTH = options[:width]
HEIGHT = options[:height]
WARMUPS = options[:warmups]
RUNS = options[:runs]
FORMAT = options[:format]
EXTENSION = FORMAT == "png" ? "png" : "webp"
ENCODER = {
  "png" => "image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-png.wasm",
  "webp-lossless" => "image/ktx2/ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless.wasm",
  "webp-lossy" => "image/ktx2/ktx2-r8g8b8a8-srgb-to-webp-lossy.wasm",
}.fetch(FORMAT)
SAVER_OPTIONS = {
  "png" => {},
  "webp-lossless" => { lossless: true, effort: 6 },
  "webp-lossy" => { Q: 95, effort: 4, smart_subsample: true, alpha_q: 100 },
}.fetch(FORMAT).freeze
MODULES = %W[
  image/jpeg/jpeg-to-ktx2-r8g8b8a8-srgb.wasm
  image/ktx2/ktx2-r8g8b8a8-srgb-resize-down-lanczos3-simd.wasm
  #{ENCODER}
].freeze
MEMORY_LIMITS = [1_073_741_824, 1_073_741_824, FORMAT == "png" ? 1_073_741_824 : 2_147_483_648].freeze

unless QIP_ONLY
  class CellResize < HotCell::Client
    hotcell "active_storage"
    operation "active_storage.transformers.image.vips"
  end
end

class WasmStage
  def initialize(engine, path, memory_limit)
    wasm = File.binread(path)
    @module_sha256 = Digest::SHA256.hexdigest(wasm)
    mod = Wasmtime::Module.new(engine, wasm)
    @store = Wasmtime::Store.new(engine, limits: { memory_size: memory_limit })
    @store.set_epoch_deadline(300)
    @instance = Wasmtime::Instance.new(@store, mod, [])
    @memory = exported("memory").to_memory
    @input_ptr = exported("input_ptr").to_func
    @input_cap = exported("input_bytes_cap").to_func
    @render = exported("render").to_func
  end

  attr_reader :module_sha256

  def uniform(name, value)
    exported("uniform_set_#{name}").to_func.call(value)
  end

  def run(bytes)
    raise "input exceeds component capacity" if bytes.bytesize > @input_cap.call

    @memory.write(@input_ptr.call, bytes)
    @store.set_epoch_deadline(300) # 30 seconds with a 100 ms engine epoch interval.
    result = @render.call(bytes.bytesize) & 0xffff_ffff_ffff_ffff
    raise "component rejected input" unless (result >> 63).zero?

    size = result & 0xffff_ffff
    pointer = (result >> 32) & 0x7fff_ffff
    raise "component returned an invalid output range" if pointer + size > @memory.data_size

    @memory.read(pointer, size)
  end

  private

  def exported(name)
    @instance.export(name) || raise("missing Wasm export #{name}")
  end
end

def png_size(bytes)
  raise "invalid PNG output" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)
  bytes.byteslice(16, 8).unpack("N2")
end

def webp_size(bytes)
  raise "invalid WebP output" unless bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP"

  offset = 12
  while offset + 8 <= bytes.bytesize
    kind = bytes.byteslice(offset, 4)
    length = bytes.byteslice(offset + 4, 4).unpack1("V")
    data = bytes.byteslice(offset + 8, length)
    raise "truncated WebP chunk" unless data&.bytesize == length

    case kind
    when "VP8X"
      raise "short VP8X chunk" if length < 10
      return [1 + data.getbyte(4) + (data.getbyte(5) << 8) + (data.getbyte(6) << 16),
              1 + data.getbyte(7) + (data.getbyte(8) << 8) + (data.getbyte(9) << 16)]
    when "VP8L"
      raise "short VP8L chunk" if length < 5 || data.getbyte(0) != 0x2f
      bits = data.byteslice(1, 4).unpack1("V")
      return [1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff)]
    when "VP8 "
      raise "short VP8 chunk" if length < 10 || data.byteslice(3, 3) != "\x9d\x01\x2a".b
      return [data.byteslice(6, 2).unpack1("v") & 0x3fff,
              data.byteslice(8, 2).unpack1("v") & 0x3fff]
    end
    offset += 8 + length + (length & 1)
  end
  raise "WebP output has no image chunk"
end

def image_size(bytes)
  FORMAT == "png" ? png_size(bytes) : webp_size(bytes)
end

def sample
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  bytes = yield
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  raise "unexpected output size #{image_size(bytes).inspect}" unless image_size(bytes) == [WIDTH, HEIGHT]
  [elapsed, bytes]
end

def stats(values)
  ordered = values.sort
  { mean_ms: values.sum / values.size, p50_ms: ordered[(values.size - 1) / 2],
    p95_ms: ordered[((values.size - 1) * 0.95).ceil], min_ms: ordered.first,
    max_ms: ordered.last }
end

input = File.binread(INPUT)
unless QIP_ONLY
  HotCell.register "active_storage", dir: ENV.fetch("HOTCELL_DIR"), timeout: 35
  raise "HotCell socket is absent; run make cell first" unless File.socket?(File.join(ENV.fetch("HOTCELL_DIR"), "work.sock"))

  Vips.concurrency_set Integer(ENV.fetch("VIPS_CONCURRENCY", "2"))
  Vips.cache_set_max 0
  Vips.cache_set_max_mem 0
end

qip_setup_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
engine = Wasmtime::Engine.new(epoch_interruption: true)
engine.start_epoch_interval(100)
stages = MODULES.zip(MEMORY_LIMITS).map { |path, limit| WasmStage.new(engine, File.join(ROOT, path), limit) }
qip_setup_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - qip_setup_start) * 1000

Dir.mktmpdir("qip-hotcell-resize-") do |dir|
  hotcell_output = File.join(dir, "hotcell.#{EXTENSION}")
  direct_output = File.join(dir, "direct.#{EXTENSION}")
  paths = {
    "qip_wasmtime" => -> {
      stages[1].uniform("width", WIDTH)
      stages[1].uniform("height", HEIGHT)
      if FORMAT == "webp-lossless"
        stages[2].uniform("level", 6)
      elsif FORMAT == "webp-lossy"
        stages[2].uniform("quality", 95)
        stages[2].uniform("method", 4)
        stages[2].uniform("sharp_yuv", 1)
      end
      stages.reduce(File.binread(INPUT)) { |bytes, stage| stage.run(bytes) }
    },
  }
  unless QIP_ONLY
    paths["direct_vips"] = -> {
      ImageProcessing::Vips.source(INPUT).loader(page: 0).convert(EXTENSION).saver(**SAVER_OPTIONS)
        .apply(resize_to_limit: [WIDTH, HEIGHT]).call(destination: direct_output)
      File.binread(direct_output)
    }
    paths["hotcell_vips"] = -> {
      File.open(INPUT, "rb") do |source|
        File.open(hotcell_output, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |destination|
          CellResize.perform_in_hotcell [source], [destination],
                                        { format: EXTENSION, operations: { resize_to_limit: [WIDTH, HEIGHT],
                                                                           saver: SAVER_OPTIONS } }
        end
      end
      File.binread(hotcell_output)
    }
  end

  results = paths.transform_values { [] }
  outputs = {}
  final_bytes = {}
  (WARMUPS + RUNS).times do |round|
    paths.to_a.rotate(round % paths.size).each do |name, run|
      elapsed, bytes = sample(&run)
      next if round < WARMUPS

      results.fetch(name) << elapsed
      outputs[name] = { bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes) }
      final_bytes[name] = bytes
    end
  end

  output_dir = File.join(__dir__, "tmp", "results", FORMAT)
  FileUtils.mkdir_p(output_dir)
  final_bytes.each { |name, bytes| File.binwrite(File.join(output_dir, "#{name}.#{EXTENSION}"), bytes) }

  quality = nil
  unless QIP_ONLY
    raise "direct and HotCell Vips output differ" unless final_bytes.fetch("direct_vips") == final_bytes.fetch("hotcell_vips")

    qip_pixels = Vips::Image.new_from_file(File.join(output_dir, "qip_wasmtime.#{EXTENSION}"))
      .extract_band(0, n: 3)
    vips_pixels = Vips::Image.new_from_file(File.join(output_dir, "direct_vips.#{EXTENSION}"))
      .extract_band(0, n: 3)
    difference = (qip_pixels - vips_pixels).abs
    quality = { direct_and_hotcell_identical: true,
                qip_vs_vips_mean_absolute_channel_difference: difference.avg,
                qip_vs_vips_max_absolute_channel_difference: difference.max }
  end

  puts JSON.pretty_generate(
    fixture: INPUT.delete_prefix(ROOT + "/"),
    fixture_sha256: Digest::SHA256.hexdigest(input),
    dimensions: [WIDTH, HEIGHT], format: FORMAT, saver_options: SAVER_OPTIONS,
    warmups: WARMUPS, runs: RUNS,
    qip_setup_ms: qip_setup_ms,
    ruby: RUBY_DESCRIPTION, wasmtime: Gem.loaded_specs.fetch("wasmtime").version.to_s,
    hotcell: QIP_ONLY ? nil : Gem.loaded_specs.fetch("hotcell-client").version.to_s,
    vips_concurrency: QIP_ONLY ? nil : Vips.concurrency,
    libvips: QIP_ONLY ? nil : Vips.version_string,
    modules: MODULES.zip(stages.map(&:module_sha256)).to_h,
    wasm_memory_limits: MODULES.zip(MEMORY_LIMITS).to_h,
    quality: quality,
    results: results.to_h { |name, values| [name, stats(values).merge(outputs.fetch(name))] },
  )
end

engine.stop_epoch_interval
