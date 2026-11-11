## Skybox images for the 3D view: level 0's skies (every ONSK a project can
## pick), extracted once into ~/.cache/catwalk/sky/<sky>/<face>.tga.
##
## An ONSK links six TXMPs: top, left, right, front, back and a bottom, which
## level 0's skies leave empty and only Arklite draws. Oni_Sky.c (the star placement in FUN_005105a0) gives their
## placement on a cube around the camera, in Oni's Y-up world:
##   top    y = +1   u = (x + 1) / 2   v = (1 - z) / 2
##   right  x = +1   u = (z + 1) / 2   v = (1 - y) / 2
##   left   x = -1   u = (1 - z) / 2   v = (1 - y) / 2
##   back   z = +1   u = (1 - x) / 2   v = (1 - y) / 2
##   front  z = -1   u = (x + 1) / 2   v = (1 - y) / 2
## (v = 0 is the image's top row.)

import std/[os, strutils, tables]
import jobs, project

const SkyVersion = "1"

proc hasSkyCache*(): bool =
  # Not a new version for onsk.xml: an older Catwalk left open would extract again on seeing it.
  fileExists(skyDir() / "version") and readFile(skyDir() / "version").strip == SkyVersion and
    fileExists(skyDir() / "night" / "onsk.xml")

proc skyImage*(p: Project, sky, face: string): string =
  ## A face of a sky the project can use: its own, or level 0's.
  if p.isCustomSky(sky): p.customSkyDir(sky) / face & ".tga" else: skyFace(sky, face)

proc skyCacheJob*(c: Config, logPath: string): Job =
  let
    work = skyDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    tga = work / "tga"
  var faces: Table[string, (string, string)]   # TXMP name -> (sky, face)
  var steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, tga]: createDir(d))]
  steps.add c.exportTypes("Reading level 0", c.gameData / "level0_Final.dat", oni, ["TXMP", "ONSK"])
  steps.add @[
    command("Reading skies", proc(): seq[string] =
      c.oniSplitCmd & @["-extract:xml", xml, oni / "ONSK*.oni"]),
    commandFiles("Extracting sky images", proc(): FileCommand =
      result.head = c.oniSplitCmd & @["-extract:tga", tga]
      for f in walkFiles(xml / "ONSK*.xml"):
        let sky = f.splitFile.name["ONSK".len .. ^1]
        let x = readFile(f)
        let a = x.find("<SkyboxTextures>")
        let b = x.find("</SkyboxTextures>")
        if a < 0 or b < a: continue
        var i = a
        var k = 0
        while k < SkyFaces.len:
          let s = x.find("<Link>", i)
          if s < 0 or s > b: break
          let e = x.find("</Link>", s)
          let link = x[s + "<Link>".len ..< e].strip
          if link.len > 0 and fileExists(oni / link & ".oni"):
            faces[link] = (sky, SkyFaces[k])
            result.files.add oni / link & ".oni"
          i = e
          inc k),
    action("Writing skies", proc() =
      for link, (sky, face) in faces:
        let f = tga / link & ".tga"
        if fileExists(f):
          createDir(skyDir() / sky)
          moveFile(f, skyFace(sky, face))
      for f in walkFiles(xml / "ONSK*.xml"):   # A graded copy of the sky starts from this.
        let sky = f.splitFile.name["ONSK".len .. ^1]
        if dirExists(skyDir() / sky): copyFile(f, skyDir() / sky / "onsk.xml")
      writeFile(skyDir() / "version", SkyVersion)
      removeDir(work))]
  newJob("Extracting skies", logPath, steps)
