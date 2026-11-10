## A level's sky settings: brightness, then a tint in some blend mode. They
## never touch a sky's images. The 3D view applies them in its shader (keep
## skyGrade in render.nim the same as this), and Build on copies of the faces,
## as Oni has no such step of its own.

import tga

type
  SkyBlend* = enum
    sbNone, sbMultiply, sbScreen, sbOverlay, sbSoftLight, sbAdd, sbColor

  SkyGrade* = object
    brightness*: float32        ## 1 leaves it as it is.
    blend*: SkyBlend
    tint*: array[3, int]

const
  PlainSky* = SkyGrade(brightness: 1, blend: sbNone, tint: [255, 255, 255])
  SkyBlendNames*: array[SkyBlend, string] = [
    "None", "Multiply", "Screen", "Overlay", "Soft light", "Add", "Color"]

proc isPlain*(g: SkyGrade): bool = g.brightness == 1 and g.blend == sbNone

proc gradePixel(g: SkyGrade, c: var array[3, float32]) =
  ## 0..1 per channel.
  var t: array[3, float32]
  for k in 0 .. 2:
    t[k] = g.tint[k].float32 / 255
    c[k] = min(c[k] * g.brightness, 1)
  let luma = c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114
  let tintLuma = max(t[0] * 0.299 + t[1] * 0.587 + t[2] * 0.114, 0.001)
  for k in 0 .. 2:
    let (b, s) = (c[k], t[k])
    c[k] = case g.blend
      of sbNone: b
      of sbMultiply: b * s
      of sbScreen: 1 - (1 - b) * (1 - s)
      of sbOverlay: (if b < 0.5: 2 * b * s else: 1 - 2 * (1 - b) * (1 - s))
      of sbSoftLight: (1 - 2 * s) * b * b + 2 * s * b
      of sbAdd: min(b + s, 1)
      of sbColor: min(s * luma / tintLuma, 1)

proc graded*(src: TgaImage, g: SkyGrade): TgaImage =
  result = src
  for i in 0 ..< src.width * src.height:
    var c: array[3, float32]
    for k in 0 .. 2: c[k] = src.rgba[i * 4 + k].float32 / 255
    g.gradePixel(c)
    for k in 0 .. 2: result.rgba[i * 4 + k] = uint8(clamp(c[k] * 255 + 0.5, 0, 255))
