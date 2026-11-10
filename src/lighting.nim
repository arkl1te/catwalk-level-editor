## Baked vertex lighting from the lights placed in the level (point, spot and
## directional lights, in lights.xml): their light, with shadows, is summed into
## every visible face corner's color, on top of an ambient color. The game shows
## those colors as the level's lighting (texture × vertex color). Corners set to
## override the lights (CornerAnim.manual) keep their own color.
##
## An animated light also leaves a layer on each corner it reaches
## (Face.lightAnims): the corner's color with that light at the other end of
## its animation, which Arklite plays in the game.
##
## A corner buried under a solid touching its face (a sign on a wall, a buttress)
## can't see any light, and being black would darken the whole visible face
## around it, so it takes its light from the nearest uncovered spots beside it.
##
## Shadow rays run against a uniform grid of the geometry's triangles, which
## is kept until the geometry's shape changes; corners are split across threads.
## The realtime sound preview casts its occlusion rays through the same kind of
## grid (soundscene.nim).

import std/[math, strutils, cpuinfo, typedthreads, algorithm]
import vmath
import geometry

# The bake is tight number crunching run during drags: stack traces (see
# config.nims) would double its time, and a crash in it is still reported from
# bakeLighting's caller.
{.push stackTrace: off, lineTrace: off.}

type
  LightKind* = enum lkPoint, lkSpot, lkDirectional

  Light* = object
    kind*: LightKind
    pos*: Vec3            ## Point, spot: where it is.
    dir*: Vec3            ## Spot, directional: unit vector the light travels along.
    color*: Vec3          ## 0..1 per channel, times the light's intensity.
    radius*: float32      ## Point, spot: light reaches no further.
    cosOuter*, cosInner*: float32
      ## Spot: cosines of the angles off its axis where its light ends, and
      ## where it starts fading toward that edge.
    shadows*: bool
    anim*: CornerAnim     ## Mode, interp, period and offset of its animation (color unused)...
    other*: Vec3          ## ...toward this color (like color, times the intensity).

  Tri = object
    a, e1, e2: Vec3

  Grid* = object
    lo: Vec3
    cell: float32
    dims: array[3, int32]
    start: seq[int32]     ## Per cell, where its triangles begin in items (cells + 1 entries).
    items: seq[int32]
    tris: seq[Tri]
    face: seq[int32]      ## Per triangle, the face it came from.

  Work = object
    grid: ptr Grid
    lights: ptr UncheckedArray[Light]
    lightCount: int
    far: float32          ## Directional shadow rays: past the whole level.
    pos, nrm, toCenter: ptr UncheckedArray[Vec3]
    twoSided: ptr UncheckedArray[bool]
    outSum: ptr UncheckedArray[Vec3]
    slot: ptr UncheckedArray[int32]     ## Per light: its column in outAnim, or -1 (not animated).
    slots: int
    outAnim: ptr UncheckedArray[float32] ## Per corner and animated light: how much of its light arrives.
    ambient: Vec3
    soft: float32         ## Soft shadows: how far around a corner it takes its light from.

  Slice = tuple[work: ptr Work, first, last: int]

const
  RayLift = 0.05'f32        ## Shadow rays start this far off the surface...
  CornerInset = 0.5'f32     ## ...and up to this far in from the corner, toward the face's center.
  BuriedDepth = 32'f32      ## A corner is buried if this close above it is the inside of a solid.
  UncoverSteps = [2'f32, 4, 8, 16, 32] ## How far beside a buried corner to look for uncovered spots.
  UncoverSpots = 8          ## Spots tried at each of those distances, around the corner.
  MaxCells = 4_000_000

var
  gridCache: Grid
  gridShape = -1'i64        ## shapeKey of the geometry gridCache was built from.

proc castsShadow(f: Face): bool =
  f.verts.len >= 3 and (f.flags and (gfGhost or gfDoorFrame or gfInvisible or gfTransparent or gfNoShadow)) == 0 and
    not f.texture.startsWith("_marker")

proc isLit*(f: Face): bool =
  ## Faces the bake colors: everything the game draws.
  f.verts.len >= 3 and (f.flags and (gfGhost or gfDoorFrame or gfInvisible)) == 0 and
    not f.texture.startsWith("_marker")

proc shapeKey(g: Geometry): int64 =
  ## Changes when the points or the shadow-casting faces do (not the colors).
  var h = 1469598103934665603'u64
  template mix(v: uint64) = h = (h xor v) * 1099511628211'u64
  for p in g.points:
    mix cast[uint32](p.x).uint64
    mix cast[uint32](p.y).uint64
    mix cast[uint32](p.z).uint64
  for f in g.faces:
    if not f.castsShadow: continue
    for v in f.verts: mix v.uint64
  cast[int64](h)

proc cellOf(gr: Grid, p: Vec3, axis: int): int32 =
  clamp(int32(floor((p[axis] - gr.lo[axis]) / gr.cell)), 0'i32, gr.dims[axis] - 1)

proc triangles*(gr: Grid): int = gr.tris.len

proc buildGrid*(g: Geometry, keep: proc(f: Face): bool {.nimcall.}): Grid =
  ## A grid of the triangles of the faces keep accepts (with at least 3 corners).
  for fi, f in g.faces:
    if f.verts.len < 3 or not keep(f): continue
    let a = g.points[f.verts[0]]
    for k in 1 ..< f.verts.len - 1:
      let b = g.points[f.verts[k]]
      let c = g.points[f.verts[k + 1]]
      result.tris.add Tri(a: a, e1: b - a, e2: c - a)
      result.face.add fi.int32
  if result.tris.len == 0: return
  var lo = result.tris[0].a
  var hi = lo
  for t in result.tris:
    for p in [t.a, t.a + t.e1, t.a + t.e2]:
      lo = min(lo, p)
      hi = max(hi, p)
  lo -= vec3(1, 1, 1)
  hi += vec3(1, 1, 1)
  let size = hi - lo
  # About two cells per triangle, none smaller than 2 units.
  let cells = clamp(result.tris.len * 2, 1, MaxCells).float64
  result.cell = max(float32(cbrt(size.x.float64 * size.y.float64 * size.z.float64 / cells)), 2'f32)
  result.lo = lo
  for i in 0 .. 2:
    result.dims[i] = max(1'i32, int32(ceil(size[i] / result.cell)))
  while result.dims[0].int64 * result.dims[1] * result.dims[2] > MaxCells:
    result.cell *= 1.25
    for i in 0 .. 2: result.dims[i] = max(1'i32, int32(ceil(size[i] / result.cell)))
  let n = result.dims[0].int * result.dims[1].int * result.dims[2].int
  var counts = newSeq[int32](n + 1)
  proc span(gr: Grid, t: Tri): (array[3, int32], array[3, int32]) =
    let a = t.a
    let b = t.a + t.e1
    let c = t.a + t.e2
    let tlo = min(a, min(b, c))
    let thi = max(a, max(b, c))
    for i in 0 .. 2:
      result[0][i] = gr.cellOf(tlo, i)
      result[1][i] = gr.cellOf(thi, i)
  let (dx, dy) = (result.dims[0].int, result.dims[1].int)
  for t in result.tris:
    let (l, h) = result.span(t)
    for z in l[2] .. h[2]:
      for y in l[1] .. h[1]:
        for x in l[0] .. h[0]: inc counts[x + dx * (y + dy * z)]
  result.start = newSeq[int32](n + 1)
  for i in 0 ..< n: result.start[i + 1] = result.start[i] + counts[i]
  result.items = newSeq[int32](result.start[n])
  var fill = result.start
  for ti, t in result.tris:
    let (l, h) = result.span(t)
    for z in l[2] .. h[2]:
      for y in l[1] .. h[1]:
        for x in l[0] .. h[0]:
          let c = x + dx * (y + dy * z)
          result.items[fill[c]] = ti.int32
          inc fill[c]

proc hitTri(t: Tri, o, d: Vec3, tmax: float32): float32 {.inline.} =
  ## Möller–Trumbore, either side: the distance along d to the triangle, or -1.
  result = -1
  let p = cross(d, t.e2)
  let det = dot(t.e1, p)
  if abs(det) < 1e-9: return
  let inv = 1 / det
  let s = o - t.a
  let u = dot(s, p) * inv
  if u < 0 or u > 1: return
  let q = cross(s, t.e1)
  let v = dot(d, q) * inv
  if v < 0 or u + v > 1: return
  let tt = dot(t.e2, q) * inv
  if tt > 1e-4 and tt < tmax: result = tt

iterator cellsAlong(gr: ptr Grid, o, d: Vec3, len: float32): int32 =
  ## The cells the segment from o, len along the unit vector d, passes
  ## through, in order (3D DDA).
  var cellI: array[3, int32]
  var step: array[3, int32]
  var tNext, tDelta: array[3, float32]
  for i in 0 .. 2:
    cellI[i] = gr[].cellOf(o, i)
    if d[i] > 1e-9:
      step[i] = 1
      tNext[i] = (gr.lo[i] + (cellI[i] + 1).float32 * gr.cell - o[i]) / d[i]
      tDelta[i] = gr.cell / d[i]
    elif d[i] < -1e-9:
      step[i] = -1
      tNext[i] = (gr.lo[i] + cellI[i].float32 * gr.cell - o[i]) / d[i]
      tDelta[i] = -gr.cell / d[i]
    else:
      step[i] = 0
      tNext[i] = Inf.float32
      tDelta[i] = Inf.float32
  let (dx, dy) = (gr.dims[0], gr.dims[1])
  while true:
    yield cellI[0] + dx * (cellI[1] + dy * cellI[2])
    var axis = 0
    if tNext[1] < tNext[axis]: axis = 1
    if tNext[2] < tNext[axis]: axis = 2
    if tNext[axis] > len: break
    cellI[axis] += step[axis]
    if cellI[axis] < 0 or cellI[axis] >= gr.dims[axis]: break
    tNext[axis] += tDelta[axis]

proc blocked(gr: ptr Grid, o, target: Vec3, stamp: var seq[int32], ray: int32): bool =
  ## Whether a triangle lies between o and target.
  var d = target - o
  let len = d.length
  if len < 1e-6: return false
  d /= len
  for c in cellsAlong(gr, o, d, len):
    for k in gr.start[c] ..< gr.start[c + 1]:
      let ti = gr.items[k]
      if stamp[ti] == ray: continue
      stamp[ti] = ray
      if gr.tris[ti].hitTri(o, d, len) >= 0: return true

proc crossings*(gr: ptr Grid, o, target: Vec3, stamp: var seq[int32], ray: int32): seq[(float32, int32)] =
  ## The faces between o and target: (distance from o, face index), nearest
  ## first, each face once. stamp has one entry per triangle; ray must differ
  ## from every earlier call's.
  var d = target - o
  let len = d.length
  if len < 1e-6 or gr.tris.len == 0: return
  d /= len
  for c in cellsAlong(gr, o, d, len):
    for k in gr.start[c] ..< gr.start[c + 1]:
      let ti = gr.items[k]
      if stamp[ti] == ray: continue
      stamp[ti] = ray
      let t = gr.tris[ti].hitTri(o, d, len)
      if t >= 0: result.add (t, gr.face[ti])
  result.sort()
  var n = 0
  for i in 0 ..< result.len:
    var seen = false
    for j in 0 ..< n:
      if result[j][1] == result[i][1]: seen = true
    if not seen:
      result[n] = result[i]
      inc n
  result.setLen n

proc insideSolid(gr: ptr Grid, o, d: Vec3, len: float32, stamp: var seq[int32], ray: int32): bool =
  ## Whether the nearest triangle within len of o, along the unit vector d, is
  ## one seen from behind.
  var nearest = len
  var hit = -1'i32
  for c in cellsAlong(gr, o, d, len):
    for k in gr.start[c] ..< gr.start[c + 1]:
      let ti = gr.items[k]
      if stamp[ti] == ray: continue
      stamp[ti] = ray
      let t = gr.tris[ti].hitTri(o, d, nearest)
      if t >= 0:
        nearest = t
        hit = ti
  hit >= 0 and dot(cross(gr.tris[hit].e1, gr.tris[hit].e2), d) > 0

proc shade(w: ptr Work, first, last: int) =
  var stamp = newSeq[int32](w.grid.tris.len)
  var ray = 0'i32
  template nextRay() =
    inc ray
    if ray == int32.high:
      for s in stamp.mitems: s = 0
      ray = 1
  template buried(q, n: Vec3): bool =
    nextRay()
    insideSolid(w.grid, q + n * RayLift, n, BuriedDepth, stamp, ray)
  for i in first ..< last:
    let n = w.nrm[i]
    var sum = w.ambient
    template gather(p: Vec3, share: float32) =
      for k in 0 ..< w.lightCount:
        let lt = w.lights[k]
        var l: Vec3                   # toward the light
        var fall = 1'f32
        if lt.kind in {lkPoint, lkSpot}:
          let toL = lt.pos - p
          let d2 = dot(toL, toL)
          if d2 >= lt.radius * lt.radius or d2 < 1e-8: continue
          l = toL / sqrt(d2)
          fall = 1 - d2 / (lt.radius * lt.radius)   # (1 - (d/r)²)², smooth to zero at the radius
          fall *= fall
          if lt.kind == lkSpot:
            let off = -dot(l, lt.dir)                # cosine of the angle off the spot's axis
            if off <= lt.cosOuter: continue
            if lt.cosInner > lt.cosOuter + 1e-6:
              let e = clamp((off - lt.cosOuter) / (lt.cosInner - lt.cosOuter), 0, 1)
              fall *= e * e * (3 - 2 * e)
        else:
          l = -lt.dir
        var nd = dot(n, l)
        let side = if nd >= 0: n else: -n
        if w.twoSided[i]: nd = abs(nd)
        if nd <= 0: continue
        if lt.shadows and w.grid.tris.len > 0:
          nextRay()
          let o = p + side * RayLift
          let target = if lt.kind == lkDirectional: o + l * w.far else: lt.pos
          if blocked(w.grid, o, target, stamp, ray): continue
        sum += lt.color * (nd * fall * share)
        if w.slot[k] >= 0: w.outAnim[i * w.slots + w.slot[k]] += nd * fall * share
    let u = cross(n, if abs(n.x) < 0.7: vec3(1, 0, 0) else: vec3(0, 1, 0)).normalize
    let v = cross(n, u)
    if w.soft > 0 and w.grid.tris.len > 0:
      # The corner and the spots around it that nothing stands between: a
      # shadow's edge becomes a ramp, which corners can show; a hard one comes
      # out in steps. All around, whichever face it's on: faces meeting at a
      # corner have to agree on it.
      var spots: array[UncoverSpots + 1, Vec3]
      spots[0] = w.pos[i]
      var found = 1
      for s in 0 ..< UncoverSpots:
        let ang = s.float32 * 2 * PI / UncoverSpots
        let off = (u * cos(ang) + v * sin(ang)) * w.soft
        nextRay()
        if blocked(w.grid, w.pos[i] + n * RayLift, w.pos[i] + off + n * RayLift, stamp, ray): continue
        if not buried(w.pos[i] + off, n):
          spots[found] = w.pos[i] + off
          inc found
      for s in 0 ..< found: gather(spots[s], 1 / found.float32)
    else:
      gather(w.pos[i], 1'f32)
    if sum == w.ambient and w.grid.tris.len > 0 and not w.twoSided[i] and buried(w.pos[i], n):
      # Beside it on its own face's side, not past a wall it's under: that's another room.
      for step in UncoverSteps:
        var spots: array[UncoverSpots, Vec3]
        var found = 0
        for s in 0 ..< UncoverSpots:
          let ang = s.float32 * 2 * PI / UncoverSpots
          let off = (u * cos(ang) + v * sin(ang)) * step
          if dot(off, w.toCenter[i]) < 0: continue
          if not buried(w.pos[i] + off, n):
            spots[found] = w.pos[i] + off
            inc found
        if found > 0:
          for s in 0 ..< found: gather(spots[s], 1 / found.float32)
          break
    w.outSum[i] = sum

proc shadeSlice(s: Slice) {.thread.} = shade(s.work, s.first, s.last)

proc rgb8(c: Vec3): array[3, uint8] =
  [uint8(clamp(c.x * 255, 0, 255)), uint8(clamp(c.y * 255, 0, 255)), uint8(clamp(c.z * 255, 0, 255))]

proc sampleLight*(g: Geometry, lights: seq[Light], ambient: Vec3, pos, nrm: seq[Vec3], soft = 0'f32): seq[Vec3] =
  ## The light the bake would give points on surfaces facing nrm (before
  ## rounding to 0..255, not clamped).
  if pos.len == 0: return
  let key = g.shapeKey
  if key != gridShape:
    gridCache = buildGrid(g, castsShadow)
    gridShape = key
  result = newSeq[Vec3](pos.len)
  var pr = lights
  for l in pr.mitems:
    if l.kind != lkPoint: l.dir = if l.dir.length > 1e-6: l.dir.normalize else: vec3(0, -1, 0)
  var slot = newSeq[int32](pr.len + 1)
  for s in slot.mitems: s = -1
  var two = newSeq[bool](pos.len)
  var toCenter = newSeq[Vec3](pos.len)
  var outAnim = @[0'f32]
  var (p, n) = (pos, nrm)
  var w = Work(grid: addr gridCache, lightCount: pr.len, ambient: ambient, soft: soft,
               pos: cast[ptr UncheckedArray[Vec3]](p[0].addr),
               nrm: cast[ptr UncheckedArray[Vec3]](n[0].addr),
               toCenter: cast[ptr UncheckedArray[Vec3]](toCenter[0].addr),
               twoSided: cast[ptr UncheckedArray[bool]](two[0].addr),
               outSum: cast[ptr UncheckedArray[Vec3]](result[0].addr),
               slot: cast[ptr UncheckedArray[int32]](slot[0].addr),
               outAnim: cast[ptr UncheckedArray[float32]](outAnim[0].addr))
  if pr.len > 0: w.lights = cast[ptr UncheckedArray[Light]](pr[0].addr)
  if gridCache.tris.len > 0:
    let d = vec3(gridCache.dims[0].float32, gridCache.dims[1].float32, gridCache.dims[2].float32)
    w.far = d.length * gridCache.cell
  shade(w.addr, 0, pos.len)

proc bakeLighting*(g: Geometry, lights: seq[Light], ambient: Vec3, soft = 0'f32): int =
  ## Sets every lit face corner's color to ambient (0..1) plus the lights'
  ## light, and its light layers to the animated lights' (corners that
  ## override the lights keep theirs and get none); returns how many corners
  ## changed. Bumps g.version if any did.
  let key = g.shapeKey
  if key != gridShape:
    gridCache = buildGrid(g, castsShadow)
    gridShape = key
  var pos, nrm, toCenter: seq[Vec3]
  var two: seq[bool]
  var at: seq[(int32, int32)]           # (face, corner) of each entry
  for fi, f in g.faces:
    if not f.isLit: continue
    let n = g.normal(f)
    let c = g.center(f)
    for k, v in f.verts:
      if k >= f.colors.len: break
      if f.animAt(k).manual: continue
      let p = g.points[v]
      let toC = c - p
      let dc = toC.length
      pos.add(if dc > 1e-6: p + toC * (min(CornerInset, dc * 0.05) / dc) else: p)
      nrm.add n
      toCenter.add toC
      two.add (f.flags and gfTwoSided) != 0
      at.add (fi.int32, k.int32)
  var layers = newSeq[seq[LightLayer]](g.faces.len)
  if pos.len == 0:
    for fi in 0 ..< g.faces.len:
      if g.faces[fi].lightAnims.len > 0:
        g.faces[fi].lightAnims.setLen 0
        inc result
    if result > 0: g.bump()
    return
  var outSum = newSeq[Vec3](pos.len)
  var pr = lights
  var slot = newSeq[int32](pr.len + 1)
  var animated: seq[int]
  for k, l in pr.mpairs:
    if l.kind != lkPoint: l.dir = if l.dir.length > 1e-6: l.dir.normalize else: vec3(0, -1, 0)
    slot[k] = -1
    if l.anim.mode != amNone and l.anim.period > 0 and l.other != l.color:
      slot[k] = animated.len.int32
      animated.add k
  var outAnim = newSeq[float32](pos.len * animated.len + 1)
  var w = Work(grid: addr gridCache, lightCount: pr.len, ambient: ambient, soft: soft,
               pos: cast[ptr UncheckedArray[Vec3]](pos[0].addr),
               nrm: cast[ptr UncheckedArray[Vec3]](nrm[0].addr),
               toCenter: cast[ptr UncheckedArray[Vec3]](toCenter[0].addr),
               twoSided: cast[ptr UncheckedArray[bool]](two[0].addr),
               outSum: cast[ptr UncheckedArray[Vec3]](outSum[0].addr),
               slot: cast[ptr UncheckedArray[int32]](slot[0].addr), slots: animated.len,
               outAnim: cast[ptr UncheckedArray[float32]](outAnim[0].addr))
  if pr.len > 0: w.lights = cast[ptr UncheckedArray[Light]](pr[0].addr)
  if gridCache.tris.len > 0:
    let d = vec3(gridCache.dims[0].float32, gridCache.dims[1].float32, gridCache.dims[2].float32)
    w.far = d.length * gridCache.cell
  let threads = if pr.len == 0 or pos.len < 4096: 1 else: clamp(countProcessors(), 1, 32)
  if threads == 1:
    shade(w.addr, 0, pos.len)
  else:
    var ts = newSeq[Thread[Slice]](threads)
    let per = (pos.len + threads - 1) div threads
    for t in 0 ..< threads:
      createThread(ts[t], shadeSlice, (w.addr, min(t * per, pos.len), min((t + 1) * per, pos.len)))
    joinThreads(ts)
  for i, (fi, k) in at:
    let c = rgb8(outSum[i])
    var col = addr g.faces[fi].colors[k]
    if col[0] != c[0] or col[1] != c[1] or col[2] != c[2]:
      col[0] = c[0]
      col[1] = c[1]
      col[2] = c[2]
      inc result
    for j, li in animated:
      let amount = outAnim[i * animated.len + j]
      if amount <= 0: continue
      let lt = pr[li]
      var m = lt.anim
      m.manual = false
      m.color = rgb8(outSum[i] + (lt.other - lt.color) * amount)
      if m.color != c: layers[fi].add LightLayer(corner: k, anim: m)
  for fi in 0 ..< g.faces.len:
    if g.faces[fi].lightAnims != layers[fi]:
      g.faces[fi].lightAnims = move layers[fi]
      inc result
  if result > 0: g.bump()

{.pop.}
