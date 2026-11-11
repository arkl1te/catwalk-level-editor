#!/usr/bin/env bash
# Clean temporary files that belong to Catwalk, and only those.
# Anything a running process still has open (cwd, open file, executable) is kept.
#
# Usage: cleanup.sh [--apply] [--keep DIR]...
#   default        dry run: report what would be freed and what is held
#   --apply        actually delete
#   --keep DIR     never touch DIR (pass the current session's folder)
set -uo pipefail
shopt -s nullglob dotglob

REPO=$(cd "$(dirname "$0")/../../.." && pwd)
# Claude Code names a session's scratch folder after the directory it started in.
SESSIONS=/tmp/claude-$(id -u)/$(sed 's|[^A-Za-z0-9]|-|g' <<<"$REPO")
APPLY=0; KEEP=()
while (($#)); do
  case $1 in
    --apply) APPLY=1 ;;
    --keep) KEEP+=("$(realpath -m "$2")"); shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Every path a live process holds: working directory, open files, executable.
HELD=$(for p in /proc/[0-9]*; do
  readlink "$p/cwd" "$p/exe" 2>/dev/null
  for f in "$p"/fd/*; do readlink "$f" 2>/dev/null; done
done | sed 's/ (deleted)$//' | sort -u)

is_held() {  # $1 = path; true if it or anything under it is in use
  local t; t=$(realpath -m "$1")
  for k in "${KEEP[@]}"; do [[ $t == "$k" || $k == "$t"/* || $t == "$k"/* ]] && return 0; done
  grep -qxF "$t" <<<"$HELD" || grep -qF "$t/" <<<"$HELD"
}

freed=0; held=0
declare -a DEL_LINES=() HELD_LINES=()
consider() {  # $1 = path, $2 = label, $3 = optional reason to keep
  local path=$1 label=$2 reason=${3:-} size
  [[ -e $path ]] || return
  size=$(du -sb "$path" 2>/dev/null | cut -f1); size=${size:-0}
  if [[ -z $reason ]] && is_held "$path"; then reason="in use by a running process"; fi
  if [[ -n $reason ]]; then
    held=$((held + size)); HELD_LINES+=("$(numfmt --to=iec "$size")	$label	($reason)")
  else
    freed=$((freed + size)); DEL_LINES+=("$(numfmt --to=iec "$size")	$label")
    ((APPLY)) && { chmod -R u+w "$path" 2>/dev/null; rm -rf -- "$path"; }
  fi
}

# 1. Claude session scratch folders for this repo.
for d in "$SESSIONS"/*/; do consider "${d%/}" "session ${d%/}"; done

# 2. Catwalk fonts (rewritten at Catwalk startup).
r=; pgrep -x catwalk >/dev/null && r="Catwalk running"
for f in /tmp/catwalk-font.ttf /tmp/catwalk-mono.ttf; do consider "$f" "Catwalk font $(basename "$f")" "$r"; done

verb=$( ((APPLY)) && echo "Freed" || echo "Would free" )
echo "== $verb: $(numfmt --to=iec $freed)"
printf '%s\n' "${DEL_LINES[@]}" | sort -rh | head -40
((${#DEL_LINES[@]} > 40)) && echo "... and $((${#DEL_LINES[@]} - 40)) more"
echo "== Holding onto: $(numfmt --to=iec $held)"
printf '%s\n' "${HELD_LINES[@]}" | sort -rh
