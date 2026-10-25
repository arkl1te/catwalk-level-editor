## Reading BSL the way Oni does (its lexer is ptLang_Token.c, 0x47dac0): the
## tokens of a script file, then what each one is (keyword, command, function,
## variable, object reference...), the calls with their arguments matched to
## the command's argument list, the declarations, and the problems the game
## would complain about.
##
## Oni's rules: # starts a comment to the end of the line; "..." is a string;
## a number is digits and dots, optionally after a - or an f ("f60" is 60, the
## frame count vanilla scripts write after sleep); a word starts with a letter
## or _. Statements end at the end of the line or a ;. A call's arguments are
## the words after its name, or a (comma, separated) list in parentheses.

import std/[strutils, strformat, tables, sets]
import bsldefs

type
  TokKind* = enum tkIdent, tkNumber, tkString, tkComment, tkPunct

  Sem* = enum
    semPlain, semComment, semString, semNumber, semKeyword, semType, semOperator, semPunct,
    semCommand,      ## one of the game's commands
    semEngineVar,    ## one of the game's variables
    semFunc,         ## a function of the level's scripts
    semGlobal,       ## a variable declared outside functions
    semLocal,        ## a function's argument or a variable declared inside it
    semDeclName,     ## the name a func or var declares
    semUnknownCall,  ## called, but no command or function has that name
    semBareWord      ## a word that is just text (an object's name, a film...)

  RefKind* = enum
    ## What an argument names, judged by the argument list's names.
    rkNone, rkCharName, rkTrgvName, rkPatrName, rkNeutName, rkPartTag,
    rkFlagId, rkDoorId, rkConsoleId, rkTriggerId, rkTurretId, rkTrgvId, rkFuncName

  Tok* = object
    kind*: TokKind
    line*, col*, len*: int      ## col: byte offset in its line.
    text*: string
    sem*: Sem
    refk*: RefKind
    call*: int = -1             ## The call it's the name (arg -1) or an argument of.
    arg*: int = -1
    decl*: int = -1             ## semDeclName: index in Analysis.decls.

  Decl* = object
    name*: string
    isFunc*: bool
    typ*: string                ## Function: what it returns ("" = nothing); variable: its type.
    params*: seq[(string, string)]  ## Function: (type, name) of each argument.
    line*, col*: int
    doc*: string                ## The comment just above it.

  Call* = object
    name*: string
    tok*: int                   ## The name's token.
    args*: seq[Slice[int]]      ## Each argument's tokens.
    paren*: bool                ## name(a, b) rather than name a b.
    open*, close*: int          ## paren: the ( and ) tokens (close -1: missing).
    last*: int                  ## The statement's last token.
    form*: int = -1             ## Engine command: the argument form the arguments match (-1: none).

  Diag* = object
    line*, col*, len*: int
    msg*: string
    error*: bool                ## Else a warning.

  Analysis* = ref object
    toks*: seq[Tok]
    calls*: seq[Call]
    decls*: seq[Decl]
    diags*: seq[Diag]

  DeclRef* = object
    file*: string
    decl*: Decl

  ProjectIndex* = object
    ## Declarations of every script file of the level (BSL names are global).
    funcs*: Table[string, DeclRef]
    globals*: Table[string, DeclRef]

const
  IdStart = {'a'..'z', 'A'..'Z', '_'}
  IdChar = IdStart + {'0'..'9'}

proc isWord(t: Tok, s: string): bool = t.kind == tkIdent and t.text == s
proc isPunct(t: Tok, s: string): bool = t.kind == tkPunct and t.text == s

# --- lexer -------------------------------------------------------------------------------

proc lexBsl*(lines: seq[string]): seq[Tok] =
  for ln, s in lines:
    var i = 0
    while i < s.len:
      let c = s[i]
      if c in Whitespace:
        inc i
        continue
      let start = i
      var kind: TokKind
      if c == '#':
        i = s.len
        kind = tkComment
      elif c == '"':
        inc i
        while i < s.len and s[i] != '"': inc i
        if i < s.len: inc i
        kind = tkString
      elif c in Digits or (c == '.' and i + 1 < s.len and s[i + 1] in Digits) or
           (c in {'-', 'f'} and i + 1 < s.len and s[i + 1] in Digits):
        inc i
        while i < s.len and s[i] in Digits + {'.'}: inc i
        kind = tkNumber
      elif c in IdStart:
        while i < s.len and s[i] in IdChar: inc i
        kind = tkIdent
      else:
        inc i
        if i < s.len and s[i] == '=' and c in {'=', '!', '<', '>'}: inc i
        kind = tkPunct
      result.add Tok(kind: kind, line: ln, col: start, len: i - start, text: s[start ..< i])

# --- argument roles ------------------------------------------------------------------------

proc refFor*(cmd, param: string): RefKind =
  ## What a command's argument names, by the argument list's name for it.
  case param
  of "ai_name", "target_name", "forget_char": rkCharName
  of "path_name": rkPatrName
  of "flag_id": rkFlagId
  of "door_id": rkDoorId
  of "console_id": rkConsoleId
  of "trigger_id": rkTriggerId
  of "turret_id": rkTurretId
  of "trig_id": rkTrgvId
  of "script": rkFuncName
  of "behavior": (if cmd == "ai2_neutralbehavior": rkNeutName else: rkNone)
  of "name": (if cmd.startsWith("trigvolume_"): rkTrgvName else: rkNone)
  else: rkNone

proc numberValue*(t: string): string =
  ## A number token as the game reads it ("f60" -> "60").
  if t.startsWith("f"): t[1 .. ^1] else: t

# --- declarations ------------------------------------------------------------------------------

proc docAbove(lines: seq[string], line: int): string =
  ## The comment lines right above a declaration (not rules of #####).
  var parts: seq[string]
  var k = line - 1
  while k >= 0:
    let s = lines[k].strip
    if not s.startsWith("#"): break
    let t = s.strip(chars = {'#', ' ', '\t'})
    if t.len > 0 and not t.allCharsInSet({'#', '-', '=', '*', ' '}): parts.insert(t, 0)
    dec k
  parts.join(" ")

type Parser = object
  lines: seq[string]
  an: Analysis
  sig: seq[int]                 ## Non-comment token indices.
  p: int
  defs: BslDefs
  idx: ProjectIndex
  locals: Table[string, string] ## name -> type, inside a function.
  depth: int

proc tk(ps: Parser, k = 0): Tok =
  let i = ps.p + k
  if i < ps.sig.len: ps.an.toks[ps.sig[i]] else: Tok(kind: tkPunct, line: int.high, text: "")

proc ti(ps: Parser, k = 0): int =
  let i = ps.p + k
  if i < ps.sig.len: ps.sig[i] else: -1

proc atEnd(ps: Parser): bool = ps.p >= ps.sig.len

proc warn(ps: var Parser, t: Tok, msg: string, error = false) =
  ps.an.diags.add Diag(line: t.line, col: t.col, len: max(1, t.len), msg: msg, error: error)

proc setSem(ps: var Parser, i: int, s: Sem) =
  if i >= 0: ps.an.toks[i].sem = s

proc typeOf(ps: Parser, name: string): (bool, string) =
  ## Whether name is a variable here, and its type.
  if name in ps.locals: return (true, ps.locals[name])
  if name in ps.idx.globals: return (true, ps.idx.globals[name].decl.typ)
  if ps.defs != nil and name in ps.defs.variables: return (true, $ps.defs.variables[name].typ)
  (false, "")

proc classifyWord(ps: var Parser, i: int) =
  ## A word used as a value.
  let t = ps.an.toks[i]
  if t.text in OperatorWords: ps.setSem(i, semOperator)
  elif t.text in ["true", "false"]: ps.setSem(i, semKeyword)
  elif t.text in ps.locals: ps.setSem(i, semLocal)
  elif t.text in ps.idx.globals: ps.setSem(i, semGlobal)
  elif ps.defs != nil and t.text in ps.defs.variables: ps.setSem(i, semEngineVar)
  elif t.text in ps.idx.funcs: ps.setSem(i, semFunc)
  elif ps.defs != nil and t.text in ps.defs.commands: ps.setSem(i, semCommand)
  else: ps.setSem(i, semBareWord)

proc literalSem(ps: var Parser, i: int) =
  case ps.an.toks[i].kind
  of tkNumber: ps.setSem(i, semNumber)
  of tkString: ps.setSem(i, semString)
  of tkPunct: ps.setSem(i, semPunct)
  of tkIdent: ps.classifyWord(i)
  of tkComment: ps.setSem(i, semComment)

proc stmtEnd(ps: Parser, line: int): bool =
  ## The token at p doesn't belong to a statement that started on line.
  let t = ps.tk
  ps.atEnd or t.line != line or t.isPunct(";") or t.isPunct("}") or t.isPunct("{")

proc callAt(ps: var Parser)
proc expr(ps: var Parser, line: int, closeParen: bool)

proc checkArgs(ps: var Parser, ci: int) =
  ## Matches a call's arguments to its command's (or function's) argument list:
  ## gives each argument its role and reports what the game would reject.
  let c = ps.an.calls[ci]
  let nameTok = ps.an.toks[c.tok]
  proc argInfo(ps: Parser, s: Slice[int]): (char, string) =
    ## 'i' int literal, 'f' float literal, 'w' word or string, 'v' variable (its type), 'x' other.
    if s.a != s.b: return ('x', "")
    let t = ps.an.toks[s.a]
    case t.kind
    of tkNumber: (if '.' in t.text: ('f', "") else: ('i', ""))
    of tkString: ('w', "")
    of tkIdent:
      let (isVar, typ) = ps.typeOf(t.text)
      if isVar: ('v', typ)
      elif t.text in ["true", "false"]: ('b', "")
      elif t.text in ps.idx.funcs or (ps.defs != nil and t.text in ps.defs.commands): ('x', "")
      else: ('w', "")
    else: ('x', "")
  proc fits(k: (char, string), p: ParamNode): bool =
    # The game converts numbers to any type, but not words to numbers.
    case k[0]
    of 'w': p.typ == btString
    of 'b': p.typ in {btBool, btString}
    of 'v': not (k[1] == "string" and p.typ != btString)
    else: true
  proc valueOk(ps: Parser, s: Slice[int], p: ParamNode): bool =
    if p.values.len == 0 or s.a != s.b: return true
    let t = ps.an.toks[s.a]
    if t.kind == tkIdent and ps.typeOf(t.text)[0]: return true
    let v = (if t.kind == tkNumber: numberValue(t.text) else: t.text.strip(chars = {'"'})).toLowerAscii
    for x in p.values:
      if x.toLowerAscii == v: return true
  var kinds: seq[(char, string)]
  for s in c.args: kinds.add ps.argInfo(s)
  let n = c.args.len

  if ps.defs != nil and c.name in ps.defs.commands:
    let cmd = ps.defs.commands[c.name]
    if c.name == "particle" and n > 0:
      ps.an.toks[c.args[0].a].refk = rkPartTag
    if n > 8:
      ps.warn(ps.an.toks[c.args[8].a], "More than 8 arguments: the game skips the line", error = true)
      return
    if not cmd.checked or cmd.forms.len == 0: return
    # As the game picks (0x479b60): of the forms every given argument fits
    # (extra ones are ignored, missing ones get 0 or ""), the one with the
    # fewest extra, then the fewest missing arguments.
    var best = -1
    var bestKey = (int.high, int.high)
    var near = 0          # No form fits: the one that fits furthest, to explain.
    var nearOk = -1
    for fi, f in cmd.forms:
      var ok = 0
      while ok < min(n, f.len) and fits(kinds[ok], f[ok]) and ps.valueOk(c.args[ok], f[ok]): inc ok
      if ok == min(n, f.len):
        let key = (max(0, n - f.len), max(0, f.len - n))
        if key < bestKey:
          bestKey = key
          best = fi
      elif ok > nearOk:
        nearOk = ok
        near = fi
    let sig = cmd.signature
    let f = cmd.forms[if best >= 0: best else: near]
    ps.an.calls[ci].form = if best >= 0: best else: near
    for k in 0 ..< min(n, f.len):
      let s = c.args[k]
      if s.a == s.b: ps.an.toks[s.a].refk = refFor(c.name, f[k].name)
    if best < 0:
      let k = nearOk
      let t = ps.an.toks[c.args[k].a]
      let p = f[k]
      let why = if not fits(kinds[k], p): &"{p.name} should be {p.typ}"
                else: &"{p.name} takes {p.values.join(\", \")}"
      ps.warn(t, &"{why}: the game skips the line ({sig})", error = true)
    elif bestKey[0] > 0:
      let t = ps.an.toks[c.args[f.len].a]
      ps.warn(t, (if f.len == 0: c.name & " takes no arguments; the game ignores these"
                  else: &"The game ignores this: {c.name} takes {f.len} argument(s) here ({sig})"))
  elif c.name in ps.idx.funcs:
    let d = ps.idx.funcs[c.name].decl
    var params = d.params
    if params.len == 1 and params[0][1].len == 0: params.setLen 0   # (void)
    for k in 0 ..< min(n, params.len):
      let s = c.args[k]
      if s.a == s.b: ps.an.toks[s.a].refk = refFor("", params[k][1])
    # Fewer is fine (vanilla scripts call their callbacks with nothing).
    if n > params.len:
      ps.warn(nameTok, &"{c.name} takes {params.len} argument(s), not {n}")

proc callAt(ps: var Parser) =
  ## A call whose name is the token at p: name args... or name(args, ...).
  let nameI = ps.ti
  let name = ps.tk.text
  let line = ps.tk.line
  var c = Call(name: name, tok: nameI, open: -1, close: -1)
  let ci = ps.an.calls.len
  ps.an.calls.add c
  ps.an.toks[nameI].call = ci
  inc ps.p
  if ps.defs != nil and name in ps.defs.commands: ps.setSem(nameI, semCommand)
  elif name in ps.idx.funcs: ps.setSem(nameI, semFunc)
  elif ps.typeOf(name)[0]: ps.classifyWord(nameI)
  else:
    ps.setSem(nameI, semUnknownCall)
    ps.warn(ps.an.toks[nameI], "Unknown command or function: " & name &
            " (the game reports it and skips the line)")
  if not ps.atEnd and ps.tk.isPunct("(") and ps.tk.line == line:
    c.paren = true
    c.open = ps.ti
    ps.setSem(c.open, semPunct)
    inc ps.p
    var depth = 0
    var start = -1
    while not ps.atEnd:
      let t = ps.tk
      if depth == 0 and (t.isPunct(")") or t.isPunct(",")):
        if start >= 0: c.args.add start .. ps.ti(-1)
        start = -1
        ps.setSem(ps.ti, semPunct)
        if t.isPunct(")"):
          c.close = ps.ti
          inc ps.p
          break
        inc ps.p
        continue
      if t.isPunct("{") or t.isPunct("}") or t.isPunct(";") or t.line != line: break
      if start < 0: start = ps.ti
      if t.isPunct("("): inc depth
      if t.isPunct(")"): dec depth
      if t.kind == tkIdent and ps.p + 1 < ps.sig.len and ps.tk(1).isPunct("(") and
         not (t.text in OperatorWords):
        callAt(ps)   # a call inside the argument
        continue
      ps.literalSem(ps.ti)
      inc ps.p
    if c.close < 0 and start >= 0: c.args.add start .. ps.ti(-1)
    if c.close < 0: ps.warn(ps.an.toks[c.open], "Missing )", error = true)
  else:
    while not ps.stmtEnd(line):
      let i = ps.ti
      c.args.add i .. i
      ps.literalSem(i)
      inc ps.p
  c.last = max(nameI, ps.ti(-1))
  for k, s in c.args:
    for j in s:
      if ps.an.toks[j].call < 0:
        ps.an.toks[j].call = ci
        ps.an.toks[j].arg = k
  ps.an.calls[ci] = c
  ps.checkArgs(ci)

proc expr(ps: var Parser, line: int, closeParen: bool) =
  ## Values and operators: to the end of the line, or (closeParen) through
  ## the ) that matches the ( before p.
  var depth = 0
  while not ps.atEnd:
    let t = ps.tk
    if closeParen:
      if t.isPunct("{") or t.isPunct("}") or t.isPunct(";"): break
      if t.isPunct("("): inc depth
      if t.isPunct(")"):
        ps.setSem(ps.ti, semPunct)
        inc ps.p
        if depth == 0: return
        dec depth
        continue
    elif ps.stmtEnd(line): return
    if t.kind == tkIdent and ps.p + 1 < ps.sig.len and ps.tk(1).isPunct("(") and
       t.text notin OperatorWords:
      ps.callAt()
      continue
    if t.kind == tkIdent:
      ps.classifyWord(ps.ti)
      if ps.an.toks[ps.ti].sem == semBareWord and t.text notin ["eq", "ne"]:
        ps.warn(t, t.text & " isn't a declared variable (the game takes it as the text \"" & t.text & "\")")
    else: ps.literalSem(ps.ti)
    inc ps.p
  if closeParen: ps.warn(ps.an.toks[ps.sig[^1]], "Missing )", error = true)

proc funcHeader(ps: var Parser) =
  ## func [type] name [(type arg, ...)]
  ps.setSem(ps.ti, semKeyword)
  inc ps.p
  var d = Decl(isFunc: true)
  if not ps.atEnd and ps.tk.kind == tkIdent and ps.tk.text in TypeWords and ps.tk(1).kind == tkIdent:
    ps.setSem(ps.ti, semType)
    d.typ = if ps.tk.text == "void": "" else: ps.tk.text
    inc ps.p
  ps.locals.clear()
  if ps.atEnd or ps.tk.kind != tkIdent:
    if not ps.atEnd: ps.warn(ps.tk, "A function name should follow func", error = true)
    return
  let ni = ps.ti
  d.name = ps.tk.text
  d.line = ps.tk.line
  d.col = ps.tk.col
  d.doc = docAbove(ps.lines, ps.an.toks[ni].line)
  ps.setSem(ni, semDeclName)
  inc ps.p
  if not ps.atEnd and ps.tk.isPunct("("):
    ps.setSem(ps.ti, semPunct)
    inc ps.p
    var typ = ""
    while not ps.atEnd and not ps.tk.isPunct(")") and not ps.tk.isPunct("{"):
      let t = ps.tk
      if t.kind == tkIdent and t.text in TypeWords:
        ps.setSem(ps.ti, semType)
        typ = t.text
        if t.text == "void" and ps.tk(1).isPunct(")"): d.params.add ("void", "")
      elif t.kind == tkIdent:
        ps.setSem(ps.ti, semLocal)
        if typ.len == 0: ps.warn(t, "Give the argument a type: string, int, float or bool", error = true)
        d.params.add (typ, t.text)
        ps.locals[t.text] = typ
        typ = ""
      elif not t.isPunct(","):
        ps.warn(t, "Unexpected " & t.text & " in the arguments", error = true)
      else: ps.setSem(ps.ti, semPunct)
      inc ps.p
    if not ps.atEnd and ps.tk.isPunct(")"):
      ps.setSem(ps.ti, semPunct)
      inc ps.p
    else: ps.warn(ps.an.toks[ni], "Missing ) after the arguments", error = true)
  ps.an.toks[ni].decl = ps.an.decls.len
  ps.an.decls.add d
  if ps.depth > 0: ps.warn(ps.an.toks[ni], "A function can't be declared inside another", error = true)

proc varDecl(ps: var Parser) =
  ## var type name [= value]
  let line = ps.tk.line
  ps.setSem(ps.ti, semKeyword)
  inc ps.p
  var d = Decl()
  if not ps.atEnd and ps.tk.kind == tkIdent and ps.tk.text in TypeWords and ps.tk.text != "void":
    ps.setSem(ps.ti, semType)
    d.typ = ps.tk.text
    inc ps.p
  else:
    ps.warn(ps.an.toks[ps.ti(-1)], "var needs a type: int, float, bool or string", error = true)
  if ps.atEnd or ps.tk.kind != tkIdent or ps.tk.line != line:
    ps.warn(ps.an.toks[ps.ti(-1)], "A variable name should follow", error = true)
    return
  let ni = ps.ti
  d.name = ps.tk.text
  d.line = ps.tk.line
  d.col = ps.tk.col
  d.doc = docAbove(ps.lines, d.line)
  ps.setSem(ni, semDeclName)
  inc ps.p
  if ps.depth > 0:
    ps.locals[d.name] = d.typ
  else:
    ps.an.toks[ni].decl = ps.an.decls.len
    ps.an.decls.add d
  if not ps.atEnd and ps.tk.isPunct("=") and ps.tk.line == line:
    ps.setSem(ps.ti, semPunct)
    inc ps.p
    ps.expr(line, false)

proc statement(ps: var Parser) =
  let t = ps.tk
  let i = ps.ti
  if t.isPunct("{"):
    ps.setSem(i, semPunct)
    inc ps.depth
    inc ps.p
  elif t.isPunct("}"):
    ps.setSem(i, semPunct)
    if ps.depth == 0: ps.warn(t, "This } closes nothing", error = true)
    else: dec ps.depth
    if ps.depth == 0: ps.locals.clear()
    inc ps.p
  elif t.isPunct(";"):
    ps.setSem(i, semPunct)
    inc ps.p
  elif t.kind == tkIdent:
    case t.text
    of "func": ps.funcHeader()
    of "var": ps.varDecl()
    of "if":
      ps.setSem(i, semKeyword)
      inc ps.p
      if not ps.atEnd and ps.tk.isPunct("("):
        ps.setSem(ps.ti, semPunct)
        inc ps.p
        ps.expr(t.line, true)
      else: ps.expr(t.line, false)
    of "else":
      ps.setSem(i, semKeyword)
      inc ps.p
    of "return", "sleep":
      ps.setSem(i, semKeyword)
      inc ps.p
      ps.expr(t.line, false)
    of "fork":
      ps.setSem(i, semKeyword)
      inc ps.p
      if not ps.atEnd and ps.tk.kind == tkIdent and ps.tk.line == t.line: ps.callAt()
    else:
      if t.text in Keywords and t.text notin ["true", "false"]:
        ps.setSem(i, semKeyword)
        ps.warn(t, t.text & " can't start a statement", error = t.text notin TypeWords)
        inc ps.p
      elif ps.tk(1).isPunct("=") and ps.tk(1).line == t.line:
        ps.classifyWord(i)
        if ps.an.toks[i].sem == semBareWord:
          ps.warn(t, t.text & " isn't a declared variable")
        elif ps.an.toks[i].sem notin {semLocal, semGlobal, semEngineVar}:
          ps.warn(t, t.text & " is not a variable")
        ps.setSem(ps.ti(1), semPunct)
        ps.p += 2
        ps.expr(t.line, false)
      else:
        ps.callAt()
  else:
    ps.literalSem(i)
    if t.kind != tkPunct or t.text notin [")", ","]:
      ps.warn(t, "Unexpected " & t.text & " (a statement starts with a command, function or keyword)")
    inc ps.p

proc scanDecls*(lines: seq[string], toks: seq[Tok]): seq[Decl] =
  ## The functions and global variables a file declares (cheap: no other lookups).
  let ps = Parser(lines: lines, an: Analysis(toks: toks))
  var p = ps
  for i, t in toks:
    if t.kind != tkComment: p.sig.add i
  while not p.atEnd:
    let t = p.tk
    if t.isPunct("{"): inc p.depth
    elif t.isPunct("}"): p.depth = max(0, p.depth - 1)
    elif t.isWord("func") and p.depth == 0:
      p.funcHeader()
      continue
    elif t.isWord("var") and p.depth == 0:
      p.varDecl()
      continue
    inc p.p
  p.an.decls

proc analyze*(lines: seq[string], toks: seq[Tok], defs: BslDefs, idx: ProjectIndex): Analysis =
  var ps = Parser(lines: lines, an: Analysis(toks: toks), defs: defs, idx: idx)
  for i, t in toks:
    if t.kind == tkComment: ps.an.toks[i].sem = semComment
    elif t.kind == tkString: ps.an.toks[i].sem = semString
    else: ps.sig.add i
  for t in toks:
    if t.kind == tkString and (t.len < 2 or t.text[^1] != '"'):
      ps.warn(t, "Missing \" at the end of the string", error = true)
  while not ps.atEnd: ps.statement()
  if ps.depth > 0 and ps.sig.len > 0:
    ps.warn(ps.an.toks[ps.sig[^1]], &"Missing }} ({ps.depth} block(s) left open)", error = true)
  ps.an

# --- where the caret is ----------------------------------------------------------------------

type
  CtxKind* = enum ckNone, ckStatement, ckArg, ckExpr, ckFuncName
  CaretCtx* = object
    kind*: CtxKind
    call*: int = -1             ## ckArg: the call.
    arg*: int                   ## ckArg: which of its arguments.
    prefix*: string             ## The part of the word before the caret.
    start*: int                 ## Where that word starts (col).

proc tokAt*(an: Analysis, line, col: int, touching = true): int =
  ## The token under (line, col); touching: also the one ending right there.
  for i, t in an.toks:
    if t.line == line and col >= t.col and (col < t.col + t.len or (touching and col == t.col + t.len)):
      return i
  -1

proc caretContext*(an: Analysis, lines: seq[string], line, col: int): CaretCtx =
  let s = if line < lines.len: lines[line] else: ""
  var a = min(col, s.len)
  while a > 0 and s[a - 1] in IdChar: dec a
  let prefix = s[a ..< min(col, s.len)]
  # In a comment or string: nothing to offer.
  for t in an.toks:
    if t.line == line and t.kind in {tkComment, tkString} and col > t.col and
       (col < t.col + t.len or (t.kind == tkComment or t.text.len < 2 or t.text[^1] != '"')):
      return CaretCtx(kind: ckNone)
  # A call whose arguments the caret is among: the innermost one.
  var best = -1
  for ci, c in an.calls:
    let nt = an.toks[c.tok]
    var inside = false
    if c.paren:
      let o = an.toks[c.open]
      let afterOpen = line > o.line or (line == o.line and col > o.col)
      var beforeClose = false
      if c.close < 0: beforeClose = line == o.line
      else:
        let cl = an.toks[c.close]
        beforeClose = line < cl.line or (line == cl.line and col <= cl.col)
      inside = afterOpen and beforeClose
    else:
      inside = line == nt.line and a > nt.col + nt.len - 1 and col > nt.col + nt.len
      # Not past a ; or a } that ends the statement.
      if inside:
        for j in c.tok + 1 ..< an.toks.len:
          let t = an.toks[j]
          if t.line != line or t.col >= col: break
          if t.kind == tkPunct and t.text in [";", "}", "{"]: inside = false
    if inside: best = ci
  if best >= 0:
    let c = an.calls[best]
    var k = 0
    if c.paren:
      # Commas at the call's own level before the caret.
      var depth = 0
      for j in c.open + 1 ..< an.toks.len:
        let t = an.toks[j]
        if t.line > line or (t.line == line and t.col >= col) or j == c.close: break
        if t.isPunct("("): inc depth
        elif t.isPunct(")"): dec depth
        elif t.isPunct(",") and depth == 0: inc k
    else:
      # The argument the caret is in or right after, else the next one.
      k = -1
      for ai, s in c.args:
        let t = an.toks[s.b]
        if t.line == line and col >= an.toks[s.a].col and col <= t.col + t.len: k = ai
      if k < 0:
        k = 0
        for s in c.args:
          if an.toks[s.b].line == line and an.toks[s.b].col + an.toks[s.b].len < col: inc k
    return CaretCtx(kind: ckArg, call: best, arg: k, prefix: prefix, start: a)
  # The first word of a line (or after { or ;) starts a statement.
  var j = a - 1
  while j >= 0 and s[j] in {' ', '\t'}: dec j
  if j < 0 or s[j] in {'{', ';', '}'}: return CaretCtx(kind: ckStatement, prefix: prefix, start: a)
  # After func / var / a type: a new name. A function's may be one the game
  # or the level calls.
  let before = s[0 ..< max(0, j + 1)].strip
  for w in ["func", "var"]:
    if before == w or before.endsWith(" " & w) or (before.startsWith(w & " ") and
       before.split(Whitespace).len <= 2 and before.split(Whitespace)[^1] in TypeWords):
      return if w == "func": CaretCtx(kind: ckFuncName, prefix: prefix, start: a) else: CaretCtx(kind: ckNone)
  CaretCtx(kind: ckExpr, prefix: prefix, start: a)

proc formFor*(an: Analysis, defs: BslDefs, ci: int): seq[ParamNode] =
  ## The argument form a call is being written in.
  let c = an.calls[ci]
  if defs == nil or c.name notin defs.commands: return
  let cmd = defs.commands[c.name]
  if cmd.forms.len == 0: return
  cmd.forms[max(0, c.form)]

proc paramsAt*(an: Analysis, defs: BslDefs, ci, arg: int): seq[ParamNode] =
  ## What argument number arg of call ci can be (one per form that gets that far
  ## with the arguments before it fitting), first the form matched so far.
  let c = an.calls[ci]
  if defs == nil or c.name notin defs.commands: return
  let cmd = defs.commands[c.name]
  var seen: HashSet[string]
  var order: seq[int]
  if c.form >= 0: order.add c.form
  for fi in 0 ..< cmd.forms.len:
    if fi != c.form: order.add fi
  for fi in order:
    let f = cmd.forms[fi]
    if arg >= f.len: continue
    var ok = true
    for k in 0 ..< min(arg, c.args.len):
      let s = c.args[k]
      if s.a == s.b:
        let t = an.toks[s.a]
        if t.kind == tkNumber and f[k].typ == btString: ok = false
        if t.kind in {tkString} and f[k].typ != btString: ok = false
    if not ok: continue
    let key = f[arg].argText
    if key notin seen:
      seen.incl key
      result.add f[arg]
