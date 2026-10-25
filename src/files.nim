## Files inspector tab: the open project's folder read from disk. Each folder's
## listing is cached and read again when the folder changes (or, for small
## folders, every second, so file sizes stay current).

import std/[os, times, tables, algorithm, strutils, uri]

type
  FileEntry* = object
    name*: string
    dir*: bool
    size*: int64
    mtime*: Time

  DirListing* = object
    stamp: Time          ## The folder's modification time when it was read.
    checked: float       ## When the stamp was last compared.
    entries*: seq[FileEntry]

  FileCache* = object
    dirs*: Table[string, DirListing]
    all*: seq[string]    ## Every file and folder under allRoot (relative), for the filter.
    allRoot: string
    allChecked: float

proc readDir(path: string): seq[FileEntry] =
  for kind, p in walkDir(path):
    var e = FileEntry(name: p.lastPathPart, dir: kind in {pcDir, pcLinkToDir})
    try:
      let info = getFileInfo(p)
      e.size = info.size
      e.mtime = info.lastWriteTime
    except OSError: discard
    result.add e
  result.sort(proc(x, y: FileEntry): int =
    if x.dir != y.dir: (if x.dir: -1 else: 1) else: cmpIgnoreCase(x.name, y.name))

proc refresh*(c: var FileCache, path: string, force = false) =
  ## Makes c.dirs[path] current.
  let now = epochTime()
  let known = path in c.dirs
  if known and not force and now - c.dirs[path].checked < 1.0: return
  let stamp = try: getLastModificationTime(path) except OSError: Time()
  if force or not known or stamp != c.dirs[path].stamp or c.dirs[path].entries.len < 300:
    c.dirs[path] = DirListing(stamp: stamp, entries: readDir(path))
  c.dirs[path].checked = now

proc refreshAll*(c: var FileCache, root: string, force = false) =
  ## Makes c.all current: every path under root, walked again every 3 seconds.
  let now = epochTime()
  if not force and root == c.allRoot and now - c.allChecked < 3.0: return
  c.all.setLen 0
  for p in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}, relative = true):
    c.all.add p
  c.all.sort(cmpIgnoreCase)
  c.allRoot = root
  c.allChecked = now

proc clear*(c: var FileCache) =
  c.dirs.clear()
  c.all.setLen 0
  c.allRoot = ""

proc sizeText*(n: int64): string =
  if n < 1024: $n & " B"
  elif n < 1024 * 1024: formatFloat(n.float / 1024, ffDecimal, 1) & " KB"
  elif n < 1024 * 1024 * 1024: formatFloat(n.float / (1024 * 1024), ffDecimal, 1) & " MB"
  else: formatFloat(n.float / (1024 * 1024 * 1024), ffDecimal, 2) & " GB"

proc fileUri*(path: string): string =
  "file://" & encodeUrl(path, usePlus = false).replace("%2F", "/")
