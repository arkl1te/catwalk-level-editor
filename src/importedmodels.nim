## Models imported as furniture (modelimport.nim) stay in the entity browser,
## in the Imported models group, to place again in any level. Each one is a
## folder in ~/.local/share/catwalk/imported/ (%LOCALAPPDATA%\catwalk\imported),
## next to the entity library but not part of it (rebuilding that keeps them):
##   entry.json      its name, class, source file and size
##   geometry.json   its faces in object space (Catwalk's geometry.json format)
##   <TEXTURE>.tga   the textures they use, as the import made them
##   preview.png     the browser's tile
## A folder is named after the furniture's class; importing the same file again
## replaces its entry, another file of the same name gets name_2 and so on.

import std/[os, json, strutils, times, algorithm, math, sequtils]
import vmath
import project, presets, geometry, thumbs, modelimport

const
  ImportedGroup* = "Imported models"
  EntryVersion = 1

proc importedDir*(): string = libraryDir().parentDir / "imported"

proc entrySource(dir: string): string =
  try:
    let f = parseFile(dir / "entry.json"){"file"}.getStr
    if f.len > 0: absolutePath(f).normalizedPath else: ""
  except CatchableError: ""

proc entryName(r: ImportedModel, source: string): string =
  ## The folder this import goes in: the one made from the same file, else a
  ## free one.
  var name = r.name
  var n = 2
  while dirExists(importedDir() / name) and entrySource(importedDir() / name) != source:
    let suffix = "_" & $n
    name = r.name[0 ..< min(r.name.len, 31 - suffix.len)] & suffix
    inc n
  name

proc saveImported*(r: ImportedModel, imagesDir: string): string =
  ## Keeps an imported model (its textures are read from imagesDir, where the
  ## import put them) for the entity browser. Returns its name there.
  let source = absolutePath(r.file).normalizedPath
  result = entryName(r, source)
  let dir = importedDir() / result
  let tmp = importedDir() / ("." & result & ".new")
  if dirExists(tmp): removeDir(tmp)
  createDir(tmp)
  r.geo.save(tmp / "geometry.json")
  for t in r.textures:
    if fileExists(imagesDir / t & ".tga"): copyFile(imagesDir / t & ".tga", tmp / t & ".tga")
  var m: ThumbMesh
  m.addGeometry(r.geo, proc(t: string): string = tmp / t & ".tga")
  if not m.isEmpty: m.renderTo(tmp / "preview.png")
  writeFile(tmp / "entry.json", pretty(%*{"version": EntryVersion, "name": result, "class": r.name,
    "file": source, "faces": r.faces, "size": [r.size.x, r.size.y, r.size.z], "textures": r.textures,
    "time": $int64(epochTime() * 1000)}))
  if dirExists(dir): removeDir(dir)
  moveDir(tmp, dir)

proc loadImported*(): seq[Preset] =
  ## The kept models as entity browser presets, by name.
  if not dirExists(importedDir()): return
  for dir in walkDirs(importedDir() / "*"):
    if dir.lastPathPart.startsWith("."): continue
    try:
      let j = parseFile(dir / "entry.json")
      if j{"version"}.getInt != EntryVersion or not fileExists(dir / "geometry.json"): continue
      let size = j{"size"}.getElems
      var detail = j{"file"}.getStr.extractFilename
      if size.len == 3:
        detail.add " · " & size.mapIt($it.getFloat.round.int).join(" x ") & " units"
      var p = Preset(group: ImportedGroup, label: j["name"].getStr, detail: detail, tag: "FURN",
                     xml: furnitureXml(j{"class"}.getStr), prefab: "geometry.json", imported: dir,
                     importStamp: j{"time"}.getStr)
      for t in j{"textures"}.getElems: p.textures.add t.getStr
      result.add p
    except CatchableError: discard   # Half written or damaged: not listed.
  result.sort(proc(x, y: Preset): int = cmpIgnoreCase(x.label, y.label))

proc removeImported*(p: Preset) =
  ## Takes the model out of the entity browser (furniture placed from it stays).
  if p.imported.len > 0 and p.imported.parentDir == importedDir(): removeDir(p.imported)
