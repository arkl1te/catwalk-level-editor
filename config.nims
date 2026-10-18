# Resolve all Nim dependencies from ./vendor (see deps.lock, tools/fetch_deps.sh).
import std/os
for dir in listDirs(thisDir() / "vendor"):
  switch("path", dir / "src")
  switch("path", dir)
switch("noNimblePath")
