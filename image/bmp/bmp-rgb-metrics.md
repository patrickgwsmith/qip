# BMP RGB metrics

`bmp-rgb-metrics.wasm` compares two same-sized, uncompressed B8G8R8A8 sRGB BMP files
and emits a JSON report containing RGB MSE, PSNR, and SSIM.

Its input is a POSIX ustar archive containing exactly two root-level regular
files named `reference.bmp` and `candidate.bmp`. Entry order does not matter.
The fixed names identify each image without introducing a private container
format:

```sh
COPYFILE_DISABLE=1 tar -cf images.tar reference.bmp candidate.bmp
./qip run -i images.tar -- image/bmp/bmp-rgb-metrics.wasm
```

The input content type is `application/x-tar`; output is JSON. The component
rejects missing, duplicate, or additional entries, non-regular entries,
invalid checksums, non-ustar headers, and non-zero padding. Each BMP may be
top-down or bottom-up. Width and height must match.

RGB PSNR uses the global mean squared error over all red, green, and blue
samples:

```text
MSE  = sum((reference - candidate)^2) / (width * height * 3)
PSNR = 10 * log10(255^2 / MSE)
```

An exact match reports `"identical": true` and `"psnr_rgb_db": null`, because
its mathematical PSNR is positive infinity.

SSIM matches FFmpeg's 8-bit approximation: uniformly weighted 8x8 windows
overlapping every four pixels, calculated separately for R, G, and B. The
reported `ssim_rgb` is the equal mean of those three channel scores. This is
not the Gaussian-window formulation from the original SSIM paper, nor a
perceptual color-space metric.

The component keeps no image copies or scratch image planes. Its 128 MiB input
capacity includes the TAR headers and is enough for two B8G8R8A8 sRGB BMPs of about
16 megapixels each. On a 12 MP pair it took about 132 ms under Node and 3.45
seconds in QIP's default Go/Wasm runtime on the development machine.
