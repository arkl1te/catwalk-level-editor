## Logs Catwalk writes for itself, so a bug can be tracked down after the fact,
## also from someone else's machine. Each run keeps a session log (what the
## console showed and every edit, flushed line by line, so it survives anything
## short of a power cut), and a crash adds a report: where it happened, what the
## editor was doing, the machine, and the end of the session log. Files live in
## logDir, with the home folder written as ~ so they can be shared as they are.

import std/[os, strutils, times, algorithm, atomics]
when defined(posix):
  from std/posix import getpid

const
  CrashIssue* = "Catwalk crashed in an earlier run. Click to find the report; please send it along when reporting the bug."
  KeepFiles = 20       ## Newest sessions and newest reports kept, each.
  TailLines = 200      ## Session log lines copied into a report.
  ContextSize = 2048

var
  logFolder, sessionPath, home, version: string
  sysInfo: string
  session: File
  sessionOpen: bool
  crashing: Atomic[int]  ## int: MSVC stores 8 bytes into any Atomic, see music.nim
  # A fixed buffer, as a crash may come from any thread, or from a signal
  # during an allocation: reading it needs no memory management.
  context: array[ContextSize, char]
  contextLen: int

proc logDir*(): string =
  ## ~/.local/state/catwalk/logs, on Windows %LOCALAPPDATA%\catwalk\logs (not
  ## getCacheDir("catwalk"): on Windows that is already catwalk\cache).
  when defined(windows):
    getCacheDir() / "catwalk" / "logs"
  else:
    let state = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
    state / "catwalk" / "logs"

proc scrub(s: string): string =
  if home.len > 1: s.replace(home, "~") else: s

proc stamp(): string = now().format("yyyyMMdd-HHmmss")

proc prune(pattern: string) =
  var files: seq[string]
  for f in walkFiles(logFolder / pattern): files.add f
  files.sort(system.cmp, Descending)   # The names sort by time.
  for i in KeepFiles ..< files.len:
    try: removeFile(files[i])
    except OSError: discard

proc readSystem(): string =
  result = "OS: " & hostOS & " " & hostCPU & "\n"
  when defined(linux):
    try:
      for l in lines("/etc/os-release"):
        if l.startsWith("PRETTY_NAME="):
          result.add "Distribution: " & l[12 .. ^1].strip(chars = {'"'}) & "\n"
    except IOError, OSError: discard
    try: result.add "Kernel: " & readFile("/proc/sys/kernel/osrelease").strip & "\n"
    except IOError, OSError: discard
    try:
      for l in lines("/proc/meminfo"):
        if l.startsWith("MemTotal:"): result.add "Memory: " & l[9 .. ^1].strip & "\n"
    except IOError, OSError: discard
    result.add "Session: " & getEnv("XDG_SESSION_TYPE", "?") & ", " & getEnv("XDG_CURRENT_DESKTOP", "?") & "\n"

proc logLine*(text: string, error = false) =
  ## Adds a line to the session log.
  if not sessionOpen: return
  try:
    session.writeLine now().format("HH:mm:ss"), (if error: " ERROR " else: " "), scrub(text)
    session.flushFile()
  except IOError, OSError, ValueError: discard

proc addSystemInfo*(line: string) =
  ## More about the machine (the graphics card, once there's a context).
  sysInfo.add line & "\n"
  logLine line

proc setContext*(s: string) =
  ## What the editor is doing right now, for a report. Called every frame.
  let n = min(s.len, ContextSize)
  if n > 0: copyMem(addr context[0], unsafeAddr s[0], n)
  contextLen = n

proc tailOfSession(): string =
  if sessionPath.len == 0: return
  let all = readFile(sessionPath).splitLines
  all[max(all.len - TailLines - 1, 0) .. ^1].join("\n")

proc writeReport(msg: string): string =
  ## Writes the part that matters first and flushes it, as the rest might fail.
  result = logFolder / "crash-" & stamp() & "-" & $getCurrentProcessId() & ".txt"
  let f = open(result, fmWrite)
  defer: f.close()
  f.write "Catwalk ", version, " crash report\n\n", scrub(msg), "\n"
  f.flushFile()
  var ctx = newString(contextLen)
  if contextLen > 0: copyMem(addr ctx[0], addr context[0], contextLen)
  f.write "--- Editor state ---\n", scrub(ctx), "\n\n--- System ---\n", scrub(sysInfo), "\n"
  f.flushFile()
  f.write "--- Last ", TailLines, " log lines ---\n", tailOfSession(), "\n"

proc crashed(msg: string) {.nimcall, gcsafe, raises: [], tags: [WriteIOEffect].} =
  ## Both of Nim's ways out: an unhandled exception and a fatal signal.
  # Nim calls this with the thread's error flag still up, and every call here
  # would take that for its own failure and return at once. The process quits
  # right after this, so nothing needs the flag any more.
  {.emit: "*nimErrorFlag() = NIM_FALSE;".}
  try:
    {.cast(gcsafe).}:
      {.cast(tags: []).}:
        stderr.write msg
        if msg.contains("SIGINT:"): return    # Ctrl+C in a terminal.
        if crashing.exchange(1) != 0: return    # Another thread got here first.
        if logFolder.len == 0: return
        let path = writeReport(msg)
        logLine("Crashed, report in " & path, true)
        stderr.writeLine "Crash report: ", path
  except Exception: discard

proc initLog*(appVersion: string, args: seq[string]) =
  ## Starts the session log and takes over crash reporting.
  version = appVersion
  home = getHomeDir().strip(leading = false, chars = {'/', '\\'})
  sysInfo = readSystem()
  onUnhandledException = crashed
  errorMessageWriter = crashed
  try:
    logFolder = logDir()
    createDir(logFolder)
    prune("session-*.log")
    prune("crash-*.txt")
    sessionPath = logFolder / "session-" & stamp() & "-" & $getCurrentProcessId() & ".log"
    session = open(sessionPath, fmWrite)
    sessionOpen = true
  except IOError, OSError:
    logFolder = ""     # Nowhere to write: the editor works without logs.
    return
  logLine "Catwalk " & version & ", built " & CompileDate & " " & CompileTime
  for l in sysInfo.strip.splitLines: logLine l
  logLine "Arguments: " & args.join(" ")

proc closeLog*() =
  ## A clean exit; a session log without this line ended some other way.
  logLine "Clean exit"
  if sessionOpen:
    sessionOpen = false
    session.close()

proc unseenCrash*(): string =
  ## The newest report no earlier launch has shown, or "".
  if logFolder.len == 0: return
  var files: seq[string]
  for f in walkFiles(logFolder / "crash-*.txt"): files.add f
  if files.len == 0: return
  files.sort()
  let marker = logFolder / "last-seen-crash"
  let seen = try: readFile(marker).strip except IOError, OSError: ""
  if files[^1].extractFilename <= seen: return
  try: writeFile(marker, files[^1].extractFilename)
  except IOError, OSError: discard
  files[^1]
