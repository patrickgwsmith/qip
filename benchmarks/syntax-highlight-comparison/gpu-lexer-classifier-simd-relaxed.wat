;; Generated from the Odin SIMD module. The two matrix loops use relaxed
;; multiply-add instructions to test code that Odin cannot emit directly.
(module $gpu-lexer-classifier-simd-odin.wasm
  (type (;0;) (func (result i32)))
  (type (;1;) (func (param i32) (result i32)))
  (func $features_ptr (type 0) (result i32)
    i32.const 1048576)
  (func $features_f32_cap (type 0) (result i32)
    i32.const 262144)
  (func $weights_ptr (type 0) (result i32)
    i32.const 2097152)
  (func $weights_f32_cap (type 0) (result i32)
    i32.const 7529)
  (func $labels_ptr (type 0) (result i32)
    i32.const 2127268)
  (func $labels_cap (type 0) (result i32)
    i32.const 4096)
  (func $gpu_lexer_classifier_simd::classify_one (type 1) (param i32) (result i32)
    (local i32 v128 i32 i32 i32 i32 f32 f32 i32 i32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32 f32)
    global.get $__stack_pointer
    i32.const 352
    i32.sub
    local.tee 1
    global.set $__stack_pointer
    local.get 1
    v128.const i32x4 0x00000000 0x00000000 0x00000000 0x00000000
    local.tee 2
    v128.store offset=336 align=8
    local.get 1
    local.get 2
    v128.store offset=320 align=8
    local.get 1
    local.get 2
    v128.store offset=304 align=8
    local.get 1
    local.get 2
    v128.store offset=288 align=8
    local.get 0
    i32.const 8
    i32.shl
    i32.const 1048576
    i32.add
    local.set 3
    i32.const 0
    local.set 4
    i32.const 2097152
    local.set 5
    loop  ;; label = @1
      local.get 4
      i32.const 2
      i32.shl
      local.tee 6
      i32.const 2101248
      i32.add
      f32.load
      local.set 7
      f32.const 0x0p+0 (;=0;)
      local.set 8
      i32.const -256
      local.set 0
      loop  ;; label = @2
        local.get 8
        local.get 3
        local.get 0
        i32.add
        local.tee 9
        i32.const 256
        i32.add
        f32.load
        local.get 5
        local.get 0
        i32.add
        local.tee 10
        i32.const 256
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 260
        i32.add
        f32.load
        local.get 10
        i32.const 260
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 264
        i32.add
        f32.load
        local.get 10
        i32.const 264
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 268
        i32.add
        f32.load
        local.get 10
        i32.const 268
        i32.add
        f32.load
        f32.mul
        f32.add
        local.set 8
        local.get 0
        i32.const 16
        i32.add
        local.tee 0
        br_if 0 (;@2;)
      end
      local.get 1
      i32.const 288
      i32.add
      local.get 6
      i32.add
      f32.const -0x1.8p+1 (;=-3;)
      f32.const 0x1.8p+1 (;=3;)
      local.get 7
      local.get 8
      f32.add
      f32.const 0x1p-1 (;=0.5;)
      f32.mul
      local.tee 8
      local.get 8
      f32.const 0x1.8p+1 (;=3;)
      f32.gt
      select
      local.tee 8
      local.get 8
      f32.const -0x1.8p+1 (;=-3;)
      f32.lt
      select
      local.tee 8
      local.get 8
      local.get 8
      f32.mul
      local.tee 8
      f32.const 0x1.bp+4 (;=27;)
      f32.add
      f32.mul
      local.get 8
      f32.const 0x1.2p+3 (;=9;)
      f32.mul
      f32.const 0x1.bp+4 (;=27;)
      f32.add
      f32.div
      f32.const 0x1p-1 (;=0.5;)
      f32.mul
      f32.const 0x1p-1 (;=0.5;)
      f32.add
      f32.store
      local.get 5
      i32.const 256
      i32.add
      local.set 5
      local.get 4
      i32.const 1
      i32.add
      local.tee 4
      i32.const 16
      i32.ne
      br_if 0 (;@1;)
    end
    i32.const 0
    local.set 4
    local.get 1
    i32.const 0
    i32.const 288
    memory.fill
    i32.const 2097152
    local.set 5
    local.get 1
    f32.load offset=348
    local.set 11
    local.get 1
    f32.load offset=344
    local.set 12
    local.get 1
    f32.load offset=340
    local.set 13
    local.get 1
    f32.load offset=336
    local.set 14
    local.get 1
    f32.load offset=332
    local.set 15
    local.get 1
    f32.load offset=328
    local.set 16
    local.get 1
    f32.load offset=324
    local.set 17
    local.get 1
    f32.load offset=320
    local.set 18
    local.get 1
    f32.load offset=316
    local.set 19
    local.get 1
    f32.load offset=312
    local.set 20
    local.get 1
    f32.load offset=308
    local.set 21
    local.get 1
    f32.load offset=304
    local.set 22
    local.get 1
    f32.load offset=300
    local.set 23
    local.get 1
    f32.load offset=296
    local.set 24
    local.get 1
    f32.load offset=292
    local.set 25
    local.get 1
    f32.load offset=288
    local.set 26
    loop  ;; label = @1
      local.get 4
      i32.const 2
      i32.shl
      local.tee 6
      i32.const 2124352
      i32.add
      f32.load
      local.set 7
      i32.const -256
      local.set 0
      f32.const 0x0p+0 (;=0;)
      local.set 8
      loop  ;; label = @2
        local.get 8
        local.get 3
        local.get 0
        i32.add
        local.tee 9
        i32.const 256
        i32.add
        f32.load
        local.get 5
        local.get 0
        i32.add
        local.tee 10
        i32.const 4416
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 260
        i32.add
        f32.load
        local.get 10
        i32.const 4420
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 264
        i32.add
        f32.load
        local.get 10
        i32.const 4424
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 268
        i32.add
        f32.load
        local.get 10
        i32.const 4428
        i32.add
        f32.load
        f32.mul
        f32.add
        local.set 8
        local.get 0
        i32.const 16
        i32.add
        local.tee 0
        br_if 0 (;@2;)
      end
      local.get 1
      local.get 6
      i32.add
      f32.const -0x1.8p+1 (;=-3;)
      f32.const 0x1.8p+1 (;=3;)
      local.get 7
      local.get 8
      f32.add
      local.get 26
      local.get 4
      i32.const 6
      i32.shl
      local.tee 0
      i32.const 2119744
      i32.add
      f32.load
      f32.mul
      f32.const 0x0p+0 (;=0;)
      f32.add
      local.get 25
      local.get 0
      i32.const 2119748
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 24
      local.get 0
      i32.const 2119752
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 23
      local.get 0
      i32.const 2119756
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 22
      local.get 0
      i32.const 2119760
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 21
      local.get 0
      i32.const 2119764
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 20
      local.get 0
      i32.const 2119768
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 19
      local.get 0
      i32.const 2119772
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 18
      local.get 0
      i32.const 2119776
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 17
      local.get 0
      i32.const 2119780
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 16
      local.get 0
      i32.const 2119784
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 15
      local.get 0
      i32.const 2119788
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 14
      local.get 0
      i32.const 2119792
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 13
      local.get 0
      i32.const 2119796
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 12
      local.get 0
      i32.const 2119800
      i32.add
      f32.load
      f32.mul
      f32.add
      local.get 11
      local.get 0
      i32.const 2119804
      i32.add
      f32.load
      f32.mul
      f32.add
      f32.add
      local.tee 8
      local.get 8
      f32.const 0x1.8p+1 (;=3;)
      f32.gt
      select
      local.tee 8
      local.get 8
      f32.const -0x1.8p+1 (;=-3;)
      f32.lt
      select
      local.tee 8
      local.get 8
      local.get 8
      f32.mul
      local.tee 8
      f32.const 0x1.bp+4 (;=27;)
      f32.add
      f32.mul
      local.get 8
      f32.const 0x1.2p+3 (;=9;)
      f32.mul
      f32.const 0x1.bp+4 (;=27;)
      f32.add
      f32.div
      f32.store
      local.get 5
      i32.const 256
      i32.add
      local.set 5
      local.get 4
      i32.const 1
      i32.add
      local.tee 4
      i32.const 72
      i32.ne
      br_if 0 (;@1;)
    end
    i32.const 0
    local.set 4
    f32.const -0x1.fffffep+127 (;=-3.40282e+38;)
    local.set 7
    i32.const 2097152
    local.set 3
    i32.const 0
    local.set 5
    loop  ;; label = @1
      local.get 5
      i32.const 2
      i32.shl
      i32.const 2127232
      i32.add
      f32.load
      local.set 11
      f32.const 0x0p+0 (;=0;)
      local.set 8
      i32.const -288
      local.set 0
      loop  ;; label = @2
        local.get 8
        local.get 1
        local.get 0
        i32.add
        local.tee 9
        i32.const 288
        i32.add
        f32.load
        local.get 3
        local.get 0
        i32.add
        local.tee 10
        i32.const 27776
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 292
        i32.add
        f32.load
        local.get 10
        i32.const 27780
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 296
        i32.add
        f32.load
        local.get 10
        i32.const 27784
        i32.add
        f32.load
        f32.mul
        f32.add
        local.get 9
        i32.const 300
        i32.add
        f32.load
        local.get 10
        i32.const 27788
        i32.add
        f32.load
        f32.mul
        f32.add
        local.set 8
        local.get 0
        i32.const 16
        i32.add
        local.tee 0
        br_if 0 (;@2;)
      end
      local.get 11
      local.get 8
      f32.add
      local.tee 8
      local.get 7
      local.get 8
      local.get 7
      f32.gt
      local.tee 0
      select
      local.set 7
      local.get 5
      local.get 4
      local.get 0
      select
      local.set 4
      local.get 3
      i32.const 288
      i32.add
      local.set 3
      local.get 5
      i32.const 1
      i32.add
      local.tee 5
      i32.const 9
      i32.ne
      br_if 0 (;@1;)
    end
    local.get 1
    i32.const 352
    i32.add
    global.set $__stack_pointer
    local.get 4)
  (func $classify_scalar (type 1) (param i32) (result i32)
    (local i32 i32 i32)
    block  ;; label = @1
      local.get 0
      i32.const 4096
      i32.gt_u
      br_if 0 (;@1;)
      i32.const 0
      local.set 1
      block  ;; label = @2
        local.get 0
        i32.eqz
        br_if 0 (;@2;)
        i32.const 0
        local.set 2
        loop  ;; label = @3
          local.get 2
          i32.const 2127268
          i32.add
          local.get 2
          call $gpu_lexer_classifier_simd::classify_one
          local.tee 3
          i32.store8
          local.get 1
          local.get 3
          i32.const 255
          i32.and
          i32.add
          local.set 1
          local.get 0
          local.get 2
          i32.const 1
          i32.add
          local.tee 2
          i32.ne
          br_if 0 (;@3;)
        end
      end
      local.get 1
      return
    end
    unreachable)
  (func $classify_simd (type 1) (param i32) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 v128 i32 v128 v128 v128 v128 v128 i32 i32)
    global.get $__stack_pointer
    i32.const 1408
    i32.sub
    local.tee 1
    global.set $__stack_pointer
    block  ;; label = @1
      local.get 0
      i32.const 4096
      i32.gt_u
      br_if 0 (;@1;)
      i32.const 0
      local.set 2
      i32.const 0
      local.set 3
      block  ;; label = @2
        local.get 0
        i32.const 4
        i32.lt_u
        br_if 0 (;@2;)
        i32.const 1048576
        local.set 4
        i32.const 4
        local.set 5
        i32.const 0
        local.set 3
        i32.const 0
        local.set 6
        loop  ;; label = @3
          local.get 5
          local.set 2
          local.get 1
          i32.const 1152
          i32.add
          i32.const 0
          i32.const 256
          memory.fill
          i32.const 2097152
          local.set 7
          i32.const 0
          local.set 8
          loop  ;; label = @4
            local.get 8
            i32.const 2
            i32.shl
            i32.const 2101248
            i32.add
            v128.load32_splat
            local.set 9
            i32.const 0
            local.set 5
            loop  ;; label = @5
              local.get 4
              local.get 5
              i32.add
              local.tee 10
              i32.const 768
              i32.add
              local.get 10
              i32.const 512
              i32.add
              local.get 10
              i32.const 256
              i32.add
              local.get 10
              v128.load32_zero
              v128.load32_lane 1
              v128.load32_lane 2
              v128.load32_lane 3
              local.get 7
              local.get 5
              i32.add
              v128.load32_splat
              local.get 9
              f32x4.relaxed_madd
              local.set 9
              local.get 5
              i32.const 4
              i32.add
              local.tee 5
              i32.const 256
              i32.ne
              br_if 0 (;@5;)
            end
            local.get 1
            i32.const 1152
            i32.add
            local.get 8
            i32.const 4
            i32.shl
            i32.add
            local.get 9
            v128.const i32x4 0x3f000000 0x3f000000 0x3f000000 0x3f000000
            local.tee 11
            f32x4.mul
            v128.const i32x4 0xc0400000 0xc0400000 0xc0400000 0xc0400000
            local.tee 12
            f32x4.pmax
            v128.const i32x4 0x40400000 0x40400000 0x40400000 0x40400000
            local.tee 13
            f32x4.pmin
            local.tee 9
            local.get 9
            local.get 9
            f32x4.mul
            local.tee 9
            v128.const i32x4 0x41d80000 0x41d80000 0x41d80000 0x41d80000
            local.tee 14
            f32x4.add
            f32x4.mul
            local.get 9
            v128.const i32x4 0x41100000 0x41100000 0x41100000 0x41100000
            local.tee 15
            f32x4.mul
            local.get 14
            f32x4.add
            f32x4.div
            local.get 11
            f32x4.mul
            local.get 11
            f32x4.add
            v128.store
            local.get 7
            i32.const 256
            i32.add
            local.set 7
            local.get 8
            i32.const 1
            i32.add
            local.tee 8
            i32.const 16
            i32.ne
            br_if 0 (;@4;)
          end
          i32.const 0
          local.set 16
          local.get 1
          i32.const 0
          i32.const 1152
          memory.fill
          i32.const 2101312
          local.set 8
          i32.const 2119748
          local.set 17
          loop  ;; label = @4
            local.get 16
            i32.const 2
            i32.shl
            i32.const 2124352
            i32.add
            v128.load32_splat
            local.set 9
            i32.const 0
            local.set 5
            loop  ;; label = @5
              local.get 4
              local.get 5
              i32.add
              local.tee 10
              i32.const 768
              i32.add
              local.get 10
              i32.const 512
              i32.add
              local.get 10
              i32.const 256
              i32.add
              local.get 10
              v128.load32_zero
              v128.load32_lane 1
              v128.load32_lane 2
              v128.load32_lane 3
              local.get 8
              local.get 5
              i32.add
              v128.load32_splat
              local.get 9
              f32x4.relaxed_madd
              local.set 9
              local.get 5
              i32.const 4
              i32.add
              local.tee 5
              i32.const 256
              i32.ne
              br_if 0 (;@5;)
            end
            i32.const 0
            local.set 10
            local.get 17
            local.set 5
            loop  ;; label = @5
              local.get 9
              local.get 1
              i32.const 1152
              i32.add
              local.get 10
              i32.add
              local.tee 7
              v128.load
              local.get 5
              i32.const -4
              i32.add
              v128.load32_splat
              f32x4.mul
              f32x4.add
              local.get 7
              i32.const 16
              i32.add
              v128.load
              local.get 5
              v128.load32_splat
              f32x4.mul
              f32x4.add
              local.set 9
              local.get 5
              i32.const 8
              i32.add
              local.set 5
              local.get 10
              i32.const 32
              i32.add
              local.tee 10
              i32.const 256
              i32.ne
              br_if 0 (;@5;)
            end
            local.get 1
            local.get 16
            i32.const 4
            i32.shl
            i32.add
            local.get 9
            local.get 12
            f32x4.pmax
            local.get 13
            f32x4.pmin
            local.tee 9
            local.get 9
            local.get 9
            f32x4.mul
            local.tee 9
            local.get 14
            f32x4.add
            f32x4.mul
            local.get 9
            local.get 15
            f32x4.mul
            local.get 14
            f32x4.add
            f32x4.div
            v128.store
            local.get 17
            i32.const 64
            i32.add
            local.set 17
            local.get 8
            i32.const 256
            i32.add
            local.set 8
            local.get 16
            i32.const 1
            i32.add
            local.tee 16
            i32.const 72
            i32.ne
            br_if 0 (;@4;)
          end
          v128.const i32x4 0x00000000 0x00000000 0x00000000 0x00000000
          local.set 11
          v128.const i32x4 0xff7fffff 0xff7fffff 0xff7fffff 0xff7fffff
          local.set 14
          i32.const 0
          local.set 8
          i32.const 2124644
          local.set 16
          loop  ;; label = @4
            local.get 8
            i32.const 2
            i32.shl
            i32.const 2127232
            i32.add
            v128.load32_splat
            local.set 9
            i32.const 0
            local.set 10
            local.get 16
            local.set 5
            loop  ;; label = @5
              local.get 9
              local.get 1
              local.get 10
              i32.add
              local.tee 7
              v128.load
              local.get 5
              i32.const -4
              i32.add
              v128.load32_splat
              f32x4.mul
              f32x4.add
              local.get 7
              i32.const 16
              i32.add
              v128.load
              local.get 5
              v128.load32_splat
              f32x4.mul
              f32x4.add
              local.set 9
              local.get 5
              i32.const 8
              i32.add
              local.set 5
              local.get 10
              i32.const 32
              i32.add
              local.tee 10
              i32.const 1152
              i32.ne
              br_if 0 (;@5;)
            end
            local.get 8
            i32x4.splat
            local.get 11
            local.get 9
            local.get 14
            f32x4.gt
            v128.bitselect
            local.set 11
            local.get 16
            i32.const 288
            i32.add
            local.set 16
            local.get 14
            local.get 9
            f32x4.pmax
            local.set 14
            local.get 8
            i32.const 1
            i32.add
            local.tee 8
            i32.const 9
            i32.ne
            br_if 0 (;@4;)
          end
          local.get 6
          i32.const 2127271
          i32.add
          local.get 11
          i32x4.extract_lane 3
          local.tee 5
          i32.store8
          local.get 6
          i32.const 2127270
          i32.add
          local.get 11
          i32x4.extract_lane 2
          local.tee 10
          i32.store8
          local.get 6
          i32.const 2127269
          i32.add
          local.get 11
          i32x4.extract_lane 1
          local.tee 7
          i32.store8
          local.get 6
          i32.const 2127268
          i32.add
          local.get 11
          i32x4.extract_lane 0
          local.tee 8
          i32.store8
          local.get 5
          i32.const 255
          i32.and
          local.get 10
          i32.const 255
          i32.and
          local.get 7
          i32.const 255
          i32.and
          local.get 8
          i32.const 255
          i32.and
          local.get 3
          i32.add
          i32.add
          i32.add
          i32.add
          local.set 3
          local.get 4
          i32.const 1024
          i32.add
          local.set 4
          local.get 2
          local.set 6
          local.get 2
          i32.const 4
          i32.add
          local.tee 5
          local.get 0
          i32.le_s
          br_if 0 (;@3;)
        end
      end
      block  ;; label = @2
        local.get 2
        local.get 0
        i32.ge_s
        br_if 0 (;@2;)
        loop  ;; label = @3
          local.get 2
          i32.const 2127268
          i32.add
          local.get 2
          call $gpu_lexer_classifier_simd::classify_one
          local.tee 5
          i32.store8
          local.get 3
          local.get 5
          i32.const 255
          i32.and
          i32.add
          local.set 3
          local.get 0
          local.get 2
          i32.const 1
          i32.add
          local.tee 2
          i32.ne
          br_if 0 (;@3;)
        end
      end
      local.get 1
      i32.const 1408
      i32.add
      global.set $__stack_pointer
      local.get 3
      return
    end
    unreachable)
  (memory (;0;) 33 64)
  (global $__stack_pointer (mut i32) (i32.const 1048576))
  (export "memory" (memory 0))
  (export "features_ptr" (func $features_ptr))
  (export "features_f32_cap" (func $features_f32_cap))
  (export "weights_ptr" (func $weights_ptr))
  (export "weights_f32_cap" (func $weights_f32_cap))
  (export "labels_ptr" (func $labels_ptr))
  (export "labels_cap" (func $labels_cap))
  (export "classify_scalar" (func $classify_scalar))
  (export "classify_simd" (func $classify_simd)))
