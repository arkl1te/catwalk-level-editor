## Catwalk, a level editor for Oni: TrenchBroom-style editing of a level's
## geometry and objects, built and played through OniSplit and the Custom Game mod.

import std/[os, sequtils, strutils, times, math, sets]
from std/unicode import Rune, `$`
import silky, vmath, bumpy, pixie, opengl
from pixie/fileformats/svg import parseSvg, newImage
import theme, ui, icons, dialogs, menutree, xwin, colorpick
import project, camera, render, appstate, viewtools, panels, objtemplates, music, pie, mcp, mcptools,
       screenshot, crashlog, setupwin, frameprof
from library import renderPreviewsCli

template staticBytes(path: string): untyped =
  ## A file's bytes, embedded at compile time.
  const s = staticRead(path)
  var bytes: array[s.len, byte]
  for i, c in s: bytes[i] = byte(c)
  bytes

const
  AppVersion = staticRead("../VERSION").strip
  # Bytes, not strings: MSVC refuses a C string literal past 64 KB (Majestic's fix).
  FontData = staticBytes("../assets/fonts/IBMPlexSans-Regular.ttf")
  MonoFontData = staticBytes("../assets/fonts/IBMPlexMono-Regular.ttf")
  IconSvg = staticRead("../assets/catwalk.svg")
  # logo.svg with its text converted to paths (pixie can't draw <text>); see the Makefile.
  LogoSvg = staticRead("../assets/logo-paths.svg")

proc noteState(a: App) =
  ## What a crash report says the editor was doing.
  let selected = a.selection
  var s = "Project: " & (if a.proj != nil: a.proj.title & " (" & a.proj.dir & ")" else: "none") &
          "\nTool: " & $a.tool & "\nDrag: " & $a.drag.kind & "\nSelected: " & $selected.len &
          " objects, " & $a.selPieces.len & " pieces, " & $a.selFaces.len & " faces"
  if selected.len > 0: s.add " (first: " & selected[0].tag & ")"
  if a.geo != nil: s.add "\nGeometry: " & $a.geo.pieces.len & " pieces, " & $a.geo.faces.len & " faces"
  s.add "\nObjects: " & $a.objects.len & "\nLayout: " & $a.layout & "\nRender mode: " & $a.opts.mode &
        "\nRealtime preview: " & $a.realtime & "\nUnsaved changes: " & $a.dirty
  if a.busy: s.add "\nRunning: " & a.job.title
  for l in a.loads: s.add "\nLoading: " & l.loadState
  setContext(s)

proc frame(a: App) =
  a.noteState()
  let now = epochTime()
  let dt = clamp(float32(now - a.lastTime), 0, 0.1)
  a.lastTime = now
  a.updateCamAnim()
  a.pollJob()
  a.pollLoads()
  a.autoLoad()
  a.pollMcp(AppVersion)
  if a.dialog != nil:
    var done = false
    let res = a.dialog.poll(done)
    if done:
      let purpose = a.dialog.purpose
      a.dialog = nil
      if res.len > 0:
        let dir = res[0]
        case purpose
        of "textures": a.importTextures(res)
        of "sounds": a.importSounds(res)
        of "fieldsound":
          a.importSounds(res, a.soundImportPick)
          a.soundImportPick = nil
        of "sky": a.importSky(dir)
        of "skysource": a.skyConvertFile = dir
        of "setupae", "setupgame": a.setupPicked(purpose, dir)
        of "screenshot":
          # Read from this frame, once it's drawn.
          let app = a
          a.afterFrame.add proc() = app.saveScreenshots(dir)
        of "saveas", "savecopy":
          # The dialog doesn't block the editor: a Build or Play started while it
          # was open must finish before the project moves to another folder.
          a.pendingSave = (purpose, dir)
          if a.busy: a.say("Saving after " & a.job.title & " finishes")
        else: a.whenSaved(proc() = a.openProjectDir(dir))
  if a.pendingSave[0].len > 0 and not a.busy:
    let (purpose, dir) = a.pendingSave
    a.pendingSave = ("", "")
    a.saveProjectAs(dir, keepWorking = purpose == "savecopy")

  let ui = a.ui
  let s = a.sk.uiScale
  let size = a.window.size
  let usz = size.vec2 / s
  inc a.frameNo
  wantCursor = ArrowCursor
  let top = MenuBarHeight + ToolbarHeight
  let mainH = usz.y - top - StatusHeight
  let panelsR = rect(0, top, usz.x, mainH)
  if a.proj != nil: a.layoutPanels(panelsR)
  else: a.viewsArea = rect(0, 0, 0, 0)
  a.layoutViews(a.viewsArea)
  a.updateLastSelection()
  a.updateFaceTemplate()

  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255, colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  a.sk.beginUi(a.window, size)
  ui.beginFrame()
  # The Setup window is modal: the main window takes no clicks while it's open.
  if a.setupOpen: ui.mouse = vec2(-1e6, -1e6)
  ui.eyedropperInput()   # while it's picking, the next click is its
  # Menus first: they take the mouse before anything under them.
  a.menuSys.captureInput(ui)
  a.pieInput()   # the render-mode pie (Z) takes the mouse while it's open
  a.drawMenuBar()
  a.drawSettings()
  a.drawSavePrompt()
  a.drawNamePrompt()
  a.drawSkyConvert()
  a.drawSkyImport()
  a.drawAmbientEditor()
  a.drawToolbar()
  if a.proj == nil:
    a.drawWelcome(rect(0, top, usz.x, mainH))
  else:
    a.drawPanels(panelsR)
  a.drawStatus()
  a.updateRealtime()
  a.updateParticles()
  if a.proj != nil:
    if not ui.captured or a.drag.kind != dkNone: a.handleViews(dt)
    if not ui.captured:
      let app = a
      a.handleKeys(proc(label: string): bool = app.runMenu(label))
    a.autoBake()
    a.drawViews()
    a.drawViewOverlays()
    a.drawParticlePanel()
  elif not ui.captured:
    let app = a
    a.handleKeys(proc(label: string): bool = app.runMenu(label))
  a.updateMenus()
  let selBefore = a.selRecorded
  a.expandGroupSelection()
  a.recordSelection()
  a.endMerge()
  # The rotate tool's center follows the selection (it's otherwise only set
  # when the tool opens).
  if a.tool == toolRotate and not sameSel(selBefore, a.selRecorded): a.resetRotateCenter()
  # Tab / Shift+Tab move keyboard focus through the panels (a dialog keeps it
  # among its own controls).
  if not a.modalOpen and not a.menuSys.isOpen: discard ui.tabNavigate()
  a.drawPie()
  ui.drawTooltip()
  ui.endFrame()
  if eyedropperActive(): wantCursor = CrosshairCursor
  a.applyCursor()
  a.sk.endUi()
  for action in a.afterFrame: action()
  a.afterFrame.setLen 0
  if a.settingsSaved:
    a.settingsSaved = false
    a.applyMcp()
  a.updateWindowTitle()
  ui.sampleUnderMouse()   # the finished frame, for the eyedropper
  # Silky's own text-input layer (unused here) switches rune input off in
  # endUi; without it Windy drops typed characters. Windy calls onFrame before
  # reading events, so turning it back on here covers the events that follow.
  a.window.runeInputEnabled = true
  a.window.swapBuffers()
  # Menu popups live in their own windows, so they can extend past this one.
  # Draw them only after the main swap (see Majestic's renderPopups).
  a.menuSys.renderPopups(ui)
  a.renderSetup()
  a.window.runeInputEnabled = true

# --- drawing only when needed ----------------------------------------------------------
# Like TrenchBroom, which repaints a view only when something in it changed:
# a frame is drawn when input arrived, while something moves (a drag, a
# camera glide, Realtime preview, a job), and otherwise 10 times a second
# (timers, tooltips, the MCP server). In between the loop sleeps until input.

const IdleFrame = 0.1   ## Seconds between frames when nothing moves.
var wake = true         ## Input arrived since the last frame.
var idle = false        ## The last onFrame drew nothing.
var lastDraw = 0.0

proc moving(a: App): bool =
  ## Whether frames must come at the display's rate.
  if a.busy or a.loads.len > 0 or a.realtime or a.particlePlaying.len > 0 or a.camAnim.on or
     a.drag.kind != dkNone or a.menuSys.isOpen or a.setupOpen or
     epochTime() - a.dupFlashAt < 1:
    return true
  for b in Button:
    if a.window.buttonDown[b]: return true   # a key or button held: flying, dragging

when defined(windows):
  proc msgWaitForMultipleObjects(n: int32, handles: pointer, waitAll: int32, ms: int32,
                                 wakeMask: int32): int32 {.stdcall, dynlib: "user32",
                                 importc: "MsgWaitForMultipleObjects".}

proc waitForInput(seconds: float) =
  ## Sleeps until a window message arrives or seconds pass.
  when defined(windows):
    const QsAllInput = 0x04FF'i32
    discard msgWaitForMultipleObjects(0, nil, 0, int32(seconds * 1000), QsAllInput)
  else:
    sleep(max(1, min(8, int(seconds * 1000))))

proc buildAtlas(scale: float32): (Image, SilkyAtlas) =
  let fontPath = getTempDir() / "catwalk-font.ttf"
  if not fileExists(fontPath) or getFileSize(fontPath) != FontData.len:
    writeFile(fontPath, FontData)
  let monoPath = getTempDir() / "catwalk-mono.ttf"
  if not fileExists(monoPath) or getFileSize(monoPath) != MonoFontData.len:
    writeFile(monoPath, MonoFontData)
  let b = newAtlasBuilder(2048, 2)
  var glyphs = AsciiGlyphs
  for s in ["…", "–", "—", "•", "·", "→", "←", "×", "°", "●", "◌", "▸", "»", "−"]: glyphs.add s
  b.addFont(fontPath, FontMain, 15 * scale, glyphs)
  b.addFont(fontPath, FontSmall, 13 * scale, glyphs)
  b.addFont(fontPath, FontTitle, 20 * scale, glyphs)
  b.addFont(monoPath, FontMono, 14 * scale, glyphs)
  for px in CodeFontSizes: b.addFont(monoPath, codeFont(px), px.float32 * scale, glyphs)
  b.addIcons(scale)
  let logo = parseSvg(LogoSvg)
  let lh = round(LogoHeight * scale).int
  discard b.addImage("logo", newImage(parseSvg(LogoSvg, round(lh.float32 * logo.width.float32 / logo.height.float32).int, lh)))
  (b.atlasImage, b.atlas)

proc restoreGeometry(w: Window, a: App) =
  ## Puts the window where it was left, if that spot is still on a monitor.
  if a.winSize.x < 200 or a.winSize.y < 150: return
  let p = a.winPos + ivec2(40, 10)  # a point on the title bar
  let mon = monitorAt(p)
  if p.x < mon.pos.x or p.y < mon.pos.y or
     p.x >= mon.pos.x + mon.size.x or p.y >= mon.pos.y + mon.size.y: return
  w.placeWindow(a.winPos, a.winSize, a.winMaximized)

proc rememberGeometry(w: Window, a: App) =
  ## Keeps the last unmaximized geometry, so restoring a maximized window
  ## un-maximizes to it.
  a.winMaximized = w.maximized
  if not a.winMaximized or a.winSize.x == 0:
    a.winPos = w.framePos
    a.winSize = w.size

proc main() =
  # A GUI program starts without stdout/stderr, and writing to them raises:
  # the terminal's console if started from one, else nowhere. A pipe (the MCP
  # bridge's) is kept.
  when defined(windows): attachStdio()
  var args = commandLineParams()
  if "--mcp" in args:
    runBridge(loadConfig().mcpPort, AppVersion)
    return
  if args.len > 0 and args[0] == "--render-previews":   # The library build's helpers.
    renderPreviewsCli(args[1 .. ^1])
    return
  moveOldDataDir()   # Before the session log opens in the logs folder.
  initLog(AppVersion, args)
  let forceMcp = "--mcp-server" in args
  args.keepItIf(it != "--mcp-server")
  let a = App(cfg: loadConfig(), mcpForced: forceMcp, gridIndex: GridKeyBase + 3, snap: true, showGrid: true,
              hoverView: -1, maximized: -1, layout: pl1, previewParts: {ppLights, ppSounds, ppParticles},
              previewSoundVolume: 1, previewMusicVolume: 1, dock: defaultDock(),
              opts: ViewOptions(mode: rmDynamicLight, models: true, sky: true), showDirections: true, showGizmos: true,
              showEditorOnly: true, notesRange: DefaultNotesRange, editorOnlyParts: {EditorOnlyPart.low .. EditorOnlyPart.high}, lastTime: epochTime(), zoom2D: 0.5, flySpeed: StartFlySpeed, texThumb: DefaultTexThumb, entityPreview: 0.75, newTexLevel: 1, codeFontSize: DefaultCodeFontSize,
              brushHeight: 64, rotateAngle: 15,
              moveBy: "0 0 0", shade: [200.0, 200, 200],
              splitX: 0.55, splitY: 0.5, shapeSides: 8, shapeSteps: 4, treeAnchor: -1,
              extrudeHover: -1, browserPress: (-1, vec2(0, 0)), scaleBySize: true, rotAxis: 1, newSky: Skies[0])
  for c in Categories: a.browserOpen.incl c.generic
  a.loadLayout()
  a.loadPresets()
  when defined(linux): x11ClassName = "catwalk"
  # Created hidden so the saved geometry is in place before the WM places it.
  a.window = newWindow("Catwalk", ivec2(1700, 1000), vsync = true, visible = false)
  when defined(windows):
    # Dark title bar, file drops and the hook the diagonal resize cursors
    # need; file dialogs center on the window.
    a.window.initMainWindow()
    setDialogOwner(a.window.getHWND)
  a.window.restoreGeometry(a)
  a.window.visible = true
  a.window.icon = newImage(parseSvg(IconSvg, 128, 128))
  makeContextCurrent(a.window)
  loadExtensions()
  detectableAutoRepeat()
  let scale = 1'f32
  let (img, atlas) = buildAtlas(scale)
  a.sk = newSilky(a.window, img, atlas)
  a.sk.uiScale = scale
  a.sk.atlasScale = scale
  a.ui = newUi(a.sk, a.window)
  a.menuSys = newMenuSystem()
  a.window.onFocusChange = proc() =
    wake = true
    a.focusLostAt = if a.window.focused: 0.0 else: epochTime()
  a.window.onRune = proc(r: Rune) =
    wake = true
    if r.int32 >= 32: a.ui.typedPending.add $r
  a.window.onMouseMove = proc() = wake = true
  a.window.onScroll = proc() = wake = true
  a.window.onResize = proc() = wake = true
  a.window.onMove = proc() = wake = true
  a.window.onButtonPress = proc(b: Button) = wake = true
  a.window.onButtonRelease = proc(b: Button) = wake = true
  a.rend = newRenderer()
  a.views[0].cam = Camera(kind: vk3D, fovY: a.defaultFov, pos: vec3(0, 100, 300))
  a.views[1].cam = Camera(kind: vkTop, zoom: 0.5)
  a.views[2].cam = Camera(kind: vkFront, zoom: 0.5)
  a.views[3].cam = Camera(kind: vkSide, zoom: 0.5)
  a.say "Catwalk " & AppVersion
  addSystemInfo("Graphics: " & $cast[cstring](glGetString(GL_RENDERER)) & ", OpenGL " &
                $cast[cstring](glGetString(GL_VERSION)))
  a.showCrashReport()

  # First run (or no AE folder chosen yet): ask where Oni is.
  if a.cfg.aeDir.len == 0: a.openSetup(newImage(parseSvg(IconSvg, 128, 128)))
  if args.len > 0: a.openProjectDir(args[0].absolutePath)
  a.applyMcp()

  a.window.onFrame = proc() =
    let now = epochTime()
    if not wake and now - lastDraw < IdleFrame and not a.moving:
      idle = true
      return
    idle = false
    wake = false
    # After a pause, a frame's worth of movement, not the whole pause's (a
    # key pressed to fly would jump).
    if now - lastDraw > 0.05: a.lastTime = now - 1 / 60
    lastDraw = now
    prof "frame": a.frame()
    profFrame()
  while true:
    pollEvents()
    if idle and not wake: waitForInput(IdleFrame - (epochTime() - lastDraw))
    discard a.menuSys.pollInput()
    # Menus close when the window loses focus. Re-checked every iteration, so
    # menus opened or kept open after the focus left still close; the grace
    # period also counts from the opening, as the click that opens a menu on
    # an inactive window activates it a moment later. A press held on a popup
    # is spared, so a focus blip from clicking it can't swallow the item.
    if not a.menuSys.isOpen: a.menuOpenedAt = 0
    elif a.menuOpenedAt == 0: a.menuOpenedAt = epochTime()
    if a.focusLostAt > 0 and epochTime() - max(a.focusLostAt, a.menuOpenedAt) > 0.15 and
       not a.window.focused and a.menuSys.isOpen and
       not (pointerButtonsDown() and a.menuSys.pointerOverPopup(a.ui)):
      a.menuSys.close()
    if a.window.closeRequested:
      if a.quitConfirmed: break
      # Window close or Quit: ask about unsaved changes before leaving.
      a.window.closeRequested = false
      a.whenSaved(proc() =
        a.quitConfirmed = true
        a.window.closeRequested = true)
      if a.quitConfirmed: break
  a.window.rememberGeometry(a)
  a.saveCamera()
  a.saveLayout()
  stopPreview()
  stopScene()
  stopMcp()
  closeLog()

main()
