## Vector icons rasterized into the Silky atlas at startup (white; tinted when drawn).

import std/math
import pixie, silky

const musicPath* = "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"
const crownPath* = "M5 16L3 5l5.5 5L12 4l3.5 6L21 5l-2 11H5zm14 3c0 .6-.4 1-1 1H6c-.6 0-1-.4-1-1v-1h14v1z"

const iconPaths = {
  "play": (24, "M8 5v14l11-7z"),
  "pause": (24, "M6 5h4v14H6zM14 5h4v14h-4z"),
  "stop": (24, "M6 6h12v12H6z"),
  "prev": (24, "M6 6h2v12H6zM9.5 12L18 18V6z"),
  "next": (24, "M16 6h2v12h-2zM6 18l8.5-6L6 6z"),
  "loop": (24, "M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"),
  "slower": (24, "M11 18V6l-8.5 6zM20.5 18V6L12 12z"),
  "faster": (24, "M3.5 18l8.5-6L3.5 6zM13 18l8.5-6L13 6z"),
  "check": (24, "M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"),
  "radio": (24, "M12 7.5a4.5 4.5 0 1 1 0 9a4.5 4.5 0 1 1 0-9z"),
  "knob": (24, "M12 5a7 7 0 1 1 0 14a7 7 0 1 1 0-14z"),
  "arrow": (24, "M9.5 7l5 5-5 5z"),
  "arrowleft": (24, "M14.5 7l-5 5 5 5z"),
  "expand": (24, "M7 9.5l5 5 5-5z"),
  "film": (24, "M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"),
  "music": (24, musicPath),
  "nofile": (24, "M6 2c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z"),
  "mono": (24, "M3 9v6h4l5 5V4L7 9H3zm11-1v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "nosound": (24, "M3 9v6h4l5 5V4L7 9H3zM14.5 9.5l1.4-1.4 2.1 2.1 2.1-2.1 1.4 1.4-2.1 2.1 2.1 2.1-1.4 1.4-2.1-2.1-2.1 2.1-1.4-1.4 2.1-2.1z"),
  "stereo": (32, "M14 9v6h-3l-4 5V4l4 5zM5 8v8c-1.7-.8-3-2.3-3-4s1.3-3.2 3-4zM18 9v6h3l4 5V4l-4 5zM27 8v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "volume": (24, "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"),
  "playlist": (24, "M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z"),
  "crown": (24, crownPath),
  "terminal": (24, "M20 4H4c-1.11 0-2 .9-2 2v12c0 1.1.89 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.89-2-2-2zm0 14H4V8h16v10zm-2-1h-6v-2h6v2zM7.5 17l-1.41-1.41L8.67 13l-2.59-2.59L7.5 9l4 4-4 4z"),
  "rect": (24, "M3 5h18v14H3zM5 7v10h14V7z"),
  "rectoff": (24, "M3 5h18v14H3zM5 7v10h14V7zM3.4 2l18.6 18.6-1.4 1.4L2 3.4z"),
  "folder": (24, "M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z"),
  "plus": (24, "M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"),
  "eyedropper": (24, "M20.71 5.63l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-3.12 3.12-1.93-1.91-1.41 1.41 1.42 1.42L3 16.25V21h4.75l8.92-8.92 1.42 1.42 1.41-1.41-1.92-1.92 3.12-3.12c.4-.4.4-1.03.01-1.42zM6.92 19L5 17.08l8.06-8.06 1.92 1.92L6.92 19z"),
  "close": (24, "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"),
  # Catwalk tools
  "cursor": (24, "M5 3l14 9.5-6.2 1.3 3.6 6.8-2.6 1.4-3.6-6.9L5 19z"),
  "cube": (24, "M12 2l9 5v10l-9 5-9-5V7zm0 2.3L5.6 7.9 12 11.5l6.4-3.6zM5 9.6v6.2l6 3.4V13zm14 0L13 13v6.2l6-3.4z"),
  "vertex": (24, "M10 2h4v4h-4zM2 18h4v4H2zM18 18h4v4h-4zM11.2 6h1.6L6 18.2l-1.4-.8zm.2 0h1.6l6.8 11.4-1.4.8zM6 19.2h12v1.6H6z"),
  "edge": (24, "M3.5 18.1L18.1 3.5l2.4 2.4L5.9 20.5z"),
  "face": (24, "M7 4h14l-4 16H3z"),
  "scissors": (24, "M6 2.5a3.5 3.5 0 110 7 3.5 3.5 0 010-7zm0 2a1.5 1.5 0 100 3 1.5 1.5 0 000-3zm0 10a3.5 3.5 0 110 7 3.5 3.5 0 010-7zm0 2a1.5 1.5 0 100 3 1.5 1.5 0 000-3zM8.7 8.2L21 19.4V21h-1.4L7.4 9.7zm0 7.6l3.6-3.3 1.4 1.4-3.6 3.3zm5-5.4L19.6 5H21v1.6l-5.9 5.2z"),
  "rotate": (24, "M12 3a9 9 0 108.5 6h-2.2A7 7 0 1112 5v3l4-4-4-4z"),
  "scale": (24, "M3 3h8v2H6.4l5.3 5.3-1.4 1.4L5 6.4V11H3zm18 18h-8v-2h4.6l-5.3-5.3 1.4-1.4 5.3 5.3V13h2z"),
  "fliph": (24, "M11 2h2v20h-2zM9 6.5v11L2.5 12zm6 0l6.5 5.5L15 17.5z"),
  "flipv": (24, "M2 11h20v2H2zM6.5 9h11L12 2.5zm0 6h11L12 21.5z"),
  "duplicate": (24, "M8 8h13v13H8zm2 2v9h9v-9zM3 3h13v3h-2V5H5v9h1v2H3z"),
  "lock": (24, "M7 10V7a5 5 0 0110 0v3h1.5v11h-13V10zm2 0h6V7a3 3 0 00-6 0zm2 4h2v4h-2z"),
  "unlock": (24, "M7 10V7a5 5 0 019.6-1.9l-1.8.8A3 3 0 009 7v3h9.5v11h-13V10zm4 4h2v4h-2z"),
  "grid": (24, "M3 3h18v18H3zm2 2v4h4V5zm6 0v4h2V5zm4 0v4h4V5zM5 11v2h4v-2zm6 0v2h2v-2zm4 0v2h4v-2zM5 15v4h4v-4zm6 0v4h2v-4zm4 0v4h4v-4z"),
  "magnet": (24, "M4 3h5v8a3 3 0 006 0V3h5v8a8 8 0 01-16 0zm2 2v2h1V5zm11 0v2h1V5z"),
  "eye": (24, "M12 5c5 0 9 4.4 10 7-1 2.6-5 7-10 7S3 14.6 2 12c1-2.6 5-7 10-7zm0 3a4 4 0 100 8 4 4 0 000-8zm0 2.2a1.8 1.8 0 110 3.6 1.8 1.8 0 010-3.6z"),
  "eyeoff": (24, "M3.3 2l18.7 18.7-1.4 1.4-3.3-3.3A10.6 10.6 0 0112 19c-5 0-9-4.4-10-7a12 12 0 013.9-4.9L1.9 3.4zM12 5c5 0 9 4.4 10 7a11.8 11.8 0 01-2.7 3.8l-3.4-3.4A4 4 0 0012.6 8.1L9.9 5.4A10.7 10.7 0 0112 5z"),
  "hammer": (24, "M14.5 2.5l7 7-3 3-2-2-8.2 8.2-3-3L13.5 7.5l-2-2z"),
  "uvlock": (24, "M4 4h7v7H4zm2 2v3h3V6zm7-2h7v7h-7zm2 2v3h3V6zM4 13h7v7H4zm2 2v3h3v-3zm9-2a3 3 0 013 3v1h1v4h-8v-4h1v-1a3 3 0 013-3zm0 2a1 1 0 00-1 1v1h2v-1a1 1 0 00-1-1z"),
}

proc renderIcon*(path: string, viewBox, size: int, color = color(1, 1, 1, 1)): Image =
  ## viewBox is the square (or 32x24 for wide icons) design grid width.
  let wide = viewBox == 32
  let h = size
  let w = if wide: size * 4 div 3 else: size
  result = newImage(w, h)
  let s = size.float32 / 24
  result.fillPath(parsePath(path), color, scale(vec2(s, s)))

proc ringIcon(size: int): Image =
  ## Radio button outline.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.strokeStyle = color(1, 1, 1, 1)
  let k = size / 16
  ctx.lineWidth = 1.5 * k
  ctx.strokeCircle(circle(vec2(size / 2, size / 2), size / 2 - 1.5 * k))

proc tri(path: Path, a, b, c: Vec2) =
  path.moveTo(a); path.lineTo(b); path.lineTo(c); path.closePath()

proc mouseIcon*(size: int, button, motion: string): Image =
  ## Blender-style mouse for the status bar's hints: outlined body with the
  ## used button ("left", "right" or "middle") filled. `motion` ("v" or "h")
  ## adds a double arrow to its right for wheel and drag gestures.
  let k = size / 16
  let w = if motion.len > 0: int(round(23 * k)) else: size
  result = newImage(w, size)
  let white = color(1, 1, 1, 1)
  let body = newPath()
  body.roundedRect(rect(3.5 * k, 1 * k, 9 * k, 14 * k), 4.5 * k, 4.5 * k, 4 * k, 4 * k)
  let wheel = newPath()
  wheel.roundedRect(rect(6.75 * k, 2.75 * k, 2.5 * k, 4 * k), 1.25 * k, 1.25 * k, 1.25 * k, 1.25 * k)
  if button in ["left", "right"]:
    let fill = newImage(w, size)
    let part = newPath()
    part.rect(if button == "left": rect(0, 0, 8 * k, 7.5 * k) else: rect(8 * k, 0, 8 * k, 7.5 * k))
    fill.fillPath(part, white)
    let mask = newImage(w, size)
    mask.fillPath(body, white)
    fill.draw(mask, blendMode = MaskBlend)
    # Keep the wheel's outline readable on top of the filled button.
    let gap = newPath()
    gap.roundedRect(rect(6 * k, 2 * k, 4 * k, 5.5 * k), 2 * k, 2 * k, 2 * k, 2 * k)
    let cut = newImage(w, size)
    cut.fillPath(gap, white)
    fill.draw(cut, blendMode = SubtractMaskBlend)
    result.draw(fill)
  let lw = 1.2 * k
  result.strokePath(body, white, strokeWidth = lw)
  let lines = newPath()
  lines.moveTo(3.5 * k, 7.5 * k); lines.lineTo(12.5 * k, 7.5 * k)
  lines.moveTo(8 * k, 1 * k); lines.lineTo(8 * k, 2.75 * k)
  lines.moveTo(8 * k, 6.75 * k); lines.lineTo(8 * k, 7.5 * k)
  result.strokePath(lines, white, strokeWidth = lw)
  if button == "middle": result.fillPath(wheel, white)
  result.strokePath(wheel, white, strokeWidth = lw)
  if motion.len > 0:
    let arrow = newPath()
    if motion == "v":
      arrow.rect(rect(17.4 * k, 4 * k, 1.2 * k, 8 * k))
      arrow.tri(vec2(18 * k, 1 * k), vec2(20.5 * k, 4.5 * k), vec2(15.5 * k, 4.5 * k))
      arrow.tri(vec2(18 * k, 15 * k), vec2(20.5 * k, 11.5 * k), vec2(15.5 * k, 11.5 * k))
    else:
      arrow.rect(rect(17 * k, 7.4 * k, 3 * k, 1.2 * k))
      arrow.tri(vec2(14.5 * k, 8 * k), vec2(17.5 * k, 5.5 * k), vec2(17.5 * k, 10.5 * k))
      arrow.tri(vec2(22.5 * k, 8 * k), vec2(19.5 * k, 5.5 * k), vec2(19.5 * k, 10.5 * k))
    result.fillPath(arrow, white)

# Status bar hint key -> (atlas image, button, motion).
const mouseIcons* = {
  "LMB": ("mouse-lmb16", "left", ""),
  "RMB": ("mouse-rmb16", "right", ""),
  "MMB": ("mouse-mmb16", "middle", ""),
  "Wheel": ("mouse-wheel16", "middle", "v"),
  "Drag": ("mouse-drag16", "left", "h"),
  "MDrag": ("mouse-mdrag16", "middle", "h"),
  "RDrag": ("mouse-rdrag16", "right", "h"),
}

proc addIcons*(builder: AtlasBuilder, scale = 1'f32) =
  ## Names keep the nominal size; images are rasterized at size * scale.
  proc px(size: int): int = int(round(size.float32 * scale))
  for (name, spec) in iconPaths:
    for size in [16, 20]:
      let img = renderIcon(spec[1], spec[0], px(size))
      discard builder.addImage(name & $size, img)
  discard builder.addImage("ring16", ringIcon(px(16)))
  for (_, spec) in mouseIcons:
    discard builder.addImage(spec[0], mouseIcon(px(16), spec[1], spec[2]))

proc appIcon*(): Image =
  ## Window icon: accent crown on a dark rounded tile.
  result = newImage(64, 64)
  let ctx = newContext(result)
  ctx.fillStyle = parseHtmlColor("#17181c")
  ctx.fillRoundedRect(rect(0, 0, 64, 64), 14)
  result.fillPath(parsePath(crownPath), parseHtmlColor("#9d8cff"),
    translate(vec2(8, 6)) * scale(vec2(2, 2)))
