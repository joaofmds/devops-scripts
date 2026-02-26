#!/usr/bin/env bash
set -euo pipefail

# ============================================
# DevOps Ubuntu Bootstrap (Zsh + Neovim + K8s)
# ============================================

# --------- CLI flags ----------
DO_UPGRADE=false
INSTALL_NEOVIM=true
INSTALL_K8S_TOOLS=true
INSTALL_DEVOPS_TOOLS=true

for arg in "${@:-}"; do
  case "$arg" in
    --upgrade) DO_UPGRADE=true ;;
    --no-neovim) INSTALL_NEOVIM=false ;;
    --no-k8s) INSTALL_K8S_TOOLS=false ;;
    --no-devops) INSTALL_DEVOPS_TOOLS=false ;;
    -h|--help)
      cat <<'EOF'
Usage: bash devops-ubuntu-setup.sh [options]

Options:
  --upgrade        Runs apt upgrade/dist-upgrade (recommended on fresh install)
  --no-neovim      Skips Neovim + kickstart.nvim setup
  --no-k8s         Skips Kubernetes tools (kubectl/helm/k9s/kubectx/krew)
  --no-devops      Skips general DevOps tools (jq/yq/fzf/rg/bat/eza/direnv/etc)
EOF
      exit 0
      ;;
  esac
done

# --------- pretty output ----------
if command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
  RED="$(tput setaf 1 || true)"; GRN="$(tput setaf 2 || true)"; YLW="$(tput setaf 3 || true)"; BLU="$(tput setaf 4 || true)"
else
  BOLD=""; RESET=""; RED=""; GRN=""; YLW=""; BLU=""
fi

log()  { echo "${BLU}${BOLD}==>${RESET} $*"; }
ok()   { echo "${GRN}${BOLD}✔${RESET} $*"; }
warn() { echo "${YLW}${BOLD}⚠${RESET} $*"; }
die()  { echo "${RED}${BOLD}✖${RESET} $*" >&2; exit 1; }

# --------- basics ----------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

is_ubuntu() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *"ubuntu"* ]]
}

SUDO="sudo"
if [[ $EUID -eq 0 ]]; then
  SUDO=""
fi

USER_HOME="${HOME}"
USER_NAME="$(id -un)"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

# --------- github latest release helper ----------
# Usage: gh_latest "derailed/k9s" "Linux_amd64.tar.gz"
gh_latest_url() {
  local repo="$1"
  local pattern="$2"
  require_cmd curl
  require_cmd grep
  require_cmd sed

  # GitHub API: latest release assets
  # We avoid jq dependency here (jq is installed later).
  local api="https://api.github.com/repos/${repo}/releases/latest"
  local url
  url="$(
    curl -fsSL "$api" \
      | grep -Eo '"browser_download_url":[ ]*"[^"]+"' \
      | sed -E 's/"browser_download_url":[ ]*"([^"]+)"/\1/' \
      | grep -E "$pattern" \
      | head -n 1
  )"
  [[ -n "${url:-}" ]] || die "Could not find latest asset for ${repo} matching pattern: ${pattern}"
  echo "$url"
}

download_to() {
  local url="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL "$url" -o "$dest"
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# --------- APT ----------
apt_install() {
  local pkgs=("$@")
  log "Installing packages: ${pkgs[*]}"
  $SUDO apt-get install -y "${pkgs[@]}"
}

apt_update_upgrade() {
  log "Updating apt indexes"
  $SUDO apt-get update -y
  if $DO_UPGRADE; then
    log "Upgrading system packages (this can take a while)"
    $SUDO apt-get upgrade -y
    $SUDO apt-get dist-upgrade -y || true
  fi
}

# --------- main ----------
main() {
  is_ubuntu || warn "This script was designed for Ubuntu. Continuing anyway..."
  require_cmd bash

  log "Bootstrapping DevOps environment for user: ${USER_NAME}"
  log "Arch: ${ARCH}"

  apt_update_upgrade

  # Core dependencies
  apt_install \
    ca-certificates curl wget git unzip tar gzip xz-utils \
    build-essential software-properties-common \
    gnupg lsb-release \
    python3 python3-pip \
    make \
    net-tools iproute2 dnsutils traceroute \
    openssh-client \
    jq

  if $INSTALL_DEVOPS_TOOLS; then
    install_devops_tooling
  fi

  install_zsh_ohmyzsh

  if $INSTALL_NEOVIM; then
    install_neovim_kickstart
  fi

  if $INSTALL_K8S_TOOLS; then
    install_k8s_tooling
  fi

  post_shell_notes

  ok "Done."
}

install_devops_tooling() {
  log "Installing general DevOps CLI utilities"

  # eza is often better than exa; bat is cat with wings
  apt_install \
    fzf ripgrep bat \
    direnv \
    tree \
    htop \
    tmux \
    vim \
    silversearcher-ag \
    universal-ctags

  # eza package name can vary; try eza first, fallback to exa
  if ! dpkg -s eza >/dev/null 2>&1; then
    if $SUDO apt-get install -y eza >/dev/null 2>&1; then
      ok "Installed eza"
    else
      warn "Could not install eza via apt; trying exa"
      $SUDO apt-get install -y exa || warn "exa also unavailable; skipping"
    fi
  fi

  # yq (mikefarah) – prefer latest release binary
  install_yq_latest
}

install_yq_latest() {
  log "Installing yq (mikefarah) latest"
  local os="linux"
  local arch
  case "$ARCH" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) warn "Unsupported arch for yq binary (${ARCH}), trying apt"; $SUDO apt-get install -y yq || true; return ;;
  esac

  local url
  url="$(gh_latest_url "mikefarah/yq" "/yq_${os}_${arch}\$")"
  local dest="/usr/local/bin/yq"
  $SUDO curl -fsSL "$url" -o "$dest"
  $SUDO chmod +x "$dest"
  ok "yq installed: $(yq --version || true)"
}

install_zsh_ohmyzsh() {
  log "Installing Zsh + Oh My Zsh + Powerlevel10k + plugins"

  apt_install zsh

  # Oh My Zsh (unattended)
  if [[ ! -d "${USER_HOME}/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh (unattended)"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    ok "Oh My Zsh already installed"
  fi

  local ZSH_CUSTOM="${ZSH_CUSTOM:-${USER_HOME}/.oh-my-zsh/custom}"

  # Powerlevel10k theme
  if [[ ! -d "${ZSH_CUSTOM}/themes/powerlevel10k" ]]; then
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM}/themes/powerlevel10k"
  else
    ok "powerlevel10k already present"
  fi

  # Plugins
  clone_or_update() {
    local repo="$1"
    local dest="$2"
    if [[ -d "$dest/.git" ]]; then
      (cd "$dest" && git pull --rebase --autostash) || true
    else
      git clone --depth=1 "$repo" "$dest"
    fi
  }

  clone_or_update https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
  clone_or_update https://github.com/zsh-users/zsh-syntax-highlighting "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
  clone_or_update https://github.com/Aloxaf/fzf-tab "${ZSH_CUSTOM}/plugins/fzf-tab"

  # Nerd Font (Meslo) for p10k (same recommended by p10k docs)
  install_meslo_nerd_font

  # Configure .zshrc
  local zshrc="${USER_HOME}/.zshrc"
  touch "$zshrc"

  # Set theme
  if grep -q '^ZSH_THEME=' "$zshrc"; then
    sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$zshrc"
  else
    echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$zshrc"
  fi

  # Set plugins (merge-safe: replace existing plugins line)
  if grep -q '^plugins=' "$zshrc"; then
    sed -i 's|^plugins=.*|plugins=(git sudo docker kubectl helm terraform aws fzf zsh-autosuggestions zsh-syntax-highlighting fzf-tab)|' "$zshrc"
  else
    echo 'plugins=(git sudo docker kubectl helm terraform aws fzf zsh-autosuggestions zsh-syntax-highlighting fzf-tab)' >> "$zshrc"
  fi

  # Sensible defaults
  ensure_line_in_file 'export EDITOR=nvim' "$zshrc"
  ensure_line_in_file 'export VISUAL=nvim' "$zshrc"
  ensure_line_in_file 'export PAGER=less' "$zshrc"
  ensure_line_in_file 'alias k=kubectl' "$zshrc"
  ensure_line_in_file 'alias kgp="kubectl get pods"' "$zshrc"
  ensure_line_in_file 'alias kgs="kubectl get svc"' "$zshrc"
  ensure_line_in_file 'alias kgn="kubectl get nodes"' "$zshrc"
  ensure_line_in_file 'alias tf=terraform' "$zshrc"
  ensure_line_in_file 'eval "$(direnv hook zsh)"' "$zshrc"

  # Set default shell (won't break if it fails on some environments)
  if [[ "${SHELL:-}" != "/usr/bin/zsh" && "${SHELL:-}" != "/bin/zsh" ]]; then
    log "Setting default shell to zsh (may ask for password)"
    chsh -s "$(command -v zsh)" "$USER_NAME" || warn "Could not change shell automatically. Run: chsh -s $(command -v zsh)"
  fi

  ok "Zsh stack configured"
}

install_meslo_nerd_font() {
  log "Installing Meslo Nerd Font (user-local)"
  local font_dir="${USER_HOME}/.local/share/fonts"
  mkdir -p "$font_dir"

  # Only download if not present
  local marker="${font_dir}/MesloLGS NF Regular.ttf"
  if [[ -f "$marker" ]]; then
    ok "Meslo Nerd Font already present"
    return
  fi

  local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  download_to "${base}/MesloLGS%20NF%20Regular.ttf" "${font_dir}/MesloLGS NF Regular.ttf"
  download_to "${base}/MesloLGS%20NF%20Bold.ttf" "${font_dir}/MesloLGS NF Bold.ttf"
  download_to "${base}/MesloLGS%20NF%20Italic.ttf" "${font_dir}/MesloLGS NF Italic.ttf"
  download_to "${base}/MesloLGS%20NF%20Bold%20Italic.ttf" "${font_dir}/MesloLGS NF Bold Italic.ttf"

  fc-cache -f "$font_dir" >/dev/null 2>&1 || true
  ok "Fonts installed. You may need to select 'MesloLGS NF' in your terminal profile."
}

install_neovim_kickstart() {
  log "Installing Neovim (AppImage latest) + kickstart.nvim config"

  # Install Neovim AppImage latest
  local arch
  case "$ARCH" in
    amd64) arch="x86_64" ;;
    arm64) arch="aarch64" ;;
    *) warn "Unsupported arch for Neovim AppImage (${ARCH}), installing from apt"; apt_install neovim; return ;;
  esac

  local url
  url="$(gh_latest_url "neovim/neovim" "/nvim-linux-${arch}\.appimage$")"
  local tmp="/tmp/nvim.appimage"
  download_to "$url" "$tmp"
  chmod +x "$tmp"
  $SUDO mv "$tmp" /usr/local/bin/nvim

  ok "Neovim installed: $(nvim --version | head -n 1 || true)"

  # kickstart.nvim as baseline config
  local nvim_dir="${USER_HOME}/.config/nvim"
  if [[ ! -d "$nvim_dir" ]]; then
    log "Cloning kickstart.nvim"
    git clone --depth=1 https://github.com/nvim-lua/kickstart.nvim.git "$nvim_dir"
  else
    ok "Neovim config already exists at ~/.config/nvim (skipping kickstart clone)"
  fi

  # Useful extras: make vim point to nvim
  if command -v update-alternatives >/dev/null 2>&1; then
    $SUDO update-alternatives --install /usr/bin/vim vim /usr/local/bin/nvim 60 || true
    $SUDO update-alternatives --install /usr/bin/vi vi /usr/local/bin/nvim 60 || true
  fi

  ok "Neovim configured (kickstart.nvim). First run: nvim (it will auto-install plugins)."
}

install_k8s_tooling() {
  log "Installing Kubernetes tooling"

  # kubectl from apt (snap is avoided)
  # On Ubuntu, kubectl may be in apt repos; if not, install via official kubernetes repo quickly:
  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl via apt (fallback to official repo if needed)"
    if ! $SUDO apt-get install -y kubectl >/dev/null 2>&1; then
      log "Setting up Kubernetes apt repo"
      $SUDO mkdir -p /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
      $SUDO apt-get update -y
      $SUDO apt-get install -y kubectl
    fi
  else
    ok "kubectl already installed"
  fi

  # Helm (official script)
  if ! command -v helm >/dev/null 2>&1; then
    log "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    ok "helm already installed"
  fi

  # Kustomize (latest)
  if ! command -v kustomize >/dev/null 2>&1; then
    log "Installing kustomize latest"
    local arch
    case "$ARCH" in
      amd64) arch="amd64" ;;
      arm64) arch="arm64" ;;
      *) warn "Unsupported arch for kustomize (${ARCH}), skipping"; arch="" ;;
    esac
    if [[ -n "$arch" ]]; then
      local url
      url="$(gh_latest_url "kubernetes-sigs/kustomize" "kustomize_v.*_linux_${arch}\.tar\.gz$")"
      local tgz="/tmp/kustomize.tgz"
      download_to "$url" "$tgz"
      tar -xzf "$tgz" -C /tmp
      $SUDO mv /tmp/kustomize /usr/local/bin/kustomize
      $SUDO chmod +x /usr/local/bin/kustomize
      rm -f "$tgz"
      ok "kustomize installed"
    fi
  else
    ok "kustomize already installed"
  fi

  # kubectx/kubens
  install_kubectx_kubens

  # k9s
  install_k9s_latest

  # krew + plugins
  install_krew_and_plugins

  ok "Kubernetes tooling installed"
}

install_kubectx_kubens() {
  log "Installing kubectx/kubens"
  if command -v kubectx >/dev/null 2>&1 && command -v kubens >/dev/null 2>&1; then
    ok "kubectx/kubens already installed"
    return
  fi

  # Prefer apt if available
  if $SUDO apt-get install -y kubectx >/dev/null 2>&1; then
    ok "kubectx installed via apt"
    return
  fi

  # Fallback: git clone
  local dir="${USER_HOME}/.local/share/kubectx"
  mkdir -p "$(dirname "$dir")"
  if [[ ! -d "$dir" ]]; then
    git clone --depth=1 https://github.com/ahmetb/kubectx.git "$dir"
  fi
  mkdir -p "${USER_HOME}/.local/bin"
  ln -sf "${dir}/kubectx" "${USER_HOME}/.local/bin/kubectx"
  ln -sf "${dir}/kubens"  "${USER_HOME}/.local/bin/kubens"

  ok "kubectx/kubens installed in ~/.local/bin"
}

install_k9s_latest() {
  log "Installing k9s latest"
  if command -v k9s >/dev/null 2>&1; then
    ok "k9s already installed"
    return
  fi

  local arch
  case "$ARCH" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) warn "Unsupported arch for k9s (${ARCH}), skipping"; return ;;
  esac

  local url
  url="$(gh_latest_url "derailed/k9s" "Linux_${arch}\.tar\.gz$")"
  local tgz="/tmp/k9s.tgz"
  download_to "$url" "$tgz"
  tar -xzf "$tgz" -C /tmp k9s
  $SUDO mv /tmp/k9s /usr/local/bin/k9s
  $SUDO chmod +x /usr/local/bin/k9s
  rm -f "$tgz"
  ok "k9s installed"
}

install_krew_and_plugins() {
  log "Installing krew (kubectl plugin manager) + curated plugins"

  if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl not found; skipping krew"
    return
  fi

  # Add ~/.local/bin early in PATH for this script run
  export PATH="${USER_HOME}/.local/bin:${PATH}"

  if ! kubectl krew version >/dev/null 2>&1; then
    log "Installing krew"
    local os="linux"
    local arch
    case "$ARCH" in
      amd64) arch="amd64" ;;
      arm64) arch="arm64" ;;
      *) warn "Unsupported arch for krew (${ARCH}), skipping"; return ;;
    esac

    local tmpdir
    tmpdir="$(mktemp -d)"
    local url
    url="$(gh_latest_url "kubernetes-sigs/krew" "krew-${os}_${arch}\.tar\.gz$")"
    download_to "$url" "${tmpdir}/krew.tgz"
    tar -xzf "${tmpdir}/krew.tgz" -C "$tmpdir"
    "${tmpdir}/krew-${os}_${arch}" install krew
    rm -rf "$tmpdir"
  else
    ok "krew already installed"
  fi

  # Persist krew PATH in zshrc
  local zshrc="${USER_HOME}/.zshrc"
  ensure_line_in_file 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' "$zshrc"
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

  # Curated plugin set (safe + high utility)
  # - ctx/ns: context & namespace switching
  # - neat: clean manifests
  # - whoami: see current auth
  # - view-secret: decode secrets
  # - sniff: troubleshooting (requires privileges)
  # - tree: resource tree
  # - access-matrix: RBAC quick view
  local plugins=(
    ctx
    ns
    neat
    whoami
    view-secret
    tree
    access-matrix
  )

  for p in "${plugins[@]}"; do
    if kubectl krew list 2>/dev/null | grep -qx "$p"; then
      ok "krew plugin already installed: $p"
    else
      kubectl krew install "$p" || warn "Failed to install krew plugin: $p"
    fi
  done
}

post_shell_notes() {
  cat <<EOF

${BOLD}Next steps (recommended):${RESET}

1) ${BOLD}Set your terminal font${RESET} to: ${BOLD}MesloLGS NF${RESET}
   - Needed for Powerlevel10k icons to render correctly.

2) ${BOLD}Open a new terminal${RESET} (or run: ${BOLD}zsh${RESET})
   - Powerlevel10k will start its configuration wizard on first run.

3) ${BOLD}Start Neovim${RESET}: ${BOLD}nvim${RESET}
   - kickstart.nvim will auto-install plugins on first launch.

4) Ensure ~/.local/bin is in PATH (usually already is on Ubuntu).
   If not, add to your shell profile.

EOF
}

main "$@"
