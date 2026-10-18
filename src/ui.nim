## Small immediate-mode widget layer on top of Silky's drawing primitives.

import std/[strformat, strutils, math]
from std/times import epochTime
import silky, vmath, bumpy, chroma, pixie, opengl
import theme, xwin

type
  Ui* = ref object
    sk*: Silky
    window*: Window
    mouse*: Vec2
    size*: Vec2
    captured*: bool          ## A popup/modal owns the mouse this frame.
    popupRect*: Rect         ## A list drawn over the widgets (a field's dropdown); set each frame it shows.
    popupHit*: bool          ## The mouse is over last frame's popupRect: widgets under it ignore it.
    clickConsumed*: bool     ## The left press/release was handled already.
    activeId*: string        ## Widget currently being dragged.
    pressId*: string         ## Widget the left press started on.
    scrollConsumed*: bool
    tooltip*: string
    tooltipAnchor*: Rect
    fakeMouse*: Vec2         ## debug scripting: overrides the pointer when x >= 0
    hitClips*: seq[Rect]     ## pushClip stack: the mouse only hits widgets inside the last one
    focusId*: string         ## text field owning the keyboard
    caret*: int              ## byte offset of the caret in the focused field
    selAnchor*: int          ## other end of the focused field's selection (== caret: none)
    dragFrom*: int           ## text field press: byte offset under the press
    dragX*: float32          ## text field press: where it happened
    clickCount*: int         ## text field press: 1, 2 (word), 3 (all) in a quick series
    clickTime: float         ## when the last text field press happened
    clickPos: Vec2           ## where
    clickId: string          ## on which field
    fieldScroll*: float32    ## horizontal scroll of the focused field's text
    editText*: string        ## numberField: text being typed
    typed*: string           ## text typed since the previous frame
    typedPending*: string    ## filled by the window's rune callback
    navId*: string           ## widget with keyboard focus (moved with Tab)
    navVisible*: bool        ## keyboard was used last: draw the focus ring
    focusFresh*: bool        ## focusId was just given by Tab, not by a click
    enterUsed*: bool         ## a focused button took Enter this frame
    tabStops*: seq[TabStop]  ## focusable widgets drawn this frame, in order

  TabStop* = object
    id*: string
    r*: Rect
    edit*: bool              ## a text input: focusing it starts editing

  EditEvent* = enum
    eeChanged, eeFocused, eeCommitted

proc readFramebuffer*(size: IVec2): Image =
  result = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()

when not defined(windows):
  var offPixels: seq[uint8]  ## BGRA, top row first: the last offscreen frame

  proc beginOffscreen*(sk: Silky, fb, size: IVec2, background: ColorRGBX) =
    ## Makes sk's next frame, size big, draw into the current (main window's)
    ## back buffer, fb big, in as many tiles as it takes, each read back into
    ## offscreenPixels for putPixels. Only right after the main swap, when
    ## that buffer is free to scribble on. See xwin_x11's putPixelsOn for why.
    offPixels.setLen(max(0, size.x * size.y * 4))
    sk.drawer.tiles.setLen 0
    var rects: seq[tuple[x, y, w, h: int32]]
    if fb.x > 0 and fb.y > 0:
      for ty in countup(0'i32, size.y - 1, fb.y):
        for tx in countup(0'i32, size.x - 1, fb.x):
          let r = (x: tx, y: ty, w: min(fb.x, size.x - tx), h: min(fb.y, size.y - ty))
          rects.add r
          # Lower left corner that puts the tile's rows at the buffer's bottom.
          sk.drawer.tiles.add ivec2(-r.x, r.y + r.h - size.y)
    var tile = newSeq[uint8](min(size.x, fb.x).max(0) * min(size.y, fb.y).max(0) * 4)
    let c = background.color
    sk.drawer.beforeTile = proc (i: int) =
      glClearColor(c.r, c.g, c.b, 1)
      glClear(GL_COLOR_BUFFER_BIT)
    sk.drawer.afterTile = proc (i: int) =
      let r = rects[i]
      glPixelStorei(GL_PACK_ALIGNMENT, 1)
      glReadPixels(0, 0, r.w, r.h, GL_BGRA, GL_UNSIGNED_BYTE, tile[0].addr)
      for y in 0 ..< r.h:  # GL rows run bottom-up
        copyMem(offPixels[((r.y + y) * size.x + r.x) * 4].addr,
                tile[(r.h - 1 - y) * r.w * 4].addr, r.w * 4)

  proc endOffscreen*(sk: Silky) =
    sk.drawer.tiles.setLen 0
    sk.drawer.beforeTile = nil
    sk.drawer.afterTile = nil

  proc offscreenPixels*(): lent seq[uint8] = offPixels

  proc offscreenImage*(size: IVec2): Image =
    ## The last offscreen frame as an image (for screenshots).
    result = newImage(size.x, size.y)
    for i in 0 ..< min(result.data.len, offPixels.len div 4):
      result.data[i] = rgbx(offPixels[i * 4 + 2], offPixels[i * 4 + 1], offPixels[i * 4], 255)

proc newUi*(sk: Silky, window: Window): Ui =
  Ui(sk: sk, window: window, fakeMouse: vec2(-1, -1))

proc scale*(ui: Ui): float32 =
  ## Window pixels per UI unit (Options > Player > UI scaling). Layout,
  ## mouse and sizes here are in UI units.
  ui.sk.uiScale

proc beginFrame*(ui: Ui) =
  ui.mouse = if ui.fakeMouse.x >= 0: ui.fakeMouse else: ui.window.mousePos.vec2 / ui.scale
  # Windy only tracks the pointer from motion events, so a click without a
  # preceding motion (e.g. the first one after the window appears or gets
  # focus) would be tested against a stale position. Ask the server instead.
  if ui.fakeMouse.x < 0:
    for b in [MouseLeft, MouseRight, MouseMiddle]:
      if ui.window.buttonPressed[b] or ui.window.buttonReleased[b]:
        ui.mouse = ui.window.pointerPos.local.vec2 / ui.scale
        break
  ui.size = ui.window.size.vec2 / ui.scale
  ui.captured = false
  let pr = ui.popupRect
  ui.popupHit = pr.w > 0 and ui.mouse.x >= pr.x and ui.mouse.y >= pr.y and
    ui.mouse.x < pr.x + pr.w and ui.mouse.y < pr.y + pr.h
  ui.popupRect = rect(0, 0, 0, 0)
  ui.clickConsumed = false
  ui.scrollConsumed = false
  ui.tooltip = ""
  ui.hitClips.setLen 0
  ui.typed = ui.typedPending
  ui.typedPending = ""
  ui.enterUsed = false
  ui.tabStops.setLen 0
  for b in [MouseLeft, MouseRight, MouseMiddle]:
    if ui.window.buttonPressed[b]: ui.navVisible = false

proc endFrame*(ui: Ui) =
  if ui.window.buttonReleased[MouseLeft] or not ui.window.buttonDown[MouseLeft]:
    ui.activeId = ""
    ui.pressId = ""

proc inside*(p: Vec2, r: Rect): bool =
  p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h

proc hover*(ui: Ui, r: Rect): bool =
  not ui.captured and not ui.popupHit and ui.mouse.inside(r) and
    (ui.hitClips.len == 0 or ui.mouse.inside(ui.hitClips[^1]))

proc pushClip*(ui: Ui, r: Rect) =
  ## Clips drawing and the mouse: widgets scrolled out of r can't be hovered
  ## or clicked through whatever is drawn there instead.
  ui.sk.pushClipRect(r)
  var c = r
  if ui.hitClips.len > 0:
    let p = ui.hitClips[^1]
    let (x0, y0) = (max(c.x, p.x), max(c.y, p.y))
    c = rect(x0, y0, max(0'f32, min(c.x + c.w, p.x + p.w) - x0),
             max(0'f32, min(c.y + c.h, p.y + p.h) - y0))
  ui.hitClips.add c

proc popClip*(ui: Ui) =
  ui.sk.popClipRect()
  discard ui.hitClips.pop()

proc pressed*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonPressed[b] and not (b == MouseLeft and ui.clickConsumed)

proc released*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonReleased[b] and not (b == MouseLeft and ui.clickConsumed)

proc down*(ui: Ui, b = MouseLeft): bool = ui.window.buttonDown[b]

proc consumeClick*(ui: Ui) = ui.clickConsumed = true

proc scroll*(ui: Ui): float32 =
  ## Wheel movement this frame in X11 units: ±10 per notch, + = down.
  if ui.scrollConsumed: return 0
  when defined(windows):
    # Windy reports notches there (WHEEL_DELTA = 1), + = up.
    -ui.window.scrollDelta.y * 10
  else:
    ui.window.scrollDelta.y

proc wheelNotches*(ui: Ui): float32 =
  ## Wheel notches this frame, + = down (added up when several arrive within
  ## one poll).
  ui.scroll() / 10

proc shiftDown*(w: Window): bool = w.buttonDown[KeyLeftShift] or w.buttonDown[KeyRightShift]

# --- keyboard focus ----------------------------------------------------------

proc tabStop*(ui: Ui, id: string, r: Rect, edit = false): bool =
  ## Adds a widget to this frame's Tab order; true when it has keyboard focus.
  ui.tabStops.add TabStop(id: id, r: r, edit: edit)
  ui.navId == id

proc navKey*(ui: Ui, id: string, key: Button): bool =
  ## key was pressed while widget id has keyboard focus (and no text field does).
  ui.navId == id and ui.focusId.len == 0 and ui.window.buttonPressed[key]

proc tabNavigate*(ui: Ui): int =
  ## Moves keyboard focus on Tab / Shift+Tab through this frame's stops.
  ## Returns the index of the newly focused stop, or -1.
  let w = ui.window
  result = -1
  if not w.buttonPressed[KeyTab] or ui.tabStops.len == 0: return
  if w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl] or
     w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]: return
  let n = ui.tabStops.len
  var i = -1
  for k, s in ui.tabStops:
    if s.id == ui.navId: i = k
  result =
    if i < 0: (if w.shiftDown: n - 1 else: 0)
    else: (i + (if w.shiftDown: n - 1 else: 1)) mod n
  let s = ui.tabStops[result]
  ui.navId = s.id
  ui.navVisible = true
  ui.focusId = if s.edit: s.id else: ""
  ui.focusFresh = s.edit

# --- drawing helpers -------------------------------------------------------

proc rect*(ui: Ui, r: Rect, color: ColorRGBX) =
  ui.sk.drawRect(r.xy, r.wh, color)

proc gradient*(ui: Ui, r: Rect, tl, tr, br, bl: ColorRGBX) =
  ## r filled with its corners' colors blended across it (premultiplied).
  let e = ui.sk.atlas.entries[WhiteTileKey]
  let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
  let (p0, p1, p2, p3) = (r.xy, vec2(r.x + r.w, r.y), r.xy + r.wh, vec2(r.x, r.y + r.h))
  ui.sk.drawTriangle([p0, p1, p2], [uv, uv, uv], [tl, tr, br])
  ui.sk.drawTriangle([p0, p2, p3], [uv, uv, uv], [tl, br, bl])

proc border*(ui: Ui, r: Rect, color: ColorRGBX, t = 1'f32) =
  ui.sk.drawRect(r.xy, vec2(r.w, t), color)
  ui.sk.drawRect(vec2(r.x, r.y + r.h - t), vec2(r.w, t), color)
  ui.sk.drawRect(vec2(r.x, r.y), vec2(t, r.h), color)
  ui.sk.drawRect(vec2(r.x + r.w - t, r.y), vec2(t, r.h), color)

proc dashedBorder*(ui: Ui, r: Rect, color: ColorRGBX, dash, gap: float32, t = 1'f32) =
  var x = r.x
  while x < r.x + r.w:
    let w = min(dash, r.x + r.w - x)
    ui.rect(rect(x, r.y, w, t), color)
    ui.rect(rect(x, r.y + r.h - t, w, t), color)
    x += dash + gap
  var y = r.y
  while y < r.y + r.h:
    let h = min(dash, r.y + r.h - y)
    ui.rect(rect(r.x, y, t, h), color)
    ui.rect(rect(r.x + r.w - t, y, t, h), color)
    y += dash + gap

proc textSize*(ui: Ui, s: string, font = FontMain): Vec2 =
  ui.sk.getTextSize(font, s)

proc text*(ui: Ui, s: string, pos: Vec2, color = colText, font = FontMain) =
  discard ui.sk.drawText(font, s, pos.floor, color, clip = false)

proc textIn*(ui: Ui, s: string, r: Rect, color = colText, font = FontMain,
             h = LeftAlign, v = MiddleAlign) =
  ## Draws text clipped and aligned inside a rect.
  discard ui.sk.drawText(font, s, r.xy.floor, color, r.w, r.h, clip = true,
    hAlign = h, vAlign = v)

proc ellipsize*(ui: Ui, s: string, maxW: float32, font = FontMain): string =
  if ui.textSize(s, font).x <= maxW: return s
  var lo = 0
  var hi = s.len
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if ui.textSize(s[0 ..< mid] & "…", font).x <= maxW: lo = mid
    else: hi = mid - 1
  # Avoid cutting a UTF-8 sequence in half.
  while lo > 0 and (s[lo].ord and 0xC0) == 0x80: dec lo
  s[0 ..< lo] & "…"

proc wrapText*(ui: Ui, s: string, width: float32, maxLines: int, font = FontMain): seq[string] =
  ## Greedy word wrap; the last line is ellipsized when text remains.
  var line = ""
  let words = s.split(' ')
  for i, word in words:
    let next = if line.len == 0: word else: line & " " & word
    if line.len > 0 and ui.textSize(next, font).x > width:
      if result.len == maxLines - 1:
        result.add ui.ellipsize(line & " " & words[i .. ^1].join(" "), width, font)
        return
      result.add ui.ellipsize(line, width, font)
      line = word
    else:
      line = next
  if line.len > 0: result.add ui.ellipsize(line, width, font)

proc focusRing*(ui: Ui, r: Rect) =
  ## Keyboard focus marker around a widget, shown after Tab was used.
  if ui.navVisible: ui.border(rect(r.x - 3, r.y - 3, r.w + 6, r.h + 6), colAccent)

proc icon*(ui: Ui, name: string, center: Vec2, color = colText) =
  let sz = ui.sk.getImageSize(name)
  ui.sk.drawImage(name, (center - sz / 2).floor, color)

proc tip*(ui: Ui, r: Rect, s: string) =
  if ui.hover(r): ui.tooltip = s; ui.tooltipAnchor = r

proc drawTooltip*(ui: Ui) =
  if ui.tooltip.len == 0 or ui.sk.mouseIdleTime < 0.5: return
  let lines = ui.wrapText(ui.tooltip, 360, 8, FontSmall)
  let lineH = ui.textSize("Ag", FontSmall).y
  var textW = 0'f32
  for l in lines: textW = max(textW, ui.textSize(l, FontSmall).x)
  let sz = vec2(textW + 14, lineH * lines.len.float32 + 8)
  var p = vec2(ui.mouse.x + 12, ui.tooltipAnchor.y - sz.y - 6)
  p.x = clamp(p.x, 4, ui.size.x - sz.x - 4)
  if p.y < 4: p.y = ui.tooltipAnchor.y + ui.tooltipAnchor.h + 6
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(p, sz), colPopup)
  ui.border(rect(p, sz), colBorder)
  for i, l in lines:
    ui.text(l, p + vec2(7, 4 + lineH * i.float32), colText, FontSmall)
  ui.sk.popLayer()

# --- widgets ---------------------------------------------------------------

proc iconButton*(ui: Ui, id: string, r: Rect, iconName: string, tooltip = "",
                 enabled = true, toggled = false): bool =
  let hov = enabled and ui.hover(r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.consumeClick()
  let isDown = hov and ui.pressId == id and ui.down()
  if isDown: ui.rect(r, colPressed)
  elif hov: ui.rect(r, colHover)
  let col =
    if not enabled: colTextDisabled
    elif toggled: colAccent
    elif hov: colWhite
    else: colText
  ui.icon(iconName, r.xy + r.wh / 2, col)
  if tooltip.len > 0: ui.tip(r, tooltip)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true

proc textButton*(ui: Ui, id: string, r: Rect, label: string, primary = false): bool =
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  let base = if primary: colAccent else: colPanelRaised
  let col =
    if hov and ui.pressId == id and ui.down(): colPressed
    elif hov: (if primary: colAccentHover else: colHover)
    else: base
  ui.rect(r, col)
  if not primary: ui.border(r, colBorder)
  ui.textIn(label, r, if primary: colOnAccent else: colText, h = CenterAlign)
  if focused: ui.focusRing(r)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true
  if ui.navKey(id, KeySpace) or ui.navKey(id, KeyEnter) or ui.navKey(id, NumpadEnter):
    ui.enterUsed = true
    result = true

proc checkbox*(ui: Ui, id: string, pos: Vec2, label: string, value: var bool): bool =
  let box = rect(pos.x, pos.y + 3, 16, 16)
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  if focused: ui.focusRing(r)
  ui.rect(box, if value: colAccent else: colPanelRaised)
  ui.border(box, if hov: colAccent else: colBorder)
  if value: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22), colText)
  if (hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id) or
     ui.navKey(id, KeySpace):
    value = not value
    result = true

proc slider*(ui: Ui, id: string, r: Rect, value: var float, lo, hi, step: float): bool =
  ## Horizontal track with a knob: drag or click it, scroll over it, or
  ## Left/Right (Home/End) while it has keyboard focus. Returns true when
  ## value changed.
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.activeId = id
    ui.navId = id
    ui.consumeClick()
  var v = value
  if ui.activeId == id and ui.down():
    v = lo + clamp((ui.mouse.x - r.x) / r.w, 0, 1) * (hi - lo)
  if hov and ui.scroll() != 0:
    v += (if ui.scroll() < 0: step else: -step)
    ui.scrollConsumed = true
  if ui.navKey(id, KeyRight) or ui.navKey(id, KeyUp): v += step
  if ui.navKey(id, KeyLeft) or ui.navKey(id, KeyDown): v -= step
  if ui.navKey(id, KeyHome): v = lo
  if ui.navKey(id, KeyEnd): v = hi
  v = clamp(round((v - lo) / step) * step + lo, lo, hi)
  if v != value:
    value = v
    result = true
  let cy = r.y + r.h / 2
  let frac = clamp((value - lo) / (hi - lo), 0, 1).float32
  ui.rect(rect(r.x, cy - 2, r.w, 4), colTrack)
  ui.rect(rect(r.x, cy - 2, r.w * frac, 4), colAccent)
  ui.icon("knob16", vec2(r.x + r.w * frac, cy),
    if hov or ui.activeId == id: colWhite else: colText)
  if focused: ui.focusRing(r)

proc radioButton*(ui: Ui, id: string, pos: Vec2, label: string, selected: bool,
                  enabled = true): bool =
  ## Returns true when clicked while not selected.
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = enabled and ui.hover(r)
  let focused = enabled and ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  if focused: ui.focusRing(r)
  let c = vec2(pos.x + 8, pos.y + 11)
  ui.icon("ring16", c, if hov or selected: colAccent else: colBorder)
  if selected: ui.icon("radio16", c, if enabled: colAccent else: colTextDisabled)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22),
    if enabled: colText else: colTextDisabled)
  if (hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id) or
     (focused and ui.navKey(id, KeySpace)):
    result = not selected

proc groupHeader*(ui: Ui, pos: Vec2, w: float32, title: string) =
  ## Section title followed by a rule to the right edge.
  let tw = ui.textSize(title, FontSmall).x
  ui.textIn(title, rect(pos.x, pos.y, tw + 2, 20), colTextDim, FontSmall)
  ui.rect(rect(pos.x + tw + 10, pos.y + 10, max(0'f32, w - tw - 10), 1), colBorder)

proc prevRune(s: string, i: int): int =
  result = max(0, i - 1)
  while result > 0 and (s[result].ord and 0xC0) == 0x80: dec result

proc nextRune(s: string, i: int): int =
  result = min(s.len, i + 1)
  while result < s.len and (s[result].ord and 0xC0) == 0x80: inc result

proc countClick*(ui: Ui, id: string): int =
  ## Call on a left press over text input id: 1, then 2 (select a word) and
  ## 3 or more (select all) for presses in quick succession at the same spot.
  let now = epochTime()
  if id == ui.clickId and now - ui.clickTime < 0.4 and (ui.mouse - ui.clickPos).length <= 4:
    inc ui.clickCount
  else:
    ui.clickCount = 1
  ui.clickId = id
  ui.clickTime = now
  ui.clickPos = ui.mouse
  ui.clickCount

proc charClass*(c: char): int =
  ## What separates words: 0 whitespace, 1 letters, digits, underscores and
  ## any non-ASCII byte (so a UTF-8 character is never split), 2 the rest.
  if c in Whitespace: 0
  elif c in IdentChars or c.ord >= 0x80: 1
  else: 2

proc classes*(s: string): seq[int] =
  for c in s: result.add charClass(c)

proc wordLeft*(cls: openArray[int], i: int): int =
  ## Ctrl+Left from i: start of the word before it. cls holds each item's
  ## class; a run of the same nonzero class is a word, 0 is whitespace.
  result = min(i, cls.len)
  while result > 0 and cls[result - 1] == 0: dec result
  if result > 0:
    let c = cls[result - 1]
    while result > 0 and cls[result - 1] == c: dec result

proc wordRight*(cls: openArray[int], i: int): int =
  ## Ctrl+Right from i: start of the next word.
  result = max(i, 0)
  if result < cls.len and cls[result] != 0:
    let c = cls[result]
    while result < cls.len and cls[result] == c: inc result
  while result < cls.len and cls[result] == 0: inc result

proc wordAround*(cls: openArray[int], i: int): tuple[a, b: int] =
  ## Double-click on item i: the run of items of its class around it.
  if cls.len == 0: return (0, 0)
  let k = clamp(i, 0, cls.len - 1)
  result = (k, k + 1)
  while result.a > 0 and cls[result.a - 1] == cls[k]: dec result.a
  while result.b < cls.len and cls[result.b] == cls[k]: inc result.b

proc wordDrag*(cls: openArray[int], fromItem, toItem: int): tuple[anchor, caret: int] =
  ## Dragging after a double-click selects whole words, from the one first
  ## clicked to the one under the pointer.
  let w0 = wordAround(cls, fromItem)
  let w1 = wordAround(cls, toItem)
  if w1.a >= w0.a: (w0.a, max(w0.b, w1.b)) else: (w0.b, w1.a)

proc textField*(ui: Ui, id: string, r: Rect, text: var string,
                placeholder = ""): set[EditEvent] =
  ## Single-line text input. Focusing it (click or Tab) selects all of its
  ## text; Enter, Tab, Escape or a click elsewhere ends editing (eeCommitted).
  ## Dragging or Shift+click/arrows select, a double-click selects a word and
  ## a triple-click everything; Ctrl+arrows move by words, Ctrl+A/C/X/V work
  ## on the selection.
  let w = ui.window
  let hov = ui.hover(r)
  let pad = 7'f32
  proc hitIndex(text: string, x: float32, nearest = true): int =
    ## Character boundary nearest to window x, or with nearest off, where
    ## the character under x starts.
    let x = x - r.x - pad + ui.fieldScroll
    while result < text.len:
      let j = nextRune(text, result)
      let edge = if nearest: (ui.textSize(text[0 ..< result]).x + ui.textSize(text[0 ..< j]).x) / 2
                 else: ui.textSize(text[0 ..< j]).x
      if x < edge: break
      result = j
  discard ui.tabStop(id, r, edit = true)
  if ui.focusId == id and ui.focusFresh:
    ui.focusFresh = false
    ui.fieldScroll = 0
    ui.selAnchor = 0
    ui.caret = text.len
    result.incl eeFocused
  # A press on the field's dropdown (popupHit) keeps the field focused.
  if ui.focusId == id and w.buttonPressed[MouseLeft] and not hov and not ui.popupHit:
    ui.focusId = ""
    result.incl eeCommitted
  if hov and ui.pressed():
    ui.consumeClick()
    ui.navId = id
    ui.activeId = id
    ui.dragFrom = hitIndex(text, ui.mouse.x)
    ui.dragX = ui.mouse.x
    let clicks = ui.countClick(id)
    if ui.focusId != id:
      ui.focusId = id
      ui.fieldScroll = 0
      ui.selAnchor = 0
      ui.caret = text.len
      result.incl eeFocused
    elif clicks == 2:
      (ui.selAnchor, ui.caret) = wordAround(text.classes, hitIndex(text, ui.mouse.x, false))
    elif clicks >= 3:
      ui.selAnchor = 0
      ui.caret = text.len
    else:
      if not w.shiftDown: ui.selAnchor = ui.dragFrom
      ui.caret = ui.dragFrom
  let focused = ui.focusId == id
  if focused and ui.activeId == id and ui.down() and ui.clickCount == 2:
    (ui.selAnchor, ui.caret) = wordDrag(text.classes,
      hitIndex(text, ui.dragX, false), hitIndex(text, ui.mouse.x, false))
  elif focused and ui.activeId == id and ui.down() and ui.clickCount == 1 and
       abs(ui.mouse.x - ui.dragX) > 3:
    # Dragging selects from the press, even the one that focused the field.
    ui.selAnchor = ui.dragFrom
    ui.caret = hitIndex(text, ui.mouse.x)
  if focused:
    ui.caret = clamp(ui.caret, 0, text.len)
    ui.selAnchor = clamp(ui.selAnchor, 0, text.len)
    let ctrl = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
    let shift = w.shiftDown
    let (s0, s1) = (min(ui.selAnchor, ui.caret), max(ui.selAnchor, ui.caret))
    proc deleteSelection(text: var string) =
      text.delete(s0 ..< s1)
      ui.caret = s0
      ui.selAnchor = s0
    if ctrl and w.buttonPressed[KeyA]:
      ui.selAnchor = 0
      ui.caret = text.len
    if ctrl and (w.buttonPressed[KeyC] or w.buttonPressed[KeyX]) and s1 > s0:
      setClipboardString(text[s0 ..< s1])
      if w.buttonPressed[KeyX]:
        deleteSelection(text)
        result.incl eeChanged
    var ins = ""
    for ch in ui.typed:  # drop control characters such as Tab
      if ch.ord >= 0x20 and ch.ord != 0x7f: ins.add ch
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r", ""), ("\n", " "))
    if ins.len > 0:
      if ui.caret != ui.selAnchor: deleteSelection(text)
      text.insert(ins, ui.caret)
      ui.caret += ins.len
      ui.selAnchor = ui.caret
      result.incl eeChanged
    if (w.buttonPressed[KeyBackspace] or w.buttonPressed[KeyDelete]) and
       ui.caret != ui.selAnchor:
      deleteSelection(text)
      result.incl eeChanged
    elif w.buttonPressed[KeyBackspace] and ui.caret > 0:
      let a = if ctrl: 0 else: prevRune(text, ui.caret)
      text.delete(a ..< ui.caret)
      ui.caret = a
      ui.selAnchor = a
      result.incl eeChanged
    elif w.buttonPressed[KeyDelete] and ui.caret < text.len:
      text.delete(ui.caret ..< nextRune(text, ui.caret))
      result.incl eeChanged
    # Arrows, Home and End move the caret, Ctrl+arrows by words; with Shift
    # they extend the selection, without it a selection collapses to the
    # side moved toward.
    var move = -1
    let (lo, hi) = (min(ui.selAnchor, ui.caret), max(ui.selAnchor, ui.caret))
    if w.buttonPressed[KeyLeft]:
      move = if ctrl: wordLeft(text.classes, ui.caret)
             elif shift or lo == hi: prevRune(text, ui.caret) else: lo
    if w.buttonPressed[KeyRight]:
      move = if ctrl: wordRight(text.classes, ui.caret)
             elif shift or lo == hi: nextRune(text, ui.caret) else: hi
    if w.buttonPressed[KeyHome]: move = 0
    if w.buttonPressed[KeyEnd]: move = text.len
    if move >= 0:
      ui.caret = move
      if not shift: ui.selAnchor = move
    if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or
       w.buttonPressed[KeyTab] or w.buttonPressed[KeyEscape]:
      ui.focusId = ""
      result.incl eeCommitted
  ui.rect(r, colBackground)
  ui.border(r, if focused: colAccent elif hov: colTextDim else: colBorder)
  let inner = rect(r.x + pad, r.y, r.w - pad * 2, r.h)
  ui.pushClip(inner)
  if focused:
    let cx = ui.textSize(text[0 ..< ui.caret]).x
    if cx - ui.fieldScroll > inner.w - 2: ui.fieldScroll = cx - inner.w + 2
    if cx - ui.fieldScroll < 0: ui.fieldScroll = cx
    if ui.selAnchor != ui.caret:
      let ax = ui.textSize(text[0 ..< ui.selAnchor]).x
      ui.rect(rect(inner.x + min(ax, cx) - ui.fieldScroll, r.y + 4, abs(ax - cx), r.h - 8),
        colAccentDim)
    ui.textIn(text, rect(inner.x - ui.fieldScroll, r.y, inner.w + ui.fieldScroll + 4000, r.h), colText)
    ui.rect(rect(inner.x + cx - ui.fieldScroll, r.y + 5, 1, r.h - 10), colAccent)
  elif text.len > 0:
    ui.textIn(text, rect(inner.x, r.y, inner.w + 4000, r.h), colText)
  else:
    ui.textIn(placeholder, rect(inner.x, r.y, inner.w + 4000, r.h), colTextDisabled)
  ui.popClip()

proc evalMath*(s: string): float =
  ## Basic arithmetic typed into a number field: + - * / and parentheses,
  ## as in 24*3+12/2. Raises ValueError on anything else.
  var i = 0
  proc skip() =
    while i < s.len and s[i] in Whitespace: inc i
  proc expr(): float
  proc atom(): float =
    skip()
    if i < s.len and s[i] in {'+', '-'}:
      let neg = s[i] == '-'
      inc i
      let v = atom()
      return if neg: -v else: v
    if i < s.len and s[i] == '(':
      inc i
      result = expr()
      skip()
      if i >= s.len or s[i] != ')': raise newException(ValueError, "missing )")
      inc i
      return
    let start = i
    while i < s.len and s[i] in Digits + {'.'}: inc i
    if i == start: raise newException(ValueError, "number expected")
    result = parseFloat(s[start ..< i])
  proc term(): float =
    result = atom()
    skip()
    while i < s.len and s[i] in {'*', '/'}:
      let op = s[i]
      inc i
      let v = atom()
      result = if op == '*': result * v else: result / v
      skip()
  proc expr(): float =
    result = term()
    skip()
    while i < s.len and s[i] in {'+', '-'}:
      let op = s[i]
      inc i
      let v = term()
      result = if op == '+': result + v else: result - v
      skip()
  result = expr()
  if i < s.len: raise newException(ValueError, "unexpected " & s[i])
  if result.classify in {fcNan, fcInf, fcNegInf}:
    raise newException(ValueError, "not a number")

proc numberField*(ui: Ui, id: string, r: Rect, value: var float,
                  step, lo, hi: float, decimals = 0, axis = -1, live = false): bool =
  ## Type a number (or basic math, worked out on Enter or unfocus), scroll
  ## over it or press Up/Down while typing (Shift: a quarter step). axis
  ## 0..2 colors the left edge with that axis's color. live also takes the
  ## value on every keystroke that leaves a valid number. Returns true when value changed.
  let fid = id & "#field"
  proc fmt(v: float): string =
    if decimals == 0: $int(round(v)) else: formatFloat(v, ffDecimal, decimals)
  if ui.focusId == fid and ui.focusFresh: ui.editText = fmt(value)
  var buf = if ui.focusId == fid: ui.editText else: fmt(value)
  let ev = ui.textField(fid, r, buf)
  if axis in 0 .. 2:
    ui.rect(rect(r.x, r.y, 3, r.h), colAxis[axis])
  if eeFocused in ev:
    buf = fmt(value)
    ui.selAnchor = 0
    ui.caret = buf.len
  # Up/Down and the wheel step the value while typing in it, keeping the
  # field focused. Shift steps by a quarter (a whole number in whole-number
  # fields, so the value never hides a fraction).
  let step =
    if not ui.window.shiftDown: step
    elif decimals == 0: max(1.0, round(step / 4))
    else: step / 4
  var delta = 0.0
  if ui.hover(r) and ui.scroll() != 0:
    delta = if ui.scroll() < 0: step else: -step
    ui.scrollConsumed = true
  let focused = ui.focusId == fid
  if focused:
    if ui.window.buttonPressed[KeyUp]: delta = step
    if ui.window.buttonPressed[KeyDown]: delta = -step
    if delta != 0:
      try:
        let v = clamp(evalMath(buf), lo, hi)
        if v != value:
          value = v
          result = true
      except ValueError: discard
  if focused: ui.editText = buf
  if live and focused and eeChanged in ev:
    try:
      let v = clamp(evalMath(buf), lo, hi)
      if v != value:
        value = v
        result = true
    except ValueError: discard
  if eeCommitted in ev:
    try:
      let v = clamp(evalMath(buf), lo, hi)
      if v != value:
        value = v
        result = true
    except ValueError: discard
  if delta != 0:
    # Snap to the step grid so typed odd values rejoin it.
    let v = clamp(round((value + delta) / step) * step, lo, hi)
    if v != value:
      value = v
      result = true
    if focused:
      ui.editText = fmt(value)
      ui.selAnchor = 0
      ui.caret = ui.editText.len

proc fmtTime*(t: float, millis = false, dur = -1.0): string =
  ## HH:MM:SS, or HH:MM:SS.mmm with millis. MM:SS instead when the media's
  ## duration dur is known and under an hour.
  let ms = max(0, int(t * 1000))
  let s = ms div 1000
  result =
    if dur > 0 and dur < 3600 and s < 3600: &"{s div 60:02}:{s mod 60:02}"
    else: &"{s div 3600:02}:{(s mod 3600) div 60:02}:{s mod 60:02}"
  if millis: result.add &".{ms mod 1000:03}"

proc parseTime*(s: string): float =
  ## The other way from fmtTime: "SS", "MM:SS" or "HH:MM:SS", each with an
  ## optional fraction on the seconds. Raises ValueError on anything else.
  let parts = s.strip.split(':')
  if parts.len > 3: raise newException(ValueError, "too many fields: " & s)
  for i, f in parts:
    let v = f.strip.parseFloat
    if not (v >= 0 and v < Inf) or (i < parts.high and v != floor(v)):
      raise newException(ValueError, "bad field: " & f)
    result = result * 60 + v
