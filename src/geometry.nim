## The level's environment geometry as Catwalk edits it: shared points and
## polygons (faces) carrying their own UVs, baked vertex colors, texture, Oni
## gunk flags and script id. Faces are grouped into pieces, the units you
## select, move and reshape; pieces made with the brush tools are convex solids.
##
## Imported from OniSplit's XML dump of the AKEV instance (which keeps every
## per-quad flag), and written back as .dae files plus a level XML that tells
## OniSplit each group's flags and script id.

import std/[parsexml, streams, strutils, tables, os, algorithm, sets, json, math, strformat]
import vmath

type
  Face* = object
    verts*: seq[int32]               ## Indices into Geometry.points, in order.
    uvs*: seq[Vec2]
    colors*: seq[array[4, uint8]]
    texture*: string                 ## Name without the TXMP prefix, e.g. WH_INTWALL.
    flags*: uint32                   ## Gunk flags (authorable ones; see AuthorFlags).
    scriptId*: int32                 ## 0 = none. Used by env_show and friends.
    objectId*: int32                 ## -1, or object type << 24 | object id: geometry
                                     ## owned by a furniture/door/console/... object.
    piece*: int32

  Piece* = object
    brush*: bool                     ## A convex solid made with Catwalk's tools.
    hidden*: bool

  Geometry* = ref object
    points*: seq[Vec3]
    faces*: seq[Face]
    pieces*: seq[Piece]
    version*: int                    ## Bumped on every change (render cache key).

const
  gfDoorFrame* = 0x01'u32
  gfGhost* = 0x02'u32
  gfStairsUp* = 0x04'u32
  gfStairsDown* = 0x08'u32
  gfStairs* = 0x10'u32
  gfTriangle* = 0x40'u32
  gfTransparent* = 0x80'u32
  gfTwoSided* = 0x200'u32
  gfNoCollision* = 0x800'u32
  gfInvisible* = 0x2000'u32
  gfNoObjectCollision* = 0x4000'u32
  gfNoCharacterCollision* = 0x8000'u32
  gfNoOcclusion* = 0x10000'u32
  gfDanger* = 0x20000'u32
  gfHorizontal* = 0x80000'u32
  gfVertical* = 0x100000'u32
  gfGridIgnore* = 0x400000'u32
  gfNoDecals* = 0x800000'u32
  gfFurniture* = 0x1000000'u32
  gfProjection0* = 0x2000000'u32
  gfProjection1* = 0x4000000'u32
  gfSoundTransparent* = 0x8000000'u32
  gfImpassable* = 0x10000000'u32

  FlagNames* = [
    ("DoorFrame", gfDoorFrame), ("Ghost", gfGhost), ("StairsUp", gfStairsUp),
    ("StairsDown", gfStairsDown), ("Stairs", gfStairs), ("Triangle", gfTriangle),
    ("Transparent", gfTransparent), ("TwoSided", gfTwoSided), ("NoCollision", gfNoCollision),
    ("Invisible", gfInvisible), ("NoObjectCollision", gfNoObjectCollision),
    ("NoCharacterCollision", gfNoCharacterCollision), ("NoOcclusion", gfNoOcclusion),
    ("Danger", gfDanger), ("Horizontal", gfHorizontal), ("Vertical", gfVertical),
    ("GridIgnore", gfGridIgnore), ("NoDecals", gfNoDecals), ("Furniture", gfFurniture),
    ("ProjectionBit0", gfProjection0), ("ProjectionBit1", gfProjection1),
    ("SoundTransparent", gfSoundTransparent), ("Impassable", gfImpassable)]

  ## Flags OniSplit computes itself; never stored or written.
  DerivedFlags* = gfTriangle or gfHorizontal or gfVertical or gfProjection0 or gfProjection1

  ## Flags shown as checkboxes in the Face inspector, with their tooltips.
  EditableFlags* = [
    ("Transparent", gfTransparent,
     "Drawn alpha-blended after the opaque geometry. Use for glass, grates and other textures with alpha."),
    ("Two-sided", gfTwoSided,
     "Rendered from both sides instead of only the front."),
    ("No collision", gfNoCollision,
     "Nothing collides with it: characters, objects, projectiles and particles pass through."),
    ("Invisible", gfInvisible,
     "Not rendered, but still collides (unless a no-collision flag is set). Use for invisible walls."),
    ("No object collision", gfNoObjectCollision,
     "Objects, weapons, projectiles and particles pass through; characters still collide."),
    ("No character collision", gfNoCharacterCollision,
     "Characters walk through it; objects, weapons and projectiles still collide."),
    ("No occlusion", gfNoOcclusion,
     "Doesn't block sight: AI can see through it and it doesn't hide geometry behind it."),
    ("Stairs", gfStairs,
     "Stair ramp characters walk on. Usually an invisible slope over the visible steps."),
    ("Danger", gfDanger,
     "Marks a hazard (pits, fire, lasers). AI pathfinding avoids the area."),
    ("Impassable", gfImpassable,
     "AI pathfinding treats it as blocked and never paths through it."),
    ("Furniture", gfFurniture,
     "Furniture (desks, crates, consoles). AI treats it as an obstacle to walk around."),
    ("No decals", gfNoDecals,
     "Bullet holes, scorch marks and other decals don't stick to it."),
    ("Sound transparent", gfSoundTransparent,
     "Doesn't block sound, so AI hears noises through it."),
    ("Grid ignore", gfGridIgnore,
     "Left out of the AI pathfinding grid, as if it weren't there."),
    ("Ghost (room link)", gfGhost,
     "Invisible portal joining two rooms (BNVs) so AI pathfinding can pass between them."),
    ("Door frame", gfDoorFrame,
     "Room link in a doorway: AI pathfinding passes between the two rooms through the door.")]

proc parseFlags*(s: string): uint32 =
  for tok in s.splitWhitespace:
    var found = false
    for (n, v) in FlagNames:
      if n == tok:
        result = result or v
        found = true
        break
    if not found:
      try: result = result or uint32(parseInt(tok))
      except ValueError: discard

proc flagsText*(f: uint32): string =
  var rest = f
  for (n, v) in FlagNames:
    if (f and v) != 0:
      if result.len > 0: result.add ' '
      result.add n
      rest = rest and not v
  if rest != 0:
    if result.len > 0: result.add ' '
    result.add $rest

# --- queries ------------------------------------------------------------------------------

proc bump*(g: Geometry) = inc g.version

proc center*(g: Geometry, f: Face): Vec3 =
  for v in f.verts: result += g.points[v]
  if f.verts.len > 0: result /= f.verts.len.float32

proc normal*(g: Geometry, f: Face): Vec3 =
  ## Newell's method; robust for slightly non-planar quads.
  var n = vec3(0, 0, 0)
  for i in 0 ..< f.verts.len:
    let a = g.points[f.verts[i]]
    let b = g.points[f.verts[(i + 1) mod f.verts.len]]
    n.x += (a.y - b.y) * (a.z + b.z)
    n.y += (a.z - b.z) * (a.x + b.x)
    n.z += (a.x - b.x) * (a.y + b.y)
  if n.length > 1e-9: n.normalize else: vec3(0, 1, 0)

proc pieceFaces*(g: Geometry): seq[seq[int]] =
  result = newSeq[seq[int]](g.pieces.len)
  for i, f in g.faces:
    if f.piece >= 0 and f.piece < g.pieces.len: result[f.piece].add i

proc textureNames*(g: Geometry): seq[string] =
  var seen: HashSet[string]
  for f in g.faces:
    if f.texture notin seen:
      seen.incl f.texture
      result.add f.texture
  result.sort

proc separateObjectPoints*(g: Geometry) =
  ## Gives each object's faces their own points, so moving an object (and its
  ## geometry) never drags a corner of the level or of another object.
  var owner = newSeq[int32](g.points.len)
  for i in 0 ..< owner.len: owner[i] = int32.low
  var copies: Table[(int32, int32), int32]
  for f in g.faces.mitems:
    for v in f.verts.mitems:
      if owner[v] == int32.low: owner[v] = f.objectId
      elif owner[v] != f.objectId:
        let key = (v, f.objectId)
        if key notin copies:
          copies[key] = g.points.len.int32
          g.points.add g.points[v]
          owner.add f.objectId
        v = copies[key]
  g.bump()

proc bounds*(g: Geometry): (Vec3, Vec3) =
  ## Box around the points faces use. Unused points don't count: AKEV's point
  ## list has one at -2^21 on every axis. Empty geometry gives lo > hi.
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  for f in g.faces:
    for v in f.verts:
      lo = min(lo, g.points[v])
      hi = max(hi, g.points[v])
  (lo, hi)

proc compact*(g: Geometry) =
  ## Drops faces without corners, unused points and empty pieces.
  var keep: seq[Face]
  for f in g.faces:
    if f.verts.len >= 3: keep.add f
  g.faces = keep
  var used = newSeq[bool](g.points.len)
  for f in g.faces:
    for v in f.verts: used[v] = true
  var remap = newSeq[int32](g.points.len)
  var pts: seq[Vec3]
  for i, p in g.points:
    if used[i]:
      remap[i] = pts.len.int32
      pts.add p
  g.points = pts
  for f in g.faces.mitems:
    for v in f.verts.mitems: v = remap[v]
  var pieceUsed = newSeq[bool](g.pieces.len)
  for f in g.faces:
    if f.piece >= 0 and f.piece < g.pieces.len: pieceUsed[f.piece] = true
  var premap = newSeq[int32](g.pieces.len)
  var pcs: seq[Piece]
  for i, p in g.pieces:
    if pieceUsed[i]:
      premap[i] = pcs.len.int32
      pcs.add p
  g.pieces = pcs
  for f in g.faces.mitems: f.piece = premap[f.piece]
  g.bump()

proc weld*(g: Geometry, eps = 0.01'f32) =
  ## Merges points closer than eps (after moves that make corners meet).
  var grid: Table[(int, int, int), seq[int32]]
  var remap = newSeq[int32](g.points.len)
  var pts: seq[Vec3]
  for i, p in g.points:
    let key = (int(floor(p.x / eps)), int(floor(p.y / eps)), int(floor(p.z / eps)))
    var found = -1'i32
    for dx in -1 .. 1:
      for dy in -1 .. 1:
        for dz in -1 .. 1:
          let k = (key[0] + dx, key[1] + dy, key[2] + dz)
          if k in grid:
            for j in grid[k]:
              if (pts[j] - p).length <= eps:
                found = j
                break
          if found >= 0: break
        if found >= 0: break
      if found >= 0: break
    if found < 0:
      found = pts.len.int32
      pts.add p
      grid.mgetOrPut(key, @[]).add found
    remap[i] = found
  g.points = pts
  for f in g.faces.mitems:
    for v in f.verts.mitems: v = remap[v]
    # Drop corners that collapsed onto their neighbour.
    var i = 0
    while i < f.verts.len and f.verts.len > 0:
      let j = (i + 1) mod f.verts.len
      if f.verts.len > 1 and f.verts[i] == f.verts[j]:
        f.verts.delete(j)
        f.uvs.delete(j)
        f.colors.delete(j)
      else: inc i
  g.compact()

# --- import from OniSplit's AKEV XML ---------------------------------------------------------------

proc importAkevXml*(path: string): Geometry =
  ## Reads the AKEV XML that `OniSplit -extract:xml` writes. Faces are grouped
  ## into pieces: faces sharing an edge with the same texture, flags and script id.
  result = Geometry()
  var s = newFileStream(path, fmRead)
  if s == nil: raise newException(IOError, "cannot read " & path)
  defer: s.close()
  var x: XmlParser
  x.open(s, path)
  defer: x.close()

  var
    texcoords: seq[Vec2]
    quadTex: seq[int]
    textures: seq[string]
    top = ""            # current child of <Oni>
    stack: seq[string]
    text = ""
    q: Face
    qTex: seq[int32]
    inQuad = false
    depth = 0
    topId = ""
    quadGroupListId, quadGroupIdId = ""
    idxa: Table[string, seq[int]]

  proc vec(t: string): seq[float32] =
    for tok in t.splitWhitespace: result.add parseFloat(tok).float32

  while true:
    x.next()
    case x.kind
    of xmlElementStart, xmlElementOpen:
      let tag = x.elementName
      stack.add tag
      inc depth
      if depth == 2:
        top = tag
        topId = ""
      if tag == "AGQGQuad":
        inQuad = true
        q = Face(scriptId: 0, objectId: -1)
        qTex.setLen 0
      text.setLen 0
    of xmlAttribute:
      if depth == 2 and x.attrKey == "id": topId = x.attrValue
    of xmlElementClose: discard
    of xmlCharData, xmlWhitespace, xmlCData:
      text.add x.charData
    of xmlElementEnd:
      let tag = if stack.len > 0: stack.pop else: ""
      let parent = if stack.len > 0: stack[^1] else: ""
      case top
      of "PNTA":
        if tag == "Vector3":
          let v = vec(text)
          if v.len == 3: result.points.add vec3(v[0], v[1], v[2])
      of "TXCA":
        if tag == "Vector2":
          let v = vec(text)
          if v.len == 2: texcoords.add vec2(v[0], v[1])
      of "AGQG":
        if inQuad:
          case tag
          of "Int32":
            let n = parseInt(text.strip).int32
            if parent == "Points": q.verts.add n
            elif parent == "TextureCoordinates": qTex.add n
          of "Color":
            let v = vec(text)
            if v.len >= 3:
              q.colors.add [uint8(clamp(v[0], 0, 255)), uint8(clamp(v[1], 0, 255)),
                            uint8(clamp(v[2], 0, 255)), 255'u8]
          of "Flags": q.flags = parseFlags(text)
          of "ObjectId": q.objectId = parseInt(text.strip).int32
          of "AGQGQuad":
            inQuad = false
            for t in qTex:
              q.uvs.add (if t >= 0 and t < texcoords.len: texcoords[t] else: vec2(0, 0))
            while q.colors.len < q.verts.len: q.colors.add [255'u8, 255, 255, 255]
            if (q.flags and gfTriangle) != 0 and q.verts.len == 4:
              q.verts.setLen 3
              q.uvs.setLen 3
              q.colors.setLen 3
            q.flags = q.flags and not DerivedFlags
            result.faces.add q
          else: discard
      of "AKEV":
        if tag == "QuadGroupList": quadGroupListId = text.strip.strip(chars = {'#'})
        elif tag == "QuadGroupId": quadGroupIdId = text.strip.strip(chars = {'#'})
      of "IDXA":
        if tag == "Int32": idxa.mgetOrPut(topId, @[]).add parseInt(text.strip)
      of "AGQR":
        if tag == "Texture": quadTex.add parseInt(text.strip)
      of "TXMA":
        if tag == "Link":
          var n = text.strip
          if n.startsWith("TXMP"): n = n[4 .. ^1]
          textures.add n
      else: discard
      dec depth
      text.setLen 0
    of xmlEof: break
    of xmlError:
      raise newException(ValueError, path & ": " & x.errorMsg)
    else: discard

  for i, f in result.faces.mpairs:
    let t = if i < quadTex.len: quadTex[i] else: -1
    f.texture = if t >= 0 and t < textures.len: textures[t] else: "NONE"
  # Script ids: two parallel index arrays (quad index, script id).
  let qs = idxa.getOrDefault(quadGroupListId)
  let ids = idxa.getOrDefault(quadGroupIdId)
  for k in 0 ..< min(qs.len, ids.len):
    if qs[k] >= 0 and qs[k] < result.faces.len: result.faces[qs[k]].scriptId = ids[k].int32

  # Pieces: edge-connected faces with the same texture, flags and script id.
  var parent = newSeq[int](result.faces.len)
  for i in 0 ..< parent.len: parent[i] = i
  proc find(i: int): int =
    var r = i
    while parent[r] != r: r = parent[r]
    var j = i
    while parent[j] != r:
      let n = parent[j]
      parent[j] = r
      j = n
    r
  var edgeOwner: Table[(int32, int32), int]
  for i, f in result.faces:
    for k in 0 ..< f.verts.len:
      let a = f.verts[k]
      let b = f.verts[(k + 1) mod f.verts.len]
      let key = (min(a, b), max(a, b))
      if key in edgeOwner:
        let j = edgeOwner[key]
        let o = result.faces[j]
        if o.texture == f.texture and o.flags == f.flags and o.scriptId == f.scriptId and
           o.objectId == f.objectId:
          let (ri, rj) = (find(i), find(j))
          if ri != rj: parent[ri] = rj
      else:
        edgeOwner[key] = i
  var pieceOf: Table[int, int32]
  for i in 0 ..< result.faces.len:
    let r = find(i)
    if r notin pieceOf:
      pieceOf[r] = result.pieces.len.int32
      result.pieces.add Piece()
    result.faces[i].piece = pieceOf[r]

# --- persistence ------------------------------------------------------------------------------

proc save*(g: Geometry, path: string) =
  ## Compact JSON: flat arrays, one texture table.
  var texIndex: Table[string, int]
  var texNames = newJArray()
  var pts = newJArray()
  for p in g.points:
    pts.add %p.x; pts.add %p.y; pts.add %p.z
  var faces = newJArray()
  for f in g.faces:
    if f.texture notin texIndex:
      texIndex[f.texture] = texIndex.len
      texNames.add %f.texture
    var vs = newJArray()
    var uv = newJArray()
    var col = newJArray()
    for i, v in f.verts:
      vs.add %v
      uv.add %f.uvs[i].x; uv.add %f.uvs[i].y
      let c = f.colors[i]
      col.add %((c[0].int shl 16) or (c[1].int shl 8) or c[2].int)
    faces.add %*{"v": vs, "uv": uv, "c": col, "t": texIndex[f.texture], "f": f.flags.int,
                 "s": f.scriptId, "o": f.objectId, "p": f.piece}
  var pcs = newJArray()
  for p in g.pieces: pcs.add %*{"b": p.brush}
  let j = %*{"version": 1, "points": pts, "textures": texNames, "faces": faces, "pieces": pcs}
  let tmp = path & ".tmp"
  writeFile(tmp, $j)
  moveFile(tmp, path)

proc loadGeometry*(path: string): Geometry =
  let j = parseFile(path)
  result = Geometry()
  let pts = j["points"].getElems
  var i = 0
  while i + 2 < pts.len:
    result.points.add vec3(pts[i].getFloat, pts[i + 1].getFloat, pts[i + 2].getFloat)
    i += 3
  var texNames: seq[string]
  for t in j["textures"].getElems: texNames.add t.getStr
  for fj in j["faces"].getElems:
    var f = Face(texture: texNames[fj["t"].getInt], flags: uint32(fj["f"].getInt),
                 scriptId: fj["s"].getInt.int32, objectId: fj{"o"}.getInt(-1).int32,
                 piece: fj["p"].getInt.int32)
    for v in fj["v"].getElems: f.verts.add v.getInt.int32
    let uv = fj["uv"].getElems
    var k = 0
    while k + 1 < uv.len:
      f.uvs.add vec2(uv[k].getFloat, uv[k + 1].getFloat)
      k += 2
    for c in fj["c"].getElems:
      let n = c.getInt
      f.colors.add [uint8((n shr 16) and 255), uint8((n shr 8) and 255), uint8(n and 255), 255'u8]
    result.faces.add f
  for pj in j["pieces"].getElems:
    result.pieces.add Piece(brush: pj{"b"}.getBool)

proc clone*(g: Geometry): Geometry =
  Geometry(points: g.points, faces: g.faces, pieces: g.pieces, version: g.version)

# --- export for OniSplit -create:level ----------------------------------------------------------

proc markerMaterial*(f: Face): string =
  ## OniSplit recognises ghosts and door frames by these material names.
  if (f.flags and gfGhost) != 0: "_marker_ghost"
  elif (f.flags and gfDoorFrame) != 0: "_marker_door"
  else: ""

proc xmlEsc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc writeDae(path: string, g: Geometry, faces: seq[int], imageDir, markerDir: string) =
  ## One geometry node; one polylist per material.
  var byMat: OrderedTable[string, seq[int]]
  for fi in faces:
    let f = g.faces[fi]
    let m = block:
      let mk = markerMaterial(f)
      if mk.len > 0: mk else: f.texture
    byMat.mgetOrPut(m, @[]).add fi
  var pointIndex: Table[int32, int]
  var pos, uvs, cols: seq[string]
  for fi in faces:
    for v in g.faces[fi].verts:
      if v notin pointIndex:
        pointIndex[v] = pointIndex.len
        let p = g.points[v]
        pos.add &"{p.x:.4f} {p.y:.4f} {p.z:.4f}"
  var o = newStringOfCap(1 shl 16)
  o.add "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
  o.add "<COLLADA version=\"1.4.0\" xmlns=\"http://www.collada.org/2005/11/COLLADASchema\">\n"
  o.add "<asset><unit meter=\"0.1\" name=\"decimeter\"/><up_axis>Y_UP</up_axis></asset>\n"
  o.add "<library_images>\n"
  for m in byMat.keys:
    let img = if m.startsWith("_marker_"): markerDir / m & ".tga" else: imageDir / m & ".tga"
    o.add &"<image id=\"{xmlEsc(m)}_img\"><init_from>{xmlEsc(img)}</init_from></image>\n"
  o.add "</library_images>\n<library_effects>\n"
  for m in byMat.keys:
    let e = xmlEsc(m)
    o.add &"<effect id=\"{e}_fx\"><profile_COMMON><newparam sid=\"surface\"><surface type=\"2D\"><init_from>{e}_img</init_from></surface></newparam>" &
      "<newparam sid=\"sampler\"><sampler2D><source>surface</source></sampler2D></newparam>" &
      "<technique sid=\"common\"><phong><ambient><color sid=\"ambient\">1 1 1 1</color></ambient>" &
      "<diffuse><texture texture=\"sampler\" texcoord=\"uv\"/></diffuse>" &
      "<specular><color sid=\"specular\">0 0 0 0</color></specular></phong></technique></profile_COMMON></effect>\n"
  o.add "</library_effects>\n<library_materials>\n"
  for m in byMat.keys:
    let e = xmlEsc(m)
    o.add &"<material id=\"{e}\" name=\"{e}\"><instance_effect url=\"#{e}_fx\"/></material>\n"
  o.add "</library_materials>\n<library_geometries>\n<geometry id=\"geo\"><mesh>\n"
  o.add &"<source id=\"pos\"><float_array id=\"pos_a\" count=\"{pos.len * 3}\">{pos.join(\" \")}</float_array>" &
    &"<technique_common><accessor source=\"#pos_a\" count=\"{pos.len}\" stride=\"3\"><param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>\n"
  var corner = 0
  var polys = ""
  for m, fis in byMat:
    var vcount, p: seq[string]
    for fi in fis:
      let f = g.faces[fi]
      vcount.add $f.verts.len
      for k, v in f.verts:
        let uv = f.uvs[k]
        uvs.add &"{uv.x:.6f} {1 - uv.y:.6f}"   # OniSplit flips V when reading .dae
        let c = f.colors[k]
        cols.add &"{c[0].float / 255:.4f} {c[1].float / 255:.4f} {c[2].float / 255:.4f} 1"
        p.add &"{pointIndex[v]} {corner} {corner}"
        inc corner
    polys.add &"<polylist count=\"{vcount.len}\" material=\"{xmlEsc(m)}\">" &
      "<input semantic=\"VERTEX\" source=\"#vtx\" offset=\"0\"/>" &
      "<input semantic=\"TEXCOORD\" source=\"#uv\" offset=\"1\" set=\"0\"/>" &
      "<input semantic=\"COLOR\" source=\"#col\" offset=\"2\"/>" &
      &"<vcount>{vcount.join(\" \")}</vcount><p>{p.join(\" \")}</p></polylist>\n"
  o.add &"<source id=\"uv\"><float_array id=\"uv_a\" count=\"{uvs.len * 2}\">{uvs.join(\" \")}</float_array>" &
    &"<technique_common><accessor source=\"#uv_a\" count=\"{uvs.len}\" stride=\"2\"><param name=\"S\" type=\"float\"/><param name=\"T\" type=\"float\"/></accessor></technique_common></source>\n"
  o.add &"<source id=\"col\"><float_array id=\"col_a\" count=\"{cols.len * 4}\">{cols.join(\" \")}</float_array>" &
    &"<technique_common><accessor source=\"#col_a\" count=\"{cols.len}\" stride=\"4\"><param name=\"R\" type=\"float\"/><param name=\"G\" type=\"float\"/><param name=\"B\" type=\"float\"/><param name=\"A\" type=\"float\"/></accessor></technique_common></source>\n"
  o.add "<vertices id=\"vtx\"><input semantic=\"POSITION\" source=\"#pos\"/></vertices>\n"
  o.add polys
  o.add "</mesh></geometry>\n</library_geometries>\n"
  o.add "<library_visual_scenes><visual_scene id=\"scene\"><node id=\"n\" name=\"n\"><instance_geometry url=\"#geo\"><bind_material><technique_common>\n"
  for m in byMat.keys:
    let e = xmlEsc(m)
    o.add &"<instance_material symbol=\"{e}\" target=\"#{e}\"><bind_vertex_input semantic=\"uv\" input_semantic=\"TEXCOORD\" input_set=\"0\"/></instance_material>\n"
  o.add "</technique_common></bind_material></instance_geometry></node></visual_scene></library_visual_scenes>\n"
  o.add "<scene><instance_visual_scene url=\"#scene\"/></scene>\n</COLLADA>\n"
  writeFile(path, o)

proc writeLevelSource*(g: Geometry, dir, envName, sky, imageDir, markerDir: string,
                       roomDaes: seq[string]): string =
  ## Writes the geometry as .dae files (one per flags/script group) and the
  ## level XML OniSplit -create:level reads. Returns the XML path.
  createDir(dir)
  var groups: OrderedTable[(uint32, int32), seq[int]]
  for i, f in g.faces:
    if f.verts.len < 3: continue
    groups.mgetOrPut((f.flags and not DerivedFlags, f.scriptId), @[]).add i
  var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Oni>\n"
  x.add &"  <Level Name=\"{xmlEsc(envName)}\" SharedPath=\"{xmlEsc(dir / \"shared\")}\">\n"
  x.add "    <Environment>\n      <Model>\n"
  var n = 0
  for key, faces in groups:
    let file = &"g{n:04}.dae"
    inc n
    writeDae(dir / file, g, faces, imageDir, markerDir)
    let (flags, script) = key
    # Properties apply per node (the .dae's single node is "n").
    x.add &"        <Import Path=\"{file}\">\n          <Node Id=\"n\">\n"
    let ft = flagsText(flags)
    if ft.len > 0: x.add &"            <GunkFlags>{ft}</GunkFlags>\n"
    if script != 0: x.add &"            <ScriptId>{script}</ScriptId>\n"
    x.add "          </Node>\n        </Import>\n"
  x.add "      </Model>\n      <Rooms>\n"
  for r in roomDaes: x.add &"        <Import Path=\"{xmlEsc(r)}\" />\n"
  # OniSplit always writes an ONSK link and throws on an empty name. Levels
  # without a sky (level 6) get a placeholder; only the AKEV output is used.
  let skyName = if sky.len > 0: sky else: "none"
  x.add &"      </Rooms>\n    </Environment>\n    <Sky>{xmlEsc(skyName)}</Sky>\n    <Objects></Objects>\n  </Level>\n</Oni>\n"
  result = dir / envName & ".xml"
  createDir(dir / "shared")
  writeFile(result, x)

proc writeRoomsDae*(g: Geometry, path: string): int =
  ## AI rooms (BNVs) for a level made in Catwalk: one room per walkable floor
  ## face. OniSplit reads a room as its floor polygon (normal up) and builds
  ## the pathfinding grid over it; vertical quads would be ghosts (room links).
  ## Returns the number of rooms.
  const NotFloor = gfGhost or gfDoorFrame or gfNoCollision or gfNoCharacterCollision
  var pos: seq[string]
  var polys = ""
  var n = 0
  for f in g.faces:
    if f.verts.len < 3 or (f.flags and NotFloor) != 0 or g.normal(f).y < 0.7: continue
    let (lo, hi) = block:
      var lo = vec3(Inf.float32)
      var hi = vec3(-Inf.float32)
      for v in f.verts:
        lo = min(lo, g.points[v])
        hi = max(hi, g.points[v])
      (lo, hi)
    if hi.x - lo.x < 8 or hi.z - lo.z < 8: continue   # stair treads, trims
    var idx: seq[string]
    for v in f.verts:
      let p = g.points[v]
      idx.add $pos.len
      pos.add &"{p.x:.4f} {p.y:.4f} {p.z:.4f}"
    polys.add &"<polylist count=\"1\"><input semantic=\"VERTEX\" source=\"#vtx\" offset=\"0\"/>" &
      &"<vcount>{f.verts.len}</vcount><p>{idx.join(\" \")}</p></polylist>\n"
    inc n
  if n == 0:
    # OniSplit needs at least one room; a small one at the origin.
    for p in ["-8 0 -8", "-8 0 8", "8 0 8", "8 0 -8"]: pos.add p
    polys.add "<polylist count=\"1\"><input semantic=\"VERTEX\" source=\"#vtx\" offset=\"0\"/>" &
      "<vcount>4</vcount><p>0 1 2 3</p></polylist>\n"
  var o = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
  o.add "<COLLADA version=\"1.4.0\" xmlns=\"http://www.collada.org/2005/11/COLLADASchema\">\n"
  o.add "<asset><unit meter=\"0.1\" name=\"decimeter\"/><up_axis>Y_UP</up_axis></asset>\n"
  o.add "<library_geometries>\n<geometry id=\"rooms_geo\"><mesh>\n"
  o.add &"<source id=\"pos\"><float_array id=\"pos_a\" count=\"{pos.len * 3}\">{pos.join(\" \")}</float_array>" &
    &"<technique_common><accessor source=\"#pos_a\" count=\"{pos.len}\" stride=\"3\"><param name=\"X\" type=\"float\"/><param name=\"Y\" type=\"float\"/><param name=\"Z\" type=\"float\"/></accessor></technique_common></source>\n"
  o.add "<vertices id=\"vtx\"><input semantic=\"POSITION\" source=\"#pos\"/></vertices>\n"
  o.add polys
  o.add "</mesh></geometry>\n</library_geometries>\n"
  o.add "<library_visual_scenes><visual_scene id=\"scene\"><node id=\"rooms\" name=\"rooms\"><instance_geometry url=\"#rooms_geo\"/></node></visual_scene></library_visual_scenes>\n"
  o.add "<scene><instance_visual_scene url=\"#scene\"/></scene>\n</COLLADA>\n"
  createDir(path.parentDir)
  writeFile(path, o)
  max(n, 1)

# --- object links ------------------------------------------------------------------------

proc cornerKey(p: Vec3): (int, int, int) =
  (int(round(p.x * 10)), int(round(p.y * 10)), int(round(p.z * 10)))

proc faceKey(g: Geometry, f: Face): string =
  var cs: seq[(int, int, int)]
  for v in f.verts: cs.add cornerKey(g.points[v])
  cs.sort
  result = f.texture
  for c in cs: result.add &"|{c[0]},{c[1]},{c[2]}"

proc restoreObjectIds*(model: Geometry, akevXml, akevOni: string):
    tuple[linked, faces: int, ids: seq[int32], built: Geometry] =
  ## OniSplit can only link geometry to objects when it imports the objects
  ## itself, so after rebuilding the environment from Catwalk's faces the quads'
  ## ObjectId (type << 24 | id) is put back here, matching quads by their corners.
  ## akevXml is OniSplit's XML dump of akevOni; akevOni is patched in place.
  let built = importAkevXml(akevXml)
  var exact: Table[string, int32]
  var byCorner: Table[(int, int, int), seq[(string, int32)]]
  for f in model.faces:
    if f.objectId == -1: continue
    exact[model.faceKey(f)] = f.objectId
    for v in f.verts:
      byCorner.mgetOrPut(cornerKey(model.points[v]), @[]).add (f.texture, f.objectId)
  var ids = newSeq[int32](built.faces.len)
  for i, f in built.faces:
    ids[i] = -1
    let k = built.faceKey(f)
    if k in exact:
      ids[i] = exact[k]
      continue
    # Split or re-triangulated faces: an id shared by every corner (same texture).
    var common: seq[int32]
    for n, v in f.verts:
      var here: seq[int32]
      for (tex, id) in byCorner.getOrDefault(cornerKey(built.points[v])):
        if tex == f.texture and id notin here: here.add id
      if n == 0: common = here
      else:
        var keep: seq[int32]
        for id in common:
          if id in here: keep.add id
        common = keep
      if common.len == 0: break
    if common.len == 1: ids[i] = common[0]
  for id in ids:
    if id != -1: inc result.linked
  result.faces = ids.len
  result.ids = ids
  result.built = built
  if result.linked == 0: return

  # The quad table in the .oni: int32 count, then 56 bytes per quad
  # (4 point, 4 texcoord, 4 color, flags, ObjectId). Found by its count plus the
  # first quad's point and texcoord indices, read from the XML dump.
  let xml = readFile(akevXml)
  let q0 = xml.find("<AGQGQuad>")
  if q0 < 0: raise newException(ValueError, "no quads in " & akevXml)
  var first: seq[int32]
  var p = q0
  while first.len < 8:
    let a = xml.find("<Int32>", p)
    let b = xml.find("</Int32>", a)
    first.add parseInt(xml[a + 7 ..< b]).int32
    p = b
  var pattern = newString(4 + 32)
  var cnt = ids.len.int32
  copyMem(pattern[0].addr, cnt.addr, 4)
  for i, v in first:
    var x = v
    copyMem(pattern[4 + i * 4].addr, x.addr, 4)
  var data = readFile(akevOni)
  let at = data.find(pattern)
  if at < 0 or data.find(pattern, at + 1) >= 0:
    raise newException(ValueError, "could not locate the quad table in " & akevOni)
  let base = at + 4
  if base + ids.len * 56 > data.len: raise newException(ValueError, "quad table truncated")
  for i, id in ids:
    var x = id
    copyMem(data[base + i * 56 + 52].addr, x.addr, 4)
  writeFile(akevOni, data)

# --- ONLV quad references ------------------------------------------------------------------------

proc quadKey(g: Geometry, f: Face): string =
  ## Corner positions only (no texture: door frames get a marker material).
  var cs: seq[(int, int, int)]
  for v in f.verts:
    let c = cornerKey(g.points[v])
    if c notin cs: cs.add c
  cs.sort
  for c in cs: result.add &"{c[0]},{c[1]},{c[2]}|"

proc tagEnd(xml: string, at: int, tag: string): int =
  ## End (exclusive) of the element starting at `at`, self-closing or not.
  let gt = xml.find('>', at)
  if xml[gt - 1] == '/': gt + 1
  else: xml.find("</" & tag & ">", gt) + tag.len + 3

proc remapLevelLinks*(orig, built: Geometry, builtIds: seq[int32], onlvXml: string):
    tuple[objects, added, doors, lostDoors: int] =
  ## The ONLV refers to AKEV quads by index: ONOA lists each object's quads and
  ## each OBOA door has a DoorGunkId. Both still index the original AKEV, so they
  ## are rewritten for the rebuilt one. onlvXml is patched in place.
  var quadsOf: OrderedTable[int32, seq[int]]
  for i, id in builtIds:
    if id != -1: quadsOf.mgetOrPut(id, @[]).add i
  var x = readFile(onlvXml)

  # ONOA: ObjectId -> IDXA id of its quad list.
  var listOf: Table[string, seq[int]]
  var maxId = 0
  var p = 0
  while true:
    p = x.find(" id=\"", p)
    if p < 0: break
    let q = x.find('"', p + 5)
    maxId = max(maxId, parseInt(x[p + 5 ..< q]))
    p = q
  let onoa = x.find("<ONOA ")
  if onoa < 0: raise newException(ValueError, "no ONOA in " & onlvXml)
  let onoaEnd = tagEnd(x, onoa, "ONOA")
  var seen: HashSet[int32]
  p = onoa
  while true:
    p = x.find("<ONOAElement>", p)
    if p < 0 or p > onoaEnd: break
    let e = x.find("</ONOAElement>", p)
    let a = x.find("<ObjectId>", p) + 10
    let id = parseInt(x[a ..< x.find('<', a)]).int32
    let l = x.find("<QuadList>#", p) + 11
    if l > 10 and l < e:   # the id -1 element has no list
      listOf[x[l ..< x.find('<', l)]] = quadsOf.getOrDefault(id)
      inc result.objects
    seen.incl id
    p = e
  # Objects that gained geometry get a new element and list.
  var newElems, newLists = ""
  for id, quads in quadsOf:
    if id in seen: continue
    inc maxId
    newElems.add &"            <ONOAElement>\n                <ObjectId>{id}</ObjectId>\n" &
      &"                <QuadList>#{maxId}</QuadList>\n            </ONOAElement>\n"
    newLists.add &"    <IDXA id=\"{maxId}\" />\n"
    listOf[$maxId] = quads
    inc result.added
  if newElems.len > 0:
    let close = x.find("</Elements>", onoa)
    if close >= 0 and close < onoaEnd:
      x.insert(newElems, close)
    else:
      # Levels OniSplit made from scratch: <Elements />.
      let empty = x.find("<Elements />", onoa)
      if empty < 0 or empty > onoaEnd: raise newException(ValueError, "no ONOA elements in " & onlvXml)
      x = x[0 ..< empty] & "<Elements>\n" & newElems & "        </Elements>" & x[empty + "<Elements />".len .. ^1]
    x.insert(newLists, x.rfind("</Oni>"))

  # DoorGunkId: the rebuilt quad with the same corners, preferring a door frame.
  var byKey: Table[string, seq[int]]
  for i, f in built.faces: byKey.mgetOrPut(built.quadKey(f), @[]).add i
  var o = newStringOfCap(x.len + x.len div 4)
  p = 0
  while true:
    let a = x.find("<DoorGunkId>", p)
    if a < 0: break
    let b = x.find('<', a + 12)
    var g = parseInt(x[a + 12 ..< b])
    if g > 0:
      inc result.doors
      let cands = if g < orig.faces.len: byKey.getOrDefault(orig.quadKey(orig.faces[g])) else: @[]
      var pick = -1
      for c in cands:
        if (built.faces[c].flags and gfDoorFrame) != 0:
          pick = c
          break
      if pick < 0 and cands.len > 0: pick = cands[0]
      if pick < 0: inc result.lostDoors
      g = max(pick, 0)
    o.add x[p ..< a + 12]
    o.add $g
    p = b
  o.add x[p .. ^1]
  x = o

  # Rewrite the quad lists.
  o.setLen 0
  p = 0
  while true:
    let a = x.find("<IDXA id=\"", p)
    if a < 0: break
    let q = x.find('"', a + 10)
    let id = x[a + 10 ..< q]
    if id notin listOf:
      o.add x[p ..< q]
      p = q
      continue
    let e = tagEnd(x, a, "IDXA")
    o.add x[p ..< a]
    o.add &"<IDXA id=\"{id}\">\n        <Indices>\n"
    for i in listOf[id]: o.add &"            <Int32>{i}</Int32>\n"
    o.add "        </Indices>\n    </IDXA>"
    p = e
  o.add x[p .. ^1]
  writeFile(onlvXml, o)
