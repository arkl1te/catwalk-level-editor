## Everything around the map views, laid out like TrenchBroom: menu bar,
## toolbar, tool options strip, the inspector (Map / Entity / Face tabs with the
## entity and texture browsers), the Console / Issues panel, the status bar, the
## welcome screen and the settings dialog.

import std/[os, osproc, strutils, strformat, math, tables, sets, algorithm, times, sequtils, xmltree]
import silky, vmath, bumpy, pixie
import theme, ui, dialogs, icons, music, sky, menutree
import levelobjects, project, jobs, camera, render, geometry, geomops, objtemplates, appstate, viewtools,
  presets, library, thumbs, fieldchoices

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
  var x = r.x + 6
  for t in T:
    let label = $t
    let w = ui.textSize(label).x + 20
    let tr = rect(x, r.y, w, r.h)
    let sel = value == t
    if ui.hover(tr) and ui.pressed():
      value = t
      ui.consumeClick()
    ui.textIn(label, tr, if sel: colText else: colTextDim, h = CenterAlign)
    if sel: ui.rect(rect(tr.x + 4, tr.y + tr.h - 2, tr.w - 8, 2), colAccent)
    x += w
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)

proc dropdown(a: App, id: string, r: Rect, label: string, items: seq[string]): int =
  ## A button that opens a list; returns the picked index (or -1).
  result = -1
  let ui = a.ui
  let open = a.openDropdown == id
  let hov = ui.hover(r)
  ui.rect(r, if open: colPressed elif hov: colHover else: colPanel)
  ui.border(r, colBorder)
  ui.textIn(ui.ellipsize(label, r.w - 28), rect(r.x + 8, r.y, r.w - 28, r.h), colText)
  ui.icon("expand16", vec2(r.x + r.w - 12, r.y + r.h / 2), colTextDim)
  if hov and ui.pressed():
    a.openDropdown = if open: "" else: id
    ui.consumeClick()
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
    if ui.mouse.inside(ir): ui.rect(ir, colHover)
    ui.textIn(it, rect(ir.x + 8, ir.y, ir.w - 8, ir.h), colText)
    if ui.mouse.inside(ir) and ui.window.buttonPressed[MouseLeft]:
      result = i
  ui.sk.popLayer()
  if ui.window.buttonPressed[MouseLeft]:
    a.openDropdown = ""
    ui.consumeClick()
  ui.captured = true

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
    let o = LevelObject(tag: a.clipboard[i])
    o.node = newElement(a.clipboard[i])
    o.restore(a.clipboard[i + 1])
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
    for p in g.pieces: a.geo.pieces.add p
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
  for o in a.objects: o.selected = a.pickable(o)
  if a.geometryEditable:
    for f in a.geo.faces:
      if f.objectId == -1 and not a.geo.pieces[f.piece].hidden: a.selPieces.incl f.piece

proc invertSelection(a: App) =
  for o in a.objects:
    if a.pickable(o): o.selected = not o.selected
  if a.geometryEditable:
    var all: HashSet[int32]
    for f in a.geo.faces:
      if f.objectId == -1: all.incl f.piece
    a.selPieces = all.difference(a.selPieces)

proc hideSelection(a: App) =
  for o in a.selection:
    o.hidden = true
    o.selected = false
  if a.geo != nil:
    for pc in a.selPieces: a.geo.pieces[pc].hidden = true
    a.selPieces.clear()
    a.geo.bump()

proc isolateSelection(a: App) =
  for o in a.objects: o.hidden = not o.selected
  if a.geo != nil:
    for pc in 0 ..< a.geo.pieces.len: a.geo.pieces[pc].hidden = pc.int32 notin a.selPieces
    a.geo.bump()

proc showAll(a: App) =
  for o in a.objects: o.hidden = false
  a.layerHidden.clear()
  if a.geo != nil:
    for p in a.geo.pieces.mitems: p.hidden = false
    a.geo.bump()

proc openSettings(a: App) =
  a.settingsEdit = a.cfg
  a.settingsOpen = true

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
    item("Duplicate", "Ctrl+D", hasSel, action = proc() = a.duplicateSelection(vec3(0, 0, 0))),
    item("Delete", "Del", hasSel, action = proc() = a.deleteSelection()),
    item("Move objects...", "Ctrl+Alt+M", hasSel, action = proc() =
      a.tool = toolSelect
      a.ui.focusId = "opt.moveby"
      a.ui.focusFresh = true),
    sep(),
    item("Flip horizontally", "Ctrl+F", hasSel, action = proc() =
      a.flipSelection(if abs(a.viewAxes.right.x) > 0.5: 0 elif abs(a.viewAxes.right.y) > 0.5: 1 else: 2)),
    item("Flip vertically", "Ctrl+Alt+F", hasSel, action = proc() =
      a.flipSelection(if abs(a.viewAxes.up.x) > 0.5: 0 elif abs(a.viewAxes.up.y) > 0.5: 1 else: 2)),
    sep(),
    item("CSG: Convex merge", "Ctrl+J", geo and a.selPieces.len > 0, action = proc() = a.csg("merge")),
    item("CSG: Subtract", "Ctrl+K", geo and a.selPieces.len > 0, action = proc() = a.csg("subtract")),
    item("CSG: Hollow", "Ctrl+Shift+K", geo and a.selPieces.len > 0, action = proc() = a.csg("hollow")),
    item("CSG: Intersect", "Ctrl+L", geo and a.selPieces.len > 1, action = proc() = a.csg("intersect")),
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
  result.add ("Tools", @[
    item("No tool (select, move, draw)", "W", true, a.tool == toolSelect, action = proc() =
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
    item(&"Grid {GridSizes[i]:g}", $(i + 1), true, a.gridIndex == i, action = proc() = a.gridIndex = i)
  var gridSizes: seq[MenuItem]
  for i in 0 .. GridSizes.high: gridSizes.add gridSize(i)
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
    subMenu("Render", @[
      item("Textures", "", true, a.opts.textured, action = proc() = a.opts.textured = not a.opts.textured),
      item("Wireframe 3D", "", true, a.opts.wireframe, action = proc() = a.opts.wireframe = not a.opts.wireframe),
      item("Fullbright", "", true, a.rend.fullbright, action = proc() = a.rend.fullbright = not a.rend.fullbright),
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
          if a.views[i].cam.kind == vk3D: a.views[i].cam.fovY = 70'f32.degToRad)]),
    sep(),
    item("Isolate selection", "Ctrl+I", hasSel, action = proc() = a.isolateSelection()),
    item("Hide selection", "Ctrl+Alt+I", hasSel, action = proc() = a.hideSelection()),
    item("Show all", "Ctrl+Shift+I", hasProj, action = proc() = a.showAll()),
    sep(),
    item("Map inspector", "Ctrl+1", true, a.inspector == itMap and a.showInspector, action = proc() =
      a.inspector = itMap
      a.showInspector = true),
    item("Entity inspector", "Ctrl+2", true, a.inspector == itEntity and a.showInspector, action = proc() =
      a.inspector = itEntity
      a.showInspector = true),
    item("Face inspector", "Ctrl+3", true, a.inspector == itFace and a.showInspector, action = proc() =
      a.inspector = itFace
      a.showInspector = true),
    item("Info panel", "Ctrl+4", true, a.showBottom, action = proc() = a.showBottom = not a.showBottom),
    item("Inspector", "Ctrl+5", true, a.showInspector, action = proc() = a.showInspector = not a.showInspector)])
  result.add ("Run", @[
    item("Play", "F5", hasProj and not a.busy, action = proc() = a.build(play = true)),
    item("Build", "F7", hasProj and not a.busy, action = proc() = a.build(play = false)),
    sep(),
    item("Check for issues", "", hasProj, action = proc() =
      a.findIssues()
      a.bottom = btIssues
      a.showBottom = true),
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

proc contextTree(a: App): MenuNode =
  ## Right click in a view (TrenchBroom's map view menu, for Oni's objects).
  result = newMenuRoot()
  let c = a.ctx
  let create = result.sub("Create object", a.proj != nil)
  # Object types, placed where the menu was opened. A proc per item, as
  # closures made in a loop would all share the last tag.
  proc createItem(tag: string) =
    let col = LevelObject(tag: tag).look.col
    create.item(typeName(tag), swatch = rgbx(col[0], col[1], col[2], 255), action = proc() =
      discard a.addObject(tag, a.snapV(c.point))
      a.say "Placed a new " & typeName(tag))
  var tags = toSeq(Templates.keys)
  tags.sort(proc(x, y: string): int = cmp(typeName(x), typeName(y)))
  for t in tags: createItem(t)
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
      a.inspector = itFace
      a.showInspector = true)
  result.sep()
  let hasSel = a.hasSelection
  result.item("Duplicate", enabled = hasSel, action = proc() = a.duplicateSelection(vec3(0, 0, 0)))
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
        let at = if p.startSavePoint > 0: &" at save point {p.startSavePoint}" else: ""
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

proc pollJob*(a: App) =
  if a.job == nil: return
  a.job.poll()
  case a.job.state
  of jsRunning: discard
  of jsDone:
    let done = a.jobDone
    a.job = nil
    a.jobDone = nil
    if done != nil: done()
  of jsFailed:
    a.say(a.job.error, true)
    for l in a.job.logTail(8).splitLines: a.say("  " & l, true)
    a.showBottom = true
    a.bottom = btConsole
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
    ui.iconButton(id, r, icon & "20", tip, enabled and hasProj, toggled)
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
    a.duplicateSelection(vec3(0, 0, 0))
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
  let gi = a.dropdown("tb.grid", rect(x, y, 104, 28), &"Grid {a.grid:g}", gridItems)
  if gi >= 0: a.gridIndex = gi
  x += 112

  # Start point, Build and Play on the right.
  let playR = rect(ui.size.x - 104, y, 96, 28)
  let buildR = rect(playR.x - 88, y, 82, 28)
  let startR = rect(buildR.x - 184, y, 176, 28)
  let can = hasProj and not a.busy
  if hasProj:
    var labels = @["Start: beginning"]
    for n in a.savePointList: labels.add &"Start: save point {n}"
    let cur = if a.proj.startSavePoint == 0: labels[0] else: &"Start: save point {a.proj.startSavePoint}"
    let pick = a.dropdown("tb.start", startR, cur, labels)
    if pick == 0: a.proj.startSavePoint = 0
    elif pick > 0: a.proj.startSavePoint = a.savePointList[pick - 1]
    ui.tip(startR, "Where Play starts the level. Save points use your saved game from the original level.")
  if can:
    if ui.textButton("tb.build", buildR, "Build"): a.build(play = false)
    if ui.textButton("tb.play", playR, "", primary = true): a.build(play = true)
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
  # View options, right-aligned.
  let vr = rect(r.x + r.w - 134, y, 126, 24)
  let toggles = [("Textures", a.opts.textured), ("Wireframe 3D", a.opts.wireframe),
                 ("Fullbright", a.rend.fullbright), ("Invisible and marker faces", a.opts.markers),
                 ("AI rooms", a.opts.rooms), ("Entity models", a.opts.models),
                 ("Object names in 2D", a.showObjectNames), ("Grid", a.showGrid), ("Sky", a.opts.sky)]
  var items: seq[string]
  for (n, on) in toggles: items.add (if on: "● " else: "◌ ") & n
  case a.dropdown("opt.view", vr, "View options", items)
  of 0: a.opts.textured = not a.opts.textured
  of 1: a.opts.wireframe = not a.opts.wireframe
  of 2: a.rend.fullbright = not a.rend.fullbright
  of 3:
    a.opts.markers = not a.opts.markers
    if a.geo != nil: a.geo.bump()
  of 4: a.opts.rooms = not a.opts.rooms
  of 5: a.opts.models = not a.opts.models
  of 6: a.showObjectNames = not a.showObjectNames
  of 7: a.showGrid = not a.showGrid
  of 8: a.opts.sky = not a.opts.sky
  else: discard
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
    label "Click faces to place points, double-click a face for its corners, drag on a face for a rectangle, Shift+drag to stretch the shape."
    if button("opt.asmcreate", "Create (Enter)"): a.createAssembled()
    if button("opt.asmclear", "Clear (Esc)"): a.assemblePoints.setLen 0
  of toolVertex, toolEdge, toolFace:
    label &"{a.tool} tool: {a.selHandles.len} handle(s) selected."
    label "Click or drag handles; drag empty space to lasso (Ctrl toggles); Delete removes corners from brushes."
  of toolClip:
    label "Click 2 points in a 2D view (or 3 on faces in 3D), or drag; double-click a face to clip along it."
    for (s, side) in [("Keep front", sideFront), ("Keep back", sideBack), ("Keep both", sideBoth)]:
      if ui.radioButton("opt.clip." & s, vec2(x, y + 1), s, a.clipSide == side): a.clipSide = side
      x += ui.textSize(s).x + 34
    if button("opt.clipapply", "Apply (Enter)"): a.applyClip()
    if button("opt.clipreset", "Reset"): a.clipPoints.setLen 0
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

proc pieceInfo(a: App): seq[PieceInfo] =
  if a.geo == nil: return
  if pieceInfoCache.geo == a.geo and pieceInfoCache.version == a.geo.version: return pieceInfoCache.info
  result = newSeq[PieceInfo](a.geo.pieces.len)
  for f in a.geo.faces:
    if f.piece < 0 or f.piece >= result.len: continue
    inc result[f.piece].faces
    if result[f.piece].texture.len == 0 and not f.isMarkerFace: result[f.piece].texture = f.texture
    if f.objectId == -1: result[f.piece].world = true
  pieceInfoCache = (a.geo.version, a.geo, result)

type TreeRow = object
  layer: string          ## Layer key (GEOM or an object tag).
  depth: int             ## 0 layer, 1 member.
  obj: LevelObject
  piece: int32


proc previewMusic(a: App) =
  ## Plays the project's track; extracts level 0's music first if needed.
  let p = a.proj
  proc play() =
    if p != a.proj or p.music.len == 0: return
    try: playMusic(p.music, p.musicVolume)
    except CatchableError as e: a.say(e.msg, true)
  if hasMusicCache():
    play()
  elif a.busy:
    a.say("Wait for the current job to finish, then preview the music again", true)
  else:
    try: a.startJob(musicCacheJob(a.cfg, musicDir().parentDir / "music.log"), play)
    except CatchableError as e: a.say(e.msg, true)

proc musicRow(a: App, x: float32, y: var float32, w: float32) =
  ## Music started when the level loads, and its volume.
  let ui = a.ui
  ui.text("Music", vec2(x, y + 5), colTextDim, FontSmall)
  var items = @["None"]
  for t in MusicTracks: items.add t
  let dw = min(200'f32, w - 50 - 30)
  let mi = a.dropdown("map.music", rect(x + 50, y, dw, 26),
                      if a.proj.music.len > 0: a.proj.music else: "None", items)
  if mi >= 0:
    a.proj.music = if mi == 0: "" else: MusicTracks[mi - 1]
    a.proj.save()
    # A preview follows the pick.
    if musicPlaying():
      if a.proj.music.len > 0: a.previewMusic() else: stopMusic()
  let playing = musicPlaying()
  if ui.iconButton("map.musicplay", rect(x + 50 + dw + 4, y, 26, 26),
                   if playing: "stop16" else: "play16",
                   if playing: "Stop the preview" else: "Listen to this track",
                   a.proj.music.len > 0 or playing):
    if playing: stopMusic() else: a.previewMusic()
  y += 34
  if a.proj.music.len > 0:
    ui.text("Volume", vec2(x, y + 5), colTextDim, FontSmall)
    var v = a.proj.musicVolume
    if ui.slider("map.musicvol", rect(x + 60, y + 4, dw - 50, 18), v, 0, 1, 0.05):
      a.proj.musicVolume = v
      a.proj.save()
      setMusicVolume(v)
    ui.text(&"{int(round(a.proj.musicVolume * 100))}%", vec2(x + 60 + dw - 50 + 10, y + 5),
            colTextDim, FontSmall)
    y += 34

proc drawMapTab(a: App, r: Rect) =
  let ui = a.ui
  var y = r.y
  ui.sectionTitle(rect(r.x, y, r.w, 26), "Layers")
  y += 26
  if a.layersH <= 0: a.layersH = max(160, r.h * 0.55)
  a.layersH = clamp(a.layersH, 60, max(60, r.h - 200))
  let list = rect(r.x, y, r.w, a.layersH)
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
  if ui.hover(list) and not ui.scrollConsumed:
    a.layersScroll += ui.wheelNotches * rowH * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  a.layersScroll = clamp(a.layersScroll, 0, max(0, rows.len.float32 * rowH - list.h))
  ui.pushClip(list)
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
      let eyeR = rect(rr.x + 20, rr.y + 1, 20, 20)
      let lockR = rect(rr.x + 40, rr.y + 1, 20, 20)
      if ui.iconButton("layer.eye." & key, eyeR, (if hidden: "eyeoff16" else: "eye16"),
                       if hidden: "Show layer" else: "Hide layer"):
        if hidden: a.layerHidden.excl key else: a.layerHidden.incl key
        if key == GeometryLayer and a.geo != nil: a.geo.bump()
      if ui.iconButton("layer.lock." & key, lockR, (if locked: "lock16" else: "unlock16"),
                       if locked: "Unlock layer" else: "Lock layer", toggled = locked):
        if locked: a.layerLocked.excl key else: a.layerLocked.incl key
      let nx = rr.x + 66
      ui.textIn(name, rect(nx, rr.y, rr.w - 70, rowH), if hidden: colTextDisabled else: colText)
      let tw = ui.textSize(name).x
      ui.textIn(&"{n} {unit}", rect(nx + tw + 8, rr.y, rr.w, rowH), colTextDim, FontSmall)
      let hit = rect(rr.x, rr.y, 20, rowH)
      let body = rect(rr.x + 62, rr.y, rr.w - 62, rowH)
      if ui.hover(hit) and ui.pressed():
        ui.consumeClick()
        if open: a.expanded.excl key else: a.expanded.incl key
      elif ui.hover(body) and ui.pressed():
        ui.consumeClick()
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
    let eyeR = rect(rr.x + 26, rr.y + 1, 20, 20)
    let id = if row.obj != nil: "obj." & $cast[int](row.obj) else: "pc." & $row.piece
    if ui.iconButton("tree.eye." & id, eyeR, (if hiddenM: "eyeoff16" else: "eye16"),
                     if hiddenM: "Show" else: "Hide"):
      if row.obj != nil:
        row.obj.hidden = not row.obj.hidden
        if row.obj.hidden: row.obj.selected = false
      else:
        a.geo.pieces[row.piece].hidden = not hiddenM
        if not hiddenM: a.selPieces.excl row.piece
        a.geo.bump()
    var name, detail: string
    if row.obj != nil:
      name = row.obj.label
      detail = "#" & $row.obj.id
    else:
      let pi = info[row.piece]
      name = "Piece " & $row.piece & (if a.geo.pieces[row.piece].brush: " (brush)" else: "")
      detail = &"{pi.faces} faces" & (if pi.texture.len > 0: " · " & pi.texture else: "")
    let nx = rr.x + 50
    let nameW = min(ui.textSize(name, FontSmall).x, rr.w - 60)
    ui.textIn(ui.ellipsize(name, rr.w - 60, FontSmall), rect(nx, rr.y, rr.w - 60, rowH),
              if hiddenM: colTextDisabled else: colText, FontSmall)
    ui.textIn(ui.ellipsize(detail, max(0, rr.w - nameW - 70), FontSmall),
              rect(nx + nameW + 8, rr.y, rr.w, rowH), colTextDim, FontSmall)
    let body = rect(rr.x + 48, rr.y, rr.w - 48, rowH)
    if ui.hover(body) and ui.pressed() and ui.mouse.inside(list):
      ui.consumeClick()
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
  ui.popClip()
  y += a.layersH
  let (dragging, my) = a.divider("map.layers", rect(r.x, y, r.w, 6), false)
  if dragging: a.layersH = my - list.y - 3
  y += 8
  if a.proj == nil: return
  ui.sectionTitle(rect(r.x, y, r.w, 26), "Level")
  y += 34
  let x = r.x + 10
  let w = r.w - 20
  ui.text("Name in Oni's Custom Game list", vec2(x, y), colTextDim, FontSmall)
  y += 18
  var title = a.proj.title
  let ev = ui.textField("map.title", rect(x, y, w, 26), title)
  if eeChanged in ev or eeCommitted in ev:
    a.proj.title = title
    a.proj.save()
    a.updateWindowTitle()
  y += 34
  if a.proj.scratch:
    ui.text("Sky", vec2(x, y + 5), colTextDim, FontSmall)
    var skyItems = @["None"]
    for s in Skies: skyItems.add s
    let si = a.dropdown("map.sky", rect(x + 40, y, min(200'f32, w - 40), 26),
                        if a.proj.sky.len > 0: a.proj.sky else: "None", skyItems)
    if si >= 0:
      a.proj.sky = if si == 0: "" else: Skies[si - 1]
      a.proj.save()
    y += 34
  a.musicRow(x, y, w)
  if a.proj.scratch:
    ui.text(&"Made in Catwalk · environment {a.proj.envName}", vec2(x, y), colTextDim, FontSmall)
  else:
    ui.text(&"Built from level {a.proj.levelNumber} ({a.proj.source}) · environment {a.proj.envName}" &
            (if a.proj.sky.len > 0: &" · sky {a.proj.sky}" else: ""), vec2(x, y), colTextDim, FontSmall)
  y += 20
  ui.text("Project folder: " & a.proj.dir, vec2(x, y), colTextDim, FontSmall)
  y += 20
  ui.text("Builds to: " & a.cfg.customLevels / a.proj.folder, vec2(x, y), colTextDim, FontSmall)

# --- inspector: entity ---------------------------------------------------------------------

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

# --- field dropdowns ---------------------------------------------------------------------
# A focused Entity tab field lists what the game accepts there (fieldchoices.nim):
# DropRows at a time, the rest behind a scroll. Typing filters the list; a click,
# or Up/Down then Enter, picks a value.

const
  DropRows = 12
  DropRowH = 22'f32

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

proc dropField(a: App, id: string, r: Rect, left: float32, text: var string,
               o: LevelObject, fld: ObjectField, pick: proc(v: string)) =
  ## Call before the field's textField: shows the list of o's field while the
  ## field is focused and handles its keys (Enter takes the highlighted row).
  let ui = a.ui
  if ui.focusId != id: return
  if a.drop.id != id: a.openDrop(id, a.fieldChoices(o, fld), text)
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

proc drawFieldDrop(a: App) =
  ## Draws the list a field asked for this frame, over everything else.
  let ui = a.ui
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
  var picked = -1
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
    let rr = rect(box.x + 3, box.y + 3 + row.float32 * DropRowH, listW, DropRowH)
    if c.hint:
      ui.textIn(ui.ellipsize(c.value, rr.w - 12, FontSmall), rect(rr.x + 6, rr.y, rr.w - 12, rr.h),
                colTextDim, FontSmall)
      continue
    let over = ui.popupHit and ui.mouse.inside(rr) and ui.activeId != "fielddrop.bar"
    if k == a.drop.hi: ui.rect(rr, colAccentDim)
    elif over: ui.rect(rr, colHover)
    let noteW = if c.note.len > 0: min(rr.w * 0.5, ui.textSize(c.note, FontSmall).x) + 14 else: 0'f32
    if c.value.len == 0:
      ui.textIn("(empty)", rect(rr.x + 6, rr.y, rr.w - 12 - noteW, rr.h), colTextDisabled)
    else:
      ui.textIn(ui.ellipsize(c.value, rr.w - 12 - noteW), rect(rr.x + 6, rr.y, rr.w - 12 - noteW, rr.h), colText)
    if c.note.len > 0:
      ui.textIn(ui.ellipsize(c.note, noteW - 14, FontSmall), rect(rr.x + rr.w - noteW, rr.y, noteW - 6, rr.h),
                colTextDim, FontSmall, h = RightAlign)
    if over and ui.window.buttonPressed[MouseLeft]: picked = k
  if bar:
    let ty = track.y + (track.h - thumbH) * a.drop.scroll.float32 / (n - DropRows).float32
    ui.rect(track, colTrack)
    ui.rect(rect(track.x, ty, track.w, thumbH),
            if ui.activeId == "fielddrop.bar": colAccent else: colTextDisabled)
  ui.sk.popLayer()
  if ui.popupHit and ui.window.buttonPressed[MouseLeft]: ui.consumeClick()
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
  ui.text(typeName(sel[0].tag), vec2(x, y), colAccent, FontSmall)
  y += 18
  ui.textIn(&"{sel.len} objects selected", rect(x, y, w, 22), colText)
  y += 28
  ui.rect(rect(x, y, w, 1), colBorder)
  y += 10
  # Fields every object has, in the first one's order, with each object's value.
  var values: Table[string, seq[string]]
  for o in sel:
    for fld in o.fields: values.mgetOrPut(fld.path & "@" & fld.attr, @[]).add fld.value
  for fld in sel[0].fields:
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
    let kw = w * 0.42
    let row = rect(x, y, w, 26)
    if row.y + row.h > props.y and row.y < props.y + props.h:
      ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
      let fr = rect(x + kw, y, w - kw, 26)
      let joined = uniq.join(";")
      if mixed: ui.tip(fr, joined)
      a.dropField(id, fr, x, a.fieldText[key], sel[0], fld, a.pickAll(sel, fld))
      let ev = ui.textField(id, fr, a.fieldText[key], if mixed: joined else: "")
      # A mixed field left blank keeps each object's own value.
      if eeCommitted in ev and not (mixed and a.fieldText[key].len == 0):
        a.commitFieldAll(sel, fld, a.fieldText[key])
    y += 30
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

proc drawEntityTab(a: App, r: Rect) =
  let ui = a.ui
  a.drop.live = false
  if a.entityBrowserH <= 0: a.entityBrowserH = 210
  a.entityBrowserH = clamp(a.entityBrowserH, 90, max(90, r.h - 120))
  let browserH = a.entityBrowserH
  let props = rect(r.x, r.y, r.w, r.h - browserH - 6)
  let sel = a.selection
  ui.pushClip(props)
  if sel.len == 0:
    ui.textIn("No object selected", props, colTextDim, h = CenterAlign)
    a.fieldObj = nil
    a.fieldSel = @[]
  elif sel.len > 1 and (block:
      var same = true
      for o in sel:
        if o.tag != sel[0].tag: same = false
      same):
    a.fieldObj = nil
    a.drawMultiFields(sel, props)
  elif sel.len > 1:
    a.fieldSel = @[]
    var counts: CountTable[string]
    for o in sel: counts.inc typeName(o.tag)
    var y = props.y + 12
    ui.text(&"{sel.len} objects selected", vec2(props.x + 12, y), colText)
    y += 26
    for k, v in counts:
      ui.text(&"{v} × {k}", vec2(props.x + 20, y), colTextDim, FontSmall)
      y += 20
    a.fieldObj = nil
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
    ui.text(typeName(o.tag), vec2(x, y), colAccent, FontSmall)
    y += 18
    ui.textIn(ui.ellipsize(o.label & "   #" & $o.id, w), rect(x, y, w, 22), colText)
    y += 28
    if a.hasGeometry(o):
      ui.text("Owns level geometry (moves with it)", vec2(x, y), colTextDim, FontSmall)
      y += 20
    proc vecRow(title: string, v: var Vec3, step: float, isRot: bool): bool =
      ui.text(title, vec2(x, y), colTextDim, FontSmall)
      y += 18
      let cw = (w - 8) / 3
      for i in 0 .. 2:
        var f = v[i].float
        let rr = rect(x + i.float32 * (cw + 4), y, cw, 26)
        if ui.numberField(&"prop.{title}.{i}.{o.id}", rr, f, step, -100000, 100000, (if isRot: 1 else: 2), axis = i):
          v[i] = f.float32
          result = true
      y += 34
    var p = o.pos
    var rr = o.rot
    let objBefore = @[o.snapshot]
    let linked = a.hasGeometry(o)
    let geoBefore = if linked: a.geo.clone else: nil
    let posChanged = vecRow("Position (X Y Z)", p, a.grid.float, false)
    let rotChanged = vecRow("Rotation (degrees)", rr, 15, true)
    if posChanged or rotChanged:
      a.setPose(o, p, rr)
      a.push editCmd(if posChanged: "Move" else: "Rotate", @[o], objBefore, geoBefore, a.geo)
    ui.rect(rect(x, y, w, 1), colBorder)
    y += 10
    # Key / value table.
    for fld in o.fields:
      let key = fld.path & "@" & fld.attr
      let name = (if fld.path.startsWith("OSD/"): fld.path[4 .. ^1] else: fld.path) &
                 (if fld.attr.len > 0: " ." & fld.attr else: "")
      let kw = w * 0.42
      if key notin a.fieldText or ui.focusId != "prop." & key: a.fieldText[key] = fld.value
      let row = rect(x, y, w, 26)
      if row.y + row.h > props.y and row.y < props.y + props.h:
        ui.textIn(ui.ellipsize(name, kw - 6, FontSmall), rect(x, y, kw, 26), colTextDim, FontSmall)
        let fr = rect(x + kw, y, w - kw, 26)
        a.dropField("prop." & key, fr, x, a.fieldText[key], o, fld, a.pickOne(o, fld))
        let ev = ui.textField("prop." & key, fr, a.fieldText[key])
        if eeCommitted in ev: a.commitField(o, fld, a.fieldText[key])
      y += 30
    # After the fields, so a wheel over a number field steps it instead.
    # Measured before the wheel moves propsScroll (y was laid out with the old one).
    let contentH = y + a.propsScroll - props.y
    if ui.hover(props) and not ui.scrollConsumed:
      a.propsScroll += ui.wheelNotches * RowH * 3
    a.propsScroll = clamp(a.propsScroll, 0, max(0, contentH - props.h + 20))
  ui.popClip()

  # Entity browser: presets in collapsible groups.
  let (dragging, my) = a.divider("entity.browser", rect(r.x, r.y + r.h - browserH - 6, r.w, 6), false)
  if dragging: a.entityBrowserH = r.y + r.h - my - 3
  let br = rect(r.x, r.y + r.h - browserH, r.w, browserH)
  let tiles = a.entityPreview > 0
  if tiles and not a.busy and hasPreviews() and not a.presetsCurrent: a.loadPresets()
  let rendering = tiles and not hasPreviews() and (a.busy or libraryBusyElsewhere())
  ui.sectionTitle(rect(br.x, br.y, br.w, 26),
    if rendering: "Entity browser · rendering model previews..."
    else: "Entity browser · drag into a view, or click to place")
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
  for g in groups:
    contentH += HeadH + 2
    if g in a.browserOpen or filter.len > 0:
      contentH += ((members[g].len + cols - 1) div cols).float32 * cellH + 4
  contentH += 40
  if ui.hover(list) and not ui.scrollConsumed:
    a.entityScroll += ui.wheelNotches * 26 * 3
    if ui.wheelNotches != 0: ui.scrollConsumed = true
  a.entityScroll = clamp(a.entityScroll, 0, max(0, contentH - list.h))
  ui.pushClip(list)
  let inList = ui.mouse.inside(list)
  var wanted: seq[Preset]   # Visible previews not loaded yet.
  var y = list.y + 2 - a.entityScroll
  for g in groups:
    let open = g in a.browserOpen or filter.len > 0
    let hr = rect(list.x + 4, y, list.w - 8, HeadH)
    if hr.y + hr.h > list.y and hr.y < list.y + list.h:
      let hov = ui.hover(hr) and inList
      ui.rect(hr, if hov: colHover else: colPanelRaised)
      ui.icon(if open: "expand16" else: "arrow16", vec2(hr.x + 10, hr.y + HeadH / 2), colTextDim)
      ui.textIn(g, rect(hr.x + 22, hr.y, hr.w - 22, HeadH), colText, FontSmall)
      let tw = ui.textSize(g, FontSmall).x
      ui.textIn($members[g].len, rect(hr.x + 30 + tw, hr.y, hr.w, HeadH), colTextDim, FontSmall)
      if hov and ui.pressed() and filter.len == 0:
        ui.consumeClick()
        if open: a.browserOpen.excl g else: a.browserOpen.incl g
    y += HeadH + 2
    if not open: continue
    let ids = members[g]
    for k, i in ids:
      let p = a.presets[i]
      let cell = rect(list.x + 4 + (k mod cols).float32 * (cw + 4), y + (k div cols).float32 * cellH, cw, cellH - 2)
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
  # Furniture, consoles, doors and triggers come from the game files.
  let lb = rect(list.x + 8, y + 6, list.w - 16, 26)
  if lb.y < list.y + list.h:
    let label = if not hasLibrary(): "Build furniture, consoles, doors and triggers"
                elif not hasPreviews(): "Rebuild the entity library for model previews"
                else: "Rebuild the entity library"
    if ui.textButton("entity.library", lb, label, primary = not hasLibrary()) and not a.busy:
      a.buildLibrary()
    ui.tip(lb, "Takes them, with their geometry and textures, from the game's levels (about 30 s)")
  ui.popClip()
  # After drawing: the atlas can't change while this frame's quads point into it.
  if wanted.len > 0: a.loadPreviews(wanted)
  a.drawFieldDrop()

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
  if merge: a.undoStack[^1].geoAfter = a.geo.clone
  else: a.push geoCmd(label, before, a.geo)
  a.faceUndo = (label, a.geo, a.geo.version, a.undoStack.len, key)

proc drawFaceTab(a: App, r: Rect) =
  let ui = a.ui
  if a.faceBrowserH <= 0: a.faceBrowserH = max(260'f32, r.h * 0.45)
  a.faceBrowserH = clamp(a.faceBrowserH, 120, max(120, r.h - 120))
  let browserH = a.faceBrowserH
  let top = rect(r.x, r.y, r.w, r.h - browserH - 6)
  let faces = a.selectedFaceSet
  ui.pushClip(top)
  var y = top.y + 8 - a.faceScroll
  let x = top.x + 10
  let w = top.w - 20
  if a.geo == nil:
    ui.textIn("This project has no editable geometry", top, colTextDim, h = CenterAlign)
  elif faces.len == 0:
    ui.textIn("Select faces (Shift+click) or pieces", top, colTextDim, h = CenterAlign)
  else:
    # Shows the face clicked last, or else any selected one.
    var first = a.lastFace
    if first notin faces:
      for fi in faces:
        first = fi
        break
    let f0 = a.geo.faces[first]
    ui.text(&"{faces.len} face(s) · texture {f0.texture}", vec2(x, y), colText)
    y += 26
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
    let cw = (w - 8) / 3
    # One row per pair: Shift U/V, Scale U/V, then Rotation.
    let pw = (w - 4) / 2
    for i in 0 .. 4:
      let cx = x + (i mod 2).float32 * (pw + 4)
      if i == 2 or i == 4: y += 46
      let cy = y
      ui.text(names[i], vec2(cx, cy), colTextDim, FontSmall)
      let fr = rect(cx, cy + 16, pw, 26)
      ui.tip(fr, tips[i])
      var v = case i
        of 0, 1: shown.shift[i]
        of 2, 3: shown.scale[i - 2]
        else: shown.rot
      let (step, decimals) = if i < 2: (0.0625, 4) elif i < 4: (0.25, 4) else: (15.0, 2)
      if ui.numberField("face.uv." & $i, fr, v, step, -1000, 1000, decimals,
                        axis = (if i < 4: i mod 2 else: -1), live = true):
        if i in 2 .. 3 and abs(v) < 1e-4: continue  # No zero scale.
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
    y += 50
    var bx = x
    proc fbtn(id, s: string): bool =
      let bw = ui.textSize(s).x + 20
      result = ui.textButton(id, rect(bx, y, bw, 26), s)
      bx += bw + 6
    if fbtn("face.flipu", "Flip U"):
      let app = a
      a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(-1, 1), 0))
    if fbtn("face.flipv", "Flip V"):
      let app = a
      a.applyToFaces("Flip texture", proc(fi: int) = app.geo.transformUVs(fi, vec2(0, 0), vec2(1, -1), 0))
    if fbtn("face.align", "World align"):
      let app = a
      a.applyToFaces("Align texture", proc(fi: int) =
        app.geo.projectUVs(fi, app.density(app.geo.faces[fi].texture)))
    y += 36
    ui.text("Arrows move textures, PgUp/PgDn rotate (Shift coarse, Ctrl fine)", vec2(x, y), colTextDim, FontSmall)
    y += 26
    # Flags.
    ui.rect(rect(x, y, w, 1), colBorder)
    y += 8
    ui.text("Surface flags", vec2(x, y), colTextDim, FontSmall)
    y += 20
    let half = (w - 8) / 2
    for i, (name, bit, desc) in EditableFlags:
      var all = true
      for fi in faces:
        if (a.geo.faces[fi].flags and bit) == 0:
          all = false
          break
      var v = all
      let cx = x + (i mod 2).float32 * (half + 8)
      ui.tip(rect(cx, y, 22 + ui.textSize(name).x, 22), desc)
      if ui.checkbox("face.flag." & name, vec2(cx, y), name, v):
        let app = a
        let on = v
        a.applyToFaces(name, proc(fi: int) =
          if on: app.geo.faces[fi].flags = app.geo.faces[fi].flags or bit
          else: app.geo.faces[fi].flags = app.geo.faces[fi].flags and not bit)
      if i mod 2 == 1: y += 24
    y += 30
    # Script id and shade.
    ui.text("Script id (env_show and friends; 0 = none)", vec2(x, y), colTextDim, FontSmall)
    y += 18
    var sid = f0.scriptId.float
    if ui.numberField("face.script", rect(x, y, 120, 26), sid, 1, int32.low.float, int32.high.float,
                      live = true):
      let app = a
      let n = int32(sid)
      a.faceEdit("Script id", proc(fi: int) = app.geo.faces[fi].scriptId = n)
    y += 36
    ui.text("Shade (baked light color, 0–255)", vec2(x, y), colTextDim, FontSmall)
    y += 18
    let shadeNames = ["Shade red", "Shade green", "Shade blue"]
    for i in 0 .. 2:
      if f0.colors.len > 0: a.shade[i] = f0.colors[0][i].float
      if ui.numberField("face.shade." & $i, rect(x + i.float32 * (cw + 4), y, cw, 26), a.shade[i],
                        8, 0, 255, axis = i, live = true):
        let app = a
        let (c, ch) = (uint8(round(a.shade[i])), i)
        a.faceEdit(shadeNames[i], proc(fi: int) =
          for col in app.geo.faces[fi].colors.mitems: col[ch] = c)
    y += 40
    # After the fields, so a wheel over a number field steps it instead.
    let contentH = y + a.faceScroll - top.y
    if ui.hover(top) and not ui.scrollConsumed: a.faceScroll += ui.wheelNotches * RowH * 3
    a.faceScroll = clamp(a.faceScroll, 0, max(0, contentH - top.h + 10))
  ui.popClip()

  # Texture browser.
  let (dragging, my) = a.divider("face.browser", rect(r.x, r.y + r.h - browserH - 6, r.w, 6), false)
  if dragging: a.faceBrowserH = r.y + r.h - my - 3
  let br = rect(r.x, r.y + r.h - browserH, r.w, browserH)
  ui.sectionTitle(rect(br.x, br.y, br.w, 26), "Texture browser · click to apply to selected faces")
  discard ui.textField("tex.filter", rect(br.x + 8, br.y + 32, br.w - 90, 26), a.texFilter, "Search...")
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
  for t in a.textures:
    if (f.len == 0 or f in t.toLowerAscii) and (not a.texUsedOnly or t in used): shown.add t
  let cell = 74'f32
  let cols = max(1, int((list.w - 8) / cell))
  let rows = (shown.len + cols - 1) div cols
  if ui.hover(list) and not ui.scrollConsumed: a.texScroll += ui.wheelNotches * cell
  a.texScroll = clamp(a.texScroll, 0, max(0, rows.float32 * (cell + 14) - list.h))
  ui.pushClip(list)
  for i, t in shown:
    let cx = list.x + 6 + (i mod cols).float32 * cell
    let cy = list.y + 4 + (i div cols).float32 * (cell + 14) - a.texScroll
    if cy + cell + 14 < list.y or cy > list.y + list.h: continue
    let r = rect(cx, cy, cell - 6, cell - 6)
    # TrenchBroom's borders: red for the current texture, yellow for used ones.
    if t == current: ui.rect(rect(r.x - 2, r.y - 2, r.w + 4, r.h + 4), pm(255, 60, 60))
    elif t in used: ui.rect(rect(r.x - 2, r.y - 2, r.w + 4, r.h + 4), pm(240, 200, 40))
    let key = "tex:" & t
    if key in ui.sk.atlas.entries: ui.sk.drawImage(key, r.xy + vec2(5, 5))
    else: ui.rect(r, colPanelRaised)
    ui.text(ui.ellipsize(t, cell - 4, FontSmall), vec2(cx, cy + cell - 6), colTextDim, FontSmall)
    if ui.hover(r) and ui.pressed():
      ui.consumeClick()
      a.currentTexture = t
      # Picked with no face selected: new geometry gets this texture.
      if faces.len == 0 and a.faceTemplate.texture.len > 0: a.faceTemplate.texture = t
      if faces.len > 0:
        let app = a
        a.applyToFaces("Apply texture", proc(fi: int) =
          let old = app.geo.faces[fi].texture
          app.geo.faces[fi].texture = t
          if not app.uvLock:
            # Keep the texel density of the new texture.
            let s = app.density(old) / max(app.density(t), 0.01)
            if abs(s - 1) > 0.01: app.geo.transformUVs(fi, vec2(0, 0), vec2(1 / s, 1 / s), 0))
      ui.tip(r, t & (if t in used: " (used)" else: ""))
  ui.popClip()

proc drawInspector*(a: App, r: Rect) =
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, 1, r.h), colBorder)
  ui.tabs("inspector", rect(r.x, r.y, r.w, 32), a.inspector)
  let body = rect(r.x + 1, r.y + 32, r.w - 1, r.h - 32)
  case a.inspector
  of itMap: a.drawMapTab(body)
  of itEntity: a.drawEntityTab(body)
  of itFace: a.drawFaceTab(body)

# --- bottom panel and status -------------------------------------------------------------------

proc drawBottom*(a: App, r: Rect) =
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, r.w, 1), colBorder)
  ui.tabs("bottom", rect(r.x, r.y, r.w, 28), a.bottom)
  let body = rect(r.x, r.y + 28, r.w, r.h - 28)
  ui.pushClip(body)
  case a.bottom
  of btConsole:
    let lineH = 18'f32
    var lines = a.log
    if a.busy:
      for l in a.job.logTail(6).splitLines: lines.add LogLine(text: "  " & l)
    if ui.hover(body) and not ui.scrollConsumed: a.logScroll -= ui.wheelNotches * lineH * 3
    let total = lines.len.float32 * lineH
    a.logScroll = clamp(a.logScroll, 0, max(0, total - body.h + 8))
    let bottomY = body.y + body.h - 4 + a.logScroll
    for i in countdown(lines.high, 0):
      let y = bottomY - (lines.len - i).float32 * lineH
      if y < body.y - lineH: break
      if y > body.y + body.h: continue
      ui.text(lines[i].text, vec2(body.x + 10, y), if lines[i].error: colError else: colTextDim, FontSmall)
  of btIssues:
    var y = body.y + 4
    if a.issues.len == 0:
      ui.text("No issues found (Run ▸ Check for issues to refresh)", vec2(body.x + 10, y), colTextDim, FontSmall)
    for iss in a.issues:
      let row = rect(body.x, y, body.w, 20)
      if ui.hover(row):
        ui.rect(row, colHover)
        if ui.pressed():
          ui.consumeClick()
          a.clearSelection()
          if iss.obj != nil: iss.obj.selected = true
          elif iss.face >= 0 and a.geo != nil and iss.face < a.geo.faces.len:
            a.selFaces.incl iss.face
            a.lastFace = iss.face
          a.frameSelection()
      ui.text(iss.text, vec2(body.x + 10, y + 2), colText, FontSmall)
      y += 20
      if y > body.y + body.h: break
  ui.popClip()

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
      mouse.add ("Dbl", "Add all in layer")
      if in3D: mouse.add ("Wheel", "Select next behind / in front")
  elif held == {'s'}:
    if drawing: mouse = @[("Drag", "Square " & ($a.shape).toLowerAscii)]
    elif moving: mouse = @[("Drag", "Lock to one axis")]
    else:
      mouse = @[("LMB", "Select face"), ("Dbl", "Select all faces of a piece")]
      if noTool and pieces: mouse.add ("Drag", "Selected brush's face: extrude")
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
    if a.tool == toolClip: extra.add ("Enter", "Keep front / back / both")
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
  ui.text("Catwalk", vec2(x0, y), colText, FontTitle)
  ui.text("Level editor for Oni", vec2(x0 + ui.textSize("Catwalk", FontTitle).x + 12, y + 4), colTextDim)
  y += 48
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
  for p in projects:
    let r = rect(lx, py, colW, 30)
    let hov = ui.hover(r)
    ui.rect(r, if hov: colHover else: colPanelRaised)
    ui.textIn(p.lastPathPart, rect(r.x + 10, r.y, r.w - 20, r.h), colText)
    if hov and ui.pressed() and not a.busy:
      ui.consumeClick()
      a.openProjectDir(p)
    py += 34
    if py > area.y + area.h - 60: break
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
  for i, n in levels:
    let r = rect(rx + (i mod cols).float32 * (bw + 6), ly + (i div cols).float32 * 34, bw, 30)
    let sel = a.newLevel == n
    let hov = ui.hover(r)
    ui.rect(r, if sel: colAccentDim elif hov: colHover else: colPanelRaised)
    ui.textIn("Level " & $n, r, colText, h = CenterAlign)
    if hov and ui.pressed():
      ui.consumeClick()
      a.newLevel = n
      a.newName = uniqueName("Level" & $n)
  ly += ((levels.len + cols - 1) div cols).float32 * 34 + 4
  if a.newLevel > 0 and not a.busy and not taken:
    if ui.textButton("welcome.import", rect(rx + colW - 120, ly, 120, 30), "Import", primary = true):
      a.importLevel(a.newLevel, a.newName)
  ui.text("Projects folder: " & a.cfg.projectsDir & "   (File ▸ Settings to change)",
          vec2(lx, area.y + area.h - 30), colTextDisabled, FontSmall)

proc drawSettings*(a: App) =
  if not a.settingsOpen: return
  let ui = a.ui
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(0, 0, ui.size.x, ui.size.y), colScrim)
  let box = rect(floor((ui.size.x - 640) / 2), floor((ui.size.y - 330) / 2), 640, 330)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  ui.text("Settings", vec2(box.x + 16, box.y + 12), colText, FontTitle)
  var y = box.y + 54
  let x = box.x + 16
  let w = box.w - 32
  proc field(title: string, value: var string) =
    ui.text(title, vec2(x, y), colTextDim, FontSmall)
    discard ui.textField("settings." & title, rect(x, y + 18, w, 28), value)
    y += 56
  field("Oni AE folder (has Tools/OniSplit.exe and GameDataFolder)", a.settingsEdit.aeDir)
  field("Projects folder", a.settingsEdit.projectsDir)
  field("Game launch script (started with ARKLITE_AUTOSTART=<project>)", a.settingsEdit.launchScript)
  let sr = rect(box.x + box.w - 200, box.y + box.h - 46, 88, 30)
  let cr = rect(box.x + box.w - 104, box.y + box.h - 46, 88, 30)
  if ui.textButton("settings.save", sr, "Save", primary = true):
    a.cfg = a.settingsEdit
    a.cfg.save()
    a.settingsOpen = false
    a.say "Settings saved"
  if ui.textButton("settings.cancel", cr, "Cancel") or
     (ui.focusId.len == 0 and ui.window.buttonPressed[KeyEscape]):
    a.settingsOpen = false
  ui.sk.popLayer()
  ui.captured = true

proc drawSavePrompt*(a: App) =
  ## Unsaved changes: Yes saves then continues, No continues without saving,
  ## Cancel (or Esc) stays put.
  if a.savePrompt == nil: return
  let ui = a.ui
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
  if choice.len > 0:
    let action = a.savePrompt
    a.savePrompt = nil
    if choice == "yes": a.saveProject()
    if choice != "cancel": action()
