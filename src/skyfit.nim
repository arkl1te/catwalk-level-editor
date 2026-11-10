## Which picture of a sky goes on which face, and turned how. Names can't tell:
## sets disagree on left and right, and on which way up top and bottom are. But
## neighbouring faces of a cube share an edge, so the pictures show how they fit
## together. A cube looks the same from 24 sides, so of the arrangements that
## fit equally well this takes the one nearest the file names.
##
## Sides are indices into SkySides. Turns are quarter turns clockwise. Mirrored
## pictures aren't looked for: no sky set is known to need it.

import std/strutils
import tga

const
  SkySides* = ["top", "left", "right", "front", "back", "bottom"]
  (sTop, sLeft, sRight, sFront, sBack, sBottom) = (0, 1, 2, 3, 4, 5)
  EdgeSamples = 64
  GoodSeam = 0.4'f32   ## A join's mean difference, as a share of that between unrelated edges.
  Tie = 1.25'f32       ## Arrangements this close to the best count as equally good.

type
  Edge = enum eTop, eRight, eBottom, eLeft

  Seam = tuple[a: int, ea: Edge, b: int, eb: Edge, flip: bool]

  SkyFit* = ref object
    edges: seq[array[4, array[4, seq[float32]]]]  ## Per picture, per turn, per edge.

const Seams: array[12, Seam] = [
  # Oni's layout (sky.nim), each edge read left to right or top to bottom.
  (sFront, eRight, sRight, eLeft, false), (sRight, eRight, sBack, eLeft, false),
  (sBack, eRight, sLeft, eLeft, false), (sLeft, eRight, sFront, eLeft, false),
  (sTop, eBottom, sFront, eTop, false), (sTop, eRight, sRight, eTop, true),
  (sTop, eTop, sBack, eTop, true), (sTop, eLeft, sLeft, eTop, false),
  (sBottom, eTop, sFront, eBottom, false), (sBottom, eRight, sRight, eBottom, false),
  (sBottom, eBottom, sBack, eBottom, true), (sBottom, eLeft, sLeft, eBottom, true)]

proc newSkyFit*(pictures: openArray[TgaImage]): SkyFit =
  ## Looks at the pictures' edges.
  result = SkyFit()
  for img in pictures:
    template at(x, y: int): float32 =
      let i = (y * img.width + x) * 4
      (img.rgba[i].float32 + img.rgba[i + 1].float32 + img.rgba[i + 2].float32) / 3
    var e: array[4, seq[float32]]
    for k in eTop .. eLeft: e[k.ord] = newSeq[float32](EdgeSamples)
    for n in 0 ..< EdgeSamples:
      let x = n * img.width div EdgeSamples
      let y = n * img.height div EdgeSamples
      e[eTop.ord][n] = at(x, 0)
      e[eRight.ord][n] = at(img.width - 1, y)
      e[eBottom.ord][n] = at(x, img.height - 1)
      e[eLeft.ord][n] = at(0, y)
    var turns: array[4, array[4, seq[float32]]]
    turns[0] = e
    proc reversed(s: seq[float32]): seq[float32] =
      for i in countdown(s.high, 0): result.add s[i]
    for t in 1 .. 3:
      let o = turns[t - 1]
      # A quarter turn clockwise.
      turns[t][eTop.ord] = reversed(o[eLeft.ord])
      turns[t][eRight.ord] = o[eTop.ord]
      turns[t][eBottom.ord] = reversed(o[eRight.ord])
      turns[t][eLeft.ord] = o[eBottom.ord]
    result.edges.add turns

proc seamCost(f: SkyFit, s: Seam, pa, ta, pb, tb: int): float32 =
  let (x, y) = (f.edges[pa][ta][s.ea.ord], f.edges[pb][tb][s.eb.ord])
  for i in 0 ..< EdgeSamples:
    result += abs(x[i] - y[if s.flip: EdgeSamples - 1 - i else: i])
  result /= EdgeSamples

type Search = object
  wanted: seq[int]         ## The side each picture is called, -1 for no idea.
  fixed: seq[int]          ## Per side: the picture that must go there, -1 free, -2 none.
  sides: seq[int]          ## Order to fill them in.
  place, turn: array[6, int]
  seams: int
  limit: float32           ## Total cost not to go past.
  best: tuple[score, cost: float32, place, turn: array[6, int], found: bool]
  picking: bool            ## Second pass: limit is fixed, score decides.

proc walk(f: SkyFit, s: var Search, depth: int, cost: float32, used: int) =
  if cost > s.limit: return
  if depth == s.sides.len:
    if not s.picking:
      s.limit = cost
      s.best.cost = cost
      s.best.found = true
      return
    var score = 0'f32
    for side in SkySides.low .. SkySides.high:
      let p = s.place[side]
      if p < 0: continue
      # Ties go to the side everyone looks at first.
      if s.wanted[p] == side: score += (if side == sFront: 101 else: 100)
      score -= s.turn[side].float32 + (if s.turn[side] != 0 and side notin [sTop, sBottom]: 10'f32 else: 0)
    if not s.best.found or score > s.best.score or (score == s.best.score and cost < s.best.cost):
      s.best = (score, cost, s.place, s.turn, true)
    return
  let side = s.sides[depth]
  for p in 0 ..< f.edges.len:
    if s.fixed[side] >= 0 and s.fixed[side] != p: continue
    if (used and (1 shl p)) != 0: continue
    s.place[side] = p
    for t in 0 .. 3:
      s.turn[side] = t
      var more = cost
      for seam in Seams:
        let (a, b) = (seam.a, seam.b)
        if a == side and s.place[b] >= 0: more += f.seamCost(seam, p, t, s.place[b], s.turn[b])
        elif b == side and s.place[a] >= 0: more += f.seamCost(seam, s.place[a], s.turn[a], p, t)
      f.walk(s, depth + 1, more, used or (1 shl p))
    s.turn[side] = 0
  s.place[side] = -1

proc unrelated(f: SkyFit): float32 =
  ## How different two edges that don't join are: a sky of soft clouds has
  ## small differences everywhere, so a fixed limit would pass anything.
  var n = 0
  for a in 0 ..< f.edges.len:
    for b in a + 1 ..< f.edges.len:
      for ea in 0 .. 3:
        for eb in 0 .. 3:
          for i in 0 ..< EdgeSamples: result += abs(f.edges[a][0][ea][i] - f.edges[b][0][eb][i])
          n += EdgeSamples
  result /= max(n, 1).float32

proc solve(f: SkyFit, wanted, fixed: seq[int]): tuple[ok: bool, place, turn: array[6, int]] =
  var s = Search(wanted: wanted, fixed: fixed, limit: 1e9)
  for side in [sFront, sRight, sBack, sLeft, sTop, sBottom]:
    if fixed[side] != -2: s.sides.add side
    s.place[side] = -1
  for seam in Seams:
    if fixed[seam.a] != -2 and fixed[seam.b] != -2: inc s.seams
  f.walk(s, 0, 0, 0)
  if not s.best.found or s.best.cost / s.seams.float32 > f.unrelated * GoodSeam: return
  s.limit = s.best.cost * Tie + 1
  s.picking = true
  s.best.found = false
  f.walk(s, 0, 0, 0)
  (true, s.best.place, s.best.turn)

proc arrange*(f: SkyFit, wanted: seq[int]): tuple[ok: bool, sides, turns: seq[int]] =
  ## Sides and turns per picture for five or six pictures, nearest wanted (-1
  ## for pictures with no name to go by). ok is false if their edges don't join.
  let n = f.edges.len
  if n notin 5 .. 6: return
  var fixed = newSeq[int](6)
  if n == 5: fixed[sBottom] = -2
  else: fixed[sBottom] = -1
  for side in 0 .. 4: fixed[side] = -1
  let r = f.solve(wanted, fixed)
  if not r.ok: return
  result.ok = true
  result.sides = newSeq[int](n)
  result.turns = newSeq[int](n)
  for side in 0 .. 5:
    if r.place[side] >= 0:
      result.sides[r.place[side]] = side
      result.turns[r.place[side]] = r.turn[side]

proc turnsFor*(f: SkyFit, sides: seq[int]): tuple[ok: bool, turns: seq[int]] =
  ## The turns for sides chosen by hand (per picture; another value = not
  ## used). ok is false if they don't join: all turns are 0 then.
  result.turns = newSeq[int](sides.len)
  if f == nil or sides.len != f.edges.len: return
  var fixed = @[-2, -2, -2, -2, -2, -2]
  for p, side in sides:
    if side in 0 .. 5: fixed[side] = p
  for side in 0 .. 4:
    if fixed[side] < 0: return
  let r = f.solve(sides, fixed)
  if not r.ok: return
  result.ok = true
  for side in 0 .. 5:
    if r.place[side] >= 0: result.turns[r.place[side]] = r.turn[side]

proc turned*(src: TgaImage, turns: int): TgaImage =
  ## src, quarter turns clockwise. Square pictures only.
  if turns mod 4 == 0: return src
  let n = src.width
  result = src
  for y in 0 ..< n:
    for x in 0 ..< n:
      let (sx, sy) = case turns mod 4
        of 1: (y, n - 1 - x)
        of 2: (n - 1 - x, n - 1 - y)
        else: (n - 1 - y, x)
      for k in 0 .. 3: result.rgba[(y * n + x) * 4 + k] = src.rgba[(sy * n + sx) * 4 + k]

const SideNames: array[6, seq[string]] = [
  @["top", "up", "py", "posy", "ceiling", "sky"], @["left", "lf", "lt", "nx", "negx", "west"],
  @["right", "rt", "px", "posx", "east"], @["front", "ft", "fr", "pz", "posz", "north"],
  @["back", "bk", "ba", "nz", "negz", "south"], @["bottom", "down", "dn", "bot", "ny", "negy", "floor"]]

proc sideByName*(file: string): int =
  ## The side a picture's name (without folder or extension) says, or -1.
  var words: seq[string]
  var w = ""
  for ch in file.toLowerAscii & " ":
    if ch in {'a'..'z'}: w.add ch
    elif w.len > 0:
      words.add w
      w = ""
  # The last word decides: "front_top" is a top.
  for i in countdown(words.high, 0):
    for side, names in SideNames:
      if words[i] in names: return side
  -1

proc guessSides*(names: seq[string]): seq[int] =
  ## By name, then in order: unknown pictures take the sides still free, and
  ## any more than six none (-1).
  result = newSeq[int](names.len)
  var free = @[0, 1, 2, 3, 4, 5]
  for i, n in names:
    result[i] = sideByName(n)
    if result[i] in free: free.del free.find(result[i])
    else: result[i] = -1
  for i in 0 ..< names.len:
    if result[i] < 0 and free.len > 0:
      result[i] = free[0]
      free.delete 0
