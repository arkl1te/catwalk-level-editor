## Catwalk, a level editor for Oni: TrenchBroom-style editing of a level's
## geometry and objects, built and played through OniSplit and the Custom Game mod.

import std/[os, strutils, times, math, sets]
from std/unicode import Rune, `$`
import silky, vmath, bumpy, pixie, opengl
from pixie/fileformats/svg import parseSvg, newImage
import theme, ui, icons, dialogs, menutree, xwin
import project, camera, render, appstate, viewtools, panels, presets, music

const
  AppVersion = staticRead("../VERSION").strip
  FontData = staticRead("../assets/fonts/IBMPlexSans-Regular.ttf")
  IconSvg = staticRead("../assets/catwalk.svg")

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
  a.inspectorWidth = clamp(a.inspectorWidth, 220, max(220, usz.x - 300))
  a.bottomHeight = clamp(a.bottomHeight, 60, max(60, mainH - OptionsHeight - 160))
  let inspW = if a.showInspector and a.proj != nil: a.inspectorWidth else: 0'f32
  let mapW = usz.x - inspW
  let bottomH = if a.showBottom and a.proj != nil: a.bottomHeight else: 0'f32
  let optionsR = rect(0, top, mapW, OptionsHeight)
  let viewsR = rect(0, top + OptionsHeight, mapW, mainH - OptionsHeight - bottomH - (if bottomH > 0: SplitW else: 0))
  a.layoutViews(viewsR)
  a.updateLastSelection()
  a.updateFaceTemplate()

  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255, colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  a.sk.beginUi(a.window, size)
  ui.beginFrame()
  # Menus first: they take the mouse before anything under them.
  a.menuSys.captureInput(ui)
  a.drawMenuBar()
  a.drawSettings()
  a.drawSavePrompt()
  a.drawToolbar()
  if a.proj == nil:
    a.drawWelcome(rect(0, top, usz.x, mainH))
  else:
    a.drawToolOptions(optionsR)
    if inspW > 0:
      a.drawInspector(rect(mapW + SplitW / 2, top, inspW - SplitW / 2, mainH))
      let (dragging, mx) = a.divider("inspector", rect(mapW - SplitW / 2, top, SplitW, mainH), true)
      if dragging: a.inspectorWidth = usz.x - mx
    if bottomH > 0:
      a.drawBottom(rect(0, top + mainH - bottomH, mapW - SplitW / 2, bottomH))
      let (dragging, my) = a.divider("bottom", rect(0, top + mainH - bottomH - SplitW, mapW - SplitW / 2, SplitW), false)
      if dragging: a.bottomHeight = top + mainH - my - SplitW / 2
    for (id, r, vertical) in a.viewDividers(viewsR):
      let (dragging, p) = a.divider(id, r, vertical)
      if dragging:
        if id == "view.x": a.splitX = clamp((p - viewsR.x) / viewsR.w, 0.1, 0.9)
        else: a.splitY = clamp((p - viewsR.y) / viewsR.h, 0.1, 0.9)
  a.drawStatus()
  if a.proj != nil:
    if not ui.captured or a.drag.kind != dkNone: a.handleViews(dt)
    if not ui.captured:
      let app = a
      a.handleKeys(proc(label: string): bool = app.runMenu(label))
    a.drawViews()
    a.drawViewOverlays()
  elif not ui.captured:
    let app = a
    a.handleKeys(proc(label: string): bool = app.runMenu(label))
  a.updateMenus()
  ui.drawTooltip()
  ui.endFrame()
  a.applyCursor()
  a.sk.endUi()
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
  let b = newAtlasBuilder(2048, 2)
  var glyphs = AsciiGlyphs
  for s in ["…", "–", "—", "•", "·", "→", "←", "×", "°", "●", "◌", "▸", "»", "−"]: glyphs.add s
  b.addFont(fontPath, FontMain, 15 * scale, glyphs)
  b.addFont(fontPath, FontSmall, 13 * scale, glyphs)
  b.addFont(fontPath, FontTitle, 20 * scale, glyphs)
  b.addIcons(scale)
  (b.atlasImage, b.atlas)

proc main() =
  let a = App(cfg: loadConfig(), gridIndex: 3, snap: true, showGrid: true,
              hoverView: -1, maximized: -1, layout: pl3, showInspector: true, showBottom: true,
              opts: ViewOptions(textured: true, models: true, sky: true), lastTime: epochTime(), zoom2D: 0.5, flySpeed: 500,
              inspectorWidth: 360, bottomHeight: 150, brushHeight: 64, rotateAngle: 15,
              moveBy: "0 0 0", shade: [200.0, 200, 200],
              splitX: 0.55, splitY: 0.5, shapeSides: 8, shapeSteps: 4, treeAnchor: -1,
              extrudeHover: -1, scaleBySize: true, rotAxis: 1, newSky: Skies[0])
  a.browserOpen.incl GenericGroup
  a.loadLayout()
  a.loadPresets()
  when defined(linux): x11ClassName = "catwalk"
  a.window = newWindow("Catwalk", ivec2(1700, 1000), vsync = true)
  a.window.icon = newImage(parseSvg(IconSvg, 128, 128))
  makeContextCurrent(a.window)
  loadExtensions()
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
  a.views[0].cam = Camera(kind: vk3D, fovY: 70'f32.degToRad, pos: vec3(0, 100, 300))
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
  a.saveCamera()
  a.saveLayout()
  stopMusic()

main()
