## What a particle class's Events can hold, and the edits to them. The events and
## actions are OniSplit's names (ParticleXml.eventActionInfoTable), in the game's
## order; the parameters are Bungie's P3gActionInfo. Nothing else reaches the file:
## an unknown name stops the build.
##
## An action's Action parameter is its target's position in the whole class, events
## in EventDefs order, so anything that moves an action renumbers those (editActions).

import std/[xmltree, strutils, tables, sequtils]

type
  ParamKind* = enum
    pkFloat, pkVar, pkPingPong, pkColor, pkAction, pkEmitter, pkFalloff, pkCoordFrame,
    pkOrient, pkBool, pkModifier, pkDamage, pkDirection, pkClass, pkImpact, pkImpulse, pkAmbient

  ActionParam* = object
    name*, value*: string   ## Element name and a new action's value.
    kind*: ParamKind

  ActionDef* = object
    name*, label*, group*, tip*: string
    params*: seq[ActionParam]

  EventDef* = tuple[name, label, tip: string]

const
  EventDefs*: array[16, EventDef] = [
    ("Update", "Update", "Every frame the particle lives. Actions run in this order."),
    ("Pulse", "Pulse", "Sent by the game to a weapon's, turret's or character's particles. Emitters never send it: for each emitted particle, use Create on that particle's class."),
    ("Start", "Start", "The particle is turned on (a script's particle start, a weapon's trigger)."),
    ("Stop", "Stop", "The particle is turned off."),
    ("BackgroundFxStart", "Background FX start", "A weapon's or character's background effect starts."),
    ("BackgroundFxStop", "Background FX stop", "A weapon's or character's background effect stops."),
    ("HitWall", "Hit wall", "It touches the level. Needs Collide With Walls."),
    ("HitCharacter", "Hit character", "It touches a character. Needs Collide With Chars."),
    ("Lifetime", "Lifetime", "Its Lifetime runs out."),
    ("Explode", "Explode", "It explodes (an Explode action, or a script)."),
    ("BrokenLink", "Broken link", "What it was linked to is gone."),
    ("Create", "Create", "It's created: runs once for every particle an emitter makes."),
    ("Die", "Die", "It's removed."),
    ("NewAttractor", "New attractor", "It finds a new attractor."),
    ("DelayStart", "Delay start", "A weapon's delayed fire starts."),
    ("DelayStop", "Delay stop", "A weapon's delayed fire stops.")]

proc p(name: string, kind = pkFloat, value = "0"): ActionParam =
  ActionParam(name: name, kind: kind, value: value)

proc v(name: string): ActionParam = p(name, pkVar, "")

proc act(group, name, label, tip: string, params: varargs[ActionParam]): ActionDef =
  ActionDef(name: name, label: label, group: group, tip: tip, params: @params)

const ActionGroups* = ["Sound", "Emitters", "Life", "Variables", "Movement", "Rotation",
                       "Attractors", "Collision", "Damage", "Looks", "Action control", "Links", "Special"]

let ActionDefs*: seq[ActionDef] = @[
  act("Sound", "ImpulseSound", "Impulse sound", "Plays an impulse sound once, at the particle.", p("Sound", pkImpulse, "")),
  act("Sound", "AmbientSound", "Start ambient sound", "Starts an ambient sound that follows the particle.", p("Sound", pkAmbient, "")),
  act("Sound", "EndAmbientSound", "End ambient sound", "Stops the particle's ambient sound."),
  act("Emitters", "EmitActivate", "Enable emitter", "Turns an emitter on.", p("Emitter", pkEmitter)),
  act("Emitters", "EmitDeactivate", "Disable emitter", "Turns an emitter off.", p("Emitter", pkEmitter)),
  act("Emitters", "EmitParticles", "Emit particles", "An emitter makes this many at once.", p("Emitter", pkEmitter), p("Particles", pkFloat, "1")),
  act("Emitters", "ChangeClass", "Change class", "Turns the particle into its emitter's class.", p("Emitter", pkEmitter)),
  act("Emitters", "KillLastEmitted", "Kill last emitted", "Removes what the emitter made last.", p("Emitter", pkEmitter)),
  act("Emitters", "ExplodeLastEmitted", "Explode last emitted", "Explodes what the emitter made last.", p("Emitter", pkEmitter)),
  act("Life", "FadeOut", "Fade out", "Fades out over this many seconds, then dies.", p("TimeToDie", pkFloat, "1")),
  act("Life", "Die", "Die", "Removes the particle."),
  act("Life", "SetLifetime", "Set lifetime", "Sets the seconds it has left.", p("Time", pkFloat, "1")),
  act("Life", "Explode", "Explode", "Sends the Explode event."),
  act("Life", "Stop", "Stop", "Stops the particle's movement."),
  act("Life", "StopIfSlow", "Stop below speed", "Stops once it's slower than this.", p("Speed")),
  act("Life", "StopIfBreakable", "Stop if breakable", "Stops on something breakable."),
  act("Variables", "AnimateLinear", "Linear change", "Changes a variable at a steady rate.", v("Target"), p("Rate", pkFloat, "1")),
  act("Variables", "AnimateAccelerated", "Accelerating change", "Changes a variable at a rate that grows.", v("Target"), v("Velocity"), p("Acceleration", pkFloat, "1")),
  act("Variables", "AnimateRandom", "Random change", "Moves a variable at random between two values.", v("Target"), p("Min"), p("Max", pkFloat, "1"), p("Rate", pkFloat, "1")),
  act("Variables", "AnimatePingPong", "Ping-pong change", "Moves a variable up and down between two values. State names a PingPongState variable.", v("Target"), p("State", pkPingPong, ""), p("Min"), p("Max", pkFloat, "1"), p("Rate", pkFloat, "1")),
  act("Variables", "AnimateLoop", "Looping change", "Moves a variable from Min to Max, again and again.", v("Target"), p("Min"), p("Max", pkFloat, "1"), p("Rate", pkFloat, "1")),
  act("Variables", "AnimateToValue", "Change to value", "Moves a variable until it reaches Value.", v("Target"), p("Rate", pkFloat, "1"), p("Value")),
  act("Variables", "ColorInterpolate", "Color blend", "Sets a color variable between two colors. Amount: 0 is the first, 1 the second.", v("Target"), p("Color0", pkColor, "255 255 255"), p("Color1", pkColor, "255 255 255"), p("Amount")),
  act("Variables", "SetVariable", "Set variable", "Sets a variable.", v("Target"), p("Value")),
  act("Variables", "RecalculateAll", "Recalculate all", "Picks the variables' random values again."),
  act("Movement", "MoveLine", "Apply velocity", "Moves it by its velocity. Without this it stays put."),
  act("Movement", "MoveGravity", "Apply gravity", "Pulls it down. 1 is full gravity.", p("Fraction", pkFloat, "1")),
  act("Movement", "MoveResistance", "Air resistance", "Slows it down.", p("Resistance", pkFloat, "1"), p("MinimumVelocity")),
  act("Movement", "MoveDrift", "Drift", "Pushes it toward a direction.", p("Acceleration"), p("MaxSpeed"), p("SidewaysDecay"), p("DirX"), p("DirY", pkFloat, "1"), p("DirZ"), p("Space", pkCoordFrame)),
  act("Movement", "MoveSpiral", "Spiral", "Moves it around a circle. Theta names a variable.", v("Theta"), p("Radius", pkFloat, "1"), p("RotateSpeed", pkFloat, "1")),
  act("Movement", "SpiralTangent", "Spiral tangent", "Sets its velocity along a spiral.", p("Theta"), p("Radius", pkFloat, "1"), p("Rotate_speed", pkFloat, "1")),
  act("Movement", "SetVelocity", "Set speed", "Sets its speed.", p("Speed"), p("Space", pkCoordFrame), p("NoSideways", pkBool)),
  act("Movement", "KillBeyondPoint", "Kill beyond point", "Removes it past a coordinate.", p("Direction", pkDirection), p("Value")),
  act("Movement", "RandomSwirl", "Random swirl", "Wanders. SwirlAngle names a variable.", v("SwirlAngle"), p("SwirlBaseRate"), p("SwirlDeltaRate"), p("SwirlSpeed")),
  act("Movement", "AvoidWalls", "Avoid walls", "Steers away from walls. The first five name variables.", v("AxisX"), v("AxisY"), v("AxisZ"), v("CurrentAngle"), v("TimeUntilCheck"), p("SenseDistance", pkFloat, "10"), p("TurningSpeed", pkFloat, "1"), p("TurningDecay")),
  act("Movement", "FloatAbovePlayer", "Follow player", "Stays above the player.", p("Height", pkFloat, "10")),
  act("Rotation", "RotateX", "Rotate X", "Turns it around X. Needs orientation.", p("Space", pkCoordFrame), p("Rate", pkFloat, "1"), p("RotateVelocity", pkBool)),
  act("Rotation", "RotateY", "Rotate Y", "Turns it around Y. Needs orientation.", p("Space", pkCoordFrame), p("Rate", pkFloat, "1"), p("RotateVelocity", pkBool)),
  act("Rotation", "RotateZ", "Rotate Z", "Turns it around Z. Needs orientation.", p("Space", pkCoordFrame), p("Rate", pkFloat, "1"), p("RotateVelocity", pkBool)),
  act("Attractors", "FindAttractor", "Find attractor", "Looks for an attractor (see Attractor).", p("DelayTime")),
  act("Attractors", "AttractGravity", "Attract gravity", "Pulled toward the attractor.", p("Gravity", pkFloat, "1"), p("MaxG", pkFloat, "1"), p("HorizontalOnly", pkBool)),
  act("Attractors", "AttractHoming", "Attract homing", "Turns toward the attractor.", p("TurnSpeed", pkFloat, "1"), p("PredictPosition", pkBool), p("HorizontalOnly", pkBool)),
  act("Attractors", "AttractSpring", "Attract spring", "Stays a distance from the attractor.", p("AccelRate", pkFloat, "1"), p("MaxAccel", pkFloat, "1"), p("DesiredDistance", pkFloat, "10")),
  act("Collision", "Bounce", "Bounce", "Bounces off what it hit.", p("ElasticDirect", pkFloat, "0.5"), p("ElasticGlancing", pkFloat, "0.5")),
  act("Collision", "StickToWall", "Stick to wall", "Stays where it hit."),
  act("Collision", "Chop", "Chop particle", "Cuts it so it doesn't poke through the wall."),
  act("Collision", "CollisionEffect", "Create effect", "Makes a particle at the hit point.", p("Effect", pkClass, ""), p("WallOffset"), p("Orientation", pkOrient, "3"), p("Attach", pkBool)),
  act("Collision", "ImpactEffect", "Impact effect", "Plays an impact type's sound and particles.", p("ImpactType", pkImpact, ""), p("ImpactModifier", pkModifier)),
  act("Damage", "DamageChar", "Damage character", "Hurts the character it hit.", p("Damage", pkFloat, "10"), p("StunDamage"), p("KnockBack"), p("DamageType", pkDamage), p("SelfImmune", pkBool, "1"), p("CanHitMultiple", pkBool)),
  act("Damage", "DamageBlast", "Blast damage", "Hurts everything in a radius.", p("Damage", pkFloat, "10"), p("StunDamage"), p("KnockBack"), p("Radius", pkFloat, "10"), p("FallOff", pkFalloff, "1"), p("DamageType", pkDamage), p("SelfImmune", pkBool, "1"), p("DamageEnvironment", pkBool)),
  act("Damage", "DamageEnvironment", "Damage environment", "Hurts breakable objects it hit.", p("Damage", pkFloat, "10")),
  act("Damage", "GlassCharge", "Glass charge", "Breaks glass around it.", p("BlastVelocity", pkFloat, "1"), p("Radius", pkFloat, "10")),
  act("Looks", "Show", "Unhide particle", "Shows it."),
  act("Looks", "Hide", "Hide particle", "Hides it."),
  act("Looks", "SetTextureTick", "Set texture tick", "Picks the animated texture's frame.", p("Tick", pkFloat, "0")),
  act("Looks", "RandomTextureFrame", "Random texture frame", "Picks a random frame of the animated texture."),
  act("Action control", "EnableNow", "Enable now", "Turns another Update action on.", p("Action", pkAction)),
  act("Action control", "DisableNow", "Disable now", "Turns another Update action off.", p("Action", pkAction)),
  act("Action control", "EnableAtTime", "Enable at time", "Turns another Update action on when it has lived this long.", p("Action", pkAction), p("Lifetime")),
  act("Action control", "DisableAtTime", "Disable at time", "Turns another Update action off when it has lived this long.", p("Action", pkAction), p("Lifetime")),
  act("Action control", "EnableAbove", "Enable above", "Turns another Update action on above a value.", p("Action", pkAction), p("Var"), p("Threshold")),
  act("Action control", "EnableBelow", "Enable below", "Turns another Update action on below a value.", p("Action", pkAction), p("Var"), p("Threshold")),
  act("Links", "StopLink", "Stop link", "Stops following its link."),
  act("Links", "CheckLink", "Check link", "Sends Broken Link if its link is gone."),
  act("Links", "BreakLink", "Break link", "Ends its link."),
  act("Special", "SuperBallTrigger", "Superball trigger", "The Superball's bounce fuse.", p("Emitter", pkEmitter), p("FuseTime", pkFloat, "1")),
  act("Special", "SuperParticle", "Super particle", "Scales a variable by a character's Daodan power.", v("Variable"), p("BaseValue"), p("DeltaValue"), p("MinValue"), p("MaxValue", pkFloat, "1"))]

let ActionIndex = (proc(): Table[string, int] =
  for i, d in ActionDefs: result[d.name] = i)()

proc actionDef*(name: string): ptr ActionDef =
  ## The action's definition, or nil. Valid for the program's life.
  let i = ActionIndex.getOrDefault(name, -1)
  if i >= 0: result = unsafeAddr ActionDefs[i]

proc eventDef*(name: string): EventDef =
  for e in EventDefs:
    if e.name == name: return e

proc paramKind*(action, param: string): ParamKind =
  ## pkFloat for anything the table doesn't know.
  let d = actionDef(action)
  if d != nil:
    for q in d.params:
      if q.name == param: return q.kind
  pkFloat

proc eventParam*(path: string): ParamKind =
  ## The kind of the parameter at a class field's path (Events/<event>/<action>/<param>).
  let seg = path.split('/')
  if seg.len == 4 and seg[0] == "Events": paramKind(seg[2].split('[')[0], seg[3]) else: pkFloat

proc paramChoices*(k: ParamKind): seq[(string, string)] =
  ## (value, its meaning) of a parameter that's a number standing for a name.
  case k
  of pkBool: @[("0", "No"), ("1", "Yes")]
  of pkCoordFrame: @[("0", "Local"), ("1", "World")]
  of pkFalloff: @[("0", "None"), ("1", "Linear"), ("2", "Inverse square")]
  of pkOrient: @[("0", "Unchanged"), ("1", "Reversed"), ("2", "Reflected"), ("3", "Wall normal")]
  of pkDirection: @[("0", "+X"), ("1", "-X"), ("2", "+Y"), ("3", "-Y"), ("4", "+Z"), ("5", "-Z")]
  of pkModifier: @[("0", "Any"), ("1", "Heavy damage"), ("2", "Medium damage"), ("3", "Light damage")]
  of pkDamage: @[("0", "Normal"), ("1", "Minor stun"), ("2", "Major stun"), ("3", "Minor knockdown"),
                 ("4", "Major knockdown"), ("5", "Blown up"), ("6", "Pick up")]
  else: @[]

proc eventsOf*(root: XmlNode): XmlNode = root.child("Events")

proc elements(n: XmlNode): seq[XmlNode] =
  if n != nil:
    for c in n:
      if c.kind == xnElement: result.add c

proc eventOf*(root: XmlNode, name: string): XmlNode =
  let ev = root.eventsOf
  if ev != nil: result = ev.child(name)

proc classActions*(root: XmlNode): seq[(string, XmlNode)] =
  ## Every action with its event, in the order the Action parameter counts them.
  for e in EventDefs:
    for a in root.eventOf(e.name).elements: result.add (e.name, a)

proc actionKey*(event: XmlNode, action: XmlNode): string =
  ## The action's path segment: its tag, and [n] if the event has several (fields).
  var total, seen = 0
  var at = -1
  for c in event.elements:
    if c.tag == action.tag:
      if c == action: at = seen
      inc seen
      inc total
  if total > 1: action.tag & "[" & $at & "]" else: action.tag

proc actionByKey*(event: XmlNode, key: string): XmlNode =
  for c in event.elements:
    if event.actionKey(c) == key: return c

proc addVariable(root: XmlNode, tag, name, value: string): string =
  ## Adds a variable named name, or with a number after it if that's taken.
  var vars = root.child("Variables")
  if vars == nil:
    vars = newElement("Variables")
    var at = root.len
    for i in 0 ..< root.len:
      if root[i].kind == xnElement and root[i].tag in ["Emitters", "Events"]:
        at = i
        break
    root.insert(vars, at)
  let taken = vars.elements.mapIt(it.attr("Name"))
  result = name
  var n = 2
  while result in taken:
    result = name & $n
    inc n
  let e = newElement(tag)
  e.attrs = {"Name": result}.toXmlAttributes
  e.add newText(value)
  vars.add e

proc newAction*(root: XmlNode, name: string): XmlNode =
  ## A new action with working values. Target takes the class's first variable of
  ## its type; the others keep state of their own, so each gets a new variable.
  ## None can stay empty: OniSplit would read the next parameter in its place.
  result = newElement(name)
  let d = actionDef(name)
  if d == nil: return
  proc firstVar(tag: string): string =
    for x in root.child("Variables").elements:
      if x.tag == tag: return x.attr("Name")
  for q in d.params:
    let e = newElement(q.name)
    var value = q.value
    if q.kind == pkVar and q.name in ["Target", "Variable"]:
      let color = name == "ColorInterpolate"
      value = firstVar(if color: "Color" else: "Float")
      if value.len == 0:
        value = root.addVariable(if color: "Color" else: "Float", if color: "color" else: "value",
                                 if color: "255 255 255" else: "0")
    elif q.kind == pkVar:
      value = root.addVariable("Float", q.name.toLowerAscii, "0")
    elif q.kind == pkPingPong:
      value = root.addVariable("PingPongState", "pingpong", "0")
    if value.len > 0: e.add newText(value)
    result.add e

proc isVarParam*(k: ParamKind): bool = k in {pkVar, pkPingPong}

proc editActions*(root: XmlNode, change: proc()): int =
  ## Runs change, then points every Action parameter back at the action it named.
  ## Returns how many lost theirs, now at 0.
  let before = root.classActions.mapIt(it[1])
  change()
  let after = root.classActions.mapIt(it[1])
  for (_, a) in root.classActions:
    let d = actionDef(a.tag)
    if d == nil or not d.params.anyIt(it.kind == pkAction): continue
    let n = a.child("Action")
    if n == nil: continue
    var i = -1
    try: i = parseInt(n.innerText.strip)
    except ValueError: continue
    if i notin 0 ..< before.len: continue
    let to = after.find(before[i])
    if to != i:
      while n.len > 0: n.delete(0)
      n.add newText($max(to, 0))
    if to < 0: inc result

proc ensureEvents(root: XmlNode): XmlNode =
  result = root.eventsOf
  if result == nil:
    result = newElement("Events")
    root.add result

proc addEvent*(root: XmlNode, name: string): XmlNode =
  ## The event's element, added where the game's order puts it. Action numbers
  ## don't move, as a new event is empty.
  result = root.eventOf(name)
  if result != nil: return
  let ev = root.ensureEvents
  var order = -1
  for i, e in EventDefs:
    if e.name == name: order = i
  var at = 0
  for i, c in ev.elements:
    var other = 0
    for j, e in EventDefs:
      if e.name == c.tag: other = j
    if other < order: at = i + 1
  result = newElement(name)
  ev.insert(result, at)

proc removeNode(parent, n: XmlNode) =
  for i in 0 ..< parent.len:
    if parent[i] == n:
      parent.delete(i)
      return

proc addAction*(root: XmlNode, event, name: string): int =
  ## Adds the action last in the event. Returns editActions'.
  root.editActions(proc() = root.addEvent(event).add root.newAction(name))

proc removeAction*(root: XmlNode, event: string, action: XmlNode): int =
  root.editActions(proc() = root.eventOf(event).removeNode(action))

proc removeEvent*(root: XmlNode, event: string): int =
  root.editActions(proc() = root.eventsOf.removeNode(root.eventOf(event)))

proc moveAction*(root: XmlNode, event: string, action: XmlNode, by: int): int =
  ## Moves the action earlier or later in its event; order is the order they run in.
  let ev = root.eventOf(event)
  root.editActions(proc() =
    let all = ev.elements
    let i = all.find(action)
    if i + by notin 0 ..< all.len: return
    ev.removeNode(action)
    ev.insert(action, i + by))

proc checkClass*(root: XmlNode): string =
  ## What in a particle class would stop the build, or "": its Events' names.
  let ev = root.eventsOf
  for e in ev.elements:
    if EventDefs.allIt(it.name != e.tag): return "\"" & e.tag & "\" isn't an event"
    for a in e.elements:
      let d = actionDef(a.tag)
      if d == nil and a.tag notin ["XXSoundVolume", "XXXCreateDecal"]:
        return "\"" & a.tag & "\" isn't an action"
      if d != nil:
        for q in a.elements:
          if d.params.allIt(it.name != q.tag):
            return a.tag & " has no parameter \"" & q.tag & "\""
          if paramKind(a.tag, q.tag).isVarParam and q.innerText.strip.len == 0 and q.len == 0:
            return a.tag & " needs a variable in " & q.tag
