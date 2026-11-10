## Minimal Targa reader for the textures OniSplit exports: true-color
## (type 2) and RLE true-color (type 10), 24 or 32 bits per pixel.

type
  TgaImage* = object
    width*, height*: int
    rgba*: seq[uint8]   ## Top row first, 4 bytes per pixel.

proc tgaSize*(data: string): (int, int) =
  ## Width and height from the header alone.
  if data.len < 18: raise newException(ValueError, "TGA too short")
  (data[12].uint8.int or (data[13].uint8.int shl 8), data[14].uint8.int or (data[15].uint8.int shl 8))

proc readTga*(data: string): TgaImage =
  if data.len < 18: raise newException(ValueError, "TGA too short")
  let
    idLen = data[0].uint8.int
    cmapType = data[1].uint8.int
    imageType = data[2].uint8.int
    cmapLen = data[5].uint8.int or (data[6].uint8.int shl 8)
    cmapBits = data[7].uint8.int
    w = data[12].uint8.int or (data[13].uint8.int shl 8)
    h = data[14].uint8.int or (data[15].uint8.int shl 8)
    bpp = data[16].uint8.int
    desc = data[17].uint8.int
  if imageType notin [2, 10] or bpp notin [24, 32]:
    raise newException(ValueError, "unsupported TGA type " & $imageType & "/" & $bpp)
  let px = bpp div 8
  var pos = 18 + idLen + (if cmapType != 0: cmapLen * ((cmapBits + 7) div 8) else: 0)
  var src = newSeq[uint8](w * h * 4)   # in file pixel order
  var n = 0

  proc putPixel(p: int) =
    src[n * 4 + 0] = data[p + 2].uint8
    src[n * 4 + 1] = data[p + 1].uint8
    src[n * 4 + 2] = data[p + 0].uint8
    src[n * 4 + 3] = (if px == 4: data[p + 3].uint8 else: 255'u8)
    inc n

  let total = w * h
  if imageType == 2:
    if pos + total * px > data.len: raise newException(ValueError, "TGA truncated")
    while n < total:
      putPixel(pos)
      pos += px
  else:
    while n < total:
      if pos >= data.len: raise newException(ValueError, "TGA truncated")
      let header = data[pos].uint8.int
      inc pos
      let count = (header and 0x7f) + 1
      if (header and 0x80) != 0:
        for _ in 0 ..< count:
          if n >= total: break
          putPixel(pos)
        pos += px
      else:
        for _ in 0 ..< count:
          if n >= total: break
          putPixel(pos)
          pos += px

  result.width = w
  result.height = h
  result.rgba = newSeq[uint8](w * h * 4)
  let topFirst = (desc and 0x20) != 0
  for y in 0 ..< h:
    let sy = if topFirst: y else: h - 1 - y
    copyMem(result.rgba[y * w * 4].addr, src[sy * w * 4].addr, w * 4)

proc seeThrough*(img: TgaImage): bool =
  ## Whether the picture has see-through pixels: the one test the viewport
  ## (blended pass), the Texture Browser (Alpha filter) and Build (Transparent
  ## flag) share. Alpha 250 and up counts as opaque, so export noise doesn't
  ## turn a solid texture into a blended one.
  var i = 3
  while i < img.rgba.len:
    if img.rgba[i] < 250: return true
    i += 4

proc makeOpaque*(data: var string) =
  ## Sets every pixel's alpha to 255 in place (32-bit images; others have none).
  if data.len < 18 or data[16].uint8 != 32 or data[2].uint8 notin [2'u8, 10]: return
  let
    idLen = data[0].uint8.int
    cmapLen = data[5].uint8.int or (data[6].uint8.int shl 8)
    cmapBits = data[7].uint8.int
    total = (data[12].uint8.int or (data[13].uint8.int shl 8)) *
            (data[14].uint8.int or (data[15].uint8.int shl 8))
    rle = data[2].uint8 == 10
  var pos = 18 + idLen + (if data[1].uint8 != 0: cmapLen * ((cmapBits + 7) div 8) else: 0)
  var n = 0
  while n < total and pos < data.len:
    var count = 1
    var stored = 1
    if rle:
      let header = data[pos].uint8.int
      inc pos
      count = (header and 0x7f) + 1
      stored = (if (header and 0x80) != 0: 1 else: count)
    for _ in 0 ..< stored:
      if pos + 3 < data.len: data[pos + 3] = '\xFF'
      pos += 4
    n += count
