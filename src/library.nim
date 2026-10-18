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
## Built once from the game files into ~/.local/share/catwalk/library/:
##   library.json        the entries
##   prefabs/*.json      geometry (Catwalk's geometry.json format)
##   images/*.tga        textures the prefabs use
##   oni/TXMP*.oni       level textures decals need (see presets.DecalTextures)
##   thumbs/*.png        entity browser previews (see thumbKey)
##   models/*.bin        the models previews show, for the map views (see objectModel)

import std/[os, json, xmltree, xmlparser, strutils, tables, sets, algorithm, times, uri]
import vmath
import jobs, project, geometry, geomops, levelobjects, objtemplates, presets, thumbs, particles, tga

const
  LibraryVersion = 2
  ## Object types the library takes, with the object file OniSplit names after them.
  LibraryTypes = [("FURN", "Furniture"), ("CONS", "Console"), ("DOOR", "Door"), ("TRIG", "Trigger")]
  LevelTitles = {"EnvWarehouse": "Warehouse", "manplant": "Manufacturing plant",
    "lab": "Research lab", "Airport": "Airport", "Airport_III": "Airport hangars",
    "tctf": "TCTF headquarters", "power": "Power plant", "power_II": "Power plant II",
    "state": "State building", "roof": "Rooftops", "dream_lab": "Dream lab",
    "neuro": "Neuro lab", "tctf_II": "TCTF headquarters II", "compound": "Mountain compound"}.toTable

proc libraryDir*(): string =
  let xdg = getEnv("XDG_DATA_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".local/share") / "catwalk" / "library"

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

proc hasLibrary*(): bool = fileExists(libraryFile())

proc lockPath(): string = libraryDir().parentDir / "library.lock"

proc libraryBusyElsewhere*(): bool =
  ## Another running Catwalk is building the library (it holds the lock).
  try:
    let pid = readFile(lockPath()).strip.parseInt
    pid != getCurrentProcessId() and dirExists("/proc/" & $pid)
  except CatchableError: false

const PreviewVersion = 4   ## Bump when previews should be rendered again (2: particles, 3: models, 4: env-mapped textures opaque).

proc hasPreviews*(): bool =
  ## The library has a complete set of model previews from this version.
  try: readFile(libraryDir() / "thumbs" / "version").strip == $PreviewVersion
  except IOError: false

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
  ## Library entries by the number of preview-rendering steps.
  PreviewSteps = 48

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

proc clearModelCache*() = modelBoundsCache.clear()

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

type Collector = ref object
  entries: seq[JsonNode]
  seen: HashSet[string]           ## tag/class already taken
  textures: HashSet[string]       ## textures prefabs use
  copied: HashSet[string]         ## textures in images/
  shared: Table[string, string]   ## level 0 TXMP name -> texture it provides
  l0: string                      ## Level 0's export (door classes).
  doorWanted: Table[string, HashSet[string]]  ## Door preview textures not found yet: lower case -> names.
  doorTextures: seq[(string, string)]  ## This level's TXMP files door previews need, and texture names.
  previews: seq[Preset]           ## Presets to render previews of.
  particleTextures: seq[string]   ## TXMPs particle previews show.
  particleGeometry: seq[string]   ## M3GMs particle previews show.

proc classTexture(file: string): string =
  ## The texture a door class's model links to, by name ("" if unknown):
  ## the first "TXMP<name>" string in its .oni file.
  if not fileExists(file): return
  let data = readFile(file)
  var i = data.find("TXMP")
  if i < 0: return
  i += 4
  while i < data.len and data[i] in {' ' .. '~'}:
    result.add data[i]
    inc i

proc collectLevel(lib: Collector, work: string) =
  ## Takes every class not in the library yet from one exported level.
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
        # level content, not always in this level; see the end of this proc.
        var t = n.xpath("OSD/Texture1").str.strip
        if t.len == 0: t = classTexture(lib.l0 / "oni" / "DOOR" & cls & ".oni")
        if t.len > 0:
          e["modelTexture"] = %t
          if not fileExists(libraryImages() / t & ".tga"):
            lib.doorWanted.mgetOrPut(t.toLowerAscii, initHashSet[string]()).incl t
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
          let src = work / "env" / "images" / t & ".tga"
          if t notin lib.copied and fileExists(src):
            copyFile(src, libraryImages() / t & ".tga")
            lib.copied.incl t
      e["xml"] = %($n)
      lib.entries.add e
  # Door textures this level has.
  if lib.doorWanted.len > 0:
    for f in walkFiles(work / "oni" / "TXMP*.oni"):
      let key = f.splitFile.name["TXMP".len .. ^1].toLowerAscii
      if key in lib.doorWanted:
        for t in lib.doorWanted[key]: lib.doorTextures.add (f, t)
        lib.doorWanted.del key
  # Decal textures this level has.
  for t in decalTextures():
    let src = work / "oni" / "TXMP" & t & ".oni"
    if fileExists(src) and not fileExists(libraryOni() / "TXMP" & t & ".oni"):
      copyFile(src, libraryOni() / "TXMP" & t & ".oni")

proc levelSteps(c: Config, lib: Collector, n: int, lw: string): seq[Step] =
  ## Its own proc so each level's closures capture their own n and folder.
  let dat = c.gameData / "level" & $n & "_Final.dat"
  @[
    command("Reading level " & $n, proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", lw / "oni", dat]),
    command("Extracting level " & $n, proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", lw / "xml"]
      for f in walkFiles(lw / "oni" / "AKEV*.oni"): result.add f
      for (_, fileName) in LibraryTypes:
        let f = lw / "oni" / "BINACJBO" & fileName & ".oni"
        if fileExists(f): result.add f),
    command("Extracting textures of level " & $n, proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:dae", lw / "env"]
      for f in walkFiles(lw / "oni" / "AKEV*.oni"): result.add f),
    action("Collecting level " & $n, proc() = lib.collectLevel(lw)),
    command("Extracting door textures of level " & $n, proc(): seq[string] =
      if lib.doorTextures.len == 0: return @["true"]
      result = @[c.mono, c.oniSplit, "-extract:tga", lw / "doors"]
      for (f, _) in lib.doorTextures: result.add f),
    action("Collecting door textures of level " & $n, proc() =
      # OniSplit names the images after the instance: TXMP<name>.tga.
      for (f, t) in lib.doorTextures:
        let src = lw / "doors" / f.splitFile.name & ".tga"
        if fileExists(src) and not fileExists(libraryImages() / t & ".tga"):
          copyFile(src, libraryImages() / t & ".tga")
      lib.doorTextures.setLen 0
      removeDir(lw))]

proc previewMesh(p: Preset, l0: string): ThumbMesh =
  ## The model a preset's preview shows: library geometry, or the class's
  ## model from level 0 (extracted to l0/models and l0/classes).
  if p.prefab.len > 0:
    result.addGeometry(loadGeometry(p.prefabPath), proc(t: string): string =
      libraryImages() / t & ".tga")
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
    let x = classXml(l0 / "classes" / "TURR" & cls & ".xml")
    if x == nil: return
    let t = x.child("TURR")
    proc field(tag: string): string = t.xpath(tag).str.strip
    let arm = parseVec3(field("ArmTranslation"))
    result.addDae(l0 / "classes" / field("BaseGeometry"))
    result.addDae(l0 / "classes" / field("ArmGeometry"), arm)
    result.addDae(l0 / "classes" / field("WeaponGeometry"), arm + parseVec3(field("WeaponTranslation")))
  of "DOOR":
    let x = classXml(l0 / "classes" / "DOOR" & cls & ".xml")
    if x == nil: return
    let image = if p.modelTexture.len > 0: libraryImages() / p.modelTexture & ".tga" else: ""
    for g in x.findAll("Geometry"):
      result.addDae(l0 / "classes" / g.innerText.strip, image = image, upright = true)
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

proc renderPreviews(lib: Collector, l0: string, part: int) =
  ## One of PreviewSteps slices of the previews.
  let n = lib.previews.len
  for i in n * part div PreviewSteps ..< n * (part + 1) div PreviewSteps:
    let p = lib.previews[i]
    try:
      if p.tag == "PART":
        renderParticlePreview(p, l0)
        continue
      let m = previewMesh(p, l0)
      if m.isEmpty: continue
      m.renderTo(p.thumbPath)
      # Prefab geometry is in the level already.
      if p.prefab.len == 0 and p.tag in ModelTags:
        m.saveModel(modelDir() / p.thumbKey & ".bin", libraryDir(), modelDir() / "images",
                    libraryImages())
    except CatchableError:
      discard   # No preview: the browser shows the type's color.

proc previewStep(lib: Collector, l0: string, part: int): Step =
  ## Its own proc so each step's closure captures its own part.
  action("Rendering previews", proc() = lib.renderPreviews(l0, part))

proc libraryJob*(c: Config, logPath: string, onDone: proc()): Job =
  ## Exports each original level, takes its classes, then fills in textures
  ## that only level 0 has. The work folders are removed as it goes.
  let dir = libraryDir()
  let work = dir / "work"
  let l0 = work / "0"
  let lib = Collector(l0: l0)
  var steps = @[
    action("Preparing", proc() =
      # Two builds in one folder break each other.
      if libraryBusyElsewhere():
        raise newException(IOError, "another Catwalk is building the entity library")
      createDir(lockPath().parentDir)
      writeFile(lockPath(), $getCurrentProcessId())
      if dirExists(dir): removeDir(dir)
      for d in [dir, libraryImages(), libraryOni(), work]: createDir(d)),
    # First: the levels' door objects need their classes.
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", l0 / "oni", c.gameData / "level0_Final.dat"])]
  for n in c.gameLevels: steps.add levelSteps(c, lib, n, work / $n)
  # Textures prefabs use that no level had as an image: level 0's.
  steps.add @[
    command("Extracting shared textures", proc(): seq[string] =
      # Instance names can differ in case from the quads' (TXMPeye for EYE).
      result = @[c.mono, c.oniSplit, "-extract:tga", l0 / "tga"]
      for _, names in lib.doorWanted:   # No level had them.
        for t in names: lib.textures.incl t
      var byLower: Table[string, string]
      for f in walkFiles(l0 / "oni" / "TXMP*.oni"):
        let n = f.splitFile.name["TXMP".len .. ^1]
        byLower[n.toLowerAscii] = n
      for t in lib.textures:
        let n = byLower.getOrDefault(t.toLowerAscii)
        if t notin lib.copied and n.len > 0:
          lib.shared[n] = t
          result.add l0 / "oni" / "TXMP" & n & ".oni"
      if result.len == 4: result = @["true"]),
    action("Writing library", proc() =
      # OniSplit names the images after the instance: TXMP<name>.tga.
      for n, t in lib.shared:
        let f = l0 / "tga" / "TXMP" & n & ".tga"
        if fileExists(f): moveFile(f, libraryImages() / t & ".tga")
      # Groups in level order (devices first), entries by name.
      var order: Table[string, int]
      for e in lib.entries:
        let g = e["group"].getStr
        if g notin order: order[g] = (if g.startsWith("Furniture"): 100 else: 0) + order.len
      lib.entries.sort(proc(x, y: JsonNode): int =
        result = cmp(order[x["group"].getStr], order[y["group"].getStr])
        if result == 0: result = cmp(x["label"].getStr.toLowerAscii, y["label"].getStr.toLowerAscii))
      writeFile(libraryFile(), $(%*{"version": LibraryVersion, "entries": lib.entries}))
      createDir(thumbDir())
      createDir(modelDir())
      for p in builtinPresets() & loadLibrary():
        if p.thumbKey.len > 0: lib.previews.add p),
    command("Extracting particle classes", proc(): seq[string] =
      # OniSplit expands the pattern (921 paths are too long for one command).
      @[c.mono, c.oniSplit, "-extract:xml", l0 / "particles", l0 / "oni" / "BINA3RAP*.oni"]),
    action("Finding what particles show", proc() =
      for p in lib.previews:
        if p.tag != "PART": continue
        let layers = particleLayers(l0 / "particles", p.presetClass)
        for t in layers.particleTextures:
          if t notin lib.particleTextures: lib.particleTextures.add t
        for g in layers.particleGeometry:
          if g notin lib.particleGeometry: lib.particleGeometry.add g),
    command("Extracting particle textures", proc(): seq[string] =
      # Level 0's, or the decal textures the library keeps.
      result = @[c.mono, c.oniSplit, "-extract:xml", l0 / "ptex"]
      for t in lib.particleTextures:
        for f in [l0 / "oni" / "TXMP" & t & ".oni", libraryOni() / "TXMP" & t & ".oni"]:
          if fileExists(f):
            result.add f
            break
      if result.len == 4: result = @["true"]),
    command("Extracting character, weapon, power-up and particle models", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:dae", l0 / "models"]
      for p in lib.previews:
        let cls = p.presetClass
        let f = case p.tag
          of "CHAR": "ONCC" & cls
          of "WEAP": "ONWC" & cls
          of "PWRU": "M3GM" & PowerUpModels[cls]
          else: ""
        if f.len > 0 and fileExists(l0 / "oni" / f & ".oni"): result.add l0 / "oni" / f & ".oni"
      for g in lib.particleGeometry:
        if fileExists(l0 / "oni" / "M3GM" & g & ".oni"): result.add l0 / "oni" / "M3GM" & g & ".oni"),
    action("Making reflective textures opaque", proc() =
      let envMapped = envMappedImages(l0 / "oni")
      for f in walkFiles(l0 / "models" / "images" / "*.tga"):
        if f.extractFilename.toLowerAscii notin envMapped: continue
        var data = readFile(f)
        makeOpaque(data)
        writeFile(f, data)),
    command("Extracting turret and door models", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", l0 / "classes"]
      for p in lib.previews:
        let f = l0 / "oni" / p.tag & p.presetClass & ".oni"
        if p.tag in ["TURR", "DOOR"] and fileExists(f): result.add f)]
  for part in 0 ..< PreviewSteps:
    steps.add previewStep(lib, l0, part)
  steps.add @[
    action("Cleaning up", proc() =
      removeDir(work)
      writeFile(thumbDir() / "version", $PreviewVersion)
      removeFile(lockPath())),
    action("Done", onDone)]
  newJob("Building the entity library", logPath, steps)
