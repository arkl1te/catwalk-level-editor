## Reads the Collada (.dae) files OniSplit writes for level geometry into
## world-space triangle batches, one batch per texture image.
## Supports what OniSplit emits: <triangles>, <polylist> and <polygons> with
## VERTEX/TEXCOORD/COLOR inputs, and node <matrix>/<translate>/<rotate>/<scale>.

import std/[xmlparser, xmltree, strutils, tables, os, math]
import vmath

type
  DaeVertex* = object
    pos*: Vec3
    uv*: Vec2
    color*: array[4, uint8]

  DaeBatch* = object
    image*: string          ## Absolute image path, or "" for untextured.
    material*: string
    verts*: seq[DaeVertex]  ## Triangle list.

  DaeScene* = object
    batches*: seq[DaeBatch]
    boundsMin*, boundsMax*: Vec3

  Source = object
    data: seq[float32]
    stride: int

  Input = object
    semantic, source: string
    offset, set: int

  Primitive = object
    material: string
    inputs: seq[Input]
    vcount: seq[int]        ## Corners per polygon (all 3 for <triangles>).
    p: seq[int]

  Geometry = object
    sources: Table[string, Source]
    positionOf: Table[string, string]   ## <vertices> id -> POSITION source id
    prims: seq[Primitive]

  Mat = array[16, float32]   ## Row-major, as Collada writes it.

const Identity: Mat = [1'f32, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

proc `*`(a, b: Mat): Mat =
  for r in 0 .. 3:
    for c in 0 .. 3:
      var s = 0'f32
      for k in 0 .. 3: s += a[r * 4 + k] * b[k * 4 + c]
      result[r * 4 + c] = s

proc apply(m: Mat, p: Vec3): Vec3 =
  vec3(m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
       m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
       m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])

proc floats(s: string): seq[float32] =
  for tok in s.splitWhitespace: result.add parseFloat(tok).float32

proc ints(s: string): seq[int] =
  for tok in s.splitWhitespace: result.add parseInt(tok)

proc stripHash(s: string): string =
  if s.startsWith("#"): s[1 .. ^1] else: s

iterator elems(n: XmlNode, tag: string): XmlNode =
  ## Direct children with the given tag.
  if n != nil:
    for c in n:
      if c.kind == xnElement and c.tag == tag: yield c

proc first(n: XmlNode, tag: string): XmlNode =
  for c in n.elems(tag): return c

proc findAll(n: XmlNode, tag: string, acc: var seq[XmlNode]) =
  for c in n:
    if c.kind == xnElement:
      if c.tag == tag: acc.add c
      c.findAll(tag, acc)

proc findFirst(n: XmlNode, tag: string): XmlNode =
  var acc: seq[XmlNode]
  n.findAll(tag, acc)
  if acc.len > 0: acc[0] else: nil

proc readGeometry(g: XmlNode): Geometry =
  let mesh = g.first("mesh")
  if mesh == nil: return
  for s in mesh.elems("source"):
    var src: Source
    let fa = s.first("float_array")
    if fa != nil: src.data = floats(fa.innerText)
    src.stride = 1
    let acc = s.findFirst("accessor")
    if acc != nil and acc.attr("stride").len > 0: src.stride = parseInt(acc.attr("stride"))
    result.sources[s.attr("id")] = src
  for v in mesh.elems("vertices"):
    for inp in v.elems("input"):
      if inp.attr("semantic") == "POSITION":
        result.positionOf[v.attr("id")] = inp.attr("source").stripHash
  for c in mesh:
    if c.kind != xnElement or c.tag notin ["triangles", "polylist", "polygons"]: continue
    var prim = Primitive(material: c.attr("material"))
    for inp in c.elems("input"):
      prim.inputs.add Input(semantic: inp.attr("semantic"), source: inp.attr("source").stripHash,
        offset: parseInt(inp.attr("offset")),
        set: (if inp.attr("set").len > 0: parseInt(inp.attr("set")) else: 0))
    case c.tag
    of "triangles":
      let pn = c.first("p")
      if pn != nil: prim.p = ints(pn.innerText)
    of "polylist":
      let vc = c.first("vcount")
      if vc != nil: prim.vcount = ints(vc.innerText)
      let pn = c.first("p")
      if pn != nil: prim.p = ints(pn.innerText)
    else:  # polygons: one <p> per polygon
      var stride = 0
      for inp in prim.inputs: stride = max(stride, inp.offset + 1)
      for pn in c.elems("p"):
        let idx = ints(pn.innerText)
        prim.vcount.add idx.len div max(stride, 1)
        prim.p.add idx
    result.prims.add prim

proc nodeMatrix(n: XmlNode): Mat =
  result = Identity
  for c in n:
    if c.kind != xnElement: continue
    case c.tag
    of "matrix":
      let f = floats(c.innerText)
      if f.len == 16:
        var m: Mat
        for i in 0 .. 15: m[i] = f[i]
        result = result * m
    of "translate":
      let f = floats(c.innerText)
      if f.len == 3:
        var m = Identity
        m[3] = f[0]; m[7] = f[1]; m[11] = f[2]
        result = result * m
    of "scale":
      let f = floats(c.innerText)
      if f.len == 3:
        var m = Identity
        m[0] = f[0]; m[5] = f[1]; m[10] = f[2]
        result = result * m
    of "rotate":
      let f = floats(c.innerText)
      if f.len == 4:
        var axis = vec3(f[0], f[1], f[2])
        if axis.length > 0: axis = axis.normalize
        let
          a = f[3].float64.degToRad
          cs = cos(a).float32
          sn = sin(a).float32
          t = 1 - cs
          (x, y, z) = (axis.x, axis.y, axis.z)
        var m = Identity
        m[0] = t*x*x + cs;   m[1] = t*x*y - sn*z; m[2] = t*x*z + sn*y
        m[4] = t*x*y + sn*z; m[5] = t*y*y + cs;   m[6] = t*y*z - sn*x
        m[8] = t*x*z - sn*y; m[9] = t*y*z + sn*x; m[10] = t*z*z + cs
        result = result * m
    else: discard

proc applyFirstFrame(root: XmlNode) =
  ## Poses the node hierarchy at its animation's first key. OniSplit writes a
  ## character's bones unposed (laid out along X) plus its idle animation,
  ## with channels like "pelvis/pos.X" and "pelvis/rotX.ANGLE".
  var nodes, anims, inputs: seq[XmlNode]
  root.findAll("node", nodes)
  root.findAll("animation", anims)
  var byId: Table[string, XmlNode]
  for n in nodes: byId[n.attr("id")] = n
  for anim in anims:
    var arrays, samplers: Table[string, XmlNode]
    for s in anim.elems("source"):
      let fa = s.first("float_array")
      if fa != nil: arrays[s.attr("id")] = fa
    for s in anim.elems("sampler"): samplers[s.attr("id")] = s
    for ch in anim.elems("channel"):
      let target = ch.attr("target")
      let slash = target.find('/')
      let dot = target.rfind('.')
      if slash < 0 or dot < slash: continue
      let node = byId.getOrDefault(target[0 ..< slash])
      let sampler = samplers.getOrDefault(ch.attr("source").stripHash)
      if node == nil or sampler == nil: continue
      var output: seq[float32]
      for inp in sampler.elems("input"):
        if inp.attr("semantic") == "OUTPUT":
          let fa = arrays.getOrDefault(inp.attr("source").stripHash)
          if fa != nil: output = floats(fa.innerText)
      if output.len == 0: continue
      let sid = target[slash + 1 ..< dot]
      let comp = case target[dot + 1 .. ^1]
        of "X": 0
        of "Y": 1
        of "Z": 2
        of "ANGLE": 3
        else: -1
      if comp < 0: continue
      for c in node:
        if c.kind == xnElement and c.attr("sid") == sid:
          var f = floats(c.innerText)
          if comp < f.len:
            f[comp] = output[0]
            var parts: seq[string]
            for x in f: parts.add $x
            while c.len > 0: c.delete(0)
            c.add newText(parts.join(" "))
          break

proc readDae*(path: string, firstFrame = false): DaeScene =
  ## firstFrame: pose animated nodes at their first key (character models).
  let root = loadXml(path)
  if firstFrame: root.applyFirstFrame()
  let dir = path.parentDir

  var images: Table[string, string]
  for lib in root.elems("library_images"):
    for img in lib.elems("image"):
      let f = img.first("init_from")
      if f != nil:
        var p = f.innerText.strip
        if p.startsWith("file://"): p = p[7 .. ^1]
        images[img.attr("id")] = if p.isAbsolute: p else: normalizedPath(dir / p)

  var effectImage: Table[string, string]
  for lib in root.elems("library_effects"):
    for fx in lib.elems("effect"):
      var inits: seq[XmlNode]
      fx.findAll("init_from", inits)
      for i in inits:
        let id = i.innerText.strip
        if id in images:
          effectImage[fx.attr("id")] = images[id]
          break

  var materialImage: Table[string, string]
  for lib in root.elems("library_materials"):
    for m in lib.elems("material"):
      let ie = m.first("instance_effect")
      if ie != nil:
        materialImage[m.attr("id")] = effectImage.getOrDefault(ie.attr("url").stripHash)

  var geometries: Table[string, Geometry]
  for lib in root.elems("library_geometries"):
    for g in lib.elems("geometry"):
      geometries[g.attr("id")] = readGeometry(g)

  var batchIndex: Table[string, int]
  result.boundsMin = vec3(Inf.float32)
  result.boundsMax = vec3(-Inf.float32)

  proc emit(scene: var DaeScene, geo: Geometry, binds: Table[string, string], m: Mat) =
    for prim in geo.prims:
      let matId = binds.getOrDefault(prim.material, prim.material)
      let image = materialImage.getOrDefault(matId)
      let key = matId & "|" & image
      if key notin batchIndex:
        batchIndex[key] = scene.batches.len
        scene.batches.add DaeBatch(image: image, material: matId)
      let bi = batchIndex[key]
      var stride = 0
      var posSrc, uvSrc, colSrc: Source
      var posOff, uvOff, colOff = -1
      for inp in prim.inputs:
        stride = max(stride, inp.offset + 1)
        case inp.semantic
        of "VERTEX":
          posOff = inp.offset
          posSrc = geo.sources.getOrDefault(geo.positionOf.getOrDefault(inp.source, inp.source))
        of "TEXCOORD":
          if uvOff < 0 or inp.set == 0:
            uvOff = inp.offset; uvSrc = geo.sources.getOrDefault(inp.source)
        of "COLOR":
          colOff = inp.offset; colSrc = geo.sources.getOrDefault(inp.source)
        else: discard
      if posOff < 0 or stride == 0: continue

      template corner(k: int): DaeVertex =
        var v: DaeVertex
        let base = (k) * stride
        let pi = prim.p[base + posOff] * posSrc.stride
        v.pos = m.apply(vec3(posSrc.data[pi], posSrc.data[pi + 1], posSrc.data[pi + 2]))
        if uvOff >= 0 and uvSrc.data.len > 0:
          let ti = prim.p[base + uvOff] * uvSrc.stride
          v.uv = vec2(uvSrc.data[ti], 1 - uvSrc.data[ti + 1])
        v.color = [255'u8, 255, 255, 255]
        if colOff >= 0 and colSrc.data.len > 0:
          let ci = prim.p[base + colOff] * colSrc.stride
          for j in 0 ..< min(colSrc.stride, 4):
            v.color[j] = uint8(clamp(colSrc.data[ci + j], 0, 1) * 255)
        v

      var k = 0
      let polys = if prim.vcount.len > 0: prim.vcount
                  else: newSeq[int]((prim.p.len div stride) div 3)
      for i, cnt in polys:
        let n = if prim.vcount.len > 0: cnt else: 3
        if (k + n) * stride > prim.p.len: break
        let c0 = corner(k)
        for j in 1 .. n - 2:
          let c1 = corner(k + j)
          let c2 = corner(k + j + 1)
          for c in [c0, c1, c2]:
            scene.batches[bi].verts.add c
            scene.boundsMin = min(scene.boundsMin, c.pos)
            scene.boundsMax = max(scene.boundsMax, c.pos)
        k += n

  proc walk(scene: var DaeScene, n: XmlNode, parent: Mat) =
    let m = parent * nodeMatrix(n)
    for ig in n.elems("instance_geometry"):
      var binds: Table[string, string]
      var mats: seq[XmlNode]
      ig.findAll("instance_material", mats)
      for im in mats: binds[im.attr("symbol")] = im.attr("target").stripHash
      let id = ig.attr("url").stripHash
      if id in geometries: scene.emit(geometries[id], binds, m)
    for c in n.elems("node"): scene.walk(c, m)

  for lib in root.elems("library_visual_scenes"):
    for vs in lib.elems("visual_scene"):
      for n in vs.elems("node"): result.walk(n, Identity)
