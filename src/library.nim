## The entity library: furniture, consoles, doors and triggers taken from the
## original game's levels, ready to place in any level.
##
## In the shipped game, furniture has no class of its own (no OFGA instances):
## each piece is quads in the level's AKEV, linked to its FURN object by
## ObjectId. Consoles and triggers own geometry the same way. So the library
## keeps, per class, the first instance's object XML (cleaned up) plus its
## geometry in object space, and the textures that geometry uses. Placing one
## adds the faces to the level, linked to the new object.
##
## Built from level 0 and the first game levels (FirstLevels) into
## ~/.local/share/catwalk/library/ (%LOCALAPPDATA%\catwalk\library); each
## level a project adds to its Texture Collections adds its classes too
## (addLevelsJob):
##   library.json        the entries, and the levels they come from
##   prefabs/*.json      geometry (Catwalk's geometry.json format)
##   images/*.tga        textures the prefabs use
##   oni/TXMP*.oni       level textures decals need (see presets.DecalTextures)
##   doors/*.oni         level 0's DOOR classes and their OBAN animations, and every
##                       door texture (class links, Texture1/2) from any level:
##                       what OniSplit needs to build doors into a level
##   thumbs/*.png        entity browser previews (see thumbKey)
##   models/*.bin        the models previews show, for the map views (see objectModel)
##   screens/*.tga       level 0's console screen textures, by lowercase name (see consoleScreen)
##   classes/            level 0's turret and door classes as XML and their models, and
##                       console screen models: previews of classes added later need them

import std/[os, json, xmltree, xmlparser, strutils, tables, sets, algorithm, times, uri, sequtils]
import std/osproc
import vmath
import jobs, project, geometry, geomops, levelobjects, objtemplates, presets, thumbs, particles, tga

const
  LibraryVersion = 3   ## 3: levels added with their Texture Collections ("levels").
  ## Object types the library takes, with the object file OniSplit names after them.
  LibraryTypes = [("FURN", "Furniture"), ("CONS", "Console"), ("DOOR", "Door"), ("TRIG", "Trigger")]
  LevelTitles = {"EnvWarehouse": "Warehouse", "manplant": "Manufacturing plant",
    "lab": "Research lab", "Airport": "Airport", "Airport_III": "Airport hangars",
    "tctf": "TCTF headquarters", "power": "Power plant", "power_II": "Power plant II",
    "state": "State building", "roof": "Rooftops", "dream_lab": "Dream lab",
    "neuro": "Neuro lab", "tctf_II": "TCTF headquarters II", "compound": "Mountain compound"}.toTable

export libraryDir, libraryDoorsDir   # in project: Build reads the library's door files

proc envMappedImages(oniDir: string): HashSet[string] =
  ## The .tga names (lowercase, as -extract:dae writes them) of the textures
  ## with an environment map. Their alpha is how strongly the map reflects,
  ## not transparency: drawn as cutouts, faces and armor plates vanish. An
  ## exported TXMP .oni holds its env map as a second TXMP instance.
  for f in walkFiles(oniDir / "TXMP*.oni"):
    var file: File
    if not open(file, f): continue
    var head = newString(0x40 + 20 * 4)
    let n = file.readBuffer(head[0].addr, head.len)
    file.close()
    if n < 0x40: continue
    let count = min(4, head[0x14].uint8.int or (head[0x15].uint8.int shl 8))
    var txmp = 0
    var animated = false
    for i in 0 ..< count:
      let o = 0x40 + 20 * i
      if o + 4 > n: break
      case head[o ..< o + 4]
      of "PMXT": inc txmp
      of "NAXT": animated = true
    if txmp > 1 and not animated:
      let name = decodeUrl(f.extractFilename.changeFileExt("")[4 .. ^1]).replace('/', '_')
      result.incl name.toLowerAscii & ".tga"

proc libraryFile*(): string = libraryDir() / "library.json"
proc libraryImages*(): string = libraryDir() / "images"
proc libraryOni*(): string = libraryDir() / "oni"
proc prefabPath*(p: Preset): string = libraryDir() / "prefabs" / p.prefab
proc thumbDir*(): string = libraryDir() / "thumbs"
proc modelDir*(): string = libraryDir() / "models"

const PreviewVersion = 7   ## Bump when previews should be rendered again (2: particles, 3: models, 4: env-mapped textures opaque, 5: doors/ for Build, 6: console screens, 7: classes/ kept).

var libraryLooked = -1.0   ## epochTime of the last look at the library's files (see lookAtLibrary).
var libraryState: tuple[built, previews: bool, stamp: string]

proc libraryChanged*() =
  ## The library's files were written or removed: look again.
  libraryLooked = -1.0

proc lookAtLibrary() =
  ## Whether the library and its previews are there, and its file's time:
  ## the editor asks every frame, the files are looked at twice a second
  ## (and after libraryChanged).
  let now = epochTime()
  if libraryLooked >= 0 and now - libraryLooked < 0.5: return
  libraryLooked = now
  libraryState.built = fileExists(libraryFile())
  libraryState.previews =
    try: readFile(libraryDir() / "thumbs" / "version").strip == $PreviewVersion
    except IOError: false
  libraryState.stamp =
    try: (if libraryState.built: $getLastModificationTime(libraryFile()).toUnix else: "")
    except CatchableError: ""

proc hasLibrary*(): bool =
  lookAtLibrary()
  libraryState.built

proc libraryStamp*(): string =
  ## The library file's time ("" = none): another value means it was rebuilt.
  lookAtLibrary()
  libraryState.stamp

proc lockPath(): string = libraryDir().parentDir / "library.lock"

proc libraryBusyElsewhere*(): bool =
  ## Another running Catwalk is building the library (it holds the lock).
  try:
    let pid = readFile(lockPath()).strip.parseInt
    pid != getCurrentProcessId() and processAlive(pid)
  except CatchableError: false


proc hasPreviews*(): bool =
  ## The library has a complete set of model previews from this version.
  lookAtLibrary()
  libraryState.previews

proc loadLibrary*(): seq[Preset] =
  ## Library entries as presets; empty when the library isn't built.
  if not hasLibrary(): return
  let j = parseFile(libraryFile())
  if j{"version"}.getInt != LibraryVersion: return
  for e in j["entries"]:
    var p = Preset(group: e["group"].getStr, label: e["label"].getStr, detail: e{"detail"}.getStr,
                   tag: e["tag"].getStr, xml: e["xml"].getStr, prefab: e{"prefab"}.getStr,
                   doorCenter: e{"doorCenter"}.getStr, modelTexture: e{"modelTexture"}.getStr)
    for t in e{"textures"}.getElems: p.textures.add t.getStr
    result.add p

proc removeTokens(s: string, drop: openArray[string]): string =
  var keep: seq[string]
  for t in s.splitWhitespace:
    if t notin drop: keep.add t
  keep.join(" ")

proc fileSafe(s: string): string =
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: c else: '_')

const
  ## Power-up classes and their level 0 models (LSI has none).
  PowerUpModels = {"Hypo": "powerup_hypo", "Ammo": "powerup_ammo", "EnergyCell": "powerup_cell",
    "Shield": "powerup_shield", "Invisibility": "powerup_invis"}.toTable

proc presetClass(p: Preset): string =
  for (k, v) in p.fields:
    if k == "OSD/Class": return v
  if p.xml.len > 0: return p.label   # Library entries are named after their class.

proc classKey(tag, cls: string): string =
  ## Preview and model file name of an object class ("" if it has none).
  if cls.len == 0: return ""
  case tag
  of "CHAR", "WEAP", "TURR", "DOOR", "PART": fileSafe(tag & "_" & cls)
  of "PWRU": (if cls in PowerUpModels: "PWRU_" & cls else: "")
  else: ""

proc thumbKey*(p: Preset): string =
  ## The preview's file name in thumbs/ (without .png); "" for presets without
  ## a model (generic objects, particles, the LSI).
  if p.generic: return ""
  if p.prefab.len > 0: return p.prefab.changeFileExt("")
  classKey(p.tag, p.presetClass)

proc thumbPath*(p: Preset): string =
  let k = p.thumbKey
  if k.len > 0: thumbDir() / k & ".png" else: ""

const
  ## Objects the map views draw with their class's model.
  ModelTags* = ["CHAR", "WEAP", "PWRU", "TURR", "DOOR"]
  ## Models that rest on the floor at the object's position (the others are
  ## modelled that way already: characters stand on it, turrets hang from it).
  FloorTags = ["WEAP", "PWRU", "DOOR"]

type
  ObjectModel* = object
    path*: string                 ## The model's file in models/.
    parts*: seq[Mat4]             ## Model space to object space, one per copy drawn.
    lo*, hi*: Vec3                ## Bounds in object space.

var modelBoundsCache: Table[string, (bool, Vec3, Vec3)]
var modelStamp = ""   ## thumbs/version's time when the cache was filled.

var modelEpoch* = 0   ## Bumped when the cached models are forgotten (appstate's object cache follows).

proc clearModelCache*() =
  modelBoundsCache.clear()
  inc modelEpoch

proc modelsChanged*(): bool =
  ## True (once) when the library finished a build since the last call; the
  ## cached models, including "has none", are then forgotten. Once per frame.
  let stamp = try: $getLastModificationTime(thumbDir() / "version").toUnixFloat
              except OSError: ""
  if stamp == modelStamp: return false
  modelStamp = stamp
  clearModelCache()
  true

proc modelBounds(path: string): (bool, Vec3, Vec3) =
  if path notin modelBoundsCache:
    let m = loadModel(path, libraryDir())
    modelBoundsCache[path] =
      if m.isEmpty: (false, vec3(0, 0, 0), vec3(0, 0, 0))
      else:
        let (lo, hi) = m.bounds
        (true, lo, hi)
  modelBoundsCache[path]

proc objectModel*(o: LevelObject): (bool, ObjectModel) =
  ## The model the map views draw for an object, if the library has one.
  if o.tag notin ModelTags: return
  let key = classKey(o.tag, o.node.xpath("OSD/Class").str.strip)
  if key.len == 0: return
  let path = modelDir() / key & ".bin"
  let (ok, lo, hi) = modelBounds(path)
  if not ok: return
  var m = ObjectModel(path: path)
  let lift = if o.tag in FloorTags: translate(vec3(0, -lo.y, 0)) else: mat4()
  if o.tag == "DOOR" and "DoubleDoor" in o.node.xpath("OSD/Flags").str.splitWhitespace:
    # One model per half, the second turned around.
    let w = (hi.x - lo.x) / 2
    m.parts = @[translate(vec3(-w, 0, 0)) * lift, translate(vec3(w, 0, 0)) * rotateY(PI.float32) * lift]
  else:
    m.parts = @[lift]
  m.lo = vec3(Inf.float32)
  m.hi = vec3(-Inf.float32)
  for t in m.parts:
    for x in [lo.x, hi.x]:
      for y in [lo.y, hi.y]:
        for z in [lo.z, hi.z]:
          let q = t * vec3(x, y, z)
          m.lo = min(m.lo, q)
          m.hi = max(m.hi, q)
  (true, m)

proc screenDir*(): string = libraryDir() / "screens"

proc screenImage(texture: string): string =
  ## The image of a console screen texture ("" if the library has none).
  if texture.len == 0: return ""
  let f = screenDir() / texture.toLowerAscii & ".tga"
  if fileExists(f): f else: ""

proc consoleState(n: XmlNode): string =
  ## The OSD texture field a console's screen shows when the level starts.
  if "InitialActive" in n.xpath("OSD/Flags").str.splitWhitespace: "OSD/ActiveTexture"
  else: "OSD/InactiveTexture"

proc consoleScreen*(o: LevelObject): (bool, string, string) =
  ## A console's screen: not level geometry but its class's ScreenGeometry,
  ## which the game textures by state. The model in models/ (object space,
  ## like the class's prefab) and the image of the texture the console's
  ## starting state shows ("" if the library lacks it).
  if o.tag != "CONS": return
  let cls = o.node.xpath("OSD/Class").str.strip
  if cls.len == 0: return
  let path = modelDir() / fileSafe("CONS_" & cls & "_screen") & ".bin"
  if not modelBounds(path)[0]: return
  (true, path, screenImage(o.node.xpath(consoleState(o.node)).str.strip))

type Collector = ref object
  entries: seq[JsonNode]
  levels: seq[int]                ## Game levels the entries come from.
  seen: HashSet[string]           ## tag/class already taken
  textures: HashSet[string]       ## textures prefabs use
  copied: HashSet[string]         ## textures in images/
  shared: Table[string, string]   ## level 0 TXMP name -> texture it provides
  l0: string                      ## Level 0's export.
  doorWanted: Table[string, HashSet[string]]  ## Door preview textures not found yet: lower case -> names.
  doorWantedFrom: Table[string, int]  ## The level whose door first wanted each: looked for there and after.
  doorTextures: Table[int, seq[(string, string)]]  ## Per level: TXMP files door previews need, and texture names.
  doorWantedOni: HashSet[string]  ## Door textures doors/ keeps (instanceKey names).
  doorHaveOni: HashSet[string]    ## Those in doors/ already.
  doorMissingOni: HashSet[string] ## Those no level the library has, nor level 0, had.
  particleTextures: seq[string]   ## TXMPs particle previews show.
  modelParticles: HashSet[string] ## Particle classes whose previews show models.
  envMapped: HashSet[string]      ## See envMappedImages.

const
  ## Level 0's instance types the library reads (characters, weapons and
  ## all M3GM models are extracted from the .dat itself): textures, turret,
  ## door and console classes with their geometry, door animations,
  ## particles. OniSplit exports each type on its own and side by side, much
  ## faster than the whole level.
  Level0Types = ["TXMP", "M3GM", "BINA", "TURR", "OBAN"]
  ## Those whose export brings a few TXMPs too: to folders of their own (two
  ## OniSplits writing one file fail), moved in once TXMP's is done.
  OwnFolderTypes = ["DOOR", "CONS"]
  ## The levels a first build takes (more are added with their Texture
  ## Collections, see addLevelsJob).
  FirstLevels = [1]
  ## Levels with decal textures (presets.DecalTextures): their textures are
  ## read whichever levels the library takes.
  DecalLevels = [1, 2, 4, 6, 10, 19]

proc libraryClassesDir(): string = libraryDir() / "classes"

proc libraryLevels*(): seq[int] =
  ## The game levels the built library has taken classes from (none when it
  ## isn't built, or from an older version).
  try:
    let j = parseFile(libraryFile())
    if j{"version"}.getInt != LibraryVersion: return
    for l in j{"levels"}.getElems: result.add l.getInt
  except CatchableError: discard

proc libraryBuilt*(): bool =
  ## The library is built, by this version, previews included.
  hasPreviews() and libraryLevels().len > 0

proc classTexture(file: string): string =
  ## The texture a door class's model links to, by name ("" if unknown):
  ## the first "TXMP<name>" string in its .oni file.
  let links = oniLinks(file, "TXMP")
  if links.len > 0: links[0] else: ""

proc collectDoorOni(lib: Collector, oniDir: string) =
  ## Copies the door textures doors/ still lacks from one exported level.
  for f in walkFiles(oniDir / "TXMP*.oni"):
    let k = instanceKey(f)
    if k in lib.doorWantedOni and k notin lib.doorHaveOni:
      copyFile(f, libraryDoorsDir() / f.extractFilename)
      lib.doorHaveOni.incl k

proc collectDoorClasses(lib: Collector) =
  ## Level 0's DOOR classes, their animations and the textures they link, for
  ## Build (OniSplit builds a level's doors from them; see project.doorSteps).
  let src = lib.l0 / "oni"
  createDir(libraryDoorsDir())
  for f in walkFiles(src / "DOOR*.oni"):
    copyFile(f, libraryDoorsDir() / f.extractFilename)
    for a in oniLinks(f, "OBAN"):
      let anim = src / "OBAN" & a & ".oni"
      if fileExists(anim): copyFile(anim, libraryDoorsDir() / anim.extractFilename)
    for t in oniLinks(f, "TXMP"): lib.doorWantedOni.incl ("TXMP" & t).toLowerAscii
  lib.collectDoorOni(src)

proc loadCollector(l0: string): Collector =
  ## The built library, to add levels to: only what those levels need is
  ## looked for (their door textures, the textures their classes use).
  result = Collector(l0: l0)
  let j = parseFile(libraryFile())
  for e in j["entries"]:
    result.entries.add e
    result.seen.incl e["tag"].getStr & "/" & e["label"].getStr
  for l in j{"levels"}.getElems: result.levels.add l.getInt
  for f in walkFiles(libraryImages() / "*.tga"): result.copied.incl f.splitFile.name
  for f in walkFiles(libraryDoorsDir() / "TXMP*.oni"): result.doorHaveOni.incl instanceKey(f)
  # What the doors of the levels it has wanted: a level added may have some.
  for t in j{"doorTextures"}.getElems: result.doorWantedOni.incl t.getStr
  result.doorMissingOni = result.doorWantedOni - result.doorHaveOni

proc levelWork(n: int): string = libraryDir() / "work" / $n

proc keepLevelTextures(n: int) =
  ## The level's textures, which its Texture Collection shows too: extracted
  ## once for both (see project.levelTexturesDir).
  if levelTexturesReady(n): return
  let dir = levelTexturesDir(n)
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  for f in walkFiles(levelWork(n) / "env" / "images" / "*.tga"):
    if not f.extractFilename.startsWith("bnv_grid"): moveFile(f, dir / f.extractFilename)
  writeFile(dir / ".done", "")

proc collectLevel(lib: Collector, level: int) =
  ## Takes every class not in the library yet from one exported level.
  let work = levelWork(level)
  keepLevelTextures(level)
  if level notin lib.levels: lib.levels.add level
  var env = ""
  for f in walkFiles(work / "oni" / "ONLV*.oni"): env = f.splitFile.name["ONLV".len .. ^1]
  let title = LevelTitles.getOrDefault(env, env)
  var akev = ""
  for f in walkFiles(work / "xml" / "AKEV*.xml"): akev = f
  let geo = if akev.len > 0: importAkevXml(akev) else: Geometry()
  var facesOf: Table[int32, seq[int]]
  for i, f in geo.faces:
    if f.objectId != -1: facesOf.mgetOrPut(f.objectId, @[]).add i
  let dir = libraryDir()
  for (tag, fileName) in LibraryTypes:
    let path = work / "xml" / "BINACJBO" & fileName & ".xml"
    if not fileExists(path): continue
    let (_, objs) = loadObjectFile(path)
    for o in objs:
      if tag == "DOOR":
        for field in ["OSD/Texture1", "OSD/Texture2"]:
          let t = o.node.xpath(field).str.strip
          if t.len > 0: lib.doorWantedOni.incl ("TXMP" & t).toLowerAscii
      let cls = o.node.xpath("OSD/Class").str.strip
      if cls.len == 0 or (tag & "/" & cls) in lib.seen: continue
      let code = int32((GunkTypes[tag] shl 24) or (o.id and 0xffffff))
      let faces = if tag == "DOOR": @[] else: facesOf.getOrDefault(code)
      # Furniture is nothing but its geometry.
      if tag == "FURN" and faces.len == 0: continue
      lib.seen.incl tag & "/" & cls
      let toLocal = objectMatrix(o.pos, o.rot).inverse
      let n = parseXml($o.node)
      n.setAttr("Id", "0")
      n.xpath("Header/Position").setText("0 0 0")
      n.xpath("Header/Rotation").setText("0 0 0")
      let hf = n.xpath("Header/Flags")
      # Doors come without their frame geometry: no Gunk link and no frame.
      hf.setText(removeTokens(hf.str, if faces.len > 0: @["Locked"] else: @["Locked", "Gunk"]))
      if tag in ScriptIdFields: n.xpath(ScriptIdFields[tag]).setText("0")
      let events = n.xpath("OSD/Events")
      if events != nil:
        while events.len > 0: events.delete(0)
      var e = %*{"group": (if tag == "FURN": "Furniture: " & title else: typeName(tag) & "s"),
                 "label": cls, "tag": tag}
      if tag != "FURN": e["detail"] = %title
      if tag == "DOOR":
        let fl = n.xpath("OSD/Flags")
        fl.setText(removeTokens(fl.str, ["InitialLocked", "InDoorFrame"]))
        let c = toLocal * parseVec3(n.xpath("OSD/Center").str)
        e["doorCenter"] = %fmtVec3(c)
        # The preview's texture: the object's, else the class's. Both are
        # level content, not always in this level (see findDoorTextures).
        var t = n.xpath("OSD/Texture1").str.strip
        if t.len == 0: t = classTexture(libraryDoorsDir() / "DOOR" & cls & ".oni")
        if t.len > 0:
          e["modelTexture"] = %t
          if not fileExists(libraryImages() / t & ".tga"):
            lib.doorWanted.mgetOrPut(t.toLowerAscii, initHashSet[string]()).incl t
            if t.toLowerAscii notin lib.doorWantedFrom: lib.doorWantedFrom[t.toLowerAscii] = level
      if faces.len > 0:
        let g = Geometry(pieces: @[Piece()])
        var remap: Table[int32, int32]
        var texs: seq[string]
        for fi in faces:
          var f = geo.faces[fi]
          for v in f.verts.mitems:
            if v notin remap:
              remap[v] = g.points.len.int32
              g.points.add toLocal * geo.points[v]
            v = remap[v]
          f.objectId = -1
          f.piece = 0
          g.faces.add f
          if f.texture notin texs: texs.add f.texture
        let file = fileSafe(tag & "_" & cls) & ".json"
        createDir(dir / "prefabs")
        g.save(dir / "prefabs" / file)
        e["prefab"] = %file
        e["textures"] = %texs
        for t in texs:
          lib.textures.incl t
          let src = levelTexturesDir(level) / t & ".tga"
          if t notin lib.copied and fileExists(src):
            copyFile(src, libraryImages() / t & ".tga")
            lib.copied.incl t
      e["xml"] = %($n)
      lib.entries.add e
  lib.collectDoorOni(work / "oni")
  # Decal textures this level has.
  for t in decalTextures():
    let src = work / "oni" / "TXMP" & t & ".oni"
    if fileExists(src) and not fileExists(libraryOni() / "TXMP" & t & ".oni"):
      copyFile(src, libraryOni() / "TXMP" & t & ".oni")

proc findDoorTextures(lib: Collector, levels: seq[int]) =
  ## The levels' TXMP files door previews still need: from the door's level,
  ## else the first later one that has it (level 0's are looked for after:
  ## shared textures).
  for n in levels:
    if lib.doorWanted.len == 0: return
    for f in walkFiles(levelWork(n) / "oni" / "TXMP*.oni"):
      let key = f.splitFile.name["TXMP".len .. ^1].toLowerAscii
      if key in lib.doorWanted and lib.doorWantedFrom.getOrDefault(key) <= n:
        for t in lib.doorWanted[key]: lib.doorTextures.mgetOrPut(n, @[]).add (f, t)
        lib.doorWanted.del key

proc collectDoorTextures(lib: Collector) =
  for n, list in lib.doorTextures:
    # OniSplit names the images after the instance: TXMP<name>.tga.
    for (f, t) in list:
      let src = levelWork(n) / "doors" / f.splitFile.name & ".tga"
      if fileExists(src) and not fileExists(libraryImages() / t & ".tga"):
        copyFile(src, libraryImages() / t & ".tga")
  lib.doorTextures.clear()

proc needsLevel0Textures(lib: Collector): bool =
  ## Textures the levels lacked, which level 0 may have (not those it was
  ## looked in for already).
  if lib.doorWanted.len > 0 or (lib.doorWantedOni - lib.doorHaveOni - lib.doorMissingOni).len > 0:
    return true
  for t in lib.textures:
    if t notin lib.copied: return true

proc sharedTextures(c: Config, lib: Collector): FileCommand =
  ## Textures prefabs and door previews use that no level had as an image:
  ## level 0's, extracted to l0/tga (no files: none, or level 0 not read).
  let l0 = lib.l0
  result.head = c.oniSplitCmd & @["-extract:tga", l0 / "tga"]
  for _, names in lib.doorWanted:   # No level had them.
    for t in names: lib.textures.incl t
  # Instance names can differ in case from the quads' (TXMPeye for EYE).
  var byLower: Table[string, string]
  for f in walkFiles(l0 / "oni" / "TXMP*.oni"):
    let n = f.splitFile.name["TXMP".len .. ^1]
    byLower[n.toLowerAscii] = n
  for t in lib.textures:
    let n = byLower.getOrDefault(t.toLowerAscii)
    if t notin lib.copied and n.len > 0:
      lib.shared[n] = t
      result.files.add l0 / "oni" / "TXMP" & n & ".oni"

proc writeLibrary(lib: Collector) =
  ## library.json, with the shared textures moved into images/.
  let l0 = lib.l0
  # OniSplit names the images after the instance: TXMP<name>.tga.
  for n, t in lib.shared:
    let f = l0 / "tga" / "TXMP" & n & ".tga"
    if fileExists(f) and not fileExists(libraryImages() / t & ".tga"):
      moveFile(f, libraryImages() / t & ".tga")
  lib.shared.clear()
  if dirExists(l0 / "oni"): lib.collectDoorOni(l0 / "oni")
  # Groups in level order (devices first), entries by name.
  var order: Table[string, int]
  for e in lib.entries:
    let g = e["group"].getStr
    if g notin order: order[g] = (if g.startsWith("Furniture"): 100 else: 0) + order.len
  lib.entries.sort(proc(x, y: JsonNode): int =
    result = cmp(order[x["group"].getStr], order[y["group"].getStr])
    if result == 0: result = cmp(x["label"].getStr.toLowerAscii, y["label"].getStr.toLowerAscii))
  lib.levels.sort
  var doorTextures = toSeq(lib.doorWantedOni)
  doorTextures.sort
  writeFile(libraryFile(), $(%*{"version": LibraryVersion, "levels": lib.levels,
                                "doorTextures": doorTextures, "entries": lib.entries}))
  libraryChanged()
  createDir(thumbDir())
  createDir(modelDir())

proc previewMesh(p: Preset, l0: string): ThumbMesh =
  ## The model a preset's preview shows: library geometry, or the class's
  ## model (from l0/models, or the library's classes/).
  let classes = libraryClassesDir()
  if p.prefab.len > 0:
    result.addGeometry(loadGeometry(p.prefabPath), proc(t: string): string =
      libraryImages() / t & ".tga")
    if p.tag == "CONS" and p.xml.len > 0:
      let n = parseXml(p.xml)
      let screen = classes / "screens" / fileSafe(p.presetClass) & ".dae"
      result.addDae(screen, image = screenImage(n.xpath(consoleState(n)).str.strip))
    return
  let cls = p.presetClass
  let models = l0 / "models"
  proc classXml(file: string): XmlNode =
    if not fileExists(file): return nil
    var s = readFile(file)
    if s.startsWith("\xEF\xBB\xBF"): s = s[3 .. ^1]
    parseXml(s)
  case p.tag
  of "CHAR": result.addDae(models / cls & ".dae", posed = true)
  of "WEAP": result.addDae(models / cls & ".dae")
  of "PWRU": result.addDae(models / PowerUpModels[cls] & ".dae")
  of "TURR":
    # Base, then the arm and the weapon on it, unrotated.
    let x = classXml(classes / "TURR" & cls & ".xml")
    if x == nil: return
    let t = x.child("TURR")
    proc field(tag: string): string = t.xpath(tag).str.strip
    let arm = parseVec3(field("ArmTranslation"))
    result.addDae(classes / field("BaseGeometry"))
    result.addDae(classes / field("ArmGeometry"), arm)
    result.addDae(classes / field("WeaponGeometry"), arm + parseVec3(field("WeaponTranslation")))
  of "DOOR":
    let x = classXml(classes / "DOOR" & cls & ".xml")
    if x == nil: return
    let image = if p.modelTexture.len > 0: libraryImages() / p.modelTexture & ".tga" else: ""
    for g in x.findAll("Geometry"):
      result.addDae(classes / g.innerText.strip, image = image, upright = true)
  else: discard

proc fieldValue(p: Preset, path: string): string =
  for (k, v) in p.fields:
    if k == path: return v

proc renderParticlePreview(p: Preset, l0: string) =
  ## Classes with nothing visible (env_dust_e01) get no preview.
  let layers = particleLayers(l0 / "particles", p.presetClass)
  if layers.len == 0: return
  var aspect = 1'f32   # Decals: OSD/DecalScale "w h".
  let ds = parseVec3(p.fieldValue("OSD/DecalScale") & " 0")
  if ds.x > 0 and ds.y > 0: aspect = ds.x / ds.y
  renderParticleTo(layers, l0 / "ptex", l0 / "models", aspect, p.thumbPath)

proc renderPreview(p: Preset, l0: string) =
  try:
    if p.tag == "PART":
      renderParticlePreview(p, l0)
      return
    let m = previewMesh(p, l0)
    if m.isEmpty: return
    m.renderTo(p.thumbPath)
    # Prefab geometry is in the level already.
    if p.prefab.len == 0 and p.tag in ModelTags:
      m.saveModel(modelDir() / p.thumbKey & ".bin", libraryDir(), modelDir() / "images",
                  libraryImages())
  except CatchableError:
    discard   # No preview: the browser shows the type's color.

proc listPreviews(file: string, onlyLibrary: bool, wanted: proc(p: Preset): bool = nil) =
  ## The previews to render (those wanted), one key a line (see
  ## renderPreviewsCli): each once, and those already rendered not again.
  var keys: seq[string]
  var seen: HashSet[string]
  for p in (if onlyLibrary: loadLibrary() else: builtinPresets() & loadLibrary()):
    let k = p.thumbKey
    if k.len == 0 or k in seen or fileExists(p.thumbPath): continue
    if wanted != nil and not wanted(p): continue
    seen.incl k
    keys.add k
  writeFile(file, keys.join("\n"))

proc renderPreviewsCli*(args: seq[string]) =
  ## catwalk --render-previews <level 0 folder> <list> <part> <parts>: renders
  ## the part-th share of the previews the list names, so that the library
  ## build renders them in several processes at once.
  if args.len < 4: quit "usage: --render-previews <level 0 folder> <list> <part> <parts>", 2
  let (l0, part, parts) = (args[0], parseInt(args[2]), parseInt(args[3]))
  var mine: HashSet[string]
  let keys = readFile(args[1]).splitLines
  for i, k in keys:
    if k.len > 0 and i mod parts == part: mine.incl k
  var done: HashSet[string]
  for p in builtinPresets() & loadLibrary():
    let k = p.thumbKey
    if k in mine and k notin done:
      done.incl k
      renderPreview(p, l0)

var previewRenderer* = @[getAppFilename(), "--render-previews"]
  ## The command that runs renderPreviewsCli (a test program sets its own).

proc levelExport(c: Config, n: int): FileCommand =
  (c.oniSplitCmd & @["-export", levelWork(n) / "oni", c.gameData / "level" & $n & "_Final.dat"],
   newSeq[string]())

proc levelExtracts(c: Config, n: int): seq[FileCommand] =
  ## What a level's classes need from its export: its geometry and objects as
  ## XML, and its textures (unless its Texture Collection has them).
  let lw = levelWork(n)
  var xml = (head: c.oniSplitCmd & @["-extract:xml", lw / "xml"], files: newSeq[string]())
  for f in walkFiles(lw / "oni" / "AKEV*.oni"): xml.files.add f
  for (_, fileName) in LibraryTypes:
    let f = lw / "oni" / "BINACJBO" & fileName & ".oni"
    if fileExists(f): xml.files.add f
  if xml.files.len > 0: result.add xml
  if not levelTexturesReady(n):
    var dae = (head: c.oniSplitCmd & @["-extract:dae", lw / "env"], files: newSeq[string]())
    for f in walkFiles(lw / "oni" / "AKEV*.oni"): dae.files.add f
    if dae.files.len > 0: result.add dae

proc doorTextureExtracts(c: Config, lib: Collector): seq[FileCommand] =
  for n, list in lib.doorTextures:
    var t = (head: c.oniSplitCmd & @["-extract:tga", levelWork(n) / "doors"], files: newSeq[string]())
    for (f, _) in list: t.files.add f
    result.add t

proc addIf(tasks: var seq[FileCommand], t: FileCommand) =
  ## t, if it has files to work on.
  if t.files.len > 0: tasks.add t

proc trashDir(): string = libraryDir().parentDir

proc removeInBackground(dir: string) =
  ## Starts removing dir in another process: thousands of files take seconds.
  try:
    when defined(windows):
      let p = startProcess(getEnv("ComSpec", "cmd.exe"), args = ["/d", "/c", "rd", "/s", "/q", dir],
                           options = {poDaemon})
    else:
      let p = startProcess("rm", args = ["-rf", dir], options = {poUsePath})
    p.close()
  except OSError:
    try: removeDir(dir)
    except OSError: discard

proc removeLater(dir: string) =
  ## Moves dir out of the way and removes it in the background. What a
  ## Catwalk that quit first left behind goes with the next build.
  if not dirExists(dir): return
  let trash = trashDir() / "trash-" & $getCurrentProcessId() & "-" & $int(epochTime() * 1000)
  try: moveDir(dir, trash)
  except OSError:
    removeDir(dir)
    return
  removeInBackground(trash)

proc lockSteps(): Step =
  action("Preparing", proc() =
    # Two builds in one folder break each other.
    if libraryBusyElsewhere():
      raise newException(IOError, "another Catwalk is building the entity library")
    createDir(lockPath().parentDir)
    writeFile(lockPath(), $getCurrentProcessId())
    for kind, d in walkDir(trashDir()):
      if kind == pcDir and d.lastPathPart.startsWith("trash-"): removeInBackground(d))

proc levelNodes(c: Config, lib: Collector, n: int, after: seq[string]): seq[Node] =
  ## Reading, extracting and collecting level n; collecting comes after the
  ## after nodes too. Its own proc so each level's closures have their own n.
  @[commandsNode("read " & $n, [], "Reading level " & $n, proc(): seq[FileCommand] =
      @[c.levelExport(n)]),
    commandsNode("extract " & $n, ["read " & $n], "Extracting level " & $n, proc(): seq[FileCommand] =
      c.levelExtracts(n)),
    actionNode("collect " & $n, @["extract " & $n] & after, "Collecting level " & $n, proc() =
      lib.collectLevel(n))]

proc levelsNodes(c: Config, lib: Collector, levels: seq[int], after: seq[string]): seq[Node] =
  ## The levels', collected in order: a class goes to the first level with it.
  var prev: seq[string]
  for n in levels:
    result.add c.levelNodes(lib, n, after & prev)
    prev = @["collect " & $n]

proc previewNodes(l0, name: string, onlyLibrary: bool, after: seq[string],
                  wanted: proc(p: Preset): bool = nil): seq[Node] =
  ## The previews not rendered yet (onlyLibrary: of the library's entries,
  ## those of the levels just added; wanted: those it takes), in as many
  ## processes as there are processors. Nodes "list <name>" and name.
  let list = libraryDir() / "work" / name & ".txt"
  @[actionNode("list " & name, after, "Listing previews", proc() = listPreviews(list, onlyLibrary, wanted)),
    commandsNode(name, ["list " & name], "Rendering previews", proc(): seq[FileCommand] =
      let n = max(1, countProcessors())
      for k in 0 ..< n:
        result.add (previewRenderer & @[l0, list, $k, $n], newSeq[string]()))]

proc firstLevels(c: Config): seq[int] =
  ## The levels a full build takes: FirstLevels, and those whose Texture
  ## Collection is extracted (a project has used them).
  let have = c.gameLevels
  for n in have:
    if n in FirstLevels or levelTexturesReady(n): result.add n
  if result.len == 0 and have.len > 0: result.add have[0]

proc libraryJob*(c: Config, logPath: string, onDone: proc()): Job =
  ## Reads level 0 (classes, models, textures) and the first levels, takes the
  ## levels' classes, then fills in what only level 0 has, each piece as soon
  ## as what it needs is there. More levels come with addLevelsJob.
  let dir = libraryDir()
  let work = dir / "work"
  let l0 = work / "0"
  let lib = Collector(l0: l0)
  let levels = c.firstLevels
  let dat0 = c.gameData / "level0_Final.dat"
  proc oniSplit(args: varargs[string]): seq[FileCommand] =
    @[(c.oniSplitCmd & @args, newSeq[string]())]
  proc export0(t: string, urgent = false, own = false): Node =
    commandsNode("l0 " & t, [], "Reading level 0's " & t, proc(): seq[FileCommand] =
      oniSplit("-export:" & t, (if own: l0 / t else: l0 / "oni"), dat0), urgent)
  proc decals(n: int): Node =
    # After the big reads, which the rest waits for more.
    commandsNode("decals " & $n, ["l0 TXMP", "l0 BINA"], "Reading level " & $n & "'s decal textures",
      proc(): seq[FileCommand] =
        oniSplit("-export:TXMP", work / "decals" / $n, c.gameData / "level" & $n & "_Final.dat"))
  # Models straight from the .dat, one OniSplit (single-threaded) for all:
  # it poses characters with their animations without 2,600 TRAM files
  # written first, which is faster than exporting those and extracting the
  # models in parts. The longest piece: the others give way to it.
  var nodes = @[commandsNode("models", [], "Extracting models", proc(): seq[FileCommand] =
    oniSplit("-extract:dae", l0 / "models", dat0), urgent = true)]
  for t in Level0Types: nodes.add export0(t)
  for t in OwnFolderTypes: nodes.add export0(t, own = true)
  nodes.add actionNode("l0 classes", ["l0 DOOR", "l0 CONS", "l0 TXMP"], "Collecting door and console classes",
    proc() =
      for t in OwnFolderTypes: mergeInto(l0 / t, l0 / "oni"))
  nodes.add c.levelsNodes(lib, levels, @["door classes"])
  if levels.len == 0: raise newException(IOError, "no game levels in " & c.gameData)
  let collected = "collect " & $levels[^1]
  var decalNodes: seq[string]
  for n in DecalLevels:
    if n notin levels and n in c.gameLevels:
      nodes.add decals(n)
      decalNodes.add "decals " & $n
  nodes.add @[
    actionNode("door classes", ["l0 classes", "l0 OBAN"], "Collecting door classes", proc() =
      lib.collectDoorClasses()),
    actionNode("decals", decalNodes, "Collecting decal textures", proc() =
      for t in decalTextures():
        for k, d in walkDir(work / "decals"):
          let src = d / "TXMP" & t & ".oni"
          if fileExists(src) and not fileExists(libraryOni() / "TXMP" & t & ".oni"):
            copyFile(src, libraryOni() / "TXMP" & t & ".oni")),
    # OniSplit expands the patterns (921 particle paths are too long for one command).
    commandsNode("particles", ["l0 BINA"], "Extracting particle classes", proc(): seq[FileCommand] =
      oniSplit("-extract:xml", l0 / "particles", l0 / "oni" / "BINA3RAP*.oni")),
    commandsNode("classes", ["l0 TURR", "l0 classes", "l0 M3GM"], "Extracting turret and door models",
      proc(): seq[FileCommand] =
        oniSplit("-extract:xml", libraryClassesDir(), l0 / "oni" / "TURR*.oni") &
          oniSplit("-extract:xml", libraryClassesDir(), l0 / "oni" / "DOOR*.oni")),
    commandsNode("consoles", ["l0 classes", "l0 M3GM"], "Extracting consoles", proc(): seq[FileCommand] =
      oniSplit("-extract:xml", l0 / "consoles", l0 / "oni" / "CONS*.oni") &
        oniSplit("-extract:tga", l0 / "screens", l0 / "oni" / "TXMP_CON_*.oni")),
    actionNode("particle textures", ["particles"], "Finding what particles show", proc() =
      for p in builtinPresets():
        if p.tag != "PART": continue
        let layers = particleLayers(l0 / "particles", p.presetClass)
        for t in layers.particleTextures:
          if t notin lib.particleTextures: lib.particleTextures.add t
        if layers.particleGeometry.len > 0: lib.modelParticles.incl p.presetClass),
    commandsNode("ptex", ["particle textures", "l0 TXMP", "decals", collected], "Extracting particle textures",
      proc(): seq[FileCommand] =
        # Level 0's, or the decal textures the library keeps.
        var ptex = (head: c.oniSplitCmd & @["-extract:xml", l0 / "ptex"], files: newSeq[string]())
        for t in lib.particleTextures:
          for f in [l0 / "oni" / "TXMP" & t & ".oni", libraryOni() / "TXMP" & t & ".oni"]:
            if fileExists(f):
              ptex.files.add f
              break
        result.addIf ptex),
    actionNode("door textures", [collected, "l0 TXMP"], "Finding door textures", proc() =
      lib.findDoorTextures(levels)),
    commandsNode("textures", ["door textures"], "Extracting door and shared textures", proc(): seq[FileCommand] =
      result = c.doorTextureExtracts(lib)
      result.addIf c.sharedTextures(lib)),
    actionNode("write", ["textures"], "Writing library", proc() =
      lib.collectDoorTextures()
      lib.writeLibrary()),
    actionNode("env maps", ["l0 TXMP"], "Finding reflective textures", proc() =
      lib.envMapped = envMappedImages(l0 / "oni")),
    actionNode("opaque", ["models", "env maps"], "Making reflective textures opaque", proc() =
      for f in walkFiles(l0 / "models" / "images" / "*.tga"):
        if f.extractFilename.toLowerAscii notin lib.envMapped: continue
        var data = readFile(f)
        makeOpaque(data)
        writeFile(f, data)),
    actionNode("screens", ["consoles", "write"], "Saving console screens", proc() =
      # Each class's ScreenGeometry, for the map views and the previews.
      let screens = libraryClassesDir() / "screens"
      createDir(screens)
      for f in walkFiles(l0 / "consoles" / "CONS*.xml"):
        let cls = f.splitFile.name["CONS".len .. ^1]
        var s = readFile(f)
        if s.startsWith("\xEF\xBB\xBF"): s = s[3 .. ^1]
        let dae = parseXml(s).child("CONS").xpath("ScreenGeometry").str.strip
        if dae.len == 0: continue
        copyFile(l0 / "consoles" / dae, screens / fileSafe(cls) & ".dae")
        var m: ThumbMesh
        m.addDae(l0 / "consoles" / dae)
        if not m.isEmpty:
          m.saveModel(modelDir() / fileSafe("CONS_" & cls & "_screen") & ".bin", libraryDir(),
                      modelDir() / "images", libraryImages())
      # OniSplit names the images after the instance: TXMP_CON_WH1.tga.
      createDir(screenDir())
      for f in walkFiles(l0 / "screens" / "TXMP*.tga"):
        let name = f.splitFile.name["TXMP".len .. ^1].toLowerAscii
        moveFile(f, screenDir() / name & ".tga"))]
  # The previews of models from the .dat after it, the others while it runs.
  proc needsModels(p: Preset): bool =
    p.tag in ["CHAR", "WEAP", "PWRU"] or (p.tag == "PART" and p.presetClass in lib.modelParticles)
  nodes.add previewNodes(l0, "previews", onlyLibrary = false, @["write", "screens", "ptex", "classes"],
                         proc(p: Preset): bool = not needsModels(p))
  nodes.add previewNodes(l0, "model previews", onlyLibrary = false, @["write", "ptex", "opaque"],
                         needsModels)
  newJob("Building the entity library", logPath, @[
    lockSteps(),
    action("Clearing the library", proc() =
      removeLater(dir)
      libraryChanged()
      for d in [dir, libraryImages(), libraryOni(), libraryClassesDir(), work, l0 / "oni"]: createDir(d)),
    graph("Building the entity library", nodes),
    action("Cleaning up", proc() =
      removeLater(work)
      writeFile(thumbDir() / "version", $PreviewVersion)
      libraryChanged()
      removeFile(lockPath())),
    action("Done", onDone)])

proc addLevelsJob*(c: Config, levels: seq[int], logPath: string, onDone: proc()): Job =
  ## Extracts game levels' textures for their Texture Collections and adds
  ## their classes to the built library (see libraryBuilt), with previews.
  let work = libraryDir() / "work"
  let l0 = work / "0"
  let lib = Collector(l0: l0)
  let names = levels.mapIt($it).join(", ")
  let collected = "collect " & $levels[^1]
  var nodes = c.levelsNodes(lib, levels, @[])
  nodes.add @[
    actionNode("door textures", [collected], "Finding door textures", proc() =
      lib.findDoorTextures(levels)),
    commandsNode("l0 TXMP", ["door textures"], "Reading level 0's textures", proc(): seq[FileCommand] =
      if lib.needsLevel0Textures:
        result.add (c.oniSplitCmd & @["-export:TXMP", l0 / "oni", c.gameData / "level0_Final.dat"],
                    newSeq[string]())),
    commandsNode("textures", ["l0 TXMP"], "Extracting door and shared textures", proc(): seq[FileCommand] =
      result = c.doorTextureExtracts(lib)
      result.addIf c.sharedTextures(lib)),
    actionNode("write", ["textures"], "Writing library", proc() =
      lib.collectDoorTextures()
      lib.writeLibrary())]
  nodes.add previewNodes(l0, "previews", onlyLibrary = true, @["write"])
  newJob("Adding level " & names & " to the entity library", logPath, @[
    lockSteps(),
    action("Reading the library", proc() =
      lib[] = loadCollector(l0)[]
      removeLater(work)
      createDir(work)),
    graph("Adding level " & names, nodes),
    action("Cleaning up", proc() =
      removeLater(work)
      # A new time: the views read the models again (modelsChanged).
      writeFile(thumbDir() / "version", $PreviewVersion)
      libraryChanged()
      removeFile(lockPath())),
    action("Done", onDone)])
