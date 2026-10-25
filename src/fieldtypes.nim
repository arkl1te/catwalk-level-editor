## What kind of input an Entity tab or class field takes, beyond text: a number
## (with its step and range), an on/off box, or a pair of numbers. Colors
## ("R G B") and XYZ values are told apart by their name and value (panels.nim).
##
## Object field types follow OniSplit's BINACJBO XML reader (ReadElementContentAsInt
## or AsFloat, the attributes' ToInt16/ToSingle); character class types its
## ONCC metadata (Oni.Metadata.InstanceMetadata). Ids that name another object
## or profile stay text fields: their dropdown lists what they can point at.

import std/[strutils, re, tables]

type
  FieldKind* = enum fkText, fkNumber, fkToggle, fkPair
  FieldType* = object
    kind*: FieldKind
    whole*: bool            ## Whole numbers only.
    step*, lo*, hi*: float
    tip*: string            ## What the value means, when the name doesn't say.

proc num(whole: bool, step, lo, hi: float, tip = ""): FieldType =
  FieldType(kind: fkNumber, whole: whole, step: step, lo: lo, hi: hi, tip: tip)

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
  "OSD/Animation/Min": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/Max": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/Stability": num(false, 0.05, 0, 1, Unit),
  "OSD/Animation/FaultLength": num(false, 0.1, 0, 3600, "Seconds")}.toTable

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

proc fieldType*(tag, path, attr: string): FieldType =
  ## The input for o's field (path, attr); fkText when it takes text or names something.
  let p = path.replace(re"\[\d+\]", "")
  if tag == "ONCC":
    return if attr.len > 0: FieldType(kind: fkText) else: classType(p)
  if attr.len > 0:
    if tag == "PATR" and p.startsWith("OSD/Points"): return patrolAttrs.getOrDefault(attr)
    return
  if tag in ["LITE", "SPOT", "SUNL"]: return lightTypes.getOrDefault(p)
  if tag == "CHAR" and p.startsWith("OSD/Inventory/"): return short()
  objectTypes.getOrDefault(tag & " " & p)
