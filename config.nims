# Resolve all Nim dependencies from ./vendor (see deps.lock, tools/fetch_deps.sh).
import std/os
for dir in listDirs(thisDir() / "vendor"):
  switch("path", dir / "src")
  switch("path", dir)
switch("noNimblePath")
# Under ORC, Nim never frees a thread's own heap when the thread exits
# (threadimpl.nim skips deallocOsPages), so every light bake's worker threads
# and every audio player thread leaked their memory: ~20 MB per auto-bake,
# 25 GB after an hour of editing. With malloc, glibc reuses the arenas.
switch("define", "useMalloc")
# Crash reports (crashlog.nim) need to say where: release builds drop stack
# traces by default. Short file names keep the builder's folders out of them.
# Costs about 30% on loading a project; lighting.nim opts out of it.
switch("stackTrace", "on")
switch("lineTrace", "on")
switch("excessiveStackTrace", "off")
