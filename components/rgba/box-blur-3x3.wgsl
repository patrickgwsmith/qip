// Each pixel becomes the mean of itself and its eight neighbors.
fn pixel(c: vec4f) -> vec4f {
  let above = sample(-1, -1) + sample(0, -1) + sample(1, -1);
  let row = sample(-1, 0) + c + sample(1, 0);
  let below = sample(-1, 1) + sample(0, 1) + sample(1, 1);
  return (above + row + below) / 9.0;
}
