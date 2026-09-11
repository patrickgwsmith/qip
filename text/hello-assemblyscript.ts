// hello-assemblyscript.ts - qip-compatible WebAssembly module in AssemblyScript

const INPUT_PTR: i32 = 0x10000;
const INPUT_CAP: i32 = 0x10000 - 7;
const OUTPUT_PTR: i32 = 0x20000;
const OUTPUT_CAP: i32 = 0x10000;

const PREFIX_SIZE: i32 = 7;
const DEFAULT_NAME_SIZE: i32 = 5;

export function input_ptr(): i32 {
  return INPUT_PTR;
}

export function input_utf8_cap(): i32 {
  return INPUT_CAP;
}

export function output_utf8_cap(): i32 {
  return OUTPUT_CAP;
}

export function render(input_size: i32): i64 {
  if (input_size < 0 || input_size > INPUT_CAP) unreachable();
  store<u8>(OUTPUT_PTR + 0, 72); // H
  store<u8>(OUTPUT_PTR + 1, 101); // e
  store<u8>(OUTPUT_PTR + 2, 108); // l
  store<u8>(OUTPUT_PTR + 3, 108); // l
  store<u8>(OUTPUT_PTR + 4, 111); // o
  store<u8>(OUTPUT_PTR + 5, 44); // ,
  store<u8>(OUTPUT_PTR + 6, 32); // space

  if (input_size > 0) {
    // Copy input bytes after prefix
    for (let i: i32 = 0; i < input_size; i++) {
      const b = load<u8>(INPUT_PTR + i);
      store<u8>(OUTPUT_PTR + PREFIX_SIZE + i, b);
    }
    return (<i64>OUTPUT_PTR << 32) | <i64>(PREFIX_SIZE + input_size);
  }

  store<u8>(OUTPUT_PTR + PREFIX_SIZE + 0, 87); // W
  store<u8>(OUTPUT_PTR + PREFIX_SIZE + 1, 111); // o
  store<u8>(OUTPUT_PTR + PREFIX_SIZE + 2, 114); // r
  store<u8>(OUTPUT_PTR + PREFIX_SIZE + 3, 108); // l
  store<u8>(OUTPUT_PTR + PREFIX_SIZE + 4, 100); // d
  return (<i64>OUTPUT_PTR << 32) | <i64>(PREFIX_SIZE + DEFAULT_NAME_SIZE);
}
