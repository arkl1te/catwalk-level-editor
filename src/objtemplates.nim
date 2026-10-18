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
  "SNDG": """<SNDG Id="0"><Header><Flags></Flags><Position>0 0 0</Position><Rotation>0 0 0</Rotation></Header>
<OSD><Class></Class><Box><Min>-20 -20 -20</Min><Max>20 20 20</Max></Box><Volume>1</Volume><Pitch>1</Pitch></OSD></SNDG>""",
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
  "NEUT": "Neutral", "PART": "Particle", "PATR": "Patrol Path", "PWRU": "PowerUp",
  "SNDG": "Sound", "TRGV": "Trigger Volume", "TRIG": "Trigger", "TURR": "Turret",
  "WEAP": "Weapon"}.toTable

const AutoStartTag* = "autostart"
  ## Tag of particles Build starts when the level loads. The engine only sends a
  ## placed particle its Create event; emitters that switch on in the Start event
  ## (fire, smoke, steam, sparks...) stay off until a script does
  ## "particle <tag> do start", as every game level does for them.

const GunkTypes* = {"DOOR": 3, "FURN": 5, "TRIG": 13, "TURR": 14, "CONS": 15}.toTable
  ## Object types whose geometry lives in the level's AKEV, linked by
  ## ObjectId = type << 24 | object id.
