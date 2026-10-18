## Entity browser previews of particle classes: a still frame put together
## from what a class shows. Most placed classes are invisible emitters, so
## this follows their emitters to the particles that are drawn: sprites,
## beams, contrails, geometry and decals, with their textures (first frame),
## tint, relative size and the texture's additive or alpha blending.
##
## Input is OniSplit's -extract:xml of the classes (BINA3RAP<class>.xml) and
## of their textures (TXMP<name>.xml + .tga), and -extract:dae of geometry.

import std/[os, strutils, tables, sets, math, xmltree, xmlparser, random, algorithm]
import vmath, pixie
import tga, thumbs

type
  ParticleLayer* = object
    display*: string          ## Sprite, RotatedSprite, Flat, Discus, Arrow, Beam, Contrail, Geometry, Decal.
    texGeom*: string          ## TXMP or M3GM name (without the prefix).
    scale, yScale: float32    ## yScale: 0 = same as scale.
    tint: Vec3                ## 0..1.

  Tex = object
    img: TgaImage
    additive: bool
    gain: float32       ## Brings faint textures (clouds, glows) up to full strength.
    average: Vec3       ## Mean color of the covered texels.

proc loadClassXml(file: string): XmlNode =
  if not fileExists(file): return nil
  var s = readFile(file)
  if s.startsWith("\xEF\xBB\xBF"): s = s[3 .. ^1]
  try: parseXml(s) except CatchableError: nil

proc firstElem(n: XmlNode): XmlNode =
  for c in n:
    if c.kind == xnElement: return c

proc numbers(s: string): seq[float32] =
  for t in s.splitWhitespace:
    try: result.add parseFloat(t).float32
    except ValueError: return @[]

proc rangeValue(n: XmlNode): seq[float32] =
  ## A Random/BellCurve/... element: the middle of its range.
  let lo = numbers(n.attr("Min"))
  let hi = numbers(n.attr("Max"))
  if lo.len > 0 and lo.len == hi.len:
    for i in 0 ..< lo.len: result.add (lo[i] + hi[i]) / 2
    return
  for a in ["Mean", "Value", "Min", "Max"]:
    result = numbers(n.attr(a))
    if result.len > 0: return

proc value(n: XmlNode, vars: Table[string, XmlNode], depth = 0): seq[float32] =
  ## A value as the class writes it: literal, a range, or a variable's name.
  if n == nil or depth > 4: return
  let e = n.firstElem
  if e != nil: return rangeValue(e)
  let s = n.innerText.strip
  result = numbers(s)
  if result.len == 0 and s in vars: result = value(vars[s], vars, depth + 1)

proc particleLayers*(classDir, cls: string): seq[ParticleLayer] =
  ## The visible particles a class shows, itself first, then what its
  ## emitters spawn (breadth first), one per display/texture pair.
  var queue = @[cls]
  var seen: HashSet[string]
  var shown: HashSet[string]
  while queue.len > 0 and seen.len < 40 and result.len < 5:
    let c = queue[0]
    queue.delete(0)
    if c in seen: continue
    seen.incl c
    let x = loadClassXml(classDir / "BINA3RAP" & c & ".xml")
    if x == nil: continue
    let p = x.child("Particle")
    if p == nil: continue
    var vars: Table[string, XmlNode]
    let vs = p.child("Variables")
    if vs != nil:
      for v in vs:
        if v.kind == xnElement: vars[v.attr("Name")] = v
    let a = p.child("Appearance")
    if a != nil and a.child("Invisible").innerText.strip != "true":
      var l = ParticleLayer(display: a.child("DisplayType").innerText.strip,
                            texGeom: a.child("TexGeom").innerText.strip, tint: vec3(1, 1, 1))
      let sc = value(a.child("Scale"), vars)
      l.scale = if sc.len > 0: abs(sc[0]) else: 1
      if a.child("UseSeparateYScale").innerText.strip == "true":
        let ys = value(a.child("YScale"), vars)
        if ys.len > 0: l.yScale = abs(ys[0])
      let t = value(a.child("Tint"), vars)
      if t.len >= 3: l.tint = vec3(t[0], t[1], t[2]) / 255
      if l.scale <= 0: l.scale = 1
      let key = l.display & "/" & l.texGeom
      if l.texGeom.len > 0 and key notin shown:
        shown.incl key
        result.add l
    let es = p.child("Emitters")
    if es != nil:
      for e in es:
        if e.kind == xnElement:
          let k = e.child("Class")
          if k != nil and k.innerText.strip.len > 0: queue.add k.innerText.strip

proc loadTex(texDir, name: string): Tex =
  ## TXMP<name>.xml: its flags and first frame.
  let x = loadClassXml(texDir / "TXMP" & name & ".xml")
  if x == nil: return
  let t = x.child("Texture")
  if t == nil: return
  result.additive = "AdditiveBlend" in t.child("Flags").innerText
  let img = t.child("Image")
  if img == nil: return
  try: result.img = readTga(readFile(texDir / img.innerText.strip))
  except CatchableError: return
  var peak = 0'f32
  var sum = vec3(0, 0, 0)
  var w = 0'f32
  let px = result.img.rgba
  for i in countup(0, px.len - 4, 4):
    let c = vec3(px[i].float32, px[i + 1].float32, px[i + 2].float32) / 255
    let a = px[i + 3].float32 / 255
    let strength = if result.additive: max(c.x, max(c.y, c.z)) * a else: a
    peak = max(peak, strength)
    sum += c * strength
    w += strength
  result.gain = if peak > 0.01: min(1 / peak, 4) else: 1
  result.average = if w > 0: sum / w else: vec3(1, 1, 1)

type Canvas = object
  n: int
  px: seq[Vec4]   ## Premultiplied.

proc sample(t: TgaImage, u, v: float32): Vec4 =
  ## Bilinear, clamped; 0..1 straight RGBA.
  let x = clamp(u * t.width.float32 - 0.5, 0, (t.width - 1).float32)
  let y = clamp(v * t.height.float32 - 0.5, 0, (t.height - 1).float32)
  let x0 = int(x)
  let y0 = int(y)
  let x1 = min(x0 + 1, t.width - 1)
  let y1 = min(y0 + 1, t.height - 1)
  let fx = x - x0.float32
  let fy = y - y0.float32
  # A template: a nested proc would capture (copy) the whole image per call.
  template at(xx, yy: int): Vec4 =
    let o = (yy * t.width + xx) * 4
    vec4(t.rgba[o].float32, t.rgba[o + 1].float32, t.rgba[o + 2].float32, t.rgba[o + 3].float32) / 255
  mix(mix(at(x0, y0), at(x1, y0), fx), mix(at(x0, y1), at(x1, y1), fx), fy)

proc blend(c: var Canvas, i: int, col: Vec3, a: float32, additive: bool) =
  if additive:
    let d = c.px[i]
    let rgb = vec3(d.x, d.y, d.z) + col * a
    c.px[i] = vec4(rgb.x, rgb.y, rgb.z, max(d.w, min(1, max(rgb.x, max(rgb.y, rgb.z)))))
  else:
    c.px[i] = vec4(col.x * a, col.y * a, col.z * a, a) + c.px[i] * (1 - a)

proc drawTex(c: var Canvas, t: Tex, center: Vec2, half: Vec2, tint: Vec3, angle = 0'f32) =
  ## The texture on a (rotated) rectangle.
  if t.img.width == 0: return
  let r = half.length
  let (cs, sn) = (cos(angle), sin(angle))
  for y in max(0, int(center.y - r)) .. min(c.n - 1, int(center.y + r)):
    for x in max(0, int(center.x - r)) .. min(c.n - 1, int(center.x + r)):
      let d = vec2(x.float32 + 0.5, y.float32 + 0.5) - center
      let l = vec2(d.x * cs + d.y * sn, -d.x * sn + d.y * cs)
      if abs(l.x) > half.x or abs(l.y) > half.y: continue
      let s = t.img.sample(l.x / half.x * 0.5 + 0.5, l.y / half.y * 0.5 + 0.5)
      let col = vec3(s.x, s.y, s.z) * tint
      if t.additive: c.blend(y * c.n + x, col * t.gain, s.w, true)
      elif s.w > 0.003: c.blend(y * c.n + x, col, min(1, s.w * t.gain), false)

proc drawStreak(c: var Canvas, a, b: Vec2, width: float32, col: Vec3) =
  ## A soft additive line (contrails: sparks, arcs).
  let lo = min(a, b) - vec2(width)
  let hi = max(a, b) + vec2(width)
  let ab = b - a
  let len2 = max(ab.dot(ab), 1e-6)
  for y in max(0, int(lo.y)) .. min(c.n - 1, int(hi.y)):
    for x in max(0, int(lo.x)) .. min(c.n - 1, int(hi.x)):
      let p = vec2(x.float32 + 0.5, y.float32 + 0.5)
      let t = clamp((p - a).dot(ab) / len2, 0, 1)
      let d = (p - (a + ab * t)).length
      if d < width: c.blend(y * c.n + x, col, (1 - d / width) * (1 - 0.6 * t), true)

proc renderParticle*(layers: seq[ParticleLayer], texDir, modelDir: string,
                     decalAspect = 1'f32, size = ThumbSize): Image =
  ## A still frame of the layers, fitted to the image: biggest at the back,
  ## additive ones on top, small ones (embers, snow, bugs) scattered around.
  result = newImage(size, size)
  if layers.len == 0: return
  const ss = 2
  var c = Canvas(n: size * ss)
  c.px.setLen(c.n * c.n)
  let n = c.n.float32
  let center = vec2(n / 2, n / 2)
  proc extent(l: ParticleLayer): float32 =
    if l.display == "Contrail": 0 else: max(l.scale, l.yScale)
  var biggest = 0'f32
  for l in layers: biggest = max(biggest, l.extent)
  if biggest <= 0: biggest = 1
  var texs: Table[string, Tex]
  for l in layers:
    if l.display notin ["Geometry"] and l.texGeom notin texs: texs[l.texGeom] = loadTex(texDir, l.texGeom)
  # Back to front: alpha-blended (big first), then additive (big first).
  var order: seq[int]
  for i in 0 ..< layers.len: order.add i
  proc rank(i: int): float32 =
    let l = layers[i]
    let add = l.display == "Contrail" or (l.texGeom in texs and texs[l.texGeom].additive)
    (if add: 1e6'f32 else: 0'f32) - l.extent
  order.sort(proc(x, y: int): int = cmp(rank(x), rank(y)))
  var rng = initRand(7)
  let full = n * 0.44
  for i in order:
    let l = layers[i]
    let frac = l.extent / biggest
    case l.display
    of "Decal":
      template t: Tex = texs[l.texGeom]
      let half = if decalAspect >= 1: vec2(full, full / decalAspect) else: vec2(full * decalAspect, full)
      c.drawTex(Tex(img: t.img, additive: false, gain: 1), center, half, l.tint)
    of "Contrail":
      var avg = if texs[l.texGeom].img.width > 0: texs[l.texGeom].average * l.tint else: l.tint
      avg /= max(0.05, max(avg.x, max(avg.y, avg.z)))   # Full brightness, its hue.
      for k in 0 ..< 7:
        let ang = rng.rand(2 * PI).float32
        var p = center
        let steps = 4
        let len = full * rng.rand(0.5 .. 1.0).float32
        for s in 0 ..< steps:
          let q = p + vec2(cos(ang), sin(ang)) * len / steps.float32 +
                  vec2(rng.rand(-1.0 .. 1.0).float32, rng.rand(-1.0 .. 1.0).float32) * n * 0.03
          c.drawStreak(p, q, n * 0.012, avg * 0.9)
          p = q
    of "Geometry":
      var m: ThumbMesh
      m.addDae(modelDir / l.texGeom & ".dae")
      if m.isEmpty: continue
      let sz = max(8, int(n * 0.9 * max(frac, 0.5)))
      let img = m.render(sz)
      let o = int(center.x) - sz div 2
      for y in 0 ..< sz:
        for x in 0 ..< sz:
          let p = img.data[y * sz + x]
          if p.a == 0: continue
          let a = p.a.float32 / 255
          let col = vec3(p.r.float32, p.g.float32, p.b.float32) / 255 / a * l.tint
          if o + x in 0 ..< c.n and o + y in 0 ..< c.n: c.blend((o + y) * c.n + o + x, col, a, false)
    else:
      template t: Tex = texs[l.texGeom]
      var half = vec2(l.scale, if l.yScale > 0: l.yScale else: l.scale) / biggest * full
      if l.display == "Beam" and l.yScale == 0: half.y *= 2
      # Thin beams and streaks stay readable.
      half = max(half, vec2(max(half.x, half.y) * 0.25))
      if max(half.x, half.y) < n * 0.12:
        # Small particles: a handful around the middle, each still readable.
        let k = n * 0.07 / max(half.x, half.y)
        half *= k
        for j in 0 ..< 9:
          let p = center + vec2(rng.rand(-1.0 .. 1.0).float32, rng.rand(-1.0 .. 1.0).float32) * full * 0.8
          c.drawTex(t, p, half, l.tint)
      else:
        c.drawTex(t, center, half, l.tint)
  for y in 0 ..< size:
    for x in 0 ..< size:
      var acc = vec4(0, 0, 0, 0)
      for dy in 0 ..< ss:
        for dx in 0 ..< ss:
          acc += c.px[(y * ss + dy) * c.n + x * ss + dx]
      acc /= (ss * ss).float32
      let a = clamp(acc.w, 0, 1)
      result.data[y * size + x] = rgbx(uint8(clamp(acc.x, 0, a) * 255), uint8(clamp(acc.y, 0, a) * 255),
                                       uint8(clamp(acc.z, 0, a) * 255), uint8(a * 255))

proc particleTextures*(layers: seq[ParticleLayer]): seq[string] =
  for l in layers:
    if l.display != "Geometry" and l.texGeom notin result: result.add l.texGeom

proc particleGeometry*(layers: seq[ParticleLayer]): seq[string] =
  for l in layers:
    if l.display == "Geometry" and l.texGeom notin result: result.add l.texGeom

proc renderParticleTo*(layers: seq[ParticleLayer], texDir, modelDir: string, decalAspect: float32,
                       path: string) =
  ## Writes the preview, unless nothing showed (then the browser keeps the
  ## type's color).
  let img = renderParticle(layers, texDir, modelDir, decalAspect)
  for c in img.data:
    if c.a > 0:
      img.writeFile(path)
      return
