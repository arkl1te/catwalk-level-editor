## Skybox images for the 3D view: level 0's skies (every ONSK a project can
## pick), extracted once into ~/.cache/catwalk/sky/<sky>/<face>.tga.
##
## An ONSK links six TXMPs: top, left, right, front, back and an unused
## bottom. Oni_Sky.c (the star placement in FUN_005105a0) gives their
## placement on a cube around the camera, in Oni's Y-up world:
##   top    y = +1   u = (x + 1) / 2   v = (1 - z) / 2
##   right  x = +1   u = (z + 1) / 2   v = (1 - y) / 2
##   left   x = -1   u = (1 - z) / 2   v = (1 - y) / 2
##   back   z = +1   u = (1 - x) / 2   v = (1 - y) / 2
##   front  z = -1   u = (x + 1) / 2   v = (1 - y) / 2
## (v = 0 is the image's top row.)

import std/[os, strutils, tables]
import jobs, project

const
  SkyFaces* = ["top", "left", "right", "front", "back"]   ## ONSK SkyboxTextures order.
  SkyVersion = "1"

proc skyDir*(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk" / "sky"

proc hasSkyCache*(): bool =
  fileExists(skyDir() / "version") and readFile(skyDir() / "version").strip == SkyVersion

proc skyFace*(sky, face: string): string = skyDir() / sky / face & ".tga"

proc skyCacheJob*(c: Config, logPath: string): Job =
  let
    work = skyDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    tga = work / "tga"
  var faces: Table[string, (string, string)]   # TXMP name -> (sky, face)
  let steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, tga]: createDir(d)),
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", oni, c.gameData / "level0_Final.dat"]),
    command("Reading skies", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-extract:xml", xml, oni / "ONSK*.oni"]),
    command("Extracting sky images", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:tga", tga]
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
            result.add oni / link & ".oni"
          i = e
          inc k
      if result.len == 4: result = @["true"]),
    action("Writing skies", proc() =
      for link, (sky, face) in faces:
        let f = tga / link & ".tga"
        if fileExists(f):
          createDir(skyDir() / sky)
          moveFile(f, skyFace(sky, face))
      writeFile(skyDir() / "version", SkyVersion)
      removeDir(work))]
  newJob("Extracting skies", logPath, steps)
