# Progress display shared by the build scripts (sourced, not run).
# Every task gets its own line, prefixed with the time elapsed since the build
# started, and stays on screen once the next task begins, so the output reads
# as a log of what's been done. On a terminal the current task's line and the
# overall bar under it update live; when stdout isn't a terminal (CI, logs),
# each task's line is printed once, when it's finished.

PB_TTY=0
[[ -t 1 && ${TERM:-dumb} != dumb ]] && PB_TTY=1
# Exported so the clock keeps running across scripts (windows.sh -> build.sh).
[[ -n ${PB_T0:-} ]] || printf -v PB_T0 '%(%s)T' -1
export PB_T0
PB_ROWS=0  # live lines currently drawn; the cursor sits at the end of the last
PB_COLS=$(tput cols 2>/dev/null || echo 80)
trap 'PB_COLS=$(tput cols 2>/dev/null || echo 80)' WINCH
PB_LAST=""
PB_TASK="" PB_TASK_PCT=0 PB_TASK_INFO=""
PB_TOTAL="" PB_TOTAL_PCT=0

# pb_clock -> MM:SS since the build started.
pb_clock() {
  local now
  printf -v now '%(%s)T' -1
  printf '%02d:%02d' $(( (now - PB_T0) / 60 )) $(( (now - PB_T0) % 60 ))
}

# pb_size BYTES -> "4.5 MiB".
pb_size() {
  local t=$(( $1 * 10 )) i=0 units=(B KiB MiB GiB)
  (( $1 < 1024 )) && { printf '%d B' "$1"; return; }
  while (( t >= 10240 && i < 3 )); do (( t /= 1024, ++i )); done
  printf '%d.%d %s' $(( t / 10 )) $(( t % 10 )) "${units[i]}"
}

# pb_bytes NUM UNIT -> bytes, for sizes as tools print them ("1.23" "MiB").
pb_bytes() {
  local int=${1%%.*} frac=00 mult=1
  [[ $1 == *.* ]] && frac="${1#*.}00"
  case $2 in KiB) mult=1024 ;; MiB) mult=1048576 ;; GiB) mult=1073741824 ;; esac
  echo $(( (int * 100 + 10#${frac:0:2}) * mult / 100 ))
}

# pb_line LABEL PCT [INFO] -> one formatted bar line, sized to the terminal width.
pb_line() {
  local label=$1 pct=$2 info=${3:-} width fill bar pad
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  (( width = PB_COLS - 62 ))
  (( width > 40 )) && width=40
  (( width < 10 )) && width=10
  (( fill = pct * width / 100 ))
  printf -v bar '%*s' "$fill" ''
  bar=${bar// /█}
  printf -v pad '%*s' "$(( width - fill ))" ''
  pad=${pad// /░}
  printf '%s  %-24.24s %s%s %3d%%  %s' "$(pb_clock)" "$label" "$bar" "$pad" "$pct" "$info"
}

# pb_rewind: move the cursor back to the start of the first live line.
pb_rewind() {
  (( PB_ROWS )) && printf '\r'
  (( PB_ROWS > 1 )) && printf '\e[%dA' $(( PB_ROWS - 1 ))
  PB_ROWS=0
}

pb_draw() {
  (( PB_TTY )) || return 0
  local lines=() key i
  [[ -n $PB_TASK ]] && lines+=("$(pb_line "$PB_TASK" "$PB_TASK_PCT" "$PB_TASK_INFO")")
  [[ -n $PB_TOTAL ]] && lines+=("$(pb_line "$PB_TOTAL" "$PB_TOTAL_PCT")")
  key="${lines[*]}"
  [[ $key == "$PB_LAST" ]] && return 0
  PB_LAST=$key
  pb_rewind
  for (( i = 0; i < ${#lines[@]}; i++ )); do
    (( i )) && printf '\n'
    printf '\e[K%s' "${lines[i]}"
  done
  PB_ROWS=${#lines[@]}
}

# pb_above MSG: print a line above the live bars (the caller redraws them).
pb_above() {
  if (( PB_TTY )); then
    pb_rewind
    printf '\e[K%s\n' "$1"
    PB_LAST=""
  else
    printf '%s\n' "$1"
  fi
}

# pb_close_task: leave the current task's line behind as finished.
pb_close_task() {
  [[ -n $PB_TASK ]] && pb_above "$(pb_line "$PB_TASK" "$PB_TASK_PCT" "$PB_TASK_INFO")"
  PB_TASK=""
}

# pb_task LABEL PCT [INFO] updates the current task, or starts a new line when
# LABEL changes. INFO goes after the percent (sizes, counts).
# pb_total LABEL PCT updates the overall bar.
pb_task() {
  [[ $1 != "$PB_TASK" ]] && pb_close_task
  PB_TASK=$1 PB_TASK_PCT=$2 PB_TASK_INFO=${3:-}
  pb_draw
}
pb_total() { PB_TOTAL=$1; PB_TOTAL_PCT=$2; pb_draw; }

# pb_log MSG... prints a line above the bars.
pb_log() { pb_above "$*"; pb_draw; }

# pb_finish MSG: leave everything on screen and print a final line.
pb_finish() {
  pb_close_task
  pb_draw
  (( PB_ROWS )) && printf '\n'
  PB_ROWS=0 PB_LAST="" PB_TOTAL=""
  printf '%s\n' "$*"
}

# pb_download LABEL URL FILE: curl URL to FILE with a task bar showing
# received / total bytes.
pb_download() {
  local label=$1 url=$2 out=$3 total got pid
  total=$(curl -fsSLI "$url" 2>/dev/null | tr -d '\r' |
          awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }') || total=0
  curl -fsSL -o "$out" "$url" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    got=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if (( total )); then
      pb_task "$label" $(( got * 100 / total )) "$(pb_size "$got") / $(pb_size "$total")"
    else
      pb_task "$label" 0 "$(pb_size "$got")"
    fi
    sleep 0.2
  done
  wait "$pid" || { pb_finish "Download failed: $url"; return 1; }
  got=$(stat -c %s "$out")
  pb_task "$label" 100 "$(pb_size "$got") / $(pb_size "$got")"
}

if (( PB_TTY )); then
  printf '\e[?25l'
  trap 'printf "\e[?25h"; (( PB_ROWS )) && printf "\n"' EXIT
  trap 'exit 130' INT TERM
fi
