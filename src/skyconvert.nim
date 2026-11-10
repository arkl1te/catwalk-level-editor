## Turns a single skybox picture into the five square faces Oni's ONSK takes
## (see sky.nim for their placement). Panoramas are resampled face by face, so
## a job can do one face per frame. Cube layouts are cut up.
##
## A cylindrical panorama shows only part of the sky: row = horizon - R tan(lat)
## with R = width / 2 pi. Above the picture its own sky goes on: mirrored at the
## top edge so that nothing shows a seam, then laid flat overhead, as stretching
## it up to the zenith would pinch it into a star. Whatever is much brighter than
## the sky (a moon) isn't repeated: its place gets the top row's color fading
## to the zenith's. The ground goes on below the picture the same way.
##
## Besides Oni's five there's a bottom face: the game only shows it with Arklite.

import std/[algorithm, math]
import vmath
import pictures, tga

type
  SkySource* = enum
    ssCylinder, ssEquirect, ssCrossH, ssCrossV, ssStrip

  SkyConverter* = ref object
    src: TgaImage
    kind: SkySource
    side*: int                  ## Faces are side x side.
    horizon, radius: float32    ## Cylinder: the horizon's row, pixels per radian.
    topLat: float32             ## Cylinder: elevation of the picture's top edge, degrees.
    bottomLat: float32          ## Cylinder: how far its bottom edge is below the horizon, degrees.
    topColor: seq[array[3, float32]]  ## Cylinder: the top rows, smoothed, per column.
    zenith: array[3, float32]
    skyRows, groundRows: int    ## Cylinder: the rows repeated above and below the picture.
    around: seq[float32]        ## Cylinder: the brightness around each pixel of those rows.

const
  SkySourceNames*: array[SkySource, string] = [
    "Cylindrical panorama", "Equirectangular panorama (2:1)", "Cube cross, horizontal (4:3)",
    "Cube cross, vertical (3:4)", "Cube strip (6:1 or 1:6)"]
  SkySourceHelp*: array[SkySource, string] = [
    "A wide 360° strip that stops above the horizon. Its own sky is carried on overhead.",
    "A full 360° by 180° sphere, the usual HDRI layout.",
    "Top above the front; left, front, right and back in a row; bottom below.",
    "Top, front, bottom and back (upside down) in a column; left and right beside the front.",
    "Six faces in a row or column: right, left, top, bottom, front, back."]
  GlowFade = 24'f32     ## Degrees over which the top row's color reaches the zenith's.
  MirrorEnd = 20'f32    ## Degrees above the picture by which the sky lies flat.
  FlatShear = 0.6'f32   ## Slides the flat sky's rows, or its mirrored rows would look like a kaleidoscope.
  SkyBright = (45'f32, 75'f32)  ## Sky brighter than this around isn't repeated (fades between).
  HorizonStep = 12'f32  ## A row-to-row change this big is a straight horizon.

proc guessSkySource*(w, h: int): SkySource =
  ## The layout a picture of this shape most likely has.
  let r = w.float / max(h, 1).float
  if abs(r - 2) < 0.03: ssEquirect
  elif abs(r - 4 / 3) < 0.03: ssCrossH
  elif abs(r - 3 / 4) < 0.03: ssCrossV
  elif abs(r - 6) < 0.1 or abs(r - 1 / 6) < 0.01: ssStrip
  else: ssCylinder

proc luma(s: TgaImage, x, y: int): float32 =
  let i = (y * s.width + x) * 4
  (s.rgba[i].float32 + s.rgba[i + 1].float32 + s.rgba[i + 2].float32) / 3

proc findHorizon(s: TgaImage): float32 =
  ## Where the far ground meets the sky. A sea or plain shows as one sharp
  ## line across the picture. Otherwise it's the skyline (per column, the first
  ## row that looks more like the ground than the sky) at its low points, as
  ## hills only rise above the horizon. The middle row if sky and ground
  ## look alike.
  let h = s.height
  var mean = newSeq[float32](h)
  for y in 0 ..< h:
    for x in 0 ..< s.width: mean[y] += s.luma(x, y)
    mean[y] /= s.width.float32
  var (best, step) = (0, 0'f32)
  for y in h div 4 .. h * 3 div 4:
    let d = abs(mean[min(y + 2, h - 1)] - mean[max(y - 2, 0)])
    if d > step: (best, step) = (y, d)
  if step >= HorizonStep: return best.float32
  proc medianOf(y0, y1: int): float32 =
    var v: seq[float32]
    for y in y0 ..< y1:
      for x in 0 ..< s.width: v.add s.luma(x, y)
    v.sort
    v[v.len div 2]
  let sky = medianOf(0, h div 4)
  let ground = medianOf(h - h div 4, h)
  if abs(ground - sky) < 8: return h.float32 / 2
  let mid = (sky + ground) / 2
  let up = ground > sky
  var line: seq[int]
  for x in 0 ..< s.width:
    var row = h - 1
    for y in h div 8 ..< h - 2:
      var sum = 0'f32   # Three rows, so that a star doesn't count.
      for d in 0 .. 2: sum += s.luma(x, y + d)
      if (sum / 3 > mid) == up:
        row = y
        break
    line.add row
  line.sort
  clamp(line[line.len * 9 div 10], h div 4, h * 3 div 4).float32

proc boxMeans(s: TgaImage, rows, r: int): seq[float32] =
  ## The brightness around each pixel of the first rows, wrapping sideways.
  var sums = newSeq[float32]((rows + 1) * (s.width + 1))
  let w1 = s.width + 1
  for y in 0 ..< rows:
    for x in 0 ..< s.width:
      sums[(y + 1) * w1 + x + 1] = s.luma(x, y) + sums[y * w1 + x + 1] +
                                   sums[(y + 1) * w1 + x] - sums[y * w1 + x]
  result = newSeq[float32](rows * s.width)
  for y in 0 ..< rows:
    let (y0, y1) = (max(0, y - r), min(rows, y + r + 1))
    for x in 0 ..< s.width:
      let (x0, x1) = (max(0, x - r), min(s.width, x + r + 1))
      result[y * s.width + x] = (sums[y1 * w1 + x1] - sums[y0 * w1 + x1] - sums[y1 * w1 + x0] +
                                 sums[y0 * w1 + x0]) / float32((y1 - y0) * (x1 - x0))

proc prepareCylinder(c: SkyConverter) =
  let s = c.src
  c.horizon = findHorizon(s)
  c.radius = s.width.float32 / (2 * PI)
  c.topLat = radToDeg(arctan(c.horizon / c.radius))
  c.bottomLat = radToDeg(arctan((s.height.float32 - c.horizon) / c.radius))
  var line = newSeq[array[3, float32]](s.width)
  let rows = max(1, s.height div 40)
  for x in 0 ..< s.width:
    for y in 0 ..< rows:
      for k in 0 .. 2: line[x][k] += s.rgba[(y * s.width + x) * 4 + k].float32 / rows.float32
  # Smoothed twice so that stars on the top row don't streak up the sky.
  let r = max(1, s.width div 50)
  for _ in 0 .. 1:
    var next = line
    for x in 0 ..< s.width:
      for k in 0 .. 2:
        var sum = 0'f32
        for d in -r .. r: sum += line[(x + d + s.width) mod s.width][k]
        next[x][k] = sum / float32(2 * r + 1)
    line = next
  c.topColor = line
  for k in 0 .. 2:   # Not the darkest: a zenith darker than the edge looks like a hole.
    var v = newSeq[float32](s.width)
    for x in 0 ..< s.width: v[x] = line[x][k]
    v.sort
    c.zenith[k] = v[s.width * 3 div 10]
  c.skyRows = max(4, int(c.horizon * 0.6))
  c.groundRows = max(4, int((s.height.float32 - c.horizon) * 0.6))
  c.around = s.boxMeans(c.skyRows, 6)

proc checkSkyShape*(w, h: int, kind: SkySource) =
  ## Raises ValueError when a picture of this shape can't have the layout.
  proc shape(ok: bool, what: string) =
    if not ok: raise newException(ValueError, what & ", but this picture is " & $w & "×" & $h)
  proc near(a, b: float): bool = abs(a / b - 1) < 0.03
  let r = w.float / max(h, 1).float
  case kind
  of ssCylinder: shape(r >= 1.5, "A cylindrical panorama is much wider than tall")
  of ssEquirect: shape(near(r, 2), "An equirectangular panorama is twice as wide as tall")
  of ssCrossH: shape(near(r, 4 / 3), "A horizontal cube cross is 4:3")
  of ssCrossV: shape(near(r, 3 / 4), "A vertical cube cross is 3:4")
  of ssStrip: shape(near(r, 6) or near(r, 1 / 6), "A cube strip is 6:1 or 1:6")

proc newSkyConverter*(src: TgaImage, kind: SkySource): SkyConverter =
  checkSkyShape(src.width, src.height, kind)
  let (w, h) = (src.width, src.height)
  result = SkyConverter(src: src, kind: kind)
  case kind
  of ssCylinder, ssEquirect:
    # Twice the picture's own detail, so resampling keeps what it has.
    var side = 256
    while side < w div 2 and side < MaxTextureSide: side *= 2
    result.side = side
  else:
    let cell = case kind
      of ssCrossH: w div 4
      of ssCrossV: w div 3
      else: min(w, h)
    result.side = fittedSize(cell, cell)[0]
  if kind == ssCylinder: result.prepareCylinder()

proc faceDir(face: string, u, v: float32): Vec3 =
  ## Direction of a face's point, u and v in 0..1 (the inverse of sky.nim's table).
  let (a, b) = (2 * u - 1, 1 - 2 * v)
  case face
  of "top": vec3(a, 1, b)
  of "bottom": vec3(a, -1, -b)
  of "right": vec3(1, b, a)
  of "left": vec3(-1, b, -a)
  of "back": vec3(-a, b, 1)
  else: vec3(a, b, -1)

proc catmull(p0, p1, p2, p3, t: float32): float32 =
  p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))

proc sample(s: TgaImage, col, row: float32): array[3, float32] =
  ## Bicubic; columns wrap (it's a full turn), rows stop at the edge.
  let (x0, y0) = (floor(col).int, floor(row).int)
  let (fx, fy) = (col - floor(col), row - floor(row))
  for k in 0 .. 2:
    var rows: array[4, float32]
    for j in 0 .. 3:
      let y = clamp(y0 + j - 1, 0, s.height - 1)
      template px(i: int): float32 =
        s.rgba[(y * s.width + ((x0 + i - 1) mod s.width + s.width) mod s.width) * 4 + k].float32
      rows[j] = catmull(px(0), px(1), px(2), px(3), fx)
    result[k] = catmull(rows[0], rows[1], rows[2], rows[3], fy)

proc skyAbove(c: SkyConverter, d: Vec3, col, lat: float32): array[3, float32] =
  ## The sky above the top of a cylindrical panorama. Called per pixel, so no
  ## let of c.src here: that copies the whole picture.
  template s: untyped = c.src
  let n = c.skyRows.float32 - 1
  proc bounce(p: float32): float32 =   # 0..n and back.
    let m = abs(p) mod (2 * n)
    if m > n: 2 * n - m else: m
  let past = lat - c.topLat
  let (mirrorCol, mirrorRow) = (col, bounce(past / 360 * s.width.float32))
  # Flat: as seen on a ceiling, at the picture's own scale.
  let flatCol = (d.x + d.z * FlatShear) / d.y * c.radius
  let flatRow = bounce(d.z / d.y * c.radius)
  var a = clamp((past - 4) / (MirrorEnd - 4), 0, 1)
  a = a * a * (3 - 2 * a)
  let mirrored = s.sample(mirrorCol, mirrorRow)
  let flat = s.sample(flatCol, flatRow)
  proc brightAt(cl, row: float32): float32 =
    let x = ((cl.int mod s.width) + s.width) mod s.width
    c.around[row.int * s.width + x]
  var t = clamp(past / GlowFade, 0, 1)
  t = t * t * (3 - 2 * t)
  let tc = ((col.int mod s.width) + s.width) mod s.width
  var w = max(brightAt(mirrorCol, mirrorRow) * (1 - a), brightAt(flatCol, flatRow) * a)
  w = clamp((w - SkyBright[0]) / (SkyBright[1] - SkyBright[0]), 0, 1)
  for k in 0 .. 2:
    let made = c.topColor[tc][k] * (1 - t) + c.zenith[k] * t
    result[k] = (mirrored[k] * (1 - a) + flat[k] * a) * (1 - w) + made * w

proc groundBelow(c: SkyConverter, d: Vec3, col, lat: float32): array[3, float32] =
  ## The ground below the bottom of a cylindrical panorama: skyAbove upside
  ## down, without its bright objects.
  template s: untyped = c.src
  let n = c.groundRows.float32 - 1
  let last = (s.height - 1).float32
  proc bounce(p: float32): float32 =
    let m = abs(p) mod (2 * n)
    last - (if m > n: 2 * n - m else: m)
  let past = -lat - c.bottomLat
  var a = clamp((past - 4) / (MirrorEnd - 4), 0, 1)
  a = a * a * (3 - 2 * a)
  let mirrored = s.sample(col, bounce(past / 360 * s.width.float32))
  let flat = s.sample((d.x + d.z * FlatShear) / -d.y * c.radius, bounce(d.z / -d.y * c.radius))
  for k in 0 .. 2: result[k] = mirrored[k] * (1 - a) + flat[k] * a

proc panoramaFace(c: SkyConverter, face: string): TgaImage =
  template s: untyped = c.src
  let n = c.side
  result = TgaImage(width: n, height: n, rgba: newSeq[uint8](n * n * 4))
  for y in 0 ..< n:
    for x in 0 ..< n:
      let d = faceDir(face, (x.float32 + 0.5) / n.float32, (y.float32 + 0.5) / n.float32)
      let lat = radToDeg(arcsin(d.y / length(d)))
      let lon = arctan2(d.x, -d.z)
      let col = (lon / (2 * PI) + 0.5) * s.width.float32 - 0.5
      var color: array[3, float32]
      if c.kind == ssEquirect:
        color = s.sample(col, (90 - lat) / 180 * s.height.float32 - 0.5)
      else:
        if lat > c.topLat:
          color = c.skyAbove(d, col, lat)
        elif lat < -c.bottomLat:
          color = c.groundBelow(d, col, lat)
        else:
          color = s.sample(col, clamp(c.horizon - c.radius * tan(degToRad(lat)) - 0.5,
                                      0, (s.height - 1).float32))
      let i = (y * n + x) * 4
      for k in 0 .. 2: result.rgba[i + k] = uint8(clamp(color[k] + 0.5, 0, 255))
      result.rgba[i + 3] = 255

proc cell(s: TgaImage, cx, cy, size, side: int, turned = false): TgaImage =
  ## The size x size square at grid place cx, cy, as a side x side face.
  var part = TgaImage(width: size, height: size, rgba: newSeq[uint8](size * size * 4))
  for y in 0 ..< size:
    for x in 0 ..< size:
      let (sx, sy) = if turned: (cx * size + size - 1 - x, cy * size + size - 1 - y)
                     else: (cx * size + x, cy * size + y)
      for k in 0 .. 2: part.rgba[(y * size + x) * 4 + k] = s.rgba[(sy * s.width + sx) * 4 + k]
      part.rgba[(y * size + x) * 4 + 3] = 255
  part.resized(side, side)

proc face*(c: SkyConverter, name: string): TgaImage =
  ## A face: top, left, right, front, back or bottom.
  let s = c.src
  case c.kind
  of ssCylinder, ssEquirect: c.panoramaFace(name)
  of ssCrossH:
    let (cx, cy) = case name
      of "top": (1, 0)
      of "bottom": (1, 2)
      of "left": (0, 1)
      of "right": (2, 1)
      of "back": (3, 1)
      else: (1, 1)
    s.cell(cx, cy, s.width div 4, c.side)
  of ssCrossV:
    let (cx, cy) = case name
      of "top": (1, 0)
      of "bottom": (1, 2)
      of "left": (0, 1)
      of "right": (2, 1)
      of "back": (1, 3)
      else: (1, 1)
    s.cell(cx, cy, s.width div 3, c.side, turned = name == "back")
  of ssStrip:
    let i = case name
      of "right": 0
      of "left": 1
      of "top": 2
      of "bottom": 3
      of "front": 4
      else: 5
    let size = min(s.width, s.height)
    if s.width > s.height: s.cell(i, 0, size, c.side) else: s.cell(0, i, size, c.side)
