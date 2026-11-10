## The render-mode pie menu: hold Z over the views, point toward a mode and
## let go of Z (or click). Ported from Blender's pie menus with its default
## preferences: pie_handler (interface_handlers.cc) for the tap / hold / drag
## logic, but_isect_pie_seg (interface_query.cc) for picking by direction,
## LayoutRadial::resolve_impl (interface_layout.cc) for placing the items,
## and draw_pie_center / widget_menu_pie_itembut (interface_widgets.cc) for
## the center ring, the spawn animation and the items' look.
##
## A tap (Z up within PieTapTimeout without moving the mouse) leaves the pie
## open until a click; holding Z confirms on release. Inside the center ring
## nothing is picked, so letting go there cancels. 1-9 (row or numpad) pick
## the item in that numpad direction; Esc, right click or Z again cancel.

import std/[math, times]
import silky, vmath, bumpy, pixie
import theme, ui, menutree, render, appstate, viewtools

type
  PieDir = enum
    ## Blender's RadialDirection, counter-clockwise from north.
    pdN, pdNE, pdE, pdSE, pdS, pdSW, pdW, pdNW

const
  PieRadius = 100'f32         ## U.pie_menu_radius: center to the items' anchors.
  PieThreshold = 12'f32       ## U.pie_menu_threshold: the dead zone (and the ring's inner radius).
  PieRingWidth = 7'f32        ## draw_pie_center: outer radius = threshold + 7.
  PieTapTimeout = 0.2         ## U.pie_tap_timeout (20/100 s): a shorter press is a tap.
  PieAnimTime = 0.06          ## U.pie_animation_timeout (6/100 s): the items fly out this long.
  PieClickThresholdSq = 50'f32  ## PIE_CLICK_THRESHOLD_SQ: moving this far makes releasing Z confirm.
  PieItemH = 30'f32           ## 1.5 × UI_UNIT_Y.
  PieNumberW = 30'f32         ## 1.5 × UI_UNIT_X added for the numpad number.
  PieRounding = 4'f32         ## wcol_pie_menu.roundness 0.2 × widget unit.
  DirAngle: array[PieDir, float32] = [90'f32, 45, 0, 315, 270, 225, 180, 135]
  DirNumpad: array[PieDir, int] = [8, 9, 6, 3, 2, 1, 4, 7]
  # Blender's radial_dir_order fills W, E, S, N, NW, NE, SW, SE. The modes
  # sit like Blender's shading pie: wireframes left, untextured right, lit
  # textures on top (Rendered) and unlit ones below (Material Preview).
  PieItems = [(pdW, rmWireframe), (pdE, rmSolid), (pdS, rmUnlit), (pdN, rmDynamicLight),
              (pdNW, rmLitWireframe), (pdNE, rmLighting)]
  PieTitle = "Render Mode"

let
  # Blender's default wcol_pie_menu, with Catwalk's accent for inner_sel.
  pieInner = pm(24, 24, 24)
  pieItem = pm(84, 84, 84)
  pieInnerSel = pm(96, 137, 216)
  pieOutline = pm(36, 36, 36)
  pieText = pm(217, 217, 217)
  pieTextSel = pm(255, 255, 255)

proc modeIcon(m: RenderMode): string =
  ## The view header's icon for the mode.
  case m
  of rmDynamicLight: "bulb"
  of rmUnlit: "image"
  of rmLighting: "contrast"
  of rmSolid: "solid"
  of rmWireframe, rmLitWireframe: "cube"

proc dirVec(d: PieDir): Vec2 =
  ## Unit vector toward d on screen (y down).
  let t = DirAngle[d].degToRad
  vec2(cos(t), -sin(t))

proc fade(c: ColorRGBX, f: float32): ColorRGBX =
  ## A premultiplied color at f of its opacity (Blender's alphafac).
  rgbx(uint8(c.r.float32 * f), uint8(c.g.float32 * f), uint8(c.b.float32 * f), uint8(c.a.float32 * f))

proc itemSize(a: App, m: RenderMode): Vec2 =
  vec2(8 + 20 + 6 + a.ui.textSize($m).x + 8 + PieNumberW, PieItemH)

proc itemRect(a: App, i: int, center: Vec2): Rect =
  ## LayoutRadial::resolve_impl: the anchor is radius away in the item's
  ## direction; items to the right start there, those to the left end there,
  ## north / south ones sit above / below it, centered.
  let (d, m) = PieItems[i]
  let v = d.dirVec
  let sz = a.itemSize(m)
  let fx = if v.x > 0.01: 0'f32 elif v.x < -0.01: -1'f32 else: -0.5'f32
  let fy = if v.y < -0.99: -1'f32 elif v.y > 0.99: 0'f32 else: -0.5'f32
  let p = center + v * PieRadius
  rect(p.x + fx * sz.x, p.y + fy * sz.y, sz.x, sz.y)

proc titleRect(a: App, center: Vec2): Rect =
  ## LayoutRootPieMenu::resolve_impl: centered, just above the ring.
  let sz = a.ui.textSize(PieTitle) + vec2(20, 0)
  rect(center.x - sz.x / 2, center.y - (PieThreshold + 9) - PieItemH, sz.x, PieItemH)

proc fitCenter(a: App, p: Vec2): Vec2 =
  ## Moves the pie so all of it is inside the window (Blender's
  ## BLOCK_BOUNDS_PIE_CENTER positioning).
  var lo = p - vec2(PieThreshold + PieRingWidth)
  var hi = p + vec2(PieThreshold + PieRingWidth)
  let t = a.titleRect(p)
  lo = min(lo, t.xy)
  hi = max(hi, t.xy + t.wh)
  for i in 0 ..< PieItems.len:
    let r = a.itemRect(i, p)
    lo = min(lo, r.xy)
    hi = max(hi, r.xy + r.wh)
  const margin = 4'f32
  let size = a.ui.size
  result = p
  if lo.x < margin: result.x += margin - lo.x
  elif hi.x > size.x - margin: result.x -= hi.x - (size.x - margin)
  if lo.y < margin: result.y += margin - lo.y
  elif hi.y > size.y - margin: result.y -= hi.y - (size.y - margin)

proc pieDirection(a: App): (bool, Vec2) =
  ## block_calc_pie_segment: the cursor's direction from the center, invalid
  ## inside the threshold.
  let d = a.ui.mouse - a.pie.center
  let l = d.length
  if l < PieThreshold: (false, vec2(0, 0)) else: (true, d / l)

proc pieHover(a: App): int =
  ## but_isect_pie_seg: the item whose direction is closest to the cursor's,
  ## within 45 degrees. With items on every 8th the halfway line between
  ## neighbours decides; where a direction is empty the item reaches its
  ## 45-degree limit.
  result = -1
  let (ok, dir) = a.pieDirection
  if not ok: return
  var best = cos(45'f32.degToRad) - 1e-4
  for i, (d, _) in PieItems:
    let c = dot(d.dirVec, dir)
    if c > best:
      best = c
      result = i

proc closePie(a: App) =
  a.pie.open = false
  a.pie.hover = -1
  # Auto-repeat presses of a Z still held mustn't open it again.
  a.pie.keyLock = a.window.buttonDown[KeyZ]

proc applyPie(a: App, i: int) =
  if i in 0 ..< PieItems.len: a.opts.mode = PieItems[i][1]
  a.closePie()

proc pieInput*(a: App) =
  ## Opens the pie on Z over the views and, while it's open, takes the mouse
  ## and keys (pie_handler). Call after the menus capture input and before
  ## the panels and views use it.
  let ui = a.ui
  let w = a.window
  if not a.pie.open:
    if a.pie.keyLock and not w.buttonDown[KeyZ]: a.pie.keyLock = false
    if a.pie.keyLock or not w.buttonPressed[KeyZ] or a.proj == nil or ui.captured or
       ui.focusId.len > 0 or a.modalOpen or a.menuSys.isOpen or a.drag.kind != dkNone: return
    if w.ctrl or w.alt or w.shiftDown or w.meta: return
    if w.buttonDown[MouseLeft] or w.buttonDown[MouseRight] or w.buttonDown[MouseMiddle]: return
    if not ui.mouse.inside(a.viewsArea): return
    a.pie = PieMenu(open: true, init: ui.mouse, center: a.fitCenter(ui.mouse),
                    openedAt: epochTime(), hover: -1)
    # Pressed and released between two frames: a tap.
    if w.buttonReleased[KeyZ] and not w.buttonDown[KeyZ]: a.pie.clickStyle = true
    ui.captured = true
    return

  ui.captured = true
  let held = epochTime() - a.pie.openedAt
  if not w.focused:   # WINDEACTIVATE
    a.closePie()
    a.pie.keyLock = false
    return
  if not a.pie.clickStyle and (ui.mouse - a.pie.init).lengthSq > PieClickThresholdSq:
    a.pie.dragStyle = true
  a.pie.hover = a.pieHover()

  if w.buttonPressed[KeyEscape] or w.buttonPressed[MouseRight]:
    a.closePie()
    return
  # Numpad directions (CASE_NUM_TO_DIR), on the number row too.
  for d in PieDir:
    let n = DirNumpad[d]
    if w.buttonPressed[Button(Key0.ord + n)] or w.buttonPressed[Button(Numpad0.ord + n)]:
      for i, (id, _) in PieItems:
        if id == d:
          a.applyPie(i)
          return
  if w.buttonReleased[KeyZ] and not w.buttonDown[KeyZ] and not a.pie.clickStyle:
    if held < PieTapTimeout and not a.pie.dragStyle: a.pie.clickStyle = true
    else:
      a.applyPie(a.pie.hover)   # in the center: nothing, closes
      return
  elif w.buttonPressed[KeyZ] and a.pie.clickStyle:
    a.closePie()
    return
  if w.buttonPressed[MouseLeft]:
    ui.consumeClick()
    if a.pie.hover >= 0: a.applyPie(a.pie.hover)
    elif a.pie.clickStyle: a.closePie()

proc diskSector(ui: Ui, c: Vec2, r0, r1, start, span: float32, col: ColorRGBX) =
  ## draw_disk_shaded: the ring between r0 and r1 from angle start over span
  ## (radians, counter-clockwise on screen like Blender's y-up).
  const subd = 40
  for k in 0 ..< subd - 1:
    let t0 = start + k.float32 / (subd - 1) * span
    let t1 = start + (k + 1).float32 / (subd - 1) * span
    let (u0, u1) = (vec2(cos(t0), -sin(t0)), vec2(cos(t1), -sin(t1)))
    ui.uiTriangle(c + u0 * r0, c + u0 * r1, c + u1 * r1, col)
    ui.uiTriangle(c + u0 * r0, c + u1 * r1, c + u1 * r0, col)

proc drawPie*(a: App) =
  ## The center ring with its direction arc, the title and the items flying
  ## out from the center (positions and opacity eased in over PieAnimTime).
  if not a.pie.open: return
  let ui = a.ui
  let c = a.pie.center
  let fac = clamp(float32((epochTime() - a.pie.openedAt) / PieAnimTime), 0, 1)
  let r0 = PieThreshold
  let r1 = PieThreshold + PieRingWidth

  # Center: the ring, the arc toward the cursor (45 degrees wide, as there are
  # both axis-aligned and diagonal items) and the two outlines.
  ui.diskSector(c, r0, r1, 0, 2 * PI, pieInner)
  let (ok, dir) = a.pieDirection
  if ok:
    const range = PI / 4
    let angle = arctan2(-dir.y, dir.x)
    ui.diskSector(c, r0, r1, angle - range / 2, range, pieInnerSel)
  ui.uiCircle(c, r0, pieOutline, 1)
  ui.uiCircle(c, r1, pieOutline, 1)

  # Title, like Blender's label button above the ring.
  let tr = a.titleRect(c)
  ui.roundedRect(tr, fade(pieInner, fac), PieRounding)
  ui.roundedBorder(tr, fade(pieOutline, fac), PieRounding)
  ui.textIn(PieTitle, tr, fade(pieText, fac), h = CenterAlign)

  for i, (d, m) in PieItems:
    let final = a.itemRect(i, c)
    let mid = c + (final.xy + final.wh / 2 - c) * fac
    let r = rect((mid - final.wh / 2).floor, final.wh)
    let hot = i == a.pie.hover
    let current = a.opts.mode == m
    # widget_state_pie_menu_item: the current mode is selected, the hovered
    # item lit, and either one's text white.
    let inner = if current: pieInnerSel elif hot: pieItem else: pieInner
    let text = if hot or current: pieTextSel else: pieText
    # A soft shadow keeps the items readable over bright textures.
    for k in 1 .. 3:
      let s = k.float32 * 1.5
      ui.roundedRect(rect(r.x - s + 1, r.y - s + 2, r.w + 2 * s - 2, r.h + 2 * s - 2),
                     fade(pm(0, 0, 0, 40), fac), PieRounding + s)
    ui.roundedRect(r, fade(inner, fac), PieRounding)
    ui.roundedBorder(r, fade(pieOutline, fac), PieRounding)
    # Lit Wireframe shares the cube; its edges are lit, so it's tinted warm.
    let iconCol = if m == rmLitWireframe and not (hot or current): colMarker else: text
    ui.icon(modeIcon(m) & "20", vec2(r.x + 8 + 10, r.y + r.h / 2), fade(iconCol, fac))
    ui.textIn($m, rect(r.x + 8 + 20 + 6, r.y, r.w, r.h), fade(text, fac))
    ui.textIn($DirNumpad[d], rect(r.x + r.w - PieNumberW, r.y, PieNumberW - 8, r.h),
              fade(if hot or current: pieText else: colTextDim, fac), FontSmall, h = RightAlign)
  ui.tooltip = ""
