## Color fields: a swatch that opens a color picker (saturation/value square,
## hue bar, RGB, HSV and hex), a number field per channel, and an eyedropper
## that picks the color of any pixel in Catwalk's window (views, panels, the
## picker itself).
##
## One picker is open at a time. While it's open its target's live proc sets
## the color as it changes (no undo step); done runs once when it closes, so
## the caller can push one undo step for the whole edit.

import std/[strutils, strformat, math]
import silky, vmath, bumpy, chroma, pixie, opengl
import theme, ui, xwin

type
  RGB* = array[3, int]

  ColorTarget* = object
    live*: proc(c: RGB)            ## The picker's color changed.
    done*: proc(changed: bool)     ## The picker closed; changed: it ended on another color.

  Picker = object
    id: string                     ## Field that opened it ("" = closed).
    anchor: Rect                   ## That field's rect, this frame.
    seen: bool                     ## The field was drawn this frame.
    orig: RGB
    h, s, v: float                 ## Current color: hue 0..360, saturation and value 0..1.
    target: ColorTarget
    drag: int                      ## 1: the SV square, 2: the hue bar.
    picking*: bool                 ## Eyedropper: the next click anywhere takes that pixel's color.
    under: RGB                     ## Pixel under the mouse in the last frame (while picking).
    pickEnded: bool                ## The eyedropper ended this frame (its key or click is spent).
    hex: string

var pick: Picker

const
  PopW = 248'f32
  PopH = 300'f32
  SvSize = vec2(196, 150)

# --- conversions ----------------------------------------------------------------------------------

proc toHsv*(c: RGB): (float, float, float) =
  let (r, g, b) = (c[0] / 255, c[1] / 255, c[2] / 255)
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let d = mx - mn
  var h = 0.0
  if d > 1e-9:
    if mx == r: h = 60 * ((g - b) / d)
    elif mx == g: h = 60 * ((b - r) / d + 2)
    else: h = 60 * ((r - g) / d + 4)
    if h < 0: h += 360
  (h, (if mx > 1e-9: d / mx else: 0.0), mx)

proc toRgb*(h, s, v: float): RGB =
  let hh = (h mod 360) / 60
  let c = v * s
  let x = c * (1 - abs(hh mod 2 - 1))
  let (r, g, b) =
    if hh < 1: (c, x, 0.0)
    elif hh < 2: (x, c, 0.0)
    elif hh < 3: (0.0, c, x)
    elif hh < 4: (0.0, x, c)
    elif hh < 5: (x, 0.0, c)
    else: (c, 0.0, x)
  let m = v - c
  [int(round((r + m) * 255)), int(round((g + m) * 255)), int(round((b + m) * 255))]

proc toHex*(c: RGB): string = &"#{c[0]:02X}{c[1]:02X}{c[2]:02X}"

proc fmtRgb*(c: RGB): string = &"{c[0]} {c[1]} {c[2]}"

proc parseColor*(s: string): (bool, RGB) =
  ## "R G B" or "R, G, B" (0–255), "rgb(R, G, B)", "#RRGGBB", "#RGB", "RRGGBB",
  ## "0xRRGGBB", or "hsv(H, S, V)" / "hsv H S V" (H 0–360, S and V 0–100).
  var t = s.strip.toLowerAscii
  if t.len == 0: return
  var hsv = false
  for p in ["rgb", "hsv"]:
    if t.startsWith(p):
      hsv = p == "hsv"
      t = t[3 .. ^1]
  var hexs = t.strip(chars = {'(', ')', ' '})
  if hexs.startsWith("#"): hexs = hexs[1 .. ^1]
  elif hexs.startsWith("0x"): hexs = hexs[2 .. ^1]
  if not hsv and hexs.len in [3, 6] and hexs.allCharsInSet(HexDigits) and
     (s.strip.startsWith("#") or s.strip.toLowerAscii.startsWith("0x") or hexs.len == 6 and
      not hexs.allCharsInSet(Digits)):
    if hexs.len == 3: hexs = &"{hexs[0]}{hexs[0]}{hexs[1]}{hexs[1]}{hexs[2]}{hexs[2]}"
    let n = parseHexInt(hexs)
    return (true, [(n shr 16) and 255, (n shr 8) and 255, n and 255])
  var nums: seq[float]
  let cleaned = t.multiReplace(("(", " "), (")", " "), (",", " "), ("%", " "), ("°", " "))
  for part in strutils.splitWhitespace(cleaned):
    try: nums.add parseFloat(part)
    except ValueError: return
  if nums.len != 3: return
  if hsv:
    return (true, toRgb(clamp(nums[0], 0, 360), clamp(nums[1], 0, 100) / 100, clamp(nums[2], 0, 100) / 100))
  (true, [clamp(int(round(nums[0])), 0, 255), clamp(int(round(nums[1])), 0, 255),
          clamp(int(round(nums[2])), 0, 255)])

proc col(c: RGB): ColorRGBX = rgbx(c[0].uint8, c[1].uint8, c[2].uint8, 255)

# --- picker state ---------------------------------------------------------------------------------

proc current(): RGB = toRgb(pick.h, pick.s, pick.v)

proc closePicker*() =
  ## Ends the open picker (its done runs).
  if pick.id.len == 0: return
  let changed = current() != pick.orig
  let t = pick.target
  pick.id = ""
  pick.picking = false
  pick.drag = 0
  if t.done != nil: t.done(changed)

proc pickerOpen*(id: string): bool = pick.id == id

proc openPicker(id: string, c: RGB, target: ColorTarget) =
  closePicker()
  pick = Picker(id: id, orig: c, target: target)
  (pick.h, pick.s, pick.v) = toHsv(c)
  pick.hex = toHex(c)

proc setColor(c: RGB, keepHue = true) =
  ## A color from RGB, hex, a typed value or the eyedropper.
  let (h, s, v) = toHsv(c)
  if not keepHue or s > 1e-6 and v > 1e-6: pick.h = h
  if not keepHue or v > 1e-6: pick.s = s
  pick.v = v
  pick.hex = toHex(c)
  pick.target.live(c)

proc changedHsv() =
  let c = current()
  pick.hex = toHex(c)
  pick.target.live(c)

# --- eyedropper -----------------------------------------------------------------------------------

proc eyedropperInput*(ui: Ui) =
  ## Right after beginFrame: while picking, the mouse belongs to the eyedropper.
  ## A left click takes the color under it; Escape or a right click cancels.
  pick.pickEnded = false
  if not pick.picking: return
  ui.captured = true
  let w = ui.window
  if w.buttonPressed[MouseLeft]:
    pick.picking = false
    pick.pickEnded = true
    setColor(pick.under, keepHue = false)
    ui.consumeClick()
  elif w.buttonPressed[KeyEscape] or w.buttonPressed[MouseRight]:
    pick.picking = false
    pick.pickEnded = true

proc eyedropperActive*(): bool = pick.picking

proc sampleUnderMouse*(ui: Ui) =
  ## After the frame is drawn, before the swap: the pixel under the mouse.
  if not pick.picking: return
  let p = ui.mouse * ui.scale
  let h = ui.window.size.y
  let (x, y) = (p.x.int32, h - 1 - p.y.int32)
  if x < 0 or y < 0 or x >= ui.window.size.x or y >= h: return
  var px: array[4, uint8]
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[0].addr)
  pick.under = [px[0].int, px[1].int, px[2].int]

# --- widgets --------------------------------------------------------------------------------------

var colorComponent*: int = -1
  ## The channel (0 red, 1 green, 2 blue) the last eeCommitted of colorField
  ## changed: with several objects, the others keep each object's own.

proc colorField*(ui: Ui, id: string, r: Rect, text: var string, target: ColorTarget,
                 placeholder = ""): set[EditEvent] =
  ## A swatch (opens the picker), the red, green and blue channels as number
  ## fields side by side (like the XYZ fields) and an eyedropper button. A
  ## channel edit puts the color in text as "R G B" and returns eeCommitted
  ## (colorComponent: which channel); the picker reports through target. text
  ## blank with placeholder "R G B;R G B;...": several values, a channel that
  ## differs shows blank.
  let sw = rect(r.x, r.y, 26, r.h)
  let eye = rect(r.x + r.w - 26, r.y, 26, r.h)
  let open = pick.id == id
  let (ok, c) = parseColor(text)
  var vals = c
  var mixed = [not ok, not ok, not ok]
  if not ok and placeholder.len > 0:
    var first = true
    for part in placeholder.split(';'):
      let (pok, pc) = parseColor(part)
      if not pok: continue
      if first:
        vals = pc
        mixed = [false, false, false]
        first = false
      else:
        for i in 0 .. 2:
          if pc[i] != vals[i]: mixed[i] = true
  let anyMixed = mixed[0] or mixed[1] or mixed[2]
  let shown = if open: current() else: vals
  let hov = ui.hover(sw)
  ui.rect(sw, if hov or open: colAccent else: colBorder)
  if open or not anyMixed:
    ui.rect(rect(sw.x + 2, sw.y + 2, sw.w - 4, sw.h - 4), col(shown))
  else:
    # Unknown or mixed: a crossed-out swatch.
    ui.rect(rect(sw.x + 1, sw.y + 1, sw.w - 2, sw.h - 2), colPanel)
    ui.rect(rect(sw.x + 5, sw.y + sw.h / 2 - 1, sw.w - 10, 2), colTextDim)
  ui.tip(sw, "Open the color picker")
  if hov and ui.pressed():
    ui.consumeClick()
    if open: closePicker()
    else: openPicker(id, (if anyMixed: [255, 255, 255] else: vals), target)
  const names = ["Red", "Green", "Blue"]
  let fx = r.x + 30
  let cw = (r.w - 60 - 4) / 3
  for i in 0 .. 2:
    let fr = rect(fx + i.float32 * (cw + 2), r.y, cw, r.h)
    var v = shown[i].float
    if ui.numberField(id & "." & $i, fr, v, 8, 0, 255, axis = i, mixed = mixed[i] and not open):
      var nc = shown
      nc[i] = clamp(int(round(v)), 0, 255)
      if open: setColor(nc)   # The picker's edit: one undo step when it closes.
      else:
        text = fmtRgb(nc)
        colorComponent = i
        result.incl eeCommitted
    ui.tip(fr, names[i] & " (0–255)")
  if ui.iconButton(id & ".eye", eye, "eyedropper16", "Pick a color from anywhere in Catwalk " &
                   "(click; Esc or right-click cancels)", toggled = open and pick.picking):
    if not open: openPicker(id, (if anyMixed: [255, 255, 255] else: vals), target)
    pick.picking = not pick.picking
  if pick.id == id:
    # Also when it opened just now: the picker draws this frame, under this field.
    pick.anchor = r
    pick.seen = true

proc drawColorPicker*(ui: Ui) =
  ## Draws the open picker under (or over) its field, above everything else.
  ## Call once per frame after every color field had its turn.
  if pick.id.len == 0: return
  if not pick.seen:
    closePicker()   # its field is gone (other selection, other tab)
    return
  pick.seen = false
  let ar = pick.anchor
  var box = rect(ar.x + ar.w - PopW, ar.y + ar.h + 2, PopW, PopH)
  if box.y + box.h > ui.size.y - 4 and ar.y - PopH - 2 >= 0: box.y = ar.y - PopH - 2
  box.x = clamp(box.x, 4, max(4'f32, ui.size.x - PopW - 4))
  let over = ui.popupHit
  let typing = ui.focusId.len > 0   # Esc and Enter end the typing, not the picker
  ui.popupRect = box
  # Its own widgets take the mouse over it (popupHit blocks the ones below).
  let wasHit = ui.popupHit
  ui.popupHit = false
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(box.x + 3, box.y + 3, box.w, box.h), colShadow)
  ui.rect(box, colPopup)
  ui.border(box, colBorder)
  let x = box.x + 10
  var y = box.y + 10
  # Saturation (across) and value (down) for the current hue, in columns.
  let sv = rect(x, y, SvSize.x, SvSize.y)
  const Cols = 24
  for i in 0 ..< Cols:
    let s0 = i / Cols
    let s1 = (i + 1) / Cols
    let cr = rect(sv.x + sv.w * s0.float32, sv.y, sv.w / Cols + 0.5, sv.h)
    let top0 = col(toRgb(pick.h, s0, 1))
    let top1 = col(toRgb(pick.h, s1, 1))
    let black = rgbx(0, 0, 0, 255)
    ui.gradient(cr, top0, top1, black, black)
  let mx = sv.x + sv.w * pick.s.float32
  let my = sv.y + sv.h * (1 - pick.v.float32)
  ui.border(rect(mx - 5, my - 5, 10, 10), rgbx(0, 0, 0, 255), 1)
  ui.border(rect(mx - 4, my - 4, 8, 8), rgbx(255, 255, 255, 255), 1)
  # Hue bar.
  let hb = rect(sv.x + sv.w + 10, y, 18, sv.h)
  for k in 0 ..< 6:
    let c0 = col(toRgb(k.float * 60, 1, 1))
    let c1 = col(toRgb((k + 1).float * 60, 1, 1))
    ui.gradient(rect(hb.x, hb.y + hb.h * k.float32 / 6, hb.w, hb.h / 6 + 0.5), c0, c0, c1, c1)
  let hy = hb.y + hb.h * (pick.h / 360).float32
  ui.rect(rect(hb.x - 3, hy - 1, hb.w + 6, 3), rgbx(255, 255, 255, 255))
  ui.border(rect(hb.x - 3, hy - 2, hb.w + 6, 5), rgbx(0, 0, 0, 255), 1)
  if not pick.picking and ui.pressed():
    if ui.hover(sv): pick.drag = 1
    elif ui.hover(rect(hb.x - 4, hb.y, hb.w + 8, hb.h)): pick.drag = 2
    if pick.drag != 0: ui.consumeClick()
  if pick.drag != 0:
    if not ui.down(): pick.drag = 0
    elif pick.drag == 1:
      pick.s = clamp((ui.mouse.x - sv.x) / sv.w, 0, 1)
      pick.v = clamp(1 - (ui.mouse.y - sv.y) / sv.h, 0, 1)
      changedHsv()
    else:
      pick.h = clamp((ui.mouse.y - hb.y) / hb.h, 0, 1) * 360
      if pick.h >= 360: pick.h = 359.99
      changedHsv()
  y += sv.h + 10
  # Before / now (or under the eyedropper), the eyedropper and hex.
  let now = if pick.picking: pick.under else: current()
  let pv = rect(x, y, 64, 26)
  ui.rect(pv, colBorder)
  ui.rect(rect(pv.x + 1, pv.y + 1, 31, 24), col(pick.orig))
  ui.rect(rect(pv.x + 32, pv.y + 1, 31, 24), col(now))
  ui.tip(rect(pv.x, pv.y, 32, 26), "Before: click to go back to it")
  ui.tip(rect(pv.x + 32, pv.y, 32, 26), if pick.picking: "Under the eyedropper" else: "Now")
  if not pick.picking and ui.hover(rect(pv.x, pv.y, 32, 26)) and ui.pressed():
    ui.consumeClick()
    setColor(pick.orig, keepHue = false)
  if ui.iconButton("cpick.eye", rect(pv.x + 70, y, 26, 26), "eyedropper16",
                   "Pick a color from anywhere in Catwalk (click; Esc or right-click cancels)",
                   toggled = pick.picking):
    pick.picking = not pick.picking
  ui.text("Hex", vec2(pv.x + 104, y + 5), colTextDim, FontSmall)
  let ev = ui.textField("cpick.hex", rect(pv.x + 132, y, box.x + box.w - 10 - pv.x - 132, 26), pick.hex)
  if eeCommitted in ev:
    let (ok, c) = parseColor(if pick.hex.strip.startsWith("#"): pick.hex else: "#" & pick.hex.strip)
    if ok: setColor(c) else: pick.hex = toHex(current())
  y += 34
  # RGB and HSV, typed or stepped (wheel, Up/Down).
  let fw = (box.w - 20 - 34 - 8) / 3
  ui.text("RGB", vec2(x, y + 5), colTextDim, FontSmall)
  var c = current()
  var rgbChanged = false
  for i in 0 .. 2:
    var f = c[i].float
    if ui.numberField("cpick.rgb." & $i, rect(x + 34 + i.float32 * (fw + 4), y, fw, 26), f, 1, 0, 255,
                      axis = i, live = true):
      c[i] = int(round(f))
      rgbChanged = true
  if rgbChanged: setColor(c)
  y += 32
  ui.text("HSV", vec2(x, y + 5), colTextDim, FontSmall)
  var hsv = [pick.h, pick.s * 100, pick.v * 100]
  const his = [360.0, 100, 100]
  for i in 0 .. 2:
    if ui.numberField("cpick.hsv." & $i, rect(x + 34 + i.float32 * (fw + 4), y, fw, 26), hsv[i], 1, 0,
                      his[i], live = true):
      pick.h = min(hsv[0], 359.99)
      pick.s = hsv[1] / 100
      pick.v = hsv[2] / 100
      changedHsv()
  y += 34
  ui.text(if pick.picking: "Click anywhere to take its color · Esc cancels"
          else: "Enter keeps it · Esc puts it back",
          vec2(x, y), colTextDim, FontSmall)
  if pick.picking:
    # The color under the eyedropper, next to the pointer.
    let m = ui.mouse
    let tr = rect(min(m.x + 18, ui.size.x - 92), min(m.y + 18, ui.size.y - 30), 88, 26)
    ui.rect(rect(tr.x + 2, tr.y + 2, tr.w, tr.h), colShadow)
    ui.rect(tr, colPopup)
    ui.border(tr, colBorder)
    ui.rect(rect(tr.x + 3, tr.y + 3, 20, 20), col(pick.under))
    ui.textIn(toHex(pick.under), rect(tr.x + 27, tr.y, tr.w - 30, tr.h), colText, FontSmall)
  ui.sk.popLayer()
  ui.popupHit = wasHit
  if over: ui.captured = true
  let w = ui.window
  if not pick.picking and not pick.pickEnded:
    if w.buttonPressed[KeyEscape] and not typing:
      setColor(pick.orig, keepHue = false)
      closePicker()
      ui.captured = true
    elif (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]) and not typing and
         not ui.enterUsed:
      closePicker()
    elif ui.pressed() and not ui.mouse.inside(box) and not ui.mouse.inside(ar):
      closePicker()
      ui.captured = true   # the click only closes it (the views come later)
