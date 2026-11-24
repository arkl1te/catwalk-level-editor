## Included by panels.nim: the Face tab's UV view, TrenchBroom's UV editor
## (UvEditor.cpp, UvView.cpp, UvViewHelper.cpp and its Uv*Tool.cpp tools)
## for Catwalk's per-corner UVs. The one selected face is seen from its front,
## its texture spread over the whole view, and dragging on it:
##   - anywhere moves the texture (UvOffsetTool); Shift: along one axis only;
##   - a grid line scales the texture from the origin (UvScaleTool); Shift:
##     both axes alike;
##   - the ring around the origin, or anywhere with Ctrl, turns it about the
##     origin (UvRotateTool); Shift: in 15° steps;
##   - the origin's red lines or its dot move the origin (UvOriginTool), the
##     pivot of scaling and turning; it is the view's, not the face's;
##   - Alt and a grid line shears it (UvShearTool);
##   - an edge or a corner of the face's outline resizes the outline over the
##     texture, which holds still meanwhile, the opposite side staying put: the
##     face then shows what the outline framed (not TrenchBroom's; Shift: keeps
##     the proportions);
##   - the right or middle button pans the view and the wheel zooms it (UvCameraTool).
## Snapping is TrenchBroom's: the grid lines, the face's corners, edges and
## middle; Ctrl turns it off. Esc cancels a drag; each drag is one undo step.
## The shifts, scales and turns are applied to the face's UVs as they are, so
## UVs that aren't quite affine (imported ones) keep their irregularities.

const
  UvSnapPx = 8'f32          ## UvViewHelper::snapDelta's and UvScaleTool's snap distance.
  UvPickPx = 5'f32          ## Grid lines and the origin's lines (pickUvGrid, MaxPickDistance).
  UvLineGapPx = 32'f32      ## Grid lines closer than this can't be grabbed: on a face of many
                            ## repeats every spot would be a line, leaving nothing to move it by.
  UvOriginR = 5'f32         ## UvOriginTool::OriginHandleRadius.
  UvRingR = 32'f32          ## UvRotateTool's RotateHandleRadius...
  UvRingW = 5'f32           ## ...and RotateHandleWidth.
  UvCenterR = 2.5'f32       ## Its dot at the face's middle (CenterHandleRadius).
  UvShearPx = 10'f32        ## snapShearFactors' threshold.
  UvShearGuardPx = 6'f32    ## #1350: no shearing from right next to the origin's lines.
  UvAxisLen = 32'f32        ## renderUvAxes' length.
  UvCornerPx = 8'f32        ## The outline's corners can be grabbed this far from them...
  UvEdgePx = 5'f32          ## ...and its edges this far.
  UvMinSidePx = 2'f32       ## An outline is never squeezed thinner than this.
  UvGripH = 8'f32           ## The strip under the view that resizes it.
  UvWheelStep = 1.1'f32     ## UvCameraTool's zoom per wheel notch.
  UvZoomRange = 64'f32      ## Zoom from 1/64 to 64 times the one framing the face.
  UvBack = rgbx(36, 36, 36, 255)  ## TrenchBroom's Browser/Background color.

type
  D2 = array[2, float]

  UvHit = object
    ## What's under the mouse in the UV view, in the tools' order.
    ring: bool                ## The rotate handle.
    originAxes: array[2, bool]  ## The origin's lines (U: the one of constant U), both on its dot.
    line: array[2, bool]      ## A grid line of constant U / V...
    lineAt: array[2, float]   ## ...and its value.
    grab: seq[int]            ## The outline's edges a drag would move (two at a corner)...
    corner: int               ## ...the corner, or -1.

  UvLook = object
    ## The face shown and its mapping this frame.
    fi: int
    axes: (Vec3, Vec3)
    pts: seq[D2]              ## Its corners in face coordinates.
    lo, hi: D2                ## Their bounds.
    map: UvAffine
    tex: string               ## Texture image path.
    texels: D2                ## Texture size in pixels (0 when unknown).

proc d2(v: Vec2): D2 = [v.x.float, v.y.float]
proc v2(d: D2): Vec2 = vec2(d[0].float32, d[1].float32)
proc sub(p, q: D2): D2 = [p[0] - q[0], p[1] - q[1]]

proc uvScreen(v: UvView, r: Rect, p: D2): Vec2 =
  ## Face coordinates to UI units (y down on screen, up on the face).
  vec2(r.x + r.w / 2 + float32((p[0] - v.center.x.float) * v.zoom.float),
       r.y + r.h / 2 - float32((p[1] - v.center.y.float) * v.zoom.float))

proc uvFace(v: UvView, r: Rect, s: Vec2): D2 =
  [v.center.x.float + (s.x - (r.x + r.w / 2)).float / v.zoom.float,
   v.center.y.float - (s.y - (r.y + r.h / 2)).float / v.zoom.float]

proc uvPx(v: UvView, m: UvAffine, i: int, du: float): float32 =
  ## How far apart on screen (UI units) two lines of constant U (i = 0) or V
  ## are when their values differ by du.
  let l = hypot(m.m[i * 2], m.m[i * 2 + 1])
  if l < 1e-12: return Inf.float32
  float32(abs(du) / l * v.zoom.float)

proc screenDir(d: D2): Vec2 =
  ## A direction on the face as one on screen.
  let s = vec2(d[0].float32, -d[1].float32)
  if s.length > 1e-9: s.normalize else: vec2(1, 0)

proc nearestLine(x: float, n: int): float = round(x * n.float) / n.float

proc snapLines(v: UvView, m: UvAffine, i: int): int =
  ## Grid lines per repeat along U (i = 0) or V that can be grabbed and
  ## snapped to: the finest drawn at least UvLineGapPx apart; 0 = none.
  result = v.grid[i]
  if v.uvPx(m, i, 1 / result) < UvLineGapPx: result = 1
  if v.uvPx(m, i, 1 / result) < UvLineGapPx: result = 0

proc uvCols(m: UvAffine): (D2, D2) =
  ## The directions on the face along which only U grows, and only V.
  let im = inverseM(m.m)
  ([im[0], im[2]], [im[1], im[3]])

proc uvLook(a: App, fi: int): UvLook =
  let g = a.geo
  let f = g.faces[fi]
  result.fi = fi
  result.axes = faceAxes(g.normal(f))
  result.lo = [Inf, Inf]
  result.hi = [-Inf, -Inf]
  for v in f.verts:
    let q = faceCoords(g.points[v], result.axes)
    result.pts.add q
    for i in 0 .. 1:
      result.lo[i] = min(result.lo[i], q[i])
      result.hi[i] = max(result.hi[i], q[i])
  result.map = g.fitUvAffine(f, result.axes)
  result.tex = a.texturePath(f.texture)
  if f.texture in a.texSizes:
    let (w, h) = a.texSizes[f.texture]
    result.texels = [w.float, h.float]

proc middle(l: UvLook): D2 = [(l.lo[0] + l.hi[0]) / 2, (l.lo[1] + l.hi[1]) / 2]

proc uvFrame(v: var UvView, r: Rect, l: UvLook) =
  ## UvViewHelper::resetCamera and resetZoom: the face in the middle with a
  ## margin of a tenth (2 to 40 units) around it. Only once the view has a size.
  if r.w <= 20 or r.h <= 20 or l.pts.len == 0: return
  let mx = clamp(r.w * 0.1, 2, 40)
  let my = clamp(r.h * 0.1, 2, 40)
  let (w, h) = (r.w - 2 * mx, r.h - 2 * my)
  let size = [l.hi[0] - l.lo[0], l.hi[1] - l.lo[1]]
  var z = Inf
  if size[0] > 1e-6: z = min(z, w.float / size[0])
  if size[1] > 1e-6: z = min(z, h.float / size[1])
  if z == Inf: z = 1
  v.center = v2(l.middle)
  v.zoom = z.float32
  v.fitZoom = v.zoom
  v.fitted = true

proc uvResetOrigin(v: var UvView, l: UvLook) =
  ## UvViewHelper::resetOrigin: U of the leftmost corner, V of the lowest one.
  if l.pts.len == 0: return
  var (ix, iy) = (0, 0)
  for k, p in l.pts:
    if p[0] < l.pts[ix][0]: ix = k
    if p[1] < l.pts[iy][1]: iy = k
  v.origin =
    if l.map.ok: v2(l.map.unapply([l.map.apply(l.pts[ix])[0], l.map.apply(l.pts[iy])[1]]))
    else: vec2(l.pts[ix][0].float32, l.pts[iy][1].float32)

proc uvPick(a: App, l: UvLook, r: Rect, m: Vec2): UvHit =
  let v = addr a.uvView
  result.corner = -1
  if not l.map.ok: return
  # The outline: a corner first, else the nearest edge.
  let n = l.pts.len
  var sp: seq[Vec2]
  for p in l.pts: sp.add v[].uvScreen(r, p)
  proc long(k: int): bool = (sp[(k + 1) mod n] - sp[k]).length > 1e-3
  var best = UvCornerPx
  for k in 0 ..< n:
    let dd = (m - sp[k]).length
    if dd <= best:
      let (e0, e1) = ((k + n - 1) mod n, k)
      var es: seq[int]
      for e in [e0, e1]:
        if long(e): es.add e
      # Two edges in one line make no corner: it's a point along that edge.
      if es.len == 2:
        let (d0, d1) = ((sp[k] - sp[e0]).normalize, (sp[(k + 1) mod n] - sp[k]).normalize)
        if abs(d0.x * d1.y - d0.y * d1.x) < 0.02: es = @[e1]
      if es.len > 0:
        best = dd
        result.corner = (if es.len == 2: k else: -1)
        result.grab = es
  if result.grab.len == 0:
    best = UvEdgePx
    for k in 0 ..< n:
      if not long(k): continue
      let (p, q) = (sp[k], sp[(k + 1) mod n])
      let t = clamp((m - p).dot(q - p) / (q - p).dot(q - p), 0, 1)
      let dd = (m - (p + (q - p) * t)).length
      if dd <= best:
        best = dd
        result.grab = @[k]
  let o = v[].uvScreen(r, d2(v.origin))
  let dist = (m - o).length
  if abs(dist - UvRingR) <= UvRingW:
    result.ring = true
    return
  let uvm = l.map.apply(v[].uvFace(r, m))
  let uvo = l.map.apply(d2(v.origin))
  if dist <= UvOriginR: result.originAxes = [true, true]
  else:
    for i in 0 .. 1: result.originAxes[i] = v[].uvPx(l.map, i, uvm[i] - uvo[i]) <= UvPickPx
  for i in 0 .. 1:
    let n = v[].snapLines(l.map, i)
    if n == 0: continue
    let at = nearestLine(uvm[i], n)
    if v[].uvPx(l.map, i, uvm[i] - at) <= UvPickPx:
      result.line[i] = true
      result.lineAt[i] = at

proc outlineGrabbed(h: UvHit, rotateOrShear: bool): bool =
  ## A press here would resize the outline: the ring, the origin's dot and
  ## Ctrl/Alt come first.
  h.grab.len > 0 and not rotateOrShear and not h.ring and not (h.originAxes[0] and h.originAxes[1])

proc edgeCursor(v: UvView, l: UvLook, r: Rect, grab: seq[int], corner: int): CursorKind =
  ## Across an edge as it lies on screen; a cross at a corner.
  if corner >= 0 or grab.len != 1 or l.pts.len == 0: return CrosshairCursor
  let e = grab[0]
  let d = v.uvScreen(r, l.pts[(e + 1) mod l.pts.len]) - v.uvScreen(r, l.pts[e])
  if abs(d.x) >= abs(d.y): ResizeUpDownCursor else: ResizeLeftRightCursor

proc uvUpdate(a: App, l: UvLook, r: Rect) =
  ## The drag in progress, from where it began (so nothing drifts).
  let ui = a.ui
  let w = a.window
  var v = addr a.uvView
  var d = addr v.drag
  let m = ui.mouse
  let ctrl = w.ctrl
  let shift = w.shiftDown
  case d.kind
  of utPan:
    v.center = vec2(d.center.x - (m.x - d.mouse.x) / v.zoom, d.center.y + (m.y - d.mouse.y) / v.zoom)
    return
  of utResize:
    v.height = clamp(d.height + m.y - d.mouse.y, MinUvViewH, MaxUvViewH)
    return
  else: discard
  let m0 = v[].uvFace(r, d.mouse)
  let m1 = v[].uvFace(r, m)
  let dp = m1.sub(m0)
  let map = d.map
  var t = [1.0, 0, 0, 1]      # uv = t·(uv0 − pivot) + pivot + shift
  var pivot, shiftBy: D2
  case d.kind
  of utOffset:
    var delta = lin(map.m, dp)
    if shift:
      if v[].uvPx(map, 0, delta[0]) >= v[].uvPx(map, 1, delta[1]): delta[1] = 0 else: delta[0] = 0
    if not ctrl:
      # A corner onto a grid line when one comes near it, else whole texels.
      for i in 0 .. 1:
        if shift and delta[i] == 0: continue
        let n = v[].snapLines(map, i)
        var best = Inf
        if n > 0:
          for uv in d.uvs:
            let x = (if i == 0: uv.x else: uv.y).float - delta[i]
            let dd = nearestLine(x, n) - x
            if abs(dd) < abs(best): best = dd
        if best != Inf and v[].uvPx(map, i, best) < UvSnapPx: delta[i] -= best
        elif l.texels[i] > 0: delta[i] = round(delta[i] * l.texels[i]) / l.texels[i]
    shiftBy = [-delta[0], -delta[1]]
  of utOrigin:
    if not l.map.ok: return
    var duv = lin(l.map.m, dp)
    for i in 0 .. 1:
      if not d.axes[i]: duv[i] = 0
    let o0 = l.map.apply(d2(d.origin))
    var nu = [o0[0] + duv[0], o0[1] + duv[1]]
    if not ctrl:
      # Onto a corner's U or V, a grid line or the face's middle.
      let mid = l.map.apply(l.middle)
      for i in 0 .. 1:
        if not d.axes[i]: continue
        var cands = @[mid[i]]
        let n = v[].snapLines(l.map, i)
        if n > 0: cands.add nearestLine(nu[i], n)
        for p in l.pts: cands.add l.map.apply(p)[i]
        var best = cands[0]
        for c in cands:
          if abs(c - nu[i]) < abs(best - nu[i]): best = c
        if v[].uvPx(l.map, i, best - nu[i]) < UvSnapPx: nu[i] = best
    v.origin = v2(l.map.unapply(nu))
    return
  of utScale:
    pivot = map.apply(d2(d.origin))
    let moved = lin(map.m, dp)
    var k = [1.0, 1.0]
    for i in 0 .. 1:
      if not d.axes[i]: continue
      # Where the grabbed line is to be, in the UVs it started with.
      var x = d.lines[i] + moved[i]
      if not ctrl:
        var best = Inf
        for p in l.pts:
          let c = map.apply(p)[i]
          if abs(c - x) < abs(best - x): best = c
        if best != Inf and v[].uvPx(map, i, best - x) < UvSnapPx: x = best
      let den = x - pivot[i]
      if abs(den) > 1e-12:
        let kk = (d.lines[i] - pivot[i]) / den
        if kk != 0 and kk.classify notin {fcInf, fcNegInf, fcNan}: k[i] = kk
    if shift:
      let same = if d.axes[0]: k[0] else: k[1]
      k = [same, same]
    t = [k[0], 0, 0, k[1]]
  of utRotate:
    let p0 = d2(d.origin)
    pivot = map.apply(p0)
    let s0 = m0.sub(p0)
    let s1 = m1.sub(p0)
    var th = (arctan2(s1[1], s1[0]) - arctan2(s0[1], s0[0])).radToDeg
    while th > 180: th -= 360
    while th <= -180: th += 360
    if shift: th = round(th / 15) * 15
    elif not ctrl:
      # A texture axis along one of the face's edges (snapAngle).
      let (du, dv) = map.uvCols
      let axisAngles = [arctan2(du[1], du[0]).radToDeg, arctan2(dv[1], dv[0]).radToDeg]
      var best = Inf
      for k in 0 ..< l.pts.len:
        let e = l.pts[(k + 1) mod l.pts.len].sub(l.pts[k])
        if hypot(e[0], e[1]) < 1e-9: continue
        let phi = arctan2(e[1], e[0]).radToDeg
        for al in axisAngles:
          var c = phi - al
          c += round((th - c) / 180) * 180
          if abs(c - th) < abs(best - th): best = c
      let distPx = max(1.0, hypot(s1[0], s1[1]) * v.zoom.float)
      if best != Inf and abs(best - th) < 130 / pow(distPx, 0.8): th = best
    t = mulM(mulM(map.m, rotationM(-th)), inverseM(map.m))
  of utShear:
    let p0 = d2(d.origin)
    pivot = map.apply(p0)
    let h0 = map.apply(m0)
    let h1 = map.apply(m1)
    let moved = lin(map.m, dp)
    # Along U's lines (constant U) the texture slides in V by s·(u − u0), and
    # the other way for V's; the point grabbed follows the mouse.
    var s = [0.0, 0.0]
    for i in 0 .. 1:
      if not d.axes[i]: continue
      let j = 1 - i
      let base = h0[i] - pivot[i]
      if abs(base) < 1e-12: continue
      s[i] = moved[j] / base
      if not ctrl:
        # An edge along the texture axis (snapShearFactors).
        var best = Inf
        for k in 0 ..< l.pts.len:
          let e = map.apply(l.pts[(k + 1) mod l.pts.len]).sub(map.apply(l.pts[k]))
          if abs(e[i]) < 1e-9: continue
          let c = e[j] / e[i]
          if abs(c - s[i]) < abs(best - s[i]): best = c
        if best != Inf and v[].uvPx(map, j, (best - s[i]) * (h1[i] - pivot[i])) < UvShearPx: s[i] = best
    t = [1.0, -s[1], -s[0], 1.0]
  of utEdge:
    # The texture holds still (the view keeps the mapping the drag began with)
    # while the outline stretches over it, p' = A·p + b; the face then shows
    # what the stretched outline covers: uv(p) = map(A·p + b).
    let pts = l.pts
    let np = pts.len
    if not map.ok or np < 3 or d.grab.len == 0: return
    let minSide = UvMinSidePx.float / v.zoom.float
    var area = 0.0
    for k in 0 ..< np:
      let (p, q) = (pts[k], pts[(k + 1) mod np])
      area += p[0] * q[1] - q[0] * p[1]
    proc dot2(p, q: D2): float = p[0] * q[0] + p[1] * q[1]
    proc side(e: int): tuple[n, c: D2, depth: float] =
      ## The edge's outward normal, the corner furthest behind it and how far.
      let p = pts[e]
      let u = pts[(e + 1) mod np].sub(p)
      let ul = hypot(u[0], u[1])
      if ul < 1e-12: return
      result.n = if area >= 0: [u[1] / ul, -u[0] / ul] else: [-u[1] / ul, u[0] / ul]
      for x in pts:
        let dd = dot2(p.sub(x), result.n)
        if dd > result.depth: (result.depth, result.c) = (dd, x)
    proc snapped(e: int, n: D2, delta: float): float =
      ## An edge along a texture axis onto a grid line near it, else onto
      ## whole texels.
      result = delta
      let w = lin(map.m, pts[(e + 1) mod np].sub(pts[e]))
      let mn = lin(map.m, n)
      for i in 0 .. 1:
        if abs(w[i]) > 1e-4 * hypot(w[0], w[1]) or abs(mn[i]) < 1e-12: continue
        let x0 = map.apply(pts[e])[i]
        let x = x0 + delta * mn[i]
        var to = Inf
        let lines = v[].snapLines(map, i)
        if lines > 0 and v[].uvPx(map, i, nearestLine(x, lines) - x) < UvSnapPx: to = nearestLine(x, lines)
        elif l.texels[i] > 0: to = round(x * l.texels[i]) / l.texels[i]
        if to != Inf: return (to - x0) / mn[i]
    var am = [1.0, 0, 0, 1]
    var b = [0.0, 0.0]
    if shift:
      # The same scale both ways, from the opposite corner or side.
      var k = 1.0
      var c: D2
      if d.corner >= 0:
        let p = pts[d.corner]
        var far = -1.0
        for x in pts:
          let dd = hypot(p[0] - x[0], p[1] - x[1])
          if dd > far: (far, c) = (dd, x)
        let diag = p.sub(c)
        let len2 = dot2(diag, diag)
        if len2 < 1e-12: return
        k = max(dot2(p.sub(c), diag) + dot2(dp, diag), minSide * sqrt(len2)) / len2
      else:
        let e = d.grab[0]
        let s = side(e)
        if s.depth < 1e-9: return
        var delta = dot2(dp, s.n)
        if not ctrl: delta = snapped(e, s.n, delta)
        k = max(s.depth + delta, minSide) / s.depth
        let q = pts[(e + 1) mod np]
        let em = [(pts[e][0] + q[0]) / 2, (pts[e][1] + q[1]) / 2]
        let back = dot2(em.sub(s.c), s.n)
        c = [em[0] - s.n[0] * back, em[1] - s.n[1] * back]
      am = [k, 0, 0, k]
      b = [c[0] * (1 - k), c[1] * (1 - k)]
    else:
      # Each edge moved along its normal, the line through the corner
      # furthest behind it staying put.
      for e in d.grab:
        let s = side(e)
        if s.depth < 1e-9: continue
        var delta = dot2(dp, s.n)
        if not ctrl: delta = snapped(e, s.n, delta)
        let k1 = max(s.depth + delta, minSide) / s.depth - 1
        let sm = [1 + k1 * s.n[0] * s.n[0], k1 * s.n[0] * s.n[1],
                  k1 * s.n[0] * s.n[1], 1 + k1 * s.n[1] * s.n[1]]
        am = mulM(sm, am)
        let bb = lin(sm, b.sub(s.c))
        b = [bb[0] + s.c[0], bb[1] + s.c[1]]
    d.outA = am
    d.outB = b
    t = mulM(mulM(map.m, am), inverseM(map.m))
    pivot = map.o
    shiftBy = lin(map.m, b)
  else: return
  if d.face notin 0 .. a.geo.faces.high or a.geo.faces[d.face].uvs.len != d.uvs.len: return
  a.geo.faces[d.face].mapUvs(d.uvs, t, pivot, shiftBy)
  a.geo.bump()
  d.changed = true

const UvDragLabels: array[UvTool, string] = ["", "Move texture", "", "Scale texture",
  "Rotate texture", "Shear texture", "Fit texture to outline", "", ""]

proc uvEndDrag(a: App, cancel: bool) =
  var v = addr a.uvView
  let d = v.drag
  v.drag = UvDrag()
  case d.kind
  of utOffset, utScale, utRotate, utShear, utEdge:
    let valid = a.geo == d.geo and d.face in 0 .. a.geo.faces.high and
                a.geo.faces[d.face].uvs.len == d.uvs.len
    if not valid or not d.changed: return
    if cancel:
      a.geo.faces[d.face].uvs = d.uvs
      a.geo.bump()
    elif a.geo.faces[d.face].uvs != d.uvs:
      a.push geoCmd(UvDragLabels[d.kind], d.before, a.geo)
  of utOrigin:
    if cancel: v.origin = d.origin
  of utPan:
    if cancel: v.center = d.center
  of utResize:
    if cancel: v.height = d.height
    else: a.saveLayout()
  of utNone: discard

proc uvBeginDrag(a: App, kind: UvTool, l: UvLook, hit: UvHit) =
  var v = addr a.uvView
  v.drag = UvDrag(kind: kind, face: l.fi, geo: a.geo, mouse: a.ui.mouse, origin: v.origin,
                  center: v.center, height: v.height, map: l.map)
  if kind in {utOffset, utScale, utRotate, utShear, utEdge}:
    v.drag.before = a.geo.clone
    v.drag.uvs = a.geo.faces[l.fi].uvs
  v.drag.corner = -1
  v.drag.outA = [1.0, 0, 0, 1]
  case kind
  of utOrigin: v.drag.axes = hit.originAxes
  of utEdge:
    v.drag.grab = hit.grab
    v.drag.corner = hit.corner
  of utScale, utShear:
    v.drag.axes = hit.line
    v.drag.lines = hit.lineAt
  else: discard

proc uvTurnFaces(a: App, deg: float) =
  ## UvEditor's Rotate UV 90° buttons, about each face's middle.
  let app = a
  var squashed = 0
  a.applyToFaces("Rotate texture", proc(fi: int) =
    if not app.geo.turnUvs(fi, deg): inc squashed)
  if squashed > 0:
    a.say(&"{squashed} face(s) have their UVs squashed to a line: Face align or World align them first", true)

proc drawUvEditor(a: App, x: float32, y: var float32, w: float32, faces: HashSet[int], first: int) =
  ## The UV view (one face selected), then its buttons, which work on every
  ## selected face, and the grid's subdivisions.
  let ui = a.ui
  var v = addr a.uvView
  let r = rect(x, y, w, v.height)
  let grip = rect(x, r.y + r.h, w, UvGripH)
  y += v.height + UvGripH + 4
  let one = faces.len == 1 and a.geo != nil and first in 0 .. a.geo.faces.high
  # A new face (or one shown again after the tab showed something else) gets
  # the camera and origin reset, as TrenchBroom does when the selection changes.
  if not one or v.geo != a.geo or v.face != first or v.lastFrame + 1 != a.frameNo:
    if v.drag.kind notin {utNone, utResize}: a.uvEndDrag(cancel = true)
    v.geo = a.geo
    v.face = (if one: first else: -1)
    v.fitted = false
    v.originSet = false
  v.lastFrame = a.frameNo
  var look = if one: a.uvLook(first) else: UvLook(fi: -1)
  if one:
    let n = a.geo.normal(a.geo.faces[first])
    if not v.fitted or n.dot(v.normal) < 0.9999:
      # Turned to another plane: what the camera framed is somewhere else now.
      v.normal = n
      v[].uvFrame(r, look)
      v.originSet = false
    if not v.originSet and look.pts.len > 0:
      v[].uvResetOrigin(look)
      v.originSet = true
  # Until the view has a size there is no zoom to work with.
  let single = one and v.fitted and v.zoom > 0

  # --- input ---
  let frameBtn = rect(r.x + r.w - 58, r.y + 6, 52, 22)
  let over = ui.hover(r) and not ui.mouse.inside(frameBtn)
  if v.drag.kind != utNone:
    ui.pressId = "uvview"
    # The keyboard is the drag's: Esc cancels it, and no shortcut acts meanwhile.
    for k in Button:
      if k notin {ButtonUnknown, MouseLeft, MouseRight, MouseMiddle}: ui.navTaken.incl k
    let held = if v.drag.kind == utPan: ui.down(MouseRight) or ui.down(MouseMiddle) else: ui.down(MouseLeft)
    if a.window.buttonPressed[KeyEscape]: a.uvEndDrag(cancel = true)
    elif v.drag.kind != utResize and (not single or v.drag.face != first or v.drag.geo != a.geo):
      a.uvEndDrag(cancel = true)
    elif not held:
      a.uvUpdate(look, r)
      a.uvEndDrag(cancel = false)
    else:
      a.uvUpdate(look, r)
    if one: look = a.uvLook(first)
    # Resizing the outline: the texture holds still under it until the drag ends.
    if v.drag.kind == utEdge and v.drag.map.ok: look.map = v.drag.map
  elif ui.hover(grip) and ui.pressed():
    ui.consumeClick()
    ui.pressId = "uvview"
    a.uvBeginDrag(utResize, look, UvHit())
  elif single and over:
    let win = a.window
    let hit = a.uvPick(look, r, ui.mouse)
    if ui.pressed():
      ui.consumeClick()
      ui.pressId = "uvview"
      let (ctrl, alt) = (win.ctrl, win.alt)
      if look.map.ok:
        # TrenchBroom's tool order: rotate, origin, scale, shear, offset.
        if alt:
          if hit.line[0] or hit.line[1]:
            # Not from right next to the origin's lines (TrenchBroom #1350).
            let uvm = look.map.apply(v[].uvFace(r, ui.mouse))
            let uvo = look.map.apply(d2(v.origin))
            if v[].uvPx(look.map, 0, uvm[0] - uvo[0]) >= UvShearGuardPx and
               v[].uvPx(look.map, 1, uvm[1] - uvo[1]) >= UvShearGuardPx:
              a.uvBeginDrag(utShear, look, hit)
        elif ctrl or hit.ring: a.uvBeginDrag(utRotate, look, hit)
        elif hit.originAxes[0] and hit.originAxes[1]: a.uvBeginDrag(utOrigin, look, hit)
        elif hit.grab.len > 0: a.uvBeginDrag(utEdge, look, hit)
        elif hit.originAxes[0] or hit.originAxes[1]: a.uvBeginDrag(utOrigin, look, hit)
        elif hit.line[0] or hit.line[1]: a.uvBeginDrag(utScale, look, hit)
        else: a.uvBeginDrag(utOffset, look, hit)
      else: a.uvBeginDrag(utOffset, look, hit)
    elif ui.window.buttonPressed[MouseRight] or ui.window.buttonPressed[MouseMiddle]:
      a.uvBeginDrag(utPan, look, hit)
    elif look.map.ok and hit.outlineGrabbed(win.ctrl or win.alt):
      wantCursor = edgeCursor(v[], look, r, hit.grab, hit.corner)
    let notches = (if a.cfg.invertWheel: -1'f32 else: 1'f32) * ui.wheelNotches
    if notches != 0 and not ui.scrollConsumed:
      ui.scrollConsumed = true
      # About the point under the mouse (UvCameraTool::mouseScroll).
      let at = v[].uvFace(r, ui.mouse)
      v.zoom = clamp(v.zoom * pow(UvWheelStep, -notches), v.fitZoom / UvZoomRange, v.fitZoom * UvZoomRange)
      let s = ui.mouse - vec2(r.x + r.w / 2, r.y + r.h / 2)
      v.center = vec2(float32(at[0] - s.x / v.zoom), float32(at[1] + s.y / v.zoom))
  if ui.hover(grip) or v.drag.kind == utResize: wantCursor = ResizeUpDownCursor
  elif v.drag.kind == utPan: wantCursor = ClosedHandCursor
  elif v.drag.kind == utEdge: wantCursor = edgeCursor(v[], look, r, v.drag.grab, v.drag.corner)

  # --- the texture, under everything else drawn after this ---
  # Light lines on dark textures, dark on bright ones (UvView's adaptiveOverlayColor).
  let bright = look.tex.len > 0 and a.rend.textureLuma(look.tex) * a.cfg.brightness >= 0.5
  ui.rect(r, UvBack)
  if single and look.map.ok:
    let s = ui.scale
    let fbH = a.window.size.y.float32
    let px = (x: int32(round(r.x * s)), y: int32(round(fbH - (r.y + r.h) * s)),
              w: int32(round(r.w * s)), h: int32(round(r.h * s)))
    let c = ui.sk.clipRect
    let (cx0, cy0) = (max(r.x, c.x), max(r.y, c.y))
    let (cx1, cy1) = (min(r.x + r.w, c.x + c.w), min(r.y + r.h, c.y + c.h))
    if cx1 > cx0 and cy1 > cy0 and px.w > 0 and px.h > 0:
      let cpx = (x: int32(floor(cx0 * s)), y: int32(floor(fbH - cy1 * s)),
                 w: int32(ceil(cx1 * s) - floor(cx0 * s)), h: int32(ceil(fbH - cy0 * s) - floor(fbH - cy1 * s)))
      # The corners of the pixels drawn, back in UI units.
      let (l0, r0) = (px.x.float32 / s, (px.x + px.w).float32 / s)
      let (t0, b0) = ((fbH - (px.y + px.h).float32) / s, (fbH - px.y.float32) / s)
      var uvs: array[4, Vec2]
      for k, corner in [vec2(l0, b0), vec2(r0, b0), vec2(r0, t0), vec2(l0, t0)]:
        uvs[k] = v2(look.map.apply(v[].uvFace(r, corner)))
      let rend = a.rend
      let path = look.tex
      let back = vec3(UvBack.r.float32, UvBack.g.float32, UvBack.b.float32) / 255
      ui.sk.markHole(proc() = discard rend.drawUvTexture(path, px, cpx, uvs, back))

  # --- overlays ---
  ui.pushClip(r)
  if not one:
    ui.textIn(if faces.len == 0: "" else: "Select one face to edit its texture here",
              r, colTextDim, FontSmall, h = CenterAlign)
  elif not look.map.ok:
    ui.textIn("Its UVs are squashed to a line: Face align or World align it",
              r, colTextDim, FontSmall, h = CenterAlign)
  if single:
    let map = look.map
    let overlay = if bright: pm(26, 26, 26) else: pm(230, 230, 230)
    let diag = hypot(r.w, r.h).float / v.zoom.float   # world units across the view
    let mid = v[].uvFace(r, vec2(r.x + r.w / 2, r.y + r.h / 2))
    proc lineOf(i: int, value: float, col: ColorRGBX, width: float32) =
      ## The line of constant U (i = 0) or V = value, across the view.
      let (du, dv) = map.uvCols
      let dir = if i == 0: dv else: du
      let dl = hypot(dir[0], dir[1])
      if dl < 1e-12: return
      var uv = map.apply(mid)
      uv[i] = value
      let p = map.unapply(uv)
      let e = [dir[0] / dl * diag, dir[1] / dl * diag]
      ui.uiLine(v[].uvScreen(r, [p[0] - e[0], p[1] - e[1]]), v[].uvScreen(r, [p[0] + e[0], p[1] + e[1]]),
                col, width)
    if map.ok:
      # The grid: a line per repeat, and per subdivision while they're apart enough.
      var lo = [Inf, Inf]
      var hi = [-Inf, -Inf]
      for corner in [r.xy, vec2(r.x + r.w, r.y), vec2(r.x, r.y + r.h), r.xy + r.wh]:
        let uv = map.apply(v[].uvFace(r, corner))
        for i in 0 .. 1:
          lo[i] = min(lo[i], uv[i])
          hi[i] = max(hi[i], uv[i])
      let alpha = clamp(a.cfg.gridOpacity, 0, 1)
      for i in 0 .. 1:
        # Subdivisions closer than 6 units go, then the repeats' lines fade out
        # from 16 units apart down to 4 (as TrenchBroom's soft grid lines thin).
        var n = v.grid[i]
        if v[].uvPx(map, i, 1 / n) < 6: n = 1
        let fade = clamp((v[].uvPx(map, i, 1 / n) - 4) / 12, 0, 1)
        if fade <= 0: continue
        for k in int(floor(lo[i] * n.float)) .. int(ceil(hi[i] * n.float)):
          let major = k mod n == 0
          let al = int(255 * alpha * fade * (if major: 1.0 else: 0.55))
          let col = if bright: pm(26, 26, 26, al) else: pm(230, 230, 230, al)
          lineOf(i, k / n, col, 1)
    let hot = v.drag.kind == utNone and over
    let hit = if hot: a.uvPick(look, r, ui.mouse) else: UvHit(corner: -1)
    # The face's outline; the edges a drag would resize, or is resizing, in red.
    let np = look.pts.len
    if v.drag.kind == utEdge:
      let (am, b) = (v.drag.outA, v.drag.outB)
      proc moved(p: D2): D2 =
        let q = lin(am, p)
        [q[0] + b[0], q[1] + b[1]]
      for k in 0 ..< np:
        ui.uiLine(v[].uvScreen(r, look.pts[k]), v[].uvScreen(r, look.pts[(k + 1) mod np]),
                  ColorRGBX(r: overlay.r div 3, g: overlay.g div 3, b: overlay.b div 3, a: 85), 1)
      for k in 0 ..< np:
        ui.uiLine(v[].uvScreen(r, moved(look.pts[k])), v[].uvScreen(r, moved(look.pts[(k + 1) mod np])),
                  if k in v.drag.grab: pm(255, 0, 0) else: overlay, 2)
      if v.drag.corner >= 0:
        ui.uiCircle(v[].uvScreen(r, moved(look.pts[v.drag.corner])), 3.5, pm(255, 0, 0), filled = true)
    else:
      let lit = if hot and map.ok and hit.outlineGrabbed(a.window.ctrl or a.window.alt): hit.grab else: @[]
      for k in 0 ..< np:
        ui.uiLine(v[].uvScreen(r, look.pts[k]), v[].uvScreen(r, look.pts[(k + 1) mod np]),
                  if k in lit: pm(255, 0, 0) else: overlay, 2)
      if lit.len > 0 and hit.corner >= 0:
        ui.uiCircle(v[].uvScreen(r, look.pts[hit.corner]), 3.5, pm(255, 0, 0), filled = true)
    if map.ok:
      let red = pm(255, 0, 0)
      let dimRed = pm(178, 0, 0)
      let handle = pm(247, 230, 59)
      let o = v[].uvScreen(r, d2(v.origin))
      let uvo = map.apply(d2(v.origin))
      # A grid line under the mouse, or the one being dragged (not over the origin's).
      if v.drag.kind == utScale or v.drag.kind == utShear:
        for i in 0 .. 1:
          if v.drag.axes[i]:
            if v.drag.kind == utScale: lineOf(i, v.drag.lines[i], red, 1)
            else:
              let p = map.apply(v[].uvFace(r, ui.mouse))
              lineOf(i, p[i], red, 1)
      elif hot and not hit.ring and not (hit.originAxes[0] or hit.originAxes[1]) and
           not hit.outlineGrabbed(a.window.ctrl or a.window.alt):
        for i in 0 .. 1:
          if hit.line[i]: lineOf(i, hit.lineAt[i], red, 1)
      # The origin: its lines of constant U and V, and its dot.
      let lit = if v.drag.kind == utOrigin: v.drag.axes
                elif hit.outlineGrabbed(a.window.ctrl or a.window.alt): [false, false]
                else: hit.originAxes
      for i in 0 .. 1: lineOf(i, uvo[i], if lit[i]: red else: dimRed, 1)
      # The rotate handle around it, and the face's middle.
      let ringHot = v.drag.kind == utRotate or (hot and (hit.ring or a.window.ctrl))
      ui.uiCircle(o, UvRingR, if ringHot: red else: handle, 1.5)
      ui.uiCircle(o, UvOriginR, if lit[0] or lit[1]: red else: handle, filled = true)
      ui.uiCircle(v[].uvScreen(r, look.middle), UvCenterR, red, filled = true)
      # The texture's axes from the face's middle: where U and V grow.
      let c = v[].uvScreen(r, look.middle)
      for i in 0 .. 1:
        ui.uiLine(c, c + screenDir([map.m[i * 2], map.m[i * 2 + 1]]) * UvAxisLen, colAxis[i], 2)
    # What a drag does here, or the values a drag gives.
    var note = ""
    case v.drag.kind
    of utOffset, utScale, utRotate, utEdge:
      let tf = a.geo.texFrame(first, a.density(a.geo.faces[first].texture))
      if tf.ok:
        note = case v.drag.kind
          of utOffset: "Shift " & fmtNumber(tf.shift[0], 4) & ", " & fmtNumber(tf.shift[1], 4)
          of utScale, utEdge: "Scale " & fmtNumber(tf.scale[0], 4) & ", " & fmtNumber(tf.scale[1], 4)
          else: "Rotation " & fmtNumber(tf.rot, 2) & "°"
      if v.drag.kind == utEdge: note.add " · Shift: keep proportions"
      note.add (if note.len > 0: " · " else: "") & "Ctrl: no snap · Esc: cancel"
    of utShear, utOrigin: note = "Ctrl: no snap · Esc: cancel"
    else:
      if hot and map.ok:
        note =
          if hit.ring: "Drag: rotate about the origin · Shift: 15° steps"
          elif hit.outlineGrabbed(a.window.ctrl or a.window.alt):
            "Drag: resize the outline over the texture · Shift: keep proportions"
          elif hit.originAxes[0] or hit.originAxes[1]: "Drag: move the origin (where scaling and turning pivot)"
          elif hit.line[0] or hit.line[1]: "Drag: scale from the origin · Shift: both axes · Alt: shear"
          else: "Drag: move · Ctrl+drag: rotate · Right-drag: pan · Wheel: zoom"
    let dragging = v.drag.kind != utNone
    if note.len > 0:
      # Wrapped between its "·"-separated parts, beside the Frame button
      # (hidden while dragging).
      let maxW = (if dragging: r.w - 8 else: r.w - frameBtn.w - 16) - 10
      var lines: seq[string]
      for part in note.split(" · "):
        if lines.len > 0 and ui.textSize(lines[^1] & " · " & part, FontSmall).x <= maxW:
          lines[^1].add " · " & part
        else: lines.add part
      var tw = 0'f32
      for ln in lines: tw = max(tw, min(ui.textSize(ln, FontSmall).x, maxW))
      let nr = rect(r.x + 4, r.y + 8, tw + 10, lines.len.float32 * 16 + 3)
      ui.rect(nr, pm(20, 22, 26, 215))
      for k, ln in lines:
        ui.textIn(ui.ellipsize(ln, maxW, FontSmall), rect(nr.x + 5, nr.y + 1 + k.float32 * 16, maxW, 16),
                  colText, FontSmall)
    if not dragging:
      if ui.textButton("uv.frame", frameBtn, "Frame"):
        v.fitted = false
      ui.tip(frameBtn, "Frame the face in the view again")
  ui.popClip()
  ui.border(r, colBorder)
  ui.rect(rect(grip.x + grip.w / 2 - 16, grip.y + 3, 32, 2),
          if ui.hover(grip) or v.drag.kind == utResize: colText else: colBorder)
  ui.tip(grip, "Drag to make the view taller or shorter")

  # --- buttons (every selected face) ---
  let app = a
  let hw = (w - 4) / 2
  if ui.textButton("face.facealign", rect(x, y, hw, 26), "Face align"):
    a.applyToFaces("Face align texture", proc(fi: int) =
      app.geo.faceAlignUVs(fi, app.density(app.geo.faces[fi].texture)))
  ui.tip(rect(x, y, hw, 26), "Project the texture onto the face's own plane at its usual size, " &
         "shift 0, so slopes aren't stretched (TrenchBroom's Reset UV alignment)")
  let ar = rect(x + hw + 4, y, hw, 26)
  if ui.textButton("face.align", ar, "World align"):
    a.applyToFaces("Align texture", proc(fi: int) =
      app.geo.projectUVs(fi, app.density(app.geo.faces[fi].texture)))
  ui.tip(ar, "Project the texture from the nearest axis at its usual size, shift 0 " &
         "(TrenchBroom's Reset UV alignment to world aligned)")
  y += 30
  let qw = (w - 3 * 4) / 4
  let rr = [rect(x, y, qw, 26), rect(x + qw + 4, y, qw, 26), rect(x + 2 * (qw + 4), y, qw, 26),
            rect(x + 3 * (qw + 4), y, qw, 26)]
  if ui.textButton("face.flipu", rr[0], "Flip U"):
    a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(-1, 1), 0))
  ui.tip(rr[0], "Mirror the texture along U")
  if ui.textButton("face.flipv", rr[1], "Flip V"):
    a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(1, -1), 0))
  ui.tip(rr[1], "Mirror the texture along V")
  if ui.textButton("face.turnleft", rr[2], "90° left"): a.uvTurnFaces(90)
  ui.tip(rr[2], "Rotate the texture 90° counter-clockwise about the face's middle")
  if ui.textButton("face.turnright", rr[3], "90° right"): a.uvTurnFaces(-90)
  ui.tip(rr[3], "Rotate the texture 90° clockwise about the face's middle")
  y += 30
  # Grid X and Y (1–16 lines per repeat): the view's grid and what it snaps to.
  let gr = a.propName("Grid", x, y, w, "Grid lines per texture repeat along U and V, in the view " &
                      "above: they snap moves and can be dragged to scale")
  let gw = (gr.w - 2) / 2
  for i in 0 .. 1:
    let fr = rect(gr.x + i.float32 * (gw + 2), y, gw, 26)
    var n = v.grid[i].float
    if ui.numberField("uv.grid." & $i, fr, n, 1, 1, MaxUvGrid.float, 0, axis = i, live = true):
      v.grid[i] = clamp(int(round(n)), 1, MaxUvGrid)
      a.saveLayout()
    ui.tip(fr, (if i == 0: "U" else: "V") & ": grid lines per texture repeat")
  y += 30
