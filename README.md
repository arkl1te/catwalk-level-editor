# Catwalk

A level editor for Oni, laid out and controlled like TrenchBroom. It edits a level's
geometry (brushes, plus the shipped level meshes) and its objects (characters,
furniture, doors, consoles, triggers, ...). **Play** builds the level and starts Oni
in it.

Built like Majestic: Nim with Silky/Windy/OpenGL. `ui.nim`, `theme.nim`, `icons.nim`,
`dialogs*.nim` and `xwin*.nim` come from Majestic.

## Build and run

```fish
make
./catwalk [project folder]
```

It needs `mono` (to run OniSplit from the AE install). Play also needs the Custom
Game menu, which is part of Arklite (`../arklite`).

`make install` puts the binary in `~/.local/bin` and adds an app-menu entry with
the icon (`assets/catwalk.svg`); `make uninstall` removes them.

## Window

- **Toolbar:** tools, duplicate and flips, UV lock, snap and grid. On the right are
  the start point (beginning or a save point), **Build** and **Play**.
- **Tool options strip:** settings for the current tool (with no tool: the shape new
  brushes get, and Move objects by). **View options** is on its right.
- **Map views:** 1–4 panes (View menu). The 2D views share zoom and pan.
- **Console / Issues:** at the bottom (Ctrl+4).
- **Inspector:** on the right (Ctrl+5), with three tabs:
  - **Map:** layers as a tree (geometry and each object type, with counts). Open a
    layer to see its pieces or objects; click, Ctrl+click and Shift+click select,
    double-click focuses. Eye and lock icons hide and lock.
  - **Entity:** a key/value table and the entity browser: ready-to-use entities in
    collapsible groups, with a search field. Drag one into a view, or click to place it.
    Built in: a generic object of each type, the game's characters (players, enemies,
    TCTF, civilians, with their usual team and weapon), weapons, power-ups, turrets and
    particles (lights, fire, steam, sparks, weather, decals). Furniture, consoles, doors
    and triggers come from the entity library, which the browser's button builds from the
    game files (about 30 s, into `~/.local/share/catwalk/library/`). The game has no
    furniture classes: each piece is level geometry linked to its object, so the library
    keeps that geometry and its textures, and placing one adds them to the level.
    The slider next to the search field sets the preview size: all the way left is a
    compact list of names; further right shows each entity's model (characters in
    their idle pose, weapons, power-ups, turrets, doors, furniture, consoles and
    triggers), as TrenchBroom does. Particles show a still frame of what they emit
    (glows, fire, smoke, sparks, decals). The library build renders these previews,
    by itself the first time they're needed.
  - **Face:** texture adjustments, surface flags, script id, shade, and the texture
    browser (red border: current texture, yellow: used in the level).
- **Status bar:** while Ctrl, Shift or Alt is held, it lists what the mouse and keys
  do with those modifiers (scroll it with the wheel).

Every divider between panes, the inspector, the bottom panel and the browsers can be
dragged.

## New projects

The welcome screen (File ▸ New project, Ctrl+N) starts a project in two ways:

- **Empty level:** like a new map in TrenchBroom: one floor brush and a player start
  (Konoko, `IsPlayer`) at the origin, plus a `main()` script. Pick the game levels whose
  environment textures go into the texture browser (all of them by default) and a sky
  from level 0 (afternoon, sunset, night, crapsky, or none; the Map tab can change it
  later). Character classes, weapons and skies are linked by name from level 0.
- **Copy of an Oni level:** an editable copy of one of the game's levels.

Either kind of level can play one of the game's music tracks (from level 0) from the
moment it loads: pick it and its volume under Level in the Map tab. Build adds the
`sound_music_start` line to the built copy of `main()`; the project's scripts are left as
they are. The play button next to the track previews it (intro, then its loop pieces in
random order, as Oni plays them) through `pw-cat`, `paplay` or `aplay`. The first preview
extracts level 0's music into `~/.cache/catwalk/music` (about 36 MB, a few seconds).

## How a level goes through Catwalk

| Step | What happens |
|---|---|
| Import | `OniSplit -export` copies the level's instances. Objects become XML. The environment (AKEV) is dumped to XML and turned into `geometry.json`, keeping every face's UVs, baked lighting, flags, script id and object link. |
| Edit | Objects are edited as XML. Geometry is edited in Catwalk's own model. Furniture, doors, consoles, turrets and triggers own their geometry, which moves, duplicates and deletes with them. |
| Build (F7) | Objects are compiled with `OniSplit -create`. If the geometry changed, Catwalk writes it as `.dae` files grouped by flags and script id, plus a level XML; `OniSplit -create:level` rebuilds the environment (collision, octree, AI rooms); Catwalk then puts the object links back into the binary. Everything is packed into `AE/GameDataFolder/CustomLevels/<project>/`. |
| Build, empty level | `OniSplit -create:level` makes the whole level from `geometry.json`: environment, ONLV and the textures used. AI rooms are generated, one per walkable floor face. Objects are compiled as above. It is packed as `level50_Final.dat` (Custom Game mounts it under a free number). |
| Play (F5) | Build, then run `oni-ae-game.sh` with `ARKLITE_AUTOSTART=<project>` and `ARKLITE_SAVEPOINT=<n>`. |

Starting at a save point uses your saved game for that save point from the original
level, so you need to have reached it there. Without one, the level starts from the
beginning; `AE/Arklite.log` says which happened. Level 1 from the beginning is
Chapter 00 (Combat Training); Chapter 01 is save point 1.

## Controls (TrenchBroom defaults)

As in TrenchBroom, a left press is a click until the mouse moves, then a drag. With
no tool active:

| | |
|---|---|
| Click | Select a piece or object (empty space: select nothing) |
| Ctrl+click | Add to / remove from the selection |
| Double-click | Everything in that layer (Ctrl: add) |
| Shift+click, Ctrl+Shift+click | Select a face, add/remove a face |
| Shift+double-click, Shift+Alt+double-click | All faces of a piece, connected coplanar faces |
| Alt+click, Alt+drag, Alt+double-click | With one face selected: copy its texture and alignment to the clicked face, to every face the mouse passes over while the button is held, or to the whole piece (Alt+Ctrl: texture only) |
| Drag the selection | Move (Alt: vertically in 3D, Shift: lock to one axis, Ctrl: duplicate first) |
| Ctrl+drag | Paint select (Ctrl+Shift: faces) |
| Drag with nothing selected | Draw a brush in the chosen shape. 2D: its depth comes from the last selection. 3D: on the surface under the mouse, one grid step high; Alt changes the height, Shift makes it square, Shift+Alt a cube. |
| Shift+drag a selected brush's face | Extrude it, along with the other selected brushes' faces on the same plane (Ctrl: split off a new brush, Alt: move the face, Ctrl+Alt: stamp a new brush) |
| Right click | View menu: create objects there, select all of a type, reveal a texture, hide, isolate |
| Ctrl+wheel (3D) | Select the next thing behind / in front |
| Ctrl+Alt+wheel | Grid size |

Tools (press the key again or Esc to leave; W or Shift+Esc always leaves):

| | |
|---|---|
| B | Brush tool: click faces to place points, double-click a face for its corners, drag for a rectangle, Shift+drag to stretch the shape; Enter builds the brush |
| V, E, F | Vertex, edge, face tools: click/drag handles (Ctrl toggles), drag empty space to lasso, arrows move them, Delete removes corners. Brushes stay convex. |
| C | Clip: click or drag points (2D anywhere, 3D on faces), drag them to adjust, double-click a face to clip along it; Enter applies, Ctrl+Enter switches the side kept, Delete removes the last point |
| R | Rotate: drag the ring(s) around the center handle, drag the center to move it, or Apply an angle |
| T | Scale: drag the box's sides, edges or corners (Shift: proportional, Alt: from the center), or Apply a size |

Keys:

| | |
|---|---|
| Esc | Cancel the drag in progress, then the tool's points or handles, then the tool, then the selection |
| Ctrl+J / K / Shift+K / L | CSG merge / subtract / hollow (walls one grid step thick) / intersect |
| Arrows, PgUp/PgDn | Move the selection one grid step (Ctrl: duplicate and move). With only faces selected, they move and rotate textures (Shift coarse, Ctrl fine). |
| Alt+arrows, Alt+PgUp/PgDn | Yaw, roll, pitch by 90° (by the rotate tool's angle about its center while it is active) |
| Ctrl+D, Ctrl+X/C/V, Ctrl+Alt+V, Del | Duplicate in place, cut/copy, paste under the mouse, paste at the original position, delete |
| Ctrl+F, Ctrl+Alt+F | Flip horizontally / vertically (textures, with only faces selected) |
| Shift+R | Reset texture alignment |
| Ctrl+B, Ctrl+T, Ctrl+E | Select siblings; select what the selected brushes touch / contain (the brushes are removed) |
| Ctrl+Alt+M | Move objects by a typed offset |
| + −, 1–9, 0, Alt+0 | Grid size, show grid, snap |
| Ctrl+I, Ctrl+Alt+I, Ctrl+Shift+I | Isolate, hide, show all |
| Ctrl+U, Ctrl+Shift+U | Focus on selection, reset cameras |
| Space, Ctrl+Space | Switch the view under the mouse, maximize it |
| 3D view | RMB look, RMB+WASD/QE fly (wheel: speed), Alt+RMB orbit, MMB pan, wheel forward/back, Shift+wheel zoom (Ctrl+Alt+Z resets) |
| 2D views | RMB/MMB pan, wheel zoom |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo (objects and geometry) |

Number fields accept arithmetic (`64*3`).

## Limits

- CSG works on convex brushes only (brushes you draw, or pieces shaped like one).
  The shipped level meshes are edited with the vertex, edge, face and clip tools.
- AI rooms (BNV) are rebuilt from the level's original room data, so large geometry
  changes may need room edits that Catwalk can't do yet. Empty levels get one room per
  floor face. Nothing links the rooms yet, so AI may not path from one floor to another.
- Empty levels: furniture, doors, consoles, turrets and triggers have no geometry of
  their own yet, and there is no save point to start from.
- Objects are drawn as filled boxes; furniture and doors also show their geometry.
- Only the Y rotation of object boxes is drawn.
- Not from TrenchBroom (yet): the shear and sweep tools, groups and linked groups,
  the graphical UV editor, and shapes other than cuboid, cylinder, cone and stairs.
- Trigger volume boxes are drawn from Position to Position + Size; the game's exact
  reading of Size isn't confirmed.
