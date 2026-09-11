# Photo Light Table Assets

These photos are saved locally so the interactive module builds and runs offline. We use Unsplash images as source assets, then bake them to fixed 256x256 RGBA textures with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/qip-swift-module-cache \
swift tools/generate-photo-light-table-assets.swift \
  components/interactive/assets/photo-light-table/source \
  components/interactive/assets/photo-light-table/tga \
  256
```

Source photos, downloaded June 28, 2026:

- `00-bailey-zindel-landscape.jpg` - Bailey Zindel - `https://images.unsplash.com/photo-1506744038136-46273834b3fb`
- `01-marek-piwnicki-mountains.jpg` - Marek Piwnicki - `https://images.unsplash.com/photo-1773691323862-b33577111b0a`
- `02-pietro-de-grandi-boats.jpg` - Pietro De Grandi - `https://images.unsplash.com/photo-1501785888041-af3ef285b470`
- `03-kalen-emsley-snow.jpg` - Kalen Emsley - `https://images.unsplash.com/photo-1464822759023-fed622ff2c3b`
- `04-pine-watt-forest.jpg` - pine watt - `https://images.unsplash.com/photo-1511884642898-4c92249e20b6`
- `05-mark-harpur-lake.jpg` - Mark Harpur - `https://images.unsplash.com/photo-1532274402911-5a369e4c4bb5`
- `06-andre-benz-city.jpg` - Andre Benz - `https://images.unsplash.com/photo-1562351778-a451cb11dc90`
- `07-pedro-lastra-city.jpg` - Pedro Lastra - `https://images.unsplash.com/photo-1477959858617-67f85cf4f1df`
- `08-ben-obro-city.jpg` - ben o'bro - `https://images.unsplash.com/photo-1480714378408-67cf0d13bc1b`
- `09-max-bender-city.jpg` - Max Bender - `https://images.unsplash.com/photo-1519501025264-65ba15a82390`
- `10-robynne-hu-home.jpg` - Robynne Hu - `https://images.unsplash.com/photo-1500530855697-b586d89ba3ee`
- `11-jeremy-bishop-desert.jpg` - Jeremy Bishop - `https://images.unsplash.com/photo-1500534314209-a25ddb2bd429`

Unsplash license: `https://unsplash.com/license`

Future size pass: if the TGA BGRA8 assets make the module too large for a particular demo, compress `tga/*.tga` with zlib and inflate once in `ensureInit()`. The repo already has examples using `std.compress.flate.Decompress` in `bytes/zlib-decompress.zig`.
