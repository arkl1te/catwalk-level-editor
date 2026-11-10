## Setup window: on the first run (no AE folder set yet), a dialog window over
## the main one asks where Oni's AE folder and the game are. Laid out like
## Majestic's Run window: a row per path, its field and a folder button, and the
## buttons along the bottom. Auto-detect looks where Oni usually is
## (project.detectOni) and takes the game's Oni.exe rather than a script.
##
## Drawn as Majestic draws its dialog windows: after the main window's swap,
## into the main window's back buffer, then put into this window by X (see
## ui.beginOffscreen and xwin_x11's putPixelsOn), so it needs no GL context of
## its own. On Windows the main context draws into it directly.

import std/[os, strutils]
from std/unicode import Rune, `$`
import silky, vmath, bumpy, chroma, pixie, opengl
import ui, theme, dialogs, xwin, project, appstate

const
  SetupSize = ivec2(640, 290)
  RowsTop = 66'f32
  RowH = 60'f32
  LabelW = 110'f32

proc homeShort(path: string): string =
  ## path with the home folder written as ~.
  let home = getHomeDir().strip(leading = false, chars = {'/', '\\'})
  if path.startsWith(home): "~" & path[home.len .. ^1] else: path

proc openSetup*(a: App, icon: Image) =
  ## Shows the Setup window, its fields holding the current settings; icon is
  ## the app's.
  if a.setupWin == nil:
    let w = newWindow("Set up Catwalk", SetupSize, style = Decorated, visible = false, vsync = false)
    # Windy made the new window's context current; it is drawn with the main
    # one's (see the module's comment).
    makeContextCurrent(a.window)
    w.icon = icon
    w.setDialogFor(a.window)
    a.setupSk = newSilky(w, a.sk.image, a.sk.atlas)
    a.setupSk.uiScale = a.sk.uiScale
    a.setupSk.atlasScale = a.sk.atlasScale
    a.setupUi = newUi(a.setupSk, w)
    let ui = a.setupUi
    w.onRune = proc(r: Rune) =
      if r.int32 >= 32: ui.typedPending.add $r
    a.setupWin = w
  (a.setupAe, a.setupGame) = (a.cfg.aeDir, a.cfg.game)
  a.setupNote = ""
  a.setupNoteBad = false
  # Centered on the main window's frame, on its monitor.
  let w = a.setupWin
  var pos = a.window.framePos + (a.window.size - SetupSize) div 2
  let m = monitorAt(a.window.pos + a.window.size div 2)
  pos.x = clamp(pos.x, m.pos.x, max(m.pos.x, m.pos.x + m.size.x - SetupSize.x))
  pos.y = clamp(pos.y, m.pos.y, max(m.pos.y, m.pos.y + m.size.y - SetupSize.y))
  w.placeDialog(pos, SetupSize)
  w.visible = true
  w.activate()

proc closeSetup(a: App) =
  a.setupUi.focusId = ""
  a.setupWin.visible = false
  a.window.activate()

proc autoDetect(a: App) =
  let (ae, game, found) = detectOni()
  if ae.len == 0:
    a.setupNote = "Oni isn't in any of the usual places: pick its AE folder and Oni.exe."
    a.setupNoteBad = true
    return
  (a.setupAe, a.setupGame) = (ae, game)
  a.setupNoteBad = false
  a.setupNote =
    if found.len > 1: "Found " & $found.len & " AE installs; took " &
                      (if ae.hasArklite: "the first with Arklite." else: "the first.")
    else: "Found Oni in " & ae.homeShort & "."

proc setupPicked*(a: App, purpose, path: string) =
  ## A file dialog the Setup window opened chose path (catwalk.nim polls it).
  if a.setupWin == nil: return
  if purpose == "setupae":
    a.setupAe = path
    # The game usually sits in the folder picked: fill it in if it isn't set.
    if not fileExists(a.setupGame): a.setupGame = gameExe(path)
  else: a.setupGame = path
  a.setupNote = ""

proc save(a: App) =
  let ae = a.setupAe.strip.expandTilde
  let game = a.setupGame.strip.expandTilde
  if not ae.isAeDir:
    a.setupNote = "The AE folder needs Tools/OniSplit.exe and GameDataFolder."
  elif not fileExists(game):
    a.setupNote = "Pick the game: Oni.exe, or a script that starts it."
  else:
    a.cfg.aeDir = ae
    a.cfg.game = game
    try: a.cfg.save()
    except CatchableError as e:
      a.setupNote = "Can't save the settings: " & e.msg
      a.setupNoteBad = true
      return
    a.say "Oni: " & ae.homeShort & ", started with " & game.homeShort
    a.closeSetup()
    return
  a.setupNoteBad = true

proc aeStatus(dir: string): (string, ColorRGBX) =
  let d = dir.strip.expandTilde
  if d.len == 0: ("Has Tools/OniSplit.exe and GameDataFolder.", colTextDim)
  elif not d.isAeDir: ("No Tools/OniSplit.exe and GameDataFolder here.", colError)
  elif not d.hasArklite: ("Arklite isn't installed here: the game won't find your maps without it.", colWarning)
  else: ("OniSplit, the game data and Arklite are here.", colTextDim)

proc gameStatus(path: string): (string, ColorRGBX) =
  let p = path.strip.expandTilde
  if p.len == 0: ("Oni.exe, or a script that starts it.", colTextDim)
  elif not fileExists(p): ("Not found.", colError)
  elif p.isExe:
    when defined(windows): ("Play starts it.", colTextDim)
    else:
      let prefix = winePrefixOf(p)
      if findExe("wine").len == 0: ("Play starts it with Wine, which isn't installed.", colError)
      elif prefix.len > 0: ("Play starts it with Wine, in the prefix " & prefix.homeShort & ".", colTextDim)
      else: ("Play starts it with Wine.", colTextDim)
  else: ("Play runs this script with ARKLITE_AUTOSTART set.", colTextDim)

proc draw(a: App, r: Rect) =
  let ui = a.setupUi
  let w = a.setupWin
  ui.textIn("Where is Oni?", rect(r.x + 16, r.y + 12, r.w - 32, 22), colText)
  ui.textIn(ui.ellipsize("Catwalk builds your maps into Oni's AE folder and starts the game to play them.",
    r.w - 32, FontSmall), rect(r.x + 16, r.y + 36, r.w - 32, 18), colTextDim, FontSmall)

  proc row(i: int, label, id: string, value: var string, status: (string, ColorRGBX),
           tip: string): bool =
    ## A path row: its field and folder button; true when the button is pressed.
    let y = r.y + RowsTop + i.float32 * RowH
    let fr = rect(r.x + 16 + LabelW, y, r.w - 32 - LabelW, 28)
    ui.textIn(label, rect(r.x + 16, y, LabelW - 12, fr.h), colText)
    discard ui.textField(id, rect(fr.x, fr.y, fr.w - 32, fr.h), value)
    result = ui.iconButton(id & "-browse", rect(fr.x + fr.w - 28, fr.y, 28, fr.h), "folder20", tip)
    ui.textIn(ui.ellipsize(status[0], fr.w, FontSmall), rect(fr.x, fr.y + fr.h + 2, fr.w, 18),
      status[1], FontSmall)

  if row(0, "AE folder", "setup-ae", a.setupAe, aeStatus(a.setupAe), "Choose Oni's AE folder"):
    let start = a.setupAe.strip.expandTilde
    a.dialog = startDialog(dkOpenDir, "setupae", "Oni's AE folder",
      if dirExists(start): start else: getHomeDir())
  if row(1, "Game", "setup-game", a.setupGame, gameStatus(a.setupGame),
         "Choose Oni.exe, or a script that starts it"):
    let start = a.setupGame.strip.expandTilde
    a.dialog = startDialog(dkOpenFile, "setupgame", "Oni.exe, or a script that starts it",
      if fileExists(start): start elif dirExists(a.setupAe): a.setupAe else: getHomeDir(),
      @["exe"], "Oni.exe", @[("Scripts", @["sh"])])
  if a.setupNote.len > 0:
    ui.textIn(ui.ellipsize(a.setupNote, r.w - 32, FontSmall),
      rect(r.x + 16, r.y + RowsTop + 2 * RowH, r.w - 32, 18),
      if a.setupNoteBad: colError else: colText, FontSmall)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if ui.textButton("setup-detect", rect(r.x + 16, by, 110, 30), "Auto-detect"): a.autoDetect()
  ui.tip(rect(r.x + 16, by, 110, 30), "Look for Oni in the usual places: Wine prefixes " &
    "(Lutris, Bottles, Heroic, Steam's Proton) and Program Files")
  let cancel = ui.textButton("setup-cancel", rect(r.x + r.w - 212, by, 92, 30), "Cancel")
  var ok = ui.textButton("setup-save", rect(r.x + r.w - 112, by, 92, 30), "Save", primary = true)
  # Enter saves, also from a field.
  if not ui.enterUsed and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]): ok = true
  if ok: a.save()
  elif cancel or ui.focusId.len == 0 and w.buttonPressed[KeyEscape]: a.closeSetup()

proc renderSetup*(a: App) =
  ## Draws the Setup window; call after the main window's swap.
  if not a.setupOpen: return
  let w = a.setupWin
  if w.closeRequested:
    w.closeRequested = false
    a.closeSetup()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let ui = a.setupUi
  # On Windows the main window's GL context draws straight into this one
  # (same pixel format; see xwin_win32's beginDrawOn), as Majestic does.
  when defined(windows):
    if not w.beginDrawOn(): return  # retried next frame
  else:
    a.setupSk.beginOffscreen(a.window.size, size, colPanel)
  ui.beginFrame()
  a.setupSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255, colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  a.draw(rect(vec2(0, 0), ui.size))
  discard ui.tabNavigate()
  ui.drawTooltip()
  a.setupSk.endUi()
  ui.endFrame()
  when defined(windows):
    w.endDrawOn(a.window)
  else:
    a.setupSk.endOffscreen()
    w.putPixels(size, offscreenPixels())
  w.runeInputEnabled = true
