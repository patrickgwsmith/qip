(module $Base64Encode
  (memory (export "memory") 4 4)
  (global $input_ptr i32 (i32.const 0x10000))
  (global $input_bytes_cap i32 (i32.const 0x10000))
  (global $output_ptr i32 (i32.const 0x20000))
  ;; 4 * ceil(input_bytes_cap / 3)
  (global $output_utf8_cap i32 (i32.const 0x15558))

  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (func (export "input_bytes_cap") (result i32)
    (global.get $input_bytes_cap))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))

  ;; Base64 alphabet: ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
  (func $get_base64_char (param $index i32) (result i32)
    (if (result i32) (i32.lt_u (local.get $index) (i32.const 26))
      (then
        ;; A-Z (65-90)
        (i32.add (i32.const 65) (local.get $index))
      )
      (else
        (if (result i32) (i32.lt_u (local.get $index) (i32.const 52))
          (then
            ;; a-z (97-122)
            (i32.add (i32.const 71) (local.get $index))
          )
          (else
            (if (result i32) (i32.lt_u (local.get $index) (i32.const 62))
              (then
                ;; 0-9 (48-57)
                (i32.sub (local.get $index) (i32.const 4))
              )
              (else
                (if (result i32) (i32.eq (local.get $index) (i32.const 62))
                  (then
                    ;; + (43)
                    (i32.const 43)
                  )
                  (else
                    ;; / (47)
                    (i32.const 47)
                  )
                )
              )
            )
          )
        )
      )
    )
  )

  (func $render_size (param $input_size i32) (result i32)
    (local $input_idx i32)
    (local $output_idx i32)
    (local $b1 i32)
    (local $b2 i32)
    (local $b3 i32)
    (local $remaining i32)
    (local $full_end i32)

    (if (i32.gt_u (local.get $input_size) (global.get $input_bytes_cap))
      (then unreachable)
    )

    ;; Return 0 if input is empty
    (if (i32.eq (local.get $input_size) (i32.const 0))
      (then (return (i32.const 0)))
    )

    ;; Process 3-byte groups. Keep the loop bound explicit so static
    ;; checkers can prove the loop is bounded cheaply.
    (local.set $full_end
      (i32.sub
        (local.get $input_size)
        (i32.rem_u (local.get $input_size) (i32.const 3))))

    (block $break
      (loop $continue
        (br_if $break (i32.ge_u (local.get $input_idx) (local.get $full_end)))

        ;; Read 3 bytes
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))
        (local.set $b2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 1)))))
        (local.set $b3 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 2)))))

        ;; Write 4 base64 characters
        ;; First char: top 6 bits of b1
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.shr_u (local.get $b1) (i32.const 2))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Second char: bottom 2 bits of b1 + top 4 bits of b2
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char
            (i32.or
              (i32.shl (i32.and (local.get $b1) (i32.const 3)) (i32.const 4))
              (i32.shr_u (local.get $b2) (i32.const 4)))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Third char: bottom 4 bits of b2 + top 2 bits of b3
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char
            (i32.or
              (i32.shl (i32.and (local.get $b2) (i32.const 15)) (i32.const 2))
              (i32.shr_u (local.get $b3) (i32.const 6)))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Fourth char: bottom 6 bits of b3
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.and (local.get $b3) (i32.const 63))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        (local.set $input_idx (i32.add (local.get $input_idx) (i32.const 3)))
        (br $continue)
      )
    )

    ;; Handle remaining 1 or 2 bytes with padding
    (local.set $remaining (i32.sub (local.get $input_size) (local.get $input_idx)))

    (if (i32.eq (local.get $remaining) (i32.const 1))
      (then
        ;; 1 byte remaining
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))

        ;; First char: top 6 bits of b1
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.shr_u (local.get $b1) (i32.const 2))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Second char: bottom 2 bits of b1, padded with zeros
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.shl (i32.and (local.get $b1) (i32.const 3)) (i32.const 4))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Padding ==
        (i32.store8 (i32.add (global.get $output_ptr) (local.get $output_idx)) (i32.const 61))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
        (i32.store8 (i32.add (global.get $output_ptr) (local.get $output_idx)) (i32.const 61))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
      )
    )

    (if (i32.eq (local.get $remaining) (i32.const 2))
      (then
        ;; 2 bytes remaining
        (local.set $b1 (i32.load8_u (i32.add (global.get $input_ptr) (local.get $input_idx))))
        (local.set $b2 (i32.load8_u (i32.add (global.get $input_ptr) (i32.add (local.get $input_idx) (i32.const 1)))))

        ;; First char: top 6 bits of b1
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.shr_u (local.get $b1) (i32.const 2))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Second char: bottom 2 bits of b1 + top 4 bits of b2
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char
            (i32.or
              (i32.shl (i32.and (local.get $b1) (i32.const 3)) (i32.const 4))
              (i32.shr_u (local.get $b2) (i32.const 4)))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Third char: bottom 4 bits of b2, padded with zeros
        (i32.store8
          (i32.add (global.get $output_ptr) (local.get $output_idx))
          (call $get_base64_char (i32.shl (i32.and (local.get $b2) (i32.const 15)) (i32.const 2))))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))

        ;; Padding =
        (i32.store8 (i32.add (global.get $output_ptr) (local.get $output_idx)) (i32.const 61))
        (local.set $output_idx (i32.add (local.get $output_idx) (i32.const 1)))
      )
    )

    ;; Return output size
    (local.get $output_idx)
  )
  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)