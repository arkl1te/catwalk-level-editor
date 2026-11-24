## The Scripts panel (included by panels.nim): a code editor for the level's
## BSL files (IGMD/<env>/*.bsl). Highlighting and checks follow what Oni's
## script reader accepts (bslparse.nim) and the commands and variables the
## player's Oni.exe defines (bsldefs.nim). Typing a word lists what fits there
## (Ctrl+Space asks), with the argument a command expects shown above the line;
## hovering a word says what it is. Names of the level's objects are drawn in
## their type's color: Ctrl+click one to select it (Properties, its Map row and
## the views go to it); Ctrl+click (or F12) a function or variable goes to its
## declaration, and on a declaration lists its uses in every script file (and
## the objects calling a function) to jump to; Shift+F12 lists them from a use.
## Hovering a declaration lists its uses; hovering a game command or variable
## shows a line of the game's own scripts using it, and the level it's from.
## Ctrl+click on a sound's name opens it in the sound player (drawMini).
## Ctrl+wheel changes the text size (Ctrl+0 puts it back).

import bsldefs, bslparse, scriptedit

const
  ScriptTabsH = 26'f32
  ScriptStatusH = 22'f32
  FindBarH = 32'f32
  TabCols = 4                     ## A tab's width in columns.
  CompRows = 10
  EditorId = "scripts.edit"

proc hexCol(s: string): ColorRGBX = parseHtmlColor(s).rgbx

let
  colCodeKeyword = hexCol("#c792ea")
  colCodeType = hexCol("#89ddff")
  colCodeCommand = hexCol("#82aaff")
  colCodeEngineVar = hexCol("#f78c6c")
  colCodeFunc = hexCol("#ffcb6b")
  colCodeGlobal = hexCol("#f07178")
  colCodeLocal = hexCol("#d7c4ff")
  colCodeNumber = hexCol("#f78c6c")
  colCodeString = hexCol("#c3e88d")
  colCodeComment = hexCol("#6b7280")
  colCodePunct = hexCol("#a6accd")
  colCodeLineNo = hexCol("#4b5060")
  colCodePartTag = rgbx(255, 110, 255, 255)   ## A tag particles have: the particle marker color (appstate.look).
  colCodePartCommand = hexCol("#7fdbca")      ## particle tag create / kill / reset / do.
  colCodePartEvent = hexCol("#f5b8ff")        ## particle tag [do] start / stop / explode...
  colWarn = hexCol("#ffc857")
  # The chosen row of the completion and uses lists: the accent at 10% over
  # colPopup, dark enough that every code color and the dim text on it keep
  # 4.5:1 contrast (trigger red: 4.1), marked by an accent bar and outline.
  colListHi = hexCol("#2b303e")
  colListHiEdge = hexCol("#576a95")
  colTipBg = hexCol("#17181c")          ## Hover tips: darker than the other popups.
  colTipWhere = hexCol("#a8c4ff")       ## In them: where something is.

type ObjIndex = object
  names: Table[string, seq[LevelObject]]   ## Lowercase name or tag -> objects.
  ids: Table[string, LevelObject]          ## "DOOR 15" -> the door.

var
  objIdx: ObjIndex
  objIdxAt = -1.0
  bufDecls: Table[string, (int, seq[Decl])]   ## Open buffers' declarations, by version.
  editorArea: Rect                            ## The text area, as last drawn.
  revealCaret: bool                           ## Scroll the caret into view next draw.
  scrollToLine = -1                           ## Bring this line of scrollFor into view next draw.
  scrollFor: ScriptBuffer
  # A jump scrolls there smoothly (ScrollAnimTime), so it doesn't look like
  # another file opened. setY: the value it last gave; anything else moved
  # the text since (the wheel, the scrollbar), which ends it.
  scrollAnim: tuple[buf: ScriptBuffer, fromY, toY, setY: float32, start: float]
  # The ) a function taken from the list got, while the caret stays on its
  # line: typing ) there steps over it, Backspace in an empty () takes both.
  # fromEnd: its distance from the line's end (typing inside the parentheses
  # doesn't change it).
  autoClose: tuple[buf: ScriptBuffer, line, fromEnd: int]

  defsSaid: bool
  scriptPopups: seq[proc()]                   ## Drawn after the panels, outside their clips.
  escTaken: bool                              ## This frame's Esc closed the find bar: the editor keeps the keyboard.
  caretTipDrawn: bool                         ## The tip at the caret showed last frame.
  editorDrawnAt: float                        ## When the text area was last drawn (the status bar's hints).

const ScrollAnimTime = 0.1    ## Seconds a jump takes to scroll there.

const RefTags: array[RefKind, string] = ["", "CHAR", "TRGV", "PATR", "NEUT", "PART",
  "FLAG", "DOOR", "CONS", "TRIG", "TURR", "TRGV", "", "", ""]

proc objName(o: LevelObject): string =
  ## The name scripts call an object by: a character's, trigger volume's,
  ## patrol path's or neutral's Name, a particle's Tag.
  case o.tag
  of "CHAR", "TRGV", "PATR", "NEUT": o.node.xpath("OSD/Name").str.strip
  of "PART": o.node.xpath("OSD/Tag").str.strip
  else: ""

proc objectIndex(a: App): ObjIndex =
  let now = epochTime()
  if now - objIdxAt < 0.3: return objIdx
  objIdxAt = now
  objIdx = ObjIndex()
  for o in a.objects:
    let n = o.objName
    if n.len > 0: objIdx.names.mgetOrPut(n.toLowerAscii, @[]).add o
    let f = ScriptIdFields.getOrDefault(o.tag)
    if f.len > 0:
      let id = o.node.xpath(f).str.strip
      if id.len > 0 and (o.tag & " " & id) notin objIdx.ids: objIdx.ids[o.tag & " " & id] = o
  objIdx

# --- particle tags ---------------------------------------------------------------------------
#
# `particle tag ...` reaches every particle with that tag (EPrEnumerateByTag, exact
# strcmp): PART objects (their OSD/Tag), and the level's own particles, which the
# ONLV's ENVP array holds: retail furniture is gunk, so the particles of its
# geometry were baked there, tagged "<the furniture's Particle>_<their own tag>"
# (OT_Furniture.c). Those have no object in Catwalk, only a class and a place.

type
  EnvParticle = tuple[cls, tag: string, pos: Vec3]
  PartTargets = object
    parts: seq[LevelObject]     ## PART objects with the tag.
    envs: seq[EnvParticle]      ## The level's own particles with it.
    furn: seq[LevelObject]      ## Furniture whose Particle prefixes the tag ("lock_1" for lock_1_locklight01).
    caseOf: string              ## Nothing has the tag, but this one differs only in case.

var
  envParts: tuple[path: string, stamp: Time, list: seq[EnvParticle]]
  envPartsAt = -1.0
  partIdx: tuple[at: float, tags: Table[string, seq[LevelObject]], furn: seq[(string, LevelObject)]]

const ParticleCommandDocs = {
  "create": "Creates the particles with the tag: ones killed, or not created when the level started (their Not initially created flag).",
  "kill": "Removes the particles with the tag (create brings them back).",
  "reset": "Kills the particles with the tag and creates them again, as the level started them: ones flagged Not initially created stay gone.",
  "do": "Sends the event after it to the particles with the tag: particle tag do start. Writing the event alone does the same."}.toTable

proc levelEnvParticles(a: App): seq[EnvParticle] =
  ## The ENVP array of the project's ONLV*.oni (none in a level made from
  ## scratch). Records of 208 bytes after 32 (instance id, 22 pad, u16 count):
  ## class [64], tag [48], a 4x3 matrix (position last), decal scale, flags.
  if a.proj == nil: return
  let now = epochTime()
  if now - envPartsAt < 1.0: return envParts.list
  envPartsAt = now
  var path = ""
  for f in walkFiles(a.proj.oniDir / "ONLV*.oni"):
    path = f
    break
  if path.len == 0:
    envParts = ("", Time(), @[])
    return
  var stamp: Time
  try: stamp = getLastModificationTime(path)
  except OSError: return
  if path == envParts.path and stamp == envParts.stamp: return envParts.list
  envParts = (path, stamp, @[])
  var d: string
  try: d = readFile(path)
  except IOError: return
  proc u32(o: int): int =
    if o < 0 or o + 4 > d.len: return 0
    int(d[o].byte) or int(d[o + 1].byte) shl 8 or int(d[o + 2].byte) shl 16 or int(d[o + 3].byte) shl 24
  proc f32(o: int): float32 = cast[float32](uint32(u32(o)))
  proc cstr(o, n: int): string =
    for i in o ..< min(o + n, d.len):
      if d[i] == '\0': break
      result.add d[i]
  if d.len < 0x40: return
  let count = u32(0x14)
  let dataAt = u32(0x20)
  for i in 0 ..< count:
    let o = 0x40 + 20 * i
    if o + 20 > d.len: break
    if d[o ..< o + 4] != "PVNE" or u32(o + 12) < 32: continue   # tags are stored backwards
    let s = dataAt + u32(o + 4) - 8
    if s < 0 or s + 32 > d.len: continue
    let n = int(d[s + 30].byte) or int(d[s + 31].byte) shl 8
    for k in 0 ..< n:
      let r = s + 32 + 208 * k
      if r + 208 > d.len: break
      envParts.list.add (cstr(r, 64), cstr(r + 64, 48), vec3(f32(r + 148), f32(r + 152), f32(r + 156)))
  envParts.list

proc partIndex(a: App) =
  let now = epochTime()
  if now - partIdx.at < 0.3: return
  partIdx.at = now
  partIdx.tags.clear()
  partIdx.furn.setLen 0
  for o in a.objects:
    if o.tag == "PART":
      let t = o.node.xpath("OSD/Tag").str.strip
      if t.len > 0: partIdx.tags.mgetOrPut(t, @[]).add o
    elif o.tag == "FURN":
      let t = o.node.xpath("OSD/Particle").str.strip
      if t.len > 0: partIdx.furn.add (t, o)

proc particleTargets(a: App, tag: string): PartTargets =
  ## Every particle `particle tag` reaches in this level.
  if tag.len == 0: return
  a.partIndex()
  result.parts = partIdx.tags.getOrDefault(tag)
  for e in a.levelEnvParticles:
    if e.tag == tag: result.envs.add e
  # The furniture they came from: the longest Particle that prefixes the tag,
  # near one of them when the level has them.
  var best = 0
  for (pre, o) in partIdx.furn:
    if tag.len > pre.len + 1 and tag.startsWith(pre) and tag[pre.len] == '_' and pre.len >= best:
      var near = result.envs.len == 0
      for e in result.envs:
        if (e.pos - o.pos).length < 30: near = true
      if not near: continue
      if pre.len > best: result.furn.setLen 0
      best = pre.len
      result.furn.add o
  if result.parts.len == 0 and result.envs.len == 0:
    let low = tag.toLowerAscii
    for t in partIdx.tags.keys:
      if t.toLowerAscii == low: return PartTargets(caseOf: t)
    for e in envParts.list:
      if e.tag.toLowerAscii == low: return PartTargets(caseOf: e.tag)

proc found(p: PartTargets): bool = p.parts.len > 0 or p.envs.len > 0 or p.furn.len > 0

proc partTag(t: Tok): string = t.text.strip(chars = {'"'})

proc particleTok(a: App, t: Tok): PartTargets =
  ## What a particle command's tag reaches (nothing for any other token).
  if t.refk == rkPartTag and t.kind in {tkIdent, tkString}: result = a.particleTargets(t.partTag)

proc partWhat(p: PartTargets): string =
  ## "2 particles (locklight)" and the like, for tips and the status bar.
  let n = p.parts.len + p.envs.len
  if n == 0:
    return if p.furn.len > 0: "furniture " & p.furn.mapIt("#" & $it.id).join(", ") else: "no particle"
  var classes: seq[string]
  for o in p.parts:
    let c = o.node.xpath("OSD/Class").str.strip
    if c.len > 0 and c notin classes: classes.add c
  for e in p.envs:
    if e.cls notin classes: classes.add e.cls
  result = (if n == 1: "1 particle" else: $n & " particles")
  if classes.len > 0: result.add " (" & classes.join(", ") & ")"

proc focusParticles(a: App, p: PartTargets, tag: string) =
  ## Ctrl+click on a particle tag: the views go to every particle it reaches.
  ## PART objects get selected; the level's own particles have no object, so
  ## they're marked in the views, with the furniture they came from selected.
  var objs = p.parts
  if objs.len == 0: objs = p.furn
  var spots: seq[Vec3]
  for e in p.envs: spots.add e.pos
  a.clearSelection()
  for o in objs:
    if o.hidden: o.hidden = false
    o.selected = true
  if objs.len > 0:
    a.showPanel(pkProperties)
    let pl = a.dock.leafOf(pkProperties)
    if a.dock.leafOf(pkMap) == nil: a.showPanel(pkMap)
    if a.dock.leafOf(pkMap) == pl and pl.tabs.len > 1:
      a.dropPanel(pkMap, pl, dzBottom, 0)
    a.showPanel(pkProperties)
    a.showPanel(pkMap)
    a.expanded.incl objs[0].tag
    a.mapReveal = objs[0]
  a.spotMarks = spots
  a.spotMarksAt = if spots.len > 0: epochTime() else: 0
  let vl = a.dock.leafOf(pkViewport)
  if vl != nil: vl.active = max(0, vl.tabs.find(pkViewport))
  a.frameSelection(spots)
  var msg = tag & ": " & p.partWhat
  if p.parts.len == 0 and p.furn.len > 0:
    msg.add ", of furniture " & p.furn.mapIt("#" & $it.id).join(", ")
  a.say(msg)

proc resolveTok(a: App, t: Tok): LevelObject =
  ## The level object a token names, if any.
  if t.kind notin {tkIdent, tkString, tkNumber}: return
  if t.refk in {rkPartTag, rkPartCommand, rkPartEvent}: return   # particleTok
  let idx = a.objectIndex
  let tag = RefTags[t.refk]
  if t.refk in {rkFlagId, rkDoorId, rkConsoleId, rkTriggerId, rkTurretId, rkTrgvId}:
    return idx.ids.getOrDefault(tag & " " & numberValue(t.text))
  if t.kind == tkNumber: return
  if t.sem notin {semBareWord, semString, semPlain} and t.refk == rkNone: return
  let objs = idx.names.getOrDefault(t.text.strip(chars = {'"'}).toLowerAscii)
  for o in objs:
    if tag.len == 0 or o.tag == tag: return o

# --- files and the index ---------------------------------------------------------------------

proc scriptRoot(a: App): string = a.proj.dir / "IGMD"

proc relScript(a: App, path: string): string =
  try: path.relativePath(a.scriptRoot) except CatchableError: path.extractFilename

proc ensureScripts(a: App) =
  if a.scripts == nil:
    a.scripts = ScriptEditor(active: -1)
  if a.scripts.defs == nil:
    a.scripts.defs = loadBslDefs(oniExePath(a.cfg.aeDir))
    if a.scripts.defs.error.len > 0 and not defsSaid:
      defsSaid = true
      a.say("Scripts: " & a.scripts.defs.error & "; the game's commands won't be listed", true)

proc refreshScripts(a: App) =
  ## Keeps the file list, the closed files' declarations and the index current.
  let e = a.scripts
  let now = epochTime()
  if now - e.filesChecked > 1.0:
    e.filesChecked = now
    e.files.setLen 0
    if dirExists(a.scriptRoot):
      for f in walkDirRec(a.scriptRoot):
        if f.toLowerAscii.endsWith(".bsl"): e.files.add f
    e.files.sort(cmpIgnoreCase)
    for f in e.files:
      var t: Time
      try: t = getLastModificationTime(f)
      except OSError: continue
      if f notin e.disk or e.disk[f].time != t:
        var lines: seq[string]
        try: lines = readFile(f).replace("\r\n", "\n").split('\n')
        except IOError: discard
        e.disk[f] = DiskFile(time: t, decls: scanDecls(lines, lexBsl(lines)))
    for b in e.buffers: b.checkDisk()
  # The index: open buffers as edited, the other files as on disk.
  var key = ""
  for f in e.files:
    var open: ScriptBuffer
    for b in e.buffers:
      if b.path == f: open = b
    key.add f & (if open != nil: "@" & $open.version else: "#" & $e.disk.getOrDefault(f).time.toUnix) & ";"
  for b in e.buffers:
    if b.path notin e.files: key.add b.path & "@" & $b.version & ";"
  if key == e.indexKey: return
  e.indexKey = key
  var idx: ProjectIndex
  proc addDecls(file: string, decls: seq[Decl]) =
    for d in decls:
      if d.isFunc:
        if d.name notin idx.funcs: idx.funcs[d.name] = DeclRef(file: file, decl: d)
      elif d.name notin idx.globals: idx.globals[d.name] = DeclRef(file: file, decl: d)
  var seen: HashSet[string]
  for b in e.buffers:
    seen.incl b.path
    let cached = bufDecls.getOrDefault(b.path, (-1, newSeq[Decl]()))
    if cached[0] != b.version:
      bufDecls[b.path] = (b.version, scanDecls(b.lines, lexBsl(b.lines)))
    addDecls(b.path, bufDecls[b.path][1])
  for f in e.files:
    if f notin seen and f in e.disk: addDecls(f, e.disk[f].decls)
  e.index = idx
  inc e.indexVersion

proc analysisOf(a: App, b: ScriptBuffer): Analysis =
  if b.an == nil or b.anVersion != b.version or b.anIndex != a.scripts.indexVersion:
    b.an = analyze(b.lines, lexBsl(b.lines), a.scripts.defs, a.scripts.index)
    b.anVersion = b.version
    b.anIndex = a.scripts.indexVersion
  b.an

type ScriptView* = object
  ## A level script as the Scripts panel has it (the MCP's list_scripts and read_script).
  path*, rel*: string           ## Full path; relative to the project's IGMD folder.
  open*, dirty*, active*: bool  ## A tab in the panel; with unsaved edits; the tab shown.
  changedOnDisk*: bool          ## Another program changed the file while it has unsaved edits.
  caret*: Pos
  lines*: seq[string]           ## Its text (when asked for): the panel's, unsaved edits included.
  problems*: seq[tuple[line, col: int, error: bool, msg: string]]   ## 1-based, as the panel marks them.

proc scriptViews*(a: App, only = "", text = false): seq[ScriptView] =
  ## The level's .bsl files (or the one only names: its path relative to IGMD, its file name or
  ## its full path), as edited in the Scripts panel when open there, else as on disk.
  if a.proj == nil: return
  a.ensureScripts()
  a.refreshScripts()
  let e = a.scripts
  var paths = e.files
  for b in e.buffers:
    if b.path notin paths: paths.add b.path
  let want = only.replace('\\', '/').toLowerAscii
  for p in paths:
    let rel = a.relScript(p)
    if want.len > 0 and want notin [p.replace('\\', '/').toLowerAscii, rel.replace('\\', '/').toLowerAscii,
                                    p.extractFilename.toLowerAscii]:
      continue
    var v = ScriptView(path: p, rel: rel)
    var b: ScriptBuffer
    for i, x in e.buffers:
      if x.path == p:
        b = x
        v.active = i == e.active
    var lines: seq[string]
    var an: Analysis
    if b != nil:
      v.open = true
      v.dirty = b.dirty
      v.changedOnDisk = b.changedOnDisk
      v.caret = b.caret
      lines = b.lines
      an = a.analysisOf(b)
    else:
      try: lines = readFile(p).replace("\r\n", "\n").split('\n')
      except IOError: discard
      an = analyze(lines, lexBsl(lines), e.defs, e.index)
    if text: v.lines = lines
    for d in an.diags: v.problems.add (d.line + 1, d.col + 1, d.error, d.msg)
    result.add v

proc readGameValues(a: App) =
  ## The values the game's own scripts pass each command argument ("particle
  ## x do start"...), to offer them, and a line of them using each command and
  ## variable, to show as an example.
  let e = a.scripts
  if e.gameValuesRead: return
  e.gameValuesRead = true
  let dir = a.cfg.gameData / "IGMD"
  if not dirExists(dir) or e.defs == nil: return
  var envs: Table[string, int]
  try: envs = a.cfg.levelEnvs
  except CatchableError: discard
  e.readGameScripts(dir, envs)

# --- opening -------------------------------------------------------------------------------

proc openScript*(a: App, path: string): ScriptBuffer =
  ## Opens path in the Scripts panel (or brings its tab forward).
  a.ensureScripts()
  let e = a.scripts
  for i, b in e.buffers:
    if b.path == path:
      e.active = i
      return b
  result = loadBuffer(path)
  e.buffers.add result
  e.active = e.buffers.high
  e.compOpen = false

proc openScriptAt*(a: App, path: string, line, col: int) =
  ## Shows path's line in the Scripts panel, the caret at col, ready to type.
  let b = a.openScript(path)
  a.showPanel(pkScripts)
  b.caret = b.clampPos((line, col))
  b.anchor = b.caret
  scrollToLine = b.caret.line
  scrollFor = b
  a.ui.focusId = EditorId
  a.ui.navId = ""

proc findDecl*(a: App, name: string, funcsOnly = false): (bool, DeclRef) =
  if a.proj == nil: return
  a.ensureScripts()
  a.refreshScripts()
  let idx = a.scripts.index
  if name in idx.funcs: return (true, idx.funcs[name])
  if not funcsOnly and name in idx.globals: return (true, idx.globals[name])

proc openFunction*(a: App, name: string): bool =
  ## Goes to where the level's scripts declare function name.
  let (ok, d) = a.findDecl(name.strip, funcsOnly = true)
  if not ok: return false
  a.openScriptAt(d.file, d.decl.line, d.decl.col)
  true

proc isScriptField*(tag: string, fld: ObjectField): bool =
  ## Fields that name a function of the level's scripts.
  (tag in ["CHAR", "TRGV"] and fld.path.startsWith("OSD/Scripts/") and fld.attr.len == 0) or
    (tag == "NEUT" and fld.path == "OSD/Script/AfterTalk" and fld.attr.len == 0) or
    (fld.attr == "Function" and fld.path.contains("OSD/Events/"))

proc scriptFieldButton*(a: App, id: string, r: Rect, value: string) =
  ## The button beside a script field: to the function's declaration.
  let name = value.strip
  var tip = "Go to the function in the Scripts panel"
  var enabled = name.len > 0
  if enabled:
    let (ok, d) = a.findDecl(name, funcsOnly = true)
    if ok: tip = &"Go to {name} in {a.relScript(d.file)}, line {d.decl.line + 1}"
    else:
      enabled = false
      tip = &"No function named {name} in the level's scripts"
  else: tip = "No function set"
  if a.ui.iconButton(id, r, "code16", tip, enabled, focusable = false):
    discard a.openFunction(name)

proc focusObject*(a: App, o: LevelObject) =
  ## Selects o and shows it everywhere: its Properties, its row in the Map
  ## tab (both in sight: the Map moves under the Properties if they share a
  ## stack) and the views framed on it.
  if o.hidden:
    o.hidden = false
  a.clearSelection()
  o.selected = true
  a.showPanel(pkProperties)
  let pl = a.dock.leafOf(pkProperties)
  if a.dock.leafOf(pkMap) == nil: a.showPanel(pkMap)
  if a.dock.leafOf(pkMap) == pl and pl.tabs.len > 1:
    a.dropPanel(pkMap, pl, dzBottom, 0)
    a.say("The Map tab moved under Properties so both show")
  a.showPanel(pkProperties)
  a.showPanel(pkMap)
  a.expanded.incl o.tag
  a.mapReveal = o
  let vl = a.dock.leafOf(pkViewport)
  if vl != nil: vl.active = max(0, vl.tabs.find(pkViewport))
  a.frameSelection()

# --- text geometry -------------------------------------------------------------------------

proc vcol(s: string, col: int): int =
  ## The column byte col of s is drawn at (tabs expanded).
  for i in 0 ..< min(col, s.len):
    if s[i] == '\t': result = (result div TabCols + 1) * TabCols
    else: inc result

proc colAt(s: string, v: float32): int =
  ## The byte nearest drawn column v.
  var x = 0
  while result < s.len:
    let nx = if s[result] == '\t': (x div TabCols + 1) * TabCols else: x + 1
    if v < (x + nx).float32 / 2: return
    x = nx
    inc result

proc indentOf(s: string): string =
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  s[0 ..< i]

proc wordAt(s: string, col: int): (int, int) =
  var a = min(col, s.len)
  var b = a
  while a > 0 and s[a - 1] in IdentChars: dec a
  while b < s.len and s[b] in IdentChars: inc b
  (a, b)

# --- completion -----------------------------------------------------------------------------

proc instanceTag(cmd, param: string): (string, string, string) =
  ## Level 0 instances an argument names: (tag, name prefix, suffix).
  let cmd = gameCommand(cmd)
  case param
  of "film_name": ("FILM", "", "")
  of "anim_name", "anim": ("TRAM", "", "")
  of "char_class", "class_name": ("ONCC", "", "")
  of "weapon_name": ("ONWC", "", "")
  of "texture", "bitmap_name", "tex_name": ("TXMP", "", "")
  of "particle_class": ("BINA", "3RAP", "")
  of "name", "sound_name":
    if cmd == "sound_impulse_play": ("OSBD", "", ".imp")
    elif cmd.startsWith("sound_") or param == "sound_name": ("OSBD", "", ".amb")
    else: ("", "", "")
  else: ("", "", "")

const SoundCompHint = "Ctrl+click: open it in the sound player"

proc soundKindOf(itag, suffix: string): int =
  ## instanceTag's answer as CompItem.sound: 1 an ambient, 2 an impulse, 0 not a sound.
  if itag != "OSBD": 0 elif suffix == ".imp": 2 else: 1

proc soundTok(a: App, an: Analysis, ti: int): int =
  ## Token ti is a sound's name written as a command's argument (sound_dialog_play,
  ## sound_ambient_start, sound_impulse_play, chr_talk...): as CompItem.sound.
  let t = an.toks[ti]
  if t.kind notin {tkIdent, tkString} or t.sem notin {semBareWord, semString, semPlain} or
     t.call < 0 or t.arg < 0 or a.scripts == nil or a.scripts.defs == nil:
    return 0
  let name = an.calls[t.call].name
  for p in paramsAt(an, a.scripts.defs, t.call, t.arg):
    let (itag, _, suf) = instanceTag(name, p.name)
    let k = soundKindOf(itag, suf)
    if k > 0: return k

proc soundName(t: Tok): string = t.text.strip(chars = {'"'}).strip

proc particleItems(a: App, an: Analysis, ci, arg: int): seq[CompItem] =
  ## What `particle` takes there: the level's particle tags, then a command or
  ## an event, then after do an event.
  let c = an.calls[ci]
  proc eventItems(items: var seq[CompItem]) =
    var order = @[2, 3, 9]    # start, stop, explode: what scripts send
    for i in 0 ..< ParticleEvents.len:
      if i notin order: order.add i
    for i in order:
      items.add CompItem(label: ParticleEvents[i], insert: ParticleEvents[i], detail: "event " & $i & " · " & EventDefs[i].label,
                         doc: EventDefs[i].tip, kind: semBareWord, refk: rkPartEvent, what: "particle event")
  case arg
  of 0:
    var tags: seq[string]
    a.partIndex()
    for t in partIdx.tags.keys: tags.add t
    for e in a.levelEnvParticles:
      if e.tag.len > 0 and e.tag notin tags: tags.add e.tag
    tags.sort(cmpIgnoreCase)
    for t in tags:
      let p = a.particleTargets(t)
      result.add CompItem(label: t, insert: t, detail: p.partWhat, kind: semBareWord, tag: "PART",
                          refk: rkPartTag, what: "particle tag", then: true,
                          doc: "Ctrl+click it in the script to go to " & (if p.parts.len + p.envs.len == 1: "it" else: "them"))
  of 1:
    for w in ["do", "create", "kill", "reset"]:
      result.add CompItem(label: w, insert: w, detail: (if w == "do": "do event" else: "command"),
                          doc: ParticleCommandDocs[w], kind: semBareWord, refk: rkPartCommand,
                          what: "particle command", then: w == "do")
    result.eventItems()
  of 2:
    if c.args.len > 1 and c.args[1].a == c.args[1].b and an.toks[c.args[1].a].partTag == "do":
      result.eventItems()
  else: discard

proc enclosingParams(an: Analysis, line: int): seq[(string, string)] =
  ## The arguments of the function the line is in (the last one declared above it).
  for d in an.decls:
    if d.isFunc and d.line <= line: result = d.params

const ScriptWhen = {"Spawn": "when it spawns", "Die": "when it dies", "Combat": "when it starts fighting",
  "Alarm": "when it goes for an alarm", "Hurt": "when it's hurt", "Defeated": "when it's defeated",
  "OutOfAmmo": "when it runs out of ammo", "NoPath": "when it can't find a path",
  "Entry": "when a character enters it", "Inside": "while a character is inside it",
  "Exit": "when a character leaves it"}.toTable

type ObjFuncRef = object
  ## A function the game calls by name for one of the level's objects.
  name, detail, doc, args: string
  obj: LevelObject

proc objectFuncRefs(a: App): seq[ObjFuncRef] =
  ## The objects' script fields, patrol paths' script points (patrolscriptNNNN,
  ## the only name besides main the game builds itself) and event functions.
  proc add(refs: var seq[ObjFuncRef], o: LevelObject, name, detail, doc: string, args = "(string ai_name)") =
    if name.len > 0: refs.add ObjFuncRef(name: name, detail: detail, doc: doc, args: args, obj: o)
  for o in a.objects:
    let who = typeName(o.tag) & " " & o.label
    case o.tag
    of "CHAR", "TRGV":
      let sc = o.node.xpath("OSD/Scripts")
      if sc != nil:
        for c in sc:
          if c.kind != xnElement: continue
          let w = ScriptWhen.getOrDefault(c.tag, "")
          result.add(o, c.str.strip, &"{c.tag} script of {who}",
            &"{who} (#{o.id}) calls it by this name" & (if w.len > 0: " " & w else: "") &
            ", passing the character's name.")
    of "NEUT":
      result.add(o, o.node.xpath("OSD/Script/AfterTalk").str.strip, &"AfterTalk script of {who}",
        &"{who} (#{o.id}) calls it by this name after its dialogue, passing the character's name.")
    of "PATR":
      proc points(o: LevelObject, n: XmlNode, refs: var seq[ObjFuncRef]) =
        let who = typeName(o.tag) & " " & o.label
        for c in n:
          if c.kind != xnElement: continue
          if c.tag in ["CallScript", "ForkScript"] and c.attr("ScriptId").len > 0:
            try:
              let id = parseInt(c.attr("ScriptId").strip)
              refs.add(o, "patrolscript" & align($id, 4, '0'), &"{c.tag} point of {who}",
                &"A character following {who} reaches its {c.tag} point (ScriptId {id}) and the game " &
                "calls patrolscript plus the id in four digits, passing the character's name" &
                (if c.tag == "ForkScript": ", without waiting for it." else: "."))
            except ValueError: discard
          else: points(o, c, refs)
      let pts = o.node.xpath("OSD/Points")
      if pts != nil: points(o, pts, result)
    else: discard
    let ev = o.node.xpath("OSD/Events")
    if ev != nil:
      for c in ev:
        if c.kind == xnElement and c.attr("Function").len > 0:
          result.add(o, c.attr("Function").strip, &"{c.tag} event of {who}",
            &"{who} (#{o.id}) calls it by this name when its events fire.", "")

proc calledFuncs(a: App, an: Analysis): seq[CompItem] =
  ## The function names the game or the level calls that no script declares
  ## yet: main, the objects' script fields and event functions, patrol paths'
  ## script points and names this file passes as a script argument.
  let idx = a.scripts.index
  var seen: HashSet[string]
  proc add(items: var seq[CompItem], name, detail, doc: string, args = "(string ai_name)") =
    if name.len == 0 or name in idx.funcs or name in seen: return
    seen.incl name
    items.add CompItem(label: name, insert: name, detail: detail, doc: doc, kind: semFunc, args: args,
                       what: "new function")
  result.add("main", "the level's start", "The game calls main by this name once the level has loaded, " &
    "with no arguments. It's where a level's scripts begin.", "(void)")
  for r in a.objectFuncRefs:
    result.add(r.name, r.detail, r.doc, r.args)
  for t in an.toks:
    if t.refk == rkFuncName and t.kind != tkNumber:
      let c = if t.call >= 0: an.calls[t.call].name else: "a command"
      result.add(t.text.strip(chars = {'"'}), &"named in {c}, line {t.line + 1}",
        &"This file passes it to {c} on line {t.line + 1}.", "")

proc completions(a: App, b: ScriptBuffer, an: Analysis, ctx: CaretCtx): seq[CompItem] =
  let e = a.scripts
  let defs = e.defs
  var seen: HashSet[string]
  proc variables(items: var seq[CompItem], want = "") =
    for (typ, name) in an.enclosingParams(b.caret.line):
      if name.len > 0 and (want.len == 0 or typ == want):
        items.add CompItem(label: name, insert: name, detail: typ & " argument", kind: semLocal, what: "argument")
    for name, d in e.index.globals:
      if want.len == 0 or d.decl.typ == want:
        items.add CompItem(label: name, insert: name, detail: d.decl.typ & " variable",
                           doc: d.decl.doc, kind: semGlobal, what: "variable")
    if defs != nil and want.len == 0:
      for name, v in defs.variables:
        items.add CompItem(label: name, insert: name, detail: $v.typ & (if v.arklite: " (Arklite)" else: " (game)"),
                           doc: v.desc, kind: semEngineVar, also: (if v.arklite: "arklite" else: ""),
                           what: if v.arklite: "Arklite variable" else: "game variable")
  proc funcs(items: var seq[CompItem], then: bool) =
    for name, d in e.index.funcs:
      var ps: seq[string]
      for (t, n) in d.decl.params:
        if n.len > 0: ps.add t & " " & n
      items.add CompItem(label: name, insert: name,
                         detail: "func " & (if d.decl.typ.len > 0: d.decl.typ else: "void") & " " & "(" & ps.join(", ") & ")",
                         doc: d.decl.doc, kind: semFunc, then: then and ps.len > 0, what: "function",
                         call: if ps.len > 0: 2 else: 1)
  proc commands(items: var seq[CompItem], valuesOnly: bool) =
    if defs == nil: return
    for name, c in defs.commands:
      if valuesOnly and c.ret == btVoid: continue
      items.add CompItem(label: name, insert: name,
                         detail: (if c.ret != btVoid: "returns " & $c.ret & (if c.spec.len > 0: " · " else: "") else: "") & c.spec,
                         doc: c.desc, kind: semCommand, then: not valuesOnly and c.spec.len > 0,
                         what: if c.arklite: "Arklite function" else: "game function",
                         also: if c.arklite: "arklite" else: "",
                         call: if c.spec.len > 0: 2 else: 1)
  case ctx.kind
  of ckNone: discard
  of ckFuncName:
    let before = b.lines[b.caret.line][0 ..< ctx.start].strip
    if before == "func" or before.endsWith(" func"):
      for w in ["void", "int", "float", "string", "bool"]:
        result.add CompItem(label: w, insert: w, detail: "return type", doc: Keywords.getOrDefault(w),
                            kind: semType, then: true, what: "type")
    for it in a.calledFuncs(an): result.add it
  of ckStatement:
    for kw in ["func", "var", "if", "else", "return", "sleep", "fork"]:
      result.add CompItem(label: kw, insert: kw, detail: "keyword", doc: Keywords[kw], kind: semKeyword,
                          then: kw != "else", what: "keyword")
    result.commands(false)
    result.funcs(true)
    result.variables()
  of ckExpr:
    for kw in ["eq", "ne", "and", "or", "true", "false"]:
      result.add CompItem(label: kw, insert: kw, detail: "keyword", doc: Keywords[kw], kind: semKeyword,
                          what: if kw in ["true", "false"]: "bool value" else: "operator")
    result.variables()
    result.funcs(false)
    result.commands(true)
  of ckArg:
    let c = an.calls[ctx.call]
    var params = paramsAt(an, defs, ctx.call, ctx.arg)
    if c.name in e.index.funcs:
      let ps = e.index.funcs[c.name].decl.params
      if ctx.arg < ps.len and ps[ctx.arg][1].len > 0:
        params.add ParamNode(name: ps[ctx.arg][1], typ: parseEnum[BslType](ps[ctx.arg][0], btString))
    var items: seq[CompItem]
    let idx = a.objectIndex
    proc objects(items: var seq[CompItem], rk: RefKind) =
      let tag = RefTags[rk]
      if rk in {rkFlagId, rkDoorId, rkConsoleId, rkTriggerId, rkTurretId, rkTrgvId}:
        var rows: seq[(int, string, LevelObject)]
        for o in a.objects:
          if o.tag != tag: continue
          try:
            let id = parseInt(o.node.xpath(ScriptIdFields[tag]).str.strip)
            let label = if tag == "FLAG": o.node.xpath("OSD/Notes").str.strip else: o.label
            rows.add (id, label, o)
          except ValueError: discard
        rows.sort(proc(x, y: (int, string, LevelObject)): int = cmp(x[0], y[0]))
        for (id, label, o) in rows:
          items.add CompItem(label: $id, insert: $id, detail: typeName(tag) & (if label.len > 0: " · " & label else: ""),
                             kind: semNumber, tag: tag, what: typeName(tag) & " id")
      else:
        var rows: seq[(string, LevelObject)]
        for o in a.objects:
          if o.tag == tag and o.objName.len > 0: rows.add (o.objName, o)
        rows.sort(proc(x, y: (string, LevelObject)): int = cmpIgnoreCase(x[0], y[0]))
        for (n, o) in rows:
          items.add CompItem(label: n, insert: n, detail: typeName(tag) & " #" & $o.id, kind: semBareWord, tag: tag,
                             what: typeName(tag) & " name")
    discard idx
    var argSound = 0   # The argument is a sound's name: as CompItem.sound.
    for p in params:
      for v in p.values:
        items.add CompItem(label: v, insert: v, detail: p.name, kind: (if v[0] in Digits: semNumber else: semString),
                           what: $p.typ & " value")
      let rk = refFor(c.name, p.name)
      if rk == rkFuncName: items.funcs(false)
      elif rk != rkNone: items.objects(rk)
      let (itag, pre, suf) = instanceTag(c.name, p.name)
      let snd = soundKindOf(itag, suf)
      if snd > 0 and argSound == 0: argSound = snd
      if itag.len > 0:
        if a.catalog == nil: a.catalog = newCatalog()
        a.catalog.refresh(a.cfg.gameData, a.proj.dir)
        for n in a.catalog.instanceNames(itag, pre, suf):
          items.add CompItem(label: n, insert: n, detail: itag, kind: semBareWord, sound: snd,
                             doc: if snd > 0: SoundCompHint else: "",
                             what: if snd > 0: "sound" else: itag & " name")
    # What the game's scripts pass there.
    a.readGameValues()
    let key = gameCommand(c.name) & "#" & $ctx.arg
    if key in e.gameValues:
      var used = e.gameValues[key]
      used.sort()
      var n = 0
      for v, k in used:
        let isNum = v[0] in Digits or v[0] == '-'
        items.add CompItem(label: v, insert: v, detail: &"used {k}× in the game's scripts",
                           kind: (if isNum: semNumber else: semBareWord),
                           sound: argSound, doc: if argSound > 0: SoundCompHint else: "",
                           what: if argSound > 0: "sound"
                                 elif isNum: (if '.' in v: "float value" else: "int value")
                                 else: "string value")
        inc n
        if n >= 40: break
    if c.name == "particle": items = a.particleItems(an, ctx.call, ctx.arg)
    var want = ""
    for p in params:
      if p.values.len == 0: want = $p.typ
    if params.len == 0 or want.len > 0: items.variables(if params.len > 0: want else: "")
    for it in items: result.add it
  # Typed so far: names starting with it, then names containing it.
  let pre = ctx.prefix.toLowerAscii
  var first, rest: seq[CompItem]
  for it in result:
    let l = it.label.toLowerAscii
    # What's typed in full drops out, except a function: Enter or Tab still
    # takes it, with its parentheses.
    if l == pre and ctx.kind != ckArg and it.call == 0: continue
    if l.startsWith(pre) or (pre.len >= 2 and it.also.len > 0 and it.also.startsWith(pre)): first.add it
    elif pre.len >= 2 and pre in l: rest.add it
  if ctx.kind != ckArg:
    first.sort(proc(x, y: CompItem): int = cmpIgnoreCase(x.label, y.label))
    rest.sort(proc(x, y: CompItem): int = cmpIgnoreCase(x.label, y.label))
  result.setLen 0
  for it in first & rest: result.add it
  seen.clear()
  var dedup: seq[CompItem]
  for it in result:
    if it.label notin seen:
      seen.incl it.label
      dedup.add it
  result = dedup
  if result.len > 300: result.setLen 300

proc updateCompletion(a: App, b: ScriptBuffer, force = false, onSpace = false) =
  ## Opens, filters or closes the list after the caret moved or text changed.
  let e = a.scripts
  let an = a.analysisOf(b)
  let ctx = caretContext(an, b.lines, b.caret.line, b.caret.col)
  if not force and not e.compOpen and not onSpace:
    return
  if ctx.kind == ckNone or (not force and not onSpace and ctx.prefix.len == 0 and ctx.kind != ckArg):
    e.compOpen = false
    return
  let items = a.completions(b, an, ctx)
  if items.len == 0 or (onSpace and ctx.kind notin {ckArg, ckFuncName}):
    e.compOpen = false
    return
  if not e.compOpen or e.compStart != (b.caret.line, ctx.start):
    e.compHi = 0
    e.compScroll = 0
  e.compOpen = true
  e.compItems = items
  e.compStart = (b.caret.line, ctx.start)
  e.compHi = clamp(e.compHi, 0, items.high)

proc acceptCompletion(a: App, b: ScriptBuffer) =
  let e = a.scripts
  if not e.compOpen or e.compHi notin 0 ..< e.compItems.len: return
  let it = e.compItems[e.compHi]
  e.caretTip = true
  let line = b.lines[b.caret.line]
  let z = wordAt(line, b.caret.col)[1]
  let start = (b.caret.line, min(e.compStart.col, b.caret.col))
  var ins = it.insert
  let rest = line[z .. ^1]
  let after = rest.strip(trailing = false)
  if it.call > 0 and rest.startsWith("("):
    # Its parentheses are there already: the caret goes inside them.
    b.replace(start, (b.caret.line, max(z, b.caret.col)), ins, now = epochTime())
    b.caret.col += 1
    b.anchor = b.caret
    e.compOpen = false
    a.updateCompletion(b, onSpace = true)
    return
  if it.call > 0 and (after.len == 0 or after[0] in {';', ')', ',', '}', ']'}):
    # A function opens its parentheses, the caret inside them when it takes
    # arguments (they're offered next), else after them.
    ins.add "()"
    b.replace(start, (b.caret.line, max(z, b.caret.col)), ins, now = epochTime())
    e.compOpen = false
    if it.call == 2:
      b.caret.col -= 1
      b.anchor = b.caret
      autoClose = (b, b.caret.line, b.lines[b.caret.line].len - b.caret.col)
      a.updateCompletion(b, onSpace = true)
    return
  if it.then and (z >= line.len or line[z] notin {' ', '\t', '('}): ins.add " "
  if it.args.len > 0 and line[z .. ^1].strip.len == 0: ins.add it.args
  b.replace(start, (b.caret.line, max(z, b.caret.col)), ins, now = epochTime())
  e.compOpen = false
  if it.then: a.updateCompletion(b, onSpace = true)

# --- hover help -------------------------------------------------------------------------------

type
  TipKind = enum
    tlDesc,     ## A description: the default text color.
    tlWhere,    ## Where something is: light blue.
    tlHint,     ## What a click or key does: dim.
    tlUse,      ## A use: its place (light blue), then its line (code) or who calls it.
    tlError, tlWarn,
    tlCode      ## A line of code.
  TipLine = object
    kind: TipKind
    text: string
    code: string                ## tlUse: the line there, or who calls it (prose: not mono).
    mono: bool

proc tip(kind: TipKind, text: string): TipLine = TipLine(kind: kind, text: text)

proc declLines(d: DeclRef, rel: string): (string, seq[TipLine]) =
  ## A declaration's signature (the tip's title), where it is and its comment.
  var ps: seq[string]
  for (t, n) in d.decl.params:
    ps.add (if n.len > 0: t & " " & n else: t)
  let title = if d.decl.isFunc:
                "func " & (if d.decl.typ.len > 0: d.decl.typ else: "void") & " " & d.decl.name & "(" & ps.join(", ") & ")"
              else: "var " & d.decl.typ & " " & d.decl.name
  var lines = @[tip(tlWhere, rel & ", line " & $(d.decl.line + 1))]
  if d.decl.doc.len > 0: lines.add tip(tlDesc, d.decl.doc)
  (title, lines)

# --- uses of the level's functions and variables --------------------------------------------

type
  SymKind = enum skNone, skFunc, skGlobal, skLocal
  Sym = object
    kind: SymKind
    name: string
  Usage = object
    file: string                ## The script file; "": an object (obj) or the game itself.
    line, col, len: int
    code: string                ## The line, trimmed, tabs as spaces.
    at: int                     ## Where the name is in code.
    obj: LevelObject
    what: string                ## Not a script line: who calls it, and when.

var
  diskAn: Table[string, tuple[time: Time, index: int, lines: seq[string], an: Analysis]]
  usageCache: tuple[key: string, list: seq[Usage]]
  objRefsCache: tuple[at: float, refs: seq[ObjFuncRef]]
  # The list of uses Ctrl+click on a declaration opens, under its name.
  refsOpen, refsFresh: bool
  refsBuf: ScriptBuffer
  refsVersion: int
  refsAt: Pos
  refsName: string
  refsList: seq[Usage]
  refsHi, refsScroll: int

const RefsRows = 12

proc symAt(an: Analysis, ti: int): (Sym, bool) =
  ## The function or variable of the level's scripts the token names, and
  ## whether the token is its declaration.
  let t = an.toks[ti]
  case t.sem
  of semDeclName:
    if t.decl >= 0: (Sym(kind: (if an.decls[t.decl].isFunc: skFunc else: skGlobal), name: t.text), true)
    else: (Sym(kind: skLocal, name: t.text), true)
  of semLocal: (Sym(kind: skLocal, name: t.text), t.defines)
  of semFunc: (Sym(kind: skFunc, name: t.text), false)
  of semGlobal: (Sym(kind: skGlobal, name: t.text), false)
  else:
    if t.refk == rkFuncName and t.kind in {tkIdent, tkString}:
      (Sym(kind: skFunc, name: t.text.strip(chars = {'"'})), false)
    else: (Sym(), false)

proc localDecl(an: Analysis, ti: int): int =
  ## The argument or var that declares the local variable at ti: the last one
  ## above it in its function, else the first below (-1: none).
  let t = an.toks[ti]
  result = -1
  for i, u in an.toks:
    if not u.defines or u.fn != t.fn or u.text != t.text: continue
    if u.sem == semDeclName and u.decl >= 0: continue
    if i <= ti: result = i
    elif result < 0: return i
    else: return

proc usageAt(file: string, lines: seq[string], t: Tok): Usage =
  let s = if t.line < lines.len: lines[t.line] else: ""
  var lead = 0
  while lead < s.len and s[lead] in {' ', '\t'}: inc lead
  Usage(file: file, line: t.line, col: t.col, len: t.len, code: s[lead .. ^1].strip(leading = false).replace('\t', ' '),
        at: max(0, t.col - lead))

proc fileAnalysis(a: App, path: string): (seq[string], Analysis) =
  ## A script file's lines and analysis: an open one's as edited, else as on disk.
  let e = a.scripts
  for b in e.buffers:
    if b.path == path: return (b.lines, a.analysisOf(b))
  var t: Time
  try: t = getLastModificationTime(path)
  except OSError: return
  if path in diskAn and diskAn[path].time == t and diskAn[path].index == e.indexVersion:
    return (diskAn[path].lines, diskAn[path].an)
  var lines: seq[string]
  try: lines = readFile(path).replace("\r\n", "\n").split('\n')
  except IOError: return
  let an = analyze(lines, lexBsl(lines), e.defs, e.index)
  diskAn[path] = (t, e.indexVersion, lines, an)
  (lines, an)

proc usagesOf(a: App, b: ScriptBuffer, an: Analysis, ti: int): seq[Usage] =
  ## Every use of what token ti names: a local variable's in its function; a
  ## function's or global variable's in all the level's script files, then
  ## the objects and the game calling a function by its name.
  let (sym, _) = symAt(an, ti)
  case sym.kind
  of skNone: return
  of skLocal:
    let fn = an.toks[ti].fn
    for u in an.toks:
      if u.sem == semLocal and not u.defines and u.fn == fn and u.text == sym.name:
        result.add usageAt(b.path, b.lines, u)
    return
  of skFunc, skGlobal: discard
  let e = a.scripts
  let key = $sym.kind & ":" & sym.name & "@" & $e.indexVersion
  if usageCache.key != key:
    var list: seq[Usage]
    var files = e.files
    for ob in e.buffers:
      if ob.path notin files: files.add ob.path
    for f in files:
      let (lines, fa) = a.fileAnalysis(f)
      if fa == nil: continue
      for u in fa.toks:
        let hit = if sym.kind == skGlobal: u.sem == semGlobal and u.text == sym.name
                  else: (u.sem == semFunc and u.text == sym.name) or
                        (u.refk == rkFuncName and u.kind in {tkIdent, tkString} and u.sem != semFunc and
                         u.text.strip(chars = {'"'}) == sym.name)
        if hit: list.add usageAt(f, lines, u)
    usageCache = (key, list)
  result = usageCache.list
  if sym.kind == skFunc:
    if sym.name == "main":
      result.insert(Usage(what: "calls it once the level has loaded"), 0)
    let now = epochTime()
    if now - objRefsCache.at > 0.5: objRefsCache = (now, a.objectFuncRefs)
    for r in objRefsCache.refs:
      if r.name == sym.name: result.add Usage(obj: r.obj, what: r.detail)

proc usageWhere(a: App, u: Usage): string =
  if u.file.len > 0: u.file.extractFilename & ":" & $(u.line + 1)
  elif u.obj != nil: typeName(u.obj.tag) & " " & u.obj.label & " #" & $u.obj.id
  else: "The game"

proc usesLines(a: App, uses: seq[Usage], sym: Sym): seq[TipLine] =
  ## Hover lines listing the uses of a declaration.
  if uses.len == 0:
    return @[tip(tlDesc, if sym.kind == skFunc: "Nothing calls it: no script, object or the game"
                         else: "Nothing uses it")]
  result.add tip(tlDesc, "Used " & $uses.len & (if uses.len == 1: " time:" else: " times:"))
  for k, u in uses:
    if k == 6:
      result.add tip(tlHint, "and " & $(uses.len - 6) & " more")
      break
    result.add TipLine(kind: tlUse, text: a.usageWhere(u), code: (if u.file.len > 0: u.code else: u.what),
                       mono: u.file.len > 0)
  result.add tip(tlHint, "Ctrl+click: list them all, to jump to one")

proc gotoUsage(a: App, u: Usage) =
  if u.obj != nil:
    a.focusObject(u.obj)
  elif u.file.len > 0:
    a.openScriptAt(u.file, u.line, u.col)
    let b = a.scripts.current
    if b != nil:
      b.anchor = b.clampPos((u.line, u.col))
      b.caret = b.clampPos((u.line, u.col + u.len))

proc openUses(a: App, b: ScriptBuffer, an: Analysis, ti: int) =
  ## The list of uses of what token ti names, under the token.
  let (sym, _) = symAt(an, ti)
  if sym.kind == skNone: return
  let t = an.toks[ti]
  refsList = a.usagesOf(b, an, ti)
  refsOpen = true
  refsFresh = true
  refsBuf = b
  refsVersion = b.version
  refsAt = (t.line, t.col)
  refsName = sym.name
  refsHi = 0
  refsScroll = 0
  a.scripts.compOpen = false

proc localTitle(an: Analysis, ti: int): (string, bool) =
  ## "type name" of a local variable, and whether it's an argument.
  let d = localDecl(an, ti)
  if d < 0: return (an.toks[ti].text, false)
  var j = d - 1
  while j >= 0 and an.toks[j].kind == tkComment: dec j
  let typ = if j >= 0 and an.toks[j].sem == semType: an.toks[j].text & " " else: ""
  (typ & an.toks[ti].text, an.toks[d].sem == semLocal)

proc gameExampleText(a: App, key: string): (string, string) =
  ## (where, code) of a line of the game's own scripts using a command ("c:name")
  ## or variable ("v:name"); where: "" when none uses it.
  a.readGameValues()
  let e = a.scripts
  if key notin e.gameExamples: return
  let ex = e.gameExamples[key]
  var where = ""
  if ex.level > 0:
    var titles: Table[int, string]
    try: titles = a.cfg.levelTitles
    except CatchableError: discard
    let t = titles.getOrDefault(ex.level)
    where = (if t.len > 0: t & " (level " & $ex.level & ")" else: "Level " & $ex.level)
  else: where = ex.folder
  ("Example from " & where & ", " & ex.folder & "/" & ex.file & " line " & $(ex.line + 1) & ":", ex.code)



proc particleTagLines(a: App, t: Tok): seq[TipLine] =
  ## A particle command's tag: what it reaches.
  let p = a.particleTok(t)
  if p.parts.len > 0 or p.envs.len > 0:
    result.add tip(tlDesc, "Particle tag: " & p.partWhat & " in this level")
    for o in p.parts: result.add tip(tlWhere, "Particle object #" & $o.id & " · " & o.node.xpath("OSD/Class").str.strip)
    if p.envs.len > 0:
      var line = (if p.envs.len == 1: "1 is" else: $p.envs.len & " are") & " the level's own"
      if p.furn.len > 0:
        let cls = p.furn[0].node.xpath("OSD/Class").str.strip
        line.add ", from furniture " & cls & " " & p.furn.mapIt("#" & $it.id).join(", ") &
          (if p.furn.len == 1: " (its Particle " else: " (their Particle ") &
          p.furn[0].node.xpath("OSD/Particle").str.strip & ")"
      result.add tip(tlWhere, line)
    result.add tip(tlHint, "Ctrl+click: go to " & (if p.parts.len + p.envs.len == 1: "it" else: "them"))
  elif p.furn.len > 0:
    result.add tip(tlDesc, "Particle tag of furniture " & p.furn.mapIt("#" & $it.id).join(", ") &
      (if p.furn.len == 1: " (its Particle " else: " (their Particle ") & p.furn[0].node.xpath("OSD/Particle").str.strip & "), if its model has a particle tagged " &
      t.partTag[p.furn[0].node.xpath("OSD/Particle").str.strip.len + 1 .. ^1])
    result.add tip(tlHint, "Ctrl+click: go to it")
  elif p.caseOf.len > 0:
    result.add tip(tlDesc, "No particle has this tag, but " & p.caseOf & " has: the game compares exactly, so it does nothing")
  else:
    result.add tip(tlDesc, "No particle in this level has this tag: the game does nothing")

proc hoverText(a: App, b: ScriptBuffer, an: Analysis, ti: int): (string, seq[TipLine]) =
  ## (title in code font, the lines below it) for the token.
  let e = a.scripts
  let t = an.toks[ti]
  let defs = e.defs
  var title: string
  var lines: seq[TipLine]
  proc example(key: string) =
    let (head, code) = a.gameExampleText(key)
    if head.len > 0:
      lines.add tip(tlWhere, head)
      lines.add tip(tlCode, code)
    else: lines.add tip(tlDesc, "None of the game's levels uses it.")
  case t.sem
  of semCommand:
    let c = defs.commands[t.text]
    title = c.signature
    lines.add tip(tlDesc, c.desc)
    if c.arklite:
      lines.add tip(tlDesc, "Arklite's command: the game has it only with Arklite installed. Without " &
                            "Arklite the script stops here with an error.")
    else:
      if not c.checked: lines.add tip(tlDesc, "The game doesn't check its arguments.")
      example("c:" & t.text)
  of semEngineVar:
    let v = defs.variables[t.text]
    title = $v.typ & " " & v.name
    lines.add tip(tlDesc, v.desc)
    if v.arklite:
      lines.add tip(tlDesc, "Arklite's variable: the game has it only with Arklite installed (set it with " &
                            v.name & " = value).")
    else:
      lines.add tip(tlDesc, "A variable of the game (set it with " & v.name & " = value).")
      example("v:" & t.text)
  of semKeyword, semType, semOperator:
    title = t.text
    lines.add tip(tlDesc, Keywords.getOrDefault(t.text))
  of semLocal:
    let (tt, isArg) = localTitle(an, ti)
    title = tt
    lines.add tip(tlDesc, if isArg: "An argument of this function." else: "A local variable of this function.")
    if t.defines: lines.add a.usesLines(a.usagesOf(b, an, ti), Sym(kind: skLocal))
    elif localDecl(an, ti) >= 0:
      lines.add tip(tlWhere, "Line " & $(an.toks[localDecl(an, ti)].line + 1))
      lines.add tip(tlHint, "Ctrl+click or F12: go to its declaration")
  of semDeclName:
    let (sym, _) = symAt(an, ti)
    if sym.kind == skLocal:
      title = localTitle(an, ti)[0]
      lines.add tip(tlDesc, "A local variable of this function.")
    else:
      (title, lines) = declLines(DeclRef(file: b.path, decl: an.decls[t.decl]), a.relScript(b.path))
    lines.add a.usesLines(a.usagesOf(b, an, ti), sym)
  of semFunc, semGlobal:
    let (ok, d) = a.findDecl(t.text)
    if ok:
      (title, lines) = declLines(d, a.relScript(d.file))
      lines.add tip(tlHint, "Ctrl+click or F12: go to its declaration · Shift+F12: list its uses")
  of semUnknownCall:
    title = t.text
    lines.add tip(tlDesc, "No command of the game or function of the level's scripts has this name.")
  of semNumber:
    if t.text.startsWith("f"): lines.add tip(tlDesc, "Written fN, the game reads " & numberValue(t.text) & ".")
  else: discard
  # Before those: which argument it is, and the object it names.
  var pre: seq[TipLine]
  if t.call >= 0 and t.arg >= 0:
    let c = an.calls[t.call]
    let f = formFor(an, defs, t.call)
    if t.arg < f.len: pre.add tip(tlDesc, "Argument " & f[t.arg].argText & " of " & c.name)
  let snd = a.soundTok(an, ti)
  if snd > 0 and soundKnown(t.soundName, snd == 2):
    pre.add tip(tlHint, "Ctrl+click: open it in the sound player")
  if t.refk == rkPartTag and t.kind in {tkIdent, tkString}:
    if title.len == 0: title = t.text
    for l in a.particleTagLines(t): pre.add l
  elif t.refk == rkPartCommand:
    if title.len == 0: title = t.partTag
    pre.add tip(tlDesc, ParticleCommandDocs.getOrDefault(t.partTag))
  elif t.refk == rkPartEvent:
    if title.len == 0: title = t.partTag
    let i = ParticleEvents.find(t.partTag)
    pre.add tip(tlDesc, "Particle event " & $i & ": sent to the particles with the tag, which run " &
      "their class's " & EventDefs[i].label & " actions. " & EventDefs[i].tip)
  let o = a.resolveTok(t)
  if o != nil:
    if title.len == 0: title = t.text
    pre.add tip(tlDesc, typeName(o.tag) & " " & o.label & " #" & $o.id & " in this level")
    pre.add tip(tlHint, "Ctrl+click: select it")
  elif t.refk in {rkCharName, rkTrgvName, rkPatrName, rkNeutName} and t.kind != tkNumber:
    pre.add tip(tlDesc, "No " & typeName(RefTags[t.refk]).toLowerAscii & " named " & t.text & " in this level")
  elif t.refk == rkFuncName:
    let (ok, d) = a.findDecl(t.text.strip(chars = {'"'}), funcsOnly = true)
    if ok:
      var dl: seq[TipLine]
      (title, dl) = declLines(d, a.relScript(d.file))
      lines.add dl
      lines.add tip(tlHint, "Ctrl+click: go to it")
  lines = pre & lines
  for dg in an.diags:
    if dg.line == t.line and t.col < dg.col + dg.len and dg.col < t.col + t.len:
      lines.add tip(if dg.error: tlError else: tlWarn, (if dg.error: "Error: " else: "Warning: ") & dg.msg)
  var kept: seq[TipLine]
  for l in lines:
    if l.text.strip.len > 0 or l.code.len > 0: kept.add l
  (title, kept)

# --- the sound player ------------------------------------------------------------------------
#
# Ctrl+click on a sound's name (an argument of sound_dialog_play,
# sound_ambient_start, sound_impulse_play, chr_talk... or a sound in the
# completion list) opens it in a small player at the text's bottom-right
# corner: play/pause, stop (back to the start), a seek bar and the place in
# seconds. It plays one run of the sound, rendered whole (music.nim's clip).
# The sound's names in the file and the player get a green outline. Esc stops
# it; Esc again (or its X) closes it. "Play on Ctrl+click" starts it at once.
# Its volume slider is Oni's 0..1, like a script's volume argument.

type MiniPlayer = object
  open: bool
  name: string          ## As written where it was opened.
  impulse: bool
  seeking: bool         ## The seek bar is held.
  seekAt: float         ## Where it's held (seconds).
  resume: bool          ## It was playing when the bar was taken: it plays on from there.
  volSave: bool         ## The volume changed: saved once the slider is let go.

var mini: MiniPlayer

let colSoundMark = hexCol("#3ddc84")   ## The open sound's outline: in the text, the list and the player.

const
  MiniW = 340'f32
  MiniH = 96'f32
  MiniSeekId = "scripts.mini.seek"

proc withSounds(a: App, what: string, play: proc())

proc isMiniSound(name: string): bool =
  mini.open and name.len > 0 and cmpIgnoreCase(name, mini.name) == 0

proc miniRect(area: Rect): Rect =
  ## The player: the text area's bottom-right corner, clear of its scrollbar.
  let w = min(MiniW, max(160'f32, area.w - 28))
  rect(area.x + area.w - 16 - w, area.y + area.h - 10 - MiniH, w, MiniH)

proc playMini(a: App) =
  setClipVolume(a.scriptSoundVolume)
  try: playClip()
  except CatchableError as e: a.say(e.msg, true)

proc closeMini() =
  unloadClip()
  mini = MiniPlayer()

proc miniEscape(): bool =
  ## Esc: stops a sound that plays (or waits mid-way), else closes the player.
  ## False when the player isn't open.
  if not mini.open: return false
  let pos = clipPosition()
  if clipPlaying() or (pos > 0 and pos < clipLength()): stopClip()
  else: closeMini()
  true

proc openSound(a: App, name: string, impulse: bool) =
  ## Ctrl+click on a sound: opens it in the player (playing it at once with
  ## "Play on Ctrl+click"). The one already open stays as it was rendered.
  let n = name.strip
  if n.len == 0: return
  if isMiniSound(n) and mini.impulse == impulse:
    if a.scriptSoundAutoplay:
      stopClip()
      a.playMini()
    return
  a.withSounds("sound", proc() =
    try: loadClip(n, impulse)
    except CatchableError as e:
      a.say(e.msg, true)
      return
    mini = MiniPlayer(open: true, name: n, impulse: impulse)
    if a.scriptSoundAutoplay: a.playMini())

proc drawMini(a: App, area: Rect, focused: bool) =
  let ui = a.ui
  let r = miniRect(area)
  if not mini.open: return
  # Esc with the mouse on it while the editor doesn't have the keyboard (editorKeys does it then).
  if not focused and ui.mouse.inside(r) and ui.window.buttonPressed[KeyEscape]:
    discard miniEscape()
    if not mini.open: return
  let playing = clipPlaying()
  let shownPlaying = playing or (mini.seeking and mini.resume)   # it plays on when the bar is let go
  let len = clipLength()
  if playing: a.animUntil = max(a.animUntil, epochTime() + 0.1)   # the bar moves
  # Clicks on it keep the keyboard in the editor (Esc).
  if ui.hover(r) and ui.pressed(): ui.focusId = EditorId
  ui.rect(rect(r.x + 3, r.y + 3, r.w, r.h), colShadow)
  ui.rect(r, colPopup)
  ui.border(r, colSoundMark)
  let x0 = r.x + 10
  let x1 = r.x + r.w - 8
  # The sound and the X.
  let closeR = rect(x1 - 22, r.y + 6, 22, 22)
  let kind = if mini.impulse: "impulse" else: "ambient"
  let kindW = ui.textSize(kind, FontSmall).x
  let nameW = max(20'f32, closeR.x - x0 - kindW - 14)
  let shown = ui.ellipsize(mini.name, nameW, FontMain)
  ui.textIn(shown, rect(x0, r.y + 6, nameW, 22), colCodeString)
  ui.textIn(kind, rect(x0 + ui.textSize(shown).x + 8, r.y + 6, kindW + 4, 22), colTextDim, FontSmall)
  if ui.iconButton("scripts.mini.close", closeR, "close16", "Close the player (Esc when stopped)", focusable = false):
    closeMini()
    return
  # Play/pause, stop, the seek bar and the place.
  let cy = r.y + 34
  let playR = rect(x0 - 4, cy, 26, 26)
  let stopR = rect(playR.x + 28, cy, 26, 26)
  if ui.iconButton("scripts.mini.play", playR, if shownPlaying: "pause16" else: "play16",
                   if shownPlaying: "Pause" else: "Play", focusable = false):
    if playing: pauseClip() else: a.playMini()
  if ui.iconButton("scripts.mini.stop", stopR, "stop16", "Stop: back to the start (Esc)", focusable = false):
    stopClip()
  let timeW = ui.textSize("000.000", FontMain).x + 6
  let bar = rect(stopR.x + stopR.w + 10, cy, max(20'f32, x1 - timeW - 8 - (stopR.x + stopR.w + 10)), 26)
  let barHov = ui.hover(bar)
  if barHov and ui.pressed() and len > 0:
    ui.consumeClick()
    ui.activeId = MiniSeekId
    mini.seeking = true
    mini.resume = playing
    if playing: pauseClip()
  if mini.seeking:
    mini.seekAt = clamp((ui.mouse.x - bar.x) / bar.w, 0, 1) * len
    if not ui.down():
      mini.seeking = false
      seekClip(mini.seekAt)
      if mini.resume: a.playMini()
  let pos = if mini.seeking: mini.seekAt else: clipPosition()
  let frac = if len > 0: clamp(pos / len, 0, 1).float32 else: 0'f32
  let my = bar.y + bar.h / 2
  ui.rect(rect(bar.x, my - 2, bar.w, 4), colTrack)
  ui.rect(rect(bar.x, my - 2, bar.w * frac, 4), colSoundMark)
  ui.icon("knob16", vec2(bar.x + bar.w * frac, my), if barHov or mini.seeking: colWhite else: colText)
  ui.tip(bar, "Seek: click or drag · " & formatFloat(len, ffDecimal, 3) & " s long")
  ui.textIn(formatFloat(pos, ffDecimal, 3), rect(x1 - timeW, cy, timeW, 26), colText, h = RightAlign)
  # Play on Ctrl+click.
  var auto = a.scriptSoundAutoplay
  if ui.checkbox("scripts.mini.auto", vec2(x0 - 2, r.y + 66), "Play on Ctrl+click", auto):
    a.scriptSoundAutoplay = auto
    a.saveLayout()
  # Volume: a speaker and a slider, right of the checkbox.
  const VolId = "scripts.mini.vol"
  let volX = x0 + 22 + ui.textSize("Play on Ctrl+click").x + 18
  let volR = rect(volX + 22, r.y + 66, max(30'f32, x1 - volX - 22 - 4), 22)
  let mute = a.scriptSoundVolume <= 0.05   # Oni's curve is silent from here down
  ui.icon("volume16", vec2(volX + 8, volR.y + volR.h / 2), if mute: colTextDisabled else: colTextDim)
  var vol = a.scriptSoundVolume
  if ui.slider(VolId, volR, vol, 0, 1, 0.05):
    a.scriptSoundVolume = vol
    mini.volSave = true
  setClipVolume(a.scriptSoundVolume)
  ui.tip(volR, "Volume " & formatFloat(a.scriptSoundVolume, ffDecimal, 2) & ", as in a script")
  if mini.volSave and ui.activeId != VolId:
    mini.volSave = false
    a.saveLayout()
  for id in ["scripts.mini.auto", VolId]:
    if ui.navId == id: ui.navId = ""   # Space and the arrows stay the editor's

proc linkTarget(a: App, an: Analysis, ti: int): (LevelObject, string) =
  ## What Ctrl+click on the token goes to: an object, or a declaration's name.
  let t = an.toks[ti]
  let o = a.resolveTok(t)
  if o != nil: return (o, "")
  if t.sem in {semFunc, semGlobal}: return (nil, t.text)
  if t.refk == rkFuncName: return (nil, t.text.strip(chars = {'"'}))

proc hasLink(a: App, an: Analysis, ti: int): bool =
  if an.toks[ti].refk == rkPartTag: return a.particleTok(an.toks[ti]).found
  let snd = a.soundTok(an, ti)
  if snd > 0: return soundKnown(an.toks[ti].soundName, snd == 2)
  let (o, name) = a.linkTarget(an, ti)
  if o != nil or (name.len > 0 and a.findDecl(name)[0]): return true
  let (sym, isDecl) = symAt(an, ti)
  (isDecl and sym.kind != skNone) or (sym.kind == skLocal and localDecl(an, ti) >= 0)

proc followLink(a: App, b: ScriptBuffer, an: Analysis, ti: int): bool =
  ## Ctrl+click or F12: an object gets selected; a declaration lists its uses;
  ## a use goes to its declaration; a sound opens in the sound player; a
  ## particle tag sends the views to its particles.
  if an.toks[ti].refk == rkPartTag:
    let p = a.particleTok(an.toks[ti])
    if not p.found: return false
    a.focusParticles(p, an.toks[ti].partTag)
    return true
  let snd = a.soundTok(an, ti)
  if snd > 0:
    if not soundKnown(an.toks[ti].soundName, snd == 2): return false
    a.openSound(an.toks[ti].soundName, snd == 2)
    return true
  let (o, name) = a.linkTarget(an, ti)
  if o != nil:
    a.focusObject(o)
    return true
  let (sym, isDecl) = symAt(an, ti)
  if isDecl and sym.kind != skNone:
    a.openUses(b, an, ti)
    return true
  if name.len > 0:
    let (ok, d) = a.findDecl(name)
    if ok:
      a.openScriptAt(d.file, d.decl.line, d.decl.col)
      return true
  if sym.kind == skLocal:
    let d = localDecl(an, ti)
    if d >= 0:
      a.openScriptAt(b.path, an.toks[d].line, an.toks[d].col)
      return true

proc semColor(a: App, t: Tok): ColorRGBX =
  case t.refk
  of rkPartCommand: return colCodePartCommand
  of rkPartEvent: return colCodePartEvent
  of rkPartTag:
    if a.particleTok(t).found: return colCodePartTag
  else: discard
  case t.sem
  of semComment: colCodeComment
  of semString: colCodeString
  of semNumber: colCodeNumber
  of semKeyword, semOperator: colCodeKeyword
  of semType: colCodeType
  of semPunct: colCodePunct
  of semCommand: colCodeCommand
  of semEngineVar: colCodeEngineVar
  of semFunc, semDeclName: colCodeFunc
  of semGlobal: colCodeGlobal
  of semLocal: colCodeLocal
  of semUnknownCall: colError
  of semBareWord, semPlain: colText

# --- what's at the caret ----------------------------------------------------------------------

type
  CaretRow = object
    ## One row of the tip above the caret: what something is, then it in code.
    what: string                ## "game function", "variable"... (small, light blue).
    code: string                ## Its signature or declaration.
    nameA, nameB: int           ## The name in code (nameCol), [nameA, nameB).
    nameCol: ColorRGBX
    hiA, hiB: int = -1          ## The part being typed (underlined), [hiA, hiB); -1: none.
    lead: int                   ## Where wrapped lines line up (its first parameter); 0: none.

proc callRow(a: App, an: Analysis, ci, arg: int): CaretRow =
  ## A call's signature, its name marked (arg -1) or argument arg. code ""
  ## when no command or function has its name.
  let e = a.scripts
  let c = an.calls[ci]
  if e.defs != nil and c.name in e.defs.commands:
    let cmd = e.defs.commands[c.name]
    let head = if cmd.ret != btVoid: $cmd.ret & " " else: ""
    result.what = if cmd.arklite: "Arklite function" else: "game function"
    result.code = head & cmd.name & (if cmd.spec.len > 0: " " & cmd.spec else: "")
    result.nameA = head.len
    result.nameB = head.len + cmd.name.len
    result.nameCol = colCodeCommand
    if cmd.spec.len > 0: result.lead = result.nameB + 1
    if arg < 0: (result.hiA, result.hiB) = (result.nameA, result.nameB)
    elif cmd.spec.len > 0:
      let ps = paramsAt(an, e.defs, ci, arg)
      if ps.len > 0 and ps[0].at >= 0 and ps[0].stop <= cmd.spec.len:
        (result.hiA, result.hiB) = (result.lead + ps[0].at, result.lead + ps[0].stop)
  elif c.name in e.index.funcs:
    let d = e.index.funcs[c.name].decl
    var code = "func " & (if d.typ.len > 0: d.typ else: "void") & " "
    result.nameA = code.len
    code.add d.name
    result.nameB = code.len
    code.add "("
    result.lead = code.len
    for k, (t, n) in d.params:
      if k > 0: code.add ", "
      let p0 = code.len
      code.add (if n.len > 0: t & " " & n else: t)
      if k == arg and n.len > 0: (result.hiA, result.hiB) = (p0, code.len)
    code.add ")"
    if arg < 0: (result.hiA, result.hiB) = (result.nameA, result.nameB)
    result.what = "function"
    result.nameCol = colCodeFunc
    result.code = code

proc wordRow(a: App, b: ScriptBuffer, an: Analysis, ti: int): CaretRow =
  ## What the word at the caret is; what "" for nothing to say.
  let e = a.scripts
  let t = an.toks[ti]
  proc named(r: var CaretRow, what, code: string, nameAt: int, col: ColorRGBX) =
    r.what = what
    r.code = code
    r.nameA = nameAt
    r.nameB = nameAt + t.text.len
    r.nameCol = col
  case t.sem
  of semCommand, semFunc:
    if t.call >= 0 and an.calls[t.call].tok == ti: return a.callRow(an, t.call, -1)
    let (ok, d) = a.findDecl(t.text, funcsOnly = true)
    if ok:
      let title = declLines(d, "")[0]
      result.named("function", title, max(0, title.find(" " & t.text & "(") + 1), colCodeFunc)
    elif e.defs != nil and t.text in e.defs.commands:
      result.named(if e.defs.commands[t.text].arklite: "Arklite function" else: "game function", t.text, 0, colCodeCommand)
  of semEngineVar:
    if e.defs != nil and t.text in e.defs.variables:
      let v = e.defs.variables[t.text]
      let head = $v.typ & " "
      result.named(if v.arklite: "Arklite variable" else: "game variable", head & v.name, head.len, colCodeEngineVar)
  of semGlobal:
    let (ok, d) = a.findDecl(t.text)
    if ok:
      let head = "var " & d.decl.typ & " "
      result.named("variable", head & t.text, head.len, colCodeGlobal)
  of semLocal:
    let (tt, isArg) = localTitle(an, ti)
    result.named(if isArg: "argument" else: "local variable", tt, tt.len - t.text.len, colCodeLocal)
  of semDeclName:
    if t.decl >= 0:
      let d = an.decls[t.decl]
      if d.isFunc:
        let title = declLines(DeclRef(file: b.path, decl: d), "")[0]
        result.named("function", title, max(0, title.find(" " & t.text & "(") + 1), colCodeFunc)
      else:
        let head = "var " & d.typ & " "
        result.named("variable", head & t.text, head.len, colCodeGlobal)
    else:
      let (tt, isArg) = localTitle(an, ti)
      result.named(if isArg: "argument" else: "local variable", tt, tt.len - t.text.len, colCodeLocal)
  of semKeyword: result.named("keyword", t.text, 0, colCodeKeyword)
  of semType: result.named("type", t.text, 0, colCodeType)
  of semOperator: result.named("operator", t.text, 0, colCodeKeyword)
  of semNumber, semString:
    let what = if t.sem == semString: "string value" elif '.' in t.text: "float value" else: "int value"
    result.named(what, t.text, 0, if t.sem == semString: colCodeString else: colCodeNumber)
    # The level object it names.
    let o = a.resolveTok(t)
    if o != nil:
      result.code.add "  → " & typeName(o.tag) & (if o.label.len > 0: " " & o.label else: "") & " #" & $o.id
  of semUnknownCall:
    if not e.compOpen: result.named("unknown function", t.text, 0, colError)
  of semBareWord, semPlain:
    if t.kind != tkIdent: return
    if t.refk == rkPartCommand:
      result.named("particle command", t.text, 0, colCodePartCommand)
      return
    if t.refk == rkPartEvent:
      result.named("particle event", t.text, 0, colCodePartEvent)
      return
    if t.refk == rkPartTag:
      let p = a.particleTok(t)
      if p.found:
        result.named("particle tag", t.text & "  → " & p.partWhat, 0, colCodePartTag)
        return
    let o = a.resolveTok(t)
    if o != nil:
      result.named("string value", t.text & "  → " & typeName(o.tag) & " #" & $o.id, 0, a.semColor(t))
    elif t.call >= 0: result.named("string value", t.text, 0, a.semColor(t))
    elif not e.compOpen: result.named("unknown name", t.text, 0, colTextDim)
  else: discard

proc caretRows(a: App, b: ScriptBuffer, an: Analysis): seq[CaretRow] =
  ## The tip above the caret: the call it's in (the part being typed marked)
  ## and what the word it's on is.
  let (line, col) = b.caret
  # The word it's in or right after (the one being typed), not a comment.
  var ti = -1
  for i, t in an.toks:
    if t.line == line and t.kind != tkPunct and col >= t.col and col <= t.col + t.len:
      if t.kind == tkComment:
        if col > t.col: return
        continue
      if ti < 0 or t.col + t.len == col: ti = i
  var ci = -1
  var arg = -1
  if ti >= 0 and an.toks[ti].call >= 0:
    ci = an.toks[ti].call
    arg = an.toks[ti].arg
  else:
    let ctx = caretContext(an, b.lines, line, col)
    if ctx.kind == ckArg:
      ci = ctx.call
      arg = ctx.arg
  var nameRow = false
  if ci >= 0:
    let r = a.callRow(an, ci, arg)
    if r.code.len > 0:
      result.add r
      nameRow = arg < 0
  if ti >= 0 and not nameRow:
    let r = a.wordRow(b, an, ti)
    if r.what.len > 0: result.add r

proc drawCodeTip(a: App, anchor: Rect, title: string, lines: seq[TipLine]) =
  ## A hover box: the title in the code font, then its lines, each kind in its
  ## own color (descriptions in the text color, places light blue, hints dim,
  ## code in the code font), a gap where the kind changes.
  let ui = a.ui
  if title.len == 0 and lines.len == 0: return
  const PadX = 12'f32
  const PadY = 9'f32
  const MaxW = 540'f32
  # Never wider than the window; long titles and code wrap instead of being cut.
  let codeMax = max(120'f32, min(MaxW + 20, ui.size.x - 8 - PadX * 2))
  let descMax = min(MaxW, codeMax)
  let monoH = ui.textSize("Ag", FontMono).y
  let smallH = ui.textSize("Ag", FontSmall).y
  let charW = ui.textSize("0000000000", FontMono).x / 10
  type Row = object
    kind: TipKind
    text, code: string
    mono: bool
    gap: float32               ## Space above it.
  var rows: seq[Row]
  var prev = TipKind.high
  for i, l in lines:
    let gap = if i == 0: 0'f32
              elif l.kind == prev or (l.kind == tlUse and prev == tlDesc) or
                   (l.kind == tlCode and prev == tlWhere): 0'f32
              else: 6'f32
    prev = l.kind
    case l.kind
    of tlCode:
      # Continuation lines indented by two characters.
      for k, sl in ui.wrapCode(l.text, codeMax, FontMono, 2 * charW):
        rows.add Row(kind: tlCode, text: (if k > 0: "  " else: "") & l.text[sl], gap: if k == 0: gap else: 0)
    of tlUse: rows.add Row(kind: tlUse, text: l.text, code: l.code, mono: l.mono, gap: gap)
    else:
      for k, w in ui.wrapText(l.text, descMax, 1000, FontSmall):
        rows.add Row(kind: l.kind, text: w, gap: if k == 0: gap else: 0)
  proc rowH(r: Row): float32 = (if r.kind == tlCode or (r.kind == tlUse and r.mono): monoH else: smallH) + 3
  # The title (a signature) breaks between parameters; the lines after the
  # first line up under its first parameter, or two characters in when the
  # name is long.
  var titleLines: seq[string]
  if title.len > 0:
    # Where the first parameter starts: after "(" in a function's
    # declaration, else after the name (past a return type in front of it).
    var lead = title.find('(') + 1
    if lead == 0:
      let words = title.split(' ')
      let skip = if words.len > 2 and words[0] in ["int", "float", "string", "bool"]: 2 else: 1
      if words.len > skip: lead = words[0 ..< skip].join(" ").len + 1
    let leadW = if lead > 0 and ui.textSize(title[0 ..< lead], FontMono).x <= codeMax * 0.4:
                  ui.textSize(title[0 ..< lead], FontMono).x
                else: 2 * charW
    let pad = max(1, int(leadW / charW + 0.5))
    for k, sl in ui.wrapCode(title, codeMax, FontMono, pad.float32 * charW):
      titleLines.add (if k > 0: " ".repeat(pad) else: "") & title[sl]
  var w = 0'f32
  for t in titleLines: w = max(w, ui.textSize(t, FontMono).x)
  for r in rows:
    case r.kind
    of tlCode: w = max(w, ui.textSize(r.text, FontMono).x)
    of tlUse: w = max(w, ui.textSize(r.text, FontSmall).x + 10 +
                         ui.textSize(r.code, if r.mono: FontMono else: FontSmall).x)
    else: w = max(w, ui.textSize(r.text, FontSmall).x)
  w = min(w + 4, codeMax) + PadX * 2   # +4: exact widths would make ellipsize cut the widest line
  var h = PadY * 2
  if titleLines.len > 0: h += titleLines.len.float32 * (monoH + 2) - 2 + (if rows.len > 0: 7 else: 0)
  for r in rows: h += r.gap + r.rowH
  var p = vec2(anchor.x, anchor.y - h - 4)
  if p.y < 4: p.y = anchor.y + anchor.h + 4
  p.x = clamp(p.x, 4, max(4'f32, ui.size.x - w - 4))
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(p.x + 3, p.y + 3, w, h), colShadow)
  ui.rect(rect(p, vec2(w, h)), colTipBg)
  ui.border(rect(p, vec2(w, h)), colBorder)
  let inner = w - PadX * 2
  var y = p.y + PadY
  for t in titleLines:
    ui.text(t, vec2(p.x + PadX, y), colCodeCommand, FontMono)
    y += monoH + 2
  if titleLines.len > 0: y += 5
  for r in rows:
    y += r.gap
    let x = p.x + PadX
    case r.kind
    of tlCode: ui.text(r.text, vec2(x, y), colCodeString, FontMono)
    of tlUse:
      let ww = min(ui.textSize(r.text, FontSmall).x, inner * 0.6)
      let rh = r.rowH - 3
      ui.text(ui.ellipsize(r.text, ww, FontSmall), vec2(x, y + (rh - smallH) / 2), colTipWhere, FontSmall)
      let f = if r.mono: FontMono else: FontSmall
      ui.text(ui.ellipsize(r.code, inner - ww - 10, f), vec2(x + ww + 10, y + (rh - ui.textSize("Ag", f).y) / 2),
              if r.mono: colCodeString else: colText, f)
    else:
      let col = case r.kind
                of tlWhere: colTipWhere
                of tlHint: colTextDim
                of tlError: colError
                of tlWarn: colWarn
                else: colText
      ui.text(r.text, vec2(x, y), col, FontSmall)
    y += r.rowH
  ui.sk.popLayer()

# --- the editor ---------------------------------------------------------------------------------

proc closeBuffer(a: App, i: int) =
  let e = a.scripts
  bufDecls.del e.buffers[i].path
  e.buffers.delete i
  if e.active >= e.buffers.len: e.active = e.buffers.high
  e.compOpen = false
  if e.buffers.len == 0 and a.ui.focusId == EditorId: a.ui.focusId = ""

proc newScriptFile(a: App) =
  let dir = a.scriptRoot / a.proj.envName
  a.askName("New script file", a.proj.envName.toLowerAscii & "_new.bsl", proc(name: string) =
    var n = name.strip
    if n.len == 0: return
    if not n.toLowerAscii.endsWith(".bsl"): n.add ".bsl"
    let path = dir / n
    if fileExists(path):
      a.say(n & " already exists", true)
    else:
      createDir(dir)
      writeFile(path, "# " & n & "\n\n")
      a.scripts.filesChecked = 0
      a.say("Created " & a.relScript(path))
    a.openScriptAt(path, 2, 0))

proc findMatches(b: ScriptBuffer, text: string, matchCase, wholeWord: bool): seq[Pos] =
  ## Where text is found, in order, not overlapping: in any case unless
  ## matchCase; with wholeWord, only where no letter, digit or _ touches it.
  if text.len == 0: return
  let nd = if matchCase: text else: text.toLowerAscii
  for l, line in b.lines:
    let hay = if matchCase: line else: line.toLowerAscii
    var k = hay.find(nd)
    while k >= 0:
      if not wholeWord or ((k == 0 or line[k - 1] notin IdentChars) and
                           (k + nd.len >= line.len or line[k + nd.len] notin IdentChars)):
        result.add (l, k)
        k = hay.find(nd, k + nd.len)
      else: k = hay.find(nd, k + 1)

proc findNext(a: App, b: ScriptBuffer, back = false) =
  ## Selects the next (back: previous) match of the find text, wrapping around.
  let e = a.scripts
  let needle = e.findText
  if needle.len == 0: return
  let hits = b.findMatches(needle, e.findCase, e.findWord)
  if hits.len == 0:
    a.say("Not found: " & a.scripts.findText)
    return
  let (s0, s1) = b.selRange
  var pick = -1
  if back:
    for i in countdown(hits.high, 0):
      if hits[i] < s0:
        pick = i
        break
    if pick < 0: pick = hits.high
  else:
    for i, h in hits:
      if s1 <= h and not (h == s0 and b.hasSelection):
        pick = i
        break
    if pick < 0: pick = 0
  b.anchor = hits[pick]
  b.caret = (hits[pick].line, hits[pick].col + needle.len)
  revealCaret = true

proc toggleComment(b: ScriptBuffer) =
  ## Ctrl+/: # in front of the selected lines (or removed when all have one).
  let (s0, s1) = b.selRange
  let last = if s1.col == 0 and s1.line > s0.line: s1.line - 1 else: s1.line
  var all = true
  for l in s0.line .. last:
    if b.lines[l].strip.len > 0 and not b.lines[l].strip.startsWith("#"): all = false
  let before = b.textIn((s0.line, 0), (last, b.lines[last].len))
  var lines = before.split('\n')
  for i, s in lines.mpairs:
    let ind = s.indentOf
    if all:
      if s.strip.startsWith("#"):
        var rest = s[ind.len + 1 .. ^1]
        if rest.startsWith(" "): rest = rest[1 .. ^1]
        s = ind & rest
    elif s.strip.len > 0: s = ind & "# " & s[ind.len .. ^1]
  b.replace((s0.line, 0), (last, b.lines[last].len), lines.join("\n"), now = epochTime())
  b.anchor = (s0.line, 0)
  b.caret = (last, b.lines[last].len)

proc indentLines(b: ScriptBuffer, outdent: bool) =
  let (s0, s1) = b.selRange
  let last = if s1.col == 0 and s1.line > s0.line: s1.line - 1 else: s1.line
  var lines = b.textIn((s0.line, 0), (last, b.lines[last].len)).split('\n')
  for s in lines.mitems:
    if outdent:
      if s.startsWith("\t"): s = s[1 .. ^1]
      else:
        var k = 0
        while k < TabCols and k < s.len and s[k] == ' ': inc k
        s = s[k .. ^1]
    elif s.len > 0: s = "\t" & s
  b.replace((s0.line, 0), (last, b.lines[last].len), lines.join("\n"), now = epochTime())
  b.anchor = (s0.line, 0)
  b.caret = (last, b.lines[last].len)

proc setCodeFontSize(a: App, b: ScriptBuffer, px: int) =
  ## Changes the editor's text size, keeping the same lines and columns in view.
  if px == a.codeFontSize: return
  let ui = a.ui
  let (o, n) = (codeFont(a.codeFontSize), codeFont(px))
  b.scrollY *= round(ui.textSize("Ag", n).y) / round(ui.textSize("Ag", o).y)
  b.scrollX *= ui.textSize("0000000000", n).x / ui.textSize("0000000000", o).x
  a.codeFontSize = px

proc startRename(a: App, b: ScriptBuffer)
proc copyText(b: ScriptBuffer, cut: bool): bool

# --- several cursors ---------------------------------------------------------------------------
# Ctrl+D adds the next occurrence of the selection (from a bare cursor it
# first selects the word, then adds whole-word matches), Alt+click adds a
# cursor, Ctrl+Alt+Up/Down one on the line above/below. Typing, deleting,
# Enter, Tab, paste and the arrows act at every cursor; each edit is one undo
# step. Esc or a click goes back to one cursor. Ctrl+Shift+D duplicates the
# cursors' lines, Ctrl+T swaps the selections' texts around (one cursor
# without a selection: the characters either side of it).

type Edit = tuple[a, z: Pos, s: string]

proc wordLeftCol(s: string, col: int): int =
  result = col
  while result > 0 and s[result - 1] in {' ', '\t'}: dec result
  if result > 0 and s[result - 1] in IdentChars:
    while result > 0 and s[result - 1] in IdentChars: dec result
  elif result == col and result > 0: dec result

proc wordRightCol(s: string, col: int): int =
  result = col
  if result < s.len and s[result] in IdentChars:
    while result < s.len and s[result] in IdentChars: inc result
  elif result < s.len: inc result
  while result < s.len and s[result] in {' ', '\t'}: inc result

proc primaryIndex(b: ScriptBuffer, cs: seq[Sel]): int =
  for i, c in cs:
    if c.caret == b.caret and c.anchor == b.anchor: return i
  cs.high

proc editAt(b: ScriptBuffer, f: proc(c: Sel): Edit, group = 0) =
  ## One edit per cursor, as one undo step; each cursor ends after its text.
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var edits: seq[Edit]
  for c in cs: edits.add f(c)
  let ends = b.multiEdit(edits, group)
  var ns: seq[Sel]
  for p in ends: ns.add (p, p)
  b.setCursors(ns, ns[pi])

proc linesOf(c: Sel): (int, int) =
  ## The lines a cursor's selection covers (not a last line it ends at the start of).
  let a = c.selStart
  let z = c.selEnd
  (a.line, if z.line > a.line and z.col == 0: z.line - 1 else: z.line)

proc lineEdits(b: ScriptBuffer, f: proc(line: int): Edit) =
  ## An edit on each line the cursors are on (once per line), the cursors kept in place.
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var ls: seq[int]
  for c in cs:
    let (l0, l1) = c.linesOf
    for l in l0 .. l1:
      if ls.len == 0 or ls[^1] < l: ls.add l
  var edits: seq[Edit]
  for l in ls:
    let e = f(l)
    if e.a != e.z or e.s.len > 0: edits.add e
  if edits.len == 0: return
  let ends = b.multiEdit(edits)
  var ns: seq[Sel]
  for c in cs: ns.add (mapPos(c.caret, edits, ends), mapPos(c.anchor, edits, ends))
  b.setCursors(ns, ns[pi])

proc addNextOccurrence(a: App, b: ScriptBuffer) =
  ## Ctrl+D.
  if b.caret == b.anchor:
    let (wa, wb) = wordAt(b.lines[b.caret.line], b.caret.col)
    if wa == wb: return
    b.anchor = (b.caret.line, wa)
    b.caret = (b.caret.line, wb)
    b.wordSel = (b.caret, b.anchor)
    return
  let (s0, s1) = b.selRange
  if s0.line != s1.line:
    a.say("Ctrl+D: select text within one line", true)
    return
  let needle = b.textIn(s0, s1)
  let whole = b.wordSel == (b.caret, b.anchor) or b.extra.len > 0 and b.wordSel.caret.line >= 0 and
              b.textIn(b.wordSel.selStart, b.wordSel.selEnd) == needle and b.wordSel in b.extra
  var taken: HashSet[Pos]
  for c in b.cursors: taken.incl c.selStart
  proc wordEdge(l, c: int): bool =
    let s = b.lines[l]
    (c == 0 or s[c - 1] notin IdentChars) and (c + needle.len >= s.len or s[c + needle.len] notin IdentChars)
  # From the end of the newest selection on, then from the top.
  let n = b.lines.len
  for k in 0 .. n:
    let l = (s1.line + k) mod n
    var from0 = if k == 0: s1.col else: 0
    let s = b.lines[l]
    var c = s.find(needle, from0)
    while c >= 0:
      if (k < n or c < s1.col) and (l, c) notin taken and (not whole or wordEdge(l, c)):
        b.extra.add (b.caret, b.anchor)
        b.anchor = (l, c)
        b.caret = (l, c + needle.len)
        revealCaret = true
        return
      c = s.find(needle, c + 1)
  a.say("Every " & (if whole: "\"" & needle & "\" word" else: "\"" & needle & "\"") & " is selected (" &
        $(b.extra.len + 1) & ")")

proc duplicateLines(b: ScriptBuffer) =
  ## Ctrl+Shift+D: a copy of the cursors' lines below them; the cursors go to the copy.
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var ranges: seq[(int, int)]
  for c in cs:
    let r = c.linesOf
    if ranges.len > 0 and r[0] <= ranges[^1][1]: ranges[^1][1] = max(ranges[^1][1], r[1])
    else: ranges.add r
  var edits: seq[Edit]
  for (l0, l1) in ranges:
    edits.add ((l1, b.lines[l1].len), (l1, b.lines[l1].len), "\n" & b.lines[l0 .. l1].join("\n"))
  discard b.multiEdit(edits)
  # Each cursor moves down by the lines copied above it and its own block's.
  var ns: seq[Sel]
  for c in cs:
    var shift = 0
    for (l0, l1) in ranges:
      if l0 <= c.selStart.line: shift += l1 - l0 + 1
    ns.add ((c.caret.line + shift, c.caret.col), (c.anchor.line + shift, c.anchor.col))
  b.setCursors(ns, ns[pi])

proc moveLines(b: ScriptBuffer, dir: int) =
  ## Ctrl+Shift+Up/Down: the lines the cursors are on (touching blocks move
  ## together) swap with the line above or below them; the cursors go along.
  ## Nothing moves past the first or last line. One undo step.
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var ranges: seq[(int, int)]
  for c in cs:
    let r = c.linesOf
    if ranges.len > 0 and r[0] <= ranges[^1][1] + 1: ranges[^1][1] = max(ranges[^1][1], r[1])
    else: ranges.add r
  if (dir < 0 and ranges[0][0] == 0) or (dir > 0 and ranges[^1][1] == b.lines.high): return
  let lo = if dir < 0: ranges[0][0] - 1 else: ranges[0][0]
  let hi = if dir < 0: ranges[^1][1] else: ranges[^1][1] + 1
  var ls = b.lines[lo .. hi]
  for (l0, l1) in ranges:
    # In ls, the block is at l0 - lo .. l1 - lo; the line it swaps with is next to it.
    let a = l0 - lo
    let z = l1 - lo
    if dir < 0:
      let above = ls[a - 1]
      for k in a - 1 ..< z: ls[k] = ls[k + 1]
      ls[z] = above
    else:
      let below = ls[z + 1]
      for k in countdown(z + 1, a + 1): ls[k] = ls[k - 1]
      ls[a] = below
  b.replace((lo, 0), (hi, b.lines[hi].len), ls.join("\n"))
  var ns: seq[Sel]
  for c in cs: ns.add ((c.caret.line + dir, c.caret.col), (c.anchor.line + dir, c.anchor.col))
  b.setCursors(ns, ns[pi])

proc transpose(a: App, b: ScriptBuffer) =
  ## Ctrl+T: with two or more selections, each takes the text of the one
  ## before it (the first the last's: two swap); at a bare cursor, the
  ## characters either side of it swap.
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var sels: seq[int]
  for i, c in cs:
    if c.caret != c.anchor: sels.add i
  if sels.len >= 2:
    var edits: seq[Edit]
    for k, i in sels:
      let prev = cs[sels[(k - 1 + sels.len) mod sels.len]]
      edits.add (cs[i].selStart, cs[i].selEnd, b.textIn(prev.selStart, prev.selEnd))
    let ends = b.multiEdit(edits)
    var ns: seq[Sel]
    for k, e in edits: ns.add (ends[k], mapPos(e.a, edits[0 ..< k], ends[0 ..< k]))
    b.setCursors(ns, ns[min(pi, ns.high)])
    return
  if sels.len == 1:
    a.say("Ctrl+T swaps the texts of two or more selections (Ctrl+D adds one), or the characters at a cursor", true)
    return
  var edits: seq[Edit]
  for c in cs:
    let s = b.lines[c.caret.line]
    var k = c.caret.col
    if k >= s.len: k = s.len - 1
    if k < 1: continue
    edits.add ((c.caret.line, k - 1), (c.caret.line, k + 1), $s[k] & $s[k - 1])
  if edits.len == 0: return
  let ends = b.multiEdit(edits)
  var ns: seq[Sel]
  for p in ends: ns.add (p, p)
  b.setCursors(ns, ns[min(pi, ns.high)])

proc addCursorVertical(b: ScriptBuffer, dir: int) =
  ## Ctrl+Alt+Up/Down: a cursor on the line above the top one or below the bottom one.
  let cs = b.cursors
  let edge = if dir < 0: cs[0].caret else: cs[^1].caret
  let l = edge.line + dir
  if l < 0 or l > b.lines.high: return
  let x = vcol(b.lines[edge.line], edge.col).float32
  let p: Pos = (l, colAt(b.lines[l], x))
  b.setCursors(cs & @[(p, p)], (p, p))
  revealCaret = true

proc multiKeys(a: App, b: ScriptBuffer, pageLines: int): bool =
  ## The keys while there are several cursors; whether the text changed.
  let w = a.window
  let ctrl = w.ctrl
  let shift = w.shiftDown
  template key(k: Button): bool = w.buttonPressed[k] and not (k == KeyEscape and escTaken)
  a.scripts.compOpen = false
  if key(KeyEscape):
    b.extra.setLen 0
    return
  if ctrl and (key(KeyZ) or key(KeyY)):
    discard (if (key(KeyZ) and shift) or key(KeyY): b.redoStep() else: b.undoStep())
    revealCaret = true
    return true
  if ctrl and key(KeyA):
    b.extra.setLen 0
    b.anchor = (0, 0)
    b.caret = (b.lines.high, b.lines[^1].len)
    return
  if ctrl and key(KeySlash):
    b.extra.setLen 0
    b.toggleComment()
    return true
  if ctrl and (key(KeyC) or key(KeyX)):
    let cs = b.cursors
    var parts: seq[string]
    let anySel = cs.anyIt(it.caret != it.anchor)
    for c in cs:
      parts.add (if anySel: b.textIn(c.selStart, c.selEnd) else: b.lines[c.caret.line])
    setClipboardString(parts.join("\n") & (if anySel: "" else: "\n"))
    if key(KeyX):
      if anySel: b.editAt(proc(c: Sel): Edit = (c.selStart, c.selEnd, ""))
      else:
        b.lineEdits(proc(l: int): Edit =
          if l < b.lines.high: ((l, 0), (l + 1, 0), "") else: ((l, 0), (l, b.lines[l].len), ""))
      return true
    return
  if ctrl and key(KeyV):
    let text = getClipboardString().replace("\r\n", "\n").replace("\r", "\n")
    var parts = text.split('\n')
    if parts.len > 1 and parts[^1].len == 0: parts.setLen parts.len - 1
    let n = b.cursors.len
    var i = -1
    b.editAt(proc(c: Sel): Edit =
      inc i
      (c.selStart, c.selEnd, if parts.len == n: parts[i] else: text))
    return true
  var typed = ""
  for ch in a.ui.typed:
    if ch.ord >= 0x20 and ch.ord != 0x7f: typed.add ch
  if typed.len > 0 and not ctrl:
    # A run of word characters, each within a second of the last, undoes as one
    # step (as typing at one cursor does).
    let now = epochTime()
    let word = typed.allCharsInSet(IdentChars)
    if not (word and b.typeWord and now - b.typeTime < 1.0 and b.typeGroup != 0 and b.undoGroup == b.typeGroup):
      inc b.groupSeq
      b.typeGroup = b.groupSeq
    b.typeTime = now
    b.typeWord = word
    b.editAt(proc(c: Sel): Edit = (c.selStart, c.selEnd, typed), b.typeGroup)
    return true
  if key(KeyEnter) or key(NumpadEnter):
    b.editAt(proc(c: Sel): Edit =
      let st = c.selStart
      let line = b.lines[st.line]
      var ind = line.indentOf
      if line[0 ..< min(st.col, line.len)].strip.endsWith("{"): ind.add "\t"
      (st, c.selEnd, "\n" & ind))
    return true
  if key(KeyTab):
    let multiLine = b.cursors.anyIt(it.linesOf[0] != it.linesOf[1])
    if shift:
      b.lineEdits(proc(l: int): Edit =
        let s = b.lines[l]
        var k = 0
        if s.startsWith("\t"): k = 1
        else:
          while k < min(TabCols, s.len) and s[k] == ' ': inc k
        ((l, 0), (l, k), ""))
    elif multiLine: b.lineEdits(proc(l: int): Edit = ((l, 0), (l, 0), "\t"))
    else: b.editAt(proc(c: Sel): Edit = (c.selStart, c.selEnd, "\t"))
    return true
  if key(KeyBackspace):
    b.editAt(proc(c: Sel): Edit =
      if c.caret != c.anchor: return (c.selStart, c.selEnd, "")
      let p = c.caret
      if p.col > 0: ((p.line, if ctrl: wordLeftCol(b.lines[p.line], p.col) else: p.col - 1), p, "")
      elif p.line > 0: ((p.line - 1, b.lines[p.line - 1].len), p, "")
      else: (p, p, ""))
    return true
  if key(KeyDelete):
    b.editAt(proc(c: Sel): Edit =
      if c.caret != c.anchor: return (c.selStart, c.selEnd, "")
      let p = c.caret
      let s = b.lines[p.line]
      if p.col < s.len: (p, (p.line, if ctrl: wordRightCol(s, p.col) else: p.col + 1), "")
      elif p.line < b.lines.high: (p, (p.line + 1, 0), "")
      else: (p, p, ""))
    return true
  # The arrows, Home and End move every cursor (Shift selects).
  var moveKey = KeyEscape
  for k in [KeyLeft, KeyRight, KeyUp, KeyDown, KeyHome, KeyEnd, KeyPageUp, KeyPageDown]:
    if key(k): moveKey = k
  if moveKey == KeyEscape: return
  let cs = b.cursors
  let pi = b.primaryIndex(cs)
  var ns: seq[Sel]
  for c in cs:
    let p = c.caret
    let s = b.lines[p.line]
    proc vert(n: int): Pos =
      let l = clamp(p.line + n, 0, b.lines.high)
      (l, colAt(b.lines[l], vcol(s, p.col).float32))
    var q = p
    case moveKey
    of KeyLeft:
      if c.caret != c.anchor and not shift: q = c.selStart
      elif ctrl: q = (if p.col == 0 and p.line > 0: (p.line - 1, b.lines[p.line - 1].len) else: (p.line, wordLeftCol(s, p.col)))
      elif p.col > 0: q = (p.line, p.col - 1)
      elif p.line > 0: q = (p.line - 1, b.lines[p.line - 1].len)
    of KeyRight:
      if c.caret != c.anchor and not shift: q = c.selEnd
      elif ctrl: q = (if p.col == s.len and p.line < b.lines.high: (p.line + 1, 0) else: (p.line, wordRightCol(s, p.col)))
      elif p.col < s.len: q = (p.line, p.col + 1)
      elif p.line < b.lines.high: q = (p.line + 1, 0)
    of KeyUp: q = vert(-1)
    of KeyDown: q = vert(1)
    of KeyPageUp: q = vert(-pageLines)
    of KeyPageDown: q = vert(pageLines)
    of KeyHome:
      let ind = s.indentOf.len
      q = (p.line, if p.col == ind: 0 else: ind)
    of KeyEnd: q = (p.line, s.len)
    else: discard
    ns.add (q, if shift: c.anchor else: q)
  b.setCursors(ns, ns[pi])
  revealCaret = true


proc atAutoClose(b: ScriptBuffer): bool =
  ## The caret is right before the ) a function from the list got.
  if autoClose.buf != b or autoClose.line != b.caret.line or b.extra.len > 0 or b.hasSelection: return
  let s = b.lines[b.caret.line]
  let i = s.len - autoClose.fromEnd
  i == b.caret.col and i in 0 ..< s.len and s[i] == ')'

proc editorKeys(a: App, b: ScriptBuffer, pageLines: int) =
  ## The keyboard while the editor has it.
  let w = a.window
  let ui = a.ui
  let e = a.scripts
  let ctrl = w.ctrl
  let shift = w.shiftDown
  let now = epochTime()
  ui.tabTaken = true
  var changed = false
  var moved = false
  var typedSpace = false
  template key(k: Button): bool = w.buttonPressed[k] and not (k == KeyEscape and escTaken)
  proc moveTo(p: Pos, keepX = false) =
    b.caret = b.clampPos(p)
    if not shift: b.anchor = b.caret
    if not keepX: b.wantX = -1
    moved = true
  proc deleteSel() =
    let (s0, s1) = b.selRange
    b.replace(s0, s1, "", now = now)
    changed = true
  proc put(s: string, typing = false) =
    let (s0, s1) = b.selRange
    b.replace(s0, s1, s, typing, now)
    changed = true

  # The list of uses takes its keys first.
  if refsOpen:
    let n = refsList.len
    if key(KeyEscape):
      refsOpen = false
      return
    if n > 0:
      if key(KeyDown):
        refsHi = (refsHi + 1) mod n
        return
      if key(KeyUp):
        refsHi = (refsHi - 1 + n) mod n
        return
      if key(KeyEnter) or key(NumpadEnter):
        refsOpen = false
        a.gotoUsage(refsList[clamp(refsHi, 0, n - 1)])
        return
  # The completion list takes its keys first.
  if e.compOpen:
    let n = e.compItems.len
    if key(KeyEscape):
      e.compOpen = false
      return
    if key(KeyDown):
      e.compHi = (e.compHi + 1) mod n
      return
    if key(KeyUp):
      e.compHi = (e.compHi - 1 + n) mod n
      return
    if key(KeyPageDown):
      e.compHi = min(n - 1, e.compHi + CompRows)
      return
    if key(KeyPageUp):
      e.compHi = max(0, e.compHi - CompRows)
      return
    if key(KeyEnter) or key(NumpadEnter) or key(KeyTab):
      a.acceptCompletion(b)
      revealCaret = true
      return
  if key(KeyEscape):
    if b.extra.len > 0: b.extra.setLen 0
    elif miniEscape(): discard
    elif e.findOpen: e.findOpen = false
    elif e.caretTip and caretTipDrawn: e.caretTip = false
    else: ui.focusId = ""
    return
  if ctrl and key(KeySpace):
    a.updateCompletion(b, force = true)
    return
  if ctrl and key(KeyS):
    a.saveProject()
    return
  if ctrl and (key(Key0) or key(Numpad0)):
    a.setCodeFontSize(b, DefaultCodeFontSize)
    return
  if ctrl and key(KeyF):
    e.findOpen = true
    e.findFocus = true
    if b.hasSelection and b.caret.line == b.anchor.line:
      let (s0, s1) = b.selRange
      e.findText = b.textIn(s0, s1)
    return
  if key(KeyF3):
    a.findNext(b, back = shift)
    return
  if key(KeyF2):
    a.startRename(b)
    return
  if key(KeyF12):
    let an = a.analysisOf(b)
    let ti = an.tokAt(b.caret.line, b.caret.col)
    if ti >= 0:
      if shift: a.openUses(b, an, ti)
      else: discard a.followLink(b, an, ti)
    return
  if ctrl and key(KeyD):
    if shift: b.duplicateLines()
    else: a.addNextOccurrence(b)
    e.compOpen = false
    revealCaret = true
    return
  if ctrl and key(KeyT):
    a.transpose(b)
    e.compOpen = false
    revealCaret = true
    return
  if ctrl and shift and not w.alt and (key(KeyUp) or key(KeyDown)):
    b.moveLines(if key(KeyUp): -1 else: 1)
    e.compOpen = false
    revealCaret = true
    return
  if ctrl and w.alt and (key(KeyUp) or key(KeyDown)):
    b.addCursorVertical(if key(KeyUp): -1 else: 1)
    e.compOpen = false
    return
  if b.extra.len > 0:
    # An edit at several cursors scrolls to the main one, as typing at one does.
    if a.multiKeys(b, pageLines): revealCaret = true
    return
  if ctrl and (key(KeyZ) or key(KeyY)):
    if (key(KeyZ) and shift) or key(KeyY): changed = b.redoStep()
    else: changed = b.undoStep()
    e.compOpen = false
    revealCaret = true
    return
  if ctrl and key(KeyA):
    b.anchor = (0, 0)
    b.caret = (b.lines.high, b.lines[^1].len)
    return
  if ctrl and (key(KeyC) or key(KeyX)):
    if b.copyText(cut = key(KeyX)): changed = true
  if ctrl and key(KeyV):
    put(getClipboardString().replace("\r\n", "\n").replace("\r", "\n"))
  if ctrl and key(KeySlash):
    b.toggleComment()
    changed = true

  # Typing.
  var typed = ""
  for ch in ui.typed:
    if ch.ord >= 0x20 and ch.ord != 0x7f: typed.add ch
  if typed.len > 0 and not ctrl:
    for ch in typed:
      if ch == '}':
        # A } alone on its line goes back one indent.
        let line = b.lines[b.caret.line]
        if not b.hasSelection and line[0 ..< b.caret.col].strip.len == 0 and b.caret.col > 0:
          let ind = line[0 ..< b.caret.col]
          let less = if ind.endsWith("\t"): ind[0 ..< ^1] elif ind.len >= TabCols: ind[0 ..< ^TabCols] else: ""
          b.replace((b.caret.line, 0), b.caret, less, now = now)
      if ch == ')' and b.atAutoClose:
        # Over the ) its function got.
        autoClose.buf = nil
        b.caret.col += 1
        b.anchor = b.caret
        changed = true
        continue
      put($ch, typing = true)
      if ch == ' ': typedSpace = true
  if key(KeyEnter) or key(NumpadEnter):
    let line = b.lines[b.caret.line]
    var ind = line.indentOf
    let (s0, _) = b.selRange
    if line[0 ..< min(s0.col, line.len)].strip.endsWith("{"): ind.add "\t"
    put("\n" & ind)
  if key(KeyTab):
    if b.hasSelection and b.caret.line != b.anchor.line: b.indentLines(shift)
    elif shift: b.indentLines(true)
    else: put("\t")
    changed = true
  if key(KeyBackspace):
    if b.hasSelection: deleteSel()
    elif b.atAutoClose and b.caret.col > 0 and b.lines[b.caret.line][b.caret.col - 1] == '(':
      # An empty () a function got: both go.
      autoClose.buf = nil
      b.replace((b.caret.line, b.caret.col - 1), (b.caret.line, b.caret.col + 1), "", now = now)
      changed = true
    elif b.caret.col > 0:
      let s = b.lines[b.caret.line]
      var k = b.caret.col - 1
      if ctrl:
        k = b.caret.col
        while k > 0 and s[k - 1] in {' ', '\t'}: dec k
        if k > 0 and s[k - 1] in IdentChars:
          while k > 0 and s[k - 1] in IdentChars: dec k
        elif k == b.caret.col: k = b.caret.col - 1
      b.replace((b.caret.line, k), b.caret, "", now = now)
      changed = true
    elif b.caret.line > 0:
      b.replace((b.caret.line - 1, b.lines[b.caret.line - 1].len), b.caret, "", now = now)
      changed = true
  if key(KeyDelete):
    if b.hasSelection: deleteSel()
    else:
      let s = b.lines[b.caret.line]
      if b.caret.col < s.len:
        var k = b.caret.col + 1
        if ctrl:
          k = b.caret.col
          if s[k] in IdentChars:
            while k < s.len and s[k] in IdentChars: inc k
          else: inc k
          while k < s.len and s[k] in {' ', '\t'}: inc k
        b.replace(b.caret, (b.caret.line, k), "", now = now)
        changed = true
      elif b.caret.line < b.lines.high:
        b.replace(b.caret, (b.caret.line + 1, 0), "", now = now)
        changed = true

  # Moving the caret (Shift selects).
  let c = b.caret
  let s = b.lines[c.line]
  if key(KeyLeft):
    if b.hasSelection and not shift: moveTo(b.selRange[0])
    elif ctrl:
      var k = c.col
      while k > 0 and s[k - 1] in {' ', '\t'}: dec k
      if k > 0 and s[k - 1] in IdentChars:
        while k > 0 and s[k - 1] in IdentChars: dec k
      elif k > 0: dec k
      if c.col == 0 and c.line > 0: moveTo((c.line - 1, b.lines[c.line - 1].len))
      else: moveTo((c.line, k))
    elif c.col > 0: moveTo((c.line, c.col - 1))
    elif c.line > 0: moveTo((c.line - 1, b.lines[c.line - 1].len))
  if key(KeyRight):
    if b.hasSelection and not shift: moveTo(b.selRange[1])
    elif ctrl:
      var k = c.col
      if k < s.len and s[k] in IdentChars:
        while k < s.len and s[k] in IdentChars: inc k
      elif k < s.len: inc k
      while k < s.len and s[k] in {' ', '\t'}: inc k
      if c.col == s.len and c.line < b.lines.high: moveTo((c.line + 1, 0))
      else: moveTo((c.line, k))
    elif c.col < s.len: moveTo((c.line, c.col + 1))
    elif c.line < b.lines.high: moveTo((c.line + 1, 0))
  proc vertical(lines: int) =
    let x = if b.wantX >= 0: b.wantX else: vcol(b.lines[c.line], c.col).float32
    b.wantX = x
    let l = clamp(c.line + lines, 0, b.lines.high)
    moveTo((l, colAt(b.lines[l], x)), keepX = true)
  if key(KeyUp) and not ctrl: vertical(-1)
  if key(KeyDown) and not ctrl: vertical(1)
  if key(KeyUp) and ctrl: b.scrollY -= editorArea.h / 6
  if key(KeyDown) and ctrl: b.scrollY += editorArea.h / 6
  if key(KeyPageUp): vertical(-pageLines)
  if key(KeyPageDown): vertical(pageLines)
  if key(KeyHome):
    if ctrl: moveTo((0, 0))
    else:
      # To the first non-blank character, then to the line's start.
      let ind = s.indentOf.len
      moveTo((c.line, if c.col == ind: 0 else: ind))
  if key(KeyEnd):
    if ctrl: moveTo((b.lines.high, b.lines[^1].len))
    else: moveTo((c.line, s.len))

  if changed or moved:
    revealCaret = true
    e.caretTip = true
  if autoClose.buf == b and autoClose.line != b.caret.line: autoClose.buf = nil
  if changed:
    let ctx = caretContext(a.analysisOf(b), b.lines, b.caret.line, b.caret.col)
    let wordTyped = typed.len > 0 and typed[^1] in IdentChars
    if wordTyped and ctx.kind != ckNone and ctx.prefix.len >= 1: a.updateCompletion(b, force = true)
    elif typedSpace: a.updateCompletion(b, onSpace = true)
    elif e.compOpen: a.updateCompletion(b)
  elif moved and e.compOpen:
    if b.caret.line != e.compStart.line or b.caret.col < e.compStart.col: e.compOpen = false
    else: a.updateCompletion(b)

proc drawSquiggle(ui: Ui, x0, x1, y: float32, col: ColorRGBX) =
  var x = x0
  var up = false
  while x < x1:
    let w = min(2'f32, x1 - x)
    ui.rect(rect(x, y + (if up: 0'f32 else: 1'f32), w, 1), col)
    x += 2
    up = not up

# --- rename and extract function ------------------------------------------------------------

type Span = tuple[at: Pos, len: int]

proc isIdent(s: string): bool =
  s.len > 0 and s[0] in {'a'..'z', 'A'..'Z', '_'} and s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_'})

proc scriptFiles(a: App): seq[string] =
  ## The level's script files, and open ones elsewhere.
  result = a.scripts.files
  for b in a.scripts.buffers:
    if b.path notin result: result.add b.path

proc nameProblem(a: App, name: string, kind: SymKind, an: Analysis = nil, fn = -1): string =
  ## Why a function or variable can't be called name ("": it can). Names are
  ## case-sensitive in the game (strcmp). A global name that any script already
  ## uses as a word (an object's name, a local) would change what that word
  ## means, so it has to be new to the level's scripts; a local's, to its function.
  let e = a.scripts
  if not isIdent(name): return name & " isn't a name: use letters, digits and _, not starting with a digit"
  if name in Keywords or name in TypeWords or name in OperatorWords: return name & " is a word of the script language"
  if e.defs != nil and name in e.defs.commands: return "The game has a command called " & name
  if e.defs != nil and name in e.defs.variables: return "The game has a variable called " & name
  if name in e.index.funcs:
    return "A function called " & name & " already exists (" & e.index.funcs[name].file.extractFilename & ")"
  if name in e.index.globals:
    return "A global variable called " & name & " already exists (" & e.index.globals[name].file.extractFilename & ")"
  if kind == skLocal:
    for t in an.toks:
      if t.fn == fn and t.kind == tkIdent and t.text == name:
        return name & " is already used in this function (line " & $(t.line + 1) & ")"
    return
  for f in a.scriptFiles:
    let (_, fa) = a.fileAnalysis(f)
    if fa == nil: continue
    for t in fa.toks:
      if (t.kind == tkIdent and t.text == name) or
         (t.kind == tkString and t.refk == rkFuncName and t.text.strip(chars = {'"'}) == name):
        return name & " is already used in " & f.extractFilename & ", line " & $(t.line + 1) &
               ": the scripts would read it as the new name"
  if kind == skFunc:
    for r in a.objectFuncRefs:
      if r.name == name: return "The " & r.detail & " already calls a function named " & name

proc renameSpans(a: App, b: ScriptBuffer, an: Analysis, ti: int, sym: Sym): Table[string, seq[Span]] =
  ## Every place the name of what token ti names is written: its declaration
  ## and its uses (a function's: also where a string argument names it).
  if sym.kind == skLocal:
    let fn = an.toks[ti].fn
    for t in an.toks:
      if t.fn == fn and t.text == sym.name and (t.sem == semLocal or (t.sem == semDeclName and t.decl < 0)):
        result.mgetOrPut(b.path, @[]).add ((t.line, t.col), t.len)
    return
  for f in a.scriptFiles:
    let (_, fa) = a.fileAnalysis(f)
    if fa == nil: continue
    for t in fa.toks:
      let declHere = t.sem == semDeclName and t.decl >= 0 and fa.decls[t.decl].isFunc == (sym.kind == skFunc)
      if t.text == sym.name and ((sym.kind == skGlobal and t.sem == semGlobal) or
                                 (sym.kind == skFunc and t.sem == semFunc) or declHere):
        result.mgetOrPut(f, @[]).add ((t.line, t.col), t.len)
      elif sym.kind == skFunc and t.refk == rkFuncName and t.kind in {tkIdent, tkString} and t.sem != semFunc and
           t.text.strip(chars = {'"'}) == sym.name:
        let q = if t.text.startsWith("\""): 1 else: 0
        result.mgetOrPut(f, @[]).add ((t.line, t.col + q), sym.name.len)

proc renameObjectCalls(a: App, old, name: string): int =
  ## The characters, trigger volumes and neutrals whose script fields, and the
  ## objects whose events, call function old: they call it name now (one undo
  ## step). Returns how many objects changed.
  var objs: seq[LevelObject]
  for o in a.objects:
    var hit = false
    case o.tag
    of "CHAR", "TRGV":
      let sc = o.node.xpath("OSD/Scripts")
      if sc != nil:
        for c in sc:
          if c.kind == xnElement and c.str.strip == old: hit = true
    of "NEUT": hit = o.node.xpath("OSD/Script/AfterTalk").str.strip == old
    else: discard
    let ev = o.node.xpath("OSD/Events")
    if ev != nil:
      for c in ev:
        if c.kind == xnElement and c.attr("Function").strip == old: hit = true
    if hit: objs.add o
  if objs.len == 0: return
  let before = snapshotObjects(objs)
  for o in objs:
    case o.tag
    of "CHAR", "TRGV":
      let sc = o.node.xpath("OSD/Scripts")
      if sc != nil:
        for c in sc:
          if c.kind == xnElement and c.str.strip == old: o.setField(ObjectField(path: "OSD/Scripts/" & c.tag), name)
    of "NEUT":
      if o.node.xpath("OSD/Script/AfterTalk").str.strip == old:
        o.setField(ObjectField(path: "OSD/Script/AfterTalk"), name)
    else: discard
    let ev = o.node.xpath("OSD/Events")
    if ev != nil:
      for c in ev:
        if c.kind == xnElement and c.attr("Function").strip == old:
          c.setAttr("Function", name)
          o.file.dirty = true
    o.syncFromNode()
  a.push editCmd("Rename function " & old & " to " & name, objs, before)
  objs.len

proc startRename(a: App, b: ScriptBuffer) =
  ## F2: asks for a new name for the function or variable under the cursor and
  ## writes it everywhere it's declared and used, in every script file (files
  ## not open are opened, unsaved, one undo step each) and, for a function, in
  ## the objects that call it by name.
  let an = a.analysisOf(b)
  let ti = an.tokAt(b.caret.line, b.caret.col)
  let (sym, _) = if ti >= 0: symAt(an, ti) else: (Sym(), false)
  if sym.kind == skNone:
    let t = if ti >= 0: an.toks[ti] else: Tok()
    a.say(if ti >= 0 and t.sem == semCommand: "Rename: " & t.text & " is a command of the game, not of the level's scripts"
          elif ti >= 0 and t.sem == semEngineVar: "Rename: " & t.text & " is a variable of the game, not of the level's scripts"
          else: "Rename: put the cursor on the name of a function or variable of the level's scripts", true)
    return
  if sym.kind in {skFunc, skGlobal} and not a.findDecl(sym.name, funcsOnly = sym.kind == skFunc)[0]:
    a.say("Rename: no script of the level declares " & sym.name, true)
    return
  if sym.kind == skLocal and localDecl(an, ti) < 0:
    a.say("Rename: " & sym.name & " isn't declared in this function", true)
    return
  if sym.kind == skFunc and sym.name == "main":
    a.say("Rename: the game calls main by that name when the level loads", true)
    return
  if sym.kind == skFunc:
    for r in a.objectFuncRefs:
      if r.name == sym.name and r.obj.tag == "PATR":
        a.say("Rename: the " & r.detail & " calls " & sym.name & " by a name the game makes from the point's " &
              "ScriptId (patrolscript and four digits)", true)
        return
  let at = (an.toks[ti].line, an.toks[ti].col)
  let ver = b.version
  let what = case sym.kind
             of skFunc: "function"
             of skGlobal: "global variable"
             else: (if an.toks[localDecl(an, ti)].sem == semLocal: "argument" else: "local variable")
  a.askName("Rename " & what & " " & sym.name, sym.name, proc(name: string) =
    let n = name.strip
    if n.len == 0 or n == sym.name: return
    if b.version != ver or b notin a.scripts.buffers:
      a.say("Rename: the script changed meanwhile; rename again", true)
      return
    a.refreshScripts()
    let an = a.analysisOf(b)
    let ti = an.tokAt(at[0], at[1], touching = false)
    if ti < 0 or symAt(an, ti)[0] != sym:
      a.say("Rename: the script changed meanwhile; rename again", true)
      return
    let problem = a.nameProblem(n, sym.kind, an, an.toks[ti].fn)
    if problem.len > 0:
      a.say("Rename: " & problem, true)
      return
    let e = a.scripts
    let spans = a.renameSpans(b, an, ti, sym)
    var carets: seq[(ScriptBuffer, Pos, Pos)]
    for ob in e.buffers: carets.add (ob, ob.caret, ob.anchor)
    var places = 0
    for file, sp in spans:
      var buf: ScriptBuffer
      for ob in e.buffers:
        if ob.path == file: buf = ob
      if buf == nil:
        buf = loadBuffer(file)
        e.buffers.add buf
      buf.replaceSpans(sp, n)
      if not carets.anyIt(it[0] == buf):
        buf.caret = sp[0].at
        buf.anchor = buf.caret
      places += sp.len
    for (ob, c, an0) in carets:
      ob.caret = ob.clampPos(c)
      ob.anchor = ob.clampPos(an0)
    # The cursor stays on the name it was on.
    let t = an.toks[ti]
    var shift = 0
    for sp in spans.getOrDefault(b.path):
      if sp.at.line == t.line and sp.at.col < t.col: shift += n.len - sp.len
    b.caret = (t.line, t.col + shift)
    b.anchor = b.caret
    let objs = if sym.kind == skFunc: a.renameObjectCalls(sym.name, n) else: 0
    e.compOpen = false
    refsOpen = false
    a.say("Renamed " & sym.name & " to " & n & ": " & $places & (if places == 1: " place" else: " places") &
          " in " & $spans.len & (if spans.len == 1: " file" else: " files") &
          (if objs > 0: " and " & $objs & (if objs == 1: " object's" else: " objects'") & " script fields" else: "") &
          " (Ctrl+S saves)"), back = EditorId)

proc extractFunction(a: App, b: ScriptBuffer) =
  ## Moves the selected lines into a new function below the one they're in,
  ## and calls it where they were. The variables of the function they use
  ## become its arguments (the game passes copies), so selections the meaning
  ## would change for are refused, saying why.
  proc fail(why: string) = a.say("Extract function: " & why, true)
  if not b.hasSelection:
    fail("select the lines to move into a new function")
    return
  let an = a.analysisOf(b)
  let (s0, s1) = b.selRange
  let l0 = s0.line
  let l1 = if s1.col == 0 and s1.line > s0.line: s1.line - 1 else: s1.line
  var sel: seq[int]
  for i, t in an.toks:
    if t.line >= l0 and t.line <= l1 and t.kind != tkComment: sel.add i
  if sel.len == 0:
    fail("the selected lines have no code")
    return
  let fn = an.toks[sel[0]].fn
  if fn < 0:
    fail("select lines inside a function")
    return
  for i in sel:
    if an.toks[i].fn != fn:
      fail("select lines of one function only")
      return
  var bodyOpen, bodyClose = -1
  for i, t in an.toks:
    if t.fn != fn: continue
    if bodyOpen < 0 and t.kind == tkPunct and t.text == "{": bodyOpen = i
    bodyClose = i
  if bodyOpen < 0 or sel[0] <= bodyOpen or sel[^1] >= bodyClose or an.toks[bodyClose].text != "}":
    fail("select whole lines inside the function's braces, not the braces themselves")
    return
  var depth = 0
  for i in sel:
    let t = an.toks[i]
    if t.kind == tkPunct and t.text == "{": inc depth
    elif t.kind == tkPunct and t.text == "}":
      dec depth
      if depth < 0:
        fail("the selection closes a block it doesn't open (line " & $(t.line + 1) & ")")
        return
  if depth != 0:
    fail("the selection opens a block it doesn't close")
    return
  for i in sel:
    let t = an.toks[i]
    if t.kind == tkIdent and t.text == "return":
      fail("line " & $(t.line + 1) & " returns: in a new function it would only end that function")
      return
  if an.toks[sel[0]].kind == tkIdent and an.toks[sel[0]].text == "else":
    fail("it starts with else: select the if it belongs to as well")
    return
  var after = -1
  for i in sel[^1] + 1 ..< an.toks.len:
    if an.toks[i].kind != tkComment:
      after = i
      break
  if after >= 0 and an.toks[after].kind == tkIdent and an.toks[after].text == "else":
    fail("an else follows it (line " & $(an.toks[after].line + 1) & "): select it too")
    return
  # The function's variables it uses: arguments of the new one.
  let selFirst = sel[0]
  let selLast = sel[^1]
  var params: seq[(string, string)]
  var seen: HashSet[string]
  for k, i in sel:
    let t = an.toks[i]
    if t.sem != semLocal or t.defines: continue
    let d = localDecl(an, i)
    if d < 0:
      fail(t.text & " (line " & $(t.line + 1) & ") isn't declared in this function")
      return
    if d >= selFirst and d <= selLast: continue
    if d > selLast:
      fail(t.text & " is declared below the selection")
      return
    # Changed here and read after: the change would stay in the new function's copy.
    let assigned = k + 1 < sel.len and an.toks[sel[k + 1]].kind == tkPunct and an.toks[sel[k + 1]].text == "=" and
                   an.toks[sel[k + 1]].line == t.line
    if assigned:
      for j in selLast + 1 ..< an.toks.len:
        let u = an.toks[j]
        if u.fn == fn and u.sem == semLocal and u.text == t.text:
          fail("it sets " & t.text & " (line " & $(t.line + 1) & "), which line " & $(u.line + 1) &
               " reads: a function gets a copy of it, so the change wouldn't reach that line")
          return
    if t.text notin seen:
      seen.incl t.text
      var j = d - 1
      while j >= 0 and an.toks[j].kind == tkComment: dec j
      if j < 0 or an.toks[j].sem != semType:
        fail("can't tell the type of " & t.text)
        return
      params.add (an.toks[j].text, t.text)
  # Variables it declares that the lines after it use.
  for j in selLast + 1 ..< an.toks.len:
    let u = an.toks[j]
    if u.fn != fn or u.sem != semLocal: continue
    let d = localDecl(an, j)
    if d >= selFirst and d <= selLast:
      fail("it declares " & u.text & ", which line " & $(u.line + 1) & " uses")
      return
  if params.len > 8:
    fail("the new function would take " & $params.len & " arguments; the game takes at most 8")
    return
  let outer = an.decls[fn].name
  var def = "new_function"
  var k = 2
  while a.nameProblem(def, skFunc).len > 0:
    def = "new_function" & $k
    inc k
  let ver = b.version
  a.askName("Extract function (from " & outer & ")", def, proc(name: string) =
    let n = name.strip
    if n.len == 0: return
    if b.version != ver or b notin a.scripts.buffers:
      fail("the script changed meanwhile; select the lines again")
      return
    let problem = a.nameProblem(n, skFunc)
    if problem.len > 0:
      fail(problem)
      return
    let lines = b.lines
    let callIndent = lines[an.toks[selFirst].line].indentOf
    # The lines without the indent they share, one tab in.
    var common = ""
    var first = true
    for l in l0 .. l1:
      if lines[l].strip.len == 0: continue
      let ind = lines[l].indentOf
      if first:
        common = ind
        first = false
      else:
        var m = 0
        while m < common.len and m < ind.len and common[m] == ind[m]: inc m
        common = common[0 ..< m]
    var body: seq[string]
    for l in l0 .. l1:
      body.add (if lines[l].strip.len == 0: "" else: "\t" & lines[l][common.len .. ^1])
    var ps, names: seq[string]
    for (t, nm) in params:
      ps.add t & " " & nm
      names.add nm
    let header = "func void " & n & "(" & (if ps.len == 0: "void" else: ps.join(", ")) & ")"
    let call = callIndent & n & (if names.len > 0: "(" & names.join(", ") & ")" else: "")
    let closeLine = an.toks[bodyClose].line
    let text = call & "\n" & lines[l1 + 1 .. closeLine].join("\n") & "\n\n" & header & "\n{\n" & body.join("\n") & "\n}"
    b.replace((l0, 0), (closeLine, lines[closeLine].len), text)
    b.caret = (l0, callIndent.len)
    b.anchor = (l0, callIndent.len + n.len)
    revealCaret = true
    a.scripts.compOpen = false
    let count = l1 - l0 + 1
    a.say("Moved " & $count & (if count == 1: " line" else: " lines") & " into " & n & "(" & names.join(", ") &
          "), below " & outer & " (Ctrl+Z puts them back)"), back = EditorId)

proc copyText(b: ScriptBuffer, cut: bool): bool =
  ## Ctrl+C / Ctrl+X: the selection, or without one the cursor's whole line, as
  ## code editors do. Whether the text changed.
  if b.hasSelection:
    let (s0, s1) = b.selRange
    setClipboardString(b.textIn(s0, s1))
    if cut:
      b.replace(s0, s1, "", now = epochTime())
      return true
  else:
    let l = b.caret.line
    setClipboardString(b.lines[l] & "\n")
    if cut:
      if l < b.lines.high: b.replace((l, 0), (l + 1, 0), "", now = epochTime())
      else: b.replace((l, 0), (l, b.lines[l].len), "", now = epochTime())
      return true

proc pasteText(b: ScriptBuffer) =
  let (s0, s1) = b.selRange
  b.replace(s0, s1, getClipboardString().replace("\r\n", "\n").replace("\r", "\n"), now = epochTime())

# --- quick actions ---------------------------------------------------------------------------
# Rewrites the context menu offers for the code at the cursor, like an IDE's
# suggestions, but only ones the game's script reader accepts and that can't
# change what the script does. Facts they rely on (Oni.exe 0x47b590, 0x47dac0
# and OniFoxed's BFW_ScriptLang): `else` takes any statement (so else if
# chains work); `and`/`or` evaluate both sides (no short-circuit); precedence
# is and/or 5, comparisons 10, + - 20, ! 255 (table at file offset 0x13d1b8);
# `return` ends the function even inside an if whose condition is false, so
# no rewrite adds one. BSL has no ?: operator, no switch and no lambdas.

type
  IfInfo = object
    ifTok, lpar, rpar, bOpen, bClose: int
    elseTok, eOpen, eClose, elseIf: int     ## -1 when absent.
  QuickAction = tuple[label: string, run: proc()]

proc sigNext(an: Analysis, i: int): int =
  result = i + 1
  while result < an.toks.len and an.toks[result].kind == tkComment: inc result
  if result >= an.toks.len: result = -1

proc sigPrev(an: Analysis, i: int): int =
  result = i - 1
  while result >= 0 and an.toks[result].kind == tkComment: dec result

proc isP(an: Analysis, i: int, s: string): bool =
  i >= 0 and i < an.toks.len and an.toks[i].kind == tkPunct and an.toks[i].text == s

proc isW(an: Analysis, i: int, s: string): bool =
  i >= 0 and i < an.toks.len and an.toks[i].kind == tkIdent and an.toks[i].text == s

proc matchClose(an: Analysis, i: int): int =
  ## The ) or } that closes the ( or { at i (-1: none).
  let o = an.toks[i].text
  let c = if o == "(": ")" else: "}"
  var depth = 0
  for j in i ..< an.toks.len:
    if an.isP(j, o): inc depth
    elif an.isP(j, c):
      dec depth
      if depth == 0: return j
  -1

proc tStart(an: Analysis, i: int): Pos = (an.toks[i].line, an.toks[i].col)
proc tEnd(an: Analysis, i: int): Pos = (an.toks[i].line, an.toks[i].col + an.toks[i].len)

proc ifAt(an: Analysis, i: int): (bool, IfInfo) =
  ## The if statement whose keyword is token i, with braces around its blocks.
  var f = IfInfo(ifTok: i, elseTok: -1, eOpen: -1, eClose: -1, elseIf: -1)
  if not an.isW(i, "if"): return
  f.lpar = an.sigNext(i)
  if not an.isP(f.lpar, "("): return
  f.rpar = an.matchClose(f.lpar)
  if f.rpar < 0: return
  f.bOpen = an.sigNext(f.rpar)
  if not an.isP(f.bOpen, "{"): return
  f.bClose = an.matchClose(f.bOpen)
  if f.bClose < 0: return
  let e = an.sigNext(f.bClose)
  if an.isW(e, "else"):
    f.elseTok = e
    let n = an.sigNext(e)
    if an.isP(n, "{"):
      f.eOpen = n
      f.eClose = an.matchClose(n)
      if f.eClose < 0: return
    elif an.isW(n, "if"): f.elseIf = n
    else: return
  (true, f)

proc stmtEnd(an: Analysis, f: IfInfo): int =
  ## The last token of the whole if statement (its else's too).
  if f.eClose >= 0: return f.eClose
  if f.elseIf >= 0:
    let (ok, g) = an.ifAt(f.elseIf)
    return if ok: an.stmtEnd(g) else: -1
  f.bClose

proc condTopOps(an: Analysis, f: IfInfo): seq[int] =
  ## The operators at the top level of the condition (not inside parentheses).
  var depth = 0
  for j in f.lpar + 1 ..< f.rpar:
    let t = an.toks[j]
    if t.kind == tkComment: continue
    if an.isP(j, "("): inc depth
    elif an.isP(j, ")"): dec depth
    elif depth == 0 and ((t.kind == tkIdent and t.text in ["and", "or", "eq", "ne"]) or
                         (t.kind == tkPunct and t.text in ["<", ">", "<=", ">=", "!"])):
      result.add j

proc hasCall(an: Analysis, a, z: int): bool =
  for j in a .. z:
    if an.toks[j].sem in {semCommand, semFunc, semUnknownCall}: return true

proc hasComment(an: Analysis, a, z: int): bool =
  for j in a .. z:
    if an.toks[j].kind == tkComment: return true

proc isComparison(an: Analysis, a, z: int): bool =
  ## Tokens a..z are one comparison at their top level (x eq 1, n < 3...).
  var depth, ops = 0
  for j in a .. z:
    if an.isP(j, "("): inc depth
    elif an.isP(j, ")"): dec depth
    elif depth == 0:
      let t = an.toks[j]
      if t.kind == tkIdent and t.text in ["and", "or"]: return false
      if (t.kind == tkIdent and t.text in ["eq", "ne"]) or (t.kind == tkPunct and t.text in ["<", ">", "<=", ">="]):
        inc ops
  ops == 1

proc reindent(text, drop, add: string): string =
  ## Each line of text after the first, without drop at its start, with add.
  var ls = text.split('\n')
  for k in 1 ..< ls.len:
    var l = ls[k]
    if drop.len > 0 and l.startsWith(drop): l = l[drop.len .. ^1]
    if l.strip.len > 0: l = add & l
    ls[k] = l
  ls.join("\n")

proc inlineCall(a: App, b: ScriptBuffer, an: Analysis, ti: int): (string, proc()) =
  ## "Inline <function>": the call at token ti replaced with the function's
  ## body. ("", nil) when it isn't one or would work differently: see quickActions.
  let t = an.toks[ti]
  if t.sem != semFunc or t.call < 0 or an.calls[t.call].tok != ti or t.fn < 0: return
  let c = an.calls[t.call]
  # A whole statement on its own line(s), not forked, not inside an expression.
  let before = an.sigPrev(ti)
  if before >= 0 and an.toks[before].line == t.line and not (an.isP(before, "{") or an.isP(before, ";")): return
  if before >= 0 and an.isW(before, "fork"): return
  if t.col != b.lines[t.line].indentOf.len: return
  var trailing = ""
  var last = c.last
  for j in c.last + 1 ..< an.toks.len:
    let u = an.toks[j]
    if u.line != an.toks[c.last].line: break
    if u.kind == tkComment: trailing = u.text
    elif an.isP(j, ";") and j == c.last + 1: last = j
    else: return
  let (found, d) = a.findDecl(c.name, funcsOnly = true)
  if not found or d.decl.typ.len > 0: return
  let (clines, fa) = a.fileAnalysis(d.file)
  if fa == nil: return
  var nameTok = -1
  for j, u in fa.toks:
    if u.sem == semDeclName and u.decl >= 0 and fa.decls[u.decl].isFunc and u.text == c.name and u.line == d.decl.line:
      nameTok = j
  if nameTok < 0: return
  var bOpen = -1
  for j in nameTok + 1 ..< fa.toks.len:
    if fa.isP(j, "{"):
      bOpen = j
      break
  if bOpen < 0: return
  let bClose = fa.matchClose(bOpen)
  if bClose < 0: return
  # A return only as the body's last statement, without a value: dropped.
  var dropFrom, dropTo = -1
  for j in bOpen + 1 ..< bClose:
    if fa.isW(j, "return") and fa.toks[j].sem == semKeyword:
      var k = fa.sigNext(j)
      if fa.isP(k, ";"): k = fa.sigNext(k)
      if k != bClose: return
      var depth = 0
      for m in bOpen + 1 ..< j:
        if fa.isP(m, "{"): inc depth
        elif fa.isP(m, "}"): dec depth
      if depth != 0: return
      dropFrom = j
      dropTo = fa.sigPrev(bClose)
  var params: seq[(string, string)]
  for (pt, pn) in d.decl.params:
    if pn.len > 0: params.add (pt, pn)
  # Names: the function's own must be new to the caller, and the globals it
  # uses mustn't be hidden there by the caller's locals.
  var callerNames, callerLocals: HashSet[string]
  for u in an.toks:
    if u.fn == t.fn and u.kind == tkIdent:
      callerNames.incl u.text
      if u.sem == semLocal or (u.sem == semDeclName and u.decl < 0): callerLocals.incl u.text
  var own: seq[string]
  for (_, pn) in params: own.add pn
  for j in bOpen + 1 ..< bClose:
    let u = fa.toks[j]
    if u.sem == semDeclName and u.decl < 0: own.add u.text
    if u.sem == semGlobal and u.text in callerLocals: return
  for n in own:
    if n in callerNames: return
  # The arguments: substituted where that's the same, else a var each.
  proc assigned(n: string): bool =
    for j in bOpen + 1 ..< bClose:
      if fa.toks[j].text == n and fa.toks[j].sem == semLocal and fa.isP(fa.sigNext(j), "="): return true
  var subst: Table[string, string]
  var decls: seq[string]
  for k, (pt, pn) in params:
    var text = ""
    var direct = false
    if k < c.args.len:
      let sl = c.args[k]
      text = b.textIn(an.tStart(sl.a), an.tEnd(sl.b)).strip
      if sl.a == sl.b:
        let u = an.toks[sl.a]
        if u.kind in {tkNumber, tkString} or u.text in ["true", "false"]: direct = true
        elif u.sem == semBareWord:
          text = "\"" & u.text & "\""
          direct = true
        elif u.sem == semLocal: direct = true
    else:
      text = case pt
             of "int": "0"
             of "float": "0.0"
             of "bool": "false"
             else: "\"\""
      direct = true
    if direct and not assigned(pn): subst[pn] = text
    else: decls.add "var " & pt & " " & pn & " = " & text & ";"
  # The body's text, with the substitutions and without the dropped return.
  var spans: seq[(Pos, Pos, string)]
  for j in bOpen + 1 ..< bClose:
    let u = fa.toks[j]
    if dropFrom >= 0 and j >= dropFrom and j <= dropTo: continue
    if u.sem == semLocal and u.text in subst: spans.add (fa.tStart(j), fa.tEnd(j), subst[u.text])
  if dropFrom >= 0: spans.add (fa.tStart(dropFrom), fa.tEnd(dropTo), "")
  proc textOf(x, y: Pos): string =
    if x.line == y.line: return clines[x.line][x.col ..< y.col]
    result = clines[x.line][x.col .. ^1]
    for l in x.line + 1 ..< y.line: result.add "\n" & clines[l]
    result.add "\n" & clines[y.line][0 ..< y.col]
  var body = ""
  var cur = fa.tEnd(bOpen)
  for (x, y, r) in spans:
    body.add textOf(cur, x)
    body.add r
    cur = y
  body.add textOf(cur, fa.tStart(bClose))
  var ls = body.split('\n')
  while ls.len > 0 and ls[0].strip.len == 0: ls.delete 0
  while ls.len > 0 and ls[^1].strip.len == 0: ls.setLen ls.len - 1
  var common = ""
  var first = true
  for l in ls:
    if l.strip.len == 0: continue
    let ind = l.indentOf
    if first:
      common = ind
      first = false
    else:
      var m = 0
      while m < common.len and m < ind.len and common[m] == ind[m]: inc m
      common = common[0 ..< m]
  let callInd = b.lines[t.line].indentOf
  var outLines: seq[string]
  if trailing.len > 0: outLines.add callInd & trailing
  for dl in decls: outLines.add callInd & dl
  for l in ls: outLines.add (if l.strip.len == 0: "" else: callInd & l[common.len .. ^1])
  let l0 = t.line
  let l1 = an.toks[last].line
  let ver = b.version
  let name = c.name
  let label = "Inline " & name & " (replace the call with its body)"
  (label, proc() =
    if b.version != ver: return
    let x: Pos = (l0, 0)
    if outLines.len == 0:
      let z: Pos = if l1 < b.lines.high: (l1 + 1, 0) else: (l1, b.lines[l1].len)
      b.replace(x, z, "")
    else:
      b.replace(x, (l1, b.lines[l1].len), outLines.join("\n"))
    b.caret = (l0, callInd.len)
    b.anchor = b.caret
    revealCaret = true
    a.ui.focusId = EditorId
    a.say("Inlined " & name & ": " & $outLines.len & (if outLines.len == 1: " line" else: " lines") &
          " in place of the call (Ctrl+Z undoes it)"))

proc quickActions(a: App, b: ScriptBuffer, an: Analysis): seq[QuickAction] =
  let c = b.caret
  let ver = b.version
  proc txt(x, y: Pos): string = b.textIn(x, y)
  proc indentAt(i: int): string = b.lines[an.toks[i].line].indentOf
  proc firstOnLine(i: int): bool = an.toks[i].col == indentAt(i).len
  proc apply(label: string, x, y: Pos, s: string, caret: Pos): proc() =
    result = proc() =
      if b.version != ver: return
      b.replace(x, y, s)
      b.caret = b.clampPos(caret)
      b.anchor = b.caret
      revealCaret = true
      a.ui.focusId = EditorId
      a.say(label & " (Ctrl+Z undoes it)")
  # The if at the cursor: its keyword, its condition or the else of it.
  var here = -1
  for i, t in an.toks:
    if not an.isW(i, "if") or t.sem != semKeyword: continue
    let (ok, f) = an.ifAt(i)
    if not ok: continue
    if (an.tStart(i) <= c and c <= an.tEnd(f.rpar)) or (f.elseTok >= 0 and an.tStart(f.elseTok) <= c and c <= an.tEnd(f.elseTok)):
      here = i
  if here >= 0:
    let (_, f) = an.ifAt(here)
    let cond = txt(an.tEnd(f.lpar), an.tStart(f.rpar)).strip
    let ind = indentAt(here)
    # Merge nested if: if (a) { if (b) {...} } -> if (a and b) {...}
    let inner = an.sigNext(f.bOpen)
    if f.elseTok < 0 and an.isW(inner, "if"):
      let (ok2, g) = an.ifAt(inner)
      if ok2 and g.elseTok < 0 and an.sigNext(g.bClose) == f.bClose and
         not an.hasCall(g.lpar, g.rpar) and not an.hasComment(f.bOpen, inner) and
         not an.hasComment(g.bClose, f.bClose):
        let c2 = txt(an.tEnd(g.lpar), an.tStart(g.rpar)).strip
        let wrapA = an.condTopOps(f).anyIt(an.toks[it].text == "or")
        let wrapB = an.condTopOps(g).anyIt(an.toks[it].text in ["and", "or"])
        let joined = (if wrapA: "(" & cond & ")" else: cond) & " and " & (if wrapB: "(" & c2 & ")" else: c2)
        let innerInd = indentAt(inner)
        let drop = if innerInd.startsWith(ind): innerInd[ind.len .. ^1] else: ""
        let body = reindent(txt(an.tEnd(g.rpar), an.tEnd(g.bClose)), drop, "")
        result.add ("Merge nested if", apply("Merged the nested if", an.tStart(here), an.tEnd(f.bClose),
                    "if (" & joined & ")" & body, an.tStart(here)))
    # Split into nested if: if (a and b) {...} -> if (a) { if (b) {...} }
    let ops = an.condTopOps(f)
    if f.elseTok < 0 and ops.len > 0 and ops.allIt(an.toks[it].text in ["and", "eq", "ne", "<", ">", "<=", ">="]) and
       ops.anyIt(an.toks[it].text == "and"):
      var last = -1
      for o in ops:
        if an.toks[o].text == "and": last = o
      let aPart = txt(an.tEnd(f.lpar), an.tStart(last)).strip
      let bPart = txt(an.tEnd(last), an.tStart(f.rpar)).strip
      if an.isComparison(an.sigNext(last), an.sigPrev(f.rpar)) and not an.hasCall(last, f.rpar) and
         not an.hasComment(f.lpar, f.rpar):
        let sameLine = an.toks[f.bOpen].line == an.toks[f.rpar].line
        let body = reindent(txt(an.tEnd(f.rpar), an.tEnd(f.bClose)), "", "\t")
        let open = if sameLine: " {\n" else: "\n" & ind & "{\n"
        result.add ("Split into nested if", apply("Split the if", an.tStart(here), an.tEnd(f.bClose),
                    "if (" & aPart & ")" & open & ind & "\t" & "if (" & bPart & ")" & body & "\n" & ind & "}",
                    an.tStart(here)))
    # Invert if: swap the blocks, negate the condition.
    if f.eOpen >= 0 and not an.hasComment(f.lpar, f.rpar):
      var neg = ""
      let first = an.sigNext(f.lpar)
      if an.isComparison(first, an.sigPrev(f.rpar)):
        const Flip = {"eq": "ne", "ne": "eq", "<": ">=", ">": "<=", "<=": ">", ">=": "<"}.toTable
        let op = ops[0]
        neg = txt(an.tEnd(f.lpar), an.tStart(op)).strip & " " & Flip[an.toks[op].text] & " " &
              txt(an.tEnd(op), an.tStart(f.rpar)).strip
      elif an.isP(first, "!") and an.isP(an.sigNext(first), "(") and
           an.matchClose(an.sigNext(first)) == an.sigPrev(f.rpar):
        neg = txt(an.tEnd(an.sigNext(first)), an.tStart(an.sigPrev(f.rpar))).strip
      else: neg = "!(" & cond & ")"
      let s = "if (" & neg & ")" & txt(an.tEnd(f.rpar), an.tStart(f.bOpen)) &
              txt(an.tStart(f.eOpen), an.tEnd(f.eClose)) & txt(an.tEnd(f.bClose), an.tStart(f.eOpen)) &
              txt(an.tStart(f.bOpen), an.tEnd(f.bClose))
      result.add ("Invert if (swap the if and else blocks)", apply("Inverted the if", an.tStart(here),
                  an.tEnd(f.eClose), s, an.tStart(here)))
    # Merge into else if: else { if ... } -> else if ...
    if f.eOpen >= 0:
      let inner2 = an.sigNext(f.eOpen)
      if an.isW(inner2, "if"):
        let (ok3, g) = an.ifAt(inner2)
        if ok3 and an.sigNext(an.stmtEnd(g)) == f.eClose and not an.hasComment(f.eOpen, inner2) and
           not an.hasComment(an.stmtEnd(g), f.eClose):
          let innerInd = indentAt(inner2)
          let elseInd = indentAt(f.elseTok)   # The if's lines move out one level, to the else's.
          let drop = if innerInd.startsWith(elseInd): innerInd[elseInd.len .. ^1] else: ""
          let s = reindent(txt(an.tStart(inner2), an.tEnd(an.stmtEnd(g))), drop, "")
          result.add ("Merge into else if", apply("Merged into else if", an.tEnd(f.elseTok), an.tEnd(f.eClose),
                      " " & s, an.tStart(f.elseTok)))
    # Chain with else if (BSL has no switch): ifs comparing one variable to
    # different constants, none with an else, none changing the variable.
    proc caseOf(g: IfInfo): (string, string) =
      ## (variable, constant) of a condition "v eq K" or "K eq v".
      let x = an.sigNext(g.lpar)
      let op = an.sigNext(x)
      let y = an.sigNext(op)
      if an.sigNext(y) != g.rpar or not an.isW(op, "eq"): return
      let tx = an.toks[x]
      let ty = an.toks[y]
      proc isConst(t: Tok): bool = t.kind in {tkNumber, tkString} or (t.kind == tkIdent and t.text in ["true", "false"])
      if tx.sem in {semLocal, semGlobal} and ty.isConst: return (tx.text, ty.text)
      if ty.sem in {semLocal, semGlobal} and tx.isConst: return (ty.text, tx.text)
    let (v, k0) = caseOf(f)
    if v.len > 0 and f.elseTok < 0:
      # The run of such ifs this one is in.
      var run = @[f]
      var j = an.sigPrev(here)
      while j >= 0 and an.isP(j, "}"):
        # The if this } closes, if it's the end of one.
        var found = false
        for i2 in countdown(j - 1, 0):
          if an.isW(i2, "if"):
            let (okp, p) = an.ifAt(i2)
            if okp and p.bClose == j and p.elseTok < 0 and caseOf(p)[0] == v:
              run.insert(p, 0)
              j = an.sigPrev(i2)
              found = true
            break
        if not found: break
      var n = an.sigNext(f.bClose)
      while an.isW(n, "if"):
        let (okn, q) = an.ifAt(n)
        if not okn or q.elseTok >= 0 or caseOf(q)[0] != v: break
        run.add q
        n = an.sigNext(q.bClose)
      var consts: HashSet[string]
      var safe = run.len >= 2
      let isGlobal = an.toks[an.sigNext(f.lpar)].text == v and an.toks[an.sigNext(f.lpar)].sem == semGlobal or
                     an.toks[an.sigPrev(f.rpar)].text == v and an.toks[an.sigPrev(f.rpar)].sem == semGlobal
      for q in run:
        let k = caseOf(q)[1]
        let key = if k.startsWith("\"") or k in ["true", "false"]: k else: numberValue(k)
        if key in consts: safe = false
        consts.incl key
        for jj in q.bOpen .. q.bClose:
          let t = an.toks[jj]
          if t.text == v and t.sem in {semLocal, semGlobal} and an.isP(an.sigNext(jj), "="): safe = false
          if isGlobal and (t.sem == semFunc or (t.kind == tkIdent and t.text in ["sleep", "fork"])): safe = false
      if safe:
        var spans: seq[Span]
        for q in run[1 .. ^1]: spans.add (an.tStart(q.ifTok), 0)
        let label = "Chain these " & $run.len & " ifs on " & v & " with else if"
        result.add (label, proc() =
          if b.version != ver: return
          b.replaceSpans(spans, "else ")
          b.caret = b.clampPos(c)
          b.anchor = b.caret
          a.ui.focusId = EditorId
          a.say("Chained the ifs on " & v & " with else if (Ctrl+Z undoes it)"))
  # The token at the cursor.
  let ti = an.tokAt(c.line, c.col)
  # A call: inline it.
  if ti >= 0:
    let (label, run) = a.inlineCall(b, an, ti)
    if run != nil: result.add (label, run)
  # Declarations: the local var at the cursor.
  var decl = -1
  if ti >= 0:
    if an.toks[ti].sem == semDeclName and an.toks[ti].decl < 0: decl = ti
    elif an.isW(ti, "var") and an.toks[ti].sem == semKeyword:
      let nm = an.sigNext(an.sigNext(ti))
      if nm >= 0 and an.toks[nm].sem == semDeclName and an.toks[nm].decl < 0: decl = nm
    elif an.toks[ti].sem == semType:
      let nm = an.sigNext(ti)
      if nm >= 0 and an.toks[nm].sem == semDeclName and an.toks[nm].decl < 0: decl = nm
  if decl >= 0:
    let typ = an.sigPrev(decl)
    let kw = an.sigPrev(typ)
    let name = an.toks[decl].text
    let after = an.sigNext(decl)
    if an.isW(kw, "var") and an.toks[typ].sem == semType and firstOnLine(kw):
      let ind = indentAt(kw)
      # The statement's end: the last token of the line, or its ;.
      proc lineEnd(i: int): int =
        result = i
        var j = an.sigNext(i)
        while j >= 0 and an.toks[j].line == an.toks[i].line and not an.isP(j, "}") and not an.isP(j, "{"):
          result = j
          if an.isP(j, ";"): break
          j = an.sigNext(j)
      if an.isP(after, "="):
        # Split declaration and assignment.
        let e = lineEnd(after)
        let semi = an.isP(e, ";")
        let exprEnd = if semi: an.sigPrev(e) else: e
        if exprEnd > after:
          let expr = txt(an.tEnd(after), an.tEnd(exprEnd)).strip
          result.add ("Split declaration and assignment", apply("Split the declaration of " & name, an.tStart(kw),
                      an.tEnd(e), "var " & an.toks[typ].text & " " & name & (if semi: ";" else: "") & "\n" & ind &
                      name & " = " & expr & (if semi: ";" else: ""), an.tStart(kw)))
      else:
        # Join declaration and assignment: var int x; then x = ...
        let declEnd = if an.isP(after, ";") and an.toks[after].line == an.toks[decl].line: after else: decl
        let st = an.sigNext(declEnd)
        if st >= 0 and an.toks[st].text == name and an.toks[st].sem == semLocal and an.isP(an.sigNext(st), "=") and
           firstOnLine(st) and not an.hasComment(declEnd, st) and an.toks[st].line == an.toks[decl].line + 1:
          let eq = an.sigNext(st)
          let e = lineEnd(eq)
          let semi = an.isP(e, ";")
          let exprEnd = if semi: an.sigPrev(e) else: e
          var selfRef = false
          for j in eq + 1 .. exprEnd:
            if an.toks[j].text == name: selfRef = true
          if exprEnd > eq and not selfRef:
            let expr = txt(an.tEnd(eq), an.tEnd(exprEnd)).strip
            result.add ("Join declaration and assignment", apply("Joined the declaration of " & name, an.tStart(kw),
                        an.tEnd(e), "var " & an.toks[typ].text & " " & name & " = " & expr & (if semi: ";" else: ""),
                        an.tStart(kw)))
      # Remove unused variable: nothing reads it and its start value calls nothing.
      if a.usagesOf(b, an, decl).len == 0:
        let e = lineEnd(decl)
        let l = an.toks[kw].line
        var lineOnly = true
        for j, t in an.toks:
          if t.line == l and (j < kw or j > e): lineOnly = false
        if lineOnly and not an.hasCall(kw, e):
          let z: Pos = if l < b.lines.high: (l + 1, 0) else: (l, b.lines[l].len)
          result.add ("Remove unused variable " & name, apply("Removed the unused variable " & name, (l, 0), z, "",
                      (l, 0)))

proc scriptContextTree(a: App): MenuNode =
  ## Right click on the Scripts panel's text.
  result = newMenuRoot()
  if a.scripts == nil: return
  let b = a.scripts.current
  if b == nil: return
  let an = a.analysisOf(b)
  let ti = an.tokAt(b.caret.line, b.caret.col)
  let (sym, isDecl) = if ti >= 0: symAt(an, ti) else: (Sym(), false)
  proc back() = a.ui.focusId = EditorId
  let quick = a.quickActions(b, an)
  for q in quick: result.item(q.label, action = q.run)
  if quick.len > 0: result.sep()
  result.item("Go to declaration", "F12", enabled = ti >= 0 and not isDecl and a.hasLink(an, ti), action = proc() =
    back()
    discard a.followLink(b, an, ti))
  result.item("List uses", "Shift+F12", enabled = sym.kind != skNone, action = proc() =
    back()
    a.openUses(b, an, ti))
  result.item("Rename...", "F2", enabled = sym.kind != skNone, action = proc() = a.startRename(b))
  result.item("Extract function...", enabled = b.hasSelection, action = proc() = a.extractFunction(b))
  result.sep()
  result.item("Cut", "Ctrl+X", action = proc() =
    back()
    discard b.copyText(cut = true))
  result.item("Copy", "Ctrl+C", action = proc() =
    back()
    discard b.copyText(cut = false))
  result.item("Paste", "Ctrl+V", action = proc() =
    back()
    b.pasteText())
  result.item("Select all", "Ctrl+A", action = proc() =
    back()
    b.anchor = (0, 0)
    b.caret = (b.lines.high, b.lines[^1].len))
  result.sep()
  result.item("Comment / uncomment lines", "Ctrl+/", action = proc() =
    back()
    b.toggleComment())
  result.item("Find...", "Ctrl+F", action = proc() =
    a.scripts.findOpen = true
    a.scripts.findFocus = true
    if b.hasSelection and b.caret.line == b.anchor.line:
      let (s0, s1) = b.selRange
      a.scripts.findText = b.textIn(s0, s1))

proc drawListHi(ui: Ui, r: Rect) =
  ## The chosen row of a list: a dark accent fill, outline and bar on the left.
  ui.rect(r, colListHi)
  ui.border(r, colListHiEdge)
  ui.rect(rect(r.x, r.y, 3, r.h), colAccent)

proc drawUses(a: App, anchor: Rect, mono: string, lineH: float32) =
  ## The list Ctrl+click on a declaration opens: a row per use, a click (or
  ## Up/Down and Enter) goes to it. A click elsewhere or Esc closes it.
  let ui = a.ui
  let n = refsList.len
  let headH = 24'f32
  let rowH = lineH + 6
  let rows = min(n, RefsRows)
  var whereW = 0'f32
  var codeW = 0'f32
  for u in refsList:
    whereW = max(whereW, ui.textSize(a.usageWhere(u), FontSmall).x)
    codeW = max(codeW, if u.file.len > 0: ui.textSize(u.code, mono).x else: ui.textSize(u.what, FontSmall).x)
  whereW = min(whereW, 320'f32) + 16
  let head = if n == 0: "Nothing uses " & refsName
             else: $n & (if n == 1: " use of " else: " uses of ") & refsName & " · click one to go to it"
  let w = clamp(max(whereW + min(codeW, 560'f32) + 24, ui.textSize(head, FontSmall).x + 24), 280'f32,
                max(280'f32, ui.size.x - 8))
  let h = headH + rows.float32 * rowH + 4
  var r = rect(anchor.x - 8, anchor.y + anchor.h + 2, w, h)
  if r.y + r.h > ui.size.y - 4: r.y = anchor.y - h - 2
  r.x = clamp(r.x, 4, max(4'f32, ui.size.x - r.w - 4))
  ui.popupRect = r
  let inside = ui.mouse.inside(r)
  if not refsFresh and not inside and (ui.window.buttonPressed[MouseLeft] or ui.window.buttonPressed[MouseRight]):
    refsOpen = false
    return
  refsFresh = false
  refsHi = clamp(refsHi, 0, max(0, n - 1))
  refsScroll = clamp(refsScroll, max(0, refsHi - rows + 1), min(refsHi, max(0, n - rows)))
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(r.x + 3, r.y + 3, r.w, r.h), colShadow)
  ui.rect(r, colPopup)
  ui.border(r, colBorder)
  ui.textIn(head, rect(r.x + 8, r.y, r.w - 16, headH), colTextDim, FontSmall)
  ui.rect(rect(r.x, r.y + headH - 1, r.w, 1), colBorder)
  if inside and ui.scroll() != 0:
    refsScroll = clamp(refsScroll + (if ui.scroll() > 0: 1 else: -1), 0, max(0, n - rows))
    refsHi = clamp(refsHi, refsScroll, refsScroll + rows - 1)
    ui.scrollConsumed = true
  var go = -1
  for k in 0 ..< rows:
    let i = refsScroll + k
    if i >= n: break
    let u = refsList[i]
    let ir = rect(r.x + 2, r.y + headH + 1 + k.float32 * rowH, r.w - 4, rowH)
    let hov = ui.mouse.inside(ir)
    if hov: refsHi = i
    let hi = i == refsHi
    if hi: drawListHi(ui, ir)
    var whereCol = if hi: colText else: colTextDim
    if u.obj != nil:
      let c = u.obj.look.col
      whereCol = rgbx(c[0], c[1], c[2], 255)
    ui.textIn(ui.ellipsize(a.usageWhere(u), whereW - 12, FontSmall), rect(ir.x + 6, ir.y, whereW - 8, rowH),
              whereCol, FontSmall)
    let cx = ir.x + whereW
    let cw = ir.w - whereW - 6
    if u.file.len > 0:
      let ty = ir.y + (rowH - lineH) / 2
      let code = ui.ellipsize(u.code, cw, mono)
      ui.text(code, vec2(cx, ty), colText, mono)
      # The name, marked.
      if u.at + u.len <= code.len:
        let nx = cx + ui.textSize(code[0 ..< u.at], mono).x
        let nw = ui.textSize(code[u.at ..< u.at + u.len], mono).x
        ui.text(code[u.at ..< u.at + u.len], vec2(nx, ty), colAccentHover, mono)
        ui.rect(rect(nx, ty + lineH - 1, nw, 1), colAccentHover)
    else:
      ui.textIn(ui.ellipsize(u.what, cw, FontSmall), rect(cx, ir.y, cw, rowH), colText, FontSmall)
    if hov and ui.window.buttonPressed[MouseLeft] and (u.file.len > 0 or u.obj != nil):
      ui.consumeClick()
      go = i
  if n > rows:
    let trackH = rows.float32 * rowH
    let th = max(12'f32, trackH * rows.float32 / n.float32)
    let ty = r.y + headH + 1 + (trackH - th) * refsScroll.float32 / max(1, n - rows).float32
    ui.rect(rect(r.x + r.w - 5, ty, 3, th), colBorder)
  ui.sk.popLayer()
  if go >= 0:
    refsOpen = false
    a.gotoUsage(refsList[go])

proc drawScripts*(a: App, body: Rect) =
  let ui = a.ui
  if a.proj == nil:
    ui.textIn("No project open", rect(body.x, body.y + 12, body.w, 22), colTextDim, h = CenterAlign)
    return
  a.ensureScripts()
  a.refreshScripts()
  let e = a.scripts

  # Tabs: one per open file, then Open... and New.
  let bar = rect(body.x, body.y, body.w, ScriptTabsH)
  ui.rect(bar, colPanelRaised)
  ui.rect(rect(bar.x, bar.y + bar.h - 1, bar.w, 1), colBorder)
  let openW = 96'f32
  var x = bar.x + 4
  var closeIt = -1
  proc tabW(b: ScriptBuffer): float32 =
    min(ui.textSize(b.path.extractFilename & (if b.dirty: " •" else: ""), FontSmall).x + 34, 220)
  # The tabs that fit, from one that keeps the active tab in sight.
  let room = bar.w - openW - 34
  var firstTab = 0
  if e.active >= 0:
    var used = 0'f32
    for k in countdown(e.active, 0):
      used += e.buffers[k].tabW + 2
      if used > room and k < e.active: break
      firstTab = k
  if firstTab > 0:
    ui.textIn("…", rect(x, bar.y, 12, bar.h), colTextDim, FontSmall)
    x += 14
  for i, b in e.buffers:
    if i < firstTab: continue
    let name = b.path.extractFilename & (if b.dirty: " •" else: "")
    let tw = b.tabW
    if x + tw > bar.x + room + 4:
      ui.textIn("…", rect(x, bar.y, 12, bar.h), colTextDim, FontSmall)
      break
    let tr = rect(x, bar.y + 2, tw, ScriptTabsH - 3)
    let sel = i == e.active
    let hov = ui.hover(tr)
    ui.rect(tr, if sel: colPanel elif hov: colHover else: colPanelRaised)
    if sel: ui.rect(rect(tr.x, tr.y + tr.h - 2, tr.w, 2), colAccent)
    ui.textIn(ui.ellipsize(name, tw - 30, FontSmall), rect(tr.x + 8, tr.y, tw - 30, tr.h),
              if sel: colText else: colTextDim, FontSmall)
    ui.tip(tr, a.relScript(b.path) & (if b.dirty: " (unsaved changes; Ctrl+S saves the project)" else: ""))
    let cr = rect(tr.x + tw - 22, tr.y + 2, 18, tr.h - 4)
    if ui.iconButton("scripts.close." & $i, cr, "close16", "Close", focusable = false): closeIt = i
    elif hov and ui.pressed():
      ui.consumeClick()
      e.active = i
      e.compOpen = false
      ui.focusId = EditorId
    elif hov and ui.pressed(MouseMiddle): closeIt = i
    x += tw + 2
  if closeIt >= 0:
    let b = e.buffers[closeIt]
    if b.dirty:
      let k = closeIt
      a.savePrompt = proc() =
        if k < a.scripts.buffers.len and a.scripts.buffers[k] == b: a.closeBuffer(k)
    else: a.closeBuffer(closeIt)
  var names: seq[string]
  var paths: seq[string]
  for f in e.files:
    names.add a.relScript(f)
    paths.add f
  names.add "New script file..."
  let picked = a.dropdown("scripts.open", rect(bar.x + bar.w - openW - 4, bar.y + 2, openW, ScriptTabsH - 4),
                          "Open...", names, clickFocus = false)
  if picked >= 0:
    if picked < paths.len: a.openScriptAt(paths[picked], 0, 0)
    else: a.newScriptFile()

  let b = e.current
  var y = bar.y + bar.h
  if b == nil:
    # Nothing open: the level's files, a click opens one.
    var ly = y + 10
    ui.textIn("The level's script files (Oni reads every .bsl in IGMD/" & a.proj.envName & "):",
              rect(body.x + 12, ly, body.w - 24, 20), colTextDim, FontSmall)
    ly += 24
    for f in e.files:
      let r = rect(body.x + 8, ly, body.w - 16, 22)
      let hov = ui.hover(r)
      if hov: ui.rect(r, colHover)
      ui.icon("nofile16", vec2(r.x + 12, r.y + 11), colTextDim)
      ui.textIn(a.relScript(f), rect(r.x + 26, r.y, r.w - 30, r.h), colText, FontSmall)
      if hov and ui.pressed():
        ui.consumeClick()
        a.openScriptAt(f, 0, 0)
      ly += 22
    if e.files.len == 0:
      ui.textIn("None yet: Open... > New script file", rect(body.x + 12, ly, body.w - 24, 20), colTextDim, FontSmall)
    return

  let an = a.analysisOf(b)
  # Changed on disk while edited here.
  if b.changedOnDisk:
    let r = rect(body.x, y, body.w, 30)
    ui.rect(r, colCardRef)
    ui.textIn("Changed by another program. Reload it (losing the edits here), or keep these and save over it.",
              rect(r.x + 10, r.y, r.w - 190, r.h), colText, FontSmall)
    if ui.textButton("scripts.reload", rect(r.x + r.w - 176, r.y + 3, 80, 24), "Reload"): b.reload()
    if ui.textButton("scripts.keep", rect(r.x + r.w - 90, r.y + 3, 80, 24), "Keep mine"):
      b.changedOnDisk = false
      try: b.diskTime = getLastModificationTime(b.path)
      except OSError: discard
    y += 30
  # Find bar.
  if e.findOpen:
    let r = rect(body.x, y, body.w, FindBarH)
    ui.rect(r, colPanelRaised)
    if e.findFocus:
      ui.focusId = "scripts.find"
      ui.focusFresh = true
      e.findFocus = false
    let fr = rect(r.x + 8, r.y + 3, max(80'f32, min(320'f32, r.w - 280)), 26)
    let enter = a.window.buttonPressed[KeyEnter] or a.window.buttonPressed[NumpadEnter]
    let wasFocused = ui.focusId == "scripts.find"
    # Alt+C / Alt+W (the left Alt: the right one is AltGr on many layouts) toggle
    # Match case / Whole word, and their letter isn't typed.
    if wasFocused and a.window.buttonDown[KeyLeftAlt]:
      for (k, ch) in [(KeyC, 'c'), (KeyW, 'w')]:
        if a.window.buttonPressed[k]:
          if k == KeyC: e.findCase = not e.findCase
          else: e.findWord = not e.findWord
          var t = ""
          for x in ui.typed:
            if x.toLowerAscii != ch: t.add x
          ui.typed = t
    let ev = ui.textField("scripts.find", fr, e.findText, "Find")
    if wasFocused and enter:
      a.findNext(b, back = a.window.shiftDown)
      ui.focusId = "scripts.find"
    elif wasFocused and a.window.buttonPressed[KeyEscape]:
      e.findOpen = false
      ui.focusId = EditorId
      escTaken = true
    discard ev
    # Match case (Aa) and Whole word (ab, underlined): lit while on.
    proc toggle(id: string, tr: Rect, label: string, on: bool, tip: string, underline: bool): bool =
      let hov = ui.hover(tr)
      ui.rect(tr, if on: colAccentDim elif hov: colHover else: colPanelRaised)
      ui.border(tr, if on: colAccent else: colBorder)
      let col = if on: colText else: colTextDim
      ui.textIn(label, tr, col, FontSmall, h = CenterAlign)
      if underline:
        let tw = ui.textSize(label, FontSmall).x
        let ux = tr.x + (tr.w - tw) / 2 - 2
        let uy = tr.y + tr.h - 7
        ui.rect(rect(ux, uy, tw + 4, 1), col)
        ui.rect(rect(ux, uy - 3, 1, 3), col)
        ui.rect(rect(ux + tw + 3, uy - 3, 1, 3), col)
      ui.tip(tr, tip)
      if hov and ui.pressed():
        ui.consumeClick()
        result = true
    let cr = rect(fr.x + fr.w + 4, r.y + 3, 28, 26)
    let wr = rect(cr.x + cr.w + 2, r.y + 3, 28, 26)
    if toggle("scripts.findcase", cr, "Aa", e.findCase, "Match case (Alt+C)", false): e.findCase = not e.findCase
    if toggle("scripts.findword", wr, "ab", e.findWord, "Whole word (Alt+W)", true): e.findWord = not e.findWord
    # "3/12": the match the selection is on, of the matches (as findNext finds
    # them); "?/12" when it's on none.
    let found = b.findMatches(e.findText, e.findCase, e.findWord)
    var at = 0
    let (fs0, fs1) = b.selRange
    for i, h in found:
      if fs0 == h and fs1 == (h.line, h.col + e.findText.len): at = i + 1
    let count = if e.findText.len == 0: "" elif found.len == 0: "0 found"
                else: (if at > 0: $at else: "?") & "/" & $found.len
    let cx = wr.x + wr.w + 8
    ui.textIn(count, rect(cx, r.y, 70, r.h), colTextDim, FontSmall)
    if ui.textButton("scripts.findprev", rect(cx + 72, r.y + 3, 44, 26), "Prev"): a.findNext(b, back = true)
    ui.tip(rect(cx + 72, r.y + 3, 44, 26), "Previous match (Shift+Enter, Shift+F3)")
    if ui.textButton("scripts.findnext", rect(cx + 118, r.y + 3, 44, 26), "Next"): a.findNext(b)
    ui.tip(rect(cx + 118, r.y + 3, 44, 26), "Next match (Enter, F3)")
    if ui.iconButton("scripts.findclose", rect(r.x + r.w - 30, r.y + 4, 24, 24), "close16", "Close (Esc)", focusable = false):
      e.findOpen = false
    y += FindBarH

  # The text.
  let mono = codeFont(a.codeFontSize)
  let lineH = round(ui.textSize("Ag", mono).y)
  let charW = ui.textSize("0000000000", mono).x / 10
  let area = rect(body.x, y, body.w, max(0'f32, body.y + body.h - ScriptStatusH - y))
  editorArea = area
  editorDrawnAt = epochTime()
  let digits = max(3, len($b.lines.len))
  let gutterW = digits.float32 * charW + 18
  let textX = area.x + gutterW + 6
  let textW = max(10'f32, area.w - gutterW - 6 - 12)
  let pageLines = max(1, int(area.h / lineH) - 1)
  let focused = ui.focusId == EditorId
  let w = a.window
  if focused: ui.keepFocus()
  let inArea = ui.hover(area)
  let hov = inArea and not (mini.open and ui.mouse.inside(miniRect(area)))   # The player takes its own clicks.

  # Mouse.
  proc posAt(m: Vec2): Pos =
    let l = clamp(int(floor((m.y - area.y - 4 + b.scrollY) / lineH)), 0, b.lines.high)
    (l, colAt(b.lines[l], (m.x - textX + b.scrollX) / charW))
  var hoverTok = -1
  if hov and ui.mouse.x >= textX - 4:
    let p = posAt(ui.mouse)
    let my = area.y + 4 + p.line.float32 * lineH - b.scrollY
    if ui.mouse.y >= my and ui.mouse.y < my + lineH:
      for i, t in an.toks:
        if t.line == p.line and p.col >= t.col and p.col < t.col + t.len or
           (t.line == p.line and p.col == t.col + t.len and
            (ui.mouse.x - textX + b.scrollX) / charW < vcol(b.lines[p.line], t.col + t.len).float32):
          hoverTok = i
          break
  let linkTok = if hoverTok >= 0 and w.ctrl:
                  (if a.hasLink(an, hoverTok): hoverTok else: -1)
                else: -1
  if hov and not ui.mouse.inside(rect(area.x + area.w - 12, area.y, 12, area.h)):
    wantCursor = if linkTok >= 0: PointerCursor elif ui.mouse.x >= textX - 4: IBeamCursor else: ArrowCursor
  # Clicks elsewhere end editing.
  if focused and (ui.pressed() or ui.pressed(MouseRight) or ui.pressed(MouseMiddle)) and not inArea and
     not ui.popupHit:
    ui.focusId = ""
  # The scrollbar takes its press before the text.
  let contentH = b.lines.len.float32 * lineH + area.h * 0.5
  ui.scrollArea("scripts.text", area, b.scrollY)
  if hov and ui.pressed(MouseRight) and ui.mouse.x >= textX - 4 and
     not ui.mouse.inside(rect(area.x + area.w - 12, area.y, 12, area.h)):
    # The context menu, for the word clicked (the selection stays if it's in it).
    ui.focusId = EditorId
    ui.navId = ""
    e.compOpen = false
    refsOpen = false
    let p = posAt(ui.mouse)
    let (s0, s1) = b.selRange
    if not b.hasSelection or p < s0 or s1 < p:
      b.caret = p
      b.anchor = p
    a.ctx = CtxMenu(pos: ui.mouse, view: -1, face: -1, scripts: true)
    a.menuSys.openContext(ui.mouse)
  if hov and ui.pressed():
    ui.consumeClick()
    ui.focusId = EditorId
    ui.navId = ""
    e.compOpen = false
    e.caretTip = false
    if linkTok >= 0:
      discard a.followLink(b, an, linkTok)
    elif w.alt and not w.ctrl:
      # Alt+click: one more cursor; dragging from there selects with it (the
      # other cursors and selections stay).
      let p = posAt(ui.mouse)
      b.setCursors(b.cursors & @[(p, p)], (p, p))
      e.clicks = 1
      b.wantX = -1
      e.dragging = true
    else:
      b.extra.setLen 0
      let p = posAt(ui.mouse)
      e.clicks = ui.countClick(EditorId)
      if e.clicks == 2:
        let (wa, wb) = wordAt(b.lines[p.line], p.col)
        b.anchor = (p.line, wa)
        b.caret = (p.line, wb)
        e.dragWords = (b.anchor, b.caret)
      elif e.clicks >= 3:
        b.anchor = (p.line, 0)
        b.caret = if p.line < b.lines.high: (p.line + 1, 0) else: (p.line, b.lines[p.line].len)
      else:
        b.caret = p
        if not w.shiftDown: b.anchor = p
      b.wantX = -1
      e.dragging = true
  if e.dragging:
    if not ui.down():
      e.dragging = false
      # A selection dragged over others merges with them.
      if b.extra.len > 0: b.setCursors(b.cursors, (b.caret, b.anchor))
    elif ui.window.buttonDown[MouseLeft]:
      let p = posAt(ui.mouse)
      if e.clicks == 2:
        let (wa, wb) = wordAt(b.lines[p.line], p.col)
        if p < e.dragWords[0]:
          b.anchor = e.dragWords[1]
          b.caret = (p.line, wa)
        else:
          b.anchor = e.dragWords[0]
          b.caret = (p.line, max(wb, p.col))
      elif e.clicks == 1:
        b.caret = p
      # Dragging past the edges scrolls.
      if ui.mouse.y < area.y: b.scrollY -= lineH
      if ui.mouse.y > area.y + area.h: b.scrollY += lineH
  if hov and ui.scroll() != 0 and not ui.scrollConsumed:
    if w.ctrl:
      let i = CodeFontSizes.find(a.codeFontSize)
      a.setCodeFontSize(b, CodeFontSizes[clamp(i + (if ui.wheelNotches < 0: 1 else: -1), 0, CodeFontSizes.high)])
    elif w.shiftDown: b.scrollX = max(0, b.scrollX + ui.wheelNotches * charW * 6)
    else: b.scrollY += ui.wheelNotches * lineH * 3
    ui.scrollConsumed = true

  if focused: a.editorKeys(b, pageLines)
  escTaken = false
  let an2 = a.analysisOf(b)   # The keys may have changed the text.

  # A jump's scrolling under way.
  if scrollAnim.buf == b:
    if b.scrollY != scrollAnim.setY: scrollAnim.buf = nil
    else:
      let t = (epochTime() - scrollAnim.start) / ScrollAnimTime
      if t >= 1:
        b.scrollY = scrollAnim.toY
        scrollAnim.buf = nil
      else:
        let k = 1 - (1 - t) * (1 - t) * (1 - t)   # ease-out
        b.scrollY = scrollAnim.fromY + (scrollAnim.toY - scrollAnim.fromY) * k
  # Scrolling to the caret (or a line asked for), judged from where a jump
  # under way is heading.
  let shownY = b.scrollY
  let jump = revealCaret or (scrollToLine >= 0 and scrollFor == b)
  if jump and scrollAnim.buf == b: b.scrollY = scrollAnim.toY
  if scrollToLine >= 0 and scrollFor == b:
    b.scrollY = scrollToLine.float32 * lineH - area.h / 3
    scrollToLine = -1
    revealCaret = true
  if revealCaret:
    revealCaret = false
    let cy = b.caret.line.float32 * lineH
    if cy - b.scrollY < 0: b.scrollY = cy
    if cy + lineH - b.scrollY > area.h - 8: b.scrollY = cy + lineH - area.h + 8
    let cx = vcol(b.lines[b.caret.line], b.caret.col).float32 * charW
    if cx - b.scrollX < 0: b.scrollX = max(0, cx - charW * 8)
    if cx - b.scrollX > textW - charW * 2: b.scrollX = cx - textW + charW * 8
  b.scrollY = clamp(b.scrollY, 0, max(0'f32, contentH - area.h))
  if jump:
    # More than a line or so scrolls there smoothly; a line's step (arrows,
    # typing) stays instant.
    let toY = b.scrollY
    let fromY = clamp(shownY, 0, max(0'f32, contentH - area.h))
    if abs(toY - fromY) > lineH * 1.5:
      scrollAnim = (b, fromY, toY, fromY, epochTime())
      b.scrollY = fromY
      a.animUntil = max(a.animUntil, epochTime() + ScrollAnimTime + 0.05)
    else: scrollAnim.buf = nil
  if scrollAnim.buf == b: scrollAnim.setY = b.scrollY

  # Draw.
  ui.rect(area, colBackground)
  ui.rect(rect(area.x, area.y, gutterW, area.h), colPanel)
  ui.pushClip(area)
  let first = max(0, int(b.scrollY / lineH) - 1)
  let lastL = min(b.lines.high, first + int(area.h / lineH) + 2)
  let (s0, s1) = b.selRange
  let allSels = b.cursors
  # The innermost pair the cursor is between ((), [], {}, or a string's
  # quotes): both get a thin outline.
  var pairMarks: seq[Pos]
  if focused:
    let cp = b.caret
    for t in an2.toks:
      if t.kind == tkString and t.line == cp.line and t.len >= 2 and t.text[^1] == '"' and
         cp.col > t.col and cp.col < t.col + t.len:
        pairMarks = @[(t.line, t.col), (t.line, t.col + t.len - 1)]
    if pairMarks.len == 0:
      const Closer = {"(": ")", "[": "]", "{": "}"}.toTable
      var stack: seq[int]
      for i, t in an2.toks:
        if t.kind != tkPunct: continue
        if not ((t.line, t.col) < cp): break
        if t.text in Closer: stack.add i
        elif t.text in [")", "]", "}"]:
          var k = stack.high
          while k >= 0 and Closer[an2.toks[stack[k]].text] != t.text: dec k
          if k >= 0: stack.setLen k
      if stack.len > 0:
        let o = stack[^1]
        let open = an2.toks[o].text
        var depth = 0
        for j in o ..< an2.toks.len:
          let t = an2.toks[j]
          if t.kind != tkPunct: continue
          if t.text == open: inc depth
          elif t.text == Closer[open]:
            dec depth
            if depth == 0:
              pairMarks = @[(an2.toks[o].line, an2.toks[o].col), (t.line, t.col)]
              break
  var tokStart = newSeq[int](b.lines.len + 1)
  block:
    var k = 0
    for l in 0 .. b.lines.len:
      while k < an2.toks.len and an2.toks[k].line < l: inc k
      tokStart[l] = k
  # The find text's matches, by line.
  var findHits: Table[int, seq[int]]
  if e.findOpen:
    for h in b.findMatches(e.findText, e.findCase, e.findWord): findHits.mgetOrPut(h.line, @[]).add h.col
  for l in first .. lastL:
    let ly = area.y + 4 + l.float32 * lineH - b.scrollY
    let s = b.lines[l]
    proc xOf(col: int): float32 = textX + vcol(s, col).float32 * charW - b.scrollX
    if focused and l == b.caret.line and not b.hasSelection and b.extra.len == 0:
      ui.rect(rect(area.x + gutterW, ly, area.w - gutterW, lineH), colPanelRaised)
    # Selections (every cursor's).
    for sc in allSels:
      let (a0, a1) = (sc.selStart, sc.selEnd)
      if a0 == a1 or l < a0.line or l > a1.line: continue
      let c0 = if l == a0.line: a0.col else: 0
      let c1 = if l == a1.line: a1.col else: s.len
      var x1 = xOf(c1)
      if l < a1.line: x1 += charW * 0.6
      ui.rect(rect(max(xOf(c0), area.x + gutterW), ly, max(0'f32, x1 - max(xOf(c0), area.x + gutterW)), lineH), colAccentDim)
    # Find matches.
    for k in findHits.getOrDefault(l):
      ui.rect(rect(xOf(k), ly, xOf(k + e.findText.len) - xOf(k), lineH), colCardRef)
    # Tokens.
    ui.pushClip(rect(area.x + gutterW, area.y, area.w - gutterW, area.h))
    for ti in tokStart[l] ..< tokStart[l + 1]:
      let t = an2.toks[ti]
      let tx = xOf(t.col)
      if tx > area.x + area.w: break
      var col = a.semColor(t)
      let o = if t.kind in {tkIdent, tkString, tkNumber}: a.resolveTok(t) else: nil
      if o != nil:
        let c = o.look.col
        col = rgbx(c[0], c[1], c[2], 255)
      ui.text(t.text, vec2(tx, ly), col, mono)
      if ti == linkTok or (o != nil and ti == hoverTok and w.ctrl):
        ui.rect(rect(tx, ly + lineH - 2, xOf(t.col + t.len) - tx, 1), col)
      # The sound open in the player, wherever the file names it.
      if mini.open and t.kind in {tkIdent, tkString} and isMiniSound(t.soundName) and
         (t.kind == tkString or a.soundTok(an2, ti) > 0):
        ui.border(rect(tx - 2, ly, xOf(t.col + t.len) - tx + 4, lineH), colSoundMark)
    # Problems.
    for dg in an2.diags:
      if dg.line != l: continue
      let x0 = xOf(dg.col)
      let x1 = max(x0 + charW, xOf(min(s.len, dg.col + dg.len)))
      ui.drawSquiggle(x0, x1, ly + lineH - 3, if dg.error: colError else: colWarn)
    # The pair around the cursor.
    for m in pairMarks:
      if m.line == l: ui.border(rect(xOf(m.col), ly + 1, xOf(m.col + 1) - xOf(m.col), lineH - 2), colWhite)
    # Carets.
    if focused:
      for sc in allSels:
        if sc.caret.line == l: ui.rect(rect(xOf(sc.caret.col), ly + 1, 2, lineH - 2), colText)
    ui.popClip()
    # Line number.
    let numCol = if l == b.caret.line: colTextDim else: colCodeLineNo
    ui.textIn($(l + 1), rect(area.x, ly, gutterW - 10, lineH), numCol, mono, h = RightAlign)
    var mark = false
    for dg in an2.diags:
      if dg.line == l:
        mark = true
        ui.rect(rect(area.x + 2, ly + 3, 3, lineH - 6), if dg.error: colError else: colWarn)
        break
    discard mark
  ui.popClip()
  ui.scrollbar("scripts.text", area, b.scrollY, contentH)
  a.drawMini(area, focused)

  # Hover help.
  var hoverShown = false
  if hoverTok >= 0 and not e.dragging and ui.sk.mouseIdleTime >= 0.35 and not ui.popupHit and not refsOpen:
    let t = an2.toks[min(hoverTok, an2.toks.high)]
    if hoverTok < an2.toks.len:
      let (title, tipLines) = a.hoverText(b, an2, hoverTok)
      let tx = textX + vcol(b.lines[t.line], t.col).float32 * charW - b.scrollX
      let ty = area.y + 4 + t.line.float32 * lineH - b.scrollY
      let tipR = rect(tx, ty, charW * t.len.float32, lineH)
      if title.len > 0 or tipLines.len > 0:
        hoverShown = true
        scriptPopups.add proc() = a.drawCodeTip(tipR, title, tipLines)

  # The list of uses of a declaration (Ctrl+click on it, Shift+F12).
  if refsOpen and (refsBuf != b or refsVersion != b.version): refsOpen = false
  if refsOpen:
    let rl = min(refsAt.line, b.lines.high)
    let anchor = rect(textX + vcol(b.lines[rl], refsAt.col).float32 * charW - b.scrollX,
                      area.y + 4 + rl.float32 * lineH - b.scrollY, charW, lineH)
    scriptPopups.add proc() = a.drawUses(anchor, mono, lineH)

  # Signature help and completion, at the caret.
  if focused:
    scriptPopups.add proc() =
      let cx = textX + vcol(b.lines[b.caret.line], b.caret.col).float32 * charW - b.scrollX
      let cy = area.y + 4 + b.caret.line.float32 * lineH - b.scrollY
      # What's at the caret, above it (below when there's no room), starting
      # where the caret is: the call it's in with the part being typed
      # underlined, and what the word is.
      let rows = if e.caretTip and not hoverShown and b.extra.len == 0 and not b.hasSelection and not refsOpen:
                   a.caretRows(b, an2)
                 else: @[]
      caretTipDrawn = rows.len > 0
      var tipR: Rect
      if rows.len > 0:
        const Pad = 8'f32
        const Gap = 10'f32
        var whatW = 0'f32
        for r in rows: whatW = max(whatW, ui.textSize(r.what, FontSmall).x)
        let maxW = max(220'f32, min(area.w - 8, ui.size.x - 24))
        let codeMax = max(80'f32, maxW - Pad * 2 - whatW - Gap)
        var spans: seq[seq[Slice[int]]]
        var leads: seq[float32]
        var codeW = 0'f32
        var nLines = 0
        for r in rows:
          let lw = if r.lead > 0 and ui.textSize(r.code[0 ..< r.lead], mono).x <= codeMax * 0.4:
                     ui.textSize(r.code[0 ..< r.lead], mono).x
                   else: 2 * charW
          let sp = ui.wrapCode(r.code, codeMax, mono, lw)
          for k, sl in sp: codeW = max(codeW, (if k > 0: lw else: 0'f32) + ui.textSize(r.code[sl], mono).x)
          spans.add sp
          leads.add lw
          nLines += sp.len
        let tw = Pad * 2 + whatW + Gap + codeW
        let th = nLines.float32 * lineH + 6 + (rows.len - 1).float32 * 3
        tipR = rect(cx - Pad, cy - th - 4, tw, th)
        tipR.x = max(min(tipR.x, area.x + area.w - tw), area.x)
        if tipR.x + tw > ui.size.x - 4: tipR.x = max(4'f32, ui.size.x - 4 - tw)
        if tipR.y < area.y: tipR.y = cy + lineH + 2
        ui.sk.pushLayer(PopupsLayer)
        ui.rect(tipR, colPopup)
        ui.border(tipR, colBorder)
        var y = tipR.y + 3
        let smallDy = (lineH - ui.textSize("Ag", FontSmall).y) / 2
        for ri, r in rows:
          ui.text(r.what, vec2(tipR.x + Pad, y + smallDy), colTipWhere, FontSmall)
          let codeX = tipR.x + Pad + whatW + Gap
          for k, sl in spans[ri]:
            var px = codeX + (if k > 0: leads[ri] else: 0'f32)
            # Pieces of the line: the name, the part being typed, the rest.
            var cuts = @[sl.a, sl.b + 1]
            for c in [r.nameA, r.nameB, r.hiA, r.hiB]:
              if c > sl.a and c <= sl.b: cuts.add c
            cuts.sort()
            for j in 0 ..< cuts.high:
              let (x0, x1) = (cuts[j], cuts[j + 1])
              if x1 <= x0: continue
              let piece = r.code[x0 ..< x1]
              let pw = ui.textSize(piece, mono).x
              let inName = x0 >= r.nameA and x1 <= r.nameB
              if r.hiA >= 0 and x0 >= r.hiA and x1 <= r.hiB:
                ui.text(piece, vec2(px, y), (if inName: r.nameCol else: colAccentHover), mono)
                ui.rect(rect(px, y + lineH - 1, pw, 1), colAccentHover)
              elif inName: ui.text(piece, vec2(px, y), r.nameCol, mono)
              else: ui.text(piece, vec2(px, y), colTextDim, mono)
              px += pw
            y += lineH
          y += 3
        ui.sk.popLayer()
      if e.compOpen and e.compItems.len > 0:
        let n = e.compItems.len
        let rowH = lineH + 4
        let rows = min(n, CompRows)
        var labelW, whatW, detailW = 0'f32
        for it in e.compItems:
          labelW = max(labelW, ui.textSize(it.label, mono).x)
          whatW = max(whatW, ui.textSize(it.what, FontSmall).x)
          detailW = max(detailW, ui.textSize(it.detail, FontSmall).x)
        let lw = min(labelW, 300'f32) + 24
        let ww = if whatW > 0: min(whatW, 150'f32) + 14 else: 0'f32
        let dw = min(detailW, 320'f32)
        let listW = lw + ww + dw + 24
        let docLines = block:
          # The highlighted item's whole detail (a command's parameters) when
          # its column cuts it, then its description.
          let it = e.compItems[clamp(e.compHi, 0, n - 1)]
          var ls: seq[string]
          if ui.textSize(it.detail, FontSmall).x > dw:
            for k, sl in ui.wrapCode(it.detail, listW - 16, FontSmall, 2 * charW):
              ls.add (if k > 0: "    " else: "") & it.detail[sl]
          if it.doc.len > 0: ls.add ui.wrapText(it.doc, listW - 16, 1000, FontSmall)
          ls
        let docH = if docLines.len > 0: docLines.len.float32 * 17 + 10 else: 0'f32
        let h = rows.float32 * rowH + 4 + docH
        var r = rect(cx - ui.textSize(b.lines[b.caret.line][min(e.compStart.col, b.caret.col) ..< b.caret.col], mono).x - 12,
                     cy + lineH + 2, listW, h)
        if r.y + r.h > ui.size.y - 4: r.y = cy - h - 2
        # Clear of the tip at the caret when it's on the same side.
        if caretTipDrawn and r.y > cy and tipR.y > cy: r.y = tipR.y + tipR.h + 2
        elif caretTipDrawn and r.y < cy and tipR.y < cy: r.y = tipR.y - h - 2
        r.x = clamp(r.x, 4, max(4'f32, ui.size.x - r.w - 4))
        e.compScroll = clamp(e.compScroll, max(0, e.compHi - rows + 1), min(e.compHi, max(0, n - rows)))
        ui.popupRect = r
        ui.sk.pushLayer(PopupsLayer)
        ui.rect(rect(r.x + 3, r.y + 3, r.w, r.h), colShadow)
        ui.rect(r, colPopup)
        ui.border(r, colBorder)
        if ui.mouse.inside(r) and ui.scroll() != 0:
          e.compScroll = clamp(e.compScroll + (if ui.scroll() > 0: 1 else: -1), 0, max(0, n - rows))
          e.compHi = clamp(e.compHi, e.compScroll, e.compScroll + rows - 1)
          ui.scrollConsumed = true
        for k in 0 ..< rows:
          let i = e.compScroll + k
          if i >= n: break
          let it = e.compItems[i]
          let ir = rect(r.x + 2, r.y + 2 + k.float32 * rowH, r.w - 4, rowH)
          if i == e.compHi: drawListHi(ui, ir)
          elif ui.mouse.inside(ir): ui.rect(ir, colHover)
          var col = a.semColor(Tok(sem: it.kind, refk: it.refk))
          if it.tag.len > 0:
            let c = LevelObject(tag: it.tag).look.col
            col = rgbx(c[0], c[1], c[2], 255)
          ui.rect(rect(ir.x + 6, ir.y + rowH / 2 - 3, 6, 6), col)
          ui.text(ui.ellipsize(it.label, lw - 20, mono), vec2(ir.x + 18, ir.y + 2), col, mono)
          if ww > 0:
            ui.textIn(ui.ellipsize(it.what, ww - 14, FontSmall), rect(ir.x + lw, ir.y, ww, rowH), colTipWhere, FontSmall)
          ui.textIn(ui.ellipsize(it.detail, dw, FontSmall), rect(ir.x + lw + ww, ir.y, dw + 8, rowH),
                    if i == e.compHi: colText else: colTextDim, FontSmall)
          if it.sound > 0 and isMiniSound(it.label): ui.border(ir, colSoundMark)
          let soundClick = it.sound > 0 and w.ctrl
          if soundClick and ui.mouse.inside(ir): wantCursor = PointerCursor
          if ui.mouse.inside(ir) and a.window.buttonPressed[MouseLeft]:
            e.compHi = i
            if soundClick: a.openSound(it.label, it.sound == 2)   # Ctrl+click: listen; the list stays
            else: a.acceptCompletion(b)
            ui.consumeClick()
            ui.focusId = EditorId
        if docLines.len > 0:
          let dy = r.y + rows.float32 * rowH + 6
          ui.rect(rect(r.x, dy - 2, r.w, 1), colBorder)
          for k, l in docLines:
            ui.text(l, vec2(r.x + 8, dy + 3 + k.float32 * 17), colTextDim, FontSmall)
        ui.sk.popLayer()

  # Status: the caret and the file's problems.
  let st = rect(body.x, body.y + body.h - ScriptStatusH, body.w, ScriptStatusH)
  ui.rect(st, colPanelRaised)
  ui.rect(rect(st.x, st.y, st.w, 1), colBorder)
  var errs, warns = 0
  var atCaret = ""
  for dg in an2.diags:
    if dg.error: inc errs
    else: inc warns
    if dg.line == b.caret.line and atCaret.len == 0: atCaret = dg.msg
  let pos = if b.extra.len > 0: $(b.extra.len + 1) & " cursors"
            else: &"Ln {b.caret.line + 1}, Col {vcol(b.lines[b.caret.line], b.caret.col) + 1}"
  ui.textIn(pos, rect(st.x + 10, st.y, 110, st.h), colTextDim, FontSmall)
  let probs = if errs + warns == 0: "No problems" else: &"{errs} error(s), {warns} warning(s)"
  let pr = rect(st.x + 120, st.y, 150, st.h)
  ui.textIn(probs, pr, if errs > 0: colError elif warns > 0: colWarn else: colTextDim, FontSmall)
  if errs + warns > 0:
    ui.tip(pr, "Click: the next problem")
    if ui.hover(pr) and ui.pressed():
      ui.consumeClick()
      var next = -1
      for i, dg in an2.diags:
        if (dg.line, dg.col) > (b.caret.line, b.caret.col) and
           (next < 0 or (dg.line, dg.col) < (an2.diags[next].line, an2.diags[next].col)): next = i
      if next < 0:
        for i, dg in an2.diags:
          if next < 0 or (dg.line, dg.col) < (an2.diags[next].line, an2.diags[next].col): next = i
      let dg = an2.diags[next]
      b.caret = (dg.line, dg.col)
      b.anchor = b.caret
      revealCaret = true
      ui.focusId = EditorId
  let info = if atCaret.len > 0: atCaret
             elif e.defs != nil and e.defs.error.len > 0: e.defs.error
             else: a.relScript(b.path) & " · Ctrl+Space: suggestions · Ctrl+click: go to / list uses · Ctrl+F: find"
  ui.textIn(ui.ellipsize(info, st.w - 290, FontSmall), rect(st.x + 280, st.y, st.w - 290, st.h),
            if atCaret.len > 0: colWarn else: colTextDim, FontSmall)

proc overScriptEditor(a: App): bool =
  ## The mouse is over the Scripts panel's text, or the text has the keyboard.
  epochTime() - editorDrawnAt < 0.25 and (a.ui.focusId == EditorId or a.ui.mouse.inside(editorArea))

proc drawScriptPopups*(a: App) =
  ## The Scripts panel's hover help, argument help and completion list, over
  ## everything (call after the panels).
  let ps = scriptPopups
  scriptPopups.setLen 0
  for p in ps: p()
