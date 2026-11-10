## The level's environment geometry as Catwalk edits it: shared points and
## polygons (faces) carrying their own UVs, baked vertex colors, texture, Oni
## gunk flags and script id. Faces are grouped into pieces, the units you
## select, move and reshape; pieces made with the brush tools are convex solids.
##
## Imported from OniSplit's XML dump of the AKEV instance (which keeps every
## per-quad flag), and written back as .dae files plus a level XML that tells
## OniSplit each group's flags and script id.

import std/[parsexml, streams, strutils, tables, os, algorithm, sets, json, math, strformat, sequtils]
import vmath
import tga

type
  AnimMode* = enum amNone, amPulse, amFlicker
  AnimInterp* = enum aiSmooth, aiLinear, aiStep

const MaxAnimSeed* = 999999

type

  CornerAnim* = object
    ## A corner's own light settings. Its light going back and forth between
    ## its baked color and color in the game (Arklite's vertex_light.c, from the
    ## build's vertexlight.bin), and whether Bake light leaves it alone.
    manual*: bool                    ## Overrides the lights: the bake keeps this corner's color.
    mode*: AnimMode
    interp*: AnimInterp
    color*: array[3, uint8]          ## The other end, 0..255.
    period*: float32                 ## Seconds: one pulse there and back, or one flicker step.
    offset*: float32                 ## Seconds added to the clock.
    seed*: uint32                    ## Flicker: picks the random pattern. Flickers with the
                                     ## same period, offset and seed flicker together.
    unlit*: float32                  ## 0..1: how far the corner ignores its shading (1 = its
                                     ## color at full brightness, hue kept: fullbright).
                                     ## Applied on top of its colors and its animations' colors
                                     ## everywhere they're shown or built (shownColor, liveColor).
    low*, high*: float32             ## How far toward color it goes (0 the baked color, 1
                                     ## all the way): Pulse between them, Flicker a random
                                     ## level between them each step. CornerAnim() has
                                     ## high 0; a mode's defaults set it (withDefaults).
    stability*: float32              ## Flicker: share of the time it works normally (at the
                                     ## baked color), 0 = flickers all the time...
    faultLen*: float32               ## ...in runs of this many seconds (a failure, or a
                                     ## stretch working), at least one period.

  LightLayer* = object
    ## What one animated light does to one corner: anim.color is the corner's
    ## color with that light at the other end of its animation (the rest of the
    ## lighting unchanged). Several layers on a corner add up in the game.
    corner*: int32
    anim*: CornerAnim

  Face* = object
    verts*: seq[int32]               ## Indices into Geometry.points, in order.
    uvs*: seq[Vec2]
    colors*: seq[array[4, uint8]]
    anims*: seq[CornerAnim]          ## Empty, or per corner (may be shorter than verts: animAt).
    lightAnims*: seq[LightLayer]     ## Baked from animated lights (lighting.nim), any number per corner.
    texture*: string                 ## Name without the TXMP prefix, e.g. WH_INTWALL.
    untint*: array[3, uint8]         ## 255 minus the face's tint per channel (use tint and
                                     ## tint=), so a zeroed Face is untinted (white).
    flags*: uint32                   ## Gunk flags (authorable ones; see AuthorFlags).
    scriptId*: int32                 ## 0 = none. Used by env_show and friends.
    objectId*: int32                 ## -1, or object type << 24 | object id: geometry
                                     ## owned by a furniture/door/console/... object.
    piece*: int32

  Piece* = object
    brush*: bool                     ## A convex solid made with Catwalk's tools.
    hidden*: bool
    group*: int32                    ## Group it belongs to (App.groups id), 0 = none.

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
  gfNoShadow* = 0x20000000'u32     ## Catwalk only: the light bake's shadow rays pass through it.

  FlagNames* = [
    ("DoorFrame", gfDoorFrame), ("Ghost", gfGhost), ("StairsUp", gfStairsUp),
    ("StairsDown", gfStairsDown), ("Stairs", gfStairs), ("Triangle", gfTriangle),
    ("Transparent", gfTransparent), ("TwoSided", gfTwoSided), ("NoCollision", gfNoCollision),
    ("Invisible", gfInvisible), ("NoObjectCollision", gfNoObjectCollision),
    ("NoCharacterCollision", gfNoCharacterCollision), ("NoOcclusion", gfNoOcclusion),
    ("Danger", gfDanger), ("Horizontal", gfHorizontal), ("Vertical", gfVertical),
    ("GridIgnore", gfGridIgnore), ("NoDecals", gfNoDecals), ("Furniture", gfFurniture),
    ("ProjectionBit0", gfProjection0), ("ProjectionBit1", gfProjection1),
    ("SoundTransparent", gfSoundTransparent), ("Impassable", gfImpassable),
    ("NoShadow", gfNoShadow)]

  ## Flags OniSplit computes itself; never stored or written.
  DerivedFlags* = gfTriangle or gfHorizontal or gfVertical or gfProjection0 or gfProjection1

  ## Flags only Catwalk uses; stored, but never written to the level.
  EditorFlags* = gfNoShadow

  ## Flags shown as checkboxes in the Face inspector, with their tooltips.
  EditableFlags* = [
    ("Transparent", gfTransparent,
     "Drawn alpha-blended after the opaque geometry. Build sets it (and Two-sided) on every face whose texture has alpha, as Bungie's tools did."),
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
     "Room link in a doorway: AI pathfinding passes between the two rooms through the door."),
    ("No shadow", gfNoShadow,
     "Doesn't block light: point and directional lights shine through it when the lighting is baked. " &
     "Catwalk only; not written to the level.")]

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

proc compact*(g: Geometry, keepPieces = false) =
  ## Drops faces without corners, unused points and empty pieces (keepPieces:
  ## not the pieces, so piece numbers stay valid).
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
  if keepPieces:
    g.bump()
    return
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
  ## Piece numbers stay as they are: callers hold on to them.
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
        if j < f.anims.len: f.anims.delete(j)
        f.lightAnims.setLen 0   # until the next bake
      else: inc i
  g.compact(keepPieces = true)

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

# --- corner light animation ------------------------------------------------------------------

proc withDefaults*(m: CornerAnim, mode: AnimMode, color: array[3, uint8]): CornerAnim =
  ## m switched on from Off: a mode's starting timing toward color.
  result = m
  result.mode = mode
  result.color = color
  result.period = if mode == amFlicker: 0.1 else: 2.0
  result.interp = if mode == amFlicker: aiStep else: aiSmooth
  result.low = 0
  result.high = 1
  result.stability = 0
  result.faultLen = 1

proc animAt*(f: Face, k: int): CornerAnim =
  if k < f.anims.len: f.anims[k] else: CornerAnim()

proc animated*(f: Face): bool =
  for m in f.anims:
    if m.mode != amNone: return true

proc hasCornerData*(f: Face): bool =
  for m in f.anims:
    if m.mode != amNone or m.manual or m.unlit > 0: return true

proc fullbright*(c: array[3, uint8]): array[3, uint8] =
  ## c at full brightness: scaled up until its brightest channel is 255, so it
  ## keeps its hue (255 0 0 stays 255 0 0, a shadowed 100 0 0 becomes it).
  ## Black has no hue: white, the texture's own colors.
  let top = max(c[0], max(c[1], c[2]))
  if top == 0: return [255'u8, 255, 255]
  for i in 0 .. 2: result[i] = uint8(min(round(c[i].float32 * 255 / top.float32), 255))

proc unlitColor*(c, base: array[3, uint8], unlit: float32): array[3, uint8] =
  ## c brightened the way base's unlit factor brightens base: base moves unlit
  ## of the way to its fullbright color, and c (base itself, or an animation's
  ## other end) is scaled by the same gain, so the animation keeps its contrast
  ## (a red corner pulsing to black stays a pulse to black). A black base has
  ## no hue to scale: its colors move toward white instead.
  if unlit <= 0: return c
  let u = min(unlit, 1)
  let top = max(base[0], max(base[1], base[2]))
  if top == 0:
    for i in 0 .. 2: result[i] = uint8(round(c[i].float32 + (255 - c[i].float32) * u))
    return
  let gain = 1 + (255 / top.float32 - 1) * u
  for i in 0 .. 2: result[i] = uint8(min(round(c[i].float32 * gain), 255))

const NoTint* = [255'u8, 255, 255]

proc tint*(f: Face): array[3, uint8] =
  ## The face's tint: its color, multiplied into the light its corners get
  ## (baked, unlit, animated). White = none.
  [255'u8 - f.untint[0], 255'u8 - f.untint[1], 255'u8 - f.untint[2]]

proc `tint=`*(f: var Face, c: array[3, uint8]) =
  f.untint = [255'u8 - c[0], 255'u8 - c[1], 255'u8 - c[2]]

proc tinted*(f: Face): bool = f.untint != [0'u8, 0, 0]

proc tinted*(c, tint: array[3, uint8]): array[3, uint8] =
  ## Light c on a surface of color tint (channel times channel, 255 = 1).
  for i in 0 .. 2: result[i] = uint8((c[i].int * tint[i].int + 127) div 255)

proc shownColor*(f: Face, k: int): array[4, uint8] =
  ## The corner's color as the views draw it and Build writes it: its baked
  ## color with its unlit factor applied, then the face's tint.
  result = f.colors[k]
  let u = f.animAt(k).unlit
  var c = [result[0], result[1], result[2]]
  if u > 0: c = unlitColor(c, c, u)
  if f.tinted: c = tinted(c, f.tint)
  result = [c[0], c[1], c[2], result[3]]

proc noise(seed: uint32, step: int): float32 =
  ## vertex_light.c's noise: 0..1, the same for the same step of the same flicker.
  var h = seed xor (cast[uint32](step.int32) * 0x9e3779b1'u32)
  h = h xor (h shr 16); h *= 0x7feb352d'u32
  h = h xor (h shr 15); h *= 0x846ca68b'u32
  h = h xor (h shr 16)
  (h shr 8).float32 * (1'f32 / 16777215'f32)

proc flickerSeed(m: CornerAnim): uint32 =
  ## vertex_light.c's flicker_seed.
  cast[uint32](max(m.period, 0.01'f32)) * 31'u32 + cast[uint32](m.offset) + m.seed

proc runWorks(m: CornerAnim, seed: uint32, step: int): bool =
  ## Whether the run of steps that flicker step `step` is in came up working
  ## (vertex_light.c's flicker_run and run_works). Only for stability > 0.
  let period = max(m.period, 0.01'f32)
  let run = max(m.faultLen, period)
  noise(seed xor 0x5bd1e995'u32, floor(step.float32 * period / run).int) < m.stability

proc flickerFailing*(m: CornerAnim, seconds: float32): bool =
  ## Whether a flicker is in one of its failures at seconds (Stability 0 fails
  ## all the time): when a light's ambient plays, as Arklite's vertex_light.c
  ## sound_gate_open has it.
  if m.stability <= 0: return true
  let period = max(m.period, 0.01'f32)
  not m.runWorks(m.flickerSeed, floor((seconds + m.offset) / period).int)

proc ambientPitch*(m: CornerAnim, light: int, low, high: float32, seconds: float32): float32 =
  ## The pitch a light's ambient starts at, at seconds: from low to high, by the
  ## flicker's run (any other light: its step) and the light's id. Arklite's
  ## vertex_light.c ambient_pitch is the same, so the preview picks what the game does.
  let period = max(m.period, 0.01'f32)
  let k = floor((seconds + m.offset) / period).int
  let step = if m.mode == amFlicker: floor(k.float32 * period / max(m.faultLen, period)).int else: k
  low + (high - low) * noise(m.flickerSeed xor (0x6c8e9cf5'u32 * uint32(light + 1)), step)

proc animAmount*(m: CornerAnim, seconds: float32): float32 =
  ## How far toward m.color at seconds, 0..1: Arklite's vertex_light.c amount(),
  ## so the views animate the corners the way the game does.
  proc shape(f: float32, interp: AnimInterp): float32 =
    case interp
    of aiStep: (if f < 0.5: 0 else: 1)
    of aiSmooth: f * f * (3 - 2 * f)
    of aiLinear: f
  let period = max(m.period, 0.01'f32)
  let x = (seconds + m.offset) / period
  let k = floor(x)
  let f = x - k
  if m.mode == amPulse:
    let t = if m.interp == aiStep: (if f < 0.5: 0'f32 else: 1'f32)
            else: shape(if f < 0.5: 2 * f else: 2 - 2 * f, m.interp)
    return m.low + (m.high - m.low) * t
  let seed = m.flickerSeed
  proc level(step: int): float32 =
    ## flicker_level: 0 while the light works (by stability), else between low and high.
    if m.stability > 0 and m.runWorks(seed, step): return 0
    m.low + (m.high - m.low) * noise(seed, step)
  let v0 = level(k.int)
  if m.interp == aiStep: return v0
  v0 + (level(k.int + 1) - v0) * shape(f, m.interp)

proc animEnd*(f: Face, k: int, color: array[3, uint8]): array[3, uint8] =
  ## An animation's other end (color) for corner k as shown and built: with
  ## the corner's unlit factor and the face's tint, like shownColor.
  let baked = [f.colors[k][0], f.colors[k][1], f.colors[k][2]]
  result = unlitColor(color, baked, f.animAt(k).unlit)
  if f.tinted: result = tinted(result, f.tint)

proc liveColor*(f: Face, k: int, seconds: float32): array[4, uint8] =
  ## The corner's shown color at seconds with its own and its lights'
  ## animations playing (they add up, like vertex_light.c's records). The
  ## animations' other ends are tinted like the baked color (animEnd).
  let base = f.shownColor(k)
  var sum = [base[0].float32, base[1].float32, base[2].float32]
  template add(m: CornerAnim) =
    if m.mode != amNone:
      let t = m.animAmount(seconds)
      let b = f.animEnd(k, m.color)
      for i in 0 .. 2: sum[i] += (b[i].float32 - base[i].float32) * t
  add f.animAt(k)
  for l in f.lightAnims:
    if l.corner == k: add l.anim
  for i in 0 .. 2: result[i] = uint8(clamp(sum[i] + 0.5, 0, 255))
  result[3] = base[3]

proc setAnim*(f: var Face, k: int, m: CornerAnim) =
  while f.anims.len < f.verts.len: f.anims.add CornerAnim()
  f.anims[k] = m
  if not f.hasCornerData: f.anims.setLen 0

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
    var fj = %*{"v": vs, "uv": uv, "c": col, "t": texIndex[f.texture], "f": f.flags.int,
                "s": f.scriptId, "o": f.objectId, "p": f.piece}
    if f.tinted:
      let t = f.tint
      fj["ti"] = %((t[0].int shl 16) or (t[1].int shl 8) or t[2].int)
    proc animJson(m: CornerAnim): JsonNode =
      %*[m.mode.ord, m.interp.ord, (m.color[0].int shl 16) or (m.color[1].int shl 8) or m.color[2].int,
         m.period, m.offset, (if m.manual: 1 else: 0), m.low, m.high, m.stability, m.faultLen, m.unlit, m.seed.int]
    if f.hasCornerData:
      var an = newJArray()
      for k in 0 ..< f.verts.len:
        let m = f.animAt(k)
        if m.mode == amNone and not m.manual and m.unlit <= 0: an.add newJNull()
        else: an.add animJson(m)
      fj["a"] = an
    if f.lightAnims.len > 0:
      var la = newJArray()
      for l in f.lightAnims: la.add %*[l.corner, animJson(l.anim)]
      fj["la"] = la
    faces.add fj
  var pcs = newJArray()
  for p in g.pieces:
    let pj = %*{"b": p.brush}
    if p.group != 0: pj["g"] = %p.group
    pcs.add pj
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
    if fj.hasKey("ti"):
      let t = fj["ti"].getInt
      f.tint = [uint8((t shr 16) and 255), uint8((t shr 8) and 255), uint8(t and 255)]
    for v in fj["v"].getElems: f.verts.add v.getInt.int32
    let uv = fj["uv"].getElems
    var k = 0
    while k + 1 < uv.len:
      f.uvs.add vec2(uv[k].getFloat, uv[k + 1].getFloat)
      k += 2
    for c in fj["c"].getElems:
      let n = c.getInt
      f.colors.add [uint8((n shr 16) and 255), uint8((n shr 8) and 255), uint8(n and 255), 255'u8]
    proc animOf(aj: JsonNode): CornerAnim =
      let e = aj.getElems
      if e.len >= 5:
        let c = e[2].getInt
        result = CornerAnim(mode: AnimMode(clamp(e[0].getInt, 0, AnimMode.high.ord)),
                            interp: AnimInterp(clamp(e[1].getInt, 0, AnimInterp.high.ord)),
                            color: [uint8((c shr 16) and 255), uint8((c shr 8) and 255), uint8(c and 255)],
                            period: e[3].getFloat.float32, offset: e[4].getFloat.float32,
                            manual: e.len >= 6 and e[5].getInt != 0, high: 1)
        if e.len >= 10:
          result.low = e[6].getFloat.float32
          result.high = e[7].getFloat.float32
          result.stability = e[8].getFloat.float32
          result.faultLen = e[9].getFloat.float32
        if e.len >= 11: result.unlit = clamp(e[10].getFloat, 0, 1).float32
        if e.len >= 12: result.seed = clamp(e[11].getInt, 0, MaxAnimSeed).uint32
    for aj in fj{"a"}.getElems: f.anims.add animOf(aj)
    for lj in fj{"la"}.getElems:
      let e = lj.getElems
      if e.len == 2: f.lightAnims.add LightLayer(corner: e[0].getInt.int32, anim: animOf(e[1]))
    result.faces.add f
  for pj in j["pieces"].getElems:
    result.pieces.add Piece(brush: pj{"b"}.getBool, group: pj{"g"}.getInt.int32)

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

proc daePieces(g: Geometry, f: Face): seq[seq[int]] =
  ## Corner lists (indices into f.verts) to write for f. OniSplit drops any
  ## polygon with more than 4 corners but still files it in the octree, which
  ## then throws KeyNotFoundException, so larger faces go out as a fan of quads
  ## (plus a triangle). Pieces of a convex face are convex; slivers made by
  ## collinear corners are skipped.
  let n = f.verts.len
  if n <= 4: return @[toSeq(0 ..< n)]
  var i = 1
  while i + 1 < n:
    let piece = if i + 2 < n: @[0, i, i + 1, i + 2] else: @[0, i, i + 1]
    var area = vec3(0)
    let p0 = g.points[f.verts[0]]
    for k in 1 ..< piece.len - 1:
      area += cross(g.points[f.verts[piece[k]]] - p0, g.points[f.verts[piece[k + 1]]] - p0)
    if area.length > 1e-4: result.add piece
    i += piece.len - 2

type
  Severity* = enum
    ## How bad an issue is: info = the build copes with it, warning = the level
    ## builds but likely looks or plays wrong, error = it breaks the level.
    sevError = "error", sevWarning = "warning", sevInfo = "info"

  FaceProblem* = object
    severity*: Severity
    face*: int
    corner*: int     ## Index into the face's verts of the corner to fix, or -1.
    text*: string

proc faceProblems*(g: Geometry): seq[FaceProblem] =
  ## Faces Oni (or OniSplit) can't take as they are: more than 4 corners,
  ## corners on top of each other, bent (non-planar) or concave faces, and
  ## faces with no area. Each names the corner most worth moving.
  const PlanarTol = 0.05'f32   # world units off the face's plane
  for fi, f in g.faces:
    let n = f.verts.len
    if n < 3: continue
    let ps = f.verts.mapIt(g.points[it])
    var nrm = vec3(0)
    for k in 0 ..< n:
      let (a, b) = (ps[k], ps[(k + 1) mod n])
      nrm += vec3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
    if nrm.length < 1e-4:
      result.add FaceProblem(severity: sevWarning, face: fi, corner: -1, text: "has no area")
      continue
    nrm = nrm.normalize
    # Corner turns: cross of the edges in and out, along the normal. Negative =
    # concave; near zero relative to the edges = a corner on a straight line.
    var dup, concave = -1
    var straight: seq[int]   # Corners on a straight edge: deleting one keeps the shape.
    for k in 0 ..< n:
      let ein = ps[k] - ps[(k + n - 1) mod n]
      let eout = ps[(k + 1) mod n] - ps[k]
      if eout.length < 1e-3:
        if dup < 0: dup = (k + 1) mod n
        continue
      if ein.length < 1e-3: continue
      let turn = dot(cross(ein, eout), nrm) / (ein.length * eout.length)
      if turn < -1e-3 and concave < 0: concave = k
      if abs(turn) < 1e-3: straight.add k
    if dup >= 0:
      result.add FaceProblem(severity: sevWarning, face: fi, corner: dup, text: &"sits on top of corner {(dup + n - 1) mod n}")
    if n > 4:
      # The whole face's problem, not one corner's: no corner is named.
      var text = &"has {n} corners, but Oni faces take at most 4, so the build splits it into {daePieces(g, f).len} pieces"
      if straight.len > 0:
        let names = straight.mapIt($it)
        let list = if names.len == 1: "corner " & names[0]
                   else: "corners " & names[0 ..< ^1].join(", ") & " and " & names[^1]
        text.add &"; {list} lie on straight edges and can be deleted without changing its shape"
      result.add FaceProblem(severity: sevInfo, face: fi, corner: -1, text: text)
    var c = vec3(0)
    for p in ps: c += p
    c /= n.float32
    var far = -1
    var farDist = PlanarTol
    for k, p in ps:
      let d = abs(dot(p - c, nrm))
      if d > farDist:
        farDist = d
        far = k
    if far >= 0:
      result.add FaceProblem(severity: sevWarning, face: fi, corner: far,
        text: &"is {farDist:.2f} off the plane of the rest of the face (the face is bent)")
    if concave >= 0:
      result.add FaceProblem(severity: sevWarning, face: fi, corner: concave, text: "dents inwards (the face is concave here)")

proc faceRef*(fp: FaceProblem): string =
  ## How build logs and the Issues list name the face; parseFaceRef reads it back.
  result = &"face {fp.face}"
  if fp.corner >= 0: result.add &", corner {fp.corner}"

proc parseFaceRef*(s: string): tuple[face, corner: int] =
  ## (face, corner) from a line naming "face N" or "face N, corner K"; -1 if absent.
  result = (-1, -1)
  let low = s.toLowerAscii
  var at = low.find("face ")
  while at > 0 and low[at - 1].isAlphaAscii: at = low.find("face ", at + 1)   # "surface"
  if at < 0: return
  var i = at + 5
  var j = i
  while j < s.len and s[j].isDigit: inc j
  if j == i: return
  result.face = parseInt(s[i ..< j])
  const tag = ", corner "
  if low.continuesWith(tag, j):
    i = j + tag.len
    j = i
    while j < s.len and s[j].isDigit: inc j
    if j > i: result.corner = parseInt(s[i ..< j])

# Spinning groups: Oni moves only physics objects (ONLV OBOA) with an OBAN, so
# a group with a spin leaves the environment and goes to -create:level's
# <Physics> as a looping object, turned about the vertical through its center.
# An Oni mesh has one texture, so each texture is its own object, sharing the
# group's pivot and script id. No collision: characters find floors only in the
# environment, so they fall through it anyway, and one that blocks an animated
# object pauses that object alone, which would pull a group's parts apart.
# Particle objects in the group don't go to the object: Arklite turns them
# (spinparticles.bin, its spin_particle.c), with the same period.

const
  MinSpinSeconds* = 0.1'f32
  SpinSource = "spin.xml"
  SpinScriptBase = 30000    ## Group id + this = the object's script id.
  SpinParticleMagic = 0x50535743'u32   ## "CWSP"
  SpinParticleVersion = 1'u32

type
  SpinGroup* = object
    name*: string          ## The object's name: its M3GM and OBAN instances.
    seconds*: float32      ## Per turn; negative = the other way.
    center*: Vec3
    faces*: seq[int]
    particles*: seq[int]   ## Ids of the Particle objects in it.
    scriptId*: int         ## obj_create's handle: see startOnLoad.

  SpinMember* = tuple[id: int, group: int32, pos: Vec3]  ## A Particle object in a group.

proc spinTicks*(seconds: float32): int =
  ## A turn's length in ticks.
  max(round(abs(seconds) * 60).int, 2)

proc collectSpins*(g: Geometry, parent: Table[int32, int32], spin: Table[int32, float32],
                   members: seq[SpinMember]): seq[SpinGroup] =
  ## The groups that spin, from the group table. A group inside a spinning group
  ## turns with the outer one; its own spin doesn't add to it. The center is that
  ## of the group's faces and particles together, so they turn as one.
  proc outerSpin(gid: int32): int32 =
    var at = gid
    while at != 0:
      if spin.getOrDefault(at) != 0: result = at
      at = parent.getOrDefault(at)
  var found: OrderedTable[int32, SpinGroup]
  var bounds: Table[int32, (Vec3, Vec3)]
  proc note(id: int32, p: Vec3) =
    let (lo, hi) = bounds.getOrDefault(id, (vec3(Inf.float32), vec3(-Inf.float32)))
    bounds[id] = (min(lo, p), max(hi, p))
  for i, f in g.faces:
    if f.verts.len < 3 or f.piece notin 0'i32 .. g.pieces.high.int32: continue
    let id = outerSpin(g.pieces[f.piece].group)
    if id == 0: continue
    found.mgetOrPut(id, SpinGroup()).faces.add i
    for v in f.verts: note(id, g.points[v])
  for m in members:
    let id = outerSpin(m.group)
    if id == 0: continue
    found.mgetOrPut(id, SpinGroup()).particles.add m.id
    note(id, m.pos)
  for id, s in found:
    var s = s
    let (lo, hi) = bounds[id]
    s.name = "cw_spin" & $id
    s.seconds = spin[id]
    s.center = (lo + hi) / 2
    s.scriptId = SpinScriptBase + id
    result.add s

proc spinGroups*(g: Geometry, groupsFile: string, particles: Table[int, Vec3]): seq[SpinGroup] =
  ## The groups in groupsFile that spin. particles: where each Particle object is.
  if not fileExists(groupsFile): return
  let j = parseFile(groupsFile)
  var parent = initTable[int32, int32]()
  var spin = initTable[int32, float32]()
  for gj in j{"groups"}.getElems:
    let id = gj{"id"}.getInt.int32
    parent[id] = gj{"parent"}.getInt.int32
    spin[id] = gj{"spin"}.getFloat.float32
  var members: seq[SpinMember]
  for e in j{"objects"}.getElems:
    let k = e.getElems
    if k.len == 3 and k[0].getStr == "PART" and k[1].getInt in particles:
      members.add (k[1].getInt, k[2].getInt.int32, particles[k[1].getInt])
  collectSpins(g, parent, spin, members)

proc writeSpinParticles*(spins: seq[SpinGroup], path: string): int =
  ## spinparticles.bin for Arklite (spin_particle.c), sorted by object id: the
  ## particles of the spinning groups, each with its group's axis and turn. No
  ## file without any. Returns the record count.
  if fileExists(path): removeFile(path)
  var recs: seq[(uint32, float32, float32, float32)]
  for s in spins:
    for id in s.particles:
      recs.add (id.uint32, s.seconds, s.center.x, s.center.z)
  if recs.len == 0: return
  recs.sort(proc(a, b: (uint32, float32, float32, float32)): int = cmp(a[0], b[0]))
  var o = newStringStream()
  o.write SpinParticleMagic
  o.write SpinParticleVersion
  o.write recs.len.uint32
  for r in recs:
    o.write r[0]
    o.write r[1]
    o.write r[2]
    o.write r[3]
  createDir(path.parentDir)
  writeFile(path, o.data)
  recs.len

proc withoutSpinning*(g: Geometry, spins: seq[SpinGroup]): Geometry =
  ## g without the spinning groups' faces (they share g's points).
  var gone: HashSet[int]
  for s in spins:
    for fi in s.faces: gone.incl fi
  result = Geometry(points: g.points, pieces: g.pieces)
  for i, f in g.faces:
    if i notin gone: result.faces.add f

proc spinSamplers(s: SpinGroup): string =
  ## The node's turn as a Collada animation: one turn, ending one tick short of
  ## the start, so the loop's jump back to frame 0 is a normal step.
  let ticks = spinTicks(s.seconds)
  let last = 360 * (ticks - 1) / ticks * (if s.seconds < 0: -1.0 else: 1.0)
  let t = &"0 {(ticks - 1).float / 60:.5f}"
  result.add "<library_animations><animation id=\"turn\">"
  result.add &"<source id=\"t\"><float_array id=\"t_a\" count=\"2\">{t}</float_array><technique_common>" &
    "<accessor source=\"#t_a\" count=\"2\" stride=\"1\"><param name=\"TIME\" type=\"float\"/></accessor></technique_common></source>"
  result.add &"<source id=\"v\"><float_array id=\"v_a\" count=\"2\">0 {last:.5f}</float_array><technique_common>" &
    "<accessor source=\"#v_a\" count=\"2\" stride=\"1\"><param name=\"ANGLE\" type=\"float\"/></accessor></technique_common></source>"
  result.add "<source id=\"i\"><Name_array id=\"i_a\" count=\"2\">LINEAR LINEAR</Name_array><technique_common>" &
    "<accessor source=\"#i_a\" count=\"2\" stride=\"1\"><param name=\"INTERPOLATION\" type=\"name\"/></accessor></technique_common></source>"
  result.add "<sampler id=\"s\"><input semantic=\"INPUT\" source=\"#t\"/><input semantic=\"OUTPUT\" source=\"#v\"/>" &
    "<input semantic=\"INTERPOLATION\" source=\"#i\"/></sampler>"
  result.add &"<channel source=\"#s\" target=\"{s.name}/turn.ANGLE\"/></animation></library_animations>\n"

proc writeDae(path: string, g: Geometry, faces: seq[int], imageDir, markerDir: string,
              spin = SpinGroup()) =
  ## One geometry node; one polylist per material. With a spin the points are
  ## relative to its center and the node carries the turn.
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
        let p = g.points[v] - spin.center
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
      for piece in daePieces(g, f):
        vcount.add $piece.len
        for k in piece:
          let uv = f.uvs[k]
          uvs.add &"{uv.x:.6f} {1 - uv.y:.6f}"   # OniSplit flips V when reading .dae
          let c = f.shownColor(k)
          cols.add &"{c[0].float / 255:.4f} {c[1].float / 255:.4f} {c[2].float / 255:.4f} 1"
          p.add &"{pointIndex[f.verts[k]]} {corner} {corner}"
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
  let node = if spin.name.len > 0: spin.name else: "n"
  if spin.name.len > 0: o.add spinSamplers(spin)
  o.add &"<library_visual_scenes><visual_scene id=\"scene\"><node id=\"{node}\" name=\"{node}\">"
  if spin.name.len > 0:
    let c = spin.center
    o.add &"<translate sid=\"move\">{c.x:.4f} {c.y:.4f} {c.z:.4f}</translate><rotate sid=\"turn\">0 1 0 0</rotate>"
  o.add "<instance_geometry url=\"#geo\"><bind_material><technique_common>\n"
  for m in byMat.keys:
    let e = xmlEsc(m)
    o.add &"<instance_material symbol=\"{e}\" target=\"#{e}\"><bind_vertex_input semantic=\"uv\" input_semantic=\"TEXCOORD\" input_set=\"0\"/></instance_material>\n"
  o.add "</technique_common></bind_material></instance_geometry></node></visual_scene></library_visual_scenes>\n"
  o.add "<scene><instance_visual_scene url=\"#scene\"/></scene>\n</COLLADA>\n"
  writeFile(path, o)

proc writeSpinSource*(g: Geometry, spins: seq[SpinGroup], dir, imageDir, markerDir: string): string =
  ## The spinning groups as an object XML for -create:level; "" with none.
  ## g is the geometry they were found in. Groups of particles alone have none.
  if not spins.anyIt(it.faces.len > 0): return
  createDir(dir)
  var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Oni>\n<Physics>\n"
  for s in spins:
    var parts: OrderedTable[string, seq[int]]
    for fi in s.faces:
      let m = markerMaterial(g.faces[fi])
      parts.mgetOrPut(if m.len > 0: m else: g.faces[fi].texture, @[]).add fi
    var n = 0
    for _, faces in parts:
      var part = s
      part.name = s.name & "_" & $n
      part.faces = faces
      inc n
      writeDae(dir / part.name & ".dae", g, faces, imageDir, markerDir, part)
      x.add &"<Object><ScriptId>{s.scriptId}</ScriptId><Flags>NoCollision</Flags><Physics>Animated</Physics><Import Path=\"{part.name}.dae\">" &
        &"<Animation Name=\"{part.name}\"><Flags>Loop AutoStart</Flags></Animation></Import></Object>\n"
  x.add "</Physics>\n</Oni>\n"
  result = dir / SpinSource
  writeFile(result, x)

proc textureHasAlpha*(path: string): bool =
  ## Whether a texture's picture has see-through pixels (as the viewport's test).
  if not fileExists(path): return false
  try:
    return readTga(readFile(path)).seeThrough
  except CatchableError: discard

proc writeLevelSource*(g: Geometry, dir, envName, sky, imageDir, markerDir: string,
                       roomDaes: seq[string], objectFiles: seq[string] = @[]): string =
  ## Writes the geometry as .dae files (one per flags/script group) and the
  ## level XML OniSplit -create:level reads. Returns the XML path. objectFiles
  ## are object XMLs OniSplit builds into the level (doors: their geometry).
  createDir(dir)
  var groups: OrderedTable[(uint32, int32), seq[int]]
  var alphaTex: Table[string, bool]
  for i, f in g.faces:
    if f.verts.len < 3: continue
    var flags = f.flags and not (DerivedFlags or EditorFlags)
    # Bungie's importer made every face with a see-through texture Transparent
    # and Two-sided (Imp_Env2_Process.c): Oni then draws it in its alpha pass,
    # after everything solid and sorted, as the viewport does. Without it the
    # face blends in the solid pass, over whatever happens to be drawn yet.
    if markerMaterial(f).len == 0 and not f.texture.startsWith("_marker"):
      if f.texture notin alphaTex: alphaTex[f.texture] = textureHasAlpha(imageDir / f.texture & ".tga")
      if alphaTex[f.texture]: flags = flags or gfTransparent or gfTwoSided
    groups.mgetOrPut((flags, f.scriptId), @[]).add i
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
  # Not an empty element: OniSplit skips one without reading its attributes.
  # Past MaxSize it would shrink the picture (see pictures.nim for the size).
  x.add "      </Rooms>\n      <Textures MaxSize=\"1024\"> </Textures>\n    </Environment>\n"
  x.add &"    <Sky>{xmlEsc(skyName)}</Sky>\n    <Objects>"
  for f in objectFiles: x.add &"\n      <Import>{xmlEsc(f)}</Import>"
  x.add (if objectFiles.len > 0: "\n    " else: "") & "</Objects>\n  </Level>\n</Oni>\n"
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

proc restoreObjectIds*(model: Geometry, akevXml, akevOni: string,
                       keep = initTable[int32, int32]()):
    tuple[linked, faces: int, ids: seq[int32], built: Geometry] =
  ## OniSplit can only link geometry to objects when it imports the objects
  ## itself, so after rebuilding the environment from Catwalk's faces the quads'
  ## ObjectId (type << 24 | id) is put back here, matching quads by their corners.
  ## Quads OniSplit made for objects it imported (doors) keep their link,
  ## through keep (OniSplit's ObjectId -> Catwalk's).
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
    if f.objectId in keep:
      ids[i] = keep[f.objectId]
      continue
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

proc hasAnims*(g: Geometry): bool =
  for f in g.faces:
    if f.animated or f.lightAnims.len > 0: return true

type LightEvent* = object
  ## A light's sound: an impulse played when a flicker's failure starts, or each
  ## pulse; or (soundObject > 0) the Sound object that plays a flickering light's
  ## ambient, which Arklite lets play only while the flicker fails.
  mode*: AnimMode
  period*, offset*, stability*, fault*: float32  ## As its corners' records have them.
  seed*: uint32
  pitch*, pitchMax*, volume*: float32   ## Each play picks a pitch from pitch to pitchMax.
  pos*: Vec3
  positional*: bool                  ## False (directional lights): heard everywhere.
  sound*: string                     ## Impulse name (an ambient's, for soundObject).
  soundObject*: int                  ## Id of the SNDG that plays the light's ambient; 0 = impulse.
  light*: int                        ## The light's own id: picks its ambient's pitches.

proc writeVertexAnims*(model, built: Geometry, path: string,
                       events: seq[LightEvent] = @[]): int =
  ## vertexlight.bin for Arklite (vertex_light.c): one record per animation
  ## of a corner of the built quads, by AGQG index, with its baked color: the
  ## corner's own animation, then one per animated light that reaches it (a
  ## corner's records are written together; the game adds them up). A built
  ## quad came from a model face when it has the face's texture and all its
  ## corners are the face's (OniSplit gets large faces as several quads).
  ## Returns the record count.
  type Rec = tuple[quad: int, corner: int, m: CornerAnim]
  var byCorner: Table[(int, int, int), seq[(int, int)]]   # built (quad, corner)
  for qi, q in built.faces:
    for k, v in q.verts: byCorner.mgetOrPut(cornerKey(built.points[v]), @[]).add (qi, k)
  var recs: seq[Rec]
  var seen: HashSet[(int, int)]
  for f in model.faces:
    if not f.animated and f.lightAnims.len == 0: continue
    var own: HashSet[(int, int, int)]
    for v in f.verts: own.incl cornerKey(model.points[v])
    for k, v in f.verts:
      var layers: seq[CornerAnim]
      if f.animAt(k).mode != amNone: layers.add f.animAt(k)
      for l in f.lightAnims:
        if l.corner == k and l.anim.mode != amNone: layers.add l.anim
      for m in layers.mitems: m.color = f.animEnd(k, m.color)   # as the built colors
      if layers.len == 0: continue
      for (qi, qk) in byCorner.getOrDefault(cornerKey(model.points[v])):
        let q = built.faces[qi]
        if q.texture != f.texture or (qi, qk) in seen: continue
        if not q.verts.allIt(cornerKey(built.points[it]) in own): continue
        seen.incl (qi, qk)
        for m in layers: recs.add (qi, qk, m)
  var data = newStringOfCap(12 + recs.len * 40)
  proc put32(v: uint32) =
    for b in 0 .. 3: data.add char((v shr (8 * b)) and 255)
  put32 0x4c565743'u32   # "CWVL"
  put32 8
  put32 recs.len.uint32
  for r in recs:
    let m = r.m
    let c = built.faces[r.quad].colors[r.corner]
    put32 r.quad.uint32
    data.add char(r.corner)
    data.add char(m.mode.ord)
    data.add char(m.interp.ord)
    data.add '\0'
    put32 0xff000000'u32 or (c[0].uint32 shl 16) or (c[1].uint32 shl 8) or c[2].uint32
    put32 0xff000000'u32 or (m.color[0].uint32 shl 16) or (m.color[1].uint32 shl 8) or m.color[2].uint32
    put32 cast[uint32](max(m.period, 0.01'f32))
    put32 cast[uint32](m.offset)
    put32 cast[uint32](clamp(m.low, 0, 1))
    put32 cast[uint32](clamp(m.high, 0, 1))
    put32 cast[uint32](clamp(m.stability, 0, 1))
    put32 cast[uint32](max(m.faultLen, 0))
    put32 m.seed
  put32 events.len.uint32
  for e in events:
    put32 e.mode.ord.uint32
    for v in [e.period, e.offset, e.stability, e.fault, e.pitch, e.volume, e.pos.x, e.pos.y, e.pos.z]:
      put32 cast[uint32](v)
    put32 e.positional.uint32
    for i in 0 ..< 32: data.add (if i < min(e.sound.len, 31): e.sound[i] else: '\0')
    put32 cast[uint32](e.pitchMax)
    put32 e.seed
    put32 e.soundObject.uint32
    put32 e.light.uint32
  writeFile(path, data)
  recs.len

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
