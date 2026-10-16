#!/usr/bin/env bash
set -eu
if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
  echo "Rode este instalador dentro do WSL." >&2
  exit 1
fi
dir=$(cd "$(dirname "$0")" && pwd)
chmod 755 "$dir/kt68-clock.sh"
if command -v powershell.exe >/dev/null 2>&1; then
  powershell=(powershell.exe)
else
  powershell=(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
fi
winuser=$(
  cd /mnt/c
  "${powershell[@]}" -NoProfile -Command 'Write-Output $env:USERNAME' | tr -d '\r'
)
if [[ -z "$winuser" ]]; then
  echo "Não foi possível ler o usuário do Windows." >&2
  exit 1
fi
(
  cd /mnt/c
  "${powershell[@]}" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$dir/install-kt68-clock.ps1")" -Distro "$WSL_DISTRO_NAME" -Script "$dir/kt68-clock.sh" -User "$winuser"
)
