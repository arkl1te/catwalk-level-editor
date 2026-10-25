## The Scripts panel (included by panels.nim): a code editor for the level's
## BSL files (IGMD/<env>/*.bsl). Highlighting and checks follow what Oni's
## script reader accepts (bslparse.nim) and the commands and variables the
## player's Oni.exe defines (bsldefs.nim). Typing a word lists what fits there
## (Ctrl+Space asks), with the argument a command expects shown above the line;
## hovering a word says what it is. Names of the level's objects are drawn in
## their type's color: Ctrl+click one to select it (Properties, its Map row and
## the views go to it); Ctrl+click (or F12) a function goes to its declaration.
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
  colWarn = hexCol("#ffc857")

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
  defsSaid: bool
  scriptPopups: seq[proc()]                   ## Drawn after the panels, outside their clips.

const RefTags: array[RefKind, string] = ["", "CHAR", "TRGV", "PATR", "NEUT", "PART",
  "FLAG", "DOOR", "CONS", "TRIG", "TURR", "TRGV", ""]

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

proc resolveTok(a: App, t: Tok): LevelObject =
  ## The level object a token names, if any.
  if t.kind notin {tkIdent, tkString, tkNumber}: return
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

proc readGameValues(a: App) =
  ## The values the game's own scripts pass each command argument ("particle
  ## x do start"...), to offer them.
  let e = a.scripts
  if e.gameValuesRead: return
  e.gameValuesRead = true
  let dir = a.cfg.gameData / "IGMD"
  if not dirExists(dir): return
  for f in walkDirRec(dir):
    if not f.toLowerAscii.endsWith(".bsl"): continue
    var lines: seq[string]
    try: lines = readFile(f).replace("\r\n", "\n").split('\n')
    except IOError: continue
    let an = analyze(lines, lexBsl(lines), e.defs, ProjectIndex())
    for c in an.calls:
      if e.defs == nil or c.name notin e.defs.commands: continue
      for k, s in c.args:
        if s.a != s.b: continue
        let t = an.toks[s.a]
        if t.sem in {semBareWord, semNumber, semString}:
          e.gameValues.mgetOrPut(c.name & "#" & $k, initCountTable[string]()).inc t.text

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

proc enclosingParams(an: Analysis, line: int): seq[(string, string)] =
  ## The arguments of the function the line is in (the last one declared above it).
  for d in an.decls:
    if d.isFunc and d.line <= line: result = d.params

const ScriptWhen = {"Spawn": "when it spawns", "Die": "when it dies", "Combat": "when it starts fighting",
  "Alarm": "when it goes for an alarm", "Hurt": "when it's hurt", "Defeated": "when it's defeated",
  "OutOfAmmo": "when it runs out of ammo", "NoPath": "when it can't find a path",
  "Entry": "when a character enters it", "Inside": "while a character is inside it",
  "Exit": "when a character leaves it"}.toTable

proc calledFuncs(a: App, an: Analysis): seq[CompItem] =
  ## The function names the game or the level calls that no script declares
  ## yet: main, the objects' script fields, patrol paths' script points
  ## (patrolscriptNNNN, the only name besides main the game builds itself) and
  ## names this file passes as a script argument.
  let idx = a.scripts.index
  var seen: HashSet[string]
  proc add(items: var seq[CompItem], name, detail, doc: string, args = "(string ai_name)") =
    if name.len == 0 or name in idx.funcs or name in seen: return
    seen.incl name
    items.add CompItem(label: name, insert: name, detail: detail, doc: doc, kind: semFunc, args: args)
  result.add("main", "the level's start", "The game calls main by this name once the level has loaded, " &
    "with no arguments. It's where a level's scripts begin.", "(void)")
  for o in a.objects:
    let who = typeName(o.tag) & " " & o.label
    case o.tag
    of "CHAR", "TRGV":
      let sc = o.node.xpath("OSD/Scripts")
      if sc != nil:
        for c in sc:
          if c.kind != xnElement: continue
          let w = ScriptWhen.getOrDefault(c.tag, "")
          result.add(c.str.strip, &"{c.tag} script of {who}",
            &"{who} (#{o.id}) calls it by this name" & (if w.len > 0: " " & w else: "") &
            ", passing the character's name.")
    of "NEUT":
      result.add(o.node.xpath("OSD/Script/AfterTalk").str.strip, &"AfterTalk script of {who}",
        &"{who} (#{o.id}) calls it by this name after its dialogue, passing the character's name.")
    of "PATR":
      proc points(n: XmlNode, items: var seq[CompItem]) =
        for c in n:
          if c.kind != xnElement: continue
          if c.tag in ["CallScript", "ForkScript"] and c.attr("ScriptId").len > 0:
            try:
              let id = parseInt(c.attr("ScriptId").strip)
              items.add("patrolscript" & align($id, 4, '0'), &"{c.tag} point of {who}",
                &"A character following {who} reaches its {c.tag} point (ScriptId {id}) and the game " &
                "calls patrolscript plus the id in four digits, passing the character's name" &
                (if c.tag == "ForkScript": ", without waiting for it." else: "."))
            except ValueError: discard
          else: points(c, items)
      let pts = o.node.xpath("OSD/Points")
      if pts != nil: points(pts, result)
    else: discard
    let ev = o.node.xpath("OSD/Events")
    if ev != nil:
      for c in ev:
        if c.kind == xnElement and c.attr("Function").len > 0:
          result.add(c.attr("Function").strip, &"{c.tag} event of {who}",
            &"{who} (#{o.id}) calls it by this name when its events fire.", "")
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
        items.add CompItem(label: name, insert: name, detail: typ & " argument", kind: semLocal)
    for name, d in e.index.globals:
      if want.len == 0 or d.decl.typ == want:
        items.add CompItem(label: name, insert: name, detail: d.decl.typ & " variable",
                           doc: d.decl.doc, kind: semGlobal)
    if defs != nil and want.len == 0:
      for name, v in defs.variables:
        items.add CompItem(label: name, insert: name, detail: $v.typ & " (game)", doc: v.desc,
                           kind: semEngineVar)
  proc funcs(items: var seq[CompItem], then: bool) =
    for name, d in e.index.funcs:
      var ps: seq[string]
      for (t, n) in d.decl.params:
        if n.len > 0: ps.add t & " " & n
      items.add CompItem(label: name, insert: name, detail: "func(" & ps.join(", ") & ")",
                         doc: d.decl.doc, kind: semFunc, then: then and ps.len > 0)
  proc commands(items: var seq[CompItem], valuesOnly: bool) =
    if defs == nil: return
    for name, c in defs.commands:
      if valuesOnly and c.ret == btVoid: continue
      items.add CompItem(label: name, insert: name, detail: c.spec, doc: c.desc, kind: semCommand,
                         then: not valuesOnly and c.spec.len > 0)
  case ctx.kind
  of ckNone: discard
  of ckFuncName:
    let before = b.lines[b.caret.line][0 ..< ctx.start].strip
    if before == "func" or before.endsWith(" func"):
      for w in ["void", "int", "float", "string", "bool"]:
        result.add CompItem(label: w, insert: w, detail: "return type", doc: Keywords.getOrDefault(w),
                            kind: semType, then: true)
    for it in a.calledFuncs(an): result.add it
  of ckStatement:
    for kw in ["func", "var", "if", "else", "return", "sleep", "fork"]:
      result.add CompItem(label: kw, insert: kw, detail: "keyword", doc: Keywords[kw], kind: semKeyword,
                          then: kw != "else")
    result.commands(false)
    result.funcs(true)
    result.variables()
  of ckExpr:
    for kw in ["eq", "ne", "and", "or", "true", "false"]:
      result.add CompItem(label: kw, insert: kw, detail: "keyword", doc: Keywords[kw], kind: semKeyword)
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
                             kind: semNumber, tag: tag)
      else:
        var rows: seq[(string, LevelObject)]
        for o in a.objects:
          if o.tag == tag and o.objName.len > 0: rows.add (o.objName, o)
        rows.sort(proc(x, y: (string, LevelObject)): int = cmpIgnoreCase(x[0], y[0]))
        for (n, o) in rows:
          items.add CompItem(label: n, insert: n, detail: typeName(tag) & " #" & $o.id, kind: semBareWord, tag: tag)
    discard idx
    for p in params:
      for v in p.values:
        items.add CompItem(label: v, insert: v, detail: p.name, kind: (if v[0] in Digits: semNumber else: semString))
      let rk = refFor(c.name, p.name)
      if rk == rkFuncName: items.funcs(false)
      elif rk != rkNone: items.objects(rk)
      let (itag, pre, suf) = instanceTag(c.name, p.name)
      if itag.len > 0:
        if a.catalog == nil: a.catalog = newCatalog()
        a.catalog.refresh(a.cfg.gameData, a.proj.dir)
        for n in a.catalog.instanceNames(itag, pre, suf):
          items.add CompItem(label: n, insert: n, detail: itag, kind: semBareWord)
    if c.name == "particle" and ctx.arg == 0: items.objects(rkPartTag)
    # What the game's scripts pass there.
    a.readGameValues()
    let key = c.name & "#" & $ctx.arg
    if key in e.gameValues:
      var used = e.gameValues[key]
      used.sort()
      var n = 0
      for v, k in used:
        items.add CompItem(label: v, insert: v, detail: &"used {k}× in the game's scripts",
                           kind: (if v[0] in Digits or v[0] == '-': semNumber else: semBareWord))
        inc n
        if n >= 40: break
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
    if l == pre and ctx.kind != ckArg: continue
    if l.startsWith(pre): first.add it
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
  let line = b.lines[b.caret.line]
  let z = wordAt(line, b.caret.col)[1]
  let start = (b.caret.line, min(e.compStart.col, b.caret.col))
  var ins = it.insert
  if it.then and (z >= line.len or line[z] notin {' ', '\t', '('}): ins.add " "
  if it.args.len > 0 and line[z .. ^1].strip.len == 0: ins.add it.args
  b.replace(start, (b.caret.line, max(z, b.caret.col)), ins, now = epochTime())
  e.compOpen = false
  if it.then: a.updateCompletion(b, onSpace = true)

# --- hover help -------------------------------------------------------------------------------

proc declText(d: DeclRef, rel: string): string =
  var ps: seq[string]
  for (t, n) in d.decl.params:
    ps.add (if n.len > 0: t & " " & n else: t)
  if d.decl.isFunc:
    result = "func " & (if d.decl.typ.len > 0: d.decl.typ & " " else: "") & d.decl.name & "(" & ps.join(", ") & ")"
  else:
    result = "var " & d.decl.typ & " " & d.decl.name
  result.add "\n" & rel & ", line " & $(d.decl.line + 1)
  if d.decl.doc.len > 0: result.add "\n" & d.decl.doc

proc hoverText(a: App, an: Analysis, ti: int): (string, string) =
  ## (title in code font, explanation) for the token.
  let e = a.scripts
  let t = an.toks[ti]
  let defs = e.defs
  var title, body: string
  case t.sem
  of semCommand:
    let c = defs.commands[t.text]
    title = c.signature
    body = c.desc & (if not c.checked: "\nThe game doesn't check its arguments." else: "")
  of semEngineVar:
    let v = defs.variables[t.text]
    title = $v.typ & " " & v.name
    body = v.desc & "\nA variable of the game (set it with " & v.name & " = value)."
  of semKeyword, semType, semOperator:
    title = t.text
    body = Keywords.getOrDefault(t.text)
  of semFunc, semGlobal, semDeclName:
    let (ok, d) = a.findDecl(t.text)
    if ok:
      let parts = declText(d, a.relScript(d.file)).split('\n', 1)
      title = parts[0]
      body = if parts.len > 1: parts[1] else: ""
      if t.sem != semDeclName: body.add "\nCtrl+click or F12: go to it"
  of semLocal:
    title = t.text
    body = "An argument or local variable of this function."
  of semUnknownCall:
    title = t.text
    body = "No command of the game or function of the level's scripts has this name."
  of semNumber:
    if t.text.startsWith("f"): body = "Written fN, the game reads " & numberValue(t.text) & "."
  else: discard
  # As an argument: which one it is.
  if t.call >= 0 and t.arg >= 0:
    let c = an.calls[t.call]
    let f = formFor(an, defs, t.call)
    if t.arg < f.len:
      let p = f[t.arg]
      let line = "Argument " & p.argText & " of " & c.name
      body = if body.len > 0: line & "\n" & body else: line
  let o = a.resolveTok(t)
  if o != nil:
    if title.len == 0: title = t.text
    let line = typeName(o.tag) & " " & o.label & " #" & $o.id & " in this level · Ctrl+click: select it"
    body = if body.len > 0: line & "\n" & body else: line
  elif t.refk in {rkCharName, rkTrgvName, rkPatrName, rkNeutName, rkPartTag} and t.kind != tkNumber:
    let line = "No " & typeName(RefTags[t.refk]).toLowerAscii & " named " & t.text & " in this level"
    body = if body.len > 0: line & "\n" & body else: line
  elif t.refk == rkFuncName:
    let (ok, d) = a.findDecl(t.text.strip(chars = {'"'}), funcsOnly = true)
    if ok:
      title = declText(d, a.relScript(d.file)).split('\n')[0]
      body.add "\nCtrl+click: go to it"
  for dg in an.diags:
    if dg.line == t.line and t.col < dg.col + dg.len and dg.col < t.col + t.len:
      body.add "\n" & (if dg.error: "Error: " else: "Warning: ") & dg.msg
  (title, body.strip)

proc linkTarget(a: App, an: Analysis, ti: int): (LevelObject, string) =
  ## What Ctrl+click on the token goes to: an object, or a declaration's name.
  let t = an.toks[ti]
  let o = a.resolveTok(t)
  if o != nil: return (o, "")
  if t.sem in {semFunc, semGlobal}: return (nil, t.text)
  if t.refk == rkFuncName: return (nil, t.text.strip(chars = {'"'}))

proc hasLink(a: App, an: Analysis, ti: int): bool =
  let (o, name) = a.linkTarget(an, ti)
  o != nil or (name.len > 0 and a.findDecl(name)[0])

proc followLink(a: App, an: Analysis, ti: int): bool =
  let (o, name) = a.linkTarget(an, ti)
  if o != nil:
    a.focusObject(o)
    return true
  if name.len > 0:
    let (ok, d) = a.findDecl(name)
    if ok:
      a.openScriptAt(d.file, d.decl.line, d.decl.col)
      return true

proc semColor(a: App, t: Tok): ColorRGBX =
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

proc drawCodeTip(a: App, anchor: Rect, title, body: string) =
  ## A hover box: the title in the code font, then the explanation wrapped.
  let ui = a.ui
  if title.len == 0 and body.len == 0: return
  let monoH = ui.textSize("Ag", FontMono).y
  let smallH = ui.textSize("Ag", FontSmall).y
  var lines: seq[string]
  for para in body.split('\n'):
    for l in ui.wrapText(para, 440, 6, FontSmall): lines.add l
  var w = if title.len > 0: ui.textSize(title, FontMono).x else: 0'f32
  for l in lines: w = max(w, ui.textSize(l, FontSmall).x)
  w = min(w, 560) + 16
  let h = (if title.len > 0: monoH + 4 else: 0) + smallH * lines.len.float32 + 10
  var p = vec2(anchor.x, anchor.y - h - 4)
  if p.y < 4: p.y = anchor.y + anchor.h + 4
  p.x = clamp(p.x, 4, max(4'f32, ui.size.x - w - 4))
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(p.x + 3, p.y + 3, w, h), colShadow)
  ui.rect(rect(p, vec2(w, h)), colPopup)
  ui.border(rect(p, vec2(w, h)), colBorder)
  var y = p.y + 5
  if title.len > 0:
    ui.text(ui.ellipsize(title, w - 16, FontMono), vec2(p.x + 8, y), colCodeCommand, FontMono)
    y += monoH + 4
  for l in lines:
    let col = if l.startsWith("Error:"): colError elif l.startsWith("Warning:"): colWarn else: colText
    ui.text(l, vec2(p.x + 8, y), col, FontSmall)
    y += smallH
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

proc findNext(a: App, b: ScriptBuffer, back = false) =
  ## Selects the next (back: previous) match of the find text, wrapping around.
  let needle = a.scripts.findText.toLowerAscii
  if needle.len == 0: return
  var hits: seq[Pos]
  for l, line in b.lines:
    let hay = line.toLowerAscii
    var k = hay.find(needle)
    while k >= 0:
      hits.add (l, k)
      k = hay.find(needle, k + max(1, needle.len))
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
  template key(k: Button): bool = w.buttonPressed[k]
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
    if e.findOpen: e.findOpen = false
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
  if key(KeyF12):
    let an = a.analysisOf(b)
    let ti = an.tokAt(b.caret.line, b.caret.col)
    if ti >= 0: discard a.followLink(an, ti)
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
    if b.hasSelection:
      let (s0, s1) = b.selRange
      setClipboardString(b.textIn(s0, s1))
      if key(KeyX): deleteSel()
    else:
      # No selection: the whole line, as code editors do.
      let l = b.caret.line
      setClipboardString(b.lines[l] & "\n")
      if key(KeyX):
        if l < b.lines.high: b.replace((l, 0), (l + 1, 0), "", now = now)
        else: b.replace((l, 0), (l, b.lines[l].len), "", now = now)
        changed = true
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

  if changed or moved: revealCaret = true
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
    let fr = rect(r.x + 8, r.y + 3, max(80'f32, min(320'f32, r.w - 220)), 26)
    let enter = a.window.buttonPressed[KeyEnter] or a.window.buttonPressed[NumpadEnter]
    let wasFocused = ui.focusId == "scripts.find"
    let ev = ui.textField("scripts.find", fr, e.findText, "Find")
    if wasFocused and enter:
      a.findNext(b, back = a.window.shiftDown)
      ui.focusId = "scripts.find"
    elif wasFocused and a.window.buttonPressed[KeyEscape]:
      e.findOpen = false
      ui.focusId = EditorId
    discard ev
    var hits = 0
    if e.findText.len > 0:
      let nd = e.findText.toLowerAscii
      for l in b.lines: hits += l.toLowerAscii.count(nd)
    ui.textIn(if e.findText.len == 0: "" else: $hits & " found", rect(fr.x + fr.w + 8, r.y, 70, r.h), colTextDim, FontSmall)
    if ui.textButton("scripts.findprev", rect(fr.x + fr.w + 80, r.y + 3, 44, 26), "Prev"): a.findNext(b, back = true)
    ui.tip(rect(fr.x + fr.w + 80, r.y + 3, 44, 26), "Previous match (Shift+Enter, Shift+F3)")
    if ui.textButton("scripts.findnext", rect(fr.x + fr.w + 126, r.y + 3, 44, 26), "Next"): a.findNext(b)
    ui.tip(rect(fr.x + fr.w + 126, r.y + 3, 44, 26), "Next match (Enter, F3)")
    if ui.iconButton("scripts.findclose", rect(r.x + r.w - 30, r.y + 4, 24, 24), "close16", "Close (Esc)", focusable = false):
      e.findOpen = false
    y += FindBarH

  # The text.
  let mono = codeFont(a.codeFontSize)
  let lineH = round(ui.textSize("Ag", mono).y)
  let charW = ui.textSize("0000000000", mono).x / 10
  let area = rect(body.x, y, body.w, max(0'f32, body.y + body.h - ScriptStatusH - y))
  editorArea = area
  let digits = max(3, len($b.lines.len))
  let gutterW = digits.float32 * charW + 18
  let textX = area.x + gutterW + 6
  let textW = max(10'f32, area.w - gutterW - 6 - 12)
  let pageLines = max(1, int(area.h / lineH) - 1)
  let focused = ui.focusId == EditorId
  let w = a.window
  if focused: ui.keepFocus()
  let hov = ui.hover(area)

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
  if focused and (ui.pressed() or ui.pressed(MouseRight) or ui.pressed(MouseMiddle)) and not hov and
     not ui.popupHit:
    ui.focusId = ""
  # The scrollbar takes its press before the text.
  let contentH = b.lines.len.float32 * lineH + area.h * 0.5
  ui.scrollArea("scripts.text", area, b.scrollY)
  if hov and ui.pressed():
    ui.consumeClick()
    ui.focusId = EditorId
    ui.navId = ""
    e.compOpen = false
    if linkTok >= 0:
      discard a.followLink(an, linkTok)
    else:
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
    if not ui.down(): e.dragging = false
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
  let an2 = a.analysisOf(b)   # The keys may have changed the text.

  # Scrolling to the caret (or a line asked for).
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

  # Draw.
  ui.rect(area, colBackground)
  ui.rect(rect(area.x, area.y, gutterW, area.h), colPanel)
  ui.pushClip(area)
  let first = max(0, int(b.scrollY / lineH) - 1)
  let lastL = min(b.lines.high, first + int(area.h / lineH) + 2)
  let (s0, s1) = b.selRange
  var tokStart = newSeq[int](b.lines.len + 1)
  block:
    var k = 0
    for l in 0 .. b.lines.len:
      while k < an2.toks.len and an2.toks[k].line < l: inc k
      tokStart[l] = k
  let needle = if e.findOpen: e.findText.toLowerAscii else: ""
  for l in first .. lastL:
    let ly = area.y + 4 + l.float32 * lineH - b.scrollY
    let s = b.lines[l]
    proc xOf(col: int): float32 = textX + vcol(s, col).float32 * charW - b.scrollX
    if focused and l == b.caret.line and not b.hasSelection:
      ui.rect(rect(area.x + gutterW, ly, area.w - gutterW, lineH), colPanelRaised)
    # Selection.
    if b.hasSelection and l >= s0.line and l <= s1.line:
      let c0 = if l == s0.line: s0.col else: 0
      let c1 = if l == s1.line: s1.col else: s.len
      var x1 = xOf(c1)
      if l < s1.line: x1 += charW * 0.6
      ui.rect(rect(max(xOf(c0), area.x + gutterW), ly, max(0'f32, x1 - max(xOf(c0), area.x + gutterW)), lineH), colAccentDim)
    # Find matches.
    if needle.len > 0:
      let hay = s.toLowerAscii
      var k = hay.find(needle)
      while k >= 0:
        ui.rect(rect(xOf(k), ly, xOf(k + needle.len) - xOf(k), lineH), colCardRef)
        k = hay.find(needle, k + needle.len)
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
    # Problems.
    for dg in an2.diags:
      if dg.line != l: continue
      let x0 = xOf(dg.col)
      let x1 = max(x0 + charW, xOf(min(s.len, dg.col + dg.len)))
      ui.drawSquiggle(x0, x1, ly + lineH - 3, if dg.error: colError else: colWarn)
    # Caret.
    if focused and l == b.caret.line:
      ui.rect(rect(xOf(b.caret.col), ly + 1, 2, lineH - 2), colText)
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

  # Hover help.
  var hoverShown = false
  if hoverTok >= 0 and not e.dragging and ui.sk.mouseIdleTime >= 0.35 and not ui.popupHit:
    let t = an2.toks[min(hoverTok, an2.toks.high)]
    if hoverTok < an2.toks.len:
      let (title, text) = a.hoverText(an2, hoverTok)
      let tx = textX + vcol(b.lines[t.line], t.col).float32 * charW - b.scrollX
      let ty = area.y + 4 + t.line.float32 * lineH - b.scrollY
      let tipR = rect(tx, ty, charW * t.len.float32, lineH)
      if title.len > 0 or text.len > 0:
        hoverShown = true
        scriptPopups.add proc() = a.drawCodeTip(tipR, title, text)

  # Signature help and completion, at the caret.
  if focused:
    scriptPopups.add proc() =
      let ctx = caretContext(an2, b.lines, b.caret.line, b.caret.col)
      let cx = textX + vcol(b.lines[b.caret.line], b.caret.col).float32 * charW - b.scrollX
      let cy = area.y + 4 + b.caret.line.float32 * lineH - b.scrollY
      if ctx.kind == ckArg and not hoverShown and e.defs != nil and an2.calls[ctx.call].name in e.defs.commands:
        let cmd = e.defs.commands[an2.calls[ctx.call].name]
        if cmd.spec.len > 0:
          let ps = paramsAt(an2, e.defs, ctx.call, ctx.arg)
          let head = cmd.name & " "
          let full = head & cmd.spec
          let tw = ui.textSize(full, mono).x + 16
          let nameX = textX + vcol(b.lines[an2.toks[an2.calls[ctx.call].tok].line],
                                   an2.toks[an2.calls[ctx.call].tok].col).float32 * charW - b.scrollX
          var r = rect(clamp(nameX, area.x, max(area.x, area.x + area.w - tw)), cy - lineH - 10, tw, lineH + 6)
          if r.y < area.y: r.y = cy + lineH + 2
          ui.sk.pushLayer(PopupsLayer)
          ui.rect(r, colPopup)
          ui.border(r, colBorder)
          var px = r.x + 8
          ui.text(head, vec2(px, r.y + 3), colCodeCommand, mono)
          px += ui.textSize(head, mono).x
          # The argument being written, highlighted in the list.
          var hiA, hiB = -1
          if ps.len > 0:
            hiA = ps[0].at
            hiB = ps[0].stop
          if hiA >= 0 and hiB <= cmd.spec.len:
            let pre = cmd.spec[0 ..< hiA]
            let mid = cmd.spec[hiA ..< hiB]
            ui.text(pre, vec2(px, r.y + 3), colTextDim, mono)
            px += ui.textSize(pre, mono).x
            ui.text(mid, vec2(px, r.y + 3), colAccentHover, mono)
            ui.rect(rect(px, r.y + 3 + lineH - 1, ui.textSize(mid, mono).x, 1), colAccentHover)
            px += ui.textSize(mid, mono).x
            ui.text(cmd.spec[hiB .. ^1], vec2(px, r.y + 3), colTextDim, mono)
          else:
            ui.text(cmd.spec, vec2(px, r.y + 3), colTextDim, mono)
          ui.sk.popLayer()
      if e.compOpen and e.compItems.len > 0:
        let n = e.compItems.len
        let rowH = lineH + 4
        let rows = min(n, CompRows)
        var labelW, detailW = 0'f32
        for it in e.compItems:
          labelW = max(labelW, ui.textSize(it.label, mono).x)
          detailW = max(detailW, ui.textSize(it.detail, FontSmall).x)
        let lw = min(labelW, 300'f32) + 24
        let dw = min(detailW, 320'f32)
        let listW = lw + dw + 24
        let docLines = block:
          let it = e.compItems[clamp(e.compHi, 0, n - 1)]
          if it.doc.len > 0: ui.wrapText(it.doc, listW - 16, 3, FontSmall) else: @[]
        let docH = if docLines.len > 0: docLines.len.float32 * 17 + 10 else: 0'f32
        let h = rows.float32 * rowH + 4 + docH
        var r = rect(cx - ui.textSize(b.lines[b.caret.line][min(e.compStart.col, b.caret.col) ..< b.caret.col], mono).x - 12,
                     cy + lineH + 2, listW, h)
        if r.y + r.h > ui.size.y - 4: r.y = cy - h - 2
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
          if i == e.compHi: ui.rect(ir, colAccentDim)
          elif ui.mouse.inside(ir): ui.rect(ir, colHover)
          var col = a.semColor(Tok(sem: it.kind))
          if it.tag.len > 0:
            let c = LevelObject(tag: it.tag).look.col
            col = rgbx(c[0], c[1], c[2], 255)
          ui.rect(rect(ir.x + 6, ir.y + rowH / 2 - 3, 6, 6), col)
          ui.text(ui.ellipsize(it.label, lw - 20, mono), vec2(ir.x + 18, ir.y + 2), col, mono)
          ui.textIn(ui.ellipsize(it.detail, dw, FontSmall), rect(ir.x + lw, ir.y, dw + 8, rowH), colTextDim, FontSmall)
          if ui.mouse.inside(ir) and a.window.buttonPressed[MouseLeft]:
            e.compHi = i
            a.acceptCompletion(b)
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
  let pos = &"Ln {b.caret.line + 1}, Col {vcol(b.lines[b.caret.line], b.caret.col) + 1}"
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
             else: a.relScript(b.path) & " · Ctrl+Space: suggestions · Ctrl+click: go to · Ctrl+F: find"
  ui.textIn(ui.ellipsize(info, st.w - 290, FontSmall), rect(st.x + 280, st.y, st.w - 290, st.h),
            if atCaret.len > 0: colWarn else: colTextDim, FontSmall)

proc drawScriptPopups*(a: App) =
  ## The Scripts panel's hover help, argument help and completion list, over
  ## everything (call after the panels).
  let ps = scriptPopups
  scriptPopups.setLen 0
  for p in ps: p()
