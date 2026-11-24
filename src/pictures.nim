## Pictures brought in from outside: read from the formats people have, fitted
## to what Oni can show, and written as the TGA files the rest of Catwalk uses.
##
## What the game takes (found in Oni.exe and OniSplit):
##   - Sides must be powers of 2: the engine walks the mipmaps by halving them.
##   - Pixels are stored as 32-bit BGRX (OniSplit "bgr"), 32-bit BGRA ("rgba"),
##     16-bit BGR555, BGRA5551, BGRA4444 or DXT1. -create:level takes the first
##     two, picked by whether the image has alpha.
##   - The OpenGL driver converts every one of those into a fixed 256x256x4 byte
##     buffer while uploading (0x40524e), so the stock game overruns it past
##     65536 pixels. Arklite makes the buffer big enough for MaxTextureSide
##     squares (arklite/src/texture_clamp.c), and Catwalk's levels only run on
##     Arklite.

import std/[math, os, strutils, osproc, streams, strformat]
import pixie
import tga

const
  MaxTextureSide* = 1024
  DirectFormats* = ["png", "jpg", "jpeg", "bmp", "gif", "qoi", "ppm", "tga"]
  OniSplitFormats* = ["dds", "tif", "tiff"]   ## Read through OniSplit.

var ffmpegCopies = 0

proc decodeWithFfmpeg(path: string, why: ref CatchableError): Image =
  ## A picture Pixie can't read (16-bit PNG...), as ffmpeg reads it, at 8
  ## bits per channel; raises why when there's no ffmpeg or it can't either.
  if findExe("ffmpeg").len == 0: raise why
  inc ffmpegCopies
  let tmp = getTempDir() / &"catwalk-picture-{getCurrentProcessId()}-{ffmpegCopies}.png"
  try:
    let p = startProcess("ffmpeg", args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                                           "-frames:v", "1", "-pix_fmt", "rgba", "-c:v", "png", "-f", "image2", tmp],
                         options = {poUsePath, poStdErrToStdOut})
    discard p.outputStream.readAll
    let code = p.waitForExit
    p.close()
    if code != 0 or not fileExists(tmp): raise why
    result = decodeImage(readFile(tmp))
  finally:
    if fileExists(tmp): removeFile(tmp)

proc readPicture*(path: string): TgaImage =
  if path.splitFile.ext.toLowerAscii == ".tga": return readTga(readFile(path))
  var img: Image
  try: img = decodeImage(readFile(path))
  except PixieError as e: img = decodeWithFfmpeg(path, e)
  result = TgaImage(width: img.width, height: img.height, rgba: newSeq[uint8](img.width * img.height * 4))
  for i, px in img.data:
    let c = px.rgba
    result.rgba[i * 4] = c.r
    result.rgba[i * 4 + 1] = c.g
    result.rgba[i * 4 + 2] = c.b
    result.rgba[i * 4 + 3] = c.a

proc nearestPower(n: int, maxSide = MaxTextureSide): int =
  ## The power of 2 nearest to n, at most maxSide (a power of 2).
  1 shl clamp(round(log2(max(n, 1).float)).int, 0, log2(maxSide.float).int)

proc fittedSize*(w, h: int, maxSide = MaxTextureSide): (int, int) =
  ## Size a w x h picture gets: scaled to fit maxSide, each side then taken to
  ## its nearest power of 2.
  let s = min(1.0, maxSide / max(w, h))
  (nearestPower(int(w.float * s), maxSide), nearestPower(int(h.float * s), maxSide))

proc resized*(src: TgaImage, w, h: int): TgaImage =
  ## Averages the source pixels each target pixel covers (linear when enlarging).
  if src.width == w and src.height == h: return src
  result = TgaImage(width: w, height: h, rgba: newSeq[uint8](w * h * 4))
  proc span(i, dst, from0: int): (float, float) =
    let k = from0.float / dst.float
    (i.float * k, max((i + 1).float * k, i.float * k + 1))
  template at(x, y, c: int): float = src.rgba[(y * src.width + x) * 4 + c].float
  for y in 0 ..< h:
    let (y0, y1) = span(y, h, src.height)
    for x in 0 ..< w:
      let (x0, x1) = span(x, w, src.width)
      var sum: array[4, float]
      var weight = 0.0
      for sy in int(y0) .. min(int(ceil(y1)) - 1, src.height - 1):
        let wy = min(y1, (sy + 1).float) - max(y0, sy.float)
        for sx in int(x0) .. min(int(ceil(x1)) - 1, src.width - 1):
          let wt = wy * (min(x1, (sx + 1).float) - max(x0, sx.float))
          for c in 0 .. 3: sum[c] += at(sx, sy, c) * wt
          weight += wt
      for c in 0 .. 3:
        result.rgba[(y * w + x) * 4 + c] = uint8(clamp(sum[c] / max(weight, 1e-6), 0, 255))

proc writeTga*(path: string, img: TgaImage) =
  ## Uncompressed, top row first; 24 bits unless some pixel isn't opaque.
  var alpha = false
  var i = 3
  while i < img.rgba.len:
    if img.rgba[i] != 255:
      alpha = true
      break
    i += 4
  let px = if alpha: 4 else: 3
  var s = newString(18 + img.width * img.height * px)
  s[2] = char(2)
  s[12] = char(img.width and 255)
  s[13] = char(img.width shr 8)
  s[14] = char(img.height and 255)
  s[15] = char(img.height shr 8)
  s[16] = char(px * 8)
  s[17] = char(if alpha: 0x28 else: 0x20)
  var o = 18
  for p in 0 ..< img.width * img.height:
    s[o] = char(img.rgba[p * 4 + 2])
    s[o + 1] = char(img.rgba[p * 4 + 1])
    s[o + 2] = char(img.rgba[p * 4])
    if alpha: s[o + 3] = char(img.rgba[p * 4 + 3])
    o += px
  createDir(path.parentDir)
  writeFile(path, s)

proc safeName*(file: string): string =
  ## A file's name as an instance name: letters, digits and _, upper case.
  for ch in file.splitFile.name:
    result.add(if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: ch.toUpperAscii else: '_')
  if result.len > 40: result.setLen 40

# --- marker textures ---------------------------------------------------------

proc markerPictures*(): seq[(string, TgaImage)] =
  ## The pictures of the marker textures (ghosts, door frames, stairs...),
  ## drawn as OniSplit draws them (Akira/MaterialLibrary.cs, MarkerMaterials):
  ## a level made with no game level's textures gets them from here.
  proc surface(w, h: int): TgaImage = TgaImage(width: w, height: h, rgba: newSeq[uint8](w * h * 4))
  proc fill(s: var TgaImage, x, y, w, h: int, c: array[4, uint8]) =
    for yy in y ..< min(y + h, s.height):
      for xx in x ..< min(x + w, s.width):
        for k in 0 .. 3: s.rgba[(yy * s.width + xx) * 4 + k] = c[k]
  proc lines(s: var TgaImage, c: array[4, uint8]) =
    ## The frame and middle cross of the ghost, barrier and impassable markers.
    s.fill(0, 0, 128, 1, c)
    s.fill(0, 127, 128, 1, c)
    s.fill(0, 1, 1, 126, c)
    s.fill(127, 1, 1, 126, c)
    s.fill(64, 1, 1, 126, c)
    s.fill(1, 64, 126, 1, c)
  var ghost = surface(128, 128)
  ghost.fill(0, 0, 128, 128, [208'u8, 240, 240, 80])
  ghost.lines([16'u8, 48, 240, 240])
  var barrier = surface(128, 128)
  barrier.fill(0, 0, 128, 128, [0'u8, 240, 20, 180])
  barrier.lines([240'u8, 20, 0, 255])
  var danger = surface(128, 128)
  danger.fill(0, 0, 128, 128, [255'u8, 10, 0, 208])
  danger.fill(52, 16, 24, 64, [255'u8, 255, 255, 255])
  danger.fill(52, 96, 24, 16, [255'u8, 255, 255, 255])
  var door = surface(128, 128)
  door.fill(0, 0, 128, 128, [240'u8, 240, 0, 208])
  for (x, y, w, h) in [(1, 1, 126, 1), (1, 1, 1, 126), (1, 126, 126, 1), (126, 1, 1, 126)]:
    door.fill(x, y, w, h, [0'u8, 0, 240, 255])
  var stairs = surface(128, 128)
  stairs.fill(0, 0, 128, 128, [40'u8, 240, 0, 180])
  for y in countup(0, 127, 32): stairs.fill(0, y, 128, 16, [40'u8, 0, 240, 180])
  var impassable = surface(128, 128)
  impassable.fill(0, 0, 128, 128, [240'u8, 0, 20, 180])
  impassable.lines([240'u8, 20, 0, 255])
  var blackness = surface(16, 16)
  blackness.fill(0, 0, 16, 16, [0'u8, 0, 0, 255])
  @[("_marker_ghost", ghost), ("_marker_barrier", barrier), ("_marker_danger", danger), ("_marker_door", door),
    ("_marker_stairs", stairs), ("_marker_impassable", impassable), ("_marker_blackness", blackness)]

proc writeMarkerTextures*(dir: string) =
  ## The marker textures' pictures into dir (env/markers), leaving ones already there.
  createDir(dir)
  for (name, img) in markerPictures():
    if not fileExists(dir / name & ".tga"): writeTga(dir / name & ".tga", img)
