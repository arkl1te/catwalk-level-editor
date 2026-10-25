## The BSL language of Oni's level scripts (IGMD/<level>/*.bsl): its keywords,
## and the commands and variables the game defines. Those are read from the
## player's own Oni.exe: bsltable.nim only says where the game keeps each one's
## name, description and argument list (tools/bsl_table.py finds them).
##
## An argument list is the game's own notation, e.g.
##   [ai_name:string | script_id:int] film_name:string [mode:string{"fromhere" | "interp"} | ]
## name:type is one argument, {a | b} the values it takes, [x | y] one of x or
## y, and an empty choice ([x | ]) makes x optional.

import std/[os, strutils, tables]
import bsltable

type
  BslType* = enum btInt = "int", btString = "string", btFloat = "float", btBool = "bool", btVoid = "void"

  ParamNode* = object
    ## One argument (alts empty), or a choice between sequences of them.
    name*: string
    typ*: BslType
    values*: seq[string]       ## {a | b}: the only values it takes (quotes removed).
    alts*: seq[seq[ParamNode]]
    at*, stop*: int            ## Where it is in the argument list text.

  BslCommand* = object
    name*, desc*, spec*: string
    params*: seq[ParamNode]
    checked*: bool             ## The game has an argument list for it (else takes anything).
    ret*: BslType              ## btVoid: returns nothing.
    forms*: seq[seq[ParamNode]]  ## Every way to write its arguments (the choices expanded).

  BslVariable* = object
    name*, desc*: string
    typ*: BslType

  BslDefs* = ref object
    commands*: Table[string, BslCommand]
    variables*: Table[string, BslVariable]
    exe*: string               ## The Oni.exe they were read from.
    error*: string             ## Why they couldn't be ("" = they were).

const
  Keywords* = {
    "func": "Declares a function: func [type] name(type arg, ...) { ... }. The type is what it " &
      "returns (void or none: nothing). Any function can be called from the console, other " &
      "functions or an object's script field; main() runs when the level starts.",
    "var": "Declares a variable: var type name = value; Outside functions it is global to all " &
      "of the level's script files and keeps its value; inside one it lasts for that call.",
    "if": "if (condition) { ... } runs the block when the condition is true (not 0).",
    "else": "else { ... } after an if block runs when its condition was false.",
    "return": "Leaves the function, giving back a value if it returns one: return x",
    "sleep": "sleep frames (or fN): pauses this script for that many game frames, 60 a second. " &
      "Other scripts and the game keep running.",
    "fork": "fork function args: starts the function as a separate script and goes on at once, " &
      "without waiting for it (it can sleep on its own).",
    "eq": "Equal: a eq b is true when a and b are the same.",
    "ne": "Not equal: a ne b is true when a and b differ.",
    "and": "a and b: true when both are true.",
    "or": "a or b: true when either is true.",
    "true": "The bool value true (1).",
    "false": "The bool value false (0).",
    "void": "No value: a function that returns nothing, or one that takes no arguments: func void name(void)",
    "int": "Type: a whole number.",
    "float": "Type: a number with a fraction, like 0.75.",
    "bool": "Type: true or false.",
    "string": "Type: text. Bare words are strings: ai2_spawn A_t48 passes \"A_t48\".",
    "schedule": "Reserved word of the script language (no level script uses it).",
    "at": "Reserved word of the script language (no level script uses it).",
    "every": "Reserved word of the script language (no level script uses it).",
    "repeat": "Reserved word of the script language (no level script uses it).",
    "iterate": "Reserved word of the script language (no level script uses it).",
    "over": "Reserved word of the script language (no level script uses it).",
    "using": "Reserved word of the script language (no level script uses it).",
    "for": "Reserved word of the script language (no level script uses it)."}.toTable

  TypeWords* = ["void", "int", "float", "bool", "string"]
  OperatorWords* = ["eq", "ne", "and", "or"]

proc oniExePath*(aeDir: string): string =
  ## Oni.exe next to the AE folder (<Oni>/AE and <Oni>/Oni.exe).
  aeDir.parentDir / "Oni.exe"

# --- argument lists ------------------------------------------------------------------------

proc parseType(s: string): BslType =
  case s.toLowerAscii
  of "int": btInt
  of "float": btFloat
  of "bool": btBool
  else: btString

proc parseSeq(s: string, i: var int, stops: set[char]): seq[ParamNode] =
  while true:
    while i < s.len and s[i] in Whitespace: inc i
    if i >= s.len or s[i] in stops: return
    if s[i] == '[':
      var n = ParamNode(at: i)
      inc i
      while true:
        n.alts.add parseSeq(s, i, {'|', ']'})
        if i < s.len and s[i] == '|':
          inc i
          continue
        if i < s.len and s[i] == ']': inc i
        break
      n.stop = i
      result.add n
    else:
      var n = ParamNode(at: i)
      var name = ""
      while i < s.len and s[i] notin {':', ' ', '[', ']', '|'}:
        name.add s[i]
        inc i
      var typ = ""
      if i < s.len and s[i] == ':':
        inc i
        while i < s.len and s[i] in IdentChars:
          typ.add s[i]
          inc i
      n.name = name
      n.typ = parseType(typ)
      if i < s.len and s[i] == '{':
        let e = s.find('}', i)
        let body = if e < 0: s[i + 1 .. ^1] else: s[i + 1 ..< e]
        for v in body.split('|'):
          let t = v.strip.strip(chars = {'"'})
          if t.len > 0: n.values.add t
        i = if e < 0: s.len else: e + 1
      n.stop = i
      if name.len == 0 and typ.len == 0:
        inc i   # a stray character: skip it
        continue
      result.add n

proc parseSpec*(s: string): seq[ParamNode] =
  var i = 0
  while i < s.len:
    result.add parseSeq(s, i, {'|', ']'})
    if i < s.len: inc i   # a stray | or ]

proc expand(nodes: seq[ParamNode], k: int, prefix: seq[ParamNode], acc: var seq[seq[ParamNode]]) =
  if acc.len >= 512: return
  if k >= nodes.len:
    acc.add prefix
    return
  let n = nodes[k]
  if n.alts.len == 0:
    expand(nodes, k + 1, prefix & n, acc)
  else:
    for alt in n.alts:
      expand(alt & nodes[k + 1 .. ^1], 0, prefix, acc)

proc forms*(nodes: seq[ParamNode]): seq[seq[ParamNode]] =
  ## Every flat sequence of arguments the list allows, shortest choices first.
  expand(nodes, 0, @[], result)

proc argText*(p: ParamNode): string =
  result = p.name & ":" & $p.typ
  if p.values.len > 0: result.add "{" & p.values.join(" | ") & "}"

# --- Oni.exe -------------------------------------------------------------------------------

type Section = tuple[va, size, raw, rawSize: int]

proc u16(d: string, o: int): int =
  if o + 2 > d.len: 0 else: d[o].uint8.int or (d[o + 1].uint8.int shl 8)

proc u32(d: string, o: int): int =
  if o + 4 > d.len: 0
  else: d[o].uint8.int or (d[o + 1].uint8.int shl 8) or (d[o + 2].uint8.int shl 16) or
    (d[o + 3].uint8.int shl 24)

proc loadBslDefs*(exePath: string): BslDefs =
  ## The game's commands and variables, read from exePath (an Oni.exe of the
  ## version bsltable.nim was made from).
  result = BslDefs(exe: exePath)
  var d: string
  try: d = readFile(exePath)
  except IOError, OSError:
    result.error = "Oni.exe not found at " & exePath
    return
  if d.len != OniExeSize or d.len < 0x400 or d[0 ..< 2] != "MZ":
    result.error = exePath & " isn't the Oni.exe version Catwalk knows (" & $d.len & " bytes)"
    return
  let pe = u32(d, 0x3c)
  let nsec = u16(d, pe + 6)
  let optSize = u16(d, pe + 20)
  let base = u32(d, pe + 24 + 28)
  var secs: seq[Section]
  for k in 0 ..< nsec:
    let s = pe + 24 + optSize + 40 * k
    secs.add (base + u32(d, s + 12), u32(d, s + 8), u32(d, s + 20), u32(d, s + 16))
  proc cstr(va: int): string =
    if va == 0: return ""
    for s in secs:
      if va >= s.va and va < s.va + max(s.size, s.rawSize):
        var o = va - s.va + s.raw
        while o < d.len and d[o] != '\0' and o < s.raw + s.rawSize:
          result.add d[o]
          inc o
        return
  proc isName(s: string): bool =
    s.len > 0 and s[0] in IdentStartChars and s.allCharsInSet(IdentChars)
  for row in BslCommandAt:
    let name = cstr(row[0])
    if not name.isName: continue
    let spec = cstr(row[2])
    var c = BslCommand(name: name, desc: cstr(row[1]), spec: spec, checked: row[2] != 0 and spec.len > 0,
                       ret: if row[3] in 0 .. 3: BslType(row[3]) else: btVoid)
    c.params = parseSpec(spec)
    c.forms = forms(c.params)
    result.commands[name] = c
  for row in BslVariableAt:
    let name = cstr(row[0])
    if not name.isName: continue
    result.variables[name] = BslVariable(name: name, desc: cstr(row[1]),
                                         typ: if row[2] in 0 .. 3: BslType(row[2]) else: btString)
  if result.commands.len < BslCommandAt.len div 2:
    result.error = exePath & " doesn't hold the commands where Catwalk expects them"
    result.commands.clear()
    result.variables.clear()

proc signature*(c: BslCommand): string =
  ## "name args" as the console's help shows it, with the return type in front.
  result = (if c.ret != btVoid: $c.ret & " " else: "") & c.name
  if c.spec.len > 0: result.add " " & c.spec
