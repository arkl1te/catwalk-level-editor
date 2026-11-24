# Catwalk: technical notes

What the [README](README.md) leaves out: building, what Catwalk can't do yet, logs and the
MCP server. How to use the editor is in the [guide](Guide.draft.md).

## Building

Requirements: Nim 2.2+, git, mesa/libGL, libX11, libXrandr, `mono` (to run OniSplit from
the AE install), `wine` (Play starts Oni.exe with it, unless the game is set to a launch
script) and, to import sounds, `ffmpeg`. Building the logo again also needs Inkscape and
the Dirga font; the built one is in `assets/logo-paths.svg`. Pictures the PNG reader
can't decode (16-bit PNG, for one) are read through `ffmpeg` too, when it's there.

```sh
make                       # fetches the pinned Nim packages into vendor/, patches them, builds ./catwalk
./catwalk [project folder]
```

- `make debug` builds with debug checks, `make run` builds and starts it.
- `make install` puts the binary in `~/.local/bin` and adds an app-menu entry with the
  icon (`assets/catwalk.svg`). `make uninstall` removes them. `PREFIX` changes where.

Catwalk is built like Majestic Media Player: Nim with Silky, Windy and OpenGL.
`ui.nim`, `theme.nim`, `icons.nim`, `dialogs*.nim`, `xwin*.nim` and `win32api.nim` come from Majestic.

### Windows

From Git Bash, with Nim 2.2+, git and Visual Studio (or its Build Tools) with the C++
workload; Nim finds the compiler by itself:

| Command | What it does |
|---|---|
| `tools/windows.sh build` | Build `catwalk.exe` in the source tree (MSVC) |
| `tools/windows.sh run [project]` | Build and run it |
| `tools/windows.sh debug` | Unoptimized build with a console |
| `tools/windows.sh install` / `uninstall` | Install to `%LOCALAPPDATA%\Programs\Catwalk` with a Start menu shortcut |
| `tools/windows.sh stage DIR` | Copy what ships (exe, README, `licenses\`) into DIR |

`.github/workflows/windows.yml` runs `build` and `stage` on every push with a pinned Nim
(2.2.14) and keeps the result as the run's artifact; a `v*` tag also makes a GitHub release
with the zip, its notes taken from the annotated tag's message. Before releasing, it starts
the staged `catwalk.exe --version` with `PATH` cut to Windows' own folders: it prints
`Catwalk <version>` and quits, so a library missing from the zip fails the run instead of
the player's start (a failed load opens a message box that waits for a click, hence its
timeouts). The exe's icon is `assets/windows/catwalk.ico`,
made from `assets/catwalk.svg` by `nim r tools/make_ico.nim`.

What differs from Linux:

- OniSplit.exe runs by itself (.NET Framework, which AE needs anyway), not with Mono;
  Play starts Oni.exe directly, and a `.bat` launch script through `cmd`.
- Job steps run through `cmd /d /s /c` with their output appended to the build log
  (`jobs.nim`), every argument quoted so `&`, `^` and the like in paths stay literal,
  and split into several commands when the list of files would pass cmd's 8,191
  characters. Commands that run side by side (the entity library's graph step) log to
  files of their own, appended to the log when they end; those that give way to an
  urgent one start below normal priority (`SetPriorityClass` on cmd, which OniSplit
  inherits; `nice` on Linux).
- Sound previews play through winmm's waveOut (`waveout.nim`) instead of pw-cat.
- Menus, the Setup window and file dialogs use Majestic's Win32 backends
  (`xwin_win32.nim`, `dialogs_win32.nim`): popups drawn with the main GL context,
  Windows' own file dialogs on a thread, the dark title bar.
- Settings are in `%APPDATA%\catwalk`; logs, caches and the entity library in
  `%LOCALAPPDATA%\catwalk`.

Fixes taken over from Majestic's Windows port, which apply here too: atomic flags are
`Atomic[int]`, never `Atomic[bool]` (MSVC's `exchange` writes 8 bytes and zeroed the
globals after the flag); the fonts are embedded as byte arrays (MSVC refuses a string
literal past 64 KB); `patches/windy.patch` lets Alt+F4 through to Windows; programs are
started with `poDaemon`, so no console window flashes up; `.gitattributes` keeps the
scripts, `deps.lock` and the patches LF, which bash and `git apply` need.

Nothing may load a library at run time that Windows doesn't have, since the zip ships the
exe alone. `std/re` is out for that reason: it loads PCRE (`pcre64.dll` on Windows), which
stopped 0.2.0 from starting there. Text patterns are matched by hand in `textmatch.nim`;
`tools/textmatch_test.nim` checks each against the regex it replaced (it needs PCRE, so it
runs on Linux), optionally on a list of real files:
`nim c -r -d:release tools/textmatch_test.nim paths.txt`.

The Windows build is checked from Linux with `nim check --os:windows` (pass `--skipProjCfg`
and every `vendor/*` path by hand: `config.nims` breaks under `--os:windows`) and by
reading the C that `--compileOnly` generates (its `nimLoadLibrary` calls must name only
Windows' DLLs); the workflow's start check is the one run on Windows.

## Limits

- CSG works on convex brushes only (brushes you draw, or pieces shaped like one).
  The shipped level meshes are edited with the vertex, edge, face and clip tools. A piece
  whose faces were cut, joined or separated stops being a brush.
- AI rooms (BNV) are rebuilt from the level's original room data, so large geometry
  changes may need room edits that Catwalk can't do yet. Empty levels get one room per
  floor face. Nothing links the rooms yet, so AI may not path from one floor to another.
- Empty levels have no save point to start from.
- Spinning groups have no collision in the game, and only work in levels made in Catwalk.
- Objects without a model are drawn as boxes, and only their Y rotation is drawn.
- Not from TrenchBroom (yet): the shear and sweep tools, and shapes other than cuboid,
  cylinder, cone and stairs.
- Trigger volume boxes are drawn from Position to Position + Size, turned with the
  object; the game's exact reading of Size isn't confirmed.
- Build writes every coordinate within 0.001 of the 1/8 grid on it (geometry.nim
  `snapDrift`; the project keeps its own values). Edits leave float rounding
  (-191.99996 for -192), and OniSplit leaves a quad that close to an octree leaf's face
  out of the leaves it runs through; Oni draws only quads a visibility ray found in a
  leaf, so walls vanished from some views (Condemned, 2026-11-19). A quad about 0.006
  from a leaf face (some furniture strips) or a sloped one can still be left out:
  check a built level with `tools/octree_scan.py <project>/build/geometry/xml/AKEV<name>.xml`.

## Models as furniture

File > Import > Models as furniture (src/modelimport.nim; MCP `import_model`) makes each
file a FURN object owning the model's faces, as the game's own furniture is made (there
are no furniture classes; the class is the file's name).

- Formats: OBJ + MTL (`map_Kd`, `Kd`; a Blender MTL's colors are linear and converted to
  sRGB), glTF 2.0 (.gltf with its .bin or data URIs, .glb; node transforms, sparse
  accessors, triangle strips and fans, `baseColorTexture`/`Factor`,
  `KHR_texture_transform`, `KHR_materials_pbrSpecularGlossiness`, `COLOR_0`), Collada
  through collada.nim (`<up_axis>`, `<unit>`, diffuse colors).
- Units and axes: meters x 10 (OniSplit's own .dae files say `meter="0.1"`); Y up (Collada
  Z_UP and X_UP are turned); front faces counter-clockwise, as in all three formats. The
  object's origin is the model's bottom center.
- Faces: a polygon stays whole when it is flat (within 0.02), convex and has 3 or 4
  corners; flat convex ones with more become a fan of quads, as Build cuts any face;
  the rest are ear-clipped into triangles (a bent quad along its shorter good
  diagonal). Corners on the same spot share a point; a corner within 0.001 of the one
  before it is dropped, and faces with no area are left out. Flags:
  Furniture + NoOcclusion, as the game's furniture faces have.
- Textures: `CW_<picture name>`, fitted to 256x256 powers of 2 (stock Oni's upload limit,
  so no Arklite is needed); an identical picture already in the project is reused. A
  material without one gets `CW_MODEL_WHITE` and its color as the face tint. DDS and TIF go
  through OniSplit.
- Corner colors: 0.25-0.95 of white from a light above and in front (from the file's
  normals, else the face's), times its vertex colors, until Bake light relights them.
- Build matches the quads OniSplit writes back to Catwalk's faces by their corners;
  OniSplit returns points up to ~1e-4 off, so they are snapped to the project's points
  first (geometry.snapToModel). Without that, 147 of a Suzanne's 2472 faces lost their
  furniture link.
- Entity Browser (src/importedmodels.nim): each import is also saved to
  `<data>/catwalk/imported/<name>/` (next to the library, not in it): `entry.json` (name,
  class, normalized source path, size, save time), `geometry.json` (object space),
  the `.tga` textures and `preview.png` (thumbs.nim, rendered at once). They are presets
  with `imported` set (group "Imported models"); the preview's atlas key carries the save
  time, so a re-import shows its new preview. A folder is the class name; the same source
  file replaces it, another one takes `name_2`, ... (31 characters at most). Placing copies
  each texture into the project as a custom texture, or renames it `_2`, ... when the
  project has a different picture by that name, and points the faces at the new name.

## Logs and crash reports

Catwalk keeps a log of each run, and a report of each crash, in
`~/.local/state/catwalk/logs`, on Windows `%LOCALAPPDATA%\catwalk\logs` (Help > Open logs folder). To report a bug, send the crash
report with what you were doing. Project and object names appear in it, so read it first
if they're private. The [guide](Guide.draft.md#logs-and-crash-reports) says what each file holds.

## MCP server

Catwalk can serve the [Model Context Protocol](https://modelcontextprotocol.io), so
Claude Code can drive the open editor: read the level's objects and faces, create brushes
and objects, move the selection and the cameras, run any menu item, save, build and take
screenshots. Turn it on in **View > Settings > General > MCP Server**, then tell Claude
Code about it once:

```
claude mcp add catwalk -- catwalk --mcp
```

The server listens on `http://127.0.0.1:<port>/mcp` only and refuses requests from web
pages (Host and Origin are checked), but every program on this computer can reach it
while it's on. The [guide](Guide.draft.md#mcp-server) has the rest: the port, the Run menu
entries and `start_catwalk`.
