## Models from other programs (Blender and the rest) as furniture: Wavefront
## OBJ (+ MTL), glTF 2.0 (.gltf, .glb) and Collada (.dae) files become a FURN
## object owning the model's faces, as the game's own furniture is made (see
## library.nim: furniture is nothing but level geometry linked to its object).
##
## Nothing here needs Arklite in the game: the faces are ordinary level quads
## and triangles, and the textures are fitted to 256x256, the most stock Oni
## uploads (pictures.nim).
##
## Conversion:
##   - Units: the files' meters (glTF always, OBJ by convention, Collada by its
##     <unit>) times OniUnitsPerMeter; Konoko's model is 17.15 units tall.
##   - Axes: Oni is Y up, like glTF and Blender's OBJ export; Collada's Z_UP and
##     X_UP are turned to Y up.
##   - The object's origin is the model's bottom center, so it stands where it's put.
##   - Faces: Oni takes flat, convex faces of 3 or 4 corners (geometry.faceProblems).
##     Polygons that are flat and convex stay whole (more than 4 corners: a fan
##     of quads); the others are cut into triangles.
##   - Colors: corners get a plain light from above (shadeColor), times the
##     file's vertex colors; Bake light relights them like any face. A
##     material's color with no texture becomes the face's tint on a white texture.

import std/[os, strutils, tables, json, base64, math, xmlparser, xmltree, uri, sequtils]
import vmath
import geometry, collada, pictures, tga, jobs, project

const
  ModelFormats* = ["obj", "gltf", "glb", "dae"]
  OniUnitsPerMeter* = 10'f32
  ModelTextureSide* = 256        ## Stock Oni's texture upload limit (no Arklite needed).
  WhiteTexture* = "CW_MODEL_WHITE"
  FurnitureFlags* = gfFurniture or gfNoOcclusion   ## What the game's furniture faces carry.
  PlanarTol = 0.02'f32           ## World units: well inside faceProblems' 0.05.
  WeldTol = 1e-4'f32

type
  ModelMaterial* = object
    name*: string
    image*: string               ## Picture file, "" = none.
    imageName*: string           ## What its texture is named after.
    color*: array[3, uint8]      ## sRGB. No image: the faces' color; with one, multiplies it (glTF).
    uvSet: int                   ## glTF: TEXCOORD_n of its texture.
    uvXform: array[6, float32]   ## glTF KHR_texture_transform as u' = a u + b v + c, v' = d u + e v + f.

  ModelPoly* = object
    pos*: seq[Vec3]              ## Oni axes, meters.
    uv*: seq[Vec2]               ## Catwalk's: v = 0 at the image's top row.
    nrm*: seq[Vec3]              ## Empty, or a unit normal per corner.
    col*: seq[array[3, uint8]]   ## Empty, or an sRGB color per corner.
    mat*: int                    ## Into materials; -1 = none.

  Model* = object
    polys*: seq[ModelPoly]
    materials*: seq[ModelMaterial]
    unit*: float32               ## Meters per file unit.

  ImportedModel* = object
    name*: string                ## The furniture's class: the file's name.
    file*: string
    geo*: Geometry               ## Object space: origin at the bottom center.
    textures*: seq[string]       ## Textures its faces use.
    size*: Vec3                  ## In world units.
    polygons*, faces*, cut*, dropped*: int  ## Source polygons; faces made; polygons cut into triangles; degenerate ones left out.
    warnings*: seq[string]

proc isModelFile*(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii
  ext.len > 1 and ext[1 .. ^1] in ModelFormats

proc toSrgb(x: float32): uint8 =
  ## A linear color channel (glTF, Blender) as the sRGB value Oni's colors are.
  let c = clamp(x, 0, 1)
  let s = if c <= 0.0031308: 12.92 * c else: 1.055 * pow(c, 1 / 2.4) - 0.055
  uint8(clamp(round(s * 255), 0, 255))

proc toByte(x: float32): uint8 = uint8(clamp(round(clamp(x, 0, 1) * 255), 0, 255))

const White = [255'u8, 255, 255]
const IdentityUv = [1'f32, 0, 0, 0, 1, 0]

# --- Wavefront OBJ --------------------------------------------------------------------------------

proc mapFile(rest: string): string =
  ## The file of an MTL map_* line, after its options (-bm 1, -o u v w, ...).
  const argCount = {"-bm": 1, "-blendu": 1, "-blendv": 1, "-boost": 1, "-cc": 1, "-clamp": 1,
                    "-imfchan": 1, "-mm": 2, "-o": 3, "-s": 3, "-t": 3, "-texres": 1, "-type": 1}.toTable
  let toks = rest.splitWhitespace
  var i = 0
  while i < toks.len and toks[i].startsWith("-") and toks[i] in argCount:
    var n = argCount[toks[i]]
    inc i
    # -o, -s and -t take 1 to 3 numbers.
    while n > 0 and i < toks.len:
      if toks[i].startsWith("-") and toks[i] in argCount: break
      try: discard parseFloat(toks[i])
      except ValueError:
        if toks[i] notin ["on", "off", "r", "g", "b", "m", "l", "z", "sphere", "cube_top", "cube_bottom",
                          "cube_front", "cube_back", "cube_left", "cube_right"]: break
      inc i
      dec n
  toks[i .. ^1].join(" ")

proc findFile(name, dir: string, alsoIn: seq[string] = @[]): string =
  ## name as written in a model file (relative, absolute, Windows slashes), or
  ## "" when it isn't there. Exporters often keep the path of another PC: then
  ## the file's name next to the model will do.
  if name.len == 0: return ""
  let n = name.replace('\\', '/').strip(chars = {'"', ' '})
  var tries = @[n, dir / n]
  for d in @[dir] & alsoIn: tries.add d / n.extractFilename
  for t in tries:
    if fileExists(t): return t.absolutePath.normalizedPath
  ""

proc readMtl(path: string, m: var Model, byName: var Table[string, int], dirs: seq[string]) =
  let text = readFile(path)
  # Blender writes its scene-linear base colors as they are.
  let linear = "Blender" in text[0 ..< min(text.len, 200)]
  var cur = -1
  for raw in text.splitLines:
    let line = raw.strip
    if line.len == 0 or line[0] == '#': continue
    let sp = line.find({' ', '\t'})
    let key = if sp < 0: line else: line[0 ..< sp]
    let rest = if sp < 0: "" else: line[sp + 1 .. ^1].strip
    case key
    of "newmtl":
      if rest in byName: cur = byName[rest]
      else:
        cur = m.materials.len
        byName[rest] = cur
        m.materials.add ModelMaterial(name: rest, color: White, uvXform: IdentityUv)
    of "Kd":
      if cur < 0: continue
      let v = rest.splitWhitespace
      if v.len >= 3:
        try:
          for k in 0 .. 2:
            let x = parseFloat(v[k]).float32
            m.materials[cur].color[k] = if linear: toSrgb(x) else: toByte(x)
        except ValueError: discard
    of "map_Kd":
      if cur < 0: continue
      let f = rest.mapFile
      m.materials[cur].image = findFile(f, path.parentDir, dirs)
      m.materials[cur].imageName = f.replace('\\', '/').extractFilename
      if m.materials[cur].image.len == 0 and f.len > 0:
        m.materials[cur].imageName = "?" & f   # Reported as missing.
    else: discard

proc readObj(path: string): Model =
  result.unit = 1
  var pts: seq[Vec3]
  var cols: seq[array[3, uint8]]
  var hasCols = false
  var uvs: seq[Vec2]
  var nrms: seq[Vec3]
  var byName: Table[string, int]
  var cur = -1
  let dir = path.parentDir
  proc idx(s: string, n: int): int =
    ## A 1-based (or negative, from the end) index, as 0-based; -1 = none.
    if s.len == 0: return -1
    let i = parseInt(s)
    result = if i < 0: n + i else: i - 1
    if result < 0 or result >= n: raise newException(ValueError, "index " & s & " out of range")
  var lineNo = 0
  for raw in lines(path):
    inc lineNo
    let line = raw.strip
    if line.len < 2 or line[0] == '#': continue
    let t = line.splitWhitespace
    proc need(n: int) =
      if t.len < n: raise newException(ValueError, "too few numbers")
    try:
      case t[0]
      of "v":
        need 4
        pts.add vec3(parseFloat(t[1]).float32, parseFloat(t[2]).float32, parseFloat(t[3]).float32)
        if t.len >= 7:
          hasCols = true
          cols.add [toByte(parseFloat(t[4]).float32), toByte(parseFloat(t[5]).float32), toByte(parseFloat(t[6]).float32)]
        else: cols.add White
      of "vt":
        need 2
        # OBJ's v runs up from the image's bottom row.
        uvs.add vec2(parseFloat(t[1]).float32, 1 - (if t.len > 2: parseFloat(t[2]).float32 else: 0))
      of "vn":
        need 4
        nrms.add vec3(parseFloat(t[1]).float32, parseFloat(t[2]).float32, parseFloat(t[3]).float32)
      of "f":
        var p = ModelPoly(mat: cur)
        var withNrm = true
        for c in t[1 .. ^1]:
          let parts = c.split('/')
          let vi = idx(parts[0], pts.len)
          if vi < 0: raise newException(ValueError, "a corner without a point")
          p.pos.add pts[vi]
          if hasCols: p.col.add cols[vi]
          let ti = if parts.len > 1: idx(parts[1], uvs.len) else: -1
          p.uv.add(if ti >= 0: uvs[ti] else: vec2(0, 0))
          let ni = if parts.len > 2: idx(parts[2], nrms.len) else: -1
          if ni >= 0 and nrms[ni].length > 1e-6: p.nrm.add nrms[ni].normalize
          else: withNrm = false
        if not withNrm: p.nrm.setLen 0
        if p.pos.len >= 3: result.polys.add p
      of "usemtl":
        let name = line[6 .. ^1].strip
        if name notin byName:
          byName[name] = result.materials.len
          result.materials.add ModelMaterial(name: name, color: White, uvXform: IdentityUv)
        cur = byName[name]
      of "mtllib":
        let rest = line[6 .. ^1].strip
        # One file with spaces in its name, or several.
        let one = findFile(rest, dir)
        let files = if one.len > 0: @[one] else: rest.splitWhitespace.mapIt(findFile(it, dir))
        for f in files:
          if f.len > 0: readMtl(f, result, byName, @[dir])
      else: discard
    except ValueError:
      raise newException(ValueError, "line " & $lineNo & ": can't read \"" & line & "\"")

# --- glTF 2.0 -------------------------------------------------------------------------------------

type
  M4 = array[16, float32]        ## Column-major, as glTF writes it.

const M4Identity: M4 = [1'f32, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

proc `*`(a, b: M4): M4 =
  for c in 0 .. 3:
    for r in 0 .. 3:
      var s = 0'f32
      for k in 0 .. 3: s += a[k * 4 + r] * b[c * 4 + k]
      result[c * 4 + r] = s

proc point(m: M4, p: Vec3): Vec3 =
  vec3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
       m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
       m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])

proc det3(m: M4): float32 =
  m[0] * (m[5] * m[10] - m[9] * m[6]) - m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2])

proc normalDir(m: M4, n: Vec3): Vec3 =
  ## n through the inverse transpose of m's 3x3 (up to scale: it's normalized).
  let (a, b, c) = (vec3(m[0], m[1], m[2]), vec3(m[4], m[5], m[6]), vec3(m[8], m[9], m[10]))
  # Rows of the inverse transpose are the cofactor columns.
  let (ca, cb, cc) = (cross(b, c), cross(c, a), cross(a, b))
  let r = ca * n.x + cb * n.y + cc * n.z
  if det3(m) < 0: -r else: r

proc nodeMatrix(n: JsonNode): M4 =
  if n.hasKey("matrix"):
    let a = n["matrix"]
    for i in 0 .. 15: result[i] = a[i].getFloat.float32
    return
  var t = vec3(0, 0, 0)
  var q = [0'f32, 0, 0, 1]
  var s = vec3(1, 1, 1)
  if n.hasKey("translation"):
    let a = n["translation"]
    t = vec3(a[0].getFloat.float32, a[1].getFloat.float32, a[2].getFloat.float32)
  if n.hasKey("rotation"):
    let a = n["rotation"]
    for i in 0 .. 3: q[i] = a[i].getFloat.float32
  if n.hasKey("scale"):
    let a = n["scale"]
    s = vec3(a[0].getFloat.float32, a[1].getFloat.float32, a[2].getFloat.float32)
  let (x, y, z, w) = (q[0], q[1], q[2], q[3])
  # Rotation matrix columns, each times its scale.
  result = [(1 - 2 * (y * y + z * z)) * s.x, (2 * (x * y + z * w)) * s.x, (2 * (x * z - y * w)) * s.x, 0'f32,
            (2 * (x * y - z * w)) * s.y, (1 - 2 * (x * x + z * z)) * s.y, (2 * (y * z + x * w)) * s.y, 0'f32,
            (2 * (x * z + y * w)) * s.z, (2 * (y * z - x * w)) * s.z, (1 - 2 * (x * x + y * y)) * s.z, 0'f32,
            t.x, t.y, t.z, 1'f32]

type Gltf = object
  j: JsonNode
  buffers: seq[string]
  dir: string

proc dataUri(uri: string): (bool, string, string) =
  ## (is one, media type, bytes) of a data: URI.
  if not uri.startsWith("data:"): return (false, "", "")
  let comma = uri.find(',')
  if comma < 0: raise newException(ValueError, "bad data URI")
  let head = uri[5 ..< comma]
  let body = uri[comma + 1 .. ^1]
  let mime = head.split(';')[0]
  (true, mime, if head.endsWith(";base64"): decode(body) else: decodeUrl(body))

proc componentSize(ct: int): int =
  case ct
  of 5120, 5121: 1
  of 5122, 5123: 2
  of 5125, 5126: 4
  else: raise newException(ValueError, "unknown accessor component type " & $ct)

proc componentAt(buf: string, off, ct: int, normalized: bool): float32 =
  if off < 0 or off + componentSize(ct) > buf.len:
    raise newException(ValueError, "accessor reads past its buffer")
  case ct
  of 5126:
    var f: float32
    copyMem(f.addr, buf[off].unsafeAddr, 4)
    f
  of 5121:
    let v = buf[off].uint8.float32
    if normalized: v / 255 else: v
  of 5120:
    let v = cast[int8](buf[off]).float32
    if normalized: max(v / 127, -1) else: v
  of 5123:
    var v: uint16
    copyMem(v.addr, buf[off].unsafeAddr, 2)
    if normalized: v.float32 / 65535 else: v.float32
  of 5122:
    var v: int16
    copyMem(v.addr, buf[off].unsafeAddr, 2)
    if normalized: max(v.float32 / 32767, -1) else: v.float32
  else:
    var v: uint32
    copyMem(v.addr, buf[off].unsafeAddr, 4)
    v.float32

proc typeComponents(t: string): int =
  case t
  of "SCALAR": 1
  of "VEC2": 2
  of "VEC3": 3
  of "VEC4", "MAT2": 4
  of "MAT3": 9
  of "MAT4": 16
  else: raise newException(ValueError, "unknown accessor type " & t)

proc viewBytes(g: Gltf, view: int): (string, int, int) =
  ## The buffer a bufferView is in, its offset in it and its stride (0 = packed).
  let v = g.j["bufferViews"][view]
  let b = v["buffer"].getInt
  if b < 0 or b >= g.buffers.len: raise newException(ValueError, "bufferView " & $view & " has no buffer")
  (g.buffers[b], v{"byteOffset"}.getInt, v{"byteStride"}.getInt)

proc accessor(g: Gltf, i: int): (seq[float32], int) =
  ## The accessor's values, flat, and how many make one element.
  let a = g.j["accessors"][i]
  let ct = a["componentType"].getInt
  let n = typeComponents(a["type"].getStr)
  let count = a["count"].getInt
  let norm = a{"normalized"}.getBool
  var vals = newSeq[float32](count * n)
  if a.hasKey("bufferView"):
    let (buf, viewOff, viewStride) = g.viewBytes(a["bufferView"].getInt)
    let size = componentSize(ct)
    let stride = if viewStride > 0: viewStride else: size * n
    let base = viewOff + a{"byteOffset"}.getInt
    for e in 0 ..< count:
      for k in 0 ..< n:
        vals[e * n + k] = componentAt(buf, base + e * stride + k * size, ct, norm)
  if a.hasKey("sparse"):
    let sp = a["sparse"]
    let sc = sp["count"].getInt
    let ix = sp["indices"]
    let (ib, io, _) = g.viewBytes(ix["bufferView"].getInt)
    let ict = ix["componentType"].getInt
    let vs = sp["values"]
    let (vb, vo, _) = g.viewBytes(vs["bufferView"].getInt)
    let size = componentSize(ct)
    for s in 0 ..< sc:
      let e = componentAt(ib, io + ix{"byteOffset"}.getInt + s * componentSize(ict), ict, false).int
      if e < 0 or e >= count: raise newException(ValueError, "sparse accessor index out of range")
      for k in 0 ..< n:
        vals[e * n + k] = componentAt(vb, vo + vs{"byteOffset"}.getInt + (s * n + k) * size, ct, norm)
  (vals, n)

proc gltfImage(g: Gltf, img: int, work: string, model: string): (string, string) =
  ## (picture file, name) of images[img]; embedded ones are written into work.
  let im = g.j["images"][img]
  var name = im{"name"}.getStr
  if im.hasKey("uri"):
    let (isData, mime, bytes) = dataUri(im["uri"].getStr)
    if not isData:
      let f = decodeUrl(im["uri"].getStr)
      if name.len == 0: name = f.extractFilename
      return (findFile(f, g.dir), name)
    let ext = if "/" in mime: mime.split('/')[1] else: "png"
    let file = work / "image" & $img & "." & (if ext == "jpeg": "jpg" else: ext)
    createDir(work)
    writeFile(file, bytes)
    return (file, if name.len > 0: name else: model & "_" & $img)
  if im.hasKey("bufferView"):
    let v = g.j["bufferViews"][im["bufferView"].getInt]
    let (buf, off, _) = g.viewBytes(im["bufferView"].getInt)
    let len = v["byteLength"].getInt
    if off + len > buf.len: raise newException(ValueError, "image " & $img & " reads past its buffer")
    let mime = im{"mimeType"}.getStr
    let ext = if "/" in mime: mime.split('/')[1] else: "png"
    let file = work / "image" & $img & "." & (if ext == "jpeg": "jpg" else: ext)
    createDir(work)
    writeFile(file, buf[off ..< off + len])
    return (file, if name.len > 0: name else: model & "_" & $img)
  ("", name)

proc readGltf(path, work: string): Model =
  result.unit = 1
  var g = Gltf(dir: path.parentDir)
  let data = readFile(path)
  var bin = ""
  var hasBin = false
  if data.len >= 12 and data[0 .. 3] == "glTF":
    # GLB: a 12-byte header, then the JSON chunk and an optional BIN chunk.
    var o = 12
    var jsonText = ""
    while o + 8 <= data.len:
      var len, kind: uint32
      copyMem(len.addr, data[o].unsafeAddr, 4)
      copyMem(kind.addr, data[o + 4].unsafeAddr, 4)
      if o + 8 + len.int > data.len: raise newException(ValueError, "the .glb file is cut short")
      let chunk = data[o + 8 ..< o + 8 + len.int]
      if kind == 0x4E4F534A'u32: jsonText = chunk
      elif kind == 0x004E4942'u32 and not hasBin:
        bin = chunk
        hasBin = true
      o += 8 + ((len.int + 3) and not 3)
    g.j = parseJson(jsonText)
  else:
    g.j = parseJson(data)
  let ver = g.j{"asset"}{"version"}.getStr
  if ver.len > 0 and not ver.startsWith("2"):
    raise newException(ValueError, "glTF " & ver & " files aren't supported, only glTF 2")
  for i, b in g.j{"buffers"}.getElems:
    if b.hasKey("uri"):
      let (isData, _, bytes) = dataUri(b["uri"].getStr)
      if isData: g.buffers.add bytes
      else:
        let f = findFile(decodeUrl(b["uri"].getStr), g.dir)
        if f.len == 0: raise newException(ValueError, "its buffer file " & b["uri"].getStr & " is missing")
        g.buffers.add readFile(f)
    elif i == 0 and hasBin: g.buffers.add bin
    else: g.buffers.add ""
  let model = path.splitFile.name
  # Materials: base color texture and factor (or the old specular-glossiness ones).
  var imageOf: Table[int, (string, string)]
  for mi, mat in g.j{"materials"}.getElems:
    var mm = ModelMaterial(name: mat{"name"}.getStr, color: White, uvXform: IdentityUv)
    var factor = mat{"pbrMetallicRoughness"}{"baseColorFactor"}
    var tex = mat{"pbrMetallicRoughness"}{"baseColorTexture"}
    let sg = mat{"extensions"}{"KHR_materials_pbrSpecularGlossiness"}
    if sg != nil:
      if tex == nil: tex = sg{"diffuseTexture"}
      if factor == nil: factor = sg{"diffuseFactor"}
    if factor != nil and factor.len >= 3:
      for k in 0 .. 2: mm.color[k] = toSrgb(factor[k].getFloat.float32)
    if tex != nil:
      mm.uvSet = tex{"texCoord"}.getInt
      let xf = tex{"extensions"}{"KHR_texture_transform"}
      if xf != nil:
        if xf.hasKey("texCoord"): mm.uvSet = xf["texCoord"].getInt
        let off = xf{"offset"}
        let sc = xf{"scale"}
        let r = xf{"rotation"}.getFloat.float32
        let (ox, oy) = (if off != nil: (off[0].getFloat.float32, off[1].getFloat.float32) else: (0'f32, 0'f32))
        let (sx, sy) = (if sc != nil: (sc[0].getFloat.float32, sc[1].getFloat.float32) else: (1'f32, 1'f32))
        mm.uvXform = [cos(r) * sx, sin(r) * sy, ox, -sin(r) * sx, cos(r) * sy, oy]
      let t = g.j{"textures"}{tex{"index"}.getInt}
      if t != nil:
        var src = t{"source"}
        if src == nil:
          for ext in ["EXT_texture_webp", "KHR_texture_basisu", "MSFT_texture_dds"]:
            if t{"extensions"}{ext}{"source"} != nil: src = t["extensions"][ext]["source"]
        if src != nil:
          let si = src.getInt
          if si notin imageOf: imageOf[si] = g.gltfImage(si, work, model)
          (mm.image, mm.imageName) = imageOf[si]
          if mm.image.len == 0: mm.imageName = "?" & mm.imageName
    result.materials.add mm

  proc prims(m: var Model, mesh: JsonNode, mat: M4) =
    let flip = det3(mat) < 0    # A mirrored node turns its faces around.
    for pr in mesh{"primitives"}.getElems:
      let mode = if pr.hasKey("mode"): pr["mode"].getInt else: 4
      if mode notin [4, 5, 6]: continue   # Points and lines.
      let at = pr["attributes"]
      if not at.hasKey("POSITION"): continue
      let (pos, _) = g.accessor(at["POSITION"].getInt)
      let nv = pos.len div 3
      let matIdx = if pr.hasKey("material"): pr["material"].getInt else: -1
      let mm = if matIdx >= 0 and matIdx < m.materials.len: m.materials[matIdx] else: ModelMaterial(uvXform: IdentityUv)
      let uvKey = "TEXCOORD_" & $mm.uvSet
      var uv: seq[float32]
      if at.hasKey(uvKey): uv = g.accessor(at[uvKey].getInt)[0]
      var nrm: seq[float32]
      if at.hasKey("NORMAL"): nrm = g.accessor(at["NORMAL"].getInt)[0]
      var col: seq[float32]
      var colN = 0
      if at.hasKey("COLOR_0"): (col, colN) = g.accessor(at["COLOR_0"].getInt)
      var idx: seq[int]
      if pr.hasKey("indices"):
        for v in g.accessor(pr["indices"].getInt)[0]: idx.add v.int
      else:
        for i in 0 ..< nv: idx.add i
      for v in idx:
        if v < 0 or v >= nv: raise newException(ValueError, "a face index is out of range")
      var tris: seq[array[3, int]]
      case mode
      of 4:
        for t in 0 ..< idx.len div 3: tris.add [idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]
      of 5:
        for i in 0 .. idx.len - 3:
          tris.add(if i mod 2 == 0: [idx[i], idx[i + 1], idx[i + 2]] else: [idx[i + 1], idx[i], idx[i + 2]])
      else:
        for i in 1 .. idx.len - 2: tris.add [idx[0], idx[i], idx[i + 1]]
      let x = mm.uvXform
      for t in tris:
        var p = ModelPoly(mat: matIdx)
        let order = if flip: [t[0], t[2], t[1]] else: t
        for v in order:
          p.pos.add mat.point(vec3(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]))
          if uv.len >= (v + 1) * 2:
            let (u0, v0) = (uv[v * 2], uv[v * 2 + 1])
            p.uv.add vec2(x[0] * u0 + x[1] * v0 + x[2], x[3] * u0 + x[4] * v0 + x[5])
          else: p.uv.add vec2(0, 0)
          if nrm.len >= (v + 1) * 3:
            let n = mat.normalDir(vec3(nrm[v * 3], nrm[v * 3 + 1], nrm[v * 3 + 2]))
            if n.length > 1e-6: p.nrm.add n.normalize
          if colN >= 3:
            p.col.add [toSrgb(col[v * colN]), toSrgb(col[v * colN + 1]), toSrgb(col[v * colN + 2])]
        if p.nrm.len != p.pos.len: p.nrm.setLen 0
        m.polys.add p

  var depth = 0
  proc walk(m: var Model, ni: int, parent: M4) =
    inc depth
    if depth > 256: raise newException(ValueError, "its node tree loops")
    let n = g.j["nodes"][ni]
    let mat = parent * nodeMatrix(n)
    if n.hasKey("mesh"): m.prims(g.j["meshes"][n["mesh"].getInt], mat)
    for c in n{"children"}.getElems: m.walk(c.getInt, mat)
    dec depth

  var roots: seq[int]
  let scenes = g.j{"scenes"}.getElems
  if scenes.len > 0:
    let s = scenes[clamp(g.j{"scene"}.getInt, 0, scenes.high)]
    for n in s{"nodes"}.getElems: roots.add n.getInt
  else:
    var child: seq[bool] = newSeq[bool](g.j{"nodes"}.getElems.len)
    for n in g.j{"nodes"}.getElems:
      for c in n{"children"}.getElems: child[c.getInt] = true
    for i, c in child:
      if not c: roots.add i
  for r in roots: result.walk(r, M4Identity)
  if roots.len == 0:
    for mesh in g.j{"meshes"}.getElems: result.prims(mesh, M4Identity)

# --- Collada --------------------------------------------------------------------------------------

proc readColladaModel(path: string): Model =
  ## Through collada.readDae (world-space triangles per material), with the
  ## file's up axis and unit, and its materials' diffuse colors.
  let root = loadXml(path)
  var up = "Y_UP"
  result.unit = 1
  let asset = root.child("asset")
  if asset != nil:
    let u = asset.child("up_axis")
    if u != nil: up = u.innerText.strip.toUpperAscii
    let un = asset.child("unit")
    if un != nil and un.attr("meter").len > 0:
      try: result.unit = parseFloat(un.attr("meter")).float32
      except ValueError: discard
  # material id -> effect id -> its <diffuse><color>.
  var effectColor: Table[string, array[3, uint8]]
  for lib in root.findAll("library_effects"):
    for fx in lib.findAll("effect"):
      for d in fx.findAll("diffuse"):
        let c = d.child("color")
        if c != nil:
          let v = c.innerText.splitWhitespace
          if v.len >= 3:
            try: effectColor[fx.attr("id")] = [toByte(parseFloat(v[0]).float32), toByte(parseFloat(v[1]).float32),
                                               toByte(parseFloat(v[2]).float32)]
            except ValueError: discard
        break
  var matColor: Table[string, array[3, uint8]]
  for lib in root.findAll("library_materials"):
    for m in lib.findAll("material"):
      let ie = m.child("instance_effect")
      if ie != nil:
        let id = ie.attr("url").strip(chars = {'#'})
        if id in effectColor: matColor[m.attr("id")] = effectColor[id]
  proc axes(v: Vec3): Vec3 =
    case up
    of "Z_UP": vec3(v.x, v.z, -v.y)
    of "X_UP": vec3(-v.y, v.x, v.z)
    else: v
  let scene = readDae(path)
  for b in scene.batches:
    let mi = result.materials.len
    var mm = ModelMaterial(name: b.material, color: matColor.getOrDefault(b.material, White),
                           image: b.image, uvXform: IdentityUv)
    if b.image.len > 0:
      mm.imageName = b.image.extractFilename
      if not fileExists(b.image):
        let f = findFile(b.image.extractFilename, path.parentDir)
        mm.image = f
        if f.len == 0: mm.imageName = "?" & mm.imageName
    result.materials.add mm
    for t in 0 ..< b.verts.len div 3:
      var p = ModelPoly(mat: mi)
      var withNrm = true
      var anyColor = false
      for k in 0 .. 2:
        let v = b.verts[t * 3 + k]
        p.pos.add axes(v.pos)
        p.uv.add v.uv
        if v.nrm.length > 1e-6: p.nrm.add axes(v.nrm).normalize else: withNrm = false
        p.col.add [v.color[0], v.color[1], v.color[2]]
        if p.col[^1] != White: anyColor = true
      if not withNrm: p.nrm.setLen 0
      if not anyColor: p.col.setLen 0
      result.polys.add p

proc readModel*(path, work: string): Model =
  ## Any of ModelFormats; work holds the pictures a file embeds.
  case path.splitFile.ext.toLowerAscii
  of ".obj": readObj(path)
  of ".gltf", ".glb": readGltf(path, work)
  of ".dae": readColladaModel(path)
  else: raise newException(ValueError, "not a model Catwalk reads (" & ModelFormats.join(", ") & ")")

# --- faces ----------------------------------------------------------------------------------------

proc newell(ps: seq[Vec3]): Vec3 =
  for k in 0 ..< ps.len:
    let (a, b) = (ps[k], ps[(k + 1) mod ps.len])
    result += vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))

proc flatConvex(ps: seq[Vec3]): bool =
  ## Oni can take the polygon whole: flat, convex, no corner on top of another
  ## (geometry.faceProblems' tests, with a tighter flatness).
  let nl = newell(ps)
  if nl.length < 1e-3: return false
  let n = nl.normalize
  var c = vec3(0)
  for p in ps: c += p
  c /= ps.len.float32
  for p in ps:
    if abs(dot(p - c, n)) > PlanarTol: return false
  for k in 0 ..< ps.len:
    let ein = ps[k] - ps[(k + ps.len - 1) mod ps.len]
    let eout = ps[(k + 1) mod ps.len] - ps[k]
    if ein.length < 1e-3 or eout.length < 1e-3: return false
    if dot(cross(ein, eout), n) / (ein.length * eout.length) < -1e-3: return false
  true

proc goodTriangle(a, b, c: Vec3): bool =
  (b - a).length >= 1e-3 and (c - b).length >= 1e-3 and (a - c).length >= 1e-3 and
    cross(b - a, c - a).length >= 1e-3

proc triangulate(ps: seq[Vec3]): seq[array[3, int]] =
  ## Ear clipping in the polygon's plane (Newell normal); a quad is cut along
  ## its shorter diagonal. Falls back to a fan for polygons it can't clip.
  let n = ps.len
  if n == 3: return @[[0, 1, 2]]
  let nrm = newell(ps)
  if n == 4:
    # A split is good when both triangles face the quad's way (a dented
    # quad has only one); of two good ones, the shorter diagonal.
    proc faces(t: array[3, int]): bool = dot(cross(ps[t[1]] - ps[t[0]], ps[t[2]] - ps[t[0]]), nrm) > 0
    let a = @[[0, 1, 2], [0, 2, 3]]
    let b = @[[1, 2, 3], [1, 3, 0]]
    let aOk = faces(a[0]) and faces(a[1])
    let bOk = faces(b[0]) and faces(b[1])
    if aOk and (not bOk or (ps[2] - ps[0]).length <= (ps[3] - ps[1]).length): return a
    if bOk: return b
    return a
  var left = toSeq(0 ..< n)
  proc convexAt(a, b, c: int): bool = dot(cross(ps[b] - ps[a], ps[c] - ps[b]), nrm) > 0
  proc inside(p: Vec3, a, b, c: int): bool =
    let (x, y, z) = (ps[a], ps[b], ps[c])
    dot(cross(y - x, p - x), nrm) >= 0 and dot(cross(z - y, p - y), nrm) >= 0 and
      dot(cross(x - z, p - z), nrm) >= 0
  var guard = 0
  while left.len > 3 and guard < n * n:
    inc guard
    var clipped = false
    for i in 0 ..< left.len:
      let (a, b, c) = (left[(i + left.len - 1) mod left.len], left[i], left[(i + 1) mod left.len])
      if not convexAt(a, b, c): continue
      var ear = true
      for o in left:
        if o notin [a, b, c] and inside(ps[o], a, b, c):
          ear = false
          break
      if ear:
        result.add [a, b, c]
        left.delete(i)
        clipped = true
        break
    if not clipped: break
  if left.len == 3: result.add [left[0], left[1], left[2]]
  elif left.len > 3:
    for i in 1 ..< left.len - 1: result.add [left[0], left[i], left[i + 1]]

proc quadFan(n: int): seq[seq[int]] =
  ## A flat convex polygon of more than 4 corners as quads (and a triangle), as
  ## geometry.daePieces cuts them.
  var i = 1
  while i + 1 < n:
    result.add(if i + 2 < n: @[0, i, i + 1, i + 2] else: @[0, i, i + 1])
    i += result[^1].len - 2

const LightDir = vec3(0.35'f32, 1, 0.55)

proc shadeColor*(n: Vec3): uint8 =
  ## A corner's light until Bake light gives it the level's: from above and in
  ## front, so the model's shape shows (0.25..0.95 of full).
  let k = 0.6'f32 + 0.35'f32 * dot(n.normalize, LightDir.normalize)
  uint8(clamp(round(k * 255), 0, 255))

proc toFurniture*(m: Model, textureOf: seq[string], tintOf: seq[array[3, uint8]],
                  name, file: string): ImportedModel =
  ## The model's faces in object space: Oni units, its bottom center at the
  ## origin. textureOf/tintOf: per material (and one more at the end for -1).
  result = ImportedModel(name: name, file: file, geo: Geometry(pieces: @[Piece()]))
  let s = m.unit * OniUnitsPerMeter
  for p in m.polys:
    for q in p.pos:
      if not (abs(q.x) < Inf and abs(q.y) < Inf and abs(q.z) < Inf):   # NaN fails < too
        raise newException(ValueError, "a corner of the model isn't a number")
  if m.polys.len == 0: raise newException(ValueError, "it has no faces")
  var weld: Table[(int, int, int), int32]
  let g = result.geo
  proc pointAt(p: Vec3): int32 =
    let key = (int(round(p.x / WeldTol)), int(round(p.y / WeldTol)), int(round(p.z / WeldTol)))
    if key notin weld:
      weld[key] = g.points.len.int32
      g.points.add p
    weld[key]
  var used: seq[string]
  for p in m.polys:
    inc result.polygons
    # Corners in world units, the same corner twice in a row dropped.
    var ks: seq[int]
    var ps: seq[Vec3]
    for k, q in p.pos:
      let w = q * s
      if ps.len > 0 and (w - ps[^1]).length < 1e-3: continue
      ks.add k
      ps.add w
    while ps.len > 1 and (ps[0] - ps[^1]).length < 1e-3:
      ps.setLen ps.len - 1
      ks.setLen ks.len - 1
    if ps.len < 3 or newell(ps).length < 1e-3:
      inc result.dropped
      continue
    var pieces: seq[seq[int]]
    if flatConvex(ps):
      pieces = if ps.len <= 4: @[toSeq(0 ..< ps.len)] else: quadFan(ps.len)
    else:
      inc result.cut
      for t in triangulate(ps): pieces.add @[t[0], t[1], t[2]]
    let faceN = newell(ps).normalize
    let mi = if p.mat >= 0 and p.mat < textureOf.len - 1: p.mat else: textureOf.high
    var made = 0
    for piece in pieces:
      let cs = piece.mapIt(ps[it])
      if cs.len == 3 and not goodTriangle(cs[0], cs[1], cs[2]): continue
      if cs.len > 3 and newell(cs).length < 1e-3: continue
      var f = Face(texture: textureOf[mi], flags: FurnitureFlags, objectId: -1, piece: 0)
      f.tint = tintOf[mi]
      for c in piece:
        let k = ks[c]
        f.verts.add pointAt(ps[c])
        f.uvs.add(if k < p.uv.len: p.uv[k] else: vec2(0, 0))
        let n = if p.nrm.len == p.pos.len: p.nrm[k] else: faceN
        let sh = shadeColor(n)
        var col = [sh, sh, sh, 255'u8]
        if p.col.len == p.pos.len:
          for ch in 0 .. 2: col[ch] = uint8((sh.int * p.col[k][ch].int + 127) div 255)
        f.colors.add col
      g.faces.add f
      inc made
      if f.texture notin used: used.add f.texture
    if made == 0: inc result.dropped
    result.faces += made
  if g.faces.len == 0: raise newException(ValueError, "none of its faces has any area")
  result.textures = used
  # The bottom center of what was kept becomes the origin.
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  for q in g.points:
    lo = min(lo, q)
    hi = max(hi, q)
  let origin = vec3((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
  for q in g.points.mitems: q -= origin
  result.size = hi - lo

# --- the job --------------------------------------------------------------------------------------

proc furnitureXml*(cls: string): string =
  ## The FURN object a model becomes (Gunk, as the game's furniture).
  "<FURN Id=\"0\"><Header><Flags>Gunk</Flags><Position>0 0 0</Position>" &
    "<Rotation>0 0 0</Rotation></Header><OSD><Class>" & cls & "</Class><Particle></Particle></OSD></FURN>"

proc className*(file: string): string =
  ## The furniture's class: the file's name, as an instance name (at most 31).
  for ch in file.splitFile.name:
    result.add(if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: ch else: '_')
  if result.len == 0: result = "model"
  if result.len > 31: result.setLen 31

proc fitted(img: TgaImage): TgaImage =
  let (w, h) = fittedSize(img.width, img.height, ModelTextureSide)
  img.resized(w, h)

proc saveTexture(p: Project, base: string, img: TgaImage, work: string, made: var seq[string]): string =
  ## img as a texture of the project named base (or base_2, ...), unless an
  ## identical one is there already: then that one's name.
  let tmp = work / "texture.tga"
  writeTga(tmp, img)
  let bytes = readFile(tmp)
  var name = base
  var n = 2
  while fileExists(p.imagesDir / name & ".tga"):
    if readFile(p.imagesDir / name & ".tga") == bytes: return name
    name = base & "_" & $n
    inc n
  createDir(p.imagesDir)
  writeFile(p.imagesDir / name & ".tga", bytes)
  made.add name
  name

proc importModelsJob*(c: Config, p: Project, files: seq[string],
                      onDone: proc(models: seq[ImportedModel])): Job =
  ## Reads the model files and makes their furniture: textures go into
  ## env/images (CW_<picture name>, at most ModelTextureSide), and onDone
  ## gets the geometry to place.
  let work = p.buildDir / "import" / "models"
  type Picture = object
    file, name: string
    viaOniSplit: bool
    dir: string
    texture: string      ## "" = it couldn't be read.
  type State = object
    models: seq[Model]
    pictures: seq[Picture]
    pictureOf: Table[string, int]
    made: seq[string]
    results: seq[ImportedModel]
    warnings: seq[seq[string]]
  let st = new State
  var steps = @[
    action("Reading models", proc() =
      if dirExists(work): removeDir(work)
      createDir(work)
      for i, f in files:
        var m: Model
        try: m = readModel(f, work / $i)
        except CatchableError as e:
          raise newException(ValueError, f.extractFilename & ": " & e.msg)
        var warn: seq[string]
        for mm in m.materials:
          if mm.imageName.startsWith("?"):
            warn.add "its texture " & mm.imageName[1 .. ^1] & " is missing"
          elif mm.image.len > 0 and mm.image notin st.pictureOf:
            let ext = mm.image.splitFile.ext.toLowerAscii
            st.pictureOf[mm.image] = st.pictures.len
            st.pictures.add Picture(file: mm.image, name: mm.imageName,
                                    viaOniSplit: ext.len > 1 and ext[1 .. ^1] in OniSplitFormats,
                                    dir: work / "picture" & $st.pictures.len)
        st.models.add m
        st.warnings.add warn),
    # Pictures Catwalk doesn't decode itself (dds, tif) go through OniSplit.
    commandEach("Reading textures", proc(): seq[seq[string]] =
      for pic in st.pictures:
        if pic.viaOniSplit:
          createDir(pic.dir / "txmp")
          result.add c.splitArgs("-create:txmp", pic.dir / "txmp", "-large", pic.file)),
    commandEach("Converting textures", proc(): seq[seq[string]] =
      for pic in st.pictures:
        if pic.viaOniSplit:
          let txmp = globOni(pic.dir / "txmp", "TXMP")
          if txmp.len > 0: result.add c.oniSplitCmd & @["-extract:tga", pic.dir / "tga"] & txmp),
    action("Making textures", proc() =
      for pic in st.pictures.mitems:
        var src = pic.file
        if pic.viaOniSplit:
          src = ""
          for f in walkFiles(pic.dir / "tga" / "*.tga"):
            src = f
            break
        if src.len == 0: continue
        try:
          let img = readPicture(src)
          if img.width < 1 or img.height < 1: continue
          pic.texture = saveTexture(p, "CW_" & safeName(pic.name), img.fitted, work, st.made)
        except CatchableError: discard),
    action("Making furniture", proc() =
      var white = false
      for i, m in st.models:
        var tex: seq[string]
        var tint: seq[array[3, uint8]]
        for mm in m.materials:
          let pic = if mm.image.len > 0: st.pictures[st.pictureOf[mm.image]] else: Picture()
          if pic.texture.len > 0:
            tex.add pic.texture
            tint.add mm.color
          else:
            if mm.image.len > 0:
              st.warnings[i].add "its texture " & pic.name & " couldn't be read"
            tex.add WhiteTexture
            tint.add mm.color
            white = true
        # Faces with no material: white.
        tex.add WhiteTexture
        tint.add White
        var r = toFurniture(m, tex, tint, className(files[i]), files[i])
        if WhiteTexture in r.textures: white = true
        r.warnings = st.warnings[i]
        st.results.add r
      if white:
        var img = TgaImage(width: 16, height: 16, rgba: newSeq[uint8](16 * 16 * 4))
        for b in img.rgba.mitems: b = 255
        discard saveTexture(p, WhiteTexture, img, work, st.made)
      removeDir(work)),
    action("Done", proc() =
      for t in st.made:
        if t notin p.customTextures: p.customTextures.add t
      p.save()
      onDone(st.results))]
  newJob(if files.len == 1: "Importing " & files[0].extractFilename else: "Importing models", p.logPath, steps)
