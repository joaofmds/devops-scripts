#!/bin/bash

set -euo pipefail

HOME="/home/joaofmds"
LOG_FILE="$HOME/.scripts/logs/update_$(date +%F).log"
ERROR_LOG="$HOME/.scripts/logs/error_$(date +%F).log"
EMAIL_TO="ms.joao.felipe@gmail.com"

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERROR_LOG" >&2)

echo "===== $(date '+%Y-%m-%d %H:%M:%S') - Iniciando atualização ====="

echo "[✔] Verificando integridade do APT..."
apt-get check

echo "[✔] Atualizando pacotes..."
env DEBIAN_FRONTEND=noninteractive apt-get update -y
env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "[ℹ] Pacotes ainda atualizáveis:"
apt list --upgradable || true

echo "[✔] Limpando pacotes antigos..."
apt-get autoremove -y
apt-get autoclean -y

echo "[🔒] Atualizando definições do ClamAV..."
command -v freshclam >/dev/null && freshclam || echo "[⚠️] Falha ao atualizar ClamAV"

echo "[🕷️ ] Verificando rootkits (chkrootkit)..."
command -v chkrootkit >/dev/null && chkrootkit 2>&1 | tee -a "$LOG_FILE"

echo "[🕷️ ] Verificando rootkits (rkhunter)..."
command -v rkhunter >/dev/null && rkhunter --update
command -v rkhunter >/dev/null && rkhunter --check --sk 2>&1 | tee -a "$LOG_FILE"

echo "[🧱] Verificando estado do AppArmor..."
command -v aa-status >/dev/null && aa-status | tee -a "$LOG_FILE"

echo "[🔍] Rodando auditoria com Lynis..."
command -v lynis >/dev/null && lynis audit system --quiet --logfile "$HOME/.scripts/logs/lynis_$(date +%F).log"

echo "[🧹] Limpando logs antigos com mais de 7 dias..."
find "$HOME/.scripts/logs" -type f -mtime +7 -delete

echo "[🧹] Limpando arquivos e pastas antigos da pasta Downloads..."
find "$HOME/Downloads" -mindepth 1 -mtime +7 -exec rm -rf {} +

echo "===== Atualização concluída com sucesso em $(date '+%Y-%m-%d %H:%M:%S') ====="

if [[ -s "$LOG_FILE" ]]; then
    mail -s "Atualização diária do sistema - $(hostname)" "$EMAIL_TO" < "$LOG_FILE"
fi

