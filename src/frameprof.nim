## Frame profiling, for finding what makes frames slow: built with
## -d:frameProfile, `prof "name": body` adds body's time to name, profAdd
## adds time measured elsewhere (the GPU's), and profFrame (once per frame)
## writes each name's average milliseconds per frame to
## %TEMP%/catwalk-profile.txt every 3 seconds. Without the define, prof is
## just its body and the others do nothing.

when defined(frameProfile):
  import std/[monotimes, times, tables, algorithm, os, strutils]
  var spent: OrderedTable[string, int64]
  var frames = 0
  var since = getMonoTime()

  template prof*(name: string, body: untyped) =
    let t0 = getMonoTime()
    body
    spent.mgetOrPut(name, 0) += (getMonoTime() - t0).inNanoseconds

  proc profAdd*(name: string, ns: int64) =
    spent.mgetOrPut(name, 0) += ns

  proc profFrame*() =
    inc frames
    let now = getMonoTime()
    let total = (now - since).inNanoseconds
    if total < 3_000_000_000: return
    var lines = @["frames " & $frames & ", " & formatFloat(total.float / 1e6 / frames.float, ffDecimal, 2) &
                  " ms per frame"]
    var items: seq[(int64, string)]
    for k, v in spent: items.add (v, k)
    items.sort(SortOrder.Descending)
    for (v, k) in items:
      lines.add "  " & formatFloat(v.float / 1e6 / frames.float, ffDecimal, 3).align(9) & " ms  " & k
    let f = open(getTempDir() / "catwalk-profile.txt", fmAppend)
    f.writeLine lines.join("\n")
    f.close()
    spent.clear()
    frames = 0
    since = now
else:
  template prof*(name: string, body: untyped) = body
  proc profAdd*(name: string, ns: int64) = discard
  proc profFrame*() = discard
