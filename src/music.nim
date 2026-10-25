## Sound preview: plays level 0's ambient sounds (OSBD .amb) the way Oni
## does: music tracks for the Map tab, any ambient for a Sound object's Class.
## An ambient plays its InSound, then its two base tracks (looping, or once
## for PlayOnce ones) and, at random gaps, its detail track. Each track is a
## sound group: a weighted random permutation (an SNDD sound with a random
## volume and pitch) each time.
##
## The first preview extracts them from level0_Final.dat into
## ~/.cache/catwalk/sounds: OniSplit exports the ambients and sound groups as
## XML and the SNDD sounds they use as WAV (MS ADPCM), and sounds.json keeps
## what each ambient plays. Playback decodes the WAVs here and streams 16-bit
## PCM to pw-cat (or paplay, or aplay) from a thread.

import std/[os, math, json, strutils, sets, tables, random, atomics, osproc, streams, posix, times]
import jobs, project

const
  Rate = 22050       ## Every SNDD in level 0 is 22050 Hz (mono or stereo).
  ChunkFrames = 2048

proc soundDir*(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk" / "sounds"

proc manifestPath(): string = soundDir() / "sounds.json"

const ManifestVersion = 3
  ## 2: ambients keep their volume distances ("dist"). 3: and their Treshold,
  ## MinOcclusion and CanPan flag (realtime preview).

var manifestRead: (times.Time, JsonNode)   ## The manifest's mtime and contents.

proc manifest(): JsonNode =
  ## sounds.json, read again only when it changed; nil when missing or old.
  let path = manifestPath()
  if not fileExists(path): return nil
  let t = getLastModificationTime(path)
  if manifestRead[1] == nil or manifestRead[0] != t:
    try: manifestRead = (t, parseFile(path))
    except CatchableError: manifestRead = (t, newJObject())
  if manifestRead[1]{"v"}.getInt != ManifestVersion: return nil
  manifestRead[1]

proc hasSoundCache*(): bool =
  ## Extracted by the current version (an older cache is extracted again).
  manifest() != nil

# --- extraction ------------------------------------------------------------------

proc tagValue(xml, tag: string): string =
  let a = xml.find("<" & tag & ">")
  if a < 0: return ""
  let s = a + tag.len + 2
  let b = xml.find("</" & tag & ">", s)
  if b < 0: "" else: xml[s ..< b].strip

proc num(xml, tag: string, default = 1.0): float =
  try: parseFloat(xml.tagValue(tag)) except ValueError: default

proc minMax(xml, tag: string): JsonNode =
  let r = xml.tagValue(tag)
  %[r.num("Min"), r.num("Max")]

proc readGroup(xml: string, have: HashSet[string], want: var HashSet[string]): JsonNode =
  ## A .grp.xml as {vol, pitch, norepeat, perms: [{w, v: [min, max], p: [...], s}]},
  ## keeping the permutations whose sound this copy of Oni has.
  var perms = newJArray()
  var i = 0
  while true:
    let a = xml.find("<Permutation>", i)
    if a < 0: break
    let b = xml.find("</Permutation>", a)
    if b < 0: break
    let p = xml[a ..< b]
    let snd = p.tagValue("Sound").toLowerAscii
    if snd in have:
      want.incl snd
      perms.add %*{"w": int(p.num("Weight", 10)), "v": p.minMax("Volume"), "p": p.minMax("Pitch"), "s": snd}
    i = b
  let head = xml[0 ..< max(0, xml.find("<Permutations>"))]
  %*{"vol": head.num("Volume"), "pitch": head.num("Pitch"),
     "norepeat": "PreventRepeat" in head.tagValue("Flags"), "perms": perms}

proc soundCacheJob*(c: Config, logPath: string): Job =
  let
    work = soundDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    wav = work / "wav"
  var manifest = %*{"v": ManifestVersion, "ambients": {}, "groups": {}}
  var wanted: HashSet[string]
  let steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, wav]: createDir(d)),
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", oni, c.gameData / "level0_Final.dat"]),
    # OniSplit expands the wildcards: a thousand paths are too long for sh.
    command("Reading ambient sounds", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-extract:xml", xml, oni / "OSBD*.oni"]),
    action("Listing sounds", proc() =
      var have, want: HashSet[string]
      for f in walkFiles(oni / "SNDD*.oni"):
        have.incl f.extractFilename["SNDD".len .. ^5].toLowerAscii
      for f in walkFiles(xml / "OSBD*.grp.xml"):
        let name = f.extractFilename["OSBD".len .. ^(".grp.xml".len + 1)].toLowerAscii
        manifest["groups"][name] = readGroup(readFile(f), have, want)
      for f in walkFiles(xml / "OSBD*.amb.xml"):
        let x = readFile(f)
        let gap = x.tagValue("ElapsedTime")
        let dist = x.tagValue("Volume").tagValue("Distance")
        manifest["ambients"][f.extractFilename["OSBD".len .. ^(".amb.xml".len + 1)].toLowerAscii] = %*{
          "in": x.tagValue("InSound").toLowerAscii, "b1": x.tagValue("BaseTrack1").toLowerAscii,
          "b2": x.tagValue("BaseTrack2").toLowerAscii, "detail": x.tagValue("DetailTrack").toLowerAscii,
          "gap": [gap.num("Min", 0), gap.num("Max", 0)], "once": "PlayOnce" in x.tagValue("Flags"),
          "dist": [dist.num("Min", 10), dist.num("Max", 50)],
          "treshold": int(x.num("Treshold", 3)), "minocc": x.num("MinOcclusion", 0),
          "pan": "CanPan" in x.tagValue("Flags")}
      wanted = want),
    command("Extracting sounds", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-extract:wav", wav, oni / "SNDD*.oni"]),
    action("Writing sounds", proc() =
      for f in walkFiles(wav / "*.wav"):
        let name = f.extractFilename["SNDD".len .. ^1].toLowerAscii
        if name[0 .. ^5] in wanted: moveFile(f, soundDir() / name)
      writeFile(manifestPath(), $manifest)
      removeDir(work)
      # The music-only cache this one replaced.
      let old = soundDir().parentDir / "music"
      if dirExists(old): removeDir(old))]
  newJob("Extracting sounds", logPath, steps)

# --- decoding --------------------------------------------------------------------

const Adapt = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]

proc u16(s: string, i: int): int = s[i].ord or (s[i + 1].ord shl 8)
proc i16(s: string, i: int): int =
  result = s.u16(i)
  if result >= 0x8000: result -= 0x10000
proc u32(s: string, i: int): int = s.u16(i) or (s.u16(i + 2) shl 16)

proc decodeWav(path: string): seq[int16] {.gcsafe.} =
  ## Interleaved stereo samples of an MS ADPCM (or 16-bit PCM) WAV.
  var s: string
  try: s = readFile(path)
  except IOError: return
  if s.len < 12 or s[0 ..< 4] != "RIFF" or s[8 ..< 12] != "WAVE": return
  var fmtAt, dataAt, dataLen = -1
  var frames = -1
  var i = 12
  while i + 8 <= s.len:
    let id = s[i ..< i + 4]
    let n = s.u32(i + 4)
    case id
    of "fmt ": fmtAt = i + 8
    of "data": (dataAt = i + 8; dataLen = min(n, s.len - i - 8))
    of "fact": frames = s.u32(i + 8)
    i += 8 + n + (n and 1)
  if fmtAt < 0 or dataAt < 0: return
  let
    tag = s.u16(fmtAt)
    ch = s.u16(fmtAt + 2)
    align = s.u16(fmtAt + 12)
  if ch notin [1, 2]: return
  var mono: seq[int16]   # samples in file order
  if tag == 1:
    for k in 0 ..< dataLen div 2: mono.add s.i16(dataAt + k * 2).int16
  elif tag == 2:
    let nCoef = s.u16(fmtAt + 20)
    var c1, c2: seq[int]
    for k in 0 ..< nCoef:
      c1.add s.i16(fmtAt + 22 + k * 4)
      c2.add s.i16(fmtAt + 24 + k * 4)
    var b = dataAt
    let dataEnd = dataAt + dataLen
    while b + 7 * ch <= dataEnd:
      let blockEnd = min(b + align, dataEnd)
      var pred, delta, s1, s2: array[2, int]
      for c in 0 ..< ch:
        pred[c] = min(s[b + c].ord, nCoef - 1)
        delta[c] = s.i16(b + ch + c * 2)
        s1[c] = s.i16(b + 3 * ch + c * 2)
        s2[c] = s.i16(b + 5 * ch + c * 2)
      for c in 0 ..< ch: mono.add s2[c].int16
      for c in 0 ..< ch: mono.add s1[c].int16
      var c = 0
      for p in b + 7 * ch ..< blockEnd:
        for nib in [s[p].ord shr 4, s[p].ord and 15]:
          var v = (s1[c] * c1[pred[c]] + s2[c] * c2[pred[c]]) div 256
          v += (if nib >= 8: nib - 16 else: nib) * delta[c]
          v = clamp(v, -32768, 32767)
          s2[c] = s1[c]
          s1[c] = v
          delta[c] = max(16, Adapt[nib] * delta[c] div 256)
          mono.add v.int16
          c = (c + 1) mod ch
      b = blockEnd
  else: return
  if frames >= 0 and frames * ch < mono.len: mono.setLen(frames * ch)
  if ch == 2: return mono
  for v in mono:
    result.add v
    result.add v

# --- playback --------------------------------------------------------------------

type
  Perm = object
    weight: int
    vol, pitch: (float, float)
    file: string

  Group = object
    vol, pitch: float
    noRepeat: bool
    perms: seq[Perm]

  AmbArgs = object
    intro, base1, base2, detail: Group
    gap: (float, float)      ## Seconds between detail sounds.
    once: bool               ## Base tracks play one sound each, then it ends.

  PlayArgs = object
    player: seq[string]
    amb: AmbArgs
    realtime: bool           ## Realtime preview's level music: its music volume applies.

  SceneArgs = object
    player: seq[string]
    ambients: seq[AmbArgs]   ## What the scene's channels can play.

  Voice = object
    group: Group
    loop: bool               ## Another sound when one ends (else just one).
    gap: (float, float)      ## Silence before each sound.
    started, done: bool
    last: int
    cur: seq[int16]          ## Interleaved stereo.
    pos, step: float         ## Frame position; frames per output frame (pitch).
    vol, gain, master: float
    delay: int

var
  stopFlag: Atomic[bool]
  active: Atomic[bool]
  volumeMilli: Atomic[int]   ## The preview's volume (Oni's 0..1, before the dB curve).
  pitchMilli: Atomic[int]
  musicGainMilli: Atomic[int] ## Realtime preview's music volume (Oni's 0..1), milli.
  sceneGainMilli: Atomic[int] ## Realtime preview's Sound object volume (Oni's 0..1), milli.
  playerPid: Atomic[int]
  playThread: Thread[PlayArgs]
  started: bool
  playing: string            ## What the preview plays: "music:<track>" or "sound:<ambient>".

musicGainMilli.store(1000)
sceneGainMilli.store(1000)

proc dbGain(v: float): float =
  ## Oni hands DirectSound -33.33 dB * (1 - v) (0x485480), muting 0.05 and
  ## below, so a volume is decibels, not a linear gain. Volumes multiply first
  ## (group, permutation, object; 0x481860).
  if v <= 0.05: 0.0 else: pow(10.0, -33.33 * (1 - min(v, 1.0)) / 20)

proc between(rng: var Rand, r: (float, float)): float =
  if r[1] > r[0]: rng.rand(r[0] .. r[1]) else: r[0]

proc next(v: var Voice, rng: var Rand) =
  ## Starts the group's next sound: weighted, not the last one for PreventRepeat.
  v.cur.setLen 0
  if v.group.perms.len == 0 or (v.started and not v.loop):
    v.done = true
    return
  v.started = true
  let skip = if v.group.noRepeat and v.group.perms.len > 1: v.last else: -1
  var total = 0
  for k, p in v.group.perms:
    if k != skip: total += max(1, p.weight)
  var r = rng.rand(total - 1)
  var k = 0
  for i, p in v.group.perms:
    if i == skip: continue
    if r < max(1, p.weight):
      k = i
      break
    r -= max(1, p.weight)
  let p = v.group.perms[k]
  v.cur = decodeWav(p.file)
  if v.cur.len == 0:
    v.group.perms.delete k   # unreadable; don't retry it
    v.last = -1
    v.started = false
    return
  v.last = k
  v.pos = 0
  v.vol = v.group.vol * rng.between(p.vol)
  v.gain = dbGain(v.vol * v.master)
  v.step = v.group.pitch * rng.between(p.pitch)
  v.delay = int(rng.between(v.gap) * Rate)

proc mix(v: var Voice, rng: var Rand, pitch: float, l, r: var float) =
  if v.done: return
  if v.delay > 0:
    dec v.delay
    return
  let n = v.cur.len div 2
  if v.pos.int >= n:
    v.next(rng)
    return
  let i = v.pos.int
  let j = min(i + 1, n - 1)
  let f = v.pos - i.float
  l += (v.cur[2 * i].float * (1 - f) + v.cur[2 * j].float * f) * v.gain
  r += (v.cur[2 * i + 1].float * (1 - f) + v.cur[2 * j + 1].float * f) * v.gain
  v.pos += v.step * pitch

type Amb = object
  ## One ambient playing: its InSound, then its base tracks, and the detail track.
  intro, detail: Voice
  bases: array[2, Voice]
  once: bool

proc initAmb(args: AmbArgs): Amb =
  Amb(intro: Voice(group: args.intro, last: -1), once: args.once,
      bases: [Voice(group: args.base1, last: -1, loop: not args.once),
              Voice(group: args.base2, last: -1, loop: not args.once)],
      detail: Voice(group: args.detail, last: -1, loop: true, gap: args.gap))

proc done(a: Amb): bool =
  a.intro.done and a.bases[0].done and a.bases[1].done and (a.once or a.detail.done)

proc setMaster(a: var Amb, master: float) =
  for v in [a.intro.addr, a.bases[0].addr, a.bases[1].addr, a.detail.addr]:
    v.master = master
    v.gain = dbGain(v.vol * master)

proc mix(a: var Amb, rng: var Rand, pitch: float, l, r: var float) =
  if not a.intro.done: a.intro.mix(rng, pitch, l, r)
  else:
    for v in a.bases.mitems: v.mix(rng, pitch, l, r)
  a.detail.mix(rng, pitch, l, r)

proc feed(fd: cint, buf: seq[int16], stop: ptr Atomic[bool]): bool =
  ## Writes a chunk to a player's stdin, waiting while the pipe is full; false
  ## once stop is set or the player is gone. The pipe is non-blocking: Nim's
  ## pipes aren't close-on-exec, so a player that another thread starts at the
  ## same moment inherits this one's read end. Killing this player then left a
  ## blocking write waiting forever, and stopping it froze the editor.
  let data = cast[ptr UncheckedArray[byte]](buf[0].unsafeAddr)
  let total = buf.len * 2
  var off = 0
  while off < total:
    if stop[].load: return false
    let n = posix.write(fd, data[off].addr, total - off)
    if n > 0: off += n
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR):
      var pfd = TPollfd(fd: fd, events: POLLOUT)
      discard poll(pfd.addr, 1, 20)
    else: return false
  true

proc nonBlocking(fd: cint) =
  discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)

proc playLoop(args: PlayArgs) {.thread.} =
  var p: Process
  try:
    p = startProcess(args.player[0], args = args.player[1 .. ^1], options = {poUsePath})
    playerPid.store(p.processID)
    let output = p.inputStream
    let fd = p.inputHandle.cint
    nonBlocking(fd)
    var rng = initRand()
    var amb = initAmb(args.amb)
    var buf = newSeq[int16](ChunkFrames * 2)
    while not stopFlag.load:
      if amb.done: break
      let pitch = pitchMilli.load / 1000
      amb.setMaster(volumeMilli.load / 1000)
      let gain = if args.realtime: dbGain(musicGainMilli.load / 1000) else: 1.0
      for k in 0 ..< ChunkFrames:
        var l, r = 0.0
        amb.mix(rng, pitch, l, r)
        buf[2 * k] = clamp(int(l * gain), -32768, 32767).int16
        buf[2 * k + 1] = clamp(int(r * gain), -32768, 32767).int16
      if not feed(fd, buf, stopFlag.addr): break
    output.close()
  except CatchableError: discard
  if p != nil:
    if p.running: p.kill()
    discard p.waitForExit()
    p.close()
  playerPid.store(0)
  active.store(false)

proc playerCommand(): seq[string] =
  if findExe("pw-cat").len > 0:
    @["pw-cat", "--playback", "--raw", "--format", "s16", "--rate", $Rate, "--channels", "2", "-"]
  elif findExe("paplay").len > 0:
    @["paplay", "--raw", "--format=s16le", "--rate=" & $Rate, "--channels=2"]
  elif findExe("aplay").len > 0:
    @["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", $Rate, "-c", "2"]
  else: @[]

proc previewing(): string = (if active.load: playing else: "")
proc musicPlaying*(): bool = previewing().startsWith("music:")
proc soundPlaying*(): bool = previewing().startsWith("sound:")
proc soundPlaying*(ambient: string): bool = previewing() == "sound:" & ambient.toLowerAscii

proc stopPreview*() =
  if not started: return
  stopFlag.store(true)
  let pid = playerPid.load
  if pid > 0: discard posix.kill(pid.Pid, SIGTERM)
  joinThread(playThread)
  started = false

proc stopMusic*() =
  if musicPlaying(): stopPreview()

proc stopSound*() =
  if soundPlaying(): stopPreview()

proc setLevel(volume, pitch: float) =
  volumeMilli.store(int(clamp(volume, 0.0, 1.0) * 1000))
  pitchMilli.store(int(clamp(pitch, 0.1, 4.0) * 1000))

proc setMusicVolume*(v: float) =
  if musicPlaying(): setLevel(v, 1)

proc setSoundLevel*(volume, pitch: float) =
  ## A Sound object's Volume and Pitch, while its preview plays.
  if soundPlaying(): setLevel(volume, pitch)

proc ambArgs(ambient: string): AmbArgs =
  ## What a level 0 ambient plays; raises IOError when it can't be played.
  let m = manifest()
  if m == nil: raise newException(IOError, "level 0's sounds are not extracted yet")
  let name = ambient.toLowerAscii
  let amb = m["ambients"]{name}
  if amb == nil: raise newException(IOError, ambient & " is not one of level 0's ambient sounds")
  proc group(key: string): Group =
    let g = m["groups"]{amb[key].getStr}
    if g == nil: return
    result = Group(vol: g["vol"].getFloat, pitch: g["pitch"].getFloat, noRepeat: g["norepeat"].getBool)
    for p in g["perms"]:
      result.perms.add Perm(weight: p["w"].getInt, file: soundDir() / p["s"].getStr & ".wav",
                            vol: (p["v"][0].getFloat, p["v"][1].getFloat),
                            pitch: (p["p"][0].getFloat, p["p"][1].getFloat))
  result = AmbArgs(intro: group("in"), base1: group("b1"), base2: group("b2"),
                   detail: group("detail"), once: amb["once"].getBool,
                   gap: (amb["gap"][0].getFloat, amb["gap"][1].getFloat))
  if result.intro.perms.len + result.base1.perms.len + result.base2.perms.len +
     result.detail.perms.len == 0:
    raise newException(IOError, ambient & " has no sounds in this copy of Oni")

type AmbientInfo* = object
  treshold*: int        ## At most this many of it play at once (0x4821f0).
  minOcclusion*: float  ## Walls between a Sphere sound and the listener turn it down no further.
  canPan*: bool         ## A Sphere sound is panned toward its side.

proc ambientInfo*(ambient: string): AmbientInfo =
  ## Level 0's settings for an ambient (Oni's defaults when unknown).
  result = AmbientInfo(treshold: 3)
  let m = manifest()
  if m == nil: return
  let amb = m["ambients"]{ambient.toLowerAscii}
  if amb == nil: return
  result = AmbientInfo(treshold: amb{"treshold"}.getInt(3), minOcclusion: amb{"minocc"}.getFloat,
                       canPan: amb{"pan"}.getBool)

proc play(key, ambient: string, volume, pitch: float, realtime = false) =
  ## Starts previewing a level 0 ambient; raises IOError when it can't.
  stopPreview()
  let player = playerCommand()
  if player.len == 0: raise newException(IOError, "no audio player found (pw-cat, paplay or aplay)")
  let args = PlayArgs(player: player, amb: ambArgs(ambient), realtime: realtime)
  setLevel(volume, pitch)
  stopFlag.store(false)
  active.store(true)
  playing = key & ambient.toLowerAscii
  createThread(playThread, playLoop, args)
  started = true

proc playMusic*(track: string, volume: float, realtime = false) =
  play("music:", track, volume, 1, realtime)

proc setPreviewGains*(music, sounds: float) =
  ## Realtime preview's volumes (Oni's 0..1, through its dB curve): its level
  ## music and the level's Sound objects. They don't change the level.
  musicGainMilli.store(int(clamp(music, 0.0, 1.0) * 1000))
  sceneGainMilli.store(int(clamp(sounds, 0.0, 1.0) * 1000))

proc playSound*(ambient: string, volume, pitch: float) =
  ## A Sound object's ambient, at its Volume and Pitch.
  play("sound:", ambient, volume, pitch)

# --- the level's Sound objects (realtime preview) ---------------------------------
#
# The scene mixes channels into one player. soundscene.nim decides what each
# channel plays, like Oni's sound system: it starts an ambient on a channel
# (a new instance number), sets its volume and pan every frame, and stops it.

const
  MaxSceneChannels* = 256
  FSetPipeSize = 1031.cint   ## Linux F_SETPIPE_SZ.

var
  sceneStop: Atomic[bool]
  scenePid: Atomic[int]
  sceneAmbient: array[MaxSceneChannels, Atomic[int]]   ## Index into SceneArgs.ambients.
  sceneInstance: array[MaxSceneChannels, Atomic[int]]  ## What the channel plays; 0 = nothing.
  sceneFinished: array[MaxSceneChannels, Atomic[int]]  ## The last instance that ended by itself.
  sceneVolume: array[MaxSceneChannels, Atomic[int]]    ## Oni's 0..1 (before the dB curve), milli.
  scenePan: array[MaxSceneChannels, Atomic[int]]
    ## DirectSound pan, hundredths of a dB: < 0 turns the right channel down, > 0 the left.
  sceneThread: Thread[SceneArgs]
  sceneStarted: bool

proc sceneLoop(args: SceneArgs) {.thread.} =
  var p: Process
  try:
    p = startProcess(args.player[0], args = args.player[1 .. ^1], options = {poUsePath})
    scenePid.store(p.processID)
    # A pipe holds 64 KiB (0.75 s) by default: the volume and pan, which
    # follow the camera, would be heard that late. Two chunks keep it fed.
    discard fcntl(p.inputHandle.cint, FSetPipeSize, cint(ChunkFrames * 4 * 2))
    let output = p.inputStream
    let fd = p.inputHandle.cint
    nonBlocking(fd)
    var rng = initRand()
    var ambs = newSeq[Amb](MaxSceneChannels)
    var playing: array[MaxSceneChannels, int]
    var panL, panR: array[MaxSceneChannels, float]
    var buf = newSeq[int16](ChunkFrames * 2)
    while not sceneStop.load:
      var live: seq[int]
      for i in 0 ..< MaxSceneChannels:
        let inst = sceneInstance[i].load
        if inst != playing[i]:
          playing[i] = inst
          let k = sceneAmbient[i].load
          if inst != 0 and k in 0 ..< args.ambients.len: ambs[i] = initAmb(args.ambients[k])
          elif inst != 0: sceneFinished[i].store(inst)
        if playing[i] == 0 or sceneFinished[i].load == playing[i]: continue
        if ambs[i].done:
          sceneFinished[i].store(playing[i])
          continue
        ambs[i].setMaster(sceneVolume[i].load / 1000)
        let pan = scenePan[i].load.float
        panL[i] = if pan > 0: pow(10.0, -pan / 2000) else: 1.0
        panR[i] = if pan < 0: pow(10.0, pan / 2000) else: 1.0
        live.add i
      let gain = dbGain(sceneGainMilli.load / 1000)
      for k in 0 ..< ChunkFrames:
        var l, r = 0.0
        for i in live:
          var cl, cr = 0.0
          ambs[i].mix(rng, 1, cl, cr)
          l += cl * panL[i]
          r += cr * panR[i]
        buf[2 * k] = clamp(int(l * gain), -32768, 32767).int16
        buf[2 * k + 1] = clamp(int(r * gain), -32768, 32767).int16
      if not feed(fd, buf, sceneStop.addr): break
    output.close()
  except CatchableError: discard
  if p != nil:
    if p.running: p.kill()
    discard p.waitForExit()
    p.close()
  scenePid.store(0)

proc stopScene*() =
  if not sceneStarted: return
  sceneStop.store(true)
  let pid = scenePid.load
  if pid > 0: discard posix.kill(pid.Pid, SIGTERM)
  joinThread(sceneThread)
  sceneStarted = false

proc playScene*(ambients: seq[string]) =
  ## Starts the scene's player, every channel silent. Channels play these
  ## ambients by index; one that can't be played ends at once. Raises IOError
  ## when there's no audio player.
  stopScene()
  let player = playerCommand()
  if player.len == 0: raise newException(IOError, "no audio player found (pw-cat, paplay or aplay)")
  var args = SceneArgs(player: player)
  for ambient in ambients:
    var a: AmbArgs
    try: a = ambArgs(ambient)
    except IOError: discard
    args.ambients.add a
  for i in 0 ..< MaxSceneChannels:
    sceneInstance[i].store(0)
    sceneFinished[i].store(0)
  sceneStop.store(false)
  createThread(sceneThread, sceneLoop, args)
  sceneStarted = true

proc setChannel*(i, ambient, instance: int, volume: float, pan: int) =
  ## Channel i plays instance (0 = nothing) of ambient, at volume (Oni's 0..1)
  ## and pan. A new instance starts the ambient from its InSound.
  if i notin 0 ..< MaxSceneChannels: return
  sceneVolume[i].store(int(clamp(volume, 0.0, 1.0) * 1000))
  scenePan[i].store(clamp(pan, -10000, 10000))
  sceneAmbient[i].store(ambient)
  sceneInstance[i].store(instance)

proc channelFinished*(i, instance: int): bool =
  ## Whether the channel's instance ended by itself (a PlayOnce ambient's
  ## sounds all played, or it can't be played).
  i in 0 ..< MaxSceneChannels and instance != 0 and sceneFinished[i].load == instance

# A player that quits early must not kill Catwalk with SIGPIPE.
signal(SIGPIPE, SIG_IGN)
