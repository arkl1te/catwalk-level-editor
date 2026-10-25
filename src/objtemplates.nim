## Starting XML for new objects of each type, used by the entity browser when
## the level has no object of that type to copy. Position and Id are filled in
## when the object is placed.

import std/tables

const Templates* = {
  "CHAR": """<CHAR Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Flags></Flags><Class>striker_easy_1</Class><Name>new_character</Name><Weapon></Weapon>
<Scripts><Spawn></Spawn><Die></Die><Combat></Combat><Alarm></Alarm><Hurt></Hurt><Defeated></Defeated><OutOfAmmo></OutOfAmmo><NoPath></NoPath></Scripts>
<AdditionalHealth>0</AdditionalHealth><Job><Type>None</Type><PatrolPathId>0</PatrolPathId></Job>
<Behaviors><CombatId>0</CombatId><MeleeId>0</MeleeId><NeutralId>0</NeutralId></Behaviors>
<Inventory><Ammo><Use>0</Use><Drop>0</Drop></Ammo><EnergyCell><Use>0</Use><Drop>0</Drop></EnergyCell><Hypo><Use>0</Use><Drop>0</Drop></Hypo><Shield><Use>0</Use><Drop>0</Drop></Shield><Invisibility><Use>0</Use><Drop>0</Drop></Invisibility></Inventory>
<Team>Syndicate</Team><AmmoPercentage>100</AmmoPercentage>
<Alert><Initial>Lull</Initial><Minimal>Lull</Minimal><JobStart>Low</JobStart><Investigate>Medium</Investigate></Alert>
<AlarmGroups>0</AlarmGroups><Pursuit><StrongUnseen>Look</StrongUnseen><WeakUnseen>Look</WeakUnseen><StrongSeen>Look</StrongSeen><WeakSeen>Look</WeakSeen><Lost>ReturnToJob</Lost></Pursuit></OSD></CHAR>""",
  "CONS": """<CONS Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class>console0</Class><ConsoleId>0</ConsoleId><Flags>InitialActive</Flags><InactiveTexture>_con_INACTIVE</InactiveTexture><ActiveTexture>_con_WH1</ActiveTexture><TriggeredTexture>_con_USED</TriggeredTexture><Events /></OSD></CONS>""",
  "DOOR": """<DOOR Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class>wh_door1dbl</Class><DoorId>0</DoorId><KeyId>0</KeyId><Flags></Flags><Center>0 0 0</Center><SquaredActivationRadius>900</SquaredActivationRadius><Texture1></Texture1><Texture2></Texture2><Events /></OSD></DOOR>""",
  "FLAG": """<FLAG Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Color>255 255 0</Color><Prefix>0</Prefix><FlagId>0</FlagId><Notes></Notes></OSD></FLAG>""",
  "FURN": """<FURN Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class></Class><Particle></Particle></OSD></FURN>""",
  "LITE": """<LITE Id="0"><Header><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Enabled>1</Enabled><Color>255 236 210</Color><Intensity>1</Intensity><Radius>200</Radius><Shadows>1</Shadows>
<Animation><Mode>Off</Mode><Color>0 0 0</Color><Period>2</Period><Offset>0</Offset><Interpolation>Smooth</Interpolation><Min>0</Min><Max>1</Max><Stability>0</Stability><FaultLength>1</FaultLength></Animation></OSD></LITE>""",
  "NEUT": """<NEUT Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Name>new_neutral</Name><NeutralId>0</NeutralId><Flags></Flags>
<Ranges><Trigger>100</Trigger><Talk>40</Talk><Follow>200</Follow><Enemy>70</Enemy></Ranges>
<Speech><Trigger></Trigger><Abort></Abort><Enemy></Enemy></Speech><Script><AfterTalk></AfterTalk></Script>
<Rewards><WeaponClass></WeaponClass><Ammo>0</Ammo><EnergyCell>0</EnergyCell><Hypo>0</Hypo><Other></Other></Rewards><DialogLines /></OSD></NEUT>""",
  "PART": """<PART Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class></Class><Tag></Tag><Flags>0</Flags><DecalScale>1 1</DecalScale></OSD></PART>""",
  "PATR": """<PATR Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Name>new_path</Name><PatrolId>0</PatrolId><ReturnToNearest>1</ReturnToNearest><Points /></OSD></PATR>""",
  "PWRU": """<PWRU Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class>Hypo</Class></OSD></PWRU>""",
  "SPOT": """<SPOT Id="0"><Header><Position>0 0 0</Position><Rotation>90 0 0</Rotation></Header>
<OSD><Enabled>1</Enabled><Color>255 236 210</Color><Intensity>1.5</Intensity><Radius>300</Radius><Angle>60</Angle><Softness>0.3</Softness><Shadows>1</Shadows>
<Animation><Mode>Off</Mode><Color>0 0 0</Color><Period>2</Period><Offset>0</Offset><Interpolation>Smooth</Interpolation><Min>0</Min><Max>1</Max><Stability>0</Stability><FaultLength>1</FaultLength></Animation></OSD></SPOT>""",
  "SNDG": """<SNDG Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class></Class><Box><Min>-20 -20 -20</Min><Max>20 20 20</Max></Box><Volume>1</Volume><Pitch>1</Pitch></OSD></SNDG>""",
  "SUNL": """<SUNL Id="0"><Header><Position>0 0 0</Position><Rotation>50 30 0</Rotation></Header>
<OSD><Enabled>1</Enabled><Color>255 244 225</Color><Intensity>0.8</Intensity><Shadows>1</Shadows>
<Animation><Mode>Off</Mode><Color>0 0 0</Color><Period>2</Period><Offset>0</Offset><Interpolation>Smooth</Interpolation><Min>0</Min><Max>1</Max><Stability>0</Stability><FaultLength>1</FaultLength></Animation></OSD></SUNL>""",
  "TRGV": """<TRGV Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Name>new_trigger_volume</Name><Scripts><Entry></Entry><Inside></Inside><Exit></Exit></Scripts><Teams>1</Teams><Size>20 40 20</Size><TriggerVolumeId>0</TriggerVolumeId><ParentId>0</ParentId><Notes></Notes><Flags>PlayerOnly</Flags></OSD></TRGV>""",
  "TRIG": """<TRIG Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class>trigger_long</Class><TriggerId>0</TriggerId><Flags></Flags><LaserColor>255 0 0</LaserColor><StartPosition>0</StartPosition><Speed>0.5</Speed><EmitterCount>1</EmitterCount><TimeOn>0</TimeOn><TimeOff>0</TimeOff><Events /></OSD></TRIG>""",
  "TURR": """<TURR Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class></Class><TurretId>0</TurretId><Flags></Flags><TargetedTeams>Konoko</TargetedTeams></OSD></TURR>""",
  "WEAP": """<WEAP Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class>w1_tap</Class></OSD></WEAP>"""}.toTable

const FileNames* = {
  "CHAR": "Character", "CONS": "Console", "DOOR": "Door", "FLAG": "Flag", "FURN": "Furniture",
  "LITE": "Lights", "NEUT": "Neutral", "PART": "Particle", "PATR": "Patrol Path", "PWRU": "PowerUp",
  "SNDG": "Sound", "SPOT": "Lights", "SUNL": "Lights", "TRGV": "Trigger Volume", "TRIG": "Trigger", "TURR": "Turret",
  "WEAP": "Weapon"}.toTable

const
  PointLightTag* = "LITE"
  SpotLightTag* = "SPOT"
    ## A cone of light along its forward axis (local +Z, turned by its Rotation):
    ## Angle is the cone's full width in degrees, Softness how much of it fades
    ## out toward the edge (0 hard, 1 from the middle), Radius how far it reaches.
  DirLightTag* = "SUNL"
    ## Its light travels along its forward axis, like a sun: the same
    ## everywhere, without falloff.
  LightTags* = [PointLightTag, SpotLightTag, DirLightTag]
    ## Catwalk's own object types, kept in the project's lights.xml (never built
    ## into the level). Bake light sums their light into the geometry's vertex
    ## colors (lighting.nim). Their OSD/Animation (Mode Off, Pulse or Flicker)
    ## makes the light go to Animation/Color (times Intensity) and back in the
    ## game, as corner light animations do (Arklite's vertex_light.c), with the
    ## same settings (geometry.CornerAnim; appstate.lightAnim).
  AimedTags* = [SpotLightTag, DirLightTag]
    ## Lights placed with their template's slant (a new point light is turned
    ## back to 0 0 0 like any object).

  Categories* = [
    (name: "Characters", generic: "Generic characters", tags: @["CHAR", "NEUT"]),
    (name: "Items", generic: "Generic items", tags: @["WEAP", "PWRU"]),
    (name: "Mechanisms", generic: "Generic mechanisms", tags: @["DOOR", "CONS", "TRIG", "TURR"]),
    (name: "Environment", generic: "Generic environment", tags: @["FURN", "PART", "SNDG"]),
    (name: "Lights", generic: "Generic lights", tags: @[PointLightTag, SpotLightTag, DirLightTag]),
    (name: "AI & scripting", generic: "Generic AI & scripting", tags: @["FLAG", "PATR", "TRGV"])]
    ## Object types by what they are, for the entity browser (a heading per
    ## category; generic is the group of plain objects of its types) and the
    ## Create object menu (TrenchBroom groups entity definitions the same way).

proc categoryIndex*(tag: string): int =
  ## Index in Categories; types not listed come last.
  for i, c in Categories:
    if tag in c.tags: return i
  Categories.len

const AutoStartTag* = "autostart"
  ## Tag of particles Build starts when the level loads. The engine only sends a
  ## placed particle its Create event; emitters that switch on in the Start event
  ## (fire, smoke, steam, sparks...) stay off until a script does
  ## "particle <tag> do start", as every game level does for them.

const GunkTypes* = {"DOOR": 3, "FURN": 5, "TRIG": 13, "TURR": 14, "CONS": 15}.toTable
  ## Object types whose geometry lives in the level's AKEV, linked by
  ## ObjectId = type << 24 | object id.
