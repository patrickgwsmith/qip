//! WebAssembly Core 2.0 validation as an assertion/pass-through QIP component.
//!
//! Validation uses `wasmparser` with `WasmFeatures::WASM2`. This is the full
//! Core 2.0 language, not a profile of the instructions used by other QIP
//! components. Later proposals are disabled.

#![no_std]
#![no_main]

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::panic::PanicInfo;
use wasmparser::{Validator, WasmFeatures};

const INPUT_CAP: usize = 8 * 1024 * 1024;
const HEAP_CAP: usize = 64 * 1024 * 1024;
const INPUT_CONTENT_TYPE: &[u8] = b"application/wasm";
const OUTPUT_CONTENT_TYPE: &[u8] = b"application/wasm";

#[repr(align(64))]
struct HeapStorage(UnsafeCell<[u8; HEAP_CAP]>);

// QIP components execute on one Wasm thread. This wrapper permits the static
// arena to be used by the process-wide Rust allocator.
unsafe impl Sync for HeapStorage {}

static HEAP: HeapStorage = HeapStorage(UnsafeCell::new([0; HEAP_CAP]));

struct BumpAllocator(UnsafeCell<usize>);

unsafe impl Sync for BumpAllocator {}

unsafe impl GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let next = unsafe { &mut *self.0.get() };
        let start = match next.checked_add(layout.align() - 1) {
            Some(value) => value & !(layout.align() - 1),
            None => return core::ptr::null_mut(),
        };
        let end = match start.checked_add(layout.size()) {
            Some(value) if value <= HEAP_CAP => value,
            _ => return core::ptr::null_mut(),
        };
        *next = end;
        unsafe { (*HEAP.0.get()).as_mut_ptr().add(start) }
    }

    unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
}

impl BumpAllocator {
    unsafe fn reset(&self) {
        unsafe { *self.0.get() = 0 };
    }
}

#[global_allocator]
static ALLOCATOR: BumpAllocator = BumpAllocator(UnsafeCell::new(0));

static mut INPUT: [u8; INPUT_CAP] = [0; INPUT_CAP];

#[panic_handler]
fn panic(_: &PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

fn input_address() -> u32 {
    (&raw mut INPUT).cast::<u8>() as u32
}

fn packed_result(value: u32, output_ptr: u32, failed: bool) -> u64 {
    (value as u64) | ((output_ptr as u64) << 32) | ((failed as u64) << 63)
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
    INPUT_CAP as u32
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
pub extern "C" fn failure_modes_per_input_offset() -> u32 {
    1
}

#[unsafe(no_mangle)]
pub extern "C" fn render(input_size: u32) -> u64 {
    if input_size as usize > INPUT_CAP {
        core::arch::wasm32::unreachable();
    }

    let input = unsafe {
        core::slice::from_raw_parts((&raw const INPUT).cast::<u8>(), input_size as usize)
    };
    let validation = {
        let mut validator = Validator::new_with_features(WasmFeatures::WASM2);
        validator
            .validate_all(input)
            .map(|_| ())
            .map_err(|error| u32::try_from(error.offset()).unwrap_or(input_size))
    };

    // Every validator allocation belongs to this render call. Reset only after
    // the validator, its type state, and any error value have been dropped.
    unsafe { ALLOCATOR.reset() };

    match validation {
        Ok(()) => packed_result(input_size, input_address(), false),
        Err(offset) => packed_result(offset, 0, true),
    }
}
