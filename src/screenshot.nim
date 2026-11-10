## Reads the map views back from the finished frame, overlays included.

import std/[os, strutils]
import silky, pixie, opengl, bumpy
import appstate, camera

proc shownViews*(a: App): seq[int] =
  for i in 0 .. 3:
    if a.views[i].rect.w >= 2: result.add i

proc viewName(a: App, vi: int): string =
  let name = ($a.views[vi].cam.kind).split(' ')[0]
  var same = 0
  for i in a.shownViews:
    if i <= vi and ($a.views[i].cam.kind).split(' ')[0] == name: inc same
  if same > 1: name & "-" & $same else: name

proc readView*(a: App, vi: int): Image =
  ## Only valid after the views were drawn, before the buffers swap
  ## (App.afterFrame).
  let b = a.views[vi].viewBody
  let s = a.sk.uiScale
  let (x, y, w, h) = ((b.x * s).int, (b.y * s).int, (b.w * s).int, (b.h * s).int)
  result = newImage(w, h)
  var pixels = newSeq[uint8](w * h * 4)
  glPixelStorei(GL_PACK_ALIGNMENT, 1)
  glReadPixels(x.GLint, (a.window.size.y - y - h).GLint, w.GLsizei, h.GLsizei, GL_RGBA,
               GL_UNSIGNED_BYTE, pixels[0].addr)
  # GL's rows run bottom to top; the views' alpha means nothing here.
  for row in 0 ..< h:
    let src = (h - 1 - row) * w * 4
    for col in 0 ..< w:
      let p = src + col * 4
      result.data[row * w + col] = rgbx(pixels[p], pixels[p + 1], pixels[p + 2], 255)

proc viewPaths*(a: App, views: seq[int], path: string): seq[string] =
  ## path for one view; path_3D.png, path_Top.png... for several.
  let (dir, name, ext) = path.splitFile
  let suffix = if ext.toLowerAscii == ".png": ext else: ".png"
  let stem = if ext.toLowerAscii == ".png": name else: name & ext
  for vi in views:
    result.add dir / (if views.len == 1: stem else: stem & "_" & a.viewName(vi)) & suffix

proc saveScreenshots*(a: App, path: string) =
  ## One PNG per shown view, as they're on screen.
  let views = a.shownViews
  if views.len == 0:
    a.say("No viewport to take a screenshot of", true)
    return
  let paths = a.viewPaths(views, path)
  try:
    createDir(path.parentDir)
    for i, vi in views: a.readView(vi).writeFile(paths[i])
    a.say(if paths.len == 1: "Saved " & paths[0]
          else: "Saved " & $paths.len & " screenshots in " & path.parentDir)
  except CatchableError as e:
    a.say("Could not save the screenshot: " & e.msg, true)
