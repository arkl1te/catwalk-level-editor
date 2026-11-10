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
##     sky/<name>/         skies imported into the project: top, left, right, front, back (.tga)
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

import std/[os, osproc, json, strutils, strtabs, algorithm, re, sets, times, tables, uri, strformat, xmltree, xmlparser, sequtils]
import vmath
import jobs, geometry, geomops, objtemplates, levelobjects, pictures, skyconvert, skyfit, skygrade, tga
export skygrade
import fieldtypes, ambients
export RecordingPrefix, splitRecording
from mcp import DefaultMcpPort

type
  Config* = object
    aeDir*: string            ## Oni AE install (has Tools/OniSplit.exe and GameDataFolder)
    projectsDir*: string
    game*: string             ## Oni.exe (run with Wine off Windows) or a script that starts it;
                              ## Play runs it with ARKLITE_AUTOSTART set.
    mono*: string
    customLevelsDir*: string  ## Override for where Build writes; empty = AE's CustomLevels.
    recentProjects*: seq[string]  ## Project folders, most recently opened first.
    recentLimit*: int         ## How many of them File > Open Recent lists.
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
    showTriangles*: bool      ## Wireframes show the faces' triangles, else only their outlines.
    gridColor*: array[3, int] ## Grid lines, 0..255 (their opacity is gridOpacity).
    gridColor3D*: bool        ## The 3D face grid uses gridColor (else black or white per texture).
    mcpEnabled*: bool         ## Start the MCP server (mcp.nim) with Catwalk.
    mcpPort*: int

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
    skyGrade*: SkyGrade       ## Brightness, blend mode and tint of the sky.
    ambient*: array[3, int]   ## Baked lighting: color every lit corner gets before the lights' light.
    softShadows*: float       ## Baked lighting: how far around a corner it takes its light from, 0 = hard.
    customTextures*: seq[string]      ## Textures in env/images imported by the user.
    textureCollections*: seq[string]  ## Enabled collections, in the Texture Browser's order.
    preview*: bool            ## A throwaway copy of a game level, opened to look at (not saved
                              ## in project.json): Save asks for a project folder, Build is off.

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
  ## Faces of an ONSK skybox, in its SkyboxTextures order. The engine has no
  ## bottom face (Oni_Sky.c, M3cSkyBack is the last).
  SkyFaces* = ["top", "left", "right", "front", "back"]
  SkyBottom* = "bottom"   ## An optional sixth face: only Arklite draws it.
  ## File number of levels made from scratch. Custom Game mounts a level under
  ## any number; this one is no original level's.
  ScratchLevelNumber* = 50

proc configPath*(): string = getConfigDir() / "catwalk" / "config.json"

const MaxRecentLimit* = 99

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
  c.showTriangles = true
  c.gridColor = [255, 255, 255]
  c.gridColor3D = false

proc defaultConfig*(): Config =
  ## The AE folder and the game stay empty: the Setup window (setupwin.nim)
  ## asks for them on the first run.
  result = Config(projectsDir: getHomeDir() / "Documents/Oni Levels",
    mono: "mono", recentLimit: 12, mcpPort: DefaultMcpPort)
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
      # "launchScript" is the name configs had before the game could be Oni.exe itself.
      result.game = j{"game"}.getStr(j{"launchScript"}.getStr)
      if j.hasKey("mono"): result.mono = j["mono"].getStr
      if j.hasKey("customLevelsDir"): result.customLevelsDir = j["customLevelsDir"].getStr
      for d in j{"recentProjects"}.getElems: result.recentProjects.add d.getStr
      result.recentLimit = clamp(j{"recentLimit"}.getInt(result.recentLimit), 0, MaxRecentLimit)
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
      result.mcpEnabled = j{"mcpEnabled"}.getBool
      result.mcpPort = clamp(j{"mcpPort"}.getInt(result.mcpPort), 1024, 65535)
      break
    except CatchableError: discard
  if getEnv("ONI_AE_DIR").len > 0: result.aeDir = getEnv("ONI_AE_DIR")

proc save*(c: Config) =
  createDir(configPath().parentDir)
  writeFile(configPath(), pretty(%*{"aeDir": c.aeDir, "projectsDir": c.projectsDir,
    "game": c.game, "mono": c.mono, "customLevelsDir": c.customLevelsDir,
    "recentProjects": c.recentProjects, "recentLimit": c.recentLimit,
    "brightness": c.brightness, "gridOpacity": c.gridOpacity, "fov": c.fov,
    "linearFilter": c.linearFilter, "lookSpeed": c.lookSpeed, "lookInvertX": c.lookInvertX,
    "lookInvertY": c.lookInvertY, "panSpeed": c.panSpeed, "panInvertX": c.panInvertX,
    "panInvertY": c.panInvertY, "moveSpeed": c.moveSpeed, "invertWheel": c.invertWheel,
    "moveTowardCursor": c.moveTowardCursor, "showTriangles": c.showTriangles,
    "gridColor": c.gridColor, "gridColor3D": c.gridColor3D,
    "mcpEnabled": c.mcpEnabled, "mcpPort": c.mcpPort}))

proc noteOpened*(c: var Config, dir: string) =
  ## Moves dir to the front of the recent projects and saves the config.
  let d = dir.normalizedPath
  var keep = @[d]
  for r in c.recentProjects:
    if r != d and keep.len < max(50, c.recentLimit): keep.add r
  c.recentProjects = keep
  try: c.save()
  except CatchableError: discard

proc gameData*(c: Config): string = c.aeDir / "GameDataFolder"
proc oniSplit*(c: Config): string = c.aeDir / "Tools/OniSplit.exe"
proc customLevels*(c: Config): string =
  if c.customLevelsDir.len > 0: c.customLevelsDir else: c.gameData / "CustomLevels"

# --- Finding Oni ------------------------------------------------------------------------------

proc isAeDir*(dir: string): bool =
  ## An Oni AE install: OniSplit and the game data that Build works with.
  dir.len > 0 and fileExists(dir / "Tools/OniSplit.exe") and dirExists(dir / "GameDataFolder")

proc hasArklite*(aeDir: string): bool = fileExists(aeDir / "Arklite.dll")

proc gameExe*(aeDir: string): string =
  ## The Oni.exe that runs aeDir's game: AE's own, else the one in the Oni folder.
  for d in [aeDir, aeDir.parentDir]:
    if d.len > 0 and fileExists(d / "Oni.exe"): return d / "Oni.exe"

proc isExe*(path: string): bool = path.toLowerAscii.endsWith(".exe")

proc aeCandidates(): seq[string] =
  ## Where Oni's AE folder usually is: under the Program Files of a Wine prefix
  ## (plain Wine, Lutris and Heroic's ~/Games, Bottles, PlayOnLinux, Steam's
  ## Proton prefixes) or a copied folder; on Windows, in Program Files.
  const OniDirs = ["Program Files (x86)/Oni", "Program Files/Oni", "Games/Oni", "GOG Games/Oni", "Oni"]
  when defined(windows):
    for drive in 'C' .. 'Z':
      let root = $drive & ":\\"
      if not dirExists(root): continue
      for d in OniDirs: result.add root / d / "AE"
  else:
    let home = getHomeDir()
    var prefixes = @[home / ".wine"]
    for parent in [home / "Games", home / "Games/Heroic/Prefixes", home / "Games/Heroic/Prefixes/default",
                   home / ".local/share/wineprefixes", home / ".local/share/lutris/prefixes",
                   home / ".local/share/bottles/bottles",
                   home / ".var/app/com.usebottles.bottles/data/bottles/bottles",
                   home / ".PlayOnLinux/wineprefix"]:
      for kind, d in walkDir(parent):
        if kind in {pcDir, pcLinkToDir}: prefixes.add d
    for steam in [home / ".steam/steam/steamapps/compatdata", home / ".local/share/Steam/steamapps/compatdata"]:
      for kind, d in walkDir(steam):
        if kind in {pcDir, pcLinkToDir}: prefixes.add d / "pfx"
    for p in prefixes:
      if dirExists(p / "drive_c"):
        for d in OniDirs: result.add p / "drive_c" / d / "AE"
    for d in [home / "Games/Oni", home / "Oni", home / ".local/share/Oni", "/opt/Oni"]:
      result.add d / "AE"

proc detectOni*(): tuple[aeDir, game: string, found: seq[string]] =
  ## The AE install to use, the first with Arklite on it, else the first found;
  ## its Oni.exe (rather than any launch script) as the game; and every AE
  ## install seen.
  for d in aeCandidates():
    if d.isAeDir and d.normalizedPath notin result.found: result.found.add d.normalizedPath
  for d in result.found:
    if d.hasArklite:
      result.aeDir = d
      break
  if result.aeDir.len == 0 and result.found.len > 0: result.aeDir = result.found[0]
  if result.aeDir.len > 0: result.game = gameExe(result.aeDir)

proc winePrefixOf*(path: string): string =
  ## The Wine prefix path lies in (the folder holding its drive_c), else "".
  var d = path.parentDir
  while d.len > 1:
    if d.lastPathPart == "drive_c": return d.parentDir
    let up = d.parentDir
    if up == d: break
    d = up

proc gameLevels*(c: Config): seq[int] =
  ## Original game levels present in the game folder.
  for n in OriginalLevels:
    if fileExists(c.gameData / "level" & $n & "_Final.dat"): result.add n

proc catwalkCache*(): string =
  ## Where extracted game data is cached: ~/.cache/catwalk, on Windows
  ## %LOCALAPPDATA%\catwalk\cache (next to the logs).
  when defined(windows): getCacheDir("catwalk") / "cache"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk"

proc libraryDir*(): string =
  ## The entity library (library.nim builds it).
  when defined(windows): getCacheDir("catwalk") / "library"  # %LOCALAPPDATA%
  else:
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
  catwalkCache() / "classes"

proc originalClassPath*(name: string): string = classCacheDir() / "ONCC" & name & ".xml"

# Particle classes work the same way (P3rGetParticleClass finds the first of a
# name too). The cache keeps level 0's under their lowercase names; so does a
# project's classes/, as BINA3RAP<name>.xml.
const ParticleFilePrefix = "BINA3RAP"

proc particleCacheDir*(): string =
  catwalkCache() / "particles"

# Previews: each game level is extracted once into the cache (level<n>/, kept
# while its .dat stays the same) and opened as a fresh copy (open-<pid>/), so
# nothing done during a preview reaches the cached level or the projects folder.
proc previewCacheDir*(): string =
  catwalkCache() / "preview"

when defined(windows):
  import std/winlean
  proc processAlive(pid: int): bool =
    ## Whether a process pid runs (Windows has no /proc to look in).
    const QueryLimitedInformation = 0x1000'i32
    const StillActive = 259'i32
    let h = openProcess(QueryLimitedInformation, 0, pid.DWORD)
    if h == 0: return false
    var code: int32
    result = getExitCodeProcess(h, code) != 0 and code == StillActive
    discard closeHandle(h)

proc previewWorkDir*(): string = previewCacheDir() / "open-" & $getCurrentProcessId()

proc originalParticlePath*(name: string): string = particleCacheDir() / "classes" / name.toLowerAscii & ".xml"

# --- project files -----------------------------------------------------------

proc oniDir*(p: Project): string = p.dir / "oni"
proc objectsDir*(p: Project): string = p.dir / "objects"
proc envDir*(p: Project): string = p.dir / "env"
proc imagesDir*(p: Project): string = p.envDir / "images"

# --- the game's textures ------------------------------------------------------
# env/images holds them only so the editor can show them: a built level never
# contains one. Build leaves them out, so the level names them (a placeholder
# the engine resolves by name), and level.ini's [textures] lists the game levels
# Arklite then lends them from, from the player's own game.

type
  DatInstance = object
    tag, name: string
    desc, nameAt: int      ## Descriptor number; where the name is in the file.
    flags: uint32

const
  DatUnique = 1'u32        ## No name.
  DatPlaceholder = 2'u32   ## A name and no data.

proc le32(d: string, at: int): uint32 =
  uint32(d[at].byte) or uint32(d[at + 1].byte) shl 8 or uint32(d[at + 2].byte) shl 16 or
    uint32(d[at + 3].byte) shl 24

proc datInstances(d: string): seq[DatInstance] =
  let count = d.le32(0x14).int
  let names = d.le32(0x28).int
  for i in 0 ..< count:
    let at = 0x40 + i * 20
    var x = DatInstance(desc: i, flags: d.le32(at + 16))
    if (x.flags and DatUnique) == 0:
      x.nameAt = names + d.le32(at + 8).int
      let stop = d.find('\0', x.nameAt)
      x.tag = d[x.nameAt .. x.nameAt + 3]
      x.name = d[x.nameAt + 4 .. stop - 1]
      result.add x

var levelTitleCache: tuple[stamp: string, titles: Table[int, string]]

proc levelTitles*(c: Config): Table[int, string] =
  ## The game levels' names (level number -> name), from level 0's ONLD
  ## instances: what Oni's Load Game list shows (u16 level at +0, name at +4).
  ## Reads only the instance table and those entries; cached while level 0 stays the same.
  let path = c.gameData / "level0_Final.dat"
  if not fileExists(path): return
  let stamp = $getFileSize(path) & " " & $getLastModificationTime(path).toUnix
  if levelTitleCache.stamp == stamp: return levelTitleCache.titles
  try:
    var f = open(path)
    defer: f.close()
    var head = newString(0x40)
    if f.readBuffer(head[0].addr, head.len) != head.len: return
    let count = head.le32(0x14).int
    let dataTable = head.le32(0x20).int
    var desc = newString(count * 20)
    if count == 0 or f.readBuffer(desc[0].addr, desc.len) != desc.len: return
    var entry = newString(96)
    for i in 0 ..< count:
      let at = i * 20
      # Tags are stored backwards in the descriptors.
      if desc[at .. at + 3] != "DLNO" or (desc.le32(at + 16) and DatPlaceholder) != 0: continue
      f.setFilePos(dataTable + desc.le32(at + 4).int)
      if f.readBuffer(entry[0].addr, entry.len) != entry.len: continue
      let level = entry[0].byte.int or entry[1].byte.int shl 8
      var stop = entry.find('\0', 4)
      if stop < 0: stop = entry.len
      let name = entry[4 ..< stop].strip
      if level > 0 and name.len > 0: result[level] = name
  except CatchableError:
    return
  levelTitleCache = (stamp, result)

var projectInfoCache: Table[string, tuple[stamp: string, title: string, level: int, scratch: bool]]

proc projectInfo*(dir: string): tuple[title: string, level: int, scratch: bool] =
  ## A project's title, game level and whether it was made from scratch, read
  ## from its project.json (cached until that changes).
  let path = dir / "project.json"
  try:
    let stamp = $getLastModificationTime(path).toUnix & " " & $getFileSize(path)
    if dir in projectInfoCache and projectInfoCache[dir].stamp == stamp:
      let c = projectInfoCache[dir]
      return (c.title, c.level, c.scratch)
    let j = parseFile(path)
    result = (j{"title"}.getStr(dir.lastPathPart), j{"levelNumber"}.getInt, j{"scratch"}.getBool)
    if result.title.len == 0: result.title = dir.lastPathPart
    projectInfoCache[dir] = (stamp, result.title, result.level, result.scratch)
  except CatchableError:
    result = (dir.lastPathPart, 0, false)

proc gameTextures(gameData: string, first: int): Table[string, (string, int)] =
  ## Every texture the game has, by upper-case name: (its name, its level).
  ## Level 0 and then the project's own level win, as in the game.
  var levels = @[0, first]
  for f in walkFiles(gameData / "level*_Final.dat"):
    let n = f.extractFilename[5 .. ^1].split('_')[0]
    if n.allCharsInSet(Digits) and n.parseInt notin levels: levels.add n.parseInt
  for level in levels:
    let path = gameData / &"level{level}_Final.dat"
    if not fileExists(path): continue
    for x in datInstances(readFile(path)):
      if x.tag in ["TXMP", "TXAN"] and (x.flags and DatPlaceholder) == 0 and
         x.name.toUpperAscii notin result:
        result[x.name.toUpperAscii] = (x.name, level)

proc dropGameTextures(work: string, game: Table[string, (string, int)]) =
  for pattern in ["TXMP*.oni", "TXAN*.oni"]:
    for f in walkFiles(work / pattern):
      if f.splitFile.name[4 .. ^1].decodeUrl(false).toUpperAscii in game: removeFile(f)

proc textureLevels(dat: string, game: Table[string, (string, int)]): seq[int] =
  ## The game levels the built level's placeholders need. Names are found with
  ## strcmp in the game, so one packed in another case (doors') gets the game's,
  ## and the name table, which the game searches, is sorted again.
  var d = readFile(dat)
  var fixed = false
  var missing: seq[string]
  for x in datInstances(d):
    if x.tag != "TXMP" or (x.flags and DatPlaceholder) == 0: continue
    let key = x.name.toUpperAscii
    if key notin game:
      missing.add x.name
      continue
    let (name, level) = game[key]
    if name != x.name:
      for i, ch in name: d[x.nameAt + 4 + i] = ch
      fixed = true
    if level != 0 and level notin result: result.add level
  if missing.len > 0:
    raise newException(ValueError, "textures the game doesn't have: " & missing.join(", "))
  if fixed:
    let all = datInstances(d)
    let table = 0x40 + d.le32(0x14).int * 20
    var order = all
    order.sort(proc(a, b: DatInstance): int =
      cmp(a.tag & a.name, b.tag & b.name))
    if order.len != d.le32(0x18).int:
      raise newException(ValueError, "unexpected name table in " & dat)
    for i, x in order:
      for b in 0 .. 3: d[table + i * 8 + b] = char((x.desc shr (b * 8)) and 0xff)
    writeFile(dat, d)
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
proc particlePath*(p: Project, name: string): string =
  p.classesDir / ParticleFilePrefix & name.toLowerAscii & ".xml"
proc skyDir*(): string =
  catwalkCache() / "sky"

proc skyFace*(sky, face: string): string = skyDir() / sky / face & ".tga"

proc customSkyDir*(p: Project, sky: string): string = p.dir / "sky" / sky
proc isCustomSky*(p: Project, sky: string): bool =
  sky.len > 0 and fileExists(p.customSkyDir(sky) / SkyFaces[0] & ".tga")

proc builtSky*(p: Project): string =
  ## The sky the built level links. A sky of level 0 with its own brightness
  ## or tint gets a copy of its own, or it would change for every level.
  if p.sky.len > 0 and not p.isCustomSky(p.sky) and not p.skyGrade.isPlain: "cw_" & p.sky & "_graded"
  else: p.sky

proc customSkies*(p: Project): seq[string] =
  ## Skies imported into this project.
  for d in walkDirs(p.dir / "sky" / "*"):
    if p.isCustomSky(d.lastPathPart): result.add d.lastPathPart
  result.sort

proc save*(p: Project) =
  writeFile(p.dir / "project.json", pretty(%*{"title": p.title, "envName": p.envName,
    "sky": p.sky, "levelNumber": p.levelNumber, "source": p.source,
    "geometryEdited": p.geometryEdited, "startSavePoint": p.startSavePoint,
    "scratch": p.scratch, "music": p.music, "musicVolume": p.musicVolume,
    "skyBrightness": p.skyGrade.brightness, "skyBlend": $p.skyGrade.blend, "skyTint": p.skyGrade.tint,
    "autoBake": p.autoBake, "ambient": p.ambient, "softShadows": p.softShadows, "customTextures": p.customTextures,
    "textureCollections": p.textureCollections}))

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
    autoBake: j{"autoBake"}.getBool, ambient: DefaultAmbient, skyGrade: PlainSky,
    softShadows: j{"softShadows"}.getFloat)
  let amb = j{"ambient"}.getElems
  if amb.len == 3:
    for i in 0 .. 2: result.ambient[i] = clamp(amb[i].getInt, 0, 255)
  # No sky in a project saved before levels could choose None: it wasn't read yet.
  if j.hasKey("skyBrightness"): result.skyGrade.brightness = j["skyBrightness"].getFloat.float32
  if j.hasKey("skyTint") and j["skyTint"].len == 3:
    for k in 0 .. 2: result.skyGrade.tint[k] = j["skyTint"][k].getInt
  for b in SkyBlend:
    if $b == j{"skyBlend"}.getStr: result.skyGrade.blend = b
  if result.sky.len == 0 and not result.scratch and not j.hasKey("textureCollections"):
    result.sky = result.findSky
  for t in j{"customTextures"}.getElems: result.customTextures.add t.getStr
  for t in j{"textureCollections"}.getElems: result.textureCollections.add t.getStr
  if not j.hasKey("textureCollections"): result.textureCollections = @["level", "custom"]

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

proc oniSplitCmd*(c: Config): seq[string] =
  ## How OniSplit.exe is started: with Mono on Linux; on Windows it is a .NET
  ## program of its own.
  when defined(windows): @[c.oniSplit]
  else: @[c.mono, c.oniSplit]

proc splitArgs(c: Config, args: varargs[string]): seq[string] =
  result = c.oniSplitCmd
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

proc importSteps(c: Config, levelNumber: int, dir, folder, title: string,
                 onDone: proc(p: Project)): seq[Step] =
  ## Copies game level <levelNumber> into the new project folder dir.
  let
    dat = c.gameData / "level" & $levelNumber & "_Final.dat"
    p = Project(dir: dir, folder: folder, title: title, levelNumber: levelNumber,
                source: "level" & $levelNumber & "_Final", ambient: DefaultAmbient, skyGrade: PlainSky,
                textureCollections: @["level", "custom"])
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
  steps

proc importJob*(c: Config, levelNumber: int, folder, title: string,
                onDone: proc(p: Project)): Job =
  ## Copies game level <levelNumber> into <projects>/<folder>.
  let dir = c.projectsDir / folder
  let steps = importSteps(c, levelNumber, dir, folder, title, onDone)
  newJob("Importing level" & $levelNumber & "_Final", dir / "build" / "last-job.log", steps)

proc datStamp(dat: string): string =
  $getFileSize(dat) & " " & $getLastModificationTime(dat).toUnix

proc previewJob*(c: Config, levelNumber: int, onDone: proc(p: Project)): Job =
  ## Opens game level <levelNumber> to look at, without a project: extracts it
  ## into the cache the first time (or after the .dat changed), then opens a
  ## fresh copy of that.
  let
    cache = previewCacheDir()
    pristine = cache / "level" & $levelNumber
    dat = c.gameData / "level" & $levelNumber & "_Final.dat"
    work = previewWorkDir()
  if not fileExists(dat): raise newException(IOError, "Not found: " & dat)
  # Copies left by Catwalks that have quit.
  if dirExists(cache):
    for kind, d in walkDir(cache):
      let name = d.lastPathPart
      if kind == pcDir and name.startsWith("open-") and d != work:
        when defined(linux):
          if not dirExists("/proc" / name["open-".len .. ^1]): removeDir(d)
        elif defined(windows):
          try:
            if not processAlive(parseInt(name["open-".len .. ^1])): removeDir(d)
          except ValueError, OSError: discard
  let open = action("Opening a copy", proc() =
    if dirExists(work): removeDir(work)
    copyDir(pristine, work)
    removeFile(work / ".stamp")
    let p = openProject(work)
    p.preview = true
    p.title = "Level " & $levelNumber
    onDone(p))
  let stamp = datStamp(dat)
  var steps: seq[Step]
  if not (isProject(pristine) and fileExists(pristine / ".stamp") and
          readFile(pristine / ".stamp") == stamp):
    if dirExists(pristine): removeDir(pristine)
    steps = importSteps(c, levelNumber, pristine, "level" & $levelNumber, "Level " & $levelNumber,
                        proc(p: Project) = writeFile(pristine / ".stamp", stamp))
  steps.add open
  newJob("Previewing level " & $levelNumber, cache / "level" & $levelNumber & ".log", steps)

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
                scratch: true, ambient: DefaultAmbient, skyGrade: PlainSky, textureCollections: @["level", "custom"])
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

# --- textures from outside -----------------------------------------------------

proc levelTexturesDir*(n: int): string =
  ## Game level n's environment textures, extracted for the Texture Browser.
  catwalkCache() / "textures" / "level" & $n

proc levelTexturesReady*(n: int): bool = fileExists(levelTexturesDir(n) / ".done")

proc levelTextureSteps(c: Config, n: int): seq[Step] =
  # A proc per level: closures made in a loop would share its variable.
  let dat = c.gameData / "level" & $n & "_Final.dat"
  let dir = levelTexturesDir(n)
  let src = dir / "work"
  @[action("Preparing level " & $n, proc() =
      if dirExists(dir): removeDir(dir)
      createDir(src)),
    command("Reading level " & $n, proc(): seq[string] = c.splitArgs("-export", src / "oni", dat)),
    command("Extracting textures of level " & $n, proc(): seq[string] =
      c.splitArgs("-extract:dae", src / "env") & globOni(src / "oni", "AKEV")),
    action("Collecting textures of level " & $n, proc() =
      for f in walkFiles(src / "env" / "images" / "*.tga"):
        if not f.extractFilename.startsWith("bnv_grid"): moveFile(f, dir / f.extractFilename)
      removeDir(src)
      writeFile(dir / ".done", ""))]

proc levelTexturesJob*(c: Config, levels: seq[int], logPath: string): Job =
  ## Extracts the environment textures of the given game levels into the cache.
  var steps: seq[Step]
  for n in levels: steps.add levelTextureSteps(c, n)
  newJob("Extracting level textures", logPath, steps)

proc fitPicture(src, dst: string, square = false) =
  ## src as a picture Oni can show, at dst (see pictures.nim).
  let img = readPicture(src)
  var (w, h) = fittedSize(img.width, img.height)
  if square: (w, h) = (max(w, h), max(w, h))
  writeTga(dst, img.resized(w, h))

proc pictureSteps(c: Config, label, src, work: string, use: proc(file: string)): seq[Step] =
  ## Reads a picture and calls use with a file readPicture takes: OniSplit
  ## turns the formats Catwalk doesn't read into a TGA first.
  if src.splitFile.ext.toLowerAscii[1 .. ^1] notin OniSplitFormats:
    return @[action(label, proc() = use(src))]
  let (txmp, tga) = (work / "txmp", work / "tga")
  @[action("Preparing " & label, proc() =
      if dirExists(work): removeDir(work)
      createDir(txmp)),
    command("Reading " & label, proc(): seq[string] =
      c.splitArgs("-create:txmp", txmp, "-large", src)),
    command("Converting " & label, proc(): seq[string] =
      c.oniSplitCmd & @["-extract:tga", tga] & globOni(txmp, "TXMP")),
    action(label, proc() =
      for f in walkFiles(tga / "*.tga"):
        use(f)
        break
      removeDir(work))]

proc importTexturesJob*(c: Config, p: Project, files: seq[string],
                        onDone: proc(names: seq[string])): Job =
  ## Copies pictures into env/images as textures, named CW_<NAME> so that no
  ## game texture takes their place: the game finds instances by name and
  ## level 0 is searched first. An existing texture is never overwritten.
  var names = new seq[string]
  proc steps(i: int, file: string): seq[Step] =
    pictureSteps(c, file.extractFilename, file, p.buildDir / "import" / $i, proc(f: string) =
      let base = "CW_" & safeName(file)
      var name = base
      var n = 2
      while fileExists(p.imagesDir / name & ".tga"):
        name = base & "_" & $n
        inc n
      fitPicture(f, p.imagesDir / name & ".tga")
      names[].add name)
  var all: seq[Step]
  for i, file in files: all.add steps(i, file)
  all.add action("Done", proc() =
    p.customTextures.add names[]
    p.save()
    onDone(names[]))
  newJob("Importing textures", p.logPath, all)

proc skyFolderPictures*(dir: string): seq[string] =
  ## A folder's pictures, by name.
  for k, f in walkDir(dir):
    if k in {pcFile, pcLinkToFile} and
       f.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in @DirectFormats & @OniSplitFormats: result.add f
  result.sort

proc importSkyJob*(c: Config, p: Project, dir: string, faces: seq[tuple[file: string, side, turns: int]],
                   onDone: proc(sky: string)): Job =
  ## Pictures with their sides become a sky of this project (sky/<name>/): square,
  ## each at most MaxTextureSide. Its name also names the ONSK and its textures.
  var name = "cw_" & safeName(dir.lastPathPart).toLowerAscii
  let base = name
  var n = 2
  while dirExists(p.customSkyDir(name)):
    name = base & "_" & $n
    inc n
  let sky = name
  proc faceSteps(file, face: string, turns, i: int): seq[Step] =
    pictureSteps(c, "sky " & face, file, p.buildDir / "import" / "sky" & $i, proc(f: string) =
      let img = readPicture(f)
      var (w, h) = fittedSize(img.width, img.height)
      w = max(w, h)
      writeTga(p.customSkyDir(sky) / face & ".tga", img.resized(w, w).turned(turns)))
  var steps: seq[Step]
  # Top last: it's the face that makes the folder count as a sky.
  for i in countdown(faces.high, 0):
    let f = faces[i]
    steps.add faceSteps(f.file, SkySides[f.side], f.turns, i)
  steps.add action("Done", proc() = onDone(sky))
  newJob("Importing sky", p.logPath, steps)

proc convertSkyJob*(c: Config, p: Project, file: string, kind: SkySource,
                    onDone: proc(sky: string)): Job =
  ## One picture of the given layout becomes a sky of this project.
  var name = "cw_" & safeName(file).toLowerAscii
  let base = name
  var n = 2
  while dirExists(p.customSkyDir(name)):
    name = base & "_" & $n
    inc n
  let sky = name
  var conv: SkyConverter
  var steps = pictureSteps(c, "sky picture", file, p.buildDir / "import" / "skypicture", proc(f: string) =
    conv = newSkyConverter(readPicture(f), kind))
  proc faceStep(face: string): Step =
    action("Making the " & face & " of the sky", proc() =
      writeTga(p.customSkyDir(sky) / face & ".tga", conv.face(face)))
  # Top last: it's the face that makes the folder count as a sky.
  steps.add faceStep(SkyBottom)
  for i in countdown(SkyFaces.high, 0): steps.add faceStep(SkyFaces[i])
  steps.add action("Done", proc() = onDone(sky))
  newJob("Converting sky", p.logPath, steps)

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
  # A link where it can be had; Windows only allows one in Developer Mode or
  # as administrator, else a copy (about 1.5 MB of door files).
  try: createSymlink(lib, shared / "library")
  except OSError: copyDir(lib, shared / "library")
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
  ## One "<severity>: face N, corner K: ..." line per problem face; the Issues
  ## list turns them into links that put the corner under the vertex tool.
  let probs = model.faceProblems
  if probs.len == 0: return
  let f = open(p.logPath, fmAppend)
  for fp in probs: f.writeLine &"{fp.severity}: {fp.faceRef}: {fp.text}"
  f.close()

proc vertexLightPath(p: Project): string = p.buildDir / "vertexlight.bin"

proc lightSoundFirstId(p: Project): int =
  ## The id of the first Sound object Build adds for a light's ambient: after
  ## every object's.
  if dirExists(p.objectsDir):
    for o in loadObjects(p.objectsDir)[1]: result = max(result, o.id)
  inc result

iterator lightsWithAmbients(p: Project, firstId: int): (XmlNode, XmlNode) =
  ## Every light in lights.xml, with the Sound object (SNDG sphere) that plays
  ## its ambient (nil when it has none), numbered from firstId in this order.
  ## lightAmbients and lightEvents both count through this, so the ids agree.
  if fileExists(p.lightsPath):
    let objs = parseXml(readFile(p.lightsPath)).child("Objects")
    if objs != nil:
      var id = firstId
      for o in objs:
        if o.kind != xnElement or o.tag notin LightTags: continue
        let s = lightAmbientSound(o, id)
        if s != nil: inc id
        yield (o, s)

proc lightEvents(p: Project): seq[LightEvent] =
  ## The animated lights with a sound, from lights.xml. Period, offset and the
  ## rest as appstate.lightAnim reads them, so they match the corners' records.
  ## A point or spot light's ambient (Build's Sound object) comes too, by its id:
  ## Arklite plays it at the light's pitch range, and a flickering light's only
  ## while the flicker fails.
  for (o, amb) in p.lightsWithAmbients(p.lightSoundFirstId):
    if lightSoundAmbient(o.tag, o) and amb == nil: continue   # no sound, or the light is off
    let osd = o.child("OSD")
    let an = if osd != nil: osd.child("Animation") else: nil
    if an == nil: continue
    proc text(n: XmlNode, tag: string): string =
      let e = n.child(tag)
      if e != nil: e.innerText.strip else: ""
    proc num(tag: string, default: float32): float32 =
      try: parseFloat(an.text(tag)).float32 except ValueError: default
    let sound = an.text("Sound")
    let mode = case an.text("Mode").toLowerAscii
               of "pulse": amPulse
               of "flicker": amFlicker
               else: amNone
    # An ambient also comes without an animation: it carries the light's pitch range.
    if sound.len == 0 or (mode == amNone and amb == nil) or
       osd.text("Enabled") in ["0", "false", "no", "off"]: continue
    var e = LightEvent(mode: mode, sound: sound, positional: o.tag != DirLightTag,
                       period: max(0.01'f32, num("Period", 2)), offset: num("Offset", 0),
                       seed: clamp(num("Seed", 0), 0, MaxAnimSeed.float32).uint32,
                       stability: clamp(num("Stability", 0), 0, 1), fault: max(0'f32, num("FaultLength", 1)),
                       pitch: clamp(num("SoundPitch", 1), 0.1, 4), volume: clamp(num("SoundVolume", 1), 0, 1))
    e.pitchMax = clamp(num("SoundPitchMax", e.pitch), e.pitch, 4)
    if amb != nil: e.soundObject = parseInt(amb.attr("Id"))
    try: e.light = parseInt(o.attr("Id")) except ValueError: discard
    let c = strutils.splitWhitespace(o.child("Header").text("Position"))
    if c.len == 3:
      try: e.pos = vec3(parseFloat(c[0]), parseFloat(c[1]), parseFloat(c[2]))
      except ValueError: discard
    result.add e

proc lightAmbients(p: Project): seq[XmlNode] =
  ## Sound objects (SNDG spheres) for the point and spot lights whose sound is an
  ## ambient, from lights.xml, numbered after every object.
  for (_, s) in p.lightsWithAmbients(p.lightSoundFirstId):
    if s != nil: result.add s

proc particlePositions(p: Project): Table[int, Vec3] =
  ## Where each Particle object is.
  if not dirExists(p.objectsDir): return
  for o in loadObjects(p.objectsDir)[1]:
    if o.tag == "PART": result[o.id] = o.pos

proc projectSpins(p: Project, model: Geometry): seq[SpinGroup] =
  spinGroups(model, p.dir / "groups.json", p.particlePositions)

proc writeAnims(p: Project, model, built: Geometry) =
  ## vertexlight.bin, when the level has animated corners or light sounds. built
  ## (the quads as OniSplit made them) only matters with animated corners.
  let events = p.lightEvents
  if not model.hasAnims and events.len == 0: return
  let n = writeVertexAnims(model, built, p.vertexLightPath, events)
  let gated = events.countIt(it.soundObject > 0)
  let f = open(p.logPath, fmAppend)
  f.writeLine $n & " animated light corners, " & $(events.len - gated) & " light sounds, " & $gated &
              " light ambients (vertexlight.bin, played by Arklite)"
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
      let spins = p.projectSpins(model).filterIt(it.faces.len > 0)
      let spinXml = writeSpinSource(model, spins, geo / "src", p.imagesDir, p.markersDir)
      if spins.len > 0:
        model = model.withoutSpinning(spins)
        let f = open(p.logPath, fmAppend)
        f.writeLine $spins.len & " spinning groups"
        f.close()
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
      levelXml = writeLevelSource(model, geo / "src", p.envName, p.builtSky, p.imagesDir,
                                  p.markersDir, @[rooms],
                                  (if doorXml.len > 0: @[doorXml] else: @[]) &
                                  (if spinXml.len > 0: @[spinXml] else: @[]))),
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
        writeAnims(p, model, if model.hasAnims: importAkevXml(geo / "xml" / "AKEV" & p.envName & ".xml")
                             else: Geometry())
        return
      let onlvXml = geo / "xml" / "ONLV" & p.envName & ".xml"
      let r = restoreObjectIds(model, geo / "xml" / "AKEV" & p.envName & ".xml", geo / "out" / akevName,
                               doors.ids)
      writeAnims(p, model, r.built)
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
  # A level's physics objects don't exist until a script creates them.
  if p.hasGeometry:
    let spins = p.projectSpins(loadGeometry(p.geometryPath)).filterIt(it.faces.len > 0)
    if spins.len > 0:
      line.add "\n\t# Added by Catwalk: the spinning groups.\n"
      for s in spins: line.add &"\tobj_create {s.scriptId}\n"
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

proc editedParticles*(p: Project): seq[string] =
  ## Particle classes in the project's classes/ that differ from level 0's, lowercase.
  for f in walkFiles(p.classesDir / ParticleFilePrefix & "*.xml"):
    let name = f.splitFile.name[ParticleFilePrefix.len .. ^1].toLowerAscii
    let orig = originalParticlePath(name)
    try:
      if fileExists(orig) and $readXmlFile(f) == $readXmlFile(orig): continue
    except CatchableError: discard
    result.add name
  result.sort

proc readParticle(p: Project, name: string): XmlNode =
  ## The class file as the project has it (<Oni><Particle>); nil when there's none.
  let own = p.particlePath(name)
  let orig = originalParticlePath(name)
  if fileExists(own): readXmlFile(own)
  elif fileExists(orig): readXmlFile(orig)
  else: nil

proc particleLinks(n: XmlNode, visit: proc(link: XmlNode)) =
  ## The elements of a class naming another class: what an emitter emits, what
  ## a collision effect creates, what an attractor goes for.
  for c in n:
    if c.kind != xnElement: continue
    if (c.tag == "Class" and n.tag in ["Emitter", "Attractor"]) or (c.tag == "Effect" and n.tag == "CollisionEffect"):
      visit(c)
    else:
      particleLinks(c, visit)

proc particleSources(p: Project, dir: string, placed: seq[string]): (seq[string], Table[string, string]) =
  ## Edited particle classes for Build: each packed as <Name>EditedSuffix, and
  ## with them the classes on the way to them. placed (lowercase) is what the
  ## level's Particle objects run. A class only runs an edited one through a
  ## name, so every class that emits an edited class gets a renamed copy as
  ## well, emitting the new name. Returns the files and the new name of each
  ## class (lowercase old name -> new name).
  let edited = p.editedParticles.toHashSet
  if edited.len == 0: return
  # What the level's objects reach, and who emits what.
  var roots: Table[string, XmlNode]
  var emits: Table[string, seq[string]]
  var todo = placed
  while todo.len > 0:
    let name = todo.pop.toLowerAscii
    if name in roots: continue
    let root = p.readParticle(name)
    if root == nil: continue
    roots[name] = root
    var links: seq[string]
    particleLinks(root, proc(link: XmlNode) =
      let to = link.innerText.strip.toLowerAscii
      if to.len > 0:
        links.add to
        todo.add to)
    emits[name] = links
  # An edited class, and whatever emits one.
  var packed: HashSet[string]
  for name in roots.keys:
    if name in edited: packed.incl name
  var grew = packed.len > 0
  while grew:
    grew = false
    for name, tos in emits:
      if name notin packed and tos.anyIt(it in packed):
        packed.incl name
        grew = true
  if packed.len == 0: return
  var names: Table[string, string]
  for name in packed:
    let n = roots[name].child("Particle")
    if n == nil: raise newException(ValueError, "no Particle in the file of class " & name)
    # Class names are 63 characters at most.
    if (n.attr("Name") & EditedSuffix).len > 63:
      raise newException(ValueError, "particle class name too long to pack as edited: " & name)
    names[name] = n.attr("Name") & EditedSuffix
  createDir(dir)
  var files: seq[string]
  for name in packed:
    let root = roots[name]
    root.child("Particle").setAttr("Name", names[name])
    particleLinks(root, proc(link: XmlNode) =
      let to = link.innerText.strip.toLowerAscii
      if to in names: link.setText(names[to]))
    let dst = dir / ParticleFilePrefix & names[name] & ".xml"
    writeFile(dst, xmlHeader & $root & "\n")
    files.add dst
  (files, names)

proc soundDir*(): string =
  ## Sound preview's cache (music.nim): a WAV of every recording.
  catwalkCache() / "sounds"

proc ambientsPath*(p: Project): string =
  ## The project's own ambient sounds (ambients.nim).
  p.dir / "ambients.json"

proc soundsDir*(p: Project): string =
  ## Imported sounds' WAVs (their SNDDs are in oni/): for previews and Build.
  p.dir / "sounds"

var openSoundsDir*: string
  ## The open project's soundsDir: its recordings preview like level 0's.

proc recordingWav*(name: string): string =
  ## The WAV of a recording (zap07 for SNDDzap07.aif): the open project's own,
  ## else level 0's in the cache.
  if openSoundsDir.len > 0:
    let own = openSoundsDir / name.toLowerAscii & ".aif.wav"
    if fileExists(own): return own
  soundDir() / name.toLowerAscii & ".aif.wav"

const
  SoundFormats* = ["wav", "mp3", "ogg", "oga", "opus", "flac", "aif", "aiff", "aifc", "m4a",
                   "aac", "wma", "mka", "webm", "mp4"]
  ImportedSoundPrefix* = "cw_"
  MaxImportedName = 15
    ## Of the file's name in cw_<name>: rec_cw_<name>_<n>__p<percent> fits Oni's 31 characters.

proc fixAdpcmByteRate(wav: string) =
  ## ffmpeg writes MS ADPCM's bytes per second as if each block were full;
  ## level 0's sounds have rate * block / samples per block (11155 mono).
  var w = readFile(wav)
  var i = 12
  while i + 8 <= w.len:
    let n = w[i + 4].ord or (w[i + 5].ord shl 8) or (w[i + 6].ord shl 16) or (w[i + 7].ord shl 24)
    if w[i ..< i + 4] == "fmt " and n >= 22 and i + 8 + 22 <= w.len:
      let f = i + 8
      proc u16(k: int): int = w[k].ord or (w[k + 1].ord shl 8)
      let rate = u16(f + 4) or (u16(f + 6) shl 16)
      let (align, spb) = (u16(f + 12), u16(f + 18))
      if u16(f) != 2 or spb == 0: return
      let bps = rate * align div spb
      for k in 0 .. 3: w[f + 8 + k] = char((bps shr (8 * k)) and 0xff)
      writeFile(wav, w)
      return
    i += 8 + n + (n and 1)
  raise newException(IOError, "ffmpeg wrote no sound: " & wav)

proc importSoundsJob*(c: Config, p: Project, files: seq[string],
                      onDone: proc(names: seq[string])): Job =
  ## Audio files become recordings of this project, cw_<name>.aif: an SNDD in
  ## oni/, packed with the level, and its WAV in sounds/. Sound fields play one
  ## as rec_cw_<name>. Oni runs every sound at 22050 Hz (see music.decodeWav),
  ## so they're resampled to that, as MS ADPCM in level 0's block sizes (512
  ## bytes a channel), mono or stereo. The cw_ prefix keeps level 0's from
  ## taking their place (level 0 wins same-name lookups).
  var names = new seq[string]
  proc steps(i: int, file: string): seq[Step] =
    # A proc per file: closures made in a loop would share its variables.
    let work = p.buildDir / "import" / "sound" & $i
    let label = file.extractFilename
    var name, wav: string
    var channels = 1
    @[action("Reading " & label, proc() =
        if findExe("ffmpeg").len == 0 or findExe("ffprobe").len == 0:
          raise newException(IOError, "importing sounds needs ffmpeg and ffprobe")
        # poDaemon: no console window flashing up on Windows.
        const opts = when defined(windows): {poStdErrToStdOut, poUsePath, poEvalCommand, poDaemon}
                     else: {poStdErrToStdOut, poUsePath, poEvalCommand}
        let (output, code) = execCmdEx(quoteShellCommand(["ffprobe", "-v", "error",
          "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "csv=p=0", file]), opts)
        var n = 0
        try: n = parseInt(output.strip.splitLines()[0].strip)
        except ValueError, IndexDefect: discard
        if code != 0 or n <= 0: raise newException(IOError, "no sound in " & file)
        channels = if n >= 2: 2 else: 1
        var base = safeName(file).toLowerAscii
        if base.len > MaxImportedName: base.setLen MaxImportedName
        base = ImportedSoundPrefix & base
        name = base
        var k = 2
        while fileExists(p.oniDir / "SNDD" & name & ".aif.oni") or name in names[]:
          name = base & "_" & $k
          inc k
        if dirExists(work): removeDir(work)
        createDir(work)
        createDir(p.oniDir)
        wav = work / name & ".aif.wav"),
      command("Converting " & label, proc(): seq[string] =
        @["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", file,
          "-map", "0:a:0", "-map_metadata", "-1", "-fflags", "+bitexact",
          "-ac", $channels, "-ar", "22050", "-c:a", "adpcm_ms", "-block_size", $(512 * channels), wav]),
      action("Checking " & label, proc() = fixAdpcmByteRate(wav)),
      # OniSplit names the SNDD after the file, less its .wav: SNDDcw_<name>.aif.
      command("Packing " & label, proc(): seq[string] = c.splitArgs("-create", p.oniDir, wav)),
      action("Adding " & label, proc() =
        if not fileExists(p.oniDir / "SNDD" & name & ".aif.oni"):
          raise newException(IOError, "OniSplit made no sound of " & file)
        createDir(p.soundsDir)
        moveFile(wav, p.soundsDir / name & ".aif.wav")
        removeDir(work)
        names[].add name)]
  var all: seq[Step]
  for i, file in files: all.add steps(i, file)
  all.add action("Done", proc() = onDone(names[]))
  newJob("Importing sounds", p.logPath, all)

proc usedRecordings(p: Project): HashSet[string] =
  ## The rec_<name> sounds in the project's classes, objects, lights and scripts.
  var files: seq[string]
  for sub in [p.classesDir, p.objectsDir, p.dir / "IGMD"]:
    for f in walkDirRec(sub):
      if f.endsWith(".xml") or f.endsWith(".bsl"): files.add f
  if fileExists(p.lightsPath): files.add p.lightsPath
  for f in files:
    for m in readFile(f).findAll(re("(?<![A-Za-z0-9_])" & RecordingPrefix & "[A-Za-z0-9_.-]+")):
      result.incl m

proc dropUnusedSounds(p: Project, work: string) =
  ## Imported sounds (SNDDcw_*) that nothing in the level plays stay out of it.
  var used = loadAmbients(p.ambientsPath).usedSounds
  for id in p.usedRecordings: used.incl splitRecording(id)[0].toLowerAscii
  for f in walkFiles(work / "SNDD" & ImportedSoundPrefix & "*.aif.oni"):
    if f.extractFilename["SNDD".len .. ^(".aif.oni".len + 1)].toLowerAscii notin used: removeFile(f)

proc recordingSources(p: Project, dir: string): seq[string] =
  ## A rec_<name> sound in the project's classes, objects, lights or scripts is one
  ## recording. Oni only plays definitions, so the level gets its own: a sound
  ## group of that recording alone, and an impulse and a looping ambient of the
  ## group. The recording itself stays in level 0. Oni adds a level's OSBDs to
  ## level 0's (OSiGroup_Load); an impulse needs Arklite to find its group.
  let names = p.usedRecordings
  if names.len == 0: return
  createDir(dir)
  for id in names.toSeq.sorted:
    let (name, pitch) = splitRecording(id)
    if id.len > 31:   # Oni's sound names hold 31 characters.
      raise newException(ValueError, "the sound name " & id & " is too long for Oni: use this recording at pitch 1")
    let own = p.soundsDir / name.toLowerAscii & ".aif.wav"   # imported (importSoundsJob)
    let wav = if fileExists(own): own else: recordingWav(name)
    if not fileExists(wav):
      raise newException(ValueError, "the sound " & id & " isn't a recording in " & soundDir() &
                         " (playing any sound's preview extracts them)")
    let head = readFile(wav)
    if head.len < 24:
      raise newException(ValueError, "unreadable recording: " & wav)
    let channels = head[22].ord or (head[23].ord shl 8)
    let pieces = [("grp", &"""<Oni>
  <SoundGroup>
    <Volume>1</Volume>
    <Pitch>1</Pitch>
    <Flags></Flags>
    <NumberOfChannels>{channels}</NumberOfChannels>
    <Permutations>
      <Permutation>
        <Weight>10</Weight>
        <Volume><Min>1</Min><Max>1</Max></Volume>
        <Pitch><Min>{pitch}</Min><Max>{pitch}</Max></Pitch>
        <Sound>{name}.aif</Sound>
      </Permutation>
    </Permutations>
  </SoundGroup>
</Oni>
"""), ("imp", &"""<Oni>
  <ImpulseSound>
    <Group>{id}</Group>
    <Priority>Normal</Priority>
    <Volume>
      <Distance><Min>25</Min><Max>260</Max></Distance>
      <Angle><Min>360</Min><Max>360</Max><MinAttenuation>0</MinAttenuation></Angle>
    </Volume>
    <AlternateImpulse><Treshold>0</Treshold><Impulse></Impulse></AlternateImpulse>
    <ImpactVelocity>0</ImpactVelocity>
    <MinOcclusion>0</MinOcclusion>
  </ImpulseSound>
</Oni>
"""), ("amb", &"""<Oni>
  <AmbientSound>
    <Priority>Normal</Priority>
    <Flags></Flags>
    <DetailTrackProperties>
      <SphereRadius>10</SphereRadius>
      <ElapsedTime><Min>0</Min><Max>0</Max></ElapsedTime>
    </DetailTrackProperties>
    <Volume><Distance><Min>10</Min><Max>50</Max></Distance></Volume>
    <DetailTrack></DetailTrack>
    <BaseTrack1>{id}</BaseTrack1>
    <BaseTrack2></BaseTrack2>
    <InSound></InSound>
    <OutSound></OutSound>
    <Treshold>3</Treshold>
    <MinOcclusion>0</MinOcclusion>
  </AmbientSound>
</Oni>
""")]
    for (kind, body) in pieces:
      let dst = dir / "OSBD" & id & "." & kind & ".xml"
      writeFile(dst, xmlHeader & body)
      result.add dst
  let log = open(p.logPath, fmAppend)
  log.writeLine "recordings defined: " & names.toSeq.sorted.join(", ")
  log.close()

proc wavChannels(wav: string): int =
  ## A recording's channel count (1 or 2); raises ValueError when unreadable.
  var head = ""
  try:
    let f = open(wav)
    head = newString(24)
    head.setLen f.readBuffer(head[0].addr, 24)
    f.close()
  except IOError: discard
  if head.len < 24: raise newException(ValueError, "unreadable recording: " & wav)
  head[22].ord or (head[23].ord shl 8)

proc ambientSources(p: Project, dir: string): seq[string] =
  ## The project's own ambients (ambients.json): an OSBD .amb each and a .grp per
  ## track with sounds. A group's channel count is its recordings'.
  let ambs = loadAmbients(p.ambientsPath)
  if ambs.len == 0: return
  createDir(dir)
  for a in ambs:
    for t in AmbTrack:
      let g = a.tracks[t]
      if g.perms.len == 0: continue
      var channels = 0
      for perm in g.perms:
        let name = perm.sound.soundBase
        let own = p.soundsDir / name & ".aif.wav"
        let wav = if fileExists(own): own else: recordingWav(name)
        if not fileExists(wav):
          raise newException(ValueError, "the ambient " & a.name & " plays " & name &
                             ", which isn't a recording in " & soundDir() & " (playing any sound's preview extracts them)")
        let ch = wavChannels(wav)
        if channels == 0: channels = ch
        elif ch != channels:
          raise newException(ValueError, "the ambient " & a.name & "'s " & $t &
                             " mixes mono and stereo recordings (" & name & "): Oni plays a group in one of them")
      let dst = dir / "OSBD" & a.groupName(t) & ".grp.xml"
      writeFile(dst, xmlHeader & groupXml(g, channels))
      result.add dst
    let dst = dir / "OSBD" & a.name & ".amb.xml"
    writeFile(dst, xmlHeader & ambientXml(a))
    result.add dst
  let log = open(p.logPath, fmAppend)
  log.writeLine "level ambients defined: " & ambs.mapIt(it.name).join(", ")
  log.close()

proc classSources(p: Project, dir: string): seq[string] =
  ## What Build compiles as objects: the object lists, plus each edited class
  ## renamed to <name>EditedSuffix (see classCacheDir), with the characters of
  ## that class pointed at the new name in a copy of the character list, and
  ## likewise the edited particle classes (particleSources) and Particle objects.
  if dirExists(dir): removeDir(dir)
  let edited = p.editedClasses
  if edited.len > 0: createDir(dir)
  var placed: seq[string]
  let partList = p.objectsDir / "BINACJBOParticle.xml"
  if fileExists(partList):
    for o in loadObjectFile(partList)[1]: placed.add o.node.xpath("OSD/Class").str.strip
  let (particleFiles, particleNames) = p.particleSources(dir, placed)
  result.add particleFiles
  # Ambient light sounds join the Sound list, numbered after every object.
  let lightSounds = p.lightAmbients
  var lightSoundsAdded = false
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
    let renameParts = particleNames.len > 0 and f == partList
    # Lists with Catwalk's own fields (RespawnTime, ActivationMessage) go through a
    # copy without them.
    let addSounds = lightSounds.len > 0 and f.extractFilename == "BINACJBOSound.xml"
    if not renameChars and not renameParts and not addSounds and not hasEditorFields(readFile(f)):
      result.add f
      continue
    let (file, objs) = loadObjectFile(f)
    if addSounds and file.list != nil:
      for n in lightSounds: file.list.add n
      lightSoundsAdded = true
    if renameChars:
      for o in objs:
        let cls = o.node.xpath("OSD/Class")
        if cls != nil and cls.str.strip in edited:
          renamed.add o.label
          cls.setText(cls.str.strip & EditedSuffix)
    if renameParts:
      for o in objs:
        let cls = o.node.xpath("OSD/Class")
        if cls != nil and cls.str.strip.toLowerAscii in particleNames:
          cls.setText(particleNames[cls.str.strip.toLowerAscii])
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
  if lightSounds.len > 0:
    if not lightSoundsAdded:
      createDir(dir)
      let dst = dir / "BINACJBOSound.xml"
      let list = newElement("Objects")
      for n in lightSounds: list.add n
      writeFile(dst, xmlHeader & $newXmlTree("Oni", [list]) & "\n")
      result.add dst
    let log = open(p.logPath, fmAppend)
    log.writeLine $lightSounds.len & " light ambient sounds (as Sound objects): " &
                  lightSounds.mapIt(it.xpath("OSD/Class").str).join(", ")
    log.close()
  if particleNames.len > 0:
    let log = open(p.logPath, fmAppend)
    log.writeLine "edited particle classes packed: " & toSeq(particleNames.values).sorted.join(", ")
    log.close()
  if edited.len > 0:
    let log = open(p.logPath, fmAppend)
    log.writeLine "edited classes: " & edited.join(", ") & "; characters using them: " &
                  (if renamed.len > 0: renamed.join(", ") else: "none")
    log.close()
  result.add p.recordingSources(dir)
  result.add p.ambientSources(dir)

# --- skies -------------------------------------------------------------------

proc customSkyXml(sky: string, bottom: bool): string =
  ## An ONSK with the sky's faces and nothing else in it.
  var faces = ""
  for f in SkyFaces: faces.add &"<Link>TXMP{sky}_{f}</Link>"
  faces.add(if bottom: &"<Link>TXMP{sky}_{SkyBottom}</Link>" else: "<Link></Link>")
  proc links(n: int): string =
    for _ in 0 ..< n: result.add "<Link></Link>"
  proc zeros(n: int): string =
    for _ in 0 ..< n: result.add "<Float>0</Float>"
  xmlHeader & &"""<Oni>
  <ONSK id="0">
    <SkyboxTextures>{faces}</SkyboxTextures>
    <Planets>{links(8)}</Planets>
    <SunFlare></SunFlare>
    <Stars>{links(5)}</Stars>
    <PlanetCount>0</PlanetCount>
    <NoSunFlare>-1</NoSunFlare>
    <PlanetWidths>{zeros(8)}</PlanetWidths>
    <PlanetHeights>{zeros(8)}</PlanetHeights>
    <PlanetElevations>{zeros(8)}</PlanetElevations>
    <PlanetAzimuths>{zeros(8)}</PlanetAzimuths>
    <SunFlareSize>1</SunFlareSize>
    <SunFlareIntensity>1</SunFlareIntensity>
    <StarCount>0</StarCount>
    <RandomSeed>0</RandomSeed>
    <StarTextureCount>0</StarTextureCount>
  </ONSK>
</Oni>
"""

proc skySteps(c: Config, p: Project, work, geo: string): seq[Step] =
  ## A sky imported into the project goes into the level as its own ONSK and
  ## TXMPs; a game level whose sky was changed gets its ONLV relinked. Made
  ## from scratch, the level links its sky by name already. The sky's images
  ## stay as they are: its grade goes on the copies made here.
  let
    src = geo / "sky"
    onlvName = "ONLV" & p.envName & ".oni"
    xmlPath = geo / "sky-xml" / "ONLV" & p.envName & ".xml"
    stock = p.sky
    sky = p.builtSky
    grade = p.skyGrade
    custom = p.isCustomSky(stock)
  if custom or sky != stock:
    var faces = @SkyFaces
    let hasBottom = custom and fileExists(p.customSkyDir(stock) / SkyBottom & ".tga")
    if hasBottom: faces.add SkyBottom
    proc image(face: string): string =
      if custom: p.customSkyDir(stock) / face & ".tga" else: skyFace(stock, face)
    proc skyXml(): string =
      if custom: return customSkyXml(sky, hasBottom)
      # Level 0's own, for its stars and planets, with these faces.
      let file = skyDir() / stock / "onsk.xml"
      if not fileExists(file): raise newException(ValueError, "level 0's skies aren't extracted yet: try again in a moment")
      var links = ""
      for f in SkyFaces: links.add &"<Link>TXMP{sky}_{f}</Link>"
      readFile(file).replace(re"(?s)<SkyboxTextures>.*</SkyboxTextures>",
                             "<SkyboxTextures>" & links & "<Link></Link></SkyboxTextures>")
    result.add @[
      action("Preparing the sky", proc() =
        if dirExists(src): removeDir(src)
        createDir(src)
        for f in faces:
          let dst = src / sky & "_" & f & ".tga"
          if grade.isPlain: copyFile(image(f), dst)
          else: writeTga(dst, readTga(readFile(image(f))).graded(grade))),
      command("Writing sky textures", proc(): seq[string] =
        result = c.splitArgs("-create:txmp", work, "-nomipmaps", "-nouwrap", "-novwrap", "-large")
        for f in faces: result.add src / sky & "_" & f & ".tga"),
      action("Writing the sky", proc() = writeFile(src / "ONSK" & sky & ".xml", skyXml())),
      command("Compiling the sky", proc(): seq[string] =
        c.splitArgs("-create", work, src / "ONSK" & sky & ".xml"))]
  if p.scratch or sky == p.findSky: return
  result.add @[
    command("Reading the level", proc(): seq[string] =
      c.splitArgs("-extract:xml", geo / "sky-xml", work / onlvName)),
    action("Linking the sky", proc() =
      let link = if sky.len > 0: "ONSK" & sky else: ""
      writeFile(xmlPath, readFile(xmlPath).replace(re"<SkyBox>[^<]*</SkyBox>", "<SkyBox>" & link & "</SkyBox>"))),
    command("Writing the level", proc(): seq[string] =
      c.splitArgs("-create", geo / "sky-onlv", xmlPath)),
    action("Linking level", proc() = copyCreated(geo / "sky-onlv", work))]

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
      sources = classSources(p, p.buildDir / "classes")
      p.dropUnusedSounds(work)),
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
        levelXml = writeLevelSource(model, geo / "src", p.envName, p.builtSky, p.imagesDir,
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
        writeAnims(p, model, linked.built)
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

  steps.add skySteps(c, p, work, geo)
  var game: Table[string, (string, int)]
  steps.add @[
    action("Preparing output", proc() =
      if not dirExists(c.customLevels):
        raise newException(IOError, "CustomLevels folder missing (is the Custom Game mod installed?): " & c.customLevels)
      createDir(outDir)
      for f in walkFiles(outDir / "level*_Final.*"): removeFile(f)),
    action("Leaving out the game's textures", proc() =
      game = gameTextures(c.gameData, p.levelNumber)
      dropGameTextures(work, game)),
    command("Packing level", proc(): seq[string] =
      c.splitArgs("-import:pc", work, dat)),
    action("Writing level info", proc() =
      var ini = "[level]\nname=" & p.title & "\nsource=" & $p.levelNumber & "\n"
      let levels = textureLevels(dat, game)
      if levels.len > 0: ini.add "\n[textures]\nlevels=" & levels.join(",") & "\n"
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
      # Particles in spinning groups, also for Arklite.
      let spinning = writeSpinParticles(
        p.projectSpins(if p.hasGeometry: loadGeometry(p.geometryPath) else: Geometry()),
        outDir / "spinparticles.bin")
      if spinning > 0:
        let f = open(p.logPath, fmAppend)
        f.writeLine $spinning & " spinning particles (spinparticles.bin, turned by Arklite)"
        f.close()
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
    if c.game.len == 0:
      raise newException(IOError, "no game set: pick Oni.exe in View > Settings > General")
    if not fileExists(c.game):
      raise newException(IOError, "game not found: " & c.game)
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["ARKLITE_AUTOSTART"] = p.folder
    env["ARKLITE_SAVEPOINT"] = $savePoint
    # The game's output (Wine's crash address and backtrace) goes to build/game.log.
    createDir(p.buildDir)
    let log = p.buildDir / "game.log"
    # Oni.exe starts windowed, as the installer's launch script starts it.
    const Args = ["-noswitch", "-debugfiles"]
    var pr: Process
    if c.game.isExe:
      when defined(windows):
        pr = startProcess(c.game, workingDir = c.game.parentDir, env = env, args = Args)
      else:
        let wine = findExe("wine")
        if wine.len == 0: raise newException(IOError, "Oni.exe needs Wine, which isn't installed")
        let prefix = winePrefixOf(c.game)
        if prefix.len > 0: env["WINEPREFIX"] = prefix
        pr = startProcess("/bin/sh", workingDir = c.game.parentDir, env = env, options = {poDaemon},
                          args = @["-c", "exec \"$0\" \"$1\" \"$3\" \"$4\" >\"$2\" 2>&1", wine,
                                   c.game.extractFilename, log] & @Args)
    else:
      when defined(windows):  # a .bat or .cmd
        pr = startCmd(@[c.game], "> " & cmdQuote(log) & " 2>&1", workingDir = c.aeDir, env = env)
      else:
        pr = startProcess("/bin/sh", workingDir = c.aeDir, env = env, options = {poDaemon},
                          args = ["-c", "exec \"$0\" >\"$1\" 2>&1", c.game, log])
    pr.close())
