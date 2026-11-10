# Catwalk: technical notes

What the [README](README.md) leaves out: building, what Catwalk can't do yet, logs and the
MCP server. How to use the editor is in the [guide](Guide.draft.md).

## Building

Requirements: Nim 2.2+, git, mesa/libGL, libX11, libXrandr, `mono` (to run OniSplit from
the AE install), `wine` (Play starts Oni.exe with it, unless the game is set to a launch
script) and, to import sounds, `ffmpeg`. Building the logo again also needs Inkscape and
the Dirga font; the built one is in `assets/logo-paths.svg`.

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

`.github/workflows/windows.yml` runs `build` and `stage` on every push and keeps the
result as the run's artifact; a `v*` tag also makes a GitHub release with the zip, its
notes taken from the annotated tag's message. The exe's icon is `assets/windows/catwalk.ico`,
made from `assets/catwalk.svg` by `nim r tools/make_ico.nim`.

What differs from Linux:

- OniSplit.exe runs by itself (.NET Framework, which AE needs anyway), not with Mono;
  Play starts Oni.exe directly, and a `.bat` launch script through `cmd`.
- Job steps run through `cmd /d /s /c` with their output appended to the build log
  (`jobs.nim`), every argument quoted so `&`, `^` and the like in paths stay literal.
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

The Windows build is checked from Linux with `nim check --os:windows` (pass `--skipProjCfg`
and every `vendor/*` path by hand: `config.nims` breaks under `--os:windows`) and by
reading the C that `--compileOnly` generates; it hasn't been run on a Windows PC yet.

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
- Not from TrenchBroom (yet): the shear and sweep tools, the graphical UV editor, and
  shapes other than cuboid, cylinder, cone and stairs.
- Trigger volume boxes are drawn from Position to Position + Size, turned with the
  object; the game's exact reading of Size isn't confirmed.

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
