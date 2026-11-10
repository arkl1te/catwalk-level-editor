## Entity browser previews: a small software renderer that draws a model
## (OniSplit .dae files or library prefab geometry) from a three-quarter view
## into a transparent image, like TrenchBroom's entity browser.
## Software, so the library build can make them without a GL context.

import std/[tables, math, os, streams, strutils]
import vmath, pixie
import collada, geometry, tga

const ThumbSize* = 144   ## Pixels; the browser scales them down.

type
  ThumbTri* = object
    p*: array[3, Vec3]
    uv*: array[3, Vec2]
    col*: array[3, array[4, uint8]]
    tex*: int                      ## Index into images, -1 = untextured.

  ThumbMesh* = object
    tris*: seq[ThumbTri]
    images*: seq[string]           ## .tga paths.
    imageIndex: Table[string, int]

proc imageId(m: var ThumbMesh, path: string): int =
  if path.len == 0 or not fileExists(path): return -1
  if path notin m.imageIndex:
    m.imageIndex[path] = m.images.len
    m.images.add path
  m.imageIndex[path]

proc isEmpty*(m: ThumbMesh): bool = m.tris.len == 0

proc addDae*(m: var ThumbMesh, path: string, offset = vec3(0, 0, 0), image = "",
             posed = false, upright = false) =
  ## Adds a .dae model, moved by offset. image replaces its textures (doors
  ## take theirs from the level); posed: at its animation's first frame;
  ## upright: turned 90° about X (door models lie flat until their animation
  ## stands them up). Missing files add nothing.
  if not fileExists(path): return
  let scene = readDae(path, posed)
  for b in scene.batches:
    let t = m.imageId(if image.len > 0: image else: b.image)
    var i = 0
    while i + 2 < b.verts.len:
      var tri = ThumbTri(tex: t)
      for k in 0 .. 2:
        let v = b.verts[i + k]
        let p = if upright: vec3(v.pos.x, -v.pos.z, v.pos.y) else: v.pos
        tri.p[k] = p + offset
        tri.uv[k] = v.uv
        tri.col[k] = v.color
      m.tris.add tri
      i += 3

proc addGeometry*(m: var ThumbMesh, g: Geometry, imagePath: proc(texture: string): string) =
  ## Adds the visible faces of library prefab geometry. "_" textures are
  ## markers, except the device screens the library has images of.
  for f in g.faces:
    if f.verts.len < 3 or (f.flags and (gfInvisible or gfGhost or gfDoorFrame)) != 0: continue
    let image = imagePath(f.texture)
    if f.texture.len > 0 and f.texture[0] == '_' and not fileExists(image): continue
    let t = m.imageId(image)
    for k in 1 ..< f.verts.len - 1:
      var tri = ThumbTri(tex: t)
      for (j, c) in [(0, 0), (1, k), (2, k + 1)]:
        tri.p[j] = g.points[f.verts[c]]
        tri.uv[j] = f.uvs[c]
        tri.col[j] = f.shownColor(c)
      m.tris.add tri

proc render*(m: ThumbMesh, size = ThumbSize, cutouts = true): Image =
  ## Orthographic, from the front-left and above, fitted to the image with a
  ## margin. Rendered at twice the size and filtered down. cutouts: texels
  ## with alpha are holes.
  result = newImage(size, size)
  if m.tris.len == 0: return
  const ss = 2
  let n = size * ss
  # Oni is Y up; characters face +Z.
  let yaw = degToRad(-35'f32)
  let pitch = degToRad(-22'f32)
  let fwd = -vec3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
  let right = fwd.cross(vec3(0, 1, 0)).normalize
  let up = right.cross(fwd)
  let light = vec3(-0.35, 0.8, 0.5).normalize
  var lo = vec2(Inf.float32)
  var hi = vec2(-Inf.float32)
  for t in m.tris:
    for p in t.p:
      let q = vec2(p.dot(right), p.dot(up))
      lo = min(lo, q)
      hi = max(hi, q)
  let ext = max(hi.x - lo.x, hi.y - lo.y)
  if ext <= 0: return
  let scale = n.float32 * 0.88 / ext
  let center = (lo + hi) / 2
  var textures: seq[TgaImage]
  var alpha: seq[bool]
  for path in m.images:
    try:
      let img = readTga(readFile(path))
      textures.add img
      var a = false
      var i = 3
      while i < img.rgba.len:
        if img.rgba[i] < 250:
          a = true
          break
        i += 4
      alpha.add a
    except CatchableError:
      textures.add TgaImage()
      alpha.add false
  var depth = newSeq[float32](n * n)
  for d in depth.mitems: d = Inf.float32
  var color = newSeq[array[4, float32]](n * n)
  for t in m.tris:
    var s: array[3, Vec3]   ## Screen x, y, depth.
    for k in 0 .. 2:
      let p = t.p[k]
      s[k] = vec3((p.dot(right) - center.x) * scale + n.float32 / 2,
                  n.float32 / 2 - (p.dot(up) - center.y) * scale,
                  p.dot(fwd))
    let area = (s[1].x - s[0].x) * (s[2].y - s[0].y) - (s[2].x - s[0].x) * (s[1].y - s[0].y)
    if abs(area) < 1e-6: continue
    var nrm = (t.p[1] - t.p[0]).cross(t.p[2] - t.p[0])
    if nrm.length < 1e-12: continue
    nrm = nrm.normalize
    if nrm.dot(fwd) > 0: nrm = -nrm   # Two-sided.
    let shade = 0.62'f32 + 0.5'f32 * max(0'f32, nrm.dot(light))
    let x0 = max(0, int(floor(min(s[0].x, min(s[1].x, s[2].x)))))
    let x1 = min(n - 1, int(ceil(max(s[0].x, max(s[1].x, s[2].x)))))
    let y0 = max(0, int(floor(min(s[0].y, min(s[1].y, s[2].y)))))
    let y1 = min(n - 1, int(ceil(max(s[0].y, max(s[1].y, s[2].y)))))
    let tex = if t.tex >= 0 and textures[t.tex].width > 0: t.tex else: -1
    let (tw, th) = if tex >= 0: (textures[tex].width, textures[tex].height) else: (0, 0)
    let cutout = cutouts and tex >= 0 and alpha[tex]
    for y in y0 .. y1:
      for x in x0 .. x1:
        let px = x.float32 + 0.5
        let py = y.float32 + 0.5
        let w0 = ((s[1].x - px) * (s[2].y - py) - (s[2].x - px) * (s[1].y - py)) / area
        let w1 = ((s[2].x - px) * (s[0].y - py) - (s[0].x - px) * (s[2].y - py)) / area
        let w2 = 1 - w0 - w1
        if w0 < 0 or w1 < 0 or w2 < 0: continue
        let z = w0 * s[0].z + w1 * s[1].z + w2 * s[2].z
        let i = y * n + x
        if z >= depth[i]: continue
        var c = [1'f32, 1, 1, 1]
        if tex >= 0:
          # Indexed in place: a `let` copy of the image here costs its whole pixel data.
          let uv = t.uv[0] * w0 + t.uv[1] * w1 + t.uv[2] * w2
          let tx = floorMod(int(floor(uv.x * tw.float32)), tw)
          let ty = floorMod(int(floor(uv.y * th.float32)), th)
          let o = (ty * tw + tx) * 4
          if cutout and textures[tex].rgba[o + 3] < 128: continue
          for j in 0 .. 2: c[j] = textures[tex].rgba[o + j].float32 / 255
        for j in 0 .. 2:
          let vc = (t.col[0][j].float32 * w0 + t.col[1][j].float32 * w1 + t.col[2][j].float32 * w2) / 255
          c[j] *= vc * shade
        depth[i] = z
        color[i] = c
  for y in 0 ..< size:
    for x in 0 ..< size:
      var acc = [0'f32, 0, 0, 0]
      for dy in 0 ..< ss:
        for dx in 0 ..< ss:
          let c = color[(y * ss + dy) * n + x * ss + dx]
          for j in 0 .. 3: acc[j] += c[j]
      let k = 1'f32 / (ss * ss).float32
      # Premultiplied, as pixie stores it (covered samples carry alpha 1).
      result.data[y * size + x] = rgbx(uint8(clamp(acc[0] * k, 0, 1) * 255),
        uint8(clamp(acc[1] * k, 0, 1) * 255), uint8(clamp(acc[2] * k, 0, 1) * 255),
        uint8(clamp(acc[3] * k, 0, 1) * 255))

proc renderTo*(m: ThumbMesh, path: string, size = ThumbSize) =
  ## Renders the preview to a .png file. Models that are all holes (glass,
  ## placeholder weapons) are shown solid instead of not at all.
  var img = m.render(size)
  var covered = false
  for c in img.data:
    if c.a > 0:
      covered = true
      break
  if not covered: img = m.render(size, cutouts = false)
  img.writeFile(path)

# --- saved models (the viewport draws them at their objects) ----------------------------

const ModelMagic = "CWM1"

proc bounds*(m: ThumbMesh): (Vec3, Vec3) =
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  for t in m.tris:
    for p in t.p:
      lo = min(lo, p)
      hi = max(hi, p)
  (lo, hi)

proc saveModel*(m: ThumbMesh, path, base, imageDir, keep: string) =
  ## Writes the mesh to path. Images outside keep are copied into imageDir;
  ## the file names them relative to base (which holds both).
  var s = newFileStream(path, fmWrite)
  if s == nil: raise newException(IOError, "cannot write " & path)
  defer: s.close()
  s.write ModelMagic
  s.write m.images.len.int32
  for img in m.images:
    var src = img
    if not img.startsWith(keep & "/"):
      createDir(imageDir)
      src = imageDir / img.extractFilename
      if not fileExists(src): copyFile(img, src)
    let rel = src.relativePath(base)
    s.write rel.len.int32
    s.write rel
  s.write m.tris.len.int32
  for t in m.tris:
    s.write t.tex.int32
    for k in 0 .. 2:
      for c in [t.p[k].x, t.p[k].y, t.p[k].z, t.uv[k].x, t.uv[k].y]: s.write c
      for c in t.col[k]: s.write c

proc loadModel*(path, base: string): ThumbMesh =
  ## A mesh saveModel wrote; empty if the file is missing or not one.
  if not fileExists(path): return
  var s = newFileStream(path, fmRead)
  if s == nil: return
  defer: s.close()
  try:
    if s.readStr(4) != ModelMagic: return
    for i in 0 ..< s.readInt32:
      let n = s.readInt32
      result.images.add base / s.readStr(n)
    let n = s.readInt32
    result.tris.setLen n
    for t in result.tris.mitems:
      t.tex = s.readInt32
      for k in 0 .. 2:
        let (x, y, z, u, v) = (s.readFloat32, s.readFloat32, s.readFloat32, s.readFloat32, s.readFloat32)
        t.p[k] = vec3(x, y, z)
        t.uv[k] = vec2(u, v)
        for c in t.col[k].mitems: c = s.readUint8
  except IOError, OSError:
    result = ThumbMesh()
