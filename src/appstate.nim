## Catwalk's editor state and the operations every part of the UI shares:
## loading and saving projects, selection, picking, undo/redo (objects and
## geometry together), and keeping object-owned geometry with its object.

import std/[os, strutils, strformat, math, tables, sets, algorithm, times, xmltree, xmlparser, sequtils, json, hashes]
import silky, vmath, bumpy, pixie
import ui, dialogs, menutree, pictures, skyconvert, skyfit
import crashlog
import collada, levelobjects, project, jobs, camera, render, geometry, geomops, objtemplates, tga,
  presets, library, fieldchoices, lighting, files, scriptedit, particlesim
from music import setMusicVolume, setProjectAmbients
import ambients

const
  GridSizes* = [0.125'f32, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256]
  GridKeyBase* = 3                  ## GridSizes index that number key 2 selects (grid 1); keys 2–9 = grid 1–128.
  GridHalfIndex* = GridKeyBase - 1  ## Grid 0.5, selected by key 1.
  MinFlySpeed* = 1'f32
  MaxFlySpeed* = 20000'f32
  ViewHeader* = 44'f32              ## Height of a map view's header bar.
  SplitW* = 8'f32                   ## Thickness of the dividers between panes.
  DefaultFlySpeed* = 500'f32       ## Fly speed factor 1 (Settings > Mouse > Fly mode).
  FlyWheelStep* = 1.25'f32         ## Fly speed change per wheel notch while flying.
  StartFlySpeed* = DefaultFlySpeed / (FlyWheelStep * FlyWheelStep * FlyWheelStep * FlyWheelStep *
                   FlyWheelStep * FlyWheelStep * FlyWheelStep)
    ## The fly speed to begin with: factor 0.21 (seven wheel notches below 1).
  MinTexThumb* = 32'f32            ## Texture browser tile sizes Ctrl+wheel zooms between.
  MaxTexThumb* = 256'f32
  DefaultTexThumb* = 56'f32
  CodeFontSizes* = [9, 10, 11, 12, 13, 14, 16, 18, 20, 22, 24, 28, 32]  ## Scripts editor text sizes Ctrl+wheel steps through.
  DefaultCodeFontSize* = 14
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


  PanelKind* = enum
    pkViewport = "Viewport", pkProperties = "Properties", pkClasses = "Classes", pkMap = "Map", pkFiles = "Files",
    pkEntityBrowser = "Entity Browser", pkTextureBrowser = "Texture Browser",
    pkTextureCollections = "Texture Collections",
    pkConsole = "Console", pkIssues = "Issues", pkScripts = "Scripts"

  DockNode* = ref object
    ## The panel layout: a leaf is a stack of tabbed panels (tabs non-empty),
    ## any other node splits its rect between two kids.
    tabs*: seq[PanelKind]
    active*: int
    row*: bool                      ## Split: kids side by side (else stacked).
    frac*: float32                  ## Split: the first kid's share.
    kids*: seq[DockNode]
    r*: Rect                        ## This frame's rect (layoutDock).
    divider*: Rect                  ## Split: the bar between the kids.

  DockZone* = enum dzNone, dzTabs, dzLeft, dzRight, dzTop, dzBottom
  PaneLayout* = enum pl1 = "One pane", pl2 = "Two panes", pl3 = "Three panes", pl4 = "Four panes"

  ViewPane* = object
    cam*: Camera
    last3D*: Camera                 ## The 3D camera this pane had before Space cycled it to 2D.
    rect*: Rect

  ShapeKind* = enum
    shCuboid = "Cuboid", shCylinder = "Cylinder", shCone = "Cone", shStairs = "Stairs"

  DragKind* = enum
    dkNone, dkMove, dkBox, dkLook, dkOrbit, dkPan, dkDraw, dkHandles, dkExtrude, dkRotate,
    dkScale, dkClipPoint, dkPaint, dkPaintFaces, dkSlide, dkSplit, dkStamp, dkRotateCenter,
    dkClipNew, dkAssembleRect, dkAssembleDup, dkPlace, dkPaintTexture, dkGizmo, dkBoxFace, dkSelRect, dkCut, dkIgnore

  Press* = object
    ## A left button press in a map view: a click until it moves 2 pixels,
    ## then a drag (TrenchBroom's rule).
    active*: bool
    dragging*: bool
    view*: int
    pos*: Vec2
    time*: float

  PreviewPart* = enum
    ## What Realtime preview plays (right click its button to choose).
    ppLights = "Animated lighting", ppSounds = "Sound objects", ppMusic = "Level music",
    ppParticles = "Particles"
  EditorOnlyPart* = enum
    ## What the Editor-only button shows (right click it to choose): things
    ## the game never draws.
    eoInvisible = "Invisible faces", eoNotes = "Notes"

  ClassXmlDraft* = object
    text*, base*, error*: string       ## What's typed, the class it started from, why Apply refused it.

  CtxMenu* = object
    pos*: Vec2
    view*: int
    point*: Vec3                       ## World point under the right click.
    obj*: LevelObject                  ## Object under it, if any.
    face*: int                         ## Geometry face under it, or -1.
    groupHit*: int32                   ## Group of the nearest unselected thing under it (0 = none).
    file*: string                      ## Opened in the Files tab: the path under it (else "").
    realtime*: bool                    ## Opened on a view's Realtime preview button.
    gizmos*: bool                      ## Opened on a view's Gizmos button.
    editorOnly*: bool                  ## Opened on a view's Editor-only button.
    classAdd*: string                  ## Opened on a class's + button: "+" for an event, else the event an action goes in.
    classParentsOf*: string            ## Opened on a breadcrumb: the class whose other parents it lists.
    ambient*: string                   ## Opened on a sound list's ambient: duplicating or editing it.
    ambientPick*: proc(v: string)      ## ...and that list's field, which a duplicate's name goes in.
    texture*: string                   ## Opened on a Texture Browser tile: its texture.

  DragPiece* = object
    ## Extrude-type drags: one piece with faces on the dragged face's plane.
    piece*: int32
    planes*: seq[Plane]                ## Brush: its planes at the start, else empty.
    planeIndex*: int                   ## Brush: the plane being moved.
    maps*: seq[UVMap]
    faces*: seq[(seq[Vec3], FaceAttr)] ## Corners and look of each face on the plane.

  ClipPoint* = object
    pos*: Vec3
    help*: seq[Vec3]   ## Axes it was placed along (TrenchBroom's help vectors): pick
                       ## the plane's third point when there are only two.

  TexHold* = seq[tuple[face: int, frame: TexFrame, uvs: seq[Vec2]]]
    ## UV lock off: moved faces' texture mappings from before the move (holdTextures).

  Drag* = object
    kind*: DragKind
    view*: int
    startMouse*: Vec2
    startWorld*: Vec3
    lastDelta*: Vec3
    built*: bool                       ## Extrude / slide / split / stamp / cut: geometry rebuilt yet...
    builtMove*: Vec3                   ## ...for this move (it starts over from geoBefore, so unbaked).
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
    clipBefore*: seq[ClipPoint]        ## Clip point drags: the points at the start, to cancel.
    handleOffset*: Vec3                ## Clip point drags in 2D: press point minus the point.
    extent*: (Vec3, Vec3)              ## Scale: original selection bounds.
    scaleAxes*: Vec3                   ## Scale: which bounds sides move (-1, 0, +1 per axis).
    startTime*: float
    axis*: Vec3                        ## Rotate: axis; extrude: face normal; gizmo: arrow axis.
    along*: float32                    ## Gizmo: where the press was along the arrow's line.
    onPlane*: bool                     ## Gizmo: a square was grabbed; axis is its plane's normal.
    face*: int                         ## Extrude / slide: the dragged face; box face: 0..5 (boxHandles).
    boxStart*: seq[(Vec3, Vec3)]       ## Box faces: each of objs' volumeRange at the start.
    boxBase*: seq[Vec3]                ## Box faces: each of objs' position at the start.
    free*: bool                        ## Box faces: some move along another axis than the grabbed
                                       ## one, so the drag moves freely (like the vertex tool's).
    rectMode*: int                     ## Rectangle select: 0 nothing touched yet, 1 sound face
                                       ## handles, 2 entities (whichever it touched first).
    piece*: int32
    planes*: seq[Plane]                ## Extrude / split: the brush's planes at the start.
    planeIndex*: int
    maps*: seq[UVMap]
    selBefore*: (seq[LevelObject], HashSet[int32], HashSet[int])  ## Paint select: to cancel.
    faceBefore*: (int, FaceAttr)    ## Paint select: lastFace and faceTemplate, to cancel.
    handlesBefore*: HashSet[string]
    dup*: bool                         ## Ctrl+drag: the move follows a duplicate.
    carry*: bool                       ## Look drag with both buttons: the selection rides
                                       ## along with the camera (a move, startWorld = its center).
    carryLocal*: Vec3                  ## Carry: the center in the camera's frame (right, up, forward).
    xform*: Affine                     ## Move / rotate / scale: what the drag did so far
                                       ## (groups moved whole take it at the end).
    texHold*: TexHold                  ## Move / rotate / scale with UV lock off.
    placed*: LevelObject               ## Entity browser drag: the new object.
    preset*: Preset                    ## Entity browser drag: what it places.
    corners*: seq[Vec3]                ## Brush tool: polygon being stretched.
    angle*: float32
    painted*: HashSet[int]             ## Alt+drag: faces given the texture so far.
    wrap*: bool                        ## Alt+Shift+drag: alignment folds around edges.
    lastMouse*: Vec2
    extrudes*: seq[DragPiece]          ## Extrude / slide / split / stamp: every piece moved.
    cutEdge*: (Vec3, Vec3)             ## Cut: the edge the cut leaves from (axis points away from it).
    cutEdges*: seq[(int, Vec3, Vec3)]  ## Cut: selected faces' open edges extending with it, it first.
    cutLines*: seq[(Vec3, Vec3)]       ## Cut: where it crosses the selected faces now.
    cutOutward*: bool                  ## Cut: dragged out past the edge, so it extends the surface.
    snapLines*: seq[(Vec3, Vec3)]      ## Extrude / slide / split / stamp: (point, unit direction)
                                       ## each dragged corner travels, snapped onto grid planes.

  Affine* = object
    ## An affine map: images of the X, Y and Z axes, then the translation.
    m*: array[3, Vec3]
    t*: Vec3

  LinkSig* = (Hash, Hash, Affine)    ## A linked group's objects, geometry and xform (linkedSig).

  Group* = object
    ## TrenchBroom's group: objects and pieces selected, moved and edited as
    ## one until opened (double-click). Groups nest. Groups sharing a link are
    ## linked duplicates: an edit inside one is copied into the others, each
    ## placed by its own xform.
    id*: int32
    name*: string
    parent*: int32                     ## Enclosing group, 0 = none.
    link*: string                      ## Link set; unique unless linked.
    xform*: Affine                     ## Where the group was moved, rotated or flipped to
                                       ## (the link set's contents map through it).
    spin*: float32                     ## Seconds per turn around its center's vertical
                                       ## axis in the game, negative = the other way; 0 = fixed.
    objs*: seq[LevelObject]            ## Member objects (pieces carry their group).

  CmdKind* = enum
    ckEdit, ckAdd, ckRemove, ckGeometry
    ckSelect                    ## Selection only: not a change to the level (TrenchBroom's SelectionCommand).
    ckVisibility                ## Hidden objects, pieces and layers, locked layers (TrenchBroom's
                                ## SetVisibilityCommand / SetLockStateCommand): not a modification.
    ckProject                   ## The Level page's settings. project.json is written as they change,
                                ## so they never leave unsaved changes.

  ProjSettings* = object
    ## What the Level page edits.
    title*, sky*, music*: string
    musicVolume*: float
    autoBake*: bool
    ambient*: array[3, int]
    softShadows*: float
    skyGrade*: SkyGrade

  VisState* = object
    ## What is hidden or locked.
    objs*: seq[LevelObject]
    pieces*: HashSet[int32]
    layers*, locked*: HashSet[string]

  SelState* = object
    ## What is selected: objects, geometry pieces and faces, and the face clicked last.
    objs*: seq[LevelObject]
    pieces*: HashSet[int32]
    faces*: HashSet[int]
    lastFace*: int

  TexCollection* = object
    ## Textures the Texture Browser can list: the level's own (id "level"), the
    ## ones imported into the project ("custom"), or another game level's
    ## ("game:<n>"), which are copied into the project when first used.
    id*, name*: string
    level*: int                  ## Game level; 0 for the project's own.
    dir*: string
    ready*: bool                 ## Its textures are there (a game level's are extracted first).
    textures*: seq[string]

  CamAnim* = object
    ## The cameras gliding to a new place (animateCameras). Moving one by hand
    ## leaves it where it is.
    on*: bool
    start*: float
    target*: Vec3                ## The point they turn around.
    fromCam*, toCam*, shown*: array[4, Camera]
    fromFocus*, toFocus*, shownFocus*: Vec3
    fromZoom*, toZoom*, shownZoom*: float32

  Cmd* = object
    label*: string
    kind*: CmdKind
    objs*: seq[LevelObject]
    before*, after*: seq[string]
    indices*: seq[int]
    geoBefore*, geoAfter*: Geometry
    hasSel*: bool               ## Undo and redo put back selBefore / selAfter.
    selBefore*, selAfter*: SelState
    hasGroups*: bool            ## Undo and redo put back grpBefore / grpAfter.
    grpBefore*, grpAfter*: seq[Group]
    extra*: seq[Cmd]            ## Linked groups brought in line with this edit (done after it).
    projBefore*, projAfter*: ProjSettings   ## ckProject.
    visBefore*, visAfter*: VisState         ## ckVisibility.
    merge*: string              ## Widget whose further changes amend this step (see editProject).

  LogLine* = object
    text*: string
    error*: bool
    time*: float

  Issue* = object
    severity*: Severity
    text*: string
    time*: float                    ## When it was first found.
    obj*: LevelObject
    face*: int
    corner*: int = -1               ## Corner of face to put under the vertex tool.
    mcpPort*: bool                  ## The MCP server's port: clicking opens it in Settings.
    report*: string                 ## A crash report: clicking shows it in its folder.

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
    sound*: LevelObject             ## A Sound object's Class: rows get a preview button.
    soundField*: bool               ## A class's sound: the same, played at full volume.
    impulse*: bool                  ## That sound is an impulse.
    ambients*: bool                 ## It lists ambients: a row's right click can duplicate one.
    command*: proc()                ## Runs its command row (Import sound...).

  AmbientEdit* = ref object
    ## The ambient sound editor (File > Import > New ambient sound, File > Ambient sounds,
    ## or Duplicate as new ambient).
    amb*: CustomAmbient
    original*: string               ## The project's ambient being edited ("" = a new one).
    track*: AmbTrack                ## The track whose sounds show.
    addText*: string                ## The Add sound field.
    error*: string
    scroll*: float32
    pick*: proc(v: string)          ## The field it was opened from: gets a new ambient's name on Save.
    confirmDelete*: bool

  PieMenu* = object
    ## The render-mode pie (hold Z), after Blender's pie menus (pie.nim).
    open*: bool
    center*: Vec2                   ## Where it's drawn: the press point, moved to fit the window.
    init*: Vec2                     ## The press point.
    openedAt*: float                ## epochTime when it opened (spawn animation, tap timeout).
    clickStyle*: bool               ## Z was tapped: it stays open until a click.
    dragStyle*: bool                ## The mouse moved since it opened: releasing Z confirms.
    keyLock*: bool                  ## Closed with Z still down: it can't open again until Z comes up.
    hover*: int                     ## Item under the cursor's direction, -1 = none (in the center).

  NewKind* = enum           ## What the welcome screen's Create makes.
    nkScratch, nkCopy, nkPreview

  Load* = ref object
    ## A cache made in the background, one at a time, while the user works
    ## (they wait while a job the user started runs): the entity library,
    ## level 0's skies, particles, sounds and classes.
    key*: string                    ## "library", "sky", "particles", "sounds", "classes", "levels".
    title*: string
    make*: proc(): Job              ## When its turn comes; nil: nothing to do any more.
    done*: seq[proc()]              ## Run when it's made.
    job*: Job                       ## nil until it starts.

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
    texSizes*: Table[string, (int, int)]  ## Texture name -> width, height (filled with the thumbnails).
    texAlpha*: Table[string, bool]  ## Texture name -> has see-through pixels (filled with the thumbnails).
    densities*: Table[string, float32]
    views*: array[4, ViewPane]
    layout*: PaneLayout
    maximized*: int
    focus2D*: Vec3                  ## Linked 2D views: shared point and zoom.
    zoom2D*: float32
    flySpeed*: float32              ## 3D fly speed (units/s); wheel changes it while flying.
    winPos*, winSize*: IVec2        ## Window outer corner and content size when not maximized
    winMaximized*: bool             ## (winSize 0 = none saved yet).
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
    selBoxFaces*: seq[tuple[obj: LevelObject, face: int]]  ## Selected volume face handles.
    clipPoints*: seq[ClipPoint]
    clipFace*: seq[Vec3]            ## Clip along a double-clicked face: its corners (else empty).
    clipSide*: Side
    dock*: DockNode                 ## The panel layout (dock.nim).
    dockPress*: tuple[on: bool, kind: PanelKind, at: Vec2]  ## A press on a panel's tab.
    dockDragging*: bool             ## That tab is being dragged to another place.
    viewsArea*: Rect                ## The map views' area this frame (empty: Viewport not shown).
    log*: seq[LogLine]
    logDropped*: int                ## Lines trimmed off the top: a selection counts from the first ever.
    logAnchor*, logCaret*: (int, int)  ## Console selection: (line + logDropped, byte), caret moving.
    logWordStart*, logWord*: (int, int)  ## Double-click: the word's two ends.
    logDrag*: int                   ## The press selecting: its click count, else 0.
    logPressAt*: Vec2               ## Where it started.
    logLink*: (int, int)            ## A face link under that press (face, corner); face -1: none.
    issues*: seq[Issue]
    issuesTime*: float              ## When findIssues last ran (0: never).
    undoStack*, redoStack*: seq[Cmd]
    cleanAt*: int
    selRecorded*: SelState          ## Selection as of the last undo step (recordSelection).
    pushCount*, selSeenPush*: int   ## Commands pushed, and how many recordSelection has seen.
    mergeLive*: string              ## Widget still editing the last ckProject step ("" = none).
    musicUndone*: bool              ## Undo or redo changed the level's track: the preview follows.
    drag*: Drag
    job*: Job                       ## The job the user started (Build, a new project...).
    jobDone*: proc()
    loads*: seq[Load]               ## Caches being made while the user works: the first runs.
    soundAutoBuild*: bool           ## Level 0's sounds were extracted (or tried) unasked.
    buildAfterLoad*: int            ## Build (1) or Play (2) pressed while a load it needs ran.
    menuSys*: MenuSystem            ## Menu bar and context menu popups (their own windows).
    menuTree*: MenuNode             ## This frame's menu bar tree.
    menuOpenedAt*: float            ## When the open menus opened, else 0.
    focusLostAt*: float             ## When the window lost focus, else 0.
    settingsOpen*: bool
    mcpPortIssue*: string           ## Why the MCP server's port can't be used ("" = it can).
    crashReport*: string            ## Report of a crash in an earlier run, until the next launch.
    settingsPortMark*: bool         ## Settings outlines the port field (the issue was clicked).
    settingsSaved*: bool            ## Saved this frame: the MCP server follows (catwalk.nim).
    setupWin*: Window               ## Setup window (setupwin.nim): where Oni is, asked on the first run.
    setupSk*: Silky
    setupUi*: Ui
    setupAe*, setupGame*: string    ## Its fields.
    setupNote*: string              ## What Auto-detect found, or why Save refused.
    setupNoteBad*: bool
    mcpForced*: bool                ## --mcp-server: the server runs whatever the settings say.
    afterFrame*: seq[proc()]        ## Run once the views are drawn, before the buffers swap.
    pie*: PieMenu                   ## Render-mode pie menu (hold Z over the views).
    realtime*: bool                 ## Realtime preview: Sound objects play, light animations run.
    realtimeStart*: float           ## epochTime when it was turned on (the animations' clock).
    previewParts*: set[PreviewPart] ## What it plays (lights, sounds and particles by default; never empty).
    previewSoundVolume*: float      ## Its Sound objects' and the sound fields' previews' volume (Oni's 0..1; not the level's).
    previewMusicVolume*: float      ## Its level music's volume (Oni's 0..1; not the level's).
    realtimeMusic*: string          ## The level music it started ("" = none).
    particleSim*: ParticleSim       ## Its particles (particlesim.nim), while they're on.
    particleRestart*: bool          ## Start them all over next frame.
    particleClock*: float           ## epochTime of their last step.
    particlePlaying*: HashSet[SourceId]  ## Objects played from the particle panel: they run without Realtime preview.
    particlePlayNext*: seq[SourceId]     ## Play pressed: for updateParticles.
    particleHaltNext*: seq[SourceId]     ## Stop pressed: for updateParticles.
    particleLoop*: bool                  ## The panel's Loop.
    particleAutoBuild*: bool        ## Level 0's particles were extracted for it.
    particleLevelJob*: string       ## The oni folder whose decal textures were looked for.
    dupFlashAt*: float              ## When Ctrl+D last duplicated in place: the selection's lines flash white.
    sceneKey*: string               ## Realtime sound: "" (off), "extracting" (level 0's sounds) or "playing".
    windowTitle*: string            ## What updateWindowTitle last set.
    savePrompt*: proc()             ## Unsaved-changes prompt is up; runs this after Yes or No.
    quitConfirmed*: bool            ## The prompt (or a clean project) allowed the window to close.
    settingsEdit*: Config           ## The settings dialog's copy; the views preview it.
    settingsPage*: int              ## Settings dialog page: 0 General, 1 View, 2 Mouse.
    settingsFly*: float32           ## The dialog's copy of flySpeed.
    newName*: string
    newLevel*: int
    newKind*: NewKind               ## Welcome screen: from scratch, a copy of game level newLevel or a preview of it.
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
    texScroll*, entityScroll*, layersScroll*, propsScroll*, logScroll*, faceScroll*,
      issuesScroll*, levelScroll*: float32
    moveBy*: string
    rotateAngle*: float
    scaleBy*: string
    brushHeight*: float             ## Depth of a brush drawn in 2D before anything was selected.
    clipboard*: seq[string]
    clipboardGeo*: Geometry
    faceClip*: FaceAttr               ## Ctrl+C with faces selected: the last one's look, for Ctrl+Shift+V.
    hasFaceClip*: bool
    lastTime*: float
    texFrames*: Table[int, TexFrame] ## Face tab: selected faces' texture mappings,
    texFramesFor*: tuple[geo: Geometry, version: int, faces: seq[int]]  ## valid for this geometry and selection.
    faceUndo*: tuple[label: string, geo: Geometry, version, depth: int, faces: seq[int]]
                                    ## Last live Face tab edit; more of the same merge into its undo step.
    shade*: array[3, float]
    vertShade*: array[3, float]     ## Entity tab: the selected corners' vertex color.
    openDropdown*: string           ## Id of the open dropdown list, if any.
    dropdownHi*: int                ## Its row picked with the keyboard (-1: none).
    ## Keyboard cursors of the lists that are one Tab stop each.
    layersCursor*, entityCursor*, texCursor*, logCursor*, issuesCursor*, projectCursor*,
      levelCursor*: int
    savePointList*: seq[int]        ## Save points the level's scripts handle.
    press*: Press
    rmbPress*: Press                ## Right button: a click opens the context menu.
    lastClick*: tuple[time: float, pos: Vec2, view: int]
    lastSel*: tuple[ok: bool, lo, hi: Vec3]  ## Bounds of the latest selection (new brush depth).
    extrudeHover*: int              ## Face Shift+drag would extrude, or -1.
    extrudeHoverFaces*: seq[int]    ## It and the selection's other faces on its plane.
    cutHover*: seq[(int, Vec3, Vec3)] ## The edges Ctrl+Shift+drag would cut from or extend.
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
    entityBrowserH*: float32        ## Classes page: the class list's height.
    classListFolded*: bool          ## Classes page: the class list is down to its title.
    classFolded*: HashSet[string]   ## Classes page: folded headings ("c:" or "p:" and the path), for every class.
    splitDrag*: string              ## Divider being dragged.
    splitGrab*: float32
    hintScroll*: float32
    hintScrollKey*: string
    expanded*: HashSet[string]      ## Open layers in the Map tab tree.
    treeAnchor*: int                ## Shift+click range start in the layer tree.
    ctx*: CtxMenu
    fileCache*: FileCache           ## Files tab: folder listings.
    filesOpen*: HashSet[string]     ## Files tab: expanded folders (relative paths).
    filesSel*: string               ## Files tab: the selected path (relative).
    filesFilter*: string
    filesScroll*: float32
    filesCursor*: int
    frameNo*: int
    texUsedOnly*: bool
    texAlphaOnly*: bool             ## Texture Browser: only textures with see-through pixels.
    texThumb*: float32              ## Texture browser tile size (pixels); Ctrl+wheel zooms it.
    codeFontSize*: int              ## Scripts editor text size (one of CodeFontSizes); Ctrl+wheel zooms it.
    showObjectNames*: bool
    browserPress*: (int, Vec2)      ## Entity browser: preset pressed (-1 = none) and where.
    presets*: seq[Preset]           ## Entity browser: built in, then the library's.
    catalog*: Catalog               ## Entity tab: values each field accepts.
    soundObj*: LevelObject          ## Sound object whose ambient the preview plays.
    soundClass*: string             ## soundObj's Class when its preview started or last followed it.
    drop*: FieldDrop
    soundImportPick*: proc(v: string)   ## The sound field whose Import sound... dialog is open.
    browserOpen*: HashSet[string]   ## Entity browser: expanded groups.
    entityFilter*: string
    entityPreview*: float           ## Entity browser preview size: 0 = list, up to 1, in steps of 1/8.
    previewStamp: string            ## Library build the loaded previews are from.
    previewTried: HashSet[string]   ## Preview atlas keys loaded or missing.
    previewAutoBuild*: bool         ## The entity library was built for missing previews.
    skyAutoBuild*: bool             ## The sky images were extracted for the 3D view.
    fieldFilter*: string            ## Entity tab: only the fields matching it show.
    classFilter*: string            ## Classes page: only the classes matching it show.
    ctxPending*: bool               ## ctx is set: its menu opens after this frame's menu update.
    classXml*: bool                 ## Classes page: the open class shows as its XML.
    classXmlDrafts*: Table[string, ClassXmlDraft]   ## The XML view's text by class, until applied.
    classFieldFilter*: string       ## Classes page: only the class fields matching it show.
    className*: string              ## Classes page: the class shown ("" = none); a particle class has ParticlePrefix.
    classParticles*: bool           ## Classes page: the Particles side is up.
    classOther*: string             ## The class shown on the other side.
    particleClasses*: seq[string]   ## Classes page: level 0's particle classes.
    particleEditStamp*: (int, int, int)  ## The undo state particleSim's edited classes are from.
    particleEditKey*: string        ## Those classes' XML.
    classFor*: LevelObject          ## The character whose class the page followed last.
    classes*: Table[string, LevelObject]  ## Classes opened since the project was (undo points at them).
    classOrig*: Table[string, string]     ## Level 0's version of each of them (snapshot).
    classOnDisk*: HashSet[string]   ## Classes the project's classes/ changes, read once.
    classOnDiskRead*: bool
    classMarks*: HashSet[string]    ## Edited classes as of classMarkStamp.
    classMarkStamp*: (int, int, int)
    classTrail*: seq[string]        ## Classes page: the open particle class's ancestors, outermost first.
    level0Spawns*: Table[string, seq[string]]  ## What level 0's particle classes spawn (read once).
    classParentMap*: Table[string, seq[string]]  ## Every particle class's parents as of classParentStamp.
    classParentStamp*: (int, int, int)
    classText*: Table[string, string]
    classTextFor*: LevelObject
    classAsText*: HashSet[string]   ## Color fields shown as text, to name a variable.
    classScroll*, classListScroll*: float32
    classCursor*: int
    classAutoBuild*: bool           ## Level 0's classes were extracted (or tried) unasked.
    classList*: seq[string]         ## Level 0's class names (from the class cache).
    bakeKey*: string                ## Lights, ambient and geometry version as of the last bake.
    bakeAt*, bakeTook*: float       ## When the last automatic bake ran, and how long it took.
    groups*: seq[Group]
    groupsRecorded*: seq[Group]     ## Groups as of the last undo step.
    openGroups*: seq[int32]         ## Opened groups, outermost first (TrenchBroom's current group).
    openSet*: HashSet[int32]        ## The innermost open group and the groups inside it.
    linkSigs*: Table[int32, LinkSig] ## Linked groups as of the last sync.
    namePrompt*: proc(name: string) ## Group name prompt is up; runs this after OK.
    namePromptTitle*, namePromptText*: string
    skyImportDir*: string           ## The sky folder popup is up for this folder ("" = closed).
    skyImportFiles*: seq[string]    ## Its pictures.
    skyImportSides*: seq[int]       ## Index into SkySides per picture, -1 = not used.
    skyImportTurns*: seq[int]       ## Quarter turns clockwise per picture, -1 = from the edges.
    skyImportFit*: SkyFit           ## Their edges, nil when one couldn't be read.
    skyImportScroll*: float32
    skyConvertOpen*: bool           ## Run > Add-Ons > Skybox Converter is up.
    ambientEdit*: AmbientEdit       ## The ambient sound editor, nil when closed.
    skyConvertFile*: string         ## Its source picture.
    skyConvertKind*: SkySource
    skyConvertUse*: bool            ## Its Use skybox toggle.
    skyConvertError*: string
    skyConvertShown*: string        ## The picture the preview was last looked up for.
    skyPreviews*: Table[string, tuple[w, h: int, srcW, srcH: int]]
      ## Picture path -> preview (in pixels on screen) and picture sizes; the preview is
      ## atlas entry "skysrc:<path>".
    scripts*: ScriptEditor          ## Scripts panel: open script files and its state (scriptpanel.nim).
    mapReveal*: LevelObject         ## The Map tab scrolls to this object's row next frame.
    mapSeen*: SelState              ## Selection as of the Map tab's last frame: a change means
                                    ## it was made elsewhere, and the tab jumps to it.
    groupPicked*: int32             ## Group whose row was clicked in the Map tab (Properties shows it).
    groupNameText*: string          ## Properties' group name while it's typed.
    groupSpinText*: string          ## Properties' group spin while it's typed.
    camAnim*: CamAnim
    texCollections*: seq[TexCollection]  ## Every collection there is (refreshCollections).
    texGroup*: bool                 ## Texture Browser: headed by collection (TrenchBroom's Group).
    collAvailable*, collEnabled*: HashSet[string]  ## Texture Collections: selected rows.
    collScroll*: array[2, float32]  ## ...and their lists' scroll.
    showDirections*: bool           ## Entities show where they point.
    showGizmos*: bool               ## Entities draw their gizmos (boxes, light shapes, arrows, volumes).
    gizmoHidden*: HashSet[string]   ## Object types left out of them (right click the Gizmos button).
    showEditorOnly*: bool           ## The Editor-only button: Invisible faces and objects' Notes...
    editorOnlyParts*: set[EditorOnlyPart]  ## ...which of them (never empty).
    notesRange*: float32            ## How far from the 3D camera objects' Notes start to show.

# --- basics -------------------------------------------------------------------------------

proc hash*(o: LevelObject): Hash = hash(cast[pointer](o))

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
  logLine(msg, error)
  if a.log.len > 2000:
    a.log.delete(0)
    inc a.logDropped

proc busy*(a: App): bool = a.job != nil and a.job.state == jsRunning

proc loading*(a: App, key: string): bool =
  ## Whether the cache key names (see Load) is being made or waits its turn.
  for l in a.loads:
    if l.key == key: return true

proc loadState*(l: Load): string =
  ## "Building the entity library (12/31)", or "... (waiting)" before it starts.
  if l.job == nil: return l.title & " (waiting)"
  let (done, all) = l.job.progressCount
  &"{l.title} ({done}/{all})"

proc loadingText*(a: App, key: string): string =
  for l in a.loads:
    if l.key == key: return l.loadState

proc isModification(c: Cmd): bool = c.kind notin {ckSelect, ckVisibility, ckProject}

proc dirty*(a: App): bool =
  # Selection steps between the saved state and now don't count.
  let n = a.undoStack.len
  if a.cleanAt < 0: return true
  if n >= a.cleanAt:
    for i in a.cleanAt ..< n:
      if a.undoStack[i].isModification: return true
  else:
    let k = a.cleanAt - n
    if k > a.redoStack.len: return true
    for i in a.redoStack.len - k ..< a.redoStack.len:
      if a.redoStack[i].isModification: return true
  if a.geo != nil and a.geo.version != a.geoSavedVersion: return true
  for f in a.files:
    if f.dirty: return true
  if a.scripts.anyDirty: return true

proc defaultFov*(a: App): float32 =
  ## The 3D view's field of view from the preferences (radians).
  a.cfg.fov.float32.degToRad

proc setupOpen*(a: App): bool = a.setupWin != nil and a.setupWin.visible

proc modalOpen*(a: App): bool = a.setupOpen or a.settingsOpen or a.savePrompt != nil or a.namePrompt != nil or a.skyConvertOpen or a.skyImportDir.len > 0 or a.ambientEdit != nil

proc toggleRealtime*(a: App) =
  ## Realtime preview: Sound objects play (panels.updateRealtime) and the
  ## corners' light animations run in the views, from 0 s when turned on.
  a.realtime = not a.realtime
  a.realtimeStart = epochTime()

proc togglePreviewPart*(a: App, p: PreviewPart) =
  ## Turns one of Realtime preview's parts on or off. Turning off the last one
  ## ends the preview and leaves Animated lighting on.
  if p in a.previewParts: a.previewParts.excl p else: a.previewParts.incl p
  if a.previewParts == {}:
    a.previewParts = {ppLights}
    if a.realtime: a.toggleRealtime()

const
  MinNotesRange* = 100'f32       ## The Editor-only menu's Notes distance bar: its ends...
  MaxNotesRange* = 2100'f32
  NotesRangeStep* = 100'f32      ## ...and its steps (the menu slider's 5 %).
  DefaultNotesRange* = 600'f32

proc showInvisible*(a: App): bool =
  ## Faces flagged Invisible are drawn (and can be clicked).
  a.showEditorOnly and eoInvisible in a.editorOnlyParts

proc showNotes*(a: App): bool =
  ## Objects' Notes float over them in the 3D view.
  a.showEditorOnly and eoNotes in a.editorOnlyParts

proc switchEditorOnly*(a: App) =
  ## The Editor-only button: on or off.
  a.showEditorOnly = not a.showEditorOnly
  if a.geo != nil: a.geo.bump()

proc toggleEditorOnlyPart*(a: App, p: EditorOnlyPart) =
  ## Shows or hides one of the Editor-only things. Hiding the last one turns
  ## the button off and leaves that one on.
  if p in a.editorOnlyParts: a.editorOnlyParts.excl p else: a.editorOnlyParts.incl p
  if a.editorOnlyParts == {}:
    a.editorOnlyParts = {p}
    a.showEditorOnly = false
  if a.geo != nil: a.geo.bump()

proc toggleGizmoKind*(a: App, tag: string) =
  ## Shows or hides one object type's gizmos. Hiding the last type turns the
  ## gizmos off and leaves that type on.
  if tag in a.gizmoHidden: a.gizmoHidden.excl tag else: a.gizmoHidden.incl tag
  if Categories.allIt(it.tags.allIt(it in a.gizmoHidden)):
    a.gizmoHidden.excl tag
    a.showGizmos = false

proc whenSaved*(a: App, action: proc()) =
  ## Runs action now, or after asking whether to save the open project's changes.
  ## A preview's changes are never kept, so it doesn't ask.
  if a.proj != nil and a.dirty and not a.proj.preview:
    a.savePrompt = action
    a.ui.navId = ""  # Keys go to the prompt, not a widget behind it.
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
  a.selBoxFaces.setLen 0

proc currentSel*(a: App): SelState =
  SelState(objs: a.selection, pieces: a.selPieces, faces: a.selFaces, lastFace: a.lastFace)

proc sameSel*(x, y: SelState): bool =
  if x.pieces != y.pieces or x.faces != y.faces or x.objs.len != y.objs.len: return false
  if x.objs == y.objs: return true   # selection lists objects in level order
  for o in x.objs:
    if o notin y.objs: return false
  true

proc setSel*(a: App, s: SelState) =
  ## Puts back a selection; pieces and faces the geometry no longer has are dropped.
  for o in a.objects: o.selected = o in s.objs
  a.selPieces.clear()
  a.selFaces.clear()
  if a.geo != nil:
    for p in s.pieces:
      if p in 0'i32 .. a.geo.pieces.high.int32: a.selPieces.incl p
    for f in s.faces:
      if f in 0 .. a.geo.faces.high: a.selFaces.incl f
  a.lastFace = s.lastFace

proc visible*(a: App, o: LevelObject): bool =
  not o.hidden and o.tag notin a.layerHidden

proc entityGizmo*(a: App, o: LevelObject): bool =
  ## Whether o draws its gizmo. A selected object always does, or it couldn't be seen.
  o.selected or (a.showGizmos and o.tag notin a.gizmoHidden)

proc particleSpins(a: App): Table[int, SpinGroup] =
  ## The spinning groups, by the ids of their Particle objects.
  if a.groups.allIt(it.spin == 0): return
  var parent = initTable[int32, int32]()
  var spin = initTable[int32, float32]()
  var members: seq[SpinMember]
  for g in a.groups:
    parent[g.id] = g.parent
    spin[g.id] = g.spin
    for o in g.objs:
      if o.tag == "PART": members.add (o.id, g.id, o.pos)
  for s in collectSpins(if a.geo != nil: a.geo else: Geometry(), parent, spin, members):
    for id in s.particles: result[id] = s

proc particleSource(a: App, o: LevelObject, nth: int): ParticleSource =
  let cls = o.node.xpath("OSD/Class").str.strip
  let flags = try: parseInt(o.node.xpath("OSD/Flags").str.strip) except ValueError: 0
  let ds = strutils.splitWhitespace(o.node.xpath("OSD/DecalScale").str)
  var decal = vec2(1, 1)
  if ds.len == 2:
    try: decal = vec2(parseFloat(ds[0]), parseFloat(ds[1]))
    except ValueError: discard
  let started = o.node.xpath("OSD/Tag").str.strip == AutoStartTag
  let m = objectMatrix(vec3(0, 0, 0), o.rot)
  ParticleSource(id: (o.id, nth), cls: cls, pos: o.pos, flags: flags, decalScale: decal,
    started: started,
    axes: [(m * vec3(1, 0, 0)).normalize, (m * vec3(0, 1, 0)).normalize, (m * vec3(0, 0, 1)).normalize])

proc particleSources*(a: App, only: seq[LevelObject] = @[]): seq[ParticleSource] =
  ## The visible Particle objects, or those of them in only.
  var nth: Table[int, int]
  let spins = a.particleSpins
  for o in a.objects:
    if o.tag != "PART" or not a.visible(o): continue
    nth.mgetOrPut(o.id, -1).inc
    if only.len == 0 or o in only:
      var src = a.particleSource(o, nth[o.id])
      if o.id in spins:
        src.spin = spins[o.id].seconds
        src.pivot = spins[o.id].center
      result.add src

# --- groups: membership and locking ----------------------------------------------------------

proc groupAt*(a: App, id: int32): int =
  ## Index of group id in a.groups, or -1.
  if id == 0: return -1
  for i, g in a.groups:
    if g.id == id: return i
  -1

proc objGroup*(a: App, o: LevelObject): int32 =
  ## The group o is directly in, or 0.
  for g in a.groups:
    if o in g.objs: return g.id

proc pieceGroup*(a: App, pc: int32): int32 =
  if a.geo == nil or pc < 0 or pc >= a.geo.pieces.len: 0'i32 else: a.geo.pieces[pc].group

proc refreshOpenSet*(a: App) =
  ## Drops opened groups that no longer exist (undo), then which groups are
  ## inside the innermost open one.
  var k = 0
  while k < a.openGroups.len and a.groupAt(a.openGroups[k]) >= 0: inc k
  a.openGroups.setLen k
  a.openSet.clear()
  if k == 0: return
  a.openSet.incl a.openGroups[^1]
  var grew = true
  while grew:
    grew = false
    for g in a.groups:
      if g.parent in a.openSet and g.id notin a.openSet:
        a.openSet.incl g.id
        grew = true

proc groupLocked*(a: App, gid: int32): bool =
  ## Whether things directly in group gid are outside the open group (TrenchBroom
  ## locks everything but the open group's contents).
  a.openGroups.len > 0 and gid notin a.openSet

proc unitOf*(a: App, gid: int32): int32 =
  ## What a click on a thing directly in group gid selects: the outermost
  ## closed group around it (0 = the thing itself).
  result = 0
  var g = gid
  var guard = 0
  while g != 0 and g notin a.openGroups and guard < 1000:
    result = g
    let i = a.groupAt(g)
    g = if i >= 0: a.groups[i].parent else: 0
    inc guard

proc pieceLocked*(a: App, pc: int32): bool = a.groupLocked(a.pieceGroup(pc))

proc look*(o: LevelObject): tuple[half: Vec3, lift: float32, col: array[4, uint8]]

var objEpoch = 0   ## Bumped by every edit, undo, redo and project load.

type ObjInfo = object
  ## What an object's box comes from in its data, kept until it changes (see
  ## objInfo): picking and drawing ask for every object every frame.
  epoch, models: int               ## objEpoch and library.modelEpoch when made; models 0 = empty.
  hasModel: bool
  lo, hi: Vec3                     ## The model's bounds in object space.
  half: Vec3                       ## The marker box's, without a model.
  lift: float32

var objInfos: Table[LevelObject, ObjInfo]

proc objInfo(o: LevelObject): ObjInfo =
  ## o's ObjInfo, made again after an edit (any undo step), undo, redo, a
  ## project load or a library build.
  let epoch = objEpoch
  let models = modelEpoch + 1
  objInfos.withValue(o, c):
    if c.epoch == epoch and c.models == models: return c[]
  if objInfos.len > 0:
    # Entries of an older epoch go together.
    for v in objInfos.values:
      if v.epoch != epoch or v.models != models:
        objInfos.clear()
      break
  result = ObjInfo(epoch: epoch, models: models)
  let (ok, m) = o.objectModel
  if ok: (result.hasModel, result.lo, result.hi) = (true, m.lo, m.hi)
  let l = o.look
  (result.half, result.lift) = (l.half, l.lift)
  objInfos[o] = result

proc hasModel*(o: LevelObject): bool =
  ## Whether the library has a model for o (objectModel's first value, kept).
  o.objInfo.hasModel

proc objectsChanged*() =
  ## Forgets the kept object data: objects were edited outside push, undo
  ## and redo (those forget it themselves).
  inc objEpoch

proc pickable*(a: App, o: LevelObject): bool =
  a.visible(o) and o.tag notin a.layerLocked and not a.groupLocked(a.objGroup(o))

proc viewPickable*(a: App, o: LevelObject): bool =
  ## Whether a click in a view can hit o: there has to be something to click.
  a.pickable(o) and (a.entityGizmo(o) or (a.opts.models and o.hasModel))

proc geometryVisible*(a: App): bool = a.geo != nil and GeometryLayer notin a.layerHidden
proc geometryEditable*(a: App): bool = a.geometryVisible and GeometryLayer notin a.layerLocked

proc faceVisible*(a: App, fi: int): bool =
  let f = a.geo.faces[fi]
  if f.piece >= 0 and f.piece < a.geo.pieces.len and a.geo.pieces[f.piece].hidden: return false
  if f.isMarkerFace and not a.opts.markers: return false
  if f.isInvisibleFace and not a.showInvisible: return false
  true

# --- objects and their geometry ------------------------------------------------------------

proc objectCode*(o: LevelObject): int32 =
  ## The ObjectId the level's geometry uses for this object, or -1.
  let t = GunkTypes.getOrDefault(o.tag, 0)
  if t == 0: -1'i32 else: int32((t shl 24) or (o.id and 0xffffff))

proc facePickable*(a: App): proc(fi: int): bool =
  ## Faces a click can hit: the visible ones, plus selected faces that are only
  ## hidden as marker or invisible faces (they're still drawn highlighted).
  var codes: HashSet[int32]
  for o in a.objects:
    if o.selected and o.objectCode != -1: codes.incl o.objectCode
  let app = a
  let locking = a.openGroups.len > 0
  result = proc(fi: int): bool =
    if locking and app.geo.faces[fi].objectId == -1 and app.pieceLocked(app.geo.faces[fi].piece):
      return false
    if app.faceVisible(fi): return true
    let f = app.geo.faces[fi]
    if f.piece >= 0 and f.piece < app.geo.pieces.len and app.geo.pieces[f.piece].hidden: return false
    fi in app.selFaces or f.piece in app.selPieces or f.objectId in codes

var pieceBox: seq[(Vec3, Vec3)]
var pieceBoxGeo: Geometry
var pieceBoxVersion = -1

proc piecesHit*(a: App, r: Ray): seq[bool] =
  ## Per piece, whether r passes through its bounds: a ray's faces are only
  ## looked for in those (a level has tens of thousands). The bounds are kept
  ## until the geometry changes.
  if a.geo == nil: return
  let g = a.geo
  if pieceBoxGeo != g or pieceBoxVersion != g.version or pieceBox.len != g.pieces.len:
    pieceBox = newSeq[(Vec3, Vec3)](g.pieces.len)
    for b in pieceBox.mitems: b = (vec3(Inf.float32), vec3(-Inf.float32))
    for f in g.faces:
      if f.piece notin 0 ..< pieceBox.len.int32: continue
      for v in f.verts:
        pieceBox[f.piece][0] = min(pieceBox[f.piece][0], g.points[v])
        pieceBox[f.piece][1] = max(pieceBox[f.piece][1], g.points[v])
    pieceBoxGeo = g
    pieceBoxVersion = g.version
  result = newSeq[bool](pieceBox.len)
  const pad = vec3(0.01, 0.01, 0.01)   # flat pieces have no thickness
  for i, (lo, hi) in pieceBox:
    result[i] = lo.x <= hi.x and r.rayBox(lo - pad, hi + pad) >= 0

proc facePickable*(a: App, vi: int, r: Ray): proc(fi: int): bool =
  ## The same for ray r in view vi, which also passes through back faces where
  ## the view culls them (render.drawView), so a camera inside a wall picks
  ## what it sees past the wall. Only faces of pieces the ray goes through.
  let pickable = a.facePickable
  let hit = a.piecesHit(r)
  let app = a
  if a.views[vi].cam.kind != vk3D or a.opts.mode.wireframe:
    return proc(fi: int): bool =
      let p = app.geo.faces[fi].piece
      p in 0 ..< hit.len.int32 and hit[p] and pickable(fi)
  result = proc(fi: int): bool =
    let p = app.geo.faces[fi].piece
    if p notin 0 ..< hit.len.int32 or not hit[p] or not pickable(fi): return false
    let f = app.geo.faces[fi]
    (f.flags and gfTwoSided) != 0 or f.isMarkerFace or f.isInvisibleFace or
      app.geo.normal(f).dot(r.dir) < 0

proc ownerOf*(a: App, objectId: int32): LevelObject =
  if objectId == -1: return nil
  for o in a.objects:
    if o.objectCode == objectId: return o

var objFaceIndex: Table[int32, seq[int]]
var objFaceGeo: Geometry
var objFaceVersion = -1

proc ownedFaces*(a: App, o: LevelObject): seq[int] =
  ## The level geometry's faces o owns (its ObjectId), from an index kept
  ## until the geometry changes: a level has tens of thousands of faces.
  let code = o.objectCode
  if code == -1 or a.geo == nil: return
  if objFaceGeo != a.geo or objFaceVersion != a.geo.version:
    objFaceIndex.clear()
    for i, f in a.geo.faces:
      if f.objectId != -1: objFaceIndex.mgetOrPut(f.objectId, @[]).add i
    objFaceGeo = a.geo
    objFaceVersion = a.geo.version
  objFaceIndex.getOrDefault(code)

proc hasGeometry*(a: App, o: LevelObject): bool = a.ownedFaces(o).len > 0

proc setPose*(a: App, o: LevelObject, pos, rot: Vec3, moveGeometry = true) =
  ## Moves an object and the level geometry it owns.
  if moveGeometry and a.geo != nil and o.objectCode != -1 and (pos != o.pos or rot != o.rot):
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
  of PointLightTag, SpotLightTag, DirLightTag:
    let c = strutils.splitWhitespace(o.node.xpath("OSD/Color").str)
    var col = rgba(255, 236, 210)
    if c.len == 3:
      try: col = rgba(clamp(parseInt(c[0]), 0, 255), clamp(parseInt(c[1]), 0, 255),
                      clamp(parseInt(c[2]), 0, 255))
      except ValueError: discard
    let half = if o.tag == DirLightTag: vec3(5, 5, 5) elif o.tag == SpotLightTag: vec3(3, 3, 3)
               else: vec3(2, 2, 2)
    (half, 0'f32, col)
  else: (vec3(2, 2, 2), 0'f32, rgba(200, 200, 200))

proc corners*(o: LevelObject): array[8, Vec3] =
  ## The object's box: its model's bounds, or else its marker box.
  let c = o.objInfo
  if c.hasModel:
    let t = objectMatrix(o.pos, o.rot)
    var i = 0
    for x in [c.lo.x, c.hi.x]:
      for y in [c.lo.y, c.hi.y]:
        for z in [c.lo.z, c.hi.z]:
          result[i] = t * vec3(x, y, z)
          inc i
    return
  if o.tag == "PART":
    # Particles turn about all three axes (an emitter's direction is its local +Y).
    let t = objectMatrix(o.pos, o.rot)
    for i, k in boxCorners(vec3(0, c.lift, 0), c.half, 0): result[i] = t * k
    return
  boxCorners(o.pos + vec3(0, c.lift, 0), c.half, o.rot.y)

proc lightBall*(o: LevelObject): float32 =
  ## Lights pick by their gizmo's ball (0: not a light). A point light's is
  ## exactly its ball, so brushes next to it stay clickable.
  case o.tag
  of PointLightTag: PointBall
  of SpotLightTag: SpotBall
  of DirLightTag: SunBall
  else: 0

proc pickBox*(o: LevelObject): (Vec3, Vec3) =
  let ball = o.lightBall
  if ball > 0: return (o.pos - vec3(ball), o.pos + vec3(ball))
  let k = o.corners
  var lo = k[0]
  var hi = k[0]
  for p in k:
    lo = min(lo, p)
    hi = max(hi, p)
  (lo - vec3(1, 1, 1), hi + vec3(1, 1, 1))

proc pickRay*(o: LevelObject, r: Ray): float32 =
  ## Distance along the ray to the object's pick shape, or -1.
  let ball = o.lightBall
  if ball > 0: return r.raySphere(o.pos, ball)
  let (lo, hi) = o.pickBox
  r.rayBox(lo, hi)

proc pickRay*(o: LevelObject, r: Ray, box: (Vec3, Vec3)): float32 =
  ## pickRay with o.pickBox worked out already.
  let ball = o.lightBall
  if ball > 0: return r.raySphere(o.pos, ball)
  r.rayBox(box[0], box[1])

proc pointing*(o: LevelObject): (bool, Vec3) =
  ## The way an object faces, for those that have one: a character's and a
  ## flag's facing is their Y rotation (Oni: sin, 0, cos), a turret aims along
  ## its local +Z, a particle emits along its local +Y.
  case o.tag
  of "CHAR", "NEUT", "FLAG":
    let ang = o.rot.y.float64.degToRad
    (true, vec3(sin(ang).float32, 0, cos(ang).float32))
  of "TURR":
    let t = objectMatrix(vec3(0, 0, 0), o.rot)
    (true, (t * vec3(0, 0, 1)).normalize)
  of "PART":
    let t = objectMatrix(vec3(0, 0, 0), o.rot)
    (true, (t * vec3(0, 1, 0)).normalize)
  else: (false, vec3(0, 0, 0))

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

proc volumeTurn*(o: LevelObject): Mat4 =
  ## How the object's volume is turned around its position: the game rotates a
  ## trigger volume with the object, a sound's Box stays on the world axes.
  if o.tag == "TRGV": objectMatrix(vec3(0, 0, 0), o.rot) else: mat4()

proc volumeRange*(o: LevelObject): (bool, Vec3, Vec3) =
  ## The object's volume in its own axes, relative to its position.
  let (has, a, b) = o.extentBox
  if not has: return
  let (lo, hi) = (a - o.pos, b - o.pos)
  (true, min(lo, hi), max(lo, hi))

proc volumeCorners*(o: LevelObject, lo, hi: Vec3): array[8, Vec3] =
  ## World corners of a volumeRange.
  let half = (hi - lo) / 2
  result = boxCorners((lo + hi) / 2, half, 0)
  let turn = o.volumeTurn
  for p in result.mitems: p = o.pos + turn * p

proc setVolumeRange*(a: App, o: LevelObject, base, lo, hi: Vec3) =
  ## Gives o the volume lo .. hi around base, its position when lo and hi were
  ## measured. A trigger volume starts at its position, so its Min side moves it.
  case o.tag
  of "SNDG":
    let (bmin, bmax) = (o.node.xpath("OSD/Box/Min"), o.node.xpath("OSD/Box/Max"))
    if bmin == nil or bmax == nil: return
    bmin.setText(fmtVec3(lo))
    bmax.setText(fmtVec3(hi))
  of "TRGV":
    let size = o.node.xpath("OSD/Size")
    if size == nil: return
    size.setText(fmtVec3(hi - lo))
    a.setPose(o, base + o.volumeTurn * lo, o.rot, moveGeometry = false)
  else: return
  o.file.dirty = true

# --- undo ----------------------------------------------------------------------------------

proc trimGeometryUndo(a: App) =
  var n = 0
  for i in countdown(a.undoStack.high, 0):
    if a.undoStack[i].geoBefore != nil:
      inc n
      if n > MaxGeometryUndo:
        a.undoStack[i].geoBefore = nil
        a.undoStack[i].geoAfter = nil
        for e in a.undoStack[i].extra.mitems:
          e.geoBefore = nil
          e.geoAfter = nil

proc syncLinkedGroups(a: App, c: var Cmd)
proc storeLinkSigs(a: App)

proc captureGroups(a: App, c: var Cmd) =
  ## The command remembers what the groups were before and after it.
  if a.groups != a.groupsRecorded:
    if not c.hasGroups: c.grpBefore = a.groupsRecorded
    c.hasGroups = true
    c.grpAfter = a.groups
    a.groupsRecorded = a.groups

proc showCrashReport*(a: App) =
  ## At launch: says so if an earlier run crashed.
  let report = unseenCrash()
  if report.len == 0: return
  a.crashReport = report
  a.issues.add Issue(severity: sevError, text: CrashIssue, time: epochTime(), face: -1, report: report)
  a.say("Catwalk crashed in an earlier run. Report: " & report, true)

proc push*(a: App, c: Cmd) =
  var c = c
  if c.isModification: logLine("Edit: " & c.label)
  if c.isModification: a.syncLinkedGroups(c)
  a.captureGroups(c)
  if a.cleanAt > a.undoStack.len:
    # The saved state is in the redo stack, which goes: still clean only if
    # everything undone since then was selection.
    let k = a.cleanAt - a.undoStack.len
    var gone = k > a.redoStack.len
    if not gone:
      for i in a.redoStack.len - k ..< a.redoStack.len:
        if a.redoStack[i].isModification: gone = true
    a.cleanAt = if gone: -1 else: a.undoStack.len
  a.undoStack.add c
  a.redoStack.setLen 0
  inc a.pushCount
  inc objEpoch
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

proc projSettings*(p: Project): ProjSettings =
  ProjSettings(title: p.title, sky: p.sky, music: p.music, musicVolume: p.musicVolume,
               autoBake: p.autoBake, ambient: p.ambient, softShadows: p.softShadows, skyGrade: p.skyGrade)

proc editProject*(a: App, label: string, before: ProjSettings, merge = "") =
  ## After a change to the level's settings: saves them and leaves an undo
  ## step. Further changes from the same widget while it's still focused or
  ## dragged (merge = its id) amend that step, so typing a name is one step.
  let after = a.proj.projSettings
  if after == before: return
  a.proj.save()
  if merge.len > 0 and merge == a.mergeLive and a.redoStack.len == 0 and a.undoStack.len > 0 and
     a.undoStack[^1].kind == ckProject and a.undoStack[^1].merge == merge:
    if after == a.undoStack[^1].projBefore:
      # Edited back to where it started: no step left.
      discard a.undoStack.pop
      a.cleanAt = min(a.cleanAt, a.undoStack.len)
    else:
      a.undoStack[^1].projAfter = after
  else:
    a.push Cmd(label: label, kind: ckProject, merge: merge, projBefore: before, projAfter: after)
  a.mergeLive = merge

proc endMerge*(a: App) =
  ## Once a frame: a widget that let go (lost focus, drag released) ends its step.
  if a.mergeLive.len > 0 and a.ui.focusId != a.mergeLive and a.ui.activeId != a.mergeLive:
    a.mergeLive = ""

proc visState*(a: App): VisState =
  for o in a.objects:
    if o.hidden: result.objs.add o
  if a.geo != nil:
    for i, p in a.geo.pieces:
      if p.hidden: result.pieces.incl i.int32
  result.layers = a.layerHidden
  result.locked = a.layerLocked

proc sameVis(x, y: VisState): bool =
  if x.pieces != y.pieces or x.layers != y.layers or x.locked != y.locked or
     x.objs.len != y.objs.len: return false
  for o in x.objs:
    if o notin y.objs: return false
  true

proc setVis(a: App, s: VisState) =
  var hidden: HashSet[pointer]
  for o in s.objs: hidden.incl cast[pointer](o)
  for o in a.objects:
    o.hidden = cast[pointer](o) in hidden
  if a.geo != nil:
    for i in 0 ..< a.geo.pieces.len: a.geo.pieces[i].hidden = i.int32 in s.pieces
    a.geo.bump()
  a.layerHidden = s.layers
  a.layerLocked = s.locked

proc pushVisibility*(a: App, label: string, before: VisState) =
  ## After hiding, showing, locking or unlocking: one undo step, if anything changed.
  let after = a.visState
  if not sameVis(before, after):
    a.push Cmd(label: label, kind: ckVisibility, visBefore: before, visAfter: after)

proc removeFromList(a: App, o: LevelObject) =
  let i = a.objects.find(o)
  if i >= 0: a.objects.delete(i)

proc applyCmd(a: App, c: Cmd, undo: bool) =
  if undo:
    for i in countdown(c.extra.high, 0): a.applyCmd(c.extra[i], true)
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
  of ckProject:
    let p = a.proj
    let s = if undo: c.projBefore else: c.projAfter
    if s.music != p.music: a.musicUndone = true
    elif s.musicVolume != p.musicVolume: setMusicVolume(s.musicVolume)
    (p.title, p.sky, p.music, p.musicVolume, p.autoBake, p.ambient, p.softShadows, p.skyGrade) =
      (s.title, s.sky, s.music, s.musicVolume, s.autoBake, s.ambient, s.softShadows, s.skyGrade)
    p.save()
  of ckVisibility: a.setVis(if undo: c.visBefore else: c.visAfter)
  of ckGeometry, ckSelect: discard
  let g = if undo: c.geoBefore else: c.geoAfter
  if g != nil:
    let v = a.geo.version
    a.geo = g.clone
    a.geo.version = v + 1
    a.selPieces.clear()
    a.selFaces.clear()
    a.selHandles.clear()
  if not undo:
    for e in c.extra: a.applyCmd(e, false)
  if c.hasGroups:
    a.groups = if undo: c.grpBefore else: c.grpAfter
    a.groupsRecorded = a.groups
    a.refreshOpenSet()
  if c.hasSel: a.setSel(if undo: c.selBefore else: c.selAfter)
  a.fieldObj = nil

proc undo*(a: App) =
  if a.undoStack.len == 0: return
  let c = a.undoStack.pop
  a.applyCmd(c, undo = true)
  inc objEpoch
  a.storeLinkSigs()
  a.redoStack.add c
  a.selRecorded = a.currentSel
  a.selSeenPush = a.pushCount
  a.say "Undo " & c.label

proc redo*(a: App) =
  if a.redoStack.len == 0: return
  let c = a.redoStack.pop
  a.applyCmd(c, undo = false)
  inc objEpoch
  a.storeLinkSigs()
  a.undoStack.add c
  a.selRecorded = a.currentSel
  a.selSeenPush = a.pushCount
  a.say "Redo " & c.label

proc plural(n: int, one, many: string): string = &"{n} " & (if n == 1: one else: many)

proc selLabel(before, after: SelState): string =
  ## Names a selection step like TrenchBroom's SelectionCommand.
  if after.objs.len == 0 and after.pieces.len == 0 and after.faces.len == 0: return "Select None"
  var objsIn, objsOut = 0
  for o in after.objs:
    if o notin before.objs: inc objsIn
  for o in before.objs:
    if o notin after.objs: inc objsOut
  let piecesIn = (after.pieces - before.pieces).len
  let piecesOut = (before.pieces - after.pieces).len
  let facesIn = (after.faces - before.faces).len
  let facesOut = (before.faces - after.faces).len
  if objsIn + piecesIn > 0: "Select " & plural(objsIn + piecesIn, "Object", "Objects")
  elif facesIn > 0: "Select " & plural(facesIn, "Face", "Faces")
  elif objsOut + piecesOut > 0: "Deselect " & plural(objsOut + piecesOut, "Object", "Objects")
  else: "Deselect " & plural(facesOut, "Face", "Faces")

proc recordSelection*(a: App) =
  ## Once a frame, outside drags: a selection change becomes its own undo
  ## step, and a command pushed since the last call remembers the selection
  ## before and after it, so undoing an edit puts its selection back.
  if a.proj == nil or a.drag.kind != dkNone or a.press.active: return
  let cur = a.currentSel
  if a.pushCount != a.selSeenPush:
    if a.undoStack.len > 0:
      a.undoStack[^1].hasSel = true
      a.undoStack[^1].selBefore = a.selRecorded
      a.undoStack[^1].selAfter = cur
  elif not sameSel(cur, a.selRecorded):
    a.push Cmd(label: selLabel(a.selRecorded, cur), kind: ckSelect, hasSel: true,
               selBefore: a.selRecorded, selAfter: cur)
  a.selSeenPush = a.pushCount
  a.selRecorded = cur

# --- textures ---------------------------------------------------------------------------------

proc texturePath*(a: App, name: string): string =
  if a.proj == nil: return ""
  if name.startsWith("_marker"): a.proj.markersDir / name & ".tga"
  else: a.proj.imagesDir / name & ".tga"

proc textureFile*(a: App, name: string): string =
  ## Where a listed texture's image is: the project's, or else a collection's.
  result = a.texturePath(name)
  if fileExists(result): return
  for c in a.texCollections:
    if c.ready and c.level != 0 and fileExists(c.dir / name & ".tga"): return c.dir / name & ".tga"

proc refreshCollections*(a: App) =
  ## Rereads what each collection holds; the textures of enabled ones get
  ## thumbnails.
  a.texCollections.setLen 0
  if a.proj == nil: return
  let p = a.proj
  var own, custom: seq[string]
  for t in a.textures:
    if t in p.customTextures: custom.add t else: own.add t
  a.texCollections.add TexCollection(id: "level", name: "This level", dir: p.imagesDir, ready: true, textures: own)
  a.texCollections.add TexCollection(id: "custom", name: "Custom textures", dir: p.imagesDir, ready: true,
                                     textures: custom)
  for n in a.cfg.gameLevels:
    if n == p.levelNumber and not p.scratch: continue
    var c = TexCollection(id: "game:" & $n, name: "Level " & $n, level: n, dir: levelTexturesDir(n),
                          ready: levelTexturesReady(n))
    if c.ready:
      for f in walkFiles(c.dir / "*.tga"): c.textures.add f.splitFile.name
      c.textures.sort
    a.texCollections.add c
  a.thumbsLoaded = false

proc enabledTextures*(a: App): seq[(string, int)] =
  ## The enabled collections' textures, each once: (name, index in texCollections).
  if a.proj == nil: return
  var seen: HashSet[string]
  for id in a.proj.textureCollections:
    for ci, c in a.texCollections:
      if c.id == id and c.ready:
        for t in c.textures:
          if not seen.containsOrIncl(t): result.add (t, ci)

proc adoptTexture*(a: App, name: string) =
  ## A collection's texture was used: the level gets its own copy (Build packs env/images).
  if name in a.textures or a.proj == nil: return
  let dst = a.texturePath(name)
  try:
    if not fileExists(dst): copyFile(a.textureFile(name), dst)
    a.textures.add name
    a.textures.sort
    let keep = a.thumbsLoaded
    a.refreshCollections()
    a.thumbsLoaded = keep   # It has its thumbnail already.
  except CatchableError as e: a.say("Could not copy texture " & name & ": " & e.msg, true)

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
  var names = a.textures
  for (name, _) in a.enabledTextures:
    if name notin names: names.add name
  for name in names:
    let key = "tex:" & name
    try:
      let data = readFile(a.textureFile(name))
      a.texSizes[name] = tgaSize(data)
      if key in sk.atlas.entries and name in a.texAlpha: continue
      let t = readTga(data)
      a.texAlpha[name] = t.seeThrough
      if key in sk.atlas.entries: continue
      var img = newImage(t.width, t.height)
      # See-through pixels over a checkerboard, as image editors show them
      # (8 squares across, whatever the texture's size).
      let cell = max(1, max(t.width, t.height) div 8)
      for i in 0 ..< t.width * t.height:
        let al = t.rgba[i * 4 + 3].int
        let bg = if ((i mod t.width) div cell + (i div t.width) div cell) mod 2 == 0: 200 else: 120
        proc ch(c: uint8): uint8 = uint8((c.int * al + bg * (255 - al)) div 255)
        img.data[i] = rgbx(ch(t.rgba[i * 4]), ch(t.rgba[i * 4 + 1]), ch(t.rgba[i * 4 + 2]), 255)
      # Square, at the texture's own size up to the largest zoom; drawn scaled.
      let side = clamp(max(t.width, t.height), 1, MaxTexThumb.int)
      let thumb = if t.width == side and t.height == side: img else: img.resize(side, side)
      if not sk.builder.addImage(key, thumb):
        sk.builder.growAtlas(sk.builder.size * 2)
        discard sk.builder.addImage(key, thumb)
    except CatchableError: discard
  sk.image = sk.builder.atlasImage
  sk.atlas = sk.builder.atlas
  sk.uploadAtlas()

proc loadSkyPreview*(a: App, path: string, maxW, maxH: float32, key = "") =
  ## The picture's preview goes into the UI atlas, once, under key (default:
  ## path). A picture that can't be read gets no entry in skyPreviews.
  let key = if key.len > 0: key else: path
  if key in a.skyPreviews: return
  try:
    if path.splitFile.ext.toLowerAscii.strip(chars = {'.'}) notin DirectFormats or
       not fileExists(path): return
    let t = readPicture(path)
    if t.width == 0 or t.height == 0: return
    let k = min(1'f32, min(maxW / t.width.float32, maxH / t.height.float32))
    let (w, h) = (max(1, int(t.width.float32 * k)), max(1, int(t.height.float32 * k)))
    # The atlas holds device pixels.
    let sc = a.sk.atlasScale.float
    let thumb = t.resized(max(1, int(w.float * sc)), max(1, int(h.float * sc)))
    var img = newImage(thumb.width, thumb.height)
    for i in 0 ..< thumb.width * thumb.height:
      img.data[i] = rgbx(thumb.rgba[i * 4], thumb.rgba[i * 4 + 1], thumb.rgba[i * 4 + 2], 255)
    let sk = a.sk
    if sk.builder == nil: sk.builder = newAtlasBuilderFromAtlas(sk.atlas, sk.image)
    if not sk.builder.addImage("skysrc:" & key, img):
      sk.builder.growAtlas(sk.builder.size * 2)
      discard sk.builder.addImage("skysrc:" & key, img)
    sk.image = sk.builder.atlasImage
    sk.atlas = sk.builder.atlas
    sk.uploadAtlas()
    a.skyPreviews[key] = (w, h, t.width, t.height)
  except CatchableError: discard

proc texSizeText*(a: App, name: string): string =
  ## "256×128", or "" when the texture's size isn't known.
  if name notin a.texSizes: return ""
  let (w, h) = a.texSizes[name]
  $w & "×" & $h

include dock

# --- project loading and saving ------------------------------------------------------------------

proc frameAll*(a: App)

# Editor state kept outside the projects: the window layout (one for all maps)
# and where each map's 3D camera was left.
proc layoutPath(): string = configPath().parentDir / "layout.json"
proc camerasPath(): string =
  when defined(windows): configPath().parentDir / "cameras.json"
  else:
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
  a.dock = dockFromJson(j{"dock"})
  if j{"dockVersion"}.getInt < 2:
    # Saved before Texture Collections existed: it goes with the Texture Browser.
    let l = a.dock.leafOf(pkTextureBrowser)
    if l != nil and a.dock.leafOf(pkTextureCollections) == nil: l.tabs.add pkTextureCollections
  a.texGroup = j{"textureGroup"}.getBool(true)
  a.entityBrowserH = j{"entityBrowserH"}.getFloat(a.entityBrowserH).float32
  a.classListFolded = j{"classListFolded"}.getBool(false)
  if j{"classFolded"} != nil and j["classFolded"].kind == JArray:
    for n in j["classFolded"]: a.classFolded.incl n.getStr
  # Saved under a new name since step 6 became the default (the old one was mostly 0).
  a.entityPreview = clamp(j{"entityPreviewSize"}.getFloat(a.entityPreview), 0, 1)
  a.texThumb = clamp(j{"texThumb"}.getFloat(a.texThumb), MinTexThumb, MaxTexThumb).float32
  if j{"codeFontSize"}.getInt in CodeFontSizes: a.codeFontSize = j{"codeFontSize"}.getInt
  a.flySpeed = clamp(j{"flySpeed"}.getFloat(a.flySpeed), MinFlySpeed, MaxFlySpeed).float32
  for m in RenderMode:
    if $m == j{"renderMode"}.getStr: a.opts.mode = m
  if j{"realtimePreview"} != nil and j["realtimePreview"].kind == JArray:
    var parts: set[PreviewPart]
    for n in j["realtimePreview"]:
      for p in PreviewPart:
        if $p == n.getStr: parts.incl p
    if parts != {}: a.previewParts = parts
  a.showGizmos = j{"gizmos"}.getBool(a.showGizmos)
  if j{"gizmosHidden"} != nil and j["gizmosHidden"].kind == JArray:
    a.gizmoHidden.clear()
    for n in j["gizmosHidden"]: a.gizmoHidden.incl n.getStr
  a.showEditorOnly = j{"editorOnly"}.getBool(a.showEditorOnly)
  if j{"editorOnlyParts"} != nil and j["editorOnlyParts"].kind == JArray:
    var parts: set[EditorOnlyPart]
    for n in j["editorOnlyParts"]:
      for p in EditorOnlyPart:
        if $p == n.getStr: parts.incl p
    if parts != {}: a.editorOnlyParts = parts
  a.notesRange = clamp(j{"notesRange"}.getFloat(a.notesRange), MinNotesRange, MaxNotesRange).float32
  a.previewSoundVolume = clamp(j{"realtimeSoundVolume"}.getFloat(a.previewSoundVolume), 0, 1)
  a.previewMusicVolume = clamp(j{"realtimeMusicVolume"}.getFloat(a.previewMusicVolume), 0, 1)
  let w = j{"window"}
  if w != nil and w.kind == JObject:
    a.winPos = ivec2(w{"x"}.getInt.int32, w{"y"}.getInt.int32)
    a.winSize = ivec2(w{"width"}.getInt.int32, w{"height"}.getInt.int32)
    a.winMaximized = w{"maximized"}.getBool
  if j.hasKey("entityGroupsOpen"):
    a.browserOpen.clear()
    for g in j["entityGroupsOpen"]: a.browserOpen.incl g.getStr
    if "Generic" in a.browserOpen:   # one group before the categories
      for c in Categories: a.browserOpen.incl c.generic

proc saveLayout*(a: App) =
  try:
    createDir(layoutPath().parentDir)
    writeFile(layoutPath(), pretty(%*{"layout": $a.layout, "splitX": a.splitX, "splitY": a.splitY,
      "dock": a.dock.toJson, "dockVersion": 2, "textureGroup": a.texGroup, "entityBrowserH": a.entityBrowserH,
      "classListFolded": a.classListFolded, "classFolded": a.classFolded.toSeq.sorted,
      "entityPreviewSize": a.entityPreview, "texThumb": a.texThumb, "codeFontSize": a.codeFontSize, "entityGroupsOpen": a.browserOpen.toSeq.sorted,
      "flySpeed": a.flySpeed, "renderMode": $a.opts.mode,
      "realtimePreview": a.previewParts.toSeq.mapIt($it),
      "gizmos": a.showGizmos, "gizmosHidden": a.gizmoHidden.toSeq.sorted,
      "editorOnly": a.showEditorOnly, "editorOnlyParts": a.editorOnlyParts.toSeq.mapIt($it),
      "notesRange": a.notesRange,
      "realtimeSoundVolume": a.previewSoundVolume, "realtimeMusicVolume": a.previewMusicVolume, "window": {"x": a.winPos.x, "y": a.winPos.y,
        "width": a.winSize.x, "height": a.winSize.y, "maximized": a.winMaximized}}))
  except CatchableError as e: a.say("Could not save the layout: " & e.msg, true)

proc camera3D*(a: App): ptr Camera =
  for i in 0 .. 3:
    if a.views[i].cam.kind == vk3D: return addr a.views[i].cam
  for i in 0 .. 3:
    if a.views[i].last3D.fovY > 0: return addr a.views[i].last3D

proc saveCamera*(a: App) =
  ## Remembers the open map's 3D camera, keyed by its project folder.
  let cam = a.camera3D
  if a.proj == nil or cam == nil or a.proj.preview: return
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
  let preview = if a.proj.preview: a.proj.dir else: ""
  a.saveCamera()
  a.proj = nil
  if preview.len > 0:
    try: removeDir(preview)
    except CatchableError: discard
  openSoundsDir = ""
  a.ambientEdit = nil
  setProjectAmbients(@[])

# --- baked lighting ---------------------------------------------------------------------------

proc lightOn*(o: LevelObject): bool =
  ## A light's Enabled field (missing = on).
  o.node.xpath("OSD/Enabled").str.strip.toLowerAscii notin ["0", "false", "no", "off"]

proc lightDir*(o: LevelObject): Vec3 =
  ## A spot or directional light's direction: its forward axis.
  (objectMatrix(vec3(0, 0, 0), o.rot) * vec3(0, 0, 1)).normalize

proc spotAngles*(o: LevelObject): (float32, float32) =
  ## A spot light's half angles in degrees: where its light ends, and where it
  ## starts fading toward that edge (Angle is the full cone, Softness 0..1).
  proc num(path: string, default: float): float =
    try: parseFloat(o.node.xpath(path).str.strip) except ValueError: default
  let outer = clamp(num("OSD/Angle", 60), 1, 179).float32 / 2
  (outer, outer * (1 - clamp(num("OSD/Softness", 0.3), 0, 1).float32))

proc lightAnim*(o: LevelObject): CornerAnim =
  ## A light object's OSD/Animation, as a corner's animation would have it
  ## (color 0–255, before Intensity).
  proc num(path: string, default: float): float32 =
    try: parseFloat(o.node.xpath("OSD/Animation/" & path).str.strip).float32
    except ValueError: default.float32
  proc word(path: string): string = o.node.xpath("OSD/Animation/" & path).str.strip.toLowerAscii
  result.mode = case word("Mode")
                of "pulse": amPulse
                of "flicker": amFlicker
                else: amNone
  result.interp = case word("Interpolation")
                  of "linear": aiLinear
                  of "step": aiStep
                  else: aiSmooth
  let c = strutils.splitWhitespace(o.node.xpath("OSD/Animation/Color").str)
  if c.len == 3:
    for i in 0 .. 2:
      try: result.color[i] = uint8(clamp(parseFloat(c[i]), 0, 255))
      except ValueError: discard
  result.period = max(0.01'f32, num("Period", 2))
  result.offset = num("Offset", 0)
  result.seed = clamp(num("Seed", 0), 0, MaxAnimSeed.float32).uint32
  result.low = clamp(num("Min", 0), 0, 1)
  result.high = clamp(num("Max", 1), 0, 1)
  result.stability = clamp(num("Stability", 0), 0, 1)
  result.faultLen = max(0'f32, num("FaultLength", 1))

proc setLightAnim*(o: LevelObject, m: CornerAnim) =
  ## Writes m into the light's OSD/Animation (made if missing).
  let osd = o.node.xpath("OSD")
  if osd == nil: return
  var an = osd.child("Animation")
  if an == nil:
    an = newElement("Animation")
    osd.add an
  proc put(tag, value: string) =
    var e = an.child(tag)
    if e == nil:
      e = newElement(tag)
      an.add e
    e.setText(value)
  proc num(v: float32): string =
    result = formatFloat(v.float64, ffDecimal, 3)
    result.trimZeros()
  const modes: array[AnimMode, string] = ["Off", "Pulse", "Flicker"]
  const interps: array[AnimInterp, string] = ["Smooth", "Linear", "Step"]
  put "Mode", modes[m.mode]
  put "Color", &"{m.color[0]} {m.color[1]} {m.color[2]}"
  put "Period", num(m.period)
  put "Offset", num(m.offset)
  put "Seed", $m.seed
  put "Interpolation", interps[m.interp]
  put "Min", num(m.low)
  put "Max", num(m.high)
  put "Stability", num(m.stability)
  put "FaultLength", num(m.faultLen)
  o.file.dirty = true

proc light*(o: LevelObject): Light =
  ## A light object's light: Color (0–255 each) times Intensity; a point or
  ## spot light's reaches out to Radius, a spot's and a directional light's go
  ## along lightDir. Its Animation goes toward Animation/Color times Intensity.
  proc num(path: string, default: float): float =
    try: parseFloat(o.node.xpath(path).str.strip) except ValueError: default
  proc rgb(path: string, default: Vec3): Vec3 =
    result = default
    let c = strutils.splitWhitespace(o.node.xpath(path).str)
    if c.len == 3:
      try: result = vec3(parseFloat(c[0]), parseFloat(c[1]), parseFloat(c[2])) / 255
      except ValueError: discard
  proc word(path: string): string = o.node.xpath(path).str.strip.toLowerAscii
  let intensity = max(0, num("OSD/Intensity", 1)).float32
  result = Light(kind: (case o.tag
                        of DirLightTag: lkDirectional
                        of SpotLightTag: lkSpot
                        else: lkPoint),
                 pos: o.pos, dir: (if o.tag in AimedTags: o.lightDir else: vec3(0, 0, 0)),
                 color: rgb("OSD/Color", vec3(1, 1, 1)) * intensity,
                 radius: max(0, num("OSD/Radius", if o.tag == SpotLightTag: 300 else: 200)).float32,
                 shadows: word("OSD/Shadows") notin ["0", "false", "no", "off"])
  if o.tag == SpotLightTag:
    let (outer, inner) = o.spotAngles
    result.cosOuter = cos(outer.degToRad)
    result.cosInner = cos(inner.degToRad)
  result.anim = o.lightAnim
  result.other = rgb("OSD/Animation/Color", vec3(0, 0, 0)) * intensity

proc addMissingLightFields*(o: LevelObject) =
  ## Lights saved before a field was added get it from their template, so the
  ## Entity tab shows it (the file isn't marked changed: the values are defaults).
  if o.tag notin LightTags: return
  let osd = o.node.xpath("OSD")
  if osd == nil: return
  proc fill(have, t: XmlNode) =
    for i in 0 ..< t.len:
      let c = t[i]
      if c.kind != xnElement: continue
      let h = have.child(c.tag)
      if h == nil: have.insert(c, min(i, have.len))
      elif c.len > 0 and c[0].kind == xnElement: fill(h, c)   # Animation's fields
  fill(osd, parseXml(Templates[o.tag]).xpath("OSD"))

proc lights*(a: App): seq[Light] =
  ## The lights that are on.
  for o in a.objects:
    if o.tag in LightTags and o.lightOn: result.add o.light

proc lightingKey*(a: App): string =
  ## Everything a bake depends on; a different key means the lighting is stale.
  if a.geo == nil or a.proj == nil: return ""
  result = $a.geo.version & "|" & $a.proj.ambient & "|" & $a.proj.softShadows
  for o in a.objects:
    if o.tag in LightTags: result.add "|" & o.snapshot

proc ambientColor(a: App): Vec3 =
  vec3(a.proj.ambient[0].float32, a.proj.ambient[1].float32, a.proj.ambient[2].float32) / 255

proc bakeLights*(a: App) =
  ## Bake light: replaces every visible face corner's color with the ambient
  ## color plus the lights' light, as one undo step.
  if a.proj == nil or a.geo == nil:
    a.say("This project has no editable geometry to light", true)
    return
  let before = a.geo.clone
  let t0 = epochTime()
  let lights = a.lights
  let n = a.geo.bakeLighting(lights, a.ambientColor, a.proj.softShadows.float32)
  if n > 0: a.push geoCmd("Bake lighting", before, a.geo)
  a.bakeKey = a.lightingKey
  let ms = int((epochTime() - t0) * 1000)
  a.say &"Baked lighting from {lights.len} light(s): {n} corner color(s) changed ({ms} ms)"

proc bakeWaits*(a: App): bool =
  ## Automatic baking is on but won't run this frame: since it waits as long as
  ## the last bake took, a big level's bakes leave frames between them.
  a.proj.autoBake and epochTime() - a.bakeAt < a.bakeTook

proc autoBake*(a: App) =
  ## Once a frame: with automatic baking on, rebakes when a light, the ambient
  ## color or the geometry changed. No undo step: the lighting follows the edit
  ## that changed it. On big levels it waits as long as the last bake took.
  if a.proj == nil or a.geo == nil or not a.proj.autoBake: return
  let key = a.lightingKey
  if key == a.bakeKey: return
  if a.bakeWaits: return
  let t0 = epochTime()
  discard a.geo.bakeLighting(a.lights, a.ambientColor, a.proj.softShadows.float32)
  a.bakeAt = epochTime()
  a.bakeTook = a.bakeAt - t0
  a.bakeKey = a.lightingKey

proc refreshGeometry*(a: App) =
  if a.geo == nil: return
  let app = a
  a.rend.setGeometry(a.geo, proc(n: string): string = app.texturePath(n),
                     proc(fi: int): bool = not app.faceVisible(fi))

proc updateWindowTitle*(a: App) =
  ## "<title> (<folder>) - Catwalk": the folder tells copies of one level apart.
  ## An asterisk after the name marks unsaved changes. Runs every frame; the
  ## window is only touched when the text changes.
  let title =
    if a.proj == nil: "Catwalk"
    else:
      let mark = if a.dirty: "*" else: ""
      if a.proj.preview: &"{a.proj.title} (preview){mark} - Catwalk"
      elif a.proj.title.len == 0 or a.proj.folder == a.proj.title: &"{a.proj.folder}{mark} - Catwalk"
      else: &"{a.proj.title}{mark} ({a.proj.folder}) - Catwalk"
  if title != a.windowTitle:
    a.windowTitle = title
    a.window.title = title

proc loadGroups(a: App)
proc saveGroups(a: App, dir: string)

proc loadProject*(a: App, p: Project) =
  if a.proj != nil and a.proj != p: a.saveCamera()
  inc objEpoch
  a.rend.clearAll()
  a.proj = p
  openSoundsDir = p.soundsDir
  setProjectAmbients(loadAmbients(p.ambientsPath))
  if not p.preview: a.cfg.noteOpened(p.dir)
  a.files.setLen 0
  a.scripts = nil
  a.mapReveal = nil
  a.fileCache.clear()
  a.filesOpen.clear()
  a.filesSel = ""
  a.filesScroll = 0
  a.objects.setLen 0
  a.undoStack.setLen 0
  a.redoStack.setLen 0
  a.cleanAt = 0
  a.fieldObj = nil
  a.classes.clear()
  a.classOrig.clear()
  a.classOnDiskRead = false
  a.classMarkStamp = (-1, -1, -1)
  a.classParentStamp = (-1, -1, -1)
  a.className = ""
  a.classOther = ""
  a.classParticles = false
  a.particleEditStamp = (-1, -1, -1)
  a.particleRestart = true
  a.classFor = nil
  a.classTextFor = nil
  a.clearSelection()
  a.groups.setLen 0
  a.openGroups.setLen 0
  a.selRecorded = SelState(lastFace: -1)
  a.selSeenPush = a.pushCount
  a.densities.clear()
  a.geo = nil
  a.thumbsLoaded = false
  a.texSizes.clear()
  a.texAlpha.clear()
  try:
    (a.files, a.objects) = loadObjects(p.objectsDir)
  except CatchableError as e:
    a.say("Could not read objects: " & e.msg, true)
  if fileExists(p.lightsPath):
    try:
      let (f, objs) = loadObjectFile(p.lightsPath)
      for o in objs: o.addMissingLightFields()
      a.files.add f
      a.objects.add objs
    except CatchableError as e:
      a.say("Could not read lights: " & e.msg, true)
  if p.hasGeometry:
    try:
      a.geo = loadGeometry(p.geometryPath)
      a.geoSavedVersion = a.geo.version
    except CatchableError as e:
      a.say("Could not read geometry: " & e.msg, true)
  a.loadGroups()
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
  a.refreshCollections()
  if a.geo != nil: a.refreshGeometry()
  a.savePointList = p.savePoints
  a.bakeKey = a.lightingKey   # geometry.json was saved baked
  a.frameAll()
  if not p.preview: a.restoreCamera()
  if p.preview:
    a.say &"Previewing {p.title}: nothing is kept unless you save it as a project (File > Save As...)"
  else:
    a.say &"Opened {p.folder}: {a.objects.len} objects" &
      (if a.geo != nil: &", {a.geo.faces.len} faces in {a.geo.pieces.len} pieces" else: "")

proc nextFreeProjectDir*(a: App): string

proc saveProject*(a: App) =
  if a.proj == nil: return
  if a.proj.preview:
    # A preview has no project to save into: ask for one.
    a.dialog = startDialog(dkSaveFile, "saveas", "Save the preview as a project", a.nextFreeProjectDir())
    a.say "A preview isn't saved: choose a folder to keep it as a project"
    return
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
  a.saveGroups(a.proj.dir)
  n += a.scripts.saveAll
  a.proj.save()
  a.cleanAt = a.undoStack.len
  a.say(if n > 0: &"Saved ({n} file(s))" else: "Nothing to save")

proc copyName*(base: string, taken: proc(name: string): bool): string =
  ## A free name for a duplicate of base: base itself, then "<base>-Copy2", "-Copy3"...
  result = base
  var n = 2
  while taken(result):
    result = &"{base}-Copy{n}"
    inc n

proc nextFreeProjectDir*(a: App): string =
  ## "<folder>-Copy2", "-Copy3"... next to the open project: the save dialogs'
  ## suggestion. A preview's goes in the projects folder as "Level<n>" first.
  let parent = if a.proj.preview: a.cfg.projectsDir else: a.proj.dir.parentDir
  var base = if a.proj.preview: "Level" & $a.proj.levelNumber else: a.proj.folder
  let dash = base.rfind('-')
  if dash > 0:
    var tail = base[dash + 1 .. ^1]
    if tail.startsWith("Copy"): tail = tail["Copy".len .. ^1]
    if tail.len > 0 and tail.allCharsInSet(Digits): base = base[0 ..< dash]
  proc taken(name: string): bool =
    dirExists(parent / name) or fileExists(parent / name) or
      (not a.proj.preview and name == a.proj.folder)
  parent / copyName(base, taken)

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
      if a.scripts != nil:
        for b in a.scripts.buffers:
          if b.dirty:
            let to = dst / b.path.absolutePath.relativePath(src)
            createDir(to.parentDir)
            writeFile(to, b.text)
      let p = Project()
      p[] = a.proj[]
      p.dir = dst
      p.folder = dst.lastPathPart
      if p.preview: p.title = p.folder
      if a.geo != nil and a.geo.version != a.geoSavedVersion:
        a.geo.save(p.geometryPath)
        p.geometryEdited = true
      a.saveGroups(dst)
      p.save()
      a.say(&"Saved a copy as {dst}")
    else:
      a.saveCamera()
      for f in a.files: f.path = dst / f.path.absolutePath.relativePath(src)
      if a.scripts != nil:
        for b in a.scripts.buffers: b.path = dst / b.path.absolutePath.relativePath(src)
        a.scripts.disk.clear()
        a.scripts.files.setLen 0
      a.proj.dir = dst
      a.proj.folder = dst.lastPathPart
      if a.proj.preview:
        # The preview becomes a project: its copy in the cache isn't needed any more.
        a.proj.preview = false
        a.proj.title = a.proj.folder
        try: removeDir(src)
        except CatchableError: discard
      a.saveProject()
      a.cfg.noteOpened(dst)
      a.saveCamera()
      a.say(&"Saved as {dst}; now editing it")
  except CatchableError as e:
    a.say("Could not save the project: " & e.msg, true)

# --- cameras ------------------------------------------------------------------------------------

proc viewBody*(v: ViewPane): Rect = rect(v.rect.x, v.rect.y + ViewHeader, v.rect.w, v.rect.h - ViewHeader)

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
    let cam = if a.views[i].cam.kind == vk3D: addr a.views[i].cam
              elif a.views[i].last3D.fovY > 0: addr a.views[i].last3D
              else: nil
    if cam == nil: continue
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

proc selectionCenter*(a: App): (bool, Vec3) =
  ## Rotation pivot, as TrenchBroom's RotateTool::resetRotationCenter: a lone
  ## object turns about its origin, anything else about its bounds' center.
  ## The center isn't grid-snapped: grid-aligned bounds already center on the
  ## half grid, and snapping to the full grid moved it off by half a cell.
  let geoSel = a.geo != nil and (a.selPieces.len > 0 or a.selFaces.len > 0)
  let sel = a.selection
  if sel.len == 1 and not geoSel: return (true, sel[0].pos)
  let (ok, lo, hi) = a.selectionBounds
  (ok, (lo + hi) / 2)

# Focusing the 3D view on the selection: the current direction if nothing is
# in the way, else the nearest one that shows the selection, found by casting
# rays from candidate spots around it through the same kind of grid the light
# bake and the sound preview use.

const
  CamAnimTime = 0.45
  FocusRays = 32                ## Most points of the selection tested per spot.

type FocusPoint = object
  pos, nrm: Vec3                ## nrm: a selected face's (it's only seen from the front).

var
  focusGrid: Grid
  focusStamp: seq[int32]
  focusRay = 0'i32
  focusGeo: Geometry
  focusVersion = -1

proc blocksView(f: Face): bool {.nimcall.} =
  f.isLit and (f.flags and gfTransparent) == 0

proc focusPoints(a: App): (seq[FocusPoint], seq[bool]) =
  ## Points of the selection to see, and per face whether it can't get in the
  ## way (it's selected, hidden, or belongs to a selected object).
  var pts: seq[FocusPoint]
  var owned: HashSet[int32]
  for o in a.selection:
    let (lo, hi) = o.pickBox
    let c = (lo + hi) / 2
    pts.add FocusPoint(pos: c)
    pts.add FocusPoint(pos: c + vec3(0, (hi.y - lo.y) * 0.35, 0))
    pts.add FocusPoint(pos: c - vec3(0, (hi.y - lo.y) * 0.35, 0))
    owned.incl o.objectCode
  var skip: seq[bool]
  if a.geo != nil:
    skip = newSeq[bool](a.geo.faces.len)
    for i, f in a.geo.faces:
      if f.piece in a.selPieces or i in a.selFaces or f.objectId in owned or not a.faceVisible(i):
        skip[i] = true
      if (f.piece in a.selPieces or i in a.selFaces) and f.verts.len >= 3:
        var c = vec3(0, 0, 0)
        for v in f.verts: c += a.geo.points[v]
        c = c / f.verts.len.float32
        let n = a.geo.normal(f)
        pts.add FocusPoint(pos: c + n * 0.5, nrm: if i in a.selFaces: n else: vec3(0, 0, 0))
  let stride = max(1, pts.len div FocusRays)
  for i in countup(0, pts.high, stride): result[0].add pts[i]
  result[1] = skip

proc focusBlocked(p: FocusPoint, eye: Vec3, skip: seq[bool]): (bool, bool) =
  ## Whether a face the 3D view draws hides the point from eye, and whether
  ## any face lies between them (a back face isn't drawn, but it means the
  ## view comes from outside the level or from inside a wall).
  if p.nrm != vec3(0, 0, 0) and p.nrm.dot(eye - p.pos) <= 0: return (true, true)
  inc focusRay
  let d = (p.pos - eye).normalize
  for (t, fi) in crossings(addr focusGrid, eye, p.pos - d * 1.5, focusStamp, focusRay):
    if skip[fi]: continue
    result[1] = true
    if focusGeo.normal(focusGeo.faces[fi]).dot(d) < 0 or (focusGeo.faces[fi].flags and gfTwoSided) != 0:
      result[0] = true
      return

proc ensureFocusGrid(a: App) =
  if focusGeo != a.geo or focusVersion != a.geo.version:
    focusGrid = buildGrid(a.geo, blocksView)
    focusGeo = a.geo
    focusVersion = a.geo.version
    focusStamp = newSeq[int32](focusGrid.triangles)
    focusRay = 0

proc hiddenFrom*(a: App, p, eye: Vec3, owner = 0'i32): bool =
  ## Whether a face the 3D view draws lies between eye and p. Faces of the
  ## object coded owner (when non-zero) and hidden faces don't count.
  if a.geo == nil or a.geo.faces.len == 0: return false
  a.ensureFocusGrid
  let d = p - eye
  if d.length < 2: return false
  let n = d.normalize
  inc focusRay
  for (t, fi) in crossings(addr focusGrid, eye, p - n * 1.5, focusStamp, focusRay):
    let f = focusGeo.faces[fi]
    if (owner != 0 and f.objectId == owner) or not a.faceVisible(fi): continue
    if focusGeo.normal(f).dot(n) < 0 or (f.flags and gfTwoSided) != 0: return true

proc focusView(a: App, lo, hi: Vec3): (Vec3, float32, float32) =
  ## Where the 3D camera sees the box lo..hi framed with nothing in front of
  ## it: (position, yaw, pitch). Costs per spot: anything hidden first, then a
  ## turn away from the current view, then coming closer than the full frame.
  let cam = a.camera3D
  let c = (lo + hi) / 2
  let radius = max((hi - lo).length / 2, 24)
  var aspect = 1'f32
  for v in a.views:
    if v.cam.kind == vk3D and v.rect.h > 1: aspect = v.viewBody.w / max(v.viewBody.h, 1)
  let halfAngle = arctan(tan(cam.fovY / 2) * min(aspect, 1))
  let far = radius / sin(halfAngle) * 1.05
  let here = Camera(yaw: cam.yaw, pitch: clamp(cam.pitch, -1.45, 1.45))
  proc spot(yaw, pitch, dist: float32): Vec3 =
    c - Camera(yaw: yaw, pitch: pitch).forward * dist
  if a.geo == nil or a.geo.faces.len == 0: return (spot(here.yaw, here.pitch, far), here.yaw, here.pitch)
  a.ensureFocusGrid
  let (pts, skip) = a.focusPoints
  if pts.len == 0: return (spot(here.yaw, here.pitch, far), here.yaw, here.pitch)
  var best = Inf.float32
  var res = (spot(here.yaw, here.pitch, far), here.yaw, here.pitch)
  let f0 = here.forward
  var pitches = @[here.pitch]
  for p in [-0.25'f32, -0.55, -0.9, -1.25, 0.15, 0.45]: pitches.add p
  for pitch in pitches:
    for k in 0 ..< 16:
      let yaw = here.yaw + k.float32 / 16 * 2 * PI.float32
      let turn = arccos(clamp(Camera(yaw: yaw, pitch: pitch).forward.dot(f0), -1, 1)) / PI.float32
      for near in [1'f32, 0.7, 0.45, 0.25]:
        let dist = max(far * near, radius * 1.15 + 4)
        var cost = turn * 1.2 + (1 - near) * 0.5
        if cost >= best: continue
        let eye = spot(yaw, pitch, dist)
        var hidden, crossed = 0
        for p in pts:
          let (h, x) = p.focusBlocked(eye, skip)
          if h: inc hidden
          if x: inc crossed
          if cost + 6 * hidden.float32 / pts.len.float32 >= best: break
        cost += 6 * hidden.float32 / pts.len.float32 + 2 * crossed.float32 / pts.len.float32
        if cost < best:
          best = cost
          res = (eye, yaw, pitch)
  res

proc animateCameras(a: App, change: proc()) =
  ## Runs change, which puts the cameras somewhere else at once, and turns
  ## that into a glide from where they are now. The 2D views glide along.
  var an = CamAnim(on: true, start: epochTime(), fromFocus: a.focus2D, fromZoom: a.zoom2D)
  for i in 0 .. 3: an.fromCam[i] = a.views[i].cam
  change()
  (an.toFocus, an.toZoom, an.target) = (a.focus2D, a.zoom2D, a.focus2D)
  for i in 0 .. 3:
    an.toCam[i] = a.views[i].cam
    a.views[i].cam = an.fromCam[i]
  (a.focus2D, a.zoom2D) = (an.fromFocus, an.fromZoom)
  a.sync2D()
  for i in 0 .. 3: an.shown[i] = a.views[i].cam
  (an.shownFocus, an.shownZoom) = (a.focus2D, a.zoom2D)
  a.camAnim = an

proc updateCamAnim*(a: App) =
  ## Once a frame, before the views handle input. A camera moved by hand since
  ## the last frame ends the glide there.
  template an: untyped = a.camAnim
  if not an.on: return
  for i in 0 .. 3:
    let (c, s) = (a.views[i].cam, an.shown[i])
    if c.kind != s.kind or (c.kind == vk3D and (c.pos != s.pos or c.yaw != s.yaw or c.pitch != s.pitch)):
      an.on = false
      return
  if a.focus2D != an.shownFocus or a.zoom2D != an.shownZoom:
    an.on = false
    return
  let raw = clamp(float32((epochTime() - an.start) / CamAnimTime), 0, 1)
  let t = raw * raw * raw * (raw * (raw * 6 - 15) + 10)
  for i in 0 .. 3:
    if a.views[i].cam.kind != vk3D: continue
    let (p, q) = (an.fromCam[i], an.toCam[i])
    # Swings around the target instead of cutting straight across it.
    let (d0, d1) = ((an.target - p.pos).length, (an.target - q.pos).length)
    let look = mix(p.pos + p.forward * d0, q.pos + q.forward * d1, t)
    var dy = (q.yaw - p.yaw) mod (2 * PI.float32)
    if dy > PI.float32: dy -= 2 * PI.float32
    elif dy < -PI.float32: dy += 2 * PI.float32
    a.views[i].cam.yaw = p.yaw + dy * t
    a.views[i].cam.pitch = p.pitch + (q.pitch - p.pitch) * t
    a.views[i].cam.pos = look - a.views[i].cam.forward * (d0 + (d1 - d0) * t)
    if raw >= 1: (a.views[i].cam.pos, a.views[i].cam.yaw, a.views[i].cam.pitch) = (q.pos, q.yaw, q.pitch)
    an.shown[i] = a.views[i].cam
  a.focus2D = mix(an.fromFocus, an.toFocus, t)
  a.zoom2D = an.fromZoom * pow(an.toZoom / max(an.fromZoom, 1e-4), t)
  a.sync2D()
  (an.shownFocus, an.shownZoom) = (a.focus2D, a.zoom2D)
  if raw >= 1: an.on = false

proc frameSelection*(a: App) =
  let (ok, lo, hi) = a.selectionBounds
  if not ok:
    a.animateCameras(proc() = a.frameAll())
    return
  let (pos, yaw, pitch) = a.focusView(lo, hi)
  a.animateCameras(proc() =
    a.frameBox(lo, hi)
    for i in 0 .. 3:
      let cam = if a.views[i].cam.kind == vk3D: addr a.views[i].cam
                elif a.views[i].last3D.fovY > 0: addr a.views[i].last3D
                else: nil
      if cam != nil: (cam.pos, cam.yaw, cam.pitch) = (pos, yaw, pitch))

proc resetCameras*(a: App) =
  a.animateCameras(proc() = a.frameAll())

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
    if not a.viewPickable(o): continue
    let t = o.pickRay(r)
    if t >= 0 and t < result.t:
      result = Hit(kind: hkObject, obj: o, t: t, face: -1)
  if geometryToo and a.geometryVisible:
    let (fi, t) = a.geo.pickFace(r, a.facePickable(vi, r))
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

var pieceFaceIndex: seq[seq[int]]
var pieceFaceGeo: Geometry
var pieceFaceVersion = -1

proc facesOfPiece*(a: App, piece: int32): seq[int] =
  ## A piece's faces, from an index kept until the geometry changes.
  if a.geo == nil: return
  if pieceFaceGeo != a.geo or pieceFaceVersion != a.geo.version:
    pieceFaceIndex = a.geo.pieceFaces
    pieceFaceGeo = a.geo
    pieceFaceVersion = a.geo.version
  if piece in 0 ..< pieceFaceIndex.len.int32: pieceFaceIndex[piece] else: @[]

proc selectedFaceSet*(a: App): HashSet[int] =
  ## Faces of selected pieces plus individually selected faces. Called every
  ## frame: only the selection's own faces are looked at.
  if a.geo == nil: return
  for p in a.selPieces:
    for i in a.facesOfPiece(p): result.incl i
  for i in a.selFaces:
    if i in 0 ..< a.geo.faces.len: result.incl i

proc holdTextures*(a: App, faces: HashSet[int]): TexHold =
  ## With UV lock off, notes each face's shift, scale and rotation on its world
  ## axes, for releaseTextures to put back after a move, turn, scale or flip, so
  ## textures stay put in the world (TrenchBroom without UV lock). Empty with UV
  ## lock on: the UVs ride along with the corners.
  if a.uvLock or a.geo == nil: return
  for fi in faces:
    let f = a.geo.faces[fi]
    let t = a.geo.texFrame(f, a.density(f.texture))
    if t.ok: result.add (fi, t, f.uvs)

proc releaseTextures*(a: App, hold: TexHold, restore = false) =
  ## Gives held faces their noted mappings back on their new corners. restore
  ## first puts back their UVs from the hold (drags, applied again every frame).
  for h in hold:
    if restore: a.geo.faces[h.face].uvs = h.uvs
    let cur = a.geo.texFrame(h.face, a.density(a.geo.faces[h.face].texture))
    if cur.ok: discard a.geo.setTexFrame(h.face, cur, h.frame)

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

proc copySelectedGroups(a: App, offset: Vec3, linked: bool): Table[int32, int32]
proc addToGroup(a: App, o: LevelObject, gid: int32)
proc expandGroupSelection*(a: App)

proc duplicateSelection*(a: App, offset: Vec3, linked = false, flash = false) =
  ## Ctrl+D. Selected closed groups are copied as groups (Ctrl+Shift+D: as
  ## linked duplicates); things inside the open group stay in it. With flash,
  ## the copy's lines go white and fade back (an in-place copy is otherwise
  ## invisible).
  a.expandGroupSelection()
  let sel = a.selection
  let geoSel = a.selPieces.len > 0 or a.selFaces.len > 0
  if sel.len == 0 and not geoSel: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  var c = Cmd(label: if linked: "Create Linked Duplicate" else: "Duplicate", kind: ckAdd,
              geoBefore: geoBefore)
  let groupMap = a.copySelectedGroups(offset, linked)
  var id = a.objects.nextId
  for o in sel: o.selected = false
  for o in sel:
    let d = o.duplicate(id)
    let og = a.objGroup(o)
    a.addToGroup(d, groupMap.getOrDefault(og, og))
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
    let src = a.selectedFaceSet.toSeq.sorted
    var hold = a.holdTextures(src.toHashSet)
    let added = a.geo.duplicateFaces(src, offset)
    # Each copy keeps its original's mapping (added is in src's order).
    for h in hold.mitems: h.face = added[src.binarySearch(h.face)]
    a.releaseTextures(hold)
    a.selPieces.clear()
    a.selFaces.clear()
    for fi in added:
      let pc = a.geo.faces[fi].piece
      a.selPieces.incl pc
      a.geo.pieces[pc].group = groupMap.getOrDefault(a.geo.pieces[pc].group, a.geo.pieces[pc].group)
  if a.geo != nil: c.geoAfter = a.geo.clone
  a.push c
  if flash: a.dupFlashAt = epochTime()
  a.say(if linked: "Created a linked duplicate" else: "Duplicated")

proc affineOf*(f: proc(p: Vec3): Vec3): Affine
proc transformSelectedGroups*(a: App, x: Affine)

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
    let hold = a.holdTextures(faces)
    a.geo.detachPoints(faces)
    a.geo.movePoints(a.geo.pointsOf(faces), d)
    a.releaseTextures(hold)
  a.transformSelectedGroups(affineOf(proc(p: Vec3): Vec3 = p + d))
  a.push editCmd(label, sel, before, geoBefore, a.geo)

proc rotateSelection*(a: App, axis: Vec3, deg: float32, label = "Rotate") =
  ## Rotates the selection about its center (objects also turn in place).
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  if sel.len == 0 and not geoSel: return
  let (ok, pivot) = a.selectionCenter
  if not ok: return
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  for o in sel:
    let r = turnRotation(o.rot, axis, deg)
    let p = if sel.len > 1 or geoSel: rotateAxis(o.pos, pivot, axis, deg) else: o.pos
    a.setPose(o, p, r)
  if geoSel:
    let faces = a.selectedFaceSet
    let hold = a.holdTextures(faces)
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg))
    a.releaseTextures(hold)
  a.transformSelectedGroups(affineOf(proc(p: Vec3): Vec3 = rotateAxis(p, pivot, axis, deg)))
  a.push editCmd(label, sel, before, geoBefore, a.geo)

proc boxCenter(o: LevelObject): Vec3 =
  let (lo, hi) = o.pickBox
  (lo + hi) / 2

proc flipSelection*(a: App, axis: int) =
  ## Mirrors the selection across its center on one world axis, like
  ## TrenchBroom's flipSelection: geometry (including what objects own) is
  ## mirrored exactly, each object's box center is mirrored, and its facing and
  ## up directions are mirrored (TrenchBroom's entityYawPitchRoll; the local X
  ## side axis follows, since the pose has to stay a rotation). The center is
  ## snapped to half the grid, so odd-sized selections don't shift (TrenchBroom
  ## issue 1495).
  let sel = a.selection
  let geoSel = (a.selPieces.len > 0 or a.selFaces.len > 0) and a.geo != nil
  if sel.len == 0 and not geoSel: return
  let (ok, lo, hi) = a.selectionBounds
  if not ok: return
  let half = a.grid / 2
  let mid = (lo + hi) / 2
  let c = vec3(snapTo(mid.x, half), snapTo(mid.y, half), snapTo(mid.z, half))
  proc mirror(p: Vec3): Vec3 =
    result = p
    result[axis] = 2 * c[axis] - p[axis]
  proc mirrorDir(d: Vec3): Vec3 =
    result = d
    result[axis] = -d[axis]
  let geoBefore = if a.geo != nil: a.geo.clone else: nil
  let before = snapshotObjects(sel)
  var faces = if geoSel: a.selectedFaceSet else: initHashSet[int]()
  for o in sel:
    if a.geo != nil and o.objectCode != -1:
      for fi in a.geo.objectFaces(o.objectCode): faces.incl fi
    let m = objectMatrix(vec3(0, 0, 0), o.rot)
    let rot = objectRotation(-mirrorDir(m * vec3(1, 0, 0)), mirrorDir(m * vec3(0, 1, 0)),
                             mirrorDir(m * vec3(0, 0, 1)))
    # Where the box center sits relative to the position once turned.
    let (oldPos, oldRot) = (o.pos, o.rot)
    let target = mirror(o.boxCenter)
    o.pos = vec3(0, 0, 0)
    o.rot = rot
    let offset = o.boxCenter
    o.pos = oldPos
    o.rot = oldRot
    var pos = target - offset
    let doorCenter = if o.tag == "DOOR": o.node.xpath("OSD/Center") else: nil
    let oldCenter = if doorCenter != nil: parseVec3(doorCenter.str) else: vec3(0, 0, 0)
    case o.tag
    of "SNDG":
      # The sound volume is an axis-aligned box around the position.
      let bmin = o.node.xpath("OSD/Box/Min")
      let bmax = o.node.xpath("OSD/Box/Max")
      if bmin != nil and bmax != nil:
        let (l, h) = (parseVec3(bmin.str), parseVec3(bmax.str))
        if l != h:
          pos = mirror(o.pos)
          var nl = l
          var nh = h
          nl[axis] = -h[axis]
          nh[axis] = -l[axis]
          bmin.setText(fmtVec3(nl))
          bmax.setText(fmtVec3(nh))
    of "TRGV":
      # The trigger volume spans position .. position + size.
      let s = parseVec3(o.node.xpath("OSD/Size").str)
      if s != vec3(0, 0, 0):
        pos = mirror(o.pos + s)
        pos[(axis + 1) mod 3] = o.pos[(axis + 1) mod 3]
        pos[(axis + 2) mod 3] = o.pos[(axis + 2) mod 3]
    else: discard
    a.setPose(o, pos, rot, moveGeometry = false)
    if doorCenter != nil: doorCenter.setText(fmtVec3(mirror(oldCenter)))
  if faces.len > 0:
    # Objects' own geometry is their model: its textures always go with it.
    let hold = if geoSel: a.holdTextures(a.selectedFaceSet) else: @[]
    a.geo.detachPoints(faces)
    a.geo.transformPoints(a.geo.pointsOf(faces), mirror)
    a.geo.reverseWinding(faces)
    a.releaseTextures(hold)
  a.transformSelectedGroups(affineOf(mirror))
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
  if file == nil and tag in LightTags:
    for f in a.files:
      if f.path == a.proj.lightsPath: file = f
  if file == nil:
    let path = if tag in LightTags: a.proj.lightsPath
               else: a.proj.objectsDir / "BINACJBO" & FileNames[tag] & ".xml"
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
  if tag notin AimedTags: o.rot = vec3(0, 0, 0)   # a sun or spot keeps its slant
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

proc findIssues*(a: App, extra: seq[(Severity, string)] = @[]) =
  ## Fills the Issues list; `extra` adds lines from elsewhere (a build log's
  ## warnings) that the checks here don't already name. An issue that was
  ## already listed keeps the time it was first found.
  var seen: Table[string, float]
  for iss in a.issues: seen[iss.text] = iss.time
  a.issues.setLen 0
  var ids: CountTable[int]
  var player = false
  for o in a.objects:
    ids.inc o.id
    if o.tag == "CHAR" and "IsPlayer" in o.node.xpath("OSD/Flags").str: player = true
  if not player:
    a.issues.add Issue(severity: sevWarning, text: "No player start (a character with the IsPlayer flag)", face: -1)
  for o in a.objects:
    if ids[o.id] > 1:
      a.issues.add Issue(severity: sevError, text: &"{typeName(o.tag)} #{o.id}: duplicate object id", obj: o, face: -1)
    if o.tag in ["CHAR", "FURN", "WEAP", "PWRU", "CONS", "DOOR", "TURR", "TRIG"] and
       o.node.xpath("OSD/Class").str.strip.len == 0:
      a.issues.add Issue(severity: sevError, text: &"{typeName(o.tag)} #{o.id}: no class", obj: o, face: -1)
  if a.geo != nil:
    var known = toHashSet(a.textures)
    var missing: CountTable[string]
    for i, f in a.geo.faces:
      if f.verts.len < 3:
        a.issues.add Issue(severity: sevError, text: &"Face {i}: fewer than three corners", face: i)
      elif not (f.isMarkerFace or f.isInvisibleFace) and f.texture notin known and f.texture != "NONE":
        missing.inc f.texture
    for t, n in missing:
      a.issues.add Issue(severity: sevWarning, text: &"Texture {t} ({n} faces): no image in env/images", face: -1)
    for fp in a.geo.faceProblems:
      a.issues.add Issue(severity: fp.severity, text: &"{fp.faceRef.capitalizeAscii}: {fp.text}", face: fp.face, corner: fp.corner)
  for (sev, l) in extra:
    let text = l.capitalizeAscii
    if a.issues.anyIt(it.text == text): continue
    let (face, corner) = if a.geo != nil: parseFaceRef(text) else: (-1, -1)
    a.issues.add Issue(severity: sev, text: text, face: face, corner: corner)
  if a.mcpPortIssue.len > 0:
    a.issues.add Issue(severity: sevError, text: a.mcpPortIssue, face: -1, mcpPort: true)
  if a.crashReport.len > 0:
    a.issues.add Issue(severity: sevError, text: CrashIssue, face: -1, report: a.crashReport)
  a.issues.sort(proc(x, y: Issue): int = cmp(x.severity, y.severity))   # Errors first; stable.
  let now = epochTime()
  a.issuesTime = now
  for iss in a.issues.mitems: iss.time = seen.getOrDefault(iss.text, now)

include groups
