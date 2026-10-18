## Background jobs: a list of steps, each either an external command (run
## without blocking the UI; output goes to the job's log file) or a short
## in-process action. The editor calls poll() once per frame; it runs at most
## one action per call.

import std/[osproc, os, strutils, times]

type
  StepKind = enum skCommand, skAction

  Step* = object
    label*: string
    case kind: StepKind
    of skCommand:
      args: proc(): seq[string]    ## Evaluated when the step starts.
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
    started*: float

proc command*(label: string, args: proc(): seq[string]): Step =
  Step(label: label, kind: skCommand, args: args)

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

proc poll*(j: Job) =
  ## Advances the job as far as it can without blocking.
  while j.state == jsRunning:
    if j.process != nil:
      let code = j.process.peekExitCode
      if code == -1: return
      j.process.close()
      j.process = nil
      if code != 0:
        j.fail(j.steps[j.current].label & " exited with code " & $code)
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
        let args = s.args()
        j.log "$ " & quoteShellCommand(args)
        let sh = quoteShellCommand(args) & " >> " & quoteShell(j.logPath) & " 2>&1"
        j.process = startProcess("/bin/sh", args = ["-c", sh], options = {})
        return
      except CatchableError as e:
        j.fail(s.label & ": " & e.msg)

proc runToEnd*(j: Job) =
  ## Blocking variant, for command-line use.
  while j.state == jsRunning:
    j.poll()
    if j.state == jsRunning and j.process != nil: sleep(20)
