## Script files open in the Scripts panel (scriptpanel.nim): their text as
## lines, caret and selection, undo, reading and writing them, and the panel's
## other state (completion list, find bar). Text positions are (line, byte
## column).

import std/[os, strutils, times, tables, sets, algorithm]
import bsldefs, bslparse

type
  Pos* = tuple[line, col: int]
  Sel* = tuple[caret, anchor: Pos]   ## A cursor and the end of its selection (anchor == caret: none).

  EditStep = object
    at: Pos
    removed, inserted: string
    caretBefore, anchorBefore: Pos
    typing: bool
    time: float
    group: int                  ## Steps with the same group (not 0) undo together.

  ScriptBuffer* = ref object
    path*: string
    lines*: seq[string]
    crlf*: bool                 ## Written back with \r\n (as the game's files are).
    version*: int               ## Bumped by every change.
    diskTime*: Time             ## The file's modification time when read or written.
    changedOnDisk*: bool        ## Another program changed it while it has unsaved edits.
    caret*, anchor*: Pos        ## anchor == caret: no selection.
    extra*: seq[Sel]            ## More cursors (Ctrl+D, Alt+click); caret/anchor is the newest one.
    wordSel*: Sel               ## The word Ctrl+D last selected from a bare cursor: it adds whole words.
    groupSeq*: int              ## Last undo group handed out.
    typeGroup*: int             ## Typing at several cursors: the run's undo group, and when and
    typeTime*: float            ## what (a word character) was typed last.
    typeWord*: bool
    wantX*: float32             ## Up/Down keep this column (pixels), -1: the caret's.
    scrollY*, scrollX*: float32
    undo, redo: seq[EditStep]
    savedDepth: int             ## undo.len when saved (-1: that state is gone).
    an*: Analysis               ## Analysis of version anVersion with index anIndex.
    anVersion*, anIndex*: int

  CompItem* = object
    label*, detail*, doc*: string
    insert*: string             ## Text that replaces the typed word.
    kind*: Sem                  ## Its color.
    what*: string               ## What it is, shown in its own column ("function", "variable"...).
    call*: int                  ## A function or command: 1 takes no arguments, 2 takes some (0: not one).
    tag*: string                ## An object's name or id: its type (colored like it).
    then*: bool                 ## A command: a space follows and its arguments are offered.
    args*: string               ## A function name: the arguments it gets, added when nothing follows.
    also*: string               ## Another word that finds it when typed ("arklite" for Arklite's).
    sound*: int                 ## A sound's name: 1 an ambient (.amb), 2 an impulse (.imp); 0 not one.
    refk*: RefKind              ## What it names as an argument (particle commands and events get their colors).

  GameExample* = object
    ## A line of the game's own scripts that uses a command or variable.
    folder*, file*: string      ## IGMD folder (the level's environment) and file name.
    level*: int                 ## The game level (0: unknown).
    line*: int
    code*: string               ## The line, trimmed.
    score*: seq[int]            ## Lower: a better example.

  DiskFile* = object
    ## A script file of the level that isn't open, read for its declarations.
    time*: Time
    decls*: seq[Decl]

  ScriptEditor* = ref object
    buffers*: seq[ScriptBuffer]
    active*: int
    defs*: BslDefs
    disk*: Table[string, DiskFile]
    files*: seq[string]         ## The level's .bsl files (absolute), sorted.
    filesChecked*: float
    index*: ProjectIndex
    indexVersion*: int          ## Bumped whenever index changes.
    indexKey*: string
    # Completion list.
    compOpen*: bool
    compItems*: seq[CompItem]
    compHi*, compScroll*: int
    compStart*: Pos             ## Start of the word it completes.
    caretTip*: bool             ## Show what's at the caret above it (typing and keys turn it on,
                                ## a click or Esc off).
    # Find bar.
    findOpen*: bool
    findText*: string
    findFocus*: bool            ## Give the find field the keyboard next frame.
    findCase*: bool             ## Match case (else any case).
    findWord*: bool             ## Whole words only.
    # Mouse.
    dragging*: bool
    dragWords*: (Pos, Pos)      ## Double-click drag: the word first clicked.
    clicks*: int
    gameValues*: Table[string, CountTable[string]]  ## "command#arg" -> values game scripts pass.
    gameValuesRead*: bool
    gameExamples*: Table[string, GameExample]  ## Command or variable -> a line of the game's scripts using it.

proc `<`*(a, b: Pos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)
proc `<=`*(a, b: Pos): bool = not (b < a)

proc newBuffer(path: string): ScriptBuffer =
  ScriptBuffer(path: path, lines: @[""], wantX: -1)

proc readText(b: ScriptBuffer) =
  var s = ""
  try: s = readFile(b.path)
  except IOError, OSError: discard
  b.crlf = "\r\n" in s
  b.lines = s.replace("\r\n", "\n").replace("\r", "\n").split('\n')
  if b.lines.len == 0: b.lines = @[""]
  try: b.diskTime = getLastModificationTime(b.path)
  except OSError: discard

proc loadBuffer*(path: string): ScriptBuffer =
  result = newBuffer(path)
  result.readText()

proc dirty*(b: ScriptBuffer): bool = b.undo.len != b.savedDepth

proc text*(b: ScriptBuffer): string =
  b.lines.join(if b.crlf: "\r\n" else: "\n")

proc save*(b: ScriptBuffer) =
  createDir(b.path.parentDir)
  writeFile(b.path, b.text)
  b.savedDepth = b.undo.len
  b.changedOnDisk = false
  try: b.diskTime = getLastModificationTime(b.path)
  except OSError: discard

proc reload*(b: ScriptBuffer) =
  ## Reads the file again, dropping the edits (undo can't go back past it).
  let caret = b.caret
  b.readText()
  b.undo.setLen 0
  b.redo.setLen 0
  b.savedDepth = 0
  b.changedOnDisk = false
  inc b.version
  b.caret = (min(caret.line, b.lines.high), 0)
  b.anchor = b.caret

proc checkDisk*(b: ScriptBuffer) =
  ## Picks up a change another program made: reloads when there are no
  ## unsaved edits, else marks it.
  var t: Time
  try: t = getLastModificationTime(b.path)
  except OSError: return
  if t == b.diskTime: return
  if b.dirty: b.changedOnDisk = true
  else: b.reload()

proc clampPos*(b: ScriptBuffer, p: Pos): Pos =
  let l = clamp(p.line, 0, b.lines.high)
  (l, clamp(p.col, 0, b.lines[l].len))

proc hasSelection*(b: ScriptBuffer): bool = b.caret != b.anchor

proc selRange*(b: ScriptBuffer): (Pos, Pos) =
  if b.anchor < b.caret: (b.anchor, b.caret) else: (b.caret, b.anchor)

proc textIn*(b: ScriptBuffer, a, z: Pos): string =
  if a.line == z.line: return b.lines[a.line][a.col ..< z.col]
  result = b.lines[a.line][a.col .. ^1]
  for l in a.line + 1 ..< z.line: result.add "\n" & b.lines[l]
  result.add "\n" & b.lines[z.line][0 ..< z.col]

proc apply(b: ScriptBuffer, a, z: Pos, s: string): Pos =
  ## Replaces [a, z) with s; returns the end of the inserted text.
  let head = b.lines[a.line][0 ..< a.col]
  let tail = b.lines[z.line][z.col .. ^1]
  let parts = s.split('\n')
  var repl: seq[string]
  for i, p in parts:
    var line = p
    if i == 0: line = head & line
    if i == parts.high: line.add tail
    repl.add line
  b.lines[a.line .. z.line] = repl
  inc b.version
  let last = a.line + parts.high
  (last, b.lines[last].len - tail.len)

proc endOf(a: Pos, s: string): Pos =
  let parts = s.split('\n')
  if parts.len == 1: (a.line, a.col + s.len) else: (a.line + parts.high, parts[^1].len)

proc replace*(b: ScriptBuffer, a, z: Pos, s: string, typing = false, now = 0.0, group = 0) =
  ## An edit: [a, z) becomes s and the caret goes after it (the other cursors
  ## go). A run of typing (typing, within a second, word characters after
  ## word characters) is one undo step.
  b.extra.setLen 0
  let removed = b.textIn(a, z)
  if removed.len == 0 and s.len == 0: return
  let caretBefore = b.caret
  let anchorBefore = b.anchor
  let e = b.apply(a, z, s)
  b.redo.setLen 0
  if b.savedDepth > b.undo.len: b.savedDepth = -1
  var merged = false
  if typing and removed.len == 0 and b.undo.len > 0 and b.undo.len != b.savedDepth:
    let last = addr b.undo[^1]
    if last.typing and last.removed.len == 0 and endOf(last.at, last.inserted) == a and
       now - last.time < 1.0 and s.len == 1 and last.inserted.len > 0 and
       (s[0] in IdentChars) == (last.inserted[^1] in IdentChars) and s != "\n":
      last.inserted.add s
      last.time = now
      merged = true
  if not merged:
    b.undo.add EditStep(at: a, removed: removed, inserted: s, caretBefore: caretBefore,
                        anchorBefore: anchorBefore, typing: typing, time: now, group: group)
  b.caret = e
  b.anchor = e
  b.wantX = -1

proc replaceSpans*(b: ScriptBuffer, spans: openArray[tuple[at: Pos, len: int]], s: string) =
  ## Puts s in place of each span (each within one line, none overlapping),
  ## all as one undo step.
  if spans.len == 0: return
  var sp = @spans
  sp.sort(proc(x, y: tuple[at: Pos, len: int]): int =
    if x.at < y.at: -1 elif y.at < x.at: 1 else: 0)
  let first = sp[0].at
  let last: Pos = (sp[^1].at.line, sp[^1].at.col + sp[^1].len)
  var text = ""
  var cur = first
  for x in sp:
    text.add b.textIn(cur, x.at)
    text.add s
    cur = (x.at.line, x.at.col + x.len)
  b.replace(first, last, text)

proc selStart*(c: Sel): Pos = (if c.caret < c.anchor: c.caret else: c.anchor)
proc selEnd*(c: Sel): Pos = (if c.caret < c.anchor: c.anchor else: c.caret)

proc cursors*(b: ScriptBuffer): seq[Sel] =
  ## Every cursor, in text order.
  result = @[(b.caret, b.anchor)] & b.extra
  result.sort(proc(x, y: Sel): int =
    if x.selStart < y.selStart: -1 elif y.selStart < x.selStart: 1 else: 0)

proc setCursors*(b: ScriptBuffer, cs: seq[Sel], primary: Sel) =
  ## Puts the cursors at cs (primary is the newest), merging ones that overlap
  ## or sit at the same place.
  var sorted = cs
  for c in sorted.mitems:
    c.caret = b.clampPos(c.caret)
    c.anchor = b.clampPos(c.anchor)
  sorted.sort(proc(x, y: Sel): int =
    if x.selStart < y.selStart: -1 elif y.selStart < x.selStart: 1 else: 0)
  var merged: seq[Sel]
  var prim = -1
  for c in sorted:
    let isPrim = c == primary
    if merged.len > 0 and (c.selStart < merged[^1].selEnd or c.selStart == merged[^1].selStart):
      let a = merged[^1].selStart
      let z = if merged[^1].selEnd < c.selEnd: c.selEnd else: merged[^1].selEnd
      merged[^1] = (z, a)
      if isPrim: prim = merged.high
    else:
      merged.add c
      if isPrim: prim = merged.high
  if prim < 0: prim = merged.high
  b.caret = merged[prim].caret
  b.anchor = merged[prim].anchor
  b.extra.setLen 0
  for i, c in merged:
    if i != prim: b.extra.add c

proc undoGroup*(b: ScriptBuffer): int =
  ## The group of the step Ctrl+Z would undo (0: none).
  if b.undo.len > 0: b.undo[^1].group else: 0

proc multiEdit*(b: ScriptBuffer, edits: seq[tuple[a, z: Pos, s: string]], group = 0): seq[Pos] =
  ## Edits at several places as one undo step: each [a, z) becomes s (in text
  ## order; an edit that would overlap the one before starts where that ends).
  ## Returns where each s ends afterwards.
  if edits.len == 0: return
  var es = edits
  for i in 1 ..< es.len:
    if es[i].a < es[i - 1].z: es[i].a = es[i - 1].z
    if es[i].z < es[i].a: es[i].z = es[i].a
  let first = es[0].a
  let last = es[^1].z
  var text = ""
  var cur = first
  var ends: seq[int]
  for e in es:
    text.add b.textIn(cur, e.a)
    text.add e.s
    ends.add text.len
    cur = e.z
  b.replace(first, last, text, group = group)
  for k in ends: result.add endOf(first, text[0 ..< k])

proc mapPos*(p: Pos, edits: seq[tuple[a, z: Pos, s: string]], ends: seq[Pos]): Pos =
  ## Where p is after multiEdit(edits) returned ends.
  result = p
  for k in countdown(edits.high, 0):
    let e = edits[k]
    if e.z <= p and (e.a != e.z or e.a <= p):
      return if p.line == e.z.line: (ends[k].line, ends[k].col + p.col - e.z.col)
             else: (p.line + ends[k].line - e.z.line, p.col)
    if e.a < p: return ends[k]

proc undoStep*(b: ScriptBuffer): bool =
  if b.undo.len == 0: return false
  b.extra.setLen 0
  let g = b.undo[^1].group
  while b.undo.len > 0:
    let st = b.undo.pop
    discard b.apply(st.at, endOf(st.at, st.inserted), st.removed)
    b.redo.add st
    b.caret = st.caretBefore
    b.anchor = st.anchorBefore
    if g == 0 or b.undo.len == 0 or b.undo[^1].group != g: break
  b.wantX = -1
  true

proc redoStep*(b: ScriptBuffer): bool =
  if b.redo.len == 0: return false
  b.extra.setLen 0
  let g = b.redo[^1].group
  while b.redo.len > 0:
    let st = b.redo.pop
    let e = b.apply(st.at, endOf(st.at, st.removed), st.inserted)
    b.undo.add st
    b.undo[^1].typing = false   # nothing merges into a redone step
    b.caret = e
    b.anchor = e
    if g == 0 or b.redo.len == 0 or b.redo[^1].group != g: break
  b.wantX = -1
  true

proc current*(e: ScriptEditor): ScriptBuffer =
  if e == nil or e.active notin 0 ..< e.buffers.len: nil else: e.buffers[e.active]

proc anyDirty*(e: ScriptEditor): bool =
  if e == nil: return false
  for b in e.buffers:
    if b.dirty: return true

proc saveAll*(e: ScriptEditor): int =
  ## Writes the buffers with unsaved edits; returns how many.
  if e == nil: return
  for b in e.buffers:
    if b.dirty:
      b.save()
      inc result

proc readGameScripts*(e: ScriptEditor, dir: string, envs: Table[string, int]) =
  ## Reads the game's scripts (dir: its IGMD) for gameValues and gameExamples.
  ## Each level's folder is read with its own declarations, as the game reads
  ## it; envs: folder (lowercase) -> level number.
  var files: seq[string]
  for f in walkDirRec(dir):
    if f.toLowerAscii.endsWith(".bsl"): files.add f
  files.sort(cmpIgnoreCase)
  var texts: Table[string, seq[string]]
  var idxs: Table[string, ProjectIndex]   ## Folder -> its files' declarations.
  for f in files:
    var lines: seq[string]
    try: lines = readFile(f).replace("\r\n", "\n").split('\n')
    except IOError: continue
    texts[f] = lines
    let folder = f.parentDir.extractFilename
    var idx = idxs.getOrDefault(folder)
    for d in scanDecls(lines, lexBsl(lines)):
      if d.isFunc:
        if d.name notin idx.funcs: idx.funcs[d.name] = DeclRef(file: f, decl: d)
      elif d.name notin idx.globals: idx.globals[d.name] = DeclRef(file: f, decl: d)
    idxs[folder] = idx
  proc better(x, y: seq[int]): bool =
    for k in 0 ..< min(x.len, y.len):
      if x[k] != y[k]: return x[k] < y[k]
    x.len < y.len
  proc offer(key: string, ex: GameExample) =
    if key notin e.gameExamples or better(ex.score, e.gameExamples[key].score): e.gameExamples[key] = ex
  for fi, f in files:
    if f notin texts: continue
    let lines = texts[f]
    let folder = f.parentDir.extractFilename
    let an = analyze(lines, lexBsl(lines), e.defs, idxs.getOrDefault(folder))
    var flagged: HashSet[int]
    for dg in an.diags: flagged.incl dg.line
    let level = envs.getOrDefault(folder.toLowerAscii)
    proc example(t: Tok): (GameExample, bool) =
      ## The line of token t as code (a comment after it cut), whether it starts the line.
      var code = lines[t.line]
      var first = -1
      for j, u in an.toks:
        if u.line != t.line: continue
        if u.kind == tkComment:
          code = code[0 ..< u.col]
          break
        if first < 0: first = j
      (GameExample(folder: folder, file: f.extractFilename, level: level, line: t.line,
                   code: code.strip), first >= 0 and an.toks[first].line == t.line and
                                      an.toks[first].col == t.col)
    for c in an.calls:
      if c.name notin e.defs.commands: continue
      for k, s in c.args:
        if s.a != s.b: continue
        let t = an.toks[s.a]
        if t.sem in {semBareWord, semNumber, semString}:
          e.gameValues.mgetOrPut(c.name & "#" & $k, initCountTable[string]()).inc t.text
      let t = an.toks[c.tok]
      if t.sem != semCommand: continue
      var (ex, starts) = example(t)
      if ex.code.len == 0: continue
      var wantsArgs = false
      for fm in e.defs.commands[c.name].forms:
        if fm.len > 0: wantsArgs = true
      ex.score = @[ord(t.line in flagged), ord(not starts), ord(wantsArgs and c.args.len == 0), ord(ex.code.len > 80),
                   (if level > 0: level else: 1000), fi, t.line]
      offer("c:" & c.name, ex)
    for ti, t in an.toks:
      if t.sem != semEngineVar: continue
      var (ex, starts) = example(t)
      if ex.code.len == 0: continue
      ex.score = @[ord(t.line in flagged), ord(not starts), ord(ex.code.len > 80), (if level > 0: level else: 1000), fi, t.line]
      offer("v:" & t.text, ex)

