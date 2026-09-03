#!/usr/bin/env bash
set -euo pipefail

WIFI_NAME="${1:-HILAN-MENDES-5G}"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${HOME}/cursor-diagnostico-${BACKUP_SUFFIX}.log"

log() {
  echo -e "\n==== $1 ====" | tee -a "$LOG_FILE"
}

run_cmd() {
  echo "\$ $*" | tee -a "$LOG_FILE"
  "$@" 2>&1 | tee -a "$LOG_FILE" || true
}

confirm() {
  read -r -p "$1 [s/N]: " ans
  [[ "${ans,,}" == "s" || "${ans,,}" == "sim" ]]
}

log "Início do diagnóstico do Cursor"
echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"

log "1) Conexões ativas"
run_cmd nmcli connection show --active

log "2) Status DNS"
run_cmd resolvectl status
run_cmd resolvectl query api2.cursor.sh
run_cmd resolvectl query api3.cursor.sh

log "3) Teste HTTPS/TLS"
run_cmd curl -Iv https://api2.cursor.sh
run_cmd curl -Iv https://api3.cursor.sh
run_cmd curl -Iv https://www.cursor.com

log "4) Verificação de proxy"
run_cmd bash -lc 'env | grep -i proxy'
run_cmd gsettings get org.gnome.system.proxy mode

log "5) Descobrir binário/instalação do Cursor"
run_cmd which cursor
run_cmd bash -lc 'dpkg -l | grep -i cursor'
run_cmd bash -lc 'apt list --installed 2>/dev/null | grep -i cursor'

log "6) Verificar diretórios do Cursor"
run_cmd bash -lc 'find ~/.config ~/.cache ~/.local/share -iname "*cursor*" 2>/dev/null | head -n 200'

if confirm "Deseja configurar DNS IPv4 Cloudflare nessa conexão?"; then
  log "7) Aplicando DNS Cloudflare"
  run_cmd nmcli connection modify "$WIFI_NAME" ipv4.dns "1.1.1.1 1.0.0.1"
  run_cmd nmcli connection modify "$WIFI_NAME" ipv4.ignore-auto-dns yes
  run_cmd nmcli connection down "$WIFI_NAME"
  run_cmd nmcli connection up "$WIFI_NAME"
fi

if confirm "Deseja desabilitar IPv6 temporariamente nessa conexão?"; then
  log "8) Desabilitando IPv6"
  run_cmd nmcli connection modify "$WIFI_NAME" ipv6.dns ""
  run_cmd nmcli connection modify "$WIFI_NAME" ipv6.ignore-auto-dns yes
  run_cmd nmcli connection modify "$WIFI_NAME" ipv6.method disabled
  run_cmd nmcli connection down "$WIFI_NAME"
  run_cmd nmcli connection up "$WIFI_NAME"
  echo "Para reverter depois:" | tee -a "$LOG_FILE"
  echo "nmcli connection modify \"$WIFI_NAME\" ipv6.method auto && nmcli connection down \"$WIFI_NAME\" && nmcli connection up \"$WIFI_NAME\"" | tee -a "$LOG_FILE"
fi

if confirm "Deseja fazer backup e limpar o estado local do Cursor?"; then
  log "9) Backup e limpeza do Cursor"
  [[ -d "$HOME/.config/Cursor" ]] && run_cmd mv "$HOME/.config/Cursor" "$HOME/.config/Cursor.bak.${BACKUP_SUFFIX}"
  [[ -d "$HOME/.cache/Cursor" ]] && run_cmd mv "$HOME/.cache/Cursor" "$HOME/.cache/Cursor.bak.${BACKUP_SUFFIX}"
  [[ -d "$HOME/.cursor" ]] && run_cmd mv "$HOME/.cursor" "$HOME/.cursor.bak.${BACKUP_SUFFIX}"
fi

log "Fim"
echo -e "\nConcluído. Revise o log em: $LOG_FILE"
