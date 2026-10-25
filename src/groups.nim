## Groups, ported from TrenchBroom (Map_Groups.cpp, SelectionTool, the linked
## group updates): Ctrl+G groups the selection, a click on any member selects
## the whole group, a double-click opens it (everything else is locked until it
## is closed again), Ctrl+D copies it and Ctrl+Shift+D makes a linked
## duplicate, whose contents follow every edit made inside any of its copies.
##
## Included by appstate.nim. Objects are members through Group.objs, pieces
## through Piece.group; object-owned geometry goes with its object. Each push
## records the group table (captureGroups), so undo covers group changes.

const
  GroupsFile = "groups.json"
  AffineScale = 256'f32   ## affineOf samples this far out: less float32 rounding.

# --- affine maps ------------------------------------------------------------------------------

proc identityAffine*(): Affine = Affine(m: [vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)])

proc apply*(x: Affine, p: Vec3): Vec3 = x.m[0] * p.x + x.m[1] * p.y + x.m[2] * p.z + x.t
proc applyDir*(x: Affine, d: Vec3): Vec3 = x.m[0] * d.x + x.m[1] * d.y + x.m[2] * d.z

proc `*`*(x, y: Affine): Affine =
  ## x after y.
  for i in 0 .. 2: result.m[i] = x.applyDir(y.m[i])
  result.t = x.apply(y.t)

proc det*(x: Affine): float32 = x.m[0].dot(x.m[1].cross(x.m[2]))

proc inverse*(x: Affine): Affine =
  let d = x.det
  if abs(d) < 1e-12: return identityAffine()
  let r0 = x.m[1].cross(x.m[2]) / d
  let r1 = x.m[2].cross(x.m[0]) / d
  let r2 = x.m[0].cross(x.m[1]) / d
  result.m = [vec3(r0.x, r1.x, r2.x), vec3(r0.y, r1.y, r2.y), vec3(r0.z, r1.z, r2.z)]
  result.t = -result.applyDir(x.t)

proc affineOf*(f: proc(p: Vec3): Vec3): Affine =
  ## The affine map f is (move, rotate, mirror, scale).
  result.t = f(vec3(0, 0, 0))
  for i in 0 .. 2:
    var e = vec3(0, 0, 0)
    e[i] = AffineScale
    result.m[i] = (f(e) - result.t) / AffineScale

proc affineJson(x: Affine): JsonNode =
  result = newJArray()
  for v in [x.m[0], x.m[1], x.m[2], x.t]:
    for k in 0 .. 2: result.add %v[k]

proc affineFrom(j: JsonNode): Affine =
  let e = j.getElems
  if e.len != 12: return identityAffine()
  for i in 0 .. 2: result.m[i] = vec3(e[i * 3].getFloat, e[i * 3 + 1].getFloat, e[i * 3 + 2].getFloat)
  result.t = vec3(e[9].getFloat, e[10].getFloat, e[11].getFloat)

proc poseThrough(x: Affine, o: LevelObject): (Vec3, Vec3) =
  ## An object's position and rotation carried through x. Its box center goes
  ## through x, as flipSelection places objects (a model's box isn't centered
  ## on the position), and a mirror turns the pose like a flip: the side axis
  ## follows.
  let m = objectMatrix(vec3(0, 0, 0), o.rot)
  var ex = x.applyDir(m * vec3(1, 0, 0)).normalize
  let ey = x.applyDir(m * vec3(0, 1, 0)).normalize
  let ez = x.applyDir(m * vec3(0, 0, 1)).normalize
  if x.det < 0: ex = -ex
  let rot = objectRotation(ex, ey, ez)
  let target = x.apply(o.boxCenter)
  let (pos0, rot0) = (o.pos, o.rot)
  o.pos = vec3(0, 0, 0)
  o.rot = rot
  let offset = o.boxCenter
  o.pos = pos0
  o.rot = rot0
  (target - offset, rot)

# --- membership -------------------------------------------------------------------------------

proc newGroupId(a: App): int32 =
  for g in a.groups: result = max(result, g.id)
  inc result

var linkCounter = 0

proc newLink(a: App): string =
  var used: HashSet[string]
  for g in a.groups: used.incl g.link
  while true:
    inc linkCounter
    result = &"L{int64(epochTime() * 1000)}-{linkCounter}"
    if result notin used: return

proc addToGroup(a: App, o: LevelObject, gid: int32) =
  ## Makes o a direct member of group gid (0 = of none).
  for g in a.groups.mitems:
    let k = g.objs.find(o)
    if k >= 0: g.objs.delete k
  let i = a.groupAt(gid)
  if i >= 0: a.groups[i].objs.add o

proc groupName*(a: App, id: int32): string =
  let i = a.groupAt(id)
  if i >= 0: a.groups[i].name else: ""

proc inside*(a: App, gid, anc: int32): bool =
  ## Whether group gid is anc or inside it.
  var g = gid
  var guard = 0
  while g != 0 and guard < 1000:
    if g == anc: return true
    let i = a.groupAt(g)
    g = if i >= 0: a.groups[i].parent else: 0
    inc guard

proc depth(a: App, gid: int32): int =
  var g = gid
  while g != 0 and result < 1000:
    let i = a.groupAt(g)
    g = if i >= 0: a.groups[i].parent else: 0
    inc result

proc subtree(a: App, gid: int32): HashSet[int32] =
  ## gid and every group inside it.
  for g in a.groups:
    if a.inside(g.id, gid): result.incl g.id

proc worldPieceSet(a: App): seq[bool] =
  ## Which pieces have level geometry (faces no object owns).
  if a.geo == nil: return
  result = newSeq[bool](a.geo.pieces.len)
  for f in a.geo.faces:
    if f.objectId == -1 and f.piece >= 0 and f.piece < result.len: result[f.piece] = true

proc members*(a: App, gid: int32): (seq[LevelObject], seq[int32]) =
  ## The objects and pieces in group gid, groups inside it included.
  let set = a.subtree(gid)
  var live: HashSet[LevelObject]
  for o in a.objects: live.incl o
  for g in a.groups:
    if g.id in set:
      for o in g.objs:
        if o in live: result[0].add o
  let world = a.worldPieceSet
  for pc in 0 ..< world.len:
    if world[pc] and a.geo.pieces[pc].group in set: result[1].add pc.int32

proc groupBounds*(a: App, gid: int32): (bool, Vec3, Vec3) =
  ## The box around a group's contents (TrenchBroom draws it around groups).
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  let (objs, pieces) = a.members(gid)
  for o in objs:
    let (l, h) = o.pickBox
    lo = min(lo, l)
    hi = max(hi, h)
  if pieces.len > 0:
    let set = toHashSet(pieces)
    for f in a.geo.faces:
      if f.objectId == -1 and f.piece in set:
        for v in f.verts:
          lo = min(lo, a.geo.points[v])
          hi = max(hi, a.geo.points[v])
  (lo.x <= hi.x, lo, hi)

proc selectGroup*(a: App, gid: int32, on = true) =
  let (objs, pieces) = a.members(gid)
  for o in objs: o.selected = on
  for pc in pieces:
    if on: a.selPieces.incl pc else: a.selPieces.excl pc

proc selectedUnits*(a: App): (seq[int32], bool) =
  ## Closed groups the selection holds, outermost (what a click selects), and
  ## whether it also holds objects or pieces outside them.
  var seen: HashSet[int32]
  proc note(gid: int32, res: var (seq[int32], bool)) =
    let u = a.unitOf(gid)
    if u == 0: res[1] = true
    elif not seen.containsOrIncl(u): res[0].add u
  for o in a.selection: note(a.objGroup(o), result)
  for pc in a.selPieces: note(a.pieceGroup(pc), result)

proc expandGroupSelection*(a: App) =
  ## Once a frame: a selected member of a closed group selects the whole group
  ## (TrenchBroom selects group nodes; select all, the layer tree and the
  ## rest select members).
  if a.groups.len == 0: return
  for u in a.selectedUnits[0]: a.selectGroup(u)

proc onlyGroupsSelected*(a: App): bool =
  let (units, loose) = a.selectedUnits
  units.len > 0 and not loose and a.selFaces.len == 0

proc memberCounts(a: App): Table[int32, (int, int)] =
  ## Per group: how many objects and pieces it holds, groups inside it
  ## included, and how many of them are selected.
  proc count(a: App, gid: int32, sel: bool, res: var Table[int32, (int, int)]) =
    var g = gid
    var guard = 0
    while g != 0 and guard < 1000:
      var c = res.getOrDefault(g)
      inc c[0]
      if sel: inc c[1]
      res[g] = c
      let i = a.groupAt(g)
      g = if i >= 0: a.groups[i].parent else: 0
      inc guard
  var live: HashSet[LevelObject]
  for o in a.objects: live.incl o
  for g in a.groups:
    for o in g.objs:
      if o in live: a.count(g.id, o.selected, result)
  let world = a.worldPieceSet
  for pc in 0 ..< world.len:
    if world[pc] and a.geo.pieces[pc].group != 0:
      a.count(a.geo.pieces[pc].group, pc.int32 in a.selPieces, result)

proc transformSelectedGroups*(a: App, x: Affine) =
  ## A selected closed group (and every group inside it) moved, turned or
  ## flipped whole: its xform follows, so linked copies keep their own place.
  if a.groups.len == 0: return
  let counts = a.memberCounts
  for g in a.groups.mitems:
    if g.id in a.openGroups: continue
    let (n, s) = counts.getOrDefault(g.id)
    if n > 0 and n == s: g.xform = x * g.xform

proc pruneGroups(a: App) =
  ## Members that were deleted leave their group; groups left empty go
  ## (TrenchBroom removes empty groups).
  var live: HashSet[LevelObject]
  for o in a.objects: live.incl o
  for g in a.groups.mitems: g.objs.keepIf(proc(o: LevelObject): bool = o in live)
  let world = a.worldPieceSet
  var used: HashSet[int32]
  for pc in 0 ..< world.len:
    if world[pc]: used.incl a.geo.pieces[pc].group
  var full: HashSet[int32]
  for g in a.groups:
    if g.objs.len > 0 or g.id in used:
      var p = g.id
      var guard = 0
      while p != 0 and not full.containsOrIncl(p) and guard < 1000:
        let i = a.groupAt(p)
        p = if i >= 0: a.groups[i].parent else: 0
        inc guard
  a.groups.keepIf(proc(g: Group): bool = g.id in full)

# --- linked groups ----------------------------------------------------------------------------

type GroupIndex = object
  ## Lookups for comparing and copying group contents, made once per sync.
  objGroup: Table[LevelObject, int32]
  byPiece: seq[seq[int]]
  owned: Table[int32, seq[int]]
  world: seq[bool]

proc groupIndex(a: App): GroupIndex =
  var live: HashSet[LevelObject]
  for o in a.objects: live.incl o
  for g in a.groups:
    for o in g.objs:
      if o in live: result.objGroup[o] = g.id
  if a.geo != nil:
    result.byPiece = a.geo.pieceFaces
    result.world = a.worldPieceSet
    for i, f in a.geo.faces:
      if f.objectId != -1: result.owned.mgetOrPut(f.objectId, @[]).add i

proc preserved(o: LevelObject): seq[string] =
  ## Fields each linked copy keeps its own value of (TrenchBroom's protected
  ## properties): scripts tell copies apart by them.
  if o.tag in ScriptIdFields: result.add ScriptIdFields[o.tag]
  if o.tag == "CHAR": result.add "OSD/Name"

proc faceSig(f: Face, g: Geometry): string =
  ## A face as its link set shares it: corners and look. Baked colors stay
  ## each copy's own (they depend on where it is).
  result = f.texture & "|" & $f.flags & "|" & $f.scriptId & "|"
  for v in f.verts:
    let p = g.points[v]
    result.add $p.x & "," & $p.y & "," & $p.z & ";"
  for uv in f.uvs: result.add $uv.x & "," & $uv.y & ";"
  for m in f.anims: result.add $m & ";"

proc linkedSig(a: App, gid: int32, ix: GroupIndex): LinkSig =
  ## The group's objects and geometry exactly as they are, and its xform. A
  ## different sig with the same xform is an edit inside it; a new xform is the
  ## group moved whole (transformSelectedGroups), which changes nothing inside.
  let set = a.subtree(gid)
  proc linkOf(id: int32): string =
    if id == gid: "" else: a.groups[a.groupAt(id)].link
  var objs = ""
  for o in a.objects:
    let og = ix.objGroup.getOrDefault(o, 0)
    if og == 0 or og notin set: continue
    let n = parseXml(o.snapshot)
    n.attrs = nil
    for path in o.preserved:
      let e = n.xpath(path)
      if e != nil: e.setText("")
    objs.add o.tag & "|" & linkOf(og) & "|" & $n
    for fi in ix.owned.getOrDefault(o.objectCode): objs.add "\n" & faceSig(a.geo.faces[fi], a.geo)
    objs.add "\n"
  var geo = ""
  for pc in 0 ..< ix.world.len:
    let pg = a.geo.pieces[pc].group
    if not ix.world[pc] or pg == 0 or pg notin set: continue
    geo.add "P" & $a.geo.pieces[pc].brush & "|" & linkOf(pg) & "\n"
    for fi in ix.byPiece[pc]:
      if a.geo.faces[fi].objectId == -1: geo.add faceSig(a.geo.faces[fi], a.geo) & "\n"
  (hash(objs), hash(geo), a.groups[a.groupAt(gid)].xform)

proc linkedGroups(a: App): seq[int32] =
  ## Groups whose link set has more than one member.
  var n: CountTable[string]
  for g in a.groups: n.inc g.link
  for g in a.groups:
    if n[g.link] > 1: result.add g.id

proc storeLinkSigs(a: App) =
  a.linkSigs.clear()
  let linked = a.linkedGroups
  if linked.len == 0: return
  let ix = a.groupIndex
  for id in linked: a.linkSigs[id] = a.linkedSig(id, ix)

proc removeFacesKeepPieces(a: App, gone: HashSet[int]) =
  ## Drops faces without renumbering pieces (the selection's pieces stay put);
  ## selected faces are renumbered. Empty pieces and loose points go on the
  ## next compact.
  if gone.len == 0: return
  var keep: seq[Face]
  var newIndex = newSeq[int](a.geo.faces.len)
  for i, f in a.geo.faces:
    if i in gone: newIndex[i] = -1
    else:
      newIndex[i] = keep.len
      keep.add f
  a.geo.faces = keep
  var sel: HashSet[int]
  for fi in a.selFaces:
    if fi < newIndex.len and newIndex[fi] >= 0: sel.incl newIndex[fi]
  a.selFaces = sel
  if a.lastFace >= 0 and a.lastFace < newIndex.len: a.lastFace = newIndex[a.lastFace]
  a.geo.bump()

proc copyFacesThrough(a: App, faces: seq[int], x: Affine): seq[int] =
  ## Copies faces (into new pieces, like duplicateFaces) carried through x.
  if faces.len == 0: return
  result = a.geo.duplicateFaces(faces, vec3(0, 0, 0))
  let added = toHashSet(result)
  for v in a.geo.pointsOf(added): a.geo.points[v] = x.apply(a.geo.points[v])
  if x.det < 0: a.geo.reverseWinding(added)
  a.geo.bump()

proc replaceContents(a: App, tid, sid: int32, doObjs, doGeo: bool, c: var Cmd) =
  ## Makes linked group tid's contents a copy of sid's, placed by tid's xform
  ## (TrenchBroom's UpdateLinkedGroupsHelper). Objects keep their ids and
  ## preserved fields; groups inside are matched by link.
  let ix = a.groupIndex
  let x = a.groups[a.groupAt(tid)].xform * a.groups[a.groupAt(sid)].xform.inverse
  let sSet = a.subtree(sid)
  let tSet = a.subtree(tid)
  # What tid holds now (before groups inside it are renumbered).
  var tObjs, sObjs: seq[LevelObject]
  for o in a.objects:
    let og = ix.objGroup.getOrDefault(o, 0)
    if og in tSet: tObjs.add o
    elif og in sSet: sObjs.add o
  var tFaces, sFaces: seq[int]
  if a.geo != nil:
    for pc in 0 ..< ix.world.len:
      let pg = a.geo.pieces[pc].group
      if not ix.world[pc] or pg == 0: continue
      for fi in ix.byPiece[pc]:
        if a.geo.faces[fi].objectId != -1: continue
        if pg in tSet: tFaces.add fi
        elif pg in sSet: sFaces.add fi
  # Groups inside: reuse tid's by link, make the missing ones, drop the rest.
  var map = {sid: tid}.toTable
  var usedT: HashSet[int32]
  var made: seq[Group]
  var nextId = a.newGroupId
  for sg in a.groups:
    if sg.id == sid or sg.id notin sSet: continue
    var found = 0'i32
    for tg in a.groups:
      if tg.id != tid and tg.id in tSet and tg.id notin usedT and tg.link == sg.link:
        found = tg.id
        break
    if found == 0:
      found = nextId
      inc nextId
      made.add Group(id: found)
    usedT.incl found
    map[sg.id] = found
  a.groups.add made
  for sg in a.groups:
    if sg.id == sid or sg.id notin sSet: continue
    let k = a.groupAt(map[sg.id])
    a.groups[k].name = sg.name
    a.groups[k].link = sg.link
    a.groups[k].parent = map.getOrDefault(sg.parent, sg.parent)
    a.groups[k].xform = x * sg.xform
  var orphans: seq[LevelObject]
  var kept: seq[Group]
  for g in a.groups:
    if g.id != tid and g.id in tSet and g.id notin usedT:
      orphans.add g.objs
    else: kept.add g
  a.groups = kept
  for o in orphans: a.addToGroup(o, tid)
  var gone: HashSet[int]
  if doObjs:
    # Pair tid's objects with sid's, per type in order.
    var byTag: Table[string, seq[LevelObject]]
    for o in tObjs: byTag.mgetOrPut(o.tag, @[]).add o
    var nextObj = a.objects.nextId
    var codes: seq[(LevelObject, int32)]   # (source, owner code its geometry goes to)
    for so in sObjs:
      let sg = ix.objGroup.getOrDefault(so, sid)
      var to: LevelObject = nil
      if byTag.getOrDefault(so.tag).len > 0:
        to = byTag[so.tag][0]
        byTag[so.tag].delete 0
        let before = to.snapshot
        var keep: seq[(string, string)]
        for path in to.preserved: keep.add (path, to.node.xpath(path).str)
        let oldId = to.node.attr("Id")
        to.restore(so.snapshot)
        to.node.setAttr("Id", oldId)
        for (path, v) in keep:
          let e = to.node.xpath(path)
          if e != nil: e.setText(v)
        to.syncFromNode()
        let (p, r) = x.poseThrough(so)
        a.setPose(to, p, r, moveGeometry = false)
        c.extra.add Cmd(label: c.label, kind: ckEdit, objs: @[to], before: @[before], after: @[to.snapshot])
      else:
        to = so.duplicate(nextObj)
        inc nextObj
        let (p, r) = x.poseThrough(so)
        a.setPose(to, p, r, moveGeometry = false)
        a.objects.add to
        c.extra.add Cmd(label: c.label, kind: ckAdd, objs: @[to], indices: @[to.file.list.findChild(to.node)])
      if to.tag == "DOOR":
        let sc = so.node.xpath("OSD/Center")
        let tc = to.node.xpath("OSD/Center")
        if sc != nil and tc != nil: tc.setText(fmtVec3(x.apply(parseVec3(sc.str))))
        to.syncToNode()
      a.addToGroup(to, map.getOrDefault(sg, tid))
      codes.add (so, to.objectCode)
    for _, rest in byTag:
      for o in rest:
        let idx = o.detach()
        o.selected = false
        a.removeFromList(o)
        a.addToGroup(o, 0)
        c.extra.add Cmd(label: c.label, kind: ckRemove, objs: @[o], indices: @[idx])
    if a.geo != nil:
      for o in tObjs:
        for fi in ix.owned.getOrDefault(o.objectCode): gone.incl fi
      for (so, code) in codes:
        for fi in a.copyFacesThrough(ix.owned.getOrDefault(so.objectCode), x):
          a.geo.faces[fi].objectId = code
  if doGeo and a.geo != nil:
    for fi in tFaces: gone.incl fi
    for fi in a.copyFacesThrough(sFaces.sorted, x):
      let pc = a.geo.faces[fi].piece
      a.geo.pieces[pc].group = map.getOrDefault(a.geo.pieces[pc].group, tid)
  if a.geo != nil: a.removeFacesKeepPieces(gone)

proc adoptNew(a: App, c: Cmd): bool =
  ## TrenchBroom adds new nodes to the open group: objects the command made and
  ## pieces it added. True if pieces changed.
  if a.openGroups.len == 0: return
  let cur = a.openGroups[^1]
  if c.kind == ckAdd:
    for o in c.objs:
      if a.objGroup(o) == 0 and o in a.objects: a.addToGroup(o, cur)
  if c.geoBefore != nil and a.geo != nil:
    let world = a.worldPieceSet
    for pc in c.geoBefore.pieces.len ..< a.geo.pieces.len:
      if world[pc] and a.geo.pieces[pc].group == 0:
        a.geo.pieces[pc].group = cur
        result = true

proc syncLinkedGroups(a: App, c: var Cmd) =
  ## Before a command is pushed: new things join the open group, empty groups
  ## go, and an edit inside one linked group is copied into the rest of its
  ## link set (outermost first; a copy's groups inside are synced after).
  var geoTouched = a.adoptNew(c)
  a.pruneGroups()
  let linked = a.linkedGroups
  if linked.len > 0:
    let geoStart = if a.geo != nil: a.geo.clone else: nil
    let objCount = c.extra.len
    var guard = 0
    while guard < 32:
      inc guard
      let ix = a.groupIndex
      var changed: seq[(int32, bool, bool)]
      for id in a.linkedGroups:
        let now = a.linkedSig(id, ix)
        let was = a.linkSigs.getOrDefault(id, now)
        if now[2] == was[2] and (now[0] != was[0] or now[1] != was[1]):
          changed.add (id, now[0] != was[0], now[1] != was[1])
      if changed.len == 0: break
      # The edited copy: the outermost changed group, preferring the open one.
      var best = 0
      proc rank(k: int): (int, int) =
        let id = changed[k][0]
        (a.depth(id), (if a.openGroups.len > 0 and a.inside(a.openGroups[^1], id): 0 else: 1))
      for k in 1 ..< changed.len:
        if rank(k) < rank(best): best = k
      let (sid, doObjs, doGeo) = changed[best]
      let link = a.groups[a.groupAt(sid)].link
      var targets: seq[int32]
      for g in a.groups:
        if g.link == link and g.id != sid and not a.inside(g.id, sid) and not a.inside(sid, g.id):
          targets.add g.id
      for t in targets: a.replaceContents(t, sid, doObjs, doGeo, c)
      a.pruneGroups()
      # The copies are in line now; what changed inside the source still has
      # to reach groups linked to its own groups, so those keep their old state.
      let ix2 = a.groupIndex
      a.linkSigs[sid] = a.linkedSig(sid, ix2)
      for t in targets:
        if a.groupAt(t) < 0: continue
        for id in a.subtree(t): a.linkSigs[id] = a.linkedSig(id, ix2)
    if guard >= 32: a.say("Linked groups: gave up bringing every copy in line", true)
    if a.geo != nil and geoStart != nil and a.geo.version != geoStart.version:
      geoTouched = true
      if c.geoBefore == nil:
        c.extra.insert(geoCmd(c.label, geoStart, a.geo), objCount)
  if geoTouched and c.geoBefore != nil and a.geo != nil: c.geoAfter = a.geo.clone
  a.refreshOpenSet()
  a.storeLinkSigs()

proc amendLast*(a: App) =
  ## A live edit merged into the last undo step (Face tab typing): its linked
  ## copies follow, and the step ends where the geometry is now.
  if a.undoStack.len == 0: return
  a.syncLinkedGroups(a.undoStack[^1])
  a.captureGroups(a.undoStack[^1])
  if a.geo != nil and a.undoStack[^1].geoBefore != nil: a.undoStack[^1].geoAfter = a.geo.clone

# --- group commands ---------------------------------------------------------------------------

proc groupCmd(a: App, label: string, geoBefore: Geometry): Cmd =
  if geoBefore != nil and a.geo != nil and a.geo.version != geoBefore.version:
    geoCmd(label, geoBefore, a.geo)
  else: Cmd(label: label, kind: ckEdit)

proc canGroup*(a: App): bool =
  a.proj != nil and (a.selection.len > 0 or a.selPieces.len > 0)

proc groupSelection*(a: App, name: string) =
  ## Ctrl+G: the selection becomes one group (in the open group, if any).
  if not a.canGroup: return
  let (units, _) = a.selectedUnits
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let id = a.newGroupId
  a.groups.add Group(id: id, name: name, parent: (if a.openGroups.len > 0: a.openGroups[^1] else: 0),
                     link: a.newLink, xform: identityAffine())
  for u in units: a.groups[a.groupAt(u)].parent = id
  for o in a.selection:
    if a.unitOf(a.objGroup(o)) == 0: a.addToGroup(o, id)
  var changed = false
  let world = a.worldPieceSet
  for pc in a.selPieces:
    if pc < world.len and world[pc] and a.unitOf(a.geo.pieces[pc].group) == 0:
      a.geo.pieces[pc].group = id
      changed = true
  if changed: a.geo.bump()
  a.push a.groupCmd("Group Selected Objects", geoBefore)
  a.say &"Grouped the selection as {name}"

proc ungroupSelection*(a: App) =
  ## Ctrl+Shift+G: the selected groups' contents go up a level; they stay selected.
  let (units, _) = a.selectedUnits
  if units.len == 0: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  var changed = false
  for u in units:
    let i = a.groupAt(u)
    if i < 0: continue
    let parent = a.groups[i].parent
    let objs = a.groups[i].objs
    for o in objs: a.addToGroup(o, parent)
    for g in a.groups.mitems:
      if g.parent == u: g.parent = parent
    if a.geo != nil:
      for p in a.geo.pieces.mitems:
        if p.group == u:
          p.group = parent
          changed = true
    a.groups.delete a.groupAt(u)
  if changed: a.geo.bump()
  a.push a.groupCmd("Ungroup", geoBefore)
  a.say &"Ungrouped {units.len} group(s)"

proc renameSelectedGroups*(a: App, name: string) =
  let (units, _) = a.selectedUnits
  if units.len == 0: return
  for u in units: a.groups[a.groupAt(u)].name = name
  a.push Cmd(label: (if units.len == 1: "Rename Group" else: "Rename Groups"), kind: ckEdit)

proc canLinkedDuplicate*(a: App): bool =
  let (units, loose) = a.selectedUnits
  units.len == 1 and not loose and a.selFaces.len == 0

proc copySelectedGroups(a: App, offset: Vec3, linked: bool): Table[int32, int32] =
  ## Duplicate: the selected closed groups and the groups inside them get
  ## copies (linked: in the same link sets). Old id -> new id.
  let (units, _) = a.selectedUnits
  if units.len == 0: return
  var copied: HashSet[int32]
  for u in units:
    for id in a.subtree(u): copied.incl id
  var id = a.newGroupId
  for g in a.groups:
    if g.id in copied:
      result[g.id] = id
      inc id
  let move = affineOf(proc(p: Vec3): Vec3 = p + offset)
  var made: seq[Group]
  var links: Table[string, string]   # unlinked copies: one new link per old one
  for g in a.groups:
    if g.id notin copied: continue
    let link = if linked: g.link else: links.mgetOrPut(g.link, a.newLink & "-" & $made.len)
    made.add Group(id: result[g.id], name: g.name, parent: result.getOrDefault(g.parent, g.parent),
                   link: link, xform: move * g.xform)
  a.groups.add made

proc selectLinkedGroups*(a: App) =
  ## Every group linked to a selected one (that can be selected as a whole).
  let (units, _) = a.selectedUnits
  var links: HashSet[string]
  for u in units: links.incl a.groups[a.groupAt(u)].link
  for g in a.groups:
    if g.link in links and a.unitOf(g.id) == g.id and not a.groupLocked(g.parent):
      a.selectGroup(g.id)

proc canSelectLinkedGroups*(a: App): bool =
  let (units, _) = a.selectedUnits
  for u in units:
    let link = a.groups[a.groupAt(u)].link
    for g in a.groups:
      if g.id != u and g.link == link: return true

proc canSeparateLinkedGroups*(a: App): bool =
  ## A selected group linked to one that isn't selected.
  let (units, _) = a.selectedUnits
  let sel = toHashSet(units)
  for u in units:
    let link = a.groups[a.groupAt(u)].link
    for g in a.groups:
      if g.link == link and g.id notin sel: return true

proc separateLinkedGroups*(a: App) =
  ## The selected groups leave their link sets; selected groups of one set stay
  ## linked to each other (TrenchBroom's separateSelectedLinkedGroups).
  let (units, _) = a.selectedUnits
  let sel = toHashSet(units)
  var byLink: Table[string, seq[int32]]
  for u in units: byLink.mgetOrPut(a.groups[a.groupAt(u)].link, @[]).add u
  var n = 0
  for link, us in byLink:
    var all = 0
    for g in a.groups:
      if g.link == link: inc all
    if all == us.len: continue
    var remap: Table[string, string]
    for u in us:
      for id in a.subtree(u):
        let i = a.groupAt(id)
        if not remap.hasKey(a.groups[i].link): remap[a.groups[i].link] = a.newLink & "-" & $remap.len
        a.groups[i].link = remap[a.groups[i].link]
    n += us.len
  discard sel
  if n > 0:
    a.push Cmd(label: "Separate Linked Groups", kind: ckEdit)
    a.say &"Separated {n} group(s) from their linked copies"

proc linkedCount*(a: App, gid: int32): int =
  let i = a.groupAt(gid)
  if i < 0: return 0
  for g in a.groups:
    if g.link == a.groups[i].link: inc result

proc selectionIsLinked*(a: App): bool =
  ## Just one linked group selected: Ctrl+drag copies it as another linked duplicate.
  if not a.canLinkedDuplicate: return false
  let (units, _) = a.selectedUnits
  a.linkedCount(units[0]) > 1

proc openGroup*(a: App, gid: int32) =
  ## Double-click: edit inside the group; the rest is locked until it closes.
  if a.groupAt(gid) < 0: return
  a.clearSelection()
  a.openGroups.add gid
  a.refreshOpenSet()
  a.say "Opened group " & a.groupName(gid)

proc closeGroup*(a: App) =
  if a.openGroups.len == 0: return
  let gid = a.openGroups.pop
  a.clearSelection()
  a.refreshOpenSet()
  a.say "Closed group " & a.groupName(gid)

proc canRemoveFromGroup*(a: App): bool =
  a.openGroups.len > 0 and (a.selection.len > 0 or a.selPieces.len > 0)

proc moveSelectionToGroup(a: App, target: int32, label: string) =
  ## Reparents what is selected (whole closed groups, or things themselves).
  let (units, _) = a.selectedUnits
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  for u in units:
    if u != target and not a.inside(target, u): a.groups[a.groupAt(u)].parent = target
  for o in a.selection:
    if a.unitOf(a.objGroup(o)) == 0: a.addToGroup(o, target)
  var changed = false
  let world = a.worldPieceSet
  for pc in a.selPieces:
    if pc < world.len and world[pc] and a.unitOf(a.geo.pieces[pc].group) == 0:
      a.geo.pieces[pc].group = target
      changed = true
  if changed: a.geo.bump()
  a.push a.groupCmd(label, geoBefore)

proc removeSelectionFromGroup*(a: App) =
  ## TrenchBroom's Remove Objects from Group: out of every group, all closed.
  if not a.canRemoveFromGroup: return
  let objs = a.selection
  let pieces = a.selPieces
  let name = a.groupName(a.openGroups[^1])
  a.moveSelectionToGroup(0, "Remove Objects from Group")
  a.openGroups.setLen 0
  a.refreshOpenSet()
  for o in objs: o.selected = o in a.objects
  a.selPieces = pieces
  a.say "Removed the selection from group " & name

proc addSelectionToGroup*(a: App, gid: int32) =
  ## TrenchBroom's Add Objects to Group (the group under the right click).
  if a.groupAt(gid) < 0: return
  a.moveSelectionToGroup(gid, "Add Objects to Group")
  a.clearSelection()
  a.selectGroup(gid)
  a.say "Added the selection to group " & a.groupName(gid)

proc mergeSelectedGroups*(a: App, into: int32) =
  ## TrenchBroom's Merge Groups: the other selected groups' contents go into one.
  let (units, _) = a.selectedUnits
  if units.len < 2 or into notin units: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  var changed = false
  for u in units:
    if u == into: continue
    let objs = a.groups[a.groupAt(u)].objs
    for o in objs: a.addToGroup(o, into)
    for g in a.groups.mitems:
      if g.parent == u: g.parent = into
    if a.geo != nil:
      for p in a.geo.pieces.mitems:
        if p.group == u:
          p.group = into
          changed = true
    a.groups.delete a.groupAt(u)
  if changed: a.geo.bump()
  a.push a.groupCmd("Merge Groups", geoBefore)
  a.selectGroup(into)

# --- saving -------------------------------------------------------------------------------------

proc loadGroups(a: App) =
  ## <project>/groups.json: the group table and which objects are in which
  ## group (by type and id; pieces keep their group in geometry.json).
  a.groups.setLen 0
  a.openGroups.setLen 0
  let path = a.proj.dir / GroupsFile
  if fileExists(path):
    try:
      let j = parseFile(path)
      for gj in j{"groups"}.getElems:
        a.groups.add Group(id: gj{"id"}.getInt.int32, name: gj{"name"}.getStr,
                           parent: gj{"parent"}.getInt.int32, link: gj{"link"}.getStr,
                           xform: if gj.hasKey("xform"): affineFrom(gj["xform"]) else: identityAffine())
      var byKey: Table[string, LevelObject]
      for o in a.objects: byKey[o.tag & ":" & $o.id] = o
      for e in j{"objects"}.getElems:
        let k = e.getElems
        if k.len != 3: continue
        let o = byKey.getOrDefault(k[0].getStr & ":" & $k[1].getInt)
        if o != nil:
          let i = a.groupAt(k[2].getInt.int32)
          if i >= 0: a.groups[i].objs.add o
    except CatchableError as e:
      a.say("Could not read groups: " & e.msg, true)
  a.groupsRecorded = a.groups
  a.refreshOpenSet()
  a.storeLinkSigs()

proc saveGroups(a: App, dir: string) =
  let path = dir / GroupsFile
  if a.groups.len == 0:
    if fileExists(path): removeFile(path)
    return
  var gs = newJArray()
  var objs = newJArray()
  var live: HashSet[LevelObject]
  for o in a.objects: live.incl o
  for g in a.groups:
    gs.add %*{"id": g.id, "name": g.name, "parent": g.parent, "link": g.link, "xform": affineJson(g.xform)}
    for o in g.objs:
      if o in live: objs.add %*[o.tag, o.id, g.id]
  try:
    writeFile(path, pretty(%*{"version": 1, "groups": gs, "objects": objs}))
  except CatchableError as e:
    a.say("Could not save groups: " & e.msg, true)
