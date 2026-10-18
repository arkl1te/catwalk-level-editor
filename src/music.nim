## Music preview: plays one of level 0's music tracks the way Oni does (its
## intro, then its loop pieces in random order, back to back).
##
## The first preview extracts the tracks from level0_Final.dat into
## ~/.cache/catwalk/music: OniSplit exports the OSBD ambient sounds and their
## sound groups as XML and the SNDD sounds they use as WAV (MS ADPCM), and
## music.json lists each track's pieces. Playback decodes the WAVs here and
## streams 16-bit PCM to pw-cat (or paplay, or aplay) from a thread.

import std/[os, math, json, strutils, sets, tables, random, atomics, osproc, streams, posix]
import jobs, project

const
  Rate = 22050       ## Every music sound in level 0 is 22050 Hz stereo.
  ChunkFrames = 2048

proc musicDir*(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk" / "music"

proc manifestPath(): string = musicDir() / "music.json"

proc hasMusicCache*(): bool = fileExists(manifestPath())

# --- extraction ------------------------------------------------------------------

proc tagValue(xml, tag: string): string =
  let a = xml.find("<" & tag & ">")
  if a < 0: return ""
  let s = a + tag.len + 2
  let b = xml.find("</" & tag & ">", s)
  if b < 0: "" else: xml[s ..< b].strip

proc groupSounds(xmlDir, group: string): seq[string] =
  ## The SNDD names (e.g. mus_fiteb1.aif) a sound group's permutations play.
  let f = xmlDir / "OSBD" & group & ".grp.xml"
  if group.len == 0 or not fileExists(f): return
  let x = readFile(f)
  var i = 0
  while true:
    let a = x.find("<Sound>", i)
    if a < 0: break
    let b = x.find("</Sound>", a)
    if b < 0: break
    result.add x[a + 7 ..< b].strip
    i = b

proc musicCacheJob*(c: Config, logPath: string): Job =
  let
    work = musicDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    wav = work / "wav"
  var tracks = newJObject()
  var wanted: seq[string]
  let steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, wav]: createDir(d)),
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", oni, c.gameData / "level0_Final.dat"]),
    command("Reading music", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", xml]
      for f in walkFiles(oni / "OSBD*.oni"):
        let n = f.extractFilename
        if n.startsWith("OSBDmus_") or n.startsWith("OSBDatm_"): result.add f),
    action("Listing tracks", proc() =
      var have: HashSet[string]
      for f in walkFiles(oni / "SNDD*.oni"):
        have.incl f.extractFilename["SNDD".len .. ^5].toLowerAscii
      var want: HashSet[string]
      proc pieces(group: string): JsonNode =
        result = newJArray()
        for s in groupSounds(xml, group):
          if s.toLowerAscii in have:
            result.add %s
            want.incl s
      for t in MusicTracks:
        let f = xml / "OSBD" & t & ".amb.xml"
        if not fileExists(f): continue
        let x = readFile(f)
        tracks[t] = %*{"intro": pieces(x.tagValue("InSound")),
                       "base1": pieces(x.tagValue("BaseTrack1")),
                       "base2": pieces(x.tagValue("BaseTrack2"))}
      for s in want: wanted.add s),
    command("Extracting sounds", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:wav", wav]
      var byName: Table[string, string]
      for f in walkFiles(oni / "SNDD*.oni"):
        byName[f.extractFilename["SNDD".len .. ^5].toLowerAscii] = f
      for s in wanted: result.add byName[s.toLowerAscii]),
    action("Writing music", proc() =
      for f in walkFiles(wav / "*.wav"):
        moveFile(f, musicDir() / f.extractFilename["SNDD".len .. ^1].toLowerAscii)
      writeFile(manifestPath(), pretty(tracks))
      removeDir(work))]
  newJob("Extracting music", logPath, steps)

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
  PlayArgs = object
    player: seq[string]
    intro, base1, base2: seq[string]

  Voice = object
    pieces: seq[string]
    last: int
    cur: seq[int16]
    pos, delay: int

var
  stopFlag: Atomic[bool]
  active: Atomic[bool]
  volumeMilli: Atomic[int]
  playerPid: Atomic[int]
  playThread: Thread[PlayArgs]
  started: bool

proc sample(v: var Voice, rng: var Rand): int =
  if v.delay > 0:
    dec v.delay
    return 0
  if v.pos >= v.cur.len:
    if v.pieces.len == 0: return 0
    # Pick a piece at random, not the one just played (Oni's PreventRepeat).
    var k = rng.rand(v.pieces.high)
    if v.pieces.len > 1 and k == v.last: k = (k + 1 + rng.rand(v.pieces.len - 2)) mod v.pieces.len
    v.last = k
    v.cur = decodeWav(v.pieces[k])
    v.pos = 0
    if v.cur.len == 0:
      v.pieces.delete k   # unreadable; don't retry it
      v.last = -1
      return 0
  result = v.cur[v.pos]
  inc v.pos

proc playLoop(args: PlayArgs) {.thread.} =
  var p: Process
  try:
    p = startProcess(args.player[0], args = args.player[1 .. ^1], options = {poUsePath})
    playerPid.store(p.processID)
    let output = p.inputStream
    var rng = initRand()
    var intro: seq[int16]
    for f in args.intro: intro.add decodeWav(f)
    var v1 = Voice(pieces: args.base1, last: -1, cur: intro)
    var v2 = Voice(pieces: args.base2, last: -1, delay: intro.len)
    var buf = newSeq[int16](ChunkFrames * 2)
    while not stopFlag.load:
      if v1.pieces.len == 0 and v2.pieces.len == 0 and v1.pos >= v1.cur.len and
         v2.pos >= v2.cur.len and v2.delay == 0:
        break
      let vol = volumeMilli.load
      for k in 0 ..< buf.len:
        let m = (v1.sample(rng) + v2.sample(rng)) * vol div 1000
        buf[k] = clamp(m, -32768, 32767).int16
      output.writeData(buf[0].addr, buf.len * 2)
      output.flush()
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

proc musicPlaying*(): bool = active.load

proc stopMusic*() =
  if not started: return
  stopFlag.store(true)
  let pid = playerPid.load
  if pid > 0: discard posix.kill(pid.Pid, SIGTERM)
  joinThread(playThread)
  started = false

proc setMusicVolume*(v: float) =
  ## Oni hands DirectSound -33.33 dB * (1 - v) (0x485480), muting 0.05 and
  ## below, so a volume is decibels, not a linear gain.
  let v = clamp(v, 0.0, 1.0)
  let gain = if v <= 0.05: 0.0 else: pow(10.0, -33.33 * (1 - v) / 20)
  volumeMilli.store(int(gain * 1000))

proc playMusic*(track: string, volume: float) =
  ## Starts previewing track; raises IOError when it can't.
  stopMusic()
  let player = playerCommand()
  if player.len == 0: raise newException(IOError, "no audio player found (pw-cat, paplay or aplay)")
  let m = parseFile(manifestPath())
  if not m.hasKey(track): raise newException(IOError, track & " is not in the music cache")
  proc files(key: string): seq[string] =
    for s in m[track][key].getElems: result.add musicDir() / s.getStr.toLowerAscii & ".wav"
  let args = PlayArgs(player: player, intro: files("intro"), base1: files("base1"),
                      base2: files("base2"))
  if args.intro.len + args.base1.len + args.base2.len == 0:
    raise newException(IOError, track & " has no sounds in this copy of Oni")
  setMusicVolume(volume)
  stopFlag.store(false)
  active.store(true)
  createThread(playThread, playLoop, args)
  started = true

# A player that quits early must not kill Catwalk with SIGPIPE.
signal(SIGPIPE, SIG_IGN)
