# Checks src/textmatch.nim against the std/re patterns it replaced, on random
# strings built from the patterns' own pieces and, optionally, on real files
# (a list of paths, one per line, e.g. every .bsl and level .xml on disk).
# Needs PCRE (std/re), so it runs on Linux; Catwalk itself doesn't use it.
#   nim c -r -d:release --hints:off tools/textmatch_test.nim [paths.txt]
# Prints how often each pattern matched, so a test that only ever compares
# misses shows up, and exits 1 on any difference.

import std/[re, random, strutils, os, tables]
var hits = initCountTable[string]()
import ../src/textmatch

var fails = 0
var checks = 0

proc report(what, input: string, want, got: auto) =
  inc fails
  if fails <= 30:
    echo "MISMATCH ", what, "\n  input: ", input.escape, "\n  want:  ", want, "\n  got:   ", got

template check(what: string, input: string, want, got: untyped) =
  inc checks
  let w = want
  let g = got
  if w != g: report(what, input, w, g)
  elif $w notin ["", "@[]", "-1", "-", "false", "(first: -1, last: 0)", "oneEt", "onet", "onEt", "onEt"] and $w != input: hits.inc what

# The old patterns, exactly as Catwalk wrote them.
let
  rIdx = re"\[\d+\]"
  rFn = re"(?m)^\s*func\s+(?:(?:void|int|float|bool|string)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
  rSave = re"save_point\s+eq\s+(\d+)"
  rSky = re"<SkyBox>[^<]*</SkyBox>"
  rMain = re(r"func\s+(void\s+)?main\s*\(\s*(void)?\s*\)\s*\{")
  rAssign = re"^\s*(gl_fog_red|gl_fog_green|gl_fog_blue|gl_fog_start|gl_fog_end)\s*=\s*(-?[0-9]*\.?[0-9]+)"
  rFar = re"^\s*gs_farclipplane_set\s+(-?[0-9]*\.?[0-9]+)"
  rFogLine = re"(?m)^([ \t]*)(gl_fog_(red|green|blue|start|end)\s*=)"
  rField = re"Cannot read field '([^']+)' \(line (\d+)\)"
  rObj = re"""\s*<(\w{4}) Id="(\d+)">"""
  rName = re"\s*<Name>([^<]+)</Name>"
  rEmpty = re"\s*<[^>]*/>\s*$"
  rText = re"\s*<[^>]*>([^<]*)<"
  rInt = re"Visit(U?Int\d+|Byte|SByte)\b"
  rFloat = re"Visit(Float|Double)\b"
  rRec = re("(?<![A-Za-z0-9_])" & "rec_" & "[A-Za-z0-9_.-]+")
  rSkyTex = re"(?s)<SkyboxTextures>.*</SkyboxTextures>"

const FogPrefix = "# Catwalk: Properties, Level sets the fog instead: "

proc oldFuncs(text: string): seq[string] =
  # fieldchoices.nim's loop, as it was.
  var caps: array[1, string]
  var at = 0
  while true:
    let (first, stop) = text.findBounds(rFn, caps, at)
    if first < 0: break
    at = stop + 1
    result.add caps[0]

proc oldSave(text: string): seq[string] =
  var at = 0
  var caps: array[1, string]
  while true:
    let (first, stop) = text.findBounds(rSave, caps, at)
    if first < 0: break
    result.add caps[0]
    at = stop + 1

proc fogOld(l: string): string =
  var m: array[2, string]
  if l.match(rAssign, m): "A " & m[0] & "|" & m[1]
  elif l.match(rFar, m): "F " & m[0]
  else: "-"

proc fogNew(l: string): string =
  var m: array[2, string]
  if matchFogAssign(l, m): "A " & m[0] & "|" & m[1]
  elif matchFarPlane(l, m): "F " & m[0]
  else: "-"

proc fieldOld(o: string): string =
  var m: array[2, string]
  let at = o.find(rField, m)
  if at < 0: "-1" else: $at & "|" & m[0] & "|" & m[1]

proc fieldNew(o: string): string =
  var m: array[2, string]
  let at = findFieldError(o, m)
  if at < 0: "-1" else: $at & "|" & m[0] & "|" & m[1]

proc lineOld(l: string): string =
  var o: array[2, string]
  var n, v: array[1, string]
  result = (if l.match(rObj, o): "O" & o[0] & "|" & o[1] else: "o")
  result.add (if l.match(rName, n): "N" & n[0] else: "n")
  result.add (if l.match(rEmpty): "E" else: "e")
  result.add (if l.match(rText, v): "T" & v[0] else: "t")

proc lineNew(l: string): string =
  var o: array[2, string]
  var n, v: array[1, string]
  result = (if matchObjectHead(l, o): "O" & o[0] & "|" & o[1] else: "o")
  result.add (if matchNameElement(l, n): "N" & n[0] else: "n")
  result.add (if isEmptyElement(l): "E" else: "e")
  result.add (if matchElementText(l, v): "T" & v[0] else: "t")

proc all(s: string) =
  ## Every pattern on s.
  check("stripIndices", s, s.replace(rIdx, ""), stripIndices(s))
  check("scriptFuncs", s, oldFuncs(s), scriptFuncs(s))
  check("savePoints", s, oldSave(s), savePointNumbers(s))
  check("skybox", s, s.replace(rSky, "<SkyBox>X$1</SkyBox>"), replaceElement(s, "SkyBox", "<SkyBox>X$1</SkyBox>"))
  check("skyTextures", s, s.replace(rSkyTex, "<T>$1"), replaceSpan(s, "SkyboxTextures", "<T>$1"))
  check("main", s, findBounds(s, rMain), findMainFunc(s))
  check("fogLines", s, s.replacef(rFogLine, "$1" & FogPrefix & "$2"), commentFogLines(s, FogPrefix))
  check("fieldError", s, fieldOld(s), fieldNew(s))
  check("visitInt", s, s.find(rInt) >= 0, hasVisit(s, ["Byte", "SByte"], true))
  check("visitFloat", s, s.find(rFloat) >= 0, hasVisit(s, ["Float", "Double"]))
  check("recordings", s, s.findAll(rRec), findWordsWithPrefix(s, "rec_", {'A'..'Z', 'a'..'z', '0'..'9', '_', '.', '-'}))
  for l in s.splitLines:
    check("fog", l, fogOld(l), fogNew(l))
    check("lines", l, lineOld(l), lineNew(l))

# Pieces of every pattern plus characters that sit at their edges.
const Pieces = [
  " ", " ", "\t", "\n", "\r", "\v", "\f", "\r\n", "  ", "\n\n",
  "[", "]", "[2]", "[12]", "[]", "[a]", "0", "7", "42", ".", "-", "-1", ".5", "1.", "1.5", "1.5.3",
  "func", "func ", "funcx", "void", "void ", "int", "float", "bool", "string", "string_t", "main",
  "main(", "(", ")", "{", "}", "(void)", "( void )", "voidmain", "_x", "a1", "Foo", "x(",
  "save_point", "save_point eq ", "eq", " eq", "eqq",
  "<SkyBox>", "</SkyBox>", "<SkyBox></SkyBox>", "<", ">", "/>", "/", "<a/>", "<a>", "</a>",
  "<SkyboxTextures>", "</SkyboxTextures>",
  "gl_fog_red", "gl_fog_green", "gl_fog_blue", "gl_fog_start", "gl_fog_end", "gl_fog_redx", "=", " = ",
  "gs_farclipplane_set", "gs_farclipplane_set ",
  "Cannot read field '", "'", "' (line ", " (line ", "Cannot read field 'X' (line 12)",
  "<CHAR Id=\"", "\">", "<CHA Id=\"1\">", "<ONCC Id=\"12\">", "<Name>", "</Name>", "<Name>n</Name>",
  "Visit", "VisitInt32", "VisitUInt", "VisitUInt16", "VisitByte", "VisitSByte", "VisitByteArray",
  "VisitFloat", "VisitDouble", "VisitFloats", "Int", "UInt", "8", "x", "_",
  "rec_", "rec_a", "rec_a.b-c", "xrec_a", "_rec_b", ".rec_c", "\xC3\xA9", "\x85", "\xA0", "#", "\""]

randomize(20261114)
for n in 0 ..< 400_000:
  var s = ""
  for k in 0 ..< rand(1 .. 14): s.add sample(Pieces)
  all(s)
const Focus = ["func main", "func void main", "func void main(void)", "func main()", " ", "\t", "\n", "\r\n", "\v", "func", "func ", "void ", "void", "int ", "string ", "main", "main ",
  "(", "( ", "(void)", ")", " {", "{", "}", "x", "_a1", "gl_fog_red", "gl_fog_end", "gs_farclipplane_set ", "=", " = ",
  "0.5", "-1", ".", "1.", "#", "\"", "x(", "\n\tgl_fog_blue=0.2"]
for n in 0 ..< 600_000:
  var s = ""
  for k in 0 ..< rand(1 .. 12): s.add sample(Focus)
  all(s)
echo hits
hits.clear
echo "random: ", checks, " checks, ", fails, " mismatches"

if paramCount() >= 1:
  var files = 0
  for f in readFile(paramStr(1)).splitLines:
    if f.len == 0: continue
    var s: string
    try: s = readFile(f)
    except IOError: continue
    inc files
    all(s)
    check("stripIndices(path)", f, f.replace(rIdx, ""), stripIndices(f))
  echo hits
  echo "files: ", files, ", total ", checks, " checks, ", fails, " mismatches"

quit(if fails == 0: 0 else: 1)
