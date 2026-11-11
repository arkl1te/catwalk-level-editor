## The map views: layout (with draggable dividers), rendering of overlays
## (objects, selection, tool feedback, grids, labels), camera navigation, the
## editing tools and their mouse and keyboard input.
##
## Input follows TrenchBroom's tool chain: a left press is a click until the
## mouse moves 2 pixels, then a drag; drags shorter than 0.1 s are dropped.
## With no modal tool active, a click selects, a drag on the selection moves
## it (Ctrl duplicates), Shift+drag on a selected brush's face extrudes it (and the selection's faces on its plane),
## Ctrl+drag paints a selection, Ctrl+Shift+drag with faces selected cuts them from the nearest edge,
## and a drag anywhere else with nothing selected
## draws a new brush. Modal tools (brush, vertex/edge/face, clip, rotate,
## scale) switch the moving, extruding and drawing off while they are active.

import std/[strutils, strformat, math, tables, sets, algorithm, sequtils, times, hashes]
import silky, vmath, bumpy, pixie
import theme, ui, menutree
import levelobjects, camera, render, geometry, geomops, appstate, presets, library, objtemplates, sky, project
from music import hasSoundCache
from particlesim import hasParticleCache

const
  DragThreshold = 2'f32     ## Pixels a press moves before it becomes a drag.
  MinDragTime = 0.1         ## Shorter drags are accidental and undone.
  HandleRadius = 7'f32
  RotateRingPx = 64'f32     ## Rotate tool ring radius on screen.
  GizmoArrowPx = 72'f32     ## Translation gizmo arrow length on screen.
  GizmoSquareFrom = 0.2'f32   ## Plane squares span this much of an arrow's length...
  GizmoSquareTo = 0.5'f32     ## ...along both of their axes.
  HandleCol = [247'u8, 230, 59, 255]   ## TrenchBroom's handle color (render/Colors/Handle).

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
    if not a.viewPickable(o): continue
    let (lo, hi) = o.pickBox
    let t = o.pickRay(r, (lo, hi))
    if t >= 0:
      byObj[o] = result.len
      result.add Cand(obj: o, piece: -1, face: -1, t: t, area: a.projectedArea(vi, lo, hi))
  if a.geometryVisible:
    var byPiece: Table[int32, int]
    let hittable = a.facePickable(vi, r)
    # Only the faces of pieces whose bounds the ray goes through.
    let hit = a.piecesHit(r)
    var faces: seq[int]
    for pc, h in hit:
      if h: faces.add a.facesOfPiece(pc.int32)
    faces.sort()   # as the faces come: the nearest wins ties as before
    for i in faces:
      let f = a.geo.faces[i]
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
      for pc, k in byPiece:
        for fi in a.facesOfPiece(pc):
          for v in a.geo.faces[fi].verts:
            lo[k] = min(lo[k], a.geo.points[v])
            hi[k] = max(hi[k], a.geo.points[v])
      for pc, k in byPiece: result[k].area = a.projectedArea(vi, lo[k], hi[k])
  for c in result.mitems: c.point = r.origin + r.dir * c.t
  result.sort(proc(x, y: Cand): int = cmp(x.t, y.t))

proc pickOf(a: App, vi: int, cs: seq[Cand]): Cand =
  ## pick's choice among candidates cs.
  if cs.len == 0: return noCand()
  if a.is3D(vi): return cs[0]
  result = cs[0]
  for c in cs:
    if c.area < result.area - 0.01: result = c

proc pick*(a: App, vi: int, mouse: Vec2): Cand =
  ## TrenchBroom's choice: the nearest thing in 3D; in 2D the thing with the
  ## smallest area on the view plane, so occluded objects stay clickable.
  a.pickOf(vi, a.candidates(vi, mouse))

proc faceUnder*(a: App, vi: int, mouse: Vec2): (int, Vec3) =
  ## Frontmost editable geometry face under the mouse (faces, not objects).
  result = (-1, vec3(0, 0, 0))
  if not a.geometryEditable: return
  let r = a.viewRay(vi, mouse)
  let (fi, t) = a.geo.pickFace(r, a.facePickable(vi, r))
  if fi >= 0: result = (fi, r.origin + r.dir * t)

proc isSelected(a: App, c: Cand): bool =
  if c.obj != nil: c.obj.selected else: c.piece in a.selPieces

proc selectedUnder(a: App, vi: int, mouse: Vec2): Cand =
  ## What a drag moves: the picked thing if it's selected, else the nearest
  ## selected thing under the mouse, even behind or inside something else
  ## (TrenchBroom's move tool takes the first selected hit).
  let cs = a.candidates(vi, mouse)
  let p = a.pickOf(vi, cs)
  if p.found and a.isSelected(p): return p
  for c in cs:
    if a.isSelected(c): return c
  noCand()

var hoverMemo: tuple[frame, view: int, mouse: Vec2, found: bool]

proc hoveringSelection(a: App, vi: int): bool =
  ## Whether the mouse is over something selected in view vi, for the
  ## overlays (worked out once a frame: both ask). Not while the camera
  ## moves: flying, orbiting or panning isn't hovering.
  if a.drag.kind in {dkLook, dkOrbit, dkPan}: return false
  let m = a.ui.mouse
  if hoverMemo.frame == a.frameNo and hoverMemo.view == vi and hoverMemo.mouse == m:
    return hoverMemo.found
  let found = a.selectedUnder(vi, m).found
  hoverMemo = (a.frameNo, vi, m, found)
  found

# --- selection helpers ------------------------------------------------------------------------

proc selectCand(a: App, c: Cand, on = true) =
  # A thing in a closed group selects the outermost closed group (TrenchBroom's
  # findOutermostClosedGroupOrNode).
  let gid = if c.obj != nil: a.objGroup(c.obj) elif c.piece >= 0: a.pieceGroup(c.piece) else: 0'i32
  let unit = a.unitOf(gid)
  if unit != 0:
    a.selectGroup(unit, on)
    return
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
    if f.objectId == -1 and not a.geo.pieces[f.piece].hidden and not a.pieceLocked(f.piece):
      result.incl f.piece

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

proc selectedCornerKeys*(a: App): HashSet[string] =
  for h in a.handles:
    if h.id in a.selHandles:
      for c in h.corners: result.incl pkey(c)

proc pointsAtKeys(a: App, faces: HashSet[int], keys: HashSet[string]): HashSet[int32] =
  for fi in faces:
    for v in a.geo.faces[fi].verts:
      if pkey(a.geo.points[v]) in keys: result.incl v

# --- tool geometry: clip plane, rotate and scale handles ---------------------------------------

proc colinear(p, q, r: Vec3): bool =
  let (u, v) = (q - p, r - p)
  u.cross(v).length <= 1e-4 * max(u.length * v.length, 1e-6)

proc clipHelpVector(a: App): Vec3 =
  ## TrenchBroom's PointClipStrategy::computeHelpVector: the axis most of the
  ## points' help vectors run along; a tie goes to the vertical axis, else to X.
  ## Counted in TrenchBroom's axis order (its Z is Catwalk's Y).
  const tbOrder = [0, 2, 1]
  var counts: array[6, int]
  for p in a.clipPoints:
    for h in p.help:
      let k = axisIndex(h)
      let t = tbOrder.find(k)
      inc counts[if h[k] > 0: t else: t + 3]
  var first = 0
  for i in 1 .. 5:
    if counts[i] > counts[first]: first = i
  var next = -1
  for i in first + 1 .. 5:
    if next < 0 or counts[i] > counts[next]: next = i
  if next < 0 or counts[first] > counts[next]: result[tbOrder[first mod 3]] = 1
  elif first mod 3 == 2 or next mod 3 == 2: result = vec3(0, 1, 0)
  else: result = vec3(1, 0, 0)

proc clipThirdPoint(a: App): (bool, Vec3) =
  ## With two points, the plane's third: 128 units from the second along the
  ## help vector, so the cut runs straight along a face's or view's axis.
  if a.clipPoints.len != 2: return
  let p = a.clipPoints[1].pos + a.clipHelpVector * 128
  if colinear(a.clipPoints[0].pos, a.clipPoints[1].pos, p): return
  (true, p)

proc clipPlane*(a: App): (bool, Plane) =
  ## The plane to cut along. Its normal points to what Keep front keeps:
  ## TrenchBroom's front brushes, which lie behind its clip face (for a
  ## double-clicked face, behind that face).
  if a.clipFace.len >= 3:
    var n = vec3(0, 0, 0)
    var c = vec3(0, 0, 0)
    for i, p in a.clipFace:
      let q = a.clipFace[(i + 1) mod a.clipFace.len]
      n.x += (p.y - q.y) * (p.z + q.z)
      n.y += (p.z - q.z) * (p.x + q.x)
      n.z += (p.x - q.x) * (p.y + q.y)
      c += p
    if n.length < 1e-6: return
    return (true, plane(-n.normalize, c / a.clipFace.len.float32))
  var pts: seq[Vec3]
  for p in a.clipPoints: pts.add p.pos
  let (ok3, p3) = a.clipThirdPoint
  if ok3: pts.add p3
  if pts.len < 3: return
  let n = (pts[1] - pts[0]).cross(pts[2] - pts[0])
  if n.length < 1e-6: return
  (true, plane(n.normalize, pts[0]))

proc resetClip*(a: App) =
  a.clipPoints.setLen 0
  a.clipFace.setLen 0

proc resetRotateCenter*(a: App) =
  let (ok, c) = a.selectionCenter
  if ok: a.rotCenter = c
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

# --- translation gizmo ---------------------------------------------------------------------------
# Selected entities get X/Y/Z arrows (with no modal tool). Dragging one moves
# the selection along that world axis only.

proc gizmoShown*(a: App): bool =
  a.tool == toolSelect and a.selection.len > 0 and
    a.drag.kind in {dkNone, dkGizmo, dkMove, dkLook, dkOrbit, dkPan, dkIgnore}

proc gizmoCenter*(a: App): Vec3 =
  ## Middle of the selected entities' boxes.
  let sel = a.selection
  for o in sel:
    let (lo, hi) = o.pickBox
    result += (lo + hi) / 2
  if sel.len > 0: result = result / sel.len.float32

proc gizmoLength(a: App, vi: int, c: Vec3): float32 =
  ## World length of an arrow so it is GizmoArrowPx on screen.
  let cam = a.views[vi].cam
  if cam.kind != vk3D: return GizmoArrowPx / max(cam.zoom, 1e-4)
  let b = a.views[vi].viewBody
  let d = max((c - cam.pos).dot(cam.forward), 1)
  GizmoArrowPx * 2 * d * tan(cam.fovY / 2) / max(b.h, 1)

proc gizmoArrows(a: App, vi: int): seq[tuple[axis: int, base, tip: Vec2]] =
  ## The arrows on screen. One pointing (nearly) at the viewer is left out.
  let c = a.gizmoCenter
  let (ok, p) = a.toScreen(vi, c)
  if not ok: return
  let l = a.gizmoLength(vi, c)
  for axis in 0 .. 2:
    var e = vec3(0, 0, 0)
    e[axis] = 1
    let (ok2, q) = a.toScreen(vi, c + e * l)
    if ok2 and (q - p).length > GizmoArrowPx * 0.2: result.add (axis, p, q)

proc gizmoSquares(a: App, vi: int): seq[tuple[normal: int, quad: array[4, Vec2]]] =
  ## The squares between each pair of arrows, by the axis their plane faces.
  ## One seen (nearly) edge-on is left out.
  let c = a.gizmoCenter
  let l = a.gizmoLength(vi, c)
  for n in 0 .. 2:
    var u, v = vec3(0, 0, 0)
    u[(n + 1) mod 3] = 1
    v[(n + 2) mod 3] = 1
    let (s0, s1) = (l * GizmoSquareFrom, l * GizmoSquareTo)
    var quad: array[4, Vec2]
    var ok = true
    for k, (du, dv) in [(s0, s0), (s1, s0), (s1, s1), (s0, s1)]:
      let (okk, q) = a.toScreen(vi, c + u * du + v * dv)
      ok = ok and okk
      quad[k] = q
    if not ok: continue
    let d1 = quad[2] - quad[0]
    let d2 = quad[3] - quad[1]
    let area = abs(d1.x * d2.y - d1.y * d2.x) / 2
    let side = (s1 - s0) / l * GizmoArrowPx
    if area > side * side * 0.15: result.add (n, quad)

proc insideQuad(m: Vec2, q: array[4, Vec2]): bool =
  var pos, neg = false
  for k in 0 .. 3:
    let e = q[(k + 1) mod 4] - q[k]
    let cr = e.x * (m.y - q[k].y) - e.y * (m.x - q[k].x)
    if cr > 0: pos = true
    if cr < 0: neg = true
  not (pos and neg)

proc gizmoAt(a: App, vi: int, m: Vec2): string =
  ## "axis0".."axis2" (an arrow), "plane0".."plane2" (a square, by its
  ## plane's normal axis) or "".
  if not a.gizmoShown: return
  for (n, quad) in a.gizmoSquares(vi):
    if m.insideQuad(quad): return "plane" & $n
  var best = 7'f32
  for (axis, p, q) in a.gizmoArrows(vi):
    let d = segDist(m, p + (q - p) * 0.15, q)
    if d < best:
      best = d
      result = "axis" & $axis

proc alongAxis(r: Ray, origin, e: Vec3): (bool, float32) =
  ## Where the line origin + e*s comes closest to the ray, as s.
  let w0 = origin - r.origin
  let b = e.dot(r.dir)
  let denom = 1 - b * b
  if denom < 1e-6: return (false, 0)
  (true, (b * r.dir.dot(w0) - e.dot(w0)) / denom)

# --- volume handles -------------------------------------------------------------------------------
# A selected sound's Box or trigger volume gets a handle in the middle of each
# face, like the face tool's. Dragging one moves that face along its axis.

proc boxHandles(a: App, vi: int): seq[tuple[obj: LevelObject, face: int, pos: Vec3]] =
  ## face = axis * 2 + 0 (the Min side) or 1 (the Max side), in the volume's
  ## own axes. 2D views leave out the two faces they see head-on.
  if a.tool != toolSelect: return
  let cam = a.views[vi].cam
  var toViewer = vec3(0, 0, 0)
  if cam.kind != vk3D: toViewer[axisIndex(cam.kind.axes.toViewer)] = 1
  for o in a.selection:
    if o.tag notin ["SNDG", "TRGV"] or not a.visible(o): continue
    let (has, lo, hi) = o.volumeRange
    if not has: continue
    let turn = o.volumeTurn
    let c = (lo + hi) / 2
    for f in 0 .. 5:
      let ax = f div 2
      var e = vec3(0, 0, 0)
      e[ax] = 1
      if abs((turn * e).dot(toViewer)) > 0.999: continue
      var p = c
      p[ax] = if f mod 2 == 0: lo[ax] else: hi[ax]
      result.add (o, f, o.pos + turn * p)

proc boxHandleAt(a: App, vi: int, m: Vec2): int =
  ## Index into boxHandles of the handle under the mouse, or -1.
  result = -1
  var best = HandleRadius
  for k, h in a.boxHandles(vi):
    let (ok, q) = a.toScreen(vi, h.pos)
    if not ok: continue
    let d = (q - m).length
    if d < best:
      best = d
      result = k

proc pruneBoxFaces(a: App) =
  ## Drops selected face handles whose object isn't selected and shown any more.
  a.selBoxFaces.keepItIf(it.obj.selected and a.visible(it.obj))

proc boxFaceSelected(a: App, o: LevelObject, f: int): bool = (obj: o, face: f) in a.selBoxFaces

# --- rectangle selection --------------------------------------------------------------------------
# With entities selected, a drag from empty space (or from something not
# selected) draws a rectangle, like the vertex tool's lasso. Whichever it
# touches first, volume face handles or entities, is what it selects.

proc selRect(a: App, m: Vec2): Rect =
  let b = a.views[a.drag.view].viewBody
  let p0 = a.drag.startMouse
  let lo = max(vec2(min(p0.x, m.x), min(p0.y, m.y)), b.xy)
  let hi = min(vec2(max(p0.x, m.x), max(p0.y, m.y)), b.xy + b.wh)
  rect(lo.x, lo.y, max(hi.x - lo.x, 0), max(hi.y - lo.y, 0))

proc rectBoxFaces(a: App, r: Rect): seq[tuple[obj: LevelObject, face: int]] =
  for (o, f, p) in a.boxHandles(a.drag.view):
    let (ok, q) = a.toScreen(a.drag.view, p)
    if ok and q.inside(r): result.add (o, f)

proc rectObjects(a: App, r: Rect): seq[LevelObject] =
  ## Entities whose pick box, on screen, overlaps r.
  for o in a.objects:
    if not a.viewPickable(o): continue
    let (lo, hi) = o.pickBox
    var (slo, shi) = (vec2(Inf.float32), vec2(-Inf.float32))
    var any = false
    for k in 0 .. 7:
      let c = vec3(if (k and 1) == 0: lo.x else: hi.x, if (k and 2) == 0: lo.y else: hi.y,
                   if (k and 4) == 0: lo.z else: hi.z)
      let (ok, q) = a.toScreen(a.drag.view, c)
      if not ok: continue
      any = true
      slo = min(slo, q)
      shi = max(shi, q)
    if any and slo.x <= r.x + r.w and shi.x >= r.x and slo.y <= r.y + r.h and shi.y >= r.y:
      result.add o

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

proc cutEdgeAt*(a: App, vi: int, m: Vec2): (int, Vec3, Vec3) =
  ## The selected face Ctrl+Shift+drag would cut and the edge the cut would
  ## leave from: the edge nearest the mouse of the face under it, else of any
  ## selected face. Face -1 when there's none, so the drag paints.
  result[0] = -1
  if a.geo == nil or a.selFaces.len == 0 or a.hasNodeSelection or a.tool != toolSelect: return
  let r = a.viewRay(vi, m)
  var under = -1
  var bestT = Inf.float32
  for fi in a.selFaces:
    let f = a.geo.faces[fi]
    if f.objectId != -1 or f.verts.len < 3: continue
    let p0 = a.geo.points[f.verts[0]]
    for k in 1 ..< f.verts.len - 1:
      let t = r.rayTriangle(p0, a.geo.points[f.verts[k]], a.geo.points[f.verts[k + 1]])
      if t >= 0 and t < bestT:
        bestT = t
        under = fi
  var best = Inf.float32
  for fi in a.selFaces:
    if under >= 0 and fi != under: continue
    let f = a.geo.faces[fi]
    if f.objectId != -1 or f.verts.len < 3: continue
    for k in 0 ..< f.verts.len:
      let (p, q) = (a.geo.points[f.verts[k]], a.geo.points[f.verts[(k + 1) mod f.verts.len]])
      let (o1, p1) = a.toScreen(vi, p)
      let (o2, p2) = a.toScreen(vi, q)
      if not (o1 and o2) or (q - p).length < 1e-3: continue
      let d = segDist(m, p1, p2)
      if d < best:
        best = d
        result = (fi, p, q)

proc cutAxis(a: App, fi: int, p, q: Vec3): Vec3 =
  ## From face fi's edge p..q into the face, along its plane.
  let f = a.geo.faces[fi]
  result = a.geo.normal(f).cross(q - p).normalize
  if result.dot(a.geo.center(f) - p) < 0: result = -result

proc cutGroup*(a: App, fi: int, p, q: Vec3): seq[(int, Vec3, Vec3)] =
  ## The edge and the selected faces' other edges at the same distance, leading
  ## out of their faces the same way (what extrudeGroup is to faces): they
  ## extend together. Not an edge two selected faces share: it isn't open.
  result = @[(fi, p, q)]
  let axis = a.cutAxis(fi, p, q)
  let line = plane(axis, p)
  var used: HashSet[(string, string)]
  for i in a.selFaces:
    let f = a.geo.faces[i]
    for k in 0 ..< f.verts.len:
      used.incl (pkey(a.geo.points[f.verts[k]]), pkey(a.geo.points[f.verts[(k + 1) mod f.verts.len]]))
  for i in a.selFaces:
    let f = a.geo.faces[i]
    if f.objectId != -1 or f.verts.len < 3: continue
    if abs(a.geo.normal(f).dot(axis)) > 0.01 or line.dist(a.geo.center(f)) <= 0.01: continue
    for k in 0 ..< f.verts.len:
      let (u, v) = (a.geo.points[f.verts[k]], a.geo.points[f.verts[(k + 1) mod f.verts.len]])
      if abs(line.dist(u)) > 0.02 or abs(line.dist(v)) > 0.02 or (u - v).length < 1e-3: continue
      if (pkey(v), pkey(u)) in used: continue
      if i == fi and pkey(u) == pkey(p) and pkey(v) == pkey(q): continue
      result.add (i, u, v)

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

# --- brush tool shape ---------------------------------------------------------------------------

type AssembleShape* = object
  ## What the brush tool's points make, as TrenchBroom's polyhedron: a brush
  ## once they span a volume, a polygon while they lie in one plane (Shift+drag
  ## on it raises it into a brush), else a line or a point.
  pts*: seq[Vec3]            ## The placed points, plus a rectangle or copy being dragged.
  planes*: seq[Plane]        ## Brush: its planes, else empty.
  polys*: seq[seq[Vec3]]     ## Brush: its faces. Polygon: its outline. Else the line or the point.
  polygon*: bool
  normal*: Vec3              ## Polygon: its normal.

proc flatNormal(pts: seq[Vec3]): (bool, Vec3) =
  ## The normal of the plane all of pts lie in; false when they span a volume
  ## or no area.
  if pts.len < 3: return
  let p0 = pts[0]
  var p1 = p0
  for p in pts:
    if (p - p0).length > (p1 - p0).length: p1 = p
  var n = vec3(0, 0, 0)
  for p in pts:
    let c = (p1 - p0).cross(p - p0)
    if c.length > n.length: n = c
  if n.length < 1e-4: return
  n = n.normalize
  for p in pts:
    if abs((p - p0).dot(n)) > 0.01: return   # hullPlanes' tolerance
  (true, n)

proc flatOutline(pts: seq[Vec3], n: Vec3): seq[Vec3] =
  ## The convex outline of points in a plane with normal n, counterclockwise
  ## seen from n's side (points inside it or on its edges are left out).
  let u = (if abs(n.x) < 0.9: vec3(1, 0, 0) else: vec3(0, 1, 0)).cross(n).normalize
  let v = n.cross(u)
  var ps = uniquePoints(pts)
  ps.sort(proc(a, b: Vec3): int = cmp((a.dot(u), a.dot(v)), (b.dot(u), b.dot(v))))
  proc turn(o, a, b: Vec3): float32 = (a - o).cross(b - o).dot(n)
  var lower, upper: seq[Vec3]
  for p in ps:
    while lower.len >= 2 and turn(lower[^2], lower[^1], p) <= 1e-4: lower.setLen lower.len - 1
    lower.add p
  for i in countdown(ps.high, 0):
    let p = ps[i]
    while upper.len >= 2 and turn(upper[^2], upper[^1], p) <= 1e-4: upper.setLen upper.len - 1
    upper.add p
  result = lower[0 ..< lower.high] & upper[0 ..< upper.high]

var shapeCache: tuple[pts: seq[Vec3], shape: AssembleShape]

proc assembleShape*(a: App): AssembleShape =
  var pts = a.assemblePoints
  if a.drag.kind in {dkAssembleRect, dkAssembleDup}: pts.add a.drag.corners
  if pts == shapeCache.pts: return shapeCache.shape
  result.pts = pts
  if pts.len > 0:
    result.planes = hullPlanes(pts)
    if result.planes.len > 0:
      for (_, poly) in solidFromPlanes(result.planes): result.polys.add poly
    else:
      let (flat, n) = flatNormal(pts)
      if flat:
        result.polygon = true
        result.normal = n
        result.polys.add flatOutline(pts, n)
      else:
        # A line (its two ends) or a point.
        var p1 = pts[0]
        for p in pts:
          if (p - pts[0]).length > (p1 - pts[0]).length: p1 = p
        var p2 = p1
        for p in pts:
          if (p - p1).length > (p2 - p1).length: p2 = p
        result.polys.add (if (p2 - p1).length < 1e-3: @[p1] else: @[p1, p2])
  shapeCache = (pts, result)

proc polygonUnder(a: App, vi: int, m: Vec2, s: AssembleShape): (bool, Vec3) =
  ## Where the mouse ray meets the brush tool's polygon, in 3D (TrenchBroom
  ## starts its Shift+drag only there).
  if not s.polygon or not a.is3D(vi): return
  let r = a.viewRay(vi, m)
  let o = s.polys[0]
  for k in 1 ..< o.len - 1:
    let t = r.rayTriangle(o[0], o[k], o[k + 1])
    if t >= 0: return (true, r.origin + r.dir * t)

# --- overlays ----------------------------------------------------------------------------------

type ClipPreview = object
  kept, cut: Geometry          ## Only the clipped pieces: what is kept, and what goes.

var clipCache: tuple[key: string, preview: ClipPreview]

proc clipPreview(a: App): ClipPreview =
  ## What the clip would keep and cut off (TrenchBroom draws both, the cut
  ## part see-through).
  let (ok, pl) = a.clipPlane
  if not ok or (a.selPieces.len == 0 and a.selFaces.len == 0) or a.geo == nil: return
  let faces = toSeq(a.selFaces).sorted
  let key = &"{a.geo.version}|{a.clipPoints}|{a.clipFace}|{a.clipSide}|{toSeq(a.selPieces).sorted}|{faces}"
  if key == clipCache.key: return clipCache.preview
  proc part(side: Side): Geometry =
    result = a.geo.clone
    if a.selPieces.len == 0:
      let left = result.clipFaces(faces, pl, side)
      var g = result
      result.faces = left.mapIt(g.faces[it])
      return
    var others: HashSet[int32]
    for pc in 0 ..< result.pieces.len:
      if pc.int32 notin a.selPieces: others.incl pc.int32
    result.removePieces(others)
    var all: HashSet[int32]
    for pc in 0 ..< result.pieces.len: all.incl pc.int32
    result.clipPieces(all, pl, side, proc(t: string): float32 = 64)
  var pv = ClipPreview(kept: part(a.clipSide))
  case a.clipSide
  of sideFront: pv.cut = part(sideBack)
  of sideBack: pv.cut = part(sideFront)
  of sideBoth: discard
  clipCache = (key, pv)
  pv

proc drawExtent(a: App): (Vec3, Vec3) = a.drag.extent

proc updatePreview(a: App) =
  ## The brushes being drawn or assembled, textured as they will be once
  ## created (TrenchBroom draws them like that, see render.PreviewTint).
  var key = ""
  var g: Geometry = nil
  let attr = a.newFaceAttr
  if a.geo != nil and a.drag.kind == dkDraw:
    let (lo, hi) = a.drawExtent
    let solids = shapeSolids(a.shape, lo, hi, a.shapeSides.int, a.shapeSteps.int, a.drag.axis)
    key = "draw " & $solids & $attr
    if key != a.rend.previewKey:
      # As createShape makes them.
      g = Geometry()
      for planes in solids:
        var attrs: seq[FaceAttr]
        for _ in planes: attrs.add attr
        discard g.addSolid(planes, attrs, a.densityFn)
  elif a.geo != nil and a.tool == toolBrush:
    let s = a.assembleShape
    if s.planes.len > 0:
      key = "hull " & $s.pts & $attr
      if key != a.rend.previewKey:
        # As createAssembled makes it.
        g = Geometry()
        discard g.addHull(s.pts, attr, a.densityFn)
  if key != a.rend.previewKey:
    let app = a
    a.rend.setPreview(key, g, proc(n: string): string = app.texturePath(n))

const DupFlashTime = 0.5  ## Seconds the in-place duplicate flash takes to fade.

type ObjLook = object
  ## What the views draw of an object that comes from its data, not where it
  ## is: kept between edits (see objLook), as TrenchBroom keeps its entity
  ## renderers until something changes.
  look: tuple[half: Vec3, lift: float32, col: array[4, uint8]]
  hasModel: bool
  model: ObjectModel
  hasScreen: bool
  screen, image: string
  hasVolume: bool
  volLo, volHi: Vec3

var objLooks: Table[LevelObject, ObjLook]
var objLookStamp: (int, int, int, int, pointer, bool)

proc objLook(a: App, o: LevelObject): ObjLook =
  ## o's ObjLook, worked out again after an edit (any undo step, undo, redo),
  ## a new library, or for a selected object (a field being dragged may not
  ## have made its step yet).
  if not o.selected:
    let cached = objLooks.getOrDefault(o)
    if cached.look.col[3] != 0: return cached
  result.look = o.look
  if a.opts.models:
    (result.hasModel, result.model) = o.objectModel
    if o.tag == "CONS": (result.hasScreen, result.screen, result.image) = o.consoleScreen
  (result.hasVolume, result.volLo, result.volHi) = o.volumeRange
  if result.look.col[3] == 0: result.look.col[3] = 1   # 0 marks "not cached"
  if not o.selected: objLooks[o] = result

proc lookCorners(o: LevelObject, ol: ObjLook): array[8, Vec3] =
  ## o.corners from its ObjLook.
  if ol.hasModel:
    let t = objectMatrix(o.pos, o.rot)
    var i = 0
    for x in [ol.model.lo.x, ol.model.hi.x]:
      for y in [ol.model.lo.y, ol.model.hi.y]:
        for z in [ol.model.lo.z, ol.model.hi.z]:
          result[i] = t * vec3(x, y, z)
          inc i
    return
  let l = ol.look
  if o.tag == "PART":
    let t = objectMatrix(o.pos, o.rot)
    for i, k in boxCorners(vec3(0, l.lift, 0), l.half, 0): result[i] = t * k
    return
  boxCorners(o.pos + vec3(0, l.lift, 0), l.half, o.rot.y)

proc buildOverlays*(a: App) =
  let r = a.rend
  r.lines.setLen 0
  r.tris.setLen 0
  r.overlayTris.setLen 0
  r.overlayLines.setLen 0
  r.modelInstances.setLen 0
  r.arrows.setLen 0
  # After an in-place duplicate the selection's lines start white and fade back.
  let flash = clamp(1 - (epochTime() - a.dupFlashAt) / DupFlashTime, 0, 1)
  proc sel(c: array[4, uint8]): array[4, uint8] =
    let t = flash * flash
    for k in 0 .. 2: result[k] = uint8(c[k].float + (255 - c[k].float) * t)
    result[3] = uint8(c[3].float + (255 - c[3].float) * t)
  let fresh = modelsChanged()
  if fresh: r.clearModels()
  let stamp = (a.pushCount, a.undoStack.len, a.redoStack.len, a.objects.len, cast[pointer](a.proj), a.opts.models)
  if fresh or stamp != objLookStamp:
    objLooks.clear()
    objLookStamp = stamp
  for o in a.objects:
    if not a.visible(o): continue
    let ol = a.objLook(o)
    let l = ol.look
    let k = o.lookCorners(ol)
    # Objects with a model show it inside a plain box, like TrenchBroom.
    let (hasModel, model) = (ol.hasModel, ol.model)
    if hasModel:
      let t = objectMatrix(o.pos, o.rot)
      for part in model.parts:
        r.modelInstances.add ModelInstance(path: model.path, base: libraryDir(),
          transform: cast[M4](t * part),
          tint: (if o.selected: vec4(1, 0.6, 0.6, 1) else: vec4(1, 1, 1, 1)),
          wire: (if o.selected: sel(rgba(255, 110, 110, 200)) else: [l.col[0], l.col[1], l.col[2], 120'u8]))
    if a.opts.models and o.tag == "CONS":
      # The screen, showing the texture of the console's starting state.
      let (hasScreen, screen, image) = (ol.hasScreen, ol.screen, ol.image)
      if hasScreen:
        r.modelInstances.add ModelInstance(path: screen, base: libraryDir(), image: image,
          transform: cast[M4](objectMatrix(o.pos, o.rot)),
          tint: (if o.selected: vec4(1, 0.6, 0.6, 1) else: vec4(1, 1, 1, 1)),
          wire: [l.col[0], l.col[1], l.col[2], 120'u8])
    if not a.entityGizmo(o): continue
    if o.tag == DirLightTag:
      let c = if o.lightOn: l.col else: [l.col[0] div 3 + 60, l.col[1] div 3 + 60, l.col[2] div 3 + 60, 150'u8]
      if o.selected: r.overlayLines.sunGizmo(o.pos, sel(rgba(255, 70, 70)))
      else: r.lines.sunGizmo(o.pos, c)
    elif o.tag == SpotLightTag:
      let c = if o.lightOn: l.col else: [l.col[0] div 3 + 60, l.col[1] div 3 + 60, l.col[2] div 3 + 60, 150'u8]
      let (outer, inner) = o.spotAngles
      if o.selected:
        # Where its light reaches, and where it starts fading.
        let reach = max(o.light.radius, 1)
        r.overlayLines.spotGizmo(o.pos, o.lightDir, outer, reach, sel(rgba(255, 70, 70)))
        if inner > 0.5 and inner < outer - 0.5:
          r.overlayLines.spotGizmo(o.pos, o.lightDir, inner, reach, [l.col[0], l.col[1], l.col[2], 200'u8])
      else: r.lines.spotGizmo(o.pos, o.lightDir, outer, 14, c)
    elif o.tag == PointLightTag:
      if o.selected:
        r.tris.solidSphere(o.pos, PointBall, rgba(255, 60, 60, 70))
        r.overlayLines.wireSphere(o.pos, PointBall, sel(rgba(255, 70, 70)))
      elif not o.lightOn:
        r.lines.wireSphere(o.pos, PointBall, [l.col[0] div 3 + 60, l.col[1] div 3 + 60, l.col[2] div 3 + 60, 150'u8])
      else:
        r.tris.solidSphere(o.pos, PointBall, [l.col[0], l.col[1], l.col[2], 70'u8])
        r.lines.wireSphere(o.pos, PointBall, l.col)
    elif o.selected:
      if not hasModel: r.tris.solidBox(k, rgba(255, 60, 60, 70))
      r.overlayLines.wireBox(k, sel(rgba(255, 70, 70)))
    else:
      if not hasModel: r.tris.solidBox(k, [l.col[0], l.col[1], l.col[2], 70'u8])
      r.lines.wireBox(k, (if hasModel: [l.col[0], l.col[1], l.col[2], 150'u8] else: l.col))
    if a.showDirections:
      let (points, dir) = if o.tag in [SpotLightTag, DirLightTag]: (true, o.lightDir) else: o.pointing
      if points:
        let base = if o.tag == "PART": objectMatrix(o.pos, o.rot) * vec3(0, l.lift, 0)
                   else: o.pos + vec3(0, l.lift, 0)
        r.arrows.add DirArrow(base: base, dir: dir, onTop: o.selected,
                              col: if o.selected: sel(rgba(255, 70, 70)) else: l.col)
    if o.tag == PointLightTag and o.selected:
      # How far its light reaches.
      r.overlayLines.wireSphere(o.pos, o.light.radius, [l.col[0], l.col[1], l.col[2], 200'u8])
    elif o.tag == "SNDG" and o.selected and o.node.xpath("OSD/Sphere") != nil:
      # Where it's heard: full volume inside the first, silent past the second
      # (Oni's sound distances are world units / 3; see soundscene.nim).
      for (path, alpha) in [("OSD/Sphere/MinRadius", 200'u8), ("OSD/Sphere/MaxRadius", 110'u8)]:
        let radius = try: parseFloat(o.node.xpath(path).str.strip) * 3 except ValueError: 0.0
        if radius > 0: r.overlayLines.wireSphere(o.pos, radius.float32, [l.col[0], l.col[1], l.col[2], alpha])
    let (has, lo, hi) = (ol.hasVolume, ol.volLo, ol.volHi)
    if has and (o.selected or o.tag == "TRGV"):
      let kk = o.volumeCorners(lo, hi)
      if o.selected: r.overlayLines.wireBox(kk, sel(rgba(255, 70, 70)))
      else: r.lines.wireBox(kk, [l.col[0], l.col[1], l.col[2], 110'u8])
    if o.selected and a.geo != nil and o.objectCode != -1:
      for fi in a.ownedFaces(o):
        r.tris.faceFill(a.geo, a.geo.faces[fi], rgba(255, 60, 60, 60))
  if a.geo != nil:
    # The clip tool draws the selection as it would be after the cut instead.
    let clipping = a.tool == toolClip and a.clipPlane[0]
    # Only the selected pieces' and faces' (a level has tens of thousands).
    if not clipping and (a.selPieces.len > 0 or a.selFaces.len > 0):
      for p in a.selPieces:
        for i in a.facesOfPiece(p):
          let f = a.geo.faces[i]
          r.tris.faceFill(a.geo, f, rgba(255, 60, 60, 60))
          r.overlayLines.faceOutline(a.geo, f, sel(rgba(255, 70, 70)))
      for i in a.selFaces:
        if i notin 0 ..< a.geo.faces.len: continue
        let f = a.geo.faces[i]
        if f.piece in a.selPieces: continue
        r.tris.faceFill(a.geo, f, rgba(255, 60, 60, 110))
        r.overlayLines.faceOutline(a.geo, f, sel(rgba(255, 110, 110)))
    for fi in a.extrudeHoverFaces:
      if fi < a.geo.faces.len:
        r.overlayLines.faceOutline(a.geo, a.geo.faces[fi], rgba(255, 220, 40))
    for (_, p, q) in a.cutHover: r.overlayLines.line(p, q, rgba(255, 220, 40))
    for (p, q) in a.drag.cutLines: r.overlayLines.line(p, q, rgba(255, 220, 40))
    if a.drag.kind in {dkExtrude, dkSlide, dkSplit, dkStamp} and a.drag.face >= 0 and
       a.drag.geoBefore != nil:
      # The dragged faces where they are now: found by plane, as rebuilding a
      # brush renumbers its faces. Split and stamp drag the new brushes' faces.
      let g0 = a.drag.geoBefore
      let f0 = g0.faces[a.drag.face]
      let target = plane(g0.normal(f0), g0.center(f0) + a.drag.lastDelta)
      for f in a.geo.faces:
        if f.verts.len < 3 or f.objectId != -1 or
           not (f.piece in a.selPieces or f.piece >= g0.pieces.len): continue
        let q = a.geo.facePlane(f)
        if q.n.dot(target.n) > 0.999 and abs(q.d - target.d) < 0.1:
          r.overlayLines.faceOutline(a.geo, f, rgba(255, 220, 40))
  # Selection guide in 3D: the bounds' edges extended (TrenchBroom's spikes).
  let (sok, slo, shi) = a.selectionBounds
  let guide = sok and (a.drag.kind in {dkMove, dkHandles, dkScale, dkGizmo} or
              (a.hoverView >= 0 and a.is3D(a.hoverView) and
               a.hoveringSelection(a.hoverView)))
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
    # Edges in the selection's color; the faces are the textured preview (updatePreview).
    let (lo, hi) = a.drawExtent
    let dir = a.drag.axis
    for planes in shapeSolids(a.shape, lo, hi, a.shapeSides.int, a.shapeSteps.int, dir):
      for (_, poly) in solidFromPlanes(planes):
        for k in 0 ..< poly.len:
          r.overlayLines.line(poly[k], poly[(k + 1) mod poly.len], rgba(255, 70, 70))
  of dkMove, dkHandles, dkGizmo:
    if a.drag.moved:
      r.overlayLines.line(a.drag.startWorld, a.drag.startWorld + a.drag.lastDelta, rgba(255, 220, 40))
  else: discard
  if a.tool == toolClip:
    # TrenchBroom's PointClipStrategy::renderPoints / FaceClipStrategy::render.
    let cps = a.clipPoints
    if cps.len > 1: r.overlayLines.line(cps[0].pos, cps[1].pos, rgba(255, 150, 40))
    if cps.len > 2:
      r.overlayLines.line(cps[1].pos, cps[2].pos, rgba(255, 150, 40))
      r.overlayLines.line(cps[2].pos, cps[0].pos, rgba(255, 150, 40))
    for k, p in a.clipFace:
      r.overlayLines.line(p, a.clipFace[(k + 1) mod a.clipFace.len], rgba(255, 150, 40))
    for k in 1 ..< a.clipFace.len - 1:
      for c in [0, k, k + 1]: r.tris.add FlatVert(pos: a.clipFace[c], col: rgba(255, 150, 40, 70))
    let pv = a.clipPreview
    if pv.kept != nil:
      for f in pv.kept.faces:
        r.tris.faceFill(pv.kept, f, rgba(255, 60, 60, 60))
        r.overlayLines.faceOutline(pv.kept, f, rgba(255, 70, 70))
    if pv.cut != nil:
      for f in pv.cut.faces: r.lines.faceOutline(pv.cut, f, rgba(200, 200, 200, 110))
  if a.tool == toolBrush:
    # TrenchBroom's AssembleBrushToolController3D: the shape's edges in the
    # handle color (its corners are handles, drawViewOverlays), and with Shift
    # held, the polygon under the mouse filled to show it can be raised.
    let s = a.assembleShape
    for poly in s.polys:
      if poly.len == 2: r.overlayLines.line(poly[0], poly[1], HandleCol)
      elif poly.len > 2:
        for k in 0 ..< poly.len: r.overlayLines.line(poly[k], poly[(k + 1) mod poly.len], HandleCol)
    if s.polygon and a.drag.kind == dkNone and a.hoverView >= 0 and a.mods.only(s = true) and
       a.polygonUnder(a.hoverView, a.ui.mouse, s)[0]:
      let o = s.polys[0]
      let fill = [HandleCol[0], HandleCol[1], HandleCol[2], 128'u8]
      for k in 1 ..< o.len - 1:
        for p in [o[0], o[k], o[k + 1]]: r.overlayTris.add FlatVert(pos: p, col: fill)
  if a.tool == toolScale and sok:
    r.overlayLines.wireBox(boxCorners((slo + shi) / 2, (shi - slo) / 2, 0), rgba(160, 140, 255))
  a.updatePreview()

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
  # Alphas are for the default opacity 0.5 (Settings > View > Grid opacity).
  let prefs = if a.settingsOpen: a.settingsEdit else: a.cfg
  let op = prefs.gridOpacity / 0.5
  proc alpha(v: float): int = int(clamp(v * op, 0, 255))
  let gc = prefs.gridColor
  let minor = [gc[0].uint8, gc[1].uint8, gc[2].uint8, alpha(14).uint8]
  let major = [gc[0].uint8, gc[1].uint8, gc[2].uint8, alpha(34).uint8]
  proc axisCol(dir: Vec3): array[4, uint8] =
    let c = axisColor(axisIndex(dir))
    [c[0], c[1], c[2], alpha(130).uint8]
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
  if a.geo != nil: a.rend.setLiveColors(a.geo, float32(epochTime() - a.realtimeStart),
                                         a.realtime and ppLights in a.previewParts)
  a.buildOverlays()
  var opts = a.opts
  if not a.geometryVisible and opts.mode.wireframe: opts.mode = rmDynamicLight
  a.rend.grid3D = (if a.showGrid: a.grid else: 0)
  # The settings dialog previews their values until Save or Cancel.
  let prefs = if a.settingsOpen: a.settingsEdit else: a.cfg
  a.rend.showTriangles = prefs.showTriangles
  a.rend.gridColor = vec3(prefs.gridColor[0].float32, prefs.gridColor[1].float32,
                          prefs.gridColor[2].float32) / 255
  a.rend.gridColor3D = prefs.gridColor3D
  a.rend.gridAlpha = prefs.gridOpacity.float32
  a.rend.brightness = prefs.brightness.float32
  a.rend.setTextureFilter(prefs.linearFilter)
  let proj = a.proj
  a.rend.setSky(if proj != nil: proj.sky else: "", proc(sky, face: string): string = proj.skyImage(sky, face))
  if proj != nil: a.rend.skyGrade = proj.skyGrade
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

proc dashedLine*(ui: Ui, p, q: Vec2, color: ColorRGBX, dash, gap: float32, t = 1'f32,
                 clip = rect(0, 0, 0, 0)) =
  ## With a clip rect, only the part inside it is dashed (the pattern still
  ## starts at p). A corner just in front of the 3D camera projects millions
  ## of pixels away: dashing all of it took seconds a frame, and past ~2.7e8 px
  ## `s += dash + gap` stops changing in float32 and never ends.
  let len = (q - p).length
  if not (len >= 0.5 and len < Inf): return   # NaN fails both
  let d = (q - p) / len
  var s0 = 0'f32
  var s1 = len
  if clip.w > 0:
    # Liang–Barsky, in pixels along the line.
    for (dk, lo, hi, pk) in [(d.x, clip.x, clip.x + clip.w, p.x), (d.y, clip.y, clip.y + clip.h, p.y)]:
      if abs(dk) < 1e-9:
        if pk < lo or pk > hi: return
      else:
        var ta = (lo - pk) / dk
        var tb = (hi - pk) / dk
        if ta > tb: swap(ta, tb)
        s0 = max(s0, ta)
        s1 = min(s1, tb)
    if s0 >= s1: return
  let period = dash + gap
  var s = floor(s0 / period) * period
  while s < s1:
    ui.uiLine(p + d * max(s, s0), p + d * min(s + dash, s1), color, t)
    s += period

proc uiTriangle*(ui: Ui, p, q, s: Vec2, col: ColorRGBX) =
  let e = ui.sk.atlas.entries[WhiteTileKey]
  let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
  ui.sk.drawTriangle([p, q, s], [uv, uv, uv], [col, col, col])

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

proc clipPointAt(a: App, vi: int, m: Vec2, help: bool): (bool, ClipPoint)
proc setViewKind*(a: App, vi: int, next: ViewKind)
proc canAddClipPoint(a: App, p: Vec3): bool
proc clipPointNear(a: App, vi: int, m: Vec2): int

proc realtimeWaits*(a: App): string =
  ## What Realtime preview can't start without yet, as "Reading level 0's
  ## sounds (3/7)": its sounds and particles while they load ("" = nothing).
  ## The queue first: every view header asks every frame, and the caches'
  ## checks look at files.
  if (ppSounds in a.previewParts or ppMusic in a.previewParts) and a.loading("sounds") and
     not hasSoundCache():
    return a.loadingText("sounds")
  if ppParticles in a.previewParts and a.loading("particles") and not hasParticleCache():
    return a.loadingText("particles")

proc switchRealtime*(a: App) =
  ## Turns Realtime preview on or off; not on while what it plays still loads.
  if not a.realtime and a.realtimeWaits.len > 0:
    a.say("Realtime preview starts once this is done: " & a.realtimeWaits)
    return
  a.toggleRealtime()

proc headerButton(a: App, r: Rect, icon: string, on: bool, tip: string, alt = false,
                  outline = false, disabled = false): bool =
  ## A toggle in a view's header. alt outlines it in the accent color: the
  ## button's alternate mode is the one shown; outline draws a plain one.
  ## disabled: greyed out, with the tip saying why.
  let ui = a.ui
  if disabled:
    ui.icon(icon & "32", r.xy + r.wh / 2, colTextDisabled)
    ui.tip(r, tip)
    return false
  let hov = ui.hover(r)
  if on: ui.roundedRect(r, colAccentDim, 2)
  elif hov: ui.roundedRect(r, colHover, 2)
  if alt: ui.roundedBorder(r, colAccent, 2, 2)
  elif outline: ui.roundedBorder(r, if on or hov: colTextDim else: colBorder, 2)
  let col = if on or hov: colWhite else: colTextDim
  ui.icon(icon & "32", r.xy + r.wh / 2, col)
  ui.tip(r, tip)
  if hov and ui.pressed():
    ui.consumeClick()
    result = true

proc partsOutline(a: App, r: Rect, on, all: bool) =
  ## A header button with parts to choose from: solid while all of them are
  ## on, dashed with only some, nothing while it's off.
  if not on: return
  if all: a.ui.roundedBorder(r, colAccent, 2, 2)
  else: a.ui.dashedBorder(r, colAccent, 4, 3, 2)

proc drawViewHeader(a: App, vi: int, h: Rect, hot: bool) =
  ## The view's name (and the 3D render mode), then, like UnrealEd's viewport
  ## bar: Realtime preview, Gizmos, Invisible faces, the view kind (Top, Front, Side, Perspective) and
  ## the render modes. A mode button pressed again switches to its alternate
  ## (Lighting / Solid, Wireframe / Lit Wireframe).
  let ui = a.ui
  let kind = a.views[vi].cam.kind
  let title = if kind == vk3D: "3D · " & $a.opts.mode else: $kind
  ui.pushClip(h)
  let th = ui.textSize(title).y
  ui.text(title, vec2(h.x + 8, h.y + (h.h - th) / 2).floor, if hot: colText else: colTextDim)
  # The buttons stay put whatever the title says: after the longest one.
  var titleW = 0'f32
  for m in RenderMode: titleW = max(titleW, ui.textSize("3D · " & $m).x)
  for k in ViewKind: titleW = max(titleW, ui.textSize($k).x)
  var x = h.x + 8 + titleW + 12
  let bw = 36'f32
  proc next(): Rect =
    result = rect(x, h.y + 3, bw, h.h - 6)
    x += bw + 4
  proc separator() =
    x += 7
    ui.rect(rect(x, h.y + 11, 1, h.h - 22), colSeparator)
    x += 10
  # Right click: what it plays.
  let rt = next()
  let waits = if a.realtime: "" else: a.realtimeWaits
  let clicked = a.headerButton(rt, "gamepad", a.realtime,
                    if waits.len > 0: "Realtime preview: still loading. " & waits &
                                      ". Right click to choose what it plays"
                    else: "Realtime preview: animated vertex lighting plays, Sound objects can be heard " &
                          "from the 3D camera and the level music plays. Right click to choose which",
                    disabled = waits.len > 0)
  a.partsOutline(rt, a.realtime, a.previewParts == {PreviewPart.low .. PreviewPart.high})
  if clicked:
    if a.proj != nil: a.switchRealtime()
  elif ui.hover(rt) and ui.pressed(MouseRight):
    a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, realtime: true)
    a.menuSys.openContext(ui.mouse)
  # Right click: which object types.
  let gz = next()
  let gzClicked = a.headerButton(gz, "gizmo", a.showGizmos,
                    "Gizmos: the objects' boxes, light shapes, direction arrows and volumes. " &
                    "Selected objects keep theirs. Right click to choose which types")
  a.partsOutline(gz, a.showGizmos, a.gizmoHidden.len == 0)
  if gzClicked:
    if a.proj != nil: a.showGizmos = not a.showGizmos
  elif ui.hover(gz) and ui.pressed(MouseRight):
    a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, gizmos: true)
    a.menuSys.openContext(ui.mouse)
  if a.headerButton(next(), "eye", a.opts.invisible,
                    "Invisible faces: the light cyan faces flagged Invisible (invisible walls, " &
                    "stair ramps). Hidden ones can't be clicked either"):
    a.opts.invisible = not a.opts.invisible
    if a.geo != nil: a.geo.bump()
  separator()
  for (letter, k, name) in [("T", vkTop, "Top"), ("F", vkFront, "Front"), ("S", vkSide, "Side"),
                            ("P", vk3D, "Perspective (3D)")]:
    if a.headerButton(next(), "letter" & letter, kind == k, name & " view", outline = true):
      a.setViewKind(vi, k)
  separator()
  let mode = a.opts.mode
  for (m, alt, icon, altIcon) in [(rmDynamicLight, rmDynamicLight, "bulb", "bulb"),
                                  (rmUnlit, rmUnlit, "image", "image"),
                                  (rmLighting, rmSolid, "contrast", "solid"),
                                  (rmWireframe, rmLitWireframe, "cube", "cube")]:
    let isAlt = alt != m and mode == alt
    let tip = case m
      of rmDynamicLight: "Dynamic Light: textures lit by the vertex lighting"
      of rmUnlit: "Unlit: textures at full brightness"
      of rmLighting: "Lighting: the vertex lighting alone, no textures. " &
                     "Press again for Solid: plain faces, brighter the more they face the view, with cavity"
      else: "Wireframe: edges only. Press again for Lit Wireframe: edges in their vertex lighting colors"
    if a.headerButton(next(), (if isAlt: altIcon else: icon), mode in [m, alt], tip, isAlt):
      a.opts.mode = if mode == m: alt elif mode == alt: m else: m
  ui.popClip()

const
  NotesRange = 600'f32          ## How far an object's Notes show in the 3D view...
  NotesRangeHidden = 120'f32    ## ...and how far when a surface is in front of them.
  NotesMax = 48                 ## Most notes drawn at once (the nearest).

proc drawNotes(a: App, vi: int) =
  ## Objects' Notes floating over them in the 3D view, nearest on top.
  let ui = a.ui
  let v = a.views[vi]
  let b = v.viewBody
  let eye = v.cam.pos
  var near: seq[(float32, LevelObject, Vec3)]
  for o in a.objects:
    if not a.visible(o): continue
    let dist = (o.pos - eye).length
    if dist > NotesRange: continue
    let n = o.node.xpath("OSD/Notes")
    if n == nil or n.str.strip.len == 0: continue
    let (lo, hi) = o.pickBox
    let at = vec3((lo.x + hi.x) / 2, hi.y + 2, (lo.z + hi.z) / 2)
    near.add ((at - eye).length, o, at)
  near.sort(proc(x, y: (float32, LevelObject, Vec3)): int = cmp(x[0], y[0]))
  var shown: seq[(float32, LevelObject, Vec2, float32)]
  for (dist, o, at) in near:
    if shown.len >= NotesMax: break
    let (ok, p) = a.toScreen(vi, at)
    if not ok or not p.inside(b): continue
    let limit = if a.hiddenFrom(at, eye, o.objectCode): NotesRangeHidden else: NotesRange
    if dist > limit: continue
    # Fade out over the last fifth of the range.
    let fade = min(max((limit - dist) / (limit * 0.2'f32), 0'f32), 1'f32).float32
    shown.add (dist, o, p, fade)
  for k in countdown(shown.high, 0):
    let (_, o, p, fade) = shown[k]
    let text = o.node.xpath("OSD/Notes").str.strip.splitLines.join(" ")
    let lines = ui.wrapText(text, 220, 4, FontSmall)
    if lines.len == 0: continue
    let lh = ui.textSize("Ag", FontSmall).y
    var w = 0'f32
    for l in lines: w = max(w, ui.textSize(l, FontSmall).x)
    let sz = vec2(w + 12, lh * lines.len.float32 + 6)
    let r = rect(floor(p.x - sz.x / 2), floor(p.y - sz.y - 6), sz.x, sz.y)
    let al = (fade * 255).int
    ui.roundedRect(r, pm(30, 28, 18, (fade * 215).int), 4)
    ui.uiLine(vec2(p.x, r.y + r.h), p, pm(255, 220, 120, al div 2), 1)
    for j, l in lines:
      ui.text(l, vec2(r.x + 6, r.y + 3 + lh * j.float32), pm(255, 236, 170, al), FontSmall)

proc drawViewOverlays*(a: App) =
  ## View headers, handles, labels and the lasso (drawn by the UI layer).
  let ui = a.ui
  let (sok, slo, shi) = a.selectionBounds
  # Group boxes: the selected groups' and the open ones', named.
  var boxes, dashed: seq[(Vec3, Vec3, string, ColorRGBX)]
  if a.proj != nil and a.groups.len > 0:
    for u in a.selectedUnits[0]:
      let (ok, lo, hi) = a.groupBounds(u)
      let n = a.linkedCount(u)
      if ok: boxes.add (lo, hi, a.groupName(u) & (if n > 1: &" (linked ×{n})" else: ""), pm(255, 170, 60))
    for g in a.openGroups:
      let (ok, lo, hi) = a.groupBounds(g)
      if ok: boxes.add (lo, hi, a.groupName(g) & " (open)", pm(120, 200, 255))
    # The linked copies an edit of the selection reaches: dashed.
    for g in a.linkedOutlines:
      let (ok, lo, hi) = a.groupBounds(g)
      if ok: dashed.add (lo, hi, a.groupName(g) & " (linked)", pm(255, 170, 60))
  for i in 0 .. 3:
    let v = a.views[i]
    if v.rect.w < 2: continue
    let h = rect(v.rect.x, v.rect.y, v.rect.w, ViewHeader)
    let hot = a.hoverView == i
    ui.rect(h, if hot: colPanelRaised else: colPanel)
    a.drawViewHeader(i, h, hot)
    let b = v.viewBody
    if hot: ui.border(b, pm(157, 140, 255, 140))
    if a.proj == nil: continue
    ui.pushClip(b)
    let is3D = v.cam.kind == vk3D
    # Size of the selection: always in 2D, in 3D while hovering it or dragging.
    if sok and a.tool notin {toolVertex, toolEdge, toolFace} and
       (not is3D or a.drag.kind in {dkMove, dkScale, dkGizmo} or
        (hot and a.hoveringSelection(i))):
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
    # Translation gizmo on selected entities.
    if a.gizmoShown:
      let dragging = a.drag.kind == dkGizmo
      let dragAxis = axisIndex(a.drag.axis)
      for (n, quad) in a.gizmoSquares(i):
        let active = (dragging and a.drag.onPlane and dragAxis == n) or
                     (not dragging and hot and a.hoverHandle == "plane" & $n)
        if dragging and not active: continue
        let c = if active: HandleCol else: axisColor(n)
        let fill = pm(c[0].int, c[1].int, c[2].int, if active: 150 else: 70)
        ui.uiTriangle(quad[0], quad[1], quad[2], fill)
        ui.uiTriangle(quad[0], quad[2], quad[3], fill)
        for k in 0 .. 3: ui.uiLine(quad[k], quad[(k + 1) mod 4], c.toUi, if active: 2.0 else: 1.0)
      let arrows = a.gizmoArrows(i)
      for (axis, p, q) in arrows:
        # A dragged square keeps its two arrows.
        let active = (dragging and not a.drag.onPlane and dragAxis == axis) or
                     (dragging and a.drag.onPlane and axis != dragAxis) or
                     (not dragging and hot and a.hoverHandle == "axis" & $axis)
        if dragging and not active: continue
        let col = if active: HandleCol.toUi else: axisColor(axis).toUi
        let dir = (q - p).normalize
        let side = vec2(-dir.y, dir.x)
        let head = 12'f32
        let neck = q - dir * head
        ui.uiLine(p, neck, col, if active: 3.0 else: 2.0)
        ui.uiTriangle(q, neck + side * 5, neck - side * 5, col)
        ui.text(["X", "Y", "Z"][axis], q + dir * 6 + vec2(-4, -8), col, FontSmall)
      if arrows.len > 0: ui.uiCircle(arrows[0].base, 3, pm(235, 235, 235), filled = true)
    # Volume face handles.
    for k, (o, f, p) in a.boxHandles(i):
      let (ok, q) = a.toScreen(i, p)
      if not ok: continue
      let active = if a.drag.kind == dkBoxFace: a.drag.objs[0] == o and a.drag.face == f
                   else: hot and a.hoverHandle == "box" & $k
      let sel = a.boxFaceSelected(o, f)
      ui.uiCircle(q, 4, if active or sel: pm(255, 60, 60) else: pm(255, 220, 40), filled = true)
      if active:
        ui.uiCircle(q, 7, pm(255, 60, 60), 1.5)
        let ax = f div 2
        let (_, lo, hi) = o.volumeRange
        let letter = ["X", "Y", "Z"][ax]
        let label = if o.tag == "TRGV": "Size " & letter & ": " & fmtNum(hi[ax] - lo[ax])
                    else: (if f mod 2 == 0: "Min " else: "Max ") & letter & ": " &
                          fmtNum(if f mod 2 == 0: lo[ax] else: hi[ax]) &
                          "  (size " & fmtNum(hi[ax] - lo[ax]) & ")"
        ui.chip(label, q + vec2(0, -18), pm(200, 30, 30, 235), colWhite)
    # Brush tool: the shape's corners as handles, and a brush's size in 3D
    # (TrenchBroom shows its bounds there).
    if a.tool == toolBrush:
      let s = a.assembleShape
      var seen: HashSet[string]
      for poly in s.polys:
        for p in poly:
          if seen.containsOrIncl(pkey(p)): continue
          let (ok, q) = a.toScreen(i, p)
          if ok: ui.uiCircle(q, 4, HandleCol.toUi, filled = true)
      if is3D and s.planes.len > 0:
        var (lo, hi) = (vec3(Inf.float32), vec3(-Inf.float32))
        for p in s.pts:
          lo = min(lo, p)
          hi = max(hi, p)
        a.sizeLabels(i, lo, hi)
    # Clip points and their positions; the hovered or dragged one highlighted,
    # and where a click would put the next one (TrenchBroom's renderFeedback).
    if a.tool == toolClip:
      let dragging = a.drag.kind in {dkClipNew, dkClipPoint}
      let hotPoint =
        if a.drag.kind == dkClipPoint: a.drag.clipIndex
        elif a.drag.kind == dkClipNew: a.clipPoints.high
        elif hot: a.clipPointNear(i, ui.mouse)
        else: -1
      for k, p in a.clipPoints:
        let (ok, q) = a.toScreen(i, p.pos)
        if not ok: continue
        ui.uiCircle(q, 4, pm(255, 150, 40, 255), filled = true)
        if k == hotPoint: ui.uiCircle(q, 7, colWhite, 2)
        ui.chip(fmtVec(p.pos), q + vec2(0, -16), pm(200, 110, 20, 235), colWhite)
      if hot and not dragging and a.drag.kind == dkNone and hotPoint < 0 and ui.mouse.inside(b):
        let (ok, cp) = a.clipPointAt(i, ui.mouse, help = false)
        if ok and a.canAddClipPoint(cp.pos):
          let (sok, q) = a.toScreen(i, cp.pos)
          if sok: ui.uiCircle(q, 4, pm(255, 150, 40, 160), 1.5)
    # Move / draw feedback.
    case a.drag.kind
    of dkMove, dkHandles, dkGizmo:
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
    for bi, (lo, hi, name, col) in boxes & dashed:
      let dash = bi >= boxes.len
      var k: array[8, (bool, Vec2)]
      for c in 0 .. 7:
        k[c] = a.toScreen(i, vec3(if (c and 1) != 0: hi.x else: lo.x, if (c and 2) != 0: hi.y else: lo.y,
                                  if (c and 4) != 0: hi.z else: lo.z))
      for c in 0 .. 7:
        for bit in [1, 2, 4]:
          let d = c or bit
          if d != c and k[c][0] and k[d][0]:
            if dash: ui.dashedLine(k[c][1], k[d][1], col, 6, 4, clip = v.viewBody)
            else: ui.uiLine(k[c][1], k[d][1], col, 1.0)
      var top = vec2(Inf.float32, Inf.float32)
      for c in 0 .. 7:
        if k[c][0] and k[c][1].y < top.y: top = k[c][1]
      if top.y < Inf: ui.chip(name, top + vec2(0, -12), pm(20, 22, 26, 225), col)
    if a.openGroups.len > 0:
      var path: seq[string]
      for g in a.openGroups: path.add a.groupName(g)
      ui.chip("Group: " & path.join(" > ") & "  (Esc or double-click outside to close)",
              vec2(b.x + b.w / 2, b.y + 14), pm(30, 60, 90, 235), colWhite)
    # Object names in 2D: selected and hovered ones (all with View ▸ Object names).
    if not is3D:
      var n = 0
      for o in a.objects:
        if not (o.selected or o == a.hoverObj or (a.showObjectNames and a.entityGizmo(o))) or
           not a.visible(o): continue
        let (ok, p) = a.toScreen(i, o.pos)
        if ok and p.inside(b): ui.text(o.label, p + vec2(8, -18), colText, FontSmall)
        inc n
        if n > 300: break
    else:
      a.drawNotes(i)
    ui.popClip()
  if a.drag.kind in {dkBox, dkSelRect}:
    let v = a.views[a.drag.view]
    let p0 = a.drag.startMouse
    let p1 = ui.mouse
    let r = rect(min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x), abs(p1.y - p0.y))
    ui.pushClip(v.viewBody)
    ui.rect(r, colAccentDim)
    ui.border(r, colAccent)
    ui.popClip()

proc particlePanelRect*(a: App): Rect =
  ## Where the particle panel goes, while Particle objects are selected: over
  ## the 3D view (they only draw there), else the first view showing.
  if a.proj == nil or not a.selection.anyIt(it.tag == "PART"): return
  var view = -1
  for i in 0 .. 3:
    if a.views[i].rect.w < 2: continue
    if view < 0 or a.views[i].cam.kind == vk3D and a.views[view].cam.kind != vk3D: view = i
  if view < 0: return
  let b = a.views[view].viewBody
  let (w, h) = (3 * 36 + 2 * 4 + 12 + 12'f32, 38 + 12'f32)
  if b.w < w + 24 or b.h < h + 24: return
  rect(b.x + b.w - w - 12, b.y + b.h - h - 12, w, h)

proc drawParticlePanel*(a: App) =
  ## The selected Particle objects' Play, Stop and Loop.
  let r = a.particlePanelRect
  if r.w == 0: return
  let ui = a.ui
  ui.roundedRect(rect(r.x + 1, r.y + 3, r.w, r.h), colShadow, 6)
  ui.roundedRect(r, colPanel, 6)
  ui.roundedBorder(r, colBorder, 6)
  let sources = a.particleSources(a.selection.filterIt(it.tag == "PART"))
  var x = r.x + 6
  proc next(): Rect =
    result = rect(x, r.y + 6, 36, 38)
    x += 40
  let playing = a.particleSim != nil and sources.anyIt(it.id in a.particleSim.played)
  if a.headerButton(next(), "play", playing,
                    "Play: emits from the start, as the level's script would, with or without Realtime preview"):
    for s in sources:
      a.particlePlaying.incl s.id
      a.particlePlayNext.add s.id
  if a.headerButton(next(), "stop", false, "Stop: ends the emission. What's already flying finishes"):
    for s in sources: a.particleHaltNext.add s.id
  x += 6
  ui.rect(rect(x, r.y + 12, 1, r.h - 24), colSeparator)
  x += 7
  if a.headerButton(next(), "loop", a.particleLoop, "Loop: plays again when it finishes"):
    a.particleLoop = not a.particleLoop

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
                face: -1, piece: -1, xform: identityAffine())
  for o in a.selection:
    a.drag.objs.add o
    a.drag.startPose.add (o.pos, o.rot)
  a.drag.objBefore = snapshotObjects(a.drag.objs)
  if a.geo != nil:
    a.drag.geoBefore = a.geo.clone
    for v in points: a.drag.startPoints[v] = a.geo.points[v]
    if kind in {dkMove, dkRotate, dkScale}:
      # Only selected geometry: objects' own geometry is their model.
      var faces: HashSet[int]
      for fi in a.selectedFaceSet:
        if a.geo.faces[fi].verts.allIt(it in points): faces.incl fi
      a.drag.texHold = a.holdTextures(faces)

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

proc restoreSelection(a: App, sel: (seq[LevelObject], HashSet[int32], HashSet[int])) =
  for o in a.objects: o.selected = o in sel[0]
  a.selPieces = sel[1]
  a.selFaces = sel[2]

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
  of dkClipNew, dkClipPoint: a.clipPoints = d.clipBefore
  of dkBox: a.selHandles = d.handlesBefore
  else:
    if d.kind in {dkSplit, dkStamp, dkCut}: a.restoreSelection(d.selBefore)
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
    if d.kind in {dkMove, dkGizmo, dkRotate, dkScale}: a.transformSelectedGroups(d.xform)
    a.push editCmd(label, d.objs, d.objBefore, d.geoBefore, a.geo)
    if d.dup:
      # Duplicate and move are one step, as in TrenchBroom.
      let move = a.undoStack.pop
      a.undoStack[^1].geoAfter = if a.geo != nil: a.geo.clone else: nil
      a.undoStack[^1].extra.add move.extra
      if move.hasGroups:
        if not a.undoStack[^1].hasGroups: a.undoStack[^1].grpBefore = move.grpBefore
        a.undoStack[^1].hasGroups = true
        a.undoStack[^1].grpAfter = move.grpAfter
      a.undoStack[^1].label = "Duplicate"
  elif d.geoBefore != nil and a.geo != nil:
    # Nothing moved: drop the point detaching done at the start.
    a.restoreGeometry(d.geoBefore)
    if d.dup: a.undo()
  a.drag = Drag(kind: dkNone, face: -1, piece: -1)

# --- tools --------------------------------------------------------------------------------

proc applyClip*(a: App) =
  ## TrenchBroom's ClipTool::performClip: the selection is replaced by what is
  ## kept, which is selected; the points are reset.
  if a.geo == nil or a.drag.kind in {dkClipNew, dkClipPoint}: return
  let (ok, pl) = a.clipPlane
  if not ok: return
  let pieces = a.selPieces
  if pieces.len == 0 and a.selFaces.len > 0:
    let before = a.geo.clone
    let left = a.geo.clipFaces(toSeq(a.selFaces).sorted, pl, a.clipSide)
    if a.geo.faces == before.faces:
      a.geo = before
      a.say("Clip: the plane doesn't change the selected faces", true)
      return
    a.push geoCmd("Clip faces", before, a.geo)
    a.selFaces.clear()
    for fi in left: a.selFaces.incl fi
    a.resetClip()
    a.say "Clipped faces"
    return
  if pieces.len == 0:
    a.say("Clip: select the pieces or faces to cut first", true)
    return
  let before = a.geo.clone
  # The cut pieces are replaced by new ones appended at the end (the old ones
  # stay, empty, so nothing renumbers).
  let first = a.geo.pieces.len
  a.geo.clipPieces(pieces, pl, a.clipSide, a.densityFn)
  # Before the push: it appends the linked copies' pieces after these.
  let tail = a.geo.pieces.len
  a.push geoCmd("Clip", before, a.geo)
  a.selPieces.clear()
  for pc in first ..< tail: a.selPieces.incl pc.int32
  a.resetClip()
  a.say "Clipped"

proc mergeFaces(a: App) =
  ## TrenchBroom's convex merge of selected faces: one new brush, the convex hull
  ## of their corners. TB textures it with the current texture; here it looks
  ## like the faces (hullLike), so each one runs on across its plane. The
  ## faces' own pieces stay (any piece's faces work, not only brushes').
  if a.selFaces.len < 2:
    a.say("Convex merge: select at least two faces", true)
    return
  var pts: seq[Vec3]
  for fi in a.selFaces:
    for v in a.geo.faces[fi].verts: pts.add a.geo.points[v]
  let before = a.geo.clone
  let pc = a.geo.hullLike(pts, toSeq(a.selFaces).sorted, a.densityFn)
  if pc < 0:
    a.geo = before
    a.say("Convex merge: the faces span no volume", true)
    return
  a.push geoCmd("CSG Convex Merge", before, a.geo)
  a.clearSelection()
  a.selPieces.incl pc
  a.say "CSG merge"

proc joinPlanarFaces(a: App): bool =
  ## Ctrl+J on faces that all lie on one plane: one face where they make a
  ## convex shape. False when they don't lie on one plane (a convex merge then).
  let faces = toSeq(a.selFaces).sorted
  let f0 = a.geo.faces[faces[0]]
  let pl = a.geo.facePlane(f0)
  for fi in faces:
    let q = a.geo.facePlane(a.geo.faces[fi])
    if q.n.dot(pl.n) < 0.9999 or abs(q.d - pl.d) >= 0.1: return false
  result = true
  if faces.anyIt(a.geo.faces[it].objectId != -1):
    a.say("Join faces: faces of objects can't be joined", true)
    return
  let before = a.geo.clone
  let kept = a.geo.joinFaces(faces)
  if kept.len == 0:
    a.say("Join faces: they must touch along an edge, have the same flags and make a convex shape", true)
    return
  a.clearSelection()
  for fi in kept: a.selFaces.incl fi
  a.push geoCmd("Join faces", before, a.geo)
  a.say &"Joined faces on one plane: {faces.len} selected, {kept.len} result(s)"

proc separateSelection*(a: App) =
  ## Selected pieces fall apart into one piece per face; selected faces leave
  ## their pieces together, as one new piece. What comes out stays selected.
  if a.geo == nil: return
  a.expandGroupSelection()
  let before = a.geo.clone
  var made: seq[int32]
  if a.selPieces.len > 0:
    made = a.geo.separatePieces(toSeq(a.selPieces).sorted)
  else:
    let faces = toSeq(a.selFaces).sorted.filterIt(a.geo.faces[it].objectId == -1)
    if faces.len == 0:
      a.say("Separate: select pieces or faces first", true)
      return
    made = @[a.geo.separateFaces(faces)]
  a.push geoCmd("Separate", before, a.geo)
  a.selFaces.clear()
  a.selPieces.clear()
  for pc in made: a.selPieces.incl pc
  a.say &"Separated into {made.len} piece(s)"

proc joinSelection*(a: App) =
  ## Joins two selected meshes (pieces, or objects that own geometry such as
  ## furniture) end to end; see joinEnds.
  if a.geo == nil: return
  var parts: seq[seq[int]]
  let byPiece = a.geo.pieceFaces
  var pieces = toSeq(a.selPieces)
  pieces.sort
  for pc in pieces: parts.add byPiece[pc]
  for o in a.selection:
    if not a.hasGeometry(o): continue
    let fs = a.geo.objectFaces(o.objectCode)
    if a.geo.faces[fs[0]].piece notin a.selPieces: parts.add fs
  if parts.len != 2:
    a.say("Join: select two pieces or objects with geometry", true)
    return
  let before = a.geo.clone
  let err = a.geo.joinEnds(parts[0], parts[1])
  if err.len > 0:
    a.geo = before
    a.say("Join: " & err, true)
    return
  a.push geoCmd("Join", before, a.geo)
  a.say "Joined"

proc csg*(a: App, op: string) =
  if a.geo == nil: return
  if op == "merge" and a.selFaces.len > 0:
    if a.selFaces.len < 2 or not a.joinPlanarFaces(): a.mergeFaces()
    return
  var pieces = toSeq(a.selPieces)
  pieces.sort
  if pieces.len == 0:
    a.say("CSG: select brushes first", true)
    return
  if a.closedGroupSelected:
    # TrenchBroom's canDoCsg: the selection has to be only brushes.
    a.say("CSG: open the group first, it can't take a closed group", true)
    return
  let byPiece = a.geo.pieceFaces
  for pc in pieces:
    if not a.geo.isConvexClosed(byPiece[pc]):
      a.say("CSG needs convex brushes; piece " & $pc & " isn't one", true)
      return
  let before = a.geo.clone
  var ok = true
  # Pieces each op consumes; its results are appended after the survivors.
  var consumed = toHashSet(pieces)
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
    consumed = toHashSet(others)
    ok = a.geo.csgSubtract(others, pieces, a.densityFn) >= 0
  else: discard
  if not ok:
    a.geo = before
    a.say("CSG " & op & " produced nothing", true)
    return
  # Survivors keep their order; empty pieces (left by group edits) are
  # dropped too, so count them rather than subtract from the old total.
  var used = newSeq[bool](before.pieces.len)
  for f in before.faces:
    if f.verts.len >= 3 and f.piece >= 0 and f.piece < used.len: used[f.piece] = true
  var kept = 0
  for pc, u in used:
    if u and pc.int32 notin consumed: inc kept
  # Before the push: it appends the linked copies' pieces after these.
  let tail = a.geo.pieces.len
  a.push geoCmd("CSG " & op, before, a.geo)
  a.selPieces.clear()
  for pc in kept ..< tail: a.selPieces.incl pc.int32
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
  ## The source face's texture (and, unless textureOnly, its flags, tint and
  ## alignment) onto face fi. wrap (Alt+Shift) folds the alignment about the
  ## edge the two faces' planes meet on, so it runs on around corners.
  if fi == src: return
  let sf = a.geo.faces[src]
  if textureOnly:
    a.geo.retexture(fi, sf.texture, a.densityFn)
  else:
    a.geo.faces[fi].texture = sf.texture
    a.geo.faces[fi].flags = sf.flags
    a.geo.faces[fi].untint = sf.untint
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

proc faceSelectable(a: App, fi: int): bool =
  ## A face the selection-by-look commands may take: visible, and not in a
  ## locked group (TrenchBroom's collectSelectableBrushFaces).
  let f = a.geo.faces[fi]
  a.faceVisible(fi) and not (f.objectId == -1 and a.pieceLocked(f.piece))

proc selectFacesWithTexture*(a: App, tex: string) =
  ## TrenchBroom's texture browser "Select Faces": the selection becomes every
  ## selectable face with that texture (case-blind, as TB's materials).
  if a.geo == nil or not a.geometryEditable: return
  let key = tex.toLowerAscii
  a.clearSelection()
  for i, f in a.geo.faces:
    if f.texture.toLowerAscii == key and a.faceSelectable(i):
      a.selFaces.incl i
      a.lastFace = i
  a.say(if a.selFaces.len == 0: tex & " is on no selectable face"
        else: &"Selected {a.selFaces.len} face(s) with {tex}")

proc selectPiecesWithTexture*(a: App, tex: string) =
  ## TrenchBroom's "Select Brushes": the level pieces with a selectable face
  ## using the texture. Pieces are taken one by one, even in closed groups, so
  ## no piece without it comes along (TB does the same for entities).
  if a.geo == nil or not a.geometryEditable: return
  let key = tex.toLowerAscii
  a.clearSelection()
  for i, f in a.geo.faces:
    if f.objectId == -1 and f.texture.toLowerAscii == key and a.faceSelectable(i):
      a.selPieces.incl f.piece
  a.say(if a.selPieces.len == 0: tex & " is on no selectable piece"
        else: &"Selected {a.selPieces.len} piece(s) with {tex}")

proc sameFrame(x, y: TexFrame): bool =
  ## Two texture mappings the Face tab would show alike. Shifts wrap at 1.
  if x.ok != y.ok: return false
  if not x.ok: return true
  const Tol = 1e-3
  for k in 0 .. 1:
    let d = abs(x.shift[k] - y.shift[k])
    if min(d, 1 - d) > Tol or abs(x.scale[k] - y.scale[k]) > Tol: return false
  abs(x.rot - y.rot) <= 0.01

proc sameLook(a: App, f: Face, fr: TexFrame, g: Face, gr: TexFrame): bool =
  ## The Face tab's properties but shade (baked light, different on nearly
  ## every face): texture, mapping, flags, script id and tint.
  f.texture.toLowerAscii == g.texture.toLowerAscii and f.flags == g.flags and
    f.scriptId == g.scriptId and f.untint == g.untint and sameFrame(fr, gr)

proc selectMatchingFaces*(a: App) =
  ## The selected faces' looks pick every selectable face that looks exactly
  ## like one of them; the selection becomes those faces.
  if a.geo == nil or a.selFaces.len == 0: return
  var refs: seq[(int, TexFrame)]
  for fi in a.selFaces:
    if fi notin 0 .. a.geo.faces.high: continue
    let f = a.geo.faces[fi]
    let fr = a.geo.texFrame(fi, a.density(f.texture))
    if not refs.anyIt(a.sameLook(a.geo.faces[it[0]], it[1], f, fr)): refs.add (fi, fr)
  if refs.len == 0: return
  let keep = a.lastFace
  var found: HashSet[int]
  for i, f in a.geo.faces:
    if not a.faceSelectable(i) and i notin a.selFaces: continue
    # Cheap fields first: texFrame fits least squares per face.
    if not refs.anyIt(a.geo.faces[it[0]].texture.toLowerAscii == f.texture.toLowerAscii and
                      a.geo.faces[it[0]].flags == f.flags): continue
    let fr = a.geo.texFrame(i, a.density(f.texture))
    if refs.anyIt(a.sameLook(a.geo.faces[it[0]], it[1], f, fr)): found.incl i
  a.clearSelection()
  a.selFaces = found
  a.lastFace = if keep in found: keep else: -1
  if a.lastFace == -1:
    for fi in found:
      a.lastFace = fi
      break
  a.say &"Selected {found.len} face(s) with the same properties"

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

proc majorAxis(n: Vec3): Vec3 =
  ## vm::get_abs_max_component_axis: n's largest component's axis, with its sign.
  let k = axisIndex(n)
  result[k] = (if n[k] < 0: -1 else: 1)

proc viewHelpVector(a: App, vi: int): Vec3 =
  ## A 2D view's help vector: the camera's direction (TrenchBroom's PartDelegate2D).
  -a.views[vi].cam.kind.axes.toViewer

proc faceHelpVectors(a: App, fi: int, p: Vec3): seq[Vec3] =
  ## TrenchBroom's selectHelpVectors: the major axes of the normals of the
  ## faces a point placed on face fi touches. On a corner that's every face of
  ## the piece meeting there, on an edge the faces either side, else fi alone.
  const MaxDist = 0.01'f32
  let g = a.geo
  let f = g.faces[fi]
  var faces: seq[int]
  var best = MaxDist
  var corner = -1
  for v in f.verts:
    let d = (g.points[v] - p).length
    if d < best: (best, corner) = (d, v.int)
  if corner >= 0:
    let c = g.points[corner]
    for gi, h in g.faces:
      if h.piece != f.piece: continue
      for v in h.verts:
        if (g.points[v] - c).length < MaxDist:
          faces.add gi
          break
  else:
    best = MaxDist
    var edge = -1
    for k in 0 ..< f.verts.len:
      let (e0, e1) = (g.points[f.verts[k]], g.points[f.verts[(k + 1) mod f.verts.len]])
      let e = e1 - e0
      let t = if e.lengthSq > 1e-12: clamp((p - e0).dot(e) / e.lengthSq, 0, 1) else: 0
      let d = (e0 + e * t - p).length
      if d < best: (best, edge) = (d, k)
    if edge >= 0:
      let (e0, e1) = (g.points[f.verts[edge]], g.points[f.verts[(edge + 1) mod f.verts.len]])
      for gi, h in g.faces:
        if h.piece != f.piece: continue
        var has0, has1 = false
        for v in h.verts:
          if (g.points[v] - e0).length < MaxDist: has0 = true
          if (g.points[v] - e1).length < MaxDist: has1 = true
        if has0 and has1: faces.add gi
  if faces.len == 0: faces = @[fi]
  for gi in faces:
    let ax = majorAxis(g.normal(g.faces[gi]))
    if ax notin result: result.add ax

proc clipPointAt(a: App, vi: int, m: Vec2, help: bool): (bool, ClipPoint) =
  ## Where a new clip point goes (TrenchBroom's PartDelegate2D/3D): in 3D on
  ## the face under the mouse, snapped on its plane; in 2D on the view plane
  ## through the selection's center, snapped.
  if a.is3D(vi):
    let (fi, p) = a.faceUnder(vi, m)
    if fi < 0: return
    let q = a.snapOnFace(p, fi)
    return (true, ClipPoint(pos: q, help: (if help: a.faceHelpVectors(fi, q) else: @[])))
  let (okb, blo, bhi) = a.selectionBounds
  let q = a.snapV(a.pointOnView(vi, m, if okb: (blo + bhi) / 2 else: a.focus2D))
  (true, ClipPoint(pos: q, help: @[a.viewHelpVector(vi)]))

proc canAddClipPoint(a: App, p: Vec3): bool =
  ## TrenchBroom's PointClipStrategy::canAddPoint: three at most, none on
  ## another, the third not in line with the first two; none while clipping
  ## along a face.
  if a.clipFace.len > 0: return false
  for q in a.clipPoints:
    if (q.pos - p).length < 1e-3: return false
  a.clipPoints.len < 2 or
    (a.clipPoints.len == 2 and not colinear(a.clipPoints[0].pos, a.clipPoints[1].pos, p))

proc clipDragPos(a: App, m: Vec2): (bool, ClipPoint) =
  ## Where a dragged clip point goes: in 3D onto the face under the mouse; in
  ## 2D on the view plane through where the drag started, keeping the grab
  ## offset, snapped (TrenchBroom's handle position proposers).
  let d = a.drag
  if a.is3D(d.view): return a.clipPointAt(d.view, m, help = true)
  (true, ClipPoint(pos: a.snapV(a.pointOnView(d.view, m, d.startWorld) - d.handleOffset),
                   help: @[a.viewHelpVector(d.view)]))

proc dragClipPoint(a: App, k: int, cp: ClipPoint) =
  ## TrenchBroom's PointClipStrategy::dragPoint: never onto another point, nor
  ## in line with the other two.
  for i, q in a.clipPoints:
    if i != k and (q.pos - cp.pos).length < 1e-3: return
  if a.clipPoints.len == 3 and
     colinear(a.clipPoints[(k + 1) mod 3].pos, a.clipPoints[(k + 2) mod 3].pos, cp.pos): return
  a.clipPoints[k] = cp

proc clipPointNear(a: App, vi: int, m: Vec2): int =
  result = -1
  for i, p in a.clipPoints:
    let (ok, q) = a.toScreen(vi, p.pos)
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
  if md.none and a.gizmoAt(vi, m).len > 0: return
  case a.tool
  of toolClip:
    if md.none:
      let (ok, cp) = a.clipPointAt(vi, m, help = true)
      if ok and a.canAddClipPoint(cp.pos):
        a.clipPoints.add cp
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
  of toolSelect:
    # Volume face handles: select one (Ctrl toggles); any other click first
    # drops the selected ones, as the vertex tool does with its handles.
    a.pruneBoxFaces()
    if md.none or md.only(c = true):
      let bh = a.boxHandleAt(vi, m)
      if bh >= 0:
        let (o, f, _) = a.boxHandles(vi)[bh]
        let k = a.selBoxFaces.find((obj: o, face: f))
        if md.c:
          if k >= 0: a.selBoxFaces.delete k else: a.selBoxFaces.add (o, f)
        else:
          a.selBoxFaces = @[(obj: o, face: f)]
        return
      if not md.c and a.selBoxFaces.len > 0:
        a.selBoxFaces.setLen 0
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
      # TrenchBroom's FaceClipStrategy: the double-clicked face's plane.
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        a.clipPoints.setLen 0
        a.clipFace = a.geo.faces[fi].verts.mapIt(a.geo.points[it])
      return
  of toolBrush:
    if md.none and a.is3D(vi):
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        if a.assemblePoints.len > 0: a.assemblePoints.setLen max(0, a.assemblePoints.len - 1)
        for v in a.geo.faces[fi].verts: a.assemblePoints.add a.geo.points[v]
      return
  else: discard
  if md.al and not (md.c and md.s) and (not md.s or (a.selFaces.len == 1 and not a.hasNodeSelection)):
    # Alt / Alt+Ctrl / Alt+Shift double-click: the selected face's texture onto
    # the whole piece (Alt+Shift wraps, like the click). Without one selected
    # face, Shift+Alt falls through to selecting coplanar faces.
    if a.selFaces.len == 1 and not a.hasNodeSelection:
      let (fi, _) = a.faceUnder(vi, m)
      if fi >= 0:
        # The first click already copied to one face: make it the whole piece.
        if a.undoStack.len > 0 and a.undoStack[^1].label == "Copy texture":
          let c = a.undoStack.pop
          a.restoreGeometry(c.geoBefore)
        a.transferTexture(a.geo.pieceFaceIds(a.geo.faces[fi].piece), md.c, "Copy texture to piece", wrap = md.s)
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
  if not md.c:
    # TrenchBroom: double-clicking a group opens it; double-clicking outside
    # the open group (the rest is locked, so nothing is hit) closes it.
    if c.found:
      let gid = if c.obj != nil: a.objGroup(c.obj) else: a.pieceGroup(c.piece)
      let unit = a.unitOf(gid)
      if unit != 0:
        a.openGroup(unit)
        return
    elif a.openGroups.len > 0:
      a.closeGroup()
      return
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

proc faceSnapLines(a: App, fi: int, straight: bool): seq[(Vec3, Vec3)] =
  ## The lines face fi's corners travel along when it is dragged along its
  ## normal: straight along the normal when the corners are translated (slide,
  ## stamp, non-brush pieces), else along the brush's edges leaving the face,
  ## since a brush face moving on its plane slides its corners along those
  ## (TrenchBroom's Grid::snapMoveDistanceForFace).
  let f = a.geo.faces[fi]
  let n = a.geo.normal(f)
  if straight or not a.geo.pieces[f.piece].brush:
    for v in f.verts: result.add (a.geo.points[v], n)
    return
  let onFace = a.pieceCornerKeys(fi)
  for g in a.geo.pieceFaceIds(f.piece):
    if g == fi: continue
    let vs = a.geo.faces[g].verts
    for k, v in vs:
      let p = a.geo.points[v]
      if pkey(p) notin onFace: continue
      for q in [a.geo.points[vs[(k + vs.len - 1) mod vs.len]], a.geo.points[vs[(k + 1) mod vs.len]]]:
        let e = q - p
        # Edges of the face itself (both ends on it) don't move the corner.
        if pkey(q) in onFace or e.length < 1e-4: continue
        result.add (p, e.normalize)
  if result.len == 0:
    for v in f.verts: result.add (a.geo.points[v], n)

proc snapToGridPlane(o, dir: Vec3, dist, g: float32): float32 =
  ## The distance along the line o + t·dir nearest dist at which it crosses a
  ## grid plane meeting at the grid corner nearest o + dist·dir
  ## (TrenchBroom's Grid::snapToGridPlane).
  result = dist
  var best = Inf.float32
  let x = o + dir * dist
  for i in 0 .. 2:
    if abs(dir[i]) < 1e-6: continue
    let t = (snapTo(x[i], g) - o[i]) / dir[i]
    if abs(t - dist) < best:
      best = abs(t - dist)
      result = t

proc snapExtrude(a: App, dist: float32): float32 =
  ## Snaps a face drag's distance along its normal so a dragged corner lands on
  ## a grid plane, the snap nearest dist over every corner and its travel line.
  let n = a.drag.axis
  result = snapTo(dist, a.grid)
  var best = Inf.float32
  for (o, e) in a.drag.snapLines:
    let de = e.dot(n)
    if abs(de) < 1e-4: continue
    let s = snapToGridPlane(o, e, dist / de, a.grid) * de
    if abs(s - dist) < best:
      best = abs(s - dist)
      result = s

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
  a.drag.selBefore = (a.selection, a.selPieces, a.selFaces)
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
  # Snapping: how each corner of the dragged faces travels (TrenchBroom's
  # ExtrudeToolController snappers).
  a.drag.snapLines.setLen 0
  for g in a.extrudeGroup(fi):
    a.drag.snapLines.add a.faceSnapLines(g, kind in {dkSlide, dkStamp})

proc beginCut(a: App, vi: int, m: Vec2, fi: int, p, q: Vec3) =
  let f = a.geo.faces[fi]
  let edges = a.cutGroup(fi, p, q)
  a.startGeometryDrag(dkCut, vi, m, p, initHashSet[int32]())
  let n = a.geo.normal(f)
  let inward = a.cutAxis(fi, p, q)
  # Grab the point under the mouse on the face, so only its movement counts.
  let (ok, at) = a.viewRay(vi, m).planeHit(p, n)
  if ok and (at - p).length < 100000: a.drag.startWorld = at
  a.drag.face = fi
  a.drag.axis = inward
  a.drag.cutEdge = (p, q)
  a.drag.cutEdges = edges
  a.drag.selBefore = (a.selection, a.selPieces, a.selFaces)
  a.drag.snapLines = @[(p, inward), (q, inward)]

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
  # A volume's face handle: the selected faces (this one first, Ctrl
  # adds it) along its axis, or freely when some lie on other axes.
  let bh = a.boxHandleAt(vi, pressPos)
  if bh >= 0 and (md.none or md.only(c = true)):
    let (o, f, p) = a.boxHandles(vi)[bh]
    a.pruneBoxFaces()
    if not a.boxFaceSelected(o, f):
      if not md.c: a.selBoxFaces.setLen 0
      a.selBoxFaces.add (o, f)
    var e = vec3(0, 0, 0)
    e[f div 2] = 1
    e = o.volumeTurn * e
    let (ok, s0) = a.viewRay(vi, pressPos).alongAxis(p, e)
    if ok:
      var d = Drag(kind: dkBoxFace, view: vi, startMouse: pressPos, startWorld: p, startTime: epochTime(),
                   face: f, piece: -1, axis: e, along: s0)
      var objs = @[o]
      for (so, sf) in a.selBoxFaces:
        if so notin objs: objs.add so
        if sf div 2 != f div 2: d.free = true
      for so in objs:
        d.objs.add so
        d.objBefore.add so.snapshot
        let (_, lo, hi) = so.volumeRange
        d.boxStart.add (lo, hi)
        d.boxBase.add so.pos
      a.drag = d
      return
  # Gizmo: an arrow moves along its axis, a square on its plane (Ctrl: duplicate first).
  let gz = a.gizmoAt(vi, pressPos)
  if gz.len > 0 and (md.none or md.only(c = true)):
    let onPlane = gz.startsWith("plane")
    var e = vec3(0, 0, 0)
    e[parseInt(gz[^1 .. ^1])] = 1
    let c0 = a.gizmoCenter
    let r = a.viewRay(vi, pressPos)
    var (ok, s0, grab) = (false, 0'f32, c0)
    if onPlane: (ok, grab) = r.planeHit(c0, e)
    else: (ok, s0) = r.alongAxis(c0, e)
    if ok:
      if md.c: a.duplicateSelection(vec3(0, 0, 0), linked = a.selectionIsLinked)
      a.beginMove(vi, pressPos, c0)
      a.drag.kind = dkGizmo
      a.drag.dup = md.c
      a.drag.axis = e
      a.drag.along = s0
      a.drag.onPlane = onPlane
      a.drag.pivot = grab
      return
  # Move (Alt: vertical, Ctrl: duplicate first).
  let held = a.selectedUnder(vi, pressPos)
  if not modal and not md.s and held.found:
    var dup = false
    if md.c:
      a.duplicateSelection(vec3(0, 0, 0), linked = a.selectionIsLinked)
      dup = true
    a.beginMove(vi, pressPos, held.point)
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
  # Cut a selected face (Ctrl+Shift) from its nearest edge.
  if md.c and md.s and not md.al:
    let (fi, p, q) = a.cutEdgeAt(vi, pressPos)
    if fi >= 0:
      a.beginCut(vi, pressPos, fi, p, q)
      return
  # Paint more faces into a face selection (Shift).
  if md.only(s = true) and not modal and a.selFaces.len > 0 and not a.hasNodeSelection:
    let (fi, _) = a.faceUnder(vi, pressPos)
    if fi >= 0:
      let before = (a.selection, a.selPieces, a.selFaces)
      let faceBefore = (a.lastFace, a.faceTemplate)
      a.selFaces.incl fi
      a.lastFace = fi
      a.drag = Drag(kind: dkPaintFaces, view: vi, startMouse: pressPos, startTime: epochTime(),
                    selBefore: before, faceBefore: faceBefore, face: -1, piece: -1)
      return
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
      # TrenchBroom's MoveClipPointPart, then AddClipPointPart: drag a point,
      # or add one where the drag starts and a second that the drag moves.
      let k = a.clipPointNear(vi, pressPos)
      var start = -1
      if k >= 0:
        a.drag = Drag(kind: dkClipPoint, clipIndex: k)
        start = k
      else:
        let (ok, cp) = a.clipPointAt(vi, pressPos, help = true)
        if ok and a.canAddClipPoint(cp.pos):
          a.drag = Drag(kind: dkClipNew, clipIndex: a.clipPoints.len, clipBefore: a.clipPoints)
          a.clipPoints.add cp
          start = a.clipPoints.high
      if start >= 0:
        let p = a.clipPoints[start].pos
        if k >= 0: a.drag.clipBefore = a.clipPoints
        a.drag.view = vi
        a.drag.startMouse = pressPos
        a.drag.startWorld = p
        a.drag.startTime = epochTime()
        a.drag.face = -1
        a.drag.piece = -1
        if not is3D: a.drag.handleOffset = a.pointOnView(vi, pressPos, p) - p
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
      if md.only(s = true):
        # Shift+drag on the polygon (a triangle or more points in one plane):
        # a copy of it along its normal, so the two make a brush (TrenchBroom's
        # DuplicateFacePart). Off the polygon, Shift+drag does nothing.
        let s = a.assembleShape
        let (hit, p) = a.polygonUnder(vi, pressPos, s)
        if hit:
          var n = s.normal
          if n.dot(a.views[vi].cam.pos - p) < 0: n = -n   # the side the mouse grabbed
          a.drag = Drag(kind: dkAssembleDup, view: vi, startMouse: pressPos, startTime: epochTime(),
                        startWorld: p, axis: n, face: -1, piece: -1)
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
  # Rectangle selection while entities are selected (Ctrl toggles).
  if a.tool == toolSelect and a.selection.len > 0 and not md.s and not md.al:
    a.pruneBoxFaces()
    a.drag = Drag(kind: dkSelRect, view: vi, startMouse: pressPos, startTime: epochTime(),
                  face: -1, piece: -1)
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
  if a.snap: result = a.snapExtrude(result)

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
  # Split and stamp brushes join the group of the piece they come from.
  let group = a.geo.pieces[pc].group
  proc hull(pts: seq[Vec3], attr: FaceAttr) =
    let np = a.geo.addHull(pts, attr, a.densityFn, e.maps)
    if np >= 0: a.geo.pieces[np].group = group
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
        # A brush thinner than the cut lies wholly on the cut-off side: it stays
        # as it is, and the thicker ones are still cut.
        if not a.geo.replacePiece(pc, shrunk, e.maps, a.densityFn): return true
        slab.add moved.flipped
      let np = a.geo.pieces.len.int32
      a.geo.pieces.add Piece(brush: true, group: group)
      if not a.geo.replacePiece(np, slab, e.maps, a.densityFn): a.geo.pieces.setLen np
    else:
      for (c, attr) in e.faces:
        var pts = c
        for p in c: pts.add p + move
        hull(pts, attr)
  of dkStamp:
    for (c, attr) in e.faces:
      var pts = c
      for p in c: pts.add p + move
      hull(pts, attr)
  else: discard

proc selectSplitOff(a: App, outward: bool) =
  ## Split and stamp select the brushes they made, like TrenchBroom: only those
  ## when they grow out of the face, those and the cut brushes when a split
  ## goes inward.
  var made: HashSet[int32]
  for pc in a.drag.geoBefore.pieces.len ..< a.geo.pieces.len: made.incl pc.int32
  if made.len == 0: return
  if outward or a.drag.kind == dkStamp:
    a.clearSelection()
    a.selPieces = made
  else:
    for pc in made: a.selPieces.incl pc

proc rebuildDue(a: App, move: Vec3, last: bool): bool =
  ## A drag that rebuilds from geoBefore loses the bake: it does so only when
  ## its move changes, on a frame the bake runs too, so no unlit frame is drawn
  ## (they blink). last = the drag's end, which can't wait.
  if a.drag.built and a.drag.builtMove == move: return false
  if a.bakeWaits and not last: return false
  a.drag.built = true
  a.drag.builtMove = move
  if last: a.bakeAt = 0
  true

proc updateExtrude(a: App, m: Vec2, last = false) =
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
  if not a.rebuildDue(move, last): return
  a.restoreGeometry(d.geoBefore)
  a.drag.lastDelta = vec3(0, 0, 0)
  if d.kind in {dkSplit, dkStamp}: a.restoreSelection(d.selBefore)
  if abs(dist) < 1e-4: return
  for e in d.extrudes:
    if not a.extrudePiece(d.kind, e, dist, move):
      # One piece can't take it (it would lose its volume): none moves.
      a.restoreGeometry(d.geoBefore)
      return
  a.geo.bump()
  a.drag.lastDelta = move
  if d.kind in {dkSplit, dkStamp}: a.selectSplitOff(dist > 0)

proc finishExtrude(a: App, m: Vec2) =
  a.updateExtrude(m, last = true)
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
  a.push geoCmd(label, d.geoBefore, a.geo)
  a.drag = Drag(kind: dkNone, face: -1, piece: -1)

proc updateCut(a: App, m: Vec2, last = false) =
  ## The cut stays parallel to its edge and moves with the mouse, like an
  ## extrude's face; it goes through every selected face it crosses. Dragged
  ## the other way, out past the edge, it extends the face across its plane.
  let d = a.drag
  let dist = a.extrudeDistance(m)
  if not a.rebuildDue(d.axis * dist, last): return
  a.restoreGeometry(d.geoBefore)
  a.restoreSelection(d.selBefore)
  a.drag.cutLines.setLen 0
  a.drag.moved = false
  a.drag.cutOutward = dist < 0
  if abs(dist) < 1e-4: return
  if dist < 0:
    # Out past the edge: a new face on the plane, instead of a cut.
    let along = d.axis * dist
    for (fi, p, q) in d.cutEdges:
      let made = a.geo.extendFace(fi, p, q, along)
      if made < 0: continue
      a.selFaces.incl made
      a.drag.moved = true
      a.drag.cutLines.add [(p, p + along), (p + along, q + along), (q + along, q)]
    a.geo.bump()
    return
  let pl = plane(d.axis, d.cutEdge[0] + d.axis * dist)
  for fi in d.selBefore[2]:
    if a.geo.faces[fi].objectId != -1: continue
    let made = a.geo.cutFace(fi, pl)
    if made < 0: continue
    a.selFaces.incl made
    a.drag.moved = true
    let on = a.geo.faces[made].verts.filterIt(abs(pl.dist(a.geo.points[it])) < 0.02)
    if on.len >= 2: a.drag.cutLines.add (a.geo.points[on[0]], a.geo.points[on[^1]])
  a.geo.bump()

proc finishCut(a: App, m: Vec2) =
  a.updateCut(m, last = true)
  let d = a.drag
  if d.moved:
    # A cut is this copy's own: its linked copies keep their faces.
    var touched = d.selBefore[2].toSeq
    for (fi, _, _) in d.cutEdges: touched.add fi
    let separated = a.unlinkFaceGroups(d.geoBefore, touched)
    a.push geoCmd(if d.cutOutward: "Extend face" else: "Cut face", d.geoBefore, a.geo)
    if separated > 0:
      let verb = if d.cutOutward: "Extended" else: "Cut"
      a.say &"{verb} in this copy only: separated {separated} group(s) from their linked copies"
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  else: a.cancelDrag()

proc applyMoveDelta(a: App, delta: Vec3) =
  ## Moves the dragged objects and points to their start plus delta.
  if delta == a.drag.lastDelta: return
  a.drag.lastDelta = delta
  a.drag.xform = affineOf(proc(p: Vec3): Vec3 = p + delta)
  for i, o in a.drag.objs:
    a.setPose(o, a.drag.startPose[i][0] + delta, a.drag.startPose[i][1])
  if a.geo != nil and a.drag.startPoints.len > 0:
    for v, p in a.drag.startPoints: a.geo.points[v] = p + delta
    a.releaseTextures(a.drag.texHold, restore = true)
    a.geo.bump()

proc camUp(c: Camera): Vec3 = c.right.cross(c.forward)

proc canCarry(a: App, vi: int): bool =
  a.is3D(vi) and a.tool == toolSelect and
    (a.selection.len > 0 or (a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0)))

proc beginCarry(a: App, vi: int) =
  ## Left and right buttons together: a look drag that carries the selection,
  ## its center held where it is in front of the camera.
  let (ok, center) = a.selectionCenter
  if not ok: return
  a.beginMove(vi, vec2(0, 0), center)
  let cam = a.views[vi].cam
  let off = center - cam.pos
  a.drag.kind = dkLook
  a.drag.carry = true
  a.drag.carryLocal = vec3(off.dot(cam.right), off.dot(cam.camUp), off.dot(cam.forward))

proc updateCarry(a: App) =
  let cam = a.views[a.drag.view].cam
  let l = a.drag.carryLocal
  var delta = cam.pos + cam.right * l.x + cam.camUp * l.y + cam.forward * l.z - a.drag.startWorld
  if a.snap: delta = a.snapV(delta)
  a.applyMoveDelta(delta)

proc endCarry(a: App, cancel = false) =
  ## Commits (or undoes) the carried move; the look goes on while the right
  ## button is held.
  let view = a.drag.view
  if cancel: a.cancelDrag()
  else:
    a.drag.kind = dkMove
    a.drag.moved = a.drag.lastDelta != vec3(0, 0, 0)
    a.finishDrag("Move")
  if a.window.buttonDown[MouseRight]: a.drag = Drag(kind: dkLook, view: view, moved: true)

proc updateDrag(a: App, m: Vec2) =
  let w = a.window
  let md = a.mods
  case a.drag.kind
  of dkMove, dkHandles, dkGizmo:
    if (m - a.drag.startMouse).length > DragThreshold: a.drag.moved = true
    if not a.drag.moved: return
    var delta: Vec3
    if a.drag.kind == dkGizmo and a.drag.onPlane:
      let e = a.drag.axis
      let (ok, p) = a.viewRay(a.drag.view, m).planeHit(a.drag.pivot, e)
      if not ok: return
      delta = p - a.drag.pivot
      delta = delta - e * delta.dot(e)
    elif a.drag.kind == dkGizmo:
      let (ok, s) = a.viewRay(a.drag.view, m).alongAxis(a.drag.startWorld, a.drag.axis)
      if not ok: return
      delta = a.drag.axis * (s - a.drag.along)
    else:
      delta = a.dragDelta(m, md.s)
    if a.snap: delta = a.snapV(delta)   # relative snapping, like TrenchBroom
    a.applyMoveDelta(delta)
  of dkExtrude, dkSlide, dkSplit, dkStamp: a.updateExtrude(m)
  of dkCut: a.updateCut(m)
  of dkBoxFace:
    if (m - a.drag.startMouse).length > DragThreshold: a.drag.moved = true
    if not a.drag.moved: return
    var delta = vec3(0, 0, 0)
    if a.drag.free:
      delta = a.dragDelta(m, md.s)
      if a.snap: delta = a.snapV(delta)
    else:
      # The grabbed face lands on the grid (TrenchBroom snaps a resized face
      # there); the other selected faces move as much. On a turned volume no
      # world grid lines up with the face, so the distance snaps instead.
      let e = a.drag.axis
      let (ok, s) = a.viewRay(a.drag.view, m).alongAxis(a.drag.startWorld, e)
      if not ok: return
      let along = max(abs(e.x), max(abs(e.y), abs(e.z))) > 0.999
      let start = if along: a.drag.startWorld.dot(e) else: 0'f32
      var moved = s - a.drag.along
      if a.snap: moved = snapTo(start + moved, a.grid) - start
      delta = e * moved
    for i, o in a.drag.objs:
      let local = o.volumeTurn.inverse * delta
      var (lo, hi) = a.drag.boxStart[i]
      # A face moved alone stays at least a unit from the opposite one.
      for k in 0 .. 2:
        let (mn, mx) = (a.boxFaceSelected(o, k * 2), a.boxFaceSelected(o, k * 2 + 1))
        if mn: lo[k] += local[k]
        if mx: hi[k] += local[k]
        if mx and not mn: hi[k] = max(hi[k], lo[k] + 1)
        elif mn and not mx: lo[k] = min(lo[k], hi[k] - 1)
      a.setVolumeRange(o, a.drag.boxBase[i], lo, hi)
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
    a.drag.xform = affineOf(proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg))
    for i, o in a.drag.objs:
      let rot = turnRotation(a.drag.startPose[i][1], axis, deg)
      a.setPose(o, rotateAxis(a.drag.startPose[i][0], pivot, axis, deg), rot)
    if a.geo != nil and a.drag.startPoints.len > 0:
      for pv, p in a.drag.startPoints: a.geo.points[pv] = rotateAxis(p, pivot, axis, deg)
      a.releaseTextures(a.drag.texHold, restore = true)
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
    a.drag.xform = affineOf(remap)
    for i, o in a.drag.objs: a.setPose(o, remap(a.drag.startPose[i][0]), a.drag.startPose[i][1])
    if a.geo != nil:
      for pv, q in a.drag.startPoints: a.geo.points[pv] = remap(q)
      a.releaseTextures(a.drag.texHold, restore = true)
      a.geo.bump()
  of dkDraw: a.updateDraw(m)
  of dkBox: discard
  of dkSelRect:
    if a.drag.rectMode == 0:
      let r = a.selRect(m)
      if a.rectBoxFaces(r).len > 0: a.drag.rectMode = 1
      elif a.rectObjects(r).len > 0: a.drag.rectMode = 2
  of dkClipPoint, dkClipNew:
    let k = a.drag.clipIndex
    if a.drag.kind == dkClipNew and a.clipPoints.len == k + 1:
      # TrenchBroom's AddClipPointDragDelegate: once the mouse leaves the
      # first point, a second is added there, which the rest of the drag moves.
      let (ok, cp) = a.clipPointAt(a.drag.view, m, help = true)
      if ok and a.canAddClipPoint(cp.pos): a.clipPoints.add cp
    else:
      let j = if a.drag.kind == dkClipNew: k + 1 else: k
      let (ok, cp) = a.clipDragPos(m)
      if ok and j < a.clipPoints.len: a.dragClipPoint(j, cp)
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
    a.drag.corners = if abs(dist) < 1e-4: @[] else: a.assemblePoints.mapIt(it + n * dist)
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
        let pickable = a.facePickable(vi, r)
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
  of dkMove, dkGizmo: a.finishDrag(if d.dup: "Duplicate" else: "Move")
  of dkHandles: a.finishDrag($a.tool)
  of dkRotate: a.finishDrag("Rotate")
  of dkScale: a.finishDrag("Scale")
  of dkBoxFace: a.finishDrag("Resize volume")
  of dkExtrude, dkSlide, dkSplit, dkStamp: a.finishExtrude(m)
  of dkCut: a.finishCut(m)
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
  of dkSelRect:
    let r = a.selRect(m)
    let ctrl = a.window.ctrl
    var mode = d.rectMode
    if mode == 0:
      if a.rectBoxFaces(r).len > 0: mode = 1
      elif a.rectObjects(r).len > 0: mode = 2
    case mode
    of 1:
      # Volume face handles, toggled like the vertex tool's lasso.
      if not ctrl: a.selBoxFaces.setLen 0
      for h in a.rectBoxFaces(r):
        let k = a.selBoxFaces.find(h)
        if k >= 0: a.selBoxFaces.delete k else: a.selBoxFaces.add h
    of 2:
      let objs = a.rectObjects(r)
      let before = a.selection
      if not ctrl: a.clearSelection()
      elif a.selFaces.len > 0: a.clearSelection()
      # Each closed group toggles once, whichever member was inside.
      var units: HashSet[int32]
      for o in objs:
        let unit = a.unitOf(a.objGroup(o))
        if unit != 0 and units.containsOrIncl(unit): continue
        a.selectCand(Cand(obj: o, piece: -1, face: -1), on = not ctrl or o notin before)
      a.pruneBoxFaces()
    else:
      # Touched nothing: like a click on empty space.
      if not ctrl:
        if a.selBoxFaces.len > 0: a.selBoxFaces.setLen 0
        else: a.clearSelection()
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
      if a.undoStack.len > 0 and d.placed in a.undoStack[^1].objs: a.amendLast()
      a.say "Placed " & (if d.preset.generic: "a new " & typeName(d.placed.tag) else: d.preset.label)
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)
  else:
    a.drag = Drag(kind: dkNone, face: -1, piece: -1)

# --- mouse ----------------------------------------------------------------------------------

proc lookDelta(a: App, d: Vec2): Vec2 =
  ## Mouse motion for looking and orbiting, scaled and inverted per Settings > Mouse.
  result = d * (a.cfg.lookSpeed / 0.5).float32
  if a.cfg.lookInvertX: result.x = -result.x
  if a.cfg.lookInvertY: result.y = -result.y

proc wheelSign(a: App): float32 = (if a.cfg.invertWheel: -1 else: 1)

proc handleViews*(a: App, dt: float32) =
  let ui = a.ui
  let w = a.window
  let m = ui.mouse
  let blocked = ui.captured or a.modalOpen or a.menuSys.isOpen or a.splitDrag.len > 0 or
                m.inside(a.particlePanelRect)
  a.hoverView = if blocked: -1 else: a.viewAt(m)
  if a.drag.kind == dkPlace: a.hoverView = if blocked and a.menuSys.contextOpen: -1 else: a.viewAt(m)
  elif a.drag.kind != dkNone: a.hoverView = a.drag.view
  elif a.press.active: a.hoverView = a.press.view
  let vi = a.hoverView
  if vi >= 0: a.activeView = vi
  a.hoverObj = nil
  a.extrudeHover = -1
  a.extrudeHoverFaces.setLen 0
  a.cutHover.setLen 0

  # Camera drags.
  case a.drag.kind
  of dkLook:
    if not w.buttonDown[MouseRight]:
      if a.drag.moved or a.drag.carry: a.rmbPress.dragging = true
      if a.drag.carry: a.endCarry()
      a.drag.kind = dkNone
    else:
      # Left button too: carry the selection (it can come and go mid-look).
      if a.drag.carry and not w.buttonDown[MouseLeft]: a.endCarry()
      elif not a.drag.carry and w.buttonPressed[MouseLeft] and not ui.clickConsumed and
           a.canCarry(a.drag.view):
        ui.consumeClick()
        a.beginCarry(a.drag.view)
      let cam = addr a.views[a.drag.view].cam
      let d = a.lookDelta(w.mouseDelta.vec2)
      if d.length > 0: a.drag.moved = true
      cam.yaw -= d.x * 0.004
      cam.pitch = clamp(cam.pitch - d.y * 0.004, -1.55, 1.55)
      # Wheel while flying: up = faster, down = slower.
      let notches = a.wheelSign * ui.wheelNotches
      if notches != 0 and not ui.scrollConsumed:
        a.flySpeed = clamp(a.flySpeed * pow(FlyWheelStep, -notches), MinFlySpeed, MaxFlySpeed)
        a.drag.moved = true
        a.say(if a.flySpeed < 10: &"Fly speed {a.flySpeed:.1f}" else: &"Fly speed {a.flySpeed.round.int}")
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
      if a.drag.carry: a.updateCarry()
      return
  of dkOrbit:
    if not w.buttonDown[MouseRight]:
      if a.drag.moved: a.rmbPress.dragging = true
      a.drag.kind = dkNone
    else:
      let cam = addr a.views[a.drag.view].cam
      let d = a.lookDelta(w.mouseDelta.vec2)
      if d.length > 0: a.drag.moved = true
      let notches = a.wheelSign * ui.wheelNotches
      if notches != 0 and not ui.scrollConsumed:
        a.drag.orbitDist = clamp(a.drag.orbitDist * pow(1.15'f32, notches), 8, 40000)
      cam.yaw -= d.x * 0.006
      cam.pitch = clamp(cam.pitch - d.y * 0.006, -1.5, 1.5)
      cam.pos = a.drag.pivot - cam[].forward * a.drag.orbitDist
      return
  of dkNone:
    # WASD without the right button: walk the 3D view the mouse was last over,
    # unless a text field has the keys, a menu or dialog is open, or a
    # modifier is held (those keys are shortcuts then).
    let av = a.activeView
    if not blocked and ui.focusId.len == 0 and av >= 0 and av < a.views.len and a.is3D(av) and
       a.views[av].rect.w > 1 and not (w.ctrl or w.shiftDown or w.alt or w.meta):
      let cam = addr a.views[av].cam
      var mv = vec3(0, 0, 0)
      if w.buttonDown[KeyW] and KeyW notin ui.navTaken: mv += cam[].forward
      if w.buttonDown[KeyS] and KeyS notin ui.navTaken: mv -= cam[].forward
      if w.buttonDown[KeyD] and KeyD notin ui.navTaken: mv += cam[].right
      if w.buttonDown[KeyA] and KeyA notin ui.navTaken: mv -= cam[].right
      cam.pos += mv * (a.flySpeed * dt)
  of dkPan:
    if not (w.buttonDown[MouseMiddle] or w.buttonDown[MouseRight]):
      if a.drag.moved: a.rmbPress.dragging = true
      a.drag.kind = dkNone
    else:
      var d = w.mouseDelta.vec2 / a.sk.uiScale * (a.cfg.panSpeed / 0.5).float32
      if a.cfg.panInvertX: d.x = -d.x
      if a.cfg.panInvertY: d.y = -d.y
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
      # The group under the click, looking past the selection (it can't be
      # the group the selection joins, and it often sits in front of it).
      var groupHit = 0'i32
      for c in cs:
        if a.isSelected(c): continue
        groupHit = if c.obj != nil: a.objGroup(c.obj) else: a.pieceGroup(c.piece)
        break
      a.ctx = CtxMenu(pos: m, view: p.view, point: point, face: fi,
                      obj: (if cs.len > 0: cs[0].obj else: nil), groupHit: groupHit)
      a.menuSys.openContext(m)
      return

  # Left button: click or drag.
  if a.press.active:
    if w.buttonPressed[MouseRight] and not a.press.dragging and a.canCarry(a.press.view):
      # Right button joins a left press that hasn't dragged yet: carry.
      a.press.active = false
      a.rmbPress = Press(active: true, view: a.press.view, pos: m, time: epochTime())
      a.drag = Drag(kind: dkLook, view: a.press.view)
      a.beginCarry(a.press.view)
      return
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
      let bh = a.boxHandleAt(vi, m)
      a.hoverHandle = if bh >= 0: "box" & $bh else: a.gizmoAt(vi, m)
      if md.s and a.selPieces.len > 0:
        a.extrudeHover = a.extrudeFaceAt(vi, m)
        if a.extrudeHover >= 0: a.extrudeHoverFaces = a.extrudeGroup(a.extrudeHover)
      if md.c and md.s and not md.al:
        let (fi, p, q) = a.cutEdgeAt(vi, m)
        if fi >= 0: a.cutHover = a.cutGroup(fi, p, q)
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
        # Toward the cursor or straight ahead (Settings > Mouse).
        let dir = if a.cfg.moveTowardCursor: a.viewRay(vi, m).dir else: cam[].forward
        cam.pos -= dir * (a.wheelSign * notches * 64 * (a.cfg.moveSpeed / 0.5).float32)
    else:
      let before = cam[].pixelToPlane(m.x - b.x, m.y - b.y, b.w, b.h)
      a.zoom2D = clamp(a.zoom2D * pow(1.2'f32, -a.wheelSign * notches), 0.005, 80)
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

proc flipAxis*(a: App, vertical: bool): int =
  ## World axis Ctrl+F (horizontal) and Ctrl+Alt+F (vertical) mirror along,
  ## as TrenchBroom's MapView2D/MapView3D::flipAxis: a 2D view's screen axes;
  ## in 3D, vertical is always world up and horizontal is the axis nearest the
  ## camera's right, unless that is also the forward axis (camera at 45°).
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  let cam = a.views[clamp(vi, 0, 3)].cam
  if cam.kind != vk3D:
    let ax = cam.kind.axes
    return mainAxis(if vertical: ax.up else: ax.right)
  if vertical: return 1
  let f = cam.forward
  let flat = vec3(f.x, 0, f.z)
  # Looking straight down or up, forward is the camera's up projected flat.
  let fwd = if flat.length > 0.001: mainAxis(flat) else: mainAxis(cam.right.cross(f))
  let r = mainAxis(cam.right)
  if r == fwd: (if r == 0: 2 else: 0) else: r

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

proc setViewKind*(a: App, vi: int, next: ViewKind) =
  ## Each pane keeps its 3D camera while it shows a 2D view, like TrenchBroom's
  ## cycling map view; 2D views follow the shared focus2D/zoom2D.
  let old = a.views[vi].cam
  if old.kind == next: return
  if old.kind == vk3D: a.views[vi].last3D = old
  var c = Camera(kind: next, fovY: a.defaultFov, zoom: a.zoom2D)
  if next == vk3D:
    if a.views[vi].last3D.fovY > 0:
      c = a.views[vi].last3D
    else:
      c.pos = a.focus2D + vec3(0, 200, 400)
      c.yaw = 0
      c.pitch = -0.4
  a.views[vi].cam = c
  a.sync2D()

proc cycleView(a: App) =
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  if vi < 0: return
  let old = a.views[vi].cam.kind
  a.setViewKind(vi, ViewKind((ord(old) + 1) mod (ord(high(ViewKind)) + 1)))

proc setTool*(a: App, t: Tool) =
  ## Toggles a modal tool (pressing its key again leaves it).
  let next = if a.tool == t: toolSelect else: t
  if next == a.tool: return
  a.tool = next
  a.selHandles.clear()
  a.hoverHandle = ""
  if next == toolRotate: a.resetRotateCenter()
  a.resetClip()
  if next != toolBrush: a.assemblePoints.setLen 0

proc focusFace*(a: App, fi: int, corner = -1) =
  ## A log link or issue: selects the face (its whole brush, so the brush stays
  ## closed while it's edited), switches to the vertex tool with the named corner
  ## selected and frames the face in every view. Whatever hides or locks the
  ## face is lifted, so the corner can be dragged or nudged straight away.
  if a.geo == nil or fi < 0 or fi >= a.geo.faces.len:
    a.say(&"Face {fi} no longer exists (the geometry changed since that message)", true)
    return
  let f = a.geo.faces[fi]
  let before = a.visState
  a.layerHidden.excl GeometryLayer
  a.layerLocked.excl GeometryLayer
  if f.isMarkerFace: a.opts.markers = true
  if f.isInvisibleFace and not a.opts.invisible:
    a.opts.invisible = true
    a.geo.bump()
  if f.piece >= 0 and f.piece < a.geo.pieces.len and a.geo.pieces[f.piece].hidden:
    a.geo.pieces[f.piece].hidden = false
    a.geo.bump()
  a.pushVisibility("Ensure Objects Visible", before)
  if a.tool != toolVertex: a.setTool(toolVertex)
  a.clearSelection()
  if f.piece >= 0: a.selPieces.incl f.piece.int32
  else: a.selFaces.incl fi
  a.lastFace = fi
  if corner >= 0 and corner < f.verts.len:
    a.selHandles.incl handleId(toolVertex, @[a.geo.points[f.verts[corner]]])
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  for v in f.verts:
    lo = min(lo, a.geo.points[v])
    hi = max(hi, a.geo.points[v])
  a.frameBox(lo, hi)

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
    elif a.clipFace.len > 0: a.clipFace.setLen 0
    else: a.setTool(toolSelect)
  of toolBrush:
    if a.assemblePoints.len > 0: a.assemblePoints.setLen 0
    else: a.setTool(toolSelect)
  of toolVertex, toolEdge, toolFace:
    if a.selHandles.len > 0: a.selHandles.clear()
    else: a.setTool(toolSelect)
  of toolRotate, toolScale: a.setTool(toolSelect)
  of toolSelect:
    # TrenchBroom: Esc deselects, then closes the open group.
    if a.hasSelection: a.clearSelection()
    elif a.openGroups.len > 0: a.closeGroup()

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
      a.setPose(o, rotateAxis(o.pos, pivot, axis, deg), turnRotation(o.rot, axis, deg))
    if geoSel:
      let faces = a.selectedFaceSet
      let hold = a.holdTextures(faces)
      a.geo.detachPoints(faces)
      a.geo.transformPoints(a.geo.pointsOf(faces), proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg))
      a.releaseTextures(hold)
    a.transformSelectedGroups(affineOf(proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg)))
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
    let hold = a.holdTextures(faces)
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), sc)
    if f.x * f.y * f.z < 0: a.geo.reverseWinding(faces)
    a.releaseTextures(hold)
  a.transformSelectedGroups(affineOf(sc))
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
      if pressed(Key1):
        a.gridIndex = GridHalfIndex
        return
      for (k, i) in [(Key2, 0), (Key3, 1), (Key4, 2), (Key5, 3), (Key6, 4), (Key7, 5), (Key8, 6),
                     (Key9, 7)]:
        if pressed(k):
          a.gridIndex = GridKeyBase + i
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
    # Esc while carrying puts the selection back.
    if a.drag.carry and w.buttonPressed[KeyEscape]: a.endCarry(cancel = true)
    else: discard a.gridKeys(c, al)
    return
  # Keys the focused panel widget listens to (Space on a button, arrows in a
  # list...) are its, not the views'.
  template pressed(k: Button): bool = w.buttonPressed[k] and k notin ui.navTaken
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
  elif c and pressed(KeyW): run "Close project"
  elif c and pressed(KeyQ): run "Quit"
  elif c and al and pressed(KeyZ):
    for i in 0 .. 3:
      if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = a.defaultFov
  elif c and pressed(KeyZ): (if sh: a.redo() else: a.undo())
  elif c and pressed(KeyY): a.redo()
  elif c and sh and pressed(KeyD): run "Create linked duplicate"
  elif c and pressed(KeyD): a.duplicateSelection(vec3(0, 0, 0), flash = true)
  elif c and sh and pressed(KeyG): run "Ungroup selected objects"
  elif c and al and pressed(KeyG): run "Rename selected groups..."
  elif c and pressed(KeyG): run "Group selected objects..."
  elif c and pressed(KeyX): run "Cut"
  elif c and pressed(KeyC): run "Copy"
  elif c and al and pressed(KeyV): run "Paste at original position"
  elif c and sh and pressed(KeyV): run "Paste surface properties"
  elif c and pressed(KeyV): run "Paste"
  elif c and al and pressed(KeyA): run "Invert selection"
  elif c and sh and pressed(KeyA): a.clearSelection()
  elif c and pressed(KeyA): run "Select all"
  elif c and pressed(KeyB): a.selectSiblings()
  elif c and sh and pressed(KeyE): a.selectByBrushes(inside = true)
  elif c and pressed(KeyE): a.selectByBrushes(inside = true)
  elif c and pressed(KeyT): a.selectByBrushes(inside = false)
  elif c and sh and pressed(KeyJ): a.joinSelection()
  elif c and pressed(KeyJ): a.csg("merge")
  elif c and sh and pressed(KeyK): a.csg("hollow")
  elif c and pressed(KeyK): a.csg("subtract")
  elif c and pressed(KeyL): a.csg("intersect")
  elif c and al and pressed(KeyF):
    if faceMode: a.flipTextures(false) else: a.flipSelection(a.flipAxis(vertical = true))
  elif c and pressed(KeyF):
    if faceMode: a.flipTextures(true) else: a.flipSelection(a.flipAxis(vertical = false))
  elif sh and not c and pressed(KeyPeriod): a.resetCameras()
  elif not c and not al and pressed(KeyPeriod): a.frameSelection()
  elif c and sh and pressed(KeyI): run "Show all"
  elif c and al and pressed(KeyI): run "Hide selection"
  elif c and pressed(KeyI): run "Isolate selection"
  elif al and pressed(KeyI): run "Save screenshot..."
  elif c and al and pressed(KeyM): run "Move objects..."
  elif c and pressed(Key1): a.showPanel(pkMap)
  elif c and pressed(Key2): a.showPanel(pkProperties)
  elif c and pressed(Key3): a.showPanel(pkClasses)
  elif c and pressed(Key4): a.togglePanel(pkConsole)
  elif c and pressed(Key5): a.togglePanel(pkProperties)
  elif c and pressed(Key6): a.togglePanel(pkScripts)
  elif (c or w.meta) and pressed(KeySpace):
    a.maximized = if a.maximized >= 0: -1 else: max(a.hoverView, 0)
  elif c and (pressed(KeyEnter) or pressed(NumpadEnter)):
    # TrenchBroom's ClipTool::toggleSide: front, both, back.
    if a.tool == toolClip and a.clipPlane[0]:
      a.clipSide = case a.clipSide
        of sideFront: sideBoth
        of sideBoth: sideBack
        of sideBack: sideFront
  elif pressed(KeyF5): run "Play"
  elif pressed(KeyF7): run "Build"
  elif pressed(KeyEnter) or pressed(NumpadEnter):
    if a.tool == toolClip: a.applyClip()
    elif a.tool == toolBrush: a.createAssembled()
  elif pressed(KeyDelete) or pressed(KeyBackspace):
    if a.tool == toolClip and a.clipPoints.len > 0: a.clipPoints.setLen(a.clipPoints.len - 1)
    elif a.tool == toolClip and a.clipFace.len > 0: a.clipFace.setLen 0
    elif handleMode: discard a.deleteHandles()
    else: a.deleteSelection()
  elif sh and al and pressed(KeyR): a.resetTextures()
  elif sh and pressed(KeyR): a.resetTextures()
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
        a.duplicateSelection(dir * a.grid, linked = a.selectionIsLinked)
      else:
        a.moveSelection(dir * a.grid)
      return
