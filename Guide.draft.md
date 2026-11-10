# Catwalk guide (draft)

How to use each part of Catwalk. The [README](README.md) has the overview, building and
installing.

## First run

The first time Catwalk starts (or whenever no AE folder is set), a **Set up Catwalk** window
asks where Oni is:

- **AE folder:** Oni's Anniversary Edition folder, the one with `Tools/OniSplit.exe` and
  `GameDataFolder`. Build writes your maps into it. The line under it warns when Arklite
  isn't installed there.
- **Game:** what Play starts: Oni.exe (Catwalk runs it with Wine, in the Wine prefix it sits
  in), or a script that starts the game.

**Auto-detect** looks where Oni usually is: Wine prefixes (`~/.wine`, Lutris and Heroic
under `~/Games`, Bottles, PlayOnLinux, Steam's Proton prefixes) and Program Files. It
prefers an install with Arklite and fills in that install's Oni.exe. The folder buttons pick
by hand. Cancel leaves both empty, and the window comes back on the next start. Both can be
changed later in View > Settings > General.

## Window

- **Toolbar:** tools, duplicate and flips, UV lock, snap and grid. On the right are
  the start point (beginning or a save point), **Build** and **Play**.
- **Tool options strip:** settings for the current tool (with no tool: the shape new
  brushes get, and Move objects by). **View options** is on its right.
- **Map views:** 1–4 panes (View menu), in the **Viewport** panel with the tool
  options strip. The 2D views share zoom and pan.
- **View header:** each view has buttons for Realtime preview, **Gizmos** (object boxes,
  light shapes, direction arrows and volumes; right-click it to hide single object types;
  selected objects always show theirs) and **Invisible faces** (the eye: faces flagged
  Invisible, such as invisible walls and stair ramps; hidden ones can't be clicked). View
  options also has **Entity directions**: arrows for the way characters, flags, turrets,
  particles and lights face.
- **Panels:** Viewport, Properties, Map, Files, Classes, Entity Browser, Texture Browser,
  Texture Collections, Console, Issues and Scripts. Drag a panel's tab onto another panel's
  tabs (or its middle) to tab it there, or onto a side of a panel or of the whole window to
  split that side off. View > Panels turns each panel on or off and resets the layout,
  which Catwalk remembers. Every panel scrolls with a slim scrollbar over its right edge.
- **Status bar:** while Ctrl, Shift or Alt is held, it lists what the mouse and keys
  do with those modifiers (scroll it with the wheel).
- **Settings:** View > Settings.

Every divider between panes and panels can be dragged. The window title shows `*` while
there are unsaved changes.

### Console and Issues

Below the views by default (Ctrl+4). In the Console, drag selects text, double-click a
word, triple-click or Ctrl+A the whole log; Ctrl+C copies it, without the times.

Issues lists the level's problems with their time and severity (error, warning, info),
errors first. After a Build, the Console says how many there were and Issues opens; click
a face in a message to select it.

### Properties

Ctrl+2 (Ctrl+5 turns it on or off). What's selected, as rows of name and value under a
header that names it:

- **Level** (nothing selected): its name in the Custom Game list, sky, music and
  lighting.
- An object's type (**Character**, **Point light**, ...): its fields, with a search;
  several of one type show the fields they share, and several types show counts. A
  Particle object has **Edit class**, which opens its class in Classes.
- **Group** (click a group's row on the Map tab): name, Spin, what it holds, its linked
  copies and size, and Ungroup. A strip above Properties shows which group the selection
  is in.
- **Face** (faces or pieces): texture shift, scale and rotation, flips and World
  align, script id, shade, tint and surface flags.
- **Vertex** (handles in the vertex, edge or face tool): the corners' vertex color,
  unlit factor, Override lights and light animation.

Number fields accept arithmetic (`64*3`).

### Map

Ctrl+1. Layers as a tree (geometry and each object type, with counts). Open a layer to
see its groups, pieces and objects; click, Ctrl+click and Shift+click select,
double-click focuses. Eye and lock icons hide and lock. Groups are folders inside their
layer: clicking one selects the group, and a member's row opens the groups around it so
the member alone is selected. A selection made in the views opens the folders it is in.
A Particle object unfolds to the classes its effect spawns, nested; these aren't objects
in the level, and clicking one opens it in Classes.

### Classes

Ctrl+3. **Characters** edits character classes: the values every character of a type
(Konoko, each striker, ...) starts with, such as Health, AI and sounds. **Particles**
does the same for particle classes: lifetime, look, variables, emitters, events and
action values.

- Pick a class from the searchable list, or select a character or Particle object (its
  class opens). The class's fields have their own search, and clicking a heading folds it
  (Shift+click folds or opens everything under it too).
- A particle class's **Events** list what it does and when: + adds an event or action,
  the arrows set the order they run in, and × removes them.
- An emitter's Lifetime is how long it keeps emitting; **Spawned particles**, above the
  fields, lists what it creates with each class's Lifetime and fade time, so what it
  spawns can vanish sooner.
- The row of arrows above the class name shows what spawns it, back to the outermost
  parent; click one to open it, or use the small menu on an arrow when a class has
  several parents.
- The **XML** button shows any class as text to edit by hand; Apply checks it and makes
  it the class.
- Edited classes are saved in the project's `classes/` folder and only affect this level.
  "Use game values" puts a class back. A character's AdditionalHealth adds to its class's
  Health.
- Build packs an edited particle class and the classes that emit it under new names for
  this level's Particle objects. A weapon or character that uses the class keeps the
  game's version.

With a Particle object selected, the panel at the 3D view's bottom right plays it from
the start (even one that waits for a script, with or without Realtime preview), stops its
emission, and loops it. With Realtime preview's particles on, the views show each class
edit as you make it.

### Entity Browser

Ready-to-use entities in collapsible groups, with a search field. Drag one into a view,
or click to place it. Built in: a generic object of each type, the game's characters
(players, enemies, TCTF, civilians, with their usual team and weapon), weapons,
power-ups, turrets and particles (lights, fire, steam, sparks, weather, decals).
Furniture, consoles, doors and triggers come from the entity library, which the
browser's button builds from the game files (about 30 s, into
`~/.local/share/catwalk/library/`). The game has no furniture classes: each piece is
level geometry linked to its object, so the library keeps that geometry and its
textures, and placing one adds them to the level.

The slider next to the search field sets the preview size: all the way left is a compact
list of names; further right shows each entity's model (characters in their idle pose,
weapons, power-ups, turrets, doors, furniture, consoles and triggers), as TrenchBroom
does. Particles show a still frame of what they emit (glows, fire, smoke, sparks,
decals). The library build renders these previews, by itself the first time they're
needed.

### Texture Browser and Texture Collections

Red border: current texture, yellow: used in the level. Click one to apply it to the
selected faces; right-click it to select the faces or pieces that use it, or copy its
name. **Group** heads the textures by collection, **Used** keeps the ones the level
uses, and the alpha button keeps the see-through ones. **Import** adds your own pictures
(PNG, JPG, BMP, GIF, QOI, PPM, TGA, DDS, TIFF) as `CW_<NAME>` textures: each side becomes
a power of 2, at most 1024 (Arklite lifts the game's 256×256 limit; alpha is kept).

**Texture Collections** sets what the browser lists, as in TrenchBroom. Add moves a
collection from Available to Enabled (double-click does too) and Up / Down set its
order: this level's textures, your imported ones, and any other game level's, which are
extracted once and copied into the project when first used. **Clean up unused** (in the
browser) drops level collections no face uses.

Game textures are only extracted so the editor can show them. Build leaves them out: a
map names them, and Arklite loads them from the player's own game, so a map can be shared
without carrying Oni's textures. Only imported `CW_` textures go inside it.

### Scripts

Ctrl+6; opens beside the views. A code editor for the level's scripts, the `.bsl` files
in `IGMD/<level>/` that Oni reads when the level loads (double-click one in Files, or
pick it from Open...).

- It colors the language and the game's own commands and variables, which it reads from
  your Oni.exe with their descriptions and argument lists. Hover a word to see what it
  does.
- Typing lists what fits there (Ctrl+Space asks), including the level's characters,
  trigger volumes, patrol paths, flags, doors and the like for the arguments that name
  them, and the values the game's own scripts use. The line above the cursor shows the
  argument the command expects next.
- Names of the level's objects are drawn in their type's color: Ctrl+click one to select
  it, show its Properties and its Map row, and frame it in the views. Ctrl+click or F12 on
  a function goes to where it's declared, in any of the level's files.
- Problems the game would report (unknown commands, arguments it can't convert, missing
  braces) get a wavy underline. Click the count in the status line to go to the next one.
- Ctrl+F finds, Ctrl+/ comments lines, Tab / Shift+Tab indent, Ctrl+wheel changes the
  text size (Ctrl+0 resets it). Ctrl+S (or Save) writes the scripts along with the
  project.

Fields that name a script function (a character's Scripts, a trigger volume's
Entry/Inside/Exit, an event's Function) have a `<>` button that opens the function.

## Projects

The welcome screen (File ▸ New project, Ctrl+N) starts a project in two ways:

- **Empty level:** like a new map in TrenchBroom: one floor brush and a player start
  (Konoko, `IsPlayer`) at the origin, plus a `main()` script. Pick the game levels whose
  environment textures go into the texture browser (all of them by default) and a sky.
  Character classes, weapons and skies are linked by name from level 0.
- **Copy of an Oni level:** an editable copy of one of the game's levels.

File > Open Recent lists the last projects (View > Settings > General sets how many).

## Skies

Pick the sky under Level in Properties: one of level 0's (afternoon, sunset, night,
crapsky) or none, in any project. **Import custom sky...** takes a folder with five or six
pictures: a popup lists them with the side each goes on, worked out from how their edges
join, then their names, then their order. A bottom face needs Arklite.

**Run > Add-Ons > Skybox Converter...** makes those faces from one picture: a cylindrical
or equirectangular panorama, a cube cross or a cube strip, with a bottom face that the
game draws with Arklite.

Level also sets the sky's brightness, blend mode and tint, live in the 3D view: the
images stay as they are, and Build applies these to copies.

## Music and sounds

Either kind of level can play one of the game's music tracks (from level 0) from the
moment it loads: pick it and its volume under Level in Properties (nothing selected).
Build adds the `sound_music_start` line to the built copy of `main()`; the project's
scripts are left as they are. The play button next to the track previews it (intro, then
its loop pieces in random order, as Oni plays them) through `pw-cat`, `paplay` or
`aplay`. The first preview extracts level 0's music into `~/.cache/catwalk/music` (about
36 MB, a few seconds).

Sound fields (Sound objects, character and particle sounds, scripts) also take any single
recording as `rec_<name>`, and a **Recording pitch** row under the field changes its pitch
for this map. **File > Import > Sounds...** (or Import sound... in a sound field's list)
adds your own: WAV, MP3, OGG, FLAC, AIFF, M4A and more (through `ffmpeg`), converted to
22050 Hz MS ADPCM like Oni's own and listed as `rec_cw_<name>`. They are kept in the
project (`oni/` and `sounds/`) and Build packs the ones the level plays into it.

### Your own ambient sounds

When a stock ambient plays sounds that don't fit, make your own copy: open any sound
list that takes ambients (a light's or Sound object's sound, for example), right-click a
sound and pick **Duplicate as new ambient...**. The editor opens on a copy with a free
name. Pick which recordings each part plays:

- **In sound** and **Out sound** play once when it starts and stops.
- **Base track 1** and **Base track 2** loop.
- **Detail track** plays one random sound every **Gap** seconds, up to **Spread** units
  around the sound.

For each recording you can set how often it's picked (**Weight**) and a volume and pitch
range. Remove recordings with ×, and add game recordings or your imported ones with the
search field. **Listen** plays the copy as it stands. **Save** adds it to the level and
puts it in the field you opened the list from.

Your ambients are marked "this level's ambient" in sound lists. Right-click one and pick
**Edit ambient...**, or use **File > Ambient sounds**, to change or delete it. **File >
Import > New ambient sound...** starts one from scratch. They're kept in the project's `ambients.json`, and Build defines
them in the level, so they need Arklite in the game.

## Baked lighting

Oni lights its levels with colors baked into every face corner (texture × vertex color).
Catwalk can bake them from lights you place from the view's context menu (Create object ▸
Lights) or the entity browser:

- **Point light:** `Color` (0–255 each), `Intensity`, `Radius` (its light fades to nothing
  there; the selected light shows it as a sphere) and `Shadows` (1 or 0).
- **Spot light:** a point light that shines in a cone, `Angle` wide, with `Softness` at
  its edge.
- **Directional light:** a sun: the same light everywhere, coming from one direction, with
  `Color`, `Intensity` and `Shadows`. Turn it with its Rotation (X tilts it down, Y turns
  its heading); its arrow points the way the light travels.

Color fields (a light's, a flag's, a trigger's laser, Ambient, Tint) have a number field
for each of red, green and blue (type, or scroll over one), a swatch that opens a color
picker (saturation/value square, hue bar, RGB, HSV and hex) and an eyedropper that takes
the color of anything in Catwalk's window: click it, then click any pixel (Esc or a right
click cancels). Each channel field takes a number or arithmetic (`200+16`); with several
objects selected, one whose values differ is blank and setting it changes only that
channel. Picker changes show live; closing the picker leaves one undo step, and Esc puts
the color back.

Each light has an **Enabled** checkbox at the top of its Properties: an off light is drawn
dimmed and left out of the bake. A light's animation (Flicker, Pulse, ...) has a **Seed**:
lights with different seeds flicker and fail apart even with the same timing. Under Level
in Properties (nothing selected):

- **Ambient:** the color every face gets before the lights' light.
- **Soft shadows:** how many units around a corner it takes its light from. Shadows get
  soft edges, which corners can show, where hard ones come out in steps. 0 = hard; baking
  gets slower.
- **Bake automatically:** on, every change to a light (moving, rotating, enabling), the
  ambient color or the geometry rebakes at once (big levels rebake a few times a second
  while you drag). Off, the lighting changes only when you press **Bake light**, which is
  one undo step.

A bake replaces the vertex colors of every visible face, including an original level's
own lighting. Lights are Catwalk's own: they're kept in the project's `lights.xml` and are
never built into the level; only the colors they bake are.

A face's **Tint** (Face in Properties) colors the surface itself: the light its corners
get, from the lights, the ambient or by hand, is multiplied by it (255 255 255 = no tint),
so a tinted wall stays lit and shadowed like before, only in its color. Bakes don't change
it, and it also colors the face's light animations and unlit corners, in the views and in
the game.

Corners are all Oni lights, so a big face can't show a pool of light in its middle. Cut it
where the light needs more corners (Ctrl+Shift+drag, see Controls).

### Light sounds

A light with an animation can play a sound: pick it in **Animation/Sound** on the light
(an impulse, or `rec_<name>` for one recording), with **SoundPitch** (0.5 is an octave
down), **SoundPitchMax** (each play picks a pitch from SoundPitch to this, the same on
every PC; empty for none) and **SoundVolume**. It plays when a Flicker's failure starts, or
at each Pulse, on the same tick as the flash. A Flicker with Stability 0 never fails, so
it stays silent: use a high Stability for something sporadic. Point and spot lights play
it from where they are; directional lights are heard everywhere. Needs Arklite.

Point and spot lights can play an ambient instead: set **SoundKind** to Ambient and pick a
looping sound in **Animation/Sound**. On a Flicker it plays while the light is failing: it
starts with each failure and stops when the light works again (Stability is the share of
the time it works, so 0.25 means it fails, and sounds, three quarters of the time;
Stability 0 fails all the time). Any other light loops it for as long as it's enabled.
It's loudest within **SoundMinRadius** and silent beyond **SoundMaxRadius** (world units,
like Radius), at **SoundVolume**, and at **SoundPitch**: with **SoundPitchMax** set, each
start (each failure, on a Flicker) picks a pitch from SoundPitch to SoundPitchMax, the
same on every PC, and the whole ambient (in sound, loops, details, out sound) keeps it
until it stops. Build places it in the level as an ordinary Sound object; Arklite makes a
flickering light's follow the failures and applies the pitch (without Arklite it loops
all the time at its own pitch, and a `rec_<name>` recording needs Arklite anyway). The
realtime preview plays it the same way.

## Groups

Groups and linked groups work as in TrenchBroom: an edit inside one linked copy is made
in all of them, and the views outline the other copies an edit will change. Cutting a
face in a linked copy keeps the cut in that copy: its group leaves the link set (undo
links it again).

### Spinning groups

To make geometry turn in the game, select its group on the **Map** tab and type the
seconds per turn into **Spin** on the group's Properties page (negative turns the other
way, empty stops it). It turns around the vertical axis through the group's center, and a
group inside a spinning group turns with it.

Oni only moves physics objects, so Build takes those faces out of the environment and
writes them as one looping object, and adds `obj_create` to the level's `main()`. In the
game the group has no collision, so characters fall through it (Oni only finds floors in
the environment), keeps no baked lighting and gives AI no floor. Catwalk's views show it
still. Levels made in Catwalk only.

Particle objects in the group turn with it, around the center of its faces and particles
together, and a group can hold particles alone. Only the object's own particle moves:
what it already emitted stays behind, and new emissions leave from the new place and
direction. A particle class that moves its own placed particle stops moving, and decals
stay where they are. Build writes `spinparticles.bin` and Arklite does the turning, so
this needs Arklite. Realtime preview shows the particles turning, while the geometry
stays still.

## Controls (TrenchBroom defaults)

As in TrenchBroom, a left press is a click until the mouse moves, then a drag. With
no tool active:

| | |
|---|---|
| Click | Select a piece or object (empty space: select nothing) |
| Ctrl+click | Add to / remove from the selection |
| Double-click | Everything in that layer (Ctrl: add) |
| Shift+click, Ctrl+Shift+click | Select a face, add/remove a face |
| Shift+double-click, Shift+Alt+double-click | All faces of a piece, connected coplanar faces (Shift+Alt with one face selected: see below) |
| Alt+click, Alt+drag, Alt+double-click | With one face selected: copy its texture, flags, tint and alignment to the clicked face, to every face the mouse passes over while the button is held, or to the whole piece (Alt+Ctrl: texture only; Alt+Shift: the alignment wraps around corners) |
| Drag the selection | Move (Alt: vertically in 3D, Shift: lock to one axis, Ctrl: duplicate first) |
| Ctrl+drag | Paint select (Ctrl+Shift, with no face selected: faces) |
| Shift+drag with faces selected | Paint more faces into the selection |
| Ctrl+Shift+drag with faces selected | Cut them in two with a line parallel to the edge nearest the mouse, through every selected face the line crosses; dragged out past the edge instead, it adds a new face on the same plane, its texture running on, and so does every other selected face's open edge at the same distance. The piece stops being a brush: its faces stay separate, but CSG and removing corners no longer work on it |
| Drag with nothing selected | Draw a brush in the chosen shape. 2D: its depth comes from the last selection. 3D: on the surface under the mouse, one grid step high; Alt changes the height, Shift makes it square, Shift+Alt a cube. |
| Shift+drag a selected brush's face | Extrude it, along with the other selected brushes' faces on the same plane (Ctrl: split off a new brush, Alt: move the face, Ctrl+Alt: stamp a new brush) |
| Drag a volume's face handle | Resize a sound or trigger volume (a trigger volume turns with its object) |
| Right click | View menu: create objects there, select all of a type, select faces with the same properties, reveal a texture, Separate, hide, isolate |
| Ctrl+wheel (3D) | Select the next thing behind / in front |
| Ctrl+Alt+wheel | Grid size |

**Separate** (right-click menu, Edit): selected pieces fall apart into one piece per face;
selected faces leave their piece together as one new piece. Those pieces stop being
brushes.

Tools (press the key again or Esc to leave; Shift+Esc always leaves):

| | |
|---|---|
| B | Brush tool: click faces to place points, double-click a face for its corners, drag for a rectangle, Shift+drag to stretch the shape; Enter builds the brush |
| V, E, F | Vertex, edge, face tools: click/drag handles (Ctrl toggles), drag empty space to lasso, arrows move them, Delete removes corners. Brushes stay convex. |
| C | Clip: click or drag points (2D anywhere, 3D on faces), drag them to adjust, double-click a face to clip along it; Enter applies, Ctrl+Enter switches the side kept, Delete removes the last point. With faces selected it cuts those faces instead of whole pieces; parts dropped are deleted, and their pieces stop being brushes |
| R | Rotate: drag the ring(s) around the center handle, drag the center to move it, or Apply an angle |
| T | Scale: drag the box's sides, edges or corners (Shift: proportional, Alt: from the center), or Apply a size |

Keys:

| | |
|---|---|
| Esc | Cancel the drag in progress, then the tool's points or handles, then the tool, then the selection |
| Ctrl+J / K / Shift+K / L | CSG merge / subtract / hollow (walls one grid step thick) / intersect |
| Ctrl+J on faces of one plane | Join the touching ones into one face, as far as the shape stays convex (Oni's limit). Pieces from which a face moved stop being brushes: no CSG or corner removal on them |
| Arrows, PgUp/PgDn | Move the selection one grid step (Ctrl: duplicate and move). With only faces selected, they move and rotate textures (Shift coarse, Ctrl fine). |
| Alt+arrows, Alt+PgUp/PgDn | Yaw, roll, pitch by 90° (by the rotate tool's angle about its center while it is active) |
| Ctrl+D, Ctrl+X/C/V, Ctrl+Alt+V, Del | Duplicate in place, cut/copy, paste under the mouse, paste at the original position, delete |
| Ctrl+C, Ctrl+Shift+V (faces selected) | Copy a face's surface properties, paste them (texture, alignment, flags, script id, tint; not shade) onto the selected faces |
| Ctrl+F, Ctrl+Alt+F | Flip horizontally / vertically (textures, with only faces selected) |
| Shift+R | Reset texture alignment |
| Ctrl+B, Ctrl+T, Ctrl+E | Select siblings; select what the selected brushes touch / contain (the brushes are removed) |
| Ctrl+Alt+M | Move objects by a typed offset |
| + −, 1–9, 0, Alt+0 | Grid size, show grid, snap |
| Ctrl+I, Ctrl+Alt+I, Ctrl+Shift+I | Isolate, hide, show all |
| Alt+I | Save a screenshot of each shown viewport (File > Save screenshot...), one PNG per view |
| ., Shift+. | Focus on selection (the camera glides to a clear view), reset cameras |
| Space, Ctrl+Space | Switch the view under the mouse, maximize it |
| Z (hold) | Render mode pie: point toward a mode, let go of Z or click. Tap Z to keep it open; 1–9 pick by numpad direction, Esc cancels |
| 3D view | WASD walk (no modifiers, nothing typed into), RMB look, LMB+RMB carry the selection while looking/flying (grid-snapped; Esc puts it back), RMB+WASD/QE fly (wheel: speed), Alt+RMB orbit, MMB pan, wheel forward/back, Shift+wheel zoom (Ctrl+Alt+Z resets) |
| 2D views | RMB/MMB pan, wheel zoom |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo (objects and geometry) |

## How a level goes through Catwalk

| Step | What happens |
|---|---|
| Import | `OniSplit -export` copies the level's instances. Objects become XML. The environment (AKEV) is dumped to XML and turned into `geometry.json`, keeping every face's UVs, baked lighting, flags, script id and object link. |
| Edit | Objects are edited as XML. Geometry is edited in Catwalk's own model. Furniture, doors, consoles, turrets and triggers own their geometry, which moves, duplicates and deletes with them. |
| Build (F7) | Objects are compiled with `OniSplit -create`. If the geometry changed, Catwalk writes it as `.dae` files grouped by flags and script id, plus a level XML; `OniSplit -create:level` rebuilds the environment (collision, octree, AI rooms); Catwalk then puts the object links back into the binary. The game's own textures are left out (Arklite loads them from the player's game). Everything is packed into `AE/GameDataFolder/CustomLevels/<project>/`. |
| Build, empty level | `OniSplit -create:level` makes the whole level from `geometry.json`: environment, ONLV and the textures used. AI rooms are generated, one per walkable floor face. Objects are compiled as above. It is packed as `level50_Final.dat` (Custom Game mounts it under a free number). |
| Play (F5) | Build, then start the game (Oni.exe through Wine, with `-noswitch -debugfiles`, or your script) with `ARKLITE_AUTOSTART=<project>` and `ARKLITE_SAVEPOINT=<n>`. Its output goes to the project's `build/game.log`. |

Starting at a save point uses your saved game for that save point from the original
level, so you need to have reached it there. Without one, the level starts from the
beginning; `AE/Arklite.log` says which happened. Level 1 from the beginning is
Chapter 00 (Combat Training); Chapter 01 is save point 1.

## Logs and crash reports

Catwalk keeps its logs in `~/.local/state/catwalk/logs` (Help > Open logs folder):

- `session-<date>-<process>.log`: one for each run, with what the Console showed and
  every edit. A session that ended normally finishes with `Clean exit`.
- `crash-<date>-<process>.txt`: written when Catwalk crashes, with where it crashed, what
  the editor was doing, your system and graphics card, and the last 200 log lines.

After a crash, the next launch shows it in the Issues panel; click it to find the report.
Your home folder appears as `~`, but project names and object names stay in the file, so
read it first if they're private. The newest 20 of each kind are kept.

## MCP server

Turn it on in **View > Settings > General > MCP Server**. It's off by default and starts
with Catwalk (saving the setting also starts or stops it at once). **Run > MCP server**
shows whether it's active, and Start and End turn it on or off for this run without
changing the setting. If the port is taken or blocked, the Console says so and an Error
appears under Issues; clicking it opens Settings on the port field. The toggle is
`"mcpEnabled"` in `~/.config/catwalk/config.json`, next to `"mcpPort"` (default 47350).

`catwalk --mcp` has no window: it's a bridge between Claude Code and the running editor.
Its `start_catwalk` tool opens Catwalk with the server on (`catwalk --mcp-server
[project]`) for that run, whatever the setting says. Every edit it makes is one undo step,
and what it does is logged in the Console.
