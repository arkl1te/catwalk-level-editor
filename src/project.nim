## Level projects: an editable copy of a level, laid out as OniSplit wants it.
##
##   <projects>/<Folder>/
##     project.json        title, environment and sky name, level number, source level
##     oni/                every instance of the level (OniSplit -export)
##     objects/*.xml       BINACJBO* object lists
##     geometry.json       the environment geometry as Catwalk edits it
##     env/                *_bnv.dae (AI rooms), images/ and markers/ (textures as TGA)
##     IGMD/<env>/*.bsl    the level's scripts
##     build/              scratch space for Build
##
## A project made from scratch (New empty level) has no oni/ folder: Build
## makes the whole level with OniSplit -create:level, with AI rooms generated
## from the floors and the sky taken from level 0. Its env/images hold the
## environment textures of the game levels picked when it was created.
##
## Build writes AE/GameDataFolder/CustomLevels/<Folder>/, which the Custom Game
## mod lists; Play starts Oni with ARKLITE_AUTOSTART=<Folder> (and
## ARKLITE_SAVEPOINT=<n> to start from a save point).

import std/[os, osproc, json, strutils, strtabs, algorithm, re, sets, times]
import vmath
import jobs, geometry, geomops, objtemplates

type
  Config* = object
    aeDir*: string            ## Oni AE install (has Tools/OniSplit.exe and GameDataFolder)
    projectsDir*: string
    launchScript*: string     ## Starts the game; run with ARKLITE_AUTOSTART set.
    mono*: string
    customLevelsDir*: string  ## Override for where Build writes; empty = AE's CustomLevels.
    recentProjects*: seq[string]  ## Project folders, most recently opened first.

  Project* = ref object
    dir*: string
    folder*: string           ## Folder name; also the CustomLevels folder and autostart key.
    title*: string            ## Name shown in Oni's Custom Game list.
    envName*: string          ## ONLV/AKEV name, e.g. EnvWarehouse; also the IGMD folder.
    sky*: string              ## ONSK name.
    levelNumber*: int
    source*: string           ## e.g. level1_Final
    geometryEdited*: bool     ## Build must rebuild the environment.
    startSavePoint*: int      ## Play starts here (0 = the level's beginning).
    scratch*: bool            ## Made from scratch, not imported from a game level.
    music*: string            ## Track started when the level loads ("" = none).
    musicVolume*: float       ## 0..1

const
  ## Level numbers of the original game. Others in GameDataFolder come from mods.
  OriginalLevels* = [1, 2, 3, 4, 6, 8, 9, 10, 11, 12, 13, 14, 18, 19]
  ## Skies in level 0, which every level can use by name.
  Skies* = ["afternoon", "sunset", "night", "crapsky"]
  ## Music (OSBD ambient sounds) in level 0 that every level can start by name.
  ## Only tracks whose sounds are all in the game data: the AE level 0 lacks every
  ## sound of mus_fite, mus_cool13, mus_om02, mus_xgrv1, mus_xgrv2 and several atm_.
  MusicTracks* = ["mus_amasian", "mus_ambgrv1", "mus_ambgrv1b", "mus_ambgrv2", "mus_asian",
    "mus_asianb", "mus_chase", "mus_choral1", "mus_cool19", "mus_cool4", "mus_fiteb",
    "mus_fitec", "mus_heart", "mus_low1", "mus_lz", "mus_main01", "mus_main02", "mus_main03",
    "mus_om01", "mus_om03", "mus_ot", "mus_pursuit", "mus_sad1", "mus_space01", "mus_sv",
    "mus_trt", "mus_wls", "mus_xtr1", "mus_xtr2", "mus_xtr5",
    "atm_cl05", "atm_cl09", "atm_cl10", "atm_cl11", "atm_cl12", "atm_cl16", "atm_cl22",
    "atm_ft68", "atm_ft81", "atm_gr06", "atm_gr09", "atm_low1", "atm_low_perc1",
    "atm_low_perc2"]
  DefaultMusicVolume* = 0.75
  ## File number of levels made from scratch. Custom Game mounts a level under
  ## any number; this one is no original level's.
  ScratchLevelNumber* = 50

proc configPath*(): string = getConfigDir() / "catwalk" / "config.json"

proc defaultConfig*(): Config =
  Config(
    aeDir: getHomeDir() / "Games/oni-x/drive_c/Program Files (x86)/Oni/AE",
    projectsDir: getHomeDir() / "Documents/Oni Levels",
    launchScript: getHomeDir() / ".local/bin/oni-ae-game.sh",
    mono: "mono")

proc loadConfig*(): Config =
  result = defaultConfig()
  # Settings saved before the rename are still picked up.
  for path in [configPath(), getConfigDir() / "oni-level-editor" / "config.json"]:
    if not fileExists(path): continue
    try:
      let j = parseFile(path)
      if j.hasKey("aeDir"): result.aeDir = j["aeDir"].getStr
      if j.hasKey("projectsDir"): result.projectsDir = j["projectsDir"].getStr
      if j.hasKey("launchScript"): result.launchScript = j["launchScript"].getStr
      if j.hasKey("mono"): result.mono = j["mono"].getStr
      if j.hasKey("customLevelsDir"): result.customLevelsDir = j["customLevelsDir"].getStr
      for d in j{"recentProjects"}.getElems: result.recentProjects.add d.getStr
      break
    except CatchableError: discard
  if getEnv("ONI_AE_DIR").len > 0: result.aeDir = getEnv("ONI_AE_DIR")

proc save*(c: Config) =
  createDir(configPath().parentDir)
  writeFile(configPath(), pretty(%*{"aeDir": c.aeDir, "projectsDir": c.projectsDir,
    "launchScript": c.launchScript, "mono": c.mono, "customLevelsDir": c.customLevelsDir,
    "recentProjects": c.recentProjects}))

proc noteOpened*(c: var Config, dir: string) =
  ## Moves dir to the front of the recent projects and saves the config.
  let d = dir.normalizedPath
  var keep = @[d]
  for r in c.recentProjects:
    if r != d and keep.len < 50: keep.add r
  c.recentProjects = keep
  try: c.save()
  except CatchableError: discard

proc gameData*(c: Config): string = c.aeDir / "GameDataFolder"
proc oniSplit*(c: Config): string = c.aeDir / "Tools/OniSplit.exe"
proc customLevels*(c: Config): string =
  if c.customLevelsDir.len > 0: c.customLevelsDir else: c.gameData / "CustomLevels"

proc gameLevels*(c: Config): seq[int] =
  ## Original game levels present in the game folder.
  for n in OriginalLevels:
    if fileExists(c.gameData / "level" & $n & "_Final.dat"): result.add n

# --- project files -----------------------------------------------------------

proc oniDir*(p: Project): string = p.dir / "oni"
proc objectsDir*(p: Project): string = p.dir / "objects"
proc envDir*(p: Project): string = p.dir / "env"
proc imagesDir*(p: Project): string = p.envDir / "images"
proc markersDir*(p: Project): string = p.envDir / "markers"
proc buildDir*(p: Project): string = p.dir / "build"
proc logPath*(p: Project): string = p.dir / "build" / "last-job.log"
proc bnvDae*(p: Project): string = p.envDir / p.envName & "_bnv.dae"
proc geometryPath*(p: Project): string = p.dir / "geometry.json"
proc hasGeometry*(p: Project): bool = fileExists(p.geometryPath)
proc baseTexturesPath*(p: Project): string = p.dir / "base-textures.txt"

proc save*(p: Project) =
  writeFile(p.dir / "project.json", pretty(%*{"title": p.title, "envName": p.envName,
    "sky": p.sky, "levelNumber": p.levelNumber, "source": p.source,
    "geometryEdited": p.geometryEdited, "startSavePoint": p.startSavePoint,
    "scratch": p.scratch, "music": p.music, "musicVolume": p.musicVolume}))

proc globOni(dir, prefix: string): seq[string] =
  for p in walkFiles(dir / prefix & "*.oni"): result.add p
  result.sort

proc findSky(p: Project): string =
  let onsk = globOni(p.oniDir, "ONSK")
  if onsk.len > 0: onsk[0].splitFile.name["ONSK".len .. ^1] else: ""

proc openProject*(dir: string): Project =
  let j = parseFile(dir / "project.json")
  result = Project(dir: dir, folder: dir.lastPathPart, title: j{"title"}.getStr(dir.lastPathPart),
    envName: j{"envName"}.getStr, sky: j{"sky"}.getStr, levelNumber: j{"levelNumber"}.getInt(1),
    source: j{"source"}.getStr, geometryEdited: j{"geometryEdited"}.getBool,
    startSavePoint: j{"startSavePoint"}.getInt, scratch: j{"scratch"}.getBool,
    music: j{"music"}.getStr, musicVolume: j{"musicVolume"}.getFloat(DefaultMusicVolume))
  if result.sky.len == 0 and not result.scratch: result.sky = result.findSky

proc isProject*(dir: string): bool = fileExists(dir / "project.json")

proc listProjects*(c: Config): seq[string] =
  if dirExists(c.projectsDir):
    for kind, path in walkDir(c.projectsDir):
      if kind in {pcDir, pcLinkToDir} and path.isProject: result.add path
  # Most recently opened first; projects never opened here by when they were last saved.
  proc key(path: string): (int, float) =
    let i = c.recentProjects.find(path.normalizedPath)
    if i >= 0: return (i, 0.0)
    try: (int.high, -getLastModificationTime(path / "project.json").toUnixFloat)
    except OSError: (int.high, 0.0)
  result.sort(proc(x, y: string): int = cmp((key(x), x), (key(y), y)))

proc savePoints*(p: Project): seq[int] =
  ## Save points the level's scripts handle ("if (save_point eq N)" and the like).
  var found: HashSet[int]
  let pat = re"save_point\s+eq\s+(\d+)"
  for f in walkDirRec(p.dir / "IGMD"):
    if not f.endsWith(".bsl"): continue
    for m in findAll(readFile(f), pat):
      let digits = m.split({' ', '\t'})[^1]
      try:
        let n = parseInt(digits)
        if n > 0 and n < 10: found.incl n
      except ValueError: discard
  for n in found: result.add n
  result.sort

proc splitArgs(c: Config, args: varargs[string]): seq[string] =
  result = @[c.mono, c.oniSplit]
  for a in args: result.add a

proc copyTree(src, dst: string) =
  if dirExists(dst): removeDir(dst)
  copyDir(src, dst)

# --- jobs --------------------------------------------------------------------

proc geometrySteps*(c: Config, p: Project): seq[Step] =
  ## Dumps the level's AKEV to XML and converts it to geometry.json.
  let xmlDir = p.buildDir / "akev"
  @[
    command("Reading geometry", proc(): seq[string] =
      if dirExists(xmlDir): removeDir(xmlDir)
      c.splitArgs("-extract:xml", xmlDir) & globOni(p.oniDir, "AKEV")),
    action("Converting geometry", proc() =
      var xmls: seq[string]
      for f in walkFiles(xmlDir / "AKEV*.xml"): xmls.add f
      if xmls.len == 0: raise newException(IOError, "OniSplit wrote no AKEV XML")
      let g = importAkevXml(xmls[0])
      g.separateObjectPoints()
      g.save(p.geometryPath)
      writeFile(p.baseTexturesPath, g.textureNames.join("\n") & "\n")
      removeDir(xmlDir))]

proc geometryJob*(c: Config, p: Project, onDone: proc()): Job =
  ## For projects made before Catwalk edited geometry.
  newJob("Preparing geometry", p.logPath, geometrySteps(c, p) & @[action("Done", onDone)])

proc importJob*(c: Config, levelNumber: int, folder, title: string,
                onDone: proc(p: Project)): Job =
  ## Copies game level <levelNumber> into a new project folder.
  let
    dir = c.projectsDir / folder
    dat = c.gameData / "level" & $levelNumber & "_Final.dat"
    p = Project(dir: dir, folder: folder, title: title, levelNumber: levelNumber,
                source: "level" & $levelNumber & "_Final")
  if dirExists(dir): raise newException(IOError, "A project named " & folder & " already exists")
  if not fileExists(dat): raise newException(IOError, "Not found: " & dat)
  createDir(dir)
  var steps = @[
    command("Exporting instances", proc(): seq[string] =
      c.splitArgs("-export", p.oniDir, dat)),
    action("Reading level name", proc() =
      let onlv = globOni(p.oniDir, "ONLV")
      if onlv.len == 0: raise newException(IOError, "no ONLV instance in " & dat)
      p.envName = onlv[0].splitFile.name["ONLV".len .. ^1]
      p.sky = p.findSky
      p.save()),
    command("Extracting objects", proc(): seq[string] =
      c.splitArgs("-extract:xml", p.objectsDir) & globOni(p.oniDir, "BINACJBO")),
    command("Extracting textures and rooms", proc(): seq[string] =
      c.splitArgs("-extract:dae", p.envDir) & globOni(p.oniDir, "AKEV"))]
  steps.add geometrySteps(c, p)
  steps.add @[
    action("Copying scripts", proc() =
      let src = c.gameData / "IGMD" / p.envName
      if dirExists(src): copyTree(src, p.dir / "IGMD" / p.envName)),
    action("Done", proc() = onDone(p))]
  newJob("Importing " & p.source, dir / "build" / "last-job.log", steps)

const PlayerStart = """<?xml version="1.0" encoding="utf-8"?>
<Oni>
  <Objects>
    <CHAR Id="1">
      <Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
      <OSD><Flags>IsPlayer</Flags><Class>konoko_generic</Class><Name>player</Name><Weapon></Weapon>
        <Scripts><Spawn></Spawn><Die></Die><Combat></Combat><Alarm></Alarm><Hurt></Hurt><Defeated></Defeated><OutOfAmmo></OutOfAmmo><NoPath></NoPath></Scripts>
        <AdditionalHealth>0</AdditionalHealth><Job><Type>None</Type><PatrolPathId>0</PatrolPathId></Job>
        <Behaviors><CombatId>0</CombatId><MeleeId>0</MeleeId><NeutralId>0</NeutralId></Behaviors>
        <Inventory><Ammo><Use>0</Use><Drop>0</Drop></Ammo><EnergyCell><Use>0</Use><Drop>0</Drop></EnergyCell><Hypo><Use>0</Use><Drop>0</Drop></Hypo><Shield><Use>0</Use><Drop>0</Drop></Shield><Invisibility><Use>0</Use><Drop>0</Drop></Invisibility></Inventory>
        <Team>Konoko</Team><AmmoPercentage>100</AmmoPercentage>
        <Alert><Initial>Lull</Initial><Minimal>Lull</Minimal><JobStart>Low</JobStart><Investigate>Medium</Investigate></Alert>
        <AlarmGroups>0</AlarmGroups><Pursuit><StrongUnseen>Look</StrongUnseen><WeakUnseen>Forget</WeakUnseen><StrongSeen>Look</StrongSeen><WeakSeen>Look</WeakSeen><Lost>ReturnToJob</Lost></Pursuit></OSD>
    </CHAR>
  </Objects>
</Oni>
"""

proc envNameFor*(folder: string): string =
  ## ONLV/AKEV and script folder name for a new level: the folder's letters and digits.
  for ch in folder:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: result.add ch
  if result.len == 0 or result[0] in {'0'..'9'}: result = "Level" & result

proc textureSteps(c: Config, p: Project, n: int, src: string): seq[Step] =
  ## Puts game level n's environment textures into the project's env/.
  @[
    command("Reading level " & $n, proc(): seq[string] =
      c.splitArgs("-export", src / "oni", c.gameData / "level" & $n & "_Final.dat")),
    command("Extracting textures of level " & $n, proc(): seq[string] =
      c.splitArgs("-extract:dae", src / "env") & globOni(src / "oni", "AKEV")),
    action("Collecting textures of level " & $n, proc() =
      for sub in [("images", p.imagesDir), ("markers", p.markersDir)]:
        createDir(sub[1])
        for f in walkFiles(src / "env" / sub[0] / "*.tga"):
          let name = f.extractFilename
          if not name.startsWith("bnv_grid") and not fileExists(sub[1] / name):
            moveFile(f, sub[1] / name)
      removeDir(src))]

proc newLevelJob*(c: Config, folder, title: string, textureLevels: seq[int], sky: string,
                  onDone: proc(p: Project)): Job =
  ## A new, empty level: a floor and a player start, with the environment
  ## textures of the given game levels to build with.
  let
    dir = c.projectsDir / folder
    tex = dir / "build" / "textures"
    p = Project(dir: dir, folder: folder, title: title, envName: envNameFor(folder), sky: sky,
                levelNumber: ScratchLevelNumber, source: "level" & $ScratchLevelNumber & "_Final",
                scratch: true)
  if dirExists(dir): raise newException(IOError, "A project named " & folder & " already exists")
  if textureLevels.len == 0: raise newException(ValueError, "Pick at least one level for textures")
  for n in textureLevels:
    if not fileExists(c.gameData / "level" & $n & "_Final.dat"):
      raise newException(IOError, "Not found: " & c.gameData / "level" & $n & "_Final.dat")
  createDir(dir)
  var steps: seq[Step]
  for n in textureLevels: steps.add textureSteps(c, p, n, tex / $n)
  steps.add @[
    action("Creating level", proc() =
      var names: seq[string]
      for f in walkFiles(p.imagesDir / "*.tga"): names.add f.splitFile.name
      names.sort
      var floor = if names.len > 0: names[0] else: "NONE"
      if "WH_GREYFLOOR" in names: floor = "WH_GREYFLOOR"   # level 1's plain grey floor
      else:
        for n in names:
          if "FLOOR" in n.toUpperAscii:
            floor = n
            break
      let g = Geometry()
      discard g.addBox(vec3(-256, -16, -256), vec3(256, 0, 256), defaultAttr(floor),
                       proc(t: string): float32 = 64)
      g.save(p.geometryPath)
      createDir(p.objectsDir)
      writeFile(p.objectsDir / "BINACJBOCharacter.xml", PlayerStart)
      let igmd = p.dir / "IGMD" / p.envName
      createDir(igmd)
      writeFile(igmd / p.envName & "_main.bsl",
        "# " & p.title & ": level scripts. Oni runs main() when the level starts.\n\n" &
        "func void main(void)\n{\n\tgs_farclipplane_set 5000\n}\n")
      p.save()
      if dirExists(tex): removeDir(tex)),
    action("Done", proc() = onDone(p))]
  newJob("Creating " & folder, dir / "build" / "last-job.log", steps)

proc scratchSteps(c: Config, p: Project, work, geo: string): seq[Step] =
  ## The whole level from geometry.json: OniSplit -create:level writes the
  ## environment, the ONLV and (empty) object lists, and the textures used.
  let
    akevName = "AKEV" & p.envName & ".oni"
    onlvName = "ONLV" & p.envName & ".oni"
  var levelXml = ""
  var model: Geometry
  var linkedObjects = false
  result = @[
    action("Writing geometry", proc() =
      if dirExists(geo): removeDir(geo)
      model = if p.hasGeometry: loadGeometry(p.geometryPath) else: Geometry()
      for f in model.faces:
        if f.objectId != -1: linkedObjects = true
      let rooms = geo / "src" / "rooms.dae"
      let n = writeRoomsDae(model, rooms)
      let f = open(p.logPath, fmAppend)
      f.writeLine $n & " AI rooms from the floors"
      f.close()
      levelXml = writeLevelSource(model, geo / "src", p.envName, p.sky, p.imagesDir,
                                  p.markersDir, @[rooms])),
    command("Building level", proc(): seq[string] =
      c.splitArgs("-create:level", geo / "out", levelXml)),
    # Geometry owned by objects (furniture, consoles, triggers): OniSplit doesn't
    # link it, so the quads' ObjectId and the ONLV's object quad lists are put
    # in afterwards, as for rebuilt game levels.
    command("Reading level back", proc(): seq[string] =
      if not linkedObjects: return @["true"]
      c.splitArgs("-extract:xml", geo / "xml", geo / "out" / akevName, geo / "out" / onlvName)),
    action("Linking object geometry", proc() =
      if not linkedObjects: return
      let r = restoreObjectIds(model, geo / "xml" / "AKEV" & p.envName & ".xml", geo / "out" / akevName)
      let links = remapLevelLinks(r.built, r.built, r.ids, geo / "xml" / "ONLV" & p.envName & ".xml")
      let f = open(p.logPath, fmAppend)
      f.writeLine $r.linked & " of " & $r.faces & " quads linked to objects, " & $links.added &
                  " object quad lists"
      f.close()),
    command("Writing level links", proc(): seq[string] =
      if not linkedObjects: return @["true"]
      c.splitArgs("-create", geo / "onlv", geo / "xml" / "ONLV" & p.envName & ".xml")),
    action("Linking level", proc() =
      if not linkedObjects: return
      removeFile(geo / "out" / onlvName)
      copyFile(geo / "onlv" / onlvName, geo / "out" / onlvName)),
    command("Writing marker textures", proc(): seq[string] =
      var tgas: seq[string]
      for f in walkFiles(p.markersDir / "_marker_*.tga"): tgas.add f
      if tgas.len == 0: raise newException(IOError, "no marker textures in " & p.markersDir)
      c.splitArgs("-create:txmp", geo / "markers") & tgas),
    action("Collecting level", proc() =
      if not fileExists(geo / "out" / akevName) or not fileExists(geo / "out" / onlvName):
        raise newException(IOError, "OniSplit wrote no level (see the log)")
      # Object lists compiled from objects/ win over the empty ones.
      for f in walkFiles(geo / "out" / "*.oni"):
        let dst = work / f.extractFilename
        if not fileExists(dst): copyFile(f, dst)
      for f in walkFiles(geo / "markers" / "TXMP*.oni"):
        let dst = work / f.extractFilename
        if not fileExists(dst): copyFile(f, dst)
      # A quad whose texture resolves nowhere crashes the game while loading.
      var known: HashSet[string]
      for t in walkFiles(work / "TXMP*.oni"): known.incl t.extractFilename[4 .. ^5].toLowerAscii
      var missing: seq[string]
      if p.hasGeometry:
        for fc in loadGeometry(p.geometryPath).faces:
          if markerMaterial(fc).len == 0 and fc.texture.toLowerAscii notin known and
             fc.texture notin missing: missing.add fc.texture
      if missing.len > 0:
        raise newException(ValueError, "textures used but not in env/images: " & missing.join(", ")))]
  if p.sky.len == 0:
    # -create:level always links a sky; a level without one has an empty link.
    result.add @[
      command("Reading level", proc(): seq[string] =
        c.splitArgs("-extract:xml", geo / "onlv-xml", work / onlvName)),
      action("Removing sky", proc() =
        let x = geo / "onlv-xml" / "ONLV" & p.envName & ".xml"
        writeFile(x, readFile(x).replace(re"<SkyBox>[^<]*</SkyBox>", "<SkyBox></SkyBox>"))),
      command("Writing level", proc(): seq[string] =
        c.splitArgs("-create", geo / "onlv", geo / "onlv-xml" / "ONLV" & p.envName & ".xml")),
      action("Linking level", proc() =
        removeFile(work / onlvName)
        copyFile(geo / "onlv" / onlvName, work / onlvName))]

proc startOnLoad(p: Project, igmd: string) =
  ## Makes the built level's main() start the particles tagged AutoStartTag and
  ## the project's music.
  var line = ""
  let objs = p.objectsDir / "BINACJBOParticle.xml"
  if fileExists(objs) and ("<Tag>" & AutoStartTag & "</Tag>") in readFile(objs):
    line.add "\n\t# Added by Catwalk: particles placed to run from the start.\n\tparticle " &
             AutoStartTag & " do start\n"
  if p.music.len > 0:
    line.add "\n\t# Added by Catwalk: the level's music.\n\tsound_music_start " & p.music &
             " " & formatFloat(clamp(p.musicVolume, 0.0, 1.0), ffDecimal, 2) & "\n"
  if line.len == 0: return
  let mainPat = re"func\s+(void\s+)?main\s*\(\s*(void)?\s*\)\s*\{"
  if dirExists(igmd):
    for f in walkFiles(igmd / "*.bsl"):
      let s = readFile(f)
      let (_, last) = findBounds(s, mainPat)
      if last >= 0:
        writeFile(f, s[0 .. last] & line & s[last + 1 .. ^1])
        return
  createDir(igmd)
  writeFile(igmd / "catwalk_main.bsl", "func void main(void)\n{" & line & "}\n")

proc buildJob*(c: Config, p: Project, then: seq[Step] = @[]): Job =
  ## Rebuilds the level into CustomLevels/<Folder>/. The environment is rebuilt
  ## from geometry.json only when the geometry was edited.
  let
    work = p.buildDir / "oni"
    objs = p.buildDir / "objects"
    geo = p.buildDir / "geometry"
    outDir = c.customLevels / p.folder
    dat = outDir / p.source & ".dat"
    akevName = "AKEV" & p.envName & ".oni"
    onlvName = "ONLV" & p.envName & ".oni"
  var steps = @[
    action("Preparing", proc() =
      for d in [work, objs]:
        if dirExists(d): removeDir(d)
        createDir(d)
      for f in walkFiles(p.oniDir / "*.oni"):
        try: createHardlink(f, work / f.extractFilename)
        except OSError: copyFile(f, work / f.extractFilename)),
    command("Compiling objects", proc(): seq[string] =
      var xmls: seq[string]
      for f in walkFiles(p.objectsDir / "*.xml"): xmls.add f
      c.splitArgs("-create", objs) & xmls),
    action("Collecting objects", proc() =
      for f in walkFiles(objs / "*.oni"):
        let dst = work / f.extractFilename
        if fileExists(dst): removeFile(dst)   # a hardlink to the project's copy
        moveFile(f, dst))]

  if p.scratch:
    steps.add scratchSteps(c, p, work, geo)
  elif p.geometryEdited and p.hasGeometry:
    var model: Geometry
    var levelXml = ""
    var linked: tuple[linked, faces: int, ids: seq[int32], built: Geometry]
    steps.add @[
      action("Writing geometry", proc() =
        if dirExists(geo): removeDir(geo)
        model = loadGeometry(p.geometryPath)
        let rooms = if fileExists(p.bnvDae): @[p.bnvDae] else: @[]
        levelXml = writeLevelSource(model, geo / "src", p.envName, p.sky, p.imagesDir,
                                    p.markersDir, rooms)),
      command("Building environment", proc(): seq[string] =
        c.splitArgs("-create:level", geo / "out", levelXml)),
      command("Reading environment back", proc(): seq[string] =
        c.splitArgs("-extract:xml", geo / "xml", geo / "out" / akevName)),
      # OniSplit links ghosts and door frames to TXMP_marker_* but doesn't write
      # those textures; the engine dereferences every quad's texture on load.
      command("Writing marker textures", proc(): seq[string] =
        var tgas: seq[string]
        for f in walkFiles(p.markersDir / "_marker_*.tga"): tgas.add f
        if tgas.len == 0: raise newException(IOError, "no marker textures in " & p.markersDir)
        c.splitArgs("-create:txmp", geo / "markers") & tgas),
      action("Linking object geometry", proc() =
        let akevOni = geo / "out" / akevName
        linked = restoreObjectIds(model, geo / "xml" / "AKEV" & p.envName & ".xml", akevOni)
        let dst = work / akevName
        if fileExists(dst): removeFile(dst)
        copyFile(akevOni, dst)
        # The original AGDB has one debug entry per original quad; packed next to
        # the rebuilt AKEV it would win over the AKEV's own (empty) one and no
        # longer match the quad count.
        let agdb = work / "AGDB" & p.envName & ".oni"
        if fileExists(agdb): removeFile(agdb)
        # Textures: only ones the level didn't have (added in Catwalk). Textures
        # the original referenced but didn't contain come from level 0 at runtime.
        var base: HashSet[string]
        if fileExists(p.baseTexturesPath):
          for l in readFile(p.baseTexturesPath).splitLines:
            if l.len > 0: base.incl l
        for f in walkFiles(geo / "out" / "TXMP*.oni"):
          let name = f.extractFilename
          if not fileExists(work / name) and name[4 .. ^5] notin base:
            copyFile(f, work / name)
        for f in walkFiles(geo / "markers" / "TXMP*.oni"):
          let dst = work / f.extractFilename
          if fileExists(dst): removeFile(dst)
          copyFile(f, dst)),
      # The level's ONLV refers to AKEV quads by index (object quad lists, door
      # frames); remap those from the original AKEV to the rebuilt one.
      command("Reading level links", proc(): seq[string] =
        c.splitArgs("-extract:xml", geo / "orig", p.oniDir / akevName, p.oniDir / onlvName)),
      action("Remapping level links", proc() =
        let orig = importAkevXml(geo / "orig" / "AKEV" & p.envName & ".xml")
        let r = remapLevelLinks(orig, linked.built, linked.ids,
                                geo / "orig" / "ONLV" & p.envName & ".xml")
        let f = open(p.logPath, fmAppend)
        f.writeLine $r.objects & " object quad lists (" & $r.added & " new), " & $r.doors &
                    " doors (" & $r.lostDoors & " without a matching frame)"
        f.close()
        # A quad whose texture resolves nowhere crashes the game while loading.
        # Resolvable: packed with the level, or used by the original level (whose
        # missing ones come from level 0). Names match case-insensitively.
        var known: HashSet[string]
        for t in walkFiles(work / "TXMP*.oni"): known.incl t.extractFilename[4 .. ^5].toLowerAscii
        for fc in orig.faces: known.incl fc.texture.toLowerAscii
        var missing: seq[string]
        for fc in linked.built.faces:
          if fc.texture.toLowerAscii notin known and fc.texture notin missing: missing.add fc.texture
        linked.built = nil
        if missing.len > 0:
          raise newException(ValueError, "textures used but not available in game: " & missing.join(", "))),
      command("Writing level links", proc(): seq[string] =
        c.splitArgs("-create", geo / "onlv", geo / "orig" / "ONLV" & p.envName & ".xml")),
      action("Linking level", proc() =
        let dst = work / onlvName
        if fileExists(dst): removeFile(dst)   # a hardlink to the project's copy
        copyFile(geo / "onlv" / onlvName, dst))]

  steps.add @[
    action("Preparing output", proc() =
      if not dirExists(c.customLevels):
        raise newException(IOError, "CustomLevels folder missing (is the Custom Game mod installed?): " & c.customLevels)
      createDir(outDir)
      for f in walkFiles(outDir / "level*_Final.*"): removeFile(f)),
    command("Packing level", proc(): seq[string] =
      c.splitArgs("-import:pc", work, dat)),
    action("Writing level info", proc() =
      writeFile(outDir / "level.ini", "[level]\nname=" & p.title & "\nsource=" &
                $p.levelNumber & "\n")
      let igmd = p.dir / "IGMD"
      if dirExists(outDir / "IGMD"): removeDir(outDir / "IGMD")
      if dirExists(igmd): copyTree(igmd, outDir / "IGMD")
      startOnLoad(p, outDir / "IGMD" / p.envName))]
  steps.add then
  newJob("Building " & p.folder, p.logPath, steps)

proc launchStep*(c: Config, p: Project): Step =
  ## Starts the game straight into the project's level.
  let savePoint = p.startSavePoint
  action("Starting Oni", proc() =
    if not fileExists(c.launchScript):
      raise newException(IOError, "launch script not found: " & c.launchScript)
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["ARKLITE_AUTOSTART"] = p.folder
    env["ARKLITE_SAVEPOINT"] = $savePoint
    # Wine's output (crash address and backtrace) goes to build/game.log.
    createDir(p.buildDir)
    let pr = startProcess("/bin/sh", workingDir = c.aeDir, env = env, options = {poDaemon},
                          args = ["-c", "exec \"$0\" >\"$1\" 2>&1", c.launchScript,
                                  p.buildDir / "game.log"])
    pr.close())
