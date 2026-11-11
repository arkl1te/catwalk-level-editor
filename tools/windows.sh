#!/usr/bin/env bash
# Windows build and install, run from Git Bash (what `make` does elsewhere).
#   tools/windows.sh build       fetch deps, compile catwalk.exe
#   tools/windows.sh debug       same, unoptimized, with a console
#   tools/windows.sh run         build, then start it
#   tools/windows.sh install     build, then install for the current user
#   tools/windows.sh uninstall   remove the install and its shortcut
#   tools/windows.sh stage DIR   copy what ships (exe, README, licenses\) into DIR
# Requires: nim >= 2.2, git, and Visual Studio (or its Build Tools) with the
# C++ workload; Nim finds it by itself. Taken from Majestic Media Player's,
# which is built the same way (MSVC through Nim's vccexe).
# At run time Catwalk needs what it does on Linux minus Mono: Oni AE (its
# OniSplit.exe runs on the .NET Framework), and ffmpeg on PATH to import sounds.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${CATWALK_BIN:-catwalk.exe}   # CATWALK_BIN: build somewhere else (tools/build-when-closed.sh)
APP_DIR="${LOCALAPPDATA:?}/Programs/Catwalk"
SHORTCUT="${APPDATA:?}/Microsoft/Windows/Start Menu/Programs/Catwalk.lnk"

resources() {
  # The icon Explorer shows for the .exe (assets/windows/catwalk.ico, made by
  # tools/make_ico.nim). rc.exe ships with the Windows SDK; without it the
  # program still builds, just with the generic icon.
  local rc
  rc=$(ls -d "${PROGRAMFILES_X86:-/c/Program Files (x86)}"/Windows\ Kits/10/bin/10.*/x64/rc.exe 2>/dev/null | sort -V | tail -1)
  if [[ -z $rc ]]; then
    echo "rc.exe (Windows SDK) not found: building without the icon" >&2
    return
  fi
  mkdir -p vendor
  "$rc" -nologo -fo vendor/catwalk.res "$(cygpath -w assets/windows/catwalk.rc)" >/dev/null
  echo "--passL:$(cygpath -w vendor/catwalk.res)"
}

build() {
  local res=()
  mapfile -t res < <(resources)
  # MSVC via Nim's vccexe, which locates Visual Studio itself.
  ./tools/build.sh nim c --cc:vcc "${res[@]}" "$@" -o:"$BIN" src/catwalk.nim
}

stage() {
  # What ships: the program, the README its Help menu opens, and the licenses.
  local dest=${1:?usage: tools/windows.sh stage DIR}
  mkdir -p "$dest/licenses"
  cp "$BIN" README.md "$dest/"
  cp LICENSE "$dest/licenses/Catwalk.txt"
  cp assets/licenses/* "$dest/licenses/"
}

install_app() {
  build -d:release --app:gui
  stage "$APP_DIR"
  powershell -NoProfile -Command "
    \$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$(cygpath -w "$SHORTCUT")')
    \$s.TargetPath = '$(cygpath -w "$APP_DIR/$BIN")'
    \$s.WorkingDirectory = '$(cygpath -w "$APP_DIR")'
    \$s.Description = 'Catwalk, a level editor for Oni'
    \$s.Save()"
  echo "Installed $(cygpath -w "$APP_DIR")\\$BIN — find it in the Start menu as 'Catwalk'."
}

uninstall_app() {
  rm -rf "$APP_DIR"
  rm -f "$SHORTCUT"
  echo "Uninstalled (settings and logs are kept in %APPDATA%\\catwalk and %LOCALAPPDATA%\\catwalk)."
}

case "${1:-build}" in
  build)     build -d:release --app:gui ;;
  debug)     build -d:debug --debugger:native ;;
  run)       build -d:release --app:gui; ./"$BIN" "${@:2}" ;;
  install)   install_app ;;
  uninstall) uninstall_app ;;
  stage)     stage "${2:-}" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
