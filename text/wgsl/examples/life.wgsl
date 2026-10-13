// One generation of Conway's Game of Life on a width x height torus.
// Input and output: one u32 per cell, 0 dead or 1 alive, row by row.
// Pipe the output back in for the next generation.
override width: u32 = 64;

@group(0) @binding(0) var<storage, read> src: array<u32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
  let n = arrayLength(&src);
  let height = n / width;
  let x = id.x % width;
  let y = id.x / width;
  let l = (x + width - 1u) % width;
  let r = (x + 1u) % width;
  let u = (y + height - 1u) % height * width;
  let d = (y + 1u) % height * width;
  let row = y * width;
  let neighbors = src[u + l] + src[u + x] + src[u + r]
                + src[row + l] + src[row + r]
                + src[d + l] + src[d + x] + src[d + r];
  let alive = src[id.x] == 1u;
  dst[id.x] = select(0u, 1u, neighbors == 3u || (alive && neighbors == 2u));
}
