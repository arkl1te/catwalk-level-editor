## Character classes (ONCC) for the Entity tab's Classes page. Every character
## of a class starts with its values: health, AI, sounds, animations. Level 0
## has all of them; they're extracted once into classCacheDir (project.nim),
## and a project keeps the ones it edits in classes/ (Build packs those, see
## classCacheDir). An open class is a LevelObject with tag ONCC that no view
## draws, so field edits and undo work as for objects.

import std/[os, strutils, algorithm, xmltree]
import jobs, project, levelobjects

const ClassCacheVersion = "1"

proc hasClassCache*(): bool =
  let v = classCacheDir() / "version"
  fileExists(v) and readFile(v).strip == ClassCacheVersion

proc classNames*(): seq[string] =
  ## Level 0's classes, from the cache.
  for f in walkFiles(classCacheDir() / "ONCC*.xml"): result.add f.splitFile.name["ONCC".len .. ^1]
  result.sort(cmpIgnoreCase)

proc classCacheJob*(c: Config, logPath: string): Job =
  let dir = classCacheDir()
  let oni = dir / "work"
  newJob("Reading character classes", logPath, @[
    action("Preparing", proc() =
      if dirExists(dir): removeDir(dir)
      createDir(oni)),
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export:ONCC", oni, c.gameData / "level0_Final.dat"]),
    command("Reading classes", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", dir]
      for f in walkFiles(oni / "ONCC*.oni"): result.add f),
    action("Finishing", proc() =
      removeDir(oni)
      if classNames().len == 0: raise newException(IOError, "level 0 has no character classes")
      writeFile(dir / "version", ClassCacheVersion))])

proc classElement(root: XmlNode): XmlNode =
  for c in root:
    if c.kind == xnElement and c.tag == "ONCC": return c

proc originalClass*(name: string): string =
  ## Level 0's version of the class, as a snapshot (LevelObject.snapshot).
  let n = classElement(readXmlFile(originalClassPath(name)))
  if n == nil: raise newException(ValueError, "no ONCC in " & originalClassPath(name))
  $n

proc loadClass*(p: Project, name: string): LevelObject =
  ## The class as the project has it: its edited copy, else level 0's. Either
  ## way it saves to the project's classes/.
  let own = p.classPath(name)
  let root = readXmlFile(if fileExists(own): own else: originalClassPath(name))
  let n = classElement(root)
  if n == nil: raise newException(ValueError, "no ONCC in the file of class " & name)
  LevelObject(tag: "ONCC", node: n, file: ObjectFile(path: own, root: root, list: root))
