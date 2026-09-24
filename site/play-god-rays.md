# God Rays

A software-rendered port of the [paper-design god-rays shader](https://shaders.paper.design/god-rays), evaluating the GLSL fragment shader per pixel in WebAssembly. Both versions use the library's "Default" preset, accept the same complete uniform set, and publish a canonical KTX2 frame.

Straight port (line-for-line GLSL translation, libm `pow`/`atan2`):

<qip-play canvas-width="640px" canvas-height="360px">
  <source
    src="/gui/god-rays.wasm"
    type="application/wasm"
    data-uniform-density="0.3"
    data-uniform-spotty="0.3"
    data-uniform-mid_size="0.2"
    data-uniform-mid_intensity="0.4"
    data-uniform-intensity="0.8"
    data-uniform-bloom="0.4"
    data-uniform-colors_count="4"
    data-uniform-color_back="0x000000ff"
    data-uniform-color_bloom="0x0000ffff"
    data-uniform-color_1="0xa600ff6e"
    data-uniform-color_2="0x6200fff0"
    data-uniform-color_3="0xffffffff"
    data-uniform-color_4="0x33fff5ff"
    data-uniform-color_5="0x00000000"
    data-uniform-fit="1"
    data-uniform-scale="1"
    data-uniform-rotation="0"
    data-uniform-origin_x="0.5"
    data-uniform-origin_y="0.5"
    data-uniform-offset_x="0"
    data-uniform-offset_y="-0.55"
    data-uniform-world_width="0"
    data-uniform-world_height="0"
    data-uniform-pixel_ratio="1"
    data-uniform-speed="0.75"
    data-uniform-frame="0"
  />
</qip-play>

Optimized port (polynomial `pow`/`atan2`, hoisted angle, saturated-mix branch skip — output within 1/255 per channel of the straight port):

<qip-play canvas-width="640px" canvas-height="360px">
  <source
    src="/gui/god-rays-optimized.wasm"
    type="application/wasm"
    data-uniform-density="0.3"
    data-uniform-spotty="0.3"
    data-uniform-mid_size="0.2"
    data-uniform-mid_intensity="0.4"
    data-uniform-intensity="0.8"
    data-uniform-bloom="0.4"
    data-uniform-colors_count="4"
    data-uniform-color_back="0x000000ff"
    data-uniform-color_bloom="0x0000ffff"
    data-uniform-color_1="0xa600ff6e"
    data-uniform-color_2="0x6200fff0"
    data-uniform-color_3="0xffffffff"
    data-uniform-color_4="0x33fff5ff"
    data-uniform-color_5="0x00000000"
    data-uniform-fit="1"
    data-uniform-scale="1"
    data-uniform-rotation="0"
    data-uniform-origin_x="0.5"
    data-uniform-origin_y="0.5"
    data-uniform-offset_x="0"
    data-uniform-offset_y="-0.55"
    data-uniform-world_width="0"
    data-uniform-world_height="0"
    data-uniform-pixel_ratio="1"
    data-uniform-speed="0.75"
    data-uniform-frame="0"
  />
</qip-play>
