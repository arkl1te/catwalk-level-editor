## Geometry editing operations behind Catwalk's tools: transforms, box brushes,
## convex solids from planes, CSG, clipping, extrusion and texture projection.
## A "brush" is a piece whose faces bound a closed convex solid; any piece can be
## moved, clipped and vertex-edited, but CSG needs brushes.

import std/[math, tables, sets, algorithm]
import vmath
import geometry, camera

type
  Plane* = object
    n*: Vec3      ## Outward normal (unit).
    d*: float32   ## n·p = d on the plane; inside where n·p < d.

  TexFrame* = object
    ## A face's texture mapping as projectFaceUVs builds it: uv = R(rot) ·
    ## [[1/scale.x, shear], [0, 1/scale.y]] · q + offset, q being the face's
    ## points on its paraxial axes in texture repeats at the texture's density.
    ## So World align is shift 0, scale 1, rotation 0; scale 2 is a texture
    ## twice as big; a negative scale is a flip. Shear only carries along.
    ok*: bool
    shift*: array[2, float]   ## Offset in repeats, wrapped to [0, 1).
    scale*: array[2, float]
    rot*: float               ## Degrees, in (-90, 90] when derived.
    shear: float
    offset: array[2, float]   ## Exact offset.

  FaceAttr* = object
    texture*: string
    flags*: uint32
    scriptId*: int32
    color*: array[4, uint8]
    frame*: TexFrame          ## Mapping new faces get (World align when not ok).

  Side* = enum sideFront, sideBack, sideBoth

const Eps = 0.01'f32

proc plane*(n: Vec3, p: Vec3): Plane = Plane(n: n, d: n.dot(p))
proc dist*(pl: Plane, p: Vec3): float32 = pl.n.dot(p) - pl.d
proc flipped*(pl: Plane): Plane = Plane(n: -pl.n, d: -pl.d)

proc facePlane*(g: Geometry, f: Face): Plane =
  let n = g.normal(f)
  plane(n, g.center(f))

proc defaultAttr*(texture: string): FaceAttr =
  FaceAttr(texture: texture, color: [200'u8, 200, 200, 255])

proc attrOf*(f: Face): FaceAttr =
  FaceAttr(texture: f.texture, flags: f.flags, scriptId: f.scriptId,
           color: (if f.colors.len > 0: f.colors[0] else: [200'u8, 200, 200, 255]))

# --- texture projection -------------------------------------------------------------------

proc paraxial*(n: Vec3): (Vec3, Vec3) =
  ## World axes a face's texture follows (Quake-style): floors use X/Z, walls the
  ## two horizontal/vertical axes closest to their plane. V points down on walls.
  let a = vec3(abs(n.x), abs(n.y), abs(n.z))
  if a.y >= a.x and a.y >= a.z: (vec3(1, 0, 0), vec3(0, 0, 1))
  elif a.x >= a.z: (vec3(0, 0, 1), vec3(0, -1, 0))
  else: (vec3(1, 0, 0), vec3(0, -1, 0))

proc textureDensity*(g: Geometry, texture: string): float32 =
  ## World units per texture repeat, measured on existing faces with this
  ## texture (median), so new faces match the level. 64 when unknown.
  var samples: seq[float32]
  for f in g.faces:
    if f.texture != texture or f.verts.len < 3: continue
    for k in 0 ..< f.verts.len:
      let j = (k + 1) mod f.verts.len
      let w = (g.points[f.verts[j]] - g.points[f.verts[k]]).length
      let t = (f.uvs[j] - f.uvs[k]).length
      if w > 1 and t > 1e-4: samples.add w / t
    if samples.len > 400: break
  if samples.len == 0: return 64
  samples.sort
  samples[samples.len div 2]

proc projectFaceUVs*(g: Geometry, f: var Face, density: float32, offset = vec2(0, 0),
                     scale = vec2(1, 1), rotation = 0'f32) =
  ## World-aligned UVs for a face.
  let (ua, va) = paraxial(g.normal(f))
  let r = rotation.float64.degToRad
  let (c, s) = (cos(r).float32, sin(r).float32)
  f.uvs.setLen f.verts.len
  for k, v in f.verts:
    let p = g.points[v]
    var u = p.dot(ua) / (density * scale.x)
    var w = p.dot(va) / (density * scale.y)
    (u, w) = (u * c - w * s, u * s + w * c)
    f.uvs[k] = vec2(u, w) + offset

proc projectUVs*(g: Geometry, fi: int, density: float32, offset = vec2(0, 0),
                 scale = vec2(1, 1), rotation = 0'f32) =
  g.projectFaceUVs(g.faces[fi], density, offset, scale, rotation)

proc transformUVs*(g: Geometry, fi: int, offset = vec2(0, 0), scale = vec2(1, 1), rotation = 0'f32) =
  ## Edits the UVs a face already has: scale and rotate about their center, then shift.
  var f = addr g.faces[fi]
  if f.uvs.len == 0: return
  var c = vec2(0, 0)
  for uv in f.uvs: c += uv
  c /= f.uvs.len.float32
  let r = rotation.float64.degToRad
  let (cs, sn) = (cos(r).float32, sin(r).float32)
  for uv in f.uvs.mitems:
    var d = (uv - c)
    d = vec2(d.x / scale.x, d.y / scale.y)
    d = vec2(d.x * cs - d.y * sn, d.x * sn + d.y * cs)
    uv = c + d + offset

proc tidy(x: float): float =
  ## Snaps float noise off whole numbers (and -0 to 0).
  result = (if abs(x - round(x)) < 1e-4: round(x) else: x) + 0.0

proc texFrameMatrix(t: TexFrame): array[4, float] =
  ## [a11, a12, a21, a22].
  let r = t.rot.degToRad
  let (c, s) = (cos(r), sin(r))
  let (m11, m12, m22) = (1 / t.scale[0], t.shear, 1 / t.scale[1])
  [c * m11, c * m12 - s * m22, s * m11, s * m12 + c * m22]

proc texQ(g: Geometry, f: Face, density: float32): seq[array[2, float]] =
  let (ua, va) = paraxial(g.normal(f))
  for v in f.verts:
    let p = g.points[v]
    result.add [p.dot(ua).float / density, p.dot(va).float / density]

proc texFrame*(g: Geometry, f: Face, density: float32): TexFrame =
  ## Fits the face's UVs (least squares, so imported non-affine UVs work too).
  if f.verts.len < 3 or f.uvs.len != f.verts.len: return
  let q = g.texQ(f, density)
  let n = q.len.float
  var qm, um: array[2, float]
  for k in 0 ..< q.len:
    for i in 0 .. 1: qm[i] += q[k][i] / n
    um[0] += f.uvs[k].x.float / n
    um[1] += f.uvs[k].y.float / n
  var sxx: array[2, array[2, float]]
  var sux: array[2, array[2, float]]
  for k in 0 ..< q.len:
    let dq = [q[k][0] - qm[0], q[k][1] - qm[1]]
    let du = [f.uvs[k].x.float - um[0], f.uvs[k].y.float - um[1]]
    for i in 0 .. 1:
      for j in 0 .. 1:
        sxx[i][j] += dq[i] * dq[j]
        sux[i][j] += du[i] * dq[j]
  let det = sxx[0][0] * sxx[1][1] - sxx[0][1] * sxx[1][0]
  if abs(det) < 1e-9 * max(1.0, sxx[0][0] * sxx[1][1]): return
  let inv = [[sxx[1][1] / det, -sxx[0][1] / det], [-sxx[1][0] / det, sxx[0][0] / det]]
  var m: array[2, array[2, float]]
  for i in 0 .. 1:
    for j in 0 .. 1:
      m[i][j] = sux[i][0] * inv[0][j] + sux[i][1] * inv[1][j]
  let len1 = hypot(m[0][0], m[1][0])
  if len1 < 1e-9: return
  var th = arctan2(m[1][0], m[0][0])
  let (c, s) = (cos(th), sin(th))
  var shear = c * m[0][1] + s * m[1][1]
  var iy = -s * m[0][1] + c * m[1][1]
  if abs(iy) < 1e-9: return
  var sx = 1 / len1
  var sy = 1 / iy
  # The same mapping turned half a turn with both scales negated: show the
  # one nearer zero rotation, so a flipped U reads as scale -1, not 180°.
  var deg = th.radToDeg
  if deg > 90 or deg <= -90:
    deg = (if deg > 90: deg - 180 else: deg + 180)
    sx = -sx
    sy = -sy
    shear = -shear
  result.ok = true
  result.rot = tidy(deg)
  result.scale = [tidy(sx), tidy(sy)]
  result.shear = shear
  for i in 0 .. 1:
    result.offset[i] = um[i] - (m[i][0] * qm[0] + m[i][1] * qm[1])
    var w = result.offset[i] - floor(result.offset[i])
    if w > 1 - 1e-4 or w < 1e-4: w = 0
    result.shift[i] = w + 0.0

proc texFrame*(g: Geometry, fi: int, density: float32): TexFrame =
  g.texFrame(g.faces[fi], density)

proc setTexFrame*(f: var Face, old, t: TexFrame): TexFrame =
  ## Remaps the face's UVs from frame old to frame t: uv' = A'·A⁻¹·(uv − o) + o',
  ## which keeps whatever the fit didn't capture. t.shift sets the offset's
  ## fraction, keeping its whole repeats. Returns the face's new frame.
  result = t
  for i in 0 .. 1:
    result.offset[i] = old.offset[i] + (t.shift[i] - old.shift[i])
  let a = old.texFrameMatrix
  let b = t.texFrameMatrix
  let det = a[0] * a[3] - a[1] * a[2]
  if abs(det) < 1e-12: return
  let ai = [a[3] / det, -a[1] / det, -a[2] / det, a[0] / det]
  let m = [b[0] * ai[0] + b[1] * ai[2], b[0] * ai[1] + b[1] * ai[3],
           b[2] * ai[0] + b[3] * ai[2], b[2] * ai[1] + b[3] * ai[3]]
  for uv in f.uvs.mitems:
    let d = [uv.x.float - old.offset[0], uv.y.float - old.offset[1]]
    uv = vec2(float32(m[0] * d[0] + m[1] * d[1] + result.offset[0]),
              float32(m[2] * d[0] + m[3] * d[1] + result.offset[1]))

proc setTexFrame*(g: Geometry, fi: int, old, t: TexFrame): TexFrame =
  g.faces[fi].setTexFrame(old, t)

proc mapNewFace*(g: Geometry, f: var Face, attr: FaceAttr, density: float32) =
  ## UVs for a new face: World align, then attr's mapping (shift, scale,
  ## rotation) when it has one, so the face looks like the one attr came from.
  g.projectFaceUVs(f, density)
  if attr.frame.ok:
    let old = g.texFrame(f, density)
    if old.ok: discard f.setTexFrame(old, attr.frame)

# --- building pieces -------------------------------------------------------------------------

proc addPolygon(g: Geometry, poly: seq[Vec3], attr: FaceAttr, piece: int32,
                density: float32): int =
  var f = Face(texture: attr.texture, flags: attr.flags, scriptId: attr.scriptId,
               objectId: -1, piece: piece)
  for p in poly:
    f.verts.add g.points.len.int32
    g.points.add p
    f.colors.add attr.color
  g.mapNewFace(f, attr, density)
  g.faces.add f
  result = g.faces.high

proc solidFromPlanes*(planes: seq[Plane]): seq[(int, seq[Vec3])] =
  ## Corners of the convex solid bounded by planes, per plane (CCW seen from
  ## outside). Planes that don't touch the solid are left out.
  var pts: seq[Vec3]
  let n = planes.len
  for i in 0 ..< n:
    for j in i + 1 ..< n:
      for k in j + 1 ..< n:
        let (a, b, c) = (planes[i], planes[j], planes[k])
        let det = a.n.dot(b.n.cross(c.n))
        if abs(det) < 1e-6: continue
        let p = (b.n.cross(c.n) * a.d + c.n.cross(a.n) * b.d + a.n.cross(b.n) * c.d) / det
        var inside = true
        for pl in planes:
          if pl.dist(p) > Eps * 10:
            inside = false
            break
        if not inside: continue
        var dup = false
        for q in pts:
          if (q - p).length < Eps * 10:
            dup = true
            break
        if not dup: pts.add p
  for i, pl in planes:
    var on: seq[Vec3]
    for p in pts:
      if abs(pl.dist(p)) < Eps * 10: on.add p
    if on.len < 3: continue
    var c = vec3(0, 0, 0)
    for p in on: c += p
    c /= on.len.float32
    let u = (on[0] - c).normalize
    let v = pl.n.cross(u)
    on.sort(proc(a, b: Vec3): int =
      cmp(arctan2((a - c).dot(v), (a - c).dot(u)), arctan2((b - c).dot(v), (b - c).dot(u))))
    result.add (i, on)

proc addSolid*(g: Geometry, planes: seq[Plane], attrs: seq[FaceAttr],
               densityOf: proc(tex: string): float32): int32 =
  ## Adds a brush bounded by planes; attrs[i] textures the face on planes[i].
  ## Returns the new piece, or -1 if the planes enclose nothing.
  let polys = solidFromPlanes(planes)
  if polys.len < 4: return -1
  result = g.pieces.len.int32
  g.pieces.add Piece(brush: true)
  for (i, poly) in polys:
    discard g.addPolygon(poly, attrs[i], result, densityOf(attrs[i].texture))
  g.bump()

proc boxPlanes*(lo, hi: Vec3): seq[Plane] =
  @[plane(vec3(1, 0, 0), hi), plane(vec3(-1, 0, 0), lo), plane(vec3(0, 1, 0), hi),
    plane(vec3(0, -1, 0), lo), plane(vec3(0, 0, 1), hi), plane(vec3(0, 0, -1), lo)]

proc addBox*(g: Geometry, lo, hi: Vec3, attr: FaceAttr,
             densityOf: proc(tex: string): float32): int32 =
  var attrs: seq[FaceAttr]
  for _ in 0 .. 5: attrs.add attr
  g.addSolid(boxPlanes(min(lo, hi), max(lo, hi)), attrs, densityOf)

proc brushPlanes*(g: Geometry, faces: seq[int]): (seq[Plane], seq[FaceAttr]) =
  ## Planes of a brush piece (one per face, coplanar faces merged).
  for fi in faces:
    let pl = g.facePlane(g.faces[fi])
    var dup = false
    for q in result[0]:
      if q.n.dot(pl.n) > 0.9999 and abs(q.d - pl.d) < Eps:
        dup = true
        break
    if not dup:
      result[0].add pl
      result[1].add attrOf(g.faces[fi])

proc isConvexClosed*(g: Geometry, faces: seq[int]): bool =
  ## Every corner lies behind every face plane.
  if faces.len < 4: return false
  var pts: seq[Vec3]
  for fi in faces:
    for v in g.faces[fi].verts: pts.add g.points[v]
  for fi in faces:
    let pl = g.facePlane(g.faces[fi])
    for p in pts:
      if pl.dist(p) > 0.5: return false
  true

# --- selection-level edits --------------------------------------------------------------------

proc removePieces*(g: Geometry, pieces: HashSet[int32]) =
  var keep: seq[Face]
  for f in g.faces:
    if f.piece notin pieces: keep.add f
  g.faces = keep
  g.compact()

proc removeFaces*(g: Geometry, faces: HashSet[int]) =
  var keep: seq[Face]
  for i, f in g.faces:
    if i notin faces: keep.add f
  g.faces = keep
  g.compact()

proc detachPoints*(g: Geometry, faces: HashSet[int]) =
  ## Gives the given faces their own copies of points they share with other
  ## faces, so moving them leaves the rest alone.
  var other = newSeq[bool](g.points.len)
  for i, f in g.faces:
    if i notin faces:
      for v in f.verts: other[v] = true
  var copy: Table[int32, int32]
  for i in faces:
    for v in g.faces[i].verts.mitems:
      if other[v]:
        if v notin copy:
          copy[v] = g.points.len.int32
          g.points.add g.points[v]
        v = copy[v]

proc pointsOf*(g: Geometry, faces: HashSet[int]): HashSet[int32] =
  for i in faces:
    for v in g.faces[i].verts: result.incl v

proc movePoints*(g: Geometry, pts: HashSet[int32], d: Vec3) =
  for v in pts: g.points[v] += d
  g.bump()

proc transformPoints*(g: Geometry, pts: HashSet[int32], fn: proc(p: Vec3): Vec3) =
  for v in pts: g.points[v] = fn(g.points[v])
  g.bump()

proc rotateAxis*(p, pivot, axis: Vec3, deg: float32): Vec3 =
  let a = deg.float64.degToRad
  let (c, s) = (cos(a).float32, sin(a).float32)
  let v = p - pivot
  let k = axis.normalize
  pivot + v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c))

proc reverseWinding*(g: Geometry, faces: HashSet[int]) =
  ## After a mirror, faces must be turned back around.
  for i in faces:
    var f = addr g.faces[i]
    f.verts.reverse
    f.uvs.reverse
    f.colors.reverse

proc duplicateFaces*(g: Geometry, faces: seq[int], offset: Vec3): seq[int] =
  ## Copies the faces (with their own points) into new pieces. Returns the new faces.
  var pieceMap: Table[int32, int32]
  var pointMap: Table[int32, int32]
  for fi in faces:
    var f = g.faces[fi]
    if f.piece notin pieceMap:
      pieceMap[f.piece] = g.pieces.len.int32
      g.pieces.add Piece(brush: g.pieces[f.piece].brush)
    f.piece = pieceMap[f.piece]
    f.objectId = -1
    for v in f.verts.mitems:
      if v notin pointMap:
        pointMap[v] = g.points.len.int32
        g.points.add g.points[v] + offset
      v = pointMap[v]
    g.faces.add f
    result.add g.faces.high
  g.bump()

# --- clipping ----------------------------------------------------------------------------

proc clipPolygon(g: Geometry, f: Face, pl: Plane, keepFront: bool): Face =
  ## The part of f on one side of pl, with UVs and colors interpolated on cuts.
  result = f
  result.verts.setLen 0
  result.uvs.setLen 0
  result.colors.setLen 0
  let n = f.verts.len
  for k in 0 ..< n:
    let j = (k + 1) mod n
    let (a, b) = (g.points[f.verts[k]], g.points[f.verts[j]])
    var (da, db) = (pl.dist(a), pl.dist(b))
    if keepFront: (da, db) = (-da, -db)   # keep where dist >= 0
    let ina = da <= Eps
    let inb = db <= Eps
    if ina:
      result.verts.add f.verts[k]
      result.uvs.add f.uvs[k]
      result.colors.add f.colors[k]
    if ina != inb and abs(da - db) > 1e-6:
      let t = da / (da - db)
      result.verts.add g.points.len.int32
      g.points.add a + (b - a) * t
      result.uvs.add f.uvs[k] + (f.uvs[j] - f.uvs[k]) * t
      var c: array[4, uint8]
      for ch in 0 .. 3:
        c[ch] = uint8(f.colors[k][ch].float32 + (f.colors[j][ch].float32 - f.colors[k][ch].float32) * t)
      result.colors.add c

proc clipPieces*(g: Geometry, pieces: HashSet[int32], pl: Plane, side: Side,
                 capAttr: FaceAttr, densityOf: proc(tex: string): float32) =
  ## Cuts the pieces by pl ("front" = where the normal points). Brushes are
  ## closed again with a cap face; other pieces are just cut.
  let byPiece = g.pieceFaces
  var faces: seq[Face]
  for i, f in g.faces:
    if f.piece notin pieces: faces.add f
  for pc in pieces:
    let fs = byPiece[pc]
    let brush = g.pieces[pc].brush
    for keepFront in [true, false]:
      if (keepFront and side == sideBack) or (not keepFront and side == sideFront): continue
      let target = g.pieces.len.int32
      g.pieces.add Piece(brush: brush)
      var any = false
      for fi in fs:
        var c = g.clipPolygon(g.faces[fi], pl, keepFront)
        if c.verts.len >= 3:
          c.piece = target
          faces.add c
          any = true
      if any and brush:
        # Cap: the solid's section by the clip plane.
        let (planes, attrs) = g.brushPlanes(fs)
        var all = planes
        let capPlane = if keepFront: pl.flipped else: pl
        all.add capPlane
        var attrs2 = attrs
        attrs2.add capAttr
        for (i, poly) in solidFromPlanes(all):
          if i == all.high:
            var f = Face(texture: capAttr.texture, flags: capAttr.flags, scriptId: capAttr.scriptId,
                         objectId: -1, piece: target)
            for p in poly:
              f.verts.add g.points.len.int32
              g.points.add p
              f.colors.add capAttr.color
            g.mapNewFace(f, capAttr, densityOf(capAttr.texture))
            faces.add f
  g.faces = faces
  g.weld(0.01)

# --- CSG ---------------------------------------------------------------------------------

proc solidOf(g: Geometry, byPiece: seq[seq[int]], pc: int32): (seq[Plane], seq[FaceAttr]) =
  g.brushPlanes(byPiece[pc])

proc csgSubtract*(g: Geometry, minuends: seq[int32], subtrahends: seq[int32],
                  densityOf: proc(tex: string): float32): int =
  ## Each minuend brush minus every subtrahend brush, as convex pieces. The
  ## subtrahends are kept. Returns the number of brushes made.
  let byPiece = g.pieceFaces
  var current: seq[(seq[Plane], seq[FaceAttr])]
  for m in minuends: current.add g.solidOf(byPiece, m)
  for s in subtrahends:
    let (bp, ba) = g.solidOf(byPiece, s)
    var next: seq[(seq[Plane], seq[FaceAttr])]
    for (ap, aa) in current:
      # Quick reject: no overlap at all.
      var overlap = ap & bp
      if solidFromPlanes(overlap).len < 4:
        next.add (ap, aa)
        continue
      var inside: seq[Plane]
      var insideAttr: seq[FaceAttr]
      for i, pl in bp:
        var planes = ap & inside
        planes.add pl.flipped
        var attrs = aa & insideAttr
        attrs.add ba[i]
        if solidFromPlanes(planes).len >= 4: next.add (planes, attrs)
        inside.add pl
        insideAttr.add ba[i]
    current = next
  g.removePieces(toHashSet(minuends))
  for (planes, attrs) in current:
    if g.addSolid(planes, attrs, densityOf) >= 0: inc result

proc csgIntersect*(g: Geometry, pieces: seq[int32], densityOf: proc(tex: string): float32): bool =
  let byPiece = g.pieceFaces
  var planes: seq[Plane]
  var attrs: seq[FaceAttr]
  for pc in pieces:
    let (p, a) = g.solidOf(byPiece, pc)
    planes.add p
    attrs.add a
  if solidFromPlanes(planes).len < 4: return false
  g.removePieces(toHashSet(pieces))
  g.addSolid(planes, attrs, densityOf) >= 0

proc uniquePoints*(pts: seq[Vec3]): seq[Vec3] =
  for p in pts:
    var dup = false
    for q in result:
      if (q - p).length < Eps:
        dup = true
        break
    if not dup: result.add p

proc hullPlanes*(points: seq[Vec3]): seq[Plane] =
  ## Planes of the convex hull of the points (every plane through three of
  ## them with all of them behind it). Empty when they span no volume.
  let pts = uniquePoints(points)
  if pts.len < 4 or pts.len > 400: return
  for i in 0 ..< pts.len:
    for j in i + 1 ..< pts.len:
      for k in j + 1 ..< pts.len:
        let n0 = (pts[j] - pts[i]).cross(pts[k] - pts[i])
        if n0.length < 1e-4: continue
        var pl = plane(n0.normalize, pts[i])
        var front, back = 0
        for p in pts:
          let d = pl.dist(p)
          if d > Eps: inc front
          elif d < -Eps: inc back
        if front > 0 and back > 0: continue
        if front > 0: pl = pl.flipped
        var dup = false
        for q in result:
          if q.n.dot(pl.n) > 0.9999 and abs(q.d - pl.d) < Eps:
            dup = true
            break
        if not dup: result.add pl
  if solidFromPlanes(result).len < 4: result.setLen 0

proc csgMerge*(g: Geometry, pieces: seq[int32], densityOf: proc(tex: string): float32): bool =
  ## Convex hull of the pieces' corners, as one brush.
  let byPiece = g.pieceFaces
  var pts: seq[Vec3]
  var attr = defaultAttr("NONE")
  for pc in pieces:
    for fi in byPiece[pc]:
      attr = attrOf(g.faces[fi])
      for v in g.faces[fi].verts: pts.add g.points[v]
  let planes = hullPlanes(pts)
  if planes.len == 0: return false
  var attrs: seq[FaceAttr]
  for _ in planes: attrs.add attr
  g.removePieces(toHashSet(pieces))
  g.addSolid(planes, attrs, densityOf) >= 0

# --- rebuilding brushes, keeping their texturing ------------------------------------------

type UVMap* = object
  ## How one face maps world points to UVs (affine in its plane), so a rebuilt
  ## face on the same plane keeps the texture where it was.
  ok*: bool
  n*: Vec3
  p0*, e1*, e2*: Vec3
  uv0*, d1*, d2*: Vec2
  attr*: FaceAttr

proc uvMapOf*(g: Geometry, f: Face): UVMap =
  result.attr = attrOf(f)
  result.n = g.normal(f)
  if f.verts.len < 3 or f.uvs.len != f.verts.len: return
  let p0 = g.points[f.verts[0]]
  # The corner farthest from the first edge's line makes the best-conditioned basis.
  var best = -1
  var bestArea = 1e-3'f32
  let e1 = g.points[f.verts[1]] - p0
  for k in 2 ..< f.verts.len:
    let a = e1.cross(g.points[f.verts[k]] - p0).length
    if a > bestArea:
      bestArea = a
      best = k
  if best < 0: return
  result = UVMap(ok: true, n: result.n, attr: result.attr, p0: p0, e1: e1,
                 e2: g.points[f.verts[best]] - p0, uv0: f.uvs[0],
                 d1: f.uvs[1] - f.uvs[0], d2: f.uvs[best] - f.uvs[0])

proc mapUV*(m: UVMap, p: Vec3): Vec2 =
  let d = p - m.p0
  let (a11, a12, a22) = (m.e1.dot(m.e1), m.e1.dot(m.e2), m.e2.dot(m.e2))
  let (b1, b2) = (d.dot(m.e1), d.dot(m.e2))
  let det = a11 * a22 - a12 * a12
  if abs(det) < 1e-9: return m.uv0
  let s = (b1 * a22 - b2 * a12) / det
  let t = (a11 * b2 - a12 * b1) / det
  m.uv0 + m.d1 * s + m.d2 * t

proc rotateAbout(v, u: Vec3, c, s: float32): Vec3 =
  ## Rodrigues: v turned about the unit axis u by the angle with cosine c, sine s.
  v * c + u.cross(v) * s + u * (u.dot(v) * (1 - c))

proc wrapUVMap*(m: UVMap, src, dst: Plane): UVMap =
  ## TrenchBroom's rotation wrap (Valve format, Alt+Shift): the map folded about
  ## the line where the two planes meet, so the texture runs on across that edge
  ## unbroken. Parallel or opposite planes have no such line: m is returned as is.
  let axis = src.n.cross(dst.n)
  let s = axis.length
  if not m.ok or s < 1e-4: return m
  let u = axis / s
  let c = src.n.dot(dst.n)
  # A point on both planes (n·p = d for each).
  let q = (dst.n.cross(axis) * src.d + axis.cross(src.n) * dst.d) / (s * s)
  result = m
  result.n = dst.n
  result.p0 = q + rotateAbout(m.p0 - q, u, c, s)
  result.e1 = rotateAbout(m.e1, u, c, s)
  result.e2 = rotateAbout(m.e2, u, c, s)

proc pieceUVMaps*(g: Geometry, faces: seq[int]): seq[UVMap] =
  for fi in faces: result.add g.uvMapOf(g.faces[fi])

proc bestMap(maps: seq[UVMap], n: Vec3): int =
  ## The original face whose normal is closest to n.
  result = -1
  var best = -2'f32
  for i, m in maps:
    let d = m.n.dot(n)
    if d > best:
      best = d
      result = i

proc replacePiece*(g: Geometry, pc: int32, planes: seq[Plane], maps: seq[UVMap],
                   densityOf: proc(tex: string): float32, fallback = defaultAttr("NONE")): bool =
  ## Rebuilds piece pc as the convex solid bounded by planes. Each new face
  ## takes the texture, flags and UV mapping of the old face facing the same
  ## way (the mapping is kept exactly when the face stays on its plane or
  ## moves along it). Returns false, changing nothing, when the planes enclose
  ## no volume.
  let polys = solidFromPlanes(planes)
  if polys.len < 4: return false
  var keep: seq[Face]
  for f in g.faces:
    if f.piece != pc: keep.add f
  g.faces = keep
  g.pieces[pc].brush = true
  for (i, poly) in polys:
    let k = bestMap(maps, planes[i].n)
    let m = if k >= 0: maps[k] else: UVMap(attr: fallback)
    var f = Face(texture: m.attr.texture, flags: m.attr.flags, scriptId: m.attr.scriptId,
                 objectId: -1, piece: pc)
    for p in poly:
      f.verts.add g.points.len.int32
      g.points.add p
      f.colors.add m.attr.color
    if m.ok and m.n.dot(planes[i].n) > 0.999:
      for p in poly: f.uvs.add m.mapUV(p)
    else:
      g.mapNewFace(f, m.attr, densityOf(m.attr.texture))
    g.faces.add f
  g.weld(0.01)
  true

proc rehullPiece*(g: Geometry, pc: int32, points: seq[Vec3], maps: seq[UVMap],
                  densityOf: proc(tex: string): float32): bool =
  ## Rebuilds piece pc as the convex hull of points (vertex editing a brush).
  let planes = hullPlanes(points)
  if planes.len == 0: return false
  g.replacePiece(pc, planes, maps, densityOf)

proc addHull*(g: Geometry, points: seq[Vec3], attr: FaceAttr,
              densityOf: proc(tex: string): float32, maps: seq[UVMap] = @[]): int32 =
  ## A new brush: the convex hull of points. -1 when they span no volume.
  let planes = hullPlanes(points)
  if planes.len == 0: return -1
  result = g.pieces.len.int32
  g.pieces.add Piece(brush: true)
  if not g.replacePiece(result, planes, maps, densityOf, attr):
    g.pieces.setLen result
    return -1

proc csgHollow*(g: Geometry, pieces: seq[int32], thickness: float32,
                densityOf: proc(tex: string): float32): int =
  ## Replaces each brush with walls of the given thickness along its faces.
  let byPiece = g.pieceFaces
  var solids: seq[(seq[Plane], seq[FaceAttr])]
  for pc in pieces: solids.add g.solidOf(byPiece, pc)
  g.removePieces(toHashSet(pieces))
  for (planes, attrs) in solids:
    for i, pl in planes:
      var walls = planes
      walls.add Plane(n: -pl.n, d: -(pl.d - thickness))
      var a = attrs
      a.add attrs[i]
      if g.addSolid(walls, a, densityOf) >= 0: inc result

# --- extrusion -------------------------------------------------------------------------------

proc extrudeFaces*(g: Geometry, faces: HashSet[int], dist: float32) =
  ## Moves faces along their own normals (brush face drag / face tool push).
  var moves: Table[int32, Vec3]
  for fi in faces:
    let n = g.normal(g.faces[fi])
    for v in g.faces[fi].verts:
      moves[v] = moves.getOrDefault(v) + n * dist
  for v, d in moves:
    # A corner shared by two pushed faces moves along both normals.
    g.points[v] += d
  g.bump()

# --- picking ------------------------------------------------------------------------------

proc pickFace*(g: Geometry, r: Ray, visible: proc(fi: int): bool): (int, float32) =
  result = (-1, Inf.float32)
  for i, f in g.faces:
    if f.verts.len < 3 or not visible(i): continue
    let a = g.points[f.verts[0]]
    for k in 1 ..< f.verts.len - 1:
      let t = r.rayTriangle(a, g.points[f.verts[k]], g.points[f.verts[k + 1]])
      if t >= 0 and t < result[1]:
        result = (i, t)

# --- object-owned geometry --------------------------------------------------------------------

proc objectMatrix*(pos, rotDeg: Vec3): Mat4 =
  ## Oni object pose: rotate X, then Y, then Z (degrees), then translate.
  ## Oni's angles turn counterclockwise (right-handed); vmath's rotateX/Y/Z turn
  ## clockwise, hence the negated angles.
  let rx = rotateX(-rotDeg.x.float32.degToRad)
  let ry = rotateY(-rotDeg.y.float32.degToRad)
  let rz = rotateZ(-rotDeg.z.float32.degToRad)
  translate(pos) * rz * ry * rx

proc moveObjectGeometry*(g: Geometry, objectId: int32, oldPos, oldRot, newPos, newRot: Vec3) =
  ## Moves the faces linked to an object along with it.
  let m = objectMatrix(newPos, newRot) * objectMatrix(oldPos, oldRot).inverse
  var pts: HashSet[int32]
  for f in g.faces:
    if f.objectId == objectId:
      for v in f.verts: pts.incl v
  for v in pts: g.points[v] = m * g.points[v]
  g.bump()

proc objectFaces*(g: Geometry, objectId: int32): seq[int] =
  for i, f in g.faces:
    if f.objectId == objectId: result.add i
