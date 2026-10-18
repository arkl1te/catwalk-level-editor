## Catwalk's editor state and the operations every part of the UI shares:
## loading and saving projects, selection, picking, undo/redo (objects and
## geometry together), and keeping object-owned geometry with its object.

import std/[os, strutils, strformat, math, tables, sets, algorithm, times, xmltree, xmlparser, sequtils, json]
import silky, vmath, bumpy, pixie
import ui, dialogs, menutree
import collada, levelobjects, project, jobs, camera, render, geometry, geomops, objtemplates, tga,
  presets, library, fieldchoices

const
  GridSizes* = [1'f32, 2, 4, 8, 16, 32, 64, 128, 256]
  GeometryLayer* = "GEOM"
  MaxGeometryUndo = 80

type
  Tool* = enum
    toolSelect = "Select"     ## No modal tool: click selects, drag moves or draws.
    toolBrush = "Brush"       ## Builds a brush from points placed on faces (TrenchBroom's B).
    toolVertex = "Vertex"
    toolEdge = "Edge"
    toolFace = "Face"
    toolClip = "Clip"
    toolRotate = "Rotate"
    toolScale = "Scale"

  InspectorTab* = enum itMap = "Map", itEntity = "Entity", itFace = "Face"
  BottomTab* = enum btConsole = "Console", btIssues = "Issues"
  PaneLayout* = enum pl1 = "One pane", pl2 = "Two panes", pl3 = "Three panes", pl4 = "Four panes"

  ViewPane* = object
    cam*: Camera
    rect*: Rect

  ShapeKind* = enum
    shCuboid = "Cuboid", shCylinder = "Cylinder", shCone = "Cone", shStairs = "Stairs"

  DragKind* = enum
    dkNone, dkMove, dkBox, dkLook, dkOrbit, dkPan, dkDraw, dkHandles, dkExtrude, dkRotate,
    dkScale, dkClipPoint, dkPaint, dkPaintFaces, dkSlide, dkSplit, dkStamp, dkRotateCenter,
    dkClipNew, dkAssembleRect, dkAssembleDup, dkPlace, dkPaintTexture, dkIgnore

  Press* = object
    ## A left button press in a map view: a click until it moves 2 pixels,
    ## then a drag (TrenchBroom's rule).
    active*: bool
    dragging*: bool
    view*: int
    pos*: Vec2
    time*: float

  CtxMenu* = object
    pos*: Vec2
    view*: int
    point*: Vec3                       ## World point under the right click.
    obj*: LevelObject                  ## Object under it, if any.
    face*: int                         ## Geometry face under it, or -1.

  DragPiece* = object
    ## Extrude-type drags: one piece with faces on the dragged face's plane.
    piece*: int32
    planes*: seq[Plane]                ## Brush: its planes at the start, else empty.
    planeIndex*: int                   ## Brush: the plane being moved.
    maps*: seq[UVMap]
    faces*: seq[(seq[Vec3], FaceAttr)] ## Corners and look of each face on the plane.

  Drag* = object
    kind*: DragKind
    view*: int
    startMouse*: Vec2
    startWorld*: Vec3
    lastDelta*: Vec3
    planeNormal*: Vec3
    vertical*: bool
    moved*: bool
    objs*: seq[LevelObject]
    startPose*: seq[(Vec3, Vec3)]
    objBefore*: seq[string]
    geoBefore*: Geometry
    startPoints*: Table[int32, Vec3]   ## Moving geometry: original positions.
    pivot*: Vec3
    orbitDist*: float32
    clipIndex*: int
    extent*: (Vec3, Vec3)              ## Scale: original selection bounds.
    scaleAxes*: Vec3                   ## Scale: which bounds sides move (-1, 0, +1 per axis).
    startTime*: float
    axis*: Vec3                        ## Rotate: axis; extrude: face normal.
    face*: int                         ## Extrude / slide: the dragged face.
    piece*: int32
    planes*: seq[Plane]                ## Extrude / split: the brush's planes at the start.
    planeIndex*: int
    maps*: seq[UVMap]
    selBefore*: (seq[LevelObject], HashSet[int32], HashSet[int])  ## Paint select: to cancel.
    faceBefore*: (int, FaceAttr)    ## Paint select: lastFace and faceTemplate, to cancel.
    handlesBefore*: HashSet[string]
    dup*: bool                         ## Ctrl+drag: the move follows a duplicate.
    placed*: LevelObject               ## Entity browser drag: the new object.
    preset*: Preset                    ## Entity browser drag: what it places.
    corners*: seq[Vec3]                ## Brush tool: polygon being stretched.
    angle*: float32
    painted*: HashSet[int]             ## Alt+drag: faces given the texture so far.
    wrap*: bool                        ## Alt+Shift+drag: alignment folds around edges.
    lastMouse*: Vec2
    extrudes*: seq[DragPiece]          ## Extrude / slide / split / stamp: every piece moved.

  CmdKind* = enum ckEdit, ckAdd, ckRemove, ckGeometry

  Cmd* = object
    label*: string
    kind*: CmdKind
    objs*: seq[LevelObject]
    before*, after*: seq[string]
    indices*: seq[int]
    geoBefore*, geoAfter*: Geometry

  LogLine* = object
    text*: string
    error*: bool
    time*: float

  Issue* = object
    text*: string
    obj*: LevelObject
    face*: int

  FieldDrop* = object
    ## The Entity tab's list under the focused field: what the game accepts there.
    id*: string                     ## Field it belongs to ("" = none).
    live*: bool                     ## The field asked for it this frame.
    items*: seq[Choice]
    base*: string                   ## Field text when it opened: unchanged = no filter.
    filter*: string                 ## Text the visible rows were filtered by.
    visible*: seq[int]              ## Indices into items.
    hi*: int                        ## Highlighted visible row (-1 = none).
    scroll*: int                    ## First visible row shown.
    width*: float32                 ## Widest value and note.
    anchor*: Rect                   ## The field.
    left*: float32                  ## How far left the list may grow (the field row's start).
    pick*: proc(v: string)          ## Commits a picked value.

  App* = ref object
    window*: Window
    sk*: Silky
    ui*: Ui
    rend*: Renderer
    cfg*: Config
    proj*: Project
    files*: seq[ObjectFile]
    objects*: seq[LevelObject]
    geo*: Geometry
    geoSavedVersion*: int
    textures*: seq[string]          ## Texture names available (from env/images).
    thumbsLoaded*: bool
    densities*: Table[string, float32]
    views*: array[4, ViewPane]
    layout*: PaneLayout
    maximized*: int
    focus2D*: Vec3                  ## Linked 2D views: shared point and zoom.
    zoom2D*: float32
    flySpeed*: float32              ## 3D fly speed (units/s); wheel changes it while flying.
    hoverView*: int
    activeView*: int
    tool*: Tool
    gridIndex*: int
    snap*: bool
    uvLock*: bool
    showGrid*: bool
    opts*: ViewOptions
    layerHidden*: HashSet[string]
    layerLocked*: HashSet[string]
    selPieces*: HashSet[int32]
    selFaces*: HashSet[int]         ## Face selection (Shift+click).
    lastFace*: int                  ## Face clicked last; the Face tab shows it.
    selHandles*: HashSet[string]    ## Vertex/edge/face tool handles (by position key).
    clipPoints*: seq[Vec3]
    clipSide*: Side
    clipView*: int
    inspector*: InspectorTab
    bottom*: BottomTab
    showInspector*, showBottom*: bool
    log*: seq[LogLine]
    issues*: seq[Issue]
    undoStack*, redoStack*: seq[Cmd]
    cleanAt*: int
    drag*: Drag
    job*: Job
    jobDone*: proc()
    menuSys*: MenuSystem            ## Menu bar and context menu popups (their own windows).
    menuTree*: MenuNode             ## This frame's menu bar tree.
    menuOpenedAt*: float            ## When the open menus opened, else 0.
    focusLostAt*: float             ## When the window lost focus, else 0.
    settingsOpen*: bool
    savePrompt*: proc()             ## Unsaved-changes prompt is up; runs this after Yes or No.
    quitConfirmed*: bool            ## The prompt (or a clean project) allowed the window to close.
    settingsEdit*: Config
    newName*: string
    newLevel*: int
    newTexLevel*: int               ## New empty level: textures from this game level (0 = all).
    newSky*: string                 ## New empty level: sky ("" = none).
    dialog*: Dialog
    pendingSave*: (string, string)  ## (dialog purpose, folder) of a Save As waiting for a job.
    hoverObj*: LevelObject
    fieldText*: Table[string, string]
    fieldObj*: LevelObject
    fieldSel*: seq[LevelObject]     ## Objects the multi-object field table shows.
    currentTexture*: string
    faceTemplate*: FaceAttr         ## The last selected face's look; geometry drawn from scratch takes it.
    texFilter*: string
    texScroll*, entityScroll*, layersScroll*, propsScroll*, logScroll*, faceScroll*: float32
    moveBy*: string
    rotateAngle*: float
    scaleBy*: string
    brushHeight*: float             ## Depth of a brush drawn in 2D before anything was selected.
    clipboard*: seq[string]
    clipboardGeo*: Geometry
    lastTime*: float
    inspectorWidth*: float32
    bottomHeight*: float32
    texFrames*: Table[int, TexFrame] ## Face tab: selected faces' texture mappings,
    texFramesFor*: tuple[geo: Geometry, version: int, faces: seq[int]]  ## valid for this geometry and selection.
    faceUndo*: tuple[label: string, geo: Geometry, version, depth: int, faces: seq[int]]
                                    ## Last live Face tab edit; more of the same merge into its undo step.
    shade*: array[3, float]
    openDropdown*: string           ## Id of the open dropdown list, if any.
    savePointList*: seq[int]        ## Save points the level's scripts handle.
    press*: Press
    rmbPress*: Press                ## Right button: a click opens the context menu.
    lastClick*: tuple[time: float, pos: Vec2, view: int]
    lastSel*: tuple[ok: bool, lo, hi: Vec3]  ## Bounds of the latest selection (new brush depth).
    extrudeHover*: int              ## Face Shift+drag would extrude, or -1.
    extrudeHoverFaces*: seq[int]    ## It and the selection's other faces on its plane.
    hoverHandle*: string
    assemblePoints*: seq[Vec3]      ## Brush tool points.
    rotCenter*: Vec3
    rotCenterText*: string
    rotAxis*: int                   ## Rotate tool Apply: 0 X, 1 Y, 2 Z.
    scaleText*: string
    scaleBySize*: bool
    shape*: ShapeKind
    shapeSides*: float
    shapeSteps*: float
    splitX*, splitY*: float32       ## Map view dividers (fractions).
    layersH*, entityBrowserH*, faceBrowserH*: float32
    splitDrag*: string              ## Divider being dragged.
    splitGrab*: float32
    hintScroll*: float32
    hintScrollKey*: string
    expanded*: HashSet[string]      ## Open layers in the Map tab tree.
    treeAnchor*: int                ## Shift+click range start in the layer tree.
    ctx*: CtxMenu
    frameNo*: int
    texUsedOnly*: bool
    showObjectNames*: bool
    browserPress*: (int, Vec2)      ## Entity browser: preset pressed (-1 = none) and where.
    presets*: seq[Preset]           ## Entity browser: built in, then the library's.
    catalog*: Catalog               ## Entity tab: values each field accepts.
    drop*: FieldDrop
    browserOpen*: HashSet[string]   ## Entity browser: expanded groups.
    entityFilter*: string
    entityPreview*: float           ## Entity browser preview size: 0 = list, up to 1.
    previewStamp: string            ## Library build the loaded previews are from.
    previewTried: HashSet[string]   ## Preview atlas keys loaded or missing.
    previewAutoBuild*: bool         ## The entity library was built for missing previews.
    skyAutoBuild*: bool             ## The sky images were extracted for the 3D view.

# --- basics -------------------------------------------------------------------------------

proc ctrl*(w: Window): bool = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
proc alt*(w: Window): bool = w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]
proc grid*(a: App): float32 = GridSizes[a.gridIndex]
proc meta*(w: Window): bool = w.buttonDown[KeyLeftSuper] or w.buttonDown[KeyRightSuper]
proc snapTo*(v, g: float32): float32 = round(v / g) * g
proc snapV*(a: App, v: Vec3): Vec3 =
  if not a.snap: return v
  let g = a.grid
  vec3(snapTo(v.x, g), snapTo(v.y, g), snapTo(v.z, g))

proc say*(a: App, msg: string, error = false) =
  a.log.add LogLine(text: msg, error: error, time: epochTime())
  if a.log.len > 2000: a.log.delete(0)

proc busy*(a: App): bool = a.job != nil and a.job.state == jsRunning

proc dirty*(a: App): bool =
  if a.undoStack.len != a.cleanAt: return true
  if a.geo != nil and a.geo.version != a.geoSavedVersion: return true
  for f in a.files:
    if f.dirty: return true

proc modalOpen*(a: App): bool = a.settingsOpen or a.savePrompt != nil

proc whenSaved*(a: App, action: proc()) =
  ## Runs action now, or after asking whether to save the open project's changes.
  if a.proj != nil and a.dirty: a.savePrompt = action
  else: action()

proc selection*(a: App): seq[LevelObject] =
  for o in a.objects:
    if o.selected: result.add o

proc hasSelection*(a: App): bool =
  a.selPieces.len > 0 or a.selFaces.len > 0 or a.selection.len > 0

proc clearSelection*(a: App) =
  for o in a.objects: o.selected = false
  a.selPieces.clear()
  a.selFaces.clear()
  a.selHandles.clear()

proc visible*(a: App, o: LevelObject): bool =
  not o.hidden and o.tag notin a.layerHidden

proc pickable*(a: App, o: LevelObject): bool = a.visible(o) and o.tag notin a.layerLocked

proc geometryVisible*(a: App): bool = a.geo != nil and GeometryLayer notin a.layerHidden
proc geometryEditable*(a: App): bool = a.geometryVisible and GeometryLayer notin a.layerLocked

proc faceVisible*(a: App, fi: int): bool =
  let f = a.geo.faces[fi]
  if f.piece >= 0 and f.piece < a.geo.pieces.len and a.geo.pieces[f.piece].hidden: return false
  if f.isMarkerFace and not a.opts.markers: return false
  true

# --- objects and their geometry ------------------------------------------------------------

proc objectCode*(o: LevelObject): int32 =
  ## The ObjectId the level's geometry uses for this object, or -1.
  let t = GunkTypes.getOrDefault(o.tag, 0)
  if t == 0: -1'i32 else: int32((t shl 24) or (o.id and 0xffffff))

proc facePickable*(a: App): proc(fi: int): bool =
  ## Faces a click can hit: the visible ones, plus selected faces that are only
  ## hidden as invisible/marker faces (they're still drawn highlighted).
  var codes: HashSet[int32]
  for o in a.objects:
    if o.selected and o.objectCode != -1: codes.incl o.objectCode
  let app = a
  result = proc(fi: int): bool =
    if app.faceVisible(fi): return true
    let f = app.geo.faces[fi]
    if f.piece >= 0 and f.piece < app.geo.pieces.len and app.geo.pieces[f.piece].hidden: return false
    fi in app.selFaces or f.piece in app.selPieces or f.objectId in codes

proc ownerOf*(a: App, objectId: int32): LevelObject =
  if objectId == -1: return nil
  for o in a.objects:
    if o.objectCode == objectId: return o

proc hasGeometry*(a: App, o: LevelObject): bool =
  let code = o.objectCode
  if code == -1 or a.geo == nil: return false
  for f in a.geo.faces:
    if f.objectId == code: return true

proc setPose*(a: App, o: LevelObject, pos, rot: Vec3) =
  ## Moves an object and the level geometry it owns.
  if a.geo != nil and o.objectCode != -1 and (pos != o.pos or rot != o.rot):
    a.geo.moveObjectGeometry(o.objectCode, o.pos, o.rot, pos, rot)
  if o.tag == "DOOR" and (pos != o.pos or rot != o.rot):
    # The door's activation center moves with it.
    let c = o.node.xpath("OSD/Center")
    let m = objectMatrix(pos, rot) * objectMatrix(o.pos, o.rot).inverse
    if c != nil: c.setText(fmtVec3(m * parseVec3(c.str)))
  o.pos = pos
  o.rot = rot
  o.syncToNode()

proc look*(o: LevelObject): tuple[half: Vec3, lift: float32, col: array[4, uint8]] =
  ## Marker box for an object: half extents, height of its center, color.
  case o.tag
  of "CHAR": (vec3(4, 9, 4), 9'f32, rgba(255, 196, 64))
  of "NEUT": (vec3(4, 9, 4), 9'f32, rgba(170, 170, 255))
  of "FURN": (vec3(3, 3, 3), 0'f32, rgba(170, 175, 185))
  of "FLAG":
    let c = strutils.splitWhitespace(o.node.xpath("OSD/Color").str)
    var col = rgba(80, 255, 80)
    if c.len == 3:
      try: col = rgba(parseInt(c[0]), parseInt(c[1]), parseInt(c[2]))
      except ValueError: discard
    (vec3(1.5, 6, 1.5), 6'f32, col)
  of "PART": (vec3(1.5, 1.5, 1.5), 0'f32, rgba(255, 110, 255))
  of "DOOR": (vec3(3, 3, 3), 0'f32, rgba(215, 150, 80))
  of "CONS": (vec3(3, 3, 3), 0'f32, rgba(80, 225, 205))
  of "TRIG": (vec3(3, 3, 3), 0'f32, rgba(255, 80, 80))
  of "TURR": (vec3(4, 4, 4), 0'f32, rgba(255, 150, 80))
  of "PWRU": (vec3(2.5, 2.5, 2.5), 2.5'f32, rgba(120, 255, 200))
  of "WEAP": (vec3(4, 1.5, 1.5), 1.5'f32, rgba(255, 255, 120))
  of "SNDG": (vec3(3, 3, 3), 0'f32, rgba(90, 190, 255))
  of "TRGV": (vec3(3, 3, 3), 0'f32, rgba(120, 255, 120))
  of "PATR": (vec3(2, 2, 2), 0'f32, rgba(255, 220, 120))
  else: (vec3(2, 2, 2), 0'f32, rgba(200, 200, 200))

proc corners*(o: LevelObject): array[8, Vec3] =
  ## The object's box: its model's bounds, or else its marker box.
  let (ok, m) = o.objectModel
  if ok:
    let t = objectMatrix(o.pos, o.rot)
    var i = 0
    for x in [m.lo.x, m.hi.x]:
      for y in [m.lo.y, m.hi.y]:
        for z in [m.lo.z, m.hi.z]:
          result[i] = t * vec3(x, y, z)
          inc i
    return
  let l = o.look
  boxCorners(o.pos + vec3(0, l.lift, 0), l.half, o.rot.y)

proc pickBox*(o: LevelObject): (Vec3, Vec3) =
  let k = o.corners
  var lo = k[0]
  var hi = k[0]
  for p in k:
    lo = min(lo, p)
    hi = max(hi, p)
  (lo - vec3(1, 1, 1), hi + vec3(1, 1, 1))

proc extentBox*(o: LevelObject): (bool, Vec3, Vec3) =
  ## Volumes some objects carry in their data (sounds, trigger volumes).
  case o.tag
  of "SNDG":
    let lo = parseVec3(o.node.xpath("OSD/Box/Min").str)
    let hi = parseVec3(o.node.xpath("OSD/Box/Max").str)
    if lo != hi: return (true, o.pos + lo, o.pos + hi)
  of "TRGV":
    let s = parseVec3(o.node.xpath("OSD/Size").str)
    if s != vec3(0, 0, 0): return (true, o.pos, o.pos + s)
  else: discard
  (false, vec3(0, 0, 0), vec3(0, 0, 0))

# --- undo ----------------------------------------------------------------------------------

proc trimGeometryUndo(a: App) =
  var n = 0
  for i in countdown(a.undoStack.high, 0):
    if a.undoStack[i].geoBefore != nil:
      inc n
      if n > MaxGeometryUndo:
        a.undoStack[i].geoBefore = nil
        a.undoStack[i].geoAfter = nil

proc push*(a: App, c: Cmd) =
  a.undoStack.add c
  a.redoStack.setLen 0
  if a.cleanAt > a.undoStack.len: a.cleanAt = -1
  a.trimGeometryUndo()

proc snapshotObjects*(objs: seq[LevelObject]): seq[string] =
  for o in objs: result.add o.snapshot

proc editCmd*(label: string, objs: seq[LevelObject], before: seq[string],
              geoBefore: Geometry = nil, geo: Geometry = nil): Cmd =
  result = Cmd(label: label, kind: ckEdit, objs: objs, before: before, geoBefore: geoBefore)
  for o in objs: result.after.add o.snapshot
  if geoBefore != nil and geo != nil: result.geoAfter = geo.clone

proc geoCmd*(label: string, before, after: Geometry): Cmd =
  Cmd(label: label, kind: ckGeometry, geoBefore: before, geoAfter: after.clone)

proc removeFromList(a: App, o: LevelObject) =
  let i = a.objects.find(o)
  if i >= 0: a.objects.delete(i)

proc applyCmd(a: App, c: Cmd, undo: bool) =
  case c.kind
  of ckEdit:
    for i, o in c.objs: o.restore(if undo: c.before[i] else: c.after[i])
  of ckAdd, ckRemove:
    let removing = (c.kind == ckAdd) == undo
    if removing:
      for o in c.objs:
        discard o.detach()
        o.selected = false
        a.removeFromList(o)
    else:
      for i in countdown(c.objs.high, 0): c.objs[i].attach(c.indices[i])
      for o in c.objs: a.objects.add o
  of ckGeometry: discard
  let g = if undo: c.geoBefore else: c.geoAfter
  if g != nil:
    let v = a.geo.version
    a.geo = g.clone
    a.geo.version = v + 1
    a.selPieces.clear()
    a.selFaces.clear()
    a.selHandles.clear()
  a.fieldObj = nil

proc undo*(a: App) =
  if a.undoStack.len == 0: return
  let c = a.undoStack.pop
  a.applyCmd(c, undo = true)
  a.redoStack.add c
  a.say "Undo " & c.label

proc redo*(a: App) =
  if a.redoStack.len == 0: return
  let c = a.redoStack.pop
  a.applyCmd(c, undo = false)
  a.undoStack.add c
  a.say "Redo " & c.label

# --- textures ---------------------------------------------------------------------------------

proc texturePath*(a: App, name: string): string =
  if a.proj == nil: return ""
  if name.startsWith("_marker"): a.proj.markersDir / name & ".tga"
  else: a.proj.imagesDir / name & ".tga"

proc density*(a: App, tex: string): float32 =
  if tex notin a.densities: a.densities[tex] = a.geo.textureDensity(tex)
  a.densities[tex]

proc densityFn*(a: App): proc(tex: string): float32 =
  let app = a
  result = proc(tex: string): float32 = app.density(tex)

proc updateFaceTemplate*(a: App) =
  ## Keeps faceTemplate in step with the last selected face (lastFace), so
  ## edits made to it while it stays selected count too.
  if a.geo == nil or a.lastFace notin a.selFaces or a.lastFace notin 0 .. a.geo.faces.high: return
  let f = a.geo.faces[a.lastFace]
  var t = attrOf(f)
  t.frame = a.geo.texFrame(f, a.density(f.texture))
  a.faceTemplate = t

proc newFaceAttr*(a: App): FaceAttr =
  ## How faces of geometry drawn from scratch look: like the last selected
  ## face, else plain with the texture browser's current texture.
  if a.faceTemplate.texture.len > 0: a.faceTemplate else: defaultAttr(a.currentTexture)

proc loadThumbnails*(a: App) =
  ## Texture browser thumbnails go into the UI atlas (one upload).
  if a.thumbsLoaded: return
  a.thumbsLoaded = true
  let sk = a.sk
  if sk.builder == nil: sk.builder = newAtlasBuilderFromAtlas(sk.atlas, sk.image)
  for name in a.textures:
    let key = "tex:" & name
    if key in sk.atlas.entries: continue
    try:
      let t = readTga(readFile(a.texturePath(name)))
      var img = newImage(t.width, t.height)
      for i in 0 ..< t.width * t.height:
        img.data[i] = rgbx(t.rgba[i * 4], t.rgba[i * 4 + 1], t.rgba[i * 4 + 2], 255)
      let thumb = img.resize(56, 56)
      if not sk.builder.addImage(key, thumb):
        sk.builder.growAtlas(sk.builder.size * 2)
        discard sk.builder.addImage(key, thumb)
    except CatchableError: discard
  sk.image = sk.builder.atlasImage
  sk.atlas = sk.builder.atlas
  sk.uploadAtlas()

# --- project loading and saving ------------------------------------------------------------------

proc frameAll*(a: App)

# Editor state kept outside the projects: the window layout (one for all maps)
# and where each map's 3D camera was left.
proc layoutPath(): string = configPath().parentDir / "layout.json"
proc camerasPath(): string =
  let state = getEnv("XDG_STATE_HOME", getHomeDir() / ".local/state")
  state / "catwalk" / "cameras.json"

proc readJson(path: string): JsonNode =
  try: parseFile(path) except CatchableError: newJObject()

proc loadLayout*(a: App) =
  let j = readJson(layoutPath())
  if j.kind != JObject: return
  if j.hasKey("layout"):
    for l in PaneLayout:
      if $l == j["layout"].getStr: a.layout = l
  a.splitX = j{"splitX"}.getFloat(a.splitX).float32
  a.splitY = j{"splitY"}.getFloat(a.splitY).float32
  a.showInspector = j{"showInspector"}.getBool(a.showInspector)
  a.showBottom = j{"showBottom"}.getBool(a.showBottom)
  a.inspectorWidth = j{"inspectorWidth"}.getFloat(a.inspectorWidth).float32
  a.bottomHeight = j{"bottomHeight"}.getFloat(a.bottomHeight).float32
  a.layersH = j{"layersH"}.getFloat(a.layersH).float32
  a.entityBrowserH = j{"entityBrowserH"}.getFloat(a.entityBrowserH).float32
  a.faceBrowserH = j{"faceBrowserH"}.getFloat(a.faceBrowserH).float32
  a.entityPreview = clamp(j{"entityPreview"}.getFloat(a.entityPreview), 0, 1)
  if j.hasKey("entityGroupsOpen"):
    a.browserOpen.clear()
    for g in j["entityGroupsOpen"]: a.browserOpen.incl g.getStr

proc saveLayout*(a: App) =
  try:
    createDir(layoutPath().parentDir)
    writeFile(layoutPath(), pretty(%*{"layout": $a.layout, "splitX": a.splitX, "splitY": a.splitY,
      "showInspector": a.showInspector, "showBottom": a.showBottom,
      "inspectorWidth": a.inspectorWidth, "bottomHeight": a.bottomHeight,
      "layersH": a.layersH, "entityBrowserH": a.entityBrowserH, "faceBrowserH": a.faceBrowserH,
      "entityPreview": a.entityPreview, "entityGroupsOpen": a.browserOpen.toSeq.sorted}))
  except CatchableError as e: a.say("Could not save the layout: " & e.msg, true)

proc camera3D(a: App): ptr Camera =
  for i in 0 .. 3:
    if a.views[i].cam.kind == vk3D: return addr a.views[i].cam

proc saveCamera*(a: App) =
  ## Remembers the open map's 3D camera, keyed by its project folder.
  let cam = a.camera3D
  if a.proj == nil or cam == nil: return
  var j = readJson(camerasPath())
  if j.kind != JObject: j = newJObject()
  j[a.proj.dir] = %*{"pos": [cam.pos.x, cam.pos.y, cam.pos.z], "yaw": cam.yaw, "pitch": cam.pitch}
  try:
    createDir(camerasPath().parentDir)
    writeFile(camerasPath(), pretty(j))
  except CatchableError as e: a.say("Could not save the camera: " & e.msg, true)

proc restoreCamera(a: App) =
  let cam = a.camera3D
  if a.proj == nil or cam == nil: return
  let c = readJson(camerasPath()){a.proj.dir}
  if c == nil or c.kind != JObject: return
  let p = c{"pos"}
  if p == nil or p.kind != JArray or p.len != 3: return
  cam.pos = vec3(p[0].getFloat.float32, p[1].getFloat.float32, p[2].getFloat.float32)
  cam.yaw = c{"yaw"}.getFloat(cam.yaw).float32
  cam.pitch = c{"pitch"}.getFloat(cam.pitch).float32

proc closeProject*(a: App) =
  ## Leaves the open map, keeping its 3D camera for next time.
  if a.proj == nil: return
  a.saveCamera()
  a.proj = nil

proc refreshGeometry*(a: App) =
  if a.geo == nil: return
  let app = a
  a.rend.setGeometry(a.geo, proc(n: string): string = app.texturePath(n),
                     proc(fi: int): bool = not app.faceVisible(fi))

proc updateWindowTitle*(a: App) =
  ## "<title> (<folder>) - Catwalk": the folder tells copies of one level apart.
  a.window.title =
    if a.proj == nil: "Catwalk"
    elif a.proj.title.len == 0 or a.proj.folder == a.proj.title: a.proj.folder & " - Catwalk"
    else: &"{a.proj.title} ({a.proj.folder}) - Catwalk"

proc loadProject*(a: App, p: Project) =
  if a.proj != nil and a.proj != p: a.saveCamera()
  a.rend.clearAll()
  a.proj = p
  a.cfg.noteOpened(p.dir)
  a.files.setLen 0
  a.objects.setLen 0
  a.undoStack.setLen 0
  a.redoStack.setLen 0
  a.cleanAt = 0
  a.fieldObj = nil
  a.clearSelection()
  a.densities.clear()
  a.geo = nil
  a.thumbsLoaded = false
  try:
    (a.files, a.objects) = loadObjects(p.objectsDir)
  except CatchableError as e:
    a.say("Could not read objects: " & e.msg, true)
  if p.hasGeometry:
    try:
      a.geo = loadGeometry(p.geometryPath)
      a.geoSavedVersion = a.geo.version
    except CatchableError as e:
      a.say("Could not read geometry: " & e.msg, true)
  if fileExists(p.bnvDae):
    try: a.rend.setRooms(readDae(p.bnvDae))
    except CatchableError as e: a.say("Could not read rooms: " & e.msg, true)
  a.faceTemplate = FaceAttr()
  a.lastFace = -1
  a.textures.setLen 0
  for f in walkFiles(p.imagesDir / "*.tga"):
    let n = f.splitFile.name
    if not n.startsWith("bnv_grid"): a.textures.add n
  a.textures.sort
  if a.currentTexture.len == 0 and a.textures.len > 0: a.currentTexture = a.textures[0]
  if a.geo != nil: a.refreshGeometry()
  a.savePointList = p.savePoints
  a.updateWindowTitle()
  a.frameAll()
  a.restoreCamera()
  a.say &"Opened {p.folder}: {a.objects.len} objects" &
    (if a.geo != nil: &", {a.geo.faces.len} faces in {a.geo.pieces.len} pieces" else: "")

proc saveProject*(a: App) =
  if a.proj == nil: return
  var n = 0
  for f in a.files:
    if f.dirty:
      f.save()
      inc n
  if a.geo != nil and a.geo.version != a.geoSavedVersion:
    a.geo.save(a.proj.geometryPath)
    a.geoSavedVersion = a.geo.version
    a.proj.geometryEdited = true
    inc n
  a.proj.save()
  a.cleanAt = a.undoStack.len
  a.say(if n > 0: &"Saved ({n} file(s))" else: "Nothing to save")

proc nextFreeProjectDir*(a: App): string =
  ## "<folder>-2", "-3"... next to the open project: the save dialogs' suggestion.
  let parent = a.proj.dir.parentDir
  var base = a.proj.folder
  let dash = base.rfind('-')
  if dash > 0 and base[dash + 1 .. ^1].allCharsInSet(Digits): base = base[0 ..< dash]
  var n = 2
  while true:
    result = parent / &"{base}-{n}"
    if not dirExists(result) and not fileExists(result): return
    inc n

proc copyProjectTree(src, dst: string) =
  ## The project's files, without build/ (Build recreates everything in it).
  createDir(dst)
  for kind, path in walkDir(src):
    let name = path.extractFilename
    if name == "build": continue
    case kind
    of pcDir, pcLinkToDir: copyDir(path, dst / name)
    else: copyFile(path, dst / name)

proc saveProjectAs*(a: App, target: string, keepWorking: bool) =
  ## Copies the open project, with its unsaved changes, to a new folder. Save As
  ## (keepWorking = false) then edits the copy; Save a copy stays on the original,
  ## leaving its unsaved changes unsaved.
  if a.proj == nil or target.len == 0: return
  let src = a.proj.dir.absolutePath.normalizedPath
  let dst = target.absolutePath.normalizedPath
  if dst == src:
    a.saveProject()
    return
  if dst.startsWith(src & DirSep):
    a.say("Cannot save a project inside its own folder", true)
    return
  if fileExists(dst) or (dirExists(dst) and toSeq(walkDir(dst)).len > 0):
    a.say(&"{dst} already exists; choose a new folder name", true)
    return
  try:
    copyProjectTree(src, dst)
    if keepWorking:
      for f in a.files:
        if f.dirty: f.saveTo(dst / f.path.absolutePath.relativePath(src))
      let p = Project()
      p[] = a.proj[]
      p.dir = dst
      p.folder = dst.lastPathPart
      if a.geo != nil and a.geo.version != a.geoSavedVersion:
        a.geo.save(p.geometryPath)
        p.geometryEdited = true
      p.save()
      a.say(&"Saved a copy as {dst}")
    else:
      a.saveCamera()
      for f in a.files: f.path = dst / f.path.absolutePath.relativePath(src)
      a.proj.dir = dst
      a.proj.folder = dst.lastPathPart
      a.saveProject()
      a.cfg.noteOpened(dst)
      a.saveCamera()
      a.updateWindowTitle()
      a.say(&"Saved as {dst}; now editing it")
  except CatchableError as e:
    a.say("Could not save the project: " & e.msg, true)

# --- cameras ------------------------------------------------------------------------------------

proc viewBody*(v: ViewPane): Rect = rect(v.rect.x, v.rect.y + 22, v.rect.w, v.rect.h - 22)

proc sync2D*(a: App) =
  ## 2D views share one zoom and pan together along shared axes.
  for i in 0 .. 3:
    if a.views[i].cam.kind != vk3D:
      a.views[i].cam.zoom = a.zoom2D
      a.views[i].cam.center = a.views[i].cam.kind.toPlane(a.focus2D)

proc frameBox*(a: App, lo, hi: Vec3) =
  let c = (lo + hi) / 2
  let size = max(max(hi.x - lo.x, hi.y - lo.y), max(hi.z - lo.z, 40))
  a.focus2D = c
  var minSide = 400'f32
  for v in a.views:
    if v.cam.kind != vk3D and v.rect.w > 1: minSide = min(minSide, min(v.rect.w, v.rect.h))
  a.zoom2D = clamp(minSide / (size * 1.2), 0.01, 40)
  for i in 0 .. 3:
    if a.views[i].cam.kind == vk3D:
      let cam = addr a.views[i].cam
      cam.yaw = 0.6
      cam.pitch = -0.45
      cam.pos = c - cam[].forward * size * 1.1
  a.sync2D()

proc frameAll*(a: App) =
  let (glo, ghi) = if a.geo != nil: a.geo.bounds else: (vec3(1), vec3(0))
  if glo.x <= ghi.x:
    a.frameBox(glo, ghi)
  elif a.objects.len > 0:
    var lo = vec3(Inf.float32)
    var hi = vec3(-Inf.float32)
    for o in a.objects:
      lo = min(lo, o.pos)
      hi = max(hi, o.pos)
    a.frameBox(lo, hi)

proc selectionBounds*(a: App): (bool, Vec3, Vec3) =
  var lo = vec3(Inf.float32)
  var hi = vec3(-Inf.float32)
  for o in a.selection:
    let (l, h) = o.pickBox
    lo = min(lo, l)
    hi = max(hi, h)
  if a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0):
    for i, f in a.geo.faces:
      if f.piece in a.selPieces or i in a.selFaces:
        for v in f.verts:
          lo = min(lo, a.geo.points[v])
          hi = max(hi, a.geo.points[v])
  (lo.x <= hi.x, lo, hi)

proc frameSelection*(a: App) =
  let (ok, lo, hi) = a.selectionBounds
  if ok: a.frameBox(lo, hi) else: a.frameAll()

# --- picking ------------------------------------------------------------------------------------

type
  HitKind* = enum hkNone, hkObject, hkFace
  Hit* = object
    kind*: HitKind
    obj*: LevelObject
    face*: int
    t*: float32
    point*: Vec3

proc viewRay*(a: App, vi: int, mouse: Vec2): Ray =
  let b = a.views[vi].viewBody
  a.views[vi].cam.ray(mouse.x - b.x, mouse.y - b.y, b.w, b.h)

proc pickAt*(a: App, vi: int, mouse: Vec2, geometryToo = true): Hit =
  ## Nearest object or geometry face under the mouse. Faces owned by an object
  ## pick the object.
  let r = a.viewRay(vi, mouse)
  result = Hit(kind: hkNone, t: Inf.float32, face: -1)
  for o in a.objects:
    if not a.pickable(o): continue
    let (lo, hi) = o.pickBox
    let t = r.rayBox(lo, hi)
    if t >= 0 and t < result.t:
      result = Hit(kind: hkObject, obj: o, t: t, face: -1)
  if geometryToo and a.geometryVisible:
    let (fi, t) = a.geo.pickFace(r, a.facePickable)
    if fi >= 0 and t < result.t:
      let owner = a.ownerOf(a.geo.faces[fi].objectId)
      if owner != nil:
        if a.pickable(owner): result = Hit(kind: hkObject, obj: owner, t: t, face: fi)
      elif a.geometryEditable:
        result = Hit(kind: hkFace, face: fi, t: t)
  if result.kind != hkNone: result.point = r.origin + r.dir * result.t

proc planeHit*(r: Ray, point, normal: Vec3): (bool, Vec3) =
  let d = r.dir.dot(normal)
  if abs(d) < 1e-6: return (false, vec3(0, 0, 0))
  let t = (point - r.origin).dot(normal) / d
  if t < 0: return (false, vec3(0, 0, 0))
  (true, r.origin + r.dir * t)

# --- shared editing operations ------------------------------------------------------------------

proc selectedFaceSet*(a: App): HashSet[int] =
  ## Faces of selected pieces plus individually selected faces.
  if a.geo == nil: return
  for i, f in a.geo.faces:
    if f.piece in a.selPieces or i in a.selFaces: result.incl i

proc deleteSelection*(a: App) =
  let sel = a.selection
  let geoSel = a.selPieces.len > 0 or a.selFaces.len > 0
  var linked = false
  for o in sel:
    if a.hasGeometry(o): linked = true
  if sel.len == 0 and not geoSel: return
  let geoBefore = if (geoSel or linked) and a.geo != nil: a.geo.clone else: nil
  if geoSel:
    a.geo.removeFaces(a.selectedFaceSet)
  var c = Cmd(label: "Delete", kind: ckRemove, objs: sel, geoBefore: geoBefore)
  for o in sel:
    c.indices.add o.detach()
    o.selected = false
    a.removeFromList(o)
    if a.geo != nil and o.objectCode != -1:
      a.geo.removeFaces(toHashSet(a.geo.objectFaces(o.objectCode)))
  if geoBefore != nil: c.geoAfter = a.geo.clone
  a.push c
  a.selPieces.clear()
  a.selFaces.clear()
  a.selHandles.clear()
  a.fieldObj = nil
  a.say &"Deleted {sel.len} object(s)" & (if geoSel: " and geometry" else: "")

proc duplicateSelection*(a: App, offset: Vec3) =
  let sel = a.selection
  let geoSel = a.selPieces.len > 0 or a.selFaces.len > 0
  if sel.len == 0 and not geoSel: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  var c = Cmd(label: "Duplicate", kind: ckAdd, geoBefore: geoBefore)
  var id = a.objects.nextId
  for o in sel: o.selected = false
  for o in sel:
    let d = o.duplicate(id)
    inc id
    if a.geo != nil and o.objectCode != -1:
      let faces = a.geo.objectFaces(o.objectCode)
      let added = a.geo.duplicateFaces(faces, vec3(0, 0, 0))
      for fi in added: a.geo.faces[fi].objectId = d.objectCode
    a.setPose(d, d.pos + offset, d.rot)
    d.selected = true
    a.objects.add d
    c.objs.add d
    c.indices.add d.file.list.findChild(d.node)
  if geoSel:
    let added = a.geo.duplicateFaces(a.selectedFaceSet.toSeq.sorted, offset)
    a.selPieces.clear()
    a.selFaces.clear()
    for fi in added: a.selPieces.incl a.geo.faces[fi].piece
  if a.geo != nil: c.geoAfter = a.geo.clone
  a.push c
  a.say "Duplicated"

proc moveSelection*(a: App, d: Vec3, label = "Move") =
  ## Moves selected objects (with their geometry) and selected geometry.
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  if sel.len == 0 and not geoSel: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  for o in sel: a.setPose(o, o.pos + d, o.rot)
  if geoSel:
    let faces = a.selectedFaceSet
    a.geo.detachPoints(faces)
    a.geo.movePoints(a.geo.pointsOf(faces), d)
  a.push editCmd(label, sel, before, geoBefore, a.geo)

proc rotateSelection*(a: App, axis: Vec3, deg: float32, label = "Rotate") =
  ## Rotates the selection about its center (objects also turn in place).
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  if sel.len == 0 and not geoSel: return
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  var pivot = (lo + hi) / 2
  pivot = a.snapV(pivot)
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  for o in sel:
    var r = o.rot
    if abs(axis.y) > 0.5: r.y = r.y + deg * sgn(axis.y).float32
    elif abs(axis.x) > 0.5: r.x = r.x + deg * sgn(axis.x).float32
    else: r.z = r.z + deg * sgn(axis.z).float32
    for i in 0 .. 2: r[i] = r[i] - 360 * floor((r[i] + 180) / 360)
    let p = if sel.len > 1 or geoSel: rotateAxis(o.pos, pivot, axis, deg) else: o.pos
    a.setPose(o, p, r)
  if geoSel:
    let faces = a.selectedFaceSet
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg))
  a.push editCmd(label, sel, before, geoBefore, a.geo)

proc flipSelection*(a: App, axis: int) =
  ## Mirrors selected geometry (and object positions) across the selection center.
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  if sel.len == 0 and not geoSel: return
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  let c = a.snapV((lo + hi) / 2)
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  for o in sel:
    var p = o.pos
    p[axis] = 2 * c[axis] - p[axis]
    a.setPose(o, p, o.rot)
  if geoSel:
    let faces = a.selectedFaceSet
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), proc(p: Vec3): Vec3 =
      result = p
      result[axis] = 2 * c[axis] - p[axis])
    a.geo.reverseWinding(faces)
  a.push editCmd("Flip", sel, before, geoBefore, a.geo)

proc scatterSelection*(a: App) =
  ## Lays the selected objects out in a square grid on the ground plane, each
  ## one grid step clear of its neighbours (cells fit the largest object).
  let sel = a.selection
  if sel.len < 2: return
  let g = a.grid
  var cell = 0'f32
  var origin = vec3(Inf.float32)
  for o in sel:
    var (lo, hi) = o.pickBox
    if a.geo != nil and o.objectCode != -1:
      for fi in a.geo.objectFaces(o.objectCode):
        for v in a.geo.faces[fi].verts:
          lo = min(lo, a.geo.points[v])
          hi = max(hi, a.geo.points[v])
    cell = max(cell, max(hi.x - lo.x, hi.z - lo.z))
    origin = min(origin, o.pos)
  cell = ceil(cell / g) * g + g
  origin = vec3(snapTo(origin.x, g), 0, snapTo(origin.z, g))
  let cols = ceil(sqrt(sel.len.float32)).int
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  for i, o in sel:
    let p = vec3(origin.x + (i mod cols).float32 * cell, o.pos.y,
                 origin.z + (i div cols).float32 * cell)
    a.setPose(o, p, o.rot)
  a.push editCmd("Scatter", sel, before, geoBefore, a.geo)
  a.say &"Scattered {sel.len} object(s) {cell:g} apart"

proc newObject(a: App, tag: string, pos: Vec3, xml: string): LevelObject =
  ## Adds an object made from xml to its type's file (no undo step). It gets
  ## the next free object id and, for types that have one, the next free script
  ## id (ConsoleId, DoorId, ...).
  var file: ObjectFile = nil
  for o in a.objects:
    if o.tag == tag:
      file = o.file
      break
  if file == nil:
    for f in a.files:
      if f.path.extractFilename == "BINACJBO" & FileNames[tag] & ".xml": file = f
  if file == nil:
    let path = a.proj.objectsDir / "BINACJBO" & FileNames[tag] & ".xml"
    let root = parseXml("<Oni><Objects></Objects></Oni>")
    file = ObjectFile(path: path, root: root, list: root.xpath("Objects"), dirty: true)
    a.files.add file
  let o = LevelObject(tag: tag, file: file)
  o.node = newElement(tag)
  file.list.add o.node
  o.restore(xml)
  o.node.setAttr("Id", $a.objects.nextId)
  if tag in ScriptIdFields:
    let path = ScriptIdFields[tag]
    var top = 0
    for other in a.objects:
      if other.tag == tag:
        try: top = max(top, parseInt(other.node.xpath(path).str.strip))
        except ValueError: discard
    let n = o.node.xpath(path)
    if n != nil: n.setText($(top + 1))
  o.syncFromNode()
  o.pos = pos
  o.rot = vec3(0, 0, 0)
  o.syncToNode()
  a.objects.add o
  o

proc addObject*(a: App, tag: string, pos: Vec3): LevelObject =
  ## Places a new object: a copy of the level's first object of this type, or a template.
  var source: LevelObject = nil
  for o in a.objects:
    if o.tag == tag:
      source = o
      break
  let o = a.newObject(tag, pos, if source != nil: source.snapshot else: Templates[tag])
  a.push Cmd(label: "Create " & typeName(tag), kind: ckAdd, objs: @[o],
             indices: @[o.file.list.findChild(o.node)])
  a.clearSelection()
  o.selected = true
  o

proc addPreset*(a: App, p: Preset, pos: Vec3): LevelObject =
  ## Places a preset from the entity browser, with the geometry, textures and
  ## files it brings. Nil (and a message) when the level can't take it.
  if p.generic: return a.addObject(p.tag, pos)
  if p.prefab.len > 0 and a.geo == nil:
    a.say("This project has no editable geometry, so it can't take " & p.label, true)
    return nil
  var prefab: Geometry = nil
  if p.prefab.len > 0:
    try: prefab = loadGeometry(p.prefabPath)
    except CatchableError as e:
      a.say("Could not read " & p.label & " from the entity library: " & e.msg, true)
      return nil
  let geoBefore = if prefab != nil: a.geo.clone else: nil
  let o = a.newObject(p.tag, pos, p.presetXml)
  if o.tag == "CHAR":
    # Scripts address characters by name.
    o.node.xpath("OSD/Name").setText(o.node.xpath("OSD/Class").str & "_" & $o.id)
  if o.tag == "DOOR" and p.doorCenter.len > 0:
    o.node.xpath("OSD/Center").setText(fmtVec3(objectMatrix(pos, o.rot) * parseVec3(p.doorCenter)))
  if prefab != nil:
    # The faces, in object space, become the object's geometry.
    let m = objectMatrix(pos, o.rot)
    let base = a.geo.points.len.int32
    let piece = a.geo.pieces.len.int32
    for q in prefab.points: a.geo.points.add m * q
    a.geo.pieces.add Piece()
    for f in prefab.faces:
      var nf = f
      for v in nf.verts.mitems: v += base
      nf.objectId = o.objectCode
      nf.piece = piece
      a.geo.faces.add nf
    a.geo.bump()
    var added = false
    for t in p.textures:
      let src = libraryImages() / t & ".tga"
      let dst = a.proj.imagesDir / t & ".tga"
      if not fileExists(dst) and fileExists(src):
        createDir(a.proj.imagesDir)
        copyFile(src, dst)
      if t notin a.textures and fileExists(dst):
        a.textures.add t
        added = true
    if added:
      a.textures.sort
      a.thumbsLoaded = false
  for f in p.oniFiles:
    let src = libraryOni() / f
    let dst = a.proj.oniDir / f
    if fileExists(dst): continue
    if fileExists(src):
      createDir(a.proj.oniDir)
      copyFile(src, dst)
    else:
      a.say(&"{p.label}: {f} isn't in the entity library; build it to pack the texture", true)
  a.push Cmd(label: "Create " & p.label, kind: ckAdd, objs: @[o],
             indices: @[o.file.list.findChild(o.node)], geoBefore: geoBefore,
             geoAfter: if prefab != nil: a.geo.clone else: nil)
  a.clearSelection()
  o.selected = true
  o

proc libraryStamp(): string =
  try: (if hasLibrary(): $getLastModificationTime(libraryFile()).toUnix else: "")
  except CatchableError: ""

proc loadPresets*(a: App) =
  # The library may have been rebuilt: models are read again on next use.
  clearModelCache()
  if a.rend != nil: a.rend.clearModels()
  a.presets = builtinPresets()
  try: a.presets.add loadLibrary()
  except CatchableError as e: a.say("Could not read the entity library: " & e.msg, true)
  # Atlas entries can't be replaced: a rebuilt library's previews get new keys.
  a.previewStamp = libraryStamp()

proc presetsCurrent*(a: App): bool =
  ## False once the library was rebuilt (by another Catwalk) since loadPresets.
  a.previewStamp == libraryStamp()

proc previewKey*(a: App, p: Preset): string =
  ## The preset's preview in the UI atlas ("" = it has none); see loadPreviews.
  let k = p.thumbKey
  if k.len > 0 and a.previewStamp.len > 0: "ent:" & a.previewStamp & ":" & k else: ""

proc loadPreviews*(a: App, wanted: seq[Preset]) =
  ## Adds the previews the entity browser shows to the UI atlas, once each.
  let sk = a.sk
  var added = false
  for p in wanted:
    let key = a.previewKey(p)
    if key.len == 0 or key in a.previewTried: continue
    let path = p.thumbPath
    # Missing while the previews are still being rendered: try again later.
    if not fileExists(path) and not hasPreviews(): continue
    a.previewTried.incl key
    if not fileExists(path): continue
    try:
      let img = readImage(path)
      if sk.builder == nil: sk.builder = newAtlasBuilderFromAtlas(sk.atlas, sk.image)
      if not sk.builder.addImage(key, img):
        sk.builder.growAtlas(sk.builder.size * 2)
        discard sk.builder.addImage(key, img)
      added = true
    except CatchableError: discard
  if added:
    sk.image = sk.builder.atlasImage
    sk.atlas = sk.builder.atlas
    sk.uploadAtlas()

# --- issues ----------------------------------------------------------------------------------

proc findIssues*(a: App) =
  a.issues.setLen 0
  var ids: CountTable[int]
  var player = false
  for o in a.objects:
    ids.inc o.id
    if o.tag == "CHAR" and "IsPlayer" in o.node.xpath("OSD/Flags").str: player = true
  if not player:
    a.issues.add Issue(text: "No player start (a character with the IsPlayer flag)", face: -1)
  for o in a.objects:
    if ids[o.id] > 1:
      a.issues.add Issue(text: &"{typeName(o.tag)} #{o.id}: duplicate object id", obj: o, face: -1)
    if o.tag in ["CHAR", "FURN", "WEAP", "PWRU", "CONS", "DOOR", "TURR", "TRIG"] and
       o.node.xpath("OSD/Class").str.strip.len == 0:
      a.issues.add Issue(text: &"{typeName(o.tag)} #{o.id}: no class", obj: o, face: -1)
  if a.geo != nil:
    var known = toHashSet(a.textures)
    var missing: CountTable[string]
    for i, f in a.geo.faces:
      if f.verts.len < 3:
        a.issues.add Issue(text: &"Face {i}: fewer than three corners", face: i)
      elif not f.isMarkerFace and f.texture notin known and f.texture != "NONE":
        missing.inc f.texture
    for t, n in missing:
      a.issues.add Issue(text: &"Texture {t} ({n} faces): no image in env/images", face: -1)
