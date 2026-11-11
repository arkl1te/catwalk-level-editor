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
## PCM to pw-cat (or paplay, or aplay) from a thread; on Windows, to waveOut.

import std/[os, math, json, strutils, sets, tables, random, atomics, times, algorithm]
import jobs, project, ambients
when defined(windows):
  import waveout
else:
  import std/[osproc, posix, streams]

const
  Rate = 22050       ## What Oni plays every sound at (see decodeWav).
  ChunkFrames = 2048
  DrainSeconds = 3.0 ## Longest a player gets to finish what it was sent.

proc manifestPath(): string = soundDir() / "sounds.json"

const ManifestVersion = 7
  ## 2: ambients keep their volume distances ("dist"). 3: and their Treshold,
  ## MinOcclusion and CanPan flag (realtime preview). 4: sounds level 0 lacks
  ## come from the other levels, and WAVs get their SNDD's real format.
  ## 5: impulses. 6: every SNDD has its WAV, for picking single recordings.
  ## 7: ambients keep OutSound, SphereRadius, Priority and InterruptTracksOnStop
  ## (duplicating one as the project's own, ambients.nim).

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

proc groupSounds(xml: string): seq[string] =
  var i = 0
  while true:
    let a = xml.find("<Sound>", i)
    if a < 0: break
    let b = xml.find("</Sound>", a)
    if b < 0: break
    result.add xml[a + "<Sound>".len ..< b].strip.toLowerAscii
    i = b

proc readGroup(xml: string, have: HashSet[string]): JsonNode =
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
      perms.add %*{"w": int(p.num("Weight", 10)), "v": p.minMax("Volume"), "p": p.minMax("Pitch"), "s": snd}
    i = b
  let head = xml[0 ..< max(0, xml.find("<Permutations>"))]
  %*{"vol": head.num("Volume"), "pitch": head.num("Pitch"),
     "norepeat": "PreventRepeat" in head.tagValue("Flags"), "perms": perms}

proc fixWavFormat(wavPath, oniPath: string) =
  ## OniSplit's -extract:wav writes every sound with a 22050 Hz MS ADPCM
  ## header, but some SNDDs are 44100 Hz ADPCM (1024-byte blocks: zap01-45)
  ## or 16-bit PCM (level 14's gears.aif). The SNDD's WAVEFORMATEX is at
  ## 0x8c in its .oni; the WAV gets that one.
  const At = 0x8c
  let o = readFile(oniPath)
  if o.len < At + 18: return
  let tag = o[At].ord or (o[At + 1].ord shl 8)
  let ch = o[At + 2].ord or (o[At + 3].ord shl 8)
  let extra = if tag == 1: 0 else: o[At + 16].ord or (o[At + 17].ord shl 8)
  if tag notin [1, 2] or ch notin [1, 2] or o.len < At + 18 + extra: return
  let fmt = o[At ..< At + 18 + extra]
  let w = readFile(wavPath)
  var i = 12
  while i + 8 <= w.len:
    let n = w[i + 4].ord or (w[i + 5].ord shl 8) or (w[i + 6].ord shl 16) or (w[i + 7].ord shl 24)
    if w[i ..< i + 4] == "data":
      let data = w[i ..< min(w.len, i + 8 + n)]
      proc le32(v: int): string =
        result = newString(4)
        for k in 0 .. 3: result[k] = char((v shr (8 * k)) and 0xff)
      writeFile(wavPath, "RIFF" & le32(4 + 8 + fmt.len + data.len) & "WAVE" &
                         "fmt " & le32(fmt.len) & fmt & data)
      return
    i += 8 + n + (n and 1)

proc soundCacheJob*(c: Config, logPath: string): Job =
  let
    work = soundDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    wav = work / "wav"
    more = work / "levels"
  var manifest = %*{"v": ManifestVersion, "ambients": {}, "impulses": {}, "groups": {}}
  var otherLevels: seq[string]
  var steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, wav, more]: createDir(d))]
  steps.add c.exportTypes("Reading level 0", c.gameData / "level0_Final.dat", oni, ["SNDD", "OSBD"],
                          apart = ["OSBD"])
  steps.add @[
    # OniSplit expands the wildcards: a thousand paths are too long for sh.
    command("Reading ambient sounds", proc(): seq[string] =
      c.oniSplitCmd & @["-extract:xml", xml, typeDir(oni, "OSBD") / "OSBD*.oni"]),
    # Level 0's sound groups name some sounds that only a level has (level
    # 14's gears.aif, from AE's Missing Sounds); Oni plays those there.
    action("Finding sounds in other levels", proc() =
      var have, missing: HashSet[string]
      for f in walkFiles(oni / "SNDD*.oni"):
        have.incl f.extractFilename["SNDD".len .. ^5].toLowerAscii
      for f in walkFiles(xml / "OSBD*.grp.xml"):
        for snd in groupSounds(readFile(f)):
          if snd notin have: missing.incl snd
      for f in walkFiles(c.gameData / "level*_Final.dat"):
        if f.extractFilename == "level0_Final.dat": continue
        let names = readFile(f).toLowerAscii
        for snd in missing:
          if "sndd" & snd & "\0" in names:
            otherLevels.add f
            break),
    # OniSplit exports one .dat per run: side by side, each in a folder of its own.
    parallel("Reading other levels", proc(): seq[FileCommand] =
      for i, d in otherLevels:
        result.add (c.oniSplitCmd & @["-export:SNDD", more / $i, d], newSeq[string]())),
    action("Listing sounds", proc() =
      for i in 0 ..< otherLevels.len:
        for f in walkFiles(more / $i / "SNDD*.oni"):
          let dest = oni / f.extractFilename
          if not fileExists(dest): moveFile(f, dest)
      removeDir(more)
      var have: HashSet[string]
      for f in walkFiles(oni / "SNDD*.oni"):
        have.incl f.extractFilename["SNDD".len .. ^5].toLowerAscii
      for f in walkFiles(xml / "OSBD*.grp.xml"):
        let name = f.extractFilename["OSBD".len .. ^(".grp.xml".len + 1)].toLowerAscii
        manifest["groups"][name] = readGroup(readFile(f), have)
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
          "pan": "CanPan" in x.tagValue("Flags"), "out": x.tagValue("OutSound").toLowerAscii,
          "sphere": x.num("SphereRadius", 10), "prio": x.tagValue("Priority"),
          "interrupt": "InterruptTracksOnStop" in x.tagValue("Flags")}
      for f in walkFiles(xml / "OSBD*.imp.xml"):
        manifest["impulses"][f.extractFilename["OSBD".len .. ^(".imp.xml".len + 1)].toLowerAscii] =
          %readFile(f).tagValue("Group").toLowerAscii),
    command("Extracting sounds", proc(): seq[string] =
      c.oniSplitCmd & @["-extract:wav", wav, oni / "SNDD*.oni"]),
    action("Writing sounds", proc() =
      for f in walkFiles(wav / "*.wav"):
        let name = f.extractFilename["SNDD".len .. ^1].toLowerAscii
        fixWavFormat(f, oni / f.extractFilename.changeFileExt("oni"))
        moveFile(f, soundDir() / name)
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
  ## Interleaved stereo samples of an MS ADPCM (or 16-bit PCM) WAV. Oni runs
  ## every channel at 22050 Hz * pitch and ignores a sound's own rate
  ## (SS2rPlatform_SoundChannel_SetPitch), so the 44100 Hz ones (zap01-45,
  ## ap_hit_shld) play an octave low at half speed. The preview does the same:
  ## the samples aren't resampled. Measured against the game's output.
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
          delta[c] = clamp(Adapt[nib] * delta[c] div 256, 16, int32.high div 768)  # as ffmpeg
          mono.add v.int16
          c = (c + 1) mod ch
      b = blockEnd
  else: return
  if frames >= 0 and frames * ch < mono.len: mono.setLen(frames * ch)
  if ch == 2: return move mono
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
    sound: bool              ## A sound field's preview: the Sound objects volume applies.

  SceneArgs = object
    player: seq[string]
    ambients: seq[AmbArgs]   ## What the scene's channels can play.

  Voice = object
    group: Group
    loop: bool               ## Another sound when one ends (else just one).
    started, done: bool
    last: int
    cur: seq[int16]          ## Interleaved stereo.
    pos, step: float         ## Frame position; frames per output frame (pitch).
    vol, gain, master: float

var
  # Flags are ints: with MSVC, std/atomics stores 8 bytes whatever the type,
  # so on a bool it zeroes the 7 bytes after it (other globals). Majestic hit it.
  stopFlag: Atomic[int]
  active: Atomic[int]
  volumeMilli: Atomic[int]   ## The preview's volume (Oni's 0..1, before the dB curve).
  pitchMilli: Atomic[int]
  musicGainMilli: Atomic[int] ## Realtime preview's music volume (Oni's 0..1), milli.
  sceneGainMilli: Atomic[int] ## The Sound objects volume (Oni's 0..1), milli: Realtime's and sound fields' previews.
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

proc mix(v: var Voice, rng: var Rand, pitch: float, l, r: var float) =
  if v.done: return
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

const MaxDetails = 8   ## Detail sounds of one ambient at once (Oni takes a free channel each).

type Amb = object
  ## One ambient playing, like Oni's ambient state machine (0x480c20): its
  ## InSound, then its base tracks with detail sounds. An ambient with no
  ## InSound or base tracks plays detail sounds only, the first one at once.
  intro: Voice
  bases: array[2, Voice]
  detail: Group
  details: seq[Voice]      ## Detail sounds playing; they overlap.
  detailLast: int          ## For PreventRepeat across detail sounds.
  detailWait: int          ## Frames until the next detail sound; -1 = not started.
  gap: (float, float)
  once, detailOnly: bool
  master: float

proc initAmb(args: AmbArgs): Amb =
  Amb(intro: Voice(group: args.intro, last: -1), once: args.once,
      bases: [Voice(group: args.base1, last: -1, loop: not args.once),
              Voice(group: args.base2, last: -1, loop: not args.once)],
      detail: args.detail, detailLast: -1, detailWait: -1, gap: args.gap,
      detailOnly: args.intro.perms.len + args.base1.perms.len + args.base2.perms.len == 0)

proc basesDone(a: Amb): bool = a.bases[0].done and a.bases[1].done

proc done(a: Amb): bool =
  a.intro.done and a.basesDone and a.details.len == 0 and
    (a.detail.perms.len == 0 or not a.detailOnly)

proc setMaster(a: var Amb, master: float) =
  a.master = master
  for v in [a.intro.addr, a.bases[0].addr, a.bases[1].addr]:
    v.master = master
    v.gain = dbGain(v.vol * master)
  for v in a.details.mitems:
    v.master = master
    v.gain = dbGain(v.vol * master)

proc mixDetail(a: var Amb, rng: var Rand, pitch: float, l, r: var float) =
  ## Oni starts a detail sound whenever its timer runs out and restarts the
  ## timer at once (0x4812a0, 0x481140): random ElapsedTime seconds from the
  ## sound's start, not its end, so longer sounds overlap. It plays only
  ## while the base tracks do (or always, for a detail-only ambient).
  if a.detail.perms.len > 0 and (a.detailOnly or not a.basesDone):
    if a.detailWait < 0:
      a.detailWait = if a.detailOnly: 0 else: max(Rate div 60, int(rng.between(a.gap) * Rate))
    if a.detailWait == 0:
      var v = Voice(group: a.detail, last: a.detailLast, master: a.master)
      v.next(rng)
      if v.cur.len > 0:
        a.detailLast = v.last
        if a.details.len >= MaxDetails: a.details.delete 0
        a.details.add v
      else: a.detail = v.group   # next dropped an unreadable sound
      a.detailWait = max(Rate div 60, int(rng.between(a.gap) * Rate))  # Oni checks once a tick
    dec a.detailWait
  var i = 0
  while i < a.details.len:
    a.details[i].mix(rng, pitch, l, r)
    if a.details[i].done: a.details.delete i
    else: inc i

proc mix(a: var Amb, rng: var Rand, pitch: float, l, r: var float) =
  if not a.intro.done:
    a.intro.mix(rng, pitch, l, r)
    if not a.intro.done: return
  for v in a.bases.mitems: v.mix(rng, pitch, l, r)
  a.mixDetail(rng, pitch, l, r)

# --- sound output: a player's stdin, or Windows' waveOut -----------------------

const
  FSetPipeSize = 1031.cint   ## Linux F_SETPIPE_SZ.

type Sink = object
  when defined(windows):
    wo: WaveOut
  else:
    p: Process
    fd: cint

when not defined(windows):
  proc feed(fd: cint, buf: seq[int16], stop: ptr Atomic[int]): bool =
    ## Writes a chunk to a player's stdin, waiting while the pipe is full; false
    ## once stop is set or the player is gone. The pipe is non-blocking: Nim's
    ## pipes aren't close-on-exec, so a player that another thread starts at the
    ## same moment inherits this one's read end. Killing this player then left a
    ## blocking write waiting forever, and stopping it froze the editor.
    let data = cast[ptr UncheckedArray[byte]](buf[0].unsafeAddr)
    let total = buf.len * 2
    var off = 0
    while off < total:
      if stop[].load != 0: return false
      let n = posix.write(fd, data[off].addr, total - off)
      if n > 0: off += n
      elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR):
        var pfd = TPollfd(fd: fd, events: POLLOUT)
        discard poll(pfd.addr, 1, 20)
      else: return false
    true

  proc nonBlocking(fd: cint) =
    discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)

proc openSink(player: seq[string], pid: ptr Atomic[int], lowLatency: bool): Sink =
  ## lowLatency: as little queued as keeps it fed, for sound that follows the
  ## camera (the scene). Raises when there's no output.
  when defined(windows):
    result.wo = openWaveOut(Rate, ChunkFrames * 2, if lowLatency: 3 else: 4)
  else:
    result.p = startProcess(player[0], args = player[1 .. ^1], options = {poUsePath})
    pid[].store(result.p.processID)
    if lowLatency:
      # A pipe holds 64 KiB (0.75 s) by default: the volume and pan, which
      # follow the camera, would be heard that late. Two chunks keep it fed.
      discard fcntl(result.p.inputHandle.cint, FSetPipeSize, cint(ChunkFrames * 4 * 2))
    discard result.p.inputStream  # made now, closed by endInput
    result.fd = result.p.inputHandle.cint
    nonBlocking(result.fd)

proc feed(s: var Sink, buf: seq[int16], stop: ptr Atomic[int]): bool =
  when defined(windows): s.wo.write(buf, stop)
  else: feed(s.fd, buf, stop)

proc endInput(s: var Sink) =
  ## No more sound: the player plays what it has, then exits.
  when not defined(windows):
    if s.p != nil: s.p.inputStream.close()

proc drain(s: var Sink, stop: ptr Atomic[int]) =
  ## Waits for what was sent to play out (DrainSeconds at most).
  # What was written is still in the pipe and the player's buffer: a pipe
  # holds 0.75 s, longer than most impulse sounds, so killing the player now
  # would cut the end off a sound or lose all of it. It exits when it has
  # played everything. The time limit is for a player that sees no end of
  # input: another player started at the same moment keeps the pipe open
  # (see feed).
  when defined(windows):
    s.wo.drain(stop, DrainSeconds)
  else:
    let deadline = epochTime() + DrainSeconds
    while s.p != nil and s.p.running and stop[].load == 0 and epochTime() < deadline: sleep(10)

proc close(s: var Sink) =
  ## Stops the sound at once.
  when defined(windows):
    s.wo.close()
  else:
    if s.p != nil:
      if s.p.running: s.p.kill()
      discard s.p.waitForExit()
      s.p.close()
      s.p = nil

proc playLoop(args: PlayArgs) {.thread.} =
  var o: Sink
  try:
    o = openSink(args.player, playerPid.addr, lowLatency = false)
    var rng = initRand()
    var amb = initAmb(args.amb)
    var buf = newSeq[int16](ChunkFrames * 2)
    var ended = false
    while stopFlag.load == 0:
      if amb.done:
        ended = true
        break
      let pitch = pitchMilli.load / 1000
      amb.setMaster(volumeMilli.load / 1000)
      let gain = if args.realtime: dbGain(musicGainMilli.load / 1000)
                 elif args.sound: dbGain(sceneGainMilli.load / 1000)
                 else: 1.0
      for k in 0 ..< ChunkFrames:
        var l, r = 0.0
        amb.mix(rng, pitch, l, r)
        buf[2 * k] = clamp(int(l * gain), -32768, 32767).int16
        buf[2 * k + 1] = clamp(int(r * gain), -32768, 32767).int16
      if not o.feed(buf, stopFlag.addr): break
    o.endInput()
    if ended: o.drain(stopFlag.addr)
  except CatchableError: discard
  o.close()
  playerPid.store(0)
  active.store(0)

proc playerCommand(): seq[string] =
  ## What plays the sound; empty when nothing can. On Windows waveOut does,
  ## in-process (the name is only a marker).
  when defined(windows):
    if haveWaveOut(): @["waveOut"] else: @[]
  else:
    if findExe("pw-cat").len > 0:
      @["pw-cat", "--playback", "--raw", "--format", "s16", "--rate", $Rate, "--channels", "2", "-"]
    elif findExe("paplay").len > 0:
      @["paplay", "--raw", "--format=s16le", "--rate=" & $Rate, "--channels=2"]
    elif findExe("aplay").len > 0:
      @["aplay", "-q", "-t", "raw", "-f", "S16_LE", "-r", $Rate, "-c", "2"]
    else: @[]

const NoPlayer = when defined(windows): "no sound output device"
                 else: "no audio player found (pw-cat, paplay or aplay)"

proc previewing(): string = (if active.load != 0: playing else: "")
proc musicPlaying*(): bool = previewing().startsWith("music:")
proc soundPlaying*(): bool = previewing().startsWith("sound:")
proc soundPlaying*(ambient: string): bool = previewing() == "sound:" & ambient.toLowerAscii

proc stopPreview*() =
  if not started: return
  stopFlag.store(1)
  when not defined(windows):  # waveOut sees the flag within 5 ms
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
  ## A Sound object's level, while its preview plays.
  if soundPlaying(): setLevel(volume, pitch)

proc notPlayable(m: JsonNode, ambient: string, impulse: bool): string =
  ## Why a field that takes impulses (or ambients) can't play this name.
  let
    name = ambient.toLowerAscii
    want = if impulse: "impulse" else: "ambient"
    other = if impulse: "ambient" else: "impulse"
    (wanted, others) = if impulse: ("impulses", "ambients") else: ("ambients", "impulses")
  if m[others]{name} != nil:
    return ambient & " is an " & other & " sound, and this field takes " & want & " sounds"
  if m["groups"]{name} == nil:
    return "There is no " & want & " sound called " & ambient
  proc users(table: string): seq[string] =
    ## The ambients or impulses that play this sound group.
    for k, v in m[table]:
      if v.kind == JString:
        if v.getStr == name: result.add k
      elif name in [v["in"].getStr, v["b1"].getStr, v["b2"].getStr, v["detail"].getStr]:
        result.add k
    result.sort(cmpIgnoreCase)
  proc named(l: seq[string]): string =
    result = l[0 ..< min(l.len, 4)].join(", ")
    if l.len > 4: result &= " and " & $(l.len - 4) & " more"
  let mine = users(wanted)
  if mine.len > 0:
    return ambient & " is a sound group, not a sound: pick " & named(mine) & ", which play it"
  let theirs = users(others)
  if theirs.len > 0:
    return ambient & " is a sound group played only by the " & other & " sounds " & named(theirs) &
           ", and this field takes " & want & " sounds"
  ambient & " is a sound group that no " & want & " sound plays"

var projectAmbients: Table[string, CustomAmbient]
  ## The open project's own ambients (ambients.nim) by lower-case name, and the
  ## ambient editor's draft under DraftAmbient.

const DraftAmbient* = "\1draft"
  ## playSound's name for the ambient being edited (setDraftAmbient).

proc setProjectAmbients*(ambs: seq[CustomAmbient]) =
  let draft = projectAmbients.getOrDefault(DraftAmbient)
  projectAmbients.clear()
  for a in ambs: projectAmbients[a.name.toLowerAscii] = a
  if draft.name.len > 0: projectAmbients[DraftAmbient] = draft

proc setDraftAmbient*(a: CustomAmbient) =
  var d = a
  if d.name.len == 0: d.name = "draft"
  projectAmbients[DraftAmbient] = d

proc isProjectAmbient*(name: string): bool =
  name.toLowerAscii in projectAmbients and name.toLowerAscii != DraftAmbient

proc projectAmbient*(name: string): CustomAmbient = projectAmbients.getOrDefault(name.toLowerAscii)

proc toGroup(g: AmbGroup): Group =
  result = Group(vol: g.vol, pitch: g.pitch, noRepeat: g.noRepeat)
  for p in g.perms:
    result.perms.add Perm(weight: p.weight, file: recordingWav(p.sound.soundBase), vol: p.vol, pitch: p.pitch)

proc cachedAmbient*(ambient: string): CustomAmbient =
  ## A copy of an ambient (level 0's, the project's or a rec_ recording looped) to
  ## make a new one from; raises IOError when there's none of that name.
  let name = ambient.strip.toLowerAscii
  if name in projectAmbients:
    result = projectAmbients[name]
    result.source = ambient.strip
    return
  result = newAmbient("")
  result.source = ambient.strip
  if name.startsWith(RecordingPrefix):
    let (rec, recPitch) = splitRecording(name)
    if not fileExists(recordingWav(rec)): raise newException(IOError, "There is no recording called " & rec)
    var p = NewPerm
    p.sound = rec & ".aif"
    p.pitch = (recPitch, recPitch)
    result.tracks[atBase1].perms.add p
    return
  let m = manifest()
  if m == nil: raise newException(IOError, "level 0's sounds are not extracted yet")
  let amb = m["ambients"]{name}
  if amb == nil: raise newException(IOError, notPlayable(m, ambient, false))
  let pr = amb{"prio"}.getStr("Normal")
  result.priority = if pr in Priorities: pr else: "Normal"
  result.playOnce = amb{"once"}.getBool
  result.canPan = amb{"pan"}.getBool
  result.interrupt = amb{"interrupt"}.getBool
  result.sphere = amb{"sphere"}.getFloat(10)
  result.gap = (amb["gap"][0].getFloat, amb["gap"][1].getFloat)
  result.dist = (amb["dist"][0].getFloat, amb["dist"][1].getFloat)
  result.treshold = amb{"treshold"}.getInt(3)
  result.minOcclusion = amb{"minocc"}.getFloat
  for t in AmbTrack:
    let g = amb{TrackKeys[t]}.getStr
    if g.len > 0: result.tracks[t] = groupFromJson(m["groups"]{g})

proc ambArgs(ambient: string, impulse = false): AmbArgs =
  ## What a level 0 ambient or impulse plays; raises IOError when it can't be played.
  let name = ambient.toLowerAscii
  if not impulse and name in projectAmbients:
    let a = projectAmbients[name]
    if not a.playable: raise newException(IOError, a.name & " has no sounds yet")
    return AmbArgs(intro: a.tracks[atIn].toGroup, base1: a.tracks[atBase1].toGroup,
                   base2: a.tracks[atBase2].toGroup, detail: a.tracks[atDetail].toGroup,
                   once: a.playOnce, gap: a.gap)
  let m = manifest()
  if m == nil: raise newException(IOError, "level 0's sounds are not extracted yet")
  if name.startsWith(RecordingPrefix):
    # One recording, as Build defines it: an impulse plays it once, an ambient loops it.
    let (rec, recPitch) = splitRecording(name)
    let file = recordingWav(rec)
    if not fileExists(file):
      raise newException(IOError, "There is no recording called " & rec)
    let g = Group(vol: 1, pitch: 1, perms: @[Perm(weight: 10, vol: (1.0, 1.0), pitch: (recPitch, recPitch), file: file)])
    return AmbArgs(base1: g, once: impulse)
  let amb = m[if impulse: "impulses" else: "ambients"]{name}
  if amb == nil: raise newException(IOError, notPlayable(m, ambient, impulse))
  proc group(key: string): Group =
    let g = m["groups"]{if impulse: amb.getStr else: amb[key].getStr}
    if g == nil: return
    result = Group(vol: g["vol"].getFloat, pitch: g["pitch"].getFloat, noRepeat: g["norepeat"].getBool)
    for p in g["perms"]:
      result.perms.add Perm(weight: p["w"].getInt, file: soundDir() / p["s"].getStr & ".wav",
                            vol: (p["v"][0].getFloat, p["v"][1].getFloat),
                            pitch: (p["p"][0].getFloat, p["p"][1].getFloat))
  if impulse: result = AmbArgs(base1: group(""), once: true)   # One sound of its group.
  else:
    result = AmbArgs(intro: group("in"), base1: group("b1"), base2: group("b2"),
                     detail: group("detail"), once: amb["once"].getBool,
                     gap: (amb["gap"][0].getFloat, amb["gap"][1].getFloat))
  if result.intro.perms.len + result.base1.perms.len + result.base2.perms.len +
     result.detail.perms.len == 0:
    # Bungie shipped these ambients' definitions without their audio: no
    # level has the sounds, so they're silent in the game too.
    raise newException(IOError, ambient & " has no audio in any level (cut from Oni; silent in game too)")

type AmbientInfo* = object
  treshold*: int        ## At most this many of it play at once (0x4821f0).
  minOcclusion*: float  ## Walls between a Sphere sound and the listener turn it down no further.
  canPan*: bool         ## A Sphere sound is panned toward its side.

proc ambientInfo*(ambient: string): AmbientInfo =
  ## Level 0's settings for an ambient (Oni's defaults when unknown).
  result = AmbientInfo(treshold: 3)
  let own = ambient.toLowerAscii
  if own in projectAmbients:
    let a = projectAmbients[own]
    return AmbientInfo(treshold: a.treshold, minOcclusion: a.minOcclusion, canPan: a.canPan)
  let m = manifest()
  if m == nil: return
  let amb = m["ambients"]{ambient.toLowerAscii}
  if amb == nil: return
  result = AmbientInfo(treshold: amb{"treshold"}.getInt(3), minOcclusion: amb{"minocc"}.getFloat,
                       canPan: amb{"pan"}.getBool)

proc play(key, ambient: string, volume, pitch: float, realtime = false, impulse = false) =
  ## Starts previewing a level 0 ambient or impulse; raises IOError when it can't.
  stopPreview()
  let player = playerCommand()
  if player.len == 0: raise newException(IOError, NoPlayer)
  let args = PlayArgs(player: player, amb: ambArgs(ambient, impulse), realtime: realtime,
                      sound: key == "sound:")
  setLevel(volume, pitch)
  stopFlag.store(0)
  active.store(1)
  playing = key & ambient.toLowerAscii
  createThread(playThread, playLoop, args)
  started = true

proc playMusic*(track: string, volume: float, realtime = false) =
  play("music:", track, volume, 1, realtime)

proc setPreviewGains*(music, sounds: float) =
  ## Realtime preview's volumes (Oni's 0..1, through its dB curve): its level
  ## music and the level's Sound objects, which the sound fields' play buttons
  ## follow too. They don't change the level.
  musicGainMilli.store(int(clamp(music, 0.0, 1.0) * 1000))
  sceneGainMilli.store(int(clamp(sounds, 0.0, 1.0) * 1000))

proc playSound*(ambient: string, volume, pitch: float, impulse = false) =
  ## A Sound object's ambient at its level, or a class's sound.
  play("sound:", ambient, volume, pitch, impulse = impulse)

# --- the level's Sound objects (realtime preview) ---------------------------------
#
# The scene mixes channels into one player. soundscene.nim decides what each
# channel plays, like Oni's sound system: it starts an ambient on a channel
# (a new instance number), sets its volume and pan every frame, and stops it.

const
  MaxSceneChannels* = 256

var
  sceneStop: Atomic[int]
  scenePid: Atomic[int]
  sceneAmbient: array[MaxSceneChannels, Atomic[int]]   ## Index into SceneArgs.ambients.
  sceneInstance: array[MaxSceneChannels, Atomic[int]]  ## What the channel plays; 0 = nothing.
  sceneFinished: array[MaxSceneChannels, Atomic[int]]  ## The last instance that ended by itself.
  sceneVolume: array[MaxSceneChannels, Atomic[int]]    ## Oni's 0..1 (before the dB curve), milli.
  scenePan: array[MaxSceneChannels, Atomic[int]]
    ## DirectSound pan, hundredths of a dB: < 0 turns the right channel down, > 0 the left.
  scenePitch: array[MaxSceneChannels, Atomic[int]]   ## Playback speed, milli (1000 = normal).
  sceneThread: Thread[SceneArgs]
  sceneStarted: bool

proc sceneLoop(args: SceneArgs) {.thread.} =
  var o: Sink
  try:
    o = openSink(args.player, scenePid.addr, lowLatency = true)
    var rng = initRand()
    var ambs = newSeq[Amb](MaxSceneChannels)
    var playing: array[MaxSceneChannels, int]
    var panL, panR, pitch: array[MaxSceneChannels, float]
    var buf = newSeq[int16](ChunkFrames * 2)
    while sceneStop.load == 0:
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
        pitch[i] = scenePitch[i].load / 1000
        let pan = scenePan[i].load.float
        panL[i] = if pan > 0: pow(10.0, -pan / 2000) else: 1.0
        panR[i] = if pan < 0: pow(10.0, pan / 2000) else: 1.0
        live.add i
      let gain = dbGain(sceneGainMilli.load / 1000)
      for k in 0 ..< ChunkFrames:
        var l, r = 0.0
        for i in live:
          var cl, cr = 0.0
          ambs[i].mix(rng, pitch[i], cl, cr)
          l += cl * panL[i]
          r += cr * panR[i]
        buf[2 * k] = clamp(int(l * gain), -32768, 32767).int16
        buf[2 * k + 1] = clamp(int(r * gain), -32768, 32767).int16
      if not o.feed(buf, sceneStop.addr): break
    o.endInput()
  except CatchableError: discard
  o.close()
  scenePid.store(0)

proc stopScene*() =
  if not sceneStarted: return
  sceneStop.store(1)
  when not defined(windows):
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
  if player.len == 0: raise newException(IOError, NoPlayer)
  var args = SceneArgs(player: player)
  for ambient in ambients:
    var a: AmbArgs
    try: a = ambArgs(ambient)
    except IOError: discard
    args.ambients.add a
  for i in 0 ..< MaxSceneChannels:
    sceneInstance[i].store(0)
    sceneFinished[i].store(0)
  sceneStop.store(0)
  createThread(sceneThread, sceneLoop, args)
  sceneStarted = true

proc setChannel*(i, ambient, instance: int, volume: float, pan: int, pitch = 1.0) =
  ## Channel i plays instance (0 = nothing) of ambient, at volume (Oni's 0..1),
  ## pan and pitch (times the groups' own, like Oni's group pitch). A new
  ## instance starts the ambient from its InSound.
  if i notin 0 ..< MaxSceneChannels: return
  sceneVolume[i].store(int(clamp(volume, 0.0, 1.0) * 1000))
  scenePitch[i].store(int(clamp(pitch, 0.1, 4.0) * 1000))
  scenePan[i].store(clamp(pan, -10000, 10000))
  sceneAmbient[i].store(ambient)
  sceneInstance[i].store(instance)

proc channelFinished*(i, instance: int): bool =
  ## Whether the channel's instance ended by itself (a PlayOnce ambient's
  ## sounds all played, or it can't be played).
  i in 0 ..< MaxSceneChannels and instance != 0 and sceneFinished[i].load == instance

when not defined(windows):
  # A player that quits early must not kill Catwalk with SIGPIPE.
  signal(SIGPIPE, SIG_IGN)
