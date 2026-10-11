//! JPEG XL to canonical RGBA8 sRGB KTX2 as a QIP Content component.
//!
//! Decoding uses jxl-rs (`jxl` 0.7.4), the Rust decoder used by Chromium and
//! Firefox. The decoder writes top-down RGBA8 rows directly into the KTX2
//! payload. Every heap allocation comes from a fixed reclaiming arena, so the
//! module never calls `memory.grow`.

#![no_main]

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use jxl::api::{
    JxlColorEncoding, JxlColorProfile, JxlDecoder, JxlDecoderOptions, JxlOutputBuffer,
    JxlPixelFormat, JxlPrimaries, JxlTransferFunction, JxlWhitePoint, ProcessingResult,
};

const INPUT_CAP: usize = 64 * 1024 * 1024;
const MAX_PIXELS: usize = 25_000_000;
const MAX_DIMENSION: usize = 8192;
const KTX2_HEADER_SIZE: usize = 224;
const OUTPUT_CAP: usize = KTX2_HEADER_SIZE + MAX_PIXELS * 4;
const HEAP_CAP: usize = 256 * 1024 * 1024;
// jxl-rs's static tables used about 2 MiB during development.
const STATIC_TABLES_CAP: usize = 8 * 1024 * 1024;
const INPUT_CONTENT_TYPE: &[u8] = b"image/jxl";
const OUTPUT_CONTENT_TYPE: &[u8] = b"image/ktx2";

#[repr(align(64))]
struct Storage<const N: usize>(UnsafeCell<[u8; N]>);

// QIP components execute on one Wasm thread.
unsafe impl<const N: usize> Sync for Storage<N> {}

static INPUT: Storage<INPUT_CAP> = Storage(UnsafeCell::new([0; INPUT_CAP]));
static OUTPUT: Storage<OUTPUT_CAP> = Storage(UnsafeCell::new([0; OUTPUT_CAP]));
static HEAP: Storage<HEAP_CAP> = Storage(UnsafeCell::new([0; HEAP_CAP]));

fn heap_base() -> *mut u8 {
    HEAP.0.get().cast::<u8>()
}

// A first-fit free list over HEAP, the same design as the C components'
// arenas. Each block starts with a 16-byte header. Allocations aligned to more
// than 16 bytes over-allocate and store the block payload address in the four
// bytes before the aligned pointer.
//
// The arena is not reset between render calls. jxl-rs keeps lazily built
// tables (coefficient orders, quantization weights, the dither table) in
// process-lifetime statics, so those allocations must survive later calls.
const BLOCK_HEADER: usize = 16;
const NO_BLOCK: u32 = u32::MAX;

#[repr(C)]
struct Block {
    size: u32,
    next: u32,
    prev: u32,
    is_free: u32,
}

struct ArenaState {
    initialized: bool,
    used: usize,
    peak: usize,
    allocations: usize,
    largest: usize,
    failed: usize,
}

struct Arena(UnsafeCell<ArenaState>);

unsafe impl Sync for Arena {}

#[global_allocator]
static ARENA: Arena = Arena(UnsafeCell::new(ArenaState {
    initialized: false,
    used: 0,
    peak: 0,
    allocations: 0,
    largest: 0,
    failed: 0,
}));

unsafe fn block_at(offset: u32) -> *mut Block {
    unsafe { heap_base().add(offset as usize).cast::<Block>() }
}

impl Arena {
    fn state(&self) -> &mut ArenaState {
        unsafe { &mut *self.0.get() }
    }

    // Telemetry describes one render call. Live bytes include the statics.
    fn begin_call(&self) {
        let state = self.state();
        state.peak = state.used;
        state.allocations = 0;
        state.largest = 0;
        state.failed = 0;
    }

    fn initialize(&self) {
        self.state().initialized = true;
        unsafe {
            let first = block_at(0);
            (*first).size = (HEAP_CAP - BLOCK_HEADER) as u32;
            (*first).next = NO_BLOCK;
            (*first).prev = NO_BLOCK;
            (*first).is_free = 1;
        }
    }

    unsafe fn alloc_block(&self, size: usize) -> *mut u8 {
        if !self.state().initialized {
            self.initialize();
        }
        let state = self.state();
        let wanted = match size.max(1).checked_add(15) {
            Some(value) if value <= u32::MAX as usize => (value & !15) as u32,
            _ => {
                state.failed = size;
                return core::ptr::null_mut();
            }
        };
        let mut offset = 0u32;
        unsafe {
            while offset != NO_BLOCK {
                let block = block_at(offset);
                if (*block).is_free != 0 && (*block).size >= wanted {
                    break;
                }
                offset = (*block).next;
            }
            if offset == NO_BLOCK {
                state.failed = size;
                return core::ptr::null_mut();
            }
            let block = block_at(offset);
            if (*block).size as usize >= wanted as usize + BLOCK_HEADER + 16 {
                let split_offset = offset + BLOCK_HEADER as u32 + wanted;
                let split = block_at(split_offset);
                (*split).size = (*block).size - wanted - BLOCK_HEADER as u32;
                (*split).next = (*block).next;
                (*split).prev = offset;
                (*split).is_free = 1;
                if (*block).next != NO_BLOCK {
                    (*block_at((*block).next)).prev = split_offset;
                }
                (*block).next = split_offset;
                (*block).size = wanted;
            }
            (*block).is_free = 0;
            state.used += (*block).size as usize;
            state.peak = state.peak.max(state.used);
            state.largest = state.largest.max(size);
            state.allocations += 1;
            heap_base().add(offset as usize + BLOCK_HEADER)
        }
    }

    unsafe fn free_block(&self, payload: *mut u8) {
        let state = self.state();
        unsafe {
            let offset = (payload.offset_from(heap_base()) as usize - BLOCK_HEADER) as u32;
            let block = block_at(offset);
            (*block).is_free = 1;
            state.used -= (*block).size as usize;
            let next_offset = (*block).next;
            if next_offset != NO_BLOCK {
                let next = block_at(next_offset);
                if (*next).is_free != 0 {
                    (*block).size += BLOCK_HEADER as u32 + (*next).size;
                    (*block).next = (*next).next;
                    if (*next).next != NO_BLOCK {
                        (*block_at((*next).next)).prev = offset;
                    }
                }
            }
            let prev_offset = (*block).prev;
            if prev_offset != NO_BLOCK {
                let prev = block_at(prev_offset);
                if (*prev).is_free != 0 {
                    (*prev).size += BLOCK_HEADER as u32 + (*block).size;
                    (*prev).next = (*block).next;
                    if (*block).next != NO_BLOCK {
                        (*block_at((*block).next)).prev = prev_offset;
                    }
                }
            }
        }
    }
}

unsafe impl GlobalAlloc for Arena {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if layout.align() <= 16 {
            return unsafe { self.alloc_block(layout.size()) };
        }
        let Some(padded) = layout.size().checked_add(layout.align()) else {
            self.state().failed = layout.size();
            return core::ptr::null_mut();
        };
        unsafe {
            let payload = self.alloc_block(padded);
            if payload.is_null() {
                return payload;
            }
            // `payload` is 16-byte aligned, so the aligned pointer is at least
            // 16 bytes past it and has room for the back pointer.
            let aligned = payload.add(layout.align() - (payload as usize & (layout.align() - 1)));
            aligned.sub(4).cast::<u32>().write(payload as u32);
            aligned
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe {
            let payload = if layout.align() <= 16 {
                ptr
            } else {
                ptr.sub(4).cast::<u32>().read() as usize as *mut u8
            };
            self.free_block(payload);
        }
    }
}

fn input_address() -> u32 {
    INPUT.0.get() as u32
}

fn output_address() -> u32 {
    OUTPUT.0.get() as u32
}

fn packed_result(size: usize) -> u64 {
    ((output_address() as u64) << 32) | size as u64
}

#[unsafe(no_mangle)]
pub extern "C" fn input_ptr() -> u32 {
    input_address()
}

#[unsafe(no_mangle)]
pub extern "C" fn input_bytes_cap() -> u32 {
    INPUT_CAP as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn output_bytes_cap() -> u32 {
    OUTPUT_CAP as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn input_content_type_ptr() -> u32 {
    INPUT_CONTENT_TYPE.as_ptr() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn input_content_type_size() -> u32 {
    INPUT_CONTENT_TYPE.len() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn output_content_type_ptr() -> u32 {
    OUTPUT_CONTENT_TYPE.as_ptr() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn output_content_type_size() -> u32 {
    OUTPUT_CONTENT_TYPE.len() as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn arena_peak_bytes() -> u32 {
    ARENA.state().peak as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn arena_live_bytes() -> u32 {
    ARENA.state().used as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn arena_allocation_count() -> u32 {
    ARENA.state().allocations as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn arena_largest_allocation() -> u32 {
    ARENA.state().largest as u32
}

#[unsafe(no_mangle)]
pub extern "C" fn arena_failed_allocation() -> u32 {
    ARENA.state().failed as u32
}

const KTX2_IDENTIFIER: [u8; 12] = [
    0xab, b'K', b'T', b'X', b' ', b'2', b'0', 0xbb, 0x0d, 0x0a, 0x1a, 0x0a,
];

const KTX2_RGBA8_DFD: [u8; 92] = [
    0x5c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x58, 0x00, 0x01, 0x01, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x08, 0x00, 0x07, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x10, 0x00, 0x07, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00, 0x18, 0x00, 0x07, 0x1f,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
];

const KTX2_RGBA8_KVD: [u8; 24] = [
    0x12, 0x00, 0x00, 0x00, b'K', b'T', b'X', b'o', b'r', b'i', b'e', b'n', b't', b'a', b't', b'i',
    b'o', b'n', 0x00, b'r', b'd', 0x00, 0x00, 0x00,
];

fn write_ktx2_header(output: &mut [u8], width: u32, height: u32, pixel_bytes: u64) {
    let header = &mut output[..KTX2_HEADER_SIZE];
    header.fill(0);
    let mut put32 = |offset: usize, value: u32| {
        header[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    };
    put32(12, 43); // VK_FORMAT_R8G8B8A8_SRGB
    put32(16, 1);
    put32(20, width);
    put32(24, height);
    put32(36, 1);
    put32(40, 1);
    put32(48, 104);
    put32(52, KTX2_RGBA8_DFD.len() as u32);
    put32(56, 196);
    put32(60, KTX2_RGBA8_KVD.len() as u32);
    header[0..12].copy_from_slice(&KTX2_IDENTIFIER);
    header[80..88].copy_from_slice(&(KTX2_HEADER_SIZE as u64).to_le_bytes());
    header[88..96].copy_from_slice(&pixel_bytes.to_le_bytes());
    header[96..104].copy_from_slice(&pixel_bytes.to_le_bytes());
    header[104..196].copy_from_slice(&KTX2_RGBA8_DFD);
    header[196..220].copy_from_slice(&KTX2_RGBA8_KVD);
}

// Without a colour management system, accept only output that is already
// sRGB. XYB images can always be rendered to sRGB; others keep their embedded
// encoding.
fn is_srgb_output(profile: &JxlColorProfile) -> bool {
    match profile {
        JxlColorProfile::Simple(JxlColorEncoding::RgbColorSpace {
            white_point: JxlWhitePoint::D65,
            primaries: JxlPrimaries::SRGB,
            transfer_function: JxlTransferFunction::SRGB,
            ..
        }) => true,
        JxlColorProfile::Simple(JxlColorEncoding::GrayscaleColorSpace {
            white_point: JxlWhitePoint::D65,
            transfer_function: JxlTransferFunction::SRGB,
            ..
        }) => true,
        _ => false,
    }
}

fn decode(input: &[u8], output: &mut [u8]) -> Option<usize> {
    let mut options = JxlDecoderOptions::default();
    options.sample_limit = Some(MAX_PIXELS * 4);
    let mut remaining = input;

    let mut decoder = match JxlDecoder::new(options).process(&mut remaining, None).ok()? {
        ProcessingResult::Complete { result } => result,
        ProcessingResult::NeedsMoreInput { .. } => return None,
    };
    let info = decoder.basic_info();
    let (width, height) = info.size;
    if info.animation.is_some()
        || width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
        || width * height > MAX_PIXELS
    {
        return None;
    }
    let extra_channels = info.extra_channels.len();
    decoder.set_pixel_format(JxlPixelFormat::rgba8(extra_channels)).ok()?;
    if !is_srgb_output(decoder.output_color_profile()) {
        return None;
    }

    let decoder = match decoder.process(&mut remaining, None).ok()? {
        ProcessingResult::Complete { result } => result,
        ProcessingResult::NeedsMoreInput { .. } => return None,
    };
    let (frame_width, frame_height) = decoder.frame_header().size;
    if frame_width != width || frame_height != height {
        return None;
    }

    let row_bytes = width * 4;
    let pixel_bytes = row_bytes * height;
    let (header, pixels) = output.split_at_mut(KTX2_HEADER_SIZE);
    let mut buffers = [JxlOutputBuffer::new(&mut pixels[..pixel_bytes], height, row_bytes)];
    let decoder = match decoder.process(&mut remaining, &mut buffers, None).ok()? {
        ProcessingResult::Complete { result } => result,
        ProcessingResult::NeedsMoreInput { .. } => return None,
    };
    if decoder.has_more_frames() {
        return None;
    }
    write_ktx2_header(header, width as u32, height as u32, pixel_bytes as u64);
    Some(KTX2_HEADER_SIZE + pixel_bytes)
}

#[unsafe(no_mangle)]
pub extern "C" fn render(input_size: u32) -> u64 {
    if input_size as usize > INPUT_CAP {
        return packed_result(0);
    }
    ARENA.begin_call();
    let live_before = ARENA.state().used;
    let input = unsafe {
        core::slice::from_raw_parts(INPUT.0.get().cast::<u8>(), input_size as usize)
    };
    let output = unsafe { &mut *OUTPUT.0.get() };
    let size = decode(input, output).unwrap_or(0);
    let state = ARENA.state();
    // Live bytes may grow only by the decoder's lazily built static tables.
    if state.failed != 0 || state.used > live_before + STATIC_TABLES_CAP {
        return packed_result(0);
    }
    packed_result(size)
}
