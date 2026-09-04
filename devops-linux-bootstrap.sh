#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent DevOps workstation bootstrap for Ubuntu (native or WSL).

readonly SCRIPT_NAME="${0##*/}"
readonly LOCAL_BIN="${HOME}/.local/bin"
readonly BLOCK_BEGIN="# >>> devops-linux-bootstrap >>>"
readonly BLOCK_END="# <<< devops-linux-bootstrap <<<"
export PATH="${LOCAL_BIN}:${PATH}"

DO_UPGRADE=false
INSTALL_SHELL=true
INSTALL_NEOVIM=true
INSTALL_DOCKER=true
INSTALL_IAC=true
INSTALL_K8S=true
INSTALL_SECURITY=true
CLOUD=none

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --upgrade                    Upgrade installed APT packages
  --cloud <none|aws|azure|gcp> Install one cloud CLI (default: none)
  --no-shell                   Skip Zsh and its plugins
  --no-neovim                 Skip Neovim and kickstart.nvim
  --no-docker                 Skip Docker Engine and Compose
  --no-iac                    Skip Terraform, Ansible and IaC linters
  --no-k8s                    Skip Kubernetes tools
  --no-security               Skip security tools
  -h, --help                   Show this help

Examples:
  ./${SCRIPT_NAME} --cloud aws
  ./${SCRIPT_NAME} --upgrade --cloud azure --no-neovim
EOF
}

while (($#)); do
  case "$1" in
    --upgrade) DO_UPGRADE=true ;;
    --cloud)
      (($# >= 2)) || { echo "--cloud requires a value" >&2; exit 2; }
      CLOUD=$2; shift ;;
    --no-shell) INSTALL_SHELL=false ;;
    --no-neovim) INSTALL_NEOVIM=false ;;
    --no-docker) INSTALL_DOCKER=false ;;
    --no-iac) INSTALL_IAC=false ;;
    --no-k8s) INSTALL_K8S=false ;;
    --no-security) INSTALL_SECURITY=false ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$CLOUD" in none|aws|azure|gcp) ;; *) echo "Invalid cloud: $CLOUD" >&2; exit 2 ;; esac

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold || true)"; RESET="$(tput sgr0 || true)"
  RED="$(tput setaf 1 || true)"; GREEN="$(tput setaf 2 || true)"
  YELLOW="$(tput setaf 3 || true)"; BLUE="$(tput setaf 4 || true)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

log()  { printf '%s==>%s %s\n' "${BLUE}${BOLD}" "$RESET" "$*"; }
ok()   { printf '%sOK%s  %s\n' "${GREEN}${BOLD}" "$RESET" "$*"; }
warn() { printf '%sWARN%s %s\n' "${YELLOW}${BOLD}" "$RESET" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "${RED}${BOLD}" "$RESET" "$*" >&2; exit 1; }
on_error() { local ec=$?; printf '%sERROR%s line %s (exit %s): %s\n' "${RED}${BOLD}" "$RESET" "$1" "$ec" "$2" >&2; exit "$ec"; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

has() { command -v "$1" >/dev/null 2>&1; }
is_wsl() { [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

[[ -r /etc/os-release ]] || die "Cannot identify the operating system"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Supported system: Ubuntu; detected: ${PRETTY_NAME:-unknown}"

if ((EUID == 0)); then SUDO=(); else has sudo || die "sudo is required"; SUDO=(sudo); fi
case "$(dpkg --print-architecture)" in
  amd64)
    readonly DEB_ARCH=amd64 GO_ARCH=amd64 GNU_ARCH=x86_64
    readonly GITLEAKS_ARCH=x64
    ;;
  arm64)
    readonly DEB_ARCH=arm64 GO_ARCH=arm64 GNU_ARCH=aarch64
    readonly GITLEAKS_ARCH=arm64
    ;;
  *) die "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac

APT_UPDATED=false
apt_update() {
  $APT_UPDATED && return
  log "Updating APT package indexes"
  "${SUDO[@]}" apt-get update
  APT_UPDATED=true
}

apt_install() {
  local missing=() package
  for package in "$@"; do
    dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii ' || missing+=("$package")
  done
  ((${#missing[@]})) || return 0
  apt_update
  log "Installing APT packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get install -y --no-install-recommends "${missing[@]}"
}

download() { curl --fail --silent --show-error --location --retry 3 --output "$2" "$1"; }
install_binary() { "${SUDO[@]}" install -m 0755 "$1" "/usr/local/bin/$2"; }

github_asset_url() {
  curl --fail --silent --show-error --location --retry 3 \
    -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$1/releases/latest" |
    jq -er --arg pattern "$2" '.assets[] | select(.name | test($pattern)) | .browser_download_url' | head -n1
}

add_apt_key() {
  local url=$1 keyring=$2 tmp
  [[ -s "$keyring" ]] && return
  tmp="$(mktemp)"; download "$url" "$tmp"
  "${SUDO[@]}" mkdir -p "$(dirname "$keyring")"
  "${SUDO[@]}" gpg --dearmor --yes --output "$keyring" "$tmp"
  rm -f "$tmp"
}

write_root_file() {
  local destination=$1 content=$2 tmp
  tmp="$(mktemp)"; printf '%s\n' "$content" > "$tmp"
  if [[ ! -f "$destination" ]] || ! cmp -s "$tmp" "$destination"; then
    "${SUDO[@]}" install -m 0644 "$tmp" "$destination"
    APT_UPDATED=false
  fi
  rm -f "$tmp"
}

install_archive_binary() {
  local repository=$1 pattern=$2 binary=$3 format=$4 tmpdir archive
  has "$binary" && { ok "$binary already installed"; return; }
  log "Installing $binary"
  tmpdir="$(mktemp -d)"; archive="$tmpdir/archive"
  download "$(github_asset_url "$repository" "$pattern")" "$archive"
  case "$format" in
    tgz) tar -xzf "$archive" -C "$tmpdir" ;;
    zip) unzip -q "$archive" -d "$tmpdir" ;;
    *) die "Unknown archive type: $format" ;;
  esac
  [[ -f "$tmpdir/$binary" ]] || die "$binary not found in downloaded archive"
  install_binary "$tmpdir/$binary" "$binary"
  rm -rf "$tmpdir"
}

install_core() {
  apt_install ca-certificates curl wget git openssh-client gnupg lsb-release \
    unzip zip tar gzip xz-utils build-essential make shellcheck \
    python3 python3-pip python3-venv pipx jq fzf ripgrep bat tree htop btop tmux \
    direnv age dnsutils iproute2 net-tools traceroute netcat-openbsd nmap tcpdump \
    lsof strace openssl fontconfig vim silversearcher-ag universal-ctags
  mkdir -p "$LOCAL_BIN"
  [[ ! -x /usr/bin/batcat || -e "$LOCAL_BIN/bat" ]] || ln -s /usr/bin/batcat "$LOCAL_BIN/bat"
  install_eza
  install_yq
  install_uv
  has pre-commit || { log "Installing pre-commit with pipx"; pipx install pre-commit; }
  has gh || apt_install gh
  has glab || ! apt-cache show glab >/dev/null 2>&1 || apt_install glab
}

install_eza() {
  has eza && { ok "eza already installed"; return; }
  has exa && { ok "exa already installed"; return; }
  if apt-cache show eza >/dev/null 2>&1; then
    apt_install eza
  elif apt-cache show exa >/dev/null 2>&1; then
    apt_install exa
  else
    warn "eza/exa not available in APT"
  fi
}

install_yq() {
  has yq && { ok "yq already installed"; return; }
  local tmp; tmp="$(mktemp)"; log "Installing yq"
  download "$(github_asset_url mikefarah/yq "^yq_linux_${GO_ARCH}$")" "$tmp"
  install_binary "$tmp" yq; rm -f "$tmp"
}

install_uv() {
  has uv && { ok "uv already installed"; return; }
  local tmpdir archive; tmpdir="$(mktemp -d)"; archive="$tmpdir/uv.tar.gz"; log "Installing uv"
  download "$(github_asset_url astral-sh/uv "^uv-${GNU_ARCH}-unknown-linux-gnu\\.tar\\.gz$")" "$archive"
  tar -xzf "$archive" -C "$tmpdir"
  install -m 0755 "$tmpdir/uv-${GNU_ARCH}-unknown-linux-gnu/uv" "$LOCAL_BIN/uv"
  install -m 0755 "$tmpdir/uv-${GNU_ARCH}-unknown-linux-gnu/uvx" "$LOCAL_BIN/uvx"
  rm -rf "$tmpdir"
}

install_docker() {
  if has docker && docker compose version >/dev/null 2>&1; then ok "Docker and Compose already installed"; else
    log "Configuring the official Docker repository"
    add_apt_key https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.gpg
    write_root_file /etc/apt/sources.list.d/docker.list \
      "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable"
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  local user_name="${SUDO_USER:-$(id -un)}"
  if [[ "$user_name" != root ]] && ! id -nG "$user_name" | tr ' ' '\n' | grep -qx docker; then
    "${SUDO[@]}" usermod -aG docker "$user_name"
    warn "Docker group membership takes effect after a new login"
  fi
}

install_iac() {
  if ! has terraform; then
    log "Configuring the official HashiCorp repository"
    add_apt_key https://apt.releases.hashicorp.com/gpg /etc/apt/keyrings/hashicorp.gpg
    write_root_file /etc/apt/sources.list.d/hashicorp.list \
      "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${VERSION_CODENAME} main"
    apt_install terraform
  else ok "Terraform already installed"; fi
  apt_install ansible ansible-lint
  install_archive_binary terraform-linters/tflint "^tflint_linux_${GO_ARCH}\\.zip$" tflint zip
  install_archive_binary terraform-docs/terraform-docs "^terraform-docs-.*-linux-${GO_ARCH}\\.tar\\.gz$" terraform-docs tgz
}

install_kubectl() {
  has kubectl && { ok "kubectl already installed"; return; }
  local version tmp expected actual; log "Installing kubectl (verified SHA-256)"
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; tmp="$(mktemp)"
  download "https://dl.k8s.io/release/${version}/bin/linux/${GO_ARCH}/kubectl" "$tmp"
  expected="$(curl -fsSL "https://dl.k8s.io/release/${version}/bin/linux/${GO_ARCH}/kubectl.sha256")"
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "kubectl checksum mismatch"
  install_binary "$tmp" kubectl; rm -f "$tmp"
}

install_helm() {
  has helm && { ok "Helm already installed"; return; }
  local version tmpdir archive expected actual; log "Installing Helm (verified SHA-256)"
  version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -er .tag_name)"
  tmpdir="$(mktemp -d)"; archive="$tmpdir/helm.tar.gz"
  download "https://get.helm.sh/helm-${version}-linux-${GO_ARCH}.tar.gz" "$archive"
  expected="$(curl -fsSL "https://get.helm.sh/helm-${version}-linux-${GO_ARCH}.tar.gz.sha256sum" | awk '{print $1}')"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "Helm checksum mismatch"
  tar -xzf "$archive" -C "$tmpdir"; install_binary "$tmpdir/linux-${GO_ARCH}/helm" helm
  rm -rf "$tmpdir"
}

install_kubectx_kubens() {
  if has kubectx && has kubens; then
    ok "kubectx/kubens already installed"
    return
  fi
  if apt-cache show kubectx >/dev/null 2>&1; then
    apt_install kubectx
  fi
  if has kubectx && has kubens; then
    return
  fi
  local dir="$HOME/.local/share/kubectx"
  clone_once https://github.com/ahmetb/kubectx.git "$dir"
  mkdir -p "$LOCAL_BIN"
  [[ -e "$LOCAL_BIN/kubectx" ]] || ln -sf "$dir/kubectx" "$LOCAL_BIN/kubectx"
  [[ -e "$LOCAL_BIN/kubens" ]] || ln -sf "$dir/kubens" "$LOCAL_BIN/kubens"
}

install_krew_and_plugins() (
  unset GIT_ASKPASS SSH_ASKPASS
  local git_config_var
  for git_config_var in ${!GIT_CONFIG_@}; do
    unset "$git_config_var"
  done
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_TERMINAL_PROMPT=0

  has kubectl || { warn "kubectl not found; skipping krew"; return; }
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:${PATH}"
  if ! kubectl krew version >/dev/null 2>&1; then
    log "Installing krew"
    local tmpdir archive
    tmpdir="$(mktemp -d)"
    archive="$tmpdir/krew.tar.gz"
    download "$(github_asset_url kubernetes-sigs/krew "^krew-linux_${GO_ARCH}\\.tar\\.gz$")" "$archive"
    tar -xzf "$archive" -C "$tmpdir"
    "$tmpdir/krew-linux_${GO_ARCH}" install krew
    rm -rf "$tmpdir"
  else
    ok "krew already installed"
  fi
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:${PATH}"
  local plugin plugins=(ctx ns neat whoami view-secret tree access-matrix)
  for plugin in "${plugins[@]}"; do
    if kubectl krew list 2>/dev/null | grep -qx "$plugin"; then
      ok "krew plugin already installed: $plugin"
    else
      kubectl krew install "$plugin" || warn "Failed to install krew plugin: $plugin"
    fi
  done
)

install_kubernetes() {
  install_kubectl; install_helm
  install_archive_binary kubernetes-sigs/kustomize "^kustomize_v.*_linux_${GO_ARCH}\\.tar\\.gz$" kustomize tgz
  install_archive_binary derailed/k9s "^k9s_Linux_${GO_ARCH}\\.tar\\.gz$" k9s tgz
  install_kubectx_kubens
  install_krew_and_plugins
}

install_security() {
  if ! has trivy; then
    log "Configuring the official Trivy repository"
    add_apt_key https://aquasecurity.github.io/trivy-repo/deb/public.key /etc/apt/keyrings/trivy.gpg
    write_root_file /etc/apt/sources.list.d/trivy.list \
      "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main"
    apt_install trivy
  else ok "trivy already installed"; fi
  install_archive_binary gitleaks/gitleaks "^gitleaks_.*_linux_${GITLEAKS_ARCH}\\.tar\\.gz$" gitleaks tgz
  if ! has sops; then
    local tmp; tmp="$(mktemp)"; log "Installing sops"
    download "$(github_asset_url getsops/sops "^sops-v.*\\.linux\\.${GO_ARCH}$")" "$tmp"
    install_binary "$tmp" sops; rm -f "$tmp"
  else ok "sops already installed"; fi
}

install_cloud_cli() {
  case "$CLOUD" in
    none) ok "No cloud CLI selected (use --cloud aws|azure|gcp)" ;;
    aws) install_aws ;;
    azure)
      if ! has az; then
        add_apt_key https://packages.microsoft.com/keys/microsoft.asc /etc/apt/keyrings/microsoft.gpg
        write_root_file /etc/apt/sources.list.d/azure-cli.list \
          "deb [arch=${DEB_ARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${VERSION_CODENAME} main"
        apt_install azure-cli
      else ok "Azure CLI already installed"; fi ;;
    gcp)
      if ! has gcloud; then
        add_apt_key https://packages.cloud.google.com/apt/doc/apt-key.gpg /etc/apt/keyrings/cloud.google.gpg
        write_root_file /etc/apt/sources.list.d/google-cloud-sdk.list \
          "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main"
        apt_install google-cloud-cli google-cloud-cli-gke-gcloud-auth-plugin
      else ok "Google Cloud CLI already installed"; fi ;;
  esac
}

install_aws() {
  has aws && { ok "AWS CLI already installed"; return; }
  local aws_arch tmpdir archive; [[ "$DEB_ARCH" == amd64 ]] && aws_arch=x86_64 || aws_arch=aarch64
  tmpdir="$(mktemp -d)"; archive="$tmpdir/aws.zip"; log "Installing AWS CLI v2"
  download "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" "$archive"
  unzip -q "$archive" -d "$tmpdir"
  "${SUDO[@]}" "$tmpdir/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  rm -rf "$tmpdir"
}

clone_once() {
  [[ -d "$2/.git" ]] && { ok "Already installed: $2"; return; }
  [[ ! -e "$2" ]] || { warn "Preserving existing path: $2"; return; }
  git clone --depth=1 "$1" "$2"
}

configure_zshrc() {
  local zshrc="$HOME/.zshrc" tmp omz
  touch "$zshrc"
  tmp="$(mktemp)"
  awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
    $0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }
  ' "$zshrc" > "$tmp"
  if ! grep -q 'oh-my-zsh.sh' "$tmp"; then
    omz="$(mktemp)"
    cat > "$omz" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git sudo docker kubectl helm terraform aws fzf zsh-autosuggestions zsh-syntax-highlighting fzf-tab)
source "$ZSH/oh-my-zsh.sh"

EOF
    cat "$tmp" >> "$omz"
    mv "$omz" "$tmp"
  else
    if grep -q '^ZSH_THEME=' "$tmp"; then
      sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$tmp"
    else
      sed -i '/oh-my-zsh.sh/i ZSH_THEME="powerlevel10k/powerlevel10k"' "$tmp"
    fi
    if grep -q '^plugins=' "$tmp"; then
      sed -i 's|^plugins=.*|plugins=(git sudo docker kubectl helm terraform aws fzf zsh-autosuggestions zsh-syntax-highlighting fzf-tab)|' "$tmp"
    else
      sed -i '/oh-my-zsh.sh/i plugins=(git sudo docker kubectl helm terraform aws fzf zsh-autosuggestions zsh-syntax-highlighting fzf-tab)' "$tmp"
    fi
  fi
  cat >> "$tmp" <<'EOF'
# >>> devops-linux-bootstrap >>>
export PATH="$HOME/.local/bin:${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
command -v direnv >/dev/null && eval "$(direnv hook zsh)"
alias k=kubectl
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias tf=terraform
# <<< devops-linux-bootstrap <<<
EOF
  mv "$tmp" "$zshrc"
}

install_meslo_nerd_font() {
  local font_dir="$HOME/.local/share/fonts"
  local marker="${font_dir}/MesloLGS NF Regular.ttf"
  local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  mkdir -p "$font_dir"
  if [[ -f "$marker" ]]; then
    ok "Meslo Nerd Font already present"
    return
  fi
  log "Installing Meslo Nerd Font"
  download "${base}/MesloLGS%20NF%20Regular.ttf" "${font_dir}/MesloLGS NF Regular.ttf"
  download "${base}/MesloLGS%20NF%20Bold.ttf" "${font_dir}/MesloLGS NF Bold.ttf"
  download "${base}/MesloLGS%20NF%20Italic.ttf" "${font_dir}/MesloLGS NF Italic.ttf"
  download "${base}/MesloLGS%20NF%20Bold%20Italic.ttf" "${font_dir}/MesloLGS NF Bold Italic.ttf"
  fc-cache -f "$font_dir" >/dev/null 2>&1 || true
}

install_shell() {
  apt_install zsh
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh (unattended)"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    ok "Oh My Zsh already installed"
  fi
  local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  clone_once https://github.com/romkatv/powerlevel10k.git "$custom/themes/powerlevel10k"
  clone_once https://github.com/zsh-users/zsh-autosuggestions "$custom/plugins/zsh-autosuggestions"
  clone_once https://github.com/zsh-users/zsh-syntax-highlighting "$custom/plugins/zsh-syntax-highlighting"
  clone_once https://github.com/Aloxaf/fzf-tab "$custom/plugins/fzf-tab"
  install_meslo_nerd_font
  configure_zshrc
  if is_wsl; then
    warn "WSL detected: select zsh in the Windows Terminal profile if desired"
  elif [[ "${SHELL:-}" != "$(command -v zsh)" ]]; then
    chsh -s "$(command -v zsh)" "${SUDO_USER:-$(id -un)}" || warn "Run chsh manually"
  fi
}

install_neovim() {
  if ! has nvim; then
    local tmp; tmp="$(mktemp)"; log "Installing Neovim AppImage"
    download "$(github_asset_url neovim/neovim "^nvim-linux-${GNU_ARCH}\\.appimage$")" "$tmp"
    install_binary "$tmp" nvim; rm -f "$tmp"
  else ok "Neovim already installed"; fi
  clone_once https://github.com/nvim-lua/kickstart.nvim.git "$HOME/.config/nvim"
  if has update-alternatives; then
    local nvim_path
    nvim_path="$(command -v nvim)"
    "${SUDO[@]}" update-alternatives --install /usr/bin/vim vim "$nvim_path" 60 || true
    "${SUDO[@]}" update-alternatives --install /usr/bin/vi vi "$nvim_path" 60 || true
  fi
}

show_summary() {
  local commands=(git ssh curl jq yq rg fzf python3 uv pipx pre-commit shellcheck gh) missing=() item
  has eza && commands+=(eza) || has exa && commands+=(exa)
  $INSTALL_DOCKER && commands+=(docker)
  $INSTALL_IAC && commands+=(terraform ansible tflint terraform-docs)
  $INSTALL_K8S && commands+=(kubectl helm kustomize k9s kubectx kubens)
  $INSTALL_SECURITY && commands+=(trivy gitleaks sops age)
  [[ "$CLOUD" == aws ]] && commands+=(aws); [[ "$CLOUD" == azure ]] && commands+=(az); [[ "$CLOUD" == gcp ]] && commands+=(gcloud)
  $INSTALL_NEOVIM && commands+=(nvim)
  $INSTALL_SHELL && commands+=(zsh)
  for item in "${commands[@]}"; do has "$item" || missing+=("$item"); done
  ((${#missing[@]})) && warn "Not found in current PATH: ${missing[*]}" || ok "All selected tools are available"
  is_wsl && warn "Docker on WSL requires systemd or Docker Desktop WSL integration"
  printf '\nNext steps:\n'
  printf '  1) Set the terminal font to MesloLGS NF (required for Powerlevel10k icons).\n'
  printf '  2) Open a new terminal (or run zsh). Powerlevel10k will start its wizard on first run.\n'
  $INSTALL_NEOVIM && printf '  3) Start Neovim with nvim; kickstart.nvim installs plugins on first launch.\n'
  printf 'PATH, shell and Docker-group changes apply after a new login.\n'
}

main() {
  log "Ubuntu DevOps bootstrap ($(is_wsl && printf WSL || printf native), ${DEB_ARCH})"
  apt_update
  if $DO_UPGRADE; then
    log "Upgrading installed packages"
    DEBIAN_FRONTEND=noninteractive "${SUDO[@]}" apt-get upgrade -y
  fi
  install_core
  $INSTALL_DOCKER && install_docker
  $INSTALL_IAC && install_iac
  $INSTALL_K8S && install_kubernetes
  $INSTALL_SECURITY && install_security
  install_cloud_cli
  $INSTALL_SHELL && install_shell
  $INSTALL_NEOVIM && install_neovim
  show_summary
}

main "$@"
