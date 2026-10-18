## The map views: layout (with draggable dividers), rendering of overlays
## (objects, selection, tool feedback, grids, labels), camera navigation, the
## editing tools and their mouse and keyboard input.
##
## Input follows TrenchBroom's tool chain: a left press is a click until the
## mouse moves 2 pixels, then a drag; drags shorter than 0.1 s are dropped.
## With no modal tool active, a click selects, a drag on the selection moves
## it (Ctrl duplicates), Shift+drag on a selected brush's face extrudes it (and the selection's faces on its plane),
## Ctrl+drag paints a selection and a drag anywhere else with nothing selected
## draws a new brush. Modal tools (brush, vertex/edge/face, clip, rotate,
## scale) switch the moving, extruding and drawing off while they are active.

import std/[strutils, strformat, math, tables, sets, algorithm, sequtils, times, hashes]
import silky, vmath, bumpy, pixie
import theme, ui, menutree
import levelobjects, camera, render, geometry, geomops, appstate, presets, library

const
  ViewHeader* = 22'f32
  SplitW* = 8'f32           ## Thickness of the dividers between panes.
  DragThreshold = 2'f32     ## Pixels a press moves before it becomes a drag.
  MinDragTime = 0.1         ## Shorter drags are accidental and undone.
  HandleRadius = 7'f32
  RotateRingPx = 64'f32     ## Rotate tool ring radius on screen.

type
  Mods* = tuple[c, s, al: bool]

proc mods*(a: App): Mods = (a.window.ctrl, a.window.shiftDown, a.window.alt)
proc none(m: Mods): bool = not (m.c or m.s or m.al)
proc only(m: Mods, c = false, s = false, al = false): bool = m.c == c and m.s == s and m.al == al

proc pm*(r, g, b: int, a = 255): ColorRGBX =
  ## Premultiplied UI color.
  rgbx(uint8(r * a div 255), uint8(g * a div 255), uint8(b * a div 255), uint8(a))

# --- layout -------------------------------------------------------------------------------

proc splitFractions(a: App): (float32, float32) =
  (clamp(if a.splitX > 0: a.splitX else: 0.55'f32, 0.1, 0.9),
   clamp(if a.splitY > 0: a.splitY else: 0.5'f32, 0.1, 0.9))

proc layoutViews*(a: App, area: Rect) =
  for i in 0 .. 3: a.views[i].rect = rect(0, 0, 0, 0)
  if a.maximized >= 0:
    a.views[a.maximized].rect = area
    return
  let (sx, sy) = a.splitFractions
  let lw = floor(area.w * sx)
  let th = floor(area.h * sy)
  let h2 = SplitW / 2
  case a.layout
  of pl1: a.views[0].rect = area
  of pl2:
    a.views[0].rect = rect(area.x, area.y, lw - h2, area.h)
    a.views[1].rect = rect(area.x + lw + h2, area.y, area.w - lw - h2, area.h)
  of pl3:
    a.views[0].rect = rect(area.x, area.y, lw - h2, area.h)
    a.views[1].rect = rect(area.x + lw + h2, area.y, area.w - lw - h2, th - h2)
    a.views[2].rect = rect(area.x + lw + h2, area.y + th + h2, area.w - lw - h2, area.h - th - h2)
  of pl4:
    a.views[0].rect = rect(area.x, area.y, lw - h2, th - h2)
    a.views[1].rect = rect(area.x + lw + h2, area.y, area.w - lw - h2, th - h2)
    a.views[2].rect = rect(area.x, area.y + th + h2, lw - h2, area.h - th - h2)
    a.views[3].rect = rect(area.x + lw + h2, area.y + th + h2, area.w - lw - h2, area.h - th - h2)

proc viewDividers*(a: App, area: Rect): seq[tuple[id: string, r: Rect, vertical: bool]] =
  ## The draggable gaps between panes. vertical: a vertical bar dragged sideways.
  if a.maximized >= 0 or a.layout == pl1: return
  let (sx, sy) = a.splitFractions
  let lw = floor(area.w * sx)
  let th = floor(area.h * sy)
  result.add ("view.x", rect(area.x + lw - SplitW / 2, area.y, SplitW, area.h), true)
  case a.layout
  of pl3: result.add ("view.y", rect(area.x + lw + SplitW / 2, area.y + th - SplitW / 2,
                                      area.w - lw - SplitW / 2, SplitW), false)
  of pl4: result.add ("view.y", rect(area.x, area.y + th - SplitW / 2, area.w, SplitW), false)
  else: discard

proc viewAt*(a: App, p: Vec2): int =
  for i in 0 .. 3:
    if a.views[i].rect.w > 1 and p.inside(a.views[i].viewBody): return i
  -1

proc is3D(a: App, vi: int): bool = a.views[vi].cam.kind == vk3D

proc toScreen(a: App, vi: int, p: Vec3): (bool, Vec2) =
  let v = a.views[vi]
  let b = v.viewBody
  let (ok, q) = v.cam.project(p, b.w, b.h)
  (ok, q + b.xy)

proc axisName(v: Vec3): string =
  if abs(v.x) > 0.5: "X" elif abs(v.y) > 0.5: "Y" else: "Z"

proc axisIndex(v: Vec3): int =
  if abs(v.x) >= abs(v.y) and abs(v.x) >= abs(v.z): 0
  elif abs(v.y) >= abs(v.z): 1
  else: 2

proc axisColor(i: int): array[4, uint8] =
  case i
  of 0: rgba(235, 80, 70)
  of 1: rgba(110, 210, 90)
  else: rgba(80, 140, 255)

proc toUi(c: array[4, uint8]): ColorRGBX = pm(c[0].int, c[1].int, c[2].int, c[3].int)

# --- picking --------------------------------------------------------------------------------

type Cand* = object
  ## Something under the mouse: an object (possibly through geometry it owns)
  ## or a geometry piece, with the face hit and its distance.
  obj*: LevelObject
  piece*: int32
  face*: int
  t*: float32
  area*: float32
  point*: Vec3

proc hash(o: LevelObject): Hash = hash(cast[pointer](o))

proc found*(c: Cand): bool = c.obj != nil or c.piece >= 0
proc noCand(): Cand = Cand(piece: -1, face: -1, t: Inf.float32)

proc projectedArea(a: App, vi: int, lo, hi: Vec3): float32 =
  let ax = a.views[vi].cam.kind.axes
  let d = hi - lo
  abs(d.dot(ax.right)) * abs(d.dot(ax.up))

proc candidates*(a: App, vi: int, mouse: Vec2): seq[Cand] =
  ## Everything under the mouse, nearest first.
  if a.proj == nil: return
  let r = a.viewRay(vi, mouse)
  var byObj: Table[LevelObject, int]
  for o in a.objects:
    if not a.pickable(o): continue
    let (lo, hi) = o.pickBox
    let t = r.rayBox(lo, hi)
    if t >= 0:
      byObj[o] = result.len
      result.add Cand(obj: o, piece: -1, face: -1, t: t, area: a.projectedArea(vi, lo, hi))
  if a.geometryVisible:
    var byPiece: Table[int32, int]
    let hittable = a.facePickable
    for i, f in a.geo.faces:
      if f.verts.len < 3 or not hittable(i): continue
      let p0 = a.geo.points[f.verts[0]]
      var t = Inf.float32
      for k in 1 ..< f.verts.len - 1:
        let tt = r.rayTriangle(p0, a.geo.points[f.verts[k]], a.geo.points[f.verts[k + 1]])
        if tt >= 0 and tt < t: t = tt
      if t == Inf.float32: continue
      let owner = a.ownerOf(f.objectId)
      if owner != nil:
        if not a.pickable(owner): continue
        if owner in byObj:
          let k = byObj[owner]
          if t < result[k].t:
            result[k].t = t
            result[k].face = i
        else:
          byObj[owner] = result.len
          let (lo, hi) = owner.pickBox
          result.add Cand(obj: owner, piece: -1, face: i, t: t, area: a.projectedArea(vi, lo, hi))
      elif a.geometryEditable:
        if f.piece in byPiece:
          let k = byPiece[f.piece]
          if t < result[k].t:
            result[k].t = t
            result[k].face = i
        else:
          byPiece[f.piece] = result.len
          result.add Cand(piece: f.piece, face: i, t: t)
    # Pieces' areas (for 2D picking) from their bounds.
    if not a.is3D(vi) and byPiece.len > 0:
      var lo = newSeq[Vec3](result.len)
      var hi = newSeq[Vec3](result.len)
      for k in 0 ..< result.len:
        lo[k] = vec3(Inf.float32)
        hi[k] = vec3(-Inf.float32)
      for f in a.geo.faces:
        if f.piece in byPiece:
          let k = byPiece[f.piece]
          for v in f.verts:
            lo[k] = min(lo[k], a.geo.points[v])
            hi[k] = max(hi[k], a.geo.points[v])
      for pc, k in byPiece: result[k].area = a.projectedArea(vi, lo[k], hi[k])
  for c in result.mitems: c.point = r.origin + r.dir * c.t
  result.sort(proc(x, y: Cand): int = cmp(x.t, y.t))

proc pick*(a: App, vi: int, mouse: Vec2): Cand =
  ## TrenchBroom's choice: the nearest thing in 3D; in 2D the thing with the
  ## smallest area on the view plane, so occluded objects stay clickable.
  let cs = a.candidates(vi, mouse)
  if cs.len == 0: return noCand()
  if a.is3D(vi): return cs[0]
  result = cs[0]
  for c in cs:
    if c.area < result.area - 0.01: result = c

proc faceUnder*(a: App, vi: int, mouse: Vec2): (int, Vec3) =
  ## Frontmost editable geometry face under the mouse (faces, not objects).
  result = (-1, vec3(0, 0, 0))
  if not a.geometryEditable: return
  let r = a.viewRay(vi, mouse)
  let (fi, t) = a.geo.pickFace(r, a.facePickable)
  if fi >= 0: result = (fi, r.origin + r.dir * t)

proc isSelected(a: App, c: Cand): bool =
  if c.obj != nil: c.obj.selected else: c.piece in a.selPieces

# --- selection helpers ------------------------------------------------------------------------

proc selectCand(a: App, c: Cand, on = true) =
  if c.obj != nil: c.obj.selected = on
  elif c.piece >= 0:
    if on: a.selPieces.incl c.piece else: a.selPieces.excl c.piece

proc hasNodeSelection*(a: App): bool = a.selPieces.len > 0 or a.selection.len > 0

proc convertToFaces(a: App) =
  ## Selected pieces become their faces (objects are dropped).
  if a.geo != nil:
    for i, f in a.geo.faces:
      if f.piece in a.selPieces: a.selFaces.incl i
  a.selPieces.clear()
  for o in a.objects: o.selected = false

proc worldPieces(a: App): HashSet[int32] =
  if a.geo == nil: return
  for f in a.geo.faces:
    if f.objectId == -1 and not a.geo.pieces[f.piece].hidden: result.incl f.piece

proc updateLastSelection*(a: App) =
  ## New brushes in 2D views take their depth from the latest selection.
  let (ok, lo, hi) = a.selectionBounds
  if ok: a.lastSel = (true, lo, hi)

proc referenceBounds(a: App): (Vec3, Vec3) =
  if a.lastSel.ok: (a.lastSel.lo, a.lastSel.hi)
  else: (vec3(a.focus2D.x, 0, a.focus2D.z), vec3(a.focus2D.x, a.brushHeight.float32, a.focus2D.z))

# --- handles (vertex / edge / face tools) ---------------------------------------------------

type Handle* = object
  id*: string
  pos*: Vec3
  corners*: seq[Vec3]    ## Positions the handle moves.

proc pkey*(p: Vec3): string =
  $int(round(p.x * 16)) & "," & $int(round(p.y * 16)) & "," & $int(round(p.z * 16))

proc handleId(tool: Tool, corners: seq[Vec3]): string =
  case tool
  of toolVertex: "v" & pkey(corners[0])
  of toolEdge:
    let (k1, k2) = (pkey(corners[0]), pkey(corners[1]))
    "e" & min(k1, k2) & "|" & max(k1, k2)
  else:
    var ks = corners.mapIt(pkey(it))
    ks.sort
    "f" & ks.join("|")

var handleCache: tuple[frame, version, sel: int, tool: Tool, hs: seq[Handle]]

proc handles*(a: App): seq[Handle] =
  ## Handles of the selected pieces (and faces). Corners at the same position
  ## share one handle, so pieces that touch are edited together.
  if a.geo == nil or a.tool notin {toolVertex, toolEdge, toolFace}: return
  let selKey = a.selPieces.len * 100003 + a.selFaces.len
  if handleCache.frame == a.frameNo and handleCache.version == a.geo.version and
     handleCache.sel == selKey and handleCache.tool == a.tool:
    return handleCache.hs
  var seen: HashSet[string]
  for fi in a.selectedFaceSet:
    let f = a.geo.faces[fi]
    let ps = f.verts.mapIt(a.geo.points[it])
    case a.tool
    of toolVertex:
      for p in ps:
        let id = handleId(toolVertex, @[p])
        if id notin seen:
          seen.incl id
          result.add Handle(id: id, pos: p, corners: @[p])
    of toolEdge:
      for k in 0 ..< ps.len:
        let c = @[ps[k], ps[(k + 1) mod ps.len]]
        let id = handleId(toolEdge, c)
        if id notin seen:
          seen.incl id
          result.add Handle(id: id, pos: (c[0] + c[1]) / 2, corners: c)
    else:
      let id = handleId(toolFace, ps)
      if id notin seen:
        seen.incl id
        var c = vec3(0, 0, 0)
        for p in ps: c += p
        result.add Handle(id: id, pos: c / ps.len.float32, corners: ps)
  handleCache = (a.frameNo, a.geo.version, selKey, a.tool, result)

proc handleAt*(a: App, vi: int, mouse: Vec2): string =
  var best = HandleRadius
  for h in a.handles:
    let (ok, p) = a.toScreen(vi, h.pos)
    if not ok: continue
    let d = (p - mouse).length
    if d < best:
      best = d
      result = h.id

proc handleById(a: App, id: string): Handle =
  for h in a.handles:
    if h.id == id: return h

proc selectedCornerKeys(a: App): HashSet[string] =
  for h in a.handles:
    if h.id in a.selHandles:
      for c in h.corners: result.incl pkey(c)

proc pointsAtKeys(a: App, faces: HashSet[int], keys: HashSet[string]): HashSet[int32] =
  for fi in faces:
    for v in a.geo.faces[fi].verts:
      if pkey(a.geo.points[v]) in keys: result.incl v

# --- tool geometry: clip plane, rotate and scale handles ---------------------------------------

proc clipPlane*(a: App): (bool, Plane) =
  if a.clipPoints.len < 2: return (false, Plane())
  if a.clipPoints.len == 2:
    let cam = a.views[clamp(a.clipView, 0, 3)].cam
    let viewDir = if cam.kind == vk3D: cam.forward else: cam.kind.axes.toViewer
    let n = (a.clipPoints[1] - a.clipPoints[0]).cross(viewDir)
    if n.length < 1e-4: return (false, Plane())
    return (true, plane(n.normalize, a.clipPoints[0]))
  let n = (a.clipPoints[1] - a.clipPoints[0]).cross(a.clipPoints[2] - a.clipPoints[0])
  if n.length < 1e-4: return (false, Plane())
  (true, plane(n.normalize, a.clipPoints[0]))

proc resetRotateCenter*(a: App) =
  let (ok, lo, hi) = a.selectionBounds
  if ok: a.rotCenter = a.snapV((lo + hi) / 2)
  a.rotCenterText = &"{a.rotCenter.x:g} {a.rotCenter.y:g} {a.rotCenter.z:g}"

proc ringRadius(a: App, vi: int): float32 =
  ## World radius of the rotate ring so it is RotateRingPx on screen.
  let cam = a.views[vi].cam
  if cam.kind != vk3D: return RotateRingPx / max(cam.zoom, 1e-4)
  let b = a.views[vi].viewBody
  let d = max((a.rotCenter - cam.pos).dot(cam.forward), 1)
  RotateRingPx * 2 * d * tan(cam.fovY / 2) / max(b.h, 1)

proc ringPoints(a: App, vi: int, axis: int): seq[Vec3] =
  let r = a.ringRadius(vi)
  var u, v: Vec3
  case axis
  of 0: (u, v) = (vec3(0, 1, 0), vec3(0, 0, 1))
  of 1: (u, v) = (vec3(1, 0, 0), vec3(0, 0, 1))
  else: (u, v) = (vec3(1, 0, 0), vec3(0, 1, 0))
  for k in 0 .. 64:
    let t = k.float32 / 64 * 2 * PI
    result.add a.rotCenter + (u * cos(t) + v * sin(t)) * r

proc segDist(p, a, b: Vec2): float32 =
  let d = b - a
  let l2 = d.dot(d)
  if l2 < 1e-6: return (p - a).length
  let t = clamp((p - a).dot(d) / l2, 0, 1)
  (p - (a + d * t)).length

proc rotateHandleAt(a: App, vi: int, m: Vec2): string =
  ## "center", "ring0".."ring2" or "".
  let (ok, c) = a.toScreen(vi, a.rotCenter)
  if not ok: return
  if (m - c).length < 8: return "center"
  let cam = a.views[vi].cam
  if cam.kind != vk3D:
    if abs((m - c).length - RotateRingPx) < 6: return "ring" & $axisIndex(cam.kind.axes.toViewer)
    return
  var best = 6'f32
  for axis in 0 .. 2:
    let pts = a.ringPoints(vi, axis)
    for k in 0 ..< pts.len - 1:
      let (ok1, p1) = a.toScreen(vi, pts[k])
      let (ok2, p2) = a.toScreen(vi, pts[k + 1])
      if ok1 and ok2:
        let d = segDist(m, p1, p2)
        if d < best:
          best = d
          result = "ring" & $axis

proc scaleHandles(a: App, vi: int): seq[tuple[sides: Vec3, pos: Vec3]] =
  ## Corners, edge middles and side middles of the selection bounds. 2D views
  ## only get the ones on their view plane.
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  let c = (lo + hi) / 2
  let half = (hi - lo) / 2
  let cam = a.views[vi].cam
  let depth = if cam.kind == vk3D: -1 else: axisIndex(cam.kind.axes.toViewer)
  for x in -1 .. 1:
    for y in -1 .. 1:
      for z in -1 .. 1:
        let s = vec3(x.float32, y.float32, z.float32)
        if s == vec3(0, 0, 0): continue
        if depth >= 0 and s[depth] != 0: continue
        result.add (s, c + vec3(s.x * half.x, s.y * half.y, s.z * half.z))

proc scaleHandleAt(a: App, vi: int, m: Vec2): (bool, Vec3) =
  var best = 8'f32
  for (s, p) in a.scaleHandles(vi):
    let (ok, q) = a.toScreen(vi, p)
    if not ok: continue
    let d = (q - m).length
    if d < best:
      best = d
      result = (true, s)
  if result[0] or a.is3D(vi): return
  # 2D: anywhere along a side of the box works too.
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  let ax = a.views[vi].cam.kind.axes
  let (r, u) = (axisIndex(ax.right), axisIndex(ax.up))
  let (o1, p1) = a.toScreen(vi, lo)
  let (o2, p2) = a.toScreen(vi, hi)
  if not (o1 and o2): return
  let (x0, x1) = (min(p1.x, p2.x), max(p1.x, p2.x))
  let (y0, y1) = (min(p1.y, p2.y), max(p1.y, p2.y))
  if m.y >= y0 and m.y <= y1:
    if abs(m.x - x0) < 5: (result[0], result[1][r]) = (true, (if p1.x < p2.x: -1'f32 else: 1'f32))
    elif abs(m.x - x1) < 5: (result[0], result[1][r]) = (true, (if p1.x < p2.x: 1'f32 else: -1'f32))
  if m.x >= x0 and m.x <= x1:
    if abs(m.y - y0) < 5: (result[0], result[1][u]) = (true, (if p1.y < p2.y: -1'f32 else: 1'f32))
    elif abs(m.y - y1) < 5: (result[0], result[1][u]) = (true, (if p1.y < p2.y: 1'f32 else: -1'f32))

# --- extrusion targets ---------------------------------------------------------------------------

proc raySegDist(r: Ray, p, q: Vec3): float32 =
  ## Shortest distance between the ray and the segment p..q (world units).
  let d = q - p
  let w0 = p - r.origin
  let (aa, b, dd, e) = (d.dot(d), d.dot(r.dir), d.dot(w0), r.dir.dot(w0))
  let denom = aa - b * b
  var s = if aa < 1e-9 or denom < 1e-9: 0'f32 else: clamp((b * e - dd) / denom, 0, 1)
  var t = e + s * b
  if t < 0:
    t = 0
    s = if aa < 1e-9: 0'f32 else: clamp(-dd / aa, 0, 1)
  (p + d * s - (r.origin + r.dir * t)).length

proc extrudeFaceAt*(a: App, vi: int, m: Vec2): int =
  ## The selected piece's face Shift+drag would move: the one under the mouse,
  ## else the hidden face behind the horizon edge nearest the mouse ray, however
  ## far (TrenchBroom's ExtrudeTool). A horizon edge joins a face seen from the
  ## front and one that isn't; in 2D views, where the mouse is over the selection,
  ## only an edge within a few pixels counts, as the mouse there moves the piece.
  result = -1
  if a.geo == nil or a.selPieces.len == 0: return
  let cam = a.views[vi].cam
  let r = a.viewRay(vi, m)
  var cands: seq[int]
  for i, f in a.geo.faces:
    if f.piece in a.selPieces and f.objectId == -1 and f.verts.len >= 3: cands.add i
  if cands.len == 0 or cands.len > 4000: return
  var over = false
  var bestT = Inf.float32
  for fi in cands:
    let f = a.geo.faces[fi]
    let p0 = a.geo.points[f.verts[0]]
    for k in 1 ..< f.verts.len - 1:
      let t = r.rayTriangle(p0, a.geo.points[f.verts[k]], a.geo.points[f.verts[k + 1]])
      if t >= 0 and t < bestT:
        bestT = t
        result = fi
  if result >= 0:
    if cam.kind == vk3D: return
    over = true
    result = -1
  # Each piece's edges with the faces on them (matched by position: faces may not share points).
  var edges: Table[(int32, string, string), seq[int]]
  var ends: Table[(int32, string, string), (Vec3, Vec3)]
  for fi in cands:
    let f = a.geo.faces[fi]
    for k in 0 ..< f.verts.len:
      let (p, q) = (a.geo.points[f.verts[k]], a.geo.points[f.verts[(k + 1) mod f.verts.len]])
      let (kp, kq) = (pkey(p), pkey(q))
      if kp == kq: continue
      let key = if kp < kq: (f.piece, kp, kq) else: (f.piece, kq, kp)
      edges.mgetOrPut(key, @[]).add fi
      ends[key] = (p, q)
  var dots: Table[int, float32]
  for fi in cands: dots[fi] = a.geo.normal(a.geo.faces[fi]).dot(r.dir)
  var best = Inf.float32
  for key, fs in edges:
    # The face to drag: the hidden one of a horizon pair, or, at an edge only one
    # face has, that face when it isn't seen from the front.
    var drag = -1
    if fs.len == 1:
      let dt = dots[fs[0]]
      if (cam.kind == vk3D and dt >= 0) or (cam.kind != vk3D and abs(dt) < 0.9): drag = fs[0]
    else:
      for i in 0 ..< fs.len:
        for j in i + 1 ..< fs.len:
          let (di, dj) = (dots[fs[i]], dots[fs[j]])
          if (di < 0) != (dj < 0): drag = (if di > dj: fs[i] else: fs[j])
    if drag < 0: continue
    let (p, q) = ends[key]
    var d: float32
    if over:
      let (o1, p1) = a.toScreen(vi, p)
      let (o2, p2) = a.toScreen(vi, q)
      if not (o1 and o2): continue
      d = segDist(m, p1, p2)
      if d >= 8: continue
    else:
      d = r.raySegDist(p, q)
    if d < best:
      best = d
      result = drag

proc extrudeGroup*(a: App, fi: int): seq[int] =
  ## fi and the selected pieces' faces on its plane and facing the same way:
  ## Shift+drag on one of them moves them all (TrenchBroom). fi comes first.
  ## A piece that isn't a brush only moves the face itself when it is fi's own.
  result = @[fi]
  let f0 = a.geo.faces[fi]
  let pl = a.geo.facePlane(f0)
  for i, f in a.geo.faces:
    if i == fi or f.piece notin a.selPieces or f.objectId != -1 or f.verts.len < 3: continue
    if f.piece == f0.piece and not a.geo.pieces[f.piece].brush: continue
    let q = a.geo.facePlane(f)
    if q.n.dot(pl.n) > 0.9999 and abs(q.d - pl.d) < 0.1: result.add i

proc pieceCornerKeys(a: App, fi: int): HashSet[string] =
  for v in a.geo.faces[fi].verts: result.incl pkey(a.geo.points[v])

proc pieceFaceIds(g: Geometry, pc: int32): seq[int] =
  for i, f in g.faces:
    if f.piece == pc: result.add i

proc piecePoints(g: Geometry, pc: int32): seq[Vec3] =
  for f in g.faces:
    if f.piece == pc:
      for v in f.verts: result.add g.points[v]

proc planeOfFace(g: Geometry, planes: seq[Plane], fi: int): int =
  let pl = g.facePlane(g.faces[fi])
  result = -1
  var best = 0.99'f32
  for i, q in planes:
    let d = q.n.dot(pl.n)
    if d > best and abs(q.d - pl.d) < 1:
      best = d
      result = i

# --- shapes -------------------------------------------------------------------------------------

proc shapeSolids*(shape: ShapeKind, lo, hi: Vec3, sides: int, steps: int, dir: Vec3): seq[seq[Plane]] =
  ## Brushes for the shape tool, filling the box lo..hi (Y is up).
  case shape
  of shCuboid: result.add boxPlanes(lo, hi)
  of shCylinder, shCone:
    let n = clamp(sides, 3, 64)
    let c = (lo + hi) / 2
    let (rx, rz) = ((hi.x - lo.x) / 2, (hi.z - lo.z) / 2)
    var ring: seq[Vec3]
    for k in 0 ..< n:
      let t = (k.float32 + 0.5) / n.float32 * 2 * PI
      ring.add vec3(c.x + rx * cos(t), lo.y, c.z + rz * sin(t))
    var planes = @[plane(vec3(0, -1, 0), lo)]
    if shape == shCylinder: planes.add plane(vec3(0, 1, 0), hi)
    let apex = vec3(c.x, hi.y, c.z)
    for k in 0 ..< n:
      let (p, q) = (ring[k], ring[(k + 1) mod n])
      var nn = if shape == shCylinder: (q - p).cross(vec3(0, 1, 0)) else: (q - p).cross(apex - p)
      if nn.dot((p + q) / 2 - vec3(c.x, (p.y + q.y) / 2, c.z)) < 0: nn = -nn
      if nn.length > 1e-5: planes.add plane(nn.normalize, p)
    result.add planes
  of shStairs:
    let n = clamp(steps, 1, 64)
    # Steps climb along the longer horizontal side, toward where the drag went.
    let along = if hi.x - lo.x >= hi.z - lo.z: 0 else: 2
    let up = dir[along] >= 0
    let len = hi[along] - lo[along]
    let h = hi.y - lo.y
    for i in 0 ..< n:
      var l = lo
      var u = hi
      u.y = lo.y + h * (i + 1).float32 / n.float32
      if up:
        l[along] = lo[along] + len * i.float32 / n.float32
        u[along] = lo[along] + len * (i + 1).float32 / n.float32
      else:
        l[along] = hi[along] - len * (i + 1).float32 / n.float32
        u[along] = hi[along] - len * i.float32 / n.float32
      result.add boxPlanes(l, u)

# --- overlays ----------------------------------------------------------------------------------

var clipCache: tuple[key: string, lines: seq[(Vec3, Vec3)]]

proc clipPreview(a: App): seq[(Vec3, Vec3)] =
  ## Outlines of what the clip would keep.
  let (ok, pl) = a.clipPlane
  if not ok or a.selPieces.len == 0 or a.geo == nil: return
  let key = &"{a.geo.version}|{a.clipPoints}|{a.clipSide}|{a.selPieces.len}"
  if key == clipCache.key: return clipCache.lines
  let g = a.geo.clone
  g.clipPieces(a.selPieces, pl, a.clipSide, a.newFaceAttr, proc(t: string): float32 = 64)
  var lines: seq[(Vec3, Vec3)]
  # Welding and compacting may renumber pieces, so find the new faces by
  # comparing with the untouched ones.
  var untouched: HashSet[string]
  for f in a.geo.faces:
    if f.piece notin a.selPieces:
      untouched.incl f.verts.mapIt(pkey(a.geo.points[it])).join(";")
  for f in g.faces:
    if f.verts.mapIt(pkey(g.points[it])).join(";") in untouched: continue
    for k in 0 ..< f.verts.len:
      lines.add (g.points[f.verts[k]], g.points[f.verts[(k + 1) mod f.verts.len]])
  clipCache = (key, lines)
  lines

proc drawExtent(a: App): (Vec3, Vec3) = a.drag.extent

proc buildOverlays*(a: App) =
  let r = a.rend
  r.lines.setLen 0
  r.tris.setLen 0
  r.overlayLines.setLen 0
  r.modelInstances.setLen 0
  if modelsChanged(): r.clearModels()
  for o in a.objects:
    if not a.visible(o): continue
    let l = o.look
    let k = o.corners
    # Objects with a model show it inside a plain box, like TrenchBroom.
    let (hasModel, model) = if a.opts.models: o.objectModel else: (false, ObjectModel())
    if hasModel:
      let t = objectMatrix(o.pos, o.rot)
      for part in model.parts:
        r.modelInstances.add ModelInstance(path: model.path, base: libraryDir(),
          transform: cast[M4](t * part),
          tint: (if o.selected: vec4(1, 0.6, 0.6, 1) else: vec4(1, 1, 1, 1)),
          wire: (if o.selected: rgba(255, 110, 110, 200) else: [l.col[0], l.col[1], l.col[2], 120'u8]))
    if o.selected:
      if not hasModel: r.tris.solidBox(k, rgba(255, 60, 60, 70))
      r.overlayLines.wireBox(k, rgba(255, 70, 70))
    else:
      if not hasModel: r.tris.solidBox(k, [l.col[0], l.col[1], l.col[2], 70'u8])
      r.lines.wireBox(k, (if hasModel: [l.col[0], l.col[1], l.col[2], 150'u8] else: l.col))
    if o.tag in ["CHAR", "NEUT", "FLAG", "TURR"]:
      let ang = o.rot.y.float64.degToRad
      let fwd = vec3(sin(ang).float32, 0, cos(ang).float32)
      let base = o.pos + vec3(0, l.lift, 0)
      if o.selected: r.overlayLines.line(base, base + fwd * 14, rgba(255, 70, 70))
      else: r.lines.line(base, base + fwd * 14, l.col)
    let (has, lo, hi) = o.extentBox
    if has and (o.selected or o.tag == "TRGV"):
      let half = (hi - lo) / 2
      let kk = boxCorners((lo + hi) / 2, vec3(abs(half.x), abs(half.y), abs(half.z)), 0)
      if o.selected: r.overlayLines.wireBox(kk, rgba(255, 70, 70))
      else: r.lines.wireBox(kk, [l.col[0], l.col[1], l.col[2], 110'u8])
    if o.selected and a.geo != nil and o.objectCode != -1:
      for fi in a.geo.objectFaces(o.objectCode):
        r.tris.faceFill(a.geo, a.geo.faces[fi], rgba(255, 60, 60, 60))
  if a.geo != nil:
    for i, f in a.geo.faces:
      if f.piece in a.selPieces:
        r.tris.faceFill(a.geo, f, rgba(255, 60, 60, 60))
        r.overlayLines.faceOutline(a.geo, f, rgba(255, 70, 70))
      elif i in a.selFaces:
        r.tris.faceFill(a.geo, f, rgba(255, 60, 60, 110))
        r.overlayLines.faceOutline(a.geo, f, rgba(255, 110, 110))
    for fi in a.extrudeHoverFaces:
      if fi < a.geo.faces.len:
        r.overlayLines.faceOutline(a.geo, a.geo.faces[fi], rgba(255, 220, 40))
    if a.drag.kind in {dkExtrude, dkSlide, dkSplit, dkStamp} and a.drag.face >= 0 and
       a.drag.face < a.geo.faces.len:
      r.overlayLines.faceOutline(a.geo, a.geo.faces[a.drag.face], rgba(255, 220, 40))
  # Selection guide in 3D: the bounds' edges extended (TrenchBroom's spikes).
  let (sok, slo, shi) = a.selectionBounds
  let guide = sok and (a.drag.kind in {dkMove, dkHandles, dkScale} or
              (a.hoverView >= 0 and a.is3D(a.hoverView) and
               a.isSelected(a.pick(a.hoverView, a.ui.mouse))))
  if guide:
    let c = (slo + shi) / 2
    r.lines.wireBox(boxCorners(c, (shi - slo) / 2, 0), rgba(255, 60, 60, 160))
    for k in boxCorners(c, (shi - slo) / 2, 0):
      for i in 0 .. 2:
        var d = vec3(0, 0, 0)
        d[i] = (if k[i] >= c[i]: 1'f32 else: -1'f32)
        r.lines.line(k, k + d * 4000, rgba(255, 60, 60, 60))
  # Tool feedback.
  case a.drag.kind
  of dkDraw:
    let (lo, hi) = a.drawExtent
    let dir = a.drag.axis
    for planes in shapeSolids(a.shape, lo, hi, a.shapeSides.int, a.shapeSteps.int, dir):
      for (_, poly) in solidFromPlanes(planes):
        for k in 0 ..< poly.len:
          r.overlayLines.line(poly[k], poly[(k + 1) mod poly.len], rgba(120, 200, 255))
  of dkMove, dkHandles:
    if a.drag.moved:
      r.overlayLines.line(a.drag.startWorld, a.drag.startWorld + a.drag.lastDelta, rgba(255, 220, 40))
  else: discard
  if a.tool == toolClip:
    for p in a.clipPoints:
      r.overlayLines.wireBox(boxCorners(p, vec3(1.5, 1.5, 1.5), 0), rgba(255, 150, 40))
    for i in 1 ..< a.clipPoints.len:
      r.overlayLines.line(a.clipPoints[i - 1], a.clipPoints[i], rgba(255, 150, 40))
    for (p, q) in a.clipPreview: r.overlayLines.line(p, q, rgba(120, 255, 160))
  if a.tool == toolBrush and a.assemblePoints.len > 0:
    for p in a.assemblePoints:
      r.overlayLines.wireBox(boxCorners(p, vec3(1.5, 1.5, 1.5), 0), rgba(120, 200, 255))
    var pts = a.assemblePoints
    if a.drag.kind in {dkAssembleRect, dkAssembleDup}: pts.add a.drag.corners
    let planes = hullPlanes(pts)
    if planes.len > 0:
      for (_, poly) in solidFromPlanes(planes):
        for k in 0 ..< poly.len:
          r.overlayLines.line(poly[k], poly[(k + 1) mod poly.len], rgba(120, 200, 255))
    else:
      for i in 0 ..< pts.len:
        r.overlayLines.line(pts[i], pts[(i + 1) mod pts.len], rgba(120, 200, 255))
  elif a.drag.kind == dkAssembleRect:
    let c = a.drag.corners
    for i in 0 ..< c.len: r.overlayLines.line(c[i], c[(i + 1) mod c.len], rgba(120, 200, 255))
  if a.tool == toolScale and sok:
    r.overlayLines.wireBox(boxCorners((slo + shi) / 2, (shi - slo) / 2, 0), rgba(160, 140, 255))

proc buildGrid(a: App, vi: int, body: Rect) =
  let r = a.rend
  r.gridLines.setLen 0
  let cam = a.views[vi].cam
  if cam.kind == vk3D or not a.showGrid: return
  let ax = cam.kind.axes
  var g = a.grid
  while g * cam.zoom < 6: g *= 2
  let lo = cam.pixelToPlane(0, body.h, body.w, body.h)
  let hi = cam.pixelToPlane(body.w, 0, body.w, body.h)
  let minor = rgba(255, 255, 255, 14)
  let major = rgba(255, 255, 255, 34)
  proc axisCol(dir: Vec3): array[4, uint8] =
    let c = axisColor(axisIndex(dir))
    [c[0], c[1], c[2], 130'u8]
  var x = floor(lo.x / g) * g
  while x <= hi.x:
    let col = if abs(x) < 0.001: axisCol(ax.up) elif abs(x / (g * 8) - round(x / (g * 8))) < 0.001: major else: minor
    r.gridLines.line(ax.right * x + ax.up * lo.y, ax.right * x + ax.up * hi.y, col)
    x += g
  var y = floor(lo.y / g) * g
  while y <= hi.y:
    let col = if abs(y) < 0.001: axisCol(ax.right) elif abs(y / (g * 8) - round(y / (g * 8))) < 0.001: major else: minor
    r.gridLines.line(ax.right * lo.x + ax.up * y, ax.right * hi.x + ax.up * y, col)
    y += g

proc drawViews*(a: App) =
  let s = a.sk.uiScale
  let fb = a.window.size
  if a.geo != nil and a.rend.geometryVersion != a.geo.version: a.refreshGeometry()
  a.buildOverlays()
  var opts = a.opts
  if not a.geometryVisible: opts.wireframe = false
  a.rend.grid3D = (if a.showGrid: a.grid else: 0)
  a.rend.setSky(if a.proj != nil: a.proj.sky else: "")
  for i in 0 .. 3:
    let v = a.views[i]
    if v.rect.w < 2: continue
    let b = v.viewBody
    a.buildGrid(i, b)
    let bg = if v.cam.kind == vk3D: vec4(0.05, 0.055, 0.065, 1) else: vec4(0.08, 0.085, 0.095, 1)
    a.rend.drawView(v.cam, int32(b.x * s), int32(b.y * s), int32(b.w * s), int32(b.h * s),
                    fb.y, bg, opts)
  endViews(fb.x, fb.y)

# --- UI-layer drawing helpers ------------------------------------------------------------------

proc uiLine*(ui: Ui, p, q: Vec2, col: ColorRGBX, w = 1.5'f32) =
  let d = q - p
  let l = d.length
  if l < 0.01: return
  let n = vec2(-d.y, d.x) / l * (w / 2)
  let e = ui.sk.atlas.entries[WhiteTileKey]
  let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
  ui.sk.drawTriangle([p + n, q + n, q - n], [uv, uv, uv], [col, col, col])
  ui.sk.drawTriangle([p + n, q - n, p - n], [uv, uv, uv], [col, col, col])

proc uiCircle*(ui: Ui, c: Vec2, r: float32, col: ColorRGBX, w = 1.5'f32, filled = false) =
  const n = 48
  for k in 0 ..< n:
    let t0 = k.float32 / n * 2 * PI
    let t1 = (k + 1).float32 / n * 2 * PI
    let p = c + vec2(cos(t0), sin(t0)) * r
    let q = c + vec2(cos(t1), sin(t1)) * r
    if filled:
      let e = ui.sk.atlas.entries[WhiteTileKey]
      let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
      ui.sk.drawTriangle([c, p, q], [uv, uv, uv], [col, col, col])
    else: ui.uiLine(p, q, col, w)

proc chip*(ui: Ui, s: string, at: Vec2, bg = pm(20, 22, 26, 225), fg = colText) =
  ## A small label box centered on at (TrenchBroom's measurement labels).
  let sz = ui.textSize(s, FontSmall) + vec2(10, 4)
  let r = rect((at - sz / 2).floor, sz)
  ui.rect(r, bg)
  ui.text(s, r.xy + vec2(5, 1), fg, FontSmall)

proc fmtNum*(v: float32): string =
  var s = formatFloat(v, ffDecimal, 2)
  s.trimZeros()
  if s.endsWith("."): s.setLen(s.len - 1)
  s

proc fmtVec*(v: Vec3): string = &"{fmtNum(v.x)} {fmtNum(v.y)} {fmtNum(v.z)}"

proc sizeLabels(a: App, vi: int, lo, hi: Vec3) =
  ## Width/height labels along the bounds (2D) or the three edge lengths (3D).
  let ui = a.ui
  let cam = a.views[vi].cam
  let size = hi - lo
  if cam.kind == vk3D:
    let c = (lo + hi) / 2
    for (axis, at) in [(0, vec3(c.x, lo.y, hi.z)), (1, vec3(lo.x, c.y, hi.z)), (2, vec3(hi.x, lo.y, c.z))]:
      let (ok, p) = a.toScreen(vi, at)
      if ok: ui.chip(["X", "Y", "Z"][axis] & ": " & fmtNum(size[axis]), p)
    return
  let ax = cam.kind.axes
  let (o1, p1) = a.toScreen(vi, lo)
  let (o2, p2) = a.toScreen(vi, hi)
  if not (o1 and o2): return
  let (x0, x1, y0, y1) = (min(p1.x, p2.x), max(p1.x, p2.x), min(p1.y, p2.y), max(p1.y, p2.y))
  let (ri, ui2) = (axisIndex(ax.right), axisIndex(ax.up))
  ui.chip(axisName(ax.right) & ": " & fmtNum(size[ri]), vec2((x0 + x1) / 2, y0 - 12))
  let t = axisName(ax.up) & ": " & fmtNum(size[ui2])
  ui.chip(t, vec2(x0 - ui.textSize(t, FontSmall).x / 2 - 12, (y0 + y1) / 2))

proc drawViewOverlays*(a: App) =
  ## View headers, handles, labels and the lasso (drawn by the UI layer).
  let ui = a.ui
  let (sok, slo, shi) = a.selectionBounds
  for i in 0 .. 3:
    let v = a.views[i]
    if v.rect.w < 2: continue
    let h = rect(v.rect.x, v.rect.y, v.rect.w, ViewHeader)
    let hot = a.hoverView == i
    ui.rect(h, if hot: colPanelRaised else: colPanel)
    ui.text($v.cam.kind, vec2(h.x + 8, h.y + 3), if hot: colText else: colTextDim, FontSmall)
    let b = v.viewBody
    if hot: ui.border(b, pm(157, 140, 255, 140))
    if a.proj == nil: continue
    ui.pushClip(b)
    let is3D = v.cam.kind == vk3D
    # Size of the selection: always in 2D, in 3D while hovering it or dragging.
    if sok and a.tool notin {toolVertex, toolEdge, toolFace} and
       (not is3D or a.drag.kind in {dkMove, dkScale} or
        (hot and a.isSelected(a.pick(i, ui.mouse)))):
      a.sizeLabels(i, slo, shi)
    # Handles of the vertex/edge/face tools.
    if a.tool in {toolVertex, toolEdge, toolFace}:
      let col = if a.tool == toolVertex: pm(255, 220, 40) else: pm(255, 220, 40)
      for hd in a.handles:
        let (ok, p) = a.toScreen(i, hd.pos)
        if not ok: continue
        let sel = hd.id in a.selHandles
        ui.uiCircle(p, 4, if sel: pm(255, 60, 60) else: col, filled = true)
        if hd.id == a.hoverHandle and hot:
          ui.uiCircle(p, 7, pm(255, 60, 60), 1.5)
          ui.chip(fmtVec(hd.pos), p + vec2(0, -18), pm(200, 30, 30, 235), colWhite)
    # Rotate tool handle.
    if a.tool == toolRotate and sok:
      let (ok, c) = a.toScreen(i, a.rotCenter)
      if ok:
        if is3D:
          for axis in 0 .. 2:
            let pts = a.ringPoints(i, axis)
            let hotRing = a.hoverHandle == "ring" & $axis or (a.drag.kind == dkRotate and
                          axisIndex(a.drag.axis) == axis)
            let col = axisColor(axis).toUi
            for k in 0 ..< pts.len - 1:
              let (o1, p1) = a.toScreen(i, pts[k])
              let (o2, p2) = a.toScreen(i, pts[k + 1])
              if o1 and o2: ui.uiLine(p1, p2, col, if hotRing: 3.0 else: 1.5)
        else:
          let axis = axisIndex(v.cam.kind.axes.toViewer)
          ui.uiCircle(c, RotateRingPx, axisColor(axis).toUi,
                      if a.hoverHandle == "ring" & $axis and hot: 3.0 else: 1.5)
        ui.uiCircle(c, 5, pm(255, 220, 40), filled = true)
        if a.hoverHandle == "center" and hot:
          ui.uiCircle(c, 8, pm(255, 60, 60), 1.5)
          ui.chip(fmtVec(a.rotCenter), c + vec2(0, -20))
        if a.drag.kind == dkRotate and a.drag.view == i:
          ui.chip(fmtNum(a.drag.angle) & "°", c + vec2(0, 22))
    # Scale tool handles.
    if a.tool == toolScale and sok:
      for (s, p) in a.scaleHandles(i):
        let (ok, q) = a.toScreen(i, p)
        if ok: ui.uiCircle(q, 3.5, pm(110, 230, 110), filled = true)
    # Clip points' positions.
    if a.tool == toolClip:
      for p in a.clipPoints:
        let (ok, q) = a.toScreen(i, p)
        if ok: ui.chip(fmtVec(p), q + vec2(0, -16), pm(200, 110, 20, 235), colWhite)
    # Move / draw feedback.
    case a.drag.kind
    of dkMove, dkHandles:
      if a.drag.moved:
        var parts: seq[string]
        for k in 0 .. 2:
          if abs(a.drag.lastDelta[k]) > 1e-4: parts.add ["X", "Y", "Z"][k] & ": " & fmtNum(a.drag.lastDelta[k])
        let (ok, p) = a.toScreen(i, a.drag.startWorld + a.drag.lastDelta / 2)
        if ok and parts.len > 0: ui.chip(parts.join("  "), p + vec2(0, -14))
    of dkDraw:
      let (lo, hi) = a.drawExtent
      a.sizeLabels(i, lo, hi)
    else: discard
    # Object names in 2D: selected and hovered ones (all with View ▸ Object names).
    if not is3D:
      var n = 0
      for o in a.objects:
        if not (o.selected or o == a.hoverObj or a.showObjectNames) or not a.visible(o): continue
        let (ok, p) = a.toScreen(i, o.pos)
        if ok and p.inside(b): ui.text(o.label, p + vec2(8, -18), colText, FontSmall)
        inc n
        if n > 300: break
    ui.popClip()
  if a.drag.kind == dkBox:
    let v = a.views[a.drag.view]
    let p0 = a.drag.startMouse
    let p1 = ui.mouse
    let r = rect(min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x), abs(p1.y - p0.y))
    ui.pushClip(v.viewBody)
    ui.rect(r, colAccentDim)
    ui.border(r, colAccent)
    ui.popClip()

# --- shared helpers for drags -----------------------------------------------------------------

proc pointOnView(a: App, vi: int, mouse: Vec2, depthFrom: Vec3): Vec3 =
  ## Where the mouse points in a 2D view, at the depth of depthFrom.
  let cam = a.views[vi].cam
  let r = a.viewRay(vi, mouse)
  let ax = cam.kind.axes
  r.origin - ax.toViewer * ((r.origin - depthFrom).dot(ax.toViewer))

proc dragDelta(a: App, mouse: Vec2, shift: bool): Vec3 =
  ## Movement since the drag started: on the view plane in 2D views, on the
  ## horizontal plane in 3D (vertical with Alt, which can change mid-drag).
  ## Shift locks to the axis moved along most.
  let d = a.drag
  let cam = a.views[d.view].cam
  let r = a.viewRay(d.view, mouse)
  if cam.kind == vk3D:
    if a.window.alt:
      let toCam = cam.pos - d.startWorld
      var n = vec3(toCam.x, 0, toCam.z)
      n = if n.length > 1e-3: n.normalize else: vec3(0, 0, 1)
      let (ok, p) = r.planeHit(d.startWorld, n)
      if ok: result = vec3(0, p.y - d.startWorld.y, 0)
    else:
      let (ok, p) = r.planeHit(d.startWorld, vec3(0, 1, 0))
      if ok: result = vec3(p.x - d.startWorld.x, 0, p.z - d.startWorld.z)
  else:
    result = a.pointOnView(d.view, mouse, d.startWorld) - d.startWorld
  if shift:
    let m = max(abs(result.x), max(abs(result.y), abs(result.z)))
    for i in 0 .. 2:
      if abs(result[i]) < m: result[i] = 0

proc snapOnFace(a: App, p: Vec3, fi: int): Vec3 =
  ## Snaps p to the grid but keeps it on the face's plane (TrenchBroom glues
  ## points placed in 3D to the face they were placed on).
  if not a.snap: return p
  let pl = a.geo.facePlane(a.geo.faces[fi])
  result = a.snapV(p)
  let k = axisIndex(pl.n)
  if abs(pl.n[k]) < 1e-4: return
  var s = pl.d
  for j in 0 .. 2:
    if j != k: s -= pl.n[j] * result[j]
  result[k] = s / pl.n[k]

proc startGeometryDrag(a: App, kind: DragKind, vi: int, mouse: Vec2, world: Vec3,
                       points: HashSet[int32]) =
  a.drag = Drag(kind: kind, view: vi, startMouse: mouse, startWorld: world, startTime: epochTime(),
                face: -1, piece: -1)
  for o in a.selection:
    a.drag.objs.add o
    a.drag.startPose.add (o.pos, o.rot)
  a.drag.objBefore = snapshotObjects(a.drag.objs)
  if a.geo != nil:
    a.drag.geoBefore = a.geo.clone
    for v in points: a.drag.startPoints[v] = a.geo.points[v]

proc beginMove(a: App, vi: int, mouse: Vec2, world: Vec3) =
  var points: HashSet[int32]
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  if a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0):
    let faces = a.selectedFaceSet
    a.geo.detachPoints(faces)
    points = a.geo.pointsOf(faces)
  a.startGeometryDrag(dkMove, vi, mouse, world, points)
  if geoBefore != nil: a.drag.geoBefore = geoBefore

proc restoreGeometry(a: App, g: Geometry) =
  let v = a.geo.version
  a.geo = g.clone
  a.geo.version = v + 1

proc cancelDrag*(a: App) =
  ## Esc during a drag (or a drag too short to be meant): undo what it did.
  let d = a.drag
  case d.kind
  of dkPaint, dkPaintFaces:
    for o in a.objects: o.selected = o in d.selBefore[0]
    a.selPieces = d.selBefore[1]
    a.selFaces = d.selBefore[2]
    if d.kind == dkPaintFaces: (a.lastFace, a.faceTemplate) = d.faceBefore
  of dkPlace:
    if d.placed != nil: a.undo()
  of dkRotateCenter: a.rotCenter = d.startWorld
  of dkClipNew: a.clipPoints.setLen d.clipIndex
  of dkClipPoint:
    if d.clipIndex < a.clipPoints.len: a.clipPoints[d.clipIndex] = d.startWorld
  of dkBox: a.selHandles = d.handlesBefore
  else:
    for i, o in d.objs:
      if i < d.objBefore.len: o.restore(d.objBefore[i])
    if d.geoBefore != nil and a.geo != nil: a.restoreGeometry(d.geoBefore)
    if d.dup: a.undo()
  a.drag = Drag(kind: dkNone, face: -1, piece: -1)

proc rehullMovedBrushes(a: App, moved: HashSet[int32], before: Geometry) =
  ## Vertex-edited brushes become the convex hull of their corners again, like
  ## TrenchBroom keeps brushes convex. Other pieces keep their raw shape.
  if a.geo == nil or moved.len == 0: return
  var pieces: HashSet[int32]
  for i, f in a.geo.faces:
    if a.geo.pieces[f.piece].brush:
      for v in f.verts:
        if v in moved:
          pieces.incl f.piece
          break
  let densityOf = a.densityFn
  for pc in pieces:
    let maps = before.pieceUVMaps(before.pieceFaceIds(pc))
    let pts = a.geo.piecePoints(pc)
    discard a.geo.rehullPiece(pc, pts, maps, densityOf)

proc finishDrag(a: App, label: string) =
  let d = a.drag
  if d.moved:
    if d.kind == dkHandles:
      var moved: HashSet[int32]
      for v, _ in d.startPoints: moved.incl v
      a.rehullMovedBrushes(moved, d.geoBefore)
      # Selected handles follow their corners.
      var ids: HashSet[string]
      for id in a.selHandles: ids.incl id
      a.selHandles.clear()
      for h in a.handles:
        var orig: seq[Vec3]
        for c in h.corners: orig.add c - d.lastDelta
        if handleId(a.tool, orig) in ids: a.selHandles.incl h.id
    a.push editCmd(label, d.objs, d.objBefore, d.geoBefore, a.geo)
    if d.dup:
      # Duplicate and move are one step, as in TrenchBroom.
      discard a.undoStack.pop
      a.undoStack[^1].geoAfter = if a.geo != nil: a.geo.clone else: nil
      a.undoStack[^1].label = "Duplicate"
  elif d.geoBefore != nil and a.geo != nil:
    # Nothing moved: drop the point detaching done at the start.
    a.restoreGeometry(d.geoBefore)
    if d.dup: a.undo()
  a.drag = Drag(kind: dkNone, face: -1, piece: -1)

# --- tools --------------------------------------------------------------------------------

proc applyClip*(a: App) =
  if a.geo == nil or a.clipPoints.len < 2: return
  let pieces = a.selPieces
  if pieces.len == 0:
    a.say("Clip: select the pieces to cut first", true)
    return
  let (ok, pl) = a.clipPlane
  if not ok: return
  let before = a.geo.clone
  a.geo.clipPieces(pieces, pl, a.clipSide, a.newFaceAttr, a.densityFn)
  a.push geoCmd("Clip", before, a.geo)
  a.selPieces.clear()
  a.clipPoints.setLen 0
  a.say "Clipped"

proc csg*(a: App, op: string) =
  if a.geo == nil: return
  var pieces = toSeq(a.selPieces)
  pieces.sort
  if pieces.len == 0:
    a.say("CSG: select brushes first", true)
    return
  let byPiece = a.geo.pieceFaces
  for pc in pieces:
    if not a.geo.isConvexClosed(byPiece[pc]):
      a.say("CSG needs convex brushes; piece " & $pc & " isn't one", true)
      return
  let before = a.geo.clone
  var ok = true
  case op
  of "merge": ok = a.geo.csgMerge(pieces, a.densityFn)
  of "intersect": ok = a.geo.csgIntersect(pieces, a.densityFn)
  of "hollow": ok = a.geo.csgHollow(pieces, a.grid, a.densityFn) > 0
  of "subtract":
    # Like TrenchBroom: the selection is subtracted from every brush it touches.
    var others: seq[int32]
    let (okb, lo, hi) = a.selectionBounds
    if okb:
      for pc in 0 ..< a.geo.pieces.len:
        if pc.int32 in a.selPieces or not a.geo.pieces[pc].brush or a.geo.pieces[pc].hidden: continue
        var touches = false
        for fi in byPiece[pc]:
          for v in a.geo.faces[fi].verts:
            let p = a.geo.points[v]
            if p.x >= lo.x - 0.1 and p.y >= lo.y - 0.1 and p.z >= lo.z - 0.1 and
               p.x <= hi.x + 0.1 and p.y <= hi.y + 0.1 and p.z <= hi.z + 0.1: touches = true
        if touches and a.geo.isConvexClosed(byPiece[pc]): others.add pc.int32
    if others.len == 0:
      a.say("Subtract: no brushes touch the selection", true)
      return
    ok = a.geo.csgSubtract(others, pieces, a.densityFn) >= 0
  else: discard
  if not ok:
    a.geo = before
    a.say("CSG " & op & " produced nothing", true)
    return
  a.push geoCmd("CSG " & op, before, a.geo)
  a.selPieces.clear()
  a.say "CSG " & op

proc createShape(a: App, lo, hi: Vec3, dir: Vec3) =
  if a.geo == nil: return
  if hi.x - lo.x < 0.5 or hi.y - lo.y < 0.5 or hi.z - lo.z < 0.5: return
  let before = a.geo.clone
  var made: seq[int32]
  for planes in shapeSolids(a.shape, lo, hi, a.shapeSides.int, a.shapeSteps.int, dir):
    var attrs: seq[FaceAttr]
    for _ in planes: attrs.add a.newFaceAttr
    let pc = a.geo.addSolid(planes, attrs, a.densityFn)
    if pc >= 0: made.add pc
  if made.len == 0: return
  a.push geoCmd("Create " & ($a.shape).toLowerAscii, before, a.geo)
  a.clearSelection()
  for pc in made: a.selPieces.incl pc
  a.say &"{a.shape} {fmtNum(hi.x - lo.x)} × {fmtNum(hi.y - lo.y)} × {fmtNum(hi.z - lo.z)}"

proc createAssembled*(a: App) =
  ## Brush tool: the convex hull of the placed points becomes a brush (Enter).
  if a.geo == nil or a.assemblePoints.len < 4:
    a.say("Brush tool: place at least four points that span a volume", true)
    return
  let before = a.geo.clone
  let pc = a.geo.addHull(a.assemblePoints, a.newFaceAttr, a.densityFn)
  if pc < 0:
    a.say("Brush tool: the points don't span a volume", true)
    return
  a.push geoCmd("Create brush", before, a.geo)
  a.clearSelection()
  a.selPieces.incl pc
  a.assemblePoints.setLen 0
  a.say "Created a brush"

proc deleteHandles*(a: App): bool =
  ## Delete in the vertex/edge/face tools: removes the selected corners from
  ## brushes (they become the hull of what's left). False when it can't.
  if a.geo == nil or a.selHandles.len == 0: return false
  let keys = a.selectedCornerKeys
  let before = a.geo.clone
  var pieces: HashSet[int32]
  for fi in a.selectedFaceSet:
    let f = a.geo.faces[fi]
    for v in f.verts:
      if pkey(a.geo.points[v]) in keys: pieces.incl f.piece
  for pc in pieces:
    if not a.geo.pieces[pc].brush:
      a.say("Only brushes can lose corners; piece " & $pc & " isn't one", true)
      a.geo = before
      return true
    var pts: seq[Vec3]
    for p in a.geo.piecePoints(pc):
      if pkey(p) notin keys: pts.add p
    let maps = before.pieceUVMaps(before.pieceFaceIds(pc))
    if not a.geo.rehullPiece(pc, pts, maps, a.densityFn):
      a.say("Deleting these corners would leave a flat brush", true)
      a.restoreGeometry(before)
      return true
  a.selHandles.clear()
  a.push geoCmd("Delete corners", before, a.geo)
  true

proc copyTextureTo(a: App, src, fi: int, m: UVMap, textureOnly: bool, wrap = false) =
  ## The source face's texture (and, unless textureOnly, its flags and
  ## alignment) onto face fi. wrap (Alt+Shift) folds the alignment about the
  ## edge the two faces' planes meet on, so it runs on around corners.
  if fi == src: return
  let sf = a.geo.faces[src]
  let old = a.geo.faces[fi].texture
  a.geo.faces[fi].texture = sf.texture
  if textureOnly:
    let s = a.density(old) / max(a.density(sf.texture), 0.01)
    if abs(s - 1) > 0.01: a.geo.transformUVs(fi, vec2(0, 0), vec2(1 / s, 1 / s), 0)
  else:
    a.geo.faces[fi].flags = sf.flags
    let n = a.geo.normal(a.geo.faces[fi])
    let m = if wrap: m.wrapUVMap(a.geo.facePlane(sf), a.geo.facePlane(a.geo.faces[fi])) else: m
    if m.ok and abs(m.n.dot(n)) > 0.999:
      for k, v in a.geo.faces[fi].verts: a.geo.faces[fi].uvs[k] = m.mapUV(a.geo.points[v])
    else:
      a.geo.projectUVs(fi, a.density(sf.texture))

proc transferTexture(a: App, target: seq[int], textureOnly: bool, label: string, wrap = false) =
  ## Alt+click: the selected face's texture (and alignment) onto other faces.
  if a.geo == nil or a.selFaces.len != 1: return
  var src = -1
  for fi in a.selFaces: src = fi
  let m = a.geo.uvMapOf(a.geo.faces[src])
  let before = a.geo.clone
  for fi in target: a.copyTextureTo(src, fi, m, textureOnly, wrap)
  a.geo.bump()
  a.push geoCmd(label, before, a.geo)

proc paintTextureAlong(a: App, m: Vec2) =
  ## Alt+drag: every face the mouse passes over since the last frame gets the
  ## selected face's texture (sampled every few pixels so fast moves skip none).
  ## Alt+Shift wraps: each face takes its alignment from the one painted before
  ## it, folded about their shared edge, like TrenchBroom's drag.
  let d = a.drag
  let steps = max(1, int((m - d.lastMouse).length / 3))
  var changed = false
  for k in 1 .. steps:
    let p = d.lastMouse + (m - d.lastMouse) * (k.float32 / steps.float32)
    let (fi, _) = a.faceUnder(d.view, p)
    if fi >= 0 and fi != a.drag.face and fi notin a.drag.painted and fi notin a.selFaces:
      a.drag.painted.incl fi
      a.copyTextureTo(a.drag.face, fi, a.drag.maps[0], a.drag.vertical, a.drag.wrap)
      if a.drag.wrap:
        a.drag.face = fi
        a.drag.maps[0] = a.geo.uvMapOf(a.geo.faces[fi])
      changed = true
  a.drag.lastMouse = m
  if changed: a.geo.bump()

proc coplanarRegion(a: App, start: int): seq[int] =
  ## Faces connected to start (sharing a corner position) on the same plane.
  let pl = a.geo.facePlane(a.geo.faces[start])
  var byKey: Table[string, seq[int]]
  var on: seq[int]
  for i, f in a.geo.faces:
    if not a.faceVisible(i) or f.objectId != -1: continue
    let q = a.geo.facePlane(f)
    if q.n.dot(pl.n) > 0.999 and abs(q.d - pl.d) < 0.05:
      on.add i
      for v in f.verts: byKey.mgetOrPut(pkey(a.geo.points[v]), @[]).add i
  var seen = toHashSet([start])
  var stack = @[start]
  while stack.len > 0:
    let fi = stack.pop
    result.add fi
    for v in a.geo.faces[fi].verts:
      for nb in byKey.getOrDefault(pkey(a.geo.points[v])):
        if nb notin seen:
          seen.incl nb
          stack.add nb

proc selectByBrushes*(a: App, inside: bool) =
  ## Select Touching / Select Inside: the selected brushes pick what they
  ## touch or contain, then go away (TrenchBroom's selection brushes).
  if a.geo == nil or a.selPieces.len == 0:
    a.say("Select the brushes to select with first", true)
    return
  let byPiece = a.geo.pieceFaces
  var solids: seq[seq[Plane]]
  for pc in a.selPieces:
    if not a.geo.isConvexClosed(byPiece[pc]):
      a.say("Selecting with a piece needs a convex brush", true)
      return
    solids.add a.geo.brushPlanes(byPiece[pc])[0]
  proc inSolid(p: Vec3): bool =
    for planes in solids:
      var ok = true
      for pl in planes:
        if pl.dist(p) > 0.05:
          ok = false
          break
      if ok: return true
  let tools = a.selPieces
  var pick: HashSet[int32]
  for pc in 0 ..< a.geo.pieces.len:
    if pc.int32 in tools or a.geo.pieces[pc].hidden or byPiece[pc].len == 0: continue
    var anyIn, allIn = false
    allIn = true
    for fi in byPiece[pc]:
      if a.geo.faces[fi].objectId != -1:
        allIn = false
        anyIn = false
        break
      for v in a.geo.faces[fi].verts:
        if inSolid(a.geo.points[v]): anyIn = true else: allIn = false
    if (inside and allIn) or (not inside and anyIn): pick.incl pc.int32
  var objs: seq[LevelObject]
  for o in a.objects:
    if a.pickable(o) and inSolid(o.pos): objs.add o
  let before = a.geo.clone
  a.geo.removePieces(tools)
  a.push geoCmd(if inside: "Select inside" else: "Select touching", before, a.geo)
  # Removing pieces renumbers the rest: map picked pieces through their faces.
  a.clearSelection()
  var keys: HashSet[string]
  for pc in pick:
    for fi in byPiece[pc]: keys.incl before.faces[fi].verts.mapIt(pkey(before.points[it])).join(";")
  for f in a.geo.faces:
    if f.verts.mapIt(pkey(a.geo.points[it])).join(";") in keys: a.selPieces.incl f.piece
  for o in objs: o.selected = true
  a.say &"Selected {a.selPieces.len} piece(s) and {objs.len} object(s)"

proc selectSiblings*(a: App) =
  ## Everything in the same layers as the selection.
  var tags: HashSet[string]
  for o in a.selection: tags.incl o.tag
  let geo = a.selPieces.len > 0
  for o in a.objects:
    if o.tag in tags and a.pickable(o): o.selected = true
  if geo and a.geometryEditable:
    for pc in a.worldPieces: a.selPieces.incl pc

proc drillSelection(a: App, vi: int, m: Vec2, farther: bool) =
  ## Ctrl+wheel in 3D: move the selection to the next thing under the mouse.
  var cs = a.candidates(vi, m)
  if not farther: cs.reverse
  for i, c in cs:
    if a.isSelected(c) and i + 1 < cs.len:
      a.selectCand(c, false)
      a.selectCand(cs[i + 1], true)
      return

# --- clicks -----------------------------------------------------------------------------

proc clipPointAt(a: App, vi: int, m: Vec2): (bool, Vec3) =
  if a.is3D(vi):
    let (fi, p) = a.faceUnder(vi, m)
    if fi < 0: return (false, p)
    return (true, a.snapOnFace(p, fi))
  let (okb, blo, bhi) = a.selectionBounds
  (true, a.snapV(a.pointOnView(vi, m, if okb: (blo + bhi) / 2 else: a.focus2D)))

proc clipPointNear(a: App, vi: int, m: Vec2): int =
  result = -1
  for i, p in a.clipPoints:
    let (ok, q) = a.toScreen(vi, p)
    if ok and (q - m).length < 8: return i

proc selectClick(a: App, vi: int, m: Vec2, md: Mods) =
  if md.s:
    # Faces: Shift+click; Ctrl+Shift adds or removes.
    let (fi, _) = a.faceUnder(vi, m)
    if fi >= 0:
      if md.c:
        if a.hasNodeSelection: a.convertToFaces()
        if fi in a.selFaces: a.selFaces.excl fi else: a.selFaces.incl fi
      else:
        a.clearSelection()
        a.selFaces.incl fi
      a.lastFace = fi
      a.currentTexture = a.geo.faces[fi].texture
    elif not md.c:
      a.clearSelection()
    return
  let c = a.pick(vi, m)
  if c.found:
    if md.c:
      if a.isSelected(c): a.selectCand(c, false)
      else:
        if a.selFaces.len > 0: a.clearSelection()
        a.selectCand(c, true)
    else:
      a.clearSelection()
      a.selectCand(c, true)
  elif not md.c:
    a.clearSelection()

proc click(a: App, vi: int, m: Vec2) =
  let md = a.mods
  case a.tool
  of toolClip:
    if md.none and a.clipPoints.len < 3:
      let (ok, p) = a.clipPointAt(vi, m)
      if ok:
        if a.clipPoints.len == 2 and not a.is3D(vi): a.clipPoints.setLen 0
        a.clipPoints.add p
        a.clipView = vi
        return
  of toolVertex, toolEdge, toolFace:
    if a.tool == toolVertex and md.only(s = true, al = true) and a.selHandles.len == 1:
      # Snap the selected corner onto the clicked one.
      let target = a.handleAt(vi, m)
      if target.len > 0:
        let src = a.handleById(toSeq(a.selHandles)[0])
        let dst = a.handleById(target)
        let before = a.geo.clone
        let faces = a.selectedFaceSet
        a.geo.detachPoints(faces)
        let pts = a.pointsAtKeys(faces, toHashSet([pkey(src.pos)]))
        for v in pts: a.geo.points[v] = dst.pos
        a.geo.bump()
        a.rehullMovedBrushes(pts, before)
        a.push geoCmd("Snap corner", before, a.geo)
        a.selHandles.clear()
        return
    if not md.s and not md.al:
      let h = a.handleAt(vi, m)
      if h.len > 0:
        if md.c:
          if h in a.selHandles: a.selHandles.excl h else: a.selHandles.incl h
        else:
          a.selHandles.clear()
          a.selHandles.incl h
        return
      if not md.c and a.selHandles.len > 0:
        a.selHandles.clear()
        return
  of toolBrush:
    if md.none and a.is3D(vi):
      let (fi, p) = a.faceUnder(vi, m)
      if fi >= 0:
        a.assemblePoints.add a.snapOnFace(p, fi)
        return
  else: discard
  if md.al:
    # Alt / Alt+Ctrl / Alt+Shift click: copy the selected face's texture.
    if a.selFaces.len == 1 and not a.hasNodeSelection and not (md.c and md.s):
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0: a.transferTexture(@[fi], md.c, "Copy texture", wrap = md.s)
    return
  a.selectClick(vi, m, md)

proc doubleClick(a: App, vi: int, m: Vec2) =
  let md = a.mods
  case a.tool
  of toolClip:
    if md.none:
      # Clip plane = the double-clicked face's plane.
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        let f = a.geo.faces[fi]
        a.clipPoints = @[a.geo.points[f.verts[0]], a.geo.points[f.verts[1]], a.geo.points[f.verts[2]]]
        a.clipView = vi
      return
  of toolBrush:
    if md.none and a.is3D(vi):
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        if a.assemblePoints.len > 0: a.assemblePoints.setLen max(0, a.assemblePoints.len - 1)
        for v in a.geo.faces[fi].verts: a.assemblePoints.add a.geo.points[v]
      return
  else: discard
  if md.al and not md.s:
    if a.selFaces.len == 1 and not a.hasNodeSelection:
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        # The first click already copied to one face: make it the whole piece.
        if a.undoStack.len > 0 and a.undoStack[^1].label == "Copy texture":
          let c = a.undoStack.pop
          a.restoreGeometry(c.geoBefore)
        a.transferTexture(a.geo.pieceFaceIds(a.geo.faces[fi].piece), md.c, "Copy texture to piece")
    return
  if md.s:
    let (fi, _) = a.faceUnder(vi, m)
    if fi < 0: return
    let faces = if md.al: a.coplanarRegion(fi) else: a.geo.pieceFaceIds(a.geo.faces[fi].piece)
    if md.c:
      if a.hasNodeSelection: a.convertToFaces()
    else: a.clearSelection()
    for f in faces: a.selFaces.incl f
    a.lastFace = fi
    return
  let c = a.pick(vi, m)
  if not c.found: return
  if not md.c: a.clearSelection()
  elif a.selFaces.len > 0: a.clearSelection()
  if c.obj != nil:
    for o in a.objects:
      if o.tag == c.obj.tag and a.pickable(o): o.selected = true
  else:
    for pc in a.worldPieces: a.selPieces.incl pc

# --- starting drags ---------------------------------------------------------------------------

proc startDraw(a: App, vi: int, m: Vec2) =
  let cam = a.views[vi].cam
  var start: Vec3
  if cam.kind == vk3D:
    let (fi, p) = a.faceUnder(vi, m)
    if fi >= 0: start = p
    else:
      let r = a.viewRay(vi, m)
      let (ok, q) = r.planeHit(vec3(0, a.focus2D.y, 0), vec3(0, 1, 0))
      start = if ok and (q - r.origin).length < 4000: q else: r.origin + r.dir * 256
  else:
    let (lo, _) = a.referenceBounds
    start = a.pointOnView(vi, m, lo)
  a.drag = Drag(kind: dkDraw, view: vi, startMouse: m, startWorld: start, startTime: epochTime(),
                face: -1, piece: -1)
  a.drag.extent = (a.snapV(start), a.snapV(start))
  a.drag.lastDelta = start  # current handle position (moves on Alt in 3D)

proc beginExtrude(a: App, vi: int, m: Vec2, fi: int, kind: DragKind) =
  let f = a.geo.faces[fi]
  a.startGeometryDrag(kind, vi, m, a.geo.center(f), initHashSet[int32]())
  let r = a.viewRay(vi, m)
  # Grab the point under the mouse on the face's plane when there is one.
  let n = a.geo.normal(f)
  if a.is3D(vi):
    let (ok, p) = r.planeHit(a.geo.center(f), n)
    if ok and (p - a.geo.center(f)).length < 100000: a.drag.startWorld = p
  else:
    # The point under the mouse at the face's depth, so only the mouse's
    # movement counts.
    a.drag.startWorld = a.pointOnView(vi, m, a.geo.center(f))
  a.drag.face = fi
  a.drag.piece = f.piece
  a.drag.axis = n
  a.drag.planeNormal = n
  a.drag.objs.setLen 0
  a.drag.objBefore.setLen 0
  # Every selected piece with a face on fi's plane moves with it, fi's first.
  var order: seq[int32]
  var byPiece: Table[int32, seq[int]]
  for g in a.extrudeGroup(fi):
    let pc = a.geo.faces[g].piece
    if pc notin byPiece: order.add pc
    byPiece.mgetOrPut(pc, @[]).add g
  for pc in order:
    let ids = a.geo.pieceFaceIds(pc)
    var e = DragPiece(piece: pc, planeIndex: -1, maps: a.geo.pieceUVMaps(ids))
    if a.geo.pieces[pc].brush:
      let (planes, _) = a.geo.brushPlanes(ids)
      e.planes = planes
      e.planeIndex = a.geo.planeOfFace(planes, byPiece[pc][0])
    # Corner positions of the faces, for pieces moved point by point.
    for g in byPiece[pc]:
      let gf = a.geo.faces[g]
      e.faces.add (gf.verts.mapIt(a.geo.points[it]), gf.attrOf)
    a.drag.extrudes.add e

proc startLeftDrag(a: App, vi: int, pressPos: Vec2) =
  let md = a.mods
  let modal = a.tool != toolSelect
  let is3D = a.is3D(vi)
  let c = a.pick(vi, pressPos)
  # Alt+drag with one face selected: paint its texture onto every face touched
  # (Alt+Ctrl: the texture only).
  if md.al and not (md.c and md.s) and a.selFaces.len == 1 and not a.hasNodeSelection and a.geo != nil:
    var src = -1
    for fi in a.selFaces: src = fi
    a.drag = Drag(kind: dkPaintTexture, view: vi, startMouse: pressPos, lastMouse: pressPos,
                  startTime: epochTime(), face: src, piece: -1, vertical: md.c, wrap: md.s and not md.c,
                  geoBefore: a.geo.clone, maps: @[a.geo.uvMapOf(a.geo.faces[src])])
    a.paintTextureAlong(pressPos)
    return
  # Move (Alt: vertical, Ctrl: duplicate first).
  if not modal and not md.s and c.found and a.isSelected(c):
    var dup = false
    if md.c:
      a.duplicateSelection(vec3(0, 0, 0))
      dup = true
    a.beginMove(vi, pressPos, c.point)
    a.drag.dup = dup
    return
  case a.tool
  of toolRotate:
    let h = a.rotateHandleAt(vi, pressPos)
    if h == "center":
      a.drag = Drag(kind: dkRotateCenter, view: vi, startMouse: pressPos, startWorld: a.rotCenter,
                    startTime: epochTime(), face: -1, piece: -1)
      return
    if h.startsWith("ring") and a.hasSelection:
      var pts: HashSet[int32]
      let geoBefore = if a.geo != nil: a.geo.clone else: nil
      if a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0):
        let faces = a.selectedFaceSet
        a.geo.detachPoints(faces)
        pts = a.geo.pointsOf(faces)
      a.startGeometryDrag(dkRotate, vi, pressPos, a.rotCenter, pts)
      if geoBefore != nil: a.drag.geoBefore = geoBefore
      a.drag.pivot = a.rotCenter
      var axis = vec3(0, 0, 0)
      axis[parseInt(h[4 .. ^1])] = 1
      # Turn the same way on screen whichever side the camera is on.
      let cam = a.views[vi].cam
      let toViewer = if cam.kind == vk3D: -cam.forward else: cam.kind.axes.toViewer
      if axis.dot(toViewer) < 0: axis = -axis
      a.drag.axis = axis
      return
  of toolScale:
    let (ok, sides) = a.scaleHandleAt(vi, pressPos)
    if ok:
      let (okb, lo, hi) = a.selectionBounds
      if okb:
        var pts: HashSet[int32]
        let geoBefore = if a.geo != nil: a.geo.clone else: nil
        if a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0):
          let faces = a.selectedFaceSet
          a.geo.detachPoints(faces)
          pts = a.geo.pointsOf(faces)
        let c0 = (lo + hi) / 2
        let half = (hi - lo) / 2
        let grab = c0 + vec3(sides.x * half.x, sides.y * half.y, sides.z * half.z)
        a.startGeometryDrag(dkScale, vi, pressPos, grab, pts)
        if geoBefore != nil: a.drag.geoBefore = geoBefore
        a.drag.extent = (lo, hi)
        a.drag.scaleAxes = sides
        return
  else: discard
  # Extrude a selected brush's face (Shift), split (Ctrl), slide (Alt), stamp (Ctrl+Alt).
  if not modal and md.s and a.geo != nil:
    let fi = a.extrudeFaceAt(vi, pressPos)
    if fi >= 0:
      let kind = if md.c and md.al: dkStamp elif md.al: dkSlide elif md.c: dkSplit else: dkExtrude
      a.beginExtrude(vi, pressPos, fi, kind)
      return
  case a.tool
  of toolClip:
    if md.none:
      let k = a.clipPointNear(vi, pressPos)
      if k >= 0:
        a.drag = Drag(kind: dkClipPoint, view: vi, startMouse: pressPos, startWorld: a.clipPoints[k],
                      clipIndex: k, startTime: epochTime(), face: -1, piece: -1)
        return
      if a.clipPoints.len <= 1:
        let (ok, p) = a.clipPointAt(vi, pressPos)
        if ok:
          a.clipPoints.setLen 0
          a.clipPoints.add p
          a.clipPoints.add p
          a.clipView = vi
          a.drag = Drag(kind: dkClipNew, view: vi, startMouse: pressPos, startWorld: p, clipIndex: 0,
                        startTime: epochTime(), face: -1, piece: -1)
          return
  of toolVertex, toolEdge, toolFace:
    let h = a.handleAt(vi, pressPos)
    if h.len > 0:
      if h notin a.selHandles:
        if not md.c: a.selHandles.clear()
        a.selHandles.incl h
      let faces = a.selectedFaceSet
      let before = a.geo.clone
      let keys = a.selectedCornerKeys
      a.geo.detachPoints(faces)
      let pts = a.pointsAtKeys(faces, keys)
      a.startGeometryDrag(dkHandles, vi, pressPos, a.handleById(h).pos, pts)
      a.drag.geoBefore = before
      a.drag.objs.setLen 0
      a.drag.objBefore.setLen 0
      return
    if not md.s and not md.al:
      a.drag = Drag(kind: dkBox, view: vi, startMouse: pressPos, startTime: epochTime(),
                    handlesBefore: a.selHandles, face: -1, piece: -1)
      return
  of toolBrush:
    if is3D and a.geo != nil:
      if md.only(s = true) and a.assemblePoints.len >= 3:
        # Shift+drag: the polygon so far, copied along its normal.
        let pts = a.assemblePoints
        let n0 = (pts[1] - pts[0]).cross(pts[2] - pts[0])
        if n0.length > 1e-4:
          a.drag = Drag(kind: dkAssembleDup, view: vi, startMouse: pressPos, startTime: epochTime(),
                        startWorld: pts[0], axis: n0.normalize, face: -1, piece: -1)
          return
      if md.none:
        let (fi, p) = a.faceUnder(vi, pressPos)
        if fi >= 0:
          a.drag = Drag(kind: dkAssembleRect, view: vi, startMouse: pressPos, startTime: epochTime(),
                        startWorld: a.snapOnFace(p, fi), face: fi, piece: -1)
          return
  else: discard
  # Paint selection (Ctrl+drag; Ctrl+Shift for faces).
  if md.c and not md.al:
    let snap = (a.selection, a.selPieces, a.selFaces)
    let faceSnap = (a.lastFace, a.faceTemplate)
    if md.s:
      let (fi, _) = a.faceUnder(vi, pressPos)
      if fi >= 0:
        if a.hasNodeSelection: a.clearSelection()
        a.selFaces.incl fi
        a.lastFace = fi
        a.drag = Drag(kind: dkPaintFaces, view: vi, startMouse: pressPos, startTime: epochTime(),
                      selBefore: snap, faceBefore: faceSnap, face: -1, piece: -1)
        return
    elif c.found:
      if a.selFaces.len > 0: a.clearSelection()
      a.selectCand(c, true)
      a.drag = Drag(kind: dkPaint, view: vi, startMouse: pressPos, startTime: epochTime(),
                    selBefore: snap, face: -1, piece: -1)
      return
  # Draw a new brush: nothing selected, no Ctrl (and no Alt at the start in 3D).
  if not modal and not md.c and not (is3D and md.al) and not a.hasSelection and a.geo != nil:
    a.startDraw(vi, pressPos)
    return
  a.drag = Drag(kind: dkIgnore, view: vi, face: -1, piece: -1)

# --- drag updates ---------------------------------------------------------------------------------

proc updateDraw(a: App, m: Vec2) =
  let v = a.views[a.drag.view]
  let md = a.mods
  var cur = a.drag.lastDelta
  if v.cam.kind == vk3D:
    let r = a.viewRay(a.drag.view, m)
    if md.al and not md.s:
      # Alt: change the height along the vertical through the current corner.
      let toCam = v.cam.pos - cur
      var n = vec3(toCam.x, 0, toCam.z)
      n = if n.length > 1e-3: n.normalize else: vec3(0, 0, 1)
      let (ok, p) = r.planeHit(cur, n)
      if ok: cur.y = p.y
    else:
      let (ok, p) = r.planeHit(vec3(cur.x, cur.y, cur.z), vec3(0, 1, 0))
      if ok: cur = vec3(p.x, cur.y, p.z)
  else:
    cur = a.pointOnView(a.drag.view, m, a.drag.startWorld)
  a.drag.lastDelta = cur
  let s0 = a.drag.startWorld
  var lo = min(s0, cur)
  var hi = max(s0, cur)
  let g = a.grid
  if a.snap:
    for i in 0 .. 2:
      lo[i] = floor(lo[i] / g + 1e-4) * g
      hi[i] = ceil(hi[i] / g - 1e-4) * g
  if v.cam.kind == vk3D:
    # A flat side gets one grid step of thickness, away from the camera.
    for i in 0 .. 2:
      if hi[i] - lo[i] < 1e-3:
        if lo[i] < v.cam.pos[i]: hi[i] = lo[i] + g else: lo[i] = hi[i] - g
  else:
    let k = axisIndex(v.cam.kind.axes.toViewer)
    let (rlo, rhi) = a.referenceBounds
    lo[k] = rlo[k]
    hi[k] = max(rhi[k], rlo[k] + g)
    for i in 0 .. 2:
      if i != k and hi[i] - lo[i] < 1e-3: hi[i] = lo[i] + g
  if md.s:
    # Shift: square on the drawing plane; Shift+Alt: a cube.
    let viewAxis = if v.cam.kind == vk3D: 1 else: axisIndex(v.cam.kind.axes.toViewer)
    var axes: seq[int]
    for i in 0 .. 2:
      if md.al or i != viewAxis: axes.add i
    var mx = 0'f32
    for i in axes: mx = max(mx, hi[i] - lo[i])
    for i in axes:
      if cur[i] >= s0[i]: hi[i] = lo[i] + mx else: lo[i] = hi[i] - mx
  a.drag.extent = (lo, hi)
  a.drag.axis = cur - s0

proc extrudeDistance(a: App, m: Vec2): float32 =
  let n = a.drag.axis
  let cam = a.views[a.drag.view].cam
  let r = a.viewRay(a.drag.view, m)
  let viewDir = if cam.kind == vk3D: cam.forward else: -cam.kind.axes.toViewer
  let pn = n.cross(viewDir).cross(n)
  if pn.length < 1e-4: return 0
  let (ok, p) = r.planeHit(a.drag.startWorld, pn.normalize)
  if not ok: return 0
  result = (p - a.drag.startWorld).dot(n)
  if a.snap: result = snapTo(result, a.grid)

proc movePieceCorners(a: App, pc: int32, corners: seq[Vec3], d: Vec3) =
  ## Moves every point of piece pc at one of the corner positions by d.
  var keys: HashSet[string]
  for c in corners: keys.incl pkey(c)
  var faces: HashSet[int]
  for i, f in a.geo.faces:
    if f.piece == pc: faces.incl i
  a.geo.detachPoints(faces)
  for v in a.pointsAtKeys(faces, keys): a.geo.points[v] += d

proc extrudePiece(a: App, kind: DragKind, e: DragPiece, dist: float32, move: Vec3): bool =
  ## Applies an extrude, slide, split or stamp drag to one piece. False, after
  ## possibly changing some geometry, when a brush would enclose no volume.
  result = true
  let pc = e.piece
  let brush = e.planes.len > 0 and e.planeIndex >= 0
  var corners: seq[Vec3]
  for (c, _) in e.faces: corners.add c
  case kind
  of dkExtrude:
    if brush:
      var planes = e.planes
      planes[e.planeIndex].d += dist
      return a.geo.replacePiece(pc, planes, e.maps, a.densityFn)
    a.movePieceCorners(pc, corners, move)
  of dkSlide:
    a.movePieceCorners(pc, corners, move)
    if brush: return a.geo.rehullPiece(pc, a.geo.piecePoints(pc), e.maps, a.densityFn)
  of dkSplit:
    if brush:
      let orig = e.planes[e.planeIndex]
      var moved = orig
      moved.d += dist
      var slab = e.planes
      if dist > 0:
        # Outward: a new brush between the old and the new face position.
        slab[e.planeIndex] = moved
        slab.add orig.flipped
      else:
        # Inward: the brush shrinks and the cut-off part becomes its own brush.
        var shrunk = e.planes
        shrunk[e.planeIndex] = moved
        if not a.geo.replacePiece(pc, shrunk, e.maps, a.densityFn): return false
        slab.add moved.flipped
      let np = a.geo.pieces.len.int32
      a.geo.pieces.add Piece(brush: true)
      if not a.geo.replacePiece(np, slab, e.maps, a.densityFn): a.geo.pieces.setLen np
    else:
      for (c, attr) in e.faces:
        var pts = c
        for p in c: pts.add p + move
        discard a.geo.addHull(pts, attr, a.densityFn, e.maps)
  of dkStamp:
    for (c, attr) in e.faces:
      var pts = c
      for p in c: pts.add p + move
      discard a.geo.addHull(pts, attr, a.densityFn, e.maps)
  else: discard

proc updateExtrude(a: App, m: Vec2) =
  let d = a.drag
  var dist: float32
  var move: Vec3
  if d.kind == dkSlide and not a.is3D(d.view):
    move = a.pointOnView(d.view, m, d.startWorld) - d.startWorld
    if a.snap: move = a.snapV(move)
    dist = move.length
  else:
    dist = a.extrudeDistance(m)
    move = d.axis * dist
  if abs(dist) > 1e-4: a.drag.moved = true
  a.restoreGeometry(d.geoBefore)
  if abs(dist) < 1e-4: return
  for e in d.extrudes:
    if not a.extrudePiece(d.kind, e, dist, move):
      # One piece can't take it (it would lose its volume): none moves.
      a.restoreGeometry(d.geoBefore)
      return
  a.geo.bump()

proc finishExtrude(a: App) =
  let d = a.drag
  if not d.moved:
    a.restoreGeometry(d.geoBefore)
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
    return
  let label = case d.kind
    of dkSplit: "Split brush"
    of dkStamp: "Stamp brush"
    of dkSlide: "Move face"
    else: "Extrude"
  if d.kind in {dkSplit, dkStamp}:
    for pc in d.geoBefore.pieces.len ..< a.geo.pieces.len: a.selPieces.incl pc.int32
  a.push geoCmd(label, d.geoBefore, a.geo)
  a.drag = Drag(kind: dkNone, face: -1, piece: -1)

proc updateDrag(a: App, m: Vec2) =
  let w = a.window
  let md = a.mods
  case a.drag.kind
  of dkMove, dkHandles:
    if (m - a.drag.startMouse).length > DragThreshold: a.drag.moved = true
    if not a.drag.moved: return
    var delta = a.dragDelta(m, md.s)
    if a.snap: delta = a.snapV(delta)   # relative snapping, like TrenchBroom
    if delta == a.drag.lastDelta: return
    a.drag.lastDelta = delta
    for i, o in a.drag.objs:
      a.setPose(o, a.drag.startPose[i][0] + delta, a.drag.startPose[i][1])
    if a.geo != nil and a.drag.startPoints.len > 0:
      for v, p in a.drag.startPoints: a.geo.points[v] = p + delta
      a.geo.bump()
  of dkExtrude, dkSlide, dkSplit, dkStamp: a.updateExtrude(m)
  of dkRotate:
    let (ok, c) = a.toScreen(a.drag.view, a.drag.pivot)
    if not ok: return
    let a0 = arctan2(a.drag.startMouse.y - c.y, a.drag.startMouse.x - c.x)
    let a1 = arctan2(m.y - c.y, m.x - c.x)
    var deg = -(a1 - a0).radToDeg
    while deg > 180: deg -= 360
    while deg < -180: deg += 360
    let step = max(a.rotateAngle, 1)
    deg = round(deg / step) * step
    if abs(deg) > 0.01: a.drag.moved = true
    a.drag.angle = deg
    let axis = a.drag.axis
    let pivot = a.drag.pivot
    for i, o in a.drag.objs:
      var rot = a.drag.startPose[i][1]
      let k = axisIndex(axis)
      rot[k] = rot[k] + deg * sgn(axis[k]).float32
      a.setPose(o, rotateAxis(a.drag.startPose[i][0], pivot, axis, deg), rot)
    if a.geo != nil and a.drag.startPoints.len > 0:
      for pv, p in a.drag.startPoints: a.geo.points[pv] = rotateAxis(p, pivot, axis, deg)
      a.geo.bump()
  of dkRotateCenter:
    var d = a.dragDelta(m, md.s)
    if a.snap: d = a.snapV(d)
    a.rotCenter = a.drag.startWorld + d
    a.rotCenterText = fmtVec(a.rotCenter)
  of dkScale:
    a.drag.moved = true
    let (lo, hi) = a.drag.extent
    let sides = a.drag.scaleAxes
    let cam = a.views[a.drag.view].cam
    var p: Vec3
    if cam.kind == vk3D:
      let r = a.viewRay(a.drag.view, m)
      let (ok, q) = r.planeHit(a.drag.startWorld, -cam.forward)
      if not ok: return
      p = q
    else:
      p = a.pointOnView(a.drag.view, m, a.drag.startWorld)
    p = a.snapV(p)
    var nlo = lo
    var nhi = hi
    let c = (lo + hi) / 2
    for i in 0 .. 2:
      if sides[i] == 0: continue
      if md.al:
        let half = max(abs(p[i] - c[i]), 0.5)
        nlo[i] = c[i] - half
        nhi[i] = c[i] + half
      elif sides[i] > 0: nhi[i] = max(p[i], lo[i] + 1)
      else: nlo[i] = min(p[i], hi[i] - 1)
    if md.s:
      # Proportional: every axis (in 2D the two on screen) by the largest factor.
      var f = 1'f32
      for i in 0 .. 2:
        if sides[i] != 0 and hi[i] - lo[i] > 1e-4:
          let g = (nhi[i] - nlo[i]) / (hi[i] - lo[i])
          if abs(g - 1) > abs(f - 1): f = g
      let depth = if cam.kind == vk3D: -1 else: axisIndex(cam.kind.axes.toViewer)
      for i in 0 .. 2:
        if sides[i] != 0 or i == depth: continue
        let span = (hi[i] - lo[i]) * f
        if md.al:
          nlo[i] = c[i] - span / 2
          nhi[i] = c[i] + span / 2
        else:
          nlo[i] = lo[i]
          nhi[i] = lo[i] + span
    proc remap(q: Vec3): Vec3 =
      for i in 0 .. 2:
        let span = hi[i] - lo[i]
        result[i] = if span > 1e-4: nlo[i] + (q[i] - lo[i]) / span * (nhi[i] - nlo[i]) else: q[i]
    for i, o in a.drag.objs: a.setPose(o, remap(a.drag.startPose[i][0]), a.drag.startPose[i][1])
    if a.geo != nil:
      for pv, q in a.drag.startPoints: a.geo.points[pv] = remap(q)
      a.geo.bump()
  of dkDraw: a.updateDraw(m)
  of dkBox: discard
  of dkClipPoint, dkClipNew:
    let (ok, p) = a.clipPointAt(a.drag.view, m)
    if ok:
      let k = if a.drag.kind == dkClipNew: 1 else: a.drag.clipIndex
      if k < a.clipPoints.len: a.clipPoints[k] = p
  of dkPaint:
    let c = a.pick(a.drag.view, m)
    if c.found and not a.isSelected(c): a.selectCand(c, true)
  of dkPaintTexture: a.paintTextureAlong(m)
  of dkPaintFaces:
    let (fi, _) = a.faceUnder(a.drag.view, m)
    if fi >= 0 and fi notin a.selFaces:
      a.selFaces.incl fi
      a.lastFace = fi
  of dkAssembleRect:
    let f = a.drag.face
    let n = a.geo.normal(a.geo.faces[f])
    let r = a.viewRay(a.drag.view, m)
    let (ok, p) = r.planeHit(a.drag.startWorld, n)
    if not ok: return
    let q = a.snapOnFace(p, f)
    let s = a.drag.startWorld
    # A rectangle in the face plane, along the two world axes in it.
    let k = axisIndex(n)
    var u, v = vec3(0, 0, 0)
    u[(k + 1) mod 3] = 1
    v[(k + 2) mod 3] = 1
    let d = q - s
    let p1 = s + u * d.dot(u)
    let p3 = s + v * d.dot(v)
    let p2 = p1 + (p3 - s)
    proc onPlane(x: Vec3): Vec3 = x - n * (x - s).dot(n)
    a.drag.corners = @[s, onPlane(p1), onPlane(p2), onPlane(p3)]
  of dkAssembleDup:
    let n = a.drag.axis
    let cam = a.views[a.drag.view].cam
    let r = a.viewRay(a.drag.view, m)
    let pn = n.cross(cam.forward).cross(n)
    if pn.length < 1e-4: return
    let (ok, p) = r.planeHit(a.drag.startWorld, pn.normalize)
    if not ok: return
    var dist = (p - a.drag.startWorld).dot(n)
    if a.snap: dist = snapTo(dist, a.grid)
    a.drag.corners = a.assemblePoints.mapIt(it + n * dist)
  of dkPlace:
    let o = a.drag.placed
    if o == nil: return
    let vi = a.drag.view
    var p: Vec3
    if a.is3D(vi):
      # On the surface under the mouse, never on the object's own geometry.
      let r = a.viewRay(vi, m)
      var (fi, t) = (-1, 0'f32)
      if a.geometryEditable:
        let code = o.objectCode
        let pickable = a.facePickable
        let app = a
        (fi, t) = a.geo.pickFace(r, proc(i: int): bool =
          (code == -1 or app.geo.faces[i].objectId != code) and pickable(i))
      p = if fi >= 0: r.origin + r.dir * t else: r.origin + r.dir * 256
    else:
      let (_, rhi) = a.referenceBounds
      p = a.pointOnView(vi, m, rhi)
    p = a.snapV(p)
    if p != o.pos: a.setPose(o, p, o.rot)
  of dkLook, dkOrbit, dkPan, dkNone, dkIgnore: discard

proc endDrag(a: App, m: Vec2) =
  let d = a.drag
  case d.kind
  of dkMove: a.finishDrag(if d.dup: "Duplicate" else: "Move")
  of dkHandles: a.finishDrag($a.tool)
  of dkRotate: a.finishDrag("Rotate")
  of dkScale: a.finishDrag("Scale")
  of dkExtrude, dkSlide, dkSplit, dkStamp: a.finishExtrude()
  of dkDraw:
    let (lo, hi) = d.extent
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
    a.createShape(lo, hi, d.axis)
  of dkBox:
    let v = a.views[d.view]
    let b = v.viewBody
    let p0 = d.startMouse
    let lo = vec2(min(p0.x, m.x), min(p0.y, m.y)) - b.xy
    let hi = vec2(max(p0.x, m.x), max(p0.y, m.y)) - b.xy
    var inside: seq[string]
    for h in a.handles:
      let (ok, p) = v.cam.project(h.pos, b.w, b.h)
      if ok and p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y: inside.add h.id
    if not a.window.ctrl: a.selHandles.clear()
    for id in inside:
      if id in a.selHandles: a.selHandles.excl id else: a.selHandles.incl id
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  of dkPaintTexture:
    if d.painted.len > 0:
      a.push geoCmd(if d.vertical: "Paint texture" elif d.wrap: "Paint texture, wrapped"
                    else: "Paint texture and alignment", d.geoBefore, a.geo)
      a.say &"Gave {d.painted.len} face(s) the texture {a.geo.faces[d.face].texture}"
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  of dkAssembleRect, dkAssembleDup:
    for p in d.corners: a.assemblePoints.add p
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  of dkPlace:
    if d.placed != nil:
      # The create step's geometry is where the object ended up.
      if a.undoStack.len > 0 and a.undoStack[^1].geoAfter != nil and d.placed in a.undoStack[^1].objs:
        a.undoStack[^1].geoAfter = a.geo.clone
      a.say "Placed " & (if d.preset.generic: "a new " & typeName(d.placed.tag) else: d.preset.label)
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  else:
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)

# --- mouse ----------------------------------------------------------------------------------

proc handleViews*(a: App, dt: float32) =
  let ui = a.ui
  let w = a.window
  let m = ui.mouse
  let blocked = ui.captured or a.modalOpen or a.menuSys.isOpen or a.splitDrag.len > 0
  a.hoverView = if blocked: -1 else: a.viewAt(m)
  if a.drag.kind == dkPlace: a.hoverView = if blocked and a.menuSys.contextOpen: -1 else: a.viewAt(m)
  elif a.drag.kind != dkNone: a.hoverView = a.drag.view
  elif a.press.active: a.hoverView = a.press.view
  let vi = a.hoverView
  if vi >= 0: a.activeView = vi
  a.hoverObj = nil
  a.extrudeHover = -1
  a.extrudeHoverFaces.setLen 0

  # Camera drags.
  case a.drag.kind
  of dkLook:
    if not w.buttonDown[MouseRight]:
      if a.drag.moved: a.rmbPress.dragging = true
      a.drag.kind = dkNone
    else:
      let cam = addr a.views[a.drag.view].cam
      let d = w.mouseDelta.vec2
      if d.length > 0: a.drag.moved = true
      cam.yaw -= d.x * 0.004
      cam.pitch = clamp(cam.pitch - d.y * 0.004, -1.55, 1.55)
      # Wheel while flying: up = faster, down = slower.
      let notches = ui.wheelNotches
      if notches != 0 and not ui.scrollConsumed:
        a.flySpeed = clamp(a.flySpeed * pow(1.25'f32, -notches), 25, 20000)
        a.drag.moved = true
        a.say &"Fly speed {a.flySpeed.round.int}"
      var speed = a.flySpeed * dt
      if w.shiftDown: speed *= 3
      var mv = vec3(0, 0, 0)
      if w.buttonDown[KeyW]: mv += cam[].forward
      if w.buttonDown[KeyS]: mv -= cam[].forward
      if w.buttonDown[KeyD]: mv += cam[].right
      if w.buttonDown[KeyA]: mv -= cam[].right
      if w.buttonDown[KeyE]: mv += vec3(0, 1, 0)
      if w.buttonDown[KeyQ]: mv -= vec3(0, 1, 0)
      if mv.length > 0: a.drag.moved = true
      cam.pos += mv * speed
      return
  of dkOrbit:
    if not w.buttonDown[MouseRight]:
      if a.drag.moved: a.rmbPress.dragging = true
      a.drag.kind = dkNone
    else:
      let cam = addr a.views[a.drag.view].cam
      let d = w.mouseDelta.vec2
      if d.length > 0: a.drag.moved = true
      let notches = ui.wheelNotches
      if notches != 0 and not ui.scrollConsumed:
        a.drag.orbitDist = clamp(a.drag.orbitDist * pow(1.15'f32, notches), 8, 40000)
      cam.yaw -= d.x * 0.006
      cam.pitch = clamp(cam.pitch - d.y * 0.006, -1.5, 1.5)
      cam.pos = a.drag.pivot - cam[].forward * a.drag.orbitDist
      return
  of dkPan:
    if not (w.buttonDown[MouseMiddle] or w.buttonDown[MouseRight]):
      if a.drag.moved: a.rmbPress.dragging = true
      a.drag.kind = dkNone
    else:
      let d = w.mouseDelta.vec2 / a.sk.uiScale
      if d.length > 0: a.drag.moved = true
      let cam = addr a.views[a.drag.view].cam
      if cam.kind == vk3D:
        cam.pos += cam[].right * (-d.x) + vec3(0, 1, 0) * d.y
      else:
        let ax = cam.kind.axes
        a.focus2D += (ax.right * (-d.x) + ax.up * d.y) / a.zoom2D
        a.sync2D()
      return
  else: discard

  # Right click without moving: the view's context menu.
  if a.rmbPress.active and w.buttonReleased[MouseRight]:
    let p = a.rmbPress
    a.rmbPress.active = false
    if not blocked and not p.dragging and (m - p.pos).length <= 3 and p.view >= 0 and
       a.views[p.view].rect.w > 1:
      let cs = a.candidates(p.view, m)
      let (fi, fp) = a.faceUnder(p.view, m)
      var point = fp
      if fi < 0:
        point = if a.is3D(p.view): a.viewRay(p.view, m).origin + a.viewRay(p.view, m).dir * 256
                else: a.pointOnView(p.view, m, a.referenceBounds[1])
      a.ctx = CtxMenu(pos: m, view: p.view, point: point, face: fi,
                      obj: (if cs.len > 0: cs[0].obj else: nil))
      a.menuSys.openContext(m)
      return

  # Left button: click or drag.
  if a.press.active:
    if w.buttonDown[MouseLeft]:
      if not a.press.dragging and (m - a.press.pos).length > DragThreshold:
        a.press.dragging = true
        a.startLeftDrag(a.press.view, a.press.pos)
      if a.press.dragging and a.drag.kind != dkNone: a.updateDrag(m)
      return
    # Released.
    let p = a.press
    a.press.active = false
    if p.dragging:
      if a.drag.kind notin {dkNone, dkIgnore} and epochTime() - p.time < MinDragTime:
        # Too quick to be a drag: undo it, and count it as a click if it stayed put.
        a.cancelDrag()
        if (m - p.pos).length <= DragThreshold: a.click(p.view, p.pos)
      else:
        a.endDrag(m)
      a.drag = Drag(kind: dkNone, face: -1, piece: -1)
      return
    let now = epochTime()
    if a.lastClick.view == p.view and now - a.lastClick.time < 0.4 and
       (p.pos - a.lastClick.pos).length <= 4:
      a.doubleClick(p.view, p.pos)
      a.lastClick.time = 0
    else:
      a.click(p.view, p.pos)
      a.lastClick = (now, p.pos, p.view)
    return
  if a.drag.kind == dkPlace:
    # Dragging from the entity browser.
    if not w.buttonDown[MouseLeft]:
      a.endDrag(m)
      return
    if vi >= 0 and a.drag.placed == nil:
      a.drag.view = vi
      a.drag.placed = a.addPreset(a.drag.preset, a.focus2D)
      if a.drag.placed == nil:
        a.drag = Drag(kind: dkNone, face: -1, piece: -1)
        return
    elif vi < 0 and a.drag.placed != nil:
      a.undo()
      a.drag.placed = nil
    if a.drag.placed != nil:
      if vi >= 0: a.drag.view = vi
      a.updateDrag(m)
    return

  if vi < 0 or a.proj == nil: return
  let cam = addr a.views[vi].cam
  let b = a.views[vi].viewBody
  let md = a.mods

  # Hover feedback.
  if not w.buttonDown[MouseLeft]:
    a.hoverHandle = ""
    case a.tool
    of toolVertex, toolEdge, toolFace: a.hoverHandle = a.handleAt(vi, m)
    of toolRotate: a.hoverHandle = a.rotateHandleAt(vi, m)
    of toolSelect:
      if md.s and a.selPieces.len > 0:
        a.extrudeHover = a.extrudeFaceAt(vi, m)
        if a.extrudeHover >= 0: a.extrudeHoverFaces = a.extrudeGroup(a.extrudeHover)
    else: discard
    if not a.is3D(vi):
      let c = a.pick(vi, m)
      if c.obj != nil: a.hoverObj = c.obj

  # Wheel.
  let notches = ui.wheelNotches
  if notches != 0 and not ui.scrollConsumed:
    if md.c and md.al:
      # Ctrl+Alt+wheel: grid size.
      a.gridIndex = clamp(a.gridIndex + (if notches < 0: 1 else: -1), 0, GridSizes.high)
    elif md.c and not md.s:
      if cam.kind == vk3D: a.drillSelection(vi, m, notches < 0)
    elif cam.kind == vk3D:
      if md.s:
        # Shift+wheel: zoom (field of view); Ctrl+Alt+Z resets it.
        cam.fovY = clamp(cam.fovY * pow(1.1'f32, notches), 10'f32.degToRad, 120'f32.degToRad)
      else:
        cam.pos -= cam[].forward * notches * 64
    else:
      let before = cam[].pixelToPlane(m.x - b.x, m.y - b.y, b.w, b.h)
      a.zoom2D = clamp(a.zoom2D * pow(1.2'f32, -notches), 0.005, 80)
      cam.zoom = a.zoom2D
      let after = cam[].pixelToPlane(m.x - b.x, m.y - b.y, b.w, b.h)
      let ax = cam.kind.axes
      a.focus2D += ax.right * (before.x - after.x) + ax.up * (before.y - after.y)
      a.sync2D()

  if w.buttonPressed[MouseRight]:
    a.rmbPress = Press(active: true, view: vi, pos: m, time: epochTime())
    if cam.kind == vk3D and md.al:
      let c = a.pick(vi, m)
      let pivot = if c.found: c.point else: cam.pos + cam[].forward * 300
      a.drag = Drag(kind: dkOrbit, view: vi, pivot: pivot, orbitDist: (pivot - cam.pos).length)
    else:
      a.drag = Drag(kind: (if cam.kind == vk3D: dkLook else: dkPan), view: vi)
    return
  if w.buttonPressed[MouseMiddle]:
    a.drag = Drag(kind: dkPan, view: vi)
    return
  if w.buttonPressed[MouseLeft] and not ui.clickConsumed:
    ui.consumeClick()
    a.press = Press(active: true, view: vi, pos: m, time: epochTime())

proc startPlacing*(a: App, p: Preset) =
  ## A drag from the entity browser: the object appears once the mouse is
  ## over a view and follows it until the button is released.
  a.drag = Drag(kind: dkPlace, view: -1, preset: p, startTime: epochTime(), face: -1, piece: -1)

# --- keyboard --------------------------------------------------------------------------------

proc mainAxis(v: Vec3): int = axisIndex(v)

proc viewAxes*(a: App): tuple[right, up, toViewer: Vec3] =
  ## Directions arrow keys use: the hovered 2D view's axes, or in 3D the world
  ## axes nearest to the camera's.
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  let cam = a.views[clamp(vi, 0, 3)].cam
  if cam.kind != vk3D: return cam.kind.axes
  let f = cam.forward
  let flat = vec3(f.x, 0, f.z)
  let fwd = if flat.length > 0.01: flat.normalize else: vec3(0, 0, -1)
  var up: Vec3
  if abs(fwd.x) > abs(fwd.z): up = vec3(sgn(fwd.x).float32, 0, 0)
  else: up = vec3(0, 0, sgn(fwd.z).float32)
  (vec3(-up.z, 0, up.x), up, vec3(0, 1, 0))

proc moveTextures(a: App, d: Vec2, rot: float32) =
  let faces = a.selectedFaceSet
  if faces.len == 0 or a.geo == nil: return
  let before = a.geo.clone
  for fi in faces: a.geo.transformUVs(fi, d, vec2(1, 1), rot)
  a.geo.bump()
  a.push geoCmd("Move texture", before, a.geo)

proc flipTextures*(a: App, u: bool) =
  let faces = a.selectedFaceSet
  if faces.len == 0 or a.geo == nil: return
  let before = a.geo.clone
  for fi in faces: a.geo.transformUVs(fi, vec2(0, 0), (if u: vec2(-1, 1) else: vec2(1, -1)), 0)
  a.geo.bump()
  a.push geoCmd("Flip texture", before, a.geo)

proc resetTextures*(a: App) =
  let faces = a.selectedFaceSet
  if faces.len == 0 or a.geo == nil: return
  let before = a.geo.clone
  for fi in faces: a.geo.projectUVs(fi, a.density(a.geo.faces[fi].texture))
  a.geo.bump()
  a.push geoCmd("Reset texture", before, a.geo)

proc moveHandles(a: App, d: Vec3) =
  ## Arrow keys in the vertex/edge/face tools.
  if a.selHandles.len == 0 or a.geo == nil: return
  let before = a.geo.clone
  let faces = a.selectedFaceSet
  let keys = a.selectedCornerKeys
  a.geo.detachPoints(faces)
  let pts = a.pointsAtKeys(faces, keys)
  for v in pts: a.geo.points[v] += d
  a.geo.bump()
  a.rehullMovedBrushes(pts, before)
  var ids = a.selHandles
  a.selHandles.clear()
  for h in a.handles:
    var orig: seq[Vec3]
    for c in h.corners: orig.add c - d
    if handleId(a.tool, orig) in ids: a.selHandles.incl h.id
  a.push geoCmd($a.tool, before, a.geo)

proc cycleView(a: App) =
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  if vi < 0: return
  let old = a.views[vi].cam
  let next = ViewKind((ord(old.kind) + 1) mod (ord(high(ViewKind)) + 1))
  var c = Camera(kind: next, fovY: 70'f32.degToRad, zoom: a.zoom2D)
  if next == vk3D:
    c.pos = a.focus2D + vec3(0, 200, 400)
    c.yaw = 0
    c.pitch = -0.4
  a.views[vi].cam = c
  a.sync2D()

proc setTool*(a: App, t: Tool) =
  ## Toggles a modal tool (pressing its key again leaves it).
  let next = if a.tool == t: toolSelect else: t
  if next == a.tool: return
  a.tool = next
  a.selHandles.clear()
  a.hoverHandle = ""
  if next == toolRotate: a.resetRotateCenter()
  if next != toolClip: a.clipPoints.setLen 0
  if next != toolBrush: a.assemblePoints.setLen 0

proc cancel*(a: App) =
  ## Esc: the drag in progress, then the tool's own state, then the tool,
  ## then the selection (TrenchBroom's order).
  if a.drag.kind notin {dkNone, dkLook, dkOrbit, dkPan}:
    a.cancelDrag()
    a.press.active = false
    return
  case a.tool
  of toolClip:
    if a.clipPoints.len > 0: a.clipPoints.setLen(a.clipPoints.len - 1)
    else: a.setTool(toolSelect)
  of toolBrush:
    if a.assemblePoints.len > 0: a.assemblePoints.setLen 0
    else: a.setTool(toolSelect)
  of toolVertex, toolEdge, toolFace:
    if a.selHandles.len > 0: a.selHandles.clear()
    else: a.setTool(toolSelect)
  of toolRotate, toolScale: a.setTool(toolSelect)
  of toolSelect: a.clearSelection()

proc rotateKeyed*(a: App, axis: Vec3, sign: float32, label: string) =
  ## Alt+arrows: 90° about the selection's center, or with the rotate tool its
  ## angle about its center.
  if a.tool == toolRotate:
    let sel = a.selection
    let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
    if sel.len == 0 and not geoSel: return
    let deg = a.rotateAngle.float32 * sign
    let pivot = a.rotCenter
    let geoBefore = if a.geo != nil: a.geo.clone else: nil
    let before = snapshotObjects(sel)
    for o in sel:
      var r = o.rot
      let k = axisIndex(axis)
      r[k] = r[k] + deg * sgn(axis[k]).float32
      a.setPose(o, rotateAxis(o.pos, pivot, axis, deg), r)
    if geoSel:
      let faces = a.selectedFaceSet
      a.geo.detachPoints(faces)
      a.geo.transformPoints(a.geo.pointsOf(faces), proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg))
    a.push editCmd(label, sel, before, geoBefore, a.geo)
  else:
    a.rotateSelection(axis, 90 * sign, label)

proc scaleSelection*(a: App, f: Vec3) =
  ## Scale tool's Apply: by per-axis factors about the selection's center.
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  let c = (lo + hi) / 2
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  proc sc(p: Vec3): Vec3 = c + vec3((p.x - c.x) * f.x, (p.y - c.y) * f.y, (p.z - c.z) * f.z)
  for o in sel: a.setPose(o, sc(o.pos), o.rot)
  if geoSel:
    let faces = a.selectedFaceSet
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), sc)
    if f.x * f.y * f.z < 0: a.geo.reverseWinding(faces)
  a.push editCmd("Scale", sel, before, geoBefore, a.geo)

proc gridKeys(a: App, c, al: bool): bool =
  ## Grid shortcuts: 0 show grid, Alt+0 snap, +/- size, 1-9 size 1..256.
  ## Returns true if one was pressed.
  let w = a.window
  template pressed(k: Button): bool = w.buttonPressed[k]
  result = true
  if al and pressed(Key0): a.snap = not a.snap
  elif pressed(Key0): a.showGrid = not a.showGrid
  elif pressed(KeyEqual) or pressed(NumpadAdd): a.gridIndex = min(GridSizes.high, a.gridIndex + 1)
  elif pressed(KeyMinus) or pressed(NumpadSubtract): a.gridIndex = max(0, a.gridIndex - 1)
  else:
    if not c and not al:
      for (k, i) in [(Key1, 0), (Key2, 1), (Key3, 2), (Key4, 3), (Key5, 4), (Key6, 5), (Key7, 6),
                     (Key8, 7), (Key9, 8)]:
        if pressed(k):
          a.gridIndex = i
          return
    result = false

proc handleKeys*(a: App, menuAction: proc(label: string): bool) =
  ## Keyboard shortcuts (TrenchBroom's defaults where they apply).
  let w = a.window
  let ui = a.ui
  if ui.focusId.len > 0 or a.modalOpen: return
  let c = w.ctrl
  let sh = w.shiftDown
  let al = w.alt
  # While flying (RMB + WASD) or orbiting, only the grid keys work.
  if a.drag.kind in {dkLook, dkOrbit}:
    discard a.gridKeys(c, al)
    return
  template pressed(k: Button): bool = w.buttonPressed[k]
  template run(label: string) = discard menuAction(label)
  let faceMode = a.selFaces.len > 0 and a.selection.len == 0 and a.selPieces.len == 0
  let handleMode = a.tool in {toolVertex, toolEdge, toolFace} and a.selHandles.len > 0

  if pressed(KeyEscape):
    if sh: a.setTool(toolSelect) else: a.cancel()
  elif c and sh and pressed(KeyS): run "Save As..."
  elif c and al and pressed(KeyS): run "Save a copy..."
  elif c and pressed(KeyS): run "Save"
  elif c and pressed(KeyO): run "Open project..."
  elif c and pressed(KeyN): run "New project..."
  elif c and pressed(KeyQ): run "Quit"
  elif c and al and pressed(KeyZ):
    for i in 0 .. 3:
      if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = 70'f32.degToRad
  elif c and pressed(KeyZ): (if sh: a.redo() else: a.undo())
  elif c and pressed(KeyY): a.redo()
  elif c and pressed(KeyD): a.duplicateSelection(vec3(0, 0, 0))
  elif c and pressed(KeyX): run "Cut"
  elif c and pressed(KeyC): run "Copy"
  elif c and al and pressed(KeyV): run "Paste at original position"
  elif c and pressed(KeyV): run "Paste"
  elif c and al and pressed(KeyA): run "Invert selection"
  elif c and sh and pressed(KeyA): a.clearSelection()
  elif c and pressed(KeyA): run "Select all"
  elif c and pressed(KeyB): a.selectSiblings()
  elif c and sh and pressed(KeyE): a.selectByBrushes(inside = true)
  elif c and pressed(KeyE): a.selectByBrushes(inside = true)
  elif c and pressed(KeyT): a.selectByBrushes(inside = false)
  elif c and pressed(KeyJ): a.csg("merge")
  elif c and sh and pressed(KeyK): a.csg("hollow")
  elif c and pressed(KeyK): a.csg("subtract")
  elif c and pressed(KeyL): a.csg("intersect")
  elif c and al and pressed(KeyF):
    if faceMode: a.flipTextures(false) else: a.flipSelection(mainAxis(a.viewAxes.up))
  elif c and pressed(KeyF):
    if faceMode: a.flipTextures(true) else: a.flipSelection(mainAxis(a.viewAxes.right))
  elif c and sh and pressed(KeyU): a.frameAll()
  elif c and pressed(KeyU): a.frameSelection()
  elif c and sh and pressed(KeyI): run "Show all"
  elif c and al and pressed(KeyI): run "Hide selection"
  elif c and pressed(KeyI): run "Isolate selection"
  elif c and al and pressed(KeyM): run "Move objects..."
  elif c and pressed(Key1): a.inspector = itMap
  elif c and pressed(Key2): a.inspector = itEntity
  elif c and pressed(Key3): a.inspector = itFace
  elif c and pressed(Key4): a.showBottom = not a.showBottom
  elif c and pressed(Key5): a.showInspector = not a.showInspector
  elif (c or w.meta) and pressed(KeySpace):
    a.maximized = if a.maximized >= 0: -1 else: max(a.hoverView, 0)
  elif c and (pressed(KeyEnter) or pressed(NumpadEnter)):
    a.clipSide = Side((ord(a.clipSide) + 1) mod 3)
  elif pressed(KeyF5): run "Play"
  elif pressed(KeyF7): run "Build"
  elif pressed(KeyEnter) or pressed(NumpadEnter):
    if a.tool == toolClip: a.applyClip()
    elif a.tool == toolBrush: a.createAssembled()
  elif pressed(KeyDelete) or pressed(KeyBackspace):
    if a.tool == toolClip and a.clipPoints.len > 0: a.clipPoints.setLen(a.clipPoints.len - 1)
    elif handleMode: discard a.deleteHandles()
    else: a.deleteSelection()
  elif sh and al and pressed(KeyR): a.resetTextures()
  elif sh and pressed(KeyR): a.resetTextures()
  elif not c and not al and pressed(KeyW): a.setTool(toolSelect)
  elif not c and not al and pressed(KeyB): a.setTool(toolBrush)
  elif not c and not al and pressed(KeyC): a.setTool(toolClip)
  elif not c and not al and pressed(KeyV): a.setTool(toolVertex)
  elif not c and not al and pressed(KeyE): a.setTool(toolEdge)
  elif not c and not al and pressed(KeyF): a.setTool(toolFace)
  elif not c and not al and not sh and pressed(KeyR): a.setTool(toolRotate)
  elif not c and not al and pressed(KeyT): a.setTool(toolScale)
  elif not c and not al and pressed(KeyU): a.uvLock = not a.uvLock
  elif not c and pressed(KeySpace): a.cycleView()
  elif a.gridKeys(c, al): discard
  else:
    let ax = a.viewAxes
    let step = if c: 1 / 64 elif sh: 1 / 4 else: 1 / 16
    for (k, dir) in [(KeyLeft, -ax.right), (KeyRight, ax.right), (KeyUp, ax.up), (KeyDown, -ax.up),
                     (KeyPageUp, ax.toViewer), (KeyPageDown, -ax.toViewer)]:
      if not pressed(k): continue
      if faceMode and not al:
        case k
        of KeyLeft: a.moveTextures(vec2(-step, 0), 0)
        of KeyRight: a.moveTextures(vec2(step, 0), 0)
        of KeyUp: a.moveTextures(vec2(0, -step), 0)
        of KeyDown: a.moveTextures(vec2(0, step), 0)
        of KeyPageUp: a.moveTextures(vec2(0, 0), (if c: 1 elif sh: 90 else: 15))
        of KeyPageDown: a.moveTextures(vec2(0, 0), -(if c: 1 elif sh: 90 else: 15).float32)
        else: discard
      elif al:
        # Alt+arrows: yaw (left/right), roll (up/down), pitch (PgUp/PgDn).
        case k
        of KeyLeft: a.rotateKeyed(vec3(0, 1, 0), 1, "Yaw")
        of KeyRight: a.rotateKeyed(vec3(0, 1, 0), -1, "Yaw")
        of KeyUp: a.rotateKeyed(ax.right.cross(ax.up).normalize, 1, "Roll")
        of KeyDown: a.rotateKeyed(ax.right.cross(ax.up).normalize, -1, "Roll")
        of KeyPageUp: a.rotateKeyed(ax.right, 1, "Pitch")
        of KeyPageDown: a.rotateKeyed(ax.right, -1, "Pitch")
        else: discard
      elif handleMode:
        a.moveHandles(dir * a.grid)
      elif a.tool == toolRotate and not c:
        a.rotCenter += dir * a.grid
        a.rotCenterText = fmtVec(a.rotCenter)
      elif c:
        a.duplicateSelection(dir * a.grid)
      else:
        a.moveSelection(dir * a.grid)
      return
