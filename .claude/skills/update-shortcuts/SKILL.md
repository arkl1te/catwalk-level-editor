---
name: update-shortcuts
description: Register every keyboard or mouse shortcut added or changed in the current conversation in Catwalk's menus, the status bar's modifier hints and the Controls tables of Guide.draft.md. Use after implementing or changing any shortcut (key, key combo, mouse button, wheel or drag gesture) in Catwalk, before reporting the work as done.
---

# Update shortcuts in the menus, the status bar and the Guide

Every shortcut you implemented or changed **in the current conversation** must show up in all the
places below that apply to it. Don't skip one because the shortcut "isn't important".

## 1. List this conversation's shortcuts

Go back through the conversation and list every shortcut you added, rebound or removed:
keyboard keys, modifier combos, mouse buttons, double-clicks, wheel actions (including
modifier+wheel) and drag gestures. Include ones that are only reachable from the keyboard or
mouse, with no menu item. For each one, note its keys, what it does and when it applies (tool,
view, selection).

## 2. Menu items (`src/panels.nim`)

If the shortcut runs a menu item, its key text goes in that item's `shortcut` argument
(`item(label, shortcut, ...)`), written like `Ctrl+Shift+K`, `Shift+.`, `Del`. Keyboard
shortcuts run menu items by label, so the text must match the key that really triggers it. If
you changed or removed a shortcut, update its old item too.

The status bar picks these up by itself: while a modifier is held, `modifierHints` lists every
enabled menu item whose shortcut uses exactly that combo. Nothing else to add for them there.

## 3. Status bar hints (`modifierHints` in `src/panels.nim`)

Shortcuts that aren't menu items need a hint by hand. The `held` set says which modifiers are
down: `{'c'}` Ctrl, `{'s'}` Shift, `{'a'}` Alt, `{'c', 's'}`, `{'c', 'a'}`, `{'s', 'a'}`,
`{'c', 's', 'a'}`.

- **Mouse gestures** go in `mouse`, in the branch for their exact combo, leaving the modifier
  out of the key: Ctrl+wheel becomes `("Wheel", "Select next behind / in front")` in the
  `{'c'}` branch. Gate them on the same state as the gesture (`in3D`, `noTool`, `pieces`,
  `oneFace`, `faceMode`, `drawing`, `moving`, `a.tool`), so the bar only offers what works now.
- **Keys that aren't menu items** (arrows, PgUp/PgDn, Enter in a tool...) go in `extra`, also
  per combo and gated on the state.
- Labels are sentence case, short ("Paint select faces", "Duplicate and move"). Keys are short:
  `Arrows`, `PgUp/PgDn`, `Left/Right`, `Enter`, `R`.
- Write mouse inputs as `LMB`, `RMB`, `MMB`, `Wheel`, `Drag` (left drag), `MDrag`, `RDrag` or
  `Dbl` (double-click, drawn as a key cap). The ones drawn as Blender-style mouse icons are
  `mouseIcons` in `src/icons.nim`. For a gesture none of them covers, add an entry there:
  `"Key": ("mouse-<name>16", button, motion)`, where button is `"left"`/`"right"`/`"middle"` and
  motion is `""`, `"v"` or `"h"`.
- Shortcuts without a modifier (plain keys, plain clicks, plain wheel, tool keys such as B or
  C) have no status-bar hint, because the bar only appears while a modifier is held. Put those
  in the Guide only, and say in your reply to the user that they have no status-bar hint.

## 4. Guide (`Guide.draft.md`, "Controls (TrenchBroom defaults)")

Add or update a row in the table it belongs to: the mouse table (clicks, drags, wheel), the
Tools table (tool keys and what works inside a tool) or the Keys table. Follow the existing
style: keys like `Ctrl+Shift+click`, `Alt+arrows`, `Ctrl+J / K / Shift+K / L`; pairs and
variants share one row, with modifiers that change a gesture in brackets
("Move (Alt: vertically in 3D, Shift: lock to one axis)"). If you changed or removed a shortcut,
update or delete its old row too.

## 5. Build and install

Run `make`, then `make install`, so the installed binary in `~/.local/bin` (which the Catwalk
launcher runs) gets the changes. In your reply, list each shortcut and where you added it: the
menu item, the status-bar combo (or "automatic, from the menu"), and the Guide table, or
"Guide only (no modifier)".
