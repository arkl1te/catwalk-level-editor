## Win32 declarations the Windows ports need beyond Windy's windefs.

import windy/platforms/win32/windefs
export windefs


type
  MINMAXINFO* {.pure.} = object
    ptReserved*, ptMaxSize*, ptMaxPosition*, ptMinTrackSize*, ptMaxTrackSize*: POINT
  TIMERPROC* = proc (hWnd: HWND, msg: UINT, id: UINT_PTR, time: DWORD) {.stdcall.}

const
  GWLP_WNDPROC* = -4'i32
  GWLP_HWNDPARENT* = -8'i32
  WS_EX_TOOLWINDOW* = 0x00000080'i32
  WS_EX_NOACTIVATE* = 0x08000000'i32
  WM_DROPFILES* = 0x0233'u32
  WM_MOUSEACTIVATE* = 0x0021'u32
  MA_NOACTIVATE* = 3
  WMSZ_LEFT* = 1
  WMSZ_RIGHT* = 2
  WMSZ_TOP* = 3
  WMSZ_TOPLEFT* = 4
  WMSZ_TOPRIGHT* = 5
  WMSZ_BOTTOM* = 6
  WMSZ_BOTTOMLEFT* = 7
  WMSZ_BOTTOMRIGHT* = 8
  VK_LBUTTON* = 0x01'i32
  VK_RBUTTON* = 0x02'i32
  VK_MBUTTON* = 0x04'i32
  VK_SHIFT* = 0x10'i32
  VK_CONTROL* = 0x11'i32
  SM_SWAPBUTTON* = 23'i32
  ASFW_ANY* = -1'i32
  CF_HDROP* = 15'u32

proc GetWindowLongPtrW*(hWnd: HWND, nIndex: int32): LONG_PTR {.stdcall, dynlib: "user32", importc.}
proc SetWindowLongPtrW*(hWnd: HWND, nIndex: int32, dwNewLong: LONG_PTR): LONG_PTR {.stdcall, dynlib: "user32", importc.}
proc CallWindowProcW*(prev: WNDPROC, hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall, dynlib: "user32", importc.}
proc SetTimer*(hWnd: HWND, id: UINT_PTR, elapse: UINT, fn: TIMERPROC): UINT_PTR {.stdcall, dynlib: "user32", importc.}
proc GetAsyncKeyState*(vKey: int32): int16 {.stdcall, dynlib: "user32", importc.}
proc GetSystemMetrics*(nIndex: int32): int32 {.stdcall, dynlib: "user32", importc.}
proc SetForegroundWindow*(hWnd: HWND): BOOL {.stdcall, dynlib: "user32", importc.}
proc AllowSetForegroundWindow*(pid: int32): BOOL {.stdcall, dynlib: "user32", importc.}
proc BringWindowToTop*(hWnd: HWND): BOOL {.stdcall, dynlib: "user32", importc.}
proc GetForegroundWindow*(): HWND {.stdcall, dynlib: "user32", importc.}
proc GetWindowThreadProcessId*(hWnd: HWND, pid: ptr int32): int32 {.stdcall, dynlib: "user32", importc.}
proc AttachThreadInput*(idAttach, idAttachTo: int32, fAttach: BOOL): BOOL {.stdcall, dynlib: "user32", importc.}
proc GetCurrentThreadId*(): int32 {.stdcall, dynlib: "kernel32", importc.}
proc MonitorFromPoint*(pt: POINT, dwFlags: int32): HMONITOR {.stdcall, dynlib: "user32", importc.}
proc MoveWindow*(hWnd: HWND, x, y, w, h: int32, repaint: BOOL): BOOL {.stdcall, dynlib: "user32", importc.}
proc AdjustWindowRectEx*(r: ptr RECT, style: LONG, menu: BOOL, exStyle: LONG): BOOL {.stdcall, dynlib: "user32", importc.}
proc CreateSolidBrush*(color: int32): HBRUSH {.stdcall, dynlib: "gdi32", importc.}
proc ValidateRect*(hWnd: HWND, r: ptr RECT): BOOL {.stdcall, dynlib: "user32", importc.}

proc DwmSetWindowAttribute*(hWnd: HWND, attr: int32, value: pointer, size: int32): HRESULT {.stdcall, dynlib: "dwmapi", importc.}
proc DragAcceptFiles*(hWnd: HWND, accept: BOOL) {.stdcall, dynlib: "shell32", importc.}
proc DragQueryFileW*(hDrop: HANDLE, iFile: UINT, file: ptr WCHAR, cch: UINT): UINT {.stdcall, dynlib: "shell32", importc.}
proc DragQueryPoint*(hDrop: HANDLE, pt: ptr POINT): BOOL {.stdcall, dynlib: "shell32", importc.}
proc DragFinish*(hDrop: HANDLE) {.stdcall, dynlib: "shell32", importc.}

# opengl32.dll's, looked up once the program runs, not as it loads: it may
# be Mesa's by then (gpumem).
proc wglProc(name: cstring): pointer =
  var lib {.global.}: HMODULE
  if lib == 0: lib = LoadLibraryA("opengl32.dll")
  GetProcAddress(lib, name)

proc glCurrentContext*(): HGLRC =
  cast[proc (): HGLRC {.stdcall.}](wglProc("wglGetCurrentContext"))()
proc glMakeCurrent*(hdc: HDC, hglrc: HGLRC): BOOL =
  cast[proc (hdc: HDC, hglrc: HGLRC): BOOL {.stdcall.}](wglProc("wglMakeCurrent"))(hdc, hglrc)
proc glCurrentDc*(): HDC =
  cast[proc (): HDC {.stdcall.}](wglProc("wglGetCurrentDC"))()
proc glProcAddress*(name: cstring): pointer =
  cast[proc (name: cstring): pointer {.stdcall.}](wglProc("wglGetProcAddress"))(name)

proc toWide*(s: string): seq[uint16] =
  ## UTF-8 to a NUL-terminated UTF-16 buffer.
  let n = MultiByteToWideChar(CP_UTF8, 0, s.cstring, s.len.int32, nil, 0)
  result = newSeq[uint16](n + 1)
  if n > 0:
    discard MultiByteToWideChar(CP_UTF8, 0, s.cstring, s.len.int32,
      cast[ptr WCHAR](result[0].addr), n)

proc fromWide*(p: ptr WCHAR, len = -1): string =
  ## UTF-16 (NUL-terminated when len < 0) to UTF-8.
  if p == nil or len == 0: return
  let n = WideCharToMultiByte(CP_UTF8, 0, p, len.int32, nil, 0, nil, nil)
  if n <= 0: return
  result = newString(n)
  discard WideCharToMultiByte(CP_UTF8, 0, p, len.int32, result.cstring, n, nil, nil)
  if len < 0: result.setLen(n - 1)  # the converted terminator
