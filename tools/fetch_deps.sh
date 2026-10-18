#!/usr/bin/env bash
# Fetches pinned Nim dependencies into ./vendor so builds are reproducible.
# Run directly, or sourced by tools/build.sh, which maps this stage onto part
# of its overall progress bar (STAGE_LO..STAGE_HI percent).

# stage_pct PCT -> overall percent for PCT through the current stage.
stage_pct() { echo $(( ${STAGE_LO:-0} + $1 * (${STAGE_HI:-100} - ${STAGE_LO:-0}) / 100 )); }

# repo_size URL -> the repository's size in bytes according to GitHub's API,
# roughly what a clone downloads; nothing if it can't be had.
repo_size() {
  [[ $1 =~ github\.com[/:]([^/]+)/([^/.]+) ]] || return 0
  curl -fsS --max-time 5 "https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" 2>/dev/null |
    sed -n 's/^  "size": *\([0-9]*\).*/\1/p' | head -1 | { read -r kb && echo $(( kb * 1024 )); } || true
}

# git_progress DONE N NAME TOTAL CMD... runs a git command with --progress and
# turns its "Receiving objects: 42% (..), 1.23 MiB" / "Resolving deltas: 80%"
# output into the bars. TOTAL is the expected download in bytes (or empty).
git_progress() {
  local done=$1 n=$2 name=$3 total=$4 line pct task status got=0 info
  shift 4
  while IFS= read -r line; do
    task=""
    if [[ $line =~ (Receiving\ objects|remote:\ Counting\ objects):\ +([0-9]+)% ]]; then
      pct=${BASH_REMATCH[2]}; [[ ${BASH_REMATCH[1]} == remote* ]] && task=$(( pct / 10 )) || task=$(( 10 + pct * 75 / 100 ))
      [[ $line =~ ,\ ([0-9.]+)\ (bytes|KiB|MiB|GiB) ]] && got=$(pb_bytes "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
      # Once everything's in, what was received is the real total.
      [[ $line == "Receiving objects: 100%"* ]] && total=$got
    elif [[ $line =~ (Resolving\ deltas|Updating\ files):\ +([0-9]+)% ]]; then
      task=$(( 85 + ${BASH_REMATCH[2]} * 15 / 100 ))
    elif [[ $line == fatal:* || $line == error:* ]]; then
      pb_log "$name: $line"
    fi
    if [[ -n $task ]]; then
      info=""
      (( got )) && info=$(pb_size "$got")
      if (( got && ${total:-0} >= got )); then
        [[ $total == "$got" ]] && info+=" / $info" || info+=" / ~$(pb_size "$total")"
      fi
      pb_task "$name" "$task" "$info"
      pb_total "Overall (deps $((done + 1))/$n)" "$(stage_pct $(( (done * 100 + task) / n )))"
    fi
  done < <(set +e +o pipefail; "$@" 2>&1 | tr '\r' '\n'; echo "${PIPESTATUS[0]}" > "$PB_STATUS")
  read -r status < "$PB_STATUS"
  return "$status"
}

fetch_deps() {
  local entries=() name url rev dir label i n
  mkdir -p vendor
  PB_STATUS=$(mktemp)
  while read -r name url rev; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    entries+=("$name $url $rev")
  done < deps.lock
  n=${#entries[@]}

  for (( i = 0; i < n; i++ )); do
    read -r name url rev <<< "${entries[i]}"
    dir="vendor/$name"
    label="$name @ ${rev:0:7}"
    pb_task "$label" 0
    pb_total "Overall (deps $((i + 1))/$n)" "$(stage_pct $(( i * 100 / n )))"
    if [[ ! -d "$dir/.git" ]]; then
      git_progress "$i" "$n" "$label" "$(repo_size "$url")" git clone --progress "$url" "$dir"
    elif [[ "$(git -C "$dir" rev-parse HEAD)" == "$rev" ]]; then
      PB_TASK_INFO="up to date"
    fi
    if [[ "$(git -C "$dir" rev-parse HEAD)" != "$rev" ]]; then
      # A fresh clone usually has the pinned commit already.
      git -C "$dir" cat-file -e "$rev^{commit}" 2>/dev/null ||
        git_progress "$i" "$n" "$label" "" git -C "$dir" fetch --progress origin
      git -C "$dir" checkout --quiet -- .
      git -C "$dir" checkout --quiet "$rev"
    fi
    # Local fixes to a dependency live in patches/NAME.patch; applied once.
    if [[ -f "patches/$name.patch" ]] &&
       ! git -C "$dir" apply --reverse --check "../../patches/$name.patch" 2>/dev/null; then
      git -C "$dir" checkout --quiet -- .
      git -C "$dir" apply "../../patches/$name.patch"
    fi
    pb_task "$label" 100 "$PB_TASK_INFO"
  done
  pb_close_task
  pb_total "Overall (deps $n/$n)" "$(stage_pct 100)"
  rm -f "$PB_STATUS"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "$0")/.."
  source tools/progress.sh
  fetch_deps
  pb_finish "Dependencies ready."
fi
