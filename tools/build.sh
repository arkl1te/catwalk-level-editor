#!/usr/bin/env bash
# Builds with progress bars: fetches deps if deps.lock changed, then compiles.
# Usage: tools/build.sh NIM c [nim options...] src/catwalk.nim
# Totals for the compile bar come from the previous build with the same
# options (vendor/.build-stats-*); the first build uses rough estimates.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/progress.sh
source tools/fetch_deps.sh

STAGE_LO=0 STAGE_HI=100
if [[ ! -f vendor/.stamp || deps.lock -nt vendor/.stamp || tools/fetch_deps.sh -nt vendor/.stamp || -n $(find patches -newer vendor/.stamp 2>/dev/null) ]]; then
  STAGE_HI=40
  fetch_deps
  touch vendor/.stamp
  (( PB_TTY )) || pb_log "Dependencies ready."
  STAGE_LO=40 STAGE_HI=100
fi

# Compile: one line each for checking modules, C compilation and linking.
# Nim reports one [Processing] hint per module it checks and one
# "CC:" line per C file it compiles, then [Link]; everything else that isn't a
# hint (warnings, errors) is passed through.
stats="vendor/.build-stats-$(printf '%s' "$*" | cksum | cut -d' ' -f1)"
total_proc=410 total_cc=140
[[ -f $stats ]] && read -r total_proc total_cc < "$stats"

out=$(printf '%s\n' "$@" | sed -n 's/^-o://p' | tail -1)
cmd=("$1" "$2" --hint:Processing:on --processing:filenames --hint:CC:on --hint:Link:on
     --hint:SuccessX:off --hint:Conf:off "${@:3}")
proc=0 cc=0 phase=0
# The per-phase totals are estimates, so a phase is only known to be complete
# once the next one starts.
end_phase() { [[ $PB_TASK == "$1" ]] || pb_task "$PB_TASK" 100 "$PB_TASK_INFO"; }
PB_STATUS=$(mktemp)

(( PB_TTY )) || pb_log "Compiling..."
pb_task "Checking modules" 0
pb_total "Overall (compiling)" "$(stage_pct 0)"
while IFS= read -r line; do
  if [[ $line == *"[Processing]" ]]; then
    (( ++proc ))
    task=$(( proc * 100 / total_proc )); (( task > 99 )) && task=99
    pb_task "Checking modules" "$task" "$proc modules"
    pb_total "Overall (compiling)" "$(stage_pct $(( task * 60 / 100 )))"
  elif [[ $line == CC:* ]]; then
    end_phase "C compiler"
    (( ++cc ))
    task=$(( cc * 100 / total_cc )); (( task > 99 )) && task=99
    pb_task "C compiler" "$task" "$cc files"
    pb_total "Overall (compiling)" "$(stage_pct $(( 60 + task * 37 / 100 )))"
  elif [[ $line == *"[Link]" ]]; then
    end_phase "Linking"
    pb_task "Linking" 50
    pb_total "Overall (compiling)" "$(stage_pct 97)"
  elif [[ $line != Hint:* && $line != *") Hint: "* ]]; then
    pb_log "$line"
  fi
done < <(set +e; "${cmd[@]}" 2>&1; echo $? > "$PB_STATUS")
read -r status < "$PB_STATUS"
rm -f "$PB_STATUS"

if (( status != 0 )); then
  pb_finish "Build failed."
  exit "$status"
fi
# Only full builds give meaningful totals; incremental ones compile fewer C files.
(( cc * 2 > total_cc )) || cc=$total_cc
echo "$proc $cc" > "$stats"
pb_task "Linking" 100
pb_total "Overall" 100
pb_finish "Built ${out:-binary}."
