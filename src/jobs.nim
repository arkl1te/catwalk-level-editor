## Background jobs: a list of steps, each either an external command (run
## without blocking the UI; output goes to the job's log file), a command per
## item of a list, commands run side by side, a graph of commands and actions
## that each start once those they need are done, or a short in-process
## action. The editor calls poll() once per frame; it runs at most one action
## per call.

import std/[osproc, os, strutils, times]
when defined(windows): import std/[strtabs, winlean]

type
  StepKind = enum skCommand, skCommands, skFiles, skParallel, skGraph, skAction

  FileCommand* = tuple[head, files: seq[string]]
    ## A command that takes any number of input files (OniSplit -extract:*):
    ## head, then the files.

  Node* = object
    ## One piece of a graph step: commands (run side by side) or an action.
    name, label: string
    after: seq[string]             ## Names of the nodes that must be done first.
    tasks: proc(): seq[FileCommand]  ## As parallel's; nil: an action.
    action: proc()
    urgent: bool                   ## The others' commands run at a lower priority.

  NodeState = enum nsWaiting, nsRunning, nsDone

  Step* = object
    label*: string
    case kind: StepKind
    of skCommand, skCommands, skFiles, skParallel:
      args: proc(): seq[string]
        ## Evaluated when the step starts; none: the step just passes.
      argsList: proc(): seq[seq[string]]
        ## skCommands: the commands, run one after another (evaluated when the
        ## step starts); the first that fails fails the step.
      fileArgs: proc(): FileCommand
        ## skFiles: run as head & files, split into as many commands as keep
        ## each command line within the system's limit.
      tasks: proc(): seq[FileCommand]
        ## skParallel: the commands, all at once (as many at a time as there
        ## are processors); one without files runs as head alone.
      explain: proc(output: string): string
        ## Optional: turns the failed command's output into a readable error
        ## ("" keeps the generic one).
    of skGraph:
      nodes: seq[Node]
      deps: seq[seq[int]]          ## Per node: the indices of its after.
    of skAction:
      action: proc()               ## Raises to fail the job.

  JobState* = enum jsRunning, jsDone, jsFailed

  Running = object
    process: Process
    node: int                      ## skGraph: the node it is part of; else -1.
    output: string                 ## Its own output file; "": straight into the log.
    start: int                     ## output == "": log size when it began.
    began: float                   ## epochTime when it started.
    what: string                   ## For the log: its option and last argument.

  Job* = ref object
    title*: string
    steps: seq[Step]
    current*: int
    state*: JobState
    error*: string
    logPath*: string
    inStep: bool                   ## The current step's commands (or graph) are under way.
    running: seq[Running]          ## The step's commands running now.
    queued: seq[(int, seq[string])]  ## The step's commands still to start, with their node.
    width: int                     ## How many of them may run at once.
    nodeState: seq[NodeState]      ## skGraph: each node's.
    nodeLeft: seq[int]             ## skGraph: each node's commands not ended yet.
    urgent: seq[bool]              ## skGraph: each node's urgent.
    failure: string                ## A command failed: the job fails once the others end.
    serial: int                    ## Names the output files of side-by-side commands.
    started*: float

proc command*(label: string, args: proc(): seq[string],
              explain: proc(output: string): string = nil): Step =
  Step(label: label, kind: skCommand, args: args, explain: explain)

proc commandEach*(label: string, argsList: proc(): seq[seq[string]],
                  explain: proc(output: string): string = nil): Step =
  ## Runs each command of the list in turn (none: the step just passes).
  Step(label: label, kind: skCommands, argsList: argsList, explain: explain)

proc commandFiles*(label: string, args: proc(): FileCommand,
                   explain: proc(output: string): string = nil): Step =
  ## Runs head with the files, in several commands when one would be too long
  ## (no files: the step just passes).
  Step(label: label, kind: skFiles, fileArgs: args, explain: explain)

proc parallel*(label: string, tasks: proc(): seq[FileCommand],
               explain: proc(output: string): string = nil): Step =
  ## Runs the commands side by side, each split as commandFiles splits one;
  ## a task with no files runs as its head alone (none: the step just passes).
  ## The step ends when all have; the first that fails fails it.
  Step(label: label, kind: skParallel, tasks: tasks, explain: explain)

proc parts*(c: FileCommand, n: int): seq[FileCommand] =
  ## c as up to n commands with a share of the files each, to run in
  ## parallel (none when c has no files).
  let n = max(1, min(n, c.files.len))
  for i in 0 ..< n:
    var part = (head: c.head, files: newSeq[string]())
    for k in countup(i, c.files.high, n): part.files.add c.files[k]
    if part.files.len > 0: result.add part

proc action*(label: string, fn: proc()): Step =
  Step(label: label, kind: skAction, action: fn)

proc commandsNode*(name: string, after: openArray[string], label: string,
                   tasks: proc(): seq[FileCommand], urgent = false): Node =
  ## A graph node that runs tasks (evaluated when it starts) as parallel does.
  ## When a graph has urgent nodes (the longest), the commands of the others
  ## run at a lower priority, so that they don't slow those down.
  Node(name: name, label: label, after: @after, tasks: tasks, urgent: urgent)

proc actionNode*(name: string, after: openArray[string], label: string, fn: proc()): Node =
  Node(name: name, label: label, after: @after, action: fn)

proc graph*(label: string, nodes: seq[Node]): Step =
  ## Runs each node once the nodes it comes after are done, commands of all
  ## running nodes side by side (as many at a time as there are processors),
  ## nodes in list order when several are ready. The first failure fails it.
  result = Step(label: label, kind: skGraph, nodes: nodes)
  for n in nodes:
    var d: seq[int]
    for a in n.after:
      var k = -1
      for i, m in nodes:
        if m.name == a: k = i
      if k < 0: raise newException(ValueError, "graph node " & n.name & " comes after an unknown node " & a)
      d.add k
    result.deps.add d

proc newJob*(title, logPath: string, steps: seq[Step]): Job =
  createDir(logPath.parentDir)
  writeFile(logPath, "")
  Job(title: title, steps: steps, logPath: logPath, started: epochTime())

proc stepLabel*(j: Job): string =
  if j.current >= j.steps.len: return ""
  let s = j.steps[j.current]
  result = s.label
  if s.kind == skGraph and j.inStep:
    for i, n in s.nodes:   # The earliest node under way.
      if j.nodeState[i] == nsRunning: return n.label

proc progress*(j: Job): float32 =
  if j.steps.len == 0: return 1'f32
  var part = 0'f32
  if j.current < j.steps.len and j.steps[j.current].kind == skGraph and j.inStep:
    var done = 0
    for st in j.nodeState:
      if st == nsDone: inc done
    part = done.float32 / max(1, j.nodeState.len).float32
  (j.current.float32 + part) / j.steps.len.float32

proc progressCount*(j: Job): (int, int) =
  ## (done, all) of the job's pieces of work: its steps, a graph's nodes each.
  for i, s in j.steps:
    let n = if s.kind == skGraph: max(1, s.nodes.len) else: 1
    result[1] += n
    if i < j.current or j.state == jsDone: result[0] += n
    elif i == j.current and s.kind == skGraph and j.inStep:
      for st in j.nodeState:
        if st == nsDone: inc result[0]

proc log*(j: Job, line: string) =
  let f = open(j.logPath, fmAppend)
  f.writeLine line
  f.close()

proc logTail*(j: Job, lines = 12): string =
  try:
    let all = readFile(j.logPath).strip.splitLines
    all[max(0, all.len - lines) .. ^1].join("\n")
  except IOError: ""

proc fail(j: Job, msg: string) =
  j.state = jsFailed
  j.error = msg
  j.log "FAILED: " & msg

when defined(windows):
  proc cmdQuote*(s: string): string =
    ## s as one argument of a command line that cmd.exe passes on: always in
    ## quotes, so cmd leaves & | < > ^ in paths alone, with the backslash rules
    ## the program's own command-line parser (MSVCRT, .NET) undoes.
    result = "\""
    var slashes = 0
    for c in s:
      if c == '\\':
        inc slashes
      elif c == '"':
        result.add repeat('\\', slashes + 1)  # N already added: 2N + 1 in all
        result.add '"'
        slashes = 0
        continue
      else:
        slashes = 0
      result.add c
    result.add repeat('\\', slashes)
    result.add '"'

  proc startCmd*(args: seq[string], redirect: string, workingDir = "",
                 env: StringTableRef = nil): Process =
    ## Runs args through cmd.exe, which applies redirect ("> NUL" and such),
    ## without a console window (poDaemon). /s: cmd takes the line between
    ## its outer quotes as it is.
    var line = ""
    for a in args: line.add cmdQuote(a) & " "
    line.add redirect
    startProcess(getEnv("ComSpec", "cmd.exe") & " /d /s /c \"" & line & "\"",
                 workingDir = workingDir, env = env, options = {poEvalCommand, poDaemon})

when defined(windows):
  const MaxCommandLine = 8191
    ## The longest line cmd.exe runs; a longer one fails with exit code 1
    ## before the redirection, so with nothing in the log.
else:
  const MaxCommandLine = 131071
    ## Linux's limit for one argument (MAX_ARG_STRLEN, less the NUL): the
    ## whole script given to sh -c.

proc redirect(path: string): string =
  ## What appends a command's output (stdout and stderr) to path.
  when defined(windows): ">> " & cmdQuote(path) & " 2>&1"
  else: " >> " & quoteShell(path) & " 2>&1"

proc redirect(j: Job): string =
  ## The longest redirection of the job's commands: to a side-by-side
  ## command's own file (the log's name and a number).
  redirect(j.logPath & ".999999")

proc argLength(a: string): int =
  ## a's share of the command line, with the space after it.
  when defined(windows): cmdQuote(a).len + 1 else: quoteShell(a).len + 1

proc commandLength(j: Job, args: seq[string]): int =
  ## The length of the line startCommand runs for args (on Windows the
  ## whole of cmd's own command line), never less.
  when defined(windows):
    result = getEnv("ComSpec", "cmd.exe").len + " /d /s /c \"".len + "\"".len
  for a in args: result += argLength(a)
  result += j.redirect.len

proc splitFiles(j: Job, c: FileCommand): seq[seq[string]] =
  ## c as commands of head and as many of the files as fit on one line.
  if c.files.len == 0: return
  let budget = MaxCommandLine - 64   # Spare room for what isn't counted.
  var cmd = c.head
  var length = j.commandLength(c.head)
  for f in c.files:
    let n = argLength(f)
    if cmd.len > c.head.len and length + n > budget:
      result.add cmd
      cmd = c.head
      length = j.commandLength(c.head)
    cmd.add f
    length += n
  result.add cmd

proc commands(j: Job, tasks: seq[FileCommand]): seq[seq[string]] =
  ## Tasks as command lines: one without files is its head.
  for t in tasks:
    if t.files.len == 0: result.add t.head
    else: result.add j.splitFiles(t)

proc yields(j: Job, node: int): bool =
  ## Whether a node's commands give way to urgent ones: while any runs or waits.
  if node < 0 or j.urgent[node]: return false
  for i, u in j.urgent:
    if u and j.nodeState[i] != nsDone: return true

when defined(windows):
  proc setPriorityClass(h: Handle, cls: int32): WINBOOL {.stdcall, dynlib: "kernel32",
    importc: "SetPriorityClass".}

  proc lowerPriority(pid: int) =
    ## Below normal, which the programs a process starts inherit (cmd's
    ## OniSplit: cmd takes a while before starting it, so this comes first).
    const SetInformation = 0x0200'i32
    const BelowNormal = 0x4000'i32
    let h = openProcess(SetInformation, 0, pid.DWORD)
    if h != 0:
      discard setPriorityClass(h, BelowNormal)
      discard closeHandle(h)

proc startCommand(j: Job, args: seq[string], node: int) =
  ## Starts args with its output (stdout and stderr) appended to the log, or,
  ## when several run at once, to a file of its own the log gets at its end.
  j.log "$ " & quoteShellCommand(args)
  if j.commandLength(args) > MaxCommandLine:
    raise newException(OSError, "the command is too long to run (" & $j.commandLength(args) &
                       " characters, at most " & $MaxCommandLine & ")")
  var r = Running(node: node, began: epochTime(),
                  what: (if args.len > 1: args[1] & " " else: "") & args[^1].extractFilename)
  if j.width > 1:
    inc j.serial
    r.output = j.logPath & "." & $j.serial
    writeFile(r.output, "")
  else:
    r.start = int(getFileSize(j.logPath))
  let to = redirect(if r.output.len > 0: r.output else: j.logPath)
  let low = j.yields(node)
  when defined(windows):
    # cmd does the redirection, as sh does below.
    r.process = startCmd(args, to)
    if low: lowerPriority(r.process.processID)
  else:
    let nice = if low: "nice -n 10 " else: ""
    r.process = startProcess("/bin/sh", args = ["-c", nice & quoteShellCommand(args) & to], options = {})
  j.running.add r

proc finish(j: Job, r: Running, code: int): string =
  ## A command that ended: its output, now in the log, with how long it took.
  try:
    if r.output.len == 0:
      let all = readFile(j.logPath)
      result = all[min(r.start, all.len) .. ^1]
    else:
      result = readFile(r.output)
      removeFile(r.output)
      if result.len > 0:
        let f = open(j.logPath, fmAppend)
        f.write result
        if not result.endsWith("\n"): f.write "\n"
        f.close()
    j.log "(" & r.what & ": exit code " & $code & " after " &
          formatFloat(epochTime() - r.began, ffDecimal, 1) & " s)"
  except CatchableError: discard

proc labelOf(j: Job, node: int): string =
  let s = j.steps[j.current]
  if node >= 0 and s.kind == skGraph: s.nodes[node].label else: s.label

proc reap(j: Job) =
  ## Collects the commands that ended; the first that failed sets failure.
  let s = j.steps[j.current]
  var i = 0
  while i < j.running.len:
    let r = j.running[i]
    let code = r.process.peekExitCode
    if code == -1:
      inc i
      continue
    r.process.close()
    j.running.delete(i)
    let output = j.finish(r, code)
    if r.node >= 0: dec j.nodeLeft[r.node]
    if code != 0 and j.failure.len == 0:
      var msg = ""
      if s.kind != skGraph and s.explain != nil:
        try: msg = s.explain(output)
        except CatchableError: discard
      let label = j.labelOf(r.node)
      j.failure = if msg.len > 0: label & ": " & msg
                  else: label & " exited with code " & $code

proc startQueued(j: Job) =
  ## Starts queued commands while there is room: width in all; while urgent
  ## commands run, the others get no more than one core in two less one
  ## (two logical processors share a core), so that the urgent ones keep a
  ## core to themselves.
  var lowRunning = 0
  for r in j.running:
    if j.yields(r.node): inc lowRunning
  let lowWidth = max(1, j.width div 2 - 1)
  var i = 0
  while j.failure.len == 0 and i < j.queued.len and j.running.len < j.width:
    let (node, args) = j.queued[i]
    if j.yields(node) and lowRunning >= lowWidth:
      inc i
      continue
    j.queued.delete(i)
    if j.yields(node): inc lowRunning
    try: j.startCommand(args, node)
    except CatchableError as e:
      if node >= 0: dec j.nodeLeft[node]
      j.failure = j.labelOf(node) & ": " & e.msg

proc stamp(j: Job): string = " (at " & formatFloat(epochTime() - j.started, ffDecimal, 1) & " s)"

proc advanceGraph(j: Job): bool =
  ## Marks the nodes whose commands all ended done and starts those now
  ## ready. True when it ran an action (one per poll).
  let s = j.steps[j.current]
  var changed = true
  while changed and j.failure.len == 0:
    changed = false
    for i in 0 ..< s.nodes.len:
      if j.nodeState[i] == nsRunning and j.nodeLeft[i] == 0:
        j.nodeState[i] = nsDone
        changed = true
    for i, n in s.nodes:
      if j.nodeState[i] != nsWaiting: continue
      var ready = true
      for d in s.deps[i]:
        if j.nodeState[d] != nsDone: ready = false
      if not ready: continue
      j.log "== " & n.label & j.stamp
      if n.tasks == nil:
        j.nodeState[i] = nsDone
        try: n.action()
        except CatchableError as e: j.failure = n.label & ": " & e.msg
        return true
      j.nodeState[i] = nsRunning
      try:
        for c in j.commands(n.tasks()):
          j.queued.add (i, c)
          inc j.nodeLeft[i]
      except CatchableError as e:
        j.failure = n.label & ": " & e.msg
        return false
      changed = true
  false

proc poll*(j: Job) =
  ## Advances the job as far as it can without blocking.
  while j.state == jsRunning:
    if j.inStep:
      let s = j.steps[j.current]
      j.reap()
      j.startQueued()
      if s.kind == skGraph and j.failure.len == 0 and j.advanceGraph():
        j.startQueued()
        if j.failure.len == 0: return   # Ran an action: one per frame.
      j.startQueued()
      if j.failure.len > 0:
        # No more starts; the others end before the job fails, so that none
        # still writes where the caller may clean up.
        j.queued.setLen 0
        if j.running.len == 0: j.fail(j.failure)
        return
      if j.running.len > 0 or j.queued.len > 0: return
      if s.kind == skGraph:
        # Nothing runs and advanceGraph started all it could: a node left
        # waits for one that never ends (a cycle).
        for i, st in j.nodeState:
          if st != nsDone:
            j.fail(s.nodes[i].label & ": waits for itself through the nodes it comes after")
            return
      j.inStep = false
      inc j.current
      continue
    if j.current >= j.steps.len:
      j.state = jsDone
      return
    let s = j.steps[j.current]
    j.log "== " & s.label & j.stamp
    case s.kind
    of skAction:
      try:
        s.action()
        inc j.current
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)
      # One action per frame, so long runs of them don't freeze the UI.
      return
    of skGraph:
      j.width = max(1, countProcessors())
      j.nodeState = newSeq[NodeState](s.nodes.len)
      j.nodeLeft = newSeq[int](s.nodes.len)
      j.urgent.setLen 0
      for n in s.nodes: j.urgent.add n.urgent
      j.inStep = true
    of skCommand, skCommands, skFiles, skParallel:
      try:
        j.width = 1
        var cmds: seq[seq[string]]
        case s.kind
        of skCommand:
          let args = s.args()
          if args.len > 0: cmds = @[args]
        of skCommands: cmds = s.argsList()
        of skFiles: cmds = j.splitFiles(s.fileArgs())
        else:
          cmds = j.commands(s.tasks())
          j.width = max(1, countProcessors())
        j.queued.setLen 0
        for c in cmds: j.queued.add (-1, c)
        if j.queued.len == 0:   # Nothing to do.
          inc j.current
          continue
        j.inStep = true   # The loop's top starts them.
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)

proc runToEnd*(j: Job) =
  ## Blocking variant, for command-line use.
  while j.state == jsRunning:
    j.poll()
    if j.state == jsRunning and j.running.len > 0: sleep(20)
