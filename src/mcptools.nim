## What Catwalk's MCP tools do (mcp.nim is the transport). pollMcp runs at the
## start of a frame, on the main thread, so tools use the same procs the menus do.

import std/[algorithm, base64, json, math, os, sets, strformat, strutils, tables]
import vmath, bumpy, pixie
import appstate, camera, geometry, geomops, jobs, levelobjects, mcp, objtemplates, panels,
       project, screenshot, viewtools

const
  DefaultLimit = 200
  MaxLimit = 5000
  ReadOnlyTools = ["status", "log", "list_projects", "list_menu", "list_objects", "get_object",
                   "list_pieces", "get_faces", "list_textures", "screenshot"]

proc fail(msg: string) = raise newException(McpError, msg)

proc round3(f: float32): float = round(f.float * 1000) / 1000

proc arr(v: Vec3): JsonNode = %[round3(v.x), round3(v.y), round3(v.z)]

proc vecArg(j: JsonNode, name: string): Vec3 =
  let n = j{name}
  if n == nil or n.kind != JArray or n.len != 3: fail name & " must be [x, y, z]"
  vec3(n[0].getFloat.float32, n[1].getFloat.float32, n[2].getFloat.float32)

proc strArg(j: JsonNode, name: string): string =
  result = j{name}.getStr
  if result.len == 0: fail name & " is required"

proc needProject(a: App) =
  if a.proj == nil: fail "No project is open"

proc needGeometry(a: App) =
  a.needProject()
  if a.geo == nil: fail "This project has no editable geometry yet"

proc needFree(a: App) =
  ## Nothing may replace the open project while a job runs or changes are unsaved.
  if a.busy: fail "Busy: " & a.job.title
  if a.proj != nil and a.dirty: fail "The project has unsaved changes: save or undo them first"

proc findObject(a: App, tag: string, id: int): LevelObject =
  for o in a.objects:
    if o.tag == tag and o.id == id: return o
  fail &"No object {tag} {id}"

proc paged(j: JsonNode, total: int): (int, int) =
  ## The (first, last + 1) of a page of total.
  let first = clamp(j{"offset"}.getInt(0), 0, total)
  (first, min(total, first + clamp(j{"limit"}.getInt(DefaultLimit), 1, MaxLimit)))

proc logLines(a: App, n: int): JsonNode =
  result = newJArray()
  for l in a.log[max(0, a.log.len - n) .. ^1]:
    result.add %((if l.error: "error: " else: "") & l.text)

proc viewJson(a: App, i: int): JsonNode =
  let c = a.views[i].cam
  result = %*{"view": i, "kind": $c.kind, "width": a.views[i].viewBody.w.int,
              "height": a.views[i].viewBody.h.int}
  if c.kind == vk3D:
    result["pos"] = arr(c.pos)
    result["yaw"] = %round3(c.yaw.radToDeg)
    result["pitch"] = %round3(c.pitch.radToDeg)
  else:
    result["center"] = %[round3(c.center.x), round3(c.center.y)]
    result["zoom"] = %round3(c.zoom)

proc status(a: App): JsonNode =
  result = %*{"project": nil, "busy": a.busy, "tool": $a.tool, "grid": a.grid, "snap": a.snap,
              "layout": $a.layout, "maximized": a.maximized, "recent_log": a.logLines(5)}
  result["views"] = newJArray()
  for i in a.shownViews: result["views"].add a.viewJson(i)
  if a.busy:
    result["job"] = %*{"title": a.job.title, "step": a.job.stepLabel, "progress": a.job.progress}
  if a.proj == nil: return
  let p = a.proj
  result["project"] = %*{"dir": p.dir, "title": p.title, "env": p.envName, "level": p.levelNumber,
                         "sky": p.sky, "music": p.music, "scratch": p.scratch}
  result["dirty"] = %a.dirty
  var tags = initCountTable[string]()
  for o in a.objects: tags.inc o.tag
  var counts = newJObject()
  for t, n in tags: counts[t] = %n
  result["objects"] = counts
  var types = newJArray()
  for t in Templates.keys: types.add %t
  result["object_types"] = types
  if a.geo != nil:
    result["geometry"] = %*{"pieces": a.geo.pieces.len, "faces": a.geo.faces.len,
                            "points": a.geo.points.len}
  var sel = newJArray()
  for o in a.selection: sel.add %*{"tag": o.tag, "id": o.id}
  var pieces = newJArray()
  for pc in a.selPieces: pieces.add %pc
  var faces = newJArray()
  for f in a.selFaces: faces.add %f
  result["selection"] = %*{"objects": sel, "pieces": pieces, "faces": faces}
  var issues = newJArray()
  for i in a.issues[0 ..< min(a.issues.len, 20)]: issues.add %*{"severity": $i.severity, "text": i.text}
  result["issues"] = issues

proc listProjects(a: App): JsonNode =
  var names: seq[string]
  for kind, path in walkDir(a.cfg.projectsDir):
    if kind == pcDir and path.isProject: names.add path.lastPathPart
  names.sort
  %*{"projects_dir": a.cfg.projectsDir, "projects": names, "game_levels": a.cfg.gameLevels}

proc openProjectTool(a: App, j: JsonNode): JsonNode =
  a.needFree()
  var dir = j.strArg("path")
  if not dir.isAbsolute: dir = a.cfg.projectsDir / dir
  if not dir.isProject: fail "Not a Catwalk project: " & dir
  a.openProjectDir(dir)
  a.status

proc replaceProject(a: App) =
  a.needFree()
  if a.proj != nil: a.closeProject()

proc menuJson(items: seq[MenuItem], prefix: string, acc: JsonNode) =
  for it in items:
    if it.separator: continue
    let path = if prefix.len > 0: prefix & " > " & it.label else: it.label
    if it.sub.len > 0: menuJson(it.sub, path, acc)
    else: acc.add %*{"path": path, "shortcut": it.shortcut, "enabled": it.enabled, "checked": it.checked}

proc findMenu(items: seq[MenuItem], prefix, want: string, found: var seq[MenuItem]) =
  for it in items:
    if it.separator: continue
    let path = if prefix.len > 0: prefix & " > " & it.label else: it.label
    if it.sub.len > 0: findMenu(it.sub, path, want, found)
    elif path == want or it.label == want: found.add it

proc runMenuTool(a: App, j: JsonNode): JsonNode =
  let want = j.strArg("path")
  var found: seq[MenuItem]
  for (name, items) in a.menus: findMenu(items, name, want, found)
  if found.len == 0: fail "No menu item " & want
  if found.len > 1: fail want & " is ambiguous: use its full path from list_menu"
  if not found[0].enabled: fail want & " is disabled right now"
  found[0].action()
  %*{"ran": want}

proc objectJson(o: LevelObject): JsonNode =
  %*{"tag": o.tag, "id": o.id, "name": o.label, "pos": arr(o.pos), "rot": arr(o.rot),
     "hidden": o.hidden, "selected": o.selected}

proc listObjects(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let tag = j{"tag"}.getStr
  let onlySel = j{"selected"}.getBool
  var hits: seq[LevelObject]
  for o in a.objects:
    if (tag.len == 0 or o.tag == tag) and (not onlySel or o.selected): hits.add o
  let (first, last) = paged(j, hits.len)
  var objs = newJArray()
  for o in hits[first ..< last]: objs.add o.objectJson
  %*{"total": hits.len, "objects": objs}

proc fieldKey(f: ObjectField): string =
  if f.attr.len > 0: f.path & "@" & f.attr else: f.path

proc getObject(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let o = a.findObject(j.strArg("tag"), j{"id"}.getInt)
  result = o.objectJson
  var fields = newJObject()
  for f in o.fields: fields[f.fieldKey] = %f.value
  result["fields"] = fields

proc setObject(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let o = a.findObject(j.strArg("tag"), j{"id"}.getInt)
  var changes: seq[(ObjectField, string)]
  for key, value in j{"fields"}.getFields:
    var found = false
    for f in o.fields:
      if f.fieldKey == key:
        changes.add (f, value.getStr($value))
        found = true
    if not found: fail &"{o.tag} {o.id} has no field {key}"
  let pos = if j.hasKey("pos"): j.vecArg("pos") else: o.pos
  let rot = if j.hasKey("rot"): j.vecArg("rot") else: o.rot
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = @[o.snapshot]
  for (f, v) in changes: o.setField(f, v)
  o.syncFromNode()
  a.setPose(o, pos, rot)
  a.push editCmd("Edit object", @[o], before, geoBefore, a.geo)
  o.objectJson

proc createObject(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let tag = j.strArg("tag")
  if tag notin Templates: fail "Unknown object type " & tag
  let o = a.addObject(tag, j.vecArg("pos"))
  if j.hasKey("rot"): a.setPose(o, o.pos, j.vecArg("rot"))
  o.objectJson

proc faceBounds(g: Geometry, f: Face): (Vec3, Vec3) =
  var lo = g.points[f.verts[0]]
  var hi = lo
  for v in f.verts:
    lo = min(lo, g.points[v])
    hi = max(hi, g.points[v])
  (lo, hi)

proc boxFilter(j: JsonNode): (bool, Vec3, Vec3) =
  if j.hasKey("min") or j.hasKey("max"): (true, j.vecArg("min"), j.vecArg("max"))
  else: (false, vec3(0, 0, 0), vec3(0, 0, 0))

proc overlaps(lo, hi, boxLo, boxHi: Vec3): bool =
  lo.x <= boxHi.x and hi.x >= boxLo.x and lo.y <= boxHi.y and hi.y >= boxLo.y and
    lo.z <= boxHi.z and hi.z >= boxLo.z

proc listPieces(a: App, j: JsonNode): JsonNode =
  a.needGeometry()
  let (boxed, boxLo, boxHi) = boxFilter(j)
  let g = a.geo
  var rows: seq[JsonNode]
  for pc, faces in g.pieceFaces:
    if faces.len == 0: continue
    var (lo, hi) = g.faceBounds(g.faces[faces[0]])
    var textures = initHashSet[string]()
    for fi in faces:
      let (l, h) = g.faceBounds(g.faces[fi])
      lo = min(lo, l)
      hi = max(hi, h)
      textures.incl g.faces[fi].texture
    if boxed and not overlaps(lo, hi, boxLo, boxHi): continue
    var names: seq[string]
    for t in textures: names.add t
    rows.add %*{"piece": pc, "brush": g.pieces[pc].brush, "hidden": g.pieces[pc].hidden,
                "group": g.pieces[pc].group, "faces": faces.len, "min": arr(lo), "max": arr(hi),
                "textures": names.sorted}
  let (first, last) = paged(j, rows.len)
  %*{"total": rows.len, "pieces": rows[first ..< last]}

proc getFaces(a: App, j: JsonNode): JsonNode =
  a.needGeometry()
  let (boxed, boxLo, boxHi) = boxFilter(j)
  let g = a.geo
  let texture = j{"texture"}.getStr
  let flag = j{"flag"}.getStr
  var pieces = initHashSet[int32]()
  for p in j{"pieces"}.getElems: pieces.incl p.getInt.int32
  var hits: seq[int]
  for fi, f in g.faces:
    if f.verts.len == 0: continue
    if pieces.len > 0 and f.piece notin pieces: continue
    if texture.len > 0 and f.texture != texture: continue
    if flag.len > 0 and flag notin f.flags.flagsText.splitWhitespace: continue
    if boxed:
      let (lo, hi) = g.faceBounds(f)
      if not overlaps(lo, hi, boxLo, boxHi): continue
    hits.add fi
  let (first, last) = paged(j, hits.len)
  var faces = newJArray()
  for fi in hits[first ..< last]:
    let f = g.faces[fi]
    var corners = newJArray()
    for v in f.verts: corners.add arr(g.points[v])
    var row = %*{"face": fi, "piece": f.piece, "corners": corners, "normal": arr(g.normal(f)),
                 "texture": f.texture, "flags": f.flags.flagsText}
    if f.scriptId != 0: row["script_id"] = %f.scriptId
    if f.objectId != -1: row["object_id"] = %f.objectId
    if f.tinted: row["tint"] = %*[f.tint[0].int, f.tint[1].int, f.tint[2].int]
    faces.add row
  %*{"total": hits.len, "faces": faces}

proc listTextures(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let filter = j{"filter"}.getStr.toLowerAscii
  var names: seq[string]
  for t in a.textures:
    if filter.len == 0 or filter in t.toLowerAscii: names.add t
  %*{"current": a.currentTexture, "textures": names}

proc createBrush(a: App, j: JsonNode): JsonNode =
  a.needGeometry()
  var pts: seq[Vec3]
  if j.hasKey("points"):
    for p in j["points"].getElems:
      if p.kind != JArray or p.len != 3: fail "points must be [x, y, z] arrays"
      pts.add vec3(p[0].getFloat.float32, p[1].getFloat.float32, p[2].getFloat.float32)
  else:
    let (lo, hi) = (j.vecArg("min"), j.vecArg("max"))
    for x in [lo.x, hi.x]:
      for y in [lo.y, hi.y]:
        for z in [lo.z, hi.z]: pts.add vec3(x, y, z)
  var attr = a.newFaceAttr
  let texture = j{"texture"}.getStr
  if texture.len > 0:
    if texture notin a.textures: fail "No texture " & texture
    attr.texture = texture
  let before = a.geo.clone
  let pc = a.geo.addHull(pts, attr, a.densityFn)
  if pc < 0: fail "The points don't span a volume"
  a.push geoCmd("Create brush", before, a.geo)
  a.clearSelection()
  a.selPieces.incl pc
  %*{"piece": pc}

proc selectTool(a: App, j: JsonNode): JsonNode =
  a.needProject()
  if not j{"add"}.getBool: a.clearSelection()
  for o in j{"objects"}.getElems: a.findObject(o.strArg("tag"), o{"id"}.getInt).selected = true
  for p in j{"pieces"}.getElems:
    if a.geo == nil or p.getInt notin 0 .. a.geo.pieces.high: fail &"No piece {p}"
    a.selPieces.incl p.getInt.int32
  for f in j{"faces"}.getElems:
    if a.geo == nil or f.getInt notin 0 .. a.geo.faces.high: fail &"No face {f}"
    a.selFaces.incl f.getInt
  a.status{"selection"}

proc viewArg(a: App, j: JsonNode): int =
  ## The view asked for, else the first one showing.
  let views = a.shownViews
  if views.len == 0: fail "No viewport is showing"
  result = j{"view"}.getInt(views[0])
  if result notin views: fail &"View {result} isn't showing; status lists the views"

proc setCamera(a: App, j: JsonNode): JsonNode =
  a.needProject()
  let vi = a.viewArg(j)
  a.camAnim.on = false
  if j.hasKey("kind"):
    let want = j.strArg("kind")
    var found = false
    for k in ViewKind:
      if ($k).split(' ')[0] == want:
        a.setViewKind(vi, k)
        found = true
    if not found: fail "kind must be 3D, Top, Front or Side"
  template c: untyped = a.views[vi].cam
  if j.hasKey("pos"): c.pos = j.vecArg("pos")
  if j.hasKey("yaw"): c.yaw = j["yaw"].getFloat.float32.degToRad
  if j.hasKey("pitch"): c.pitch = j["pitch"].getFloat.float32.degToRad
  if j.hasKey("look_at"):
    let f = (j.vecArg("look_at") - c.pos).normalize
    c.pitch = arcsin(clamp(f.y, -1, 1))
    c.yaw = arctan2(-f.x, -f.z)
  if j.hasKey("center"):
    let n = j["center"]
    if n.kind != JArray or n.len != 2: fail "center must be [x, y]"
    c.center = vec2(n[0].getFloat.float32, n[1].getFloat.float32)
  if j.hasKey("zoom"):
    c.zoom = j["zoom"].getFloat.float32
    a.zoom2D = c.zoom
  a.viewJson(vi)

proc screenshotTool(a: App, id, j: JsonNode, reqId: int) =
  ## Answers after the frame is drawn.
  a.needProject()
  let views = if j.hasKey("view"): @[a.viewArg(j)] else: a.shownViews
  if views.len == 0: fail "No viewport is showing"
  let path = j{"path"}.getStr
  let maxSize = clamp(j{"max_size"}.getInt(1280), 64, 8192)
  a.afterFrame.add proc() =
    var content = newJArray()
    let paths = if path.len > 0: a.viewPaths(views, path) else: @[]
    if path.len > 0: createDir(path.parentDir)
    for i, vi in views:
      var img = a.readView(vi)
      if paths.len > 0: img.writeFile(paths[i])
      let longest = max(img.width, img.height)
      if longest > maxSize:
        img = img.resize(img.width * maxSize div longest, img.height * maxSize div longest)
      content.add a.viewJson(vi)
      content.add %*{"type": "image", "mimeType": "image/png", "data": encode(img.encodeImage(PngFormat))}
    var blocks = newJArray()
    for b in content:
      if b.hasKey("type"): blocks.add b
      else: blocks.add %*{"type": "text", "text": $b}
    answerMcp(reqId, $rpcResult(id, %*{"content": blocks, "isError": false}))

proc callTool(a: App, name: string, j: JsonNode): JsonNode =
  case name
  of "start_catwalk": %*{"running": true, "note": "Already running: use open_project"}
  of "status": a.status
  of "log": %*{"lines": a.logLines(clamp(j{"lines"}.getInt(50), 1, 2000))}
  of "list_projects": a.listProjects
  of "open_project": a.openProjectTool(j)
  of "import_level":
    a.replaceProject()
    a.importLevel(j{"level"}.getInt, j.strArg("name"))
    a.status
  of "new_level":
    a.replaceProject()
    a.newEmptyLevel(j.strArg("name"))
    a.status
  of "save":
    a.needProject()
    if a.proj.preview: fail "This is a preview of a game level: it can't be saved, only saved as a project (File > Save As...)"
    a.saveProject()
    a.status
  of "build":
    a.needProject()
    if a.busy: fail "Busy: " & a.job.title
    a.build(play = false)
    a.status
  of "undo":
    a.needProject()
    a.undo()
    a.status
  of "redo":
    a.needProject()
    a.redo()
    a.status
  of "list_menu":
    var acc = newJArray()
    for (name, items) in a.menus: menuJson(items, name, acc)
    acc
  of "run_menu": a.runMenuTool(j)
  of "list_objects": a.listObjects(j)
  of "get_object": a.getObject(j)
  of "create_object": a.createObject(j)
  of "set_object": a.setObject(j)
  of "list_pieces": a.listPieces(j)
  of "get_faces": a.getFaces(j)
  of "list_textures": a.listTextures(j)
  of "create_brush": a.createBrush(j)
  of "select": a.selectTool(j)
  of "move_selection":
    a.needProject()
    if not a.hasSelection: fail "Nothing is selected"
    a.moveSelection(j.vecArg("offset"))
    a.status{"selection"}
  of "set_camera": a.setCamera(j)
  else: raise newException(KeyError, "Unknown tool " & name)

proc handle(a: App, reqId: int, body: string, version: string) =
  var req: JsonNode
  try: req = parseJson(body)
  except CatchableError:
    answerMcp(reqId, $rpcError(newJNull(), -32700, "Parse error"))
    return
  let id = req{"id"}
  let (known, reply) = answerProtocol(req, version)
  if known:
    answerMcp(reqId, if reply != nil: $reply else: "\0")
    return
  if req{"method"}.getStr != "tools/call":
    answerMcp(reqId, $rpcError(id, -32601, "Method not found"))
    return
  let name = req{"params"}{"name"}.getStr
  let args = if req{"params"}{"arguments"} != nil: req{"params"}{"arguments"} else: newJObject()
  if name notin ReadOnlyTools: a.say "MCP: " & name
  try:
    if name == "screenshot": a.screenshotTool(id, args, reqId)
    else: answerMcp(reqId, $toolText(id, $a.callTool(name, args)))
  except KeyError as e: answerMcp(reqId, $rpcError(id, -32602, e.msg))
  except CatchableError as e:
    a.say(&"MCP: {name}: {e.msg}", true)
    answerMcp(reqId, $toolText(id, e.msg, true))

proc pollMcp*(a: App, version: string) =
  ## One request per frame. A drag in progress waits: tools push undo steps.
  if a.drag.kind != dkNone: return
  var id: int
  var body: string
  if takeMcpRequest(id, body): a.handle(id, body, version)
