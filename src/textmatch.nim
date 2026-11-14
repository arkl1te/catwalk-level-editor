## The few text patterns Catwalk looks for, matched by hand.
##
## These replace std/re, which loads PCRE at run time: Windows has no
## pcre64.dll, so a Catwalk using std/re couldn't even start there. Each proc
## names the regular expression it stands for and gives the same result as
## std/re did (ASCII classes; \s is space, tab, \n, \v, \f and \r), checked
## against std/re by tools/textmatch_test.nim.

import std/strutils

const
  Word = {'A'..'Z', 'a'..'z', '0'..'9', '_'}

proc skipWs(s: string, i: int): int =
  ## The first index at or after i that isn't whitespace (\s*).
  result = i
  while result < s.len and s[result] in Whitespace: inc result

proc skipSet(s: string, i: int, chars: set[char]): int =
  result = i
  while result < s.len and s[result] in chars: inc result

proc at(s: string, i: int, word: string): bool =
  ## Whether s has word at index i.
  i >= 0 and i + word.len <= s.len and s.continuesWith(word, i)

proc stripIndices*(path: string): string =
  ## path.replace(re"\[\d+\]", ""): "Points[2]/Loop[0]/Id" -> "Points/Loop/Id".
  result = newStringOfCap(path.len)
  var i = 0
  while i < path.len:
    if path[i] == '[':
      let e = skipSet(path, i + 1, Digits)
      if e > i + 1 and e < path.len and path[e] == ']':
        i = e + 1
        continue
    result.add path[i]
    inc i

proc scriptFuncs*(text: string): seq[string] =
  ## The names re"(?m)^\s*func\s+(?:(?:void|int|float|bool|string)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
  ## finds in text, in order, repeats included.
  proc name(s: string, i: int): int =
    # [A-Za-z_][A-Za-z0-9_]*\s*\( at i: the name's end, or -1.
    if i >= s.len or s[i] notin {'A'..'Z', 'a'..'z', '_'}: return -1
    result = skipSet(s, i + 1, Word)
    let p = skipWs(s, result)
    if p >= s.len or s[p] != '(': return -1
  var i = 0
  while i < text.len:
    # A start: the text's start or just after a newline.
    if i == 0 or text[i - 1] == '\n':
      let f = skipWs(text, i)
      if text.at(f, "func"):
        let a = f + 4
        let b = skipWs(text, a)
        if b > a:
          var found = -1
          var stop = -1
          for t in ["void", "int", "float", "bool", "string"]:
            if text.at(b, t):
              let c = skipWs(text, b + t.len)
              if c > b + t.len:
                let e = name(text, c)
                if e >= 0: (found, stop) = (c, e)
              break   # The words don't start one another: only one can be here.
          if found < 0:
            let e = name(text, b)
            if e >= 0: (found, stop) = (b, e)
          if found >= 0:
            result.add text[found ..< stop]
            i = skipWs(text, stop) + 1   # Past the "(", like findBounds' next start.
            continue
    inc i

proc savePointNumbers*(text: string): seq[string] =
  ## The (\d+) of every re"save_point\s+eq\s+(\d+)" in text.
  var i = text.find("save_point")
  while i >= 0:
    var next = i + 1
    let a = i + "save_point".len
    let b = skipWs(text, a)
    if b > a and text.at(b, "eq"):
      let c = skipWs(text, b + 2)
      if c > b + 2:
        let e = skipSet(text, c, Digits)
        if e > c:
          result.add text[c ..< e]
          next = e
    i = text.find("save_point", next)

proc replaceElement*(xml, tag, by: string): string =
  ## xml.replace(re"<Tag>[^<]*</Tag>", by): every such element with no child
  ## element becomes by.
  let open = "<" & tag & ">"
  let close = "</" & tag & ">"
  result = newStringOfCap(xml.len)
  var last = 0
  var i = xml.find(open)
  while i >= 0:
    var next = i + 1
    let e = xml.find('<', i + open.len)
    if e >= 0 and xml.at(e, close):
      result.add xml[last ..< i]
      result.add by
      last = e + close.len
      next = last
    i = xml.find(open, next)
  result.add xml[last .. ^1]

proc replaceSpan*(xml, tag, by: string): string =
  ## xml.replace(re"(?s)<Tag>.*</Tag>", by): from the first <Tag> to the last
  ## </Tag> after it, as one piece.
  let open = "<" & tag & ">"
  let close = "</" & tag & ">"
  let i = xml.find(open)
  if i < 0: return xml
  let j = xml.rfind(close)
  if j < i + open.len: return xml
  xml[0 ..< i] & by & xml[j + close.len .. ^1]

proc findMainFunc*(s: string): (int, int) =
  ## findBounds(s, re"func\s+(void\s+)?main\s*\(\s*(void)?\s*\)\s*\{"): where
  ## main()'s header starts and where its { is; (-1, 0) when there's none.
  var i = s.find("func")
  while i >= 0:
    let a = i + 4
    let b = skipWs(s, a)
    if b > a:
      var m = -1
      if s.at(b, "void"):
        let c = skipWs(s, b + 4)
        if c > b + 4 and s.at(c, "main"): m = c
      elif s.at(b, "main"): m = b
      if m >= 0:
        var p = skipWs(s, m + 4)
        if p < s.len and s[p] == '(':
          p = skipWs(s, p + 1)
          if s.at(p, "void"):
            let q = skipWs(s, p + 4)
            if q < s.len and s[q] == ')': p = q
          if p < s.len and s[p] == ')':
            p = skipWs(s, p + 1)
            if p < s.len and s[p] == '{': return (i, p)
    i = s.find("func", i + 1)
  (-1, 0)

proc number(s: string, i: int): int =
  ## -?[0-9]*\.?[0-9]+ at i: its end, or -1.
  var p = i
  if p < s.len and s[p] == '-': inc p
  let d = skipSet(s, p, Digits)
  if d < s.len and s[d] == '.' and d + 1 < s.len and s[d + 1] in Digits:
    return skipSet(s, d + 1, Digits)
  if d > p: d else: -1

const FogNames* = ["gl_fog_red", "gl_fog_green", "gl_fog_blue", "gl_fog_start", "gl_fog_end"]

proc matchFogAssign*(line: string, m: var array[2, string]): bool =
  ## line.match(re"^\s*(gl_fog_red|gl_fog_green|gl_fog_blue|gl_fog_start|gl_fog_end)\s*=\s*(-?[0-9]*\.?[0-9]+)", m)
  let a = skipWs(line, 0)
  for n in FogNames:
    if line.at(a, n):
      let b = skipWs(line, a + n.len)
      if b >= line.len or line[b] != '=': return false
      let c = skipWs(line, b + 1)
      let e = number(line, c)
      if e < 0: return false
      m = [n, line[c ..< e]]
      return true

proc matchFarPlane*(line: string, m: var array[2, string]): bool =
  ## line.match(re"^\s*gs_farclipplane_set\s+(-?[0-9]*\.?[0-9]+)", m), the
  ## number in m[0].
  let a = skipWs(line, 0)
  if not line.at(a, "gs_farclipplane_set"): return false
  let b = a + "gs_farclipplane_set".len
  let c = skipWs(line, b)
  if c == b: return false
  let e = number(line, c)
  if e < 0: return false
  m[0] = line[c ..< e]
  true

proc commentFogLines*(body, prefix: string): string =
  ## body.replacef(re"(?m)^([ \t]*)(gl_fog_(red|green|blue|start|end)\s*=)", "$1" & prefix & "$2").
  result = newStringOfCap(body.len + 256)
  var last = 0
  var i = 0
  while i < body.len:
    if i == 0 or body[i - 1] == '\n':
      let a = skipSet(body, i, {' ', '\t'})
      var e = -1
      for n in FogNames:
        if body.at(a, n):
          let b = skipWs(body, a + n.len)
          if b < body.len and body[b] == '=': e = b + 1
          break
      if e >= 0:
        result.add body[last ..< a]
        result.add prefix
        result.add body[a ..< e]
        last = e
        i = e
        continue
    inc i
  result.add body[last .. ^1]

proc findFieldError*(output: string, m: var array[2, string]): int =
  ## output.find(re"Cannot read field '([^']+)' \(line (\d+)\)", m): where it
  ## starts (-1 if nowhere), the field and line number in m.
  const head = "Cannot read field '"
  var i = output.find(head)
  while i >= 0:
    let a = i + head.len
    let q = output.find('\'', a)
    if q < 0: return -1   # No closing quote anywhere after: no later start can match either.
    if q > a and output.at(q, "' (line "):
      let d = q + "' (line ".len
      let e = skipSet(output, d, Digits)
      if e > d and e < output.len and output[e] == ')':
        m = [output[a ..< q], output[d ..< e]]
        return i
    i = output.find(head, i + 1)
  -1

proc matchObjectHead*(line: string, m: var array[2, string]): bool =
  ## line.match(re"""\s*<(\w{4}) Id="(\d+)">""", m)
  let a = skipWs(line, 0)
  if a >= line.len or line[a] != '<': return false
  let t = a + 1
  if t + 4 > line.len: return false
  for k in t ..< t + 4:
    if line[k] notin Word: return false
  if not line.at(t + 4, " Id=\""): return false
  let d = t + 4 + " Id=\"".len
  let e = skipSet(line, d, Digits)
  if e == d or not line.at(e, "\">"): return false
  m = [line[t ..< t + 4], line[d ..< e]]
  true

proc matchNameElement*(line: string, m: var array[1, string]): bool =
  ## line.match(re"\s*<Name>([^<]+)</Name>", m)
  let a = skipWs(line, 0)
  if not line.at(a, "<Name>"): return false
  let b = a + "<Name>".len
  let e = line.find('<', b)
  if e <= b or not line.at(e, "</Name>"): return false
  m[0] = line[b ..< e]
  true

proc isEmptyElement*(line: string): bool =
  ## line.match(re"\s*<[^>]*/>\s*$")
  let a = skipWs(line, 0)
  if a >= line.len or line[a] != '<': return false
  let k = line.find('>', a + 1)
  if k < 0 or k - 1 < a + 1 or line[k - 1] != '/': return false
  skipWs(line, k + 1) == line.len

proc matchElementText*(line: string, m: var array[1, string]): bool =
  ## line.match(re"\s*<[^>]*>([^<]*)<", m)
  let a = skipWs(line, 0)
  if a >= line.len or line[a] != '<': return false
  let k = line.find('>', a + 1)
  if k < 0: return false
  let e = line.find('<', k + 1)
  if e < 0: return false
  m[0] = line[k + 1 ..< e]
  true

proc hasVisit*(output: string, kinds: openArray[string], intSizes = false): bool =
  ## Whether output has "Visit" & one of kinds as a whole word; with intSizes
  ## also VisitInt<digits>/VisitUInt<digits>. hasVisit(o, ["Byte", "SByte"], true)
  ## is o.find(re"Visit(U?Int\d+|Byte|SByte)\b") >= 0, hasVisit(o, ["Float",
  ## "Double"]) is o.find(re"Visit(Float|Double)\b") >= 0.
  proc ends(s: string, e: int): bool = e >= s.len or s[e] notin Word
  var i = output.find("Visit")
  while i >= 0:
    let a = i + 5
    for k in kinds:
      if output.at(a, k) and output.ends(a + k.len): return true
    if intSizes:
      let b = if output.at(a, "UInt"): a + 4 elif output.at(a, "Int"): a + 3 else: -1
      if b >= 0:
        let e = skipSet(output, b, Digits)
        if e > b and output.ends(e): return true
    i = output.find("Visit", i + 1)

proc findWordsWithPrefix*(text, prefix: string, chars: set[char]): seq[string] =
  ## text.findAll(re("(?<![A-Za-z0-9_])" & prefix & "[chars]+")), for a prefix
  ## with no regex characters in it.
  var i = text.find(prefix)
  while i >= 0:
    var next = i + 1
    if i == 0 or text[i - 1] notin Word:
      let a = i + prefix.len
      let e = skipSet(text, a, chars)
      if e > a:
        result.add text[i ..< e]
        next = e
    i = text.find(prefix, next)
