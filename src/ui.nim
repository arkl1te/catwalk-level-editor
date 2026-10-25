## Small immediate-mode widget layer on top of Silky's drawing primitives.

import std/[strformat, strutils, math, tables]
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
    editUndoId: string       ## text input editUndo/editRedo belong to
    editUndo: seq[(string, int)]  ## its text (and caret) before each edit: Ctrl+Z
    editRedo: seq[(string, int)]  ## what Ctrl+Z took back: Ctrl+Shift+Z / Ctrl+Y
    editTyping: bool         ## the last edit was typing: more typing joins its step
    typed*: string           ## text typed since the previous frame
    typedPending*: string    ## filled by the window's rune callback
    navId*: string           ## widget with keyboard focus (moved with Tab)
    navVisible*: bool        ## keyboard was used last: draw the focus ring
    focusFresh*: bool        ## focusId was just given by Tab, not by a click
    focusSeen: bool          ## the focused field was drawn this frame
    focusAtBegin: string     ## focusId when the frame began
    enterUsed*: bool         ## a focused button took Enter this frame
    tabStops*: seq[TabStop]  ## focusable widgets drawn this frame, in order
    navTaken*: set[Button]   ## keys the focused widget listens to this frame (not the views')
    tabTaken*: bool          ## the focused widget used Tab this frame (a code editor indents)
    reveal: bool             ## this frame: scroll revealRect into view (scrollIntoView)
    revealNext: bool         ## set by Tab or a list's arrow keys, for the next frame
    revealRect: Rect         ## where it was drawn (in the frame it was focused)
    revealClip: Rect         ## the scrolled area it was drawn in
    barContent: Table[string, float32]  ## scrollbar id -> content height last frame
    barGrab: float32         ## dragged scrollbar: mouse offset from the thumb's top

  TabStop* = object
    id*: string
    r*: Rect
    edit*: bool              ## a text input: focusing it starts editing
    clip*: Rect              ## the hit clip it was drawn in (w = 0: none)

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
  ui.navTaken = {}
  ui.tabTaken = false
  ui.reveal = ui.revealNext
  ui.revealNext = false
  ui.focusSeen = false
  ui.focusAtBegin = ui.focusId
  # A press drops keyboard focus (back to the views) unless the widget under
  # it takes it.
  for b in [MouseLeft, MouseRight, MouseMiddle]:
    if ui.window.buttonPressed[b]:
      ui.navVisible = false
      ui.navId = ""

proc interacted(ui: Ui): bool =
  ## Any mouse button pressed or the wheel turned this frame.
  ui.window.scrollDelta.y != 0 or ui.window.scrollDelta.x != 0 or
    ui.window.buttonPressed[MouseLeft] or ui.window.buttonPressed[MouseRight] or
    ui.window.buttonPressed[MouseMiddle]

proc endFrame*(ui: Ui) =
  # A field that wasn't drawn this frame (its panel closed or changed) can't
  # see the click that should end its editing: drop it here so it doesn't
  # keep the keyboard away from the views. A focus given during this frame
  # (by this very click) is left alone.
  if ui.focusId.len > 0 and ui.focusId == ui.focusAtBegin and not ui.focusSeen and
     ui.interacted():
    ui.focusId = ""
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

proc keepFocus*(ui: Ui) =
  ## A custom text input that owns the keyboard (focusId) was drawn this frame:
  ## endFrame mustn't drop its focus.
  ui.focusSeen = true

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
proc ctrlDown*(w: Window): bool = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]

# --- keyboard focus ----------------------------------------------------------

proc tabStop*(ui: Ui, id: string, r: Rect, edit = false): bool =
  ## Adds a widget to this frame's Tab order; true when it has keyboard focus.
  let clip = if ui.hitClips.len > 0: ui.hitClips[^1] else: rect(0, 0, 0, 0)
  ui.tabStops.add TabStop(id: id, r: r, edit: edit, clip: clip)
  ui.navId == id

proc navKey*(ui: Ui, id: string, key: Button): bool =
  ## key was pressed while widget id has keyboard focus (and no text field does).
  ## Asking claims key for the widget while it has focus: the views' shortcut
  ## for it stands back (navTaken).
  if ui.navId != id: return false
  ui.navTaken.incl key
  ui.focusId.len == 0 and ui.window.buttonPressed[key]

proc navActivate*(ui: Ui, id: string): bool =
  ## Space or Enter pressed while widget id has keyboard focus.
  result = ui.navKey(id, KeySpace) or ui.navKey(id, KeyEnter) or ui.navKey(id, NumpadEnter)
  if result: ui.enterUsed = true

proc revealLater(ui: Ui, r, clip: Rect) =
  if clip.w <= 0: return
  ui.revealNext = true
  ui.revealRect = r
  ui.revealClip = clip

proc scrollIntoView*(ui: Ui, scroll: var float32) =
  ## Call right after pushClip of a scrolled area, before laying it out: when
  ## Tab (or a list's arrow keys) last frame went to something drawn there out
  ## of sight, scrolls to show it. Larger scroll moves the contents up.
  if not ui.reveal or ui.hitClips.len == 0 or ui.revealClip != ui.hitClips[^1]: return
  ui.reveal = false
  let (r, c) = (ui.revealRect, ui.revealClip)
  if r.y < c.y: scroll -= c.y - r.y + 4
  elif r.y + r.h > c.y + c.h: scroll += r.y + r.h - c.y - c.h + 4

proc tabNavigate*(ui: Ui, lo = 0, hi = -1): int =
  ## Moves keyboard focus on Tab / Shift+Tab through this frame's stops
  ## lo ..< hi (hi -1: all of them; a dialog passes its own).
  ## Returns the index of the newly focused stop, or -1.
  let w = ui.window
  result = -1
  let hi = if hi < 0: ui.tabStops.len else: hi
  if not w.buttonPressed[KeyTab] or hi <= lo or ui.tabTaken: return
  if w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl] or
     w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]: return
  let n = hi - lo
  var i = -1
  for k in lo ..< hi:
    if ui.tabStops[k].id == ui.navId: i = k - lo
  result = lo + (
    if i < 0: (if w.shiftDown: n - 1 else: 0)
    else: (i + (if w.shiftDown: n - 1 else: 1)) mod n)
  let s = ui.tabStops[result]
  ui.navId = s.id
  ui.navVisible = true
  ui.focusId = if s.edit: s.id else: ""
  ui.focusFresh = s.edit
  ui.revealLater(s.r, s.clip)

proc listNav*(ui: Ui, id: string, area: Rect, items: openArray[Rect], cursor: var int,
              horizontal = true): bool =
  ## A list or grid that is one Tab stop: register it with tabStop(id, area)
  ## where it belongs in the Tab order, then call this inside its clip with
  ## every item's rect as laid out this frame (out of sight ones too). A press
  ## in area focuses it; while focused the arrow keys (Left/Right only when
  ## horizontal), Home/End and PageUp/PageDown move cursor, scrolling it into
  ## view next frame. Space/Enter are the caller's (navActivate). Returns true
  ## when cursor moved.
  if ui.hover(area) and ui.window.buttonPressed[MouseLeft]: ui.navId = id
  if ui.navId != id or items.len == 0: return
  if cursor notin 0 .. items.high: cursor = 0
  var to = cursor
  proc row(items: openArray[Rect], k, dir: int): int =
    ## The item in the next row up (dir -1) or down (1) nearest k's column.
    let c = items[k]
    let cx = c.x + c.w / 2
    var rowY = NaN.float32
    for it in items:
      if (dir > 0 and it.y > c.y + 0.5 and not (it.y >= rowY)) or
         (dir < 0 and it.y < c.y - 0.5 and not (it.y <= rowY)): rowY = it.y
    if rowY != rowY: return k  # NaN: no row that way
    result = k
    var best = Inf.float32
    for j, it in items:
      if abs(it.y - rowY) < 0.5 and abs(it.x + it.w / 2 - cx) < best:
        best = abs(it.x + it.w / 2 - cx)
        result = j
  let page = max(1, int(area.h / max(1'f32, items[cursor].h)) - 1)
  if ui.navKey(id, KeyDown): to = row(items, to, 1)
  if ui.navKey(id, KeyUp): to = row(items, to, -1)
  if ui.navKey(id, KeyPageDown):
    for _ in 1 .. page: to = row(items, to, 1)
  if ui.navKey(id, KeyPageUp):
    for _ in 1 .. page: to = row(items, to, -1)
  if ui.navKey(id, KeyHome): to = 0
  if ui.navKey(id, KeyEnd): to = items.high
  if horizontal:
    if ui.navKey(id, KeyLeft): to = max(0, to - 1)
    if ui.navKey(id, KeyRight): to = min(items.high, to + 1)
  if to != cursor:
    cursor = to
    result = true
    ui.navVisible = true
    ui.revealLater(items[to], if ui.hitClips.len > 0: ui.hitClips[^1] else: rect(0, 0, 0, 0))

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

proc roundedOutline(r: Rect, radius: float32): seq[Vec2] =
  ## r's outline with arcs of radius at the corners, clockwise from the top left.
  const n = 4
  let rad = clamp(radius, 0, min(r.w, r.h) / 2)
  let centers = [vec2(r.x + r.w - rad, r.y + rad), vec2(r.x + r.w - rad, r.y + r.h - rad),
                 vec2(r.x + rad, r.y + r.h - rad), vec2(r.x + rad, r.y + rad)]
  for c, ctr in centers:
    for k in 0 .. n:
      let t = (c.float32 - 1 + k.float32 / n) * PI / 2
      result.add ctr + vec2(cos(t), sin(t)) * rad

proc roundedRect*(ui: Ui, r: Rect, color: ColorRGBX, radius: float32) =
  let e = ui.sk.atlas.entries[WhiteTileKey]
  let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
  let pts = roundedOutline(r, radius)
  let c = r.xy + r.wh / 2
  for k in 0 ..< pts.len:
    ui.sk.drawTriangle([c, pts[k], pts[(k + 1) mod pts.len]], [uv, uv, uv], [color, color, color])

proc roundedBorder*(ui: Ui, r: Rect, color: ColorRGBX, radius: float32, t = 1'f32) =
  let e = ui.sk.atlas.entries[WhiteTileKey]
  let uv = vec2(e.x.float32 + e.width.float32 / 2, e.y.float32 + e.height.float32 / 2)
  let outer = roundedOutline(r, radius)
  let inner = roundedOutline(rect(r.x + t, r.y + t, r.w - 2 * t, r.h - 2 * t), max(0, radius - t))
  for k in 0 ..< outer.len:
    let j = (k + 1) mod outer.len
    ui.sk.drawTriangle([outer[k], outer[j], inner[j]], [uv, uv, uv], [color, color, color])
    ui.sk.drawTriangle([outer[k], inner[j], inner[k]], [uv, uv, uv], [color, color, color])

# --- scrollbars ----------------------------------------------------------------

const
  BarHit = 10'f32    ## Width of the strip at an area's right edge that takes the mouse.
  BarThin = 3'f32    ## Thumb width at rest, and while hovered or dragged.
  BarWide = 6'f32
  BarMinThumb = 24'f32

proc barThumb(area: Rect, scroll, contentH: float32): Rect =
  let th = clamp(area.h * area.h / contentH, min(BarMinThumb, area.h), area.h)
  let room = contentH - area.h
  let t = if room > 0: clamp(scroll / room, 0, 1) else: 0'f32
  rect(area.x + area.w - BarHit, area.y + (area.h - th) * t, BarHit, th)

proc scrollArea*(ui: Ui, id: string, area: Rect, scroll: var float32) =
  ## Call before laying out a scrolled area: lets its scrollbar's thumb be
  ## dragged (or the track clicked, which jumps there), with the content
  ## height scrollbar gave last frame. It takes the press before the contents.
  let contentH = ui.barContent.getOrDefault(id)
  if contentH <= area.h or area.h <= 0: return
  let bid = id & "#bar"
  let track = rect(area.x + area.w - BarHit, area.y, BarHit, area.h)
  var thumb = barThumb(area, scroll, contentH)
  if ui.hover(track) and ui.pressed():
    ui.consumeClick()
    ui.activeId = bid
    if not ui.mouse.inside(thumb):
      # The track: the thumb's middle goes under the mouse.
      ui.barGrab = thumb.h / 2
    else:
      ui.barGrab = ui.mouse.y - thumb.y
  if ui.activeId == bid and ui.window.buttonDown[MouseLeft]:
    let room = area.h - thumb.h
    if room > 0:
      scroll = clamp((ui.mouse.y - ui.barGrab - area.y) / room, 0, 1) * (contentH - area.h)

proc scrollbar*(ui: Ui, id: string, area: Rect, scroll: float32, contentH: float32) =
  ## Call after laying out the area (outside its clip): draws a slim thumb over
  ## the contents' right edge when they're taller than area, so it takes no
  ## width from them. contentH: the height scroll runs over (its largest value
  ## is contentH - area.h).
  ui.barContent[id] = contentH
  if contentH <= area.h + 0.5 or area.h <= 0: return
  let bid = id & "#bar"
  let thumb = barThumb(area, scroll, contentH)
  let active = ui.activeId == bid
  let hot = active or ui.hover(rect(area.x + area.w - BarHit, area.y, BarHit, area.h))
  let w = if hot: BarWide else: BarThin
  let r = rect(area.x + area.w - w - 2, thumb.y + 2, w, thumb.h - 4)
  ui.roundedRect(r, (if active: colAccent elif hot: colTextDim else: colTextDisabled), w / 2)

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

proc cursorRing*(ui: Ui, r: Rect) =
  ## A focused list's cursor item (inside it: neighbours would cover a ring
  ## around it), shown after the keyboard was used.
  if ui.navVisible: ui.border(r, colAccent)

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
                 enabled = true, toggled = false, focusable = true, clickFocus = true): bool =
  ## `focusable = false` keeps it out of the Tab order (a row's button in a
  ## list that is one Tab stop); `clickFocus` as textButton's.
  let hov = enabled and ui.hover(r)
  let focused = enabled and focusable and ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    if focusable and clickFocus: ui.navId = id
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
  if focused: ui.focusRing(r)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true
  if focused and ui.navActivate(id): result = true

proc textButton*(ui: Ui, id: string, r: Rect, label: string, primary = false,
                 clickFocus = true): bool =
  ## `clickFocus = false` is for toolbar buttons (Qt's TabFocus): Tab reaches
  ## them, but clicking one doesn't take keyboard focus, so Space/Enter in the
  ## views can't press it.
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    if clickFocus: ui.navId = id
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
  if ui.navActivate(id): result = true

proc checkbox*(ui: Ui, id: string, pos: Vec2, label: string, value: var bool,
               mixed = false): bool =
  ## `mixed` draws the partially checked state (TrenchBroom's FlagsEditor:
  ## the selection disagrees); clicking it checks the box.
  let box = rect(pos.x, pos.y + 3, 16, 16)
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  if focused: ui.focusRing(r)
  ui.rect(box, if value and not mixed: colAccent else: colPanelRaised)
  ui.border(box, if hov: colAccent else: colBorder)
  if mixed: ui.rect(rect(box.x + 4, box.y + 7, 8, 2), colTextDim)
  elif value: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22), colText)
  if (hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id) or
     ui.navKey(id, KeySpace):
    value = mixed or not value
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

proc editHistory(ui: Ui, id: string, text: var string, before: string, beforeCaret: int,
                 typing, fresh: bool): bool =
  ## The focused text input's own undo, like a Qt line edit's: call after its
  ## edits each frame with the text it started the frame with. Ctrl+Z puts
  ## back the text before the last edit (a run of typing is one edit),
  ## Ctrl+Shift+Z or Ctrl+Y does it again. Returns true when it changed text.
  if fresh or ui.editUndoId != id:
    ui.editUndoId = id
    ui.editUndo.setLen 0
    ui.editRedo.setLen 0
    ui.editTyping = false
  if text != before:
    if not (typing and ui.editTyping): ui.editUndo.add (before, beforeCaret)
    ui.editTyping = typing
    ui.editRedo.setLen 0
  let w = ui.window
  if not w.ctrlDown: return
  if w.buttonPressed[KeyZ] and not w.shiftDown:
    if ui.editUndo.len == 0: return
    ui.editRedo.add (text, ui.caret)
    (text, ui.caret) = ui.editUndo.pop
  elif w.buttonPressed[KeyY] or (w.buttonPressed[KeyZ] and w.shiftDown):
    if ui.editRedo.len == 0: return
    ui.editUndo.add (text, ui.caret)
    (text, ui.caret) = ui.editRedo.pop
  else: return
  ui.caret = clamp(ui.caret, 0, text.len)
  ui.selAnchor = ui.caret
  ui.editTyping = false
  true

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
  # Any press or wheel turn outside the field ends editing; one on the
  # field's dropdown (popupHit) keeps it focused.
  if ui.focusId == id: ui.focusSeen = true
  if ui.focusId == id and ui.interacted() and not hov and not ui.popupHit:
    ui.focusId = ""
    result.incl eeCommitted
  if hov and ui.pressed():
    ui.consumeClick()
    ui.editTyping = false
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
    let (start, startCaret) = (text, ui.caret)
    var typing = false
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
    typing = ins.len > 0 and ui.caret == ui.selAnchor
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r", ""), ("\n", " "))
      typing = false
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
    if ui.editHistory(id, text, start, startCaret, typing, eeFocused in result):
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
      ui.editTyping = false
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

const TextAreaPad = vec2(7, 5)   ## Text inset from a text area's border.

proc areaLines(ui: Ui, text: string, width: float32): seq[(int, int)] =
  ## A text area's visual lines as byte ranges [a, b): split at newlines (not
  ## included) and wrapped after the last space that fits, or mid-word when a
  ## word alone is too wide. An empty text, or one ending in a newline, ends
  ## with an empty line.
  var start = 0
  while true:
    var e = text.find('\n', start)
    if e < 0: e = text.len
    var a = start
    while true:
      if ui.textSize(text[a ..< e]).x <= width:
        result.add (a, e)
        break
      var fit = a
      var space = -1
      var j = a
      while j < e:
        let n = nextRune(text, j)
        if ui.textSize(text[a ..< n]).x > width: break
        if text[j] == ' ': space = n
        fit = n
        j = n
      let b = if space > a: space elif fit > a: fit else: nextRune(text, a)
      result.add (a, b)
      a = b
    if e >= text.len: break
    start = e + 1

proc areaLineOf(lines: seq[(int, int)], i: int): int =
  ## The visual line the caret at byte i is drawn on (a wrapped line's end is
  ## the next line's start).
  for k, (a, _) in lines:
    if a <= i: result = k

proc textAreaHeight*(ui: Ui, text: string, width: float32, minLines = 3, maxLines = 12): float32 =
  ## The height that shows text in a text area of this width, within the line limits.
  let n = clamp(ui.areaLines(text, width - TextAreaPad.x * 2).len, minLines, maxLines)
  n.float32 * ui.textSize("Ag").y + TextAreaPad.y * 2

proc textArea*(ui: Ui, id: string, r: Rect, text: var string,
               placeholder = ""): set[EditEvent] =
  ## Multi-line text input, wrapped to its width. Enter starts a new line;
  ## Ctrl+Enter, Tab, Escape or a click elsewhere ends editing (eeCommitted).
  ## Selection, words and the clipboard work as in textField; Up/Down move a
  ## line, Home/End to the line's ends (with Ctrl, the text's); the wheel
  ## scrolls a long text while it's being edited.
  let w = ui.window
  let hov = ui.hover(r)
  let inner = rect(r.x + TextAreaPad.x, r.y + TextAreaPad.y, r.w - TextAreaPad.x * 2,
                   r.h - TextAreaPad.y * 2)
  let lineH = ui.textSize("Ag").y
  var lines = ui.areaLines(text, inner.w)
  proc indexIn(text: string, line: (int, int), x: float32): int =
    ## Character boundary on a visual line nearest to window x.
    let (a, b) = line
    let x = x - inner.x
    result = a
    while result < b:
      let j = nextRune(text, result)
      if x < (ui.textSize(text[a ..< result]).x + ui.textSize(text[a ..< j]).x) / 2: break
      result = j
  proc hitIndex(text: string, lines: seq[(int, int)], p: Vec2): int =
    let k = clamp(int(floor((p.y - inner.y + ui.fieldScroll) / lineH)), 0, lines.high)
    indexIn(text, lines[k], p.x)
  discard ui.tabStop(id, r, edit = true)
  if ui.focusId == id and ui.focusFresh:
    ui.focusFresh = false
    ui.fieldScroll = 0
    ui.selAnchor = 0
    ui.caret = text.len
    result.incl eeFocused
  if ui.focusId == id: ui.focusSeen = true
  if ui.focusId == id and ui.interacted() and not hov and not ui.popupHit:
    ui.focusId = ""
    result.incl eeCommitted
  if hov and ui.pressed():
    ui.consumeClick()
    ui.editTyping = false
    ui.navId = id
    ui.activeId = id
    ui.dragFrom = hitIndex(text, lines, ui.mouse)
    ui.dragX = ui.mouse.x
    let clicks = ui.countClick(id)
    if ui.focusId != id:
      ui.focusId = id
      ui.fieldScroll = 0
      ui.selAnchor = ui.dragFrom
      ui.caret = ui.dragFrom
      result.incl eeFocused
    elif clicks == 2:
      (ui.selAnchor, ui.caret) = wordAround(text.classes, ui.dragFrom)
    elif clicks >= 3:
      # The whole line, up to its newline.
      let k = areaLineOf(lines, ui.dragFrom)
      var a = lines[k][0]
      while a > 0 and text[a - 1] != '\n': dec a
      var b = lines[k][1]
      while b < text.len and text[b] != '\n': inc b
      (ui.selAnchor, ui.caret) = (a, b)
    else:
      if not w.shiftDown: ui.selAnchor = ui.dragFrom
      ui.caret = ui.dragFrom
  let focused = ui.focusId == id
  if focused and ui.activeId == id and ui.down() and ui.clickCount == 2:
    (ui.selAnchor, ui.caret) = wordDrag(text.classes, ui.dragFrom, hitIndex(text, lines, ui.mouse))
  elif focused and ui.activeId == id and ui.down() and ui.clickCount == 1:
    ui.caret = hitIndex(text, lines, ui.mouse)
  if focused:
    ui.caret = clamp(ui.caret, 0, text.len)
    ui.selAnchor = clamp(ui.selAnchor, 0, text.len)
    let ctrl = w.ctrlDown
    let shift = w.shiftDown
    let (s0, s1) = (min(ui.selAnchor, ui.caret), max(ui.selAnchor, ui.caret))
    let (start, startCaret) = (text, ui.caret)
    var typing = false
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
    for ch in ui.typed:  # drop control characters; Enter comes from the key below
      if ch.ord >= 0x20 and ch.ord != 0x7f: ins.add ch
    typing = ins.len > 0 and ui.caret == ui.selAnchor
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r\n", "\n"), ("\r", "\n"), ("\t", " "))
      typing = false
    let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
    if enter and not ctrl: ins.add '\n'
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
      let a = if ctrl: wordLeft(text.classes, ui.caret) else: prevRune(text, ui.caret)
      text.delete(a ..< ui.caret)
      ui.caret = a
      ui.selAnchor = a
      result.incl eeChanged
    elif w.buttonPressed[KeyDelete] and ui.caret < text.len:
      text.delete(ui.caret ..< nextRune(text, ui.caret))
      result.incl eeChanged
    if ui.editHistory(id, text, start, startCaret, typing, eeFocused in result):
      result.incl eeChanged
    if eeChanged in result: lines = ui.areaLines(text, inner.w)
    var move = -1
    let (lo, hi) = (min(ui.selAnchor, ui.caret), max(ui.selAnchor, ui.caret))
    let k = areaLineOf(lines, ui.caret)
    let caretX = inner.x + ui.textSize(text[lines[k][0] ..< ui.caret]).x
    if w.buttonPressed[KeyLeft]:
      move = if ctrl: wordLeft(text.classes, ui.caret)
             elif shift or lo == hi: prevRune(text, ui.caret) else: lo
    if w.buttonPressed[KeyRight]:
      move = if ctrl: wordRight(text.classes, ui.caret)
             elif shift or lo == hi: nextRune(text, ui.caret) else: hi
    if w.buttonPressed[KeyUp]:
      move = if k > 0: indexIn(text, lines[k - 1], caretX) else: 0
    if w.buttonPressed[KeyDown]:
      move = if k < lines.high: indexIn(text, lines[k + 1], caretX) else: text.len
    if w.buttonPressed[KeyHome]: move = if ctrl: 0 else: lines[k][0]
    if w.buttonPressed[KeyEnd]:
      # Before a wrapped line's trailing space, so the caret stays on this line.
      var e = lines[k][1]
      if k < lines.high and lines[k + 1][0] == e and e > lines[k][0]: e = prevRune(text, e)
      move = if ctrl: text.len else: e
    if move >= 0:
      ui.caret = move
      if not shift: ui.selAnchor = move
      ui.editTyping = false
    if (enter and ctrl) or w.buttonPressed[KeyTab] or w.buttonPressed[KeyEscape]:
      ui.focusId = ""
      result.incl eeCommitted
    ui.navTaken.incl {KeyEnter, NumpadEnter, KeyUp, KeyDown, KeyLeft, KeyRight, KeyHome, KeyEnd}
  # Scrolled only while editing: to the caret, and by the wheel.
  let contentH = lines.len.float32 * lineH
  if focused:
    if hov and ui.wheelNotches != 0 and contentH > inner.h:
      ui.fieldScroll += ui.wheelNotches * lineH * 3
      ui.scrollConsumed = true
    if eeChanged in result or ui.activeId == id or
       w.buttonPressed[KeyUp] or w.buttonPressed[KeyDown] or w.buttonPressed[KeyLeft] or
       w.buttonPressed[KeyRight] or w.buttonPressed[KeyHome] or w.buttonPressed[KeyEnd]:
      let cy = areaLineOf(lines, ui.caret).float32 * lineH
      if cy - ui.fieldScroll > inner.h - lineH: ui.fieldScroll = cy - inner.h + lineH
      if cy - ui.fieldScroll < 0: ui.fieldScroll = cy
    ui.fieldScroll = clamp(ui.fieldScroll, 0, max(0'f32, contentH - inner.h))
  let scroll = if focused: ui.fieldScroll else: 0
  ui.rect(r, colBackground)
  ui.border(r, if focused: colAccent elif hov: colTextDim else: colBorder)
  ui.pushClip(rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2))
  if text.len == 0 and not focused:
    ui.textIn(placeholder, rect(inner.x, inner.y, inner.w + 4000, lineH), colTextDisabled)
  let (s0, s1) = (min(ui.selAnchor, ui.caret), max(ui.selAnchor, ui.caret))
  for k, (a, b) in lines:
    let y = inner.y + k.float32 * lineH - scroll
    if y + lineH < r.y or y > r.y + r.h: continue
    if focused and s1 > s0 and s0 <= b and s1 >= a:
      let x0 = ui.textSize(text[a ..< max(a, s0)]).x
      var x1 = ui.textSize(text[a ..< min(b, s1)]).x
      if s1 > b and b < text.len and text[b] == '\n': x1 += 6   # the selected newline
      if x1 > x0: ui.rect(rect(inner.x + x0, y, x1 - x0, lineH), colAccentDim)
    ui.textIn(text[a ..< b], rect(inner.x, y, inner.w + 4000, lineH), colText)
  if focused:
    let k = areaLineOf(lines, ui.caret)
    let cx = ui.textSize(text[lines[k][0] ..< ui.caret]).x
    ui.rect(rect(inner.x + cx, inner.y + k.float32 * lineH - scroll + 1, 1, lineH - 2), colAccent)
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

proc fmtNumber*(v: float, decimals: int): string =
  ## decimals < 0: as many as the value needs (a float field shows what's stored).
  if decimals == 0: return $int(round(v))
  if decimals > 0: return formatFloat(v, ffDecimal, decimals)
  result = formatFloat(v, ffDecimal, 9)
  result.trimZeros()
  if result == "-0": result = "0"

proc numberField*(ui: Ui, id: string, r: Rect, value: var float,
                  step, lo, hi: float, decimals = 0, axis = -1, live = false,
                  mixed = false): bool =
  ## Type a number (or basic math, worked out on Enter or unfocus), scroll
  ## over it or press Up/Down while typing (Shift: a quarter step). axis
  ## 0..2 colors the left edge with that axis's color. live also takes the
  ## value on every keystroke that leaves a valid number. mixed (several
  ## objects that differ) shows the field blank and only takes a typed value.
  ## decimals < 0 shows as many as the value has. Returns true when value changed.
  let fid = id & "#field"
  proc fmt(v: float): string =
    if mixed: "" else: fmtNumber(v, decimals)
  if ui.focusId == fid and ui.focusFresh: ui.editText = fmt(value)
  var buf = if ui.focusId == fid: ui.editText else: fmt(value)
  let ev = ui.textField(fid, r, buf, if mixed: "mixed" else: "")
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
  if ui.hover(r) and ui.scroll() != 0 and not mixed:
    delta = if ui.scroll() < 0: step else: -step
    ui.scrollConsumed = true
  let focused = ui.focusId == fid
  if focused and not mixed:
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
  if eeCommitted in ev and not (mixed and buf.strip.len == 0):
    try:
      let v = clamp(evalMath(buf), lo, hi)
      if v != value or mixed:
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
