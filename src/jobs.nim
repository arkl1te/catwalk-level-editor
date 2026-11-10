## Background jobs: a list of steps, each either an external command (run
## without blocking the UI; output goes to the job's log file), a command per
## item of a list, or a short in-process action. The editor calls poll() once
## per frame; it runs at most one action per call.

import std/[osproc, os, strutils, times]
when defined(windows): import std/strtabs

type
  StepKind = enum skCommand, skCommands, skAction

  Step* = object
    label*: string
    case kind: StepKind
    of skCommand, skCommands:
      args: proc(): seq[string]    ## Evaluated when the step starts.
      argsList: proc(): seq[seq[string]]
        ## skCommands: the commands, run one after another (evaluated when the
        ## step starts); the first that fails fails the step.
      explain: proc(output: string): string
        ## Optional: turns the failed command's output into a readable error
        ## ("" keeps the generic one).
    of skAction:
      action: proc()               ## Raises to fail the job.

  JobState* = enum jsRunning, jsDone, jsFailed

  Job* = ref object
    title*: string
    steps: seq[Step]
    current*: int
    state*: JobState
    error*: string
    logPath*: string
    process: Process
    queued: seq[seq[string]]       ## skCommands: the step's commands still to run.
    outputStart: int               ## Log size when the running command began.
    started*: float

proc command*(label: string, args: proc(): seq[string],
              explain: proc(output: string): string = nil): Step =
  Step(label: label, kind: skCommand, args: args, explain: explain)

proc commandEach*(label: string, argsList: proc(): seq[seq[string]],
                  explain: proc(output: string): string = nil): Step =
  ## Runs each command of the list in turn (none: the step just passes).
  Step(label: label, kind: skCommands, argsList: argsList, explain: explain)

proc action*(label: string, fn: proc()): Step =
  Step(label: label, kind: skAction, action: fn)

proc newJob*(title, logPath: string, steps: seq[Step]): Job =
  createDir(logPath.parentDir)
  writeFile(logPath, "")
  Job(title: title, steps: steps, logPath: logPath, started: epochTime())

proc stepLabel*(j: Job): string =
  if j.current < j.steps.len: j.steps[j.current].label else: ""

proc progress*(j: Job): float32 =
  if j.steps.len == 0: 1'f32 else: j.current.float32 / j.steps.len.float32

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

proc startCommand(j: Job, args: seq[string]) =
  ## Starts args with its output (stdout and stderr) appended to the log.
  j.log "$ " & quoteShellCommand(args)
  j.outputStart = int(getFileSize(j.logPath))
  when defined(windows):
    # cmd does the redirection, as sh does below.
    j.process = startCmd(args, ">> " & cmdQuote(j.logPath) & " 2>&1")
  else:
    let sh = quoteShellCommand(args) & " >> " & quoteShell(j.logPath) & " 2>&1"
    j.process = startProcess("/bin/sh", args = ["-c", sh], options = {})

proc poll*(j: Job) =
  ## Advances the job as far as it can without blocking.
  while j.state == jsRunning:
    if j.process != nil:
      let code = j.process.peekExitCode
      if code == -1: return
      j.process.close()
      j.process = nil
      if code != 0:
        let s = j.steps[j.current]
        var msg = ""
        if s.explain != nil:
          try:
            let all = readFile(j.logPath)
            msg = s.explain(all[min(j.outputStart, all.len) .. ^1])
          except CatchableError: discard
        j.fail(if msg.len > 0: s.label & ": " & msg
               else: s.label & " exited with code " & $code)
        return
      if j.queued.len > 0:
        try: j.startCommand(j.queued[0])
        except CatchableError as e:
          j.fail(j.steps[j.current].label & ": " & e.msg)
          return
        j.queued.delete(0)
        return
      inc j.current
      continue
    if j.current >= j.steps.len:
      j.state = jsDone
      return
    let s = j.steps[j.current]
    j.log "== " & s.label
    case s.kind
    of skAction:
      try:
        s.action()
        inc j.current
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)
      # One action per frame, so long runs of them don't freeze the UI.
      return
    of skCommand:
      try:
        j.startCommand(s.args())
        return
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)
    of skCommands:
      try:
        j.queued = s.argsList()
        if j.queued.len == 0:
          inc j.current
          continue
        j.startCommand(j.queued[0])
        j.queued.delete(0)
        return
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)

proc runToEnd*(j: Job) =
  ## Blocking variant, for command-line use.
  while j.state == jsRunning:
    j.poll()
    if j.state == jsRunning and j.process != nil: sleep(20)
