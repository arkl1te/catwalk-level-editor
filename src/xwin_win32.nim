## Win32 counterparts of the X11 window helpers (see xwin_x11.nim): window
## moves, file drops, a hidden cursor, pointer capture and the popup windows
## menus are drawn into.

import std/[importutils, strutils]
import windy, vmath, chroma
from pixie import Image, newImage
import win32api

proc hwnd(window: Window): HWND = window.getHWND

proc hdc(window: Window): HDC =
  privateAccess(Window)
  window.hdc

proc outerRect(h: HWND): RECT =
  discard GetWindowRect(h, result.addr)

proc frameSize(h: HWND): IVec2 =
  ## Outer size minus client size: what the borders and title bar take.
  var c: RECT
  discard GetClientRect(h, c.addr)
  let o = outerRect(h)
  ivec2((o.right - o.left) - c.right, (o.bottom - o.top) - c.bottom)

proc disableVsync*(window: Window) =
  ## WGL's swap interval belongs to the current context, so call this while
  ## window's is current. Windy already asked for none; this makes sure
  ## drivers that default to 1 don't block.
  type SwapIntervalExt = proc (interval: cint): BOOL {.stdcall.}
  let ext = cast[SwapIntervalExt](glProcAddress("wglSwapIntervalEXT"))
  if ext != nil: discard ext(0)

proc darkTitleBar(window: Window) =
  ## Dark-first: the title bar and borders follow the app, not the system
  ## theme (Windows 10 2004+; older builds ignore it).
  const DwmwaUseImmersiveDarkMode = 20'i32
  var on: BOOL = 1
  let h = window.hwnd
  discard DwmSetWindowAttribute(h, DwmwaUseImmersiveDarkMode, on.addr, sizeof(on).int32)
  # Windy has already shown the window, and Windows 10 keeps the light frame
  # until the next activation change: recompute the frame and repaint it now.
  discard SetWindowPos(h, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or SWP_NOMOVE or
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)
  if GetForegroundWindow() == h:
    discard SendMessageW(h, WM_NCACTIVATE, 0, 0)
    discard SendMessageW(h, WM_NCACTIVATE, 1, 0)

# --- main window hook ------------------------------------------------------------

type MessageHook* = proc (msg: UINT, wParam: WPARAM, lParam: LPARAM)

type Hook = ref object
  window: Window
  prev: WNDPROC
  minSize: IVec2             ## client-area size
  frameless: bool            ## undecorated by setDecorated: the hook finds its edges
  cursor: HCURSOR            ## shown instead of Windy's cursor; 0: Windy's
  onMessage: MessageHook     ## sees every message, see setMessageHook

var hooks: seq[Hook]

var modalTick: proc ()  ## see whileModal

proc hookFor(h: HWND): Hook =
  for k in hooks:
    if k.window.hwnd == h: return k

const
  HtLeft = 10
  HtRight = 11
  HtTop = 12
  HtTopLeft = 13
  HtTopRight = 14
  HtBottom = 15
  HtBottomLeft = 16
  HtBottomRight = 17
  ScSize = 0xF000
  ScDragMove = 0xF012        ## SC_MOVE by the mouse, as from a title bar
  WmStartMove = UINT(WM_APP + 0x4D4D)  ## see startWindowDrag
  WmNcHitTest = 0x0084'u32
  WmNcLButtonDown = 0x00A1'u32
  SmCxSizeFrame = 32'i32
  SmCySizeFrame = 33'i32

proc edgeAt(k: Hook, x, y: int32): int =
  ## The hit-test code of the edge at screen point (x, y) of a frameless
  ## window, whose outer pixels stand in for the border it lacks (as MPC-HC's
  ## borderless mode does); 0 elsewhere, and when it can't be resized.
  let h = k.window.hwnd
  if not k.frameless or k.window.fullscreen or IsZoomed(h) != 0: return 0
  let o = outerRect(h)
  let (gx, gy) = (GetSystemMetrics(SmCxSizeFrame), GetSystemMetrics(SmCySizeFrame))
  let (l, r) = (x < o.left + gx, x >= o.right - gx)
  let (t, b) = (y < o.top + gy, y >= o.bottom - gy)
  if t and l: HtTopLeft elif t and r: HtTopRight
  elif b and l: HtBottomLeft elif b and r: HtBottomRight
  elif t: HtTop elif b: HtBottom elif l: HtLeft elif r: HtRight
  else: 0

proc sysSize(h: HWND, hit: int, lParam: LPARAM) =
  ## Runs the system's sizing loop from the edge hit names. SC_SIZE starts it
  ## on windows without a sizing border too, where DefWindowProc ignores a
  ## press on such an edge.
  discard SendMessageW(h, WM_SYSCOMMAND, WPARAM(ScSize or (hit - HtLeft + WMSZ_LEFT)), lParam)

proc dropFiles(k: Hook, drop: HANDLE) =
  privateAccess(Window)
  var pt: POINT
  discard DragQueryPoint(drop, pt.addr)
  k.window.state.mousePos = ivec2(pt.x, pt.y)
  let n = DragQueryFileW(drop, 0xFFFFFFFF'u32, nil, 0)
  for i in 0'u32 ..< n:
    let len = DragQueryFileW(drop, i, nil, 0)
    var buf = newSeq[uint16](len + 1)
    discard DragQueryFileW(drop, i, cast[ptr WCHAR](buf[0].addr), len + 1)
    let path = fromWide(cast[ptr WCHAR](buf[0].addr))
    if path.len > 0 and k.window.onFileDrop != nil:
      k.window.onFileDrop(path, "")
  DragFinish(drop)

# --- OLE drops: files, and links and text from browsers -------------------------
# WM_DROPFILES only ever carries files; a link dragged from a browser comes
# through OLE drag and drop alone, which then takes over files as well.

type
  FormatEtc = object
    cfFormat: uint16
    ptd: pointer
    dwAspect: int32
    lindex: int32
    tymed: int32
  StgMedium = object
    tymed: int32
    hGlobal: HGLOBAL
    pUnkForRelease: pointer
  DataObject = object
    vtbl: ptr DataObjectVtbl
  DataObjectVtbl = object
    queryInterface, addRef, release: pointer
    getData: proc (this: ptr DataObject, fmt: ptr FormatEtc, medium: ptr StgMedium): HRESULT {.stdcall.}
    getDataHere: pointer
    queryGetData: proc (this: ptr DataObject, fmt: ptr FormatEtc): HRESULT {.stdcall.}
  PointL = object
    x, y: int32
  DropTarget = object
    vtbl: ptr DropTargetVtbl
    hwnd: HWND
    accept: bool               ## the drag being over us carries something we take
  DropTargetVtbl = object
    queryInterface: proc (this: ptr DropTarget, riid: ptr GUID, obj: ptr pointer): HRESULT {.stdcall.}
    addRef, release: proc (this: ptr DropTarget): int32 {.stdcall.}
    dragEnter: proc (this: ptr DropTarget, data: ptr DataObject, keys: int32, pt: PointL,
                     effect: ptr int32): HRESULT {.stdcall.}
    dragOver: proc (this: ptr DropTarget, keys: int32, pt: PointL, effect: ptr int32): HRESULT {.stdcall.}
    dragLeave: proc (this: ptr DropTarget): HRESULT {.stdcall.}
    drop: proc (this: ptr DropTarget, data: ptr DataObject, keys: int32, pt: PointL,
                effect: ptr int32): HRESULT {.stdcall.}

const
  DvAspectContent = 1'i32
  TymedHGlobal = 1'i32
  DropEffectNone = 0'i32
  DropEffectCopy = 1'i32
  DropEffectLink = 4'i32
  ENoInterface = cast[HRESULT](0x80004002'u32)

proc OleInitialize(reserved: pointer): HRESULT {.stdcall, dynlib: "ole32", importc.}
proc RegisterDragDrop(hwnd: HWND, target: pointer): HRESULT {.stdcall, dynlib: "ole32", importc.}
proc ReleaseStgMedium(medium: ptr StgMedium) {.stdcall, dynlib: "ole32", importc.}
proc RegisterClipboardFormatW(name: ptr WCHAR): uint32 {.stdcall, dynlib: "user32", importc.}

var cfUrl: uint16  ## "UniformResourceLocatorW": a browser's link, UTF-16

proc formatOf(cf: uint16): FormatEtc =
  FormatEtc(cfFormat: cf, dwAspect: DvAspectContent, lindex: -1, tymed: TymedHGlobal)

proc dropFormats(): seq[uint16] = @[CF_HDROP.uint16, cfUrl, CF_UNICODETEXT.uint16]

proc offered(data: ptr DataObject): bool =
  for cf in dropFormats():
    var f = formatOf(cf)
    if cf != 0 and data.vtbl.queryGetData(data, f.addr) == 0: return true

proc dropped(data: ptr DataObject): seq[string] =
  ## The files, else the link, else the text lines the drag carries.
  for cf in dropFormats():
    if cf == 0: continue
    var f = formatOf(cf)
    var m: StgMedium
    if data.vtbl.getData(data, f.addr, m.addr) != 0: continue
    let p = GlobalLock(m.hGlobal)
    if p != nil:
      if cf == CF_HDROP.uint16:
        let drop = cast[HANDLE](m.hGlobal)
        for i in 0'u32 ..< DragQueryFileW(drop, 0xFFFFFFFF'u32, nil, 0):
          let len = DragQueryFileW(drop, i, nil, 0)
          var buf = newSeq[uint16](len + 1)
          discard DragQueryFileW(drop, i, cast[ptr WCHAR](buf[0].addr), len + 1)
          result.add fromWide(cast[ptr WCHAR](buf[0].addr))
      else:
        for line in fromWide(cast[ptr WCHAR](p)).splitLines:
          if line.strip.len > 0: result.add line.strip
          if cf == cfUrl: break  # just the one link
      discard GlobalUnlock(m.hGlobal)
    ReleaseStgMedium(m.addr)
    if result.len > 0: return

proc effectFor(t: ptr DropTarget, allowed: int32): int32 =
  if not t.accept: DropEffectNone
  elif (allowed and DropEffectCopy) != 0: DropEffectCopy
  elif (allowed and DropEffectLink) != 0: DropEffectLink  # some browsers' links
  else: DropEffectNone

proc trackDrag(t: ptr DropTarget, pt: PointL) =
  ## Where the drop will land, for the drop handler.
  let k = hookFor(t.hwnd)
  if k == nil: return
  privateAccess(Window)
  var p = POINT(x: pt.x, y: pt.y)
  discard ScreenToClient(t.hwnd, p.addr)
  k.window.state.mousePos = ivec2(p.x, p.y)

proc dtQueryInterface(this: ptr DropTarget, riid: ptr GUID, obj: ptr pointer): HRESULT {.stdcall.} =
  # IUnknown {00000000-0000-0000-C000-000000000046}, IDropTarget {00000122-...}
  let g = cast[ptr array[16, byte]](riid)
  let tail = [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46]
  let first = cast[ptr uint32](riid)[]
  if (first == 0 or first == 0x122) and g[4 .. 7] == [0'u8, 0, 0, 0] and g[8 .. 15] == tail:
    obj[] = this
    return 0
  obj[] = nil
  ENoInterface

proc dtAddRef(this: ptr DropTarget): int32 {.stdcall.} = 1  # lives as long as the app
proc dtRelease(this: ptr DropTarget): int32 {.stdcall.} = 1

proc dtDragEnter(this: ptr DropTarget, data: ptr DataObject, keys: int32, pt: PointL,
                 effect: ptr int32): HRESULT {.stdcall.} =
  this.accept = data.offered
  this.trackDrag(pt)
  effect[] = this.effectFor(effect[])

proc dtDragOver(this: ptr DropTarget, keys: int32, pt: PointL, effect: ptr int32): HRESULT {.stdcall.} =
  this.trackDrag(pt)
  effect[] = this.effectFor(effect[])

proc dtDragLeave(this: ptr DropTarget): HRESULT {.stdcall.} =
  this.accept = false

proc dtDrop(this: ptr DropTarget, data: ptr DataObject, keys: int32, pt: PointL,
            effect: ptr int32): HRESULT {.stdcall.} =
  this.trackDrag(pt)
  effect[] = this.effectFor(effect[])
  this.accept = false
  let k = hookFor(this.hwnd)
  if k == nil or k.window.onFileDrop == nil or effect[] == DropEffectNone: return
  for item in data.dropped: k.window.onFileDrop(item, "")

var dropVtbl = DropTargetVtbl(queryInterface: dtQueryInterface, addRef: dtAddRef,
  release: dtRelease, dragEnter: dtDragEnter, dragOver: dtDragOver,
  dragLeave: dtDragLeave, drop: dtDrop)

proc registerDrops(hwnd: HWND): bool =
  ## OLE drops on hwnd; false when OLE isn't to be had (WM_DROPFILES then).
  if OleInitialize(nil) < 0: return false
  let name = toWide("UniformResourceLocatorW")
  cfUrl = RegisterClipboardFormatW(cast[ptr WCHAR](name[0].unsafeAddr)).uint16
  let t = create(DropTarget)  # never freed: the window's for good
  t.vtbl = dropVtbl.addr
  t.hwnd = hwnd
  RegisterDragDrop(hwnd, t) >= 0

proc hookProc(h: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  let k = hookFor(h)
  if k == nil: return DefWindowProcW(h, msg, wParam, lParam)
  if k.onMessage != nil: k.onMessage(msg, wParam, lParam)
  case msg
  of WM_GETMINMAXINFO:
    result = CallWindowProcW(k.prev, h, msg, wParam, lParam)
    if k.minSize.x > 0:
      let f = frameSize(h)
      let mmi = cast[ptr MINMAXINFO](lParam)
      mmi.ptMinTrackSize = POINT(x: k.minSize.x + f.x, y: k.minSize.y + f.y)
    return 0
  of WM_SIZE:
    # Each step of a border drag, so the content follows the frame at once.
    result = CallWindowProcW(k.prev, h, msg, wParam, lParam)
    if modalTick != nil: modalTick()
    return
  of WM_NCCALCSIZE:
    # Frameless keeps its sizing border (see setDecorated) but gives it no
    # room: the client area is the whole window, or the work area when
    # maximized, which the border would otherwise overhang.
    if k.frameless and wParam != 0:
      if IsZoomed(h) != 0:
        var mi: MONITORINFO
        mi.cbSize = sizeof(MONITORINFO).DWORD
        if GetMonitorInfoW(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST), mi.addr) != 0:
          cast[ptr RECT](lParam)[] = mi.rcWork
      return 0
  of WM_NCACTIVATE:
    # Nor paint it when the window is activated or deactivated.
    if k.frameless:
      return CallWindowProcW(k.prev, h, msg, wParam, -1)
  of WmNcHitTest:
    let hit = k.edgeAt(int32(cast[int16](lParam and 0xFFFF)),
                       int32(cast[int16]((lParam shr 16) and 0xFFFF)))
    if hit != 0: return hit
  of WmNcLButtonDown:
    if k.frameless and wParam.int in HtLeft .. HtBottomRight:
      sysSize(h, wParam.int, lParam)
      return 0
  of WM_DROPFILES:
    k.dropFiles(cast[HANDLE](wParam))
    return 0
  of WM_SETCURSOR:
    if k.cursor != 0 and (lParam and 0xFFFF) == HTCLIENT:
      discard SetCursor(k.cursor)
      return 1
  of WmStartMove:
    # Still held as far as the queue goes: the release, if any, waits behind
    # this message and ends the loop. Like the X11 move, it never reaches the
    # app, where it would count as a click.
    if GetKeyState(VK_LBUTTON) < 0 and IsZoomed(h) == 0:
      var p: POINT
      discard GetCursorPos(p.addr)
      discard ReleaseCapture()
      discard SendMessageW(h, WM_SYSCOMMAND, WPARAM(ScDragMove),
        LPARAM((p.y and 0xFFFF) shl 16 or (p.x and 0xFFFF)))
    privateAccess(Window)
    k.window.state.buttonDown.excl MouseLeft
    return 0
  else: discard
  CallWindowProcW(k.prev, h, msg, wParam, lParam)

proc hookWindow(window: Window): Hook =
  ## The window's hook, installing it over its window procedure if new.
  result = hookFor(window.hwnd)
  if result != nil: return
  result = Hook(window: window)
  hooks.add result
  window.darkTitleBar()
  result.prev = cast[WNDPROC](GetWindowLongPtrW(window.hwnd, GWLP_WNDPROC))
  discard SetWindowLongPtrW(window.hwnd, GWLP_WNDPROC, cast[LONG_PTR](hookProc))

proc initMainWindow*(window: Window) =
  ## Hooks the window procedure for what Windy doesn't do on Windows: file
  ## drops, minimum size and moving by the content.
  if hookFor(window.hwnd) != nil: return
  discard window.hookWindow()
  if not registerDrops(window.hwnd): DragAcceptFiles(window.hwnd, 1)

proc setMessageHook*(window: Window, hook: MessageHook) =
  ## Shows hook every message of the main window, before it's handled.
  let k = hookFor(window.hwnd)
  if k != nil: k.onMessage = hook

# --- Windows' modal loops -----------------------------------------------------
# Dragging a title bar or a border, or opening a title bar's menu, runs a
# message loop inside DefWindowProc until it's over. The app's main loop, which
# called it through pollEvents, stalls meanwhile, and drawing with it.
# Those loops dispatch thread timers too, which call back into the app.

proc modalTimer(h: HWND, msg: UINT, id: UINT_PTR, time: DWORD) {.stdcall.} =
  if modalTick != nil: modalTick()

proc whileModal*(tick: proc ()) =
  ## Calls tick about every 10 ms from whichever message loop runs on this
  ## thread, pollEvents' or one of Windows' modal ones, and on each resize of
  ## the main window; tick tells a stalled main loop from a running one.
  modalTick = tick
  discard SetTimer(0, 0, 10, modalTimer)

proc clearFrameInput*(window: Window) =
  ## Forgets the presses, releases and deltas gathered since pollEvents began,
  ## once something has handled them in the middle of it.
  privateAccess(Window)
  window.state.perFrame = default(typeof(window.state.perFrame))

proc startWindowDrag*(window: Window) =
  ## Moves the window with the pointer until the left button comes up, by the
  ## system's move loop, as a title bar drag does: window managers such as
  ## PowerToys' FancyZones and Aero Snap only see moves made by that loop.
  ## It starts from pollEvents, which whileModal keeps stepping the app from,
  ## not from the frame calling this, which would stall it for the drag.
  if hookFor(window.hwnd) == nil or window.maximized: return
  discard PostMessageW(window.hwnd, WmStartMove, 0, 0)

type WindowEdge* = enum
  weTopLeft, weTop, weTopRight, weRight, weBottomRight, weBottom, weBottomLeft, weLeft

proc startWindowResize*(window: Window, edge: WindowEdge) =
  ## Resizes the window from edge with the system's sizing loop, as if its
  ## border had been grabbed. Frameless windows don't need this: the hook
  ## answers WM_NCHITTEST for their edges, so Windows resizes them itself.
  const Hit: array[WindowEdge, int] = [HtTopLeft, HtTop, HtTopRight, HtRight,
    HtBottomRight, HtBottom, HtBottomLeft, HtLeft]
  var p: POINT
  discard GetCursorPos(p.addr)
  discard ReleaseCapture()
  sysSize(window.hwnd, Hit[edge], LPARAM((p.y and 0xFFFF) shl 16 or (p.x and 0xFFFF)))
  # The loop ate the release.
  privateAccess(Window)
  window.state.buttonDown.excl MouseLeft

proc setDecorated*(window: Window, on: bool) =
  ## Shows or hides the title bar and borders, keeping the content size.
  ## Hidden, the sizing border stays in the style, out of sight (the hook
  ## gives it no room): PowerToys' FancyZones, like Snap, only resizes
  ## windows that have one, and would just move the window into a zone.
  let h = window.hwnd
  let size = window.size
  let style = GetWindowLongW(h, GWL_STYLE) or WS_THICKFRAME
  let k = hookFor(h)
  if k != nil: k.frameless = not on
  discard SetWindowLongW(h, GWL_STYLE, if on: style or WS_CAPTION else: style and not WS_CAPTION)
  discard SetWindowPos(h, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or SWP_NOMOVE or
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)
  window.size = size

proc activate*(window: Window) =
  ## Raises and focuses the window. Windows only lets the foreground process
  ## do that, so borrow its input state when we aren't it.
  let h = window.hwnd
  if IsIconic(h) != 0: discard ShowWindow(h, SW_RESTORE)
  if SetForegroundWindow(h) != 0: return
  let fg = GetWindowThreadProcessId(GetForegroundWindow(), nil)
  let me = GetCurrentThreadId()
  if fg != 0 and fg != me and AttachThreadInput(me, fg, 1) != 0:
    discard BringWindowToTop(h)
    discard SetForegroundWindow(h)
    discard AttachThreadInput(me, fg, 0)

proc framePos*(window: Window): IVec2 =
  ## Screen position of the window's outer (decorated) top-left corner.
  let o = outerRect(window.hwnd)
  ivec2(o.left, o.top)

proc moveFrame*(window: Window, pos: IVec2) =
  discard SetWindowPos(window.hwnd, 0, pos.x, pos.y, 0, 0,
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)

proc setDialogFor*(window, parent: Window, modal = true) =
  ## Makes window owned by parent: kept above it, minimized with it and left
  ## out of the taskbar. Call before showing it. Never modal here: the app
  ## keeps its other windows from being used itself.
  discard SetWindowLongPtrW(window.hwnd, GWLP_HWNDPARENT, cast[LONG_PTR](parent.hwnd))
  window.darkTitleBar()
  let ex = GetWindowLongW(window.hwnd, GWL_EXSTYLE)
  discard SetWindowLongW(window.hwnd, GWL_EXSTYLE, ex and not WS_EX_APPWINDOW)

proc keepContentsOnResize*(window: Window, background: ColorRGBX) =
  ## X11 only: a resized window here is drawn again by GL from the modal
  ## sizing loop, never left blank by the system.
  discard

proc placeDialog*(window: Window, pos, size: IVec2, minSize = ivec2(0, 0)) =
  ## Gives the window a client area of size with its outer top-left at pos.
  ## With minSize, a resizable window can't be made smaller than that.
  if minSize.x > 0 and minSize.y > 0: window.hookWindow().minSize = minSize
  window.size = size
  window.moveFrame(pos)

proc placeWindow*(window: Window, pos, size: IVec2, maximized: bool) =
  ## Restores a saved geometry: outer top-left corner at pos, content size
  ## size, optionally maximized (on the monitor pos is on). Call while the
  ## window is hidden.
  let f = frameSize(window.hwnd)
  discard SetWindowPos(window.hwnd, 0, pos.x, pos.y, size.x + f.x, size.y + f.y,
    SWP_NOZORDER or SWP_NOACTIVATE)
  if maximized: discard ShowWindow(window.hwnd, SW_MAXIMIZE)

proc detectableAutoRepeat*() =
  ## X11 only: Windows sends a held key's repeats as presses alone already.
  discard

proc monitorAt*(point: IVec2): tuple[pos, size: IVec2] =
  ## Screen rect of the monitor holding point, else the nearest one.
  result = (ivec2(0, 0), ivec2(1920, 1080))
  var mi: MONITORINFO
  mi.cbSize = sizeof(MONITORINFO).DWORD
  let m = MonitorFromPoint(POINT(x: point.x, y: point.y), MONITOR_DEFAULTTONEAREST)
  if m != 0 and GetMonitorInfoW(m, mi.addr) != 0:
    let r = mi.rcMonitor
    result = (ivec2(r.left, r.top), ivec2(r.right - r.left, r.bottom - r.top))

proc monitorSize*(window: Window): IVec2 =
  ## Size of the monitor that holds the window centre.
  monitorAt(window.pos + window.size div 2).size

proc pointerPos*(window: Window): tuple[screen, local: IVec2] =
  ## Pointer position on screen and relative to the window's content.
  var p: POINT
  discard GetCursorPos(p.addr)
  let screen = ivec2(p.x, p.y)
  (screen, screen - window.pos)

proc pointerButtonsDown*(): bool =
  ## Whether the left, middle or right mouse button is held anywhere.
  for vk in [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]:
    if (GetAsyncKeyState(vk).int and 0x8000) != 0: return true

proc ctrlHeld*(): bool =
  ## Whether Ctrl is held, even while another window has the keyboard.
  (GetAsyncKeyState(VK_CONTROL).int and 0x8000) != 0

proc shiftHeld*(): bool =
  ## Whether Shift is held, even while another window has the keyboard.
  (GetAsyncKeyState(VK_SHIFT).int and 0x8000) != 0

var grabbedBy: HWND

proc grabPointer*(window: Window): bool =
  ## Captures the pointer for window while a menu is open, so presses on our
  ## other windows reach it. Windows never routes a click on another app's
  ## window to us; that one is caught as focus loss instead.
  discard SetCapture(window.hwnd)
  grabbedBy = window.hwnd
  true

proc ungrabPointer*() =
  if grabbedBy != 0 and GetCapture() == grabbedBy: discard ReleaseCapture()
  grabbedBy = 0

proc setDiagonalCursor*(window: Window, nwse: bool) =
  ## A diagonal resize cursor, which Windy lacks: nwse runs top-left to
  ## bottom-right, otherwise top-right to bottom-left.
  let k = hookFor(window.hwnd)
  if k == nil: return
  k.cursor = LoadCursorW(0, if nwse: IDC_SIZENWSE else: IDC_SIZENESW)
  discard SetCursor(k.cursor)

proc clearDiagonalCursor*(window: Window) =
  ## Back to Windy's cursor (set it right after).
  let k = hookFor(window.hwnd)
  if k != nil: k.cursor = 0

var hiddenCursorImage: Image

proc hiddenCursor*(): Cursor =
  if hiddenCursorImage == nil:
    hiddenCursorImage = newImage(1, 1)
  Cursor(kind: CustomCursor, image: hiddenCursorImage, hotspot: ivec2(0, 0))

# --- popup windows ------------------------------------------------------------

type
  PopupWindow* = ref object
    ## Borderless, never-activated window (like a toolkit's menu popup) that
    ## can extend past the main window. It is drawn with the main window's
    ## GL context, which works because both use the same pixel format.
    hwnd: HWND
    dc: HDC
    pos, size*: IVec2
    mapped, formatSet: bool

  PopupInput* = object
    activity*: bool          ## any pointer or paint event arrived
    leftPressed*, leftReleased*, anyPressed*: bool

const PopupClass = "CatwalkPopup"

var
  popupClassReady: bool
  popupEvents: PopupInput    ## gathered by popupProc until pollInput drains it
  mainContext: HGLRC
  mainDc: HDC

proc popupProc(h: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_MOUSEACTIVATE:
    return MA_NOACTIVATE
  of WM_MOUSEMOVE, WM_PAINT:
    popupEvents.activity = true
    if msg == WM_PAINT:
      discard ValidateRect(h, nil)
      return 0
  of WM_LBUTTONDOWN:
    popupEvents.activity = true
    popupEvents.anyPressed = true
    popupEvents.leftPressed = true
    return 0
  of WM_RBUTTONDOWN, WM_MBUTTONDOWN:
    popupEvents.activity = true
    popupEvents.anyPressed = true
    return 0
  of WM_LBUTTONUP:
    popupEvents.activity = true
    popupEvents.leftReleased = true
    return 0
  else: discard
  DefWindowProcW(h, msg, wParam, lParam)

proc newPopupWindow*(background: ColorRGBX): PopupWindow =
  let inst = GetModuleHandleW(nil)
  var cls = toWide(PopupClass)
  if not popupClassReady:
    popupClassReady = true
    let c = background  # opaque, so premultiplied == straight
    var wc = WNDCLASSEXW(cbSize: sizeof(WNDCLASSEXW).UINT, lpfnWndProc: popupProc,
      hInstance: inst, hCursor: LoadCursorW(0, IDC_ARROW),
      hbrBackground: CreateSolidBrush(c.r.int32 or (c.g.int32 shl 8) or (c.b.int32 shl 16)),
      lpszClassName: cast[ptr WCHAR](cls[0].addr))
    discard RegisterClassExW(wc.addr)
  result = PopupWindow(pos: ivec2(-1, -1))
  result.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE,
    cast[ptr WCHAR](cls[0].addr), nil, WS_POPUP, 0, 0, 1, 1, 0, 0, inst, nil)
  result.dc = GetDC(result.hwnd)

proc show*(p: PopupWindow, pos, size: IVec2) =
  if pos != p.pos or size != p.size:
    p.pos = pos
    p.size = size
    discard SetWindowPos(p.hwnd, HWND_TOPMOST, pos.x, pos.y, size.x, size.y,
      SWP_NOACTIVATE)
  if not p.mapped:
    p.mapped = true
    discard ShowWindow(p.hwnd, SW_SHOWNOACTIVATE)

proc hide*(p: PopupWindow) =
  if not p.mapped: return
  p.mapped = false
  discard ShowWindow(p.hwnd, SW_HIDE)

proc matchPixelFormat(dc: HDC) =
  ## Gives dc the pixel format of the current (main window's) drawable, so the
  ## main context can render into it.
  let fmt = GetPixelFormat(mainDc)
  var pfd: PIXELFORMATDESCRIPTOR
  discard DescribePixelFormat(mainDc, fmt, sizeof(PIXELFORMATDESCRIPTOR).UINT, pfd.addr)
  discard SetPixelFormat(dc, fmt, pfd.addr)

proc rememberMain() =
  mainContext = glCurrentContext()
  mainDc = glCurrentDc()

proc makeCurrentOn(dc: HDC): bool =
  ## A failed switch leaves no context current: rebind the main window's.
  result = glMakeCurrent(dc, mainContext) != 0
  if not result: discard glMakeCurrent(mainDc, mainContext)

proc beginDraw*(p: PopupWindow): bool =
  ## Points the current GL context at the popup; GL state carries over.
  ## False when that failed: skip the popup this frame (no endDraw).
  rememberMain()
  if not p.formatSet:
    p.formatSet = true
    matchPixelFormat(p.dc)
  makeCurrentOn(p.dc)

proc endDraw*(p: PopupWindow, main: Window) =
  ## Presents the popup and makes the main window current again.
  discard SwapBuffers(p.dc)
  discard glMakeCurrent(main.hdc, mainContext)

proc beginDrawOn*(target: Window): bool =
  ## Points the current (main window's) GL context at another window of the
  ## same pixel format, so it draws with the main window's GL resources.
  ## False when that failed: skip drawing target this frame (no endDrawOn).
  rememberMain()
  makeCurrentOn(target.hdc)

proc endDrawOn*(target, main: Window) =
  ## Presents target and makes the main window current again.
  discard SwapBuffers(target.hdc)
  discard glMakeCurrent(main.hdc, mainContext)

proc pollInput*(popups: openArray[PopupWindow], input: var PopupInput) =
  ## Hands over what the popups saw since the last call (Windy's pollEvents
  ## dispatched their messages to popupProc).
  if popupEvents.activity: input.activity = true
  input.leftPressed = input.leftPressed or popupEvents.leftPressed
  input.leftReleased = input.leftReleased or popupEvents.leftReleased
  input.anyPressed = input.anyPressed or popupEvents.anyPressed
  popupEvents = PopupInput()

proc attachStdio*() =
  ## A GUI-subsystem program starts without stdout/stderr, and writing to
  ## them would raise. Use the console of the terminal we were started from,
  ## if any, else discard the output.
  const AttachParentProcess = -1'i32
  proc AttachConsole(pid: int32): BOOL {.stdcall, dynlib: "kernel32", importc.}
  proc GetStdHandle(n: int32): HANDLE {.stdcall, dynlib: "kernel32", importc.}
  const StdOutputHandle = -11'i32
  let h = GetStdHandle(StdOutputHandle)
  if h != 0 and h != -1: return  # redirected (or a console build): keep it
  let target = if AttachConsole(AttachParentProcess) != 0: "CONOUT$" else: "NUL"
  discard reopen(stdout, target, fmWrite)
  discard reopen(stderr, target, fmWrite)
