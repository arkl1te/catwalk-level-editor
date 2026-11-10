## Character classes (ONCC) for the Entity tab's Classes page. Every character
## of a class starts with its values: health, AI, sounds, animations. Level 0
## has all of them; they're extracted once into classCacheDir (project.nim),
## and a project keeps the ones it edits in classes/ (Build packs those, see
## classCacheDir). An open class is a LevelObject with tag ONCC that no view
## draws, so field edits and undo work as for objects.

import std/[os, strutils, algorithm, tables, xmltree]
import jobs, project, levelobjects

const ParticlePrefix* = "3RAP:"   ## On a particle class's name wherever character classes are too.

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
      c.oniSplitCmd & @["-export:ONCC", oni, c.gameData / "level0_Final.dat"]),
    command("Reading classes", proc(): seq[string] =
      result = c.oniSplitCmd & @["-extract:xml", dir]
      for f in walkFiles(oni / "ONCC*.oni"): result.add f),
    action("Finishing", proc() =
      removeDir(oni)
      if classNames().len == 0: raise newException(IOError, "level 0 has no character classes")
      writeFile(dir / "version", ClassCacheVersion))])

proc particleNames*(): seq[string] =
  ## Level 0's particle classes, from the cache (particlesim.nim).
  for f in walkFiles(particleCacheDir() / "classes" / "*.xml"):
    result.add ParticlePrefix & f.splitFile.name
  result.sort(cmpIgnoreCase)

proc particleSpawns*(): Table[string, seq[string]] =
  ## What each of level 0's particle classes creates, by emitter or on collision.
  ## A text scan of the cache: parsing some 900 files would stall the frame.
  for f in walkFiles(particleCacheDir() / "classes" / "*.xml"):
    let s = readFile(f)
    var kids: seq[string]
    proc scan(lo, hi: int, tag: string) =
      let open = "<" & tag & ">"
      var p = s.find(open, lo)
      while p >= 0 and p < hi:
        let start = p + open.len
        let stop = s.find("</" & tag & ">", start)
        if stop < 0: return
        let k = ParticlePrefix & s[start ..< stop].strip.toLowerAscii
        if k != ParticlePrefix and k notin kids: kids.add k
        p = s.find(open, stop)
    let e0 = s.find("<Emitters>")
    if e0 >= 0: scan(e0, s.find("</Emitters>", e0), "Class")
    var c = s.find("<CollisionEffect>")
    while c >= 0:
      let stop = s.find("</CollisionEffect>", c)
      if stop < 0: break
      scan(c, stop, "Effect")
      c = s.find("<CollisionEffect>", stop)
    result[ParticlePrefix & f.splitFile.name.toLowerAscii] = kids

proc classElement(root: XmlNode, tag = "ONCC"): XmlNode =
  for c in root:
    if c.kind == xnElement and c.tag == tag: return c

proc originalParticle*(name: string): string =
  ## Level 0's version of the class, as a snapshot.
  let n = classElement(readXmlFile(originalParticlePath(name)), ParticleTag)
  if n == nil: raise newException(ValueError, "no Particle in " & originalParticlePath(name))
  $n

proc loadParticle*(p: Project, name: string): LevelObject =
  ## The class as the project has it, saving to the project's classes/.
  let own = p.particlePath(name)
  let root = readXmlFile(if fileExists(own): own else: originalParticlePath(name))
  let n = classElement(root, ParticleTag)
  if n == nil: raise newException(ValueError, "no Particle in the file of class " & name)
  LevelObject(tag: ParticleTag, node: n, file: ObjectFile(path: own, root: root, list: root))

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
