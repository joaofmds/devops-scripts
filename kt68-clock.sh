#!/usr/bin/env bash
set -u
dir=$(cd "$(dirname "$0")" && pwd)
ps1=$(wslpath -w "$dir/kt68-clock.ps1")
if command -v powershell.exe >/dev/null 2>&1; then
  powershell=(powershell.exe)
else
  powershell=(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
fi
while true; do
  "${powershell[@]}" -NoProfile -ExecutionPolicy Bypass -File "$ps1"
  sleep 2
done
