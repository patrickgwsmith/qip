(module $HelloNaive
  ;; Memory must be exported with name "memory"
  ;; At least 3 pages needed: input at 0x10000, output at 0x20000
  (memory (export "memory") 3 3)

  ;; Internal buffer constants with function exports for qip integration
  (global $input_ptr i32 (i32.const 0x10000))
  (func (export "input_ptr") (result i32)
    (global.get $input_ptr))
  (global $input_utf8_cap i32 (i32.const 0x10000))
  (func (export "input_utf8_cap") (result i32)
    (global.get $input_utf8_cap))
  (global $output_ptr i32 (i32.const 0x20000))
  (global $output_utf8_cap i32 (i32.const 0x10000))
  (func (export "output_utf8_cap") (result i32)
    (global.get $output_utf8_cap))

  ;; Required export: render(input_size) -> output_size
  ;; Input is at input_ptr, output goes to output_ptr
  ;; Return 0 for no output, or the length of output written
  (func $render_size (param $input_size i32) (result i32)
    (local $i i32)
    (local $out_pos i32)

    ;; Write prefix "Hello, " once for both branches.
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 0)) (i32.const 72))   ;; H
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 1)) (i32.const 101))  ;; e
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 2)) (i32.const 108))  ;; l
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 3)) (i32.const 108))  ;; l
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 4)) (i32.const 111))  ;; o
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 5)) (i32.const 44))   ;; ,
    (i32.store8 (i32.add (global.get $output_ptr) (i32.const 6)) (i32.const 32))   ;; space

    (if (i32.gt_u (local.get $input_size) (i32.const 0))
      (then
        ;; Copy input after "Hello, ".
        (local.set $i (i32.const 0))
        (local.set $out_pos (i32.const 7))
        (block $break_copy
          (loop $continue_copy
            (br_if $break_copy (i32.ge_u (local.get $i) (local.get $input_size)))
            (i32.store8
              (i32.add (global.get $output_ptr) (local.get $out_pos))
              (i32.load8_u (i32.add (global.get $input_ptr) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $out_pos (i32.add (local.get $out_pos) (i32.const 1)))
            (br $continue_copy)
          )
        )
      )
      (else
        ;; Empty input: append "World".
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 7)) (i32.const 87))   ;; W
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 8)) (i32.const 111))  ;; o
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 9)) (i32.const 114))  ;; r
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 10)) (i32.const 108)) ;; l
        (i32.store8 (i32.add (global.get $output_ptr) (i32.const 11)) (i32.const 100)) ;; d
        (local.set $out_pos (i32.const 12))
      )
    )

    ;; Return output length
    (local.get $out_pos)
  )
  (func (export "render") (param $input_size i32) (result i64)
    (i64.or
      (i64.shl (i64.extend_i32_u (global.get $output_ptr)) (i64.const 32))
      (i64.extend_i32_u (call $render_size (local.get $input_size)))))
)