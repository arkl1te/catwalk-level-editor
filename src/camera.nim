## Viewport cameras: a fly camera for the 3D view and orthographic cameras
## for the top, front and side views. Oni is Y-up. Matrices are column-major
## float32[16], ready for glUniformMatrix4fv.

import std/math
import vmath

type
  M4* = array[16, float32]

  ViewKind* = enum vk3D = "3D", vkTop = "Top (X/Z)", vkFront = "Front (X/Y)", vkSide = "Side (Z/Y)"

  Ray* = object
    origin*, dir*: Vec3

  Camera* = object
    kind*: ViewKind
    # 3D
    pos*: Vec3
    yaw*, pitch*: float32   ## Radians; yaw 0 looks toward -Z.
    fovY*: float32
    # 2D
    center*: Vec2           ## In the view's own (right, up) plane coordinates.
    zoom*: float32          ## Pixels per world unit.

proc mul*(a, b: M4): M4 =
  for c in 0 .. 3:
    for r in 0 .. 3:
      var s = 0'f32
      for k in 0 .. 3: s += a[k * 4 + r] * b[c * 4 + k]
      result[c * 4 + r] = s

proc perspectiveM(fovY, aspect, n, f: float32): M4 =
  let t = 1 / tan(fovY / 2)
  result[0] = t / aspect
  result[5] = t
  result[10] = (f + n) / (n - f)
  result[11] = -1
  result[14] = 2 * f * n / (n - f)

proc orthoM(l, r, b, t, n, f: float32): M4 =
  result[0] = 2 / (r - l)
  result[5] = 2 / (t - b)
  result[10] = -2 / (f - n)
  result[12] = -(r + l) / (r - l)
  result[13] = -(t + b) / (t - b)
  result[14] = -(f + n) / (f - n)
  result[15] = 1

proc viewM(eye, fwd, up: Vec3): M4 =
  let f = fwd.normalize
  let s = f.cross(up).normalize
  let u = s.cross(f)
  result = [s.x, u.x, -f.x, 0, s.y, u.y, -f.y, 0, s.z, u.z, -f.z, 0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1]

proc forward*(c: Camera): Vec3 =
  vec3(-sin(c.yaw) * cos(c.pitch), sin(c.pitch), -cos(c.yaw) * cos(c.pitch))

proc right*(c: Camera): Vec3 = vec3(cos(c.yaw), 0, -sin(c.yaw))

proc axes*(kind: ViewKind): tuple[right, up, toViewer: Vec3] =
  ## World directions of a 2D view's screen right, screen up, and toward the viewer.
  case kind
  of vkTop: (vec3(1, 0, 0), vec3(0, 0, -1), vec3(0, 1, 0))
  of vkFront: (vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1))
  of vkSide: (vec3(0, 0, 1), vec3(0, 1, 0), vec3(-1, 0, 0))
  of vk3D: (vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1))

proc toPlane*(kind: ViewKind, p: Vec3): Vec2 =
  let a = kind.axes
  vec2(p.dot(a.right), p.dot(a.up))

const Depth2D = 100000'f32

proc matrix*(c: Camera, w, h: float32): M4 =
  ## Projection * view for a viewport of w x h pixels.
  if c.kind == vk3D:
    mul(perspectiveM(c.fovY, w / max(h, 1), 2, 40000), viewM(c.pos, c.forward, vec3(0, 1, 0)))
  else:
    let a = c.kind.axes
    let hw = w / 2 / c.zoom
    let hh = h / 2 / c.zoom
    let eye = a.right * c.center.x + a.up * c.center.y + a.toViewer * Depth2D
    mul(orthoM(-hw, hw, -hh, hh, 1, Depth2D * 2), viewM(eye, -a.toViewer, a.up))

proc ray*(c: Camera, px, py, w, h: float32): Ray =
  ## Ray through viewport pixel (px, py), origin top-left.
  let nx = px / w * 2 - 1
  let ny = 1 - py / h * 2
  if c.kind == vk3D:
    let t = tan(c.fovY / 2)
    let f = c.forward
    let r = c.right
    let u = r.cross(f).normalize
    Ray(origin: c.pos, dir: (f + r * (nx * t * w / max(h, 1)) + u * (ny * t)).normalize)
  else:
    let a = c.kind.axes
    let wx = c.center.x + nx * w / 2 / c.zoom
    let wy = c.center.y + ny * h / 2 / c.zoom
    Ray(origin: a.right * wx + a.up * wy + a.toViewer * Depth2D, dir: -a.toViewer)

proc worldToPixel*(c: Camera, p: Vec3, w, h: float32): Vec2 =
  ## 2D views only: world point to viewport pixel.
  let q = c.kind.toPlane(p)
  vec2(w / 2 + (q.x - c.center.x) * c.zoom, h / 2 - (q.y - c.center.y) * c.zoom)

proc pixelToPlane*(c: Camera, px, py, w, h: float32): Vec2 =
  vec2(c.center.x + (px - w / 2) / c.zoom, c.center.y - (py - h / 2) / c.zoom)

proc rayBox*(r: Ray, lo, hi: Vec3): float32 =
  ## Distance along the ray to an axis-aligned box, or -1.
  var tmin = -Inf.float32
  var tmax = Inf.float32
  for i in 0 .. 2:
    let o = r.origin[i]
    let d = r.dir[i]
    if abs(d) < 1e-8:
      if o < lo[i] or o > hi[i]: return -1
    else:
      var t1 = (lo[i] - o) / d
      var t2 = (hi[i] - o) / d
      if t1 > t2: swap(t1, t2)
      tmin = max(tmin, t1)
      tmax = min(tmax, t2)
      if tmin > tmax: return -1
  if tmax < 0: return -1
  max(tmin, 0)

proc rayTriangle*(r: Ray, a, b, c: Vec3): float32 =
  ## Möller–Trumbore; distance or -1. Both faces hit.
  let e1 = b - a
  let e2 = c - a
  let p = r.dir.cross(e2)
  let det = e1.dot(p)
  if abs(det) < 1e-7: return -1
  let inv = 1 / det
  let s = r.origin - a
  let u = s.dot(p) * inv
  if u < 0 or u > 1: return -1
  let q = s.cross(e1)
  let v = r.dir.dot(q) * inv
  if v < 0 or u + v > 1: return -1
  let t = e2.dot(q) * inv
  if t < 0: -1'f32 else: t

proc project*(c: Camera, p: Vec3, w, h: float32): (bool, Vec2) =
  ## World point to viewport pixel (origin top-left); false when behind the camera.
  let m = c.matrix(w, h)
  let x = m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12]
  let y = m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13]
  let wc = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15]
  if wc <= 1e-4: return (false, vec2(0, 0))
  (true, vec2((x / wc * 0.5 + 0.5) * w, (0.5 - y / wc * 0.5) * h))
