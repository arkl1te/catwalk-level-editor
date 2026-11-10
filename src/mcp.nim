## MCP (Model Context Protocol) transport. Catwalk serves JSON-RPC on
## http://127.0.0.1:<port>/mcp from a thread of its own; every request is handed
## to the main loop (mcptools.nim), so tools never run in the middle of a frame.
## `catwalk --mcp` is what Claude Code starts: a stdio bridge to that server with
## no window, which knows the tool list by itself, so a Claude session starting
## up doesn't open the editor.

import std/[json, locks, nativesockets, net, os, strutils, times]
when defined(windows):
  import std/[osproc, winlean]
  import jobs
else:
  from std/posix import EADDRINUSE, EACCES

const
  DefaultMcpPort* = 47350
  McpPath = "/mcp"
  ProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  MaxBody = 16 * 1024 * 1024
  ReplyTimeout = 60.0         ## Seconds the main loop has to answer.
  BridgeTimeout = 120_000     ## ms; longer than ReplyTimeout, so the server's error wins.
  LaunchTimeout = 30.0        ## Seconds start_catwalk waits for the server.
  Instructions = "Catwalk is a level editor for the game Oni. World units are Oni's, " &
    "Y is up. Start with status. Every edit is one undo step, and nothing reaches the " &
    "disk until save or build. Faces are ordered counter-clockwise from their front. " &
    "Objects are named by tag (CHAR, FLAG, ...) and id."

type McpError* = object of CatchableError   ## A tool's failure, shown to the caller.

proc tool(name, description: string, properties: JsonNode = newJObject(),
          required: seq[string] = @[]): JsonNode =
  %*{"name": name, "description": description,
     "inputSchema": {"type": "object", "properties": properties, "required": required}}

proc mcpTools*(): JsonNode =
  let vec = %*{"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}
  let page = %*{"limit": {"type": "integer"}, "offset": {"type": "integer"}}
  var faces = copy(page)
  faces["pieces"] = %*{"type": "array", "items": {"type": "integer"}}
  faces["min"] = vec
  faces["max"] = vec
  faces["texture"] = %*{"type": "string"}
  faces["flag"] = %*{"type": "string", "description": "Only faces with this gunk flag, e.g. Stairs"}
  var objects = copy(page)
  objects["tag"] = %*{"type": "string"}
  objects["selected"] = %*{"type": "boolean"}
  var pieces = copy(page)
  pieces["min"] = vec
  pieces["max"] = vec
  result = %*[
    tool("start_catwalk", "Opens Catwalk with its MCP server on, if no server is answering. " &
      "If Catwalk is open with its server off, this opens a second window.",
      %*{"project": {"type": "string", "description": "Project folder to open"}}),
    tool("status", "The open project, unsaved changes, running job, selection, tool, views and issues."),
    tool("log", "The latest Console lines.", %*{"lines": {"type": "integer"}}),
    tool("list_projects", "Projects in the projects folder, and the game levels that can be imported."),
    tool("open_project", "Opens a project (folder name or path). Refused with unsaved changes.",
      %*{"path": {"type": "string"}}, @["path"]),
    tool("import_level", "Imports a game level as a new project (a job: watch status).",
      %*{"level": {"type": "integer"}, "name": {"type": "string"}}, @["level", "name"]),
    tool("new_level", "Creates an empty level project (a job: watch status).",
      %*{"name": {"type": "string"}}, @["name"]),
    tool("save", "Saves the project."),
    tool("build", "Saves and builds into CustomLevels (a job: watch status)."),
    tool("undo", "Undoes the last step."),
    tool("redo", "Redoes the last undone step."),
    tool("list_menu", "Every menu item, with its path, shortcut and state."),
    tool("run_menu", "Runs a menu item by path (\"View > Render > Sky\") or label. " &
      "Items ending in ... open a dialog on the user's screen.",
      %*{"path": {"type": "string"}}, @["path"]),
    tool("list_objects", "Level objects: tag, id, name, position, rotation.", objects),
    tool("get_object", "An object's editable fields.",
      %*{"tag": {"type": "string"}, "id": {"type": "integer"}}, @["tag", "id"]),
    tool("create_object", "Creates an object and selects it; list_menu's Create entries and " &
      "status.object_types give the tags.",
      %*{"tag": {"type": "string"}, "pos": vec, "rot": vec}, @["tag", "pos"]),
    tool("set_object", "Changes an object's position, rotation (degrees) and fields, as one undo step. " &
      "Field keys are get_object's.",
      %*{"tag": {"type": "string"}, "id": {"type": "integer"}, "pos": vec, "rot": vec,
         "fields": {"type": "object"}}, @["tag", "id"]),
    tool("list_pieces", "Geometry pieces overlapping a box: bounds, face count, textures.", pieces),
    tool("get_faces", "Faces with their corners, normal, texture and flags, filtered by piece, " &
      "box, texture or flag.", faces),
    tool("list_textures", "Texture names usable on faces.", %*{"filter": {"type": "string"}}),
    tool("create_brush", "Creates a convex brush from a box (min, max) or the hull of points, " &
      "and selects it. The texture defaults to the current one.",
      %*{"min": vec, "max": vec, "points": {"type": "array", "items": vec},
         "texture": {"type": "string"}}),
    tool("select", "Selects objects, pieces and faces.",
      %*{"objects": {"type": "array", "items": {"type": "object", "properties":
           {"tag": {"type": "string"}, "id": {"type": "integer"}}}},
         "pieces": {"type": "array", "items": {"type": "integer"}},
         "faces": {"type": "array", "items": {"type": "integer"}},
         "add": {"type": "boolean", "description": "Keep the current selection"}}),
    tool("move_selection", "Moves the selection by an offset.", %*{"offset": vec}, @["offset"]),
    tool("set_camera", "Sets a view's camera. 3D: pos, then look_at or yaw and pitch (degrees; " &
      "yaw 0 looks toward -Z). 2D: center and zoom (pixels per unit). kind: 3D, Top, Front or Side.",
      %*{"view": {"type": "integer"}, "kind": {"type": "string"}, "pos": vec, "look_at": vec,
         "yaw": {"type": "number"}, "pitch": {"type": "number"},
         "center": {"type": "array", "items": {"type": "number"}}, "zoom": {"type": "number"}}),
    tool("screenshot", "Images of the shown viewports as the user sees them, or of one view. " &
      "path also saves them at full size.",
      %*{"view": {"type": "integer"}, "path": {"type": "string"},
         "max_size": {"type": "integer", "description": "Longest side of the returned images (default 1280)"}})]

proc rpcResult*(id, res: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": res}

proc rpcError*(id: JsonNode, code: int, msg: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}}

proc toolText*(id: JsonNode, text: string, isError = false): JsonNode =
  rpcResult(id, %*{"content": [{"type": "text", "text": text}], "isError": isError})

proc answerProtocol*(req: JsonNode, version: string): (bool, JsonNode) =
  ## The requests that need no editor. (true, nil): a notification, no reply.
  let id = req{"id"}
  let meth = req{"method"}.getStr
  if meth.startsWith("notifications/"): return (true, nil)
  case meth
  of "initialize":
    let asked = req{"params"}{"protocolVersion"}.getStr
    (true, rpcResult(id, %*{
      "protocolVersion": (if asked in ProtocolVersions: asked else: ProtocolVersions[0]),
      "capabilities": {"tools": {}},
      "serverInfo": {"name": "catwalk", "version": version},
      "instructions": Instructions}))
  of "ping": (true, rpcResult(id, newJObject()))
  of "tools/list": (true, rpcResult(id, %*{"tools": mcpTools()}))
  else: (false, nil)

# --- the server thread --------------------------------------------------------------------

var
  mcpLock: Lock
  lockReady = false
  inbox, outbox: string       ## Moved across under mcpLock, so no string is ever shared.
  inboxId, outboxId, nextId: int
  stopServer: bool
  serverThread: Thread[SocketHandle]
  serverOn = false
  servingPort = 0

proc recvSome(s: Socket, timeout: int): string =
  ## What has arrived, up to 64 KB ("" once closed). Net's recv with a timeout
  ## waits for the whole size.
  var ready = @[s.getFd]
  if selectRead(ready, timeout) <= 0: raise newException(TimeoutError, "Timed out")
  result = newString(65536)
  let got = s.recv(result[0].addr, result.len)
  if got < 0: raiseOSError(osLastError())
  result.setLen got

proc stopping(): bool =
  withLock mcpLock: result = stopServer

proc exchange(body: string): string =
  ## Hands body to the main loop and waits for its answer.
  var id: int
  withLock mcpLock:
    inc nextId
    id = nextId
    inboxId = id
    inbox = body
  let deadline = epochTime() + ReplyTimeout
  while epochTime() < deadline and not stopping():
    withLock mcpLock:
      if outboxId == id:
        outboxId = 0
        return move outbox
    sleep(2)
  withLock mcpLock:
    if inboxId == id: inboxId = 0
  ""

proc respond(c: Socket, status, body: string) =
  c.send("HTTP/1.1 " & status & "\r\nContent-Type: application/json\r\n" &
         "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" & body)

proc localHost(value: string): bool =
  ## Host and Origin checks: a web page must not reach the editor (DNS rebinding).
  var h = value.toLowerAscii
  if h.startsWith("http://"): h = h[7 .. ^1]
  for name in ["localhost", "127.0.0.1", "[::1]"]:
    if h == name or h.startsWith(name & ":"): return true

proc serveClient(c: Socket) =
  var data = ""
  var headerEnd = -1
  let deadline = epochTime() + 5
  while headerEnd < 0:
    if epochTime() > deadline or data.len > MaxBody: return
    let got = c.recvSome(1000)
    if got.len == 0: return
    data.add got
    headerEnd = data.find("\r\n\r\n")
  let lines = data[0 ..< headerEnd].split("\r\n")
  let request = lines[0].splitWhitespace
  if request.len < 2: return
  var host, origin, contentType = ""
  var length = 0
  for l in lines[1 .. ^1]:
    let colon = l.find(':')
    if colon < 0: continue
    let value = l[colon + 1 .. ^1].strip
    case l[0 ..< colon].toLowerAscii
    of "host": host = value
    of "origin": origin = value
    of "content-type": contentType = value.toLowerAscii
    of "content-length":
      try: length = parseInt(value)
      except ValueError: discard
    else: discard
  if not localHost(host) or (origin.len > 0 and not localHost(origin)):
    c.respond("403 Forbidden", "")
  elif request[1].split('?')[0] != McpPath:
    c.respond("404 Not Found", "")
  elif request[0] != "POST":
    c.respond("405 Method Not Allowed", "")   # No server-sent events: replies come with the POST.
  elif not contentType.startsWith("application/json"):
    c.respond("415 Unsupported Media Type", "")
  elif length <= 0 or length > MaxBody:
    c.respond("413 Content Too Large", "")
  else:
    var body = data[headerEnd + 4 .. ^1]
    while body.len < length:
      if epochTime() > deadline: return
      let got = c.recvSome(1000)
      if got.len == 0: return
      body.add got
    let reply = exchange(body)
    if reply == "\0": c.respond("202 Accepted", "")
    elif reply.len > 0: c.respond("200 OK", reply)
    else:
      var id = newJNull()
      try: id = parseJson(body){"id"}
      except CatchableError: discard
      c.respond("200 OK", $rpcError(id, -32000,
        if stopping(): "The MCP server stopped"
        else: "Catwalk's main loop didn't answer: the window may be blocked"))

proc serve(fd: SocketHandle) {.thread.} =
  {.cast(gcsafe).}:
    let server = newSocket(fd, AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = false)
    while not stopping():
      var ready = @[fd]
      if selectRead(ready, 200) <= 0: continue
      var c: Socket
      try:
        server.accept(c)
        try: c.serveClient()
        except CatchableError: discard
        c.close()
      except CatchableError: discard
    server.close()

proc portBlocked*(e: ref OSError): bool =
  ## startMcp failed because of the port itself: taken, or not allowed.
  when defined(windows): e.errorCode in [10048'i32, 10013]
  else: e.errorCode in [EADDRINUSE, EACCES]

proc mcpRunning*(): bool = serverOn
proc mcpServingPort*(): int = servingPort

proc startMcp*(port: int) =
  ## Raises OSError when the port can't be opened.
  if serverOn: return
  if not lockReady:
    initLock(mcpLock)
    lockReady = true
  let s = newSocket(buffered = false)
  try:
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(port), "127.0.0.1")
    s.listen()
  except OSError:
    s.close()
    raise
  stopServer = false
  inboxId = 0
  outboxId = 0
  servingPort = port
  serverOn = true
  createThread(serverThread, serve, s.getFd)

proc stopMcp*() =
  if not serverOn: return
  withLock mcpLock: stopServer = true
  joinThread(serverThread)
  serverOn = false

proc takeMcpRequest*(id: var int, body: var string): bool =
  ## The request waiting for the main loop, if any.
  if not serverOn: return false
  withLock mcpLock:
    if inboxId != 0:
      id = inboxId
      inboxId = 0
      body = move inbox
      result = true

proc answerMcp*(id: int, reply: string) =
  ## reply is "\0" for a notification. Answers nobody after the thread gave up.
  withLock mcpLock:
    outbox = reply
    outboxId = id

# --- the stdio bridge ---------------------------------------------------------------------

proc post(port: int, body: string): string =
  ## One request to the running editor; its reply body ("" for a notification).
  let s = newSocket(buffered = false)
  defer: s.close()
  s.connect("127.0.0.1", Port(port), 2000)
  s.send("POST " & McpPath & " HTTP/1.1\r\nHost: 127.0.0.1:" & $port &
         "\r\nContent-Type: application/json\r\nContent-Length: " & $body.len &
         "\r\nConnection: close\r\n\r\n" & body)
  var data = ""
  while true:
    let got = s.recvSome(BridgeTimeout)
    if got.len == 0: break
    data.add got
  let at = data.find("\r\n\r\n")
  if at < 0: raise newException(IOError, "Bad reply from Catwalk")
  if not data.startsWith("HTTP/1.1 2"): raise newException(IOError, data.splitLines[0])
  data[at + 4 .. ^1]

proc serverUp(port: int): bool =
  try:
    discard post(port, $(%*{"jsonrpc": "2.0", "id": 0, "method": "ping"}))
    true
  except CatchableError: false

proc startCatwalk(port: int, project: string): string =
  if serverUp(port): return "Catwalk is already running with its MCP server on. Use open_project."
  # Its stdout must not reach this process's: that's the MCP stream.
  when defined(windows):
    # Nor may it inherit the stream's pipes: they would stay open after this
    # bridge exits, and Claude Code would never see it end.
    for h in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE]:
      discard setHandleInformation(getStdHandle(h), HANDLE_FLAG_INHERIT, 0)
    var args = @[getAppFilename(), "--mcp-server"]
    if project.len > 0: args.add project
    discard startCmd(args, "<NUL >NUL 2>&1")
  else:
    var cmd = quoteShell(getAppFilename()) & " --mcp-server"
    if project.len > 0: cmd.add " " & quoteShell(project)
    discard execShellCmd("setsid " & cmd & " </dev/null >/dev/null 2>&1 &")
  let deadline = epochTime() + LaunchTimeout
  while epochTime() < deadline:
    if serverUp(port): return "Catwalk is running."
    sleep(100)
  raise newException(McpError, "Catwalk didn't start its MCP server in time")

proc runBridge*(port: int, version: string) =
  ## `catwalk --mcp`: MCP over stdin and stdout, until stdin closes.
  template emit(j: JsonNode) =
    stdout.writeLine($j)
    stdout.flushFile()
  var line = ""
  while stdin.readLine(line):
    if line.strip.len == 0: continue
    var req: JsonNode
    try: req = parseJson(line)
    except CatchableError:
      emit rpcError(newJNull(), -32700, "Parse error")
      continue
    let id = req{"id"}
    let (known, reply) = answerProtocol(req, version)
    if known:
      if reply != nil: emit reply
    elif req{"method"}.getStr == "tools/call" and req{"params"}{"name"}.getStr == "start_catwalk":
      try: emit toolText(id, startCatwalk(port, req{"params"}{"arguments"}{"project"}.getStr))
      except CatchableError as e: emit toolText(id, e.msg, true)
    else:
      try:
        let body = post(port, line)
        if body.len > 0: stdout.writeLine(body); stdout.flushFile()
      except CatchableError:
        if id != nil:
          emit toolText(id, "Catwalk isn't running with its MCP server on. Call start_catwalk, " &
                           "or turn on Settings > General > MCP Server in Catwalk.", true)
