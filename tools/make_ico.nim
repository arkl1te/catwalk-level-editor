## Renders assets/catwalk.svg into a Windows .ico (PNG
## entries, 16-256 px) for the executable's icon resource (from Majestic).
##   nim r tools/make_ico.nim

import std/[os, streams]
import pixie, pixie/fileformats/svg

const Sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]

let root = currentSourcePath().parentDir.parentDir
let data = readFile(root / "assets/catwalk.svg")
var pngs: seq[string]
for s in Sizes:
  pngs.add newImage(parseSvg(data, s, s)).encodeImage(PngFormat)

let outPath = root / "assets/windows/catwalk.ico"
createDir(outPath.parentDir)
let f = newFileStream(outPath, fmWrite)
f.write 0'u16                   # reserved
f.write 1'u16                   # type: icon
f.write Sizes.len.uint16
var offset = 6 + 16 * Sizes.len
for i, s in Sizes:
  f.write uint8(if s >= 256: 0 else: s)  # 0 means 256
  f.write uint8(if s >= 256: 0 else: s)
  f.write 0'u8                  # palette size
  f.write 0'u8                  # reserved
  f.write 1'u16                 # color planes
  f.write 32'u16                # bits per pixel
  f.write pngs[i].len.uint32
  f.write offset.uint32
  offset += pngs[i].len
for p in pngs: f.write p
f.close()
echo "wrote ", outPath
