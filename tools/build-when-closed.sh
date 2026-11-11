#!/usr/bin/env bash
# For Claude Code on Windows: builds Catwalk without touching the catwalk.exe
# that may be running, then puts the new build in place as soon as it can.
#   tools/build-when-closed.sh [windows.sh build options...]
# Builds into build\ (Catwalk never has that file open, so the link can't
# fail on it). If Catwalk isn't running, catwalk.exe is replaced at once;
# otherwise a hidden PowerShell process waits for every catwalk.exe to exit
# (Wait-Process waits on the process handles: no polling) and copies the new
# build over then. This script returns right after the build either way.
# Exit code 0: built (and copied, or the copy is pending); 1: the code doesn't build.
set -uo pipefail
cd "$(dirname "$0")/.."

running() { tasklist //FI "IMAGENAME eq catwalk.exe" //NH 2>/dev/null | grep -qi '^catwalk\.exe'; }

mkdir -p build
# Link to a temporary name and rename it once whole, so a pending copy never
# picks up a half-written exe.
next=build/catwalk.next.exe
echo "Building..."
out=$(CATWALK_BIN=$next ./tools/windows.sh build "$@" 2>&1)
code=$?
if (( code != 0 )) || [[ ! -f $next ]]; then
  echo "Build failed:"
  grep -v "Warning:" <<<"$out" | tail -40
  exit 1
fi
mv -f "$next" build/catwalk.exe
[[ -f build/catwalk.next.pdb ]] && mv -f build/catwalk.next.pdb build/catwalk.pdb

src=$(cygpath -w build/catwalk.exe)
dst=$(cygpath -w catwalk.exe)
log=$(cygpath -w build/copy.log)
# Copies the latest build (a later build may have replaced it meanwhile);
# retries a while in case something still holds catwalk.exe after Catwalk exits.
copy="\$ErrorActionPreference = 'Stop'
for (\$i = 0; \$i -lt 60; \$i++) {
  try { Copy-Item -LiteralPath '$src' -Destination '$dst' -Force
        Add-Content -LiteralPath '$log' \"\$(Get-Date -Format s) copied the new build to catwalk.exe\"; exit 0 }
  catch { Start-Sleep -Milliseconds 500 } }
Add-Content -LiteralPath '$log' \"\$(Get-Date -Format s) could not replace catwalk.exe: \$_\"; exit 1"

if ! running; then
  if powershell.exe -NoProfile -NonInteractive -Command "$copy" >/dev/null 2>&1; then
    echo "Built catwalk.exe."
    exit 0
  fi
  echo "Built build\\catwalk.exe, but couldn't replace catwalk.exe (see build\\copy.log)."
  exit 0
fi

# A detached, hidden process: it outlives this script and the shell running it.
waiter="Wait-Process -Name catwalk -ErrorAction SilentlyContinue
$copy"
enc=$(printf '%s' "$waiter" | iconv -t UTF-16LE | base64 -w0)
powershell.exe -NoProfile -NonInteractive -Command \
  "Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand','$enc'" \
  >/dev/null 2>&1
echo "Built. Catwalk is open: the new build replaces catwalk.exe as soon as Catwalk closes."
exit 0
