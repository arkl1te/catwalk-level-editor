## Catwalk, a level editor for Oni: TrenchBroom-style editing of a level's
## geometry and objects, built and played through OniSplit and the Custom Game mod.

import std/[os, strutils, times, math, sets]
from std/unicode import Rune, `$`
import silky, vmath, bumpy, pixie, opengl
from pixie/fileformats/svg import parseSvg, newImage
import theme, ui, icons, dialogs, menutree, xwin, colorpick
import project, camera, render, appstate, viewtools, panels, objtemplates, music, pie

const
  AppVersion = staticRead("../VERSION").strip
  FontData = staticRead("../assets/fonts/IBMPlexSans-Regular.ttf")
  MonoFontData = staticRead("../assets/fonts/IBMPlexMono-Regular.ttf")
  IconSvg = staticRead("../assets/catwalk.svg")
  # logo.svg with its text converted to paths (pixie can't draw <text>); see the Makefile.
  LogoSvg = staticRead("../assets/logo-paths.svg")

proc frame(a: App) =
  let now = epochTime()
  let dt = clamp(float32(now - a.lastTime), 0, 0.1)
  a.lastTime = now
  a.pollJob()
  a.autoBuildPreviews()
  a.autoExtractSky()
  if a.dialog != nil:
    var done = false
    let res = a.dialog.poll(done)
    if done:
      let purpose = a.dialog.purpose
      a.dialog = nil
      if res.len > 0:
        let dir = res[0]
        case purpose
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
  ui.eyedropperInput()   # while it's picking, the next click is its
  # Menus first: they take the mouse before anything under them.
  a.menuSys.captureInput(ui)
  a.pieInput()   # the render-mode pie (Z) takes the mouse while it's open
  a.drawMenuBar()
  a.drawSettings()
  a.drawOptions()
  a.drawSavePrompt()
  a.drawNamePrompt()
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
  ui.sampleUnderMouse()   # the finished frame, for the eyedropper
  # Silky's own text-input layer (unused here) switches rune input off in
  # endUi; without it Windy drops typed characters. Windy calls onFrame before
  # reading events, so turning it back on here covers the events that follow.
  a.window.runeInputEnabled = true
  a.window.swapBuffers()
  # Menu popups live in their own windows, so they can extend past this one.
  # Draw them only after the main swap (see Majestic's renderPopups).
  a.menuSys.renderPopups(ui)
  a.window.runeInputEnabled = true

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
  let a = App(cfg: loadConfig(), gridIndex: GridKeyBase + 3, snap: true, showGrid: true,
              hoverView: -1, maximized: -1, layout: pl3, previewParts: {ppLights, ppSounds},
              previewSoundVolume: 1, previewMusicVolume: 1, dock: defaultDock(),
              opts: ViewOptions(mode: rmDynamicLight, models: true, sky: true), lastTime: epochTime(), zoom2D: 0.5, flySpeed: DefaultFlySpeed, texThumb: DefaultTexThumb, codeFontSize: DefaultCodeFontSize,
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
    a.focusLostAt = if a.window.focused: 0.0 else: epochTime()
  a.window.onRune = proc(r: Rune) =
    if r.int32 >= 32: a.ui.typedPending.add $r
  a.rend = newRenderer()
  a.views[0].cam = Camera(kind: vk3D, fovY: a.defaultFov, pos: vec3(0, 100, 300))
  a.views[1].cam = Camera(kind: vkTop, zoom: 0.5)
  a.views[2].cam = Camera(kind: vkFront, zoom: 0.5)
  a.views[3].cam = Camera(kind: vkSide, zoom: 0.5)
  a.say "Catwalk " & AppVersion

  let args = commandLineParams()
  if args.len > 0: a.openProjectDir(args[0].absolutePath)

  a.window.onFrame = proc() = a.frame()
  while true:
    pollEvents()
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

main()
