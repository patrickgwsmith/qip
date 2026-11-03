;; Content Compliance oracle for text/cve.wasm.
;;
;; The contract follows the CVE JSON 5 `cveId` pattern
;; `^CVE-[0-9]{4}-[0-9]{4,19}$`, plus a year of 1999 or later. The prefix is
;; case-insensitive on input and uppercase on output. ASCII whitespace around
;; the ID is removed.
;;
;; Generated cases build valid IDs from a year, a sequence length, and a seed,
;; then mutate one property at a time and require rejection. Fixed cases cover
;; empty input, short input, and lookalike separators.
(module
  (import "qip" "must_render_exactly"
    (func $must_render_exactly (param i64 i32 i32 i32 i32) (result i32)))
  (import "qip" "must_reject"
    (func $must_reject (param i64 i32 i32) (result i32)))

  (memory (export "memory") 1)

  ;; Inputs start at 0 and expected outputs start at 256.
  ;; Prefix spellings for styles 0-3, three bytes each.
  (data (i32.const 512) "CVEcvecVeCve")
  ;; Years used by generated cases, as little-endian i32 values.
  (data (i32.const 576) "\cf\07\00\00\d0\07\00\00\de\07\00\00\ea\07\00\00\0f\27\00\00")
  ;; Fixed rejection inputs.
  (data (i32.const 1024) "CVE")
  (data (i32.const 1040) "CVE-2026-")
  (data (i32.const 1056) "CVE-2026-1234 5678")
  (data (i32.const 1088) "CVE\e2\80\932026-1234")
  (data (i32.const 1120) "CVE-2026-1234\00")
  (data (i32.const 1152) "CVE 2026 1234")
  (data (i32.const 1168) "CVE-26-1234")
  (data (i32.const 1184) "CVE-2026-12a4")
  (data (i32.const 1200) "CVE-20x6-1234")
  (data (i32.const 1216) "\c2\a0CVE-2026-1234")
  (data (i32.const 1248) "CVECVE-2026-1234")
  (data (i32.const 1280) " \t\r\n\0c ") ;; \0c is form feed

  (global $case_input_size (mut i32) (i32.const 0))
  (global $case_expected_size (mut i32) (i32.const 0))
  (global $ordinal (mut i64) (i64.const 0))

  (func $append_input (param $value i32)
    (i32.store8 (global.get $case_input_size) (local.get $value))
    (global.set $case_input_size
      (i32.add (global.get $case_input_size) (i32.const 1))))

  (func $append_expected (param $value i32)
    (i32.store8
      (i32.add (i32.const 256) (global.get $case_expected_size))
      (local.get $value))
    (global.set $case_expected_size
      (i32.add (global.get $case_expected_size) (i32.const 1))))

  (func $append_both (param $value i32)
    (call $append_input (local.get $value))
    (call $append_expected (local.get $value)))

  (func $year_at (param $index i32) (result i32)
    (i32.load (i32.add (i32.const 576) (i32.shl (local.get $index) (i32.const 2)))))

  ;; Builds `<prefix>-<year>-<seq_len digits>` with style-specific
  ;; spelling and whitespace. The expected output is always uppercase and
  ;; trimmed.
  (func $make_case
    (param $year i32)
    (param $seq_len i32)
    (param $seed i32)
    (param $style i32)
    (local $i i32)

    (global.set $case_input_size (i32.const 0))
    (global.set $case_expected_size (i32.const 0))

    (if (i32.eq (local.get $style) (i32.const 2))
      (then
        (call $append_input (i32.const 32))
        (call $append_input (i32.const 9))))

    (call $append_input (i32.load8_u (i32.add (i32.const 512) (i32.mul (local.get $style) (i32.const 3)))))
    (call $append_input (i32.load8_u (i32.add (i32.const 513) (i32.mul (local.get $style) (i32.const 3)))))
    (call $append_input (i32.load8_u (i32.add (i32.const 514) (i32.mul (local.get $style) (i32.const 3)))))
    (call $append_expected (i32.const 67))
    (call $append_expected (i32.const 86))
    (call $append_expected (i32.const 69))
    (call $append_both (i32.const 45))

    (call $append_both (i32.add (i32.const 48) (i32.div_u (local.get $year) (i32.const 1000))))
    (call $append_both
      (i32.add (i32.const 48) (i32.rem_u (i32.div_u (local.get $year) (i32.const 100)) (i32.const 10))))
    (call $append_both
      (i32.add (i32.const 48) (i32.rem_u (i32.div_u (local.get $year) (i32.const 10)) (i32.const 10))))
    (call $append_both (i32.add (i32.const 48) (i32.rem_u (local.get $year) (i32.const 10))))
    (call $append_both (i32.const 45))

    (block $done
      (loop $digits
        (br_if $done (i32.ge_u (local.get $i) (local.get $seq_len)))
        (call $append_both
          (i32.add
            (i32.const 48)
            (i32.rem_u
              (i32.add
                (i32.add (local.get $seed) (i32.mul (local.get $i) (i32.const 7)))
                (local.get $seq_len))
              (i32.const 10))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $digits)))

    (if (i32.eq (local.get $style) (i32.const 2))
      (then (call $append_input (i32.const 10))))
    (if (i32.eq (local.get $style) (i32.const 3))
      (then
        (call $append_input (i32.const 13))
        (call $append_input (i32.const 10)))))

  (func $expect_current_case
    (drop
      (call $must_render_exactly
        (global.get $ordinal)
        (i32.const 0)
        (global.get $case_input_size)
        (i32.const 256)
        (global.get $case_expected_size)))
    (global.set $ordinal (i64.add (global.get $ordinal) (i64.const 1))))

  (func $expect_reject (param $ptr i32) (param $size i32)
    (drop (call $must_reject (global.get $ordinal) (local.get $ptr) (local.get $size)))
    (global.set $ordinal (i64.add (global.get $ordinal) (i64.const 1))))

  (func $expect_current_reject
    (call $expect_reject (i32.const 0) (global.get $case_input_size)))

  (func (export "comply") (result i32)
    (local $year_index i32)
    (local $year i32)
    (local $seq_len i32)
    (local $style i32)

    (global.set $ordinal (i64.const 0))

    ;; Valid cases: 5 years x 16 sequence lengths x 4 styles.
    (block $done_years
      (loop $years
        (br_if $done_years (i32.ge_u (local.get $year_index) (i32.const 5)))
        (local.set $year (call $year_at (local.get $year_index)))
        (local.set $seq_len (i32.const 4))
        (block $done_lengths
          (loop $lengths
            (br_if $done_lengths (i32.gt_u (local.get $seq_len) (i32.const 19)))
            (local.set $style (i32.const 0))
            (block $done_styles
              (loop $styles
                (br_if $done_styles (i32.ge_u (local.get $style) (i32.const 4)))
                (call $make_case
                  (local.get $year)
                  (local.get $seq_len)
                  (local.get $year_index)
                  (local.get $style))
                (call $expect_current_case)
                (local.set $style (i32.add (local.get $style) (i32.const 1)))
                (br $styles)))
            (local.set $seq_len (i32.add (local.get $seq_len) (i32.const 1)))
            (br $lengths)))
        (local.set $year_index (i32.add (local.get $year_index) (i32.const 1)))
        (br $years)))

    ;; Mutations of each valid style-0 case: 5 years x 16 lengths x 5.
    (local.set $year_index (i32.const 0))
    (block $done_mutation_years
      (loop $mutation_years
        (br_if $done_mutation_years (i32.ge_u (local.get $year_index) (i32.const 5)))
        (local.set $year (call $year_at (local.get $year_index)))
        (local.set $seq_len (i32.const 4))
        (block $done_mutation_lengths
          (loop $mutation_lengths
            (br_if $done_mutation_lengths (i32.gt_u (local.get $seq_len) (i32.const 19)))

            ;; A letter inside the sequence number.
            (call $make_case (local.get $year) (local.get $seq_len) (local.get $year_index) (i32.const 0))
            (i32.store8
              (i32.add (i32.const 9) (i32.shr_u (local.get $seq_len) (i32.const 1)))
              (i32.const 120))
            (call $expect_current_reject)

            ;; An underscore instead of the first hyphen.
            (call $make_case (local.get $year) (local.get $seq_len) (local.get $year_index) (i32.const 0))
            (i32.store8 (i32.const 3) (i32.const 95))
            (call $expect_current_reject)

            ;; A wrong prefix letter.
            (call $make_case (local.get $year) (local.get $seq_len) (local.get $year_index) (i32.const 0))
            (i32.store8 (i32.const 1) (i32.const 87))
            (call $expect_current_reject)

            ;; A trailing letter after the sequence number.
            (call $make_case (local.get $year) (local.get $seq_len) (local.get $year_index) (i32.const 0))
            (call $append_input (i32.const 97))
            (call $expect_current_reject)

            ;; A space before the second hyphen.
            (call $make_case (local.get $year) (local.get $seq_len) (local.get $year_index) (i32.const 0))
            (i32.store8 (i32.const 8) (i32.const 32))
            (call $expect_current_reject)

            (local.set $seq_len (i32.add (local.get $seq_len) (i32.const 1)))
            (br $mutation_lengths)))
        (local.set $year_index (i32.add (local.get $year_index) (i32.const 1)))
        (br $mutation_years)))

    ;; Sequence numbers outside 4 to 19 digits, for each year.
    (local.set $year_index (i32.const 0))
    (block $done_length_years
      (loop $length_years
        (br_if $done_length_years (i32.ge_u (local.get $year_index) (i32.const 5)))
        (local.set $year (call $year_at (local.get $year_index)))
        (call $make_case (local.get $year) (i32.const 0) (i32.const 0) (i32.const 0))
        (call $expect_current_reject)
        (call $make_case (local.get $year) (i32.const 3) (i32.const 0) (i32.const 0))
        (call $expect_current_reject)
        (call $make_case (local.get $year) (i32.const 20) (i32.const 0) (i32.const 0))
        (call $expect_current_reject)
        (call $make_case (local.get $year) (i32.const 32) (i32.const 0) (i32.const 0))
        (call $expect_current_reject)
        (local.set $year_index (i32.add (local.get $year_index) (i32.const 1)))
        (br $length_years)))

    ;; Years before 1999.
    (call $make_case (i32.const 1998) (i32.const 4) (i32.const 0) (i32.const 0))
    (call $expect_current_reject)
    (call $make_case (i32.const 1000) (i32.const 5) (i32.const 0) (i32.const 0))
    (call $expect_current_reject)
    (call $make_case (i32.const 0) (i32.const 4) (i32.const 0) (i32.const 0))
    (call $expect_current_reject)

    ;; Fixed rejections.
    (call $expect_reject (i32.const 0) (i32.const 0))       ;; empty
    (call $expect_reject (i32.const 1280) (i32.const 6))    ;; whitespace only
    (call $expect_reject (i32.const 1024) (i32.const 3))    ;; "CVE"
    (call $expect_reject (i32.const 1040) (i32.const 9))    ;; no sequence number
    (call $expect_reject (i32.const 1056) (i32.const 18))   ;; inner space
    (call $expect_reject (i32.const 1088) (i32.const 15))   ;; en dash
    (call $expect_reject (i32.const 1120) (i32.const 14))   ;; trailing NUL
    (call $expect_reject (i32.const 1152) (i32.const 13))   ;; spaces as separators
    (call $expect_reject (i32.const 1168) (i32.const 11))   ;; two-digit year
    (call $expect_reject (i32.const 1184) (i32.const 13))   ;; letter in sequence
    (call $expect_reject (i32.const 1200) (i32.const 13))   ;; letter in year
    (call $expect_reject (i32.const 1216) (i32.const 15))   ;; no-break space is not trimmed
    (call $expect_reject (i32.const 1248) (i32.const 16))   ;; doubled prefix

    (i32.wrap_i64 (global.get $ordinal)))
)
