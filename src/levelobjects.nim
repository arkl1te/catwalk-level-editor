## Level objects (the BINACJBO*.xml files OniSplit extracts). Each object keeps
## its original XML element, so fields the editor doesn't know about survive a
## save unchanged; position and rotation are mirrored into typed fields.

import std/[xmlparser, xmltree, strutils, os, tables, algorithm, strformat, strtabs]
import vmath

type
  ObjectFile* = ref object
    path*: string
    root*: XmlNode
    list*: XmlNode          ## The <Objects> element.
    dirty*: bool

  LevelObject* = ref object
    tag*: string            ## CHAR, FURN, FLAG, ...
    id*: int
    node*: XmlNode
    file*: ObjectFile
    pos*: Vec3
    rot*: Vec3              ## Degrees, as in the XML.
    hidden*: bool
    selected*: bool

  ObjectField* = object
    path*: string           ## e.g. "OSD/Scripts/Spawn"
    value*: string
    attr*: string           ## Non-empty for an attribute value.

const
  BOM = "\xEF\xBB\xBF"

  TypeNames* = {
    "CHAR": "Character", "CONS": "Console", "DOOR": "Door", "FLAG": "Flag",
    "FURN": "Furniture", "NEUT": "Neutral", "PART": "Particle", "PATR": "Patrol path",
    "PWRU": "Power-up", "SNDG": "Sound", "TRGV": "Trigger volume", "TRIG": "Trigger",
    "TURR": "Turret", "WEAP": "Weapon"}.toTable

proc typeName*(tag: string): string = TypeNames.getOrDefault(tag, tag)

proc xpath*(n: XmlNode, path: string): XmlNode =
  ## Follows a "A/B/C" element path; nil when missing. "Tag[2]" picks the
  ## third of several same-named siblings.
  result = n
  for part in path.split('/'):
    if result == nil: return nil
    var tag = part
    var want = 0
    let b = part.find('[')
    if b > 0 and part.endsWith("]"):
      tag = part[0 ..< b]
      try: want = parseInt(part[b + 1 .. ^2])
      except ValueError: return nil
    var found: XmlNode = nil
    var seen = 0
    for c in result:
      if c.kind == xnElement and c.tag == tag:
        if seen == want:
          found = c
          break
        inc seen
    result = found

proc setAttr*(n: XmlNode, key, value: string) =
  var a = n.attrs
  if a == nil: a = newStringTable(modeCaseSensitive)
  a[key] = value
  n.attrs = a

proc str*(n: XmlNode): string =
  if n == nil: "" else: n.innerText

proc setText*(n: XmlNode, value: string) =
  if n == nil: return
  var i = n.len - 1
  while i >= 0:
    if n[i].kind in {xnText, xnCData}: n.delete(i)
    dec i
  if value.len > 0: n.insert(newText(value), 0)

proc parseVec3*(s: string): Vec3 =
  let f = s.splitWhitespace
  if f.len >= 3:
    try: result = vec3(parseFloat(f[0]), parseFloat(f[1]), parseFloat(f[2]))
    except ValueError: discard

proc fmtFloat(f: float32): string =
  result = formatFloat(f.float64, ffDecimal, 4)
  result.trimZeros()
  if result == "-0": result = "0"

proc fmtVec3*(v: Vec3): string = &"{fmtFloat(v.x)} {fmtFloat(v.y)} {fmtFloat(v.z)}"

proc syncFromNode*(o: LevelObject) =
  o.pos = parseVec3(o.node.xpath("Header/Position").str)
  o.rot = parseVec3(o.node.xpath("Header/Rotation").str)
  try: o.id = parseInt(o.node.attr("Id"))
  except ValueError: o.id = 0

proc syncToNode*(o: LevelObject) =
  o.node.xpath("Header/Position").setText(fmtVec3(o.pos))
  o.node.xpath("Header/Rotation").setText(fmtVec3(o.rot))
  o.file.dirty = true

proc label*(o: LevelObject): string =
  ## Short name shown in the outliner and viewports.
  for path in ["OSD/Name", "OSD/Class", "OSD/Tag"]:
    let t = o.node.xpath(path).str.strip
    if t.len > 0: return t
  case o.tag
  of "FLAG": "flag " & o.node.xpath("OSD/FlagId").str
  else: typeName(o.tag) & " " & $o.id

proc loadObjectFile*(path: string): (ObjectFile, seq[LevelObject]) =
  var data = readFile(path)
  if data.startsWith(BOM): data = data[BOM.len .. ^1]
  let root = parseXml(data)
  let f = ObjectFile(path: path, root: root, list: root.xpath("Objects"))
  var objs: seq[LevelObject]
  if f.list != nil:
    for n in f.list:
      if n.kind != xnElement: continue
      let o = LevelObject(tag: n.tag, node: n, file: f)
      o.syncFromNode()
      objs.add o
  (f, objs)

proc saveTo*(f: ObjectFile, path: string) =
  ## Writes the file to path in the same shape OniSplit reads; dirty is unchanged.
  writeFile(path, xmlHeader & $f.root & "\n")

proc save*(f: ObjectFile) =
  f.saveTo(f.path)
  f.dirty = false

proc loadObjects*(dir: string): (seq[ObjectFile], seq[LevelObject]) =
  var paths: seq[string]
  for p in walkFiles(dir / "*.xml"): paths.add p
  paths.sort
  for p in paths:
    let (f, objs) = loadObjectFile(p)
    result[0].add f
    result[1].add objs

proc fields*(o: LevelObject): seq[ObjectField] =
  ## Every editable leaf under the object's OSD, depth-first.
  proc walk(n: XmlNode, prefix: string, acc: var seq[ObjectField]) =
    var total, seen: CountTable[string]
    for c in n:
      if c.kind == xnElement: total.inc c.tag
    for c in n:
      if c.kind != xnElement: continue
      var name = c.tag
      if total[c.tag] > 1:
        name.add "[" & $seen[c.tag] & "]"
        seen.inc c.tag
      let path = if prefix.len > 0: prefix & "/" & name else: name
      if c.attrsLen > 0:
        for k, v in c.attrs.pairs: acc.add ObjectField(path: path, value: v, attr: k)
      var hasChild = false
      for g in c:
        if g.kind == xnElement: hasChild = true
      if hasChild: walk(c, path, acc)
      elif c.attrsLen == 0: acc.add ObjectField(path: path, value: c.innerText)
  let osd = o.node.xpath("OSD")
  if osd != nil: walk(osd, "OSD", result)
  let flags = o.node.xpath("Header/Flags")
  if flags != nil: result.insert(ObjectField(path: "Header/Flags", value: flags.str), 0)

proc setField*(o: LevelObject, f: ObjectField, value: string) =
  ## Sets a field by path. Repeated element names resolve to the first match.
  let n = o.node.xpath(f.path)
  if n == nil: return
  if f.attr.len > 0:
    n.setAttr(f.attr, value)
  else:
    n.setText(value)
  o.file.dirty = true

proc snapshot*(o: LevelObject): string = $o.node

proc restore*(o: LevelObject, xml: string) =
  ## Replaces the object's element with a previous snapshot.
  let fresh = parseXml(xml)
  let list = o.file.list
  for i in 0 ..< list.len:
    if list[i] == o.node:
      list.delete(i)
      list.insert(fresh, i)
      break
  o.node = fresh
  o.syncFromNode()
  o.file.dirty = true

proc findChild*(list, node: XmlNode): int =
  ## Index of node among list's children, or -1.
  for i in 0 ..< list.len:
    if list[i] == node: return i
  -1

proc nextId*(objs: seq[LevelObject]): int =
  for o in objs: result = max(result, o.id)
  inc result

proc duplicate*(o: LevelObject, newId: int): LevelObject =
  ## Copy appended to the same file, right after the original.
  let n = parseXml($o.node)
  n.setAttr("Id", $newId)
  let list = o.file.list
  var at = list.len
  for i in 0 ..< list.len:
    if list[i] == o.node:
      at = i + 1
      break
  list.insert(n, at)
  result = LevelObject(tag: o.tag, node: n, file: o.file)
  result.syncFromNode()
  o.file.dirty = true

proc detach*(o: LevelObject): int =
  ## Removes the element from its file; returns its index for undo.
  let list = o.file.list
  result = -1
  for i in 0 ..< list.len:
    if list[i] == o.node:
      list.delete(i)
      result = i
      break
  o.file.dirty = true

proc attach*(o: LevelObject, index: int) =
  let list = o.file.list
  list.insert(o.node, clamp(index, 0, list.len))
  o.file.dirty = true
