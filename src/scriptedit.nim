## Script files open in the Scripts panel (scriptpanel.nim): their text as
## lines, caret and selection, undo, reading and writing them, and the panel's
## other state (completion list, find bar). Text positions are (line, byte
## column).

import std/[os, strutils, times, tables]
import bsldefs, bslparse

type
  Pos* = tuple[line, col: int]

  EditStep = object
    at: Pos
    removed, inserted: string
    caretBefore, anchorBefore: Pos
    typing: bool
    time: float

  ScriptBuffer* = ref object
    path*: string
    lines*: seq[string]
    crlf*: bool                 ## Written back with \r\n (as the game's files are).
    version*: int               ## Bumped by every change.
    diskTime*: Time             ## The file's modification time when read or written.
    changedOnDisk*: bool        ## Another program changed it while it has unsaved edits.
    caret*, anchor*: Pos        ## anchor == caret: no selection.
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
    tag*: string                ## An object's name or id: its type (colored like it).
    then*: bool                 ## A command: a space follows and its arguments are offered.
    args*: string               ## A function name: the arguments it gets, added when nothing follows.

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
    # Find bar.
    findOpen*: bool
    findText*: string
    findFocus*: bool            ## Give the find field the keyboard next frame.
    # Mouse.
    dragging*: bool
    dragWords*: (Pos, Pos)      ## Double-click drag: the word first clicked.
    clicks*: int
    gameValues*: Table[string, CountTable[string]]  ## "command#arg" -> values game scripts pass.
    gameValuesRead*: bool

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

proc replace*(b: ScriptBuffer, a, z: Pos, s: string, typing = false, now = 0.0) =
  ## An edit: [a, z) becomes s and the caret goes after it. A run of typing
  ## (typing, within a second, word characters after word characters) is one
  ## undo step.
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
                        anchorBefore: anchorBefore, typing: typing, time: now)
  b.caret = e
  b.anchor = e
  b.wantX = -1

proc undoStep*(b: ScriptBuffer): bool =
  if b.undo.len == 0: return false
  let st = b.undo.pop
  discard b.apply(st.at, endOf(st.at, st.inserted), st.removed)
  b.redo.add st
  b.caret = st.caretBefore
  b.anchor = st.anchorBefore
  b.wantX = -1
  true

proc redoStep*(b: ScriptBuffer): bool =
  if b.redo.len == 0: return false
  let st = b.redo.pop
  let e = b.apply(st.at, endOf(st.at, st.removed), st.inserted)
  b.undo.add st
  b.undo[^1].typing = false   # nothing merges into a redone step
  b.caret = e
  b.anchor = e
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
