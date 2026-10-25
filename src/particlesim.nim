## Realtime preview's particles: the level's Particle objects (PART) run
## level 0's particle classes (BINA3RAP) the way Oni's particle system does.
##
## The classes come from OniSplit's XML, extracted once with their textures
## into ~/.cache/catwalk/particles (classes/<name>.xml, textures/TXMP*.xml and
## their TGA frames). Decal textures are per level: they come from the
## project's own oni folder (levelTextureJob).
##
## What the engine does, from the decompiled Oni.exe and the wiki's
## OBD:BINA/PAR3 pages:
## - A PART object creates its particle when the level loads unless its flags
##   have 0x02 (NotInitiallyCreated). The particle sits at the object, turned
##   with it.
## - Every tick (60 a second, FUN_0045cc70): the emitters that are on emit,
##   then the update event's actions run (actions disabled by Enable/Disable
##   actions skipped), then the lifetime counts down. When it runs out the
##   lifetime event runs, or the particle dies if that event is empty or it is
##   already fading out.
## - Emitting (FUN_0045d610): Probability is the chance of each emission,
##   Copies the burst size (a fraction is the chance of one more). Position
##   and direction are in the emitting particle's frame (its +Y ahead, +Z up);
##   velocity = speed × direction (+ the parent's velocity with
##   EmitWithParentVelocity). The new particle's frame comes from the
##   emitter's Orientation (its +Y) and OrientationUp (its +Z), X = Y × Z
##   (FUN_0045b320).
## - Action handlers (table at 0x536078, 0xC0 bytes per type): gravity is
##   98 units/s² (0x52a054); air resistance and drift ease exponentially.
## - Drawing (FUN_00461150): Scale is the half-width, YScale (when enabled)
##   the half-length along the travel axis, ScaleToVelocity multiplies the
##   scale by speed + 1. A texture's Speed is ticks per frame.
##
## - Contrails (FUN_00461d20): a contrail particle draws a ribbon, Scale
##   wide, from where it is to the particle it links to (same class). A
##   contrail emitter draws one to the last particle of the emitter that links
##   to its own previous one. Contrail faces the camera; OrientedContrail
##   spreads along the particle's X axis. U runs across, V along (0 here, 1
##   there).
## - Geometry (FUN_00460800): the M3GM named by TexGeom, in the particle's
##   orientation (else its velocity's frame), at its position, Scale times
##   its size, with Alpha; no tint.
##
## Not emulated: sounds, damage, attractors, characters, impact effects.

import std/[os, strutils, tables, sets, math, random, xmlparser, xmltree, hashes]
import vmath
import geometry, lighting, render, jobs, project, collada

const
  ParticleCacheVersion = "2"   ## 2: geometry particles' models.
  TickTime = 1'f32 / 60
  Gravity = 98'f32               ## Apply Gravity's "normal gravity" (0x52a054), units/s².
  MaxParticles = 20_000
  MaxTicksPerFrame = 6           ## Behind by more than this, the rest is skipped.
  NotInitiallyCreated = 0x02     ## PART flag.
  RebuildEvery = 1.0             ## Seconds between rebuilding the collision grid after edits.
  DecalReach = 16'f32            ## How far a placed decal looks for the surface it goes on.

# --- cache ------------------------------------------------------------------------

proc particleDir*(): string =
  let xdg = getEnv("XDG_CACHE_HOME")
  (if xdg.len > 0: xdg else: getHomeDir() / ".cache") / "catwalk" / "particles"

proc hasParticleCache*(): bool =
  let v = particleDir() / "version"
  fileExists(v) and readFile(v).strip == ParticleCacheVersion

proc tagValue(xml, tag: string): string =
  let a = xml.find("<" & tag & ">")
  if a < 0: return ""
  let s = a + tag.len + 2
  let b = xml.find("</" & tag & ">", s)
  if b < 0: "" else: xml[s ..< b].strip

proc texturesOf(dir, prefix: string, geometry = false): HashSet[string] =
  ## The texture names the particle classes in dir draw with, or (geometry)
  ## the M3GM models they draw.
  for f in walkFiles(dir / prefix & "*.xml"):
    let x = readFile(f)
    let t = x.tagValue("TexGeom")
    if t.len > 0 and (x.tagValue("DisplayType") == "Geometry") == geometry: result.incl t

proc particleCacheJob*(c: Config, logPath: string): Job =
  let
    work = particleDir() / "work"
    oni = work / "oni"
    xml = work / "xml"
    txml = work / "txml"
    dae = work / "dae"
  let steps = @[
    action("Preparing", proc() =
      if dirExists(work): removeDir(work)
      for d in [oni, xml, txml, dae]: createDir(d)),
    command("Reading level 0", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-export", oni, c.gameData / "level0_Final.dat"]),
    command("Reading particle classes", proc(): seq[string] =
      @[c.mono, c.oniSplit, "-extract:xml", xml, oni / "BINA3RAP*.oni"]),
    # Each model's .dae names its image after the model's TXMP.
    command("Extracting particle models", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:dae", dae]
      for t in texturesOf(xml, "BINA3RAP", geometry = true):
        if fileExists(oni / "M3GM" & t & ".oni"): result.add oni / "M3GM" & t & ".oni"
      if result.len == 4: result = @["true"]),
    # OniSplit finds an animated texture's frames next to its TXMP.
    command("Extracting particle textures", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", txml]
      var names = texturesOf(xml, "BINA3RAP")
      for f in walkFiles(dae / "images" / "*.tga"): names.incl f.splitFile.name
      for t in names:
        if fileExists(oni / "TXMP" & t & ".oni"): result.add oni / "TXMP" & t & ".oni"
      if result.len == 4: result = @["true"]),
    action("Writing particles", proc() =
      let classes = particleDir() / "classes"
      let textures = particleDir() / "textures"
      let models = particleDir() / "models"
      for d in [classes, textures, models]:
        if dirExists(d): removeDir(d)
        createDir(d)
      for f in walkFiles(xml / "BINA3RAP*.xml"):
        moveFile(f, classes / f.extractFilename["BINA3RAP".len .. ^1].toLowerAscii)
      for f in walkFiles(txml / "*"): moveFile(f, textures / f.extractFilename)
      for f in walkFiles(dae / "*.dae"): moveFile(f, models / f.extractFilename)
      if dirExists(dae / "images"): moveDir(dae / "images", models / "images")
      writeFile(particleDir() / "version", ParticleCacheVersion)
      removeDir(work))]
  newJob("Extracting particles", logPath, steps)

proc levelTextureDir*(oniDir: string): string =
  ## Where a project's own particle textures (decals) are extracted to.
  particleDir() / "level" / $hash(oniDir.absolutePath)

proc levelTextureJob*(c: Config, oniDir: string, names: seq[string], logPath: string): Job =
  ## Extracts the textures the particles use that level 0 doesn't have from
  ## the project's oni folder.
  let dst = levelTextureDir(oniDir)
  newJob("Extracting the level's decal textures", logPath, @[
    action("Preparing", proc() = createDir(dst)),
    command("Extracting decal textures", proc(): seq[string] =
      result = @[c.mono, c.oniSplit, "-extract:xml", dst]
      for n in names:
        if fileExists(oniDir / "TXMP" & n & ".oni"): result.add oniDir / "TXMP" & n & ".oni"
      if result.len == 4: result = @["true"]),
    action("Done", proc() = writeFile(dst / "done", names.join("\n")))])

# --- classes ----------------------------------------------------------------------

type
  ValKind = enum vNone, vConst, vRange, vBell, vVar

  Value = object
    ## A class field or action parameter: a constant, a random range or bell
    ## curve (rolled each time it's read), or one of the particle's variables.
    kind: ValKind
    a, b: Vec4                   ## Floats use x; colors are r, g, b, a in 0..1.
    slot: int

  ActKind = enum
    akNone, akAnimateLinear = "AnimateLinear", akAnimateAccelerated = "AnimateAccelerated",
    akAnimateRandom = "AnimateRandom", akAnimatePingPong = "AnimatePingPong",
    akAnimateLoop = "AnimateLoop", akAnimateToValue = "AnimateToValue",
    akColorInterpolate = "ColorInterpolate", akFadeOut = "FadeOut",
    akEnableAtTime = "EnableAtTime", akDisableAtTime = "DisableAtTime", akDie = "Die",
    akSetLifetime = "SetLifetime", akEmitActivate = "EmitActivate",
    akEmitDeactivate = "EmitDeactivate", akEmitParticles = "EmitParticles",
    akChangeClass = "ChangeClass", akKillLastEmitted = "KillLastEmitted",
    akExplodeLastEmitted = "ExplodeLastEmitted", akExplode = "Explode", akStop = "Stop",
    akRotateX = "RotateX", akRotateY = "RotateY", akRotateZ = "RotateZ",
    akMoveLine = "MoveLine", akMoveGravity = "MoveGravity", akMoveSpiral = "MoveSpiral",
    akMoveResistance = "MoveResistance", akMoveDrift = "MoveDrift",
    akSetVelocity = "SetVelocity", akSpiralTangent = "SpiralTangent",
    akKillBeyondPoint = "KillBeyondPoint", akCollisionEffect = "CollisionEffect",
    akStickToWall = "StickToWall", akBounce = "Bounce", akChop = "Chop",
    akShow = "Show", akHide = "Hide", akSetTextureTick = "SetTextureTick",
    akRandomTextureFrame = "RandomTextureFrame", akSetVariable = "SetVariable",
    akRecalculateAll = "RecalculateAll", akEnableAbove = "EnableAbove",
    akEnableBelow = "EnableBelow", akEnableNow = "EnableNow", akDisableNow = "DisableNow",
    akStopIfSlow = "StopIfSlow"

  Action = object
    kind: ActKind
    idx: int                     ## Index in the class's whole action list.
    tgt: seq[int]                ## Variables it writes (-1 = none).
    p: seq[Value]
    str: string                  ## CollisionEffect's class.

  RateKind = enum rNone, rContinuous, rRandom, rInstant, rDistance
  PosKind = enum psPoint, psLine, psCircle, psSphere, psOffset, psCylinder
  DirKind = enum dStraight, dRandom, dCone, dRing, dOffset

  Emitter = object
    cls: string
    initiallyOn, countEmits, offAtThreshold, parentVel, orientToVel: bool
    threshold: int
    probability, copies: float32
    link: int                    ## -1 none, -2 the emitting particle, -3 its link, 0.. emitter's last.
    rate: RateKind
    r: array[2, Value]
    pos: PosKind
    pp: array[3, Value]
    dir: DirKind
    dp: array[3, Value]
    stratified: bool
    sp: array[2, Value]
    orient, orientUp: string

  DisplayKind = enum dkSprite, dkRotatedSprite, dkBeam, dkArrow, dkFlat, dkContrail,
                     dkOrientedContrail, dkDiscus, dkDecal, dkGeometry

  PClass = ref object
    name: string
    lifetime: Value
    collideWalls, initiallyHidden, lockToLink: bool
    hasVelocity, hasOrientation, hasOffset: bool
    display: DisplayKind
    texture: string
    invisible, scaleToVelocity, useYScale, edgeFade, oneSidedEdgeFade, lensFlare: bool
    scale, yScale, rotation, alpha, tint: Value
    edgeFadeMin, edgeFadeMax: float32
    hasContrail, contrailEmitter: bool  ## HasContrailData, IsContrailEmitter.
    maxContrail: Value           ## Longer segments aren't drawn (0 = no limit).
    varNames: seq[string]
    varInit: seq[Value]
    events: array[16, seq[Action]]
    actionCount: int
    emitters: seq[Emitter]

  PMesh = ref object
    ## A geometry particle's model: triangles by the texture they're drawn with.
    batches: seq[tuple[tex, image: string, verts: seq[DaeVertex]]]

  TexInfo = object
    frames: seq[string]          ## TGA paths.
    speed: int                   ## Ticks per frame.
    additive, pingPong, randomOrder, localTime, dontAnimate: bool

const EventNames = ["Update", "Pulse", "Start", "Stop", "BackgroundFxStart", "BackgroundFxStop",
                    "HitWall", "HitCharacter", "Lifetime", "Explode", "BrokenLink", "Create",
                    "Die", "NewAttractor", "DelayStart", "DelayStop"]
const
  evUpdate = 0
  evStart = 2
  evStop = 3
  evHitWall = 6
  evLifetime = 8
  evExplode = 9
  evBrokenLink = 10
  evCreate = 11
  evDie = 12

proc sub(n: XmlNode, tag: string): XmlNode =
  if n == nil: return nil
  for c in n:
    if c.kind == xnElement and c.tag == tag: return c

proc text(n: XmlNode, tag: string): string =
  let c = n.sub(tag)
  if c == nil: "" else: c.innerText.strip

proc isTrue(s: string): bool = s.toLowerAscii in ["true", "1"]

proc parseNums(s: string, color: bool): (bool, Vec4) =
  ## "1.5" or, for a color, "R G B [A]" (0..255).
  let parts = s.splitWhitespace
  if parts.len == 0: return
  var v: array[4, float32] = [0'f32, 0, 0, if color: 1'f32 else: 0'f32]
  try:
    for i, p in parts:
      if i > 3: break
      v[i] = parseFloat(p).float32 / (if color: 255'f32 else: 1'f32)
  except ValueError: return
  if color and parts.len < 3: return
  (true, vec4(v[0], v[1], v[2], v[3]))

proc parseValue(n: XmlNode, cls: PClass, color = false): Value =
  if n == nil: return
  for c in n:
    if c.kind != xnElement: continue
    case c.tag
    of "Random":
      let (oa, a) = parseNums(c.attr("Min"), color)
      let (ob, b) = parseNums(c.attr("Max"), color)
      if oa and ob: return Value(kind: vRange, a: a, b: b)
    of "BellCurve":
      let (oa, a) = parseNums(c.attr("Mean"), color)
      let (ob, b) = parseNums(c.attr("StdDev"), color)
      if oa and ob: return Value(kind: vBell, a: a, b: b)
    else: discard
    return
  let s = n.innerText.strip
  if s.len == 0: return
  let (ok, v) = parseNums(s, color)
  if ok: return Value(kind: vConst, a: v)
  let i = cls.varNames.find(s)
  if i >= 0: Value(kind: vVar, slot: i) else: Value()

proc spec(k: ActKind): (seq[string], seq[string]) =
  ## The variables an action writes and its parameters, by XML name.
  case k
  of akAnimateLinear: (@["Target"], @["Rate"])
  of akAnimateAccelerated: (@["Target", "Velocity"], @["Acceleration"])
  of akAnimateRandom, akAnimateLoop: (@["Target"], @["Min", "Max", "Rate"])
  of akAnimatePingPong: (@["Target", "State"], @["Min", "Max", "Rate"])
  of akAnimateToValue: (@["Target"], @["Rate", "Value"])
  of akColorInterpolate: (@["Target"], @["Color0", "Color1", "Amount"])
  of akFadeOut: (@[], @["TimeToDie"])
  of akEnableAtTime, akDisableAtTime: (@[], @["Action", "Lifetime"])
  of akSetLifetime: (@[], @["Time"])
  of akEmitActivate, akEmitDeactivate, akKillLastEmitted, akExplodeLastEmitted, akChangeClass:
    (@[], @["Emitter"])
  of akEmitParticles: (@[], @["Emitter", "Particles"])
  of akRotateX, akRotateY, akRotateZ: (@[], @["Space", "Rate", "RotateVelocity"])
  of akMoveGravity: (@[], @["Fraction"])
  of akMoveSpiral: (@["Theta"], @["Radius", "RotateSpeed"])
  of akMoveResistance: (@[], @["Resistance", "MinimumVelocity"])
  of akMoveDrift: (@[], @["Acceleration", "MaxSpeed", "SidewaysDecay", "DirX", "DirY", "DirZ", "Space"])
  of akSetVelocity: (@[], @["Speed", "Space", "NoSideways"])
  of akSpiralTangent: (@[], @["Theta", "Radius", "Rotate_speed"])
  of akKillBeyondPoint: (@[], @["Direction", "Value"])
  of akCollisionEffect: (@[], @["WallOffset", "Orientation", "Attach"])
  of akBounce: (@[], @["ElasticDirect", "ElasticGlancing"])
  of akSetTextureTick: (@[], @["Tick"])
  of akSetVariable: (@["Target"], @["Value"])
  of akEnableAbove, akEnableBelow: (@[], @["Action", "Variable", "Threshold"])
  of akEnableNow, akDisableNow: (@[], @["Action"])
  of akStopIfSlow: (@[], @["Speed"])
  else: (@[], @[])

proc parseEmitter(n: XmlNode, cls: PClass): Emitter =
  result.cls = n.text("Class").toLowerAscii
  let flags = n.text("Flags")
  result.initiallyOn = "InitiallyOn" in flags
  result.countEmits = "IncreaseParticleCount" in flags
  result.offAtThreshold = "TurnOffAtTreshold" in flags or "TurnOffAtThreshold" in flags
  result.parentVel = "ParentVelocity" in flags
  result.orientToVel = "OrientToVelocity" in flags
  try: result.threshold = parseInt(n.text("TurnOffTreshold"))
  except ValueError: result.threshold = 0
  result.probability = (try: parseFloat(n.text("Probability")).float32 except ValueError: 1'f32)
  result.copies = (try: parseFloat(n.text("Copies")).float32 except ValueError: 1'f32)
  let link = n.text("LinkTo")
  result.link =
    if link.len == 0 or link == "None": -1
    elif link == "this": -2
    elif link == "link": -3
    else: (try: parseInt(link) except ValueError: -1)
  proc first(sect: string): XmlNode =
    let s = n.sub(sect)
    if s == nil: return nil
    for c in s:
      if c.kind == xnElement: return c
  let r = first("Rate")
  if r != nil:
    case r.tag
    of "Continous", "Continuous":
      result.rate = rContinuous
      result.r[0] = parseValue(r.sub("Interval"), cls)
    of "Random":
      result.rate = rRandom
      result.r[0] = parseValue(r.sub("MinInterval"), cls)
      result.r[1] = parseValue(r.sub("MaxInterval"), cls)
    of "Instant": result.rate = rInstant
    of "Distance":
      result.rate = rDistance
      result.r[0] = parseValue(r.sub("Distance"), cls)
    else: result.rate = rNone
  let p = first("Position")
  if p != nil:
    case p.tag
    of "Line":
      result.pos = psLine
      result.pp[0] = parseValue(p.sub("Radius"), cls)
    of "Circle", "Sphere":
      result.pos = if p.tag == "Circle": psCircle else: psSphere
      result.pp[0] = parseValue(p.sub("InnerRadius"), cls)
      result.pp[1] = parseValue(p.sub("OuterRadius"), cls)
    of "Offset":
      result.pos = psOffset
      for i, t in ["X", "Y", "Z"]: result.pp[i] = parseValue(p.sub(t), cls)
    of "Cylinder":
      result.pos = psCylinder
      for i, t in ["Height", "InnerRadius", "OuterRadius"]: result.pp[i] = parseValue(p.sub(t), cls)
    else: result.pos = psPoint
  let d = first("Direction")
  if d != nil:
    case d.tag
    of "Random": result.dir = dRandom
    of "Cone":
      result.dir = dCone
      result.dp[0] = parseValue(d.sub("Angle"), cls)
      result.dp[1] = parseValue(d.sub("CenterBias"), cls)
    of "Inaccurate":
      result.dir = dCone   # No shooter: its base angle.
      result.dp[0] = parseValue(d.sub("BaseAngle"), cls)
      result.dp[1] = parseValue(d.sub("CenterBias"), cls)
    of "Ring":
      result.dir = dRing
      result.dp[0] = parseValue(d.sub("Angle"), cls)
      result.dp[1] = parseValue(d.sub("Offset"), cls)
    of "Offset":
      result.dir = dOffset
      for i, t in ["X", "Y", "Z"]: result.dp[i] = parseValue(d.sub(t), cls)
    else: result.dir = dStraight
  let s = first("Speed")
  if s != nil:
    if s.tag == "Stratified":
      result.stratified = true
      result.sp[0] = parseValue(s.sub("Speed1"), cls)
      result.sp[1] = parseValue(s.sub("Speed2"), cls)
    else:
      result.sp[0] = parseValue(s.sub("Speed"), cls)
  result.orient = n.text("Orientation")
  result.orientUp = n.text("OrientationUp")

proc parseClass(path: string): PClass =
  var s = readFile(path)
  if s.startsWith("\xEF\xBB\xBF"): s = s[3 .. ^1]
  let root = parseXml(s)
  let n = root.sub("Particle")
  if n == nil: return nil
  let cls = PClass(name: n.attr("Name").toLowerAscii)
  let vars = n.sub("Variables")
  if vars != nil:
    for v in vars:
      if v.kind == xnElement: cls.varNames.add v.attr("Name")
    for v in vars:
      if v.kind == xnElement: cls.varInit.add parseValue(v, cls, color = v.tag == "Color")
  let o = n.sub("Options")
  cls.lifetime = parseValue(o.sub("Lifetime"), cls)
  cls.collideWalls = o.text("CollideWithWalls").isTrue
  cls.initiallyHidden = o.text("InitiallyHidden").isTrue
  cls.lockToLink = o.text("LockPositionToLink").isTrue
  let pr = n.sub("Properties")
  cls.hasVelocity = pr.text("HasVelocity").isTrue
  cls.hasOrientation = pr.text("HasOrientation").isTrue
  cls.hasOffset = pr.text("HasPositionOffset").isTrue
  cls.hasContrail = pr.text("HasContrailData").isTrue
  let a = n.sub("Appearance")
  cls.display = case a.text("DisplayType")
    of "RotatedSprite": dkRotatedSprite
    of "Beam": dkBeam
    of "Arrow": dkArrow
    of "Flat": dkFlat
    of "Contrail": dkContrail
    of "OrientedContrail": dkOrientedContrail
    of "Discus": dkDiscus
    of "Decal": dkDecal
    of "Geometry": dkGeometry
    else: dkSprite
  cls.texture = a.text("TexGeom")
  cls.invisible = a.text("Invisible").isTrue
  cls.scaleToVelocity = a.text("ScaleToVelocity").isTrue
  cls.useYScale = a.text("UseSeparateYScale").isTrue
  cls.edgeFade = a.text("FadeOutOnEdge").isTrue
  cls.oneSidedEdgeFade = a.text("OneSidedEdgeFade").isTrue
  cls.lensFlare = a.text("LensFlare").isTrue
  cls.contrailEmitter = a.text("IsContrailEmitter").isTrue
  cls.maxContrail = parseValue(a.sub("MaxContrailDistance"), cls)
  cls.edgeFadeMin = (try: parseFloat(a.text("EdgeFadeMin")).float32 except ValueError: 0.5'f32)
  cls.edgeFadeMax = (try: parseFloat(a.text("EdgeFadeMax")).float32 except ValueError: 1'f32)
  cls.scale = parseValue(a.sub("Scale"), cls)
  cls.yScale = parseValue(a.sub("YScale"), cls)
  cls.rotation = parseValue(a.sub("Rotation"), cls)
  cls.alpha = parseValue(a.sub("Alpha"), cls)
  cls.tint = parseValue(a.sub("Tint"), cls, color = true)
  let ev = n.sub("Events")
  var idx = 0
  for e, name in EventNames:
    let en = if ev == nil: nil else: ev.sub(name)
    if en == nil: continue
    for an in en:
      if an.kind != xnElement: continue
      var act = Action(kind: parseEnum[ActKind](an.tag, akNone), idx: idx)
      inc idx
      let (tgts, params) = spec(act.kind)
      for t in tgts: act.tgt.add cls.varNames.find(an.text(t))
      let colorTarget = act.tgt.len > 0 and act.tgt[0] >= 0 and act.tgt[0] < cls.varInit.len and
                        an.tag in ["SetVariable", "ColorInterpolate"]
      for p in params:
        let isColor = p in ["Color0", "Color1"] or (colorTarget and p == "Value" and
                      parseNums(an.text(p), true)[0])
        act.p.add parseValue(an.sub(p), cls, color = isColor)
      if act.kind == akCollisionEffect: act.str = an.text("Effect").toLowerAscii
      cls.events[e].add act
  cls.actionCount = idx
  let ems = n.sub("Emitters")
  if ems != nil:
    for em in ems:
      if em.kind == xnElement and em.tag == "Emitter": cls.emitters.add parseEmitter(em, cls)
  cls

proc parseTexture(path: string): TexInfo =
  var s = readFile(path)
  if s.startsWith("\xEF\xBB\xBF"): s = s[3 .. ^1]
  let t = parseXml(s).sub("Texture")
  if t == nil: return
  let flags = t.text("Flags")
  result.additive = "AdditiveBlend" in flags
  result.pingPong = "AnimPingPong" in flags
  result.randomOrder = "AnimRandom" in flags
  result.localTime = "AnimUseLocalTime" in flags
  result.dontAnimate = "AnimDontAnimate" in flags or "AnimIgnoreGlobalTime" in flags
  result.speed = max(1, (try: parseInt(t.text("Speed")) except ValueError: 1))
  for c in t:
    if c.kind == xnElement and c.tag == "Image":
      result.frames.add path.parentDir / c.innerText.strip

# --- simulation -----------------------------------------------------------------

type
  EmState = object
    on, fresh: bool
    count: int
    next: float32                ## Particle age of the next emission.
    last: Particle
    lastAt: float32              ## Sim time of the last emission.

  Particle = ref object
    cls: PClass
    pos, vel, offset, prev: Vec3
    ax: array[3, Vec3]           ## Orientation: X, Y (ahead), Z (up).
    vars: seq[Vec4]
    life: float32                ## Seconds left; 0 = no limit.
    fade, fadeTime: float32      ## Fading out when fadeTime > 0.
    hidden, dead, dying, orientToVel: bool
    snapped: bool                ## A decal moved onto the surface behind it (sprites).
    disabled: seq[bool]
    ems: seq[EmState]
    link: Particle
    age, texTick: float32
    decalScale: Vec2
    hit: bool
    hitPos, hitNrm: Vec3
    cpos, cwidth: Vec3           ## Contrail point this frame: where, and half its width.
    ccol: Vec4                   ## Its tint and alpha.
    cframe: int                  ## The triangles() call that set them.

  ParticleSim* = ref object
    classes: Table[string, PClass]
    missingClasses*: HashSet[string]
    textures: Table[string, TexInfo]
    missingTextures*: HashSet[string]  ## Not in level 0: looked for in the level (levelTextureDir).
    levelTextures*: string             ## That folder ("" = none).
    parts: seq[Particle]
    rng: Rand
    time, pending: float32
    geo: Geometry
    grid: Grid
    gridVersion: int
    gridAt: float
    stamp: seq[int32]
    ray: int32
    meshes: Table[string, PMesh]       ## Geometry particles' models, by lower-case name.
    frameNo: int

proc newParticleSim*(): ParticleSim =
  ParticleSim(rng: initRand(0x5EED), gridVersion: -1)

proc classOf(s: ParticleSim, name: string): PClass =
  let key = name.toLowerAscii
  if key.len == 0: return nil
  if key in s.classes: return s.classes[key]
  var cls: PClass
  let f = particleDir() / "classes" / key & ".xml"
  if fileExists(f):
    try: cls = parseClass(f)
    except CatchableError: cls = nil
  if cls == nil: s.missingClasses.incl key
  s.classes[key] = cls
  cls

proc textureOf(s: ParticleSim, name: string): TexInfo =
  if name in s.textures: return s.textures[name]
  for dir in [particleDir() / "textures", s.levelTextures]:
    if dir.len == 0: continue
    let f = dir / "TXMP" & name & ".xml"
    if fileExists(f):
      try: result = parseTexture(f)
      except CatchableError: discard
      if result.frames.len > 0: break
  if result.frames.len == 0: s.missingTextures.incl name
  s.textures[name] = result

proc forgetMissingTextures*(s: ParticleSim) =
  ## After the level's textures were extracted: look them up again.
  for n in s.missingTextures: s.textures.del n
  s.missingTextures.clear()

proc rnd(s: ParticleSim): float32 = s.rng.rand(1.0).float32

proc gauss(s: ParticleSim): float32 =
  let u = max(s.rnd, 1e-6'f32)
  sqrt(-2 * ln(u)) * cos(2 * PI.float32 * s.rnd)

proc eval(s: ParticleSim, v: Value, p: Particle): Vec4 =
  case v.kind
  of vNone: vec4(0, 0, 0, 0)
  of vConst: v.a
  of vRange: v.a + (v.b - v.a) * s.rnd
  of vBell: v.a + v.b * s.gauss
  of vVar: (if p != nil and v.slot < p.vars.len: p.vars[v.slot] else: vec4(0, 0, 0, 0))

proc f(s: ParticleSim, v: Value, p: Particle, default = 0'f32): float32 =
  if v.kind == vNone: default else: s.eval(v, p).x

proc rotateAround(v, axis: Vec3, deg: float32): Vec3 =
  ## Right-handed (counterclockwise looking down the axis), as Oni turns.
  let a = deg.degToRad
  let k = axis.normalize
  v * cos(a) + cross(k, v) * sin(a) + k * dot(k, v) * (1 - cos(a))

proc frame(dir, up: Vec3): array[3, Vec3] =
  ## Y along dir, Z toward up, X = Y × Z (FUN_0045b320).
  var y = if dir.length > 1e-6: dir.normalize else: vec3(0, 1, 0)
  var z = up - y * dot(up, y)
  if z.length < 1e-4:
    let alt = if abs(y.y) < 0.9: vec3(0, 1, 0) else: vec3(1, 0, 0)
    z = alt - y * dot(alt, y)
  z = z.normalize
  [cross(y, z), y, z]

proc axisChoice(name: string, parent: array[3, Vec3], vel, toEmitter: Vec3, fallback: Vec3): Vec3 =
  case name
  of "LocalPosX": parent[0]
  of "LocalNegX": -parent[0]
  of "LocalPosY": parent[1]
  of "LocalNegY": -parent[1]
  of "LocalPosZ": parent[2]
  of "LocalNegZ": -parent[2]
  of "WorldPosX": vec3(1, 0, 0)
  of "WorldNegX": vec3(-1, 0, 0)
  of "WorldPosY": vec3(0, 1, 0)
  of "WorldNegY": vec3(0, -1, 0)
  of "WorldPosZ": vec3(0, 0, 1)
  of "WorldNegZ": vec3(0, 0, -1)
  of "Velocity": (if vel.length > 1e-6: vel.normalize else: fallback)
  of "ReverseVelocity": (if vel.length > 1e-6: -vel.normalize else: fallback)
  of "TowardsEmitter": (if toEmitter.length > 1e-6: toEmitter.normalize else: fallback)
  of "AwayFromEmitter": (if toEmitter.length > 1e-6: -toEmitter.normalize else: fallback)
  else: fallback

proc run(s: ParticleSim, p: Particle, ev: int): bool
proc kill(s: ParticleSim, p: Particle)

proc initVars(s: ParticleSim, p: Particle) =
  p.vars.setLen p.cls.varInit.len
  for i, v in p.cls.varInit: p.vars[i] = s.eval(v, p)

proc create(s: ParticleSim, cls: PClass, pos: Vec3, ax: array[3, Vec3]): Particle =
  ## A new particle (its create event is run by the caller once it's placed).
  if cls == nil or s.parts.len >= MaxParticles: return nil
  result = Particle(cls: cls, pos: pos, prev: pos, ax: ax, hidden: cls.initiallyHidden,
                    decalScale: vec2(1, 1))
  s.initVars(result)
  result.life = max(0'f32, s.f(cls.lifetime, result))
  result.disabled = newSeq[bool](cls.actionCount)
  result.ems = newSeq[EmState](cls.emitters.len)
  for i, e in cls.emitters:
    result.ems[i] = EmState(on: e.initiallyOn, fresh: true)
  s.parts.add result

proc emitOnce(s: ParticleSim, p: Particle, ei: int) =
  ## One emission of emitter ei: a burst of Copies particles, by Probability.
  let e = p.cls.emitters[ei]
  if e.probability < 1 and s.rnd >= e.probability: return
  var n = int(e.copies)
  if s.rnd < e.copies - n.float32: inc n
  let cls = s.classOf(e.cls)
  let parentAx = if p.cls.hasOrientation: p.ax else: [vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)]
  for k in 0 ..< n:
    # Where, in the emitting particle's frame, and how far out (Stratified speed).
    var local = vec3(0, 0, 0)
    var frac = 0'f32
    case e.pos
    of psPoint: discard
    of psLine:
      let t = s.rnd * 2 - 1
      local = vec3(s.f(e.pp[0], p) * t, 0, 0)
      frac = abs(t)
    of psCircle, psCylinder:
      let (inner, outer) = if e.pos == psCircle: (s.f(e.pp[0], p), s.f(e.pp[1], p))
                           else: (s.f(e.pp[1], p), s.f(e.pp[2], p))
      let ang = s.rnd * 2 * PI.float32
      frac = s.rnd
      let r = inner + (outer - inner) * frac
      local = vec3(cos(ang) * r, 0, sin(ang) * r)
      if e.pos == psCylinder: local.y = s.rnd * s.f(e.pp[0], p)
    of psSphere:
      frac = s.rnd
      let r = s.f(e.pp[0], p) + (s.f(e.pp[1], p) - s.f(e.pp[0], p)) * frac
      var d: Vec3
      while true:
        d = vec3(s.rnd * 2 - 1, s.rnd * 2 - 1, s.rnd * 2 - 1)
        let l = d.length
        if l <= 1 and l > 1e-3: break
      local = d.normalize * r
    of psOffset:
      local = vec3(s.f(e.pp[0], p), s.f(e.pp[1], p), s.f(e.pp[2], p))
    # Which way, in that frame (+Y ahead).
    var dir = vec3(0, 1, 0)
    case e.dir
    of dStraight: discard
    of dRandom:
      while true:
        dir = vec3(s.rnd * 2 - 1, s.rnd * 2 - 1, s.rnd * 2 - 1)
        let l = dir.length
        if l <= 1 and l > 1e-3: break
      dir = dir.normalize
    of dCone:
      # FUN_0045e990: a fraction of the angle; a center bias reshapes it.
      var t = s.rnd
      let bias = s.f(e.dp[1], p)
      if bias != 0: t = pow(t, pow(2'f32, bias))
      frac = t
      let th = (t * s.f(e.dp[0], p)).degToRad
      let ph = s.rnd * 2 * PI.float32
      dir = vec3(cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
    of dRing:
      let th = s.f(e.dp[0], p).degToRad
      let ph = s.f(e.dp[1], p).degToRad + k.float32 * 2 * PI.float32 / max(n, 1).float32
      dir = vec3(cos(ph) * sin(th), cos(th), sin(ph) * sin(th))
    of dOffset:
      dir = vec3(s.f(e.dp[0], p), s.f(e.dp[1], p), s.f(e.dp[2], p))
    let speed = if e.stratified: s.f(e.sp[0], p) + (s.f(e.sp[1], p) - s.f(e.sp[0], p)) * frac
                else: s.f(e.sp[0], p)
    let worldLocal = parentAx[0] * local.x + parentAx[1] * local.y + parentAx[2] * local.z
    let worldDir = parentAx[0] * dir.x + parentAx[1] * dir.y + parentAx[2] * dir.z
    let base = p.pos + (if p.cls.hasOffset: p.offset else: vec3(0, 0, 0))
    let c = s.create(cls, base + worldLocal, parentAx)
    if c == nil: return
    if cls.hasOffset:
      c.pos = base
      c.offset = worldLocal
    c.prev = c.pos
    if cls.hasVelocity:
      c.vel = worldDir * speed
      if e.parentVel and p.cls.hasVelocity: c.vel += p.vel
    let fallbackY = parentAx[1]
    let y = axisChoice(if e.orient.len > 0: e.orient else: "LocalPosY", parentAx, c.vel, -worldLocal, fallbackY)
    let z = axisChoice(if e.orientUp.len > 0: e.orientUp else: "LocalPosZ", parentAx, c.vel, -worldLocal, parentAx[2])
    c.ax = frame(y, z)
    c.orientToVel = e.orientToVel
    c.decalScale = p.decalScale
    c.link = case e.link
      of -1: nil
      of -2: p
      of -3: p.link
      else: (if e.link in 0 ..< p.ems.len: p.ems[e.link].last else: nil)
    p.ems[ei].last = c
    p.ems[ei].lastAt = s.time
    discard s.run(c, evCreate)
  if e.countEmits:
    inc p.ems[ei].count
    if e.offAtThreshold and p.ems[ei].count >= e.threshold: p.ems[ei].on = false

proc runEmitters(s: ParticleSim, p: Particle) =
  for i, e in p.cls.emitters:
    template st: untyped = p.ems[i]
    if not st.on or p.dead: continue
    case e.rate
    of rNone: discard
    of rContinuous, rRandom:
      if st.fresh:
        st.fresh = false
        st.next = p.age
      var guard = 0
      while st.on and not p.dead and st.next <= p.age + 1e-5 and guard < 100:
        s.emitOnce(p, i)
        let interval = if e.rate == rContinuous: s.f(e.r[0], p)
                       else:
                         let (lo, hi) = (s.f(e.r[0], p), s.f(e.r[1], p))
                         if hi > lo: lo + (hi - lo) * s.rnd else: lo
        st.next += max(interval, 0.001'f32)
        inc guard
    of rInstant:
      var guard = 0
      while st.on and not p.dead and guard < 100:
        s.emitOnce(p, i)
        inc guard
    of rDistance:
      if st.fresh:
        st.fresh = false
        s.emitOnce(p, i)
      elif st.last != nil and not st.last.dead:
        if (st.last.pos - p.pos).length > s.f(e.r[0], p): s.emitOnce(p, i)

proc setEnabled(p: Particle, idx: int, on: bool) =
  if idx in 0 ..< p.disabled.len: p.disabled[idx] = not on

proc emitterIndex(s: ParticleSim, a: Action, p: Particle): int =
  result = int(s.f(a.p[0], p, -1))
  if result notin 0 ..< p.ems.len: result = -1

proc run(s: ParticleSim, p: Particle, ev: int): bool =
  ## Runs one of the particle's events; true when the particle died.
  let dt = TickTime
  for a in p.cls.events[ev]:
    if p.dead: return true
    if ev == evUpdate and p.disabled[a.idx]: continue
    template tgt(i: int): untyped = p.vars[a.tgt[i]]
    template hasTgt(i: int): bool = a.tgt.len > i and a.tgt[i] >= 0 and a.tgt[i] < p.vars.len
    case a.kind
    of akNone: discard
    of akAnimateLinear:
      if hasTgt(0): tgt(0).x += s.f(a.p[0], p) * dt
    of akAnimateAccelerated:
      if hasTgt(0) and hasTgt(1):
        tgt(1).x += s.f(a.p[0], p) * dt
        tgt(0).x += tgt(1).x * dt
    of akAnimateRandom:
      if hasTgt(0):
        let (lo, hi, rate) = (s.f(a.p[0], p), s.f(a.p[1], p), s.f(a.p[2], p))
        let mid = (lo + hi) / 2
        let half = max((hi - lo) / 2, 1e-6)
        # More likely to head back toward the middle the nearer it is to an end.
        let pull = (tgt(0).x - mid) / half
        let step = (s.rnd * 2 - 1 - pull * 0.5) * rate * dt
        tgt(0).x = clamp(tgt(0).x + step, lo, hi)
    of akAnimatePingPong:
      if hasTgt(0) and hasTgt(1):
        let (lo, hi, rate) = (s.f(a.p[0], p), s.f(a.p[1], p), s.f(a.p[2], p))
        if tgt(1).x == 0:
          tgt(0).x += rate * dt
          if tgt(0).x > hi:
            tgt(0).x = hi
            tgt(1).x = 1
        else:
          tgt(0).x -= rate * dt
          if tgt(0).x < lo:
            tgt(0).x = lo
            tgt(1).x = 0
    of akAnimateLoop:
      if hasTgt(0):
        let (lo, hi, rate) = (s.f(a.p[0], p), s.f(a.p[1], p), s.f(a.p[2], p))
        tgt(0).x += rate * dt
        if hi > lo:
          if tgt(0).x > hi: tgt(0).x = lo + (tgt(0).x - hi)
          elif tgt(0).x < lo: tgt(0).x = hi - (lo - tgt(0).x)
    of akAnimateToValue:
      if hasTgt(0):
        let (rate, goal) = (s.f(a.p[0], p), s.f(a.p[1], p))
        tgt(0).x += rate * dt
        if rate < 0 and tgt(0).x < goal: tgt(0).x = goal
        elif rate > 0 and tgt(0).x > goal: tgt(0).x = goal
    of akColorInterpolate:
      if hasTgt(0):
        let t = clamp(s.f(a.p[2], p), 0, 1)
        tgt(0) = s.eval(a.p[0], p) * (1 - t) + s.eval(a.p[1], p) * t
    of akFadeOut:
      if p.fadeTime <= 0:
        let t = s.f(a.p[0], p)
        if t <= 0:
          s.kill(p)
          return true
        p.fadeTime = t
        p.fade = t
    of akEnableAtTime, akDisableAtTime:
      let soon = p.life > 0 and p.life < s.f(a.p[1], p)
      p.setEnabled(int(s.f(a.p[0], p)), if a.kind == akEnableAtTime: soon else: not soon)
    of akEnableAbove, akEnableBelow:
      let v = s.f(a.p[1], p)
      let th = s.f(a.p[2], p)
      p.setEnabled(int(s.f(a.p[0], p)), if a.kind == akEnableAbove: v > th else: v < th)
    of akEnableNow: p.setEnabled(int(s.f(a.p[0], p)), true)
    of akDisableNow: p.setEnabled(int(s.f(a.p[0], p)), false)
    of akDie:
      s.kill(p)
      return true
    of akSetLifetime: p.life = max(0'f32, s.f(a.p[0], p))
    of akEmitActivate:
      let i = s.emitterIndex(a, p)
      if i >= 0: p.ems[i] = EmState(on: true, fresh: true, last: p.ems[i].last,
                                    lastAt: p.ems[i].lastAt)
    of akEmitDeactivate:
      let i = s.emitterIndex(a, p)
      if i >= 0: p.ems[i].on = false
    of akEmitParticles:
      let i = s.emitterIndex(a, p)
      if i >= 0:
        let n = if a.p[1].kind == vRange: a.p[1].a.x else: s.f(a.p[1], p)
        for k in 0 ..< int(n):
          if p.dead: break
          s.emitOnce(p, i)
    of akChangeClass:
      let i = s.emitterIndex(a, p)
      if i >= 0:
        let c = s.create(s.classOf(p.cls.emitters[i].cls), p.pos, p.ax)
        if c != nil:
          c.vel = p.vel
          c.link = p.link
          c.decalScale = p.decalScale
          discard s.run(c, evCreate)
    of akKillLastEmitted:
      let i = s.emitterIndex(a, p)
      if i >= 0 and p.ems[i].last != nil: s.kill(p.ems[i].last)
    of akExplodeLastEmitted:
      let i = s.emitterIndex(a, p)
      if i >= 0 and p.ems[i].last != nil and not p.ems[i].last.dead:
        discard s.run(p.ems[i].last, evExplode)
    of akExplode:
      if s.run(p, evExplode): return true
    of akStop:
      if s.run(p, evStop): return true
    of akRotateX, akRotateY, akRotateZ:
      let n = ord(a.kind) - ord(akRotateX)
      let world = s.f(a.p[0], p) != 0 or not p.cls.hasOrientation
      let axis = if world: [vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)][n] else: p.ax[n]
      let deg = s.f(a.p[1], p) * dt
      for k in 0 .. 2: p.ax[k] = rotateAround(p.ax[k], axis, deg)
      if s.f(a.p[2], p) != 0: p.vel = rotateAround(p.vel, axis, deg)
    of akMoveLine:
      if p.cls.hasVelocity: p.pos += p.vel * dt
    of akMoveGravity:
      if p.cls.hasVelocity: p.vel.y -= Gravity * s.f(a.p[0], p) * dt
    of akMoveSpiral:
      if hasTgt(0) and p.cls.hasOffset:
        tgt(0).x += s.f(a.p[1], p) * dt
        var r = s.f(a.p[0], p)
        if r == 0: r = p.offset.length
        let ahead = if p.vel.length > 1e-6: p.vel.normalize else: p.ax[1]
        let fr = frame(ahead, p.ax[2])
        let th = tgt(0).x.degToRad
        p.offset = (fr[0] * cos(th) + fr[2] * sin(th)) * r
    of akMoveResistance:
      let (res, minV) = (s.f(a.p[0], p), s.f(a.p[1], p))
      let v = p.vel.length
      if v > minV and v > 1e-6:
        p.vel *= ((v - minV) * exp(-res * dt) + minV) / v
    of akMoveDrift:
      var d = vec3(s.f(a.p[3], p), s.f(a.p[4], p), s.f(a.p[5], p))
      if d.length > 1e-6:
        if s.f(a.p[6], p) == 0 and p.cls.hasOrientation:
          d = p.ax[0] * d.x + p.ax[1] * d.y + p.ax[2] * d.z
        d = d.normalize
        let (acc, maxV, decay) = (s.f(a.p[0], p), s.f(a.p[1], p), s.f(a.p[2], p))
        var along = dot(p.vel, d)
        var side = p.vel - d * along
        if maxV == 0: along += acc * dt
        else: along = (along - maxV) * exp(-acc * dt) + maxV
        if decay != 0: side *= exp(-decay * dt)
        p.vel = d * along + side
    of akSetVelocity:
      let speed = s.f(a.p[0], p)
      if s.f(a.p[1], p) != 0 or not p.cls.hasOrientation:
        if p.vel.length > 1e-6: p.vel = p.vel.normalize * speed
      else:
        let along = p.ax[1] * speed
        p.vel = if s.f(a.p[2], p) != 0: along else: p.vel - p.ax[1] * dot(p.vel, p.ax[1]) + along
    of akSpiralTangent:
      let ahead = if p.vel.length > 1e-6: p.vel.normalize else: p.ax[1]
      let fr = frame(ahead, p.ax[2])
      let th = s.f(a.p[0], p).degToRad
      let push = s.f(a.p[1], p) * s.f(a.p[2], p).degToRad
      p.vel += (fr[2] * cos(th) - fr[0] * sin(th)) * push * dt
    of akKillBeyondPoint:
      let d = int(s.f(a.p[0], p))
      let v = s.f(a.p[1], p)
      let c = [p.pos.x, p.pos.y, p.pos.z][clamp(d div 2, 0, 2)]
      if (d mod 2 == 0 and c > v) or (d mod 2 == 1 and c < v):
        s.kill(p)
        return true
    of akCollisionEffect:
      let at = if p.hit: p.hitPos + p.hitNrm * s.f(a.p[0], p) else: p.pos
      var ax = p.ax
      case int(s.f(a.p[1], p))
      of 1: ax = frame(-p.ax[1], p.ax[2])
      of 2:
        if p.hit: ax = frame(p.ax[1] - p.hitNrm * 2 * dot(p.ax[1], p.hitNrm), p.ax[2])
      of 3:
        if p.hit: ax = frame(p.hitNrm, p.ax[1])
      else: discard
      let c = s.create(s.classOf(a.str), at, ax)
      if c != nil:
        c.decalScale = p.decalScale
        discard s.run(c, evCreate)
    of akStickToWall:
      if p.hit:
        p.pos = p.hitPos
        p.vel = vec3(0, 0, 0)
    of akBounce:
      if p.hit:
        let n = p.hitNrm
        p.vel = (p.vel - n * 2 * dot(p.vel, n)) * s.f(a.p[0], p, 1)
        p.pos = p.hitPos + n * 0.05
        if p.vel.length < 1: p.vel = vec3(0, 0, 0)
    of akChop:
      s.kill(p)
      return true
    of akShow: p.hidden = false
    of akHide: p.hidden = true
    of akSetTextureTick: p.texTick = s.f(a.p[0], p)
    of akRandomTextureFrame: p.texTick = s.rnd * 1000
    of akSetVariable:
      if hasTgt(0): tgt(0) = s.eval(a.p[0], p)
    of akRecalculateAll: s.initVars(p)
    of akStopIfSlow:
      if p.vel.length < s.f(a.p[0], p): break
  p.dead

proc kill(s: ParticleSim, p: Particle) =
  ## Its die event still runs, then it's gone.
  if p.dead or p.dying: return
  p.dying = true
  discard s.run(p, evDie)
  p.dead = true

proc collides(f: Face): bool =
  (f.flags and (gfGhost or gfDoorFrame or gfNoCollision)) == 0 and
    not f.texture.startsWith("_marker")

proc updateGrid(s: ParticleSim, g: Geometry, now: float) =
  if g == nil: return
  if g == s.geo and (g.version == s.gridVersion or now - s.gridAt < RebuildEvery): return
  s.grid = buildGrid(g, collides)
  s.geo = g
  s.gridVersion = g.version
  s.gridAt = now
  s.stamp = newSeq[int32](s.grid.triangles)
  s.ray = 0

proc firstHit(s: ParticleSim, a, b: Vec3): (bool, Vec3, Vec3) =
  ## The first level face between a and b: where, and its normal (facing a).
  if s.geo == nil or s.grid.triangles == 0: return
  inc s.ray
  if s.ray == int32.high:
    for x in s.stamp.mitems: x = 0
    s.ray = 1
  let hits = crossings(addr s.grid, a, b, s.stamp, s.ray)
  if hits.len == 0: return
  let (t, fi) = hits[0]
  let d = (b - a).normalize
  var n = s.geo.normal(s.geo.faces[fi])
  if dot(n, d) > 0: n = -n
  (true, a + d * t, n)

proc tick(s: ParticleSim, p: Particle) =
  if p.dead: return
  p.prev = p.pos
  p.hit = false
  s.runEmitters(p)
  if p.dead or s.run(p, evUpdate): return
  if p.cls.lockToLink and p.link != nil and not p.link.dead: p.pos = p.link.pos
  if p.link != nil and p.link.dead:
    p.link = nil
    if s.run(p, evBrokenLink): return
  if p.orientToVel and p.vel.length > 1e-6: p.ax = frame(p.vel, p.ax[2])
  if p.cls.collideWalls and p.cls.hasVelocity and (p.pos - p.prev).length > 1e-5:
    let (hit, at, n) = s.firstHit(p.prev, p.pos)
    if hit:
      p.hit = true
      p.hitPos = at
      p.hitNrm = n
      if p.cls.events[evHitWall].len == 0: p.pos = at
      elif s.run(p, evHitWall): return
  if p.life > 0:
    p.life -= TickTime
    if p.life < TickTime:
      p.life = 0
      if p.fadeTime > 0 or p.cls.events[evLifetime].len == 0:
        s.kill(p)
        return
      if s.run(p, evLifetime): return
  if p.fadeTime > 0:
    p.fade -= TickTime
    if p.fade <= 0:
      s.kill(p)
      return
  p.age += TickTime
  p.texTick += 1

type ParticleSource* = object
  ## A Particle object, as the level places it.
  cls*: string
  pos*: Vec3
  axes*: array[3, Vec3]
  decalScale*: Vec2
  flags*: int
  started*: bool   ## Its script starts it at load (AutoStartTag): it gets Start too.

proc reset*(s: ParticleSim, sources: seq[ParticleSource]) =
  ## Starts over: the level's Particle objects create their particles.
  s.parts.setLen 0
  s.time = 0
  s.pending = 0
  for src in sources:
    if (src.flags and NotInitiallyCreated) != 0: continue
    let cls = s.classOf(src.cls)
    let p = s.create(cls, src.pos, src.axes)
    if p == nil: continue
    p.decalScale = src.decalScale
    if not s.run(p, evCreate) and src.started: discard s.run(p, evStart)

proc particleCount*(s: ParticleSim): int = s.parts.len

proc step*(s: ParticleSim, dt: float, g: Geometry, now: float) =
  ## Advances the particles by dt seconds, in Oni's 60 Hz ticks.
  s.updateGrid(g, now)
  s.pending = min(s.pending + dt.float32, MaxTicksPerFrame.float32 * TickTime)
  while s.pending >= TickTime:
    s.pending -= TickTime
    s.time += TickTime
    var i = 0
    while i < s.parts.len:   # New particles join this tick's loop.
      s.tick(s.parts[i])
      inc i
    var n = 0
    for p in s.parts:
      if not p.dead:
        s.parts[n] = p
        inc n
    s.parts.setLen n

proc frameOf(s: ParticleSim, t: TexInfo, p: Particle): string =
  let n = t.frames.len
  if n == 1 or t.dontAnimate: return t.frames[0]
  let ticks = if t.localTime: p.texTick else: s.time * 60
  var i = int(ticks) div t.speed
  if t.randomOrder: i = int(hash(i + cast[int](p) shr 4) and 0x7fffffff)
  if t.pingPong and n > 2:
    i = i mod (2 * n - 2)
    if i >= n: i = 2 * n - 2 - i
  t.frames[i mod n]

proc snapDecal(s: ParticleSim, p: Particle) =
  ## Oni projects a decal onto the level (P3rCreateDecal). A placed decal
  ## faces its +Y and sits on, just off or just inside the wall it belongs
  ## to: the first face behind it (along -Y, from half a unit in front) that
  ## faces the same way. Failing that, one in front facing back at it (the
  ## decal is then turned around).
  if s.geo == nil or s.grid.triangles == 0: return
  p.snapped = true
  for (side, flip) in [(-p.ax[1], false), (p.ax[1], true)]:
    inc s.ray
    if s.ray == int32.high:
      for x in s.stamp.mitems: x = 0
      s.ray = 1
    let a = p.pos - side * 0.5
    for (t, fi) in crossings(addr s.grid, a, a + side * DecalReach, s.stamp, s.ray):
      let n = s.geo.normal(s.geo.faces[fi])
      if dot(n, side) < -0.5:
        p.pos = a + side * t + n * 0.05
        if flip: p.ax = [-p.ax[0], -p.ax[1], p.ax[2]]
        return

proc sprites*(s: ParticleSim, camPos: Vec3): seq[SpriteInst] =
  ## What to draw this frame. Lens flares behind level geometry (seen from
  ## camPos) are left out.
  for p in s.parts:
    let cls = p.cls
    if cls.display == dkDecal and not p.snapped: s.snapDecal(p)
    if p.dead or p.hidden or cls.invisible or cls.texture.len == 0 or
       cls.display in {dkGeometry, dkContrail, dkOrientedContrail}: continue
    let t = s.textureOf(cls.texture)
    if t.frames.len == 0: continue
    var alpha = s.f(cls.alpha, p, 1)
    if alpha > 1.001: alpha /= 255
    if p.fadeTime > 0: alpha *= clamp(p.fade / p.fadeTime, 0, 1)
    let tint = if cls.tint.kind == vNone: vec4(1, 1, 1, 1) else: s.eval(cls.tint, p)
    let a = clamp(alpha * tint.w, 0, 1)
    if a <= 0.002: continue
    let pos = p.pos + (if cls.hasOffset: p.offset else: vec3(0, 0, 0))
    if cls.lensFlare:
      let (hit, _, _) = s.firstHit(camPos, pos)
      if hit and (camPos - pos).length > 1: continue
    var scale = s.f(cls.scale, p, 1)
    if cls.scaleToVelocity: scale *= p.vel.length + 1
    let yscale = if cls.useYScale: s.f(cls.yScale, p, 1) else: scale
    var dir = if cls.hasVelocity and p.vel.length > 1e-6: p.vel.normalize else: p.ax[1]
    if cls.display in {dkArrow, dkFlat, dkDiscus, dkDecal} or not cls.hasVelocity: dir = p.ax[1]
    var sx = scale
    var sy = yscale
    if cls.display == dkDecal:
      sx *= p.decalScale.x
      sy *= p.decalScale.y
    result.add SpriteInst(
      pos: pos, mode: ord(cls.display), ax: [p.ax[0], dir, p.ax[2]],
      scale: sx, yscale: sy, rot: s.f(cls.rotation, p),
      col: [uint8(clamp(tint.x, 0, 1) * 255), uint8(clamp(tint.y, 0, 1) * 255),
            uint8(clamp(tint.z, 0, 1) * 255), uint8(a * 255)],
      tex: s.frameOf(t, p), additive: t.additive, flare: cls.lensFlare,
      edgeFade: cls.edgeFade, oneSided: cls.oneSidedEdgeFade,
      edgeMin: cls.edgeFadeMin, edgeMax: cls.edgeFadeMax)

proc meshOf(s: ParticleSim, name: string): PMesh =
  ## A geometry particle's model (the cache's models/<name>.dae); nil if missing.
  let key = name.toLowerAscii
  if key in s.meshes: return s.meshes[key]
  s.meshes[key] = nil
  for f in walkFiles(particleDir() / "models" / "*.dae"):
    if f.splitFile.name.toLowerAscii != key: continue
    try:
      let scene = readDae(f)
      let m = PMesh()
      for b in scene.batches:
        m.batches.add (tex: b.image.splitFile.name, image: b.image, verts: b.verts)
      s.meshes[key] = m
    except CatchableError: discard
    break
  s.meshes[key]

proc pointColor(s: ParticleSim, p: Particle): Vec4 =
  ## Tint and alpha where a contrail passes (FUN_00461d20 reads Tint and Alpha).
  var alpha = s.f(p.cls.alpha, p, 1)
  if alpha > 1.001: alpha /= 255
  if p.fadeTime > 0: alpha *= clamp(p.fade / p.fadeTime, 0, 1)
  let t = if p.cls.tint.kind == vNone: vec4(1, 1, 1, 1) else: s.eval(p.cls.tint, p)
  vec4(clamp(t.x, 0, 1), clamp(t.y, 0, 1), clamp(t.z, 0, 1), clamp(alpha * t.w, 0, 1))

proc rgba(c: Vec4): array[4, uint8] =
  [uint8(c.x * 255), uint8(c.y * 255), uint8(c.z * 255), uint8(c.w * 255)]

proc contrails(s: ParticleSim, camPos: Vec3, tris: var seq[ParticleTri]) =
  ## Contrail ribbons (FUN_00461d20). Every particle with contrail data has a
  ## point this frame; a contrail particle joins its point to its target's.
  ## A point's half width is set by the segment that starts there; a chain's
  ## last point takes the width of the segment that ends there.
  inc s.frameNo
  for p in s.parts:
    if p.cls.hasContrail and not p.dead:
      p.cpos = p.pos + (if p.cls.hasOffset: p.offset else: vec3(0, 0, 0))
      p.ccol = s.pointColor(p)
      p.cwidth = vec3(0, 0, 0)
      p.cframe = s.frameNo
  type Seg = object
    a, b: Particle
    v0: float32
    col: Vec4
  var segs: seq[Seg]
  for p in s.parts:
    let cls = p.cls
    if p.dead or p.hidden or cls.invisible or not cls.hasContrail or cls.texture.len == 0 or
       cls.display notin {dkContrail, dkOrientedContrail}: continue
    if cls.display == dkOrientedContrail and not cls.hasOrientation: continue
    var b: Particle
    var v0 = 0'f32
    if cls.contrailEmitter:
      # To the last particle of the first emitter linking to its own previous
      # one; V at this end grows from 1 to 0 over one emission interval.
      var ei = -1
      for i, e in cls.emitters:
        if e.link == i:
          ei = i
          break
      if ei < 0: continue
      b = p.ems[ei].last
      if b == nil or b.dead or b.cframe != s.frameNo: continue
      let e = cls.emitters[ei]
      var window = 1'f32
      if e.rate in {rContinuous, rRandom, rDistance} and e.r[0].kind != vNone: window = s.f(e.r[0], p)
      let age = s.time - p.ems[ei].lastAt
      v0 = if age < 0: 1'f32 elif age <= window and window > 0: 1 - age / window else: 0
    else:
      b = p.link
      if b == nil or b.dead or b.cls != cls or b.cframe != s.frameNo: continue
    let seg = b.cpos - p.cpos
    let maxLen = s.f(cls.maxContrail, p)
    if maxLen * maxLen > 0.001 and seg.lengthSq > maxLen * maxLen: continue
    let scale = s.f(cls.scale, p, 1)
    if cls.display == dkOrientedContrail:
      p.cwidth = p.ax[0] * scale
    else:
      var w = cross(seg, p.cpos - camPos)
      let l = w.length
      if l > 0.01: w *= scale / l
      p.cwidth = w
    if b.link == nil: b.cwidth = p.cwidth
    var col = p.ccol
    if cls.edgeFade:
      let toCam = p.cpos - camPos
      if seg.length < 1e-6 or toCam.length < 1e-6: continue
      let c = 1 - abs(dot(seg.normalize, toCam.normalize))
      if c < cls.edgeFadeMin: continue
      if c < cls.edgeFadeMax and cls.edgeFadeMax > cls.edgeFadeMin:
        col.w *= (c - cls.edgeFadeMin) / (cls.edgeFadeMax - cls.edgeFadeMin)
    segs.add Seg(a: p, b: b, v0: v0, col: col)
  for sg in segs:
    let t = s.textureOf(sg.a.cls.texture)
    if t.frames.len == 0: continue
    if sg.col.w <= 0.002 and sg.b.ccol.w <= 0.002: continue
    let (a, b) = (sg.a, sg.b)
    let ca = rgba(sg.col)
    let cb = rgba(b.ccol)
    let tex = s.frameOf(t, a)
    let q = [a.cpos - a.cwidth, a.cpos + a.cwidth, b.cpos + b.cwidth, b.cpos - b.cwidth]
    let uv = [vec2(0, sg.v0), vec2(1, sg.v0), vec2(1, 1), vec2(0, 1)]
    let c = [ca, ca, cb, cb]
    for (i, j, k) in [(0, 1, 2), (0, 2, 3)]:
      tris.add ParticleTri(p: [q[i], q[j], q[k]], uv: [uv[i], uv[j], uv[k]],
                           col: [c[i], c[j], c[k]], tex: tex, additive: t.additive)

proc models(s: ParticleSim, tris: var seq[ParticleTri]) =
  ## Geometry particles (FUN_00460800): their M3GM, untinted.
  for p in s.parts:
    let cls = p.cls
    if p.dead or p.hidden or cls.invisible or cls.display != dkGeometry or cls.texture.len == 0:
      continue
    let m = s.meshOf(cls.texture)
    if m == nil: continue
    let ax = if cls.hasOrientation: p.ax
             elif cls.hasVelocity: frame(p.vel, vec3(0, 1, 0))
             else: [vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)]
    let pos = p.pos + (if cls.hasOffset: p.offset else: vec3(0, 0, 0))
    let scale = s.f(cls.scale, p, 1)
    var alpha = s.f(cls.alpha, p, 1)
    if alpha > 1.001: alpha /= 255
    if p.fadeTime > 0: alpha *= clamp(p.fade / p.fadeTime, 0, 1)
    alpha = clamp(alpha, 0, 1)
    if alpha <= 0.002: continue
    for b in m.batches:
      # The model's TXMP (animated or additive) if the cache has it, else its image.
      var (tex, additive) = (b.image, false)
      if fileExists(particleDir() / "textures" / "TXMP" & b.tex & ".xml"):
        let t = s.textureOf(b.tex)
        if t.frames.len > 0: (tex, additive) = (s.frameOf(t, p), t.additive)
      if tex.len == 0: continue
      var i = 0
      while i + 2 < b.verts.len:
        var tri = ParticleTri(tex: tex, additive: additive, wrap: true)
        for k in 0 .. 2:
          let v = b.verts[i + k]
          tri.p[k] = pos + (ax[0] * v.pos.x + ax[1] * v.pos.y + ax[2] * v.pos.z) * scale
          tri.uv[k] = v.uv
          tri.col[k] = [v.color[0], v.color[1], v.color[2], uint8(v.color[3].float32 * alpha)]
        tris.add tri
        i += 3

proc triangles*(s: ParticleSim, camPos: Vec3): seq[ParticleTri] =
  ## This frame's contrail ribbons and particle models (seen from camPos).
  s.contrails(camPos, result)
  s.models(result)
