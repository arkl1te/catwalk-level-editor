## The project's own ambient sounds (File > Import > New ambient sound, File > Ambient
## sounds, or "Duplicate as new ambient..." on a sound list): each is an OSBD ambient with its own sound
## groups, kept in the project's ambients.json. Build writes them as OSBD
## <name>.amb and <name>_<track>.grp (Arklite links a level's ambients to their
## groups, as for rec_ sounds). A group's permutations name SNDD recordings: level
## 0's (zap01.aif) or the project's imported ones (cw_<name>.aif, File > Import
## sounds).

import std/[json, strutils, sets, os, strformat]

type
  AmbTrack* = enum
    ## An ambient's sound groups, as Oni plays them (0x480c20): InSound once, then
    ## the two base tracks (looping, or once with PlayOnce) with the detail track's
    ## sounds at random gaps, and OutSound when it stops.
    atIn = "In sound", atBase1 = "Base track 1", atBase2 = "Base track 2",
    atDetail = "Detail track", atOut = "Out sound"

  AmbPerm* = object
    ## One permutation: a recording, how often it's picked against the others
    ## (weight), and a random volume and pitch between min and max.
    sound*: string            ## SNDD name with .aif, lower case ("zap01.aif").
    weight*: int
    vol*, pitch*: (float, float)

  AmbGroup* = object
    vol*, pitch*: float
    noRepeat*: bool           ## PreventRepeat: never the same permutation twice in a row.
    perms*: seq[AmbPerm]

  CustomAmbient* = object
    name*: string
    source*: string           ## What it was duplicated from ("" for none).
    priority*: string         ## Low, Normal, High or Highest.
    playOnce*, canPan*, interrupt*: bool   ## OSAmFlags PlayOnce, CanPan, InterruptTracksOnStop.
    sphere*: float            ## Detail sounds play this far (x/z) around the sound.
    gap*: (float, float)      ## Seconds from one detail sound's start to the next.
    dist*: (float, float)     ## Volume distance: full up to min, silent past max.
    treshold*: int            ## At most this many of it play at once.
    minOcclusion*: float
    tracks*: array[AmbTrack, AmbGroup]

const
  Priorities* = ["Low", "Normal", "High", "Highest"]
  TrackKeys*: array[AmbTrack, string] = ["in", "b1", "b2", "detail", "out"]
    ## Their keys in ambients.json and in the sound cache's manifest.
  TrackSuffix: array[AmbTrack, string] = ["_in", "_b1", "_b2", "_dt", "_out"]
  MaxAmbientName* = 26
    ## Oni's sound names hold 31 characters, and the groups add up to 4.
  NewPerm* = AmbPerm(weight: 10, vol: (1.0, 1.0), pitch: (1.0, 1.0))

proc newGroup*(): AmbGroup = AmbGroup(vol: 1, pitch: 1)

proc newAmbient*(name: string): CustomAmbient =
  ## Oni's defaults for a fresh ambient (as Build's rec_ ambients).
  result = CustomAmbient(name: name, priority: "Normal", sphere: 10, dist: (10.0, 50.0), treshold: 3)
  for t in AmbTrack: result.tracks[t] = newGroup()

proc groupName*(a: CustomAmbient, t: AmbTrack): string = a.name & TrackSuffix[t]

proc soundBase*(sound: string): string =
  ## A permutation's recording without .aif ("zap01"), as rec_ and the WAV cache name it.
  let s = sound.strip.toLowerAscii
  if s.endsWith(".aif"): s[0 ..< ^4] else: s

proc playable*(a: CustomAmbient): bool =
  for t in AmbTrack:
    if a.tracks[t].perms.len > 0: return true

# --- ambients.json ------------------------------------------------------------------

proc pair(n: JsonNode, default: (float, float)): (float, float) =
  if n == nil or n.kind != JArray or n.len < 2: return default
  (n[0].getFloat, n[1].getFloat)

proc toJson*(g: AmbGroup): JsonNode =
  result = %*{"vol": g.vol, "pitch": g.pitch, "norepeat": g.noRepeat, "perms": []}
  for p in g.perms:
    result["perms"].add %*{"s": p.sound, "w": p.weight, "v": [p.vol[0], p.vol[1]],
                           "p": [p.pitch[0], p.pitch[1]]}

proc groupFromJson*(n: JsonNode): AmbGroup =
  ## A group as ambients.json and the sound cache keep it.
  result = newGroup()
  if n == nil or n.kind != JObject: return
  result.vol = n{"vol"}.getFloat(1)
  result.pitch = n{"pitch"}.getFloat(1)
  result.noRepeat = n{"norepeat"}.getBool
  for p in n{"perms"}.getElems:
    result.perms.add AmbPerm(sound: p{"s"}.getStr.toLowerAscii, weight: p{"w"}.getInt(10),
                             vol: pair(p{"v"}, (1.0, 1.0)), pitch: pair(p{"p"}, (1.0, 1.0)))

proc toJson*(a: CustomAmbient): JsonNode =
  result = %*{"name": a.name, "source": a.source, "priority": a.priority, "once": a.playOnce,
              "pan": a.canPan, "interrupt": a.interrupt, "sphere": a.sphere,
              "gap": [a.gap[0], a.gap[1]], "dist": [a.dist[0], a.dist[1]],
              "treshold": a.treshold, "minocc": a.minOcclusion, "tracks": {}}
  for t in AmbTrack: result["tracks"][TrackKeys[t]] = a.tracks[t].toJson

proc ambientFromJson*(n: JsonNode): CustomAmbient =
  result = newAmbient(n{"name"}.getStr)
  result.source = n{"source"}.getStr
  let pr = n{"priority"}.getStr("Normal")
  result.priority = if pr in Priorities: pr else: "Normal"
  result.playOnce = n{"once"}.getBool
  result.canPan = n{"pan"}.getBool
  result.interrupt = n{"interrupt"}.getBool
  result.sphere = n{"sphere"}.getFloat(10)
  result.gap = pair(n{"gap"}, (0.0, 0.0))
  result.dist = pair(n{"dist"}, (10.0, 50.0))
  result.treshold = n{"treshold"}.getInt(3)
  result.minOcclusion = n{"minocc"}.getFloat
  for t in AmbTrack: result.tracks[t] = groupFromJson(n{"tracks"}{TrackKeys[t]})

proc loadAmbients*(path: string): seq[CustomAmbient] =
  ## The project's ambients; none when the file is missing or unreadable.
  if not fileExists(path): return
  try:
    for n in parseFile(path){"ambients"}.getElems: result.add ambientFromJson(n)
  except CatchableError: discard

proc saveAmbients*(path: string, ambs: seq[CustomAmbient]) =
  if ambs.len == 0:
    if fileExists(path): removeFile(path)
    return
  var list = newJArray()
  for a in ambs: list.add a.toJson
  writeFile(path, (%*{"v": 1, "ambients": list}).pretty & "\n")

proc ambientNames*(path: string): seq[string] =
  for a in loadAmbients(path): result.add a.name

proc usedSounds*(ambs: seq[CustomAmbient]): HashSet[string] =
  ## The recordings (without .aif, lower case) the ambients' groups play.
  for a in ambs:
    for t in AmbTrack:
      for p in a.tracks[t].perms: result.incl p.sound.soundBase

# --- names ---------------------------------------------------------------------------

proc nameProblem*(name: string, taken: HashSet[string]): string =
  ## Why name can't be a new ambient ("" when it can). taken: every OSBD name
  ## (without .amb/.grp/.imp) of level 0 and the project, lower case.
  if name.len == 0: return "Give it a name"
  if name.len > MaxAmbientName:
    return &"Names hold {MaxAmbientName} characters at most (Oni adds the groups' endings)"
  for ch in name:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      return "Use letters, digits and _ only"
  if name.toLowerAscii.startsWith("rec_"): return "rec_ names are single recordings"
  let low = name.toLowerAscii
  if low in taken: return name & " is already a sound"
  for suf in TrackSuffix:
    if (low & suf) in taken: return name & suf & " is already a sound (one of its groups would replace it)"

# --- Build ---------------------------------------------------------------------------

proc fmtNum(f: float): string =
  result = formatFloat(f, ffDecimal, 4)
  result.trimZeros()

proc groupXml*(g: AmbGroup, channels: int): string =
  ## An OniSplit .grp.xml.
  result = "<Oni>\n  <SoundGroup>\n" &
    &"    <Volume>{fmtNum(g.vol)}</Volume>\n    <Pitch>{fmtNum(g.pitch)}</Pitch>\n" &
    "    <Flags>" & (if g.noRepeat: "PreventRepeat" else: "") & "</Flags>\n" &
    &"    <NumberOfChannels>{channels}</NumberOfChannels>\n    <Permutations>\n"
  for p in g.perms:
    result.add "      <Permutation>\n" &
      &"        <Weight>{p.weight}</Weight>\n" &
      &"        <Volume><Min>{fmtNum(p.vol[0])}</Min><Max>{fmtNum(p.vol[1])}</Max></Volume>\n" &
      &"        <Pitch><Min>{fmtNum(p.pitch[0])}</Min><Max>{fmtNum(p.pitch[1])}</Max></Pitch>\n" &
      &"        <Sound>{p.sound.soundBase}.aif</Sound>\n      </Permutation>\n"
  result.add "    </Permutations>\n  </SoundGroup>\n</Oni>\n"

proc ambientXml*(a: CustomAmbient): string =
  ## An OniSplit .amb.xml; an empty track names no group.
  proc track(t: AmbTrack): string = (if a.tracks[t].perms.len > 0: a.groupName(t) else: "")
  var flags: seq[string]
  if a.interrupt: flags.add "InterruptTracksOnStop"
  if a.playOnce: flags.add "PlayOnce"
  if a.canPan: flags.add "CanPan"
  "<Oni>\n  <AmbientSound>\n" &
    &"    <Priority>{a.priority}</Priority>\n    <Flags>{flags.join(\" \")}</Flags>\n" &
    "    <DetailTrackProperties>\n" &
    &"      <SphereRadius>{fmtNum(a.sphere)}</SphereRadius>\n" &
    &"      <ElapsedTime><Min>{fmtNum(a.gap[0])}</Min><Max>{fmtNum(a.gap[1])}</Max></ElapsedTime>\n" &
    "    </DetailTrackProperties>\n" &
    &"    <Volume><Distance><Min>{fmtNum(a.dist[0])}</Min><Max>{fmtNum(a.dist[1])}</Max></Distance></Volume>\n" &
    &"    <DetailTrack>{track(atDetail)}</DetailTrack>\n" &
    &"    <BaseTrack1>{track(atBase1)}</BaseTrack1>\n    <BaseTrack2>{track(atBase2)}</BaseTrack2>\n" &
    &"    <InSound>{track(atIn)}</InSound>\n    <OutSound>{track(atOut)}</OutSound>\n" &
    &"    <Treshold>{a.treshold}</Treshold>\n    <MinOcclusion>{fmtNum(a.minOcclusion)}</MinOcclusion>\n" &
    "  </AmbientSound>\n</Oni>\n"
