## Everything around the map views, laid out like TrenchBroom: menu bar,
## toolbar, tool options strip, the inspector (Map / Entity / Face tabs with the
## entity and texture browsers), the Console / Issues panel, the status bar, the
## welcome screen and the settings dialog.

import std/[os, osproc, strutils, strformat, math, tables, sets, algorithm, times, sequtils, xmltree, xmlparser]
import silky, vmath, bumpy, pixie
import theme, ui, dialogs, icons, music, sky, menutree, colorpick
import levelobjects, project, jobs, camera, render, geometry, geomops, objtemplates, appstate, viewtools,
  presets, library, thumbs, fieldchoices, fieldtypes, classes, files, soundscene, particlesim

const
  ToolbarHeight* = 38'f32
  OptionsHeight* = 32'f32
  RowH = 22'f32

# --- small widgets ------------------------------------------------------------------------

proc sectionTitle(ui: Ui, r: Rect, title: string) =
  ui.rect(r, colPanelRaised)
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)
  ui.text(title, vec2(r.x + 8, r.y + (r.h - 18) / 2), colText, FontSmall)

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
  let colW = max(r.w, 160)
  let h = rows.float32 * 24 + 8
  var box = rect(r.x, r.y + r.h + 2, colW * cols.float32, h)
  if box.y + box.h > ui.size.y:
    box.y = if r.y - h - 2 >= 0: r.y - h - 2 else: max(0'f32, ui.size.y - h - 8)
  if box.x + box.w > ui.size.x: box.x = max(0'f32, ui.size.x - box.w - 8)
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(box.x + 3, box.y + 3, box.w, box.h), colShadow)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  for i, it in items:
    let ir = rect(box.x + 4 + (i div rows).float32 * colW, box.y + 4 + (i mod rows).float32 * 24,
                  colW - 8, 24)
    if i == a.dropdownHi: ui.rect(ir, colAccentDim)
    elif ui.mouse.inside(ir): ui.rect(ir, colHover)
    ui.textIn(it, rect(ir.x + 8, ir.y, ir.w - 8, ir.h), colText)
    if ui.mouse.inside(ir) and ui.window.buttonPressed[MouseLeft]:
      result = i
      if clickFocus: ui.navId = id
  ui.sk.popLayer()
  if ui.window.buttonPressed[MouseLeft]:
    a.openDropdown = ""
    ui.consumeClick()
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
  a.say &"Copied {a.clipboard.len div 2} object(s)" &
    (if a.clipboardGeo != nil: &" and {a.clipboardGeo.faces.len} face(s)" else: "")

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

proc openOptions(a: App) =
  a.ui.navId = ""
  a.settingsEdit = a.cfg
  a.optionsOpen = true

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

proc menus*(a: App): seq[(string, seq[MenuItem])] =
  let hasProj = a.proj != nil
  let hasSel = a.hasSelection
  let geo = a.geo != nil
  result.add ("File", @[
    item("New project...", "Ctrl+N", not a.busy, action = proc() =
      a.whenSaved(proc() =
        a.closeProject()
        a.newName = ""
        a.window.title = "Catwalk")),
    item("Open project...", "Ctrl+O", not a.busy, action = proc() =
      a.dialog = startDialog(dkOpenDir, "project", "Open Catwalk project", a.cfg.projectsDir, @[])),
    item("Close project", "Ctrl+W", hasProj and not a.busy, action = proc() =
      a.whenSaved(proc() =
        a.closeProject()
        a.window.title = "Catwalk")),
    sep(),
    item("Save", "Ctrl+S", hasProj, action = proc() = a.saveProject()),
    item("Save As...", "Ctrl+Shift+S", hasProj and not a.busy, action = proc() =
      a.dialog = startDialog(dkSaveFile, "saveas", "Save project as", a.nextFreeProjectDir())),
    item("Save a copy...", "Ctrl+Alt+S", hasProj and not a.busy, action = proc() =
      a.dialog = startDialog(dkSaveFile, "savecopy", "Save a copy of the project",
                             a.nextFreeProjectDir())),
    sep(),
    item("Settings...", "", true, action = proc() = a.openSettings()),
    sep(),
    item("Quit", "Ctrl+Q", true, action = proc() = a.window.closeRequested = true)])
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
    item("Duplicate", "Ctrl+D", hasSel, action = proc() = a.duplicateSelection(vec3(0, 0, 0), flash = true)),
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
    item("CSG: Convex merge", "Ctrl+J", geo and (a.selPieces.len > 0 or a.selFaces.len > 1), action = proc() = a.csg("merge")),
    item("CSG: Subtract", "Ctrl+K", geo and a.selPieces.len > 0, action = proc() = a.csg("subtract")),
    item("CSG: Hollow", "Ctrl+Shift+K", geo and a.selPieces.len > 0, action = proc() = a.csg("hollow")),
    item("CSG: Intersect", "Ctrl+L", geo and a.selPieces.len > 1, action = proc() = a.csg("intersect")),
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
      item("Realtime preview", "", hasProj, a.realtime, action = proc() = a.toggleRealtime()),
      sep(),
      item("Invisible and marker faces", "", true, a.opts.markers, action = proc() =
        a.opts.markers = not a.opts.markers
        if a.geo != nil: a.geo.bump()),
      item("AI rooms", "", true, a.opts.rooms, action = proc() = a.opts.rooms = not a.opts.rooms),
      item("Entity models", "", true, a.opts.models, action = proc() = a.opts.models = not a.opts.models),
      item("Sky", "", true, a.opts.sky, action = proc() = a.opts.sky = not a.opts.sky),
      item("Object names in 2D", "", true, a.showObjectNames, action = proc() =
        a.showObjectNames = not a.showObjectNames)]),
    subMenu("Camera", @[
      item("Focus camera on selection", "Ctrl+U", hasProj, action = proc() = a.frameSelection()),
      item("Reset cameras", "Ctrl+Shift+U", hasProj, action = proc() = a.frameAll()),
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
    item("Options...", "", true, action = proc() = a.openOptions())])
  result.add ("Run", @[
    item("Play", "F5", hasProj and not a.busy, action = proc() = a.build(play = true)),
    item("Build", "F7", hasProj and not a.busy, action = proc() = a.build(play = false)),
    sep(),
    item("Check for issues", "", hasProj, action = proc() =
      a.findIssues()
      a.showPanel(pkIssues)),
    sep(),
    item("Open project folder", "", hasProj, action = proc() =
      discard execShellCmd("xdg-open " & quoteShell(a.proj.dir) & " >/dev/null 2>&1 &")),
    item("Open build log", "", hasProj, action = proc() =
      discard execShellCmd("xdg-open " & quoteShell(a.proj.logPath) & " >/dev/null 2>&1 &"))])
  result.add ("Help", @[
    item("Catwalk README", "F1", true, action = proc() =
      let readme = getAppDir() / "README.md"
      discard execShellCmd("xdg-open " & quoteShell(readme) & " >/dev/null 2>&1 &"))])

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
  # The preview's own volumes: the built level keeps its own.
  result.slider("Sound objects volume", a.previewSoundVolume,
                onChange = proc(v: float) = a.previewSoundVolume = v)
  result.slider("Music volume", a.previewMusicVolume,
                onChange = proc(v: float) = a.previewMusicVolume = v)

proc contextTree(a: App): MenuNode =
  ## Right click in a view (TrenchBroom's map view menu, for Oni's objects).
  let c = a.ctx
  if c.file.len > 0: return a.fileContextTree(c.file)
  if c.realtime: return a.realtimeTree()
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
  result.sep()
  # Groups, as TrenchBroom's map view menu: the group under the click can take
  # the selection, or take in the other selected groups.
  let hit = if c.obj != nil: a.objGroup(c.obj)
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
      if hitUnit != 0 and hitUnit notin units and (units.len > 0 or loose):
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

# --- build and play ----------------------------------------------------------------------

proc startJob*(a: App, j: Job, onDone: proc() = nil) =
  a.job = j
  a.jobDone = onDone
  a.say j.title & "..."

proc build*(a: App, play: bool) =
  if a.proj == nil or a.busy: return
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

proc buildLibrary*(a: App) =
  if a.busy: return
  try:
    let log = libraryDir().parentDir / "library.log"
    a.startJob(libraryJob(a.cfg, log, proc() = discard), proc() =
      a.loadPresets()
      a.say "Built the entity library: " & libraryDir())
  except CatchableError as e:
    a.say(e.msg, true)

proc autoBuildPreviews*(a: App) =
  ## The entity browser's tiles and the views' entity models come from the
  ## library build: when they're shown and missing or from an older version,
  ## rebuild once, unasked, whichever panel is open.
  let wanted = a.entityPreview > 0 or (a.opts.models and a.proj != nil)
  if wanted and not hasPreviews() and not a.busy and not a.previewAutoBuild and
     not libraryBusyElsewhere():
    a.previewAutoBuild = true
    a.say "Rendering entity previews and models (about 30 s)"
    a.buildLibrary()

proc autoExtractSky*(a: App) =
  ## The 3D view's skybox needs level 0's sky images: extract them once,
  ## unasked, when a project with a sky is open.
  if a.opts.sky and a.proj != nil and a.proj.sky.len > 0 and not hasSkyCache() and
     not a.busy and not a.skyAutoBuild:
    a.skyAutoBuild = true
    try: a.startJob(skyCacheJob(a.cfg, skyDir().parentDir / "sky.log"), proc() = discard)
    except CatchableError as e: a.say(e.msg, true)

proc sayFaceWarnings(a: App): seq[string] {.discardable.} =
  ## Copies the job's face warnings into the console, where they stay as links
  ## after the job's own log scrolls away. Returns the lines copied.
  try:
    for l in readFile(a.job.logPath).splitLines:
      if l.startsWith("warning: face "):
        a.say l
        result.add l
  except IOError: discard

proc pollJob*(a: App) =
  if a.job == nil: return
  a.job.poll()
  case a.job.state
  of jsRunning: discard
  of jsDone:
    a.sayFaceWarnings()
    let done = a.jobDone
    a.job = nil
    a.jobDone = nil
    if done != nil: done()
  of jsFailed:
    let shown = a.sayFaceWarnings()
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
    ui.rect(rect(x, y + 4, 1, 20), colBorder)
    x += 7
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
  let can = hasProj and not a.busy
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
    ui.rect(rect(x, y + 3, 1, 18), colBorder)
    x += 12
  ui.pushClip(rect(r.x, r.y, r.w - 140, r.h))
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
  # The render modes first, then the toggles.
  let toggles = [("Invisible and marker faces", a.opts.markers),
                 ("AI rooms", a.opts.rooms), ("Entity models", a.opts.models),
                 ("Object names in 2D", a.showObjectNames), ("Grid", a.showGrid), ("Sky", a.opts.sky),
                 ("Realtime preview", a.realtime)]
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
  of 4: a.showGrid = not a.showGrid
  of 5: a.opts.sky = not a.opts.sky
  of 6: a.toggleRealtime()
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
  depth: int             ## 0 layer, 1 member.
  obj: LevelObject
  piece: int32


proc withSounds(a: App, what: string, play: proc()) =
  ## Runs play now, or once level 0's sounds are extracted (the first preview).
  if hasSoundCache():
    play()
  elif a.busy:
    a.say("Wait for the current job to finish, then preview the " & what & " again", true)
  else:
    try: a.startJob(soundCacheJob(a.cfg, soundDir().parentDir / "sounds.log"), play)
    except CatchableError as e: a.say(e.msg, true)

proc previewMusic(a: App, realtime = false) =
  ## Plays the project's track (realtime: as Realtime preview's level music).
  let p = a.proj
  a.withSounds("music", proc() =
    if p != a.proj or p.music.len == 0: return
    try: playMusic(p.music, p.musicVolume, realtime)
    except CatchableError as e: a.say(e.msg, true))

proc soundLevel(o: LevelObject): (float, float) =
  ## A Sound object's Volume and Pitch.
  result = (1.0, 1.0)
  for f in o.fields:
    try:
      if f.path == "OSD/Volume": result[0] = parseFloat(f.value.strip)
      elif f.path == "OSD/Pitch": result[1] = parseFloat(f.value.strip)
    except ValueError: discard

proc soundClass(o: LevelObject): string =
  ## A Sound object's Class (the ambient it plays).
  for f in o.fields:
    if f.path == "OSD/Class" and f.attr.len == 0: return f.value.strip

proc previewSound(a: App, ambient: string, o: LevelObject) =
  ## Plays a Sound object's ambient (or ambient, one of its Class choices) at
  ## its Volume and Pitch; again stops it.
  if soundPlaying(ambient):
    stopSound()
    return
  a.soundObj = o
  a.soundClass = o.soundClass
  a.withSounds("sound", proc() =
    let (vol, pitch) = o.soundLevel
    try: playSound(ambient, vol, pitch)
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
    if a.sceneKey != "extracting" and not a.busy:
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

proc particleSources(a: App): (string, seq[ParticleSource]) =
  ## The visible Particle objects, and a key that changes when any of them does.
  var key = ""
  for o in a.objects:
    if o.tag != "PART" or not a.visible(o): continue
    let cls = o.node.xpath("OSD/Class").str.strip
    let flags = try: parseInt(o.node.xpath("OSD/Flags").str.strip) except ValueError: 0
    let ds = strutils.splitWhitespace(o.node.xpath("OSD/DecalScale").str)
    var decal = vec2(1, 1)
    if ds.len == 2:
      try: decal = vec2(parseFloat(ds[0]), parseFloat(ds[1]))
      except ValueError: discard
    let started = o.node.xpath("OSD/Tag").str.strip == AutoStartTag
    let m = objectMatrix(vec3(0, 0, 0), o.rot)
    result[1].add ParticleSource(cls: cls, pos: o.pos, flags: flags, decalScale: decal, started: started,
      axes: [(m * vec3(1, 0, 0)).normalize, (m * vec3(0, 1, 0)).normalize, (m * vec3(0, 0, 1)).normalize])
    key.add &"{o.id} {cls} {o.pos} {o.rot} {flags} {decal} {started}\n"
  result[0] = key

proc updateParticles*(a: App) =
  ## Realtime preview's particles, every frame: the level's Particle objects
  ## run their classes (particlesim.nim) and the 3D views draw them.
  let on = a.realtime and a.proj != nil and ppParticles in a.previewParts
  if not on:
    if a.particleSim != nil:
      a.particleSim = nil
      a.particleKey = ""
      a.rend.sprites.setLen 0
      a.rend.particleTris.setLen 0
    return
  if not hasParticleCache():
    # The first time, level 0's particle classes are extracted.
    if not a.particleAutoBuild and not a.busy:
      a.particleAutoBuild = true
      try: a.startJob(particleCacheJob(a.cfg, particleDir() / "particles.log"), proc() = discard)
      except CatchableError as e: a.say(e.msg, true)
    return
  let now = epochTime()
  if a.particleSim == nil:
    a.particleSim = newParticleSim()
    a.particleKey = ""
    a.particleClock = now
    let dir = levelTextureDir(a.proj.oniDir)
    if fileExists(dir / "done"): a.particleSim.levelTextures = dir
  let (key, sources) = a.particleSources
  if key != a.particleKey:
    a.particleSim.reset(sources)
    a.particleKey = key
  a.particleSim.step(now - a.particleClock, a.geo, now)
  a.particleClock = now
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
  var rows: seq[TreeRow]
  for (key, name, n, unit) in layers:
    rows.add TreeRow(layer: key, depth: 0, piece: -1)
    if key notin a.expanded: continue
    if key == GeometryLayer:
      for pc, pi in info:
        if pi.world: rows.add TreeRow(layer: key, depth: 1, piece: pc.int32)
    else:
      for o in a.objects:
        if o.tag == key: rows.add TreeRow(layer: key, depth: 1, obj: o, piece: -1)
  let rowH = 22'f32
  if a.mapReveal != nil:
    # Scrolled to the row of an object shown from elsewhere (the Scripts panel's Ctrl+click).
    for i, row in rows:
      if row.obj == a.mapReveal:
        a.layersCursor = i
        a.treeAnchor = i
        a.layersScroll = i.float32 * rowH - list.h / 2
    a.mapReveal = nil
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
  for i in first ..< min(rows.len, first + int(list.h / rowH) + 2):
    let row = rows[i]
    let rr = rect(list.x, list.y + i.float32 * rowH - a.layersScroll, list.w, rowH)
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
      ui.icon(if open: "expand16" else: "arrow16", vec2(rr.x + 10, rr.y + rowH / 2), colTextDim)
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
      continue
    # A member: a geometry piece or an object.
    let sel = if row.obj != nil: row.obj.selected else: row.piece in a.selPieces
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
      ui.rect(rect(rr.x + 28, rr.y + 6, 10, 10), rgbx(col[0], col[1], col[2], 255))
    let nx = rr.x + 44
    let room = eyeR.x - nx - 6
    let nameW = min(ui.textSize(name, FontSmall).x, room)
    ui.textIn(ui.ellipsize(name, room, FontSmall), rect(nx, rr.y, room, rowH),
              if hiddenM: colTextDisabled else: colText, FontSmall)
    let dw = max(0, room - nameW - 8)
    ui.textIn(ui.ellipsize(detail, dw, FontSmall), rect(nx + nameW + 8, rr.y, dw, rowH), colTextDim, FontSmall)
    let body = rect(rr.x, rr.y, eyeR.x - rr.x, rowH)
    if ui.hover(body) and ui.pressed() and ui.mouse.inside(list):
      ui.consumeClick()
      a.layersCursor = i
      let dbl = ui.countClick("tree." & id) >= 2
      proc setSel(rw: TreeRow, on: bool) =
        if rw.obj != nil:
          if a.pickable(rw.obj) or not on: rw.obj.selected = on
        elif on: a.selPieces.incl rw.piece
        else: a.selPieces.excl rw.piece
      if ui.window.shiftDown and a.treeAnchor >= 0 and a.treeAnchor < rows.len:
        # Shift+click: everything between the last clicked row and this one.
        if not ui.window.ctrl: a.clearSelection()
        for k in min(a.treeAnchor, i) .. max(a.treeAnchor, i):
          if rows[k].depth == 1: setSel(rows[k], true)
      elif ui.window.ctrl:
        if a.selFaces.len > 0: a.clearSelection()
        setSel(row, not sel)
        a.treeAnchor = i
      else:
        a.clearSelection()
        setSel(row, true)
        a.treeAnchor = i
      if dbl: a.frameSelection()
  var rowRects = newSeq[Rect](rows.len)
  for i in 0 ..< rows.len:
    rowRects[i] = rect(list.x, list.y + i.float32 * rowH - a.layersScroll, list.w, rowH)
  discard ui.listNav("map.layers", list, rowRects, a.layersCursor, horizontal = false)
  if listFocused and a.layersCursor in 0 ..< rows.len:
    let c = a.layersCursor
    let row = rows[c]
    let open = row.layer in a.expanded
    ui.cursorRing(rowRects[c])
    if ui.navKey("map.layers", KeyLeft):
      if row.depth == 0: a.expanded.excl row.layer
      else:
        var k = c
        while k > 0 and rows[k].depth != 0: dec k
        a.layersCursor = k
    if ui.navKey("map.layers", KeyRight) and row.depth == 0: a.expanded.incl row.layer
    if ui.navActivate("map.layers"):
      if row.depth == 0:
        if open: a.expanded.excl row.layer else: a.expanded.incl row.layer
      elif row.obj != nil:
        if a.pickable(row.obj):
          a.clearSelection()
          row.obj.selected = true
      else:
        a.clearSelection()
        a.selPieces.incl row.piece
      a.treeAnchor = c
  ui.popClip()
  ui.scrollbar("map.layers", list, a.layersScroll, rows.len.float32 * rowH)

proc drawLevelInfo(a: App, r: Rect) =
  ## Properties with nothing selected: the level's own settings.
  let ui = a.ui
  if a.proj == nil: return
  ui.sectionTitle(rect(r.x, r.y, r.w, 26), "Level")
  let area = rect(r.x, r.y + 26, r.w, max(0'f32, r.h - 26))
  if ui.hover(area) and not ui.scrollConsumed: a.levelScroll += ui.wheelNotches * RowH * 3
  ui.scrollArea("props.level", area, a.levelScroll)
  ui.pushClip(area)
  ui.scrollIntoView(a.levelScroll)
  var y = area.y + 8 - a.levelScroll
  let x = r.x + 10
  let w = r.w - 20
  var title = a.proj.title
  let tr = a.propName("Name", x, y, w, "The level's name in Oni's Custom Game list")
  discard ui.textField("map.title", tr, title)
  if title != a.proj.title:
    let before = a.proj.projSettings
    a.proj.title = title
    a.editProject("Rename Level", before, merge = "map.title")
    a.updateWindowTitle()
  y += 30
  if a.proj.scratch:
    var skyItems = @["None"]
    for s in Skies: skyItems.add s
    let sr = a.propName("Sky", x, y, w)
    let si = a.dropdown("map.sky", sr, if a.proj.sky.len > 0: a.proj.sky else: "None", skyItems)
    if si >= 0:
      let before = a.proj.projSettings
      a.proj.sky = if si == 0: "" else: Skies[si - 1]
      a.editProject("Change Sky", before)
    y += 30
  a.musicRow(x, y, w)
  a.lightingRows(x, y, w)
  if a.proj.scratch: a.propText("Source", "Made in Catwalk", x, y, w)
  else: a.propText("Source", &"Level {a.proj.levelNumber} ({a.proj.source})", x, y, w)
  a.propText("Environment", a.proj.envName, x, y, w)
  if not a.proj.scratch and a.proj.sky.len > 0: a.propText("Sky", a.proj.sky, x, y, w)
  a.propText("Project folder", a.proj.dir, x, y, w, a.proj.dir)
  a.propText("Builds to", a.cfg.customLevels / a.proj.folder, x, y, w, a.cfg.customLevels / a.proj.folder)
  let contentH = y + a.levelScroll - area.y
  a.levelScroll = clamp(a.levelScroll, 0, max(0, contentH - area.h))
  ui.popClip()
  ui.scrollbar("props.level", area, a.levelScroll, contentH)

# --- inspector: entity ---------------------------------------------------------------------

var propsContent: float32   ## Properties' object page: the content height this frame (its scrollbar).

proc commitField(a: App, o: LevelObject, f: ObjectField, value: string) =
  let v = evalField(f.value, value)
  if v == f.value: return
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

proc colorTarget(a: App, objs: seq[LevelObject], fld: ObjectField): ColorTarget =
  ## The color picker sets the field on every object as it goes; closing it
  ## leaves one undo step.
  var before: seq[string]
  let label = "Edit " & fld.path.split('/')[^1]
  ColorTarget(
    live: proc(c: RGB) =
      if before.len == 0: before = snapshotObjects(objs)
      for o in objs:
        o.setField(fld, fmtRgb(c))
        o.syncFromNode(),
    done: proc(changed: bool) =
      if before.len == 0: return
      if changed: a.push editCmd(label, objs, before)
      else:
        for i, o in objs: o.restore(before[i]))

proc commitColor(a: App, objs: seq[LevelObject], fld: ObjectField, text: string) =
  ## A color typed into the field, in any form parseColor takes, stored as "R G B".
  if text.strip.len == 0: return
  let (ok, c) = parseColor(text)
  if not ok:
    a.say("Not a color: " & text & " (use R G B, #RRGGBB or hsv(H, S, V))", true)
    return
  if objs.len == 1: a.commitField(objs[0], fld, fmtRgb(c))
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
  if ft.kind == fkText: return false
  result = true
  let ui = a.ui
  let mixed = uniq.len > 1
  proc parse(s: string): float =
    try: parseFloat(s.strip) except ValueError: 0
  let decimals = if ft.whole: 0 else: -1
  case ft.kind
  of fkText: discard
  of fkNumber:
    var v = parse(uniq[0])
    if ui.numberField(id, r, v, ft.step, ft.lo, ft.hi, decimals, mixed = mixed):
      a.commitFieldAll(objs, fld, fmtNumber(v, decimals))
  of fkToggle:
    var on = uniq[0].strip notin ["", "0"]
    if ui.checkbox(id, vec2(r.x, r.y + 2), "", on, mixed):
      a.commitFieldAll(objs, fld, if on: "1" else: "0")
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

proc dropField(a: App, id: string, r: Rect, left: float32, text: var string,
               o: LevelObject, fld: ObjectField, pick: proc(v: string)) =
  ## Call before the field's textField: shows the list of o's field while the
  ## field is focused and handles its keys (Enter takes the highlighted row).
  let ui = a.ui
  if ui.focusId != id: return
  if a.drop.id != id:
    a.openDrop(id, a.fieldChoices(o, fld), text)
    if o.tag == "SNDG" and fld.path == "OSD/Class" and fld.attr.len == 0:
      a.drop.sound = o
      a.drop.width += SoundButtonW
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
    text = a.drop.items[a.drop.visible[a.drop.hi]].value

proc followSound(a: App) =
  ## A Sound object's preview follows its Class, Volume and Pitch, and stops once
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
    let over = ui.popupHit and ui.mouse.inside(rr) and ui.activeId != "fielddrop.bar"
    if k == a.drop.hi: ui.rect(rr, colAccentDim)
    elif over: ui.rect(rr, colHover)
    if a.drop.sound != nil and c.value.len > 0:
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
  if bar:
    let ty = track.y + (track.h - thumbH) * a.drop.scroll.float32 / (n - DropRows).float32
    ui.rect(track, colTrack)
    ui.rect(rect(track.x, ty, track.w, thumbH),
            if ui.activeId == "fielddrop.bar": colAccent else: colTextDisabled)
  ui.sk.popLayer()
  if ui.popupHit and ui.window.buttonPressed[MouseLeft]: ui.consumeClick()
  if played >= 0: a.previewSound(a.drop.items[a.drop.visible[played]].value, a.drop.sound)
  if picked >= 0:
    let pick = a.drop.pick
    let v = a.drop.items[a.drop.visible[picked]].value
    ui.focusId = ""
    a.drop.id = ""
    if pick != nil: pick(v)

proc pickOne(a: App, o: LevelObject, fld: ObjectField): proc(v: string) =
  ## Per field, so the closure doesn't share the field loop's variable.
  result = proc(v: string) = a.commitField(o, fld, v)

proc pickAll(a: App, sel: seq[LevelObject], fld: ObjectField): proc(v: string) =
  result = proc(v: string) = a.commitFieldAll(sel, fld, v)

proc drawLightObjAnims(a: App, objs: seq[LevelObject], x: float32, y: var float32, w: float32)

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
    if sel[0].tag in LightTags and fld.path.startsWith("OSD/Animation"): continue   # drawLightObjAnims
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
    baseName & " and the other color every period (ones with the same period and offset flicker together).")
  let mi = a.dropdown(idp & ".mode", mr, modeName, modes.mapIt(it[0]))
  if mi >= 0 and modes[mi][1] != m0.mode:
    let mode = modes[mi][1]
    let fromOff = m0.mode == amNone
    let dim = [uint8(base[0].int div 5), uint8(base[1].int div 5), uint8(base[2].int div 5)]
    edit("Light animation", proc(m: var CornerAnim) =
      if fromOff or m.period <= 0: m = m.withDefaults(mode, dim)
      else: m.mode = mode)
  y += 30
  # Presets: the whole animation but its offset (which keeps neighbours apart).
  var presetTip = "Sets every setting below but Offset."
  for (name, desc, pm) in AnimPresets: presetTip.add " " & name & ": " & desc
  let pr = a.propName("Preset", x, y, w, presetTip)
  let pk = a.dropdown(idp & ".preset", pr, "Choose...", AnimPresets.mapIt(it[0]))
  if pk >= 0:
    let (name, _, pm) = AnimPresets[pk]
    let color = if name == "Candle": [base[0] div 2, base[1] div 2, base[2] div 2] else: [0'u8, 0, 0]
    edit("Light animation preset", proc(m: var CornerAnim) =
      let manual = m.manual
      let offset = m.offset
      m = pm
      m.color = color
      m.manual = manual
      m.offset = offset)
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
  if a.proj == nil or name.len == 0 or not hasClassCache() or
     not fileExists(originalClassPath(name)): return nil
  try:
    let o = loadClass(a.proj, name)
    a.classOrig[name] = originalClass(name)
    a.files.add o.file
    result = o
  except CatchableError as e:
    a.say("Could not read class " & name & ": " & e.msg, true)
  a.classes[name] = result   # nil after an error: not tried again

proc editedClasses(a: App): HashSet[string] =
  ## Classes whose values differ from level 0's, now.
  if not a.classOnDiskRead and a.proj != nil:
    a.classOnDiskRead = true
    try: a.classOnDisk = a.proj.editedClasses.toHashSet
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
    let objBefore = @[o.snapshot]
    let linked = a.hasGeometry(o)
    let geoBefore = if linked: a.geo.clone else: nil
    let posChanged = matchesFilter(a.fieldFilter, "Position", "") and
                     vecRow("Position", p, a.grid.float, false)
    let rotChanged = matchesFilter(a.fieldFilter, "Rotation", "") and
                     vecRow("Rotation", rr, 15, true)
    if posChanged or rotChanged:
      a.setPose(o, p, rr)
      a.push editCmd(if posChanged: "Move" else: "Rotate", @[o], objBefore, geoBefore, a.geo)
    # Key / value table.
    var shown = 0
    for fld in o.fields:
      let key = fld.path & "@" & fld.attr
      let name = (if fld.path.startsWith("OSD/"): fld.path[4 .. ^1] else: fld.path) &
                 (if fld.attr.len > 0: " ." & fld.attr else: "")
      if o.tag in LightTags and fld.path.startsWith("OSD/Animation"): continue   # drawLightObjAnims
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
                           if on: "Stop the preview" else: "Listen to this sound at its Volume and Pitch",
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
              let cur = fld.value.strip.toLowerAscii
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
  if tiles and not a.busy and hasPreviews() and not a.presetsCurrent: a.loadPresets()
  let rendering = tiles and not hasPreviews() and (a.busy or libraryBusyElsewhere())
  ui.sectionTitle(rect(br.x, br.y, br.w, 26),
    if rendering: "Rendering model previews..."
    else: "Drag into a view, or click to place")
  const SliderW = 84'f32
  discard ui.textField("entity.filter", rect(br.x + 8, br.y + 32, br.w - SliderW - 28, 26), a.entityFilter, "Search...")
  # Preview size, like TrenchBroom's: all the way left is the compact list.
  let sr = rect(br.x + br.w - SliderW - 12, br.y + 32, SliderW, 26)
  discard ui.slider("entity.preview", sr, a.entityPreview, 0, 1, 0.125)
  ui.tip(sr, "Preview size")
  let list = rect(br.x, br.y + 64, br.w, br.h - 64)
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
      ui.icon(if open: "expand16" else: "arrow16", vec2(hr.x + 10, hr.y + HeadH / 2), colTextDim)
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
    if ui.textButton("entity.library", lb, label, primary = not hasLibrary()) and not a.busy:
      a.buildLibrary()
    ui.tip(lb, "Takes them, with their geometry and textures, from the game's levels (about 30 s)")
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
  if a.busy: return
  a.classAutoBuild = true
  try:
    a.startJob(classCacheJob(a.cfg, classCacheDir().parentDir / "classes.log"), proc() =
      a.classList = classNames()
      a.say &"Read {a.classList.len} character classes from level 0")
  except CatchableError as e:
    a.say(e.msg, true)

proc drawClassFields(a: App, o: LevelObject, props: Rect) =
  ## The open class: what it is, then its fields under their groups.
  let ui = a.ui
  if a.classTextFor != o:
    a.classTextFor = o
    a.classText.clear()
    a.classScroll = 0
  let x = props.x + 10
  let w = props.w - 20
  var y = props.y + 8
  ui.text("Character class", vec2(x, y), colAccent, FontSmall)
  y += 18
  ui.textIn(ui.ellipsize(a.className, w), rect(x, y, w, 22), colText)
  y += 24
  var users = 0
  for ob in a.objects:
    if ob.tag == "CHAR" and ob.node.xpath("OSD/Class").str.strip == a.className: inc users
  let edited = a.className in a.editedClasses
  let note = (if users == 0: "No character in this level uses it"
              elif users == 1: "1 character in this level uses it"
              else: &"{users} characters in this level use it") & (if edited: " · edited" else: "")
  ui.textIn(ui.ellipsize(note, w - 126, FontSmall), rect(x, y, w - 126, 26), colTextDim, FontSmall)
  if edited:
    let rb = rect(x + w - 120, y, 120, 26)
    if ui.textButton("class.revert", rb, "Use game values"):
      let before = @[o.snapshot]
      o.restore(a.classOrig[a.className])
      a.push editCmd("Revert " & a.className, @[o], before)
    ui.tip(rb, "Puts back level 0's values for this class (Undo brings yours back)")
  y += 32
  discard ui.textField("class.fieldFilter", rect(x - 2, y, w + 4, 26), a.classFieldFilter, "Search fields...")
  y += 34
  let list = rect(props.x, y, props.w, props.y + props.h - y)
  if list.h <= 0: return
  ui.scrollArea("class.fields", list, a.classScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.classScroll)
  y = list.y + 4 - a.classScroll
  var group = ""
  var shown = 0
  for fld in o.fields:
    if not matchesFilter(a.classFieldFilter, fld.path, fld.value): continue
    inc shown
    let key = fld.path & "@" & fld.attr
    let id = "cprop." & key
    let cut = fld.path.rfind('/')
    let parent = if cut < 0: "" else: fld.path[0 ..< cut]
    let leaf = (if cut < 0: fld.path else: fld.path[cut + 1 .. ^1]) &
               (if fld.attr.len > 0: " ." & fld.attr else: "")
    if parent != group:
      # Fields of one element under its path, as a heading.
      group = parent
      if parent.len > 0:
        y += 4
        if y + 20 > list.y and y < list.y + list.h:
          ui.textIn(ui.ellipsize(parent.replace("/", " / "), w, FontSmall), rect(x, y, w, 20),
                    colAccent, FontSmall)
        y += 22
    if key notin a.classText or ui.focusId != id: a.classText[key] = fld.value
    let kw = w * 0.42
    let indent = if parent.len > 0: 10'f32 else: 0
    let fr = rect(x + kw, y, w - kw, 26)
    let lr = rect(x + indent, y, kw - indent, 26)
    if a.typedField(id, fr, @[o], fld, @[fld.value]):
      ui.textIn(ui.ellipsize(leaf, lr.w - 6, FontSmall), lr, colTextDim, FontSmall)
      ui.tip(lr, fld.path)
    elif y + 26 <= list.y or y >= list.y + list.h:
      discard ui.tabStop(id, fr, edit = true)  # Out of sight: Tab still gets there.
    else:
      ui.textIn(ui.ellipsize(leaf, lr.w - 6, FontSmall), lr, colTextDim, FontSmall)
      ui.tip(lr, fld.path)
      a.dropField(id, fr, x, a.classText[key], o, fld, a.pickOne(o, fld))
      let ev = ui.textField(id, fr, a.classText[key])
      if eeCommitted in ev: a.commitField(o, fld, a.classText[key])
    y += 30
  if shown == 0: ui.textIn("No field matches", rect(x, list.y + 8, w, 22), colTextDim, FontSmall)
  let contentH = y + a.classScroll - list.y
  if ui.hover(list) and not ui.scrollConsumed:
    a.classScroll += ui.wheelNotches * RowH * 3
  a.classScroll = clamp(a.classScroll, 0, max(0, contentH - list.h + 20))
  ui.popClip()
  ui.scrollbar("class.fields", list, a.classScroll, contentH + 20)

proc drawClassesPage(a: App, r: Rect) =
  ## Character classes: the open one's fields above, every class below.
  let ui = a.ui
  if not hasClassCache():
    # Level 0's classes are extracted once, unasked, the first time this shows.
    if not a.classAutoBuild and a.proj != nil and not a.busy: a.readClasses()
    if a.busy:
      ui.textIn(if a.classAutoBuild: "Reading the character classes from level 0..."
                else: "Waiting for the current job to finish", r, colTextDim, h = CenterAlign)
    else:
      let br = rect(r.x + (r.w - 260) / 2, r.y + r.h / 2 - 13, 260, 26)
      if ui.textButton("class.read", br, "Read the character classes from level 0", primary = true):
        a.readClasses()
    return
  if a.classList.len == 0: a.classList = classNames()
  if a.entityBrowserH <= 0: a.entityBrowserH = 210
  a.entityBrowserH = clamp(a.entityBrowserH, 90, max(90, r.h - 120))
  let browserH = a.entityBrowserH
  let props = rect(r.x, r.y, r.w, r.h - browserH - 6)
  # Follow the selected character: its class opens.
  let sel = a.selection
  if sel.len == 1 and sel[0].tag == "CHAR" and a.classFor != sel[0]:
    a.classFor = sel[0]
    let cn = sel[0].node.xpath("OSD/Class").str.strip
    if cn in a.classList: a.className = cn
  let o = a.openClass(a.className)
  ui.pushClip(props)
  if o == nil:
    ui.textIn(if a.className.len == 0: "Pick a class below, or select a character"
              else: "Level 0 has no class " & a.className, props, colTextDim, h = CenterAlign)
  else:
    a.drawClassFields(o, props)
  ui.popClip()

  let (dragging, my) = a.divider("class.browser", rect(r.x, r.y + r.h - browserH - 6, r.w, 6), false)
  if dragging: a.entityBrowserH = r.y + r.h - my - 3
  let br = rect(r.x, r.y + r.h - browserH, r.w, browserH)
  ui.sectionTitle(rect(br.x, br.y, br.w, 26), "Character classes · click one to edit it")
  discard ui.textField("class.filter", rect(br.x + 8, br.y + 32, br.w - 16, 26), a.classFilter, "Search classes...")
  let list = rect(br.x, br.y + 64, br.w, br.h - 64)
  var used: CountTable[string]
  for ob in a.objects:
    if ob.tag == "CHAR": used.inc ob.node.xpath("OSD/Class").str.strip
  let edited = a.editedClasses
  # The level's classes first.
  var rows: seq[string]
  for first in [true, false]:
    for n in a.classList:
      if (used[n] > 0) == first and matchesFilter(a.classFilter, n, ""): rows.add n
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
      ui.textIn(ui.ellipsize(n, rr.w - nw - 14, FontSmall), rect(rr.x + 8, rr.y, rr.w - nw - 8, rr.h),
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
  ## id and shade. Returns where the rows end.
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
  # Flags.
  a.propGroup("Surface flags", x, y, w)
  for i, (name, bit, desc) in EditableFlags:
    var (any, all) = (false, true)
    for fi in faces:
      if (a.geo.faces[fi].flags and bit) != 0: any = true
      else: all = false
    var v = all
    let fr = a.propName(name, x, y, w, desc)
    if ui.checkbox("face.flag." & name, vec2(fr.x, y + 2), "", v, mixed = any and not all):
      let on = v
      a.applyToFaces(name, proc(fi: int) =
        if on: app.geo.faces[fi].flags = app.geo.faces[fi].flags or bit
        else: app.geo.faces[fi].flags = app.geo.faces[fi].flags and not bit)
    y += 30
  y

proc drawProperties(a: App, r: Rect) =
  ## What's selected, under a header naming it: objects (their type), the
  ## vertex tools' handles, faces, or with nothing selected the level.
  let ui = a.ui
  a.drop.live = false
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
  a.drawFieldDrop()

proc drawTextureBrowser(a: App, br: Rect) =
  ## The level's textures: click one to apply it to the selected faces.
  let ui = a.ui
  let faces = a.selectedFaceSet
  ui.sectionTitle(rect(br.x, br.y, br.w, 26), "Click to apply to the selected faces")
  discard ui.textField("tex.filter", rect(br.x + 8, br.y + 32, br.w - 90, 26), a.texFilter, "Search name or size...")
  let usedR = rect(br.x + br.w - 78, br.y + 32, 70, 26)
  if a.texUsedOnly: ui.rect(usedR, colAccentDim)
  if ui.textButton("tex.used", usedR, "Used"): a.texUsedOnly = not a.texUsedOnly
  ui.tip(usedR, "Only textures the level uses")
  let list = rect(br.x, br.y + 64, br.w, br.h - 64)
  if a.proj == nil: return
  a.loadThumbnails()
  let f = a.texFilter.strip.toLowerAscii
  var used: HashSet[string]
  if a.geo != nil:
    for fc in a.geo.faces: used.incl fc.texture
  # The current texture: the selected faces' (red border), else the one picked.
  var current = a.currentTexture
  for fi in faces:
    current = a.geo.faces[fi].texture
    break
  var shown: seq[string]
  # The search also matches sizes: "256" or "128x" (an x stands for ×).
  let fs = f.replace("x", "×")
  for t in a.textures:
    if (f.len == 0 or f in t.toLowerAscii or (fs.len > 0 and fs in a.texSizeText(t))) and
       (not a.texUsedOnly or t in used): shown.add t
  # Ctrl+wheel over the list zooms the tiles, keeping the same rows in view.
  if ui.hover(list) and not ui.scrollConsumed and ui.window.ctrlDown and ui.wheelNotches != 0:
    let old = a.texThumb
    a.texThumb = clamp(a.texThumb * pow(1.25'f32, -ui.wheelNotches), MinTexThumb, MaxTexThumb)
    a.texScroll *= (a.texThumb + 32) / (old + 32)
    ui.scrollConsumed = true
  let thumb = a.texThumb
  let cell = thumb + 18
  let cols = max(1, int((list.w - 8) / cell))
  let rows = (shown.len + cols - 1) div cols
  if ui.hover(list) and not ui.scrollConsumed: a.texScroll += ui.wheelNotches * cell
  ui.scrollArea("tex.list", list, a.texScroll)
  ui.pushClip(list)
  ui.scrollIntoView(a.texScroll)
  a.texScroll = clamp(a.texScroll, 0, max(0, rows.float32 * (cell + 14) - list.h))
  proc apply(t: string) =
    a.currentTexture = t
    # Picked with no face selected: new geometry gets this texture.
    if faces.len == 0 and a.faceTemplate.texture.len > 0: a.faceTemplate.texture = t
    if faces.len > 0:
      let app = a
      a.applyToFaces("Apply texture", proc(fi: int) =
        app.geo.retexture(fi, t, app.densityFn))
  # One Tab stop: the arrow keys move through the textures, Space/Enter apply one.
  let listFocused = ui.tabStop("tex.list", list)
  var cells = newSeq[Rect](shown.len)
  for i, t in shown:
    let cx = list.x + 6 + (i mod cols).float32 * cell
    let cy = list.y + 4 + (i div cols).float32 * (cell + 14) - a.texScroll
    let r = rect(cx, cy, cell - 6, cell - 6)
    cells[i] = r
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
    ui.tip(r, t & (if size.len > 0: " · " & size else: "") & (if t in used: " (used)" else: ""))
  discard ui.listNav("tex.list", list, cells, a.texCursor)
  if listFocused and a.texCursor in 0 ..< shown.len:
    let c = cells[a.texCursor]
    ui.cursorRing(rect(c.x - 3, c.y - 3, c.w + 6, c.h + 6))
    if ui.navActivate("tex.list"): apply(shown[a.texCursor])
  ui.popClip()
  ui.scrollbar("tex.list", list, a.texScroll, rows.float32 * (cell + 14))

# --- inspector: files ---------------------------------------------------------------------

type FileRow = object
  path: string       ## Relative to the project folder.
  name: string
  depth: int
  dir: bool
  size: int64        ## -1: not known (filter results).

proc openPath(path: string) =
  discard execShellCmd("xdg-open " & quoteShell(path) & " >/dev/null 2>&1 &")

proc showInFolder(path: string) =
  ## The file manager on path's folder with path selected (FileManager1, as
  ## Dolphin and Nautilus offer), else just the folder.
  discard execShellCmd("(gdbus call --session --dest org.freedesktop.FileManager1 " &
    "--object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems " &
    quoteShell("['" & fileUri(path) & "']") & " '' || xdg-open " & quoteShell(path.parentDir) &
    ") >/dev/null 2>&1 &")

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
      ui.icon(if row.path in a.filesOpen: "expand16" else: "arrow16", vec2(x0 + 6, rr.y + rowH / 2), colTextDim)
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
  # One Tab stop: Up/Down move through the face links, Space/Enter follow one.
  if ui.tabStop("console", body):
    var links: seq[Rect]
    var refs: seq[(int, int)]
    if a.geo != nil:
      for i, l in lines:
        let (face, corner) = parseFaceRef(l.text)
        if face < 0: continue
        let y = bottomY - (lines.len - i).float32 * lineH
        links.add rect(body.x + 6, y, ui.textSize(l.text, FontSmall).x + 8, lineH)
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
    let (face, corner) = parseFaceRef(lines[i].text)
    if face >= 0 and a.geo != nil:
      # A link: click puts that face's corner under the vertex tool.
      let sz = ui.textSize(lines[i].text, FontSmall)
      let hit = rect(body.x + 6, y, sz.x + 8, lineH)
      let hot = ui.hover(hit)
      if hot:
        ui.rect(hit, colHover)
        ui.rect(rect(body.x + 10, y + sz.y, sz.x, 1), colAccentHover)
        if ui.pressed():
          ui.consumeClick()
          a.focusFace(face, corner)
      ui.text(lines[i].text, vec2(body.x + 10, y), if hot: colAccentHover else: colAccent, FontSmall)
      continue
    ui.text(lines[i].text, vec2(body.x + 10, y), if lines[i].error: colError else: colTextDim, FontSmall)
  ui.popClip()
  ui.scrollbar("console", body, maxScroll - a.logScroll, total + 8)

proc drawIssues(a: App, body: Rect) =
  let ui = a.ui
  ui.scrollArea("issues", body, a.issuesScroll)
  ui.pushClip(body)
  if a.issues.len == 0:
    ui.text("No issues found (Run ▸ Check for issues to refresh)", vec2(body.x + 10, body.y + 4), colTextDim, FontSmall)
  # One Tab stop: Up/Down move through the issues, Space/Enter go to one.
  let listFocused = ui.tabStop("issues", body)
  if ui.hover(body) and not ui.scrollConsumed: a.issuesScroll += ui.wheelNotches * 20 * 3
  ui.scrollIntoView(a.issuesScroll)
  a.issuesScroll = clamp(a.issuesScroll, 0, max(0, a.issues.len.float32 * 20 + 8 - body.h))
  proc go(iss: Issue) =
    if iss.face >= 0: a.focusFace(iss.face, iss.corner)
    else:
      a.clearSelection()
      if iss.obj != nil: iss.obj.selected = true
      a.frameSelection()
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
    ui.text(iss.text, vec2(body.x + 10, row.y + 2), colText, FontSmall)
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
  if not a.optionsOpen: ui.drawColorPicker()   # View > Options draws it above itself

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
      if noTool and a.selBoxFaces.len > 0: mouse.add ("LMB", "Sound face handle: toggle")
      mouse.add ("Dbl", "Add all in layer")
      if in3D: mouse.add ("Wheel", "Select next behind / in front")
  elif held == {'s'}:
    if drawing: mouse = @[("Drag", "Square " & ($a.shape).toLowerAscii)]
    elif moving: mouse = @[("Drag", "Lock to one axis")]
    else:
      mouse = @[("LMB", "Select face"), ("Dbl", "Select all faces of a piece")]
      if noTool and pieces: mouse.add ("Drag", "Selected brush's face: extrude")
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
    let pr = rect(r.x + 8, r.y + 8, pw, 8)
    ui.rect(pr, colTrack)
    ui.rect(rect(pr.x, pr.y, pw * clamp(j.progress, 0.03, 1), pr.h), colAccent)
    ui.textIn(j.title & ": " & j.stepLabel, rect(r.x + pw + 18, r.y, r.w / 2, r.h), colText, FontSmall)
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

# --- welcome screen and settings ---------------------------------------------------------------

proc drawWelcome*(a: App, area: Rect) =
  let ui = a.ui
  ui.rect(area, colBackground)
  let w = min(860'f32, area.w - 40)
  let x0 = area.x + (area.w - w) / 2
  var y = area.y + 40
  let logo = ui.sk.getImageSize("logo")
  ui.sk.drawImage("logo", vec2(x0, y).floor)
  ui.text("Level editor for Oni", vec2(x0 + logo.x + 16, y + logo.y - 26), colTextDim)
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
  for p in projects:
    let r = rect(lx, py, colW, 30)
    let hov = ui.hover(r)
    ui.rect(r, if hov: colHover else: colPanelRaised)
    ui.textIn(p.lastPathPart, rect(r.x + 10, r.y, r.w - 20, r.h), colText)
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
  if a.newName.len == 0 and not a.busy and ui.focusId != "welcome.name":
    a.newName = uniqueName("NewLevel")
  var ly = y
  ui.text("Project name", vec2(rx, ly), colTextDim, FontSmall)
  discard ui.textField("welcome.name", rect(rx, ly + 18, colW, 28), a.newName)
  let taken = a.newName.strip.len > 0 and dirExists(a.cfg.projectsDir / a.newName.strip)
  if taken and not a.busy:
    ui.text("A project with this name already exists", vec2(rx, ly + 50), colError, FontSmall)
  if a.busy: ui.text(a.job.title & ": " & a.job.stepLabel, vec2(rx, ly + 50), colText, FontSmall)
  ly += 80

  # Empty level: a floor and a player start, like a new map in TrenchBroom.
  ui.text("Empty level", vec2(rx, ly), colText)
  ui.text("A floor and a player start. Textures come from the game levels you pick.",
          vec2(rx, ly + 22), colTextDim, FontSmall)
  ly += 46
  let tw = floor((colW - 132) * 0.55)
  let sw = colW - 132 - tw - 6
  ui.text("Textures from", vec2(rx, ly), colTextDim, FontSmall)
  ui.text("Sky", vec2(rx + tw + 6, ly), colTextDim, FontSmall)
  var texItems = @["All game levels"]
  for n in levels: texItems.add "Level " & $n
  let texLabel = if a.newTexLevel > 0: "Level " & $a.newTexLevel else: texItems[0]
  let ti = a.dropdown("welcome.tex", rect(rx, ly + 18, tw, 28), texLabel, texItems)
  if ti == 0: a.newTexLevel = 0
  elif ti > 0: a.newTexLevel = levels[ti - 1]
  var skyItems = @["None"]
  for s in Skies: skyItems.add s
  let si = a.dropdown("welcome.sky", rect(rx + tw + 6, ly + 18, sw, 28),
                      if a.newSky.len > 0: a.newSky else: "None", skyItems)
  if si == 0: a.newSky = ""
  elif si > 0: a.newSky = Skies[si - 1]
  if levels.len > 0 and not a.busy and not taken:
    if ui.textButton("welcome.empty", rect(rx + colW - 120, ly + 18, 120, 28), "Create", primary = true):
      a.newEmptyLevel(a.newName)
  ly += 66

  ui.text("Copy of an Oni level", vec2(rx, ly), colText)
  ui.text("Its geometry, objects and scripts, to change.", vec2(rx, ly + 22), colTextDim, FontSmall)
  ly += 46
  if levels.len == 0:
    ui.text("No Oni levels found in " & a.cfg.gameData, vec2(rx, ly), colError, FontSmall)
  let cols = 4
  let bw = (colW - (cols - 1).float32 * 6) / cols.float32
  var levelCells: seq[Rect]
  for i, n in levels:
    let r = rect(rx + (i mod cols).float32 * (bw + 6), ly + (i div cols).float32 * 34, bw, 30)
    let sel = a.newLevel == n
    let hov = ui.hover(r)
    ui.rect(r, if sel: colAccentDim elif hov: colHover else: colPanelRaised)
    ui.textIn("Level " & $n, r, colText, h = CenterAlign)
    if hov and ui.pressed():
      ui.consumeClick()
      a.levelCursor = i
      a.newLevel = n
      a.newName = uniqueName("Level" & $n)
    levelCells.add r
  let rowsH = ((levels.len + cols - 1) div cols).float32 * 34
  # One Tab stop: the arrow keys move through the levels, Space/Enter pick one.
  if levels.len > 0:
    let lr = rect(rx, ly, colW, rowsH - 4)
    let focused = ui.tabStop("welcome.levels", lr)
    discard ui.listNav("welcome.levels", lr, levelCells, a.levelCursor)
    if focused and a.levelCursor in 0 ..< levels.len:
      let c = levelCells[a.levelCursor]
      ui.cursorRing(c)
      if ui.navActivate("welcome.levels"):
        a.newLevel = levels[a.levelCursor]
        a.newName = uniqueName("Level" & $a.newLevel)
  ly += rowsH + 4
  if a.newLevel > 0 and not a.busy and not taken:
    if ui.textButton("welcome.import", rect(rx + colW - 120, ly, 120, 30), "Import", primary = true):
      a.importLevel(a.newLevel, a.newName)
  ui.text("Projects folder: " & a.cfg.projectsDir & "   (File ▸ Settings to change)",
          vec2(lx, area.y + area.h - 30), colTextDisabled, FontSmall)

proc setFov(a: App, degrees: float) =
  for i in 0 .. 3:
    if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = degrees.float32.degToRad

const SettingsPages = ["General", "View", "Mouse"]

proc drawSettings*(a: App) =
  ## File > Settings: paths, plus TrenchBroom's View and Mouse preferences.
  ## The views preview View changes while it is open; Save keeps them, Cancel
  ## (or Esc) puts everything back.
  if not a.settingsOpen: return
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
    discard sliderRow("grid", "Grid opacity", e.gridOpacity, 0, 1, 0.01, pct(e.gridOpacity))
    if sliderRow("fov", "FOV", e.fov, 30, 120, 1, $int(e.fov) & "°"): a.setFov(e.fov)
    note("Vertical field of view of the 3D view. Shift+wheel zooms it; " &
         "Ctrl+Alt+Z goes back to this.")
    ui.textIn("Filter mode", rect(x, y, LabelW, 24), colText)
    if ui.radioButton("settings.linear", vec2(x + LabelW, y + 1), "Linear", e.linearFilter):
      e.linearFilter = true
    if ui.radioButton("settings.nearest", vec2(x + LabelW + 100, y + 1), "Nearest", not e.linearFilter):
      e.linearFilter = false
    y += 32
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
    field("Game launch script (started with ARKLITE_AUTOSTART=<project>)", e.launchScript)

  let by = box.y + box.h - 46
  if a.settingsPage > 0 and
     ui.textButton("settings.reset", rect(box.x + 16, by, 140, 30), "Reset to defaults"):
    # Resets the View and Mouse pages (TrenchBroom resets the pane shown).
    e[].resetViewPrefs()
    a.settingsFly = DefaultFlySpeed
    a.setFov(e.fov)
  let sr = rect(box.x + box.w - 200, by, 88, 30)
  let cr = rect(box.x + box.w - 104, by, 88, 30)
  if ui.textButton("settings.save", sr, "Save", primary = true):
    a.cfg = a.settingsEdit
    a.flySpeed = a.settingsFly
    a.cfg.save()
    a.saveLayout()
    a.settingsOpen = false
    a.say "Settings saved"
  elif ui.textButton("settings.cancel", cr, "Cancel") or
       (ui.focusId.len == 0 and ui.window.buttonPressed[KeyEscape]):
    if a.settingsEdit.fov != a.cfg.fov: a.setFov(a.cfg.fov)
    a.settingsOpen = false
  ui.sk.popLayer()
  ui.captured = true
  # Tab stays in the dialog.
  if a.settingsOpen: discard ui.tabNavigate(firstStop)

proc drawOptions*(a: App) =
  ## View > Options: how the views draw the level. Like Settings, the views
  ## preview the dialog's copy; OK keeps it, Cancel (or Esc) puts it back.
  if not a.optionsOpen: return
  let ui = a.ui
  let e = addr a.settingsEdit
  let firstStop = ui.tabStops.len
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - 460) / 2), floor((ui.size.y - 260) / 2), 460, 260)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Options", vec2(box.x + 16, box.y + 12), colText, FontTitle)
  let x = box.x + 20
  let w = box.w - 40
  var y = box.y + 54
  const LabelW = 110'f32
  ui.groupHeader(vec2(x, y), w, "Wireframe")
  y += 28
  discard ui.checkbox("options.triangles", vec2(x, y), "Show triangles", e.showTriangles)
  ui.tip(rect(x, y, 140, 22), "On: wireframes draw every triangle the faces are split into. " &
    "Off: only the faces' own edges.")
  y += 34
  ui.groupHeader(vec2(x, y), w, "Grid")
  y += 28
  ui.textIn("Grid color", rect(x, y, LabelW, 26), colText)
  const id = "options.gridcolor"
  if ui.focusId != id and not pickerOpen(id): a.fieldText[id] = fmtRgb(e.gridColor)
  let app = a
  let target = ColorTarget(
    live: proc(c: RGB) =
      for i in 0 .. 2: app.settingsEdit.gridColor[i] = clamp(c[i], 0, 255),
    done: proc(changed: bool) = discard)
  let ev = ui.colorField(id, rect(x + LabelW, y, w - LabelW, 26), a.fieldText[id], target)
  if eeCommitted in ev:
    let (ok, c) = parseColor(a.fieldText[id])
    if ok: target.live(c)
    elif a.fieldText[id].strip.len > 0:
      a.say("Not a color: " & a.fieldText[id] & " (use R G B, #RRGGBB or hsv(H, S, V))", true)
  y += 34
  discard ui.checkbox("options.grid3d", vec2(x + LabelW, y), "Also on the 3D faces", e.gridColor3D)
  ui.tip(rect(x + LabelW, y, 170, 22), "Off: the 3D grid is black or white, whichever shows on " &
    "each texture (TrenchBroom's choice).")
  let by = box.y + box.h - 46
  if ui.textButton("options.reset", rect(box.x + 16, by, 140, 30), "Reset to defaults"):
    e.showTriangles = true
    e.gridColor = [255, 255, 255]
    e.gridColor3D = false
  let okr = rect(box.x + box.w - 200, by, 88, 30)
  let cr = rect(box.x + box.w - 104, by, 88, 30)
  if ui.textButton("options.ok", okr, "OK", primary = true):
    a.cfg.showTriangles = e.showTriangles
    a.cfg.gridColor = e.gridColor
    a.cfg.gridColor3D = e.gridColor3D
    try: a.cfg.save()
    except CatchableError as err: a.say("Could not save the options: " & err.msg, true)
    a.optionsOpen = false
  elif ui.textButton("options.cancel", cr, "Cancel") or
       (ui.focusId.len == 0 and not pickerOpen(id) and ui.window.buttonPressed[KeyEscape]):
    a.optionsOpen = false
  ui.sk.popLayer()
  ui.drawColorPicker()
  ui.captured = true
  if a.optionsOpen: discard ui.tabNavigate(firstStop)

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
