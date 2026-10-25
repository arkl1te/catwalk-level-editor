## Level projects: an editable copy of a level, laid out as OniSplit wants it.
##
##   <projects>/<Folder>/
##     project.json        title, environment and sky name, level number, source level
##     oni/                every instance of the level (OniSplit -export)
##     objects/*.xml       BINACJBO* object lists
##     lights.xml          point and directional lights (Catwalk's own; baked into geometry.json's vertex colors)
##     classes/ONCC*.xml   character classes edited in Catwalk (classes.nim)
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

import std/[os, osproc, json, strutils, strtabs, algorithm, re, sets, times, tables, uri, strformat, xmltree, xmlparser]
import vmath
import jobs, geometry, geomops, objtemplates, levelobjects

type
  Config* = object
    aeDir*: string            ## Oni AE install (has Tools/OniSplit.exe and GameDataFolder)
    projectsDir*: string
    launchScript*: string     ## Starts the game; run with ARKLITE_AUTOSTART set.
    mono*: string
    customLevelsDir*: string  ## Override for where Build writes; empty = AE's CustomLevels.
    recentProjects*: seq[string]  ## Project folders, most recently opened first.
    # View and mouse preferences (TrenchBroom's View and Mouse panes).
    brightness*: float        ## Multiplies textures and vertex colors in the 3D view.
    gridOpacity*: float       ## 0..1: grid lines in the 2D and 3D views.
    fov*: float               ## Degrees (vertical); Reset camera zoom goes back to it.
    linearFilter*: bool       ## Textures sampled linearly (else nearest, pixelated).
    lookSpeed*: float         ## 0..1, 0.5 = normal: right-drag look and Alt+right orbit.
    lookInvertX*, lookInvertY*: bool
    panSpeed*: float          ## 0..1, 0.5 = normal: middle-drag pan.
    panInvertX*, panInvertY*: bool
    moveSpeed*: float         ## 0..1, 0.5 = normal: wheel moves the 3D camera.
    invertWheel*: bool        ## 3D wheel move, 2D zoom and the fly speed wheel.
    moveTowardCursor*: bool   ## 3D wheel moves toward the mouse instead of straight ahead.
    # View > Options.
    showTriangles*: bool      ## Wireframes show the faces' triangles, else only their outlines.
    gridColor*: array[3, int] ## Grid lines, 0..255 (their opacity is gridOpacity).
    gridColor3D*: bool        ## The 3D face grid uses gridColor (else black or white per texture).

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
    autoBake*: bool           ## Lights rebake the vertex lighting on every change.
    ambient*: array[3, int]   ## Baked lighting: color every lit corner gets before the lights' light.

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
  DefaultAmbient* = [56, 56, 64]
  ## File number of levels made from scratch. Custom Game mounts a level under
  ## any number; this one is no original level's.
  ScratchLevelNumber* = 50

proc configPath*(): string = getConfigDir() / "catwalk" / "config.json"

proc resetViewPrefs*(c: var Config) =
  ## The View and Mouse preferences' defaults (paths are left alone).
  c.brightness = 1
  c.gridOpacity = 0.5         # TrenchBroom's render/Grid/Alpha.
  c.fov = 70
  c.linearFilter = true
  c.lookSpeed = 0.5
  c.panSpeed = 0.5
  c.moveSpeed = 0.5
  (c.lookInvertX, c.lookInvertY, c.panInvertX, c.panInvertY) = (false, false, false, false)
  (c.invertWheel, c.moveTowardCursor) = (false, false)

proc defaultConfig*(): Config =
  result = Config(
    aeDir: getHomeDir() / "Games/oni-x/drive_c/Program Files (x86)/Oni/AE",
    projectsDir: getHomeDir() / "Documents/Oni Levels",
    launchScript: getHomeDir() / ".local/bin/oni-ae-game.sh",
    mono: "mono", showTriangles: true, gridColor: [255, 255, 255])
  result.resetViewPrefs()

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
      result.brightness = clamp(j{"brightness"}.getFloat(result.brightness), 0, 2)
      result.gridOpacity = clamp(j{"gridOpacity"}.getFloat(result.gridOpacity), 0, 1)
      result.fov = clamp(j{"fov"}.getFloat(result.fov), 30, 120)
      result.linearFilter = j{"linearFilter"}.getBool(result.linearFilter)
      result.lookSpeed = clamp(j{"lookSpeed"}.getFloat(result.lookSpeed), 0.01, 1)
      result.lookInvertX = j{"lookInvertX"}.getBool
      result.lookInvertY = j{"lookInvertY"}.getBool
      result.panSpeed = clamp(j{"panSpeed"}.getFloat(result.panSpeed), 0.01, 1)
      result.panInvertX = j{"panInvertX"}.getBool
      result.panInvertY = j{"panInvertY"}.getBool
      result.moveSpeed = clamp(j{"moveSpeed"}.getFloat(result.moveSpeed), 0.01, 1)
      result.invertWheel = j{"invertWheel"}.getBool
      result.moveTowardCursor = j{"moveTowardCursor"}.getBool
      result.showTriangles = j{"showTriangles"}.getBool(result.showTriangles)
      let gc = j{"gridColor"}
      if gc != nil and gc.kind == JArray and gc.len == 3:
        for i in 0 .. 2: result.gridColor[i] = clamp(gc[i].getInt, 0, 255)
      result.gridColor3D = j{"gridColor3D"}.getBool
      break
    except CatchableError: discard
  if getEnv("ONI_AE_DIR").len > 0: result.aeDir = getEnv("ONI_AE_DIR")

proc save*(c: Config) =
  createDir(configPath().parentDir)
  writeFile(configPath(), pretty(%*{"aeDir": c.aeDir, "projectsDir": c.projectsDir,
    "launchScript": c.launchScript, "mono": c.mono, "customLevelsDir": c.customLevelsDir,
    "recentProjects": c.recentProjects,
    "brightness": c.brightness, "gridOpacity": c.gridOpacity, "fov": c.fov,
    "linearFilter": c.linearFilter, "lookSpeed": c.lookSpeed, "lookInvertX": c.lookInvertX,
    "lookInvertY": c.lookInvertY, "panSpeed": c.panSpeed, "panInvertX": c.panInvertX,
    "panInvertY": c.panInvertY, "moveSpeed": c.moveSpeed, "invertWheel": c.invertWheel,
    "moveTowardCursor": c.moveTowardCursor, "showTriangles": c.showTriangles,
    "gridColor": c.gridColor, "gridColor3D": c.gridColor3D}))

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

proc libraryDir*(): string =
  ## The entity library (library.nim builds it).
  let xdg = getEnv("XDG_DATA_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".local/share") / "catwalk" / "library"

proc libraryDoorsDir*(): string = libraryDir() / "doors"

# Character classes (ONCC): every character of a class starts with its values
# (health, AI, sounds...). All of them are in level 0, extracted once to
# classCacheDir; a project keeps the ones it edits in classes/. The game finds
# a class by name in the instance files in load order (TMrInstance_GetDataPtr,
# 0x4232e0) and level 0 loads before the level, so a copy under the same name
# in the level would never be used: Build packs each edited class as
# <name>EditedSuffix and points the level's characters at that.
const EditedSuffix* = "_cw"

proc classCacheDir*(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk" / "classes"

proc originalClassPath*(name: string): string = classCacheDir() / "ONCC" & name & ".xml"

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
proc lightsPath*(p: Project): string = p.dir / "lights.xml"
proc hasGeometry*(p: Project): bool = fileExists(p.geometryPath)
proc baseTexturesPath*(p: Project): string = p.dir / "base-textures.txt"
proc classesDir*(p: Project): string = p.dir / "classes"
proc classPath*(p: Project, name: string): string = p.classesDir / "ONCC" & name & ".xml"

proc save*(p: Project) =
  writeFile(p.dir / "project.json", pretty(%*{"title": p.title, "envName": p.envName,
    "sky": p.sky, "levelNumber": p.levelNumber, "source": p.source,
    "geometryEdited": p.geometryEdited, "startSavePoint": p.startSavePoint,
    "scratch": p.scratch, "music": p.music, "musicVolume": p.musicVolume,
    "autoBake": p.autoBake, "ambient": p.ambient}))

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
    music: j{"music"}.getStr, musicVolume: j{"musicVolume"}.getFloat(DefaultMusicVolume),
    autoBake: j{"autoBake"}.getBool, ambient: DefaultAmbient)
  let amb = j{"ambient"}.getElems
  if amb.len == 3:
    for i in 0 .. 2: result.ambient[i] = clamp(amb[i].getInt, 0, 255)
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

const TrainingSavePoint* = -1  ## startSavePoint for level 1's Combat Training.

proc hasTraining*(p: Project): bool =
  ## Level 1's save point 0 is Combat Training; the Warehouse itself starts at save point 1.
  p.levelNumber == 1 and not p.scratch

proc gameSavePoint*(p: Project): int =
  ## The save point Oni starts at for startSavePoint (0 = the level's beginning).
  if not p.hasTraining: p.startSavePoint
  elif p.startSavePoint == TrainingSavePoint: 0
  else: max(p.startSavePoint, 1)

proc startLabel*(p: Project, sp: int): string =
  if sp == 0: "Start: beginning"
  elif sp == TrainingSavePoint: "Start: Combat Training"
  else: &"Start: save point {sp}"

proc splitArgs(c: Config, args: varargs[string]): seq[string] =
  result = @[c.mono, c.oniSplit]
  for a in args: result.add a

proc copyTree(src, dst: string) =
  if dirExists(dst): removeDir(dst)
  copyDir(src, dst)

proc copyCreated(src, dst: string) =
  ## Copies what OniSplit -create wrote for an ONLV into dst, replacing files
  ## (hardlinks to the project's copies). Not only the ONLV: -extract:xml turns
  ## the M3GMs embedded in a built ONLV (door panels) into .dae files, and
  ## -create imports those as separate named M3GMs the ONLV links to. Leaving
  ## them out left the OBOA's geometry link empty: the game crashed at 0x439b06
  ## (FUN_00439910, reading the geometry) when the door started to open.
  for f in walkFiles(src / "*.oni"):
    let d = dst / f.extractFilename
    if fileExists(d): removeFile(d)
    copyFile(f, d)

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
                source: "level" & $levelNumber & "_Final", ambient: DefaultAmbient)
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
                scratch: true, ambient: DefaultAmbient)
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

# --- doors -------------------------------------------------------------------
# Oni never draws a DOOR object (its draw method, 0x4ca680, is empty): the door
# you see is a physics object in the ONLV's OBOA, plus quads, both made by
# OniSplit only for doors in the level XML it builds from (ImportDoor). So a
# level's doors go to -create:level too, besides into BINACJBODoor.

proc instanceKey*(file: string): string =
  ## An exported instance's name in lower case, from its file name (OniSplit
  ## URL-encodes characters a file name can't hold).
  decodeUrl(file.splitFile.name).toLowerAscii

proc oniLinks*(file, tag: string): seq[string] =
  ## Names of the <tag> instances an exported .oni file links to: each
  ## "<tag><name>" string in it, without the tag.
  if not fileExists(file): return
  let data = readFile(file)
  var i = data.find(tag)
  while i >= 0:
    var name = ""
    var j = i + tag.len
    while j < data.len and data[j] in {' ' .. '~'}:
      name.add data[j]
      inc j
    if name.len > 0 and name notin result: result.add name
    i = data.find(tag, j)

proc findTxmp(dirs: openArray[string], name: string): string =
  ## The exported file of TXMP instance `name` (case ignored); "" if none.
  let k = name.toLowerAscii
  for d in dirs:
    for f in walkFiles(d / "TXMP*.oni"):
      if instanceKey(f) == k: return f

proc copyInstanceUpper(src, dir: string) =
  ## Copies an exported instance into dir, its name in upper case: OniSplit
  ## looks door textures up in upper case and matches names exactly (the game
  ## ignores case). The name is stored once, NUL-terminated, in the header.
  var data = readFile(src)
  let own = decodeUrl(src.splitFile.name)
  let at = data.find(own & "\0")
  if at >= 0:
    for i, ch in own: data[at + i] = ch.toUpperAscii
  writeFile(dir / src.splitFile.name.toUpperAscii & ".oni", data)

type DoorBuild = ref object
  ids: Table[int32, int32]   ## OniSplit's door ObjectId -> Catwalk's.
  wanted: seq[string]        ## Door textures neither the project nor the library has.

proc doorSource(p: Project, dir: string, d: DoorBuild): string =
  ## Writes the project's doors as an object XML for -create:level, and puts
  ## what OniSplit makes them from in dir/shared (its search folder). Returns
  ## the XML's path; "" when the level has no doors.
  if not dirExists(p.objectsDir): return
  let (_, objs) = loadObjects(p.objectsDir)
  var doors: seq[LevelObject]
  for o in objs:
    if o.tag == "DOOR": doors.add o
  if doors.len == 0: return
  let lib = libraryDoorsDir()
  if not dirExists(lib):
    raise newException(IOError, "doors need the entity library's door files: rebuild the entity library (Entity tab)")
  let shared = dir / "shared"
  createDir(shared)
  createSymlink(lib, shared / "library")
  var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Oni>\n<Objects>\n"
  var textures: seq[string]
  for o in doors:
    let cls = o.node.xpath("OSD/Class").str.strip
    if not fileExists(lib / "DOOR" & cls & ".oni"):
      raise newException(ValueError, &"door {o.id}: no door class \"{cls}\" in level 0")
    # OniSplit numbers the objects it reads from 1; their quads link to type << 24 | number.
    let t = GunkTypes["DOOR"] shl 24
    d.ids[int32(t or (d.ids.len + 1))] = int32(t or (o.id and 0xffffff))
    # OniSplit throws on a side without a texture (ImportGunk finds no texture
    # options for the class's own), so its copy names one for every side: an
    # empty Texture1 is the class's (first) texture, as in the previews, and a
    # double door's empty Texture2 is Texture1, as the game's levels set them.
    let n = parseXml($o.node)
    let t1 = n.xpath("OSD/Texture1")
    let t2 = n.xpath("OSD/Texture2")
    if t1 == nil or t2 == nil:
      raise newException(ValueError, &"door {o.id}: no Texture1/Texture2 fields")
    if t1.str.strip.len == 0:
      let links = oniLinks(lib / "DOOR" & cls & ".oni", "TXMP")
      if links.len == 0: raise newException(ValueError, &"door {o.id}: class \"{cls}\" has no texture")
      t1.setText(links[0])
    var sides = @[t1.str.strip]
    if "DoubleDoor" in n.xpath("OSD/Flags").str.splitWhitespace:
      if t2.str.strip.len == 0: t2.setText(t1.str.strip)
      sides.add t2.str.strip
    for s in sides:
      let tex = ("TXMP" & s).toUpperAscii
      if tex notin textures: textures.add tex
    x.add $n & "\n"
  x.add "</Objects>\n</Oni>\n"
  for tex in textures:
    let src = findTxmp([p.oniDir, lib], tex)
    if src.len > 0: copyInstanceUpper(src, shared) else: d.wanted.add tex
  result = dir / "doors.xml"
  writeFile(result, x)

proc logFaceProblems(p: Project, model: Geometry) =
  ## One "warning: face N, corner K: ..." line per problem face; the console
  ## turns them into links that put the corner under the vertex tool.
  let probs = model.faceProblems
  if probs.len == 0: return
  let f = open(p.logPath, fmAppend)
  for fp in probs: f.writeLine &"warning: {fp.faceRef}: {fp.text}"
  f.close()

proc vertexLightPath(p: Project): string = p.buildDir / "vertexlight.bin"

proc writeAnims(p: Project, model, built: Geometry) =
  let n = writeVertexAnims(model, built, p.vertexLightPath)
  let f = open(p.logPath, fmAppend)
  f.writeLine $n & " animated light corners (vertexlight.bin, played by Arklite)"
  f.close()

proc scratchSteps(c: Config, p: Project, work, geo: string): seq[Step] =
  ## The whole level from geometry.json: OniSplit -create:level writes the
  ## environment, the ONLV and (empty) object lists, and the textures used.
  let
    akevName = "AKEV" & p.envName & ".oni"
    onlvName = "ONLV" & p.envName & ".oni"
    level0 = geo / "level0"
  var levelXml = ""
  var model: Geometry
  var linkedObjects = false
  let doors = DoorBuild()
  result = @[
    action("Writing geometry", proc() =
      if dirExists(geo): removeDir(geo)
      model = if p.hasGeometry: loadGeometry(p.geometryPath) else: Geometry()
      logFaceProblems(p, model)
      for f in model.faces:
        if f.objectId != -1: linkedObjects = true
      let rooms = geo / "src" / "rooms.dae"
      let n = writeRoomsDae(model, rooms)
      let f = open(p.logPath, fmAppend)
      f.writeLine $n & " AI rooms from the floors"
      f.close()
      doors.ids.clear()
      doors.wanted.setLen 0
      let doorXml = doorSource(p, geo / "src", doors)
      if doorXml.len > 0: linkedObjects = true
      levelXml = writeLevelSource(model, geo / "src", p.envName, p.sky, p.imagesDir,
                                  p.markersDir, @[rooms],
                                  if doorXml.len > 0: @[doorXml] else: @[])),
    # Door textures the library lacks: level 0's (any texture can be picked).
    command("Reading level 0", proc(): seq[string] =
      if doors.wanted.len == 0: return @["true"]
      c.splitArgs("-export", level0, c.gameData / "level0_Final.dat")),
    action("Collecting door textures", proc() =
      if doors.wanted.len == 0: return
      var missing: seq[string]
      for tex in doors.wanted:
        let src = findTxmp([level0], tex)
        if src.len > 0: copyInstanceUpper(src, geo / "src" / "shared") else: missing.add tex[4 .. ^1]
      removeDir(level0)
      if missing.len > 0:
        raise newException(ValueError, "door textures not in the game data: " & missing.join(", "))),
    command("Building level", proc(): seq[string] =
      c.splitArgs("-create:level", geo / "out", levelXml)),
    # Geometry owned by objects (furniture, consoles, triggers): OniSplit doesn't
    # link it, so the quads' ObjectId and the ONLV's object quad lists are put
    # in afterwards, as for rebuilt game levels.
    command("Reading level back", proc(): seq[string] =
      if not linkedObjects and not model.hasAnims: return @["true"]
      c.splitArgs("-extract:xml", geo / "xml", geo / "out" / akevName, geo / "out" / onlvName)),
    action("Linking object geometry", proc() =
      if not linkedObjects:
        if model.hasAnims:
          writeAnims(p, model, importAkevXml(geo / "xml" / "AKEV" & p.envName & ".xml"))
        return
      let onlvXml = geo / "xml" / "ONLV" & p.envName & ".xml"
      let r = restoreObjectIds(model, geo / "xml" / "AKEV" & p.envName & ".xml", geo / "out" / akevName,
                               doors.ids)
      if model.hasAnims: writeAnims(p, model, r.built)
      if doors.ids.len > 0:
        # OniSplit's quad lists for its door numbers become Catwalk's door ids.
        var s = readFile(onlvXml)
        for a, b in doors.ids: s = s.replace(&"<ObjectId>{a}</ObjectId>", &"<ObjectId>#{b}</ObjectId>")
        writeFile(onlvXml, s.replace("<ObjectId>#", "<ObjectId>"))
        # A quad whose texture resolves nowhere crashes the game while loading.
        var packed: HashSet[string]
        for t in walkFiles(geo / "out" / "TXMP*.oni"): packed.incl instanceKey(t)
        var missing: seq[string]
        for i, id in r.ids:
          let tex = r.built.faces[i].texture
          if (id shr 24) == GunkTypes["DOOR"] and ("txmp" & tex.toLowerAscii) notin packed and
             tex notin missing: missing.add tex
        if missing.len > 0:
          raise newException(ValueError, "door textures OniSplit didn't find: " & missing.join(", "))
      let links = remapLevelLinks(r.built, r.built, r.ids, onlvXml)
      let f = open(p.logPath, fmAppend)
      f.writeLine $r.linked & " of " & $r.faces & " quads linked to objects, " & $links.added &
                  " object quad lists, " & $doors.ids.len & " doors"
      f.close()),
    command("Writing level links", proc(): seq[string] =
      if not linkedObjects: return @["true"]
      c.splitArgs("-create", geo / "onlv", geo / "xml" / "ONLV" & p.envName & ".xml")),
    action("Linking level", proc() =
      if not linkedObjects: return
      copyCreated(geo / "onlv", geo / "out")),
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
      action("Linking level", proc() = copyCreated(geo / "onlv", work))]

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

proc explainObjectError(output: string): string =
  ## OniSplit reports a bad object field as a .NET stack trace naming only the
  ## field and the XML line; this names the object, the field and what's wrong.
  var m: array[2, string]
  let at = output.find(re"Cannot read field '([^']+)' \(line (\d+)\)", m)
  if at < 0: return
  let field = m[0]
  var line = parseInt(m[1])
  var file = ""
  for l in output[0 ..< at].splitLines:
    if l.startsWith("Importing "): file = l["Importing ".len .. ^1].strip
  if not fileExists(file): return
  let lines = readFile(file).splitLines
  if line < 1 or line > lines.len: return
  # OniSplit's line is where its reader stopped, often the one after the field.
  for k in countdown(line, max(1, line - 2)):
    let t = lines[k - 1].strip
    if t.startsWith("<" & field & ">") or t.startsWith("<" & field & " "):
      line = k
      break
  # The object holding the line, and its name if it has one.
  var obj = ""
  for i in countdown(line - 1, 0):
    var o: array[2, string]
    if lines[i].match(re"""\s*<(\w{4}) Id="(\d+)">""", o):
      obj = typeName(o[0]) & " " & o[1]
      for k in i + 1 ..< line:
        var n: array[1, string]
        if lines[k].match(re"\s*<Name>([^<]+)</Name>", n):
          obj.add " \"" & n[0] & "\""
          break
      break
  var v: array[1, string]
  let problem =
    if lines[line - 1].match(re"\s*<[^>]*/>\s*$"): "is empty"
    elif lines[line - 1].match(re"\s*<[^>]*>([^<]*)<", v): "is \"" & v[0] & "\""
    else: "is invalid"
  let want =
    if output.find(re"Visit(U?Int\d+|Byte|SByte)\b") >= 0: "a whole number"
    elif output.find(re"Visit(Float|Double)\b") >= 0: "a number"
    else: "a valid value"
  let where = if obj.len > 0: obj & ": " else: ""
  &"{where}{field} {problem}; it must be {want} ({file.extractFilename}, line {line})"

proc editedClasses*(p: Project): seq[string] =
  ## Classes in the project's classes/ whose values differ from level 0's.
  for f in walkFiles(p.classesDir / "ONCC*.xml"):
    let name = f.splitFile.name["ONCC".len .. ^1]
    let orig = originalClassPath(name)
    try:
      if fileExists(orig) and $readXmlFile(f) == $readXmlFile(orig): continue
    except CatchableError: discard
    result.add name
  result.sort

proc consolePageXml(text: string): string =
  ## A one-page TxtC (what text_console shows) holding a console's message,
  ## styled like the original text-only pages. Each line of the text is a line
  ## on the page (an IGSt each; the game starts every one on a new line), an
  ## empty line a blank one, as the original pages write it (" "). A literal
  ## "\n" (how messages were written before the field took Enter) is a newline too.
  var strings: seq[string]
  for line in text.replace("\r\n", "\n").replace('\r', '\n').replace("\\n", "\n").split('\n'):
    # An IGSt holds 383 bytes of text: a longer line goes on in the next one.
    var rest = line.strip(leading = false)
    while rest.len > 383:
      var cut = rest.rfind(' ', 0, 383)
      if cut <= 0: cut = 383
      strings.add rest[0 ..< cut]
      rest = rest[cut .. ^1].strip(trailing = false)
    strings.add(if rest.len > 0: rest else: " ")
  const
    PageFont = "<Font><Family>TSFFTahoma</Family><Style>Bold</Style><Color>116 208 255</Color>" &
               "<Size>10</Size><Flags>Family Style Color Size</Flags></Font>"
    TextFont = "<Font><Family></Family><Style>Normal</Style><Color>0 0 0 0</Color><Size>0</Size>" &
               "<Flags></Flags></Font>"
  var links, items: string
  for i, s in strings:
    links.add &"<Link>#{i + 4}</Link>"
    items.add &"<IGSt id=\"{i + 4}\">{TextFont}<Text>{xmltree.escape(s)}</Text></IGSt>\n"
  xmlHeader & "<Oni>\n<TxtC id=\"0\"><Pages>#1</Pages></TxtC>\n" &
    "<IGPA id=\"1\"><Pages><Link>#2</Link></Pages></IGPA>\n" &
    &"<IGPG id=\"2\">{PageFont}<Image></Image><Text1>#3</Text1><Text2></Text2></IGPG>\n" &
    &"<IGSA id=\"3\"><Strings>{links}</Strings></IGSA>\n" & items & "</Oni>\n"

proc writeConsoleScripts(p: Project, igmd: string) =
  ## The BSL functions the Script events Build adds to consoles with a message
  ## run: each shows the console's page.
  if not dirExists(p.objectsDir): return
  var s = ""
  for o in loadObjects(p.objectsDir)[1]:
    if o.consoleMessage.len == 0: continue
    let name = o.consoleMessageName
    s.add &"func void {name}(string ai_name)\n{{\n\ttext_console {name}\n}}\n\n"
  if s.len == 0: return
  createDir(igmd)
  writeFile(igmd / "catwalk_consoles.bsl",
            "# Added by Catwalk: the messages of consoles (ActivationMessage).\n\n" & s)

proc classSources(p: Project, dir: string): seq[string] =
  ## What Build compiles as objects: the object lists, plus each edited class
  ## renamed to <name>EditedSuffix (see classCacheDir), with the characters of
  ## that class pointed at the new name in a copy of the character list.
  if dirExists(dir): removeDir(dir)
  let edited = p.editedClasses
  if edited.len > 0: createDir(dir)
  var renamed: seq[string]
  for name in edited:
    # Class names are 63 characters at most with the tag (CHAR Class is 64 bytes).
    if ("ONCC" & name & EditedSuffix).len > 63:
      raise newException(ValueError, "class name too long to pack as edited: " & name)
    let dst = dir / "ONCC" & name & EditedSuffix & ".xml"
    copyFile(p.classPath(name), dst)
    result.add dst
  for f in walkFiles(p.objectsDir / "*.xml"):
    let renameChars = edited.len > 0 and f.extractFilename == "BINACJBOCharacter.xml"
    # Lists with Catwalk's own fields (RespawnTime, ActivationMessage) go through a
    # copy without them.
    if not renameChars and not hasEditorFields(readFile(f)):
      result.add f
      continue
    let (file, objs) = loadObjectFile(f)
    if renameChars:
      for o in objs:
        let cls = o.node.xpath("OSD/Class")
        if cls != nil and cls.str.strip in edited:
          renamed.add o.label
          cls.setText(cls.str.strip & EditedSuffix)
    # A console's message: its page, and a Script event that shows it.
    for o in objs:
      if o.consoleMessage.len == 0: continue
      let name = o.consoleMessageName
      createDir(dir)
      let page = dir / "TxtC" & name & ".xml"
      writeFile(page, consolePageXml(o.consoleMessage))
      result.add page
      var events = o.node.xpath("OSD/Events")
      if events == nil:
        events = newElement("Events")
        o.node.xpath("OSD").add events
      let ev = newElement("Script")
      ev.setAttr("Function", name)
      events.add ev
    discard file.stripEditorFields()
    createDir(dir)
    let dst = dir / f.extractFilename
    file.saveTo(dst)
    result.add dst
  if edited.len > 0:
    let log = open(p.logPath, fmAppend)
    log.writeLine "edited classes: " & edited.join(", ") & "; characters using them: " &
                  (if renamed.len > 0: renamed.join(", ") else: "none")
    log.close()

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
  var sources: seq[string]   # Object lists and edited classes to compile.
  var steps = @[
    action("Preparing", proc() =
      if fileExists(p.vertexLightPath): removeFile(p.vertexLightPath)
      for d in [work, objs]:
        if dirExists(d): removeDir(d)
        createDir(d)
      for f in walkFiles(p.oniDir / "*.oni"):
        try: createHardlink(f, work / f.extractFilename)
        except OSError: copyFile(f, work / f.extractFilename)),
    action("Applying class edits", proc() =
      sources = classSources(p, p.buildDir / "classes")),
    command("Compiling objects", proc(): seq[string] =
      c.splitArgs("-create", objs) & sources, explainObjectError),
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
        logFaceProblems(p, model)
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
        if model.hasAnims: writeAnims(p, model, linked.built)
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
      action("Linking level", proc() = copyCreated(geo / "onlv", work))]

  steps.add @[
    action("Preparing output", proc() =
      if not dirExists(c.customLevels):
        raise newException(IOError, "CustomLevels folder missing (is the Custom Game mod installed?): " & c.customLevels)
      createDir(outDir)
      for f in walkFiles(outDir / "level*_Final.*"): removeFile(f)),
    command("Packing level", proc(): seq[string] =
      c.splitArgs("-import:pc", work, dat)),
    action("Writing level info", proc() =
      var ini = "[level]\nname=" & p.title & "\nsource=" & $p.levelNumber & "\n"
      # Items with their own respawn time, for Arklite (matched by type and position).
      var respawn: seq[string]
      if dirExists(p.objectsDir):
        for o in loadObjects(p.objectsDir)[1]:
          let e = o.respawnEntry
          if e.len > 0: respawn.add e
      if respawn.len > 0:
        ini.add "\n[respawn]\ncount=" & $respawn.len & "\n"
        for i, e in respawn: ini.add "item" & $i & "=" & e & "\n"
      writeFile(outDir / "level.ini", ini)
      # Animated vertex lights, for Arklite (written while building the environment).
      if fileExists(p.vertexLightPath): copyFile(p.vertexLightPath, outDir / "vertexlight.bin")
      elif fileExists(outDir / "vertexlight.bin"): removeFile(outDir / "vertexlight.bin")
      let igmd = p.dir / "IGMD"
      if dirExists(outDir / "IGMD"): removeDir(outDir / "IGMD")
      if dirExists(igmd): copyTree(igmd, outDir / "IGMD")
      startOnLoad(p, outDir / "IGMD" / p.envName)
      writeConsoleScripts(p, outDir / "IGMD" / p.envName))]
  steps.add then
  newJob("Building " & p.folder, p.logPath, steps)

proc launchStep*(c: Config, p: Project): Step =
  ## Starts the game straight into the project's level.
  let savePoint = p.gameSavePoint
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
