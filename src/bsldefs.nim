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
    arklite*: bool             ## Arklite registers it, not the game (ArkliteCommands).

  BslVariable* = object
    name*, desc*: string
    typ*: BslType
    arklite*: bool             ## Arklite registers it, not the game (ArkliteVariables).

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
    "schedule": "schedule f(args) at ticks runs the function once that many game ticks later " &
      "(60 a second); schedule f(args) repeat times every ticks runs it that many times, that far " &
      "apart, the first one after the first wait. Either way the script goes on at once. The call " &
      "needs its ( ). No original level uses it; tested in game.",
    "at": "schedule f(args) at ticks: runs the function once, that many game ticks later.",
    "every": "schedule f(args) repeat times every ticks: the ticks between the runs (60 a second).",
    "repeat": "schedule f(args) repeat times every ticks: how many times the function runs.",
    "iterate": "Reserved word of the script language (no level script uses it).",
    "over": "Reserved word of the script language (no level script uses it).",
    "using": "Reserved word of the script language (no level script uses it).",
    "for": "Reserved word: BSL has no for (or while) loop, and the game crashes as the level " &
      "starts when a script has one (tested). Repeat with schedule f() repeat times every ticks, " &
      "or a function that ends with: sleep ticks, then fork itself with the next number. A " &
      "function calling itself directly stops after a few steps (calls nest at most 6 deep)."}.toTable

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

const ArkliteVariables* = [
  ## The variables Arklite adds to the game's (arklite/src/char_menu.c "Map scripts"):
  ## not in Oni.exe, so listed here. Each starts over at every level load, before main().
  ("ark_characterscreen_enabled", btBool,
   "Arklite: the character menu (F2) works on this map. At every level load it starts true on " &
   "a multiplayer map (two or more IsPlayer characters) and false on any other. Off, the player " &
   "is the map's character."),
  ("ark_characterscreen_instant_swap", btBool,
   "Arklite: in a network match, a character picked with F2 changes a living player at once " &
   "instead of at their next respawn. False at every level load. Elsewhere a pick is at once anyway."),
  ("ark_characterscreen_flags", btInt,
   "Arklite: which characters F2 offers, the sum of their numbers. -1 (at every level load) is " &
   "every character, 0 none. Konoko 1, Griffin 2, Muro 4, Barabas 8, Shinatama 16, Hasegawa 32, " &
   "Ninja 64, Striker 128, Tanker 256, Comguy 512, Elite 1024, Red 2048, TCTF SWAT 4096, " &
   "TCTF Trooper 8192, Cop 16384, Female Cop 32768, Thug 65536, Mad Bomber 131072, " &
   "Ninjabot 262144, Sniper 524288, Security Guard 1048576, Scientist 2097152, " &
   "Female Scientist 4194304, Civilian 8388608, Female Civilian 16777216, Mutant Muro 33554432, " &
   "Hanako 67108864, Naomi 134217728, Janice 268435456, BGI Sarai 536870912, " &
   "Kit Ballard 1073741824, Lara the sign bit (subtract 2147483648). Other mods' characters " &
   "only with -1. In a network game the host's Mutators decide instead."),
  ("ark_characters_alwaystaunt", btBool,
   "Arklite: taunts as in multiplayer: the player can taunt any time (not only after a kill), " &
   "and a new taunt line cuts off the one being said. At every level load it starts true on a " &
   "multiplayer map and false on any other."),
]

const ArkliteCommands* = [
  ## The commands Arklite adds to the game's (arklite/src/dialog.c), with the argument list
  ## Arklite registers: not in Oni.exe, so listed here.
  ("ark_sound_dialog_play_interrupt", "name:string [immediate:bool | ]",
   "Arklite: interrupts the current character dialog and plays a new one, like " &
   "sound_dialog_play_interrupt, and hides the interrupted line's subtitle at once (the game's " &
   "would stay on screen for the old line's whole time). The subtitle fades out in about a " &
   "second; with immediate true it goes without fading."),
  ("ark_sound_dialog_stop_all", "[immediate:bool | ]",
   "Arklite: stops all character dialog playing (overlapping lines too) and hides its subtitles. " &
   "A sound_dialog_play_block waiting goes on. The subtitles fade out in about a second; with " &
   "immediate true they go without fading."),
  ("ark_sound_dialog_play_overlap", "name:string",
   "Arklite: starts a character dialog line while another is playing: both are heard and both " &
   "subtitles show (sound_dialog_play would skip the new line, sound_dialog_play_interrupt would " &
   "cut the old one off). sound_dialog_play_block waits until both are done, and an interrupt or " &
   "ark_sound_dialog_stop_all stops both. With nothing playing it's sound_dialog_play."),
]

const ParticleSpec* = "tag:string [command:string | do:string{\"do\"} event:string]"
  ## The game registers particle without an argument list (ONiParticle3_Command reads
  ## its own words): the forms Catwalk shows for it, still unchecked. Form 0: tag command
  ## (create, kill, reset or an event name), form 1: tag do event (bslparse.checkParticle).

proc addArklite(defs: BslDefs) =
  if "particle" in defs.commands and defs.commands["particle"].spec.len == 0:
    let c = addr defs.commands["particle"]
    c.spec = ParticleSpec
    c.params = parseSpec(ParticleSpec)
    c.forms = forms(c.params)
  for (name, typ, desc) in ArkliteVariables:
    defs.variables[name] = BslVariable(name: name, desc: desc, typ: typ, arklite: true)
  for (name, spec, desc) in ArkliteCommands:
    var c = BslCommand(name: name, desc: desc, spec: spec, checked: true, ret: btVoid, arklite: true)
    c.params = parseSpec(spec)
    c.forms = forms(c.params)
    defs.commands[name] = c

proc thirdPerson(verb: string): string =
  ## "start" -> "starts", "push" -> "pushes", "copy" -> "copies" (regular
  ## verbs only: tidyDesc leaves be, have, do and go alone).
  let v = verb.toLowerAscii
  if v.len == 0: return verb
  if v.endsWith("s") or v.endsWith("sh") or v.endsWith("ch") or v.endsWith("x") or v.endsWith("z"):
    verb & "es"
  elif v.len > 1 and v.endsWith("y") and v[^2] notin {'a', 'e', 'i', 'o', 'u'}:
    verb[0 ..< ^1] & "ies"
  else: verb & "s"

const DescFixes = {
  # A second verb the rule below wouldn't turn ("and play").
  "function to interrupt the current character dialog and play a new one":
    "Interrupts the current character dialog and plays a new one"}.toTable

proc tidyDesc*(desc: string): string =
  ## Some descriptions in Oni.exe start with "function to start ..." or
  ## "function plays ...": they start with the verb instead, as the others
  ## do ("Starts ...", "Plays ..."). Anything else is left as it is.
  result = desc
  if desc.strip in DescFixes: return DescFixes[desc.strip]
  let words = desc.strip.splitWhitespace
  var i = 0
  if i < words.len and words[i].toLowerAscii in ["a", "this", "the"]: inc i
  if i >= words.len or words[i].toLowerAscii notin ["function", "func", "command"]: return
  inc i
  var verb = ""
  if i + 1 < words.len and words[i].toLowerAscii == "to":
    let v = words[i + 1].toLowerAscii
    if v in ["be", "have", "do", "go"] or not v.allCharsInSet({'a'..'z'}): return
    verb = thirdPerson(words[i + 1])
    i += 2
  elif i < words.len and words[i].toLowerAscii.endsWith("s") and words[i].allCharsInSet({'a'..'z', 'A'..'Z'}) and
       words[i].toLowerAscii notin ["is", "has", "was", "this", "its"]:
    verb = words[i]
    inc i
  else: return
  result = verb[0].toUpperAscii & verb[1 .. ^1]
  if i < words.len: result.add " " & words[i .. ^1].join(" ")

proc loadBslDefs*(exePath: string): BslDefs =
  ## The game's commands and variables, read from exePath (an Oni.exe of the
  ## version bsltable.nim was made from), and Arklite's variables.
  result = BslDefs(exe: exePath)
  defer: result.addArklite()
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
    var c = BslCommand(name: name, desc: tidyDesc(cstr(row[1])), spec: spec, checked: row[2] != 0 and spec.len > 0,
                       ret: if row[3] in 0 .. 3: BslType(row[3]) else: btVoid)
    c.params = parseSpec(spec)
    c.forms = forms(c.params)
    result.commands[name] = c
  for row in BslVariableAt:
    let name = cstr(row[0])
    if not name.isName: continue
    result.variables[name] = BslVariable(name: name, desc: tidyDesc(cstr(row[1])),
                                         typ: if row[2] in 0 .. 3: BslType(row[2]) else: btString)
  if result.commands.len < BslCommandAt.len div 2:
    result.error = exePath & " doesn't hold the commands where Catwalk expects them"
    result.commands.clear()
    result.variables.clear()

proc signature*(c: BslCommand): string =
  ## "name args" as the console's help shows it, with the return type in front.
  result = (if c.ret != btVoid: $c.ret & " " else: "") & c.name
  if c.spec.len > 0: result.add " " & c.spec
