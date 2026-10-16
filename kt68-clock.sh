#!/usr/bin/env bash
set -u
dir=$(cd "$(dirname "$0")" && pwd)
log="$dir/kt68-clock.log"
ps1=$(wslpath -w "$dir/kt68-clock.ps1")
if command -v powershell.exe >/dev/null 2>&1; then
  powershell=(powershell.exe)
else
  powershell=(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
fi
if command -v stdbuf >/dev/null 2>&1; then
  tee_log=(stdbuf -oL tee -a "$log")
else
  tee_log=(tee -a "$log")
fi
cd /mnt/c
echo "start $(date --iso-8601=seconds)" | "${tee_log[@]}"
while true; do
  "${powershell[@]}" -NoProfile -ExecutionPolicy Bypass -File "$ps1" 2>&1 | "${tee_log[@]}"
  status=${PIPESTATUS[0]}
  if [[ $status -ne 0 ]]; then
    printf '%s powershell exit %s\n' "$(date --iso-8601=seconds)" "$status" | "${tee_log[@]}"
  fi
  sleep 2
done
