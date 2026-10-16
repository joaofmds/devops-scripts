#!/usr/bin/env bash
set -eu
if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
  echo "Rode este instalador dentro do WSL." >&2
  exit 1
fi
dir=$(cd "$(dirname "$0")" && pwd)
chmod 755 "$dir/kt68-clock.sh"
KT68_DISTRO="$WSL_DISTRO_NAME"
KT68_SCRIPT="$dir/kt68-clock.sh"
KT68_USER=$(cmd.exe /c "echo %USERNAME%" | tr -d '\r')
export KT68_DISTRO KT68_SCRIPT KT68_USER
if command -v powershell.exe >/dev/null 2>&1; then
  powershell=(powershell.exe)
else
  powershell=(/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)
fi
"${powershell[@]}" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$dir/install-kt68-clock.ps1")"
