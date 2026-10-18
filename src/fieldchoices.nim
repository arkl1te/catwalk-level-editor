## What each Entity tab field accepts, for the dropdown a focused field shows.
##
## Enum and flag names are OniSplit's (Oni.Metadata.ObjectMetadata, the names
## its BINACJBO XML reader parses); a flag field lists every combination of its
## flags. Class, texture and sound fields list the instances the level can link
## by name: level 0's (read from level0_Final.dat's name table) plus the
## project's own oni/ files. Script fields list the functions in the project's
## BSL; id fields the objects (or level 0's combat and melee profiles) that
## carry that id. Free-form fields say what they take and list the values
## other objects in the level use.

import std/[os, strutils, tables, sets, algorithm, xmlparser, re, uri, bitops, times]
import levelobjects, presets

type
  Choice* = object
    value*: string
    note*: string           ## Shown dimmed on the right (numeric value, object name...).
    hint*: bool             ## A line of explanation, not a value.

  Catalog* = ref object
    level0: Table[string, seq[string]]   ## Level 0 instance names by tag ("ONCC" -> [...]).
    level0Read: bool
    combat, melee: seq[(int, string)]    ## Level 0's combat / melee profiles: (id, name).
    projDir: string
    projNames: Table[string, seq[string]]
    scripts: seq[string]
    scriptsStamp: string

  EnumDef = tuple[flags: bool, items: seq[(string, int)]]

const
  ObjectFlags: EnumDef = (true, @[("Locked", 1), ("PlacedInGame", 2), ("Temporary", 4), ("Gunk", 8)])
  CharacterFlags: EnumDef = (true, @[("IsPlayer", 1), ("RandomCostume", 2),
    ("NotInitiallyPresent", 4), ("NonCombatant", 8), ("CanSpawnMultiple", 16), ("Spawned", 32),
    ("Unkillable", 64), ("InfiniteAmmo", 128), ("Omniscient", 256), ("HasLSI", 512),
    ("Boss", 1024), ("UpgradeDifficulty", 2048), ("NoAutoDrop", 4096)])
  CharacterTeam: EnumDef = (false, @[("Konoko", 0), ("TCTF", 1), ("Syndicate", 2),
    ("Neutral", 3), ("SecurityGuard", 4), ("RogueKonoko", 5), ("Switzerland", 6),
    ("SyndicateAccessory", 7)])
  CharacterJobType: EnumDef = (false, @[("None", 0), ("Idle", 1), ("Guard", 2), ("Patrol", 3),
    ("TeamBatle", 4), ("Combat", 5), ("Melee", 6), ("Alarm", 7), ("Neutral", 8), ("Panic", 9)])
  CharacterAlertStatus: EnumDef = (false, @[("Lull", 0), ("Low", 1), ("Medium", 2),
    ("High", 3), ("Combat", 4)])
  CharacterPursuitMode: EnumDef = (false, @[("None", 0), ("Forget", 1), ("GoTo", 2),
    ("Wait", 3), ("Look", 4), ("Move", 5), ("Hunt", 6), ("Glanc", 7)])
  CharacterPursuitLostBehavior: EnumDef = (false, @[("ReturnToJob", 0), ("KeepLooking", 1),
    ("FindAlarm", 2)])
  ConsoleFlags: EnumDef = (true, @[("InitialActive", 8), ("Punch", 32), ("IsAlarm", 64)])
  DoorFlags: EnumDef = (true, @[("InitialLocked", 1), ("InDoorFrame", 4), ("Manual", 16),
    ("DoubleDoor", 128), ("Mirror", 256), ("OneWay", 512), ("Reverse", 1024), ("Jammed", 2048),
    ("InitialOpen", 4096)])
  NeutralFlags: EnumDef = (true, @[("NoResume", 1), ("NoResumeAfterGive", 2), ("Uninterruptible", 4)])
  NeutralItems: EnumDef = (true, @[("Shield", 1), ("Invisibility", 2), ("LSI", 4)])
  NeutralDialogLineFlags: EnumDef = (true, @[("IsPlayer", 1), ("GiveItems", 2), ("AnimOnce", 4),
    ("OtherAnimOnce", 8)])
  ParticleFlags: EnumDef = (true, @[("NotInitiallyCreated", 2)])
  PatrolPathFacing: EnumDef = (false, @[("Forward", 0), ("Backward", 1), ("Left", 1),
    ("Right", 2), ("Stopped", 3)])
  PatrolPathMovementMode: EnumDef = (false, @[("ByAlertLevel", 0), ("Stop", 1), ("Crouch", 2),
    ("Creep", 3), ("WalkNoAim", 4), ("Walk", 5), ("RunNoAim", 6), ("Run", 7)])
  TriggerVolumeFlags: EnumDef = (true, @[("OneTimeEnter", 1), ("OneTimeInside", 2),
    ("OneTimeExit", 4), ("EnterDisabled", 8), ("InsideDisabled", 16), ("ExitDisabled", 32),
    ("Disabled", 64), ("PlayerOnly", 128)])
  TriggerFlags: EnumDef = (true, @[("InitialActive", 8), ("ReverseAnim", 16), ("PingPong", 32)])
  TurretTargetTeams: EnumDef = (true, @[("Konoko", 1), ("TCTF", 2), ("Syndicate", 4),
    ("Neutral", 8), ("SecurityGuard", 16), ("RogueKonoko", 32), ("Switzerland", 64),
    ("SyndicateAccessory", 128)])
  TurretFlags: EnumDef = (true, @[("InitialActive", 2)])

  ## Event elements (CONS/DOOR/TRIG OSD/Events/<type>) whose TargetId names an
  ## object: the type and its id field.
  EventTargets = {"ActivateTurret": "TURR", "DeactivateTurret": "TURR",
    "ActivateConsole": "CONS", "DeactivateConsole": "CONS",
    "ActivateAlarm": "CONS", "DeactivateAlaram": "CONS",
    "ActivateTrigger": "TRIG", "DeactivateTrigger": "TRIG",
    "LockDoor": "DOOR", "UnlockDoor": "DOOR"}.toTable

proc newCatalog*(): Catalog = Catalog()

# --- game data ---------------------------------------------------------------

proc u32(s: string, o: int): int =
  if o < 0 or o + 4 > s.len: return 0
  s[o].uint8.int or (s[o + 1].uint8.int shl 8) or (s[o + 2].uint8.int shl 16) or
    (s[o + 3].uint8.int shl 24)

proc cstr(s: string, o, maxLen: int): string =
  var i = o
  while i < s.len and i < o + maxLen and s[i] != '\0':
    result.add s[i]
    inc i

proc profiles(raw: string, cjbo: int, idFirst: bool): seq[(int, string)] =
  ## A BINACJBO blob in the .raw file: "CJBO", size, version, then records of
  ## size, tag, object id, flags, position, rotation and the OSD. A combat
  ## profile's OSD starts with its name then its id; a melee profile's with
  ## its id then its name.
  if cjbo + 12 > raw.len or raw[cjbo ..< cjbo + 4] != "CJBO": return
  let stop = min(raw.len, cjbo + 8 + u32(raw, cjbo + 4))
  var p = cjbo + 12
  while p + 4 <= stop:
    let size = u32(raw, p)
    if size <= 0: break
    let osd = p + 4 + 36
    if osd + 68 <= stop:
      if idFirst: result.add (u32(raw, osd).int32.int, cstr(raw, osd + 4, 64))
      else: result.add (u32(raw, osd + 64).int32.int, cstr(raw, osd, 64))
    p += 4 + size

proc readLevel0(c: Catalog, gameData: string) =
  ## Instance names from level0_Final.dat's descriptors (20 bytes each from
  ## 0x40: tag, data offset, name offset, size, flags; flag 1 = unnamed).
  c.level0Read = true
  let datPath = gameData / "level0_Final.dat"
  if not fileExists(datPath): return
  var d: string
  try: d = readFile(datPath)
  except IOError: return
  let count = u32(d, 0x14)
  let dataAt = u32(d, 0x20)
  let namesAt = u32(d, 0x28)
  var combatAt, meleeAt = -1
  for i in 0 ..< count:
    let o = 0x40 + 20 * i
    if o + 20 > d.len: break
    if (u32(d, o + 16) and 1) != 0: continue
    let name = cstr(d, namesAt + u32(d, o + 8), 512)
    if name.len < 4: continue
    c.level0.mgetOrPut(name[0 ..< 4], @[]).add name[4 .. ^1]
    # A BINA instance's data: its id (8 bytes), then size and offset in the .raw.
    if name == "BINACJBOCombat": combatAt = dataAt + u32(d, o + 4) - 8
    elif name == "BINACJBOMelee Profile": meleeAt = dataAt + u32(d, o + 4) - 8
  if combatAt >= 0 or meleeAt >= 0:
    try:
      let raw = readFile(gameData / "level0_Final.raw")
      if combatAt >= 0: c.combat = profiles(raw, u32(d, combatAt + 12), false)
      if meleeAt >= 0: c.melee = profiles(raw, u32(d, meleeAt + 12), true)
    except IOError: discard
  for _, v in c.level0.mpairs: v.sort(cmpIgnoreCase)

proc readProject(c: Catalog, projDir: string) =
  c.projDir = projDir
  c.projNames.clear()
  for f in walkFiles(projDir / "oni" / "*.oni"):
    let n = decodeUrl(f.extractFilename.changeFileExt(""))
    if n.len > 4: c.projNames.mgetOrPut(n[0 ..< 4], @[]).add n[4 .. ^1]
  for _, v in c.projNames.mpairs: v.sort(cmpIgnoreCase)
  c.scriptsStamp = ""

proc refresh*(c: Catalog, gameData, projDir: string) =
  ## Reads what changed since the last call (cheap when nothing did).
  if not c.level0Read: c.readLevel0(gameData)
  if projDir != c.projDir: c.readProject(projDir)
  var files: seq[string]
  for f in walkDirRec(projDir / "IGMD"):
    if f.toLowerAscii.endsWith(".bsl"): files.add f
  files.sort
  var stamp = ""
  for f in files:
    try: stamp.add f & $getLastModificationTime(f).toUnix & ";"
    except OSError: discard
  if stamp == c.scriptsStamp: return
  c.scriptsStamp = stamp
  var found: HashSet[string]
  c.scripts.setLen 0
  let fn = re"(?m)^\s*func\s+(?:(?:void|int|float|bool|string)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
  for f in files:
    var text: string
    try: text = readFile(f)
    except IOError: continue
    var caps: array[1, string]
    var at = 0
    while true:
      let (first, stop) = text.findBounds(fn, caps, at)
      if first < 0: break
      at = stop + 1
      let name = caps[0]
      if name notin found:
        found.incl name
        c.scripts.add name
  c.scripts.sort(cmpIgnoreCase)

proc names(c: Catalog, tag: string, prefix = "", suffix = ""): seq[string] =
  ## Instance names of tag in level 0 and the project; with prefix/suffix,
  ## only those names (with it removed).
  var seen: HashSet[string]
  for src in [c.level0.getOrDefault(tag), c.projNames.getOrDefault(tag)]:
    for n in src:
      if not (n.startsWith(prefix) and n.endsWith(suffix)): continue
      let v = n[prefix.len ..< n.len - suffix.len]
      if v.len > 0 and v.toLowerAscii notin seen:
        seen.incl v.toLowerAscii
        result.add v
  result.sort(cmpIgnoreCase)

# --- choices -----------------------------------------------------------------

proc enumChoices(e: EnumDef): seq[Choice] =
  if not e.flags:
    for (n, v) in e.items: result.add Choice(value: n, note: $v)
    return
  # Every combination, fewest flags first, each in declaration order.
  let n = e.items.len
  var masks = newSeq[int](1 shl n)
  for m in 0 ..< masks.len: masks[m] = m
  masks.sort(proc(x, y: int): int =
    result = cmp(popcount(x), popcount(y))
    if result == 0: result = cmp(reverseBits(y.uint32), reverseBits(x.uint32)))
  for m in masks:
    var parts: seq[string]
    var v = 0
    for i in 0 ..< n:
      if (m and (1 shl i)) != 0:
        parts.add e.items[i][0]
        v = v or e.items[i][1]
    result.add Choice(value: parts.join(" "), note: if m == 0: "none" else: $v)

proc nameChoices(items: seq[string], empty = ""): seq[Choice] =
  if empty.len > 0: result.add Choice(value: "", note: empty)
  for n in items: result.add Choice(value: n)

proc idChoices(objs: seq[LevelObject], tag, field: string, none = ""): seq[Choice] =
  if none.len > 0: result.add Choice(value: "0", note: none)
  var rows: seq[(int, string)]
  for o in objs:
    if o.tag != tag: continue
    # A flag's label is just its id; its notes say more.
    let label = if tag == "FLAG": o.node.xpath("OSD/Notes").str.strip else: o.label
    try: rows.add (parseInt(o.node.xpath(field).str.strip), label)
    except ValueError: discard
  rows.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  for (id, label) in rows:
    if none.len > 0 and id == 0: continue
    result.add Choice(value: $id, note: label)

proc profileChoices(rows: seq[(int, string)]): seq[Choice] =
  result.add Choice(value: "-1", note: "none")
  var sorted = rows
  sorted.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  for (id, name) in sorted: result.add Choice(value: $id, note: name)

proc hint(s: string): Choice = Choice(value: s, hint: true)

const FloatFields = ["Volume", "Pitch", "MinRadius", "MaxRadius", "Speed", "StartPosition",
                     "TimeOn", "TimeOff", "Trigger", "Talk", "Follow", "Enemy"]

proc freeHint(key, value: string): Choice =
  ## What a field without a fixed set of values takes, judged by its name and value.
  let last = key.split('/')[^1]
  if last.endsWith("Color"): return hint("Red Green Blue, 0 to 255 each")
  if last in FloatFields: return hint("Any number")
  let parts = value.splitWhitespace
  var numbers = parts.len > 0
  var ints = true
  for p in parts:
    try: discard parseInt(p)
    except ValueError:
      ints = false
      try: discard parseFloat(p)
      except ValueError: numbers = false
  if not numbers: hint("Any text")
  elif parts.len == 1: hint(if ints: "Any whole number" else: "Any number")
  elif parts.len == 2: hint("Two numbers")
  else: hint("Three numbers: X Y Z")

proc fieldKey(tag, path, attr: string): string =
  ## "CHAR OSD/Inventory/Ammo/Use", "PATR OSD/Points/MoveToFlag .FlagId", with
  ## repeat indices ([2]) and the Loop nesting of patrol points removed.
  var p = path.replace(re"\[\d+\]", "")
  if tag == "PATR": p = p.replace("/Loop/", "/")
  result = tag & " " & p
  if attr.len > 0: result.add " ." & attr

proc choices*(c: Catalog, o: LevelObject, path, attr, value: string,
              objs: seq[LevelObject], presets: seq[Preset]): seq[Choice] =
  ## Values the game accepts for o's field (path, attr), most useful first.
  let key = fieldKey(o.tag, path, attr)
  let last = key.split('/')[^1]
  let scripts = nameChoices(c.scripts, "no script")
  let ambient = c.names("OSBD", suffix = ".amb")
  let textures = c.names("TXMP")
  var fixed = true   # false: free-form; a hint leads, then the level's values
  var withUsed = false  # fixed, but the level's other values follow (flags it sets as numbers)
  case key
  of "CHAR Header/Flags", "CONS Header/Flags", "DOOR Header/Flags", "FLAG Header/Flags",
     "FURN Header/Flags", "NEUT Header/Flags", "PART Header/Flags", "PATR Header/Flags",
     "PWRU Header/Flags", "SNDG Header/Flags", "TRGV Header/Flags", "TRIG Header/Flags",
     "TURR Header/Flags", "WEAP Header/Flags":
    result = enumChoices(ObjectFlags)
  of "CHAR OSD/Flags": result = enumChoices(CharacterFlags)
  of "CHAR OSD/Class": result = nameChoices(c.names("ONCC"))
  of "CHAR OSD/Weapon", "NEUT OSD/Rewards/WeaponClass":
    result = nameChoices(c.names("ONWC"), "no weapon")
  of "CHAR OSD/Team": result = enumChoices(CharacterTeam)
  of "CHAR OSD/Job/Type": result = enumChoices(CharacterJobType)
  of "CHAR OSD/Job/PatrolPathId": result = idChoices(objs, "PATR", "OSD/PatrolId")
  of "CHAR OSD/Behaviors/CombatId": result = profileChoices(c.combat)
  of "CHAR OSD/Behaviors/MeleeId": result = profileChoices(c.melee)
  of "CHAR OSD/Behaviors/NeutralId":
    result = @[Choice(value: "-1", note: "none")] & idChoices(objs, "NEUT", "OSD/NeutralId")
  of "CHAR OSD/Alert/Initial", "CHAR OSD/Alert/Minimal", "CHAR OSD/Alert/JobStart",
     "CHAR OSD/Alert/Investigate":
    result = enumChoices(CharacterAlertStatus)
  of "CHAR OSD/Pursuit/StrongUnseen", "CHAR OSD/Pursuit/WeakUnseen",
     "CHAR OSD/Pursuit/StrongSeen", "CHAR OSD/Pursuit/WeakSeen":
    result = enumChoices(CharacterPursuitMode)
  of "CHAR OSD/Pursuit/Lost": result = enumChoices(CharacterPursuitLostBehavior)
  of "CHAR OSD/AmmoPercentage":
    for v in countup(0, 100, 5): result.add Choice(value: $v, note: "%")
  of "CONS OSD/Class": result = nameChoices(c.names("CONS"))
  of "CONS OSD/Flags": result = enumChoices(ConsoleFlags)
  of "CONS OSD/InactiveTexture", "CONS OSD/ActiveTexture", "CONS OSD/TriggeredTexture",
     "DOOR OSD/Texture1", "DOOR OSD/Texture2":
    # Console screens and door textures first; any texture links.
    var first, rest: seq[string]
    let want = if o.tag == "CONS": "_con_" else: "_door"
    for t in textures:
      if t.toLowerAscii.startsWith(want): first.add t else: rest.add t
    result = nameChoices(first & rest, if o.tag == "DOOR": "class default" else: "none")
  of "DOOR OSD/Class": result = nameChoices(c.names("DOOR"))
  of "DOOR OSD/Flags": result = enumChoices(DoorFlags)
  of "TRIG OSD/Class": result = nameChoices(c.names("TRIG"))
  of "TRIG OSD/Flags": result = enumChoices(TriggerFlags)
  of "TURR OSD/Class": result = nameChoices(c.names("TURR"))
  of "TURR OSD/Flags": result = enumChoices(TurretFlags)
  of "TURR OSD/TargetedTeams", "TRGV OSD/Teams": result = enumChoices(TurretTargetTeams)
  of "WEAP OSD/Class": result = nameChoices(c.names("ONWC"))
  of "PWRU OSD/Class":
    result = nameChoices(@["Ammo", "EnergyCell", "Hypo", "Shield", "Invisibility", "LSI"])
  of "PART OSD/Class": result = nameChoices(c.names("BINA", prefix = "3RAP"))
  of "PART OSD/Flags": result = enumChoices(ParticleFlags)
  of "FURN OSD/Class":
    var cls: seq[string]
    for p in presets:
      if p.tag != "FURN" or p.xml.len == 0: continue
      try:
        let v = parseXml(p.xml).xpath("OSD/Class").str.strip
        if v.len > 0 and v notin cls: cls.add v
      except CatchableError: discard
    cls.sort(cmpIgnoreCase)
    result = nameChoices(cls)
    fixed = false
  of "SNDG OSD/Class": result = nameChoices(ambient)
  of "NEUT OSD/Speech/Trigger", "NEUT OSD/Speech/Abort", "NEUT OSD/Speech/Enemy",
     "NEUT OSD/DialogLines/DialogLine/SpeechName":
    result = nameChoices(ambient, "silent")
  of "NEUT OSD/Flags": result = enumChoices(NeutralFlags)
  of "NEUT OSD/Rewards/Other": result = enumChoices(NeutralItems)
  of "NEUT OSD/DialogLines/DialogLine/Flags": result = enumChoices(NeutralDialogLineFlags)
  of "NEUT OSD/Script/AfterTalk": result = scripts
  of "TRGV OSD/Flags": result = enumChoices(TriggerVolumeFlags)
  of "TRGV OSD/ParentId": result = idChoices(objs, "TRGV", "OSD/TriggerVolumeId", "no parent")
  of "TRGV OSD/Scripts/Entry", "TRGV OSD/Scripts/Inside", "TRGV OSD/Scripts/Exit":
    result = scripts
  of "PATR OSD/ReturnToNearest": result = @[Choice(value: "0", note: "no"), Choice(value: "1", note: "yes")]
  of "PATR OSD/Points/MovementMode .Mode": result = enumChoices(PatrolPathMovementMode)
  of "PATR OSD/Points/LockFacing .Facing": result = enumChoices(PatrolPathFacing)
  of "PATR OSD/Points/IgnorePlayer .Value": result = @[Choice(value: "Yes"), Choice(value: "No")]
  else:
    if key.startsWith("CHAR OSD/Scripts/"):
      result = scripts
    elif key.startsWith("CHAR OSD/Inventory/"):
      for v in 0 .. 10: result.add Choice(value: $v)
      fixed = false
    elif key.startsWith("PATR OSD/Points/") and attr == "FlagId":
      result = idChoices(objs, "FLAG", "OSD/FlagId")
    elif (o.tag in ["CONS", "DOOR", "TRIG"]) and key.contains(" OSD/Events/"):
      let ev = path.replace(re"\[\d+\]", "").split('/')[^1]
      if attr == "Function": result = scripts
      elif attr == "TargetId" and ev in EventTargets:
        let t = EventTargets[ev]
        result = idChoices(objs, t, ScriptIdFields[t])
      elif last == "Events": result = @[hint("Events are child elements (edit the XML)")]
      else: fixed = false
    else:
      fixed = false
  if fixed and not withUsed:
    if result.len > 0 and result[0].note == "none" and (key.endsWith("Flags") or key.endsWith("Teams")):
      withUsed = true
    else: return
  # Free-form: what it takes, then what the level's other objects of the type use.
  var used: CountTable[string]
  for ob in objs:
    if ob.tag != o.tag: continue
    for f in ob.fields:
      if f.attr == attr and fieldKey(ob.tag, f.path, f.attr) == key and f.value.len > 0:
        used.inc f.value
  used.sort()
  var rows: seq[Choice]
  if not fixed:
    let idField = ScriptIdFields.getOrDefault(o.tag)
    if idField.len > 0 and key == o.tag & " " & idField:
      # The object's own id: unique among its type. List the taken ones.
      var top = 0
      var taken: seq[(int, string)]
      for ob in objs:
        if ob.tag != o.tag: continue
        try:
          let id = parseInt(ob.node.xpath(idField).str.strip)
          top = max(top, id)
          taken.add (id, if o.tag == "FLAG": ob.node.xpath("OSD/Notes").str.strip else: ob.label)
        except ValueError: discard
      taken.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
      rows.add hint("Any whole number not taken")
      rows.add Choice(value: $(top + 1), note: "next free")
      rows.add hint("Taken:")
      for (id, label) in taken: rows.add Choice(value: $id, note: label)
      return rows
    rows.add freeHint(key, value)
  rows.add result
  var listed: HashSet[string]
  for ch in result: listed.incl ch.value
  var head = false
  for v, n in used:
    if v in listed: continue
    if not head: rows.add hint("Used in this level:")
    head = true
    rows.add Choice(value: v, note: $n & "×")
  result = rows
