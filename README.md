# Catwalk

A level editor for [Oni](https://oni.bungie.org/), laid out and controlled like
[TrenchBroom](https://trenchbroom.github.io), with [Silky](https://github.com/treeform/silky)
UI, vibecoded in Nim.

Catwalk's aim is to make Oni levels as easy to build as Quake maps.

> [!IMPORTANT]
> **Catwalk needs [Arklite](https://github.com/arkl1te/arklite-oni-patch).** Maps made in
> Catwalk load through Arklite's Custom Game menu, so you and anyone you share a map with
> need it installed.

## Features

- **Start from scratch or from the game's own levels**: an empty level, or an editable copy of any of Oni's.
- **Play with one key** (F5): Catwalk builds the level and starts Oni in it, from the beginning or from a save point.
- **TrenchBroom's tools**: brushes, vertex, edge, face, clip, rotate and scale, CSG, groups and linked groups. Faces can be cut, extended, joined and separated.
- **Groups that spin** in the game, particles included.
- **An Entity Browser** of ready-made characters, weapons, power-ups, furniture, doors, consoles, turrets and particles, with previews of their models. Drag one into the level.
- **Every object's fields** in Properties: characters, flags, triggers, consoles, sounds and the rest, with lists of the values the game knows.
- **Character and particle classes** edited for this level only, with a live particle preview in the views.
- **Textures**: the game's own by collection, and your own pictures up to 1024×1024.
- **Skies**: the game's, or your own from six pictures or from one panorama through the Skybox Converter, with brightness, blend and tint.
- **Baked lighting** from point, spot and directional lights, with soft shadows, lights that pulse, flicker or break down (and can make a sound when they do), and face tints.
- **Music and sounds**: the game's music, any single recording, your own sounds and your own ambient sounds.
- **A script editor** for Oni's BSL that knows the game's commands and the level's objects.
- **Claude Code can drive it** through an optional MCP server.

Hold Ctrl, Shift or Alt and the status bar shows what else you can do. Try right-clicking everything, too!

## Install

### Linux from source (CachyOS / Arch)

You need Oni with the Anniversary Edition and [Arklite](https://github.com/arkl1te/arklite-oni-patch)
(the [Oni installer](https://github.com/arkl1te/oni-game-installer) sets all three up),
plus Nim 2.2+, git, Wine, mono and, to import sounds, ffmpeg.

```sh
git clone https://github.com/arkl1te/catwalk-level-editor.git
cd catwalk-level-editor
make
make install
```

Then search for **Catwalk** in your application launcher. The first time, it asks where
Oni's Anniversary Edition is, and finds the usual Wine, Lutris, Heroic, Bottles and Steam
installs by itself.

To update, `git pull` and run `make install` again. `make uninstall` removes it.

### Windows

From the next release on, the [releases page](https://github.com/arkl1te/catwalk-level-editor/releases)
has a `catwalk-VERSION-windows-x64.zip`: unpack it anywhere and run `catwalk.exe`. You need Oni with
the Anniversary Edition and Arklite, as on Linux, and ffmpeg on your PATH to import sounds.
To build it yourself, see [TECHNICAL.md](TECHNICAL.md#windows).

## More reading

- [Guide](Guide.draft.md): how to use each part of Catwalk, every shortcut, and what happens to a level on Build.
- [TECHNICAL.md](TECHNICAL.md): building by hand, what Catwalk can't do yet, logs and crash reports, and setting up the MCP server.

## Credits

Catwalk's layout, tools and controls follow [TrenchBroom](https://github.com/TrenchBroom/TrenchBroom).
Levels are read and built with OniSplit, from the Anniversary Edition. Its UI is shared
with [Majestic Media Player](https://github.com/arkl1te/majestic-media-player). Catwalk
isn't affiliated with or endorsed by Bungie or the TrenchBroom project.
