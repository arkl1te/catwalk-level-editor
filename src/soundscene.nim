## Realtime preview's sound: the level's Sound objects (SNDG), heard from the
## 3D camera the way Oni plays them. Oni_Sound2.c (0x514f20) updates every
## Sound object once a tick, with the camera as the listener:
##
## - A Sphere sound is positional. It plays while the listener is within
##   3 × MaxRadius (Oni's sound distances are world units / 3): full volume up
##   to 3 × MinRadius, then down linearly to silence at 3 × MaxRadius
##   (0x480710). Its ambient's CanPan turns the far ear down, by up to 16.7 dB
##   for a sound straight to the side (0x4853b0). Level quads between the
##   sound and the listener muffle it (0x511a00): one 0.72, two 0.47, three or
##   more 0.05, never below the ambient's MinOcclusion. Oni checks every 12
##   ticks and eases toward it by 0.05 a tick, starting from silence.
## - A Box sound isn't positional. It plays while the listener is inside its
##   box (turned with the object), fading in over 2 seconds on entering and
##   out over 2 seconds on leaving (0x515480). Entering a box whose ambient
##   another Box sound already plays takes that sound over, at its volume.
## - The object's volume is the OSD field OniSplit calls Pitch (obj + 0x58:
##   the one that varies in the game's levels). The one it calls Volume is
##   never read, and nothing changes the pitch.
## - At most the ambient's Treshold of it play at once (0x4821f0). A PlayOnce
##   ambient that ends starts again (InSound first) on the next tick while it
##   can be heard; a Box sound then fades in again.

import std/[math, strutils, tables, times]
import vmath
import levelobjects, camera, geometry, geomops, render, lighting, music, appstate

const
  TicksPerSecond = 60.0
  FadeTicks = 120.0           ## A Box sound's fade in or out.
  OcclusionTicks = 12.0       ## How often a Sphere sound's occlusion is checked...
  OcclusionStep = 0.05        ## ...and how far it moves toward that a tick.
  PanAt = 7'f32               ## Closer than this, a sound isn't panned.
  RebuildEvery = 1.0          ## Seconds between rebuilding the occlusion grid after edits.

type
  BoxFade = enum bfOff, bfFull, bfIn, bfOut

  Source = object
    ambient: int              ## Index into sceneAmbients.
    channel: int              ## -1 = not playing.
    instance: int
    occlusion, occTarget: float
    occAt: float              ## Tick the occlusion was last checked.
    fade: BoxFade
    fadeStart: float          ## Tick the fade began.
    level: float              ## Box: the fade's volume, 0..1.

var
  sources: Table[pointer, Source]      ## By Sound object.
  sceneAmbients: seq[string]           ## What the running scene's channels can play...
  infos: seq[AmbientInfo]              ## ...and their level 0 settings.
  owner: array[MaxSceneChannels, pointer]
  instances = 0
  tick = 0.0                           ## Ticks since the preview started.
  lastTime = 0.0
  grid: Grid
  gridGeo: Geometry
  gridVersion = -1
  gridAt = 0.0
  stamp: seq[int32]
  ray = 0'i32

proc blocksSound(f: Face): bool =
  ## Quads Oni's occlusion rays stop at: it skips SoundTransparent,
  ## NoCollision, NoObjectCollision and 0x40000 quads (mask 0x8044800). Ghosts
  ## and door frames are built without collision.
  (f.flags and (gfSoundTransparent or gfNoCollision or gfNoObjectCollision or 0x40000'u32 or
                gfGhost or gfDoorFrame)) == 0 and not f.isMarkerFace

proc updateGrid(g: Geometry) =
  let now = epochTime()
  if g == gridGeo and (g.version == gridVersion or now - gridAt < RebuildEvery): return
  grid = buildGrid(g, blocksSound)
  gridGeo = g
  gridVersion = g.version
  gridAt = now
  stamp = newSeq[int32](grid.triangles)
  ray = 0

proc occlusion(g: Geometry, src, listener: Vec3, minOcclusion: float): float =
  ## How much of a Sphere sound gets through the quads between it and the
  ## listener. Quads of the furniture the sound sits in don't count (the
  ## first furniture the ray leaves, before it crosses anything else).
  if minOcclusion > 0.99: return 1
  inc ray
  if ray == int32.high:
    for s in stamp.mitems: s = 0
    ray = 1
  var n = 0
  var leading = true
  var piece = -1'i32
  for (t, fi) in crossings(addr grid, src, listener, stamp, ray):
    if n == 0 and t < 0.1: continue
    let f = g.faces[fi]
    if (f.flags and gfFurniture) == 0 or not leading:
      inc n
      leading = false
    elif piece == -1: piece = f.objectId
    elif f.objectId != piece: inc n
  if n == 0: 1.0 else: max(minOcclusion, 0.8 - float(min(n, 3) ^ 2) / 12)

proc numField(o: LevelObject, path: string, default: float): float =
  try: parseFloat(o.node.xpath(path).str.strip) except ValueError: default

proc soundClass(o: LevelObject): string = o.node.xpath("OSD/Class").str.strip

proc stopSource(s: var Source) =
  if s.channel >= 0:
    setChannel(s.channel, s.ambient, 0, 0, 0)
    owner[s.channel] = nil
  s.channel = -1
  s.instance = 0

proc startSource(s: var Source, key: pointer): bool =
  ## Starts the ambient again on a free channel; false when none is free.
  for i in 0 ..< MaxSceneChannels:
    if owner[i] == nil:
      owner[i] = key
      inc instances
      s.channel = i
      s.instance = instances
      return true

proc stopSoundScene*() =
  ## Silences the preview and forgets every Sound object's state.
  stopScene()
  sources.clear()
  sceneAmbients.setLen 0
  infos.setLen 0
  for o in owner.mitems: o = nil
  tick = 0

proc updateSoundScene*(a: App) =
  ## One step of the preview; raises IOError when there's no audio player.
  let now = epochTime()
  let ticks = if lastTime == 0 or now - lastTime > 0.5: 1.0 else: (now - lastTime) * TicksPerSecond
  lastTime = now
  tick += ticks
  let cam = a.camera3D
  # The visible Sound objects, and the ambients they play: a new one restarts
  # the scene with it added (every channel stops; the sounds start again).
  var objs: seq[LevelObject]
  var restart = false
  for o in a.objects:
    if o.tag != "SNDG" or not a.visible(o): continue
    let cls = o.soundClass.toLowerAscii
    if cls.len == 0: continue
    objs.add o
    if cls notin sceneAmbients:
      sceneAmbients.add cls
      restart = true
  if restart or sceneAmbients.len == 0:
    let keep = sceneAmbients
    stopSoundScene()
    sceneAmbients = keep
    for amb in keep: infos.add ambientInfo(amb)
    if keep.len > 0: playScene(keep)
  # Forget deleted, hidden and re-classed objects.
  var seen: Table[pointer, int]
  for o in objs: seen[cast[pointer](o)] = sceneAmbients.find(o.soundClass.toLowerAscii)
  var gone: seq[pointer]
  for k, s in sources.mpairs:
    if seen.getOrDefault(k, -1) != s.ambient:
      s.stopSource()
      gone.add k
  for k in gone: sources.del k
  if a.geo != nil: updateGrid(a.geo)
  # Each ambient's instances still playing (Treshold).
  var count = newSeq[int](sceneAmbients.len)
  for s in sources.mvalues:
    if s.channel >= 0 and channelFinished(s.channel, s.instance): s.stopSource()
    if s.channel >= 0: inc count[s.ambient]
  for o in objs:
    let key = cast[pointer](o)
    let amb = seen[key]
    if key notin sources: sources[key] = Source(ambient: amb, channel: -1, occAt: NegInf)
    let info = infos[amb]
    let volume = o.numField("OSD/Pitch", 1)
    var s = sources[key]
    if o.node.xpath("OSD/Sphere") != nil:
      let minR = o.numField("OSD/Sphere/MinRadius", 0)
      let maxR = o.numField("OSD/Sphere/MaxRadius", 0)
      let d = if cam == nil: Inf else: float((cam.pos - o.pos).length) / 3
      if d > maxR:
        s.stopSource()
      else:
        if s.channel < 0 and count[amb] < info.treshold and s.startSource(key): inc count[amb]
        if s.channel >= 0:
          if tick - s.occAt >= OcclusionTicks:
            s.occTarget = if a.geo == nil: 1.0 else: occlusion(a.geo, o.pos, cam.pos, info.minOcclusion)
            s.occAt = tick
          let step = OcclusionStep * ticks
          s.occlusion = clamp(s.occTarget, s.occlusion - step, s.occlusion + step)
          let near = if d < minR: 1.0 elif maxR > minR: (maxR - d) / (maxR - minR) else: 0.0
          var pan = 0
          let to = o.pos - cam.pos
          if info.canPan and to.length > PanAt:
            let flat = vec2(to.x, to.z)
            let fwd = vec2(cam[].forward.x, cam[].forward.z)
            if flat.length > 1e-4 and fwd.length > 1e-4:
              let angle = arccos(clamp(dot(flat.normalize, fwd.normalize), -1, 1)).float
              let f = abs(angle - PI / 2) / PI + 0.5
              let side = dot(to, cam[].right)
              if side > 0: pan = int(3333 - f * 3333)
              elif side < 0: pan = -int(3333 - f * 3333)
          setChannel(s.channel, amb, s.instance, volume * s.occlusion * near, pan)
    else:
      let lo = parseVec3(o.node.xpath("OSD/Box/Min").str)
      let hi = parseVec3(o.node.xpath("OSD/Box/Max").str)
      var inside = false
      if cam != nil:
        let p = inverse(objectMatrix(o.pos, o.rot)) * cam.pos
        inside = p.x >= min(lo.x, hi.x) and p.x <= max(lo.x, hi.x) and
                 p.y >= min(lo.y, hi.y) and p.y <= max(lo.y, hi.y) and
                 p.z >= min(lo.z, hi.z) and p.z <= max(lo.z, hi.z)
      if s.fade == bfOff:
        if inside:
          var took = false
          for k, other in sources.mpairs:
            if k == key or other.ambient != amb or other.channel < 0 or other.fade == bfOff: continue
            # Its sound carries on here, the fade-in picking up at its volume.
            s.channel = other.channel
            s.instance = other.instance
            owner[s.channel] = key
            s.level = other.level
            s.fadeStart = tick - (FadeTicks - FadeTicks * sqrt(max(0.0, 1 - s.level)))
            other.channel = -1
            other.instance = 0
            other.fade = bfOff
            other.level = 0
            took = true
            break
          if not took:
            s.level = 0
            s.fadeStart = tick
            if count[amb] < info.treshold and s.startSource(key): inc count[amb]
          s.fade = bfIn
      else:
        let t = min(tick - s.fadeStart, FadeTicks)
        if s.fade == bfIn:
          s.level = 1 - (t - FadeTicks) ^ 2 / FadeTicks ^ 2
          if s.level >= 1:
            s.level = 1
            s.fade = bfFull
        elif s.fade == bfOut:
          s.level = 1 - t ^ 2 / FadeTicks ^ 2
        if s.channel < 0 or (s.fade == bfOut and s.level <= 0):
          # Ended (or never started: too many of it playing); tried again next tick.
          s.stopSource()
          s.fade = bfOff
          s.level = 0
        else:
          setChannel(s.channel, amb, s.instance, volume * s.level, 0)
          if not inside:
            if s.fade != bfOut: s.fadeStart = tick
            s.fade = bfOut
          elif s.fade == bfOut:
            s.fade = bfIn   # Oni keeps the fade-out's start, so the volume dips first.
    sources[key] = s
