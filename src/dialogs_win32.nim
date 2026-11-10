## Windows' common file dialogs, run on a thread of their own so the editor
## keeps drawing while one is open; included by dialogs.nim.

import std/[atomics, typedthreads]
import win32api

type
  DialogJob = object
    kind: DialogKind
    title, startPath: string
    filters: seq[(string, seq[string])]
    paths: seq[string]         ## written by the thread before done is set
    done: Atomic[int]          ## int: MSVC writes 8 bytes to an Atomic[bool], see crashlog.nim

  Dialog* = ref object
    job: ptr DialogJob
    thread: Thread[ptr DialogJob]
    purpose*: string         # caller-defined tag, e.g. "open", "subtitle"

var dialogOwner: HWND  ## set once at startup, read by the dialog threads

proc setDialogOwner*(hwnd: HWND) =
  ## The window dialogs center over and stay in front of.
  dialogOwner = hwnd

const
  OFN_ALLOWMULTISELECT = 0x00000200.DWORD
  OFN_HIDEREADONLY = 0x00000004.DWORD
  COINIT_APARTMENTTHREADED = 0x2'i32
  CLSCTX_INPROC_SERVER = 0x1'i32
  FOS_PICKFOLDERS = 0x20'u32
  FOS_FORCEFILESYSTEM = 0x40'u32
  SIGDN_FILESYSPATH = 0x80058000'u32

type
  Guid = object
    d1: uint32
    d2, d3: uint16
    d4: array[8, uint8]

  # Just the vtable slots used, in declaration order (IUnknown, IModalWindow,
  # IFileDialog / IShellItem).
  FileDialogVtbl = object
    queryInterface, addRef: pointer
    release: proc (this: pointer): uint32 {.stdcall.}
    show: proc (this: pointer, owner: HWND): int32 {.stdcall.}
    setFileTypes, setFileTypeIndex, getFileTypeIndex, advise, unadvise: pointer
    setOptions: proc (this: pointer, fos: uint32): int32 {.stdcall.}
    getOptions: proc (this: pointer, fos: ptr uint32): int32 {.stdcall.}
    setDefaultFolder: pointer
    setFolder: proc (this: pointer, item: pointer): int32 {.stdcall.}
    getFolder, getCurrentSelection, setFileName, getFileName: pointer
    setTitle: proc (this: pointer, title: ptr WCHAR): int32 {.stdcall.}
    setOkButtonLabel, setFileNameLabel: pointer
    getResult: proc (this: pointer, item: ptr pointer): int32 {.stdcall.}

  ShellItemVtbl = object
    queryInterface, addRef: pointer
    release: proc (this: pointer): uint32 {.stdcall.}
    bindToHandler, getParent: pointer
    getDisplayName: proc (this: pointer, sigdn: uint32, name: ptr ptr WCHAR): int32 {.stdcall.}

  ComObj[T] = ptr object
    vtbl: ptr T

const
  CLSID_FileOpenDialog = Guid(d1: 0xDC1C5A9C'u32, d2: 0xE88A, d3: 0x4DDE,
    d4: [0xA5'u8, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7])
  IID_IFileOpenDialog = Guid(d1: 0xD57C7288'u32, d2: 0xD4AD, d3: 0x4768,
    d4: [0xBE'u8, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60])
  IID_IShellItem = Guid(d1: 0x43826D1E'u32, d2: 0xE718, d3: 0x42EE,
    d4: [0xBC'u8, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE])

proc CoInitializeEx(reserved: pointer, coInit: int32): int32 {.stdcall, importc, dynlib: "ole32".}
proc CoUninitialize() {.stdcall, importc, dynlib: "ole32".}
proc CoCreateInstance(clsid: ptr Guid, outer: pointer, ctx: int32, iid: ptr Guid,
  obj: ptr pointer): int32 {.stdcall, importc, dynlib: "ole32".}
proc CoTaskMemFree(p: pointer) {.stdcall, importc, dynlib: "ole32".}
proc SHCreateItemFromParsingName(path: ptr WCHAR, bc: pointer, iid: ptr Guid,
  item: ptr pointer): int32 {.stdcall, importc, dynlib: "shell32".}

proc wptr(w: var seq[uint16]): ptr WCHAR = cast[ptr WCHAR](w[0].addr)

proc filterString(filters: seq[(string, seq[string])]): seq[uint16] =
  ## "Name (*.a;*.b)\0*.a;*.b\0...All files\0*.*\0\0" as UTF-16.
  var s = ""
  for (name, exts) in filters:
    var globs = ""
    for i, e in exts:
      if i > 0: globs.add ";"
      globs.add "*." & e
    s.add name & " (" & globs & ")\0" & globs & "\0"
  s.add "All files (*.*)\0*.*\0"
  result = toWide(s)
  result.add 0'u16

proc fileDialog(job: ptr DialogJob) =
  const BufLen = 65536  # room for a few hundred selected files
  var
    buf = newSeq[uint16](BufLen)
    initialDir: seq[uint16]
    title = toWide(job.title)
    filter = filterString(job.filters)
    defExt: seq[uint16]
  if dirExists(job.startPath):
    initialDir = toWide(job.startPath)
  else:
    initialDir = toWide(job.startPath.parentDir)
    if job.kind == dkSaveFile:
      let name = toWide(job.startPath.extractFilename)
      copyMem(buf[0].addr, name[0].unsafeAddr, min(name.len, BufLen - 1) * 2)
  if job.kind == dkSaveFile and job.filters.len > 0 and job.filters[0][1].len > 0:
    defExt = toWide(job.filters[0][1][0])
  var ofn = OPENFILENAMEW(lStructSize: sizeof(OPENFILENAMEW).DWORD,
    hwndOwner: dialogOwner, lpstrFilter: filter.wptr, nFilterIndex: 1, lpstrFile: buf.wptr,
    nMaxFile: BufLen, lpstrInitialDir: initialDir.wptr, lpstrTitle: title.wptr,
    lpstrDefExt: (if defExt.len > 0: defExt.wptr else: nil),
    Flags: OFN_EXPLORER or OFN_NOCHANGEDIR or OFN_PATHMUSTEXIST or OFN_HIDEREADONLY)
  case job.kind
  of dkSaveFile:
    ofn.Flags = ofn.Flags or OFN_OVERWRITEPROMPT
    if GetSaveFileNameW(ofn.addr) != 0:
      job.paths.add fromWide(buf.wptr)
  else:
    ofn.Flags = ofn.Flags or OFN_FILEMUSTEXIST
    if job.kind == dkOpenFiles: ofn.Flags = ofn.Flags or OFN_ALLOWMULTISELECT
    if GetOpenFileNameW(ofn.addr) != 0:
      # One file: its full path. Several: the folder, then each name; all
      # NUL-separated, ending in an empty string.
      var parts: seq[string]
      var i = 0
      while i < BufLen and buf[i] != 0:
        let start = i
        while buf[i] != 0: inc i
        parts.add fromWide(cast[ptr WCHAR](buf[start].addr), i - start)
        inc i
      if parts.len == 1: job.paths = parts
      else:
        for name in parts[1 .. ^1]: job.paths.add parts[0] / name

proc folderDialog(job: ptr DialogJob) =
  var obj: pointer
  if CoCreateInstance(CLSID_FileOpenDialog.unsafeAddr, nil, CLSCTX_INPROC_SERVER,
      IID_IFileOpenDialog.unsafeAddr, obj.addr) < 0: return
  let dlg = cast[ComObj[FileDialogVtbl]](obj)
  var fos: uint32
  discard dlg.vtbl.getOptions(dlg, fos.addr)
  discard dlg.vtbl.setOptions(dlg, fos or FOS_PICKFOLDERS or FOS_FORCEFILESYSTEM)
  var title = toWide(job.title)
  discard dlg.vtbl.setTitle(dlg, title.wptr)
  var start = toWide(job.startPath)
  var folder: pointer
  if dirExists(job.startPath) and SHCreateItemFromParsingName(start.wptr, nil,
      IID_IShellItem.unsafeAddr, folder.addr) >= 0:
    discard dlg.vtbl.setFolder(dlg, folder)
    discard cast[ComObj[ShellItemVtbl]](folder).vtbl.release(folder)
  if dlg.vtbl.show(dlg, dialogOwner) >= 0:
    var item: pointer
    if dlg.vtbl.getResult(dlg, item.addr) >= 0:
      let si = cast[ComObj[ShellItemVtbl]](item)
      var name: ptr WCHAR
      if si.vtbl.getDisplayName(si, SIGDN_FILESYSPATH, name.addr) >= 0:
        job.paths.add fromWide(name)
        CoTaskMemFree(name)
      discard si.vtbl.release(si)
  discard dlg.vtbl.release(dlg)

proc runDialog(job: ptr DialogJob) {.thread.} =
  let com = CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
  # The job is ours alone until done is set; COM's function pointers just
  # aren't marked gcsafe.
  {.cast(gcsafe).}:
    try:
      if job.kind == dkOpenDir: folderDialog(job)
      else: fileDialog(job)
    except CatchableError:
      discard
  if com >= 0: CoUninitialize()
  job.done.store(1)

proc startDialog*(kind: DialogKind, purpose, title, startPath: string,
                  filterExts: seq[string] = @[], filterName = "",
                  extraFilters: seq[(string, seq[string])] = @[]): Dialog =
  ## extraFilters: further (name, extensions) choices after the first filter.
  let job = createShared(DialogJob)
  job.kind = kind
  job.title = title
  job.startPath = startPath
  if filterExts.len > 0: job.filters.add (filterName, filterExts)
  job.filters.add extraFilters
  result = Dialog(purpose: purpose, job: job)
  createThread(result.thread, runDialog, job)

proc poll*(d: Dialog, done: var bool): seq[string] =
  ## Returns the selected paths once the dialog has closed (empty if cancelled).
  done = true
  if d == nil or d.job == nil: return
  if d.job.done.load == 0:
    done = false
    return
  joinThread(d.thread)
  result = move d.job.paths
  `=destroy`(d.job[])
  deallocShared(d.job)
  d.job = nil
