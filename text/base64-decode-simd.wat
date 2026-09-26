(module $Base64DecodeSIMD
  (memory (export "memory") 3 3)
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_bytes_cap i32 (i32.const 0x10000))
  (global $failure_offset (mut i32) (i32.const -1))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (func (export "output_bytes_cap") (result i32)
    (global.get $output_bytes_cap))
  (func (export "failure_modes_per_input_offset") (result i32)
    (i32.const 1))

  ;; Decode one RFC 4648 Base64 character. Padding is validated by render.
  (func $decode_base64_char (param $char i32) (result i32)
    (if (result i32)
      (i32.and
        (i32.ge_u (local.get $char) (i32.const 65))
        (i32.le_u (local.get $char) (i32.const 90)))
      (then (i32.sub (local.get $char) (i32.const 65)))
      (else
        (if (result i32)
          (i32.and
            (i32.ge_u (local.get $char) (i32.const 97))
            (i32.le_u (local.get $char) (i32.const 122)))
          (then (i32.sub (local.get $char) (i32.const 71)))
          (else
            (if (result i32)
              (i32.and
                (i32.ge_u (local.get $char) (i32.const 48))
                (i32.le_u (local.get $char) (i32.const 57)))
              (then (i32.add (local.get $char) (i32.const 4)))
              (else
                (if (result i32) (i32.eq (local.get $char) (i32.const 43))
                  (then (i32.const 62))
                  (else
                    (if (result i32) (i32.eq (local.get $char) (i32.const 47))
                      (then (i32.const 63))
                      (else (i32.const -1))))))))))))

  ;; Reject invalid input and include its first known byte offset.
  (func $reject (param $offset i32) (result i32)
    (global.set $failure_offset (local.get $offset))
    (i32.const 0))

  ;; Four unpadded quartets per call. A bad lane falls back to the scalar
  ;; decoder, which reports the same first failing byte offset as before.
  (func $decode16 (param $in i32) (param $out i32) (result i32)
    (local $x v128)
    (local $hash v128)
    (local $low v128)
    (local $min v128)
    (local $max v128)
    (local $v v128)
    (local $y v128)

    (local.set $x
      (v128.load (i32.add (global.get $input_ptr) (local.get $in))))
    ;; The high nibble selects a small SIMD table entry. '/' needs its own
    ;; index; low-nibble bounds then validate every ASCII range exactly.
    (local.set $hash
      (i8x16.sub
        (v128.and
          (i16x8.shr_u (local.get $x) (i32.const 4))
          (i8x16.splat (i32.const 15)))
        (v128.and
          (i8x16.eq (local.get $x) (i8x16.splat (i32.const 47)))
          (i8x16.splat (i32.const 1)))))
    (local.set $low
      (v128.and (local.get $x) (i8x16.splat (i32.const 15))))
    (local.set $min
      (i8x16.swizzle
        (v128.const i8x16 255 15 11 0 1 0 1 0 255 255 255 255 255 255 255 255)
        (local.get $hash)))
    (local.set $max
      (i8x16.swizzle
        (v128.const i8x16 0 15 11 9 15 10 15 10 0 0 0 0 0 0 0 0)
        (local.get $hash)))
    (if
      (i32.ne
        (i8x16.bitmask
          (v128.and
            (i8x16.ge_u (local.get $x) (i8x16.splat (i32.const 43)))
            (v128.and
              (i8x16.ge_u (local.get $low) (local.get $min))
              (i8x16.le_u (local.get $low) (local.get $max)))))
        (i32.const 65535))
      (then (return (i32.const 0))))

    (local.set $v
      (i8x16.add
        (local.get $x)
        (i8x16.swizzle
          (v128.const i8x16 0 16 19 4 191 191 185 185 0 0 0 0 0 0 0 0)
          (local.get $hash))))

    ;; Each 32-bit lane holds four 6-bit values. Shift and mask them into
    ;; three output bytes, then shuffle away each lane's unused fourth byte.
    (local.set $y
      (v128.or
        (v128.or
          (i32x4.shl (v128.and (local.get $v) (i32x4.splat (i32.const 0x3f)))
            (i32.const 2))
          (i32x4.shr_u (v128.and (local.get $v) (i32x4.splat (i32.const 0x3000)))
            (i32.const 12)))
        (v128.or
          (v128.or
            (i32x4.shl (v128.and (local.get $v) (i32x4.splat (i32.const 0xf00)))
              (i32.const 4))
            (i32x4.shr_u (v128.and (local.get $v) (i32x4.splat (i32.const 0x3c0000)))
              (i32.const 10)))
          (v128.or
            (i32x4.shl (v128.and (local.get $v) (i32x4.splat (i32.const 0x30000)))
              (i32.const 6))
            (i32x4.shr_u (v128.and (local.get $v) (i32x4.splat (i32.const 0x3f000000)))
              (i32.const 8))))))
    (v128.store
      (i32.add (global.get $output_ptr) (local.get $out))
      (i8x16.shuffle 0 1 2 4 5 6 8 9 10 12 13 14 0 0 0 0
        (local.get $y) (local.get $y)))
    (i32.const 1))

  (func (export "render") (param $input_size i32) (result i64)
    (local $input_idx i32)
    (local $output_idx i32)
    (local $simd_end i32)
    (local $c1 i32)
    (local $c2 i32)
    (local $c3 i32)
    (local $c4 i32)
    (local $v1 i32)
    (local $v2 i32)
    (local $v3 i32)
    (local $v4 i32)
    (local $padding i32)

    (if (i32.gt_u (local.get $input_size) (global.get $input_utf8_cap))
      (then unreachable))

    (global.set $failure_offset (i32.const -1))

    (block $finish
      ;; This strict profile accepts complete four-byte groups. The final
      ;; group uses '=' padding when the decoded byte count requires it.
      (if (i32.and (local.get $input_size) (i32.const 3))
        (then
          (local.set $output_idx (call $reject (local.get $input_size)))
          (br $finish)))

    ;; Only the final quartet can contain padding. A complete final vector
    ;; can use SIMD when the last input byte is not '='.
    (local.set $simd_end (local.get $input_size))
    (if (local.get $input_size)
      (then
        (if
          (i32.eq
            (i32.load8_u
              (i32.add (global.get $input_ptr)
                (i32.sub (local.get $input_size) (i32.const 1))))
            (i32.const 61))
          (then
            (local.set $simd_end
              (i32.sub (local.get $simd_end) (i32.const 4)))))))
    (block $simd_done
      (loop $simd_groups
        (br_if $simd_done
          (i32.gt_u
            (i32.add (local.get $input_idx) (i32.const 16))
            (local.get $simd_end)))
        (br_if $simd_done
          (i32.eqz (call $decode16 (local.get $input_idx) (local.get $output_idx))))
        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 16)))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 12)))
        (br $simd_groups)))

    (block $done
      (loop $groups
        (br_if $done (i32.ge_u (local.get $input_idx) (local.get $input_size)))

        (local.set $c1
          (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))
        (local.set $c2
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 1)))))
        (local.set $c3
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 2)))))
        (local.set $c4
          (i32.load8_u
            (i32.add (global.get $input_ptr)
              (i32.add (local.get $input_idx) (i32.const 3)))))

        (local.set $v1 (call $decode_base64_char (local.get $c1)))
        (if (i32.lt_s (local.get $v1) (i32.const 0))
          (then
            (local.set $output_idx (call $reject (local.get $input_idx)))
            (br $finish)))
        (local.set $v2 (call $decode_base64_char (local.get $c2)))
        (if (i32.lt_s (local.get $v2) (i32.const 0))
          (then
            (local.set $output_idx
              (call $reject (i32.add (local.get $input_idx) (i32.const 1))))
            (br $finish)))

        (local.set $padding (i32.const 0))
        (if (i32.eq (local.get $c3) (i32.const 61))
          (then
            (local.set $padding (i32.const 2))
            (if (i32.ne (local.get $c4) (i32.const 61))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if
              (i32.ne
                (i32.add (local.get $input_idx) (i32.const 4))
                (local.get $input_size))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if (i32.and (local.get $v2) (i32.const 15))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 1))))
                (br $finish))))
          (else
            (local.set $v3 (call $decode_base64_char (local.get $c3)))
            (if (i32.lt_s (local.get $v3) (i32.const 0))
              (then
                (local.set $output_idx
                  (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                (br $finish)))
            (if (i32.eq (local.get $c4) (i32.const 61))
              (then
                (local.set $padding (i32.const 1))
                (if
                  (i32.ne
                    (i32.add (local.get $input_idx) (i32.const 4))
                    (local.get $input_size))
                  (then
                    (local.set $output_idx
                      (call $reject (i32.add (local.get $input_idx) (i32.const 3))))
                    (br $finish)))
                (if (i32.and (local.get $v3) (i32.const 3))
                  (then
                    (local.set $output_idx
                      (call $reject (i32.add (local.get $input_idx) (i32.const 2))))
                    (br $finish))))
              (else
                (local.set $v4 (call $decode_base64_char (local.get $c4)))
                (if (i32.lt_s (local.get $v4) (i32.const 0))
                  (then
                    (local.set $output_idx
                      (call $reject
                        (i32.add (local.get $input_idx) (i32.const 3))))
                    (br $finish)))))))

        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (i32.or
            (i32.shl (local.get $v1) (i32.const 2))
            (i32.shr_u (local.get $v2) (i32.const 4))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        (if (i32.lt_u (local.get $padding) (i32.const 2))
          (then
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (i32.or
                (i32.shl (i32.and (local.get $v2) (i32.const 15)) (i32.const 4))
                (i32.shr_u (local.get $v3) (i32.const 2))))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))))

        (if (i32.eqz (local.get $padding))
          (then
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $output_idx))
              (i32.or
                (i32.shl (i32.and (local.get $v3) (i32.const 3)) (i32.const 6))
                (local.get $v4)))
            (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))))

        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 4)))
        (br $groups)))
)

    (if (i32.gt_u (local.get $output_idx) (global.get $output_bytes_cap))
      (then unreachable))
    (if (result i64) (i32.ge_s (global.get $failure_offset) (i32.const 0))
      (then
        (i64.or
          (i64.const -9223372036854775808)
          (i64.extend_i32_u (global.get $failure_offset))))
      (else
        (i64.or
          (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
          (i64.extend_i32_u (local.get $output_idx))))))

)
