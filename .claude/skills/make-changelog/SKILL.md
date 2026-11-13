---
name: make-changelog
description: Turn the commits since the last release into a changelog for the GitHub release page, written for people who make Oni levels with Catwalk and leaving out project technicalities. Use when asked to make, write or translate a changelog, release notes or a release page text, e.g. "make a changelog" or "release notes since v0.1.0".
---

# Make a changelog

Translate commit messages into release notes that level makers would care to read. This is for
the GitHub release page, so it's written for people who use Catwalk, not for its developers.

## 1. Gather the state

Always read the commits again; never reuse a message from the conversation. Unless told which
commits, cover every commit since the last tag, the last release (all of them when there's no tag):

```bash
tag=$(git describe --tags --abbrev=0 2>/dev/null); echo "since: ${tag:-the first commit}"
git log ${tag:+$tag..HEAD} --reverse --format='%h %ad%n%B' --date=short && cat VERSION
```

Read them all and merge their items into one changelog. When a later commit changes or fixes
something an earlier one added, describe it once, as it ships. Leave out commits with nothing a
user would notice. If `VERSION` is no newer than the tag, say so after the changelog.

If an item is too vague to explain to a user, read that part of the commit with `git show` rather
than guessing what it does. Don't describe anything the commits don't contain.

## 2. Write the changelog

Reply with one line naming the audience, then the changelog in one ```markdown code block, ready
to paste, in this shape:

```markdown
## Catwalk v0.2.0

### Highlights

- **See-through textures as in the game:** glass and fences draw after the solid walls, sorted far to near, and Build flags them for Oni's alpha pass.

### New

**Editing**
- Focus selection (.) glides the camera to a viewpoint where nothing blocks the selection.

### Improved

- The Issues list fills itself from Build and the geometry checks, errors first.

### Fixed

- Objects with no visible gizmo or model can no longer be clicked by accident.
- Windows: ...
```

- **Title**: `Catwalk` and the version in `VERSION`.
- **Highlights**: the few changes most users would upgrade for, each with a bold name. An item
  here can be summarized again in more detail under New, but only when New has more to say.
- **New**: features that didn't exist before, grouped under bold topics (Editing, Textures,
  Lighting, Sounds, Build, Interface...) when there are enough to group. Leave a section out when
  it would be empty.
- **Improved**: things that already existed and now work better.
- **Fixed**: what was going wrong, told from the user's side. Say what no longer happens or what
  works now. Mark fixes that apply to one system with `Linux:` or `Windows:`, and put them last.
- Sort each list from major to minor.
- Write plainly for someone who makes levels and doesn't know how Catwalk is built. Say what they
  can now do or what got better, in "you" where it reads naturally. Items don't need to begin with
  a verb here.
- Name the menus, panels, tools and shortcuts people will actually touch (View > Settings, the
  Issues list, Ctrl+J).
- Leave out project technicalities: version bumps, docs, refactors, moved code, cache formats, UI
  toolkit changes, MCP and automation, and internal names such as procs, files and formats (Nim,
  silky, OBOA, manifest v7).
- Keep an Oni term only when level makers need it, such as a face flag they'd tick (Transparent,
  Two-sided) or a file they'd create.
- Merge items that mean the same thing to a user.
- Don't publish, tag or create the release. Only write the text.
