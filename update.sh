#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Configuração
# =========================
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SCRIPT_DIR="$REAL_HOME/.scripts"
LOG_DIR="$SCRIPT_DIR/logs"
DATE_TAG="$(date +%F_%H-%M-%S)"
LOG_FILE="$LOG_DIR/update_${DATE_TAG}.log"
ERROR_LOG="$LOG_DIR/error_${DATE_TAG}.log"
LYNIS_LOG="$LOG_DIR/lynis_${DATE_TAG}.log"
EMAIL_TO="ms.joao.felipe@gmail.com"
ENABLE_EMAIL="false"   # troque para "true" se seu mail estiver configurado
CLEAN_DOWNLOADS="false" # troque para "true" se quiser manter essa limpeza

mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERROR_LOG" >&2)

# =========================
# Funções auxiliares
# =========================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_step() {
  local title="$1"
  shift
  log ">>> $title"
  if "$@"; then
    log "[OK] $title"
  else
    log "[WARN] Falha em: $title"
    return 0
  fi
}

run_as_user() {
  if [[ "$REAL_USER" = "root" ]]; then
    "$@"
  else
    sudo -u "$REAL_USER" -H "$@"
  fi
}

cleanup_old_logs() {
  find "$LOG_DIR" -type f -mtime +15 -delete 2>/dev/null || true
}

send_email_report() {
  if [[ "$ENABLE_EMAIL" != "true" ]]; then
    return 0
  fi

  if has_cmd mail; then
    mail -s "Atualização diária do sistema - $(hostname)" "$EMAIL_TO" < "$LOG_FILE" || true
  elif has_cmd mailx; then
    mailx -s "Atualização diária do sistema - $(hostname)" "$EMAIL_TO" < "$LOG_FILE" || true
  else
    log "[INFO] mail/mailx não encontrado; envio de e-mail ignorado."
  fi
}

# =========================
# Pré-checagens
# =========================
if [[ "${EUID}" -ne 0 ]]; then
  echo "Este script precisa ser executado como root."
  echo "Use: sudo $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log "===== Iniciando atualização geral do sistema ====="
log "Usuário real: $REAL_USER"
log "Home real: $REAL_HOME"

# =========================
# APT / DPKG
# =========================
run_step "Verificando integridade do APT" apt-get check
run_step "Atualizando índices do APT" apt-get update
run_step "Corrigindo dependências quebradas" apt-get -f install -y
run_step "Atualizando pacotes APT" apt-get upgrade -y
run_step "Atualizando pacotes com mudanças de dependência (dist-upgrade)" apt-get dist-upgrade -y
run_step "Removendo pacotes não utilizados" apt-get autoremove -y
run_step "Limpando cache antigo do APT" apt-get autoclean -y

log "Pacotes ainda atualizáveis via APT:"
apt list --upgradable 2>/dev/null || true

# =========================
# SNAP
# =========================
if has_cmd snap; then
  run_step "Atualizando pacotes Snap" snap refresh
else
  log "[INFO] snap não encontrado."
fi

# =========================
# FLATPAK
# =========================
if has_cmd flatpak; then
  run_step "Atualizando Flatpaks do sistema" flatpak update -y --system
  run_step "Atualizando Flatpaks do usuário" run_as_user flatpak update -y --user
  run_step "Removendo runtimes Flatpak não usados" flatpak uninstall --unused -y
else
  log "[INFO] flatpak não encontrado."
fi

# =========================
# FWUPD (firmware)
# =========================
if has_cmd fwupdmgr; then
  run_step "Atualizando metadados de firmware" fwupdmgr refresh --force
  run_step "Aplicando updates de firmware" fwupdmgr update -y
else
  log "[INFO] fwupdmgr não encontrado."
fi

# =========================
# PIPX
# =========================
if has_cmd pipx; then
  run_step "Atualizando apps instalados via pipx" run_as_user pipx upgrade-all
else
  log "[INFO] pipx não encontrado."
fi

# =========================
# NPM global
# =========================
if has_cmd npm; then
  run_step "Atualizando pacotes globais do npm" npm update -g
else
  log "[INFO] npm não encontrado."
fi

# =========================
# Yarn global
# =========================
if has_cmd yarn; then
  run_step "Atualizando pacotes globais do yarn" yarn global upgrade
else
  log "[INFO] yarn não encontrado."
fi

# =========================
# PNPM global
# =========================
if has_cmd pnpm; then
  run_step "Atualizando pacotes globais do pnpm" pnpm update -g
else
  log "[INFO] pnpm não encontrado."
fi

# =========================
# Cargo / Rust
# =========================
if has_cmd rustup; then
  run_step "Atualizando toolchains Rust via rustup" run_as_user rustup update
else
  log "[INFO] rustup não encontrado."
fi

if has_cmd cargo; then
  if has_cmd cargo-install-update; then
    run_step "Atualizando binários instalados via cargo" run_as_user cargo install-update -a
  else
    log "[INFO] cargo-install-update não encontrado; binários do cargo não serão atualizados automaticamente."
    log "[INFO] Para habilitar: cargo install cargo-update"
  fi
else
  log "[INFO] cargo não encontrado."
fi

# =========================
# Ruby Gems
# =========================
if has_cmd gem; then
  run_step "Atualizando RubyGems" gem update --system
  run_step "Atualizando gems instaladas" gem update
  run_step "Limpando versões antigas de gems" gem cleanup
else
  log "[INFO] gem não encontrado."
fi

# =========================
# Homebrew no Linux
# =========================
if has_cmd brew; then
  run_step "Atualizando fórmulas do Homebrew" run_as_user brew update
  run_step "Atualizando pacotes do Homebrew" run_as_user brew upgrade
  run_step "Limpando cache antigo do Homebrew" run_as_user brew cleanup -s
else
  log "[INFO] brew não encontrado."
fi

# =========================
# Antivirus / segurança
# =========================
if has_cmd freshclam; then
  run_step "Atualizando definições do ClamAV" freshclam
else
  log "[INFO] freshclam não encontrado."
fi

if has_cmd chkrootkit; then
  log ">>> Verificando rootkits com chkrootkit"
  chkrootkit 2>&1 | tee -a "$LOG_FILE" || true
else
  log "[INFO] chkrootkit não encontrado."
fi

if has_cmd rkhunter; then
  run_step "Atualizando base do rkhunter" rkhunter --update
  log ">>> Verificando rootkits com rkhunter"
  rkhunter --check --sk 2>&1 | tee -a "$LOG_FILE" || true
else
  log "[INFO] rkhunter não encontrado."
fi

if has_cmd aa-status; then
  log ">>> Verificando AppArmor"
  aa-status | tee -a "$LOG_FILE" || true
else
  log "[INFO] aa-status não encontrado."
fi

if has_cmd lynis; then
  run_step "Rodando auditoria Lynis" lynis audit system --quiet --logfile "$LYNIS_LOG"
else
  log "[INFO] lynis não encontrado."
fi

# =========================
# Limpeza opcional
# =========================
cleanup_old_logs

if [[ "$CLEAN_DOWNLOADS" == "true" ]]; then
  log ">>> Limpando Downloads com mais de 7 dias"
  find "$REAL_HOME/Downloads" -mindepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
else
  log "[INFO] Limpeza automática de Downloads desativada."
fi

send_email_report

log "===== Atualização concluída em $(date '+%Y-%m-%d %H:%M:%S') ====="
