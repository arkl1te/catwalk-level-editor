## The panel layout (included by appstate.nim): a tree of splits whose leaves
## are stacks of tabbed panels. Any panel's tab can be dragged onto another
## stack (tabbing it there) or onto a stack's edge (splitting it). panels.nim
## draws it.

const
  DockTabH* = 28'f32                ## A panel stack's tab bar.
  MinPanel = 60'f32                 ## Smallest side a split leaves a kid.

proc dockLeaf(tabs: varargs[PanelKind]): DockNode = DockNode(tabs: @tabs)

proc dockSplit(row: bool, frac: float32, a, b: DockNode): DockNode =
  DockNode(row: row, frac: frac, kids: @[a, b])

proc defaultDock*(): DockNode =
  ## Like TrenchBroom's: the views with Console / Issues under them, the
  ## inspector at the right with the browsers below it.
  dockSplit(true, 0.78,
    dockSplit(false, 0.82, dockLeaf(pkViewport), dockLeaf(pkConsole, pkIssues)),
    dockSplit(false, 0.55, dockLeaf(pkProperties, pkMap, pkFiles, pkClasses),
              dockLeaf(pkEntityBrowser, pkTextureBrowser)))

proc isLeaf*(n: DockNode): bool = n.kids.len == 0

proc leaves*(n: DockNode): seq[DockNode] =
  if n == nil: return
  if n.isLeaf: return @[n]
  for k in n.kids: result.add k.leaves

proc leafOf*(n: DockNode, kind: PanelKind): DockNode =
  for l in n.leaves:
    if kind in l.tabs: return l

proc activeTab*(n: DockNode): PanelKind = n.tabs[clamp(n.active, 0, n.tabs.high)]

proc panelShown*(a: App, kind: PanelKind): bool =
  ## kind is in the layout and the front tab of its stack.
  let l = a.dock.leafOf(kind)
  l != nil and l.activeTab == kind

proc prune(n: DockNode): DockNode =
  ## n without its empty stacks (a split with one kid left becomes that kid).
  if n.isLeaf: return (if n.tabs.len == 0: nil else: n)
  let a = prune(n.kids[0])
  let b = prune(n.kids[1])
  if a == nil: return b
  if b == nil: return a
  n.kids = @[a, b]
  n

proc takeTab(a: App, kind: PanelKind) =
  ## Takes kind out of its stack (the stack goes once it's empty).
  let l = a.dock.leafOf(kind)
  if l == nil: return
  let i = l.tabs.find(kind)
  let wasActive = l.active == i
  l.tabs.delete i
  if l.active > i or (wasActive and l.active >= l.tabs.len): l.active = max(0, l.active - 1)
  a.dock = prune(a.dock)

proc splitNode(n: DockNode, kind: PanelKind, zone: DockZone) =
  ## n (a stack, or a whole subtree) shares its rect with a new stack of kind
  ## on the zone's side.
  let old = DockNode()
  old[] = n[]
  let fresh = dockLeaf(kind)
  n.tabs = @[]
  n.active = 0
  n.row = zone in {dzLeft, dzRight}
  n.kids = if zone in {dzLeft, dzTop}: @[fresh, old] else: @[old, fresh]
  # The new stack takes a third of a whole side, half of a single stack.
  let share = if old.isLeaf: 0.5'f32 else: 0.3'f32
  n.frac = if zone in {dzLeft, dzTop}: share else: 1 - share

proc dropPanel*(a: App, kind: PanelKind, target: DockNode, zone: DockZone, index: int) =
  ## Moves kind onto target: into its tabs at index (dzTabs), or beside it.
  let src = a.dock.leafOf(kind)
  if src == nil or target == nil or zone == dzNone: return
  if src == target and src.tabs.len == 1: return   # onto itself
  if zone == dzTabs:
    var at = index
    if src == target and src.tabs.find(kind) < at: dec at
    a.takeTab(kind)
    at = clamp(at, 0, target.tabs.len)
    target.tabs.insert(kind, at)
    target.active = at
  else:
    # A side of the whole layout: the root may change when the panel leaves.
    let toRoot = target == a.dock
    a.takeTab(kind)
    (if toRoot: a.dock else: target).splitNode(kind, zone)

proc showPanel*(a: App, kind: PanelKind) =
  ## Brings kind to the front of its stack; a closed panel comes back next to
  ## the panels it's usually with.
  let l = a.dock.leafOf(kind)
  if l != nil:
    l.active = l.tabs.find(kind)
    return
  let near = case kind
    of pkConsole: @[pkIssues]
    of pkIssues: @[pkConsole]
    of pkEntityBrowser: @[pkTextureBrowser, pkProperties, pkMap, pkFiles]
    of pkTextureBrowser: @[pkEntityBrowser, pkProperties, pkMap, pkFiles]
    of pkClasses: @[pkFiles, pkMap, pkProperties]
    of pkScripts: @[]
    else: @[pkProperties, pkClasses, pkMap, pkFiles, pkEntityBrowser, pkTextureBrowser]
  for k in near:
    let t = a.dock.leafOf(k)
    if t != nil:
      t.tabs.add kind
      t.active = t.tabs.high
      return
  if kind in {pkConsole, pkIssues}: a.dock.leafOf(pkViewport).splitNode(kind, dzBottom)
  elif kind == pkScripts:
    # Beside the views, so they stay in sight while Ctrl+click jumps to objects.
    let v = a.dock.leafOf(pkViewport)
    v.splitNode(kind, dzRight)
    v.frac = 0.55
  else: a.dock.splitNode(kind, dzRight)

proc hidePanel*(a: App, kind: PanelKind) =
  if kind != pkViewport: a.takeTab(kind)

proc togglePanel*(a: App, kind: PanelKind) =
  if a.panelShown(kind): a.hidePanel(kind) else: a.showPanel(kind)

proc layoutDock*(n: DockNode, r: Rect) =
  ## Gives every node its rect for this frame.
  n.r = r
  if n.isLeaf: return
  let total = (if n.row: r.w else: r.h) - SplitW
  let lo = min(MinPanel, total / 2)
  let first = clamp(round(total * n.frac), lo, max(lo, total - lo))
  if n.row:
    n.kids[0].layoutDock(rect(r.x, r.y, first, r.h))
    n.divider = rect(r.x + first, r.y, SplitW, r.h)
    n.kids[1].layoutDock(rect(r.x + first + SplitW, r.y, r.w - first - SplitW, r.h))
  else:
    n.kids[0].layoutDock(rect(r.x, r.y, r.w, first))
    n.divider = rect(r.x, r.y + first, r.w, SplitW)
    n.kids[1].layoutDock(rect(r.x, r.y + first + SplitW, r.w, r.h - first - SplitW))

proc toJson*(n: DockNode): JsonNode =
  if n.isLeaf:
    var tabs = newJArray()
    for t in n.tabs: tabs.add %($t)
    return %*{"tabs": tabs, "active": n.active}
  %*{"row": n.row, "frac": n.frac, "kids": [n.kids[0].toJson, n.kids[1].toJson]}

proc dockFromJson*(j: JsonNode): DockNode =
  ## The saved layout, or the default one if it's missing or broken (every
  ## panel at most once, the Viewport always there).
  var seen: set[PanelKind]
  var bad = false
  proc node(j: JsonNode): DockNode =
    if j == nil or j.kind != JObject:
      bad = true
      return
    if j.hasKey("tabs"):
      result = DockNode(active: j{"active"}.getInt)
      if j["tabs"].kind != JArray: bad = true
      else:
        for t in j["tabs"]:
          for k in PanelKind:
            if $k == t.getStr:
              if k in seen: bad = true
              seen.incl k
              result.tabs.add k
      if result.tabs.len == 0: bad = true
      result.active = clamp(result.active, 0, max(0, result.tabs.high))
    else:
      let kids = j{"kids"}
      if kids == nil or kids.kind != JArray or kids.len != 2:
        bad = true
        return
      result = dockSplit(j{"row"}.getBool, clamp(j{"frac"}.getFloat(0.5), 0.02, 0.98).float32,
                         node(kids[0]), node(kids[1]))
      if result.kids[0] == nil or result.kids[1] == nil: bad = true
  result = node(j)
  if bad or result == nil or pkViewport notin seen: result = defaultDock()
