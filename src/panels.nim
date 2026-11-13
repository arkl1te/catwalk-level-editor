## Everything around the map views, laid out like TrenchBroom: menu bar,
## toolbar, tool options strip, the inspector (Map / Entity / Face tabs with the
## entity and texture browsers), the Console / Issues panel, the status bar, the
## welcome screen and the settings dialog.

import std/[os, osproc, strutils, strformat, math, tables, sets, algorithm, times, sequtils, xmltree, xmlparser]
import silky, vmath, bumpy, pixie
import theme, ui, dialogs, icons, music, sky, menutree, colorpick, mcp, pictures, skyconvert, skyfit, tga
import crashlog, shellopen
import particleevents, levelobjects, project, jobs, camera, render, geometry, geomops, objtemplates, appstate, viewtools,
  presets, library, thumbs, fieldchoices, fieldtypes, classes, files, soundscene, particlesim, ambients

const
  ToolbarHeight* = 38'f32
  OptionsHeight* = 32'f32
  RowH = 22'f32

proc duplicateAmbient(a: App, source: string, pick: proc(v: string) = nil)
proc editAmbient(a: App, name: string)
proc newAmbientSound(a: App)

# --- small widgets ------------------------------------------------------------------------

proc sectionTitle(ui: Ui, r: Rect, title: string) =
  ui.rect(r, colPanelRaised)
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)
  ui.text(title, vec2(r.x + 8, r.y + (r.h - 18) / 2), colText, FontSmall)

proc foldArrow(ui: Ui, open: bool, center: Vec2) =
  ## The arrow of everything in the panels that folds.
  ui.icon(if open: "foldopen16" else: "foldshut16", center, colText)

proc foldTitle(ui: Ui, id: string, r: Rect, title: string, open: bool): bool =
  ## A sectionTitle that folds what's under it: true when clicked or activated.
  let focused = ui.tabStop(id, r)
  let hov = ui.hover(r)
  ui.sectionTitle(r, "")
  if hov: ui.rect(rect(r.x, r.y, r.w, r.h - 1), colHover)
  ui.foldArrow(open, vec2(r.x + 10, r.y + r.h / 2))
  ui.text(title, vec2(r.x + 22, r.y + (r.h - 18) / 2), colText, FontSmall)
  if hov and ui.pressed():
    ui.consumeClick()
    result = true
  if focused:
    ui.cursorRing(r)
    if ui.navActivate(id): result = true

proc tabs[T: enum](ui: Ui, id: string, r: Rect, value: var T) =
  ## One Tab stop; Left/Right switch tabs while it has keyboard focus.
  let focused = ui.tabStop(id, r)
  if ui.navKey(id, KeyLeft): value = (if value == T.low: T.high else: pred(value))
  if ui.navKey(id, KeyRight): value = (if value == T.high: T.low else: succ(value))
  var x = r.x + 6
  for t in T:
    let label = $t
    let w = ui.textSize(label).x + 20
    let tr = rect(x, r.y, w, r.h)
    let sel = value == t
    if ui.hover(tr) and ui.pressed():
      value = t
      ui.navId = id
      ui.consumeClick()
    ui.textIn(label, tr, if sel: colText else: colTextDim, h = CenterAlign)
    if sel: ui.rect(rect(tr.x + 4, tr.y + tr.h - 2, tr.w - 8, 2), colAccent)
    if sel and focused: ui.cursorRing(rect(tr.x + 1, tr.y + 2, tr.w - 2, tr.h - 4))
    x += w
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)

proc dropdown(a: App, id: string, r: Rect, label: string, items: seq[string], clickFocus = true): int =
  ## A button that opens a list; returns the picked index (or -1). With
  ## keyboard focus Space, Enter or Down opens it; then Up/Down pick a row,
  ## Space/Enter take it and Esc or Tab close it. clickFocus as textButton's.
  result = -1
  let ui = a.ui
  var open = a.openDropdown == id
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  ui.rect(r, if open: colPressed elif hov: colHover else: colPanel)
  ui.border(r, colBorder)
  ui.textIn(ui.ellipsize(label, r.w - 28), rect(r.x + 8, r.y, r.w - 28, r.h), colText)
  ui.icon("expand16", vec2(r.x + r.w - 12, r.y + r.h / 2), colTextDim)
  if focused: ui.focusRing(r)
  if hov and ui.pressed():
    a.openDropdown = if open: "" else: id
    a.dropdownHi = -1
    if clickFocus: ui.navId = id
    ui.consumeClick()
    return
  if focused and items.len > 0:
    if not open:
      if ui.navActivate(id) or ui.navKey(id, KeyDown):
        a.openDropdown = id
        a.dropdownHi = max(0, items.find(label))
        open = true
    else:
      if ui.navKey(id, KeyDown): a.dropdownHi = min(items.high, a.dropdownHi + 1)
      if ui.navKey(id, KeyUp): a.dropdownHi = max(0, a.dropdownHi - 1)
      if ui.navKey(id, KeyHome): a.dropdownHi = 0
      if ui.navKey(id, KeyEnd): a.dropdownHi = items.high
      if ui.navActivate(id) and a.dropdownHi in 0 .. items.high:
        result = a.dropdownHi
        a.openDropdown = ""
        return
      if ui.navKey(id, KeyEscape) or ui.window.buttonPressed[KeyTab]:
        a.openDropdown = ""
        return
  if not open: return
  # Long lists wrap into columns so the whole list stays on screen.
  let maxRows = max(1, int((ui.size.y - 24) / 24))
  let cols = (items.len + maxRows - 1) div maxRows
  let rows = (items.len + cols - 1) div cols
  var colW = max(r.w, 160)
  for it in items: colW = max(colW, ui.textSize(it).x + 36)
  let h = rows.float32 * 24 + 8
  var box = rect(r.x, r.y + r.h + 2, colW * cols.float32, h)
  if box.y + box.h > ui.size.y:
    box.y = if r.y - h - 2 >= 0: r.y - h - 2 else: max(0'f32, ui.size.y - h - 8)
  if box.x + box.w > ui.size.x: box.x = max(0'f32, ui.size.x - box.w - 8)
  ui.sk.pushLayer(PopupsLayer)
  ui.sk.pushRawClipRect(rect(0, 0, ui.size.x, ui.size.y))   # It may reach past its panel.
  ui.rect(rect(box.x + 3, box.y + 3, box.w, box.h), colShadow)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  for i, it in items:
    let ir = rect(box.x + 4 + (i div rows).float32 * colW, box.y + 4 + (i mod rows).float32 * 24,
                  colW - 8, 24)
    if i == a.dropdownHi: ui.rect(ir, colAccentDim)
    elif ui.mouse.inside(ir): ui.rect(ir, colHover)
    # View options marks its rows; the font has no glyph for these two.
    let (on, off) = (it.startsWith("● "), it.startsWith("◌ "))
    if on: ui.icon("check16", vec2(ir.x + 13, ir.y + ir.h / 2), colAccent)
    let shownText = if on or off: it.split(' ', 1)[1] else: it
    ui.textIn(shownText, rect(ir.x + (if on or off: 26 else: 8), ir.y, ir.w - 8, ir.h), colText)
    if ui.mouse.inside(ir) and ui.window.buttonPressed[MouseLeft]:
      result = i
      if clickFocus: ui.navId = id
  ui.sk.popClipRect()
  ui.sk.popLayer()
  if ui.window.buttonPressed[MouseLeft]:
    a.openDropdown = ""
    ui.consumeClick()
  elif (ui.window.buttonPressed[MouseRight] or ui.window.buttonPressed[MouseMiddle]) and
       not ui.mouse.inside(box):
    # Closes the list and goes on to what's under it, so a held button moves
    # the camera straight away.
    a.openDropdown = ""
    return
  ui.captured = true

proc matchesFilter(filter, name, value: string): bool =
  ## Every word of filter is in the field's name or value, ignoring case.
  let words = strutils.splitWhitespace(filter.toLowerAscii)
  if words.len == 0: return true
  let hay = (name & " " & value).toLowerAscii
  words.allIt(it in hay)

proc evalField(old, typed: string): string =
  ## Number fields accept arithmetic ("64*3", "-16+8"), like Majestic.
  try:
    discard parseFloat(old.strip)
  except ValueError:
    return typed
  let t = typed.strip
  if t.len == 0: return typed
  try:
    discard parseFloat(t)
    return t
  except ValueError: discard
  try:
    var r = formatFloat(evalMath(t), ffDecimal, 4)
    r.trimZeros()
    r
  except CatchableError: typed

# --- property rows ------------------------------------------------------------------

const KeyShare = 0.42'f32   ## Properties rows: the name column's share of the width.

proc propName(a: App, name: string, x, y, w: float32, tip = ""): Rect =
  ## A property row's name, in the left column; returns its value's rect.
  let ui = a.ui
  let kw = w * KeyShare
  let lr = rect(x, y, kw, 26)
  ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), lr, colTextDim, FontSmall)
  if tip.len > 0: ui.tip(lr, tip)
  rect(x + kw, y, w - kw, 26)

proc propText(a: App, name, value: string, x: float32, y: var float32, w: float32, tip = "") =
  ## A read-only property row.
  let ui = a.ui
  let vr = a.propName(name, x, y, w, tip)
  ui.textIn(ui.ellipsize(value, vr.w - 4, FontSmall), vr, colText, FontSmall)
  if tip.len > 0: ui.tip(vr, tip)
  y += 30

proc propGroup(a: App, title: string, x: float32, y: var float32, w: float32) =
  ## A heading over the rows that follow (as the Classes panel groups its fields).
  y += 4
  a.ui.textIn(a.ui.ellipsize(title, w, FontSmall), rect(x, y, w, 20), colAccent, FontSmall)
  y += 22

proc propNote(a: App, text: string, x: float32, y: var float32, w: float32) =
  ## Dim small print under the rows, wrapped.
  for line in a.ui.wrapText(text, w, 4, FontSmall):
    a.ui.text(line, vec2(x, y), colTextDim, FontSmall)
    y += 17
  y += 6

proc scrolledRows(a: App, id: string, area: Rect, scroll: var float32,
                  draw: proc(y: float32): float32) =
  ## A scrolled column of property rows: draw lays them out from y (the area's
  ## top, scrolled) and returns where they end.
  let ui = a.ui
  ui.scrollArea(id, area, scroll)
  ui.pushClip(area)
  ui.scrollIntoView(scroll)
  let contentH = draw(area.y + 8 - scroll) + scroll - area.y + 12
  # After the rows, so a wheel over a number field steps it instead.
  if ui.hover(area) and not ui.scrollConsumed: scroll += ui.wheelNotches * RowH * 3
  scroll = clamp(scroll, 0, max(0, contentH - area.h))
  ui.popClip()
  ui.scrollbar(id, area, scroll, contentH)


# --- menus -------------------------------------------------------------------------------

type MenuItem* = object
  label*, shortcut*: string
  enabled*, checked*, separator*: bool
  action*: proc()
  sub*: seq[MenuItem]               ## Non-empty: a submenu, opened by hovering the row.

proc item(label: string, shortcut = "", enabled = true, checked = false, action: proc()): MenuItem =
  MenuItem(label: label, shortcut: shortcut, enabled: enabled, checked: checked, action: action)

proc sep(): MenuItem = MenuItem(separator: true)

proc subMenu(label: string, items: seq[MenuItem]): MenuItem =
  MenuItem(label: label, enabled: true, sub: items)

proc leaves*(items: seq[MenuItem]): seq[MenuItem] =
  ## The items, with submenus replaced by their contents.
  for it in items:
    if it.sub.len > 0: result.add leaves(it.sub)
    else: result.add it

proc build*(a: App, play: bool)
proc openProjectDir*(a: App, dir: string)

proc copySelection(a: App) =
  a.clipboard.setLen 0
  a.clipboardGeo = nil
  for o in a.selection:
    a.clipboard.add o.tag
    a.clipboard.add o.snapshot
  if a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0):
    let g = Geometry(points: a.geo.points, pieces: a.geo.pieces)
    for fi in a.selectedFaceSet.toSeq.sorted: g.faces.add a.geo.faces[fi]
    g.compact()
    a.clipboardGeo = g
  # A face selection also copies the look of the face the Face tab shows.
  var src = -1
  if a.geo != nil and a.selFaces.len > 0:
    src = if a.lastFace in a.selFaces and a.lastFace in 0 .. a.geo.faces.high: a.lastFace
          else: a.selFaces.toSeq.min
    if src notin 0 .. a.geo.faces.high: src = -1
  if src >= 0:
    let f = a.geo.faces[src]
    a.faceClip = attrOf(f)
    a.faceClip.frame = a.geo.texFrame(src, a.density(f.texture))
    a.hasFaceClip = true
  a.say &"Copied {a.clipboard.len div 2} object(s)" &
    (if a.clipboardGeo != nil: &" and {a.clipboardGeo.faces.len} face(s)" else: "") &
    (if src >= 0: " and the surface properties of " & a.faceClip.texture else: "")

proc pasteFaceProps(a: App) =
  ## Ctrl+Shift+V: the copied face's texture, mapping (shift, scale,
  ## rotation), flags, script id and tint onto the selected faces. Shade stays:
  ## it is each face's own baked light.
  let faces = a.selectedFaceSet
  if not a.hasFaceClip or a.geo == nil or faces.len == 0: return
  let t = a.faceClip
  let before = a.geo.clone
  for fi in faces:
    a.geo.faces[fi].texture = t.texture
    a.geo.faces[fi].flags = t.flags
    a.geo.faces[fi].scriptId = t.scriptId
    a.geo.faces[fi].untint = t.untint
    let d = a.density(t.texture)
    var cur = a.geo.texFrame(fi, d)
    if not cur.ok:
      # UVs squashed to a point or line: start from World align.
      a.geo.projectUVs(fi, d)
      cur = a.geo.texFrame(fi, d)
    if t.frame.ok and cur.ok: discard a.geo.setTexFrame(fi, cur, t.frame)
    elif not t.frame.ok: a.geo.projectUVs(fi, d)
  a.adoptTexture(t.texture)
  a.geo.bump()
  a.push geoCmd("Paste surface properties", before, a.geo)
  a.say &"Pasted surface properties onto {faces.len} face(s)"

proc clipboardBounds(a: App): (bool, Vec3, Vec3) =
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  var i = 0
  while i + 1 < a.clipboard.len:
    # Not in any file, so read the snapshot directly (restore needs o.file).
    let o = LevelObject(tag: a.clipboard[i], node: parseXml(a.clipboard[i + 1]))
    o.syncFromNode()
    lo = min(lo, o.pos)
    hi = max(hi, o.pos)
    i += 2
  if a.clipboardGeo != nil:
    for f in a.clipboardGeo.faces:
      for v in f.verts:
        lo = min(lo, a.clipboardGeo.points[v])
        hi = max(hi, a.clipboardGeo.points[v])
  (lo.x <= hi.x, lo, hi)

proc pasteOffset(a: App): Vec3 =
  ## TrenchBroom's Paste: centered under the mouse, on the surface there in
  ## 3D; in 2D at the far side of the latest selection.
  let (ok, lo, hi) = a.clipboardBounds
  if not ok: return vec3(a.grid, 0, a.grid)
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  if vi < 0 or vi > 3 or a.views[vi].rect.w < 2: return vec3(a.grid, 0, a.grid)
  let c = (lo + hi) / 2
  let m = a.ui.mouse
  let cam = a.views[vi].cam
  if cam.kind == vk3D:
    let (fi, p) = a.faceUnder(vi, m)
    let r = a.viewRay(vi, m)
    let target = if fi >= 0: p else: r.origin + r.dir * 256
    result = a.snapV(target - vec3(c.x, lo.y, c.z))
  else:
    let ax = cam.kind.axes
    let k = ax.toViewer
    let depth = if a.lastSel.ok: a.lastSel.hi else: a.focus2D
    let r = a.viewRay(vi, m)
    var target = r.origin - k * ((r.origin - depth).dot(k))
    result = a.snapV(target - c)

proc paste(a: App, inPlace: bool) =
  if a.proj == nil: return
  let offset = if inPlace: vec3(0, 0, 0) else: a.pasteOffset
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  var c = Cmd(label: "Paste", kind: ckAdd, geoBefore: geoBefore)
  a.clearSelection()
  var i = 0
  var id = a.objects.nextId
  while i + 1 < a.clipboard.len:
    let tag = a.clipboard[i]
    let xml = a.clipboard[i + 1]
    i += 2
    let o = a.addObject(tag, vec3(0, 0, 0))
    discard a.undoStack.pop   # folded into this paste's command
    o.restore(xml)
    o.node.setAttr("Id", $id)
    inc id
    o.syncFromNode()
    o.pos = o.pos + offset
    o.syncToNode()
    o.selected = true
    c.objs.add o
    c.indices.add o.file.list.findChild(o.node)
  if a.clipboardGeo != nil and a.geo != nil:
    let g = a.clipboardGeo
    let base = a.geo.points.len.int32
    let pbase = a.geo.pieces.len.int32
    for p in g.points: a.geo.points.add p + offset
    for p in g.pieces:
      var np = p
      np.group = 0   # pasted outside groups (into the open one, if any: see adoptNew)
      a.geo.pieces.add np
    for f in g.faces:
      var nf = f
      for v in nf.verts.mitems: v += base
      nf.piece += pbase
      nf.objectId = -1
      a.geo.faces.add nf
      a.selPieces.incl nf.piece
    a.geo.bump()
  if geoBefore != nil: c.geoAfter = a.geo.clone
  if c.objs.len > 0 or a.clipboardGeo != nil:
    a.push c
    a.say "Pasted"

proc selectAll(a: App) =
  ## Everything, or with a group open everything in it.
  for o in a.objects: o.selected = a.pickable(o)
  if a.geometryEditable:
    for f in a.geo.faces:
      if f.objectId == -1 and not a.geo.pieces[f.piece].hidden and not a.pieceLocked(f.piece):
        a.selPieces.incl f.piece

proc invertSelection(a: App) =
  ## Closed groups count as one thing: a group with any member selected is
  ## deselected as a whole, the others selected whole.
  let wasUnits = toHashSet(a.selectedUnits[0])
  for o in a.objects:
    if a.pickable(o) and a.unitOf(a.objGroup(o)) == 0: o.selected = not o.selected
  if a.geometryEditable:
    var all: HashSet[int32]
    for f in a.geo.faces:
      if f.objectId == -1 and not a.pieceLocked(f.piece) and a.unitOf(a.pieceGroup(f.piece)) == 0:
        all.incl f.piece
    var grouped: HashSet[int32]
    for pc in a.selPieces:
      if a.unitOf(a.pieceGroup(pc)) != 0: grouped.incl pc
    a.selPieces = all.difference(a.selPieces) + grouped
  for g in a.groups:
    if a.unitOf(g.id) == g.id and not a.groupLocked(g.parent):
      a.selectGroup(g.id, g.id notin wasUnits)

proc askName*(a: App, title, initial: string, done: proc(name: string)) =
  ## A one-line name prompt (TrenchBroom's queryGroupName); done runs on OK.
  a.namePromptTitle = title
  a.namePromptText = initial
  a.namePrompt = done
  a.ui.navId = ""
  a.ui.focusId = "nameprompt.text"
  a.ui.focusFresh = true

proc groupItems(a: App): seq[MenuItem] =
  ## TrenchBroom's Groups menu.
  let (units, _) = a.selectedUnits
  @[item("Group selected objects...", "Ctrl+G", a.canGroup, action = proc() =
      a.askName("Group name", "Unnamed", proc(name: string) = a.groupSelection(name))),
    item("Ungroup selected objects", "Ctrl+Shift+G", units.len > 0, action = proc() = a.ungroupSelection()),
    item("Rename selected groups...", "Ctrl+Alt+G", a.onlyGroupsSelected, action = proc() =
      let first = a.selectedUnits[0]
      a.askName("Rename group", a.groupName(first[0]), proc(name: string) = a.renameSelectedGroups(name))),
    sep(),
    item("Create linked duplicate", "Ctrl+Shift+D", a.canLinkedDuplicate, action = proc() =
      a.duplicateSelection(vec3(0, 0, 0), linked = true, flash = true)),
    item("Select linked groups", "", a.canSelectLinkedGroups, action = proc() = a.selectLinkedGroups()),
    item("Separate selected groups", "", a.canSeparateLinkedGroups, action = proc() = a.separateLinkedGroups()),
    sep(),
    item("Remove objects from group", "", a.canRemoveFromGroup, action = proc() = a.removeSelectionFromGroup()),
    item("Close group", "Esc", a.openGroups.len > 0, action = proc() = a.closeGroup())]

proc hideSelection(a: App) =
  let before = a.visState
  for o in a.selection:
    o.hidden = true
    o.selected = false
  if a.geo != nil:
    for pc in a.selPieces: a.geo.pieces[pc].hidden = true
    a.selPieces.clear()
    a.geo.bump()
  a.pushVisibility("Hide Objects", before)

proc isolateSelection(a: App) =
  let before = a.visState
  for o in a.objects: o.hidden = not o.selected
  if a.geo != nil:
    for pc in 0 ..< a.geo.pieces.len: a.geo.pieces[pc].hidden = pc.int32 notin a.selPieces
    a.geo.bump()
  a.pushVisibility("Isolate Objects", before)

proc showAll(a: App) =
  let before = a.visState
  for o in a.objects: o.hidden = false
  a.layerHidden.clear()
  if a.geo != nil:
    for p in a.geo.pieces.mitems: p.hidden = false
    a.geo.bump()
  a.pushVisibility("Reset Visibility", before)

proc openSettings(a: App) =
  a.ui.navId = ""  # Keys go to the dialog, not a widget behind it.
  a.settingsEdit = a.cfg
  a.settingsFly = a.flySpeed
  a.settingsOpen = true

proc setMcpPortIssue(a: App, text: string) =
  a.mcpPortIssue = text
  a.issues.keepItIf(not it.mcpPort)
  if text.len > 0:
    a.issues.insert(Issue(severity: sevError, text: text, time: epochTime(), face: -1, mcpPort: true), 0)
    a.showPanel(pkIssues)

proc applyMcp*(a: App) =
  ## Turns the server on or off to match the settings.
  let want = a.cfg.mcpEnabled or a.mcpForced
  if mcpRunning() and (not want or mcpServingPort() != a.cfg.mcpPort):
    stopMcp()
    a.say "MCP server stopped"
  a.setMcpPortIssue("")
  if want and not mcpRunning():
    try:
      startMcp(a.cfg.mcpPort)
      a.say &"MCP server on http://127.0.0.1:{a.cfg.mcpPort}/mcp"
    except OSError as e:
      a.say(&"Could not start the MCP server on port {a.cfg.mcpPort}: {e.msg.splitLines[0]}", true)
      if e.portBlocked:
        a.setMcpPortIssue(&"MCP server: port {a.cfg.mcpPort} is taken or blocked. Click to change it in Settings.")

proc openSkyConvert(a: App) =
  ## Run > Add-Ons > Skybox Converter. Its last picture and choices stay.
  a.skyConvertOpen = true
  a.skyConvertError = ""
  if a.skyConvertFile.len == 0: a.skyConvertUse = true
  a.ui.navId = ""
  a.ui.focusId = ""

proc mcpItems(a: App): seq[MenuItem] =
  ## Run > MCP server: for this run only; the setting stays as it is.
  let on = mcpRunning()
  @[item("Status: " & (if on: "Active" else: "Off"), "", false, action = nil),
    sep(),
    item("Start", "", not on, action = proc() =
      a.mcpForced = true
      a.applyMcp()
      a.mcpForced = mcpRunning()),
    item("End", "", on, action = proc() =
      a.mcpForced = false
      stopMcp()
      a.setMcpPortIssue("")
      a.say "MCP server stopped")]

proc panelItem(a: App, kind: PanelKind): MenuItem =
  # A proc per item: a closure made in panelItems' loop would share its variable.
  let shortcut = case kind
    of pkConsole: "Ctrl+4"
    of pkProperties: "Ctrl+5"
    of pkScripts: "Ctrl+6"
    else: ""
  item($kind, shortcut, true, a.dock.leafOf(kind) != nil, action = proc() =
    if a.dock.leafOf(kind) != nil: a.hidePanel(kind) else: a.showPanel(kind))

proc panelItems(a: App): seq[MenuItem] =
  ## View > Panels: each panel on or off (the Viewport always stays), and the
  ## default layout back.
  for k in PanelKind:
    if k != pkViewport: result.add a.panelItem(k)
  result.add sep()
  result.add item("Reset panel layout", "", true, action = proc() = a.dock = defaultDock())

proc recentItem(a: App, dir, label: string): MenuItem =
  item(label, "", not a.busy, action = proc() = a.whenSaved(proc() = a.openProjectDir(dir)))

var recentChecked: tuple[at: float, list, dirs: seq[string], limit: int]

proc recentItems(a: App): seq[MenuItem] =
  ## File > Open Recent: the last opened projects that still exist, then Clear
  ## Recent (TrenchBroom's recent documents menu). Folder names that repeat
  ## show the whole path.
  # The menus are built every frame: which still exist is looked up on disk
  # every two seconds, or when the list changes.
  let now = epochTime()
  if now - recentChecked.at > 2 or recentChecked.list != a.cfg.recentProjects or
     recentChecked.limit != a.cfg.recentLimit:
    recentChecked.dirs.setLen 0
    for d in a.cfg.recentProjects:
      if recentChecked.dirs.len >= a.cfg.recentLimit: break
      if d.isProject: recentChecked.dirs.add d
    recentChecked.at = now
    recentChecked.list = a.cfg.recentProjects
    recentChecked.limit = a.cfg.recentLimit
  let dirs = recentChecked.dirs
  for d in dirs:
    let name = d.lastPathPart
    var dup = false
    for o in dirs:
      if o != d and o.lastPathPart == name: dup = true
    result.add a.recentItem(d, if dup: d else: name)
  if result.len > 0: result.add sep()
  result.add item("Clear Recent", "", a.cfg.recentProjects.len > 0, action = proc() =
    a.cfg.recentProjects.setLen 0
    try: a.cfg.save()
    except CatchableError: discard)

proc importMenuItems(a: App, hasProj: bool): seq[MenuItem] =
  ## File > Import: recordings from sound files, and a new ambient sound from scratch.
  @[item("Sounds...", "", hasProj and not a.busy and a.dialog == nil, action = proc() =
      a.dialog = startDialog(dkOpenFiles, "sounds", "Import sounds", getHomeDir(),
                             @SoundFormats, "Sounds")),
    item("New ambient sound...", "", hasProj and not a.busy, action = proc() = a.newAmbientSound())]

proc ambientMenuItems(a: App, hasProj: bool): seq[MenuItem] =
  ## File > Ambient sounds: each of the project's own ambients to edit (none: no submenu).
  if not hasProj: return
  let on = not a.busy
  proc editItem(n: string): MenuItem =
    item("Edit " & n & "...", "", on, action = proc() = a.editAmbient(n))
  for n in ambientNames(a.proj.ambientsPath): result.add editItem(n)

proc menus*(a: App): seq[(string, seq[MenuItem])] =
  let hasProj = a.proj != nil
  let hasSel = a.hasSelection
  let geo = a.geo != nil
  let brushes = a.selPieces.len > 0 and not a.closedGroupSelected
  result.add ("File", @[
    item("New project...", "Ctrl+N", not a.busy, action = proc() =
      a.whenSaved(proc() =
        a.closeProject()
        a.newName = "")),
    item("Open project...", "Ctrl+O", not a.busy, action = proc() =
      a.dialog = startDialog(dkOpenDir, "project", "Open Catwalk project", a.cfg.projectsDir, @[])),
    subMenu("Open Recent", a.recentItems()),
    item("Close project", "Ctrl+W", hasProj and not a.busy, action = proc() =
      a.whenSaved(proc() =
        a.closeProject())),
    sep(),
    item("Save", "Ctrl+S", hasProj, action = proc() = a.saveProject()),
    item("Save As...", "Ctrl+Shift+S", hasProj and not a.busy, action = proc() =
      a.dialog = startDialog(dkSaveFile, "saveas", "Save project as", a.nextFreeProjectDir())),
    item("Save a copy...", "Ctrl+Alt+S", hasProj and not a.busy, action = proc() =
      a.dialog = startDialog(dkSaveFile, "savecopy", "Save a copy of the project",
                             a.nextFreeProjectDir())),
    item("Save screenshot...", "Alt+I", hasProj and a.viewsArea.w >= 2, action = proc() =
      let dir = a.proj.dir / "screenshots"
      createDir(dir)
      a.dialog = startDialog(dkSaveFile, "screenshot", "Save screenshot of the viewports",
                             dir / a.proj.folder & now().format("'_'yyyy-MM-dd'_'HH-mm-ss") & ".png",
                             @["png"], "PNG images")),
    sep(),
    subMenu("Import", a.importMenuItems(hasProj))])
  let ambients = a.ambientMenuItems(hasProj)
  if ambients.len > 0: result[^1][1].add subMenu("Ambient sounds", ambients)
  result[^1][1].add sep()
  result[^1][1].add item("Quit", "Ctrl+Q", true, action = proc() = a.window.closeRequested = true)
  result.add ("Edit", @[
    item("Undo", "Ctrl+Z", a.undoStack.len > 0, action = proc() = a.undo()),
    item("Redo", "Ctrl+Shift+Z", a.redoStack.len > 0, action = proc() = a.redo()),
    sep(),
    item("Cut", "Ctrl+X", hasSel, action = proc() =
      a.copySelection()
      a.deleteSelection()),
    item("Copy", "Ctrl+C", hasSel, action = proc() = a.copySelection()),
    item("Paste", "Ctrl+V", a.clipboard.len > 0 or a.clipboardGeo != nil, action = proc() = a.paste(false)),
    item("Paste at original position", "Ctrl+Alt+V", a.clipboard.len > 0 or a.clipboardGeo != nil,
         action = proc() = a.paste(true)),
    item("Paste surface properties", "Ctrl+Shift+V", a.hasFaceClip and a.geo != nil and (a.selFaces.len > 0 or a.selPieces.len > 0),
         action = proc() = a.pasteFaceProps()),
    item("Duplicate", "Ctrl+D", hasSel, action = proc() = a.duplicateSelection(vec3(0, 0, 0), flash = true)),
    item("Separate", "", a.selPieces.len > 0 or a.selFaces.len > 0, action = proc() = a.separateSelection()),
    item("Delete", "Del", hasSel, action = proc() = a.deleteSelection()),
    item("Move objects...", "Ctrl+Alt+M", hasSel, action = proc() =
      a.tool = toolSelect
      a.ui.focusId = "opt.moveby"
      a.ui.focusFresh = true),
    sep(),
    item("Flip horizontally", "Ctrl+F", hasSel, action = proc() =
      a.flipSelection(a.flipAxis(vertical = false))),
    item("Flip vertically", "Ctrl+Alt+F", hasSel, action = proc() =
      a.flipSelection(a.flipAxis(vertical = true))),
    sep(),
    item("CSG: Convex merge", "Ctrl+J", geo and (brushes or a.selFaces.len > 1), action = proc() = a.csg("merge")),
    item("CSG: Subtract", "Ctrl+K", geo and brushes, action = proc() = a.csg("subtract")),
    item("CSG: Hollow", "Ctrl+Shift+K", geo and brushes, action = proc() = a.csg("hollow")),
    item("CSG: Intersect", "Ctrl+L", geo and brushes and a.selPieces.len > 1, action = proc() = a.csg("intersect")),
    item("Join ends", "Ctrl+Shift+J", geo and a.selPieces.len + a.selection.len >= 2,
         action = proc() = a.joinSelection()),
    sep(),
    item("Reset texture alignment", "Shift+R", a.selFaces.len > 0 or a.selPieces.len > 0,
         action = proc() = a.resetTextures()),
    item("UV lock", "U", true, a.uvLock, action = proc() = a.uvLock = not a.uvLock)])
  result.add ("Selection", @[
    item("Select all", "Ctrl+A", hasProj, action = proc() = a.selectAll()),
    item("Select none", "Ctrl+Shift+A", hasSel, action = proc() = a.clearSelection()),
    item("Invert selection", "Ctrl+Alt+A", hasProj, action = proc() = a.invertSelection()),
    sep(),
    item("Select siblings", "Ctrl+B", hasSel, action = proc() = a.selectSiblings()),
    item("Select touching", "Ctrl+T", geo and a.selPieces.len > 0, action = proc() = a.selectByBrushes(false)),
    item("Select inside", "Ctrl+E", geo and a.selPieces.len > 0, action = proc() = a.selectByBrushes(true))])
  result.add ("Groups", a.groupItems)
  result.add ("Tools", @[
    item("No tool (select, move, draw)", "Shift+Esc", true, a.tool == toolSelect, action = proc() =
      a.setTool(toolSelect)),
    item("Brush tool", "B", geo, a.tool == toolBrush, action = proc() = a.setTool(toolBrush)),
    sep(),
    item("Vertex tool", "V", geo, a.tool == toolVertex, action = proc() = a.setTool(toolVertex)),
    item("Edge tool", "E", geo, a.tool == toolEdge, action = proc() = a.setTool(toolEdge)),
    item("Face tool", "F", geo, a.tool == toolFace, action = proc() = a.setTool(toolFace)),
    sep(),
    item("Clip tool", "C", geo, a.tool == toolClip, action = proc() = a.setTool(toolClip)),
    item("Rotate tool", "R", true, a.tool == toolRotate, action = proc() = a.setTool(toolRotate)),
    item("Scale tool", "T", true, a.tool == toolScale, action = proc() = a.setTool(toolScale))])
  proc gridSize(i: int): MenuItem =
    item(&"Grid {GridSizes[i]:g}", (if i in GridHalfIndex .. GridKeyBase + 7: $(i - GridHalfIndex + 1) else: ""), true, a.gridIndex == i, action = proc() = a.gridIndex = i)
  var gridSizes: seq[MenuItem]
  for i in 0 .. GridSizes.high: gridSizes.add gridSize(i)
  proc renderMode(m: RenderMode): MenuItem =
    item($m, "", true, a.opts.mode == m, action = proc() = a.opts.mode = m)
  var renderModes: seq[MenuItem]
  for m in RenderMode: renderModes.add renderMode(m)
  result.add ("View", @[
    subMenu("Panes", @[
      item("One pane", "", true, a.layout == pl1, action = proc() = a.layout = pl1),
      item("Two panes", "", true, a.layout == pl2, action = proc() = a.layout = pl2),
      item("Three panes", "", true, a.layout == pl3, action = proc() = a.layout = pl3),
      item("Four panes", "", true, a.layout == pl4, action = proc() = a.layout = pl4),
      sep(),
      item("Maximize current view", "Ctrl+Space", true, a.maximized >= 0, action = proc() =
        a.maximized = if a.maximized >= 0: -1 else: max(a.activeView, 0))]),
    subMenu("Grid", @[
      item("Show grid", "0", true, a.showGrid, action = proc() = a.showGrid = not a.showGrid),
      item("Snap to grid", "Alt+0", true, a.snap, action = proc() = a.snap = not a.snap),
      sep(),
      item("Larger grid", "+", a.gridIndex < GridSizes.high, action = proc() = inc a.gridIndex),
      item("Smaller grid", "-", a.gridIndex > 0, action = proc() = dec a.gridIndex),
      sep()] & gridSizes),
    subMenu("Render", renderModes & @[
      sep(),
      item(if not a.realtime and a.realtimeWaits.len > 0: "Realtime preview (loading)" else: "Realtime preview",
           "", hasProj and (a.realtime or a.realtimeWaits.len == 0), a.realtime,
           action = proc() = a.switchRealtime()),
      item("Gizmos", "", hasProj, a.showGizmos, action = proc() = a.showGizmos = not a.showGizmos),
      sep(),
      item("Editor-only", "", true, a.showEditorOnly, action = proc() = a.switchEditorOnly()),
      item("Marker faces", "", true, a.opts.markers, action = proc() =
        a.opts.markers = not a.opts.markers
        if a.geo != nil: a.geo.bump()),
      item("AI rooms", "", true, a.opts.rooms, action = proc() = a.opts.rooms = not a.opts.rooms),
      item("Entity models", "", true, a.opts.models, action = proc() = a.opts.models = not a.opts.models),
      item("Sky", "", true, a.opts.sky, action = proc() = a.opts.sky = not a.opts.sky),
      item("Object names in 2D", "", true, a.showObjectNames, action = proc() =
        a.showObjectNames = not a.showObjectNames)]),
    subMenu("Camera", @[
      item("Focus camera on selection", ".", hasProj, action = proc() = a.frameSelection()),
      item("Reset cameras", "Shift+.", hasProj, action = proc() = a.resetCameras()),
      item("Reset camera zoom", "Ctrl+Alt+Z", hasProj, action = proc() =
        for i in 0 .. 3:
          if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = a.defaultFov)]),
    sep(),
    item("Isolate selection", "Ctrl+I", hasSel, action = proc() = a.isolateSelection()),
    item("Hide selection", "Ctrl+Alt+I", hasSel, action = proc() = a.hideSelection()),
    item("Show all", "Ctrl+Shift+I", hasProj, action = proc() = a.showAll()),
    sep(),
    item("Map", "Ctrl+1", true, a.panelShown(pkMap), action = proc() = a.showPanel(pkMap)),
    item("Properties", "Ctrl+2", true, a.panelShown(pkProperties), action = proc() = a.showPanel(pkProperties)),
    item("Classes", "Ctrl+3", true, a.panelShown(pkClasses), action = proc() = a.showPanel(pkClasses)),
    subMenu("Panels", a.panelItems),
    sep(),
    item("Settings...", "", true, action = proc() = a.openSettings())])
  result.add ("Run", @[
    item("Play", "F5", hasProj and not a.busy, action = proc() = a.build(play = true)),
    item("Build", "F7", hasProj and not a.busy, action = proc() = a.build(play = false)),
    sep(),
    item("Open project folder", "", hasProj, action = proc() =
      openPath(a.proj.dir)),
    item("Open build log", "", hasProj, action = proc() =
      openPath(a.proj.logPath)),
    sep(),
    subMenu("Add-Ons", @[item("Skybox Converter...", "", hasProj and not a.busy, action = proc() =
      a.openSkyConvert())]),
    subMenu("MCP server", a.mcpItems)])
  result.add ("Help", @[
    item("Catwalk README", "F1", true, action = proc() =
      let readme = getAppDir() / "README.md"
      openPath(readme)),
    item("Open logs folder", "", true, action = proc() =
      openPath(logDir()))])

proc runMenu*(a: App, label: string): bool =
  ## Runs a menu item by label (used by keyboard shortcuts).
  for (_, items) in a.menus:
    for it in items.leaves:
      if it.label == label and it.enabled and it.action != nil:
        it.action()
        return true

proc addItems(parent: MenuNode, items: seq[MenuItem]) =
  for it in items:
    if it.separator: parent.sep()
    elif it.sub.len > 0: parent.sub(it.label, it.enabled).addItems(it.sub)
    elif it.checked: parent.check(it.label, it.shortcut, true, it.enabled, it.action)
    else: parent.item(it.label, it.shortcut, it.enabled, it.action)

proc drawMenuBar*(a: App) =
  ## The menu bar strip. Its menus (and the context menu) open in popup
  ## windows of their own, so they can extend past the main window; they are
  ## laid out by updateMenus and drawn by renderPopups after the swap.
  let ui = a.ui
  a.menuTree = newMenuRoot()
  for (title, items) in a.menus: a.menuTree.sub(title).addItems(items)
  # A modal dialog keeps the bar from opening menus.
  let wasCaptured = ui.captured
  if a.modalOpen: ui.captured = true
  a.menuSys.drawBar(ui, a.menuTree, rect(0, 0, ui.size.x, MenuBarHeight))
  ui.captured = wasCaptured or a.menuSys.isOpen
  if a.proj != nil:
    let t = a.proj.title & (if a.dirty: "  •" else: "")
    let tw = ui.textSize(t, FontSmall).x
    ui.text(t, vec2(ui.size.x - tw - 12, 6), colTextDim, FontSmall)

# --- map view context menu ---------------------------------------------------------------

proc fileContextTree(a: App, rel: string): MenuNode

proc realtimeTree(a: App): MenuNode =
  ## Right click on a view's Realtime preview button: what it plays.
  result = newMenuRoot()
  proc partItem(menu: MenuNode, p: PreviewPart) =
    menu.check($p, checked = p in a.previewParts, action = proc() = a.togglePreviewPart(p))
  for p in PreviewPart: partItem(result, p)
  result.sep()
  result.item("Enable all", enabled = a.previewParts != {PreviewPart.low .. PreviewPart.high},
              action = proc() = a.previewParts = {PreviewPart.low .. PreviewPart.high})
  result.sep()
  # The preview's own volumes: the built level keeps its own. Sound objects
  # volume is also what the sound fields' play buttons play at.
  result.slider("Sound objects volume", a.previewSoundVolume,
                onChange = proc(v: float) = a.previewSoundVolume = v)
  result.slider("Music volume", a.previewMusicVolume,
                onChange = proc(v: float) = a.previewMusicVolume = v)

proc gizmosTree(a: App): MenuNode =
  ## Right click on a view's Gizmos button: which object types show theirs.
  result = newMenuRoot()
  proc kindItem(menu: MenuNode, tag: string) =
    menu.check(typeName(tag), checked = tag notin a.gizmoHidden, action = proc() = a.toggleGizmoKind(tag))
  for i, c in Categories:
    if i > 0: result.sep()
    for t in c.tags: kindItem(result, t)
  result.sep()
  result.item("Enable all", enabled = a.gizmoHidden.len > 0, action = proc() = a.gizmoHidden.clear())

proc editorOnlyTree(a: App): MenuNode =
  ## Right click on a view's Editor-only button: which of its things show.
  result = newMenuRoot()
  proc partItem(menu: MenuNode, p: EditorOnlyPart) =
    menu.check($p, checked = p in a.editorOnlyParts, action = proc() = a.toggleEditorOnlyPart(p))
  for p in EditorOnlyPart: partItem(result, p)
  result.sep()
  result.item("Enable all", enabled = a.editorOnlyParts != {EditorOnlyPart.low .. EditorOnlyPart.high},
              action = proc() =
                a.editorOnlyParts = {EditorOnlyPart.low .. EditorOnlyPart.high}
                if a.geo != nil: a.geo.bump())
  result.sep()
  # How close to the 3D camera an object has to be for its Notes to show.
  # The slider's 0..1 maps onto MinNotesRange..MaxNotesRange, in its 5 % steps.
  let span = MaxNotesRange - MinNotesRange
  result.slider("Notes appear within", (a.notesRange - MinNotesRange) / span,
                enabled = eoNotes in a.editorOnlyParts,
                onChange = proc(v: float) =
                  a.notesRange = round((MinNotesRange + v.float32 * span) / NotesRangeStep) * NotesRangeStep,
                valueText = proc(v: float): string = $int(round(MinNotesRange + v.float32 * span)))

proc editParticleEvents(a: App, o: LevelObject, label: string, change: proc(root: XmlNode): int) =
  ## One undo step of a change to the class's Events. change returns how many
  ## Action parameters lost the action they named.
  let before = @[o.snapshot]
  let lost = change(o.node)
  o.file.dirty = true
  o.syncFromNode()
  a.push editCmd(label, @[o], before)
  if lost > 0:
    a.say(&"{lost} action(s) named the one removed and now name action 0: check their Action", true)

proc classLabel(name: string): string
proc classParents(a: App, key: string): seq[string]
proc classChain(a: App, key: string): seq[string]

proc classParentsTree(a: App, child: string): MenuNode =
  ## The arrow on a breadcrumb: child's other parents, to follow one of those instead.
  result = newMenuRoot()
  let at = if child == a.className: a.classTrail.len else: a.classTrail.find(child)
  if at < 1: return
  let shownParent = a.classTrail[at - 1]
  let below = a.classTrail[at .. ^1]
  let root = result
  root.item("Also spawned by", enabled = false)
  proc parentItem(alt: string) =
    root.item(alt.classLabel, action = proc() =
      a.classTrail = a.classChain(alt) & alt & below)
  for alt in a.classParents(child):
    if alt != shownParent: parentItem(alt)

proc classAddTree(a: App, what: string): MenuNode =
  ## The + on the Events heading (what = "+": an event) or on an event: its action.
  let root = newMenuRoot()
  result = root
  let o = a.classes.getOrDefault(a.className)
  if o == nil: return
  proc show(event: string) =
    a.classFolded.excl "p:Events"
    a.classFolded.excl "p:Events/" & event
  proc eventItem(e: EventDef) =
    root.item(e.label, action = proc() =
      a.editParticleEvents(o, "Add event " & e.name, proc(n: XmlNode): int = discard n.addEvent(e.name))
      show(e.name))
  proc actionItem(menu: MenuNode, d: ActionDef) =
    menu.item(d.label, action = proc() =
      a.editParticleEvents(o, "Add " & d.name, proc(n: XmlNode): int = n.addAction(what, d.name))
      show(what))
  if what == "+":
    for e in EventDefs:
      if o.node.eventOf(e.name) == nil: eventItem(e)
  else:
    for g in ActionGroups:
      let menu = root.sub(g)
      for d in ActionDefs:
        if d.group == g: actionItem(menu, d)

proc contextTree(a: App): MenuNode =
  ## Right click in a view (TrenchBroom's map view menu, for Oni's objects).
  let c = a.ctx
  if c.file.len > 0: return a.fileContextTree(c.file)
  if c.realtime: return a.realtimeTree()
  if c.gizmos: return a.gizmosTree()
  if c.editorOnly: return a.editorOnlyTree()
  if c.classAdd.len > 0: return a.classAddTree(c.classAdd)
  if c.classParentsOf.len > 0: return a.classParentsTree(c.classParentsOf)
  if c.texture.len > 0:
    # TrenchBroom's material browser menu.
    result = newMenuRoot()
    let (tex, ok) = (c.texture, a.geometryEditable)
    result.item("Select faces", enabled = ok, action = proc() = a.selectFacesWithTexture(tex))
    result.item("Select pieces", enabled = ok, action = proc() = a.selectPiecesWithTexture(tex))
    result.sep()
    result.item("Copy name", action = proc() =
      setClipboardString(tex)
      a.say "Copied " & tex)
    return
  if c.ambient.len > 0:
    result = newMenuRoot()
    let (amb, pick) = (c.ambient, c.ambientPick)
    result.item("Duplicate as new ambient...", enabled = a.proj != nil and not a.busy,
                action = proc() = a.duplicateAmbient(amb, pick))
    if isProjectAmbient(amb):
      result.item("Edit ambient...", enabled = not a.busy, action = proc() = a.editAmbient(amb))
    return
  result = newMenuRoot()
  let create = result.sub("Create object", a.proj != nil)
  # Object types, placed where the menu was opened. A proc per item, as
  # closures made in a loop would all share the last tag.
  proc createItem(menu: MenuNode, tag: string) =
    let col = LevelObject(tag: tag).look.col
    menu.item(typeName(tag), swatch = rgbx(col[0], col[1], col[2], 255), action = proc() =
      discard a.addObject(tag, a.snapV(c.point))
      a.say "Placed a new " & typeName(tag))
  # By category, like TrenchBroom's Create Point Entity menu by entity group.
  var tags = toSeq(Templates.keys)
  tags.sort(proc(x, y: string): int = cmp(typeName(x), typeName(y)))
  for c in Categories:
    let menu = create.sub(c.name)
    for t in tags:
      if t in c.tags: createItem(menu, t)
  if c.obj != nil:
    let tag = c.obj.tag
    result.item("Select all " & typeName(tag), action = proc() =
      a.clearSelection()
      for o in a.objects:
        if o.tag == tag and a.pickable(o): o.selected = true)
  if c.face >= 0 and a.geo != nil and c.face < a.geo.faces.len:
    let tex = a.geo.faces[c.face].texture
    result.item("Reveal " & tex & " in texture browser", action = proc() =
      a.currentTexture = tex
      a.texFilter = tex
      a.showPanel(pkTextureBrowser))
  if a.selFaces.len > 0:
    result.item("Select faces with the same properties", action = proc() = a.selectMatchingFaces())
  result.sep()
  # Groups, as TrenchBroom's map view menu: the group under the click can take
  # the selection, or take in the other selected groups.
  let hit = if c.groupHit != 0: c.groupHit
            elif c.obj != nil: a.objGroup(c.obj)
            elif c.face >= 0 and a.geo != nil and c.face < a.geo.faces.len and
                 a.geo.faces[c.face].objectId == -1: a.pieceGroup(a.geo.faces[c.face].piece)
            else: 0'i32
  let hitUnit = a.unitOf(hit)
  let (units, loose) = a.selectedUnits
  for it in a.groupItems:
    if it.separator: result.sep()
    elif it.label == "Ungroup selected objects":
      result.item(it.label, it.shortcut, it.enabled, it.action)
      if units.len >= 2 and not loose and hitUnit in units:
        result.item("Merge groups into " & a.groupName(hitUnit), action = proc() =
          a.mergeSelectedGroups(hitUnit))
      if hitUnit != 0 and units.len == 0 and loose:
        # Nothing grouped selected: the loose things join the group clicked on.
        result.item("Join to group " & a.groupName(hitUnit), action = proc() =
          a.addSelectionToGroup(hitUnit, join = true))
      elif hitUnit != 0 and hitUnit notin units and units.len > 0:
        result.item("Add objects to group " & a.groupName(hitUnit), action = proc() =
          a.addSelectionToGroup(hitUnit))
    elif it.label == "Remove objects from group":
      if it.enabled:
        result.item("Remove objects from group " & a.groupName(a.openGroups[^1]), it.shortcut, true, it.action)
    elif it.label == "Close group":
      if it.enabled: result.item(it.label, it.shortcut, true, it.action)
    else: result.item(it.label, it.shortcut, it.enabled, it.action)
  result.sep()
  let hasSel = a.hasSelection
  result.item("Duplicate", enabled = hasSel, action = proc() = a.duplicateSelection(vec3(0, 0, 0), flash = true))
  result.item("Separate", enabled = a.selPieces.len > 0 or a.selFaces.len > 0, action = proc() = a.separateSelection())
  result.item("Delete", enabled = hasSel, action = proc() = a.deleteSelection())
  result.item("Scatter selection", enabled = a.selection.len > 1, action = proc() = a.scatterSelection())
  result.sep()
  result.item("Hide selection", enabled = hasSel, action = proc() = discard a.runMenu("Hide selection"))
  result.item("Isolate selection", enabled = hasSel, action = proc() = discard a.runMenu("Isolate selection"))
  result.item("Show all", action = proc() = discard a.runMenu("Show all"))
  result.item("Select all in layers", enabled = hasSel, action = proc() = a.selectSiblings())
  result.sep()
  result.item("Focus camera on selection", enabled = hasSel, action = proc() = a.frameSelection())

proc updateMenus*(a: App) =
  ## Lays out the open menus, tracks hover and runs a clicked item. Call after
  ## the rest of the frame's widgets.
  let ctxTree = if a.menuSys.contextOpen: a.contextTree() else: newMenuRoot()
  a.menuSys.updatePopups(a.ui, a.menuTree, ctxTree)
  if a.ctxPending:
    a.ctxPending = false
    a.menuSys.openContext(a.ctx.pos)

# --- build and play ----------------------------------------------------------------------

proc startJob*(a: App, j: Job, onDone: proc() = nil) =
  a.job = j
  a.jobDone = onDone
  a.say j.title & "..."

proc startLoad*(a: App, key, title: string, make: proc(): Job, onDone: proc() = nil) =
  ## Queues a cache to make in the background (see Load): make runs when its
  ## turn comes. Queued already under key: onDone joins it.
  for l in a.loads:
    if l.key == key:
      if onDone != nil: l.done.add onDone
      return
  let l = Load(key: key, title: title, make: make)
  if onDone != nil: l.done.add onDone
  a.loads.add l

proc pollLoads*(a: App) =
  ## Advances the first load. While a job the user started runs (a new
  ## project's textures, Build) loads wait, so that it has the machine: none
  ## starts, and one under way starts nothing more (its running commands end).
  if a.loads.len == 0 or a.busy: return
  let l = a.loads[0]
  if l.job == nil:
    try: l.job = l.make()
    except CatchableError as e:
      a.loads.delete(0)
      a.say(l.title & ": " & e.msg, true)
      return
    if l.job == nil:   # Nothing to do any more.
      a.loads.delete(0)
      return
    a.say l.title & "..."
  l.job.poll()
  case l.job.state
  of jsRunning: discard
  of jsDone:
    a.loads.delete(0)
    let lines = a.log.len + a.logDropped
    for d in l.done: d()
    if a.log.len + a.logDropped == lines:
      a.say &"{l.title}: done in {max(1, int(epochTime() - l.job.started + 0.5))} s"
  of jsFailed:
    a.loads.delete(0)
    a.buildAfterLoad = 0   # Build, if it waited for this, will say what's missing.
    a.say(l.title & ": " & l.job.error, true)
    for line in l.job.logTail(8).splitLines: a.say("  " & line, true)
    a.showPanel(pkConsole)

proc progressBar(a: App, r: Rect, frac: float32) =
  a.ui.rect(r, colTrack)
  a.ui.rect(rect(r.x, r.y, r.w * clamp(frac, 0.03, 1), r.h), colAccent)

proc jobCount(j: Job): string =
  let (done, all) = j.progressCount
  &"({done}/{all})"

proc loadProgress(l: Load): float32 = (if l.job == nil: 0'f32 else: l.job.progress)

proc loadingBar(a: App, r: Rect, key: string) =
  ## A load's progress in the middle of r: a bar, and "what (done/all)" under it.
  let ui = a.ui
  for l in a.loads:
    if l.key != key: continue
    let w = min(260'f32, r.w - 32)
    let bar = rect(r.x + (r.w - w) / 2, r.y + r.h / 2 - 14, w, 8)
    a.progressBar(bar, l.loadProgress)
    ui.textIn(ui.ellipsize(l.loadState, r.w - 16, FontSmall), rect(r.x, bar.y + 12, r.w, 20), colTextDim,
              FontSmall, h = CenterAlign)
    return

proc libraryLoading*(a: App): Load =
  ## The library build or the levels being added to it, if either is queued.
  for l in a.loads:
    if l.key == "library" or l.key.startsWith("library "): return l

proc buildWaits(a: App): Load =
  ## A load Build reads from, if one is under way: the library's door files
  ## (when the level has doors), level 0's skies and recordings.
  let p = a.proj
  if p == nil: return
  let lib = a.libraryLoading
  if lib != nil and a.objects.anyIt(it.tag == "DOOR"): return lib
  for l in a.loads:
    if l.key == "sky" and p.sky.len > 0: return l
    if l.key == "sounds" and not hasSoundCache(): return l

proc build*(a: App, play: bool) =
  if a.proj == nil or a.busy: return
  if a.proj.preview:
    a.say("A preview can't be built or played: save it as a project first (File > Save As...)", true)
    return
  let waits = a.buildWaits
  if waits != nil:
    # Starts by itself once that's made (if the level is still open).
    let app = a
    let p = a.proj
    if a.buildAfterLoad == 0:
      waits.done.add proc() =
        let again = app.buildAfterLoad
        app.buildAfterLoad = 0
        if app.proj == p and not app.busy: app.build(play = again == 2)
    a.buildAfterLoad = if play: 2 else: 1
    a.say((if play: "Play" else: "Build") & " starts once this is done: " & waits.loadState)
    return
  a.saveProject()
  var then: seq[Step]
  if play: then.add launchStep(a.cfg, a.proj)
  let p = a.proj
  try:
    a.startJob(buildJob(a.cfg, p, then), proc() =
      if play:
        let at =
          if p.startSavePoint == TrainingSavePoint: " at Combat Training"
          elif p.startSavePoint > 0: &" at save point {p.startSavePoint}"
          else: ""
        a.say &"Started Oni with {p.folder}{at}"
      else: a.say "Built CustomLevels/" & p.folder)
  except CatchableError as e:
    a.say(e.msg, true)

proc importLevel*(a: App, number: int, name: string) =
  if a.busy: return
  let folder = name.strip
  if folder.len == 0 or folder.contains({'/', '\\'}):
    a.say("Choose a folder name for the project", true)
    return
  try:
    createDir(a.cfg.projectsDir)
    var loaded: Project
    let j = importJob(a.cfg, number, folder, folder, proc(p: Project) = loaded = p)
    a.startJob(j, proc() = a.loadProject(loaded))
  except CatchableError as e:
    a.say(e.msg, true)

proc previewLevel*(a: App, number: int) =
  ## Opens a game level to look at, without making a project.
  if a.busy: return
  try:
    var loaded: Project
    let j = previewJob(a.cfg, number, proc(p: Project) = loaded = p)
    a.startJob(j, proc() = a.loadProject(loaded))
  except CatchableError as e:
    a.say(e.msg, true)

proc newEmptyLevel*(a: App, name: string) =
  if a.busy: return
  let folder = name.strip
  if folder.len == 0 or folder.contains({'/', '\\'}):
    a.say("Choose a folder name for the project", true)
    return
  let levels = if a.newTexLevel > 0: @[a.newTexLevel] else: a.cfg.gameLevels
  try:
    createDir(a.cfg.projectsDir)
    var made: Project
    let j = newLevelJob(a.cfg, folder, folder, levels, a.newSky, proc(p: Project) = made = p)
    a.startJob(j, proc() = a.loadProject(made))
  except CatchableError as e:
    a.say(e.msg, true)

proc openProjectDir*(a: App, dir: string) =
  if not isProject(dir):
    a.say("Not a Catwalk project (no project.json): " & dir, true)
    return
  try:
    let p = openProject(dir)
    if p.hasGeometry:
      a.loadProject(p)
    else:
      # Projects from before geometry editing: convert their geometry first.
      a.startJob(geometryJob(a.cfg, p, proc() = a.loadProject(p)))
  except CatchableError as e:
    a.say("Could not open " & dir & ": " & e.msg, true)

proc importTextures*(a: App, files: seq[string]) =
  ## Files picked for the Texture Browser become textures of this project.
  if a.busy or a.proj == nil:
    a.say("Busy: import the textures once the current job ends", true)
    return
  let app = a
  a.startJob(importTexturesJob(a.cfg, a.proj, files, proc(names: seq[string]) =
    app.textures.add names
    app.textures.sort
    app.refreshCollections()
    if "custom" notin app.proj.textureCollections:
      app.proj.textureCollections.add "custom"
      app.proj.save()
    if names.len > 0:
      app.currentTexture = names[0]
      app.say(&"Imported {names.len} texture(s)")))

proc importSounds*(a: App, files: seq[string], pick: proc(v: string) = nil) =
  ## Files picked with File > Import > Sounds become recordings of this project:
  ## every sound field lists them as rec_cw_<name>. pick: the sound field they
  ## were imported from (Import sound... in its list), which gets the first.
  if a.busy or a.proj == nil:
    a.say("Busy: import the sounds once the current job ends", true)
    return
  let app = a
  let proj = a.proj
  a.startJob(importSoundsJob(a.cfg, a.proj, files, proc(names: seq[string]) =
    app.catalog.forgetProject()
    if names.len == 0: return
    let list = names.mapIt(RecordingPrefix & it).join(", ")
    if pick != nil and app.proj == proj:
      pick(RecordingPrefix & names[0])
      app.say("Imported " & list & (if names.len > 1: " (the first is in the field; all are in every sound field)"
                                    else: ", now in the field"))
    else:
      app.say("Imported " & $names.len & " sound(s): " & list & " in every sound field")))

proc importSoundInto(a: App, o: LevelObject, pick: proc(v: string)) =
  ## Import sound... in a sound field's list: the files picked become the
  ## project's recordings, and the first goes in the field, unless its object
  ## is gone by then.
  if a.proj == nil: return
  if a.busy or a.dialog != nil:
    a.say("Busy: import the sound once the current job ends", true)
    return
  let app = a
  a.soundImportPick = proc(v: string) =
    var alive = o in app.objects
    for c in app.classes.values:
      if c == o: alive = true
    if alive: pick(v)
  a.dialog = startDialog(dkOpenFiles, "fieldsound", "Import sound", getHomeDir(), @SoundFormats, "Sounds")

proc importSky*(a: App, dir: string) =
  ## A folder of faces: its popup asks which picture goes where.
  if a.busy or a.proj == nil:
    a.say("Busy: import the sky once the current job ends", true)
    return
  let files = skyFolderPictures(dir)
  if files.len == 0:
    a.say("No pictures in " & dir, true)
    return
  var names: seq[string]
  for f in files: names.add f.splitFile.name
  a.skyImportFiles = files
  a.skyImportSides = guessSides(names)
  a.skyImportTurns = newSeq[int](files.len)
  for t in a.skyImportTurns.mitems: t = -1
  a.skyImportScroll = 0
  a.skyImportFit = nil
  # Their edges show how they really fit, whatever their names say.
  if files.len in 5 .. 6:
    try:
      var pictures: seq[TgaImage]
      for f in files: pictures.add readPicture(f)
      a.skyImportFit = newSkyFit(pictures)
      var wanted: seq[int]
      for n in names: wanted.add sideByName(n)
      let fit = a.skyImportFit.arrange(wanted)
      if fit.ok: a.skyImportSides = fit.sides
    except CatchableError: a.skyImportFit = nil   # dds, tif: names and order will do.
  a.skyImportDir = dir
  a.ui.navId = ""
  a.ui.focusId = ""

proc skyImportMissing(a: App): string =
  ## The sides no picture is on yet (bottom is optional).
  var left: seq[string]
  for side in 0 .. 4:
    if side notin a.skyImportSides: left.add SkySides[side]
  left.join(", ")

proc finishSkyImport(a: App) =
  let app = a
  let fit = a.skyImportFit.turnsFor(a.skyImportSides)
  var faces: seq[tuple[file: string, side, turns: int]]
  for i, f in a.skyImportFiles:
    if a.skyImportSides[i] >= 0:
      faces.add (f, a.skyImportSides[i], if a.skyImportTurns[i] >= 0: a.skyImportTurns[i] else: fit.turns[i])
  a.startJob(importSkyJob(a.cfg, a.proj, a.skyImportDir, faces, proc(sky: string) =
    let before = app.proj.projSettings
    app.proj.sky = sky
    app.editProject("Change Sky", before)
    app.say("Imported sky " & sky)))

proc convertSky(a: App, file: string, kind: SkySource, use: bool) =
  ## One picture becomes a sky of this project, and the level's sky if use.
  let app = a
  a.startJob(convertSkyJob(a.cfg, a.proj, file, kind, proc(sky: string) =
    if use:
      let before = app.proj.projSettings
      app.proj.sky = sky
      app.editProject("Change Sky", before)
      app.say("Converted the picture and set the level's sky to " & sky)
    else:
      app.say("Converted the picture to " & sky & ": pick it under Sky in Properties")))

proc extractCollections*(a: App, levels: seq[int]) =
  ## Extracts the levels' textures; with the entity library built, their
  ## classes join it in the same job (one export of each level for both).
  if a.busy:
    a.say("Busy: enable the collection once the current job ends", true)
    return
  let app = a
  if a.libraryLoading == nil and libraryBuilt() and not libraryBusyElsewhere():
    a.startJob(addLevelsJob(a.cfg, levels, libraryDir().parentDir / "library.log", proc() = discard), proc() =
      app.refreshCollections()
      app.loadPresets())
  else:
    a.startJob(levelTexturesJob(a.cfg, levels, a.proj.buildDir / "textures.log"), proc() = app.refreshCollections())
    if a.libraryLoading != nil:
      # The library is being made: the levels' classes join it after, from
      # these textures (unless it started late enough to take them itself).
      a.startLoad("library " & levels.join(" "), "Adding levels to the entity library", proc(): Job =
        if not libraryBuilt() or libraryBusyElsewhere(): return nil
        let missing = levels.filterIt(it notin libraryLevels())
        if missing.len == 0: return nil
        addLevelsJob(app.cfg, missing, libraryDir().parentDir / "library.log", proc() = discard),
        proc() = app.loadPresets())

proc buildLibrary*(a: App) =
  ## Makes the entity library in the background (see Load).
  if a.loading("library"): return
  let app = a
  a.startLoad("library", "Building the entity library", proc(): Job =
      libraryJob(app.cfg, libraryDir().parentDir / "library.log", proc() = discard),
    proc() =
      app.loadPresets()
      app.say "Built the entity library: " & libraryDir())

proc autoBuildPreviews*(a: App) =
  ## The entity browser's tiles and the views' entity models come from the
  ## library build: when they're shown and missing or from an older version,
  ## rebuild once, unasked, whichever panel is open.
  let wanted = a.entityPreview > 0 or a.opts.models
  if a.proj != nil and wanted and not hasPreviews() and not a.loading("library") and
     not a.previewAutoBuild and not libraryBusyElsewhere():
    a.previewAutoBuild = true
    a.say "Building the entity library: level 0 and level 1 (more levels join it with their Texture Collections)"
    a.buildLibrary()

proc autoExtractSky*(a: App) =
  ## The 3D view's skybox needs level 0's sky images: extract them once,
  ## unasked, when a project with a sky is open.
  if a.opts.sky and a.proj != nil and a.proj.sky.len > 0 and not hasSkyCache() and
     not a.skyAutoBuild:
    a.skyAutoBuild = true
    let c = a.cfg
    a.startLoad("sky", "Reading level 0's skies", proc(): Job =
      skyCacheJob(c, skyDir().parentDir / "sky.log"))

proc loadSounds(a: App, then: proc() = nil) =
  ## Level 0's sounds, extracted in the background; then runs after.
  let c = a.cfg
  a.startLoad("sounds", "Reading level 0's sounds", proc(): Job =
    soundCacheJob(c, soundDir().parentDir / "sounds.log"), then)

proc loadParticles(a: App, then: proc() = nil) =
  a.particleAutoBuild = true
  let c = a.cfg
  a.startLoad("particles", "Reading level 0's particles", proc(): Job =
    particleCacheJob(c, particleDir() / "particles.log"), then)

var autoLoadAt: float

proc autoLoad*(a: App) =
  ## Once a level is open (its textures and geometry come first), what the
  ## views and panels show of the game is made in the background while the
  ## user works: entity models, skies, then what Realtime preview plays.
  ## Twice a second: the checks look at files.
  if a.proj == nil: return
  let now = epochTime()
  if now - autoLoadAt < 0.5: return
  autoLoadAt = now
  a.autoBuildPreviews()
  a.autoExtractSky()
  if not hasParticleCache() and not a.particleAutoBuild: a.loadParticles()
  if not hasSoundCache() and not a.soundAutoBuild:
    a.soundAutoBuild = true
    a.loadSounds()

proc issuesFromJob(a: App): seq[string] {.discardable.} =
  ## Moves the job's "info:", "warning:" and "error:" lines into the Issues
  ## list (refreshing its checks too), leaving one line in the console.
  ## Returns the log lines it took.
  var warnings: seq[(Severity, string)]
  try:
    for l in readFile(a.job.logPath).splitLines:
      for sev in Severity:
        let tag = $sev & ": "
        if l.startsWith(tag):
          warnings.add (sev, l[tag.len .. ^1])
          result.add l
          break
  except IOError: discard
  # Only the level's own jobs (build, geometry) refresh the list unasked.
  if a.proj == nil or (warnings.len == 0 and a.job.logPath != a.proj.logPath): return
  a.findIssues(warnings)
  if a.issues.len > 0:
    var counts: seq[string]
    for sev in Severity:
      let n = a.issues.countIt(it.severity == sev)
      if n > 0: counts.add &"{n} {sev}" & (if n > 1 and sev != sevInfo: "s" else: "")
    a.say(&"{a.job.title}: {counts.join(\", \")}, listed under Issues", a.issues[0].severity == sevError)
    a.showPanel(pkIssues)

proc pollJob*(a: App) =
  if a.job == nil: return
  a.job.poll()
  case a.job.state
  of jsRunning: discard
  of jsDone:
    a.issuesFromJob()
    let j = a.job
    let done = a.jobDone
    a.job = nil
    a.jobDone = nil
    let lines = a.log.len + a.logDropped
    if done != nil: done()
    # Jobs that say nothing when done (the caches made unasked) still end in
    # the Console, else their "..." line looks like they never finished.
    if a.log.len + a.logDropped == lines:
      a.say &"{j.title}: done in {max(1, int(epochTime() - j.started + 0.5))} s"
  of jsFailed:
    let shown = a.issuesFromJob()
    a.say(a.job.error, true)
    for l in a.job.logTail(8).splitLines:
      if l notin shown: a.say("  " & l, true)
    a.showPanel(pkConsole)
    a.job = nil
    a.jobDone = nil

# --- toolbar ---------------------------------------------------------------------------

proc drawToolbar*(a: App) =
  let ui = a.ui
  let bar = rect(0, MenuBarHeight, ui.size.x, ToolbarHeight)
  ui.rect(bar, colPanelRaised)
  ui.rect(rect(0, bar.y + bar.h - 1, bar.w, 1), colBorder)
  let hasProj = a.proj != nil
  let geo = a.geo != nil
  var x = 8'f32
  let y = bar.y + 5
  proc btn(id, icon, tip: string, enabled: bool, toggled = false): bool =
    let r = rect(x, y, 28, 28)
    x += 30
    if toggled: ui.rect(r, colAccentDim)
    ui.iconButton(id, r, icon & "20", tip, enabled and hasProj, toggled, clickFocus = false)
  proc gap() =
    x += 6
    ui.rect(rect(x, y + 6, 1, 16), colSeparator)
    x += 8
  for (t, icon, tip, needsGeo) in [
      (toolSelect, "cursor", "No tool: click selects, drag moves the selection or draws a brush (W)", false),
      (toolBrush, "cube", "Brush tool: build a brush from points (B)", true),
      (toolVertex, "vertex", "Vertex tool (V)", true),
      (toolEdge, "edge", "Edge tool (E)", true),
      (toolFace, "face", "Face tool (F)", true),
      (toolClip, "scissors", "Clip tool (C)", true),
      (toolRotate, "rotate", "Rotate tool (R)", false),
      (toolScale, "scale", "Scale tool (T)", false)]:
    if btn("tb." & $t, icon, tip, (not needsGeo) or geo, a.tool == t): a.setTool(t)
  gap()
  if btn("tb.dup", "duplicate", "Duplicate (Ctrl+D)", a.hasSelection):
    a.duplicateSelection(vec3(0, 0, 0), flash = true)
  if btn("tb.fliph", "fliph", "Flip horizontally (Ctrl+F)", a.hasSelection):
    discard a.runMenu("Flip horizontally")
  if btn("tb.flipv", "flipv", "Flip vertically (Ctrl+Alt+F)", a.hasSelection):
    discard a.runMenu("Flip vertically")
  gap()
  if btn("tb.uvlock", "uvlock", "UV lock (U): textures move with geometry", true, a.uvLock):
    a.uvLock = not a.uvLock
  if btn("tb.snap", "magnet", "Snap to grid (Alt+0)", true, a.snap): a.snap = not a.snap
  x += 6
  var gridItems: seq[string]
  for g in GridSizes: gridItems.add &"Grid {g:g}"
  let gi = a.dropdown("tb.grid", rect(x, y, 104, 28), &"Grid {a.grid:g}", gridItems, clickFocus = false)
  if gi >= 0: a.gridIndex = gi
  x += 112

  # Start point, Build and Play on the right.
  let playR = rect(ui.size.x - 104, y, 96, 28)
  let buildR = rect(playR.x - 88, y, 82, 28)
  let startR = rect(buildR.x - 184, y, 176, 28)
  let can = hasProj and not a.busy and not a.proj.preview
  if hasProj:
    var starts = @[0]
    if a.proj.hasTraining: starts.add TrainingSavePoint
    for n in a.savePointList:
      if not (a.proj.hasTraining and n == 1): starts.add n   # level 1's beginning
    var labels: seq[string]
    for sp in starts: labels.add a.proj.startLabel(sp)
    let pick = a.dropdown("tb.start", startR, a.proj.startLabel(a.proj.startSavePoint), labels,
                          clickFocus = false)
    if pick >= 0: a.proj.startSavePoint = starts[pick]
    ui.tip(startR, "Where Play starts the level. Save points use your saved game from the original level.")
  if can:
    if ui.textButton("tb.build", buildR, "Build", clickFocus = false): a.build(play = false)
    if ui.textButton("tb.play", playR, "", primary = true, clickFocus = false): a.build(play = true)
    ui.icon("play20", vec2(playR.x + 22, playR.y + playR.h / 2), colOnAccent)
    ui.text("Play", vec2(playR.x + 38, playR.y + 5), colOnAccent)
  else:
    ui.rect(buildR, colPanel)
    ui.textIn("Build", buildR, colTextDisabled, h = CenterAlign)
    ui.rect(playR, colAccentDim)
    ui.icon("play20", vec2(playR.x + 22, playR.y + playR.h / 2), colTextDisabled)
    ui.text("Play", vec2(playR.x + 38, playR.y + 5), colTextDisabled)
  ui.tip(playR, "Save, build into CustomLevels and start Oni in this level (F5)")
  ui.tip(buildR, "Save and build into CustomLevels (F7)")

# --- tool options strip -----------------------------------------------------------------

proc parseVec(s: string): (bool, Vec3) =
  let parts = strutils.splitWhitespace(s.replace(",", " "))
  if parts.len != 3: return
  try: (true, vec3(evalMath(parts[0]), evalMath(parts[1]), evalMath(parts[2])))
  except CatchableError: (false, vec3(0, 0, 0))

const
  LayoutButtonW = 30'f32
  LayoutButtonsW = 4 * (LayoutButtonW + 4) + 6   ## The four buttons and the gap before View options.

proc layoutCells(layout: PaneLayout, r: Rect): seq[Rect] =
  ## The panes of layout drawn small inside r, in view order (as layoutViews
  ## places them), with a 2 px gap between them.
  let lw = floor(r.w * 0.55)
  let th = floor(r.h * 0.5)
  case layout
  of pl1: @[r]
  of pl2: @[rect(r.x, r.y, lw - 1, r.h), rect(r.x + lw + 1, r.y, r.w - lw - 1, r.h)]
  of pl3: @[rect(r.x, r.y, lw - 1, r.h), rect(r.x + lw + 1, r.y, r.w - lw - 1, th - 1),
            rect(r.x + lw + 1, r.y + th + 1, r.w - lw - 1, r.h - th - 1)]
  of pl4: @[rect(r.x, r.y, lw - 1, th - 1), rect(r.x + lw + 1, r.y, r.w - lw - 1, th - 1),
            rect(r.x, r.y + th + 1, lw - 1, r.h - th - 1),
            rect(r.x + lw + 1, r.y + th + 1, r.w - lw - 1, r.h - th - 1)]

proc layoutButtons(a: App, x0, y: float32) =
  ## One, two, three and four panes: each a small drawing of its panes as
  ## hollow rectangles, the one holding the 3D view filled.
  let ui = a.ui
  var x = x0
  for l in PaneLayout:
    let r = rect(x, y, LayoutButtonW, 24)
    x += LayoutButtonW + 4
    let on = a.layout == l and a.maximized < 0
    let hov = ui.hover(r)
    if on: ui.roundedRect(r, colAccentDim, 2)
    elif hov: ui.roundedRect(r, colHover, 2)
    let col = if on or hov: colWhite else: colTextDim
    let icon = rect(r.x + 6, r.y + 5, r.w - 12, r.h - 10)
    for i, c in layoutCells(l, icon):
      if a.views[i].cam.kind == vk3D: ui.rect(c, col)
      else: ui.border(c, col)
    ui.tip(r, $l)
    if hov and ui.pressed():
      ui.consumeClick()
      a.layout = l
      a.maximized = -1

proc drawToolOptions*(a: App, r: Rect) =
  ## The strip above the views: settings for the current tool (TrenchBroom's
  ## info bar) and the view options on the right.
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)
  var x = r.x + 10
  let y = r.y + 4
  proc label(s: string) =
    ui.text(s, vec2(x, y + 5), colTextDim, FontSmall)
    x += ui.textSize(s, FontSmall).x + 8
  proc button(id, s: string): bool =
    let w = ui.textSize(s).x + 24
    result = ui.textButton(id, rect(x, y, w, 24), s)
    x += w + 6
  proc gap() =
    x += 6
    ui.rect(rect(x, y + 5, 1, 14), colSeparator)
    x += 13
  ui.pushClip(rect(r.x, r.y, r.w - 140 - LayoutButtonsW, r.h))
  case a.tool
  of toolSelect:
    label "Shape"
    var names: seq[string]
    for s in ShapeKind: names.add $s
    let pick = a.dropdown("opt.shape", rect(x, y, 110, 24), $a.shape, names)
    if pick >= 0: a.shape = ShapeKind(pick)
    x += 118
    if a.shape in {shCylinder, shCone}:
      label "Sides"
      discard ui.numberField("opt.sides", rect(x, y, 100, 24), a.shapeSides, 1, 3, 64)
      x += 108
    elif a.shape == shStairs:
      label "Steps"
      discard ui.numberField("opt.steps", rect(x, y, 100, 24), a.shapeSteps, 1, 1, 64)
      x += 108
    gap()
    label "Move objects by"
    let ev = ui.textField("opt.moveby", rect(x, y, 140, 24), a.moveBy, "x y z")
    x += 148
    if button("opt.moveapply", "Apply") or (eeCommitted in ev and ui.window.buttonPressed[KeyEnter]):
      let (ok, d) = parseVec(a.moveBy)
      if ok: a.moveSelection(d)
  of toolBrush:
    label &"Brush tool: {a.assemblePoints.len} point(s)."
    label "Click faces to place points, double-click a face for its corners, drag on a face for a rectangle, Shift+drag a polygon to raise it."
    if button("opt.asmcreate", "Create (Enter)"): a.createAssembled()
    if button("opt.asmclear", "Clear (Esc)"): a.assemblePoints.setLen 0
  of toolVertex, toolEdge, toolFace:
    label &"{a.tool} tool: {a.selHandles.len} handle(s) selected."
    label "Click or drag handles; drag empty space to lasso (Ctrl toggles); Delete removes corners from brushes."
  of toolClip:
    label "Click 2 or 3 points (on faces in 3D), or drag to place 2; drag points to move them; double-click a face to clip along it."
    for (s, side) in [("Keep front", sideFront), ("Keep both", sideBoth), ("Keep back", sideBack)]:
      if ui.radioButton("opt.clip." & s, vec2(x, y + 1), s, a.clipSide == side): a.clipSide = side
      x += ui.textSize(s).x + 34
    if button("opt.clipapply", "Apply (Enter)"): a.applyClip()
    if button("opt.clipreset", "Reset"): a.resetClip()
  of toolRotate:
    label "Center"
    if ui.focusId != "opt.rotcenter": a.rotCenterText = fmtVec(a.rotCenter)
    let ev = ui.textField("opt.rotcenter", rect(x, y, 140, 24), a.rotCenterText, "x y z")
    if eeCommitted in ev:
      let (ok, c) = parseVec(a.rotCenterText)
      if ok: a.rotCenter = c
    x += 148
    if button("opt.rotreset", "Reset"): a.resetRotateCenter()
    gap()
    label "Rotate objects"
    discard ui.numberField("opt.angle", rect(x, y, 100, 24), a.rotateAngle, 15, 1, 180)
    x += 108
    label "degs about"
    let ax = a.dropdown("opt.rotaxis", rect(x, y, 56, 24), ["X", "Y", "Z"][a.rotAxis], @["X", "Y", "Z"])
    if ax >= 0: a.rotAxis = ax
    x += 64
    label "axis"
    if button("opt.rotapply", "Apply"):
      var axis = vec3(0, 0, 0)
      axis[a.rotAxis] = 1
      a.rotateKeyed(axis, 1, "Rotate")
  of toolScale:
    label "Scale objects"
    let mode = a.dropdown("opt.scalemode", rect(x, y, 104, 24),
                          if a.scaleBySize: "to size" else: "by factors", @["to size", "by factors"])
    if mode >= 0: a.scaleBySize = mode == 0
    x += 112
    let (okb, lo, hi) = a.selectionBounds
    if a.scaleText.len == 0 or (ui.focusId != "opt.scale" and okb and a.scaleBySize):
      a.scaleText = if okb and a.scaleBySize: fmtVec(hi - lo) else: "1 1 1"
    discard ui.textField("opt.scale", rect(x, y, 140, 24), a.scaleText, "x y z")
    x += 148
    if button("opt.scaleapply", "Apply") and okb:
      let (ok, v) = parseVec(a.scaleText)
      if ok:
        var f = v
        if a.scaleBySize:
          for i in 0 .. 2: f[i] = if hi[i] - lo[i] > 1e-4: v[i] / (hi[i] - lo[i]) else: 1
        a.scaleSelection(f)
    label "Drag the handles: Shift scales proportionally, Alt from the center."
  ui.popClip()
  # View options, right-aligned (after the tool's controls in the Tab order).
  let vr = rect(r.x + r.w - 134, y, 126, 24)
  a.layoutButtons(vr.x - LayoutButtonsW, y)
  # The render modes first, then the toggles.
  let toggles = [("Marker faces", a.opts.markers),
                 ("AI rooms", a.opts.rooms), ("Entity models", a.opts.models),
                 ("Object names in 2D", a.showObjectNames), ("Entity directions", a.showDirections),
                 ("Grid", a.showGrid), ("Sky", a.opts.sky), ("Realtime preview", a.realtime),
                 ("Gizmos", a.showGizmos), ("Editor-only", a.showEditorOnly)]
  var items: seq[string]
  for m in RenderMode: items.add (if a.opts.mode == m: "● " else: "◌ ") & $m
  for (n, on) in toggles: items.add (if on: "● " else: "◌ ") & n
  let picked = a.dropdown("opt.view", vr, "View options", items)
  if picked in 0 .. RenderMode.high.ord: a.opts.mode = RenderMode(picked)
  case picked - RenderMode.high.ord - 1
  of 0:
    a.opts.markers = not a.opts.markers
    if a.geo != nil: a.geo.bump()
  of 1: a.opts.rooms = not a.opts.rooms
  of 2: a.opts.models = not a.opts.models
  of 3: a.showObjectNames = not a.showObjectNames
  of 4: a.showDirections = not a.showDirections
  of 5: a.showGrid = not a.showGrid
  of 6: a.opts.sky = not a.opts.sky
  of 7: a.switchRealtime()
  of 8: a.showGizmos = not a.showGizmos
  of 9: a.switchEditorOnly()
  else: discard

# --- dividers ---------------------------------------------------------------------------------

var wantCursor*: CursorKind
var shownCursor = ArrowCursor

proc divider*(a: App, id: string, r: Rect, vertical: bool): (bool, float32) =
  ## A draggable bar between two panes. Returns true and the mouse position
  ## (along the drag axis, adjusted for where it was grabbed) while dragged.
  let ui = a.ui
  let active = a.splitDrag == id
  let hov = not active and a.splitDrag.len == 0 and ui.hover(r) and a.drag.kind == dkNone and
            not a.press.active
  if hov or active: wantCursor = if vertical: ResizeLeftRightCursor else: ResizeUpDownCursor
  ui.rect(r, colPanel)
  # A visible line (wider while hovered or dragged) with a grip in the middle.
  let t = if active or hov: 4'f32 else: 2'f32
  let line = if vertical: rect(r.x + (r.w - t) / 2, r.y, t, r.h) else: rect(r.x, r.y + (r.h - t) / 2, r.w, t)
  ui.rect(line, if active: colAccent elif hov: colAccentHover else: colTextDisabled)
  let gripCol = if active or hov: colOnAccent else: colTextDim
  for i in -2 .. 2:
    let o = i.float32 * 6
    let g = if vertical: rect(r.x + r.w / 2 - 1, r.y + r.h / 2 + o - 1, 2, 2)
            else: rect(r.x + r.w / 2 + o - 1, r.y + r.h / 2 - 1, 2, 2)
    if (vertical and r.h > 40) or (not vertical and r.w > 40): ui.rect(g, gripCol)
  if hov and ui.pressed():
    a.splitDrag = id
    a.splitGrab = if vertical: ui.mouse.x - (r.x + r.w / 2) else: ui.mouse.y - (r.y + r.h / 2)
    ui.consumeClick()
  if active:
    if not ui.window.buttonDown[MouseLeft]: a.splitDrag = ""
    else: return (true, (if vertical: ui.mouse.x else: ui.mouse.y) - a.splitGrab)

proc applyCursor*(a: App) =
  if wantCursor != shownCursor:
    shownCursor = wantCursor
    a.window.cursor = Cursor(kind: wantCursor)

# --- inspector: map -----------------------------------------------------------------------

type PieceInfo = tuple[faces: int, texture: string, world: bool]
var pieceInfoCache: tuple[version: int, geo: Geometry, info: seq[PieceInfo]]

include scriptpanel

proc pieceInfo(a: App): seq[PieceInfo] =
  if a.geo == nil: return
  if pieceInfoCache.geo == a.geo and pieceInfoCache.version == a.geo.version: return pieceInfoCache.info
  result = newSeq[PieceInfo](a.geo.pieces.len)
  for f in a.geo.faces:
    if f.piece < 0 or f.piece >= result.len: continue
    inc result[f.piece].faces
    if result[f.piece].texture.len == 0 and not (f.isMarkerFace or f.isInvisibleFace): result[f.piece].texture = f.texture
    if f.objectId == -1: result[f.piece].world = true
  pieceInfoCache = (a.geo.version, a.geo, result)

type TreeRow = object
  layer: string          ## Layer key (GEOM or an object tag).
  depth: int             ## 0 layer, then groups and members, nested.
  obj: LevelObject
  piece: int32
  group: int32           ## A group row: the group (its members of this layer under it).
  cls: string            ## A class a Particle object spawns (a.classes key): not an object.
  fold: string           ## A Particle object or spawned class with spawned classes under it.

proc foldKey(row: TreeRow): string =
  ## What a.expanded holds for an open layer, group or spawn row ("" for the rest).
  if row.fold.len > 0: row.fold
  elif row.depth == 0: row.layer
  elif row.group != 0: row.layer & "/" & $row.group
  else: ""

proc isMember(row: TreeRow): bool = row.depth > 0 and row.group == 0 and row.cls.len == 0

proc openClass(a: App, name: string): LevelObject

proc spawnKids(a: App, key: string): seq[string] =
  ## The classes key's particles create, by emitter or on collision (a.classes keys).
  let c = a.openClass(key)
  if c == nil: return
  var names: seq[string]
  let ems = c.node.child("Emitters")
  if ems != nil:
    for em in ems:
      if em.kind == xnElement and em.child("Class") != nil: names.add em.child("Class").innerText
  for (_, act) in c.node.classActions:
    if act.tag == "CollisionEffect" and act.child("Effect") != nil: names.add act.child("Effect").innerText
  for n in names:
    let k = ParticlePrefix & n.strip.toLowerAscii
    if k != ParticlePrefix and k notin result: result.add k

proc openRowGroup(a: App, row: TreeRow): bool =
  ## A member row clicked: only the groups around it are open, so it's selected
  ## alone rather than as its closed group. True if the open groups changed.
  if row.obj == nil: a.openTo(a.pieceGroup(row.piece))
  elif a.visible(row.obj) and row.obj.tag notin a.layerLocked: a.openTo(a.objGroup(row.obj))
  else: false


proc withSounds(a: App, what: string, play: proc()) =
  ## Runs play now, or once level 0's sounds are extracted (the first preview).
  if hasSoundCache():
    play()
  else:
    if not a.loading("sounds"): a.say("Level 0's sounds are read first: the " & what & " plays after")
    a.loadSounds(play)

proc previewMusic(a: App, realtime = false) =
  ## Plays the project's track (realtime: as Realtime preview's level music).
  let p = a.proj
  a.withSounds("music", proc() =
    if p != a.proj or p.music.len == 0: return
    try: playMusic(p.music, p.musicVolume, realtime)
    except CatchableError as e: a.say(e.msg, true))

proc soundLevel(o: LevelObject): (float, float) =
  ## A Sound object's volume and pitch as Oni plays them: the field OniSplit
  ## calls Pitch is its volume, and Volume is never read (soundscene.nim).
  ## Nothing on the object shifts the pitch.
  result = (1.0, 1.0)
  for f in o.fields:
    try:
      if f.path == "OSD/Pitch": result[0] = parseFloat(f.value.strip)
    except ValueError: discard

proc soundClass(o: LevelObject): string =
  ## A Sound object's Class (the ambient it plays).
  for f in o.fields:
    if f.path == "OSD/Class" and f.attr.len == 0: return f.value.strip

proc previewSound(a: App, ambient: string, o: LevelObject) =
  ## Plays a Sound object's ambient (or ambient, one of its Class choices) at
  ## its level; again stops it.
  if soundPlaying(ambient):
    stopSound()
    return
  a.soundObj = o
  a.soundClass = o.soundClass
  a.withSounds("sound", proc() =
    let (vol, pitch) = o.soundLevel
    try: playSound(ambient, vol, pitch)
    except CatchableError as e: a.say(e.msg, true))

proc previewClassSound(a: App, name: string, impulse: bool) =
  ## Plays a class's sound (or one of its choices) as recorded; again stops it.
  if soundPlaying(name):
    stopSound()
    return
  a.soundObj = nil
  a.withSounds("sound", proc() =
    try: playSound(name, 1, 1, impulse)
    except CatchableError as e: a.say(e.msg, true))

proc updateRealtime*(a: App) =
  ## Realtime preview's sound, every frame: the visible Sound objects play as
  ## they would in the game, heard from the 3D camera (soundscene.nim), and the
  ## level music starts as when the level loads.
  if a.musicUndone:
    # Undo or redo changed the track: a preview (not Realtime's music) follows, as on a pick.
    a.musicUndone = false
    if musicPlaying() and a.realtimeMusic.len == 0 and a.proj != nil:
      if a.proj.music.len > 0: a.previewMusic() else: stopMusic()
  setPreviewGains(a.previewMusicVolume, a.previewSoundVolume)
  let on = a.realtime and a.proj != nil
  let sounds = on and ppSounds in a.previewParts
  let music = if on and ppMusic in a.previewParts: a.proj.music else: ""
  if a.sceneKey.len > 0 and (not on or (not sounds and a.sceneKey == "playing")):
    stopSoundScene()
    a.sceneKey = ""
  if music != a.realtimeMusic and a.realtimeMusic.len > 0:
    stopMusic()
    a.realtimeMusic = ""
  if not sounds and music.len == 0: return
  if not hasSoundCache():
    # The first time, level 0's sounds are extracted (then this picks them up).
    if a.sceneKey != "extracting":
      a.sceneKey = "extracting"
      a.withSounds("realtime sounds", proc() = discard)
    return
  if music != a.realtimeMusic:
    a.realtimeMusic = music
    a.previewMusic(realtime = true)
  if not sounds: return
  a.sceneKey = "playing"
  try: a.updateSoundScene()
  except CatchableError as e:
    a.say(e.msg, true)
    a.realtime = false
    stopSoundScene()
    a.sceneKey = ""

proc editedClasses(a: App): HashSet[string]

proc editedParticleXml(a: App): Table[string, string] =
  ## The project's versions of particle classes: as open now, else as saved.
  for n in a.editedClasses:
    if not n.startsWith(ParticlePrefix): continue
    let plain = n[ParticlePrefix.len .. ^1]
    let o = a.classes.getOrDefault(n)
    try:
      result[plain] = if o != nil: "<Oni>" & $o.node & "</Oni>" else: readFile(a.proj.particlePath(plain))
    except IOError: discard

proc updateParticles*(a: App) =
  ## Realtime preview's particles, every frame: the level's Particle objects
  ## run their classes (particlesim.nim) and the 3D views draw them.
  ## Objects played from the particle panel run with or without it.
  if a.proj == nil:
    a.particlePlaying.clear()
    a.particlePlayNext.setLen 0
    a.particleHaltNext.setLen 0
  let live = a.realtime and a.proj != nil and ppParticles in a.previewParts
  if not live and a.particlePlaying.len == 0:
    if a.particleSim != nil:
      a.particleSim = nil
      a.rend.sprites.setLen 0
      a.rend.particleTris.setLen 0
    return
  if not hasParticleCache():
    # The first time, level 0's particle classes are extracted.
    if not a.particleAutoBuild: a.loadParticles()
    return
  let now = epochTime()
  if a.particleSim == nil:
    a.particleSim = newParticleSim()
    a.particleEditKey = ""
    a.particleEditStamp = (-1, -1, -1)
    a.particleClock = now
    let dir = levelTextureDir(a.proj.oniDir)
    if fileExists(dir / "done"): a.particleSim.levelTextures = dir
  let stamp = (a.pushCount, a.undoStack.len, a.redoStack.len)
  if stamp != a.particleEditStamp:
    a.particleEditStamp = stamp
    let edited = a.editedParticleXml
    if $edited != a.particleEditKey:
      a.particleEditKey = $edited
      a.particleSim.setEditedClasses(edited)
      a.particleRestart = true
  a.particleSim.loop = a.particleLoop
  var sources = a.particleSources
  if not live: sources.keepItIf(it.id in a.particlePlaying)
  if a.particleRestart:
    a.particleSim.reset(sources)
    a.particleRestart = false
  else:
    a.particleSim.sync(sources)
  for src in sources:
    if src.id in a.particlePlayNext: a.particleSim.play(src)
  for id in a.particleHaltNext: a.particleSim.halt(id)
  a.particlePlayNext.setLen 0
  a.particleHaltNext.setLen 0
  a.particleSim.step(now - a.particleClock, a.geo, now)
  a.particleClock = now
  # Stopped ones stay until what they emitted has finished.
  for id in a.particlePlaying.toSeq:
    if id notin a.particleSim.played and not a.particleSim.alive(id): a.particlePlaying.excl id
  let cam = a.camera3D
  let camPos = if cam != nil: cam.pos else: vec3(0, 0, 0)
  a.rend.sprites = a.particleSim.sprites(camPos)
  a.rend.particleTris = a.particleSim.triangles(camPos)
  # Decal textures are the level's own: extracted from the project, once.
  let sim = a.particleSim
  if sim.missingTextures.len > 0 and not a.busy and a.particleLevelJob != a.proj.oniDir:
    a.particleLevelJob = a.proj.oniDir
    var names: seq[string]
    for n in sim.missingTextures:
      if fileExists(a.proj.oniDir / "TXMP" & n & ".oni"): names.add n
    if names.len > 0:
      let oniDir = a.proj.oniDir
      try:
        a.startJob(levelTextureJob(a.cfg, oniDir, names, particleDir() / "level.log"), proc() =
          if a.particleSim != nil:
            a.particleSim.levelTextures = levelTextureDir(oniDir)
            a.particleSim.forgetMissingTextures())
      except CatchableError as e: a.say(e.msg, true)

proc musicRow(a: App, x: float32, y: var float32, w: float32) =
  ## Music started when the level loads, and its volume.
  let ui = a.ui
  var items = @["None"]
  for t in MusicTracks: items.add t
  let vr = a.propName("Music", x, y, w, "Plays from the moment the level loads (one of level 0's tracks)")
  let mi = a.dropdown("map.music", rect(vr.x, y, vr.w - 30, 26),
                      if a.proj.music.len > 0: a.proj.music else: "None", items)
  if mi >= 0:
    let before = a.proj.projSettings
    a.proj.music = if mi == 0: "" else: MusicTracks[mi - 1]
    a.editProject("Change Music", before)
    # A preview follows the pick.
    if musicPlaying():
      if a.proj.music.len > 0: a.previewMusic() else: stopMusic()
  let playing = musicPlaying()
  if ui.iconButton("map.musicplay", rect(vr.x + vr.w - 26, y, 26, 26),
                   if playing: "stop16" else: "play16",
                   if playing: "Stop the preview" else: "Listen to this track",
                   a.proj.music.len > 0 or playing):
    if playing: stopMusic() else: a.previewMusic()
  y += 30
  if a.proj.music.len > 0:
    let r = a.propName("Volume", x, y, w)
    var v = a.proj.musicVolume
    if ui.slider("map.musicvol", rect(r.x, y + 4, r.w - 44, 18), v, 0, 1, 0.05):
      let before = a.proj.projSettings
      a.proj.musicVolume = v
      a.editProject("Change Music Volume", before, merge = "map.musicvol")
      setMusicVolume(v)
    ui.textIn(&"{int(round(a.proj.musicVolume * 100))}%", rect(r.x + r.w - 40, y, 40, 26),
              colTextDim, FontSmall, h = RightAlign)
    y += 30

proc skyGradeRows(a: App, x: float32, y: var float32, w: float32) =
  ## The sky's brightness, blend mode and tint: live in the 3D view. Its images
  ## stay as they are, and Build applies these to copies of them.
  let ui = a.ui
  let p = a.proj
  let r = a.propName("Sky brightness", x, y, w, "Brightness of the sky, before the tint.")
  var v = p.skyGrade.brightness.float
  if ui.slider("map.skybright", rect(r.x, y + 4, r.w - 44, 18), v, 0, 2, 0.05):
    let before = p.projSettings
    p.skyGrade.brightness = v.float32
    a.editProject("Change Sky Brightness", before, merge = "map.skybright")
  ui.textIn(&"{int(round(p.skyGrade.brightness * 100))}%", rect(r.x + r.w - 40, y, 40, 26), colTextDim)
  y += 30
  var names: seq[string]
  for n in SkyBlendNames: names.add n
  let br = a.propName("Sky blend", x, y, w, "How the tint mixes with the sky. None leaves the tint out.")
  let picked = a.dropdown("map.skyblend", br, SkyBlendNames[p.skyGrade.blend], names)
  if picked >= 0:
    let before = p.projSettings
    p.skyGrade.blend = SkyBlend(picked)
    a.editProject("Change Sky Blend", before)
  y += 30
  const id = "map.skytint"
  if ui.focusId != id and not pickerOpen(id): a.fieldText[id] = fmtRgb(p.skyGrade.tint)
  var before: ProjSettings
  var started = false
  let target = ColorTarget(
    live: proc(c: RGB) =
      if not started:
        before = p.projSettings
        started = true
      p.skyGrade.tint = c
      p.save(),
    done: proc(changed: bool) =
      if not started or p != a.proj: return
      if changed: a.editProject("Change Sky Tint", before)
      else:
        p.skyGrade.tint = before.skyGrade.tint
        p.save())
  let tr = a.propName("Sky tint", x, y, w, "The color the sky blend mixes in.")
  let ev = ui.colorField(id, tr, a.fieldText[id], target)
  if eeCommitted in ev:
    let (ok, c) = parseColor(a.fieldText[id])
    if ok:
      let old = p.projSettings
      p.skyGrade.tint = c
      a.editProject("Change Sky Tint", old)
  y += 30

proc lightingRows(a: App, x: float32, y: var float32, w: float32) =
  ## Baked lighting: ambient color, automatic or manual baking, Bake light.
  let ui = a.ui
  var n, on = 0
  for o in a.objects:
    if o.tag in LightTags:
      inc n
      if o.lightOn: inc on
  let count = if on == n: &"{n} light(s)" else: &"{on} of {n} lights on"
  const id = "map.ambient"
  if ui.focusId != id and not pickerOpen(id): a.fieldText[id] = fmtRgb(a.proj.ambient)
  let p = a.proj
  # The picker sets the color as it goes; closing it leaves one undo step.
  var before: ProjSettings
  var started = false
  let target = ColorTarget(
    live: proc(c: RGB) =
      if not started:
        before = p.projSettings
        started = true
      p.ambient = c
      p.save(),
    done: proc(changed: bool) =
      if not started or p != a.proj: return
      if changed: a.editProject("Change Ambient Light", before)
      else:
        p.ambient = before.ambient
        p.save())
  let vr = a.propName("Ambient", x, y, w, "Light every face gets before the lights' light.")
  let ev = ui.colorField(id, vr, a.fieldText[id], target)
  if eeCommitted in ev:
    let (ok, c) = parseColor(a.fieldText[id])
    if ok:
      let before = p.projSettings
      p.ambient = c
      a.editProject("Change Ambient Light", before)
  y += 30
  var soft = a.proj.softShadows
  let sr = a.propName("Soft shadows", x, y, w, "How many units around a corner it takes its light from: " &
    "shadows get soft edges, which corners can show, where hard ones come out in steps. 0 = hard. Baking gets slower.")
  if ui.numberField("map.soft", sr, soft, 1, 0, 32):
    let before = a.proj.projSettings
    a.proj.softShadows = soft
    a.editProject("Change Soft Shadows", before)
  y += 30
  var auto = a.proj.autoBake
  let br = a.propName("Bake automatically", x, y, w, "On: every change to a light, the ambient color " &
    "or the geometry rebakes the vertex lighting right away. Off: it changes only when you press Bake " &
    "light. Baking replaces the vertex colors of every visible face, including the level's original lighting.")
  if ui.checkbox("map.autobake", vec2(br.x, y + 2), "", auto):
    let before = a.proj.projSettings
    a.proj.autoBake = auto
    a.editProject(if auto: "Turn On Automatic Baking" else: "Turn Off Automatic Baking", before)
    if auto and a.bakeKey != a.lightingKey: a.bakeLights()   # one undo step to get back to
  y += 30
  let stale = a.geo != nil and a.bakeKey != a.lightingKey
  let lr = a.propName("Lighting", x, y, w)
  if not a.proj.autoBake:
    if ui.textButton("map.bake", rect(lr.x, y, 96, 26), "Bake light", primary = stale):
      a.bakeLights()
    let st = if a.geo == nil: "No editable geometry"
             elif stale: count & " · not baked since the last change"
             else: count & " · baked"
    let tr = rect(lr.x + 102, y, lr.w - 102, 26)
    ui.textIn(ui.ellipsize(st, tr.w, FontSmall), tr, colTextDim, FontSmall)
    ui.tip(tr, st)
  else:
    ui.textIn(ui.ellipsize(count & " · baked as you edit", lr.w, FontSmall), lr, colText, FontSmall)
  y += 30

proc stickyRows(rows: seq[TreeRow], scroll, rowH, h: float32): seq[(int, float32)] =
  ## The open parents scrolled past the top of a list of rows, outermost first,
  ## with their y in it: each holds the place under its parent until the last
  ## of its contents gets there, then leaves with them. One row stays free.
  var last = rows.len
  while (result.len + 2).float32 * rowH <= h:
    let depth = result.len
    let slot = depth.float32 * rowH
    var p = int((scroll + slot) / rowH)
    if p >= last or rows[p].depth < depth: break
    while rows[p].depth > depth: dec p
    var stop = p + 1
    while stop < rows.len and rows[stop].depth > depth: inc stop
    if stop == p + 1 or p.float32 * rowH - scroll >= slot: break
    result.add (p, min(slot, stop.float32 * rowH - scroll - rowH))
    last = stop

proc openSpawned(a: App, key: string) =
  ## Opens a spawned class in Classes. The object selected stays selected, without
  ## taking the page back to its own class.
  if not a.classParticles:
    a.classOther = a.className
    a.classParticles = true
  a.className = key
  let sel = a.selection
  if sel.len == 1: a.classFor = sel[0]
  a.showPanel(pkClasses)

proc drawMapTab(a: App, r: Rect) =
  let ui = a.ui
  ui.sectionTitle(rect(r.x, r.y, r.w, 26), "Layers")
  let list = rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26))
  let info = a.pieceInfo
  # Layers: geometry, then one per object type.
  var counts: CountTable[string]
  for o in a.objects: counts.inc o.tag
  var tags = toSeq(counts.keys)
  tags.sort(proc(x, y: string): int = cmp(typeName(x), typeName(y)))
  var worldCount = 0
  for pi in info:
    if pi.world: inc worldCount
  var layers = @[(GeometryLayer, "Geometry", worldCount, "pieces")]
  for t in tags: layers.add (t, typeName(t), counts[t], "objects")
  # Groups are folds inside each layer, before its loose members; a group
  # shows the layer's members it holds, groups inside it first.
  var objGid: Table[LevelObject, int32]
  var kids: Table[int32, seq[int32]]
  for g in a.groups:
    for o in g.objs: objGid[o] = g.id
    kids.mgetOrPut(g.parent, @[]).add g.id
  for k in kids.mvalues:
    k.sort(proc(x, y: int32): int = cmp(a.groupName(x).toLowerAscii, a.groupName(y).toLowerAscii))
  if a.mapReveal != nil:
    # The groups around the object shown from elsewhere open.
    var g = objGid.getOrDefault(a.mapReveal)
    while g != 0 and a.groupAt(g) >= 0:
      a.expanded.incl a.mapReveal.tag & "/" & $g
      g = a.groups[a.groupAt(g)].parent
  # A selection made elsewhere (the views, undo...): the Map tab opens the folds
  # it's in and goes to it. A group selected whole stays a closed row.
  var facePieces: HashSet[int32]
  if a.geo != nil:
    for fi in a.selFaces:
      if fi in 0 .. a.geo.faces.high: facePieces.incl a.geo.faces[fi].piece
  let selNow = a.currentSel
  let jump = not sameSel(selNow, a.mapSeen)
  if jump:
    var whole: Table[int32, bool]
    proc wholeGroup(g: int32): bool =
      if g notin whole:
        let (objs, pieces) = a.members(g)
        whole[g] = (objs.len + pieces.len > 0) and objs.allIt(it.selected) and
                   pieces.allIt(it in a.selPieces)
      whole[g]
    proc reveal(layer: string, gid: int32) =
      a.expanded.incl layer
      var chain: seq[int32]   # innermost first
      var g = gid
      while g != 0 and a.groupAt(g) >= 0 and chain.len < 1000:
        chain.add g
        g = a.groups[a.groupAt(g)].parent
      var stop = chain.len
      for k in countdown(chain.high, 0):
        if chain[k].wholeGroup:
          stop = k
          break
      for k in min(stop + 1, chain.len) .. chain.high: a.expanded.incl layer & "/" & $chain[k]
      if stop == chain.len:
        for k in chain: a.expanded.incl layer & "/" & $k
    for o in selNow.objs: reveal(o.tag, objGid.getOrDefault(o))
    for pc in selNow.pieces: reveal(GeometryLayer, a.pieceGroup(pc))
    for pc in facePieces: reveal(GeometryLayer, a.pieceGroup(pc))
  var rows: seq[TreeRow]
  var groupMembers: Table[(string, int32), seq[TreeRow]]   # layer, group -> its members there, nested too
  for layer in layers:
    let key = layer[0]
    rows.add TreeRow(layer: key, depth: 0, piece: -1)
    var direct: Table[int32, seq[TreeRow]]
    if key == GeometryLayer:
      for pc, pi in info:
        if pi.world:
          let g = a.pieceGroup(pc.int32)
          direct.mgetOrPut(if a.groupAt(g) >= 0: g else: 0, @[]).add TreeRow(layer: key, piece: pc.int32)
    else:
      for o in a.objects:
        if o.tag == key: direct.mgetOrPut(objGid.getOrDefault(o), @[]).add TreeRow(layer: key, obj: o, piece: -1)
    for gid, ms in direct:
      var g = gid
      var guard = 0
      while g != 0 and guard < 1000:
        groupMembers.mgetOrPut((key, g), @[]).add ms
        let i = a.groupAt(g)
        g = if i >= 0: a.groups[i].parent else: 0
        inc guard
    if key notin a.expanded: continue
    proc spawnRows(cls, fold: string, depth: int, above: seq[string]) =
      ## What cls spawns. A class already above is left out, as classes can loop.
      for k in a.spawnKids(cls):
        if k in above: continue
        var r = TreeRow(layer: key, depth: depth, piece: -1, cls: k)
        let path = above & k
        if a.spawnKids(k).anyIt(it notin path) and depth < 10: r.fold = fold & "/" & k
        rows.add r
        if r.fold.len > 0 and r.fold in a.expanded: spawnRows(k, r.fold, depth + 1, path)
    proc emit(gid: int32, depth: int) =
      for c in kids.getOrDefault(gid):
        if (key, c) notin groupMembers: continue
        let gr = TreeRow(layer: key, depth: depth, piece: -1, group: c)
        rows.add gr
        if gr.foldKey in a.expanded: emit(c, depth + 1)
      for m in direct.getOrDefault(gid):
        var m = m
        m.depth = depth
        let root = if m.obj != nil and m.obj.tag == "PART":
                     ParticlePrefix & m.obj.node.xpath("OSD/Class").str.strip.toLowerAscii
                   else: ""
        if root.len > 0 and a.spawnKids(root).len > 0: m.fold = "PART/#" & $m.obj.id
        rows.add m
        if m.fold in a.expanded and m.fold.len > 0: spawnRows(root, m.fold, depth + 1, @[root])
    emit(0, 1)
  let links = a.affectedLinks
  let rowH = 22'f32
  if a.mapReveal != nil:
    # Scrolled to the row of an object shown from elsewhere (the Scripts panel's Ctrl+click).
    for i, row in rows:
      if row.obj == a.mapReveal:
        a.layersCursor = i
        a.treeAnchor = i
        a.layersScroll = i.float32 * rowH - list.h / 2
    a.mapReveal = nil
  if jump:
    proc memberSel(m: TreeRow): bool =
      if m.obj != nil: m.obj.selected else: m.piece in a.selPieces or m.piece in facePieces
    var target = -1
    for i, row in rows:
      let hit = if row.depth == 0: false
                elif row.group != 0:
                  let ms = groupMembers.getOrDefault((row.layer, row.group))
                  ms.len > 0 and ms.allIt(it.memberSel)
                else: row.memberSel
      if hit:
        target = i
        break
    if target >= 0:
      a.layersCursor = target
      a.treeAnchor = target
      let top = target.float32 * rowH
      let above = rows[target].depth.float32 * rowH   # its parents stick over this much
      if top - above < a.layersScroll or top + rowH > a.layersScroll + list.h: a.layersScroll = top - list.h / 2
  # The member count is a column after the widest layer name; lock and eye sit at the right.
  var countW, nameColW = 0'f32
  for (key, name, n, unit) in layers:
    countW = max(countW, ui.textSize(&"{n} {unit}", FontSmall).x)
    nameColW = max(nameColW, ui.textSize(name).x)
  if ui.hover(list) and not ui.scrollConsumed:
    a.layersScroll += ui.wheelNotches * rowH * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  ui.scrollArea("map.layers", list, a.layersScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.layersScroll)
  a.layersScroll = clamp(a.layersScroll, 0, max(0, rows.len.float32 * rowH - list.h))
  # One Tab stop: Up/Down move through the rows, Left/Right fold a layer,
  # Space/Enter fold it or select the member.
  let listFocused = ui.tabStop("map.layers", list)
  let first = int(a.layersScroll / rowH)
  proc drawRow(i: int, rr: Rect) =
    let row = rows[i]
    let hov = ui.hover(rr) and ui.mouse.inside(list)
    if row.depth == 0:
      let key = row.layer
      var name, unit: string
      var n: int
      for (k, nm, c, u) in layers:
        if k == key: (name, n, unit) = (nm, c, u)
      let hidden = key in a.layerHidden
      let locked = key in a.layerLocked
      let open = key in a.expanded
      ui.rect(rr, if hov: colHover else: colPanelRaised)
      ui.foldArrow(open, vec2(rr.x + 10, rr.y + rowH / 2))
      let lockR = rect(rr.x + rr.w - 24, rr.y + 1, 20, 20)
      let eyeR = rect(lockR.x - 20, rr.y + 1, 20, 20)
      if ui.iconButton("layer.eye." & key, eyeR, (if hidden: "eyeoff16" else: "eye16"),
                       if hidden: "Show layer" else: "Hide layer", focusable = false):
        let before = a.visState
        if hidden: a.layerHidden.excl key else: a.layerHidden.incl key
        if key == GeometryLayer and a.geo != nil: a.geo.bump()
        a.pushVisibility(if hidden: "Show Layers" else: "Hide Layers", before)
      if ui.iconButton("layer.lock." & key, lockR, (if locked: "lock16" else: "unlock16"),
                       if locked: "Unlock layer" else: "Lock layer", toggled = locked, focusable = false):
        let before = a.visState
        if locked: a.layerLocked.excl key else: a.layerLocked.incl key
        a.pushVisibility(if locked: "Unlock Layers" else: "Lock Layers", before)
      if key != GeometryLayer:
        # The type's color, as the Entity tab's browser marks it.
        let col = LevelObject(tag: key).look.col
        ui.rect(rect(rr.x + 22, rr.y + 6, 10, 10), rgbx(col[0], col[1], col[2], 255))
      let nx = rr.x + 38
      let countR = rect(min(nx + nameColW + 10, eyeR.x - 8 - countW), rr.y, countW, rowH)
      ui.textIn(ui.ellipsize(name, countR.x - nx - 6), rect(nx, rr.y, countR.x - nx - 6, rowH),
                if hidden: colTextDisabled else: colText)
      ui.textIn(&"{n} {unit}", countR, colTextDim, FontSmall, h = RightAlign)
      let hit = rect(rr.x, rr.y, 20, rowH)
      let body = rect(rr.x + 20, rr.y, eyeR.x - rr.x - 20, rowH)
      if ui.hover(hit) and ui.pressed():
        ui.consumeClick()
        a.layersCursor = i
        if open: a.expanded.excl key else: a.expanded.incl key
      elif ui.hover(body) and ui.pressed():
        ui.consumeClick()
        a.layersCursor = i
        if ui.countClick("layer." & key) >= 2:
          # Double-click: select everything in the layer.
          if not ui.window.ctrl: a.clearSelection()
          if key == GeometryLayer:
            if a.geo != nil:
              for f in a.geo.faces:
                if f.objectId == -1 and not a.geo.pieces[f.piece].hidden: a.selPieces.incl f.piece
          else:
            for o in a.objects:
              if o.tag == key and a.pickable(o): o.selected = true
        else:
          if open: a.expanded.excl key else: a.expanded.incl key
      return
    let indent = float32(row.depth - 1) * 14
    if row.group != 0:
      # A group: folds its members of this layer; a click selects the group.
      let gi = a.groupAt(row.group)
      let ms = groupMembers.getOrDefault((row.layer, row.group))
      var allSel, allHidden = ms.len > 0
      for m in ms:
        if m.obj != nil:
          allSel = allSel and m.obj.selected
          allHidden = allHidden and m.obj.hidden
        else:
          allSel = allSel and m.piece in a.selPieces
          allHidden = allHidden and a.geo.pieces[m.piece].hidden
      let open = row.foldKey in a.expanded
      ui.rect(rr, if allSel: colAccentDim elif hov: colHover else: colPanel)
      if gi >= 0 and a.groups[gi].link in links:
        # Linked to the selection: an edit there reaches this group too.
        ui.dashedBorder(rect(rr.x + 1, rr.y + 1, rr.w - 2, rr.h - 2), colAccent, 4, 3)
      ui.foldArrow(open, vec2(rr.x + 24 + indent, rr.y + rowH / 2))
      ui.icon("folder16", vec2(rr.x + 42 + indent, rr.y + rowH / 2), if allHidden: colTextDisabled else: colTextDim)
      let eyeR = rect(rr.x + rr.w - 44, rr.y + 1, 20, 20)
      let gid = "grp." & row.layer & "." & $row.group
      if ui.iconButton("tree.eye." & gid, eyeR, (if allHidden: "eyeoff16" else: "eye16"),
                       if allHidden: "Show" else: "Hide", focusable = false):
        let before = a.visState
        for m in ms:
          if m.obj != nil:
            m.obj.hidden = not allHidden
            if m.obj.hidden: m.obj.selected = false
          else:
            a.geo.pieces[m.piece].hidden = not allHidden
            if not allHidden: a.selPieces.excl m.piece
        if row.layer == GeometryLayer: a.geo.bump()
        a.pushVisibility(if allHidden: "Show Objects" else: "Hide Objects", before)
      let n = a.linkedCount(row.group)
      let name = a.groupName(row.group)
      let detail = $ms.len & (if n > 1: &" · linked ×{n}" else: "")
      let nx = rr.x + 54 + indent
      let room = eyeR.x - nx - 6
      let nameW = min(ui.textSize(name, FontSmall).x, room)
      ui.textIn(ui.ellipsize(name, room, FontSmall), rect(nx, rr.y, room, rowH),
                if allHidden: colTextDisabled else: colText, FontSmall)
      let dw = max(0, room - nameW - 8)
      ui.textIn(ui.ellipsize(detail, dw, FontSmall), rect(nx + nameW + 8, rr.y, dw, rowH), colTextDim, FontSmall)
      let hit = rect(rr.x + 14 + indent, rr.y, 20, rowH)
      let body = rect(hit.x + hit.w, rr.y, eyeR.x - hit.x - hit.w, rowH)
      if ui.hover(hit) and ui.pressed() and ui.mouse.inside(list):
        ui.consumeClick()
        a.layersCursor = i
        if open: a.expanded.excl row.foldKey else: a.expanded.incl row.foldKey
      elif ui.hover(body) and ui.pressed() and ui.mouse.inside(list):
        ui.consumeClick()
        a.layersCursor = i
        a.treeAnchor = i
        let dbl = ui.countClick("tree." & gid) >= 2
        # The groups around this row are the open ones, so it selects as one.
        let opened = gi >= 0 and a.openTo(a.groups[gi].parent)
        let on = opened or not (ui.window.ctrl and allSel)
        if not ui.window.ctrl or a.selFaces.len > 0: a.clearSelection()
        a.groupPicked = if on: row.group else: 0
        if gi >= 0 and not a.groupLocked(a.groups[gi].parent):
          let (objs, pieces) = a.members(row.group)
          for o in objs:
            if a.pickable(o) or not on: o.selected = on
          for pc in pieces:
            if on: a.selPieces.incl pc else: a.selPieces.excl pc
        if dbl: a.frameSelection()
      return
    if row.cls.len > 0:
      # A class the object spawns: it isn't in the level, so a click opens the class.
      let name = row.cls.classLabel
      let open = row.fold in a.expanded
      ui.rect(rr, if a.classParticles and a.className == row.cls: colAccentDim elif hov: colHover else: colPanel)
      if row.fold.len > 0:
        ui.foldArrow(open, vec2(rr.x + 18 + indent, rr.y + rowH / 2))
      let nx = rr.x + 30 + indent
      let c = a.classes.getOrDefault(row.cls)
      let emitter = c != nil and c.node.xpath("Appearance/Invisible").str.strip == "true"
      let detail = if emitter: "emitter" else: "spawned"
      let dw = ui.textSize(detail, FontSmall).x
      let room = rr.x + rr.w - 12 - dw - 8 - nx
      ui.textIn(ui.ellipsize(name, room, FontSmall), rect(nx, rr.y, room, rowH), colText, FontSmall)
      ui.textIn(detail, rect(rr.x + rr.w - 12 - dw, rr.y, dw, rowH), colTextDim, FontSmall)
      ui.tip(rr, "Made by the effect while it runs, not placed in the level. Click to open it in Classes.")
      if ui.hover(rr) and ui.pressed() and ui.mouse.inside(list):
        ui.consumeClick()
        a.layersCursor = i
        if row.fold.len > 0 and ui.mouse.x < nx:
          if open: a.expanded.excl row.fold else: a.expanded.incl row.fold
        else: a.openSpawned(row.cls)
      return
    # A member: a geometry piece or an object.
    let sel = if row.obj != nil: row.obj.selected
              else: row.piece in a.selPieces or row.piece in facePieces
    let hiddenM = if row.obj != nil: row.obj.hidden else: a.geo.pieces[row.piece].hidden
    ui.rect(rr, if sel: colAccentDim elif hov: colHover else: colPanel)
    let eyeR = rect(rr.x + rr.w - 44, rr.y + 1, 20, 20)
    let id = if row.obj != nil: "obj." & $cast[int](row.obj) else: "pc." & $row.piece
    if ui.iconButton("tree.eye." & id, eyeR, (if hiddenM: "eyeoff16" else: "eye16"),
                     if hiddenM: "Show" else: "Hide", focusable = false):
      let before = a.visState
      if row.obj != nil:
        row.obj.hidden = not row.obj.hidden
        if row.obj.hidden: row.obj.selected = false
      else:
        a.geo.pieces[row.piece].hidden = not hiddenM
        if not hiddenM: a.selPieces.excl row.piece
        a.geo.bump()
      a.pushVisibility(if hiddenM: "Show Objects" else: "Hide Objects", before)
    var name, detail: string
    if row.obj != nil:
      name = row.obj.label
      detail = "#" & $row.obj.id
    else:
      let pi = info[row.piece]
      name = "Piece " & $row.piece & (if a.geo.pieces[row.piece].brush: " (brush)" else: "")
      detail = &"{pi.faces} faces" & (if pi.texture.len > 0: " · " & pi.texture else: "")
    if row.obj != nil:
      let col = row.obj.look.col
      ui.rect(rect(rr.x + 28 + indent, rr.y + 6, 10, 10), rgbx(col[0], col[1], col[2], 255))
    let nx = rr.x + 44 + indent
    let room = eyeR.x - nx - 6
    let nameW = min(ui.textSize(name, FontSmall).x, room)
    ui.textIn(ui.ellipsize(name, room, FontSmall), rect(nx, rr.y, room, rowH),
              if hiddenM: colTextDisabled else: colText, FontSmall)
    let dw = max(0, room - nameW - 8)
    ui.textIn(ui.ellipsize(detail, dw, FontSmall), rect(nx + nameW + 8, rr.y, dw, rowH), colTextDim, FontSmall)
    if row.fold.len > 0:
      # Its fold arrow; the rest of the row selects as ever.
      let open = row.fold in a.expanded
      let ar = rect(rr.x + 10 + indent, rr.y, 18, rowH)
      ui.foldArrow(open, vec2(ar.x + 8, rr.y + rowH / 2))
      ui.tip(ar, "What this effect spawns")
      if ui.hover(ar) and ui.pressed() and ui.mouse.inside(list):
        ui.consumeClick()
        a.layersCursor = i
        if open: a.expanded.excl row.fold else: a.expanded.incl row.fold
        return
    let body = rect(rr.x, rr.y, eyeR.x - rr.x, rowH)
    if ui.hover(body) and ui.pressed() and ui.mouse.inside(list):
      ui.consumeClick()
      a.layersCursor = i
      let dbl = ui.countClick("tree." & id) >= 2
      let opened = a.openRowGroup(row)
      a.groupPicked = 0
      proc setSel(rw: TreeRow, on: bool) =
        if rw.obj != nil:
          if a.pickable(rw.obj) or not on: rw.obj.selected = on
        elif not on: a.selPieces.excl rw.piece
        elif not a.pieceLocked(rw.piece): a.selPieces.incl rw.piece
      if ui.window.shiftDown and a.treeAnchor >= 0 and a.treeAnchor < rows.len:
        # Shift+click: everything between the last clicked row and this one.
        if not ui.window.ctrl: a.clearSelection()
        for k in min(a.treeAnchor, i) .. max(a.treeAnchor, i):
          if rows[k].isMember: setSel(rows[k], true)
      elif ui.window.ctrl:
        if a.selFaces.len > 0: a.clearSelection()
        setSel(row, opened or not sel)
        a.treeAnchor = i
      else:
        a.clearSelection()
        setSel(row, true)
        a.treeAnchor = i
      if dbl: a.frameSelection()
  # Parents scrolled out stick to the top; the rest scroll out of sight (and
  # reach) under them.
  let stuck = stickyRows(rows, a.layersScroll, rowH, list.h)
  var below = list.y
  for (_, y) in stuck: below = max(below, list.y + y + rowH)
  let rest = rect(list.x, below, list.w, list.y + list.h - below)
  ui.pushClip(rest)
  for i in first ..< min(rows.len, first + int(list.h / rowH) + 2):
    if not stuck.anyIt(it[0] == i):
      drawRow(i, rect(list.x, list.y + i.float32 * rowH - a.layersScroll, list.w, rowH))
  ui.popClip()
  var stuckTop = list.y
  for (i, y) in stuck:
    let rr = rect(list.x, list.y + y, list.w, rowH)
    if rr.y + rowH <= stuckTop: continue   # gone behind its parent
    ui.pushClip(rect(list.x, stuckTop, list.w, rr.y + rowH - stuckTop))
    drawRow(i, rr)
    ui.popClip()
    stuckTop = rr.y + rowH
  if stuck.len > 0: ui.rect(rect(list.x, below - 1, list.w, 1), colBorder)
  var rowRects = newSeq[Rect](rows.len)
  for i in 0 ..< rows.len:
    rowRects[i] = rect(list.x, list.y + i.float32 * rowH - a.layersScroll, list.w, rowH)
  if ui.listNav("map.layers", list, rowRects, a.layersCursor, horizontal = false):
    # Clear of the parents that will stick over it.
    let cr = rowRects[a.layersCursor]
    let above = rows[a.layersCursor].depth.float32 * rowH
    ui.revealArea(rect(cr.x, cr.y - above, cr.w, cr.h + above))
  if listFocused and a.layersCursor in 0 ..< rows.len:
    let c = a.layersCursor
    let row = rows[c]
    let fk = row.foldKey
    let open = fk.len > 0 and fk in a.expanded
    let pin = stuck.filterIt(it[0] == c)
    if pin.len > 0: ui.cursorRing(rect(list.x, list.y + pin[0][1], list.w, rowH))
    else:
      ui.pushClip(rest)
      ui.cursorRing(rowRects[c])
      ui.popClip()
    if ui.navKey("map.layers", KeyLeft):
      if open: a.expanded.excl fk
      elif row.depth > 0:
        var k = c
        while k > 0 and rows[k].depth >= row.depth: dec k
        a.layersCursor = k
    if ui.navKey("map.layers", KeyRight) and fk.len > 0: a.expanded.incl fk
    if ui.navActivate("map.layers"):
      if row.cls.len > 0: a.openSpawned(row.cls)
      elif fk.len > 0 and row.obj == nil:
        if open: a.expanded.excl fk else: a.expanded.incl fk
      elif row.obj != nil:
        discard a.openRowGroup(row)
        if a.pickable(row.obj):
          a.clearSelection()
          row.obj.selected = true
      else:
        discard a.openRowGroup(row)
        a.clearSelection()
        a.selPieces.incl row.piece
      a.treeAnchor = c
  for (i, y) in stuck:
    if rows[i].foldKey notin a.expanded:
      # Folded while stuck: the row stays where it is rather than jump out of sight.
      a.layersScroll = i.float32 * rowH - y
      break
  ui.popClip()
  ui.scrollbar("map.layers", list, a.layersScroll, rows.len.float32 * rowH)
  a.mapSeen = a.currentSel   # What was clicked here isn't a jump next frame.

proc drawLevelInfo(a: App, r: Rect) =
  ## Properties with nothing selected: the level's own settings.
  let ui = a.ui
  if a.proj == nil: return
  ui.sectionTitle(rect(r.x, r.y, r.w, 26), "Level")
  let x = r.x + 10
  let w = r.w - 20
  a.scrolledRows("props.level", rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26)), a.levelScroll,
                 proc(y0: float32): float32 =
    var y = y0
    var title = a.proj.title
    let tr = a.propName("Name", x, y, w, "The level's name in Oni's Custom Game list")
    discard ui.textField("map.title", tr, title)
    if title != a.proj.title:
      let before = a.proj.projSettings
      a.proj.title = title
      a.editProject("Rename Level", before, merge = "map.title")
    y += 30
    var skyItems = @["None"]
    for s in Skies: skyItems.add s
    for s in a.proj.customSkies: skyItems.add s
    skyItems.add "Import custom sky..."
    let sr = a.propName("Sky", x, y, w, "The skybox. A custom one comes from a folder with its six pictures (the bottom " &
                        "is optional and needs Arklite), or from one picture with Run > Add-Ons > Skybox Converter")
    let si = a.dropdown("map.sky", sr, if a.proj.sky.len > 0: a.proj.sky else: "None", skyItems)
    if si == skyItems.high:
      if a.dialog == nil:
        a.dialog = startDialog(dkOpenDir, "sky", "Folder with the sky's pictures", getHomeDir())
    elif si >= 0:
      let before = a.proj.projSettings
      a.proj.sky = if si == 0: "" else: skyItems[si]
      a.editProject("Change Sky", before)
    y += 30
    if a.proj.sky.len > 0: a.skyGradeRows(x, y, w)
    a.musicRow(x, y, w)
    a.lightingRows(x, y, w)
    if a.proj.scratch: a.propText("Source", "Made in Catwalk", x, y, w)
    else: a.propText("Source", &"Level {a.proj.levelNumber} ({a.proj.source})", x, y, w)
    a.propText("Environment", a.proj.envName, x, y, w)
    a.propText("Project folder", a.proj.dir, x, y, w, a.proj.dir)
    a.propText("Builds to", a.cfg.customLevels / a.proj.folder, x, y, w, a.cfg.customLevels / a.proj.folder)
    y)

# --- inspector: entity ---------------------------------------------------------------------

var propsContent: float32   ## Properties' object page: the content height this frame (its scrollbar).

proc commitField(a: App, o: LevelObject, f: ObjectField, value: string) =
  let v = evalField(f.value, value)
  if v == f.value: return
  if o.tag == ParticleTag and v.strip.len == 0 and
     eventParam(f.path).isVarParam:
    a.say("This action needs a variable: an empty one stops the build", true)
    return
  let before = @[o.snapshot]
  o.setField(f, v)
  o.syncFromNode()
  a.push editCmd("Edit " & f.path.split('/')[^1], @[o], before)

proc commitFieldAll(a: App, objs: seq[LevelObject], f: ObjectField, value: string) =
  ## One typed value for every selected object; arithmetic is evaluated
  ## against each object's own value.
  var changed: seq[LevelObject]
  var before: seq[string]
  for o in objs:
    for ofl in o.fields:
      if ofl.path != f.path or ofl.attr != f.attr: continue
      let v = evalField(ofl.value, value)
      if v != ofl.value:
        changed.add o
        before.add o.snapshot
        o.setField(ofl, v)
        o.syncFromNode()
      break
  if changed.len > 0:
    a.push editCmd("Edit " & f.path.split('/')[^1], changed, before)

proc isVecField(fld: ObjectField): bool =
  ## An XYZ value (a sound's Box Min and Max, a door's Center, a trigger
  ## volume's Size): edited as three number fields. Colors stay text.
  if fld.attr.len > 0 or fld.path.endsWith("Color"): return false
  let parts = strutils.splitWhitespace(fld.value)
  if parts.len != 3: return false
  for p in parts:
    try: discard parseFloat(p)
    except ValueError: return false
  true

proc isColorField(fld: ObjectField): bool =
  ## Colors ("R G B", 0–255): a flag's, a trigger's laser, a light's.
  fld.attr.len == 0 and fld.path.endsWith("Color")

proc colorTarget(a: App, objs: seq[LevelObject], fld: ObjectField, suffix = ""): ColorTarget =
  ## The color picker sets the field on every object as it goes; closing it
  ## leaves one undo step. suffix follows the color (a particle color's alpha).
  var before: seq[string]
  let label = "Edit " & fld.path.split('/')[^1]
  ColorTarget(
    live: proc(c: RGB) =
      if before.len == 0: before = snapshotObjects(objs)
      for o in objs:
        o.setField(fld, fmtRgb(c) & suffix)
        o.syncFromNode(),
    done: proc(changed: bool) =
      if before.len == 0: return
      if changed: a.push editCmd(label, objs, before)
      else:
        for i, o in objs: o.restore(before[i]))

proc commitColor(a: App, objs: seq[LevelObject], fld: ObjectField, text: string, suffix = "") =
  ## A color typed into the field, in any form parseColor takes, stored as "R G B".
  if text.strip.len == 0: return
  let (ok, c) = parseColor(text)
  if not ok:
    a.say("Not a color: " & text & " (use R G B, #RRGGBB or hsv(H, S, V))", true)
    return
  if objs.len == 1: a.commitField(objs[0], fld, fmtRgb(c) & suffix)
  elif colorComponent in 0 .. 2:
    # One channel: the others keep each object's own.
    let ch = colorComponent
    var changed: seq[LevelObject]
    var before: seq[string]
    for o in objs:
      for ofl in o.fields:
        if ofl.path != fld.path or ofl.attr != fld.attr: continue
        var (vok, v) = parseColor(ofl.value)
        if not vok: v = c
        if v[ch] != c[ch] or not vok:
          changed.add o
          before.add o.snapshot
          v[ch] = c[ch]
          o.setField(ofl, fmtRgb(v))
          o.syncFromNode()
        break
    if changed.len > 0:
      a.push editCmd("Edit " & fld.path.split('/')[^1], changed, before)
  else: a.commitFieldAll(objs, fld, fmtRgb(c))

proc commitVecAll(a: App, objs: seq[LevelObject], f: ObjectField, axis: int, value: float32) =
  ## Sets one component of an XYZ field on every object, keeping the others' own.
  var changed: seq[LevelObject]
  var before: seq[string]
  for o in objs:
    for ofl in o.fields:
      if ofl.path != f.path or ofl.attr != f.attr: continue
      var v = parseVec3(ofl.value)
      if v[axis] != value:
        changed.add o
        before.add o.snapshot
        v[axis] = value
        o.setField(ofl, fmtVec3(v))
        o.syncFromNode()
      break
  if changed.len > 0:
    a.push editCmd("Edit " & f.path.split('/')[^1], changed, before)

proc vecFields(a: App, id: string, x, y, w: float32, v: var Vec3,
               mixed = [false, false, false]): int =
  ## Three number fields (X Y Z) side by side in w, stepping by the grid. Returns the
  ## component changed, or -1.
  result = -1
  let cw = (w - 4) / 3
  for i in 0 .. 2:
    var f = v[i].float
    let rr = rect(x + i.float32 * (cw + 2), y, cw, 26)
    if a.ui.numberField(&"{id}.{i}", rr, f, a.grid.float, -100000, 100000, 2, axis = i, mixed = mixed[i]):
      v[i] = f.float32
      result = i

proc typedField(a: App, id: string, r: Rect, objs: seq[LevelObject], fld: ObjectField,
                uniq: seq[string]): bool =
  ## A field that takes a number, on/off or a pair of numbers (fieldtypes.nim), in r,
  ## for every object in objs; uniq is their values, more than one when they differ.
  ## False for a text field (nothing drawn).
  let ft = fieldType(objs[0].tag, fld.path, fld.attr)
  if ft.kind notin {fkNumber, fkToggle, fkPair}: return false
  result = true
  let ui = a.ui
  let mixed = uniq.len > 1
  proc parse(s: string): float =
    try: parseFloat(s.strip) except ValueError: 0
  let decimals = if ft.whole: 0 else: -2   # Every digit the value has.
  case ft.kind
  of fkText, fkColor, fkFlags, fkSound, fkTexture: discard
  of fkNumber:
    var v = parse(uniq[0])
    var s = uniq[0]
    if ui.numberField(id, r, v, ft.step, ft.lo, ft.hi, decimals, mixed = mixed,
                      free = if ft.free: s.addr else: nil):
      a.commitFieldAll(objs, fld, if ft.free: s else: fmtNumber(v, decimals))
  of fkToggle:
    let word = uniq[0].strip in ["true", "false"]   # A particle class's.
    var on = uniq[0].strip notin ["", "0", "false"]
    if ui.checkbox(id, vec2(r.x, r.y + 2), "", on, mixed):
      a.commitFieldAll(objs, fld, if word: $on elif on: "1" else: "0")
  of fkPair:
    # Each component set on its own, keeping the other one each object has.
    let cw = (r.w - 2) / 2
    for i in 0 .. 1:
      var vals: seq[float]
      for u in uniq:
        let p = strutils.splitWhitespace(u)
        vals.add (if i < p.len: parse(p[i]) else: 0)
      var v = vals[0]
      let rr = rect(r.x + i.float32 * (cw + 2), r.y, cw, r.h)
      if ui.numberField(&"{id}.{i}", rr, v, ft.step, ft.lo, ft.hi, -1, axis = i,
                        mixed = vals.anyIt(it != vals[0])):
        var changed: seq[LevelObject]
        var before: seq[string]
        for o in objs:
          for ofl in o.fields:
            if ofl.path != fld.path or ofl.attr != fld.attr: continue
            var p = strutils.splitWhitespace(ofl.value)
            while p.len < 2: p.add "0"
            p[i] = fmtNumber(v, -1)
            let s = p.join(" ")
            if s != ofl.value:
              changed.add o
              before.add o.snapshot
              o.setField(ofl, s)
              o.syncFromNode()
            break
        if changed.len > 0:
          a.push editCmd("Edit " & fld.path.split('/')[^1], changed, before)
  if ft.tip.len > 0: ui.tip(r, ft.tip)

# --- field dropdowns ---------------------------------------------------------------------
# A focused Entity tab field lists what the game accepts there (fieldchoices.nim):
# DropRows at a time, the rest behind a scroll. Typing filters the list; a click,
# or Up/Down then Enter, picks a value.

const
  DropRows = 12
  DropRowH = 22'f32
  SoundButtonW = 22'f32   ## A Sound object's Class rows: the preview button.

proc fieldChoices(a: App, o: LevelObject, fld: ObjectField): seq[Choice] =
  if a.catalog == nil: a.catalog = newCatalog()
  if a.proj != nil: a.catalog.refresh(a.cfg.gameData, a.proj.dir)
  a.catalog.choices(o, fld.path, fld.attr, fld.value, a.objects, a.presets)

proc dropFilter(a: App, text: string) =
  ## Until the field is edited every row shows; then the rows holding each typed word.
  if a.drop.filter == text: return
  a.drop.filter = text
  a.drop.visible.setLen 0
  let words = if text == a.drop.base: @[] else: strutils.splitWhitespace(text.toLowerAscii)
  for i, c in a.drop.items:
    if words.len > 0 and c.hint: continue
    if c.command:
      a.drop.visible.add i
      continue
    let hay = (c.value & " " & c.note).toLowerAscii
    if words.allIt(it in hay): a.drop.visible.add i
  a.drop.hi = -1
  a.drop.scroll = 0

proc openDrop(a: App, id: string, items: seq[Choice], text: string) =
  ## Shows the list with the field's value highlighted.
  let ui = a.ui
  a.drop = FieldDrop(id: id, items: items, base: text, filter: "\0", hi: -1)
  a.dropFilter(text)
  for k, i in a.drop.visible:
    if not items[i].hint and items[i].value == text:
      a.drop.hi = k
      break
  a.drop.scroll = clamp(a.drop.hi - DropRows div 2, 0, max(0, a.drop.visible.len - DropRows))
  for c in items:
    let w = if c.hint: ui.textSize(c.value, FontSmall).x
            else: ui.textSize(c.value).x + (if c.note.len > 0: ui.textSize(c.note, FontSmall).x + 16 else: 0)
    a.drop.width = max(a.drop.width, w + 18)

proc messageField(a: App, id: string, x, y, w: float32, text: var string,
                  placeholder = ""): (set[EditEvent], float32) =
  ## A console's ActivationMessage: its name and keys on one row, then a text
  ## area as wide as the panel. Returns the area's events and the rows' height.
  let ui = a.ui
  ui.textIn("ActivationMessage", rect(x, y, w, 22), colTextDim, FontSmall)
  ui.tip(rect(x, y, w, 22), "Text shown on screen when the player uses the console " &
         "(Oni's console text page). The console must be active (Flags: InitialActive).")
  ui.textIn("Enter: new line · Ctrl+Enter: done", rect(x, y, w, 22), colTextDisabled, FontSmall,
            h = RightAlign)
  let h = ui.textAreaHeight(text, w)
  (ui.textArea(id, rect(x, y + 22, w, h), text, placeholder), 22 + h + 8)

proc runDropCommand(a: App) =
  ## A command row was picked: the list closes, then it runs.
  let cmd = a.drop.command
  a.ui.focusId = ""
  a.drop.id = ""
  if cmd != nil: cmd()

proc dropShown(a: App, r: Rect, left: float32, text: var string, pick: proc(v: string)) =
  ## The open list wants drawing this frame; handles its keys (Enter takes the
  ## highlighted row).
  let ui = a.ui
  a.drop.live = true
  a.drop.anchor = r
  a.drop.left = left
  a.drop.pick = pick
  let w = a.window
  # Escape ends editing (the field commits it) with the value it had, and
  # only that: captured keeps the view shortcuts from also deselecting.
  if w.buttonPressed[KeyEscape]:
    text = a.drop.base
    ui.captured = true
  a.dropFilter(text)
  let n = a.drop.visible.len
  if n == 0: return
  var step = 0
  if w.buttonPressed[KeyDown]: step = 1
  if w.buttonPressed[KeyUp]: step = -1
  if w.buttonPressed[KeyPageDown]: step = DropRows
  if w.buttonPressed[KeyPageUp]: step = -DropRows
  if step != 0:
    let dir = sgn(step)
    var k = if a.drop.hi < 0: (if step > 0: -1 else: n) else: a.drop.hi
    k = clamp(k + step, 0, n - 1)
    while k in 0 ..< n and a.drop.items[a.drop.visible[k]].hint: k += dir
    if k notin 0 ..< n:
      # Only hints that way: the nearest value the other way.
      k = clamp(k, 0, n - 1)
      while k in 0 ..< n and a.drop.items[a.drop.visible[k]].hint: k -= dir
    if k in 0 ..< n:
      a.drop.hi = k
      if k < a.drop.scroll: a.drop.scroll = k
      if k >= a.drop.scroll + DropRows: a.drop.scroll = k - DropRows + 1
  if (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]) and a.drop.hi in 0 ..< n:
    let c = a.drop.items[a.drop.visible[a.drop.hi]]
    if c.command:
      # The field keeps its value (Enter commits it unchanged).
      text = a.drop.base
      a.runDropCommand()
    else:
      text = c.value

proc dropField(a: App, id: string, r: Rect, left: float32, text: var string,
               o: LevelObject, fld: ObjectField, pick: proc(v: string)) =
  ## Call before the field's textField: shows the list of o's field while the
  ## field is focused and handles its keys (Enter takes the highlighted row).
  let ui = a.ui
  if ui.focusId != id: return
  if a.drop.id != id:
    var items = a.fieldChoices(o, fld)
    let ft0 = objectFieldType(o, fld.path, fld.attr)
    let ambientList = (o.tag == "SNDG" and fld.path == "OSD/Class" and fld.attr.len == 0) or
                      (ft0.kind == fkSound and not ft0.impulse)
    if ambientList:
      items.insert(Choice(value: "Right-click a sound to duplicate it as your own ambient", hint: true), 0)
    if ft0.kind == fkSound:
      # Your own audio file, imported as rec_cw_<name> and put in this field.
      items.insert(Choice(value: "Import sound...", note: "a file of yours, as " & RecordingPrefix &
                          ImportedSoundPrefix & "<name>", command: true), 0)
    a.openDrop(id, items, text)
    a.drop.ambients = ambientList
    if o.tag == "SNDG" and fld.path == "OSD/Class" and fld.attr.len == 0:
      a.drop.sound = o
      a.drop.width += SoundButtonW
    if ft0.kind == fkSound:
      a.drop.soundField = true
      a.drop.impulse = ft0.impulse
      a.drop.width += SoundButtonW
      let app = a
      let target = o
      a.drop.command = proc() = app.importSoundInto(target, pick)
    # Build needs a picked recording's WAV (its channel count).
    if (a.drop.sound != nil or a.drop.soundField) and not hasSoundCache():
      a.withSounds("sounds", proc() = discard)
  a.dropShown(r, left, text, pick)

proc followSound(a: App) =
  ## A Sound object's preview follows its Class and level, and stops once
  ## it's no longer selected.
  if not soundPlaying() or a.soundObj == nil: return
  if not a.soundObj.selected or a.soundObj notin a.objects:
    stopSound()
    a.soundObj = nil
    return
  let (vol, pitch) = a.soundObj.soundLevel
  # A new Class (picked, typed, wheeled, undone) plays instead of the old one.
  let cls = a.soundObj.soundClass
  if cls != a.soundClass:
    a.soundClass = cls
    if cls.len == 0:
      stopSound()
      return
    try: playSound(cls, vol, pitch)
    except CatchableError as e:
      stopSound()
      a.say(e.msg, true)
    return
  setSoundLevel(vol, pitch)

proc drawFieldDrop(a: App) =
  ## Draws the list a field asked for this frame, over everything else.
  let ui = a.ui
  a.followSound()
  if not a.drop.live:
    a.drop.id = ""
    return
  a.drop.live = false
  let taken = ui.captured   # A menu over the list (its right-click one) has the mouse.
  let n = a.drop.visible.len
  let bar = n > DropRows
  let ar = a.drop.anchor
  let w = clamp(a.drop.width + (if bar: 12 else: 0), ar.w, max(ar.w, ar.x + ar.w - a.drop.left))
  let h = max(1, min(DropRows, n)).float32 * DropRowH + 6
  var box = rect(ar.x + ar.w - w, ar.y + ar.h + 2, w, h)
  if box.y + box.h > ui.size.y - 4 and ar.y - h - 2 >= 0: box.y = ar.y - h - 2
  ui.popupRect = box
  if ui.popupHit:
    ui.captured = true
    if bar and not ui.scrollConsumed:
      a.drop.scroll += int(round(ui.wheelNotches * 3))
      ui.scrollConsumed = true
  let track = rect(box.x + box.w - 10, box.y + 3, 6, box.h - 6)
  let thumbH = if bar: max(24'f32, track.h * DropRows / n.float32) else: track.h
  if bar:
    if ui.popupHit and ui.window.buttonPressed[MouseLeft] and
       ui.mouse.inside(rect(track.x - 3, track.y, track.w + 6, track.h)):
      ui.activeId = "fielddrop.bar"
    if ui.activeId == "fielddrop.bar" and ui.down():
      let t = (ui.mouse.y - track.y - thumbH / 2) / max(1'f32, track.h - thumbH)
      a.drop.scroll = int(round(t * (n - DropRows).float32))
  a.drop.scroll = clamp(a.drop.scroll, 0, max(0, n - DropRows))
  var picked, played = -1
  var command = false
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(box.x + 3, box.y + 3, box.w, box.h), colShadow)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  let listW = box.w - (if bar: 14 else: 6)
  if n == 0:
    ui.textIn("No match: Enter keeps what you typed", rect(box.x + 9, box.y + 3, listW - 6, DropRowH),
              colTextDisabled, FontSmall)
  for row in 0 ..< min(DropRows, n - a.drop.scroll):
    let k = a.drop.scroll + row
    let c = a.drop.items[a.drop.visible[k]]
    var rr = rect(box.x + 3, box.y + 3 + row.float32 * DropRowH, listW, DropRowH)
    if c.hint:
      ui.textIn(ui.ellipsize(c.value, rr.w - 12, FontSmall), rect(rr.x + 6, rr.y, rr.w - 12, rr.h),
                colTextDim, FontSmall)
      continue
    let over = ui.popupHit and not taken and ui.mouse.inside(rr) and ui.activeId != "fielddrop.bar"
    if k == a.drop.hi: ui.rect(rr, colAccentDim)
    elif over: ui.rect(rr, colHover)
    if c.command:
      # An action, not a value: no preview button, its name in the accent colour.
      # Its name first: the note gets what's left, if that's enough to read.
      let nameW = ui.textSize(c.value).x + 12
      let noteW = min(rr.w - 12 - nameW, ui.textSize(c.note, FontSmall).x + 14)
      ui.textIn(ui.ellipsize(c.value, rr.w - 12), rect(rr.x + 6, rr.y, rr.w - 12, rr.h), colAccent)
      if noteW >= 60:
        ui.textIn(ui.ellipsize(c.note, noteW - 14, FontSmall), rect(rr.x + rr.w - noteW, rr.y, noteW - 6, rr.h),
                  colTextDim, FontSmall, h = RightAlign)
      if over and ui.window.buttonPressed[MouseLeft]: command = true
      continue
    if (a.drop.sound != nil or a.drop.soundField) and c.value.len > 0:
      # Listen to this choice; the row's text moves right of the button.
      let pb = rect(rr.x, rr.y, SoundButtonW, rr.h)
      let on = soundPlaying(c.value)
      let overB = over and ui.mouse.inside(pb)
      if overB: ui.rect(pb, if ui.down(): colPressed else: colHover)
      ui.icon(if on: "stop16" else: "play16", pb.xy + pb.wh / 2,
              if on: colAccent elif overB: colWhite else: colTextDim)
      if overB and ui.window.buttonPressed[MouseLeft]: played = k
      rr = rect(rr.x + SoundButtonW - 4, rr.y, rr.w - SoundButtonW + 4, rr.h)
    let noteW = if c.note.len > 0: min(rr.w * 0.5, ui.textSize(c.note, FontSmall).x) + 14 else: 0'f32
    if c.value.len == 0:
      ui.textIn("(empty)", rect(rr.x + 6, rr.y, rr.w - 12 - noteW, rr.h), colTextDisabled)
    else:
      ui.textIn(ui.ellipsize(c.value, rr.w - 12 - noteW), rect(rr.x + 6, rr.y, rr.w - 12 - noteW, rr.h), colText)
    if c.note.len > 0:
      ui.textIn(ui.ellipsize(c.note, noteW - 14, FontSmall), rect(rr.x + rr.w - noteW, rr.y, noteW - 6, rr.h),
                colTextDim, FontSmall, h = RightAlign)
    if over and ui.window.buttonPressed[MouseLeft] and played != k: picked = k
    if over and a.drop.ambients and c.value.len > 0 and ui.window.buttonPressed[MouseRight]:
      a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, ambient: c.value, ambientPick: a.drop.pick)
      a.ctxPending = true
  if bar:
    let ty = track.y + (track.h - thumbH) * a.drop.scroll.float32 / (n - DropRows).float32
    ui.rect(track, colTrack)
    ui.rect(rect(track.x, ty, track.w, thumbH),
            if ui.activeId == "fielddrop.bar": colAccent else: colTextDisabled)
  ui.sk.popLayer()
  if ui.popupHit and ui.window.buttonPressed[MouseLeft]: ui.consumeClick()
  if command: a.runDropCommand()
  if played >= 0:
    let v = a.drop.items[a.drop.visible[played]].value
    if a.drop.soundField: a.previewClassSound(v, a.drop.impulse)
    else: a.previewSound(v, a.drop.sound)
  if picked >= 0:
    let pick = a.drop.pick
    let v = a.drop.items[a.drop.visible[picked]].value
    ui.focusId = ""
    a.drop.id = ""
    if pick != nil: pick(v)

proc recordingPitchRow(a: App, id: string, x: float32, y: var float32, kw, w: float32,
                       o: LevelObject, fld: ObjectField, impulse: bool) =
  ## Under a sound field holding a single recording: its pitch in this map.
  ## 1 is how Oni plays it. It changes speed along with pitch, as Oni's does.
  let ui = a.ui
  let (rec, pitch) = splitRecording(fld.value)
  let r = rect(x + kw, y, w - kw, 26)
  ui.textIn(ui.ellipsize("Recording pitch", kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
  var v = pitch
  if ui.numberField(id & ".pitch", r, v, 0.05, RecordingPitchMin, RecordingPitchMax, 2):
    let playing = soundPlaying(fld.value)
    let value = recordingValue(rec, v)
    a.commitField(o, fld, value)
    # A Sound object's preview follows its Class by itself.
    if playing and o.tag != "SNDG": a.previewClassSound(value, impulse)
  ui.tip(r, "Speed and pitch of this recording in this map: 1 plays it as Oni does, 2 is an octave up " &
            "and twice as fast. The campaign doesn't change.")
  y += 30

proc pickOne(a: App, o: LevelObject, fld: ObjectField): proc(v: string) =
  ## Per field, so the closure doesn't share the field loop's variable.
  result = proc(v: string) = a.commitField(o, fld, v)

proc pickAll(a: App, sel: seq[LevelObject], fld: ObjectField): proc(v: string) =
  result = proc(v: string) = a.commitFieldAll(sel, fld, v)

proc isLightAnimField(path: string): bool =
  ## Fields the animation editor shows; its Sound ones are ordinary fields.
  path.startsWith("OSD/Animation") and not path.startsWith("OSD/Animation/Sound")

proc drawLightObjAnims(a: App, objs: seq[LevelObject], x: float32, y: var float32, w: float32)

proc offLightSoundField(o: LevelObject, path: string): bool =
  ## A light's sound field its SoundKind doesn't use: an impact has no radii (the
  ## impulse has its own). Both take a pitch range.
  o.tag in LightTags and not o.lightSoundAmbient and
    path in ["OSD/Animation/SoundMinRadius", "OSD/Animation/SoundMaxRadius"]

proc drawMultiFields(a: App, sel: seq[LevelObject], props: Rect) =
  ## Several objects of one type: the fields they all have. A field whose
  ## values differ is blank, with the values (joined by ';') as placeholder;
  ## typing a value sets it on all of them.
  let ui = a.ui
  if a.fieldSel != sel:
    a.fieldSel = sel
    a.fieldText.clear()
    a.propsScroll = 0
  var y = props.y + 8 - a.propsScroll
  let x = props.x + 10
  let w = props.w - 20
  a.propText("Selected", &"{sel.len} objects", x, y, w)
  # Fields every object has, in the first one's order, with each object's value.
  var values: Table[string, seq[string]]
  for o in sel:
    for fld in o.fields: values.mgetOrPut(fld.path & "@" & fld.attr, @[]).add fld.value
  for fld in sel[0].fields:
    if sel[0].tag in LightTags and fld.path.isLightAnimField: continue   # drawLightObjAnims
    if sel.allIt(it.offLightSoundField(fld.path)): continue
    let key = fld.path & "@" & fld.attr
    let vals = values.getOrDefault(key)
    if vals.len != sel.len: continue
    var uniq: seq[string]
    for v in vals:
      if v notin uniq: uniq.add v
    let mixed = uniq.len > 1
    let id = "mprop." & key
    if key notin a.fieldText or ui.focusId != id: a.fieldText[key] = if mixed: "" else: fld.value
    let name = (if fld.path.startsWith("OSD/"): fld.path[4 .. ^1] else: fld.path) &
               (if fld.attr.len > 0: " ." & fld.attr else: "")
    if not matchesFilter(a.fieldFilter, name, uniq.join(" ")): continue
    if fld.path == MessageField and fld.attr.len == 0:
      let (ev, h) = a.messageField(id, x, y, w, a.fieldText[key],
                                   if mixed: "(different messages)" else: "")
      if eeCommitted in ev and not (mixed and a.fieldText[key].len == 0):
        a.commitFieldAll(sel, fld, a.fieldText[key])
      y += h
      continue
    if fld.isVecField:
      var v = parseVec3(fld.value)
      var mix = [false, false, false]
      for s in uniq:
        let u = parseVec3(s)
        for i in 0 .. 2:
          if u[i] != v[i]: mix[i] = true
      let kw = w * 0.42
      ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
      if mixed: ui.tip(rect(x, y, kw, 26), uniq.join(";"))
      let k = a.vecFields(id, x + kw, y, w - kw, v, mix)
      if k >= 0: a.commitVecAll(sel, fld, k, v[k])
      y += 30
      continue
    if fld.isColorField:
      let kw = w * 0.42
      ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
      if mixed: ui.tip(rect(x, y, kw, 26), uniq.join(";"))
      let ev = ui.colorField(id, rect(x + kw, y, w - kw, 26), a.fieldText[key], a.colorTarget(sel, fld),
                             if mixed: uniq.join(";") else: "")
      if eeCommitted in ev: a.commitColor(sel, fld, a.fieldText[key])
      y += 30
      continue
    let kw = w * 0.42
    if a.typedField(id, rect(x + kw, y, w - kw, 26), sel, fld, uniq):
      ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
      if mixed: ui.tip(rect(x, y, kw, 26), uniq.join(";"))
      y += 30
      continue
    let row = rect(x, y, w, 26)
    let scriptField = isScriptField(sel[0].tag, fld)
    let fr = rect(x + kw, y, w - kw - (if scriptField: 30 else: 0), 26)
    if row.y + row.h <= props.y or row.y >= props.y + props.h:
      discard ui.tabStop(id, fr, edit = true)  # Out of sight: Tab still gets there.
    else:
      ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
      if scriptField:
        a.scriptFieldButton(id & ".go", rect(fr.x + fr.w + 4, y, 26, 26), if mixed: "" else: uniq[0])
      let joined = uniq.join(";")
      if mixed: ui.tip(fr, joined)
      a.dropField(id, fr, x, a.fieldText[key], sel[0], fld, a.pickAll(sel, fld))
      let ev = ui.textField(id, fr, a.fieldText[key], if mixed: joined else: "")
      # A mixed field left blank keeps each object's own value.
      if eeCommitted in ev and not (mixed and a.fieldText[key].len == 0):
        a.commitFieldAll(sel, fld, a.fieldText[key])
    y += 30
  if sel[0].tag in LightTags: a.drawLightObjAnims(sel, x, y, w)
  let contentH = y + a.propsScroll - props.y
  if ui.hover(props) and not ui.scrollConsumed:
    a.propsScroll += ui.wheelNotches * RowH * 3
  a.propsScroll = clamp(a.propsScroll, 0, max(0, contentH - props.h + 20))

proc placeAtView(a: App): Vec3 =
  ## Where the entity browser puts new objects: the point the active view looks at.
  let vi = clamp(a.activeView, 0, 3)
  let cam = a.views[vi].cam
  if cam.kind != vk3D: return a.snapV(a.focus2D)
  let b = a.views[vi].viewBody
  let hit = a.pickAt(vi, b.xy + b.wh / 2)
  if hit.kind != hkNone: return a.snapV(hit.point)
  a.snapV(cam.pos + cam.forward * 200)

proc drawCornerAnims(a: App, corners: seq[(int, int)], baked: array[4, uint8], x: float32,
                     y: var float32, w: float32)
proc editCornerAnims(a: App, corners: seq[(int, int)], label: string, change: proc(m: var CornerAnim))

proc setCornerColors(a: App, corners: seq[(int, int)], label: string, ch: int, c: RGB) =
  ## Sets the corners' baked color (channel ch, or all of them for -1). Repeats
  ## of the same edit on the same corners merge into one undo step, like faceEdit.
  let key = corners.mapIt(it[0] * 4096 + it[1])
  let u = a.faceUndo
  let merge = u.label == label and u.geo == a.geo and u.version == a.geo.version and
              u.faces == key and u.depth == a.undoStack.len and a.undoStack.len > 0 and
              a.cleanAt != a.undoStack.len and a.redoStack.len == 0 and
              a.undoStack[^1].geoBefore != nil
  let before = if merge: nil else: a.geo.clone
  for (fi, k) in corners:
    for i in 0 .. 2:
      if ch < 0 or ch == i: a.geo.faces[fi].colors[k][i] = uint8(clamp(c[i], 0, 255))
  a.geo.bump()
  if merge: a.amendLast()
  else: a.push geoCmd(label, before, a.geo)
  a.faceUndo = (label, a.geo, a.geo.version, a.undoStack.len, key)

proc drawVertexColors(a: App, x, y0, w: float32): float32 =
  ## Properties in the vertex/edge/face tools: the baked light color of the
  ## selected corners, on every selected face that has a corner there.
  ## Returns where the rows end.
  let ui = a.ui
  let keys = a.selectedCornerKeys
  var corners: seq[(int, int)]     # (face, corner index)
  for fi in a.selectedFaceSet:
    let f = a.geo.faces[fi]
    for k, v in f.verts:
      if k < f.colors.len and pkey(a.geo.points[v]) in keys: corners.add (fi, k)
  corners.sort
  var y = y0
  a.propText("Selected", &"{a.selHandles.len} handle(s) · {corners.len} face corner(s)", x, y, w)
  if corners.len == 0:
    a.propNote("The selected handles touch no face corners.", x, y, w)
    return y
  # Vertex color: the corners' baked light color.
  var uniq: seq[string]
  for (fi, k) in corners:
    let c = a.geo.faces[fi].colors[k]
    let t = fmtRgb([c[0].int, c[1].int, c[2].int])
    if t notin uniq and uniq.len < 32: uniq.add t
  var text = if uniq.len == 1: uniq[0] else: ""
  let vr = a.propName("Vertex color", x, y, w, "Baked light color of the selected corners (0–255). " &
    "Hidden in the Unlit and Solid render modes. A face's Shade sets all its corners.")
  let app = a
  let target = ColorTarget(
    live: proc(c: RGB) = app.setCornerColors(corners, "Vertex color", -1, c),
    done: proc(changed: bool) = discard)
  let ev = ui.colorField("vert.color", vr, text, target, if uniq.len > 1: uniq.join(";") else: "")
  if eeCommitted in ev:
    let (ok, c) = parseColor(text)
    if ok: a.setCornerColors(corners, "Vertex " & ["red", "green", "blue"][max(0, colorComponent)],
                             colorComponent, c)
  y += 30
  # Unlit factor: how far the corners ignore their light (shownColor).
  var unlit = a.geo.faces[corners[0][0]].animAt(corners[0][1]).unlit.float
  var unlitMixed = false
  for (fi, k) in corners:
    if a.geo.faces[fi].animAt(k).unlit.float != unlit: unlitMixed = true
  let ur = a.propName("Unlit factor", x, y, w, "0 = lit by its color, 1 = its color at full brightness " &
    "(255 0 0 stays 255 0 0, gray and black go white). Applies to its animations too, in the views, " &
    "the game and on top of baked light.")
  if ui.numberField("vert.unlit", rect(ur.x, y, ur.w - 30, 26), unlit, 0.05, 0, 1,
                    decimals = 2, live = true, mixed = unlitMixed):
    let v = unlit.float32
    a.editCornerAnims(corners, "Unlit factor", proc(m: var CornerAnim) = m.unlit = v)
  # What the views and the game multiply the texture by: the baked color brightened.
  let sc = a.geo.faces[corners[0][0]].shownColor(corners[0][1])
  let ssr = rect(ur.x + ur.w - 26, y, 26, 26)
  ui.rect(ssr, colBorder)
  ui.rect(rect(ssr.x + 1, ssr.y + 1, ssr.w - 2, ssr.h - 2), pm(sc[0].int, sc[1].int, sc[2].int))
  ui.tip(ssr, &"Shown: {sc[0]} {sc[1]} {sc[2]}. The texture is multiplied by this, so a corner " &
    "never gets brighter than its texture: 255 0 0 shows only the texture's red.")
  y += 30
  # Corners that override the lights keep the color set here when lights bake.
  var nManual = 0
  for (fi, k) in corners:
    if a.geo.faces[fi].animAt(k).manual: inc nManual
  var manual = nManual == corners.len
  let mr = a.propName("Override lights", x, y, w, "On: Bake light leaves these corners' color (and " &
    "animation) as set here; the lights' light and their animations skip them. Off: the next bake relights them.")
  if ui.checkbox("vert.manual", vec2(mr.x, y + 2), "", manual,
                 mixed = nManual > 0 and nManual < corners.len):
    let on = manual
    a.editCornerAnims(corners, if on: "Override lights" else: "Use lights", proc(m: var CornerAnim) =
      m.manual = on)
  y += 30
  let c = a.geo.faces[corners[0][0]].colors[corners[0][1]]
  a.drawCornerAnims(corners, c, x, y, w)
  y

proc editCornerAnims(a: App, corners: seq[(int, int)], label: string, change: proc(m: var CornerAnim)) =
  ## Applies change to the corners' animation. Repeats of the same edit on the
  ## same corners (live typing, the color picker) merge into one undo step.
  let key = corners.mapIt(it[0] * 4096 + it[1])
  let u = a.faceUndo
  let merge = u.label == label and u.geo == a.geo and u.version == a.geo.version and
              u.faces == key and u.depth == a.undoStack.len and a.undoStack.len > 0 and
              a.cleanAt != a.undoStack.len and a.redoStack.len == 0 and
              a.undoStack[^1].geoBefore != nil
  let before = if merge: nil else: a.geo.clone
  for (fi, k) in corners:
    var m = a.geo.faces[fi].animAt(k)
    change(m)
    a.geo.faces[fi].setAnim(k, m)
  a.geo.bump()
  if merge: a.amendLast()
  else: a.push geoCmd(label, before, a.geo)
  a.faceUndo = (label, a.geo, a.geo.version, a.undoStack.len, key)

type AnimEdit = proc(label: string, change: proc(m: var CornerAnim))

const AnimPresets = [
  ("Candle", "A soft, restless glow: small smooth dips.",
   CornerAnim(mode: amFlicker, interp: aiSmooth, period: 0.12, low: 0, high: 0.35, faultLen: 1)),
  ("Failing", "Works, then now and then sputters for a moment: a tube about to go.",
   CornerAnim(mode: amFlicker, interp: aiStep, period: 0.05, low: 0.5, high: 1, stability: 0.85, faultLen: 0.8)),
  ("Dying", "Mostly out, with short bursts of light.",
   CornerAnim(mode: amFlicker, interp: aiStep, period: 0.07, low: 0.6, high: 1, stability: 0.25, faultLen: 2)),
  ("Alarm", "Fades out and back, steadily.",
   CornerAnim(mode: amPulse, interp: aiSmooth, period: 1.5, low: 0, high: 1, faultLen: 1))]
  ## Starting points for the light animation block: Candle goes toward half
  ## the base color, the others toward black.

proc drawLightAnim(a: App, idp: string, m0: CornerAnim, mixed: bool, base: array[3, uint8],
                   forLight: bool, x: float32, y: var float32, w: float32, edit: AnimEdit) =
  ## Light animation, the same for selected corners (Vertex tool) and lights
  ## (Entity tab): flicker or pulse between the base color (a corner's baked
  ## color, a light's Color) and another one, in the game (Arklite). m0 is
  ## the first one's; edit changes them all.
  let ui = a.ui
  let what = if forLight: "light" else: "corner"
  let baseName = if forLight: "its Color" else: "the baked color"
  a.propGroup("Light animation" & (if mixed: " (mixed: shows the first)" else: ""), x, y, w)
  const modes = [("Off", amNone), ("Pulse", amPulse), ("Flicker", amFlicker)]
  var modeName = "Off"
  for (name, mode) in modes:
    if m0.mode == mode: modeName = name
  let mr = a.propName("Mode", x, y, w, "Off: the " & what & " keeps " & baseName & ". " &
    "Pulse: fades to the other color and back once per period. Flicker: a random level between " &
    baseName & " and the other color every period (ones with the same period, offset and seed flicker together).")
  let mi = a.dropdown(idp & ".mode", mr, modeName, modes.mapIt(it[0]))
  if mi >= 0 and modes[mi][1] != m0.mode:
    let mode = modes[mi][1]
    let fromOff = m0.mode == amNone
    let dim = [uint8(base[0].int div 5), uint8(base[1].int div 5), uint8(base[2].int div 5)]
    edit("Light animation", proc(m: var CornerAnim) =
      if fromOff or m.period <= 0: m = m.withDefaults(mode, dim)
      else: m.mode = mode)
  y += 30
  # Presets: the whole animation but its offset and seed (which keep neighbours apart).
  var presetTip = "Sets every setting below but Offset and Seed."
  for (name, desc, pm) in AnimPresets: presetTip.add " " & name & ": " & desc
  let pr = a.propName("Preset", x, y, w, presetTip)
  let pk = a.dropdown(idp & ".preset", pr, "Choose...", AnimPresets.mapIt(it[0]))
  if pk >= 0:
    let (name, _, pm) = AnimPresets[pk]
    let color = if name == "Candle": [base[0] div 2, base[1] div 2, base[2] div 2] else: [0'u8, 0, 0]
    edit("Light animation preset", proc(m: var CornerAnim) =
      let manual = m.manual
      let offset = m.offset
      let seed = m.seed
      m = pm
      m.color = color
      m.manual = manual
      m.offset = offset
      m.seed = seed)
  y += 30
  let foot = if forLight: "Plays in the game with Arklite, on the corners its light reaches once baked, " &
                          "and in Catwalk with Realtime preview on."
             else: "Plays in the game with Arklite, and in Catwalk with Realtime preview on."
  if m0.mode == amNone:
    a.propNote(foot, x, y, w)
    return

  let id = idp & ".color"
  let mc = [m0.color[0].int, m0.color[1].int, m0.color[2].int]
  if ui.focusId != id and not pickerOpen(id): a.fieldText[id] = fmtRgb(mc)
  let target = ColorTarget(
    live: proc(c: RGB) =
      edit("Light animation color", proc(m: var CornerAnim) =
        m.color = [uint8(clamp(c[0], 0, 255)), uint8(clamp(c[1], 0, 255)), uint8(clamp(c[2], 0, 255))]),
    done: proc(changed: bool) = discard)
  let cr = a.propName("Other color", x, y, w, "The color the " & what & " goes to" &
    (if forLight: " (times Intensity)" else: "") & "; " & baseName & " is the other end.")
  let ev = ui.colorField(id, cr, a.fieldText[id], target)
  if eeCommitted in ev:
    let (ok, c) = parseColor(a.fieldText[id])
    if ok: target.live(c)
  y += 30

  template numRow(tLabel, tKey, tTip: string, tValue: float32, tStep, tLo, tHi: float, tDecimals: int,
                  tSet: proc(m: var CornerAnim, v: float32)) =
    let vr = a.propName(tLabel, x, y, w, tTip)
    var v = tValue.float
    if ui.numberField(idp & "." & tKey, vr, v, tStep, tLo, tHi, decimals = tDecimals, live = true):
      let f = v.float32
      let setter = tSet
      edit("Light animation " & tKey, proc(m: var CornerAnim) = setter(m, f))
    y += 30
  numRow("Period (s)", "period", if m0.mode == amPulse: "Seconds for one pulse, there and back."
                                 else: "Seconds between flicker changes.",
         m0.period, 0.05, 0.01, 600, 2, proc(m: var CornerAnim, v: float32) = m.period = v)
  numRow("Offset (s)", "offset", "Shifts the timing so neighbouring lights don't move in step.",
         m0.offset, 0.05, -600, 600, 2, proc(m: var CornerAnim, v: float32) = m.offset = v)

  # Range: how far toward the other color, as two fields on one row.
  let rr = a.propName("Range", x, y, w, "How far toward the other color it goes, from Min to Max: " &
    "0 is " & baseName & ", 1 the other color. " &
    (if m0.mode == amPulse: "A pulse goes from Min to Max and back."
     else: "Each flicker step picks a level between them."))
  let half = (rr.w - 2) / 2
  var lo = m0.low.float
  if ui.numberField(idp & ".min", rect(rr.x, y, half, 26), lo, 0.05, 0, 1, decimals = 2, live = true):
    let f = lo.float32
    edit("Light animation range", proc(m: var CornerAnim) =
      m.low = f
      m.high = max(m.high, f))
  ui.tip(rect(rr.x, y, half, 26), "Min: the least it goes toward the other color.")
  var hi = m0.high.float
  if ui.numberField(idp & ".max", rect(rr.x + half + 2, y, half, 26), hi, 0.05, 0, 1, decimals = 2, live = true):
    let f = hi.float32
    edit("Light animation range", proc(m: var CornerAnim) =
      m.high = f
      m.low = min(m.low, f))
  ui.tip(rect(rr.x + half + 2, y, half, 26), "Max: the most it goes toward the other color.")
  y += 30

  if m0.mode == amFlicker:
    numRow("Seed", "seed", "Picks the random pattern: " & what & "s with different seeds flicker and fail " &
           "at different moments, with the same settings.",
           m0.seed.float32, 1, 0, MaxAnimSeed.float, 0, proc(m: var CornerAnim, v: float32) = m.seed = v.uint32)
    # A malfunctioning light: it works (base color) most of the time, and fails in runs.
    numRow("Stability", "stability", "Share of the time the " & what & " works normally, at " & baseName &
           ": 0 flickers all the time, 0.9 fails now and then. Fault length sets how long each run lasts.",
           m0.stability, 0.05, 0, 1, 2, proc(m: var CornerAnim, v: float32) = m.stability = v)
    if m0.stability > 0:
      numRow("Fault (s)", "fault length", "Seconds each run lasts: a failure (flickering), or a stretch " &
             "working. Short: brief sputters; long: it goes out for a while. At least one period.",
             m0.faultLen, 0.1, 0, 600, 2, proc(m: var CornerAnim, v: float32) = m.faultLen = v)

  const interps = [("Smooth", aiSmooth), ("Linear", aiLinear), ("Step", aiStep)]
  var interpName = "Smooth"
  for (name, interp) in interps:
    if m0.interp == interp: interpName = name
  let ir = a.propName("Interpolation", x, y, w, "Smooth: eases in and out of each change. " &
    "Linear: changes at a steady rate. Step: jumps at once (a hard flicker, or a blink for Pulse).")
  let ii = a.dropdown(idp & ".interp", ir, interpName, interps.mapIt(it[0]))
  if ii >= 0:
    let interp = interps[ii][1]
    edit("Light animation interpolation", proc(m: var CornerAnim) = m.interp = interp)
  y += 30
  a.propNote(foot, x, y, w)

proc drawCornerAnims(a: App, corners: seq[(int, int)], baked: array[4, uint8], x: float32,
                     y: var float32, w: float32) =
  ## Light animation of the selected corners (drawLightAnim).
  let m0 = a.geo.faces[corners[0][0]].animAt(corners[0][1])
  var mixed = false
  for (fi, k) in corners:
    if a.geo.faces[fi].animAt(k) != m0: mixed = true
  a.drawLightAnim("vert.anim", m0, mixed, [baked[0], baked[1], baked[2]], false, x, y, w,
                  proc(label: string, change: proc(m: var CornerAnim)) = a.editCornerAnims(corners, label, change))

proc editLightAnims(a: App, objs: seq[LevelObject], label: string, change: proc(m: var CornerAnim)) =
  ## Applies change to the lights' Animation. Repeats of the same edit on the
  ## same lights (live typing, the color picker) merge into one undo step.
  let merge = a.undoStack.len > 0 and a.undoStack[^1].kind == ckEdit and a.undoStack[^1].label == label and
              a.undoStack[^1].objs == objs and a.cleanAt != a.undoStack.len and a.redoStack.len == 0
  let before = if merge: @[] else: snapshotObjects(objs)
  for o in objs:
    var m = o.lightAnim
    change(m)
    o.setLightAnim(m)
  if merge:
    for i, o in objs: a.undoStack[^1].after[i] = o.snapshot
    a.amendLast()
  else: a.push editCmd(label, objs, before)

proc drawLightObjAnims(a: App, objs: seq[LevelObject], x: float32, y: var float32, w: float32) =
  ## The Animation of the selected lights (drawLightAnim), in place of its fields.
  if not matchesFilter(a.fieldFilter, "Light animation Animation", ""): return
  let m0 = objs[0].lightAnim
  var mixed = false
  for o in objs:
    if o.lightAnim != m0: mixed = true
  var base = [255'u8, 255, 255]
  let c = strutils.splitWhitespace(objs[0].node.xpath("OSD/Color").str)
  if c.len == 3:
    for i in 0 .. 2:
      try: base[i] = uint8(clamp(parseFloat(c[i]), 0, 255))
      except ValueError: discard
  a.drawLightAnim("light.anim." & $objs[0].id, m0, mixed, base, true, x, y, w,
                  proc(label: string, change: proc(m: var CornerAnim)) = a.editLightAnims(objs, label, change))

proc openClass(a: App, name: string): LevelObject =
  ## Character class name as the project has it, loaded the first time; nil
  ## when level 0 has no such class or its classes aren't extracted yet.
  if name in a.classes: return a.classes[name]
  let particle = name.startsWith(ParticlePrefix)
  let plain = if particle: name[ParticlePrefix.len .. ^1] else: name
  if a.proj == nil or name.len == 0 or
     (if particle: not hasParticleCache() or not fileExists(originalParticlePath(plain))
      else: not hasClassCache() or not fileExists(originalClassPath(plain))): return nil
  try:
    let o = if particle: loadParticle(a.proj, plain) else: loadClass(a.proj, plain)
    a.classOrig[name] = if particle: originalParticle(plain) else: originalClass(plain)
    a.files.add o.file
    result = o
  except CatchableError as e:
    a.say("Could not read class " & name & ": " & e.msg, true)
  a.classes[name] = result   # nil after an error: not tried again

proc editedClasses(a: App): HashSet[string] =
  ## Classes whose values differ from level 0's, now.
  if not a.classOnDiskRead and a.proj != nil:
    a.classOnDiskRead = true
    try:
      a.classOnDisk = a.proj.editedClasses.toHashSet
      for n in a.proj.editedParticles: a.classOnDisk.incl ParticlePrefix & n
    except CatchableError: discard
    a.classMarkStamp = (-1, -1, -1)
  let stamp = (a.pushCount, a.undoStack.len, a.redoStack.len)
  if stamp != a.classMarkStamp:
    a.classMarkStamp = stamp
    a.classMarks = a.classOnDisk
    for n, o in a.classes:
      if o == nil: continue
      if o.snapshot != a.classOrig[n]: a.classMarks.incl n else: a.classMarks.excl n
  a.classMarks

proc nothingSelected(a: App): bool =
  ## No object, piece, face or vertex handle: Properties shows the level.
  a.selection.len == 0 and a.selPieces.len == 0 and a.selFaces.len == 0 and a.selHandles.len == 0

proc drawObjectsPage(a: App, r: Rect) =
  ## Properties for selected objects: the type as the header, then one row per
  ## property (several of one type: the fields they share).
  let ui = a.ui
  let sel = a.selection
  let sameType = sel.len > 1 and sel.allIt(it.tag == sel[0].tag)
  ui.sectionTitle(rect(r.x, r.y, r.w, 26),
                  if sel.len == 1 or sameType: typeName(sel[0].tag) else: "Objects")
  var props = rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26))
  if sel.len == 1 or sameType:
    # Above the scrolled fields, so it stays put while they scroll.
    discard ui.textField("entity.fieldFilter", rect(props.x + 8, props.y + 6, props.w - 16, 26),
                         a.fieldFilter, "Search fields...")
    props = rect(props.x, props.y + 38, props.w, max(0'f32, props.h - 38))
  propsContent = 0
  if ui.hover(props) and not ui.scrollConsumed and sel.len > 1 and not sameType:
    a.propsScroll += ui.wheelNotches * RowH * 3
  ui.scrollArea("props", props, a.propsScroll)
  ui.pushClip(props)
  ui.scrollIntoView(a.propsScroll)
  if sameType:
    a.fieldObj = nil
    a.drawMultiFields(sel, props)
  elif sel.len > 1:
    a.fieldSel = @[]
    a.fieldObj = nil
    var counts: CountTable[string]
    for o in sel: counts.inc typeName(o.tag)
    let x = props.x + 10
    let w = props.w - 20
    var y = props.y + 8 - a.propsScroll
    a.propText("Selected", &"{sel.len} objects", x, y, w)
    for k, v in counts: a.propText(k, $v, x, y, w)
    let contentH = y + a.propsScroll - props.y + 12
    a.propsScroll = clamp(a.propsScroll, 0, max(0, contentH - props.h))
    propsContent = contentH
  else:
    a.fieldSel = @[]
    let o = sel[0]
    if a.fieldObj != o:
      a.fieldObj = o
      a.fieldText.clear()
      a.propsScroll = 0
    var y = props.y + 8 - a.propsScroll
    let x = props.x + 10
    let w = props.w - 20
    a.propText("Name", o.label & "   #" & $o.id, x, y, w)
    if o.tag == "CHAR":
      # Health a character starts with: its class's plus AdditionalHealth
      # (ONrGameState_NewCharacter, 0x4dac50; at least 1).
      let cls = o.node.xpath("OSD/Class").str.strip
      let co = a.openClass(cls)
      var line = cls
      if co != nil:
        let base = co.node.xpath("Health").str.strip
        let add = o.node.xpath("OSD/AdditionalHealth").str.strip
        try: line = &"{max(1, parseInt(base) + parseInt(add))} ({base} + {add})"
        except ValueError: discard
      let vr = a.propName("Health", x, y, w, "Health it starts with: its class's Health plus " &
                          "AdditionalHealth. The difficulty setting scales it further.")
      let lr = rect(vr.x, vr.y, vr.w - 92, vr.h)
      ui.textIn(ui.ellipsize(line, lr.w - 6, FontSmall), lr, colText, FontSmall)
      let br = rect(vr.x + vr.w - 88, y, 88, 26)
      if ui.textButton("entity.editClass", br, "Edit class"):
        a.showPanel(pkClasses)
        a.classFor = nil   # Follow this character's class.
      ui.tip(br, "Edit " & cls & ", the values every character of that class starts with")
      y += 30
    if o.tag == "PART":
      let cls = o.node.xpath("OSD/Class").str.strip
      let vr = a.propName("Behavior", x, y, w, "Lifetime, look, emitters and everything else this class does")
      let br = rect(vr.x, y, min(vr.w, 88), 26)
      if ui.textButton("entity.editParticle", br, "Edit class"):
        a.showPanel(pkClasses)
        a.classFor = nil   # Follow this particle's class.
      ui.tip(br, "Edit " & cls & " for this level: every Particle object of that class changes")
      y += 30
    if a.hasGeometry(o): a.propText("Geometry", "Owns level geometry (moves with it)", x, y, w)
    if o.tag in LightTags:
      var on = o.lightOn
      let vr = a.propName("Enabled", x, y, w, "Off: the bake leaves this light out (it stays in the " &
        "project). With Bake automatically on, flip it to compare the lighting with and without it.")
      if ui.checkbox("entity.lightOn." & $o.id, vec2(vr.x, y + 2), "", on):
        let before = @[o.snapshot]
        var e = o.node.xpath("OSD/Enabled")
        if e == nil:
          e = newElement("Enabled")
          o.node.xpath("OSD").insert(e, 0)
        e.setText(if on: "1" else: "0")
        o.file.dirty = true
        a.push editCmd((if on: "Enable " else: "Disable ") & typeName(o.tag), @[o], before)
      y += 30
    proc vecRow(title: string, v: var Vec3, step: float, isRot: bool): bool =
      let vr = a.propName(title, x, y, w)
      let cw = (vr.w - 4) / 3
      for i in 0 .. 2:
        var f = v[i].float
        let rr = rect(vr.x + i.float32 * (cw + 2), y, cw, 26)
        if ui.numberField(&"prop.{title}.{i}.{o.id}", rr, f, step, -100000, 100000, (if isRot: 1 else: 2), axis = i):
          v[i] = f.float32
          result = true
      y += 30
    var p = o.pos
    var rr = o.rot
    let posChanged = matchesFilter(a.fieldFilter, "Position", "") and
                     vecRow("Position", p, a.grid.float, false)
    let rotChanged = matchesFilter(a.fieldFilter, "Rotation", "") and
                     vecRow("Rotation", rr, 15, true)
    if posChanged or rotChanged:
      # Taken only now (o and the geometry haven't changed yet): a level's
      # geometry is too big to copy every frame.
      let objBefore = @[o.snapshot]
      let geoBefore = if a.hasGeometry(o): a.geo.clone else: nil
      a.setPose(o, p, rr)
      a.push editCmd(if posChanged: "Move" else: "Rotate", @[o], objBefore, geoBefore, a.geo)
    # Key / value table.
    var shown = 0
    for fld in o.fields:
      let key = fld.path & "@" & fld.attr
      let name = (if fld.path.startsWith("OSD/"): fld.path[4 .. ^1] else: fld.path) &
                 (if fld.attr.len > 0: " ." & fld.attr else: "")
      if o.tag in LightTags and fld.path.isLightAnimField: continue   # drawLightObjAnims
      if o.offLightSoundField(fld.path): continue
      if not matchesFilter(a.fieldFilter, name, fld.value): continue
      inc shown
      if fld.path == MessageField and fld.attr.len == 0:
        if key notin a.fieldText or ui.focusId != "prop." & key: a.fieldText[key] = fld.value
        let (ev, h) = a.messageField("prop." & key, x, y, w, a.fieldText[key])
        if eeCommitted in ev: a.commitField(o, fld, a.fieldText[key])
        y += h
        continue
      if fld.isVecField:
        var v = parseVec3(fld.value)
        let kw = w * 0.42
        ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
        if a.vecFields(&"prop.{key}.{o.id}", x + kw, y, w - kw, v) >= 0: a.commitField(o, fld, fmtVec3(v))
        y += 30
        continue
      if fld.isColorField:
        let kw = w * 0.42
        let id = &"prop.{key}.{o.id}"
        if key notin a.fieldText or ui.focusId != id: a.fieldText[key] = fld.value
        ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
        let ev = ui.colorField(id, rect(x + kw, y, w - kw, 26), a.fieldText[key], a.colorTarget(@[o], fld))
        if eeCommitted in ev: a.commitColor(@[o], fld, a.fieldText[key])
        y += 30
        continue
      let kw = w * 0.42
      if o.tag in LightTags and fld.path == "OSD/Enabled" and fld.attr.len == 0:
        dec shown   # The Enabled box above.
        continue
      if a.typedField(&"prop.{key}.{o.id}", rect(x + kw, y, w - kw, 26), @[o], fld, @[fld.value]):
        ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
        y += 30
        continue
      if key notin a.fieldText or ui.focusId != "prop." & key: a.fieldText[key] = fld.value
      let row = rect(x, y, w, 26)
      let soundClass = o.tag == "SNDG" and fld.path == "OSD/Class" and fld.attr.len == 0
      let scriptField = isScriptField(o.tag, fld)
      let fr = rect(x + kw, y, w - kw - (if soundClass or scriptField: 30 else: 0), 26)
      if row.y + row.h <= props.y or row.y >= props.y + props.h:
        discard ui.tabStop("prop." & key, fr, edit = true)  # Out of sight: Tab still gets there.
      else:
        ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
        if scriptField:
          a.scriptFieldButton("prop.go." & key, rect(fr.x + fr.w + 4, y, 26, 26), a.fieldText[key])
        if soundClass:
          let on = soundPlaying(fld.value)
          if ui.iconButton("prop.soundplay", rect(fr.x + fr.w + 4, y, 26, 26),
                           if on: "stop16" else: "play16",
                           if on: "Stop the preview" else: "Listen to this sound as the game plays it",
                           fld.value.len > 0 or on):
            a.previewSound(fld.value, o)
          # The wheel steps through the Class choices (a playing preview follows).
          if ui.hover(fr) and ui.scroll() != 0:
            let dir = if ui.scroll() > 0: 1 else: -1
            ui.scrollConsumed = true
            var vals: seq[string]
            for c in a.fieldChoices(o, fld):
              if not c.hint and c.value.len > 0 and c.value notin vals: vals.add c.value
            if vals.len > 0:
              let cur = (if fld.value.strip.startsWith(RecordingPrefix):
                           recordingValue(splitRecording(fld.value).name, 1)
                         else: fld.value.strip).toLowerAscii
              var k = -1
              for i, v in vals:
                if v.toLowerAscii == cur: k = i
              k = if k < 0: (if dir > 0: 0 else: vals.high) else: clamp(k + dir, 0, vals.high)
              if ui.focusId == "prop." & key:
                ui.focusId = ""
                a.drop.id = ""
              a.fieldText[key] = vals[k]
              a.commitField(o, fld, vals[k])
        a.dropField("prop." & key, fr, x, a.fieldText[key], o, fld, a.pickOne(o, fld))
        let ev = ui.textField("prop." & key, fr, a.fieldText[key])
        if eeCommitted in ev: a.commitField(o, fld, a.fieldText[key])
      if soundClass and fld.value.strip.startsWith(RecordingPrefix):
        y += 30
        a.recordingPitchRow("prop." & key, x, y, kw, w, o, fld, false)
        y -= 30   # The field's own row is added below.
      y += 30
    if o.tag in LightTags:
      let before = y
      a.drawLightObjAnims(@[o], x, y, w)
      if y != before: inc shown
    if shown == 0:
      ui.textIn("No field matches", rect(x, y, w, 22), colTextDim, FontSmall)
      y += 28
    # After the fields, so a wheel over a number field steps it instead.
    # Measured before the wheel moves propsScroll (y was laid out with the old one).
    let contentH = y + a.propsScroll - props.y
    if ui.hover(props) and not ui.scrollConsumed:
      a.propsScroll += ui.wheelNotches * RowH * 3
    a.propsScroll = clamp(a.propsScroll, 0, max(0, contentH - props.h + 20))
    propsContent = contentH + 20
  ui.popClip()
  ui.scrollbar("props", props, a.propsScroll, propsContent)

proc drawEntityBrowser(a: App, br: Rect) =
  ## Presets in collapsible groups: drag one into a view, or click to place it.
  let ui = a.ui
  let tiles = a.entityPreview > 0
  if tiles and a.libraryLoading == nil and not a.presetsCurrent and hasPreviews(): a.loadPresets()
  let lib = a.libraryLoading
  let rendering = tiles and not hasPreviews() and libraryBusyElsewhere()
  ui.sectionTitle(rect(br.x, br.y, br.w, 26),
    if rendering: "Another Catwalk is building the entity library..."
    else: "Drag into a view, or click to place")
  const SliderW = 84'f32
  discard ui.textField("entity.filter", rect(br.x + 8, br.y + 32, br.w - SliderW - 28, 26), a.entityFilter, "Search...")
  # Preview size, like TrenchBroom's: all the way left is the compact list.
  let sr = rect(br.x + br.w - SliderW - 12, br.y + 32, SliderW, 26)
  discard ui.slider("entity.preview", sr, a.entityPreview, 0, 1, 0.125)
  ui.tip(sr, "Preview size")
  # The library on its way: its furniture, consoles, doors, triggers and previews.
  var top = br.y + 64
  if lib != nil:
    a.progressBar(rect(br.x + 10, top + 2, br.w - 20, 6), lib.loadProgress)
    ui.textIn(ui.ellipsize(lib.loadState, br.w - 20, FontSmall), rect(br.x + 10, top + 10, br.w - 20, 18),
              colTextDim, FontSmall)
    top += 32
  let list = rect(br.x, top, br.w, br.y + br.h - top)
  let filter = a.entityFilter.strip.toLowerAscii
  var groups: seq[string]
  var members: Table[string, seq[int]]
  for i, p in a.presets:
    if not p.matches(filter): continue
    if p.group notin members: groups.add p.group
    members.mgetOrPut(p.group, @[]).add i
  # Groups under their category's heading (the category of the group's first entry).
  proc groupCategory(g: string): int = categoryIndex(a.presets[members[g][0]].tag)
  groups.sort(proc(x, y: string): int = cmp(groupCategory(x), groupCategory(y)))   # stable
  const CatH = 24'f32
  const HeadH = 24'f32
  const LabelH = 18'f32
  # List: two columns of names. Tiles: square previews with the name below.
  let tile = if tiles: 56'f32 + (ThumbSize - 56).float32 * ((a.entityPreview - 0.125) / 0.875).float32
             else: 0'f32
  let cols = if tiles: max(1, int((list.w - 8) / (tile + 4))) else: 2
  # Tiles share out the row's spare width; the preview stays square, centered.
  let cw = if tiles: (list.w - 8 - (cols - 1).float32 * 4) / cols.float32 else: (list.w - 12) / cols.float32
  let cellH = if tiles: tile + LabelH + 4 else: 26'f32
  # Layout first (for the scroll range), drawing below.
  var contentH = 0'f32
  for gi, g in groups:
    if gi == 0 or groupCategory(g) != groupCategory(groups[gi - 1]): contentH += CatH
    contentH += HeadH + 2
    if g in a.browserOpen or filter.len > 0:
      contentH += ((members[g].len + cols - 1) div cols).float32 * cellH + 4
  contentH += 40
  if ui.hover(list) and not ui.scrollConsumed:
    a.entityScroll += ui.wheelNotches * 26 * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  ui.scrollArea("entity.list", list, a.entityScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.entityScroll)
  a.entityScroll = clamp(a.entityScroll, 0, max(0, contentH - list.h))
  # One Tab stop: the arrow keys move through group headers and entries,
  # Space/Enter fold a group or place the entry.
  let listFocused = ui.tabStop("entity.list", list)
  var navItems: seq[Rect]
  var navPreset: seq[int]   # -1: a group header
  var navGroup: seq[string]
  let inList = ui.mouse.inside(list)
  var wanted: seq[Preset]   # Visible previews not loaded yet.
  var y = list.y + 2 - a.entityScroll
  for gi, g in groups:
    let cat = groupCategory(g)
    if gi == 0 or cat != groupCategory(groups[gi - 1]):
      let cr = rect(list.x + 8, y, list.w - 16, CatH)
      if cr.y + cr.h > list.y and cr.y < list.y + list.h:
        ui.textIn(if cat < Categories.len: Categories[cat].name else: "Other", cr, colAccent, FontSmall,
                  v = BottomAlign)
      y += CatH
    let open = g in a.browserOpen or filter.len > 0
    let hr = rect(list.x + 4, y, list.w - 8, HeadH)
    let hk = navItems.len
    navItems.add hr
    navPreset.add -1
    navGroup.add g
    if hr.y + hr.h > list.y and hr.y < list.y + list.h:
      let hov = ui.hover(hr) and inList
      ui.rect(hr, if hov: colHover else: colPanelRaised)
      ui.foldArrow(open, vec2(hr.x + 10, hr.y + HeadH / 2))
      ui.textIn(g, rect(hr.x + 22, hr.y, hr.w - 22, HeadH), colText, FontSmall)
      let tw = ui.textSize(g, FontSmall).x
      ui.textIn($members[g].len, rect(hr.x + 30 + tw, hr.y, hr.w, HeadH), colTextDim, FontSmall)
      if hov and ui.pressed() and filter.len == 0:
        ui.consumeClick()
        a.entityCursor = hk
        if open: a.browserOpen.excl g else: a.browserOpen.incl g
    y += HeadH + 2
    if not open: continue
    let ids = members[g]
    for k, i in ids:
      let p = a.presets[i]
      let cell = rect(list.x + 4 + (k mod cols).float32 * (cw + 4), y + (k div cols).float32 * cellH, cw, cellH - 2)
      let ck = navItems.len
      navItems.add cell
      navPreset.add i
      navGroup.add g
      let visible = cell.y + cell.h > list.y and cell.y < list.y + list.h
      let hov = visible and ui.hover(cell) and inList
      if visible:
        let col = LevelObject(tag: p.tag).look.col
        let typeCol = rgbx(col[0], col[1], col[2], 255)
        ui.rect(cell, if hov: colHover else: colPanelRaised)
        if tiles:
          let img = rect(cell.x + (cw - tile) / 2, cell.y, tile, tile)
          let key = a.previewKey(p)
          if key.len > 0 and key in ui.sk.atlas.entries:
            let e = ui.sk.atlas.entries[key]
            ui.sk.drawQuad(img.xy + vec2(2, 2), vec2(tile - 4, tile - 4), vec2(e.x.float32, e.y.float32),
                           vec2(e.width.float32, e.height.float32), rgbx(255, 255, 255, 255))
          else:
            if key.len > 0: wanted.add p
            # No model: the type's color, as the views draw the object.
            let b = tile * 0.3
            ui.rect(rect(img.x + (tile - b) / 2, img.y + (tile - b) / 2, b, b), typeCol)
          ui.textIn(ui.ellipsize(p.label, cell.w - 6, FontSmall), rect(cell.x + 3, cell.y + tile, cell.w - 6, LabelH),
                    colText, FontSmall, h = CenterAlign)
        else:
          ui.rect(rect(cell.x + 6, cell.y + 7, 10, 10), typeCol)
          ui.textIn(ui.ellipsize(p.label, cell.w - 26, FontSmall), rect(cell.x + 22, cell.y, cell.w - 22, cell.h),
                    colText, FontSmall)
        var tip = p.label
        if p.detail.len > 0: tip.add " · " & p.detail
        if not p.generic: tip.add " (" & typeName(p.tag) & ")"
        if p.prefab.len > 0: tip.add ", with its geometry"
        ui.tip(cell, tip)
      if hov and ui.pressed() and a.proj != nil:
        ui.consumeClick()
        a.entityCursor = ck
        a.browserPress = (i, ui.mouse)
      if a.browserPress[0] == i and ui.window.buttonDown[MouseLeft] and
         (ui.mouse - a.browserPress[1]).length > 4:
        # Dragged out of the browser: the object follows the mouse in the views.
        a.browserPress = (-1, vec2(0, 0))
        a.startPlacing(p)
      elif a.browserPress[0] == i and ui.window.buttonReleased[MouseLeft]:
        a.browserPress = (-1, vec2(0, 0))
        if hov:
          if a.addPreset(p, a.placeAtView) != nil:
            a.say "Placed " & (if p.generic: "a new " & typeName(p.tag) else: p.label)
    y += ((ids.len + cols - 1) div cols).float32 * cellH + 4
  # A press that ended without placing anything (released elsewhere) is over.
  if not ui.window.buttonDown[MouseLeft]: a.browserPress = (-1, vec2(0, 0))
  # Furniture, consoles, doors and triggers come from the game files.
  let lb = rect(list.x + 8, y + 6, list.w - 16, 26)
  if lb.y < list.y + list.h:
    let label = if not hasLibrary(): "Build furniture, consoles, doors and triggers"
                elif not hasPreviews(): "Rebuild the entity library for model previews"
                else: "Rebuild the entity library"
    if ui.textButton("entity.library", lb, label, primary = not hasLibrary()) and lib == nil:
      a.buildLibrary()
    ui.tip(lb, if lib != nil: "Under way: " & lib.loadState
               else: "Takes them, with their geometry and textures, from levels 0 and 1 and the levels " &
                     "of the Texture Collections you use, in the background (about 15 s)")
  else:
    discard ui.tabStop("entity.library", lb)  # Out of sight: Tab still gets there.
  discard ui.listNav("entity.list", list, navItems, a.entityCursor)
  if listFocused and a.entityCursor in 0 ..< navItems.len:
    let c = a.entityCursor
    ui.cursorRing(navItems[c])
    if ui.navActivate("entity.list"):
      let g = navGroup[c]
      if navPreset[c] < 0:
        if filter.len == 0:
          if g in a.browserOpen: a.browserOpen.excl g else: a.browserOpen.incl g
      elif a.proj != nil:
        let p = a.presets[navPreset[c]]
        if a.addPreset(p, a.placeAtView) != nil:
          a.say "Placed " & (if p.generic: "a new " & typeName(p.tag) else: p.label)
  ui.popClip()
  ui.scrollbar("entity.list", list, a.entityScroll, contentH)
  # After drawing: the atlas can't change while this frame's quads point into it.
  if wanted.len > 0: a.loadPreviews(wanted)

proc readClasses(a: App) =
  a.classAutoBuild = true
  let app = a
  a.startLoad("classes", "Reading level 0's character classes", proc(): Job =
      classCacheJob(app.cfg, classCacheDir().parentDir / "classes.log"),
    proc() =
      app.classList = classNames()
      app.say &"Read {app.classList.len} character classes from level 0")

proc classLabel(name: string): string =
  ## A class's name as shown (classes.nim).
  if name.startsWith(ParticlePrefix): name[ParticlePrefix.len .. ^1] else: name

proc flagGrid(a: App, id: string, list: Rect, x: float32, y: var float32, w: float32, defs: seq[FlagDef],
              on: seq[bool], other: var string, otherTip: string, showOther = true): (int, bool) =
  ## Toggles in as many columns as fit, then an Other field for what they
  ## don't cover. Returns the toggled index (-1) and whether Other was committed.
  result = (-1, false)
  let ui = a.ui
  const CellH = 24'f32
  let cols = max(1, int(w / 145))
  let cw = w / cols.float32
  for i, d in defs:
    let cell = rect(x + (i mod cols).float32 * cw, y + (i div cols).float32 * CellH, cw, CellH)
    if cell.y + CellH <= list.y or cell.y >= list.y + list.h:
      discard ui.tabStop(id & "." & d.name, cell)  # Out of sight: Tab still gets there.
      continue
    var v = on[i]
    if ui.checkbox(id & "." & d.name, cell.xy, ui.ellipsize(d.label, cw - 30), v): result[0] = i
    ui.tip(cell, d.tip & " (" & d.name & ")")
  y += ((defs.len + cols - 1) div cols).float32 * CellH + 2
  if not showOther: return
  let fr = rect(x + 52, y, w - 52, 26)
  if y + 26 <= list.y or y >= list.y + list.h:
    discard ui.tabStop(id & ".other", fr, edit = true)
  else:
    ui.textIn("Other", rect(x, y, 50, 26), colTextDim, FontSmall)
    ui.tip(rect(x, y, 50, 26), otherTip)
    if eeCommitted in ui.textField(id & ".other", fr, other, "none"): result[1] = true
  y += 30

proc splitFlags(value: string, defs: seq[FlagDef]): (int, string) =
  ## A flag field's value (names, or one number): the bits defs cover, and the rest.
  let tokens = strutils.splitWhitespace(value.replace(",", " "))
  var mask = 0
  for d in defs: mask = mask or d.bit
  if tokens.len == 1:
    try:
      let n = parseInt(tokens[0])
      return (n and mask, if (n and not mask) != 0: $(n and not mask) else: "")
    except ValueError: discard
  var rest: seq[string]
  for t in tokens:
    block found:
      for d in defs:
        if d.name == t:
          result[0] = result[0] or d.bit
          break found
      rest.add t
  result[1] = rest.join(" ")

proc joinFlags(bits: int, other: string, defs: seq[FlagDef]): (bool, string) =
  ## The other way. Other takes numbers, in decimal or 0x: OniSplit reads names
  ## or one number, never both, so any bit without a name turns the value into one.
  var b = bits
  var numbers = 0
  for t in strutils.splitWhitespace(other.replace(",", " ")):
    block one:
      for d in defs:
        if cmpIgnoreCase(d.name, t) == 0:
          b = b or d.bit
          break one
      try: numbers = numbers or (if t.toLowerAscii.startsWith("0x"): parseHexInt(t) else: parseInt(t))
      except ValueError: return (false, t)
  if numbers != 0: return (true, $(b or numbers))
  var names: seq[string]
  for d in defs:
    if (b and d.bit) != 0: names.add d.name
  (true, names.join(" "))

proc drawFlagGroup(a: App, o: LevelObject, group: string, fields: seq[ObjectField], list: Rect,
                   x: float32, y: var float32, w: float32) =
  ## The on/off elements of a particle class's Properties, Options or Appearance.
  let ui = a.ui
  var defs: seq[FlagDef]
  var on: seq[bool]
  for d in flagGroup(group):
    for f in fields:
      if f.path == group & "/" & d.name and f.attr.len == 0 and
         matchesFilter(a.classFieldFilter, group & " " & d.name & " " & d.label & " " & d.tip, ""):
        defs.add d
        on.add f.value.strip == "true"
  let allowed = otherFlagNames(group)
  var extras: seq[string]
  for f in fields:
    if f.attr.len == 0 and isOtherFlag(f.path) and f.path.startsWith(group & "/") and
       f.value.strip == "true": extras.add f.path[group.len + 1 .. ^1]
  let key = group & "#other"
  let id = "cprop." & group
  if ui.focusId != id & ".other": a.classText[key] = extras.join(" ")
  let (toggled, committed) = a.flagGrid(id, list, x, y, w, defs, on, a.classText[key],
    "Other flag names OniSplit reads here, separated by spaces: " & allowed.join(", ") & ". " &
    "OniSplit has no way to set other bits of these flags.",
    showOther = matchesFilter(a.classFieldFilter, group & " other", ""))
  if toggled >= 0:
    for f in fields:
      if f.path == group & "/" & defs[toggled].name and f.attr.len == 0:
        a.commitField(o, f, if on[toggled]: "false" else: "true")
  if committed:
    var names: seq[string]
    for t in strutils.splitWhitespace(a.classText[key].replace(",", " ")):
      var hit = ""
      for n in allowed:
        if cmpIgnoreCase(n, t) == 0: hit = n
      if hit.len == 0:
        a.say(t & " isn't a flag OniSplit reads in " & group & " (Build would fail). It takes: " &
              allowed.join(", "), true)
        return
      if hit notin names: names.add hit
    if names.sorted != extras.sorted:
      let before = @[o.snapshot]
      o.setFlagElements(group, allowed, names)
      a.push editCmd("Edit " & group, @[o], before)

proc drawColorRow(a: App, o: LevelObject, fld: ObjectField, key, id: string, fr: Rect, left: float32) =
  ## A particle color: R G B (and an alpha when it has one), or a variable's name.
  let ui = a.ui
  const BtnW = 34'f32
  let parts = strutils.splitWhitespace(fld.value)
  var isColor = parts.len in 3 .. 4
  for p in parts:
    try: discard parseFloat(p)
    except ValueError: isColor = false
  let btn = rect(fr.x + fr.w - BtnW, fr.y, BtnW, fr.h)
  if isColor and key notin a.classAsText:
    let alpha = parts.len == 4
    let suffix = if alpha: " " & parts[3] else: ""
    const AlphaW = 40'f32
    let cr = rect(fr.x, fr.y, fr.w - BtnW - 2 - (if alpha: AlphaW + 2 else: 0), fr.h)
    a.classText[key] = parts[0 .. 2].join(" ")
    let ev = ui.colorField(id, cr, a.classText[key], a.colorTarget(@[o], fld, suffix))
    if eeCommitted in ev: a.commitColor(@[o], fld, a.classText[key], suffix)
    if alpha:
      var v = try: parseFloat(parts[3]) except ValueError: 255.0
      let ar = rect(cr.x + cr.w + 2, fr.y, AlphaW, fr.h)
      if ui.numberField(id & ".alpha", ar, v, 8, 0, 255, 0):
        a.commitField(o, fld, parts[0 .. 2].join(" ") & " " & $int(v))
      ui.tip(ar, "Alpha (0–255)")
    if ui.textButton(id & ".var", btn, "Var"):
      a.classAsText.incl key
      ui.focusId = id
      ui.focusFresh = true
    ui.tip(btn, "Use one of the class's color variables instead of a color")
  else:
    let tr = rect(fr.x, fr.y, fr.w - BtnW - 2, fr.h)
    let pick = proc(v: string) =
      a.classAsText.excl key
      a.commitField(o, fld, v)
    a.dropField(id, tr, left, a.classText[key], o, fld, pick)
    if eeCommitted in ui.textField(id, tr, a.classText[key]):
      a.classAsText.excl key
      a.commitField(o, fld, a.classText[key])
    if ui.textButton(id & ".rgb", btn, "RGB"):
      a.classAsText.excl key
      if not isColor: a.commitField(o, fld, "255 255 255")
    ui.tip(btn, "Use a color instead of a variable")

proc spawnedClasses(a: App): seq[tuple[key: string, depth: int]] =
  ## The classes the open class creates, and theirs, each once: an emitter's
  ## Lifetime only says how long it emits, so these say how long what it made lasts.
  const MaxShown = 40
  var seen: HashSet[string]
  var found: seq[tuple[key: string, depth: int]]
  proc walk(from_key: string, depth: int) =
    for key in a.spawnKids(from_key):
      if key in seen or found.len >= MaxShown: continue
      seen.incl key
      if a.openClass(key) == nil: continue
      found.add (key, depth)
      walk(key, depth + 1)
  seen.incl a.className
  walk(a.className, 0)
  found

proc classParents(a: App, key: string): seq[string] =
  ## The particle classes that create key, sorted. Level 0's links, with what the
  ## classes open or edited here say now.
  let stamp = (a.pushCount, a.undoStack.len, a.redoStack.len)
  if stamp != a.classParentStamp:
    a.classParentStamp = stamp
    if a.level0Spawns.len == 0: a.level0Spawns = particleSpawns()
    for k in a.editedClasses:
      if k.startsWith(ParticlePrefix): discard a.openClass(k)
    var links = a.level0Spawns
    for k in toSeq(a.classes.keys):
      if k.startsWith(ParticlePrefix) and a.classes[k] != nil: links[k] = a.spawnKids(k)
    a.classParentMap.clear()
    for parent, kids in links:
      for kid in kids:
        if kid != parent: a.classParentMap.mgetOrPut(kid, @[]).add parent
    for parents in a.classParentMap.mvalues: parents.sort()
  a.classParentMap.getOrDefault(key)

proc classChain(a: App, key: string): seq[string] =
  ## key's ancestors, outermost first, when nobody came down to it from one: the
  ## way up from a class this level's Particle objects use, or else the first
  ## parents up to a class nothing creates.
  var used: HashSet[string]
  for ob in a.objects:
    if ob.tag == "PART": used.incl ParticlePrefix & ob.node.xpath("OSD/Class").str.strip.toLowerAscii
  var seen = [key].toHashSet
  proc up(k: string): seq[string] =
    if k in used: return @[k]
    for p in a.classParents(k):
      if p in seen: continue
      seen.incl p
      let path = up(p)
      if path.len > 0: return path & k
  var path = up(key)
  if path.len > 0: path.setLen(path.len - 1)   # up() ended it with key.
  else:
    var k = key
    var climbed = [key].toHashSet
    while true:
      let next = a.classParents(k).filterIt(it notin climbed)
      if next.len == 0: break
      k = next[0]
      climbed.incl k
      path.insert(k, 0)
  path

proc checkClassTrail(a: App) =
  ## classTrail stays while it leads to the open class; any other way of opening
  ## a class gets a new one.
  let cut = a.classTrail.find(a.className)
  if cut >= 0: a.classTrail.setLen(cut)
  var fits = a.classTrail.deduplicate.len == a.classTrail.len and
             (a.classTrail.len > 0 or a.classParents(a.className).len == 0)
  var child = a.className
  for i in countdown(a.classTrail.high, 0):
    if a.classTrail[i] notin a.classParents(child): fits = false
    child = a.classTrail[i]
  if not fits: a.classTrail = a.classChain(a.className)

proc drawClassTrail(a: App, x: float32, y: var float32, w: float32) =
  ## The open particle class's ancestors as arrows running into it, on as many
  ## rows as they take. Arrows are drawn last to first: each point sits in the
  ## notch of the next one.
  let ui = a.ui
  const
    H = 24'f32
    Tip = 10'f32
    Gap = 3'f32
    Pad = 8'f32
    AltW = 16'f32
  a.checkClassTrail()
  if a.classTrail.len == 0:
    ui.textIn("No particle class spawns this one", rect(x, y, w, 20), colTextDim, FontSmall)
    y += 26
    return
  let crumbs = a.classTrail & a.className
  type Crumb = object
    r: Rect
    others: seq[string]
  var laid = newSeq[Crumb](crumbs.len)
  var cx = x
  var cy = y
  for i, key in crumbs:
    if i < crumbs.high:
      laid[i].others = a.classParents(crumbs[i + 1]).filterIt(it != key)
    let front = if i > 0: Tip else: 0
    let side = if laid[i].others.len > 0: AltW else: 0
    let bw = min(ui.textSize(key.classLabel, FontSmall).x + Pad * 2 + front + side, w - Tip)
    if cx > x and cx + bw + Tip > x + w:
      cx = x
      cy += H + 4
    laid[i].r = rect(cx.floor, cy, bw.ceil, H)
    cx = laid[i].r.x + laid[i].r.w + Gap
  for i in countdown(crumbs.high, 0):
    let key = crumbs[i]
    let c = laid[i]
    let last = i == crumbs.high
    let front = if i > 0: Tip else: 0
    let side = if c.others.len > 0: AltW else: 0
    let id = "class.crumb." & key
    let body = rect(c.r.x, c.r.y, c.r.w - side, H)
    let hov = not last and ui.hover(body)
    let fill = if last: colAccent elif hov: colAccentDim else: colBorder
    ui.rect(c.r, fill)
    if i > 0: ui.icon("crumbtip", vec2(c.r.x + Tip / 2, c.r.y + H / 2), colPanel)
    ui.icon("crumbtip", vec2(c.r.x + c.r.w + Tip / 2, c.r.y + H / 2), fill)
    let tr = rect(c.r.x + front + Pad - (if i > 0: 2 else: 0), c.r.y, c.r.w - front - side - Pad, H)
    ui.textIn(ui.ellipsize(key.classLabel, tr.w, FontSmall), tr, if last: colOnAccent else: colText, FontSmall)
    if last:
      ui.tip(c.r, "The class open here")
      continue
    var open = false
    let focused = ui.tabStop(id, body)
    ui.tip(body, "Spawns " & crumbs[i + 1].classLabel & ". Click to open " & key.classLabel & ".")
    if hov and ui.pressed():
      ui.consumeClick()
      open = true
    if focused:
      ui.cursorRing(body)
      if ui.navActivate(id): open = true
    if open:
      a.classTrail.setLen(i)
      a.className = key
    if side > 0:
      let names = c.others.mapIt(it.classLabel).join(", ")
      if ui.iconButton(id & ".others", rect(c.r.x + c.r.w - AltW, c.r.y + 2, AltW, H - 4), "expand16",
                       crumbs[i + 1].classLabel & " is also spawned by " & names & ". Click to follow one of those.",
                       focusable = false):
        a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, classParentsOf: crumbs[i + 1])
        a.ctxPending = true
  y = cy + H + 8

const NoFieldsRow = "-"   ## Last path segment of a row that only brings out its headings.

proc eventRows(o: LevelObject): seq[ObjectField] =
  ## A particle class's fields, its events and actions in the order they count. An
  ## event or action with no value gets a row too, so its heading shows.
  let all = o.fields
  for f in all:
    if not f.path.startsWith("Events/"): result.add f
  let start = result.len
  for e in EventDefs:
    let en = o.node.eventOf(e.name)
    if en == nil: continue
    let ep = "Events/" & e.name
    var any = false
    for c in en:
      if c.kind != xnElement: continue
      any = true
      let ap = ep & "/" & en.actionKey(c)
      let n = result.len
      for f in all:
        if f.path.startsWith(ap & "/"): result.add f
      if result.len == n: result.add ObjectField(path: ap & "/" & NoFieldsRow)
    if not any: result.add ObjectField(path: ep & "/" & NoFieldsRow)
  if result.len == start: result.add ObjectField(path: "Events/" & NoFieldsRow)

proc applyClassXml(a: App, o: LevelObject, d: var ClassXmlDraft) =
  ## Makes the XML view's text the class, if Build can use it.
  var n: XmlNode
  try: n = parseXml(d.text)
  except CatchableError as e:
    # "unknown_xml_doc(3, 7) Error: ..." -> "Line 3: ..."
    let m = e.msg.splitLines[0]
    let num = m.find('(')
    let msg = m.find(") Error: ")
    d.error = if num >= 0 and msg > num: "Line " & m[num + 1 ..< msg].split(',')[0] & ": " & m[msg + 9 .. ^1]
              else: m
    return
  d.error =
    if n.tag != o.node.tag: "The top element has to stay <" & o.node.tag & ">"
    elif n.attr("Name") != o.node.attr("Name"): "The class's Name has to stay " & o.node.attr("Name")
    elif o.tag == ParticleTag: n.checkClass
    else: ""
  if d.error.len > 0: return
  let before = @[o.snapshot]
  o.restore($n)
  a.push editCmd("Edit XML", @[o], before)
  d.base = o.snapshot
  d.text = d.base

proc drawClassXml(a: App, o: LevelObject, r: Rect) =
  ## The open class as text. What's typed stays apart from the class until Apply,
  ## and stays while the class is closed.
  let ui = a.ui
  let key = a.className
  let now = o.snapshot
  var d = a.classXmlDrafts.getOrDefault(key, ClassXmlDraft(text: now, base: now))
  if d.base != now and d.text == d.base: d = ClassXmlDraft(text: now, base: now)
  let typed = d.text != now
  const BarH = 26'f32
  var bx = r.x
  if typed:
    if ui.textButton("class.xml.apply", rect(bx, r.y, 70, BarH), "Apply", primary = true):
      a.applyClassXml(o, d)
    bx += 76
    if ui.textButton("class.xml.discard", rect(bx, r.y, 76, BarH), "Discard"):
      d = ClassXmlDraft(text: now, base: now)
    bx += 82
  let status = if d.error.len > 0: d.error
               elif d.text != now: "Not applied yet"
               else: "Same as the class"
  let sr = rect(bx, r.y, r.x + r.w - bx, BarH)
  ui.textIn(ui.ellipsize(status, sr.w, FontSmall), sr, if d.error.len > 0: colError else: colTextDim, FontSmall)
  ui.tip(sr, status)
  let area = rect(r.x, r.y + BarH + 6, r.w, r.h - BarH - 6)
  if area.h > 40:
    let before = d.text
    discard ui.textArea("class.xml." & key, area, d.text)
    if d.text != before: d.error = ""
  a.classXmlDrafts[key] = d

proc drawClassFields(a: App, o: LevelObject, props: Rect) =
  ## The open class: what it is, then its fields under their groups.
  let ui = a.ui
  if a.classTextFor != o:
    a.classTextFor = o
    a.classText.clear()
    a.classAsText.clear()
    a.classScroll = 0
    if a.soundObj == nil: stopSound()   # A preview of the last class's sound.
  let x = props.x + 10
  let w = props.w - 20
  var y = props.y + 8
  let particle = a.className.startsWith(ParticlePrefix)
  if particle: a.drawClassTrail(x, y, w)
  let plain = a.className.classLabel
  ui.text(if particle: "Particle class" else: "Character class", vec2(x, y), colAccent, FontSmall)
  y += 18
  ui.textIn(ui.ellipsize(plain, w), rect(x, y, w, 22), colText)
  y += 24
  var users = 0
  for ob in a.objects:
    if ob.tag == (if particle: "PART" else: "CHAR") and
       cmpIgnoreCase(ob.node.xpath("OSD/Class").str.strip, plain) == 0: inc users
  let edited = a.className in a.editedClasses
  let thing = if particle: "Particle object" else: "character"
  let note = (if users == 0: "No " & thing & " in this level uses it"
              elif users == 1: "1 " & thing & " in this level uses it"
              else: &"{users} {thing}s in this level use it") & (if edited: " · edited" else: "")
  ui.textIn(ui.ellipsize(note, w - 126, FontSmall), rect(x, y, w - 126, 26), colTextDim, FontSmall)
  if edited:
    let rb = rect(x + w - 120, y, 120, 26)
    if ui.textButton("class.revert", rb, "Use game values"):
      let before = @[o.snapshot]
      o.restore(a.classOrig[a.className])
      a.push editCmd("Revert " & a.className, @[o], before)
    ui.tip(rb, "Puts back level 0's values for this class (Undo brings yours back)")
  y += 32
  if particle:
    let pb = rect(x, y, 150, 26)
    if ui.textButton("class.previewParticles", pb, "Restart in the views"):
      a.previewParts.incl ppParticles
      if a.particleSim != nil: a.particleSim.held.clear()
      if a.realtime: a.particleRestart = true
      else: a.switchRealtime()
    ui.tip(pb, "Runs the level's Particle objects from the start in the 3D views, with these values. " &
               "Edits show as you make them. Particles that wait for a script don't start here.")
    let nr = rect(x + 158, y, w - 158, 26)
    ui.textIn(ui.ellipsize("Weapons and characters keep the game's", nr.w, FontSmall), nr, colTextDim, FontSmall)
    ui.tip(nr, "Build uses this class for the level's Particle objects and for the classes they emit. " &
               "A weapon or a character that uses it keeps level 0's version.")
    y += 32
  const XmlButtonW = 50'f32
  if not a.classXml:
    discard ui.textField("class.fieldFilter", rect(x - 2, y, w + 4 - XmlButtonW - 6, 26), a.classFieldFilter, "Search fields...")
  let xb = rect(x + w - XmlButtonW, y, XmlButtonW, 26)
  if ui.textButton("class.xml", xb, "XML", primary = a.classXml): a.classXml = not a.classXml
  ui.tip(xb, "Shows the class as XML, to edit it by hand. Apply makes it the class (Undo brings the last one back).")
  y += 34
  if a.classXml:
    a.drawClassXml(o, rect(x - 2, y, w + 4, props.y + props.h - y - 8))
    return
  let list = rect(props.x, y, props.w, props.y + props.h - y)
  if list.h <= 0: return
  ui.scrollArea("class.fields", list, a.classScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.classScroll)
  y = list.y + 4 - a.classScroll
  var shown = 0
  var gridDone: HashSet[string]
  let fields = if particle: o.eventRows else: o.fields
  # The headings open above this field, outermost first, and whether one is folded.
  var trail: seq[string]
  var foldedHere = false
  var heads = 0
  var toggle = ""   # Applied after the loop: a field being left still has to commit.
  var toggleAll = false   # Shift: everything under it goes the same way.
  let searching = a.classFieldFilter.strip.len > 0
  proc folded(path: string): bool =
    not searching and (if particle: "p:" else: "c:") & path in a.classFolded
  var eventOp: proc() = nil   # Applied after the loops, like toggle.
  proc heading(path, name: string, depth: int) =
    ## An element's fields under its name, indented by how deep it is. Events and
    ## their actions also get buttons, on the right of the row.
    y += 4
    let ind = depth.float32 * 10
    let seg = path.split('/')
    let eventRow = particle and seg[0] == "Events" and seg.len <= 3
    let def = if eventRow and seg.len == 3: actionDef(seg[2].split('[')[0]) else: nil
    let label = if eventRow and seg.len == 2 and eventDef(seg[1]).label.len > 0: eventDef(seg[1]).label
                elif def != nil: def.label
                else: name
    let info = if not eventRow: ""
               elif seg.len == 2: eventDef(seg[1]).tip
               elif def != nil: def.tip & " (" & def.name & ")"
               else: ""
    let buttons = if not eventRow: 0 elif seg.len == 1: 1 elif seg.len == 2: 2 else: 3
    let full = rect(x - 2 + ind, y, w + 4 - ind, 20)
    let hr = rect(full.x, y, full.w - buttons.float32 * 22, 20)
    let hid = "cfold." & path & "#" & $heads
    inc heads
    let focused = ui.tabStop(hid, hr)
    if y + 20 > list.y and y < list.y + list.h:
      let hov = ui.hover(hr)
      if hov: ui.rect(hr, colHover)
      ui.foldArrow(not folded(path), vec2(hr.x + 9, y + 10))
      ui.textIn(ui.ellipsize(label, hr.w - 20, FontSmall), rect(hr.x + 18, y, hr.w - 20, 20), colAccent, FontSmall)
      ui.tip(hr, (if info.len > 0: info & " · " else: path.replace("/", " / ") & " · ") &
                 "Shift+click: everything under it too")
      if hov and ui.pressed() and not searching:
        ui.consumeClick()
        toggle = path
        toggleAll = ui.window.shiftDown
      if buttons > 0:
        var bx = full.x + full.w - 22
        proc button(id, icon, tip: string, enabled = true): bool =
          result = ui.iconButton(hid & "." & id, rect(bx, y, 20, 20), icon, tip, enabled, focusable = false)
          bx -= 22
        proc addMenu(what: string) =
          # Opened after the menus' update: this release would close it at once.
          a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, classAdd: what)
          a.ctxPending = true
        if seg.len == 1:
          if button("add", "plus16", "Add an event"): addMenu("+")
        else:
          let ev = seg[1]
          let en = o.node.eventOf(ev)
          let act = if seg.len == 3 and en != nil: en.actionByKey(seg[2]) else: nil
          if seg.len == 2:
            if button("del", "close16", "Remove this event and its actions"):
              eventOp = proc() = a.editParticleEvents(o, "Remove event " & ev, proc(n: XmlNode): int = n.removeEvent(ev))
            if button("add", "plus16", "Add an action to this event"): addMenu(ev)
          elif act != nil:
            if button("del", "close16", "Remove this action"):
              eventOp = proc() = a.editParticleEvents(o, "Remove " & act.tag, proc(n: XmlNode): int = n.removeAction(ev, act))
            var at, count = 0
            for c in en:
              if c.kind == xnElement:
                if c == act: at = count
                inc count
            if button("down", "down16", "Run it later", at < count - 1):
              eventOp = proc() = a.editParticleEvents(o, "Move " & act.tag, proc(n: XmlNode): int = n.moveAction(ev, act, 1))
            if button("up", "up16", "Run it earlier", at > 0):
              eventOp = proc() = a.editParticleEvents(o, "Move " & act.tag, proc(n: XmlNode): int = n.moveAction(ev, act, -1))
    if focused:
      ui.cursorRing(hr)
      if ui.navActivate(hid) and not searching:
        toggle = path
        toggleAll = ui.window.shiftDown
    y += 22
  var openKey = ""   # Applied after the loops, like toggle.
  var openTrail: seq[string]
  if particle:
    const SpawnHead = "Spawned particles"
    var spawned: seq[tuple[key: string, depth: int]]
    for (key, depth) in a.spawnedClasses:
      if matchesFilter(a.classFieldFilter, key.classLabel & " lifetime fade spawned", ""):
        spawned.add (key, depth)
    if spawned.len > 0:
      heading(SpawnHead, &"{SpawnHead} ({spawned.len})", 0)
      shown += spawned.len
    if spawned.len > 0 and not folded(SpawnHead):
      # A table: one class a row, under its parent, its two times in columns.
      const
        ColW = 64'f32
        ColGap = 4'f32
        RowStep = 28'f32
        TagGap = 6'f32
      let fadeX = x + w - ColW
      let lifeX = fadeX - ColGap - ColW
      let nameEnd = lifeX - 6
      if y + 20 > list.y and y < list.y + list.h:
        ui.textIn("Particle", rect(x + 4, y, nameEnd - x, 20), colTextDim, FontSmall)
        ui.textIn("Lasts (s)", rect(lifeX, y, ColW, 20), colTextDim, FontSmall)
        ui.textIn("Fades (s)", rect(fadeX, y, ColW, 20), colTextDim, FontSmall)
        ui.tip(rect(lifeX, y, ColW, 20), "How long each one lives. An emitter keeps emitting for that long.")
        ui.tip(rect(fadeX, y, ColW, 20), "How long it takes to fade once Lasts has run out, on top of Lasts.")
        ui.rect(rect(x, y + 20, w, 1), colBorder)
      y += 24
      var route: seq[string]   # The rows above this one that lead to it.
      for row in spawned:
        let key = row.key
        let depth = row.depth
        route.setLen(min(route.len, depth))
        let co = a.classes[key]
        let hidden = co.node.xpath("Appearance/Invisible").str.strip == "true"
        let cid = "class.spawn." & key
        var life: seq[ObjectField]
        var fades: seq[ObjectField]
        for fld in co.fields:
          if fld.path == "Options/Lifetime": life.add fld
          elif fld.path.startsWith("Events/Lifetime/") and fld.path.endsWith("/TimeToDie"): fades.add fld
        let ind = depth.float32 * 14
        let nr = rect(x + ind, y, nameEnd - x - ind, 26)
        let focused = ui.tabStop(cid, nr)
        if y + 26 > list.y and y < list.y + list.h:
          let hov = ui.hover(nr)
          if hov: ui.rect(nr, colHover)
          if depth > 0:   # Hooks it onto the row of what spawns it.
            ui.rect(rect(nr.x - 8, y - 2, 1, 15), colTextDim)
            ui.rect(rect(nr.x - 8, y + 13, 6, 1), colTextDim)
          let tag = if hidden: "emitter" else: ""
          let tagW = if hidden: ui.textSize(tag, FontSmall).x + TagGap else: 0
          let room = nr.w - 8 - tagW
          let shownName = ui.ellipsize(key.classLabel, room, FontSmall)
          ui.textIn(shownName, rect(nr.x + 4, y, room, 26), if hov: colAccent else: colText, FontSmall)
          if hidden:
            ui.textIn(tag, rect(nr.x + 4 + ui.textSize(shownName, FontSmall).x + TagGap, y, tagW, 26),
                      colTextDim, FontSmall)
          ui.tip(nr, key.classLabel & (if hidden: " draws nothing itself, it only emits. " else: " is what you see. ") &
                     "Click to open all of its fields.")
          if hov and ui.pressed():
            ui.consumeClick()
            openKey = key
            openTrail = a.classTrail & a.className & route
        if focused:
          ui.cursorRing(nr)
          if ui.navActivate(cid):
            openKey = key
            openTrail = a.classTrail & a.className & route
        route.add key
        proc timeCell(fld: ObjectField, cx: float32, tip: string) =
          let cr = rect(cx, y, ColW, 26)
          discard a.typedField("cspawn." & key & "." & fld.path & "@" & fld.attr, cr, @[co], fld, @[fld.value])
          ui.tip(cr, tip)
        proc noCell(cx: float32, tip: string) =
          let cr = rect(cx, y, ColW, 26)
          ui.textIn("none", rect(cx + 6, y, ColW - 6, 26), colTextDim, FontSmall)
          ui.tip(cr, tip)
        if life.len > 0:
          timeCell(life[0], lifeX, (if hidden: "Seconds it keeps emitting." else: "Seconds each one lives.") &
                                   " 0: it doesn't run out by itself.")
        else: noCell(lifeX, "This class has no Lifetime.")
        let fadeTip = "Seconds it takes to fade once Lasts has run out, on top of Lasts."
        if fades.len > 0: timeCell(fades[0], fadeX, fadeTip)
        else: noCell(fadeX, "This class has no Fade out action on its Lifetime event. Open it to add one.")
        y += RowStep
        for i in 1 .. fades.high:   # A few classes fade twice.
          ui.textIn("Fade " & $(i + 1), rect(lifeX, y, ColW, 26), colTextDim, FontSmall)
          timeCell(fades[i], fadeX, fadeTip)
          y += RowStep
      y += 6
  for fld in fields:
    let ft = fieldType(o.tag, fld.path, fld.attr)
    let cut = fld.path.rfind('/')
    let parent = if cut < 0: "" else: fld.path[0 ..< cut]
    if particle and fld.attr.len == 0 and isOtherFlag(fld.path): continue   # In its group's Other.
    let flagged = particle and ft.kind == fkToggle
    if flagged:
      # Every toggle of a group goes in one grid, where the first of them is.
      if parent in gridDone: continue
      gridDone.incl parent
      if not flagGroup(parent).anyIt(matchesFilter(a.classFieldFilter,
                                                   parent & " " & it.name & " " & it.label & " " & it.tip, "")) and
         not matchesFilter(a.classFieldFilter, parent & " other", ""):
        continue
    elif not matchesFilter(a.classFieldFilter, fld.path, fld.value): continue
    inc shown
    let key = fld.path & "@" & fld.attr
    let id = "cprop." & key
    let leaf = if fld.label.len > 0: fld.label
               else: (if cut < 0: fld.path else: fld.path[cut + 1 .. ^1]) &
                     (if fld.attr.len > 0: " ." & fld.attr else: "")
    let segs = if parent.len > 0: parent.split('/') else: @[]
    if segs != trail:
      # Every level gets a heading, so one click folds all of it, even a level
      # with no fields of its own. Back from a child, the parent's is repeated.
      var common = 0
      while common < min(segs.len, trail.len) and segs[common] == trail[common]: inc common
      let back = common == segs.len
      foldedHere = false
      for d in 0 ..< segs.len:
        let path = segs[0 .. d].join("/")
        if not foldedHere and (d >= common or (back and d == segs.high and not folded(path))):
          heading(path, segs[d], d)
        if folded(path): foldedHere = true
      trail = segs
    if foldedHere or fld.path.endsWith("/" & NoFieldsRow): continue
    let indent = segs.len.float32 * 10
    if flagged:
      if parent == "Properties":
        let note = "Memory per particle; over 256 bytes, Oni refuses it."
        ui.textIn(ui.ellipsize(note, w - indent, FontSmall), rect(x + indent, y, w - indent, 20), colTextDim, FontSmall)
        ui.tip(rect(x + indent, y, w - indent, 20), note)
        y += 22
      a.drawFlagGroup(o, parent, fields, list, x + indent, y, w - indent)
      continue
    let fieldPath = fld.path
    proc fieldLabel(lr: Rect) =
      ui.textIn(ui.ellipsize(leaf, lr.w - 6, FontSmall), lr, colTextDim, FontSmall)
      ui.tip(lr, fieldPath)
    if ft.kind == fkFlags:
      # Each emitter has its own; the label heads the grid.
      let (bits, rest) = splitFlags(fld.value, ft.flags)
      let keyOther = key & "#other"
      if ui.focusId != id & ".other": a.classText[keyOther] = rest
      fieldLabel(rect(x + indent, y, w - indent, 22))
      y += 22
      let (toggled, committed) = a.flagGrid(id, list, x + indent, y, w - indent, ft.flags,
        ft.flags.mapIt((bits and it.bit) != 0), a.classText[keyOther],
        "Bits without a toggle, as numbers (decimal or 0x). With any, the value is stored as one number.")
      if toggled >= 0:
        let (_, v) = joinFlags(bits xor ft.flags[toggled].bit, rest, ft.flags)
        a.commitField(o, fld, v)
      if committed:
        let (ok, v) = joinFlags(bits, a.classText[keyOther], ft.flags)
        if ok: a.commitField(o, fld, v)
        else: a.say(v & " isn't a number or a flag of this field (Build would fail)", true)
      continue
    if key notin a.classText or ui.focusId != id: a.classText[key] = fld.value
    let wide = ft.kind == fkColor
    let kw = w * (if wide: 0.24 else: 0.42)
    let side = if ft.kind in {fkSound, fkTexture}: 30'f32 else: 0   # Its button, right of the field.
    let fr = rect(x + kw, y, w - kw - side, 26)
    let lr = rect(x + indent, y, kw - indent, 26)
    if ft.kind == fkColor:
      if y + 26 <= list.y or y >= list.y + list.h:
        discard ui.tabStop(id, fr, edit = true)
      else:
        fieldLabel(lr)
        a.drawColorRow(o, fld, key, id, fr, x)
    elif a.typedField(id, fr, @[o], fld, @[fld.value]):
      fieldLabel(lr)
    elif y + 26 <= list.y or y >= list.y + list.h:
      discard ui.tabStop(id, fr, edit = true)  # Out of sight: Tab still gets there.
    else:
      fieldLabel(lr)
      a.dropField(id, fr, x, a.classText[key], o, fld, a.pickOne(o, fld))
      let ev = ui.textField(id, fr, a.classText[key])
      if eeCommitted in ev: a.commitField(o, fld, a.classText[key])
      let br = rect(fr.x + fr.w + 4, y, 26, 26)
      if ft.kind == fkSound:
        let on = soundPlaying(fld.value)
        if ui.iconButton(id & ".play", br, if on: "stop16" else: "play16",
                         if on: "Stop the preview" else: "Listen to this sound", fld.value.len > 0 or on):
          a.previewClassSound(fld.value, ft.impulse)
      elif ft.kind == fkTexture:
        if ui.textButton(id & ".pick", br, "..."):
          ui.focusId = id
          ui.focusFresh = true
        ui.tip(br, "Pick from the list of textures")
      if ft.kind == fkSound and fld.value.strip.startsWith(RecordingPrefix):
        y += 30
        a.recordingPitchRow(id, x, y, kw, w, o, fld, ft.impulse)
        y -= 30   # The field's own row is added below.
    y += 30
  if openKey.len > 0:
    a.className = openKey
    a.classTrail = openTrail
  if eventOp != nil: eventOp()
  if toggle.len > 0:
    let k = (if particle: "p:" else: "c:") & toggle
    let opening = k in a.classFolded
    if opening: a.classFolded.excl k else: a.classFolded.incl k
    if toggleAll:
      let under = k & "/"
      if opening:
        # Other classes can have levels this one doesn't: those open as well.
        for f in a.classFolded.toSeq:
          if f.startsWith(under): a.classFolded.excl f
      else:
        let kind = k[0 .. 1]
        for fld in fields:
          var cut = fld.path.rfind('/')
          while cut >= 0:
            let level = kind & fld.path[0 ..< cut]
            if level.startsWith(under): a.classFolded.incl level
            cut = fld.path.rfind('/', last = cut - 1)
  if shown == 0: ui.textIn("No field matches", rect(x, list.y + 8, w, 22), colTextDim, FontSmall)
  let contentH = y + a.classScroll - list.y
  if ui.hover(list) and not ui.scrollConsumed:
    a.classScroll += ui.wheelNotches * RowH * 3
  a.classScroll = clamp(a.classScroll, 0, max(0, contentH - list.h + 20))
  ui.popClip()
  ui.scrollbar("class.fields", list, a.classScroll, contentH + 20)

proc readParticles(a: App) =
  let app = a
  a.loadParticles(proc() =
    app.particleClasses = particleNames()
    app.say &"Read {app.particleClasses.len} particle classes from level 0")

proc drawClassesPage(a: App, whole: Rect) =
  ## Character and particle classes: the open one's fields above, every class below.
  let ui = a.ui
  # Follow the selected object: its class opens, on its side.
  let sel = a.selection
  if sel.len == 1 and sel[0].tag in ["CHAR", "PART"] and a.classFor != sel[0]:
    a.classFor = sel[0]
    let cn = sel[0].node.xpath("OSD/Class").str.strip
    if sel[0].tag == "PART":
      if a.particleClasses.len == 0 and hasParticleCache(): a.particleClasses = particleNames()
      let key = ParticlePrefix & cn.toLowerAscii
      if key in a.particleClasses:
        if not a.classParticles: a.classOther = a.className
        a.classParticles = true
        a.className = key
    else:
      if a.classList.len == 0 and hasClassCache(): a.classList = classNames()
      if cn in a.classList:
        if a.classParticles: a.classOther = a.className
        a.classParticles = false
        a.className = cn
  const SideH = 32'f32
  for (i, side) in [(0, "Characters"), (1, "Particles")]:
    let b = rect(whole.x + 8 + i.float32 * 104, whole.y + 3, 100, 26)
    if ui.textButton("class.side." & side, b, side, primary = a.classParticles == (i == 1)) and
       a.classParticles != (i == 1):
      swap(a.className, a.classOther)
      a.classParticles = i == 1
      a.classCursor = 0
      a.classListScroll = 0
  let particles = a.classParticles
  let r = rect(whole.x, whole.y + SideH, whole.w, whole.h - SideH)
  if r.h <= 0: return
  if particles:
    if not hasParticleCache():
      # Level 0's particles are extracted once, as for the realtime preview.
      if not a.particleAutoBuild and a.proj != nil: a.readParticles()
      if a.loading("particles"):
        a.loadingBar(r, "particles")
      else:
        let br = rect(r.x + (r.w - 260) / 2, r.y + r.h / 2 - 13, 260, 26)
        if ui.textButton("class.readParticles", br, "Read the particle classes from level 0", primary = true):
          a.readParticles()
      return
    if a.particleClasses.len == 0: a.particleClasses = particleNames()
  elif not hasClassCache():
    # Level 0's classes are extracted once, unasked, the first time this shows.
    if not a.classAutoBuild and a.proj != nil: a.readClasses()
    if a.loading("classes"):
      a.loadingBar(r, "classes")
    else:
      let br = rect(r.x + (r.w - 260) / 2, r.y + r.h / 2 - 13, 260, 26)
      if ui.textButton("class.read", br, "Read the character classes from level 0", primary = true):
        a.readClasses()
    return
  if not particles and a.classList.len == 0: a.classList = classNames()
  let names = if particles: a.particleClasses else: a.classList
  if a.entityBrowserH <= 0: a.entityBrowserH = 210
  a.entityBrowserH = clamp(a.entityBrowserH, 90, max(90, r.h - 120))
  const TitleH = 26'f32
  let browserH = if a.classListFolded: TitleH else: a.entityBrowserH
  let props = rect(r.x, r.y, r.w, r.h - browserH - 6)
  let o = a.openClass(a.className)
  ui.pushClip(props)
  if o == nil:
    ui.textIn(if a.className.len == 0:
                (if particles: "Pick a class below, or select a Particle object"
                 else: "Pick a class below, or select a character")
              else: "Level 0 has no class " & a.className.classLabel, props, colTextDim, h = CenterAlign)
  else:
    a.drawClassFields(o, props)
  ui.popClip()

  if not a.classListFolded:
    let (dragging, my) = a.divider("class.browser", rect(r.x, r.y + r.h - browserH - 6, r.w, 6), false)
    if dragging: a.entityBrowserH = r.y + r.h - my - 3
  let br = rect(r.x, r.y + r.h - browserH, r.w, browserH)
  if ui.foldTitle("class.listTitle", rect(br.x, br.y, br.w, TitleH),
                  (if particles: "Particle classes" else: "Character classes") & " · click one to edit it",
                  not a.classListFolded):
    a.classListFolded = not a.classListFolded
  if a.classListFolded: return
  discard ui.textField("class.filter", rect(br.x + 8, br.y + 32, br.w - 16, 26), a.classFilter, "Search classes...")
  let list = rect(br.x, br.y + 64, br.w, br.h - 64)
  var used: CountTable[string]
  for ob in a.objects:
    if particles and ob.tag == "PART": used.inc ParticlePrefix & ob.node.xpath("OSD/Class").str.strip.toLowerAscii
    elif not particles and ob.tag == "CHAR": used.inc ob.node.xpath("OSD/Class").str.strip
  let edited = a.editedClasses
  # The level's classes first.
  var rows: seq[string]
  for first in [true, false]:
    for n in names:
      if (used[n] > 0) == first and matchesFilter(a.classFilter, n.classLabel, ""): rows.add n
  const ClassRowH = 24'f32
  let contentH = rows.len.float32 * ClassRowH + 8
  if ui.hover(list) and not ui.scrollConsumed:
    a.classListScroll += ui.wheelNotches * 26 * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  ui.scrollArea("class.list", list, a.classListScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.classListScroll)
  a.classListScroll = clamp(a.classListScroll, 0, max(0, contentH - list.h))
  let listFocused = ui.tabStop("class.list", list)
  var nav: seq[Rect]
  let inList = ui.mouse.inside(list)
  var y = list.y + 2 - a.classListScroll
  for k, n in rows:
    let rr = rect(list.x + 4, y, list.w - 8, ClassRowH - 2)
    nav.add rr
    if rr.y + rr.h > list.y and rr.y < list.y + list.h:
      let hov = ui.hover(rr) and inList
      ui.rect(rr, if n == a.className: colAccentDim elif hov: colHover else: colPanelRaised)
      var note = ""
      if n in edited: note = "edited"
      if used[n] > 0: note.add (if note.len > 0: " · " else: "") & $used[n] & "× in level"
      let nw = if note.len > 0: ui.textSize(note, FontSmall).x + 12 else: 0'f32
      ui.textIn(ui.ellipsize(n.classLabel, rr.w - nw - 14, FontSmall), rect(rr.x + 8, rr.y, rr.w - nw - 8, rr.h),
                colText, FontSmall)
      if note.len > 0:
        ui.textIn(note, rect(rr.x + rr.w - nw, rr.y, nw - 6, rr.h),
                  if n in edited: colAccent else: colTextDim, FontSmall)
      if hov and ui.pressed():
        ui.consumeClick()
        a.classCursor = k
        a.className = n
    y += ClassRowH
  if rows.len == 0: ui.textIn("No class matches", rect(list.x + 12, list.y + 4, list.w - 24, 22), colTextDim, FontSmall)
  discard ui.listNav("class.list", list, nav, a.classCursor)
  if listFocused and a.classCursor in 0 ..< nav.len:
    ui.cursorRing(nav[a.classCursor])
    if ui.navActivate("class.list"): a.className = rows[a.classCursor]
  ui.popClip()
  ui.scrollbar("class.list", list, a.classListScroll, contentH)

# --- inspector: face -----------------------------------------------------------------------

proc applyToFaces(a: App, label: string, fn: proc(fi: int)) =
  let faces = a.selectedFaceSet
  if faces.len == 0 or a.geo == nil: return
  let before = a.geo.clone
  for fi in faces: fn(fi)
  a.geo.bump()
  a.push geoCmd(label, before, a.geo)

proc faceKey(a: App, faces: HashSet[int]): seq[int] =
  result = faces.toSeq
  result.sort

proc faceEdit(a: App, label: string, fn: proc(fi: int)) =
  ## A live edit from a Face tab field. Repeats of the same edit on the same
  ## faces (wheel steps, typing) merge into one undo step.
  let faces = a.selectedFaceSet
  if faces.len == 0 or a.geo == nil: return
  let key = a.faceKey(faces)
  let u = a.faceUndo
  let merge = u.label == label and u.geo == a.geo and u.version == a.geo.version and
              u.faces == key and u.depth == a.undoStack.len and a.undoStack.len > 0 and
              a.cleanAt != a.undoStack.len and a.redoStack.len == 0 and
              a.undoStack[^1].geoBefore != nil
  let before = if merge: nil else: a.geo.clone
  for fi in key: fn(fi)
  a.geo.bump()
  if merge: a.amendLast()
  else: a.push geoCmd(label, before, a.geo)
  a.faceUndo = (label, a.geo, a.geo.version, a.undoStack.len, key)

proc drawFaceProps(a: App, x, y0, w: float32): float32 =
  ## Properties for selected faces (or pieces): texture mapping, flags, script
  ## id, shade and tint. Returns where the rows end.
  let ui = a.ui
  let faces = a.selectedFaceSet
  var y = y0
  # Shows the face clicked last, or else any selected one.
  var first = a.lastFace
  if first notin faces:
    for fi in faces:
      first = fi
      break
  let f0 = a.geo.faces[first]
  a.loadThumbnails()
  let size = a.texSizeText(f0.texture)
  a.propText("Selected", &"{faces.len} face(s)", x, y, w)
  a.propText("Texture", f0.texture & (if size.len > 0: " · " & size else: ""), x, y, w)
  # Texture mapping, absolute and live: shown for the first face, an edit
  # sets that one value on every selected face.
  let key = a.faceKey(faces)
  if a.texFramesFor.geo != a.geo or a.texFramesFor.version != a.geo.version or
     a.texFramesFor.faces != key:
    a.texFrames.clear()
    for fi in key: a.texFrames[fi] = a.geo.texFrame(fi, a.density(a.geo.faces[fi].texture))
    a.texFramesFor = (a.geo, a.geo.version, key)
  var shown = TexFrame(scale: [1.0, 1.0])
  if a.texFrames[first].ok: shown = a.texFrames[first]
  else:
    for fi in key:
      if a.texFrames[fi].ok:
        shown = a.texFrames[fi]
        break
  let names = ["Shift U", "Shift V", "Scale U", "Scale V", "Rotation°"]
  let tips = ["Offset along U, in texture repeats (0–1 wraps around)",
              "Offset along V, in texture repeats (0–1 wraps around)",
              "Texture size along U: 1 = World align's, 2 = twice as big, negative = flipped",
              "Texture size along V: 1 = World align's, 2 = twice as big, negative = flipped",
              "Texture rotation in degrees"]
  # One row per pair: Shift U/V, Scale U/V, then Rotation.
  var vr: Rect
  for i in 0 .. 4:
    case i
    of 0: vr = a.propName("Shift", x, y, w, "Offset in texture repeats (U, V). Arrows move textures, " &
                          "PgUp/PgDn rotate (Shift coarse, Ctrl fine).")
    of 2: vr = a.propName("Scale", x, y, w, "Texture size (U, V): 1 = World align's, 2 = twice as big, " &
                          "negative = flipped")
    of 4: vr = a.propName("Rotation", x, y, w, "Texture rotation in degrees")
    else: discard
    let pw = if i == 4: vr.w else: (vr.w - 2) / 2
    let fr = rect(vr.x + (if i < 4: (i mod 2).float32 * (pw + 2) else: 0), y, pw, 26)
    ui.tip(fr, tips[i])
    var v = case i
      of 0, 1: shown.shift[i]
      of 2, 3: shown.scale[i - 2]
      else: shown.rot
    let (step, decimals) = if i < 2: (0.0625, 4) elif i < 4: (0.25, 4) else: (15.0, 2)
    if ui.numberField("face.uv." & $i, fr, v, step, -1000, 1000, decimals,
                      axis = (if i < 4: i mod 2 else: -1), live = true):
      if not (i in 2 .. 3 and abs(v) < 1e-4):  # No zero scale.
        let app = a
        let (val, idx) = (v, i)
        a.faceEdit(names[i], proc(fi: int) =
          let old = app.texFrames.getOrDefault(fi)
          if not old.ok: return
          var t = old
          case idx
          of 0, 1: t.shift[idx] = val
          of 2, 3: t.scale[idx - 2] = val
          else: t.rot = val
          app.texFrames[fi] = app.geo.setTexFrame(fi, old, t))
        a.texFramesFor.version = a.geo.version
    if i mod 2 == 1 or i == 4: y += 30
  let br = a.propName("Adjust", x, y, w, "Flip the textures along U or V, or World align them " &
                      "(project them from the nearest axis, at the texture's usual size)")
  let bw = (br.w - 4) / 3
  if ui.textButton("face.flipu", rect(br.x, y, bw, 26), "Flip U"):
    let app = a
    a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(-1, 1), 0))
  if ui.textButton("face.flipv", rect(br.x + bw + 2, y, bw, 26), "Flip V"):
    let app = a
    a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(1, -1), 0))
  let ar = rect(br.x + 2 * (bw + 2), y, bw, 26)
  if ui.textButton("face.align", ar, "Align"):
    let app = a
    a.applyToFaces("Align texture", proc(fi: int) =
      app.geo.projectUVs(fi, app.density(app.geo.faces[fi].texture)))
  ui.tip(ar, "World align")
  y += 30
  # Script id and shade.
  let sr = a.propName("Script id", x, y, w, "For env_show and friends; 0 = none")
  var sid = f0.scriptId.float
  if ui.numberField("face.script", sr, sid, 1, int32.low.float, int32.high.float, live = true):
    let app = a
    let n = int32(sid)
    a.faceEdit("Script id", proc(fi: int) = app.geo.faces[fi].scriptId = n)
  y += 30
  var uniq: seq[string]
  for fi in key:
    let cs = a.geo.faces[fi].colors
    if cs.len == 0: continue
    let t = fmtRgb([cs[0][0].int, cs[0][1].int, cs[0][2].int])
    if t notin uniq and uniq.len < 32: uniq.add t
  var text = if uniq.len == 1: uniq[0] else: ""
  let shadeR = a.propName("Shade", x, y, w, "Baked light color of the whole face, every corner (0–255)")
  let app = a
  let target = ColorTarget(
    live: proc(c: RGB) =
      app.faceEdit("Shade", proc(fi: int) =
        for col in app.geo.faces[fi].colors.mitems:
          for ch in 0 .. 2: col[ch] = uint8(clamp(c[ch], 0, 255))),
    done: proc(changed: bool) = discard)
  let ev = ui.colorField("face.shade", shadeR, text, target, if uniq.len > 1: uniq.join(";") else: "")
  if eeCommitted in ev:
    let (ok, c) = parseColor(text)
    if ok:
      let ch = colorComponent
      a.faceEdit("Shade " & ["red", "green", "blue"][max(0, ch)], proc(fi: int) =
        for col in app.geo.faces[fi].colors.mitems:
          for k in 0 .. 2:
            if ch < 0 or ch == k: col[k] = uint8(clamp(c[k], 0, 255)))
  y += 30
  # Tint: the surface's own color, multiplied into whatever light it gets.
  var tints: seq[string]
  for fi in key:
    let t = a.geo.faces[fi].tint
    let s = fmtRgb([t[0].int, t[1].int, t[2].int])
    if s notin tints and tints.len < 32: tints.add s
  var tintText = if tints.len == 1: tints[0] else: ""
  let tintR = a.propName("Tint", x, y, w, "The surface's color: the light its corners get (lights, " &
    "ambient, shade, animations) is multiplied by it, in the views and the game. 255 255 255 = none.")
  proc setTint(fi: int, c: RGB, ch: int) =
    var t = app.geo.faces[fi].tint
    for k in 0 .. 2:
      if ch < 0 or ch == k: t[k] = uint8(clamp(c[k], 0, 255))
    app.geo.faces[fi].tint = t
  let tintTarget = ColorTarget(
    live: proc(c: RGB) = app.faceEdit("Tint", proc(fi: int) = setTint(fi, c, -1)),
    done: proc(changed: bool) = discard)
  let tev = ui.colorField("face.tint", tintR, tintText, tintTarget, if tints.len > 1: tints.join(";") else: "")
  if eeCommitted in tev:
    let (ok, c) = parseColor(tintText)
    if ok:
      let ch = colorComponent
      a.faceEdit("Tint " & ["red", "green", "blue"][max(0, ch)], proc(fi: int) = setTint(fi, c, ch))
  y += 30
  # Flags.
  a.propGroup("Surface flags", x, y, w)
  let cellW = (w - 10) / 2
  for i, (name, bit, desc) in EditableFlags:
    var (any, all) = (false, true)
    for fi in faces:
      if (a.geo.faces[fi].flags and bit) != 0: any = true
      else: all = false
    var v = all
    let cx = x + (i mod 2).float32 * (cellW + 10)
    if ui.checkbox("face.flag." & name, vec2(cx, y + 1), ui.ellipsize(name, cellW - 24), v,
                   mixed = any and not all):
      let on = v
      a.applyToFaces(name, proc(fi: int) =
        if on: app.geo.faces[fi].flags = app.geo.faces[fi].flags or bit
        else: app.geo.faces[fi].flags = app.geo.faces[fi].flags and not bit)
    ui.tip(rect(cx, y, cellW, 26), name & ": " & desc)
    if i mod 2 == 1 or i == EditableFlags.high: y += 28
  y

proc pickedGroup(a: App): int32 =
  ## The group whose Map row was clicked, while the selection is still that group.
  let g = a.groupPicked
  if g == 0 or a.groupAt(g) < 0 or a.selFaces.len > 0: return 0
  for gid in [g, a.unitOf(g)]:
    if gid == 0: continue
    let (objs, pieces) = a.members(gid)
    if objs.len + pieces.len > 0 and objs.len == a.selection.len and pieces.len == a.selPieces.len and
       objs.allIt(it.selected) and pieces.allIt(it in a.selPieces): return g

proc drawGroupProps(a: App, r: Rect, gid: int32) =
  ## Properties for a group picked in the Map tab: its own name and contents.
  let ui = a.ui
  let g = a.groups[a.groupAt(gid)]
  ui.sectionTitle(rect(r.x, r.y, r.w, 26), "Group")
  let (x, w) = (r.x + 10, r.w - 20)
  a.scrolledRows("props.group", rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26)), a.propsScroll,
                 proc(y0: float32): float32 =
    var y = y0
    let id = "group.name." & $gid
    if ui.focusId != id: a.groupNameText = g.name
    let vr = a.propName("Name", x, y, w, "The group's name in the Map tab and the views")
    let ev = ui.textField(id, vr, a.groupNameText)
    if eeCommitted in ev and a.groupNameText.strip.len > 0 and a.groupNameText != g.name:
      a.renameGroup(gid, a.groupNameText.strip)
    y += 30
    let spinId = "group.spin." & $gid
    if ui.focusId != spinId: a.groupSpinText = if g.spin == 0: "" else: $g.spin
    let sr = a.propName("Spin", x, y, w, "Seconds per turn around the group's center in the game, " &
                        "negative for the other way, empty for none. Particles in the group turn with it (not decals). " &
                        "New levels only; particles need Arklite.")
    if eeCommitted in ui.textField(spinId, sr, a.groupSpinText):
      let t = a.groupSpinText.strip
      try:
        let s = if t.len == 0: 0'f32 else: parseFloat(t).float32
        if s == 0 or abs(s) >= MinSpinSeconds:
          if s != g.spin: a.setGroupSpin(gid, s)
        else: a.say(&"Spin must be at least {MinSpinSeconds} seconds per turn", true)
      except ValueError: a.say("Spin takes a number of seconds per turn", true)
    y += 30
    let (objs, pieces) = a.members(gid)
    a.propText("Objects", $objs.len, x, y, w)
    a.propText("Pieces", $pieces.len, x, y, w)
    if g.parent != 0: a.propText("Inside", a.groupName(g.parent), x, y, w)
    let links = a.linkedCount(gid)
    if links > 1: a.propText("Linked copies", $links, x, y, w)
    let (ok, lo, hi) = a.groupBounds(gid)
    if ok: a.propText("Size", fmtVec(hi - lo), x, y, w)
    y += 4
    if ui.textButton("group.ungroup", rect(x, y, 96, 26), "Ungroup"): a.ungroupSelection()
    y + 30)

proc selectionGroup(a: App): (int32, bool) =
  ## The group the selection is in (0 = none), and whether its parts are in
  ## different ones.
  var seen: HashSet[int32]
  for o in a.selection: seen.incl a.objGroup(o)
  for pc in a.selPieces: seen.incl a.pieceGroup(pc)
  if a.geo != nil:
    for fi in a.selFaces:
      if fi in 0 .. a.geo.faces.high: seen.incl a.pieceGroup(a.geo.faces[fi].piece)
  seen.excl 0
  if seen.len == 1:
    for g in seen: return (g, false)
  (0'i32, seen.len > 1)

proc drawProperties(a: App, r0: Rect) =
  ## What's selected, under a header naming it: objects (their type), the
  ## vertex tools' handles, faces, or with nothing selected the level. A group
  ## picked in the Map tab has its own page; anything else that's in a group
  ## has the group's name above it.
  let ui = a.ui
  a.drop.live = false
  var r = r0
  let picked = a.pickedGroup
  if picked != 0:
    a.fieldObj = nil
    a.fieldSel = @[]
    a.drawGroupProps(r, picked)
    return
  let (inGroup, severalGroups) = a.selectionGroup
  if inGroup != 0 or severalGroups:
    var path = a.groupName(inGroup)
    var g = if inGroup != 0: a.groups[a.groupAt(inGroup)].parent else: 0
    while g != 0 and a.groupAt(g) >= 0:
      path = a.groupName(g) & " / " & path
      g = a.groups[a.groupAt(g)].parent
    let strip = rect(r.x, r.y, r.w, 26)
    ui.rect(strip, colAccentDim)
    ui.icon("folder16", vec2(strip.x + 16, strip.y + 13), colText)
    ui.textIn(ui.ellipsize(if severalGroups: "Several groups" else: path, strip.w - 36),
              rect(strip.x + 30, strip.y, strip.w - 36, strip.h), colText)
    ui.tip(strip, "The group the selection is in")
    r = rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26))
  let vertexColors = a.geo != nil and a.tool in {toolVertex, toolEdge, toolFace} and a.selHandles.len > 0
  let body = rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26))
  let (x, w) = (r.x + 10, r.w - 20)
  if vertexColors:
    a.fieldObj = nil
    a.fieldSel = @[]
    ui.sectionTitle(rect(r.x, r.y, r.w, 26), $a.tool)
    let app = a
    a.scrolledRows("props.vertex", body, a.propsScroll, proc(y: float32): float32 =
      app.drawVertexColors(x, y, w))
  elif a.selection.len > 0:
    a.drawObjectsPage(r)
  elif a.geo != nil and a.selectedFaceSet.len > 0:
    a.fieldObj = nil
    a.fieldSel = @[]
    ui.sectionTitle(rect(r.x, r.y, r.w, 26), "Face")
    let app = a
    a.scrolledRows("props.face", body, a.faceScroll, proc(y: float32): float32 =
      app.drawFaceProps(x, y, w))
  else:
    a.fieldObj = nil
    a.fieldSel = @[]
    a.drawLevelInfo(r)

var usedTex: HashSet[string]
var usedTexGeo: Geometry
var usedTexVersion = -1

proc usedTextures(a: App): HashSet[string] =
  ## The textures the level's faces use, kept until the geometry changes.
  if a.geo == nil: return
  if usedTexGeo != a.geo or usedTexVersion != a.geo.version:
    usedTex.clear()
    for fc in a.geo.faces: usedTex.incl fc.texture
    usedTexGeo = a.geo
    usedTexVersion = a.geo.version
  usedTex

proc drawTextureBrowser(a: App, br: Rect) =
  ## The enabled collections' textures: click one to apply it to the selected faces.
  let ui = a.ui
  let faces = a.selectedFaceSet
  let collR = rect(br.x + br.w - 96, br.y + 2, 92, 22)
  let cleanW = ui.textSize("Clean up unused").x + 20
  let cleanR = rect(collR.x - 4 - cleanW, br.y + 2, cleanW, 22)
  ui.sectionTitle(rect(br.x, br.y, br.w, 26),
                  ui.ellipsize("Click to apply to the selected faces", max(0'f32, cleanR.x - br.x - 12), FontSmall))
  if ui.textButton("tex.collections", collR, "Collections"): a.showPanel(pkTextureCollections)
  ui.tip(collR, "Which texture collections are listed here")
  # Drops the enabled game levels whose textures no face uses; the extracted
  # textures stay on disk, so adding one back is instant.
  if ui.textButton("tex.cleanup", cleanR, "Clean up unused") and a.proj != nil:
    var used: HashSet[string]
    if a.geo != nil:
      for fc in a.geo.faces: used.incl fc.texture
    var dropped: seq[string]
    for c in a.texCollections:
      if c.level != 0 and c.id in a.proj.textureCollections and c.ready and
         not c.textures.anyIt(it in used):
        dropped.add c.id
    if dropped.len == 0:
      a.say("Every enabled level collection has a texture in use")
    else:
      var names: seq[string]
      for c in a.texCollections:
        if c.id in dropped: names.add c.name
      a.proj.textureCollections.keepItIf(it notin dropped)
      a.proj.save()
      for id in dropped: a.collEnabled.excl id
      a.say("Removed unused collections: " & names.join(", "))
  ui.tip(cleanR, "Remove the level collections none of whose textures the level uses " &
                 "(their textures stay extracted; add them back in Collections)")
  discard ui.textField("tex.filter", rect(br.x + 8, br.y + 32, max(40'f32, br.w - 276), 26), a.texFilter,
                       "Search name or size...")
  let alphaR = rect(br.x + br.w - 260, br.y + 32, 56, 26)
  let usedR = rect(br.x + br.w - 200, br.y + 32, 56, 26)
  let groupR = rect(br.x + br.w - 140, br.y + 32, 60, 26)
  let importR = rect(br.x + br.w - 76, br.y + 32, 68, 26)
  if ui.textButton("tex.alpha", alphaR, "Alpha"): a.texAlphaOnly = not a.texAlphaOnly
  if a.texAlphaOnly: ui.border(alphaR, colAccent, 2)
  ui.tip(alphaR, "Only transparent textures: ones with see-through pixels, like glass and grates")
  if ui.textButton("tex.used", usedR, "Used"): a.texUsedOnly = not a.texUsedOnly
  if a.texUsedOnly: ui.border(usedR, colAccent, 2)
  ui.tip(usedR, "Only textures the level uses")
  if ui.textButton("tex.group", groupR, "Group"): a.texGroup = not a.texGroup
  if a.texGroup: ui.border(groupR, colAccent, 2)
  ui.tip(groupR, "Group textures by collection")
  if ui.textButton("tex.import", importR, "Import") and a.dialog == nil and a.proj != nil:
    a.dialog = startDialog(dkOpenFiles, "textures", "Import textures", getHomeDir(),
                           @DirectFormats & @OniSplitFormats, "Images")
  ui.tip(importR, &"Import pictures as textures: PNG, JPG, BMP, GIF, QOI, PPM, TGA, DDS or TIFF. " &
                  &"Sides become powers of 2, at most {MaxTextureSide}.")
  let list = rect(br.x, br.y + 64, br.w, br.h - 64)
  if a.proj == nil: return
  a.loadThumbnails()
  let f = a.texFilter.strip.toLowerAscii
  let used = a.usedTextures
  # The current texture: the selected faces' (red border), else the one picked.
  var current = a.currentTexture
  for fi in faces:
    current = a.geo.faces[fi].texture
    break
  var shown: seq[string]
  var shownIn: seq[int]    # Its collection.
  # The search also matches sizes: "256" or "128x" (an x stands for ×).
  let fs = f.replace("x", "×")
  for (t, ci) in a.enabledTextures:
    if (f.len == 0 or f in t.toLowerAscii or (fs.len > 0 and fs in a.texSizeText(t))) and
       (not a.texUsedOnly or t in used) and (not a.texAlphaOnly or a.texAlpha.getOrDefault(t)):
      shown.add t
      shownIn.add ci
  # Where everything goes at a tile size, in the list's own coordinates: a
  # new collection starts a new row under its heading.
  const HeadH = 24'f32
  proc layout(thumb: float32): (seq[Rect], seq[(float32, string)], float32) =
    let cell = thumb + 18
    let rowStep = cell + 14
    let cols = max(1, int((list.w - 8) / cell))
    var cells = newSeq[Rect](shown.len)
    var heads: seq[(float32, string)]
    var (top, col, lastIn) = (4'f32, 0, -1)
    for i in 0 ..< shown.len:
      if a.texGroup and shownIn[i] != lastIn:
        if col > 0: (top, col) = (top + rowStep, 0)
        heads.add (top, a.texCollections[shownIn[i]].name)
        top += HeadH
        lastIn = shownIn[i]
      cells[i] = rect(list.x + 6 + col.float32 * cell, top, cell - 6, cell - 6)
      inc col
      if col == cols: (top, col) = (top + rowStep, 0)
    (cells, heads, top + (if col > 0: rowStep else: 0))
  # Ctrl+wheel over the list zooms the tiles. The texture under the pointer
  # (else the nearest one) stays under it.
  var (anchor, anchorFrac, anchorAt) = (-1, 0'f32, 0'f32)
  if ui.hover(list) and not ui.scrollConsumed and ui.window.ctrlDown and ui.wheelNotches != 0:
    let (oldCells, _, _) = layout(a.texThumb)
    let m = vec2(ui.mouse.x, ui.mouse.y - list.y + a.texScroll)
    var best = Inf.float32
    for i, c in oldCells:
      let dx = max(0'f32, max(c.x - m.x, m.x - c.x - c.w))
      let dy = max(0'f32, max(c.y - m.y, m.y - c.y - c.h))
      let d = dx * dx + dy * dy
      if d < best: (best, anchor) = (d, i)
    if anchor >= 0:
      let c = oldCells[anchor]
      anchorFrac = clamp((m.y - c.y) / c.h, 0, 1)
      anchorAt = ui.mouse.y - list.y
    a.texThumb = clamp(a.texThumb * pow(1.25'f32, -ui.wheelNotches), MinTexThumb, MaxTexThumb)
    ui.scrollConsumed = true
  let thumb = a.texThumb
  let cell = thumb + 18
  var (cells, heads, contentH) = layout(thumb)
  if anchor >= 0:
    let c = cells[anchor]
    a.texScroll = c.y + anchorFrac * c.h - anchorAt
  if ui.hover(list) and not ui.scrollConsumed: a.texScroll += ui.wheelNotches * cell
  ui.scrollArea("tex.list", list, a.texScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.texScroll)
  a.texScroll = clamp(a.texScroll, 0, max(0, contentH - list.h))
  for c in cells.mitems: c.y += list.y - a.texScroll
  proc apply(t: string) =
    a.currentTexture = t
    a.adoptTexture(t)
    # Picked with no face selected: new geometry gets this texture.
    if faces.len == 0 and a.faceTemplate.texture.len > 0: a.faceTemplate.texture = t
    if faces.len > 0:
      let app = a
      a.applyToFaces("Apply texture", proc(fi: int) =
        app.geo.retexture(fi, t, app.densityFn))
  # One Tab stop: the arrow keys move through the textures, Space/Enter apply one.
  let listFocused = ui.tabStop("tex.list", list)
  for (hy, name) in heads:
    let y = list.y + hy - a.texScroll
    if y + HeadH < list.y or y > list.y + list.h: continue
    ui.textIn(ui.ellipsize(name, list.w - 16), rect(list.x + 8, y, list.w - 16, HeadH - 4), colAccent, FontSmall)
    ui.rect(rect(list.x + 8, y + HeadH - 5, list.w - 16, 1), colBorder)
  for i, t in shown:
    let r = cells[i]
    let (cx, cy) = (r.x, r.y)
    if cy + cell + 14 < list.y or cy > list.y + list.h: continue
    # TrenchBroom's borders: red for the current texture, yellow for used ones.
    if t == current: ui.rect(rect(r.x - 2, r.y - 2, r.w + 4, r.h + 4), pm(255, 60, 60))
    elif t in used: ui.rect(rect(r.x - 2, r.y - 2, r.w + 4, r.h + 4), pm(240, 200, 40))
    let key = "tex:" & t
    if key in ui.sk.atlas.entries:
      let e = ui.sk.atlas.entries[key]
      ui.sk.drawQuad(r.xy + vec2(5, 5), vec2(thumb, thumb), vec2(e.x.float32, e.y.float32),
                     vec2(e.width.float32, e.height.float32), rgbx(255, 255, 255, 255))
    else: ui.rect(r, colPanelRaised)
    # Its resolution, on a dark badge in the thumbnail's lower right corner.
    let size = a.texSizeText(t)
    if size.len > 0:
      let ts = ui.textSize(size, FontSmall)
      let badge = rect(r.x + r.w - 5 - ts.x - 6, r.y + r.h - 5 - ts.y - 1, ts.x + 6, ts.y + 1)
      ui.rect(badge, pm(0, 0, 0, 190))
      ui.text(size, vec2(badge.x + 3, badge.y), colText, FontSmall)
    ui.text(ui.ellipsize(t, cell - 4, FontSmall), vec2(cx, cy + cell - 6), colTextDim, FontSmall)
    if ui.hover(r) and ui.pressed():
      ui.consumeClick()
      a.texCursor = i
      apply(t)
    if ui.hover(r) and ui.pressed(MouseRight):
      a.texCursor = i
      a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, texture: t)
      a.menuSys.openContext(ui.mouse)
    ui.tip(r, t & (if size.len > 0: " · " & size else: "") & (if t in used: " (used)" else: ""))
  discard ui.listNav("tex.list", list, cells, a.texCursor)
  if listFocused and a.texCursor in 0 ..< shown.len:
    let c = cells[a.texCursor]
    ui.cursorRing(rect(c.x - 3, c.y - 3, c.w + 6, c.h + 6))
    if ui.navActivate("tex.list"): apply(shown[a.texCursor])
  ui.popClip()
  ui.scrollbar("tex.list", list, a.texScroll, contentH)

proc drawTextureCollections(a: App, r: Rect) =
  ## TrenchBroom's material collection editor: what's available above, what's
  ## enabled below, in the Texture Browser's order. Double-click moves a row;
  ## Ctrl+click selects several.
  let ui = a.ui
  if a.proj == nil: return
  let p = a.proj
  proc rowOf(id: string): int =
    for i, c in a.texCollections:
      if c.id == id: return i
    -1
  proc enable(ids: seq[string]) =
    var missing: seq[int]
    for id in ids:
      if id in p.textureCollections or rowOf(id) < 0: continue
      p.textureCollections.add id
      let c = a.texCollections[rowOf(id)]
      # Extracted before the library took levels this way: its classes still join.
      if not c.ready or (c.level > 0 and libraryBuilt() and c.level notin libraryLevels()):
        missing.add c.level
    p.save()
    a.collAvailable.clear()
    a.thumbsLoaded = false
    if missing.len > 0: a.extractCollections(missing)
  proc disable(ids: seq[string]) =
    p.textureCollections.keepItIf(it notin ids)
    p.save()
    a.collEnabled.clear()
  proc move(dir: int) =
    # Selected rows keep their order; the first or last one can't pass the end.
    let order = if dir < 0: toSeq(0 .. p.textureCollections.high)
                else: toSeq(countdown(p.textureCollections.high, 0))
    for i in order:
      let j = i + dir
      if p.textureCollections[i] in a.collEnabled and j in 0 .. p.textureCollections.high and
         p.textureCollections[j] notin a.collEnabled:
        swap(p.textureCollections[i], p.textureCollections[j])
    p.save()
  proc list(id, title: string, area: Rect, ids: seq[string], pick: var HashSet[string],
            scroll: var float32, action: proc(ids: seq[string])) =
    ui.sectionTitle(rect(area.x, area.y, area.w, 26), title)
    let body = rect(area.x, area.y + 26, area.w, area.h - 26)
    const rowH = 24'f32
    let contentH = ids.len.float32 * rowH
    if ui.hover(body) and not ui.scrollConsumed: scroll += ui.wheelNotches * rowH * 2
    ui.scrollArea(id, body, scroll)
    scroll = clamp(scroll, 0, max(0, contentH - body.h))
    ui.pushClip(body)
    for i, cid in ids:
      let c = rowOf(cid)
      if c < 0: continue
      let col = a.texCollections[c]
      let rr = rect(body.x, body.y + i.float32 * rowH - scroll, body.w, rowH)
      let on = cid in pick
      ui.rect(rr, if on: colAccentDim elif ui.hover(rr): colHover else: colPanel)
      let n = if col.ready: &"{col.textures.len} textures" else: "not extracted yet"
      ui.textIn(ui.ellipsize(col.name, rr.w * 0.6), rect(rr.x + 10, rr.y, rr.w * 0.6, rowH), colText)
      ui.textIn(n, rect(rr.x + rr.w * 0.6, rr.y, rr.w * 0.4 - 10, rowH), colTextDim, FontSmall, h = RightAlign)
      if ui.hover(rr) and ui.pressed():
        ui.consumeClick()
        let dbl = ui.countClick(id & cid) >= 2
        if ui.window.ctrl:
          if on: pick.excl cid else: pick.incl cid
        else:
          pick.clear()
          pick.incl cid
        if dbl:
          action(@[cid])
          break
    ui.popClip()
    ui.scrollbar(id, body, scroll, contentH)
  const BarH = 34'f32
  let half = (r.h - 2 * BarH) / 2
  let upper = rect(r.x, r.y, r.w, half)
  let lower = rect(r.x, r.y + half + BarH, r.w, half)
  var available: seq[string]
  for c in a.texCollections:
    if c.id notin p.textureCollections: available.add c.id
  list("coll.a.", "Available", upper, available, a.collAvailable, a.collScroll[0],
       proc(ids: seq[string]) = enable(ids))
  let y1 = upper.y + upper.h + 4
  if ui.textButton("coll.add", rect(r.x + 8, y1, 70, 26), "Add"):
    enable(a.collAvailable.toSeq)
  list("coll.e.", "Enabled", lower, p.textureCollections, a.collEnabled, a.collScroll[1],
       proc(ids: seq[string]) = disable(ids))
  let y2 = lower.y + lower.h + 4
  var x = r.x + 8
  if ui.textButton("coll.remove", rect(x, y2, 80, 26), "Remove"): disable(a.collEnabled.toSeq)
  x += 84
  if ui.textButton("coll.up", rect(x, y2, 50, 26), "Up"): move(-1)
  x += 54
  if ui.textButton("coll.down", rect(x, y2, 60, 26), "Down"): move(1)
  x += 64
  let rr = rect(x, y2, 72, 26)
  if ui.textButton("coll.reload", rr, "Reload"):
    a.textures.setLen 0
    for f in walkFiles(p.imagesDir / "*.tga"):
      if not f.splitFile.name.startsWith("bnv_grid"): a.textures.add f.splitFile.name
    a.textures.sort
    a.refreshCollections()
  ui.tip(rr, "Read the textures from disk again")

# --- inspector: files ---------------------------------------------------------------------

type FileRow = object
  path: string       ## Relative to the project folder.
  name: string
  depth: int
  dir: bool
  size: int64        ## -1: not known (filter results).

proc revealFile(a: App, rel: string) =
  ## Clears the filter and selects rel in the tree, its folders opened.
  a.filesFilter = ""
  var d = rel.parentDir
  while d.len > 0 and d != ".":
    a.filesOpen.incl d
    d = d.parentDir
  a.filesSel = rel
  a.filesCursor = -1   # Found by path next frame.

proc fileContextTree(a: App, rel: string): MenuNode =
  ## Right click in the Files tab ("." = the project folder itself).
  result = newMenuRoot()
  if a.proj == nil: return
  let path = if rel == ".": a.proj.dir else: a.proj.dir / rel
  let isDir = dirExists(path)
  let shown = a.filesFilter.strip.len > 0
  if isDir and rel != ".":
    result.item(if rel in a.filesOpen: "Collapse" else: "Expand", action = proc() =
      if rel in a.filesOpen: a.filesOpen.excl rel else: a.filesOpen.incl rel)
  if not isDir and rel.toLowerAscii.endsWith(".bsl"):
    result.item("Open in the Scripts panel", action = proc() = a.openScriptAt(path, 0, 0))
    result.item("Open with the default app", action = proc() = openPath(path))
  else:
    result.item(if isDir: "Open in file manager" else: "Open", action = proc() = openPath(path))
  if rel != ".":
    result.item("Show in file manager", action = proc() = showInFolder(path))
    if shown: result.item("Reveal in tree", action = proc() = a.revealFile(rel))
  result.sep()
  result.item("Copy path", action = proc() = setClipboardString(path))
  if rel != ".": result.item("Copy relative path", action = proc() = setClipboardString(rel))
  result.sep()
  result.item("Collapse all", enabled = a.filesOpen.len > 0, action = proc() = a.filesOpen.clear())
  result.item("Refresh", action = proc() =
    a.fileCache.clear())

proc drawFilesTab(a: App, r: Rect) =
  ## The project folder as a tree, like an IDE's file panel: double-click or
  ## Enter opens a file with its default application; right click for more.
  let ui = a.ui
  if a.proj == nil:
    ui.textIn("No project open", rect(r.x, r.y + 12, r.w, 22), colTextDim, h = CenterAlign)
    return
  let root = a.proj.dir
  var y = r.y
  ui.sectionTitle(rect(r.x, y, r.w, 26), a.proj.folder)
  if ui.iconButton("files.refresh", rect(r.x + r.w - 26, y + 3, 20, 20), "loop16", "Refresh",
                   focusable = false):
    a.fileCache.clear()
  y += 30
  discard ui.textField("files.filter", rect(r.x + 8, y, r.w - 16, 26), a.filesFilter, "Search files...")
  y += 32
  let footH = 40'f32
  let list = rect(r.x, y, r.w, max(0'f32, r.y + r.h - y - footH))
  let rowH = 22'f32

  var rows: seq[FileRow]
  let f = a.filesFilter.strip.toLowerAscii
  if f.len > 0:
    a.fileCache.refreshAll(root)
    for p in a.fileCache.all:
      if f in p.toLowerAscii:
        rows.add FileRow(path: p, name: p, dir: dirExists(root / p), size: -1)
  else:
    proc addDir(rows: var seq[FileRow], rel: string, depth: int) =
      let full = if rel.len == 0: root else: root / rel
      a.fileCache.refresh(full)
      for e in a.fileCache.dirs[full].entries:
        let p = if rel.len == 0: e.name else: rel / e.name
        rows.add FileRow(path: p, name: e.name, depth: depth, dir: e.dir, size: e.size)
        if e.dir and p in a.filesOpen: rows.addDir(p, depth + 1)
    rows.addDir("", 0)
  if a.filesCursor notin 0 ..< rows.len or rows[a.filesCursor].path != a.filesSel:
    a.filesCursor = -1
    for i, row in rows:
      if row.path == a.filesSel: a.filesCursor = i

  proc toggle(row: FileRow) =
    if row.path in a.filesOpen: a.filesOpen.excl row.path else: a.filesOpen.incl row.path
  proc activate(row: FileRow) =
    if f.len > 0 and row.dir: a.revealFile(row.path); a.filesOpen.incl row.path
    elif row.dir: toggle(row)
    elif row.path.toLowerAscii.endsWith(".bsl"): a.openScriptAt(root / row.path, 0, 0)
    else: openPath(root / row.path)

  if ui.hover(list) and not ui.scrollConsumed:
    a.filesScroll += ui.wheelNotches * rowH * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  ui.scrollArea("files.list", list, a.filesScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.filesScroll)
  a.filesScroll = clamp(a.filesScroll, 0, max(0, rows.len.float32 * rowH + 4 - list.h))
  # One Tab stop: Up/Down move through the rows, Left/Right fold a folder (Left
  # on a file goes to its folder), Space/Enter open a file or fold a folder.
  let listFocused = ui.tabStop("files.list", list)
  var clicked = false
  let first = max(0, int(a.filesScroll / rowH))
  for i in first ..< min(rows.len, first + int(list.h / rowH) + 2):
    let row = rows[i]
    let rr = rect(list.x, list.y + i.float32 * rowH - a.filesScroll, list.w, rowH)
    let hov = ui.hover(rr)
    let sel = row.path == a.filesSel
    ui.rect(rr, if sel: colAccentDim elif hov: colHover else: colPanel)
    let x0 = rr.x + 6 + row.depth.float32 * 14
    if row.dir and f.len == 0:
      ui.foldArrow(row.path in a.filesOpen, vec2(x0 + 6, rr.y + rowH / 2))
    ui.icon(if row.dir: "folder16" else: "nofile16", vec2(x0 + 22, rr.y + rowH / 2),
            if row.dir: colAccent else: colTextDim)
    let nx = x0 + 34
    var sizeW = 0'f32
    if not row.dir and row.size >= 0:
      let st = sizeText(row.size)
      sizeW = ui.textSize(st, FontSmall).x + 10
      ui.textIn(st, rect(rr.x + rr.w - sizeW, rr.y, sizeW, rowH), colTextDim, FontSmall)
    let nameW = max(0'f32, rr.x + rr.w - sizeW - nx - 6)
    ui.textIn(ui.ellipsize(row.name, nameW, FontSmall), rect(nx, rr.y, nameW, rowH),
              if row.name.startsWith("."): colTextDim else: colText, FontSmall)
    if hov and ui.pressed():
      ui.consumeClick()
      clicked = true
      a.filesSel = row.path
      a.filesCursor = i
      let dbl = ui.countClick("files." & row.path) >= 2
      if row.dir and f.len == 0 and ui.mouse.x < x0 + 14: toggle(row)
      elif dbl: activate(row)
    if hov and ui.pressed(MouseRight):
      clicked = true
      a.filesSel = row.path
      a.filesCursor = i
      a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, file: row.path)
      a.menuSys.openContext(ui.mouse)
  if not clicked and ui.hover(list) and ui.pressed(MouseRight):
    # Below the rows: the project folder itself.
    a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, file: ".")
    a.menuSys.openContext(ui.mouse)
  var rowRects = newSeq[Rect](rows.len)
  for i in 0 ..< rows.len:
    rowRects[i] = rect(list.x, list.y + i.float32 * rowH - a.filesScroll, list.w, rowH)
  var cur = a.filesCursor
  if ui.listNav("files.list", list, rowRects, cur, horizontal = false) and cur in 0 ..< rows.len:
    a.filesCursor = cur
    a.filesSel = rows[cur].path
  if listFocused and a.filesCursor in 0 ..< rows.len:
    let c = a.filesCursor
    let row = rows[c]
    ui.cursorRing(rowRects[c])
    if ui.navKey("files.list", KeyLeft):
      if row.dir and row.path in a.filesOpen: a.filesOpen.excl row.path
      elif f.len == 0 and row.depth > 0: a.filesSel = row.path.parentDir
    if ui.navKey("files.list", KeyRight) and row.dir and f.len == 0: a.filesOpen.incl row.path
    if ui.navActivate("files.list"): activate(row)
  if rows.len == 0:
    ui.textIn(if f.len > 0: "No files match" else: "Empty folder", rect(list.x, list.y + 8, list.w, 22),
              colTextDim, FontSmall, h = CenterAlign)
  ui.popClip()
  ui.scrollbar("files.list", list, a.filesScroll, rows.len.float32 * rowH + 4)

  # The selected file's details.
  let foot = rect(r.x, list.y + list.h, r.w, footH)
  ui.rect(rect(foot.x, foot.y, foot.w, 1), colBorder)
  if a.filesSel.len > 0:
    let full = root / a.filesSel
    var info = "Not found"
    try:
      let fi = getFileInfo(full)
      let kind = if fi.kind in {pcDir, pcLinkToDir}: "Folder" else: sizeText(fi.size)
      info = kind & " · modified " & fi.lastWriteTime.local.format("yyyy-MM-dd HH:mm")
    except OSError: discard
    ui.text(ui.ellipsize(a.filesSel, r.w - 20, FontSmall), vec2(foot.x + 10, foot.y + 4), colText, FontSmall)
    ui.text(info, vec2(foot.x + 10, foot.y + 20), colTextDim, FontSmall)

proc stamp(t: float): string =
  ## The Console's and Issues list's time column.
  t.fromUnixFloat.local.format("HH:mm:ss")

proc drawConsole(a: App, body: Rect) =
  let ui = a.ui
  let lineH = 18'f32
  var lines = a.log
  if a.busy:
    for l in a.job.logTail(6).splitLines: lines.add LogLine(text: "  " & l)
  if ui.hover(body) and not ui.scrollConsumed: a.logScroll -= ui.wheelNotches * lineH * 3
  # The scrollbar counts from the top; logScroll from the newest line.
  let maxScroll = max(0, lines.len.float32 * lineH - body.h + 8)
  var fromTop = maxScroll - clamp(a.logScroll, 0, maxScroll)
  ui.scrollArea("console", body, fromTop)
  a.logScroll = maxScroll - fromTop
  ui.pushClip(body)
  var up = -a.logScroll  # logScroll grows towards older lines: the contents move down.
  ui.scrollIntoView(up)
  a.logScroll = -up
  let total = lines.len.float32 * lineH
  a.logScroll = clamp(a.logScroll, 0, max(0, total - body.h + 8))
  let bottomY = body.y + body.h - 4 + a.logScroll
  # Lines start after a time column; the running job's log tail has no time.
  let tx = body.x + 10 + ui.textSize("00:00:00", FontSmall).x + 10
  # Selection: a drag selects characters, a double-click a word (a drag then goes
  # by words), a triple-click the whole log. The time column isn't part of it.
  template wordOf(p: (int, int)): (int, int) =
    let s = lines[p[0] - a.logDropped].text
    var (b, e) = (min(p[1], max(s.len - 1, 0)), min(p[1], max(s.len - 1, 0)))
    if s.len > 0:
      let cls = charClass(s[b])
      while b > 0 and charClass(s[b - 1]) == cls: dec b
      while e < s.len and charClass(s[e]) == cls: inc e
    (b, e)
  template mousePos(): (int, int) =
    let i = clamp(floor((ui.mouse.y - bottomY) / lineH).int + lines.len, 0, lines.high)
    (i + a.logDropped, ui.textOffset(lines[i].text, ui.mouse.x - tx, FontSmall))
  if lines.len > 0 and ui.hover(body) and ui.pressed():
    ui.consumeClick()
    let clicks = ui.countClick("console")
    let p = mousePos()
    a.logDrag = clicks
    a.logPressAt = ui.mouse
    a.logLink = (-1, -1)
    if clicks == 1:
      (a.logAnchor, a.logCaret) = (p, p)
      let text = lines[p[0] - a.logDropped].text
      if a.geo != nil and ui.mouse.x >= tx - 4 and ui.mouse.x <= tx + ui.textSize(text, FontSmall).x + 4:
        a.logLink = parseFaceRef(text)
    elif clicks == 2:
      let (b, e) = wordOf(p)
      (a.logAnchor, a.logCaret, a.logWordStart, a.logWord) = ((p[0], b), (p[0], e), (p[0], b), (p[0], e))
    else:
      (a.logAnchor, a.logCaret) = ((a.logDropped, 0), (lines.high + a.logDropped, lines[^1].text.len))
  elif ui.window.buttonPressed[MouseLeft] and not ui.hover(body):
    a.logCaret = a.logAnchor
  if a.logDrag > 0:
    if not ui.down():
      if a.logLink[0] >= 0 and (ui.mouse - a.logPressAt).length <= 4: a.focusFace(a.logLink[0], a.logLink[1])
      a.logDrag = 0
    elif a.logDrag < 3 and lines.len > 0:
      wantCursor = IBeamCursor
      if ui.mouse.y < body.y: a.logScroll += lineH
      elif ui.mouse.y > body.y + body.h: a.logScroll -= lineH
      let p = mousePos()
      if a.logDrag == 1: a.logCaret = p
      else:
        let (b, e) = wordOf(p)
        # Anchored at the double-clicked word: its far end stays selected.
        if p < a.logWord: (a.logAnchor, a.logCaret) = (a.logWord, (p[0], b))
        else: (a.logAnchor, a.logCaret) = (a.logWordStart, (p[0], e))
  let selLo = min(a.logAnchor, a.logCaret)
  let selHi = max(a.logAnchor, a.logCaret)
  let hasSel = selLo != selHi
  # One Tab stop: Up/Down move through the face links, Space/Enter follow one.
  if ui.tabStop("console", body):
    let ctrl = ui.window.ctrlDown
    if ctrl and lines.len > 0 and ui.navKey("console", KeyA):
      (a.logAnchor, a.logCaret) = ((a.logDropped, 0), (lines.high + a.logDropped, lines[^1].text.len))
    if hasSel and ctrl and ui.navKey("console", KeyC):
      var copied: seq[string]
      for n in max(selLo[0], a.logDropped) .. min(selHi[0], lines.high + a.logDropped):
        let s = lines[n - a.logDropped].text
        copied.add s[(if n == selLo[0]: min(selLo[1], s.len) else: 0) ..< (if n == selHi[0]: min(selHi[1], s.len) else: s.len)]
      setClipboardString(copied.join("\n"))
    if hasSel and ui.navKey("console", KeyEscape): a.logCaret = a.logAnchor
    var links: seq[Rect]
    var refs: seq[(int, int)]
    if a.geo != nil:
      for i, l in lines:
        let (face, corner) = parseFaceRef(l.text)
        if face < 0: continue
        let y = bottomY - (lines.len - i).float32 * lineH
        links.add rect(tx - 4, y, ui.textSize(l.text, FontSmall).x + 8, lineH)
        refs.add (face, corner)
    if a.logCursor notin 0 ..< links.len: a.logCursor = links.high
    discard ui.listNav("console", body, links, a.logCursor, horizontal = false)
    if a.logCursor in 0 ..< links.len:
      ui.cursorRing(links[a.logCursor])
      if ui.navActivate("console"): a.focusFace(refs[a.logCursor][0], refs[a.logCursor][1])
  elif ui.hover(body) and ui.window.buttonPressed[MouseLeft]:
    ui.navId = "console"
  for i in countdown(lines.high, 0):
    let y = bottomY - (lines.len - i).float32 * lineH
    if y < body.y - lineH: break
    if y > body.y + body.h: continue
    if lines[i].time > 0:
      ui.text(stamp(lines[i].time), vec2(body.x + 10, y), colTextDim, FontSmall)
    let n = i + a.logDropped
    if hasSel and n >= selLo[0] and n <= selHi[0]:
      let s = lines[i].text
      let x0 = ui.textSize(s[0 ..< (if n == selLo[0]: min(selLo[1], s.len) else: 0)], FontSmall).x
      let x1 = ui.textSize(s[0 ..< (if n == selHi[0]: min(selHi[1], s.len) else: s.len)], FontSmall).x
      ui.rect(rect(tx + x0, y, x1 - x0, lineH), colAccentDim)
    let (face, _) = parseFaceRef(lines[i].text)
    if face >= 0 and a.geo != nil:
      # A link: a click (not a drag) puts that face's corner under the vertex tool.
      let sz = ui.textSize(lines[i].text, FontSmall)
      let hit = rect(tx - 4, y, sz.x + 8, lineH)
      let hot = ui.hover(hit)
      if hot:
        ui.rect(hit, colHover)
        ui.rect(rect(tx, y + sz.y, sz.x, 1), colAccentHover)
      ui.text(lines[i].text, vec2(tx, y), if hot: colAccentHover else: colAccent, FontSmall)
      continue
    ui.text(lines[i].text, vec2(tx, y), if lines[i].error: colError else: colTextDim, FontSmall)
    if ui.hover(rect(tx, y, body.w, lineH)) and ui.hover(body): wantCursor = IBeamCursor
  ui.popClip()
  ui.scrollbar("console", body, maxScroll - a.logScroll, total + 8)

proc drawIssues(a: App, body: Rect) =
  let ui = a.ui
  ui.scrollArea("issues", body, a.issuesScroll)
  ui.pushClip(body)
  if a.issues.len == 0:
    # Stamped with the last check (build), so a stale "no issues" is visible.
    var x = body.x + 10
    if a.issuesTime > 0:
      ui.text(stamp(a.issuesTime), vec2(x, body.y + 6), colTextDim, FontSmall)
      x += ui.textSize("00:00:00", FontSmall).x + 10
    ui.text("No issues found.", vec2(x, body.y + 6), colTextDim, FontSmall)
  # One Tab stop: Up/Down move through the issues, Space/Enter go to one.
  let listFocused = ui.tabStop("issues", body)
  if ui.hover(body) and not ui.scrollConsumed: a.issuesScroll += ui.wheelNotches * 20 * 3
  ui.scrollIntoView(a.issuesScroll)
  a.issuesScroll = clamp(a.issuesScroll, 0, max(0, a.issues.len.float32 * 20 + 8 - body.h))
  proc go(iss: Issue) =
    if iss.report.len > 0:
      showInFolder(iss.report)
    elif iss.mcpPort:
      a.openSettings()
      a.settingsPage = 0
      a.settingsPortMark = true
      ui.focusId = "settings.mcpport#field"
      ui.focusFresh = true
    elif iss.face >= 0: a.focusFace(iss.face, iss.corner)
    else:
      a.clearSelection()
      if iss.obj != nil: iss.obj.selected = true
      a.frameSelection()
  # Columns: time, severity label, text.
  let lx = body.x + 10 + ui.textSize("00:00:00", FontSmall).x + 10
  let tx = lx + ui.textSize("Warning", FontSmall).x + 12
  var rows = newSeq[Rect](a.issues.len)
  for k, iss in a.issues:
    let row = rect(body.x, body.y + 4 + k.float32 * 20 - a.issuesScroll, body.w, 20)
    rows[k] = row
    if row.y + row.h < body.y or row.y > body.y + body.h: continue
    if ui.hover(row):
      ui.rect(row, colHover)
      if ui.pressed():
        ui.consumeClick()
        a.issuesCursor = k
        go(iss)
    ui.text(stamp(iss.time), vec2(body.x + 10, row.y + 2), colTextDim, FontSmall)
    let sevCol = case iss.severity
      of sevError: colError
      of sevWarning: colWarning
      of sevInfo: colTextDim
    ui.text(capitalizeAscii($iss.severity), vec2(lx, row.y + 2), sevCol, FontSmall)
    ui.text(iss.text, vec2(tx, row.y + 2), colText, FontSmall)
  discard ui.listNav("issues", body, rows, a.issuesCursor, horizontal = false)
  if listFocused and a.issuesCursor in 0 ..< rows.len:
    ui.cursorRing(rows[a.issuesCursor])
    if ui.navActivate("issues"): go(a.issues[a.issuesCursor])
  ui.popClip()
  ui.scrollbar("issues", body, a.issuesScroll, a.issues.len.float32 * 20 + 8)

# --- properties ----------------------------------------------------------------------------

# --- dock ------------------------------------------------------------------------------------

proc tabRects(a: App, n: DockNode): seq[Rect] =
  ## The tabs of a panel stack, as its tab bar draws them.
  var x = n.r.x + 6
  for t in n.tabs:
    let w = a.ui.textSize($t).x + 20
    result.add rect(x, n.r.y, w, DockTabH)
    x += w

proc dockTabBar(a: App, n: DockNode) =
  ## A stack's tabs: click one to bring it to the front, drag one to move the
  ## panel. One Tab stop; Left/Right switch tabs while it has keyboard focus.
  let ui = a.ui
  let bar = rect(n.r.x, n.r.y, n.r.w, DockTabH)
  ui.rect(bar, colPanel)
  let id = "dock." & $n.tabs[0]
  let focused = ui.tabStop(id, bar)
  if ui.navKey(id, KeyLeft): n.active = (n.active + n.tabs.len - 1) mod n.tabs.len
  if ui.navKey(id, KeyRight): n.active = (n.active + 1) mod n.tabs.len
  for k, tr in a.tabRects(n):
    let t = n.tabs[k]
    let sel = n.active == k
    let moving = a.dockDragging and a.dockPress.kind == t
    if ui.hover(tr) and ui.pressed():
      n.active = k
      ui.navId = id
      a.dockPress = (true, t, ui.mouse)
      ui.consumeClick()
    ui.textIn($t, tr, if moving: colTextDisabled elif sel: colText else: colTextDim, h = CenterAlign)
    if sel: ui.rect(rect(tr.x + 4, tr.y + tr.h - 2, tr.w - 8, 2), colAccent)
    if sel and focused: ui.cursorRing(rect(tr.x + 1, tr.y + 2, tr.w - 2, tr.h - 4))
  ui.rect(rect(bar.x, bar.y + bar.h - 1, bar.w, 1), colBorder)

proc dockTarget(a: App, area: Rect): (DockNode, DockZone, int) =
  ## Where the dragged tab would go if released now: a stack's tabs (at an
  ## index), a side of a stack, or a side of the whole layout.
  let m = a.ui.mouse
  result = (nil, dzNone, 0)
  if not m.inside(area): return
  const Edge = 16'f32
  if m.x < area.x + Edge: result = (a.dock, dzLeft, 0)
  elif m.x >= area.x + area.w - Edge: result = (a.dock, dzRight, 0)
  elif m.y < area.y + Edge: result = (a.dock, dzTop, 0)
  elif m.y >= area.y + area.h - Edge: result = (a.dock, dzBottom, 0)
  else:
    for l in a.dock.leaves:
      if not m.inside(l.r): continue
      if m.y < l.r.y + DockTabH:
        var idx = l.tabs.len
        for k, tr in a.tabRects(l):
          if m.x < tr.x + tr.w / 2:
            idx = k
            break
        result = (l, dzTabs, idx)
      else:
        let u = (m.x - l.r.x) / l.r.w
        let v = (m.y - l.r.y - DockTabH) / max(1'f32, l.r.h - DockTabH)
        let d = [u, 1 - u, v, 1 - v]
        let k = minIndex(d)
        result = if d[k] < 0.25: (l, [dzLeft, dzRight, dzTop, dzBottom][k], 0)
                 else: (l, dzTabs, l.tabs.len)
      break
  # Onto its own lone stack: nowhere to go.
  let src = a.dock.leafOf(a.dockPress.kind)
  if result[0] != nil and src == result[0] and src.tabs.len == 1: result = (nil, dzNone, 0)

proc drawDockNode(a: App, n: DockNode) =
  let ui = a.ui
  if not n.isLeaf:
    for k in n.kids: a.drawDockNode(k)
    let (dragging, p) = a.divider("dock." & $cast[int](n), n.divider, n.row)
    if dragging:
      let total = (if n.row: n.r.w else: n.r.h) - SplitW
      let start = if n.row: n.r.x else: n.r.y
      if total > 0: n.frac = clamp((p - SplitW / 2 - start) / total, 0.02, 0.98)
    return
  a.dockTabBar(n)
  let body = rect(n.r.x, n.r.y + DockTabH, n.r.w, max(0'f32, n.r.h - DockTabH))
  let kind = n.activeTab
  # The views draw themselves (before the UI): only the tool options strip here.
  if kind != pkViewport: ui.rect(body, colPanel)
  ui.pushClip(body)
  case kind
  of pkViewport:
    a.drawToolOptions(rect(body.x, body.y, body.w, OptionsHeight))
    let views = a.viewsArea
    if views.w > 0:
      for (id, r, vertical) in a.viewDividers(views):
        let (dragging, p) = a.divider(id, r, vertical)
        if dragging:
          if id == "view.x": a.splitX = clamp((p - views.x) / views.w, 0.1, 0.9)
          else: a.splitY = clamp((p - views.y) / views.h, 0.1, 0.9)
  of pkProperties: a.drawProperties(body)
  of pkClasses: a.drawClassesPage(body)
  of pkMap: a.drawMapTab(body)
  of pkFiles: a.drawFilesTab(body)
  of pkEntityBrowser: a.drawEntityBrowser(body)
  of pkTextureBrowser: a.drawTextureBrowser(body)
  of pkTextureCollections: a.drawTextureCollections(body)
  of pkConsole: a.drawConsole(body)
  of pkIssues: a.drawIssues(body)
  of pkScripts: a.drawScripts(body)
  ui.popClip()

proc layoutPanels*(a: App, area: Rect) =
  ## Before drawing: every panel's rect, and the map views' (empty when the
  ## Viewport isn't the front tab of its stack).
  a.dock.layoutDock(area)
  let l = a.dock.leafOf(pkViewport)
  a.viewsArea = rect(0, 0, 0, 0)
  if l != nil and l.activeTab == pkViewport:
    let top = DockTabH + OptionsHeight
    a.viewsArea = rect(l.r.x, l.r.y + top, l.r.w, max(0'f32, l.r.h - top))

proc drawPanels*(a: App, area: Rect) =
  ## The panels as layoutPanels placed them, and a tab being dragged to
  ## another place: released over a stack's tabs (or its middle) it joins
  ## them, over a side of a stack or of the whole layout it splits that.
  let ui = a.ui
  if a.dockDragging: ui.captured = true   # Nothing under the drag reacts.
  a.drawDockNode(a.dock)
  if a.ambientEdit == nil: a.drawFieldDrop()   # Over every panel: Properties and Classes both have such fields.
  a.drawScriptPopups()
  if a.dockPress.on:
    if ui.window.buttonPressed[KeyEscape]:
      a.dockPress.on = false
      a.dockDragging = false
    elif not ui.window.buttonDown[MouseLeft]:
      if a.dockDragging:
        let (t, z, idx) = a.dockTarget(area)
        if t != nil: a.dropPanel(a.dockPress.kind, t, z, idx)
      a.dockPress.on = false
      a.dockDragging = false
    elif not a.dockDragging and (ui.mouse - a.dockPress.at).length > 6:
      a.dockDragging = true
  if a.dockDragging:
    let (t, z, idx) = a.dockTarget(area)
    ui.sk.pushLayer(PopupsLayer)
    if t != nil:
      let r = t.r
      let share = if t.isLeaf: 0.5'f32 else: 0.3
      let hint = case z
        of dzTabs: (if ui.mouse.y < r.y + DockTabH: rect(0, 0, 0, 0)
                    else: rect(r.x, r.y + DockTabH, r.w, r.h - DockTabH))
        of dzLeft: rect(r.x, r.y, r.w * share, r.h)
        of dzRight: rect(r.x + r.w * (1 - share), r.y, r.w * share, r.h)
        of dzTop: rect(r.x, r.y, r.w, r.h * share)
        of dzBottom: rect(r.x, r.y + r.h * (1 - share), r.w, r.h * share)
        of dzNone: rect(0, 0, 0, 0)
      if hint.w > 0:
        ui.rect(hint, colAccentDim)
        ui.border(hint, colAccent, 2)
      if z == dzTabs:
        # Where the tab goes among the others.
        let rs = a.tabRects(t)
        let x = if idx < rs.len: rs[idx].x elif rs.len > 0: rs[^1].x + rs[^1].w else: r.x + 6
        ui.rect(rect(x - 1, r.y + 3, 3, DockTabH - 6), colAccent)
    let label = $a.dockPress.kind
    let lr = rect(ui.mouse.x + 12, ui.mouse.y + 8, ui.textSize(label).x + 20, 24)
    ui.rect(rect(lr.x + 2, lr.y + 2, lr.w, lr.h), colShadow)
    ui.rect(lr, colPopup)
    ui.border(lr, colAccent)
    ui.textIn(label, lr, colText, h = CenterAlign)
    ui.sk.popLayer()
  if not a.settingsOpen: ui.drawColorPicker()   # View > Settings draws it above itself

type KeyHint = tuple[key, label: string]

proc shortcutMods(sc: string): (set[char], string) =
  ## "Ctrl+Shift+K" -> ({'c', 's'}, "K").
  let parts = sc.split('+')
  if parts.len < 2: return ({}, sc)
  var m: set[char]
  for p in parts[0 .. ^2]:
    case p
    of "Ctrl": m.incl 'c'
    of "Shift": m.incl 's'
    of "Alt": m.incl 'a'
    else: discard
  (m, parts[^1])

proc modifierHints(a: App): seq[seq[KeyHint]] =
  ## What the held modifiers do right now: mouse gestures first (they depend
  ## on the tool, the view and the selection), then keys, one group per menu.
  let w = a.window
  var held: set[char]
  if w.ctrl: held.incl 'c'
  if w.shiftDown: held.incl 's'
  if w.alt: held.incl 'a'
  if held == {}: return
  let vi = if a.hoverView >= 0: a.hoverView else: a.activeView
  let in3D = vi >= 0 and a.views[vi].cam.kind == vk3D
  let noTool = a.tool == toolSelect
  let handlesTool = a.tool in {toolVertex, toolEdge, toolFace}
  let pieces = a.selPieces.len > 0
  let oneFace = a.selFaces.len == 1 and not a.hasNodeSelection
  let faceMode = a.selFaces.len > 0 and not a.hasNodeSelection
  let drawing = a.drag.kind == dkDraw
  let moving = a.drag.kind in {dkMove, dkHandles, dkRotateCenter}
  var mouse: seq[KeyHint]
  if held == {'c'}:
    if handlesTool:
      mouse = @[("LMB", "Toggle handle"), ("Drag", "Lasso: toggle handles")]
    else:
      mouse = @[("LMB", "Add / remove from selection"), ("Drag", "Paint select")]
      if noTool and a.hasSelection: mouse.add ("Drag", "On the selection: duplicate and move")
      if noTool and a.selection.len > 0: mouse.add ("Drag", "On an arrow or square: duplicate and move along it")
      if noTool and a.selection.len > 0: mouse.add ("Drag", "Empty space: rectangle, toggle entities or sound faces")
      if noTool and a.selBoxFaces.len > 0: mouse.add ("LMB", "Volume face handle: toggle")
      mouse.add ("Dbl", "Add all in layer")
      if in3D: mouse.add ("Wheel", "Select next behind / in front")
  elif held == {'s'}:
    if drawing: mouse = @[("Drag", "Square " & ($a.shape).toLowerAscii)]
    elif moving: mouse = @[("Drag", "Lock to one axis")]
    else:
      mouse = @[("LMB", "Select face"), ("Dbl", "Select all faces of a piece")]
      if noTool and pieces: mouse.add ("Drag", "Selected brush's face: extrude")
      if noTool and a.selFaces.len > 0 and not a.hasNodeSelection: mouse.add ("Drag", "Paint select faces")
      if a.tool == toolBrush and in3D: mouse.add ("Drag", "On the polygon: raise it into a brush")
      if in3D: mouse.add ("Wheel", "Zoom")
  elif held == {'a'}:
    if drawing: mouse = @[("Drag", "Change height")]
    elif moving or (noTool and a.hasNodeSelection and in3D): mouse = @[("Drag", "Move vertically")]
    if oneFace:
      mouse.add ("LMB", "Copy the selected face's texture here")
      mouse.add ("Drag", "Paint it on every face you touch")
      mouse.add ("Dbl", "Copy it to the whole piece")
    if in3D: mouse.add ("RDrag", "Orbit")
    mouse.add ("MDrag", "Pan")
  elif held == {'c', 's'}:
    mouse = @[("LMB", "Add / remove face"), ("Dbl", "Add all faces of a piece"),
              ("Drag", "Paint select faces")]
    if noTool and a.selFaces.len > 0: mouse[^1] = ("Drag", "Nearest edge: into the face cuts it, out of it extends it")
    if noTool and pieces: mouse.add ("Drag", "Selected brush's face: split off a new brush")
  elif held == {'c', 'a'}:
    mouse = @[("Wheel", "Grid size")]
    if oneFace:
      mouse.add ("LMB", "Copy only the texture here")
      mouse.add ("Drag", "Paint only the texture on faces you touch")
    if noTool and a.hasSelection: mouse.add ("Drag", "Duplicate and move vertically")
  elif held == {'s', 'a'}:
    if drawing: mouse = @[("Drag", "Cube")]
    else:
      mouse = @[("Dbl", "Select coplanar faces")]
      if noTool and pieces: mouse.add ("Drag", "Selected brush's face: move it")
      if a.tool == toolVertex and a.selHandles.len == 1: mouse.add ("LMB", "Snap corner onto clicked one")
      if oneFace:
        mouse.add ("LMB", "Copy texture, wrapped around the edge")
        mouse.add ("Drag", "Paint texture, wrapping around edges")
  elif held == {'c', 's', 'a'}:
    mouse = @[("Dbl", "Add coplanar faces")]
    if noTool and pieces: mouse.add ("Drag", "Selected brush's face: stamp a new brush")
  if mouse.len > 0: result.add mouse
  # Keys: everything the menus bind to these modifiers.
  for (_, items) in a.menus:
    var hints: seq[KeyHint]
    for it in items.leaves:
      if it.separator or it.shortcut.len == 0 or not it.enabled: continue
      let (m, key) = shortcutMods(it.shortcut)
      if m == held: hints.add (key, it.label)
    if hints.len > 0: result.add hints
  # Keys that aren't menu items.
  var extra: seq[KeyHint]
  if held == {'c'}:
    if faceMode: extra = @[("Arrows", "Move texture (fine)"), ("PgUp/PgDn", "Rotate texture 1°")]
    else: extra = @[("Arrows", "Duplicate and move"), ("PgUp/PgDn", "Duplicate and move up/down")]
    if a.tool == toolClip: extra.add ("Enter", "Keep front / both / back")
  elif held == {'s'}:
    if faceMode: extra.add @[("Arrows", "Move texture (coarse)"), ("PgUp/PgDn", "Rotate texture 90°"),
                             ("R", "Reset texture")]
  elif held == {'a'}:
    let ang = if a.tool == toolRotate: fmtNum(a.rotateAngle.float32) & "°" else: "90°"
    extra = @[("Left/Right", "Yaw " & ang), ("Up/Down", "Roll " & ang), ("PgUp/PgDn", "Pitch " & ang)]
  elif held == {'s', 'a'}:
    extra = @[("R", "World-align texture")]
  if extra.len > 0: result.add extra

proc keyHintBar(a: App, r: Rect, groups: seq[seq[KeyHint]]) =
  ## Blender-style row of [key] label pairs; groups split by a divider.
  ## Hints that don't fit scroll sideways with the mouse wheel, with an
  ## arrow at each end that has more hidden past it. (From Majestic.)
  let ui = a.ui
  let capH = r.h - 6
  proc mouseIcon(key: string): string =
    ## Mouse inputs (LMB, RMB, MMB, Wheel, Drag) draw as an icon, not a key cap.
    for (k, spec) in mouseIcons:
      if k == key: return spec[0]
  proc capW(key: string): float32 =
    let icon = mouseIcon(key)
    if icon.len > 0: ui.sk.getImageSize(icon).x
    else: max(capH, ui.textSize(key, FontSmall).x + 10)
  proc pairW(h: KeyHint): float32 = capW(h.key) + 5 + ui.textSize(h.label, FontSmall).x
  const PairGap = 14'f32
  const GroupGap = 25'f32
  const Pad = 10'f32
  const ArrowW = 18'f32
  const WheelStep = 60'f32
  var pos: seq[seq[float32]]
  var dividers: seq[float32]
  var x = 0'f32
  for gi, g in groups:
    if gi > 0:
      dividers.add x + GroupGap / 2
      x += GroupGap
    pos.add @[]
    for i, h in g:
      if i > 0: x += PairGap
      pos[^1].add x
      x += pairW(h)
  let view = rect(r.x + Pad, r.y, r.w - 2 * Pad, r.h)
  let maxScroll = if x > view.w: x - view.w + ArrowW else: 0'f32
  # Other modifiers show other hints, which start from the left again.
  let key = $groups
  if key != a.hintScrollKey:
    a.hintScrollKey = key
    a.hintScroll = 0
  if ui.hover(r) and ui.scroll() != 0:
    a.hintScroll += ui.wheelNotches * WheelStep
    ui.scrollConsumed = true
  a.hintScroll = clamp(a.hintScroll, 0, maxScroll)
  let (moreLeft, moreRight) = (a.hintScroll > 0, a.hintScroll < maxScroll)
  let left = view.x - a.hintScroll + (if moreLeft: ArrowW else: 0)
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, r.w, 1), colBorder)
  var clip = view
  if moreLeft: clip.x += ArrowW; clip.w -= ArrowW
  if moreRight: clip.w -= ArrowW
  ui.pushClip(clip)
  for dx in dividers:
    ui.rect(rect(left + dx, r.y + 5, 1, r.h - 10), colBorder)
  for gi, g in groups:
    for i, h in g:
      let cap = rect(left + pos[gi][i], r.y + (r.h - capH) / 2, capW(h.key), capH)
      if cap.x > clip.x + clip.w or cap.x + pairW(h) < clip.x: continue
      let icon = mouseIcon(h.key)
      if icon.len > 0:
        ui.icon(icon, cap.xy + cap.wh / 2, colText)
      else:
        ui.rect(cap, colPanelRaised)
        ui.border(cap, colBorder)
        ui.textIn(h.key, cap, colText, FontSmall, h = CenterAlign)
      let lw = ui.textSize(h.label, FontSmall).x
      ui.textIn(h.label, rect(cap.x + cap.w + 5, r.y, lw + 2, r.h), colTextDim, FontSmall)
  ui.popClip()
  if moreLeft:
    ui.rect(rect(clip.x - 1, r.y + 5, 1, r.h - 10), colBorder)
    ui.icon("arrowleft16", vec2(r.x + (Pad + ArrowW) / 2, r.y + r.h / 2), colAccent)
  if moreRight:
    ui.rect(rect(clip.x + clip.w, r.y + 5, 1, r.h - 10), colBorder)
    ui.icon("arrow16", vec2(r.x + r.w - (Pad + ArrowW) / 2, r.y + r.h / 2), colAccent)

proc drawStatus*(a: App) =
  let ui = a.ui
  let r = rect(0, ui.size.y - StatusHeight, ui.size.x, StatusHeight)
  # Holding a modifier shows what it does instead of the status.
  if a.window.focused and a.proj != nil and not a.menuSys.isOpen and not a.modalOpen and
     ui.focusId.len == 0:
    let hints = a.modifierHints()
    if hints.len > 0:
      a.keyHintBar(r, hints)
      return
  ui.rect(r, colPanel)
  ui.rect(rect(0, r.y, r.w, 1), colBorder)
  var left: string
  var col = colTextDim
  if a.busy:
    let j = a.job
    let pw = 160'f32
    a.progressBar(rect(r.x + 8, r.y + 8, pw, 8), j.progress)
    ui.textIn(ui.ellipsize(&"{j.title}: {j.stepLabel} {j.jobCount}", r.w * 0.45 - pw, FontSmall),
              rect(r.x + pw + 18, r.y, r.w * 0.45 - pw, r.h), colText, FontSmall)
  else:
    if a.proj == nil:
      left = "No level open"
      if a.log.len > 0 and epochTime() - a.log[^1].time < 6:
        left.add "    " & a.log[^1].text
        if a.log[^1].error: col = colError
    else:
      var parts: seq[string]
      if a.selPieces.len > 0: parts.add &"{a.selPieces.len} piece(s)"
      if a.selFaces.len > 0: parts.add &"{a.selFaces.len} face(s)"
      let n = a.selection.len
      if n > 0: parts.add &"{n} object(s)"
      left = $a.tool & " » " & (if parts.len > 0: parts.join(", ") & " selected" else: "nothing selected")
      if a.log.len > 0 and epochTime() - a.log[^1].time < 6:
        left.add "    " & a.log[^1].text
        if a.log[^1].error: col = colError
    ui.textIn(ui.ellipsize(left, r.w * 0.65, FontSmall), rect(r.x + 8, r.y, r.w * 0.65, r.h), col, FontSmall)
  var right = &"grid {a.grid:g}" & (if a.snap: " (snap)" else: "")
  if a.hoverView >= 0 and a.views[a.hoverView].cam.kind != vk3D:
    let v = a.views[a.hoverView]
    let b = v.viewBody
    let p = v.cam.pixelToPlane(ui.mouse.x - b.x, ui.mouse.y - b.y, b.w, b.h)
    right = &"{p.x:.1f}, {p.y:.1f}     " & right
  let rw = ui.textSize(right, FontSmall).x
  ui.text(right, vec2(r.x + r.w - rw - 10, r.y + 5), colTextDim, FontSmall)
  # What loads in the background, left of that: the first, and how many wait.
  if a.loads.len > 0:
    let l = a.loads[0]
    var s = (if a.busy and l.job != nil: l.title & " (paused)" else: l.loadState)
    if a.loads.len > 1: s.add &"  ·  {a.loads.len - 1} more to load"
    let pw = 100'f32
    let room = r.w * 0.5 - rw - pw - 40
    if room > 60:
      let shown = ui.ellipsize(s, room, FontSmall)
      let tx = r.x + r.w - rw - 30 - ui.textSize(shown, FontSmall).x
      a.progressBar(rect(tx - pw - 8, r.y + 8, pw, 8), l.loadProgress)
      ui.text(shown, vec2(tx, r.y + 5), colTextDim, FontSmall)
      var tip = ""
      for k in a.loads: tip.add (if tip.len > 0: "\n" else: "") & k.loadState
      ui.tip(rect(tx - pw - 8, r.y, r.x + r.w - rw - 30 - (tx - pw - 8), r.h),
             "Loading in the background while you work:\n" & tip)

# --- welcome screen and settings ---------------------------------------------------------------

proc drawWelcome*(a: App, area: Rect) =
  let ui = a.ui
  ui.rect(area, colBackground)
  let w = min(860'f32, area.w - 40)
  let x0 = area.x + (area.w - w) / 2
  var y = area.y + 40
  let logo = ui.sk.getImageSize("logo")
  ui.sk.drawImage("logo", vec2(x0, y).floor)
  ui.text("Oni level editor", vec2(x0 + logo.x + 16, y + logo.y - 26), colTextDim)
  y += logo.y + 24
  let colW = (w - 24) / 2
  let lx = x0
  let rx = x0 + colW + 24
  ui.text("Your projects", vec2(lx, y), colTextDim, FontSmall)
  ui.text("New project", vec2(rx, y), colTextDim, FontSmall)
  y += 22
  var py = y
  let projects = a.cfg.listProjects
  if projects.len == 0:
    ui.text("None yet. Start one on the right.", vec2(lx, py), colTextDisabled, FontSmall)
  var projRows: seq[Rect]
  let titles = a.cfg.levelTitles
  for p in projects:
    let r = rect(lx, py, colW, 30)
    let hov = ui.hover(r)
    ui.rect(r, if hov: colHover else: colPanelRaised)
    ui.textIn(p.lastPathPart, rect(r.x + 10, r.y, r.w - 20, r.h), colText)
    if hov:
      # The map's title; a copy of a game level also names that level.
      let info = projectInfo(p)
      ui.tip(r, if not info.scratch and info.level in titles: &"{info.title} (from {titles[info.level]})"
                else: info.title)
    if hov and ui.pressed() and not a.busy:
      ui.consumeClick()
      a.openProjectDir(p)
    projRows.add r
    py += 34
    if py > area.y + area.h - 60: break
  # One Tab stop: Up/Down pick a project, Space/Enter open it.
  if projRows.len > 0:
    let lr = rect(lx, y, colW, py - y - 4)
    let focused = ui.tabStop("welcome.projects", lr)
    discard ui.listNav("welcome.projects", lr, projRows, a.projectCursor, horizontal = false)
    if focused and a.projectCursor in 0 ..< projRows.len:
      ui.cursorRing(projRows[a.projectCursor])
      if ui.navActivate("welcome.projects") and not a.busy: a.openProjectDir(projects[a.projectCursor])
  let levels = a.cfg.gameLevels
  proc uniqueName(base: string): string =
    result = base
    var k = 2
    while dirExists(a.cfg.projectsDir / result):
      result = base & "-" & $k
      inc k
  proc levelName(n: int): string =
    ## A copy of level n: "Level1", then "Level1-Copy2", "Level1-Copy3"...
    copyName("Level" & $n, proc(name: string): bool = dirExists(a.cfg.projectsDir / name))
  if a.newName.len == 0 and not a.busy and ui.focusId != "welcome.name":
    a.newName = uniqueName("NewLevel")
  let preview = a.newKind == nkPreview
  var ly = y
  # A preview makes no project, so its name is greyed out (and can't be edited).
  ui.text("Project name", vec2(rx, ly), if preview: colTextDisabled else: colTextDim, FontSmall)
  let nameR = rect(rx, ly + 18, colW, 28)
  if preview:
    if ui.focusId == "welcome.name": ui.focusId = ""
    ui.rect(nameR, colPanel)
    ui.border(nameR, colBorder)
    ui.textIn(ui.ellipsize(a.newName, colW - 14), rect(nameR.x + 7, nameR.y, colW - 14, nameR.h),
              colTextDisabled)
  else:
    discard ui.textField("welcome.name", nameR, a.newName)
  let taken = not preview and a.newName.strip.len > 0 and dirExists(a.cfg.projectsDir / a.newName.strip)
  if taken and not a.busy:
    ui.text("A project with this name already exists", vec2(rx, ly + 50), colError, FontSmall)
  if a.busy:
    a.progressBar(rect(rx, ly + 56, 100, 6), a.job.progress)
    ui.text(ui.ellipsize(&"{a.job.title}: {a.job.stepLabel} {a.job.jobCount}", colW - 110, FontSmall),
            vec2(rx + 110, ly + 50), colText, FontSmall)
  ly += 80

  # The kinds of new project, picked with the radio buttons; the button under
  # them makes the picked one. Using an option's own controls (a dropdown, a
  # level) picks it too.
  let ix = rx + 24
  let iw = colW - 24
  proc madeName(kind: NewKind): string =
    ## The name Catwalk suggests for kind ("" = none).
    case kind
    of nkScratch: uniqueName("NewLevel")
    of nkCopy, nkPreview: (if a.newLevel > 0: levelName(a.newLevel) else: "")
  proc isMade(name: string): bool =
    ## A name Catwalk suggested (NewLevel, NewLevel-2, Level1, Level1-Copy2...):
    ## it follows the choice, where one the user typed stays.
    proc number(t: string): bool = t.len > 0 and t.allCharsInSet(Digits)
    let n = name.strip
    if n.len == 0: return true
    if n == "NewLevel": return true
    if n.startsWith("NewLevel-"): return number(n["NewLevel-".len .. ^1])
    if not n.startsWith("Level"): return false
    let rest = n["Level".len .. ^1]
    let dash = rest.find("-Copy")
    if dash < 0: number(rest) else: number(rest[0 ..< dash]) and number(rest[dash + "-Copy".len .. ^1])
  proc pick(kind: NewKind) =
    if a.newKind == kind: return
    a.newKind = kind
    if isMade(a.newName):
      let next = madeName(kind)
      if next.len > 0: a.newName = next
  # A suggested name that has since been taken (its project was made) moves on.
  if not a.busy and ui.focusId != "welcome.name" and isMade(a.newName) and
     dirExists(a.cfg.projectsDir / a.newName.strip):
    let next = madeName(a.newKind)
    if next.len > 0: a.newName = next

  # From scratch: a floor and a player start, like a new map in TrenchBroom.
  if ui.radioButton("welcome.scratch", vec2(rx, ly), "From scratch", a.newKind == nkScratch): pick(nkScratch)
  ui.text("A floor and a player start. Textures come from the levels you pick.",
          vec2(ix, ly + 24), colTextDim, FontSmall)
  ly += 48
  let tw = floor((iw - 6) * 0.55)
  let sw = iw - tw - 6
  ui.text("Textures from", vec2(ix, ly), colTextDim, FontSmall)
  ui.text("Sky", vec2(ix + tw + 6, ly), colTextDim, FontSmall)
  if a.newTexLevel > 0 and levels.len > 0 and a.newTexLevel notin levels: a.newTexLevel = 0
  var texItems = @["All game levels"]
  for n in levels: texItems.add "Level " & $n
  let texLabel = if a.newTexLevel > 0: "Level " & $a.newTexLevel else: texItems[0]
  let ti = a.dropdown("welcome.tex", rect(ix, ly + 18, tw, 28), texLabel, texItems)
  if ti == 0: a.newTexLevel = 0
  elif ti > 0: a.newTexLevel = levels[ti - 1]
  var skyItems = @["None"]
  for s in Skies: skyItems.add s
  let si = a.dropdown("welcome.sky", rect(ix + tw + 6, ly + 18, sw, 28),
                      if a.newSky.len > 0: a.newSky else: "None", skyItems)
  if si == 0: a.newSky = ""
  elif si > 0: a.newSky = Skies[si - 1]
  if ti >= 0 or si >= 0: pick(nkScratch)
  ly += 66

  # Copy of an Oni level, and a preview of one: both take a level from the grid.
  if ui.radioButton("welcome.copy", vec2(rx, ly), "Copy of an Oni level", a.newKind == nkCopy): pick(nkCopy)
  ui.text("Its geometry, objects and scripts, as a project to change.", vec2(ix, ly + 24), colTextDim, FontSmall)
  ly += 48
  if ui.radioButton("welcome.preview", vec2(rx, ly), "Preview an Oni level", preview): pick(nkPreview)
  ui.text("Look inside it without making a project. Nothing is kept.", vec2(ix, ly + 24), colTextDim, FontSmall)
  ly += 48
  if levels.len == 0:
    ui.text("No Oni levels found in " & a.cfg.gameData, vec2(ix, ly), colError, FontSmall)
  let onLevel = a.newKind in {nkCopy, nkPreview}
  let cols = 4
  let bw = (iw - (cols - 1).float32 * 6) / cols.float32
  var levelCells: seq[Rect]
  proc pickLevel(n: int) =
    if not onLevel: pick(nkPreview)
    if isMade(a.newName): a.newName = levelName(n)
    a.newLevel = n
  for i, n in levels:
    let r = rect(ix + (i mod cols).float32 * (bw + 6), ly + (i div cols).float32 * 34, bw, 30)
    let sel = onLevel and a.newLevel == n
    let hov = ui.hover(r)
    ui.rect(r, if sel: colAccentDim elif hov: colHover else: colPanelRaised)
    ui.textIn("Level " & $n, r, if onLevel or hov: colText else: colTextDim, h = CenterAlign)
    if n in titles: ui.tip(r, titles[n])
    if hov and ui.pressed():
      ui.consumeClick()
      a.levelCursor = i
      pickLevel(n)
    levelCells.add r
  let rowsH = ((levels.len + cols - 1) div cols).float32 * 34
  # One Tab stop: the arrow keys move through the levels, Space/Enter pick one.
  if levels.len > 0:
    let lr = rect(ix, ly, iw, rowsH - 4)
    let focused = ui.tabStop("welcome.levels", lr)
    discard ui.listNav("welcome.levels", lr, levelCells, a.levelCursor)
    if focused and a.levelCursor in 0 ..< levels.len:
      let c = levelCells[a.levelCursor]
      ui.cursorRing(c)
      if ui.navActivate("welcome.levels"): pickLevel(levels[a.levelCursor])
  ly += rowsH + 10

  # Create (Open for a preview): makes whichever option is picked.
  let br = rect(rx + colW - 120, ly, 120, 30)
  let label = if preview: "Open" else: "Create"
  let needLevel = a.newKind in {nkCopy, nkPreview} and a.newLevel == 0
  if levels.len > 0 and not a.busy and not taken and not needLevel and
     (preview or a.newName.strip.len > 0):
    if ui.textButton("welcome.create", br, label, primary = true):
      case a.newKind
      of nkScratch: a.newEmptyLevel(a.newName)
      of nkCopy: a.importLevel(a.newLevel, a.newName)
      of nkPreview: a.previewLevel(a.newLevel)
  else:
    ui.rect(br, colPanel)
    ui.border(br, colBorder)
    ui.textIn(label, br, colTextDisabled, h = CenterAlign)
    if needLevel and not a.busy:
      let hint = if preview: "Pick a level to preview." else: "Pick a level to copy."
      let hw = ui.textSize(hint, FontSmall).x
      ui.text(hint, vec2(br.x - hw - 12, br.y + 8), colTextDim, FontSmall)
  if a.crashReport.len > 0:
    # The Issues panel isn't up until a level is open.
    let cy = area.y + area.h - 104
    ui.text("Catwalk crashed in an earlier run.", vec2(rx, cy), colError)
    ui.text("Please send the report along when reporting the bug.", vec2(rx, cy + 20), colTextDim, FontSmall)
    if ui.textButton("welcome.crash", rect(rx, cy + 42, 140, 30), "Find the report"):
      showInFolder(a.crashReport)
  ui.text("Projects folder: " & a.cfg.projectsDir & "   (View > Settings to change)",
          vec2(lx, area.y + area.h - 30), colTextDisabled, FontSmall)

proc setFov(a: App, degrees: float) =
  for i in 0 .. 3:
    if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = degrees.float32.degToRad

const
  SettingsPages = ["General", "View", "Mouse"]
  GridColorId = "settings.gridcolor"

proc drawSettings*(a: App) =
  ## View > Settings: paths, plus TrenchBroom's View and Mouse preferences.
  ## The views preview View changes while it is open; Save keeps them, Cancel
  ## (or Esc) puts everything back.
  if not a.settingsOpen:
    a.settingsPortMark = false
    return
  let ui = a.ui
  let e = addr a.settingsEdit
  let firstStop = ui.tabStops.len
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - 700) / 2), floor((ui.size.y - 640) / 2), 700, 640)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Settings", vec2(box.x + 16, box.y + 12), colText, FontTitle)
  # Pages down the left, like TrenchBroom's preference panes.
  let side = rect(box.x + 1, box.y + 50, 130, box.h - 50 - 62)
  # One Tab stop: Up/Down switch pages.
  let pagesFocused = ui.tabStop("settings.pages", side)
  var pageRows: seq[Rect]
  for i, name in SettingsPages:
    let r = rect(side.x + 8, side.y + i.float32 * 32, side.w - 16, 28)
    let sel = a.settingsPage == i
    let hov = ui.hover(r)
    ui.rect(r, if sel: colAccentDim elif hov: colHover else: colPopup)
    ui.textIn(name, rect(r.x + 10, r.y, r.w - 20, r.h), colText)
    if sel and pagesFocused: ui.cursorRing(r)
    if hov and ui.pressed():
      ui.consumeClick()
      a.settingsPage = i
    pageRows.add r
  discard ui.listNav("settings.pages", side, pageRows, a.settingsPage, horizontal = false)
  ui.rect(rect(side.x + side.w, side.y, 1, side.h), colBorder)
  let x = side.x + side.w + 20
  let w = box.x + box.w - 20 - x
  var y = box.y + 54
  const LabelW = 130'f32
  proc field(title: string, value: var string) =
    ui.text(title, vec2(x, y), colTextDim, FontSmall)
    discard ui.textField("settings." & title, rect(x, y + 18, w, 28), value)
    y += 56
  proc section(title: string) =
    if y > box.y + 60: y += 8
    ui.groupHeader(vec2(x, y), w, title)
    y += 28
  proc sliderRow(id, label: string, value: var float, lo, hi, step: float, shown: string): bool =
    ui.textIn(label, rect(x, y, LabelW, 24), colText)
    let sw = w - LabelW - 110
    result = ui.slider("settings." & id, rect(x + LabelW, y, sw, 24), value, lo, hi, step)
    ui.textIn(shown, rect(x + LabelW + sw + 14, y, 96, 24), colTextDim)
    y += 32
  proc check(id, label: string, value: var bool) =
    discard ui.checkbox("settings." & id, vec2(x + LabelW, y), label, value)
    y += 28
  proc note(s: string) =
    for line in ui.wrapText(s, w - LabelW, 3, FontSmall):
      ui.text(line, vec2(x + LabelW, y + 2), colTextDim, FontSmall)
      y += 18
    y += 6
  proc pct(v: float): string = $int(round(v * 100)) & "%"

  case a.settingsPage
  of 1:
    section("Map Views")
    discard sliderRow("brightness", "Brightness", e.brightness, 0, 2, 0.05, pct(e.brightness))
    if sliderRow("fov", "FOV", e.fov, 30, 120, 1, $int(e.fov) & "°"): a.setFov(e.fov)
    note("Vertical field of view of the 3D view. Shift+wheel zooms it; " &
         "Ctrl+Alt+Z goes back to this.")
    ui.textIn("Filter mode", rect(x, y, LabelW, 24), colText)
    if ui.radioButton("settings.linear", vec2(x + LabelW, y + 1), "Linear", e.linearFilter):
      e.linearFilter = true
    if ui.radioButton("settings.nearest", vec2(x + LabelW + 100, y + 1), "Nearest", not e.linearFilter):
      e.linearFilter = false
    y += 32
    section("Grid")
    discard sliderRow("grid", "Opacity", e.gridOpacity, 0, 1, 0.01, pct(e.gridOpacity))
    ui.textIn("Color", rect(x, y, LabelW, 26), colText)
    if ui.focusId != GridColorId and not pickerOpen(GridColorId):
      a.fieldText[GridColorId] = fmtRgb(e.gridColor)
    let app = a
    let target = ColorTarget(
      live: proc(c: RGB) =
        for i in 0 .. 2: app.settingsEdit.gridColor[i] = clamp(c[i], 0, 255),
      done: proc(changed: bool) = discard)
    let ev = ui.colorField(GridColorId, rect(x + LabelW, y, w - LabelW, 26), a.fieldText[GridColorId], target)
    if eeCommitted in ev:
      let (ok, c) = parseColor(a.fieldText[GridColorId])
      if ok: target.live(c)
      elif a.fieldText[GridColorId].strip.len > 0:
        a.say("Not a color: " & a.fieldText[GridColorId] & " (use R G B, #RRGGBB or hsv(H, S, V))", true)
    y += 34
    check("grid3d", "Also on the 3D faces", e.gridColor3D)
    ui.tip(rect(x + LabelW, y - 28, 170, 22), "Off: the 3D grid is black or white, whichever shows on " &
      "each texture (TrenchBroom's choice).")
    section("Wireframe")
    check("triangles", "Show triangles", e.showTriangles)
    ui.tip(rect(x + LabelW, y - 28, 140, 22), "On: wireframes draw every triangle the faces are split into. " &
      "Off: only the faces' own edges.")
  of 2:
    section("Mouse Look")
    discard sliderRow("look", "Sensitivity", e.lookSpeed, 0.01, 1, 0.01, pct(e.lookSpeed))
    check("lookx", "Invert X axis", e.lookInvertX)
    check("looky", "Invert Y axis", e.lookInvertY)
    section("Mouse Pan")
    discard sliderRow("pan", "Sensitivity", e.panSpeed, 0.01, 1, 0.01, pct(e.panSpeed))
    check("panx", "Invert X axis", e.panInvertX)
    check("pany", "Invert Y axis", e.panInvertY)
    section("Mouse Move")
    discard sliderRow("move", "Sensitivity", e.moveSpeed, 0.01, 1, 0.01, pct(e.moveSpeed))
    check("wheel", "Invert mouse wheel", e.invertWheel)
    check("cursor", "Move camera towards cursor", e.moveTowardCursor)
    section("Fly Mode")
    # Steps of 1.25×, the same as one wheel notch while flying, so the speeds
    # the wheel picks sit on the slider's steps.
    var f = round(ln(a.settingsFly / DefaultFlySpeed) / ln(FlyWheelStep)).float
    let factor = a.settingsFly / DefaultFlySpeed
    let shown = (if factor < 0.1: &"{factor:.3f}×" elif factor < 10: &"{factor:.2f}×" else: &"{factor:.1f}×")
    if sliderRow("fly", "Speed factor", f, floor(ln(MinFlySpeed / DefaultFlySpeed) / ln(FlyWheelStep)),
                 ceil(ln(MaxFlySpeed / DefaultFlySpeed) / ln(FlyWheelStep)), 1, shown):
      a.settingsFly = clamp(DefaultFlySpeed * pow(FlyWheelStep, f.float32), MinFlySpeed, MaxFlySpeed)
    note(&"{a.settingsFly.round.int} units/s; Shift flies 3× faster. Turn the mouse wheel " &
         "while holding the right mouse button in the 3D view to change it while flying.")
  else:
    section("Paths")
    field("Oni AE folder (has Tools/OniSplit.exe and GameDataFolder)", e.aeDir)
    field("Projects folder", e.projectsDir)
    field("Game: Oni.exe (Play starts it with Wine) or a script that starts it", e.game)
    section("Recent Projects")
    ui.textIn("Limit", rect(x, y, LabelW, 26), colText)
    var lim = e.recentLimit.float
    if ui.numberField("settings.recentlimit", rect(x + LabelW, y, 80, 26), lim, 1, 0, MaxRecentLimit):
      e.recentLimit = clamp(lim.round.int, 0, MaxRecentLimit)
    y += 34
    note("How many projects File > Open Recent lists.")
    section("MCP Server")
    check("mcp", "Start the MCP server when Catwalk starts", e.mcpEnabled)
    ui.textIn("Port", rect(x, y, LabelW, 26), colText)
    var port = e.mcpPort.float
    if ui.numberField("settings.mcpport", rect(x + LabelW, y, 80, 26), port, 1, 1024, 65535):
      e.mcpPort = clamp(port.round.int, 1024, 65535)
      a.settingsPortMark = false
    if a.settingsPortMark: ui.border(rect(x + LabelW - 3, y - 3, 86, 32), colError, 2)
    y += 34
    note("Lets Claude Code drive the open editor, from this computer only. Saved as " &
         "\"mcpEnabled\" in " & configPath() & ".")

  let by = box.y + box.h - 46
  if a.settingsPage > 0 and
     ui.textButton("settings.reset", rect(box.x + 16, by, 140, 30), "Reset to defaults"):
    # Resets the View and Mouse pages (TrenchBroom resets the pane shown).
    e[].resetViewPrefs()
    a.settingsFly = StartFlySpeed
    a.setFov(e.fov)
  let sr = rect(box.x + box.w - 200, by, 88, 30)
  let cr = rect(box.x + box.w - 104, by, 88, 30)
  if ui.textButton("settings.save", sr, "Save", primary = true):
    a.settingsEdit.recentProjects = a.cfg.recentProjects
    a.cfg = a.settingsEdit
    a.flySpeed = a.settingsFly
    a.cfg.save()
    a.saveLayout()
    a.settingsOpen = false
    a.settingsSaved = true
    a.say "Settings saved"
  elif ui.textButton("settings.cancel", cr, "Cancel") or
       (ui.focusId.len == 0 and not pickerOpen(GridColorId) and ui.window.buttonPressed[KeyEscape]):
    if a.settingsEdit.fov != a.cfg.fov: a.setFov(a.cfg.fov)
    a.settingsOpen = false
  ui.sk.popLayer()
  ui.drawColorPicker()
  ui.captured = true
  # Tab stays in the dialog.
  if a.settingsOpen: discard ui.tabNavigate(firstStop)

proc drawNamePrompt*(a: App) =
  ## The group name prompt: Enter or OK runs it with the name, Esc or Cancel
  ## doesn't. An empty name does nothing (TrenchBroom's queryGroupName).
  if a.namePrompt == nil: return
  let ui = a.ui
  let firstStop = ui.tabStops.len
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - 400) / 2), floor((ui.size.y - 150) / 2), 400, 150)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text(a.namePromptTitle, vec2(box.x + 16, box.y + 12), colText, FontTitle)
  let ev = ui.textField("nameprompt.text", rect(box.x + 16, box.y + 50, box.w - 32, 28), a.namePromptText)
  let enter = ui.window.buttonPressed[KeyEnter] or ui.window.buttonPressed[NumpadEnter]
  let by = box.y + box.h - 46
  var choice = ""
  if ui.textButton("nameprompt.ok", rect(box.x + box.w - 200, by, 88, 30), "OK", primary = true) or
     (enter and (eeCommitted in ev or ui.focusId != "nameprompt.text")): choice = "ok"
  if ui.textButton("nameprompt.cancel", rect(box.x + box.w - 104, by, 88, 30), "Cancel") or
     (ui.window.buttonPressed[KeyEscape] and choice.len == 0): choice = "cancel"
  ui.sk.popLayer()
  ui.captured = true
  if choice.len == 0: discard ui.tabNavigate(firstStop)
  else:
    let done = a.namePrompt
    let name = a.namePromptText.strip
    a.namePrompt = nil
    ui.focusId = ""
    if choice == "ok" and name.len > 0: done(name)

proc drawSkyConvert*(a: App) =
  ## Run > Add-Ons > Skybox Converter: the source picture's preview, then its
  ## file, its layout and whether the level uses the result. Esc or Cancel
  ## closes it. Either way the sky joins the project's list of skies.
  if not a.skyConvertOpen: return
  const
    (BoxW, Pad) = (640'f32, 16'f32)
    PreviewMaxH = 256'f32    # The preview's tallest.
    NoPreviewH = 96'f32
  let ui = a.ui
  let firstStop = ui.tabStops.len
  let innerW = BoxW - Pad * 2
  let file = a.skyConvertFile.strip
  if file.len > 0: a.loadSkyPreview(file, innerW, PreviewMaxH)
  let shown = a.skyPreviews.getOrDefault(file)
  let hasShown = file in a.skyPreviews
  if file != a.skyConvertShown:
    a.skyConvertShown = file
    a.skyConvertError = ""
    if hasShown: a.skyConvertKind = guessSkySource(shown.srcW, shown.srcH)
  let previewH = if hasShown: shown.h.float32 else: NoPreviewH
  let boxH = previewH + 306
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - BoxW) / 2), max(0'f32, floor((ui.size.y - boxH) / 2)), BoxW, boxH)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Skybox Converter", vec2(box.x + Pad, box.y + 12), colText, FontTitle)
  let x = box.x + Pad
  var y = box.y + 46
  # Preview.
  let pr = rect(x, y, innerW, previewH)
  if hasShown:
    ui.rect(pr, colBackground)
    ui.sk.drawImage("skysrc:" & file, vec2(x + floor((innerW - shown.w.float32) / 2), y))
  else:
    ui.dashedBorder(pr, colBorder, 6, 4)
    let msg = if file.len == 0: "No source file"
              elif fileExists(file): "No preview for this file"
              else: "File not found"
    let tw = ui.textSize(msg).x
    ui.text(msg, vec2(x + (innerW - tw) / 2, y + previewH / 2 - 9), colTextDim)
  y += previewH + 14
  # Source file.
  ui.text("Source file", vec2(x, y), colTextDim, FontSmall)
  y += 18
  discard ui.textField("skyconvert.file", rect(x, y, innerW - 96, 28), a.skyConvertFile)
  if ui.textButton("skyconvert.browse", rect(x + innerW - 88, y, 88, 28), "Browse...") and a.dialog == nil:
    a.dialog = startDialog(dkOpenFile, "skysource", "Source picture of the skybox",
                           if file.len > 0: file.parentDir else: getHomeDir(),
                           @DirectFormats & @OniSplitFormats, "Pictures")
  y += 40
  # Type: its list is drawn last, over what's below it, and those ignore the mouse there.
  ui.text("Type of skybox", vec2(x, y), colTextDim, FontSmall)
  y += 18
  let typeRow = rect(x, y, innerW, 28)
  if a.openDropdown == "skyconvert.type":
    ui.popupRect = rect(x, y + 28, innerW, float32(SkySourceNames.len * 24 + 12))
  y += 30
  ui.text(SkySourceHelp[a.skyConvertKind], vec2(x, y), colTextDim, FontSmall)
  y += 26
  # Use skybox.
  discard ui.checkbox("skyconvert.use", vec2(x, y), "Use skybox", a.skyConvertUse)
  let usedBy = if a.proj != nil: a.proj.title else: "the level"
  let useText = if a.skyConvertUse: "Sets it as the sky of " & usedBy
                else: "Only adds it to the skies under Sky in Properties"
  ui.text(useText, vec2(x + 130, y + 3), colTextDim, FontSmall)
  # Buttons.
  let by = box.y + box.h - 46
  if a.skyConvertError.len > 0:
    ui.text(ui.ellipsize(a.skyConvertError, innerW, FontSmall), vec2(x, by - 22), colError, FontSmall)
  var choice = ""
  if ui.textButton("skyconvert.ok", rect(box.x + box.w - 200, by, 88, 30), "Convert", primary = true) and
     file.len > 0 and not a.busy: choice = "ok"
  if ui.textButton("skyconvert.cancel", rect(box.x + box.w - 104, by, 88, 30), "Cancel") or
     (ui.window.buttonPressed[KeyEscape] and a.openDropdown.len == 0 and ui.focusId.len == 0 and
      choice.len == 0): choice = "cancel"
  var names: seq[string]
  for n in SkySourceNames: names.add n
  let picked = a.dropdown("skyconvert.type", typeRow, SkySourceNames[a.skyConvertKind], names)
  if picked >= 0:
    a.skyConvertKind = SkySource(picked)
    a.skyConvertError = ""
  ui.sk.popLayer()
  ui.captured = true
  if choice == "ok":
    let ext = file.splitFile.ext.toLowerAscii.strip(chars = {'.'})
    try:
      if not fileExists(file): raise newException(ValueError, "File not found")
      if ext notin @DirectFormats & @OniSplitFormats:
        raise newException(ValueError, "Not a picture Catwalk can read")
      # Pictures with no preview are only known once read: the job reports those.
      if hasShown: checkSkyShape(shown.srcW, shown.srcH, a.skyConvertKind)
      a.skyConvertOpen = false
      ui.focusId = ""
      a.convertSky(file, a.skyConvertKind, a.skyConvertUse)
    except CatchableError as e:
      a.skyConvertOpen = true
      a.skyConvertError = e.msg
  elif choice == "cancel":
    a.skyConvertOpen = false
    ui.focusId = ""
  if a.skyConvertOpen: discard ui.tabNavigate(firstStop)

proc drawSkyImport*(a: App) =
  ## After Import custom sky...: a row per picture with the side it goes on.
  ## Picking a side another picture has swaps the two. What the edges say
  ## (skyfit.nim) only fills these in: sets differ, so the choice is the user's.
  ## Turn on Auto takes how the edges join for the sides picked here.
  if a.skyImportDir.len == 0: return
  const
    (BoxW, Pad, RowH, Thumb) = (620'f32, 16'f32, 64'f32, 56'f32)
    MaxRows = 7
    TurnNames = ["Auto", "0°", "90°", "180°", "270°"]
  let ui = a.ui
  let firstStop = ui.tabStops.len
  let shownRows = min(a.skyImportFiles.len, MaxRows)
  let listH = shownRows.float32 * RowH + 20   # scrolledRows' margins.
  let boxH = min(ui.size.y - 16, listH + 150)
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - BoxW) / 2), floor((ui.size.y - boxH) / 2), BoxW, boxH)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Import custom sky", vec2(box.x + Pad, box.y + 12), colText, FontTitle)
  let by = box.y + box.h - 46
  let missing = a.skyImportMissing
  let fit = a.skyImportFit.turnsFor(a.skyImportSides)
  var byHand = false
  for t in a.skyImportTurns:
    if t >= 0: byHand = true
  # Buttons first: the side lists draw over them.
  let status = if missing.len > 0: "Needs a picture for: " & missing
               elif fit.ok: "The edges join up"
               elif a.skyImportFit != nil and byHand: "The edges don't join: using your turns"
               elif a.skyImportFit != nil: "The edges don't join up: check the sides, or set Turn"
               else: "Sides come from the names: the edges can't be checked"
  let bad = missing.len > 0 or (a.skyImportFit != nil and not fit.ok and not byHand)
  ui.text(ui.ellipsize(status, BoxW - 230 - Pad, FontSmall), vec2(box.x + Pad, by + 8),
          if bad: colWarning else: colTextDim, FontSmall)
  var choice = ""
  if ui.textButton("skyimport.ok", rect(box.x + box.w - 200, by, 88, 30), "Import", primary = true) and
     missing.len == 0 and not a.busy: choice = "ok"
  if ui.textButton("skyimport.cancel", rect(box.x + box.w - 104, by, 88, 30), "Cancel") or
     (ui.window.buttonPressed[KeyEscape] and a.openDropdown.len == 0): choice = "cancel"
  var sideNames: seq[string]
  for s in SkySides: sideNames.add s.capitalizeAscii
  sideNames.add "Not used"
  let area = rect(box.x, box.y + 46, BoxW, min(listH, by - box.y - 54))
  let app = a
  proc sideId(i: int): string = "skyimport.side" & $i
  proc turnId(i: int): string = "skyimport.turn" & $i
  proc drawChoice(id: string, i: int, y: float32) =
    let right = box.x + BoxW - Pad - 12
    if id == turnId(i):
      let tr = rect(right - 92, y + 18, 92, 28)
      if app.openDropdown == id:
        ui.popupRect = rect(tr.x, tr.y + 28, 160, TurnNames.len.float32 * 24 + 12)
      let picked = app.dropdown(id, tr, TurnNames[app.skyImportTurns[i] + 1], @TurnNames)
      if picked >= 0: app.skyImportTurns[i] = picked - 1
    else:
      let dr = rect(right - 212, y + 18, 112, 28)
      let side = app.skyImportSides[i]
      if app.openDropdown == id:
        ui.popupRect = rect(dr.x, dr.y + 28, 160, sideNames.len.float32 * 24 + 12)
      let picked = app.dropdown(id, dr, if side >= 0: sideNames[side] else: "Not used", sideNames)
      if picked >= 0:
        let now = if picked == SkySides.len: -1 else: picked
        # The side's old picture takes this one's side: no two on one face.
        if now >= 0:
          for k in 0 ..< app.skyImportSides.len:
            if k != i and app.skyImportSides[k] == now: app.skyImportSides[k] = side
        app.skyImportSides[i] = now
  var (openId, openRow, openY) = ("", 0, 0'f32)
  let wasOpen = a.openDropdown
  a.scrolledRows("skyimport.rows", area, a.skyImportScroll, proc(y0: float32): float32 =
    var y = y0
    for i, file in app.skyImportFiles:
      let row = rect(box.x + Pad, y, BoxW - Pad * 2 - 12, RowH)
      let key = file & "#thumb"
      app.loadSkyPreview(file, Thumb, Thumb, key)
      if key in app.skyPreviews:
        let p = app.skyPreviews[key]
        ui.sk.drawImage("skysrc:" & key, vec2(row.x, y + floor((RowH - p.h.float32) / 2)))
      else:
        ui.dashedBorder(rect(row.x, y + 4, Thumb, Thumb), colBorder, 4, 3)
      let nameW = row.w - Thumb - 12 - 216
      ui.textIn(ui.ellipsize(file.lastPathPart, nameW), rect(row.x + Thumb + 12, y, nameW, RowH), colText)
      # As of before this frame's click, which reaches each dropdown only once.
      for id in [sideId(i), turnId(i)]:
        if id != wasOpen: drawChoice(id, i, y)
        else: (openId, openRow, openY) = (id, i, y)
      y += RowH
    # Last, as its list goes over the rows below.
    if openId.len > 0: drawChoice(openId, openRow, openY)
    y)
  ui.sk.popLayer()
  ui.captured = true
  if choice == "ok":
    a.finishSkyImport()
    a.skyImportDir = ""
  elif choice == "cancel": a.skyImportDir = ""
  else: discard ui.tabNavigate(firstStop)

# --- ambient sound editor ------------------------------------------------------------------

proc soundCatalog(a: App): Catalog =
  if a.catalog == nil: a.catalog = newCatalog()
  if a.proj != nil: a.catalog.refresh(a.cfg.gameData, a.proj.dir)
  a.catalog

proc freeAmbientName(a: App, source: string, plain = false): string =
  ## A name for a copy of source that no sound has yet: source_2, source_3...
  ## (plain: source itself first).
  var base = ""
  for ch in source.strip:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: base.add ch
  if base.toLowerAscii.startsWith(RecordingPrefix): base = base[RecordingPrefix.len .. ^1]
  if base.len == 0: base = "ambient"
  let taken = a.soundCatalog.soundNamesTaken
  if plain and nameProblem(base, taken).len == 0: return base
  for n in 2 .. 999:
    let suffix = "_" & $n
    let name = base[0 ..< min(base.len, MaxAmbientName - suffix.len)] & suffix
    if nameProblem(name, taken).len == 0: return name
  base

proc openAmbientEditor(a: App, amb: CustomAmbient, original: string, pick: proc(v: string)) =
  a.ui.focusId = ""
  a.drop.id = ""
  var t = atDetail
  for k in AmbTrack:
    if amb.tracks[k].perms.len > 0:
      t = k
      break
  a.ambientEdit = AmbientEdit(amb: amb, original: original, track: t, pick: pick)

proc duplicateAmbient(a: App, source: string, pick: proc(v: string) = nil) =
  ## Opens the editor on a copy of source, under a free name.
  if a.proj == nil: return
  a.withSounds("sounds", proc() =
    if a.proj == nil: return
    try:
      var amb = cachedAmbient(source)
      amb.name = a.freeAmbientName(source)
      a.openAmbientEditor(amb, "", pick)
    except CatchableError as e: a.say(e.msg, true))

proc editAmbient(a: App, name: string) =
  if a.proj == nil: return
  for found in loadAmbients(a.proj.ambientsPath):
    if found.name.toLowerAscii == name.toLowerAscii:
      let amb = found
      a.withSounds("sounds", proc() = a.openAmbientEditor(amb, amb.name, nil))
      return
  a.say("This level has no ambient called " & name, true)

proc newAmbientSound(a: App) =
  if a.proj == nil: return
  a.withSounds("sounds", proc() =
    if a.proj != nil: a.openAmbientEditor(newAmbient(a.freeAmbientName("ambient", plain = true)), "", nil))

proc ambientUsers(a: App, name: string): int =
  ## Objects with a field set to the ambient (Sound objects, lights, neutrals...).
  let low = name.toLowerAscii
  for o in a.objects:
    for f in o.fields:
      if f.attr.len == 0 and f.value.strip.toLowerAscii == low:
        inc result
        break

const TrackHelp: array[AmbTrack, string] = [
  "Plays once when the sound starts, before the base tracks.",
  "Loops while the sound plays, one random sound after another (once, with Play once).",
  "A second loop on top of base track 1.",
  "One random sound every Gap seconds (from each one's start), up to Spread units around the sound.",
  "Plays once when the sound stops."]

proc drawAmbientEditor*(a: App) =
  ## File > Import > New ambient sound, File > Ambient sounds, or Duplicate as new
  ## ambient on a sound list: an ambient of this level and its sound groups (ambients.nim). Save writes the
  ## project's ambients.json; Build defines them in the level.
  let e = a.ambientEdit
  if e == nil: return
  if a.proj == nil:
    a.ambientEdit = nil
    return
  const
    (BoxW, Pad) = (900'f32, 16'f32)
    FieldH = 26'f32
  let ui = a.ui
  let app = a
  let firstStop = ui.tabStops.len
  let editing = ui.focusId.len > 0   # Esc ends that edit, not the dialog.
  let innerW = BoxW - Pad * 2
  let boxH = min(ui.size.y - 16, 720'f32)
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - BoxW) / 2), max(0'f32, floor((ui.size.y - boxH) / 2)), BoxW, boxH)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  let isNew = e.original.len == 0
  ui.text(if isNew: "New ambient sound" else: "Ambient sound " & e.original,
          vec2(box.x + Pad, box.y + 12), colText, FontTitle)
  let x = box.x + Pad
  var y = box.y + 50
  var changed = false
  proc label(s: string, r: Rect, tip = "") =
    ui.textIn(ui.ellipsize(s, r.w, FontSmall), r, colTextDim, FontSmall)
    if tip.len > 0: ui.tip(r, tip)
  # Name.
  label("Name", rect(x, y, 110, FieldH))
  let nr = rect(x + 110, y, 280, FieldH)
  if isNew:
    if ui.textField("amb.name", nr, e.amb.name).len > 0: e.error = ""
  else:
    ui.rect(nr, colPanel)
    ui.border(nr, colBorder)
    ui.textIn(e.amb.name, rect(nr.x + 8, nr.y, nr.w - 16, nr.h), colTextDim)
    ui.tip(nr, "Objects use it by this name. Duplicate it to make a renamed copy.")
  if e.amb.source.len > 0:
    ui.textIn(ui.ellipsize("Copied from " & e.amb.source, innerW - 410, FontSmall),
              rect(x + 410, y, innerW - 410, FieldH), colTextDim, FontSmall)
  y += 38
  # Settings: three columns of a label and one or two numbers.
  let colW = (innerW - 2 * 20) / 3
  proc numPair(col, row: int, name, tip: string, v: var (float, float), step, lo, hi: float, dec = 2) =
    let cx = x + col.float32 * (colW + 20)
    let cy = y + row.float32 * 32
    let lw = colW * 0.48
    label(name, rect(cx, cy, lw, FieldH), tip)
    let fw = (colW - lw - 4) / 2
    var a0 = v[0]
    var a1 = v[1]
    if ui.numberField("amb." & name & ".0", rect(cx + lw, cy, fw, FieldH), a0, step, lo, hi, dec):
      v[0] = a0
      if v[1] < v[0]: v[1] = v[0]
      changed = true
    if ui.numberField("amb." & name & ".1", rect(cx + lw + fw + 4, cy, fw, FieldH), a1, step, lo, hi, dec):
      v[1] = a1
      if v[0] > v[1]: v[0] = v[1]
      changed = true
  proc num1(col, row: int, name, tip: string, v: var float, step, lo, hi: float, dec = 2) =
    let cx = x + col.float32 * (colW + 20)
    let cy = y + row.float32 * 32
    let lw = colW * 0.48
    label(name, rect(cx, cy, lw, FieldH), tip)
    if ui.numberField("amb." & name, rect(cx + lw, cy, colW - lw, FieldH), v, step, lo, hi, dec): changed = true
  numPair(0, 0, "Gap (s)", "Seconds from one detail sound's start to the next: a random time between these two.",
          e.amb.gap, 0.05, 0, 600)
  num1(0, 1, "Spread", "Detail sounds play at a random place up to this far (x and z) from the sound.",
       e.amb.sphere, 1, 0, 10000, 1)
  numPair(1, 0, "Distance", "Full volume up to the first, silent past the second (when no Sound object " &
          "gives its own radii, as with BSL's sound_ambient_start).", e.amb.dist, 1, 0, 100000, 1)
  var tres = e.amb.treshold.float
  num1(1, 1, "Max at once", "At most this many of it play at the same time; more Sound objects of it wait.",
       tres, 1, 1, 32, 0)
  e.amb.treshold = int(tres)
  num1(2, 0, "Min occlusion", "Walls between it and the listener turn it down to no less than this (0..1).",
       e.amb.minOcclusion, 0.05, 0, 1)
  let prioR = rect(x + 2 * (colW + 20) + colW * 0.48, y + 32, colW - colW * 0.48, FieldH)
  label("Priority", rect(x + 2 * (colW + 20), y + 32, colW * 0.48, FieldH),
        "When every channel is busy, a sound of higher priority takes one from a lower one.")
  if a.openDropdown == "amb.prio":
    ui.popupRect = rect(prioR.x, prioR.y + FieldH, prioR.w, Priorities.len.float32 * 24 + 12)
  y += 64
  if ui.checkbox("amb.once", vec2(x, y + 4), "Play once", e.amb.playOnce): changed = true
  ui.tip(rect(x, y, 120, FieldH), "The base tracks play one sound each, then it ends (a Sound object starts it again).")
  if ui.checkbox("amb.pan", vec2(x + 160, y + 4), "Can pan", e.amb.canPan): changed = true
  ui.tip(rect(x + 160, y, 120, FieldH), "A Sound sphere of it is heard from its side (the far ear turned down).")
  if ui.checkbox("amb.interrupt", vec2(x + 320, y + 4), "Cut tracks on stop", e.amb.interrupt): changed = true
  ui.tip(rect(x + 320, y, 180, FieldH), "Stopping it cuts its sounds off at once, instead of letting them end.")
  y += 40
  # Tracks.
  let tabW = (innerW - 4 * 6) / 5
  for t in AmbTrack:
    let n = e.amb.tracks[t].perms.len
    let tr = rect(x + t.ord.float32 * (tabW + 6), y, tabW, 28)
    if ui.textButton("amb.track." & $t.ord, tr, $t & (if n > 0: " (" & $n & ")" else: ""), primary = t == e.track):
      e.track = t
  y += 36
  let t = e.track
  ui.textIn(ui.ellipsize(TrackHelp[t], innerW, FontSmall), rect(x, y, innerW, 20), colTextDim, FontSmall)
  y += 26
  block:
    var g = addr e.amb.tracks[t]
    label("Group volume", rect(x, y, 100, FieldH), "Every sound of this track, times its own volume.")
    if ui.numberField("amb.gvol." & $t.ord, rect(x + 100, y, 80, FieldH), g[].vol, 0.05, 0, 1, 2): changed = true
    label("Group pitch", rect(x + 200, y, 90, FieldH), "Every sound of this track, times its own pitch " &
          "(speed and pitch together: 2 is an octave up).")
    if ui.numberField("amb.gpitch." & $t.ord, rect(x + 290, y, 80, FieldH), g[].pitch, 0.05, 0.25, 4, 2): changed = true
    if ui.checkbox("amb.norepeat." & $t.ord, vec2(x + 400, y + 4), "No repeats", g[].noRepeat): changed = true
    ui.tip(rect(x + 400, y, 140, FieldH), "Never the same sound twice in a row.")
  y += 36
  # Its sounds: a table.
  const (PlayW, NumW, DelW) = (26'f32, 74'f32, 26'f32)
  let nameW = innerW - 12 - PlayW - DelW - 5 * (NumW + 4) - 8
  var colX: array[5, float32]
  for i in 0 .. 4: colX[i] = x + PlayW + 4 + nameW + 4 + i.float32 * (NumW + 4)
  let heads = ["Weight", "Volume min", "Volume max", "Pitch min", "Pitch max"]
  let headTips = ["How often it's picked against the others: 20 is twice as often as 10.",
                  "Each play picks a volume between min and max.", "Each play picks a volume between min and max.",
                  "Each play picks a pitch between min and max (speed and pitch together).",
                  "Each play picks a pitch between min and max (speed and pitch together)."]
  label("Sound", rect(x + PlayW + 4, y, nameW, 20))
  for i in 0 .. 4: label(heads[i], rect(colX[i], y, NumW, 20), headTips[i])
  y += 22
  let by = box.y + box.h - 46
  let addY = by - 44
  let area = rect(box.x, y, BoxW, max(40'f32, addY - y - 6))
  var remove = -1
  a.scrolledRows("amb.rows", area, e.scroll, proc(y0: float32): float32 =
    var ry = y0
    let perms = addr e.amb.tracks[t].perms
    if perms[].len == 0:
      ui.textIn("No sounds: add recordings below.", rect(x, ry, innerW, FieldH), colTextDisabled, FontSmall)
      ry += 30
    for i in 0 ..< perms[].len:
      let p = addr perms[][i]
      let id = "amb.p." & $t.ord & "." & $i
      let rec = recordingValue(p.sound.soundBase, p.pitch[0])
      let on = soundPlaying(rec)
      if ui.iconButton(id & ".play", rect(x, ry, PlayW, FieldH), if on: "stop16" else: "play16",
                       if on: "Stop" else: "Listen to it (at Pitch min)", focusable = false):
        app.previewClassSound(rec, true)
      ui.textIn(ui.ellipsize(p.sound.soundBase, nameW), rect(x + PlayW + 8, ry, nameW - 4, FieldH), colText)
      var w = p.weight.float
      if ui.numberField(id & ".w", rect(colX[0], ry, NumW, FieldH), w, 1, 0, 1000, 0):
        p.weight = int(w)
        changed = true
      var v0 = p.vol[0]
      var v1 = p.vol[1]
      var p0 = p.pitch[0]
      var p1 = p.pitch[1]
      if ui.numberField(id & ".v0", rect(colX[1], ry, NumW, FieldH), v0, 0.05, 0, 1, 2):
        p.vol = (v0, max(v0, p.vol[1])); changed = true
      if ui.numberField(id & ".v1", rect(colX[2], ry, NumW, FieldH), v1, 0.05, 0, 1, 2):
        p.vol = (min(v1, p.vol[0]), v1); changed = true
      if ui.numberField(id & ".p0", rect(colX[3], ry, NumW, FieldH), p0, 0.05, 0.25, 4, 2):
        p.pitch = (p0, max(p0, p.pitch[1])); changed = true
      if ui.numberField(id & ".p1", rect(colX[4], ry, NumW, FieldH), p1, 0.05, 0.25, 4, 2):
        p.pitch = (min(p1, p.pitch[0]), p1); changed = true
      if ui.iconButton(id & ".del", rect(colX[4] + NumW + 8, ry, DelW, FieldH), "close16",
                       "Remove it from this track", focusable = false):
        remove = i
      ry += 30
    ry)
  if remove >= 0:
    e.amb.tracks[t].perms.delete remove
    changed = true
  # Add a recording.
  let addId = "amb.add"
  let addRect = rect(x, addY, innerW - 100, 28)
  let cat = a.soundCatalog
  proc addSound(v: string) =
    let name = v.strip.toLowerAscii
    var known = false
    for c in cat.recordingChoices:
      if c.value == name: known = true
    if not known:
      e.error = "There is no recording called " & v.strip
      return
    var p = NewPerm
    p.sound = name & ".aif"
    e.amb.tracks[e.track].perms.add p
    e.addText = ""
    e.error = ""
    e.scroll = 1e9   # To the new row.
  if ui.focusId == addId:
    if a.drop.id != addId: a.openDrop(addId, cat.recordingChoices, e.addText)
    a.drop.soundField = true
    a.drop.impulse = true
    a.dropShown(addRect, addRect.x, e.addText, addSound)
  let ev = ui.textField(addId, addRect, e.addText, "Add a recording to " & $t & ": type to search")
  if eeCommitted in ev and e.addText.strip.len > 0 and
     (ui.window.buttonPressed[KeyEnter] or ui.window.buttonPressed[NumpadEnter]):
    addSound(e.addText)
  if ui.textButton("amb.addbtn", rect(x + innerW - 92, addY, 92, 28), "Add") and e.addText.strip.len > 0:
    addSound(e.addText)
  # Buttons.
  if e.error.len > 0:
    ui.text(ui.ellipsize(e.error, innerW - 420, FontSmall), vec2(x, by + 8), colError, FontSmall)
  var choice = ""
  let listening = soundPlaying(DraftAmbient)
  if ui.textButton("amb.listen", rect(box.x + box.w - 392, by, 88, 30), if listening: "Stop" else: "Listen"):
    if listening: stopSound()
    elif not e.amb.playable: e.error = "Add a recording to one of the tracks first"
    else:
      setDraftAmbient(e.amb)
      app.withSounds("sound", proc() =
        try: playSound(DraftAmbient, 1, 1)
        except CatchableError as err: app.say(err.msg, true))
  if not isNew:
    let users = if e.confirmDelete: a.ambientUsers(e.amb.name) else: 0
    let delLabel = if e.confirmDelete: "Really delete" else: "Delete"
    if ui.textButton("amb.delete", rect(box.x + box.w - 296, by, 88, 30), delLabel):
      if e.confirmDelete: choice = "delete"
      else: e.confirmDelete = true
    if e.confirmDelete:
      e.error = if users == 1: "An object still uses " & e.amb.name & ": it would play nothing"
                elif users > 1: $users & " objects still use " & e.amb.name & ": they'd play nothing"
                else: "Click again to delete " & e.amb.name
  if ui.textButton("amb.save", rect(box.x + box.w - 200, by, 88, 30), "Save", primary = true): choice = "save"
  if ui.textButton("amb.cancel", rect(box.x + box.w - 104, by, 88, 30), "Cancel") or
     (ui.window.buttonPressed[KeyEscape] and a.openDropdown.len == 0 and not editing and
      choice.len == 0): choice = "cancel"
  # Last: its list goes over what's below.
  let picked = a.dropdown("amb.prio", prioR, e.amb.priority, @Priorities)
  if picked >= 0:
    e.amb.priority = Priorities[picked]
    changed = true
  ui.sk.popLayer()
  a.drawFieldDrop()   # The Add field's list, over the dialog.
  ui.captured = true
  if changed:
    e.confirmDelete = false
    if not e.error.startsWith("There is no"): e.error = ""
    if soundPlaying(DraftAmbient): setDraftAmbient(e.amb)   # Heard from the next play.
  case choice
  of "save":
    if isNew:
      let problem = nameProblem(e.amb.name.strip, cat.soundNamesTaken)
      if problem.len > 0:
        e.error = problem
        return
      e.amb.name = e.amb.name.strip
    if not e.amb.playable:
      e.error = "Add a recording to one of the tracks first"
      return
    var ambs = loadAmbients(a.proj.ambientsPath)
    var found = false
    for x in ambs.mitems:
      if x.name.toLowerAscii == e.original.toLowerAscii and not isNew:
        x = e.amb
        found = true
    if not found: ambs.add e.amb
    try: saveAmbients(a.proj.ambientsPath, ambs)
    except CatchableError as err:
      e.error = "Can't save: " & err.msg
      return
    setProjectAmbients(ambs)
    a.catalog.forgetProject()
    if soundPlaying(DraftAmbient): stopSound()
    a.ambientEdit = nil
    ui.focusId = ""
    if isNew and e.pick != nil: e.pick(e.amb.name)
    a.say (if isNew: "Added the ambient " else: "Saved the ambient ") & e.amb.name &
          " (Build puts it in the level; it needs Arklite in the game)"
  of "delete":
    var ambs = loadAmbients(a.proj.ambientsPath)
    ambs.keepItIf(it.name.toLowerAscii != e.original.toLowerAscii)
    try: saveAmbients(a.proj.ambientsPath, ambs)
    except CatchableError as err:
      e.error = "Can't save: " & err.msg
      return
    setProjectAmbients(ambs)
    a.catalog.forgetProject()
    if soundPlaying(DraftAmbient) or soundPlaying(e.original): stopSound()
    a.ambientEdit = nil
    ui.focusId = ""
    a.say "Deleted the ambient " & e.original
  of "cancel":
    if soundPlaying(DraftAmbient): stopSound()
    a.ambientEdit = nil
    ui.focusId = ""
  else: discard ui.tabNavigate(firstStop)

proc drawSavePrompt*(a: App) =
  ## Unsaved changes: Yes saves then continues, No continues without saving,
  ## Cancel (or Esc) stays put.
  if a.savePrompt == nil: return
  let ui = a.ui
  let firstStop = ui.tabStops.len
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - 440) / 2), floor((ui.size.y - 150) / 2), 440, 150)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Unsaved changes", vec2(box.x + 16, box.y + 12), colText, FontTitle)
  let name = if a.proj != nil: a.proj.title else: "the project"
  ui.text("Save changes to " & name & " first?", vec2(box.x + 16, box.y + 54), colTextDim)
  let by = box.y + box.h - 46
  var choice = ""
  if ui.textButton("saveprompt.yes", rect(box.x + box.w - 296, by, 88, 30), "Yes", primary = true): choice = "yes"
  if ui.textButton("saveprompt.no", rect(box.x + box.w - 200, by, 88, 30), "No"): choice = "no"
  if ui.textButton("saveprompt.cancel", rect(box.x + box.w - 104, by, 88, 30), "Cancel") or
     ui.window.buttonPressed[KeyEscape]: choice = "cancel"
  ui.sk.popLayer()
  ui.captured = true
  if choice.len == 0: discard ui.tabNavigate(firstStop)  # Tab stays in the dialog.
  if choice.len > 0:
    let action = a.savePrompt
    a.savePrompt = nil
    if choice == "yes": a.saveProject()
    if choice != "cancel": action()
