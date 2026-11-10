## What kind of input an Entity tab or class field takes, beyond text: a number
## (with its step and range), an on/off box, a pair of numbers; on the Classes
## page also a color, a grid of flags, a sound or a texture. An object's colors
## ("R G B") and XYZ values are told apart by their name and value (panels.nim).
##
## Object field types follow OniSplit's BINACJBO XML reader (ReadElementContentAsInt
## or AsFloat, the attributes' ToInt16/ToSingle); character class types its
## ONCC metadata (Oni.Metadata.InstanceMetadata). Ids that name another object
## or profile stay text fields: their dropdown lists what they can point at.

import std/[strutils, re, tables, sequtils, math]
import particleevents

const RecordingPrefix* = "rec_"
  ## On a sound field's value naming one SNDD (rec_zap07 is zap07.aif), not an
  ## ambient or impulse. Build defines it in the level (project.recordingSources).

const
  RecordingPitchTag = "__p"   ## rec_zap07__p150 is zap07.aif at pitch 1.5.
  RecordingPitchMin* = 0.25
  RecordingPitchMax* = 4.0

proc splitRecording*(value: string): tuple[name: string, pitch: float] =
  ## The recording and pitch of a rec_ value (its name without the prefix).
  result = (value.strip[RecordingPrefix.len .. ^1], 1.0)
  let at = result.name.rfind(RecordingPitchTag)
  if at > 0:
    try:
      let p = parseInt(result.name[at + RecordingPitchTag.len .. ^1])
      if p > 0: result = (result.name[0 ..< at], p / 100)
    except ValueError: discard

proc recordingValue*(name: string, pitch: float): string =
  ## The rec_ value of a recording at a pitch (1 is how Oni plays it).
  let p = int(round(pitch * 100))
  RecordingPrefix & name & (if p == 100: "" else: RecordingPitchTag & $p)

type
  FieldKind* = enum fkText, fkNumber, fkToggle, fkPair, fkColor, fkFlags, fkSound, fkTexture
  FlagDef* = object
    ## One toggle of a flag field: its name in the XML, what to call it, what it does.
    name*, label*, tip*: string
    bit*: int               ## In a field of flag names (fkFlags).
  FieldType* = object
    kind*: FieldKind
    free*: bool             ## A number field that may also hold a variable's name.
    impulse*: bool          ## fkSound: an impulse sound (.imp), else an ambient (.amb).
    flags*: seq[FlagDef]    ## fkFlags.
    whole*: bool            ## Whole numbers only.
    step*, lo*, hi*: float
    tip*: string            ## What the value means, when the name doesn't say.

proc num(whole: bool, step, lo, hi: float, tip = ""): FieldType =
  FieldType(kind: fkNumber, whole: whole, step: step, lo: lo, hi: hi, tip: tip)

proc flag(name, label, tip: string, bit = 0): FlagDef =
  FlagDef(name: name, label: label, tip: tip, bit: bit)

proc short(step = 1.0, lo = 0.0, tip = ""): FieldType = num(true, step, lo, 32767, tip)

const
  Frames = "Frames (60 per second)"
  Unit = "0 to 1"

let objectTypes = {
  "CHAR OSD/AdditionalHealth": num(true, 5, -100000, 100000, "Added to the class's Health"),
  "CHAR OSD/AmmoPercentage": num(true, 5, 0, 100, "Percent of a full clip"),
  "DOOR OSD/KeyId": short(),
  "DOOR OSD/SquaredActivationRadius": num(false, 100, 0, 1e7,
    "The opening distance squared (900: 30 units)"),
  "FLAG OSD/Prefix": short(lo = -32768),
  "NEUT OSD/Ranges/Trigger": num(false, 5, 0, 10000),
  "NEUT OSD/Ranges/Talk": num(false, 5, 0, 10000),
  "NEUT OSD/Ranges/Follow": num(false, 5, 0, 10000),
  "NEUT OSD/Ranges/Enemy": num(false, 5, 0, 10000),
  "NEUT OSD/Rewards/Ammo": num(true, 1, 0, 255),
  "NEUT OSD/Rewards/EnergyCell": num(true, 1, 0, 255),
  "NEUT OSD/Rewards/Hypo": num(true, 1, 0, 255),
  "SNDG OSD/Volume": num(false, 0.05, 0, 1, Unit),
  "SNDG OSD/Pitch": num(false, 0.05, 0.05, 4, "1: as recorded"),
  "SNDG OSD/Sphere/MinRadius": num(false, 5, 0, 100000),
  "SNDG OSD/Sphere/MaxRadius": num(false, 5, 0, 100000),
  "TRIG OSD/EmitterCount": num(true, 1, 0, 255),
  "TRIG OSD/Speed": num(false, 0.05, 0, 100),
  "TRIG OSD/StartPosition": num(false, 0.05, 0, 1, "Along the path, " & Unit),
  "TRIG OSD/TimeOn": short(30, tip = Frames),
  "TRIG OSD/TimeOff": short(30, tip = Frames),
  "PART OSD/DecalScale": FieldType(kind: fkPair, step: 0.1, lo: 0, hi: 1000),
  "PATR OSD/ReturnToNearest": FieldType(kind: fkToggle)}.toTable

const
  ## The on/off elements of a particle class, by group. What they do is from
  ## Bungie's BFW_Particle3 (OniFoxed); names are OniSplit's.
  ## Properties: the optional data each particle keeps (P3tParticleOptionalVar).
  ## A flag only reserves the room; the actions and display types use it.
  PropertyFlags* = [
    ("HasVelocity", "Velocity", "Room for a velocity. Off: movement actions (MoveLine, MoveGravity, " &
      "MoveResistance...) have nothing to act on and the particle stays where it was emitted."),
    ("HasOrientation", "Orientation", "Room for a rotation of its own. Off: it points along its velocity, " &
      "if it has one."),
    ("HasPositionOffset", "Position offset", "Room for an offset added to its position. MoveSpiral orbits with it."),
    ("HasAttachmentMatrix", "Attachment", "Room for a link to something that moves (a character, a weapon): " &
      "the particle rides it. Off: it stays in the world."),
    ("HasUnknown", "Previous position", "Room for its position last frame (OniSplit's HasUnknown). It was for " &
      "collisions on curved paths, which Bungie turned off: it costs memory and collision code no longer reads it."),
    ("HasDecalState", "Decal state", "Room for the decal it made on a wall. Decal particles need it."),
    ("HasTextureStartTick", "Random frame", "Room for a random number given at creation: particles " &
      "of an animated texture don't all show the same frame."),
    ("HasTextureTick", "Texture clock", "Room for the time its texture animation counts from: its creation, " &
      "or what SetTextureTick sets."),
    ("HasDamageOwner", "Damage owner", "Room for who fired it, for crediting its damage and for SelfImmune. " &
      "Particles it emits inherit the owner."),
    ("HasContrailData", "Contrail", "Room for a contrail's segment. The Contrail display types need it."),
    ("HasLensFlareState", "Lens flare", "Room for the frames its lens flare has been fading. LensFlare needs it."),
    ("HasAttractor", "Attractor", "Room for its current target. Off: the Attractor section and the " &
      "actions that use it (FindAttractor, AttractHoming, AttractGravity...) do nothing."),
    ("HasCollisionCache", "Collision cache", "Room that speeds up its wall collisions. Oni turns this on " &
      "by itself when CollideWithWalls is on.")]
  OptionFlags* = [
    ("Decorative", "Decorative", "Drops first when too many particles are alive: for looks only, " &
      "never for what affects the game."),
    ("CollideWithWalls", "Hits walls", "Collides with the level; fires HitWall."),
    ("CollideWithChars", "Hits characters", "Collides with characters; fires HitCharacter."),
    ("InitiallyHidden", "Starts hidden", "Isn't drawn until a Show action."),
    ("DrawAsSky", "Draw as sky", "Drawn with the sky, behind the level."),
    ("DontAttractThroughWalls", "Attract by sight", "An attractor counts only if no wall is in the way."),
    ("ExpireOnCutscene", "Expire on cutscene", "A cutscene ends it at the end of its lifetime."),
    ("DieOnCutscene", "Die on cutscene", "A cutscene ends it at once."),
    ("LockPositionToLink", "Lock to link", "Stays on the particle it's linked to.")]
  AppearanceFlags* = [
    ("Invisible", "Invisible", "Never drawn; it can still emit, move and do damage."),
    ("IsContrailEmitter", "Contrail emitter", "It's the head of a contrail its emitted particles draw."),
    ("ScaleToVelocity", "Scale to velocity", "Stretches with its speed."),
    ("UseSeparateYScale", "Separate Y scale", "YScale sets its height apart from Scale."),
    ("UseSpecialTint", "Global tint", "Takes the tint scripts set for all such particles."),
    ("FadeOutOnEdge", "Fade on edge", "Fades when seen edge-on (EdgeFadeMin, EdgeFadeMax)."),
    ("OneSidedEdgeFade", "One-sided fade", "Edge fade counts one side of it only."),
    ("LensFlare", "Lens flare", "Drawn as a flare that fades in and out with sight."),
    ("DecalFullBrightness", "Full bright decal", "A decal that ignores the level's lighting.")]
  ## OniSplit's other names, for a group's Other field: what the toggles don't cover.
  OtherFlags1* = ["SpriteMode0", "SpriteMode1", "SpriteMode2", "Geometry"]
  OtherFlags2* = ["DisableLevel0", "DisableLevel1", "Decal", "Vector"]

proc flagGroup*(group: string): seq[FlagDef] =
  ## The toggles of a particle class's group, "" when it has none.
  let list = case group
             of "Properties": @PropertyFlags
             of "Options": @OptionFlags
             of "Appearance": @AppearanceFlags
             else: @[]
  for (n, l, t) in list: result.add flag(n, l, t)

proc otherFlagNames*(group: string): seq[string] =
  ## What OniSplit also reads in the group: Properties takes one enum, the rest both.
  if group == "Properties": @OtherFlags1 else: @OtherFlags1 & @OtherFlags2

proc isOtherFlag*(path: string): bool =
  ## An element of a group's Other field.
  let cut = path.rfind('/')
  cut > 0 and path[cut + 1 .. ^1] in otherFlagNames(path[0 ..< cut]) and flagGroup(path[0 ..< cut]).len > 0

let
  emitterFlags = @[
    flag("InitiallyOn", "Initially on", "Starts emitting when the particle is created.", 1),
    flag("IncreaseParticleCount", "Count particles", "Counts what it emits, for TurnOffTreshold.", 2),
    flag("TurnOffAtTreshold", "Off at threshold", "Stops after TurnOffTreshold particles.", 4),
    flag("EmitWithParentVelocity", "Parent velocity", "Adds the emitter's velocity to what it emits.", 16),
    flag("Unknown0020", "Share attachment", "Emitted particles ride the same thing as this one " &
      "(OniSplit's Unknown0020).", 32),
    flag("OrientToVelocity", "Orient to velocity", "Emitted particles face their direction of travel.", 64),
    flag("InheritTint", "Inherit tint", "Emitted particles take this one's tint.", 128),
    flag("OnePerAttractor", "One per attractor", "Emits one particle at each attractor found.", 256),
    flag("AtLeastOne", "At least one", "With One per attractor: emits one even if none is found.", 512),
    flag("CycleAttractors", "Cycle attractors", "Each emission picks the next attractor.", 1024)]
  aiFlags = @[
    flag("NoStartleAnim", "Never startled", "Never plays the startle animation.", 1),
    flag("EnableMeleeFireDodge", "Dodge gunfire", "Dodges shots; the two below say how it fires meanwhile.", 2),
    flag("ShootDodge", "Dodge while firing", "Keeps firing as it dodges.", 4),
    flag("RunAwayDodge", "Stop firing to dodge", "Stops firing to run out of the line of fire.", 8),
    flag("NotUsed", "Running pickup", "Grabs weapons on the run (OniSplit's NotUsed; RunPickupChance). " &
      "Bungie's name for this bit.", 16)]

# Patrol point attributes, whatever the point.
let patrolAttrs = {
  "Frames": short(30, tip = Frames),
  "Rotation": num(false, 15, -360, 360, "Degrees"),
  "Distance": num(false, 5, 0, 100000),
  "Spread": num(false, 5, 0, 360, "Degrees"),
  "ScriptId": short(lo = -32768),
  "X": num(false, 1, -100000, 100000),
  "Y": num(false, 1, -100000, 100000),
  "Z": num(false, 1, -100000, 100000)}.toTable

# Catwalk's lights (objtemplates.LightTags; lighting.nim reads them).
let lightTypes = {
  "OSD/Enabled": FieldType(kind: fkToggle),
  "OSD/Shadows": FieldType(kind: fkToggle),
  "OSD/Intensity": num(false, 0.1, 0, 100),
  "OSD/Radius": num(false, 10, 0, 100000),
  "OSD/Angle": num(false, 5, 1, 179, "Cone width, degrees"),
  "OSD/Softness": num(false, 0.05, 0, 1, "0: a hard edge; 1: fades from the middle of the cone"),
  "OSD/Animation/Period": num(false, 0.1, 0.01, 3600, "Seconds"),
  "OSD/Animation/Offset": num(false, 0.1, -3600, 3600, "Seconds"),
  "OSD/Animation/Seed": num(true, 1, 0, 999999, "Flicker: another number gives another random pattern"),
  "OSD/Animation/Min": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/Max": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/Stability": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/FaultLength": num(false, 0.1, 0, 3600, "Seconds"),
  "OSD/Animation/Sound": FieldType(kind: fkSound, impulse: true),   # Ambient by SoundKind (objectFieldType).
  "OSD/Animation/SoundPitch": num(false, 0.05, 0.1, 4, "1 = normal, 0.5 = an octave down (Arklite)"),
  "OSD/Animation/SoundPitchMax": num(false, 0.05, 0.1, 4, "Each play (an ambient: each start) picks a pitch from SoundPitch to this; empty = always SoundPitch"),
  "OSD/Animation/SoundVolume": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/SoundMinRadius": num(false, 5, 0, 100000, "Ambient: full volume within this distance"),
  "OSD/Animation/SoundMaxRadius": num(false, 5, 0, 100000, "Ambient: silent beyond this distance")}.toTable

const
  # ONCC fields by OniSplit type.
  ClassBools = ["CantTouchThis", "HasDaodanPowers", "HasSupershield"]
  ClassBytes = ["JumpConstants/JumpDistanceSquares", "JumpConstants/JumpHeight", "WeaponHand"]
  ClassInt16 = ["AIConstants/WeaponSkills/AIWeaponSkill/MaxShotDelay",
    "AIConstants/WeaponSkills/AIWeaponSkill/MinShotDelay", "HurtSoundConstants/BasePercentage",
    "HurtSoundConstants/DeathChance", "HurtSoundConstants/HeavyTreshold", "HurtSoundConstants/MaxLight",
    "HurtSoundConstants/MaxMedium", "HurtSoundConstants/MaxPercentage", "HurtSoundConstants/MediumTreshold",
    "HurtSoundConstants/MinTimer", "HurtSoundConstants/PercentageThreshold", "HurtSoundConstants/Timer",
    "HurtSoundConstants/VolumeTreshold", "InventoryConstants/HypoRegenerationRate",
    "ShadowConstants/AlphaFade", "ShadowConstants/AlphaMax"]
  ClassUInt16 = ["AIConstants/DazedMaxFrames", "AIConstants/DazedMinFrames", "AIRateOfFire",
    "AirConstants/FramesFallGravity", "AirConstants/JetpackTimer", "DeathDeleteDelay"]
  ClassInt32 = ["AIConstants/CombatId", "AIConstants/DeadMakeSureDelay", "AIConstants/DeadTauntChance",
    "AIConstants/DodgeReactFrames", "AIConstants/FriendlyThreatDefiniteTimer",
    "AIConstants/FriendlyThreatStrongTimer", "AIConstants/FriendlyThreatWeakTimer",
    "AIConstants/GoForGunChance", "AIConstants/HostileThreatDefiniteTimer",
    "AIConstants/HostileThreatStrongTimer", "AIConstants/HostileThreatWeakTimer",
    "AIConstants/InvestigateBodyDelay", "AIConstants/LostContactDelay", "AIConstants/MeleeId",
    "AIConstants/RunPickupChance", "AIConstants/Targeting/PredictDelayFrames",
    "AIConstants/Targeting/PredictPositionDelayFrames", "AIConstants/Targeting/PredictTrendFrames",
    "AIConstants/Targeting/PredictVelocityFrames", "FightModeTimer", "Health",
    "IdleAnimation1Timer", "IdleAnimation2Timer"]
  ClassFloats = ["AIConstants/DodgeTimeScale", "AIConstants/DodgeWeightScale",
    "AIConstants/EarshotRadius", "AIConstants/RotationSpeed", "AIConstants/Targeting/PredictAmount",
    "AIConstants/Targeting/StartleMissAngle", "AIConstants/Targeting/StartleMissDistance",
    "AIConstants/VisionConstants/CentralDistance", "AIConstants/VisionConstants/CentralMax",
    "AIConstants/VisionConstants/CentralRange", "AIConstants/VisionConstants/PeripheralDistance",
    "AIConstants/VisionConstants/PeripheralMax", "AIConstants/VisionConstants/PeripheralRange",
    "AIConstants/VisionConstants/VerticalRange", "AIConstants/WeaponSkills/AIWeaponSkill/BestAimingAngle",
    "AIConstants/WeaponSkills/AIWeaponSkill/RecoilCompensation",
    "AIConstants/WeaponSkills/AIWeaponSkill/ShootingInaccuracyMultiplier",
    "AIConstants/WeaponSkills/AIWeaponSkill/ShotGroupDecay",
    "AIConstants/WeaponSkills/AIWeaponSkill/ShotGroupError", "AirConstants/FallGravity",
    "AirConstants/JetpackAcceleration", "AirConstants/JumpGravity", "AirConstants/JumpStartVelocity",
    "AirConstants/MaxDamageFallingHeight", "AirConstants/MaxNoDamageFallingHeight",
    "AirConstants/MaxVelocity", "AutoFreezeConstants/DistanceXZ", "AutoFreezeConstants/DistanceY",
    "BossShieldProtectAmount", "CoverConstants/RayAngle", "CoverConstants/RayAngleMax",
    "CoverConstants/RayIncrement", "CoverConstants/RayMax", "DamageFactors/Float",
    "HurtSoundConstants/MinVolume", "JumpConstants/JumpDistance", "LODConstants/Float",
    "MaxBodySizeFactor", "MinBodySizeFactor", "ShadowConstants/FadeHeight",
    "ShadowConstants/MaxHeight", "ShadowConstants/SizeFade", "ShadowConstants/SizeMax",
    "ShadowConstants/SizeMin"]

proc classType(path: string): FieldType =
  ## Steps of 5 (up to 100) for chances and percentages, 10 for Health.
  if path == "AIConstants/Flags": return FieldType(kind: fkFlags, flags: aiFlags)
  if path == "ShadowConstants/Texture": return FieldType(kind: fkTexture)
  if path.endsWith("Sound"):
    # Hurt sounds are impulses; what the AI says is an ambient (speech).
    return FieldType(kind: fkSound, impulse: path.startsWith("HurtSoundConstants/"))
  let pct = path.endsWith("Probability") or path.endsWith("Chance") or path.endsWith("Percentage")
  if path in ClassBools: FieldType(kind: fkToggle)
  elif path.endsWith("Probability"): num(true, 5, 0, 100, "Percent")
  elif path in ClassBytes: num(true, 1, 0, 255)
  elif path in ClassInt16: num(true, if pct: 5 else: 1, -32768, 32767)
  elif path in ClassUInt16: num(true, 1, 0, 65535, if "Frames" in path: Frames else: "")
  elif path in ClassInt32:
    num(true, (if path == "Health": 10.0 elif pct: 5 else: 1), -2147483648.0, 2147483647.0,
        if path.endsWith("Frames") or path.endsWith("Timer") or path.endsWith("Delay"): Frames else: "")
  elif path in ClassFloats: num(false, 0.1, -1e9, 1e9)
  else: FieldType(kind: fkText)

const
  ParticleNames = ["Class", "Selector", "Target", "LinkTo", "DisplayType", "DisableDetailLevel",
                   "Effect", "ImpactType", "Variable", "State"]   ## Names, not numbers.
  ParticleWhole = ["Emitter", "Action", "Attach", "Orientation", "DamageType", "ImpactModifier", "Direction",
                   "Space", "Particles", "Copies", "SelfImmune", "FallOff", "HorizontalOnly", "PredictPosition",
                   "NoSideways", "RotateVelocity", "CanHitMultiple", "DamageEnvironment", "Tick",
                   "TurnOffTreshold"]   ## Whole numbers in the game's data: the wheel steps by 1.
  ParticleColors = ["Tint", "Color", "Color0", "Color1"]

proc particleType(path, attr: string): FieldType =
  ## A value of a particle class. A number can also name one of the class's
  ## variables, so it stays free; a range's Min and Max are of the same kind.
  var p = path
  for wrap in ["/Random", "/BellCurve"]:
    if p.endsWith(wrap): p.setLen p.len - wrap.len
  let last = p[p.rfind('/') + 1 .. ^1]
  let cut = path.rfind('/')
  if attr.len == 0:
    case eventParam(p)
    of pkFloat: discard
    of pkColor: return FieldType(kind: fkColor)
    of pkImpulse: return FieldType(kind: fkSound, impulse: true)
    of pkAmbient: return FieldType(kind: fkSound)
    else: return FieldType(kind: fkText)   # Picked from a list.
  if attr.len == 0 and cut > 0 and flagGroup(path[0 ..< cut]).anyIt(it.name == path[cut + 1 .. ^1]):
    return FieldType(kind: fkToggle)
  if last in ParticleColors: return FieldType(kind: fkColor)
  if path == "Emitters/Emitter/Flags": return FieldType(kind: fkFlags, flags: emitterFlags)
  if path == "Appearance/TexGeom": return FieldType(kind: fkTexture)
  if path == "Options/FlyBySoundName": return FieldType(kind: fkSound, impulse: true)
  if p.endsWith("Sound/Sound"): return FieldType(kind: fkSound, impulse: p.endsWith("ImpulseSound/Sound"))
  if last in ParticleNames or path in ["Emitters/Emitter/Orientation", "Emitters/Emitter/OrientationUp"]:
    return FieldType(kind: fkText)
  result = num(false, if last in ParticleWhole: 1.0 else: 0.1, -1e9, 1e9)
  result.free = true

proc fieldType*(tag, path, attr: string): FieldType =
  ## The input for o's field (path, attr); fkText when it takes text or names something.
  let p = path.replace(re"\[\d+\]", "")
  if tag == "ONCC":
    return if attr.len > 0: FieldType(kind: fkText) else: classType(p)
  if tag == "Particle": return particleType(p, attr)
  if attr.len > 0:
    if tag == "PATR" and p.startsWith("OSD/Points"): return patrolAttrs.getOrDefault(attr)
    return
  if tag in ["LITE", "SPOT", "SUNL"]: return lightTypes.getOrDefault(p)
  if tag == "CHAR" and p.startsWith("OSD/Inventory/"): return short()
  objectTypes.getOrDefault(tag & " " & p)
