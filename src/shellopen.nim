## Opens files and folders with the desktop's own programs: xdg-open and the
## file manager's FileManager1 on Linux, ShellExecute and Explorer on Windows.

when defined(windows):
  import std/strutils
  import win32api
  proc ShellExecuteW(hwnd: HWND, op, file, params, dir: ptr WCHAR, show: int32): int {.stdcall, importc, dynlib: "shell32".}

  proc shellExecute(file, params: string) =
    var op = toWide("open")
    var f = toWide(file)
    var p = toWide(params)
    discard ShellExecuteW(0, cast[ptr WCHAR](op[0].addr), cast[ptr WCHAR](f[0].addr),
      (if params.len > 0: cast[ptr WCHAR](p[0].addr) else: nil), nil, SW_SHOWNORMAL)
else:
  import std/os
  import files

proc openPath*(path: string) =
  ## path in its default program (a folder in the file manager).
  when defined(windows):
    shellExecute(path, "")
  else:
    discard execShellCmd("xdg-open " & quoteShell(path) & " >/dev/null 2>&1 &")

proc showInFolder*(path: string) =
  ## The file manager on path's folder with path selected (FileManager1, as
  ## Dolphin and Nautilus offer; Explorer's /select), else just the folder.
  when defined(windows):
    shellExecute("explorer.exe", "/select,\"" & path.replace('/', '\\') & "\"")
  else:
    discard execShellCmd("(gdbus call --session --dest org.freedesktop.FileManager1 " &
      "--object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems " &
      quoteShell("['" & fileUri(path) & "']") & " '' || xdg-open " & quoteShell(path.parentDir) &
      ") >/dev/null 2>&1 &")
