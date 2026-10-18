## X11 window-manager helpers that Windy does not expose: interactive move,
## always-on-top, aspect-ratio size hints, a hidden cursor, pointer grabs and
## the override-redirect popup windows menus are drawn into.
## Windy runs on X11 (XWayland under a Wayland session), so these apply there.

import std/[importutils, strutils, tables, hashes, times]
import windy, vmath, pixie, chroma

{.passL: "-lX11".}

type
  XDisplay = pointer
  XID = culong
  Atom = culong

  XClientMessage = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: XDisplay
    window: XID
    messageType: Atom
    format: cint
    data: array[5, clong]

  XButtonEvent = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: XDisplay
    window, root, subwindow: XID
    time: culong
    x, y, xRoot, yRoot: cint
    state, button: cuint
    sameScreen: cint

  XEventBuf {.union.} = object
    msg: XClientMessage
    btn: XButtonEvent
    pad: array[24, clong]

  XVisualInfo = object
    visual: pointer
    visualid: culong
    screen, depth, class: cint
    redMask, greenMask, blueMask: culong
    colormapSize, bitsPerRgb: cint

  XSetWindowAttributes = object
    backgroundPixmap: XID
    backgroundPixel: culong
    borderPixmap: XID
    borderPixel: culong
    bitGravity, winGravity, backingStore: cint
    backingPlanes, backingPixel: culong
    saveUnder: cint
    eventMask, doNotPropagateMask: clong
    overrideRedirect: cint
    colormap, cursor: XID

  XSizeHints = object
    flags: clong
    x, y, width, height: cint
    minWidth, minHeight, maxWidth, maxHeight: cint
    widthInc, heightInc: cint
    minAspect, maxAspect: array[2, cint]
    baseWidth, baseHeight: cint
    winGravity: cint

  XErrorEvent = object
    kind: cint
    display: XDisplay
    resourceId: XID
    serial: culong
    errorCode, requestCode, minorCode: uint8

const
  ClientMessage = 33.cint
  SubstructureNotifyMask = 1.clong shl 19
  SubstructureRedirectMask = 1.clong shl 20
  USPosition = 1.clong shl 0
  PPosition = 1.clong shl 2
  PMinSize = 1.clong shl 4
  PMaxSize = 1.clong shl 5
  PAspect = 1.clong shl 7
  PBaseSize = 1.clong shl 8
  NetWmMoveResizeMove = 8
  ButtonPress = 4.cint
  ButtonRelease = 5.cint
  ButtonPressMask = 1.clong shl 2
  ButtonReleaseMask = 1.clong shl 3
  EnterWindowMask = 1.clong shl 4
  LeaveWindowMask = 1.clong shl 5
  PointerMotionMask = 1.clong shl 6
  ExposureMask = 1.clong shl 15
  PopupEventMask = ButtonPressMask or ButtonReleaseMask or EnterWindowMask or
    LeaveWindowMask or PointerMotionMask or ExposureMask
  CwBackPixel = 1.culong shl 1
  CwBorderPixel = 1.culong shl 3
  CwOverrideRedirect = 1.culong shl 9
  CwEventMask = 1.culong shl 11
  CwColormap = 1.culong shl 13
  TrueColor = 4.cint
  InputOutput = 1.cuint
  XaAtom = 4.Atom
  XcLeftPtr = 68.cuint
  XcBottomLeftCorner = 12.cuint
  XcBottomRightCorner = 14.cuint
  GrabModeAsync = 1.cint
  GrabSuccess = 0.cint
  Button1to3Mask = 0x700.cuint
  ControlMask = 0x4.cuint

proc glXGetCurrentDisplay(): XDisplay {.importc, dynlib: "libGL.so.1".}
proc XInternAtom(d: XDisplay, name: cstring, onlyIfExists: cint): Atom {.importc, cdecl.}
proc XDefaultRootWindow(d: XDisplay): XID {.importc, cdecl.}
proc XSendEvent(d: XDisplay, w: XID, propagate: cint, mask: clong, ev: ptr XEventBuf): cint {.importc, cdecl.}
proc XUngrabPointer(d: XDisplay, time: culong): cint {.importc, cdecl.}
proc XGrabPointer(d: XDisplay, w: XID, ownerEvents: cint, mask: cuint,
  pointerMode, keyboardMode: cint, confineTo, cursor: XID, time: culong): cint {.importc, cdecl.}
proc XFlush(d: XDisplay): cint {.importc, cdecl.}
proc XQueryPointer(d: XDisplay, w: XID, root, child: ptr XID, rootX, rootY, winX, winY: ptr cint, mask: ptr cuint): cint {.importc, cdecl.}
proc XSetWMNormalHints(d: XDisplay, w: XID, hints: ptr XSizeHints) {.importc, cdecl.}
proc XDefaultScreen(d: XDisplay): cint {.importc, cdecl.}
proc XMatchVisualInfo(d: XDisplay, screen, depth, class: cint, vi: ptr XVisualInfo): cint {.importc, cdecl.}
proc XCreateColormap(d: XDisplay, w: XID, visual: pointer, alloc: cint): XID {.importc, cdecl.}
proc XCreateWindow(d: XDisplay, parent: XID, x, y: cint, w, h, border: cuint, depth: cint,
  class: cuint, visual: pointer, mask: culong, attrs: ptr XSetWindowAttributes): XID {.importc, cdecl.}
proc XChangeProperty(d: XDisplay, w: XID, prop, kind: Atom, format, mode: cint,
  data: pointer, n: cint): cint {.importc, cdecl.}
proc XCreateFontCursor(d: XDisplay, shape: cuint): XID {.importc, cdecl.}
proc XDefineCursor(d: XDisplay, w, cursor: XID): cint {.importc, cdecl.}
proc XMoveResizeWindow(d: XDisplay, w: XID, x, y: cint, width, height: cuint): cint {.importc, cdecl.}
proc XMapRaised(d: XDisplay, w: XID): cint {.importc, cdecl.}
proc XUnmapWindow(d: XDisplay, w: XID): cint {.importc, cdecl.}
proc XCheckWindowEvent(d: XDisplay, w: XID, mask: clong, ev: ptr XEventBuf): cint {.importc, cdecl.}
proc XSync(d: XDisplay, discardEvents: cint): cint {.importc, cdecl.}
proc XMoveWindow(d: XDisplay, w: XID, x, y: cint): cint {.importc, cdecl.}
proc XGetWindowProperty(d: XDisplay, w: XID, prop: Atom, offset, length: clong,
  delete: cint, reqType: Atom, actualType: ptr Atom, actualFormat: ptr cint,
  nitems, bytesAfter: ptr culong, data: ptr pointer): cint {.importc, cdecl.}
proc XFree(data: pointer): cint {.importc, cdecl.}
proc XSetTransientForHint(d: XDisplay, w, parent: XID): cint {.importc, cdecl.}

proc xid(window: Window): XID =
  privateAccess(Window)
  window.handle.XID

proc glXGetProcAddressARB(name: cstring): pointer {.importc, dynlib: "libGL.so.1".}

proc disableVsync(drawable: XID) =
  ## Mesa's fallback applies to the current drawable, so call this while
  ## drawable is current.
  type SwapIntervalExt = proc (d: XDisplay, drawable: XID, interval: cint) {.cdecl.}
  type SwapIntervalMesa = proc (interval: cuint): cint {.cdecl.}
  let d = glXGetCurrentDisplay()
  let ext = cast[SwapIntervalExt](glXGetProcAddressARB("glXSwapIntervalEXT"))
  if ext != nil and d != nil:
    ext(d, drawable, 0)
    return
  let mesa = cast[SwapIntervalMesa](glXGetProcAddressARB("glXSwapIntervalMESA"))
  if mesa != nil: discard mesa(0)

proc XSetErrorHandler(handler: proc (d: XDisplay, e: ptr XErrorEvent): cint {.cdecl.}): pointer {.importc, cdecl.}

var xErrors: int

proc logXError(d: XDisplay, e: ptr XErrorEvent): cint {.cdecl.} =
  ## Windy's handler raises from inside Xlib, so any X error (a BadAlloc from
  ## XWayland, say) killed the app, and NVIDIA's GLX then crashed in exit().
  ## X errors are asynchronous reports of one failed request: log and go on.
  ## A failing request can repeat every frame, so only the first few are logged.
  inc xErrors
  if xErrors <= 20:
    try:
      stderr.writeLine "X11 error ", e.errorCode, " (request ", e.requestCode,
        ".", e.minorCode, ", resource 0x", e.resourceId.int.toHex, ")",
        (if xErrors == 20: "; further X errors not logged" else: "")
    except CatchableError: discard
  0

proc initMainWindow*(window: Window) =
  ## Replaces Windy's fatal X error handler (it installs it when opening the
  ## display, before the main window exists).
  discard XSetErrorHandler(logXError)

proc disableVsync*(window: Window) =
  ## Drivers (NVIDIA in particular) default to swap interval 1 even when Windy
  ## is asked for no vsync; force 0 so swaps never block.
  disableVsync(window.xid)

proc sendWmMessage(window: Window, msgType: string, data: openArray[clong]) =
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var ev: XEventBuf
  ev.msg.kind = ClientMessage
  ev.msg.window = window.xid
  ev.msg.messageType = XInternAtom(d, msgType.cstring, 0)
  ev.msg.format = 32
  for i, v in data: ev.msg.data[i] = v
  discard XSendEvent(d, XDefaultRootWindow(d), 0,
    SubstructureNotifyMask or SubstructureRedirectMask, ev.addr)
  discard XFlush(d)

proc startWindowDrag*(window: Window) =
  ## Hands the pointer to the window manager to move the window
  ## (_NET_WM_MOVERESIZE). The WM owns the pointer until the button is released,
  ## so the release never reaches us; clear Windy's button state to match.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(d, window.xid, root.addr, child.addr, rx.addr, ry.addr,
    wx.addr, wy.addr, mask.addr)
  discard XUngrabPointer(d, 0)
  window.sendWmMessage("_NET_WM_MOVERESIZE",
    [rx.clong, ry.clong, NetWmMoveResizeMove, 1, 1])
  privateAccess(Window)
  window.state.buttonDown.excl MouseLeft

type WindowEdge* = enum
  ## Ordered as _NET_WM_MOVERESIZE's size directions.
  weTopLeft, weTop, weTopRight, weRight, weBottomRight, weBottom, weBottomLeft, weLeft

proc startWindowResize*(window: Window, edge: WindowEdge) =
  ## Hands the pointer to the window manager to resize the window from edge
  ## (for undecorated windows, which have no frame to grab).
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(d, window.xid, root.addr, child.addr, rx.addr, ry.addr,
    wx.addr, wy.addr, mask.addr)
  discard XUngrabPointer(d, 0)
  window.sendWmMessage("_NET_WM_MOVERESIZE", [rx.clong, ry.clong, edge.ord.clong, 1, 1])
  privateAccess(Window)
  window.state.buttonDown.excl MouseLeft

proc setDecorated*(window: Window, on: bool) =
  ## Shows or hides the WM's title bar and borders (_MOTIF_WM_HINTS
  ## decorations), keeping the window mapped and its content size.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  let hints = XInternAtom(d, "_MOTIF_WM_HINTS", 0)
  var v = [clong 2, 0, clong(on), 0, 0]  # flags = decorations
  discard XChangeProperty(d, window.xid, hints, hints, 32, 0, v[0].addr, 5)
  discard XFlush(d)

proc activate*(window: Window) =
  ## Raises and focuses the window. Source 2 ("pager") asks the WM to honour
  ## it despite focus-stealing prevention.
  window.sendWmMessage("_NET_ACTIVE_WINDOW", [2.clong, 0, 0])

proc frameExtents(window: Window): tuple[left, top: int32] =
  ## Width of the WM frame left of and above the content (_NET_FRAME_EXTENTS).
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var kind: Atom
  var format: cint
  var n, after: culong
  var data: pointer
  if XGetWindowProperty(d, window.xid, XInternAtom(d, "_NET_FRAME_EXTENTS", 0),
      0, 4, 0, 0, kind.addr, format.addr, n.addr, after.addr, data.addr) == 0 and
     data != nil:
    if format == 32 and n >= 4:
      let v = cast[ptr UncheckedArray[clong]](data)  # left, right, top, bottom
      result = (v[0].int32, v[2].int32)
    discard XFree(data)

proc framePos*(window: Window): IVec2 =
  ## Screen position of the window's outer (decorated) top-left corner.
  let e = window.frameExtents
  window.pos - ivec2(e.left, e.top)

proc moveFrame*(window: Window, pos: IVec2) =
  ## Places the outer top-left corner at pos. With the default NorthWest
  ## gravity the WM reads a client move as the frame's position (ICCCM 4.1.5).
  let d = glXGetCurrentDisplay()
  if d == nil: return
  discard XMoveWindow(d, window.xid, pos.x, pos.y)
  discard XFlush(d)

proc setAlwaysOnTop*(window: Window, on: bool) =
  let d = glXGetCurrentDisplay()
  if d == nil: return
  let above = XInternAtom(d, "_NET_WM_STATE_ABOVE", 0)
  window.sendWmMessage("_NET_WM_STATE", [clong(on), above.clong, 0, 1])

proc setAspectHints*(window: Window, aspect: float, chrome: IVec2, minSize: IVec2) =
  ## Asks the WM to keep (window - chrome) at the given aspect while resizing.
  ## aspect <= 0 removes the constraint.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var hints = XSizeHints(flags: PMinSize or PBaseSize,
    minWidth: minSize.x, minHeight: minSize.y,
    baseWidth: chrome.x.cint, baseHeight: chrome.y.cint)
  if aspect > 0:
    let num = cint(aspect * 10000)
    hints.flags = hints.flags or PAspect
    hints.minAspect = [num, 10000]
    hints.maxAspect = [num, 10000]
  XSetWMNormalHints(d, window.xid, hints.addr)
  discard XFlush(d)

proc setDialogFor*(window, parent: Window) =
  ## Makes window a modal dialog of parent: the WM keeps it above parent and
  ## treats it as part of the same app (no taskbar entry). Call before mapping.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  discard XSetTransientForHint(d, window.xid, parent.xid)
  var kind = XInternAtom(d, "_NET_WM_WINDOW_TYPE_DIALOG", 0).clong
  discard XChangeProperty(d, window.xid, XInternAtom(d, "_NET_WM_WINDOW_TYPE", 0),
    XaAtom, 32, 0, kind.addr, 1)
  var state = XInternAtom(d, "_NET_WM_STATE_MODAL", 0).clong
  discard XChangeProperty(d, window.xid, XInternAtom(d, "_NET_WM_STATE", 0),
    XaAtom, 32, 0, state.addr, 1)

proc placeDialog*(window: Window, pos, size: IVec2) =
  ## Fixes the window's size and puts its outer top-left corner at pos. The
  ## position hints make the WM use it instead of its own placement; call
  ## while the window is unmapped.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var hints = XSizeHints(flags: USPosition or PPosition or PMinSize or PMaxSize,
    x: pos.x, y: pos.y, width: size.x, height: size.y,
    minWidth: size.x, minHeight: size.y, maxWidth: size.x, maxHeight: size.y)
  XSetWMNormalHints(d, window.xid, hints.addr)
  discard XMoveResizeWindow(d, window.xid, pos.x, pos.y, size.x.cuint, size.y.cuint)
  discard XFlush(d)

type XRRMonitorInfo = object
  name: Atom
  primary, automatic: cint
  noutput: cint
  x, y, width, height: cint
  mwidth, mheight: cint
  outputs: pointer

proc XRRGetMonitors(d: XDisplay, w: XID, getActive: cint, n: ptr cint): ptr UncheckedArray[XRRMonitorInfo] {.importc, cdecl, dynlib: "libXrandr.so.2".}
proc XRRFreeMonitors(m: ptr UncheckedArray[XRRMonitorInfo]) {.importc, cdecl, dynlib: "libXrandr.so.2".}

proc monitorAt*(point: IVec2): tuple[pos, size: IVec2] =
  ## Screen rect of the monitor holding point, else the primary one
  ## (falls back to 1920x1080 at the origin).
  result = (ivec2(0, 0), ivec2(1920, 1080))
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var n: cint
  let mons = XRRGetMonitors(d, XDefaultRootWindow(d), 1, n.addr)
  if mons == nil: return
  for i in 0 ..< n:
    let m = mons[i]
    let r = (ivec2(m.x, m.y), ivec2(m.width, m.height))
    if i == 0 or m.primary != 0:
      result = r
    if point.x >= m.x and point.x < m.x + m.width and
       point.y >= m.y and point.y < m.y + m.height:
      result = r
      break
  XRRFreeMonitors(mons)

proc monitorSize*(window: Window): IVec2 =
  ## Size of the monitor that holds the window centre.
  monitorAt(window.pos + window.size div 2).size

proc pointerPos*(window: Window): tuple[screen, local: IVec2] =
  ## Pointer position on screen and relative to the window's content.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(d, window.xid, root.addr, child.addr, rx.addr, ry.addr,
    wx.addr, wy.addr, mask.addr)
  (ivec2(rx, ry), ivec2(wx, wy))

proc pointerButtonsDown*(): bool =
  ## Whether the left, middle or right mouse button is held anywhere.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(d, XDefaultRootWindow(d), root.addr, child.addr, rx.addr,
    ry.addr, wx.addr, wy.addr, mask.addr)
  (mask and Button1to3Mask) != 0

proc ctrlHeld*(): bool =
  ## Whether Ctrl is held, even while another window has the keyboard (the
  ## server's modifier state; on Xwayland that needs KWin's "Legacy X11 App
  ## Support" to pass modifiers on, which it does by default).
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var root, child: XID
  var rx, ry, wx, wy: cint
  var mask: cuint
  discard XQueryPointer(d, XDefaultRootWindow(d), root.addr, child.addr, rx.addr,
    ry.addr, wx.addr, wy.addr, mask.addr)
  (mask and ControlMask) != 0

var grabCursor: XID

proc grabPointer*(window: Window): bool =
  ## Actively grabs the pointer for window, as a toolkit does while a menu is
  ## open: every press the X server sees, on any window, is reported to it
  ## (relative to its content) and never reaches the window underneath.
  ## Native Wayland surfaces are out of Xwayland's reach; clicks there are
  ## caught as focus loss instead.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  if grabCursor == 0: grabCursor = XCreateFontCursor(d, XcLeftPtr)
  result = XGrabPointer(d, window.xid, 0,
    cuint(ButtonPressMask or ButtonReleaseMask or PointerMotionMask),
    GrabModeAsync, GrabModeAsync, 0, grabCursor, 0) == GrabSuccess
  discard XFlush(d)

proc ungrabPointer*() =
  let d = glXGetCurrentDisplay()
  if d == nil: return
  discard XUngrabPointer(d, 0)
  discard XFlush(d)

proc XcursorLibraryLoadCursor(d: XDisplay, name: cstring): XID {.importc, cdecl, dynlib: "libXcursor.so(|.1)".}

var diagonalCursors: array[bool, XID]

proc setDiagonalCursor*(window: Window, nwse: bool) =
  ## A diagonal resize cursor from the cursor theme: nwse runs top-left to
  ## bottom-right, otherwise top-right to bottom-left. Set behind Windy's back;
  ## its next cursor= replaces it.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  if diagonalCursors[nwse] == 0:
    let names = if nwse: ["nwse-resize", "size_fdiag", "bd_double_arrow"]
                else: ["nesw-resize", "size_bdiag", "fd_double_arrow"]
    for name in names:
      diagonalCursors[nwse] = XcursorLibraryLoadCursor(d, name.cstring)
      if diagonalCursors[nwse] != 0: break
    if diagonalCursors[nwse] == 0:
      diagonalCursors[nwse] = XCreateFontCursor(d, if nwse: XcBottomRightCorner else: XcBottomLeftCorner)
  discard XDefineCursor(d, window.xid, diagonalCursors[nwse])
  discard XFlush(d)

proc clearDiagonalCursor*(window: Window) =
  ## Nothing to undo: Windy's cursor= redefines the cursor itself.
  discard

var hiddenCursorImage: Image

proc hiddenCursor*(): Cursor =
  if hiddenCursorImage == nil:
    hiddenCursorImage = newImage(1, 1)
  Cursor(kind: CustomCursor, image: hiddenCursorImage, hotspot: ivec2(0, 0))

# --- popup windows ------------------------------------------------------------

type
  PopupWindow* = ref object
    ## Undecorated override-redirect window (like a toolkit's menu popup): the
    ## WM neither frames, focuses nor places it, so it can extend past the main
    ## window. It is drawn with the main window's GL context, which works
    ## because both use the same visual.
    xid: XID
    pos, size*: IVec2
    mapped: bool

  PopupInput* = object
    activity*: bool          ## any pointer or expose event arrived
    leftPressed*, leftReleased*, anyPressed*: bool

type PutState = object
  gc: pointer
  size: IVec2
  hash: Hash
  at: float

var putStates: Table[XID, PutState]  ## see putPixelsOn

proc newPopupWindow*(background: ColorRGBX): PopupWindow =
  let d = glXGetCurrentDisplay()
  var vi: XVisualInfo
  # Same visual Windy uses for its windows (see putPixelsOn).
  discard XMatchVisualInfo(d, XDefaultScreen(d), 24, TrueColor, vi.addr)
  let root = XDefaultRootWindow(d)
  let c = background  # opaque, so premultiplied == straight
  var attrs = XSetWindowAttributes(
    backgroundPixel: (c.r.culong shl 16) or (c.g.culong shl 8) or c.b.culong,
    overrideRedirect: 1,
    eventMask: PopupEventMask,
    colormap: XCreateColormap(d, root, vi.visual, 0))
  result = PopupWindow(pos: ivec2(-1, -1))
  result.xid = XCreateWindow(d, root, 0, 0, 1, 1, 0, vi.depth, InputOutput, vi.visual,
    CwBackPixel or CwBorderPixel or CwOverrideRedirect or CwEventMask or CwColormap,
    attrs.addr)
  var kind = XInternAtom(d, "_NET_WM_WINDOW_TYPE_POPUP_MENU", 0).clong
  discard XChangeProperty(d, result.xid, XInternAtom(d, "_NET_WM_WINDOW_TYPE", 0),
    XaAtom, 32, 0, kind.addr, 1)
  discard XDefineCursor(d, result.xid, XCreateFontCursor(d, XcLeftPtr))

proc show*(p: PopupWindow, pos, size: IVec2) =
  let d = glXGetCurrentDisplay()
  if pos != p.pos or size != p.size:
    p.pos = pos
    p.size = size
    discard XMoveResizeWindow(d, p.xid, pos.x, pos.y, size.x.cuint, size.y.cuint)
  if not p.mapped:
    p.mapped = true
    discard XMapRaised(d, p.xid)
    putStates.del p.xid  # a fresh mapping starts out blank
    discard XSync(d, 0)

proc hide*(p: PopupWindow) =
  if not p.mapped: return
  p.mapped = false
  let d = glXGetCurrentDisplay()
  discard XUnmapWindow(d, p.xid)
  discard XFlush(d)

proc XCreateGC(d: XDisplay, drawable: XID, mask: culong, values: pointer): pointer {.importc, cdecl.}
proc XCreateImage(d: XDisplay, visual: pointer, depth: cuint, format, offset: cint, data: pointer,
                  w, h: cuint, pad, bytesPerLine: cint): pointer {.importc, cdecl.}
proc XPutImage(d: XDisplay, drawable: XID, gc, image: pointer, srcX, srcY, dstX, dstY: cint,
               w, h: cuint): cint {.importc, cdecl.}

proc putPixelsOn(xid: XID, size: IVec2, bgra: openArray[uint8]) =
  ## Shows a size big image (BGRA, top row first) in window xid by core X
  ## drawing. Menus and dialogs are drawn this way rather than by pointing
  ## the GL context at their windows: that makes the driver allocate GL
  ## buffers for each, and with VRAM full (a game running) NVIDIA fails it
  ## with BadAlloc and leaves the context dead. Unchanged images are put
  ## again only now and then, in case the server dropped the contents.
  if size.x <= 0 or size.y <= 0 or bgra.len < size.x * size.y * 4: return
  let d = glXGetCurrentDisplay()
  if d == nil: return
  let st = putStates.mgetOrPut(xid, PutState()).addr
  let h = hash(bgra.toOpenArray(0, size.x * size.y * 4 - 1))
  let t = epochTime()
  if st.gc != nil and st.size == size and st.hash == h and t - st.at < 0.25: return
  if st.gc == nil: st.gc = XCreateGC(d, xid, 0, nil)
  (st.size, st.hash, st.at) = (size, h, t)
  var vi: XVisualInfo  # the visual Windy and newPopupWindow use
  discard XMatchVisualInfo(d, XDefaultScreen(d), 24, TrueColor, vi.addr)
  const ZPixmap = 2.cint
  let img = XCreateImage(d, vi.visual, 24, ZPixmap, 0, bgra[0].unsafeAddr,
    size.x.cuint, size.y.cuint, 32, size.x * 4)
  if img == nil: return
  discard XPutImage(d, xid, st.gc, img, 0, 0, 0, 0, size.x.cuint, size.y.cuint)
  discard XFlush(d)
  discard XFree(img)  # the struct only; the pixels stay the caller's

proc putPixels*(p: PopupWindow, bgra: openArray[uint8]) =
  ## Shows a p.size image (BGRA, top row first) in the popup.
  putPixelsOn(p.xid, p.size, bgra)

proc putPixels*(window: Window, size: IVec2, bgra: openArray[uint8]) =
  ## Shows a size big image (BGRA, top row first) in the window.
  putPixelsOn(window.xid, size, bgra)

proc pollInput*(popups: openArray[PopupWindow], input: var PopupInput) =
  ## Drains the popups' X events (Windy only reads its own windows' events)
  ## and accumulates them into input.
  let d = glXGetCurrentDisplay()
  if d == nil: return
  var ev: XEventBuf
  for p in popups:
    while XCheckWindowEvent(d, p.xid, PopupEventMask, ev.addr) != 0:
      input.activity = true
      let b = ev.btn.button
      if ev.btn.kind == ButtonPress and b in 1'u32 .. 3'u32:
        input.anyPressed = true
        if b == 1: input.leftPressed = true
      elif ev.btn.kind == ButtonRelease and b == 1:
        input.leftReleased = true
