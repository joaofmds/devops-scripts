[CmdletBinding()]
param(
  [switch]$UpgradeAll,
  [switch]$InstallWSL,
  [switch]$InstallDocker,
  [switch]$InstallKrew,
  [switch]$SkipFonts,
  [switch]$SkipVSCode
)

$ErrorActionPreference = "Stop"

function Write-Info($m){ Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m){ Write-Host "✔  $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "⚠  $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "✖  $m" -ForegroundColor Red; exit 1 }

function Test-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Command($cmd) {
  return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
  if (Ensure-Command winget) { Write-Ok "winget OK"; return }
  Write-Warn "winget não encontrado. Abra Microsoft Store e instale 'App Installer'. Depois rode novamente."
  Die "winget é necessário"
}

function Ensure-Chocolatey {
  if (Ensure-Command choco) { Write-Ok "Chocolatey OK"; return }
  Write-Info "Instalando Chocolatey"
  Set-ExecutionPolicy Bypass -Scope Process -Force | Out-Null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  if (!(Ensure-Command choco)) { Die "Falha instalando Chocolatey" }
  Write-Ok "Chocolatey instalado"
}

function Install-WingetPkg($id) {
  Write-Info "winget install $id"
  winget install --id $id -e --accept-package-agreements --accept-source-agreements | Out-Null
}

function Upgrade-All {
  Write-Info "Atualizando pacotes (winget)"
  winget upgrade --all --accept-package-agreements --accept-source-agreements | Out-Null
  if (Ensure-Command choco) {
    Write-Info "Atualizando pacotes (choco)"
    choco upgrade all -y | Out-Null
  }
  Write-Ok "Upgrade concluído"
}

function Install-DevTools {
  Write-Info "Instalando ferramentas base"

  Install-WingetPkg "Microsoft.PowerShell"          # pwsh
  Install-WingetPkg "Microsoft.WindowsTerminal"
  Install-WingetPkg "Git.Git"

  if (-not $SkipVSCode) {
    Install-WingetPkg "Microsoft.VisualStudioCode"
  }

  Install-WingetPkg "JanDeDobbeleer.OhMyPosh"
  Install-WingetPkg "7zip.7zip"
  Install-WingetPkg "Microsoft.PowerToys"

  Write-Ok "Base OK"
}

function Install-CloudK8sTools {
  Write-Info "Instalando ferramentas Cloud/K8s/DevOps (winget/choco mix)"

  # winget ids
  $wingetIds = @(
    "Kubernetes.kubectl",
    "Helm.Helm",
    "derailed.k9s",
    "Hashicorp.Terraform",
    "Amazon.AWSCLI",
    "BurntSushi.ripgrep",
    "junegunn.fzf",
    "sharkdp.bat",
    "stedolan.jq"
  )

  foreach ($id in $wingetIds) { Install-WingetPkg $id }

  # yq e terragrunt geralmente mais fácil via choco
  Ensure-Chocolatey
  choco install -y yq | Out-Null
  choco install -y terragrunt | Out-Null
  choco install -y packer | Out-Null

  # AWS SSM plugin (útil com EC2/SSM)
  choco install -y awscli-session-manager | Out-Null

  Write-Ok "Tooling DevOps OK"
}

function Install-Fonts {
  if ($SkipFonts) { Write-Warn "Pulando fontes"; return }
  Write-Info "Instalando Nerd Font (recomendado para Oh My Posh)"
  Ensure-Chocolatey
  # Meslo Nerd Font (boa para prompts) — pode trocar por FiraCode Nerd Font
  choco install -y nerd-fonts-meslo | Out-Null
  Write-Ok "Fonte instalada. Configure no Windows Terminal: Settings > Profile > Appearance > Font face = 'MesloLGS NF'"
}

function Enable-WSL {
  Write-Info "Habilitando WSL2 + Ubuntu"
  if (-not (Test-Admin)) { Die "Rode como Administrador para instalar WSL" }

  wsl --install -d Ubuntu | Out-Null
  Write-Ok "WSL instalado (pode exigir reboot). Após reiniciar, abra Ubuntu 1x para finalizar"
}

function Install-DockerDesktop {
  if (-not (Test-Admin)) { Die "Rode como Administrador para instalar Docker Desktop" }
  Write-Info "Instalando Docker Desktop"
  Install-WingetPkg "Docker.DockerDesktop"
  Write-Ok "Docker Desktop instalado (pode exigir reboot)."
}

function Setup-PowerShellProfile {
  Write-Info "Configurando PowerShell profile (aliases, completions, prompt)"

  $profileDir = Split-Path -Parent $PROFILE
  if (!(Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }

  if (!(Test-Path $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }

  $content = @'
# -----------------------------
# DevOps PowerShell Profile
# -----------------------------
$ErrorActionPreference = "Stop"

# Oh My Posh prompt (ajuste tema se quiser)
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
  oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\jandedobbeleer.omp.json" | Invoke-Expression
}

# Quality-of-life aliases
Set-Alias k kubectl -Force
Set-Alias tf terraform -Force
Set-Alias tg terragrunt -Force

function kgp { kubectl get pods @Args }
function kgs { kubectl get svc  @Args }
function kgn { kubectl get nodes @Args }
function kga { kubectl get all  @Args }

# kubectl completion
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
  kubectl completion powershell | Out-String | Invoke-Expression
}

# helm completion
if (Get-Command helm -ErrorAction SilentlyContinue) {
  helm completion powershell | Out-String | Invoke-Expression
}

# terraform completion (se disponível)
if (Get-Command terraform -ErrorAction SilentlyContinue) {
  terraform -install-autocomplete | Out-Null
}

# fzf integration (optional)
# Install: winget install junegunn.fzf
'@

  # Idempotente: só escreve se não tiver o marker
  $marker = "# DevOps PowerShell Profile"
  $existing = Get-Content $PROFILE -ErrorAction SilentlyContinue | Out-String
  if ($existing -notmatch [regex]::Escape($marker)) {
    Add-Content -Path $PROFILE -Value "`n$content`n"
    Write-Ok "Profile atualizado: $PROFILE"
  } else {
    Write-Ok "Profile já contém configuração (skipping)"
  }
}

function Install-KrewOnWindows {
  if (-not $InstallKrew) { return }
  Write-Info "Instalando krew (kubectl plugins) no Windows"

  # Requer git + curl (já instalamos) e kubectl
  if (-not (Ensure-Command kubectl)) { Die "kubectl não encontrado; instale antes" }
  if (-not (Ensure-Command git)) { Die "git não encontrado; instale antes" }

  $krewRoot = Join-Path $env:USERPROFILE ".krew"
  $binDir   = Join-Path $env:USERPROFILE ".krew\bin"

  if (Test-Path (Join-Path $binDir "kubectl-krew.exe")) {
    Write-Ok "krew já instalado"
  } else {
    $os="windows"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $tmp = Join-Path $env:TEMP "krew"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Push-Location $tmp

    # Baixa e instala krew (latest via GitHub)
    $api = "https://api.github.com/repos/kubernetes-sigs/krew/releases/latest"
    $json = Invoke-RestMethod -Uri $api
    $asset = $json.assets | Where-Object { $_.name -match "krew-$os" -and $_.name -match $arch -and $_.name -match "\.tar\.gz$" } | Select-Object -First 1
    if (-not $asset) { Die "Não achei release do krew para $os/$arch" }

    $tgz = Join-Path $tmp "krew.tgz"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tgz | Out-Null

    # Extrai tar.gz
    tar -xzf $tgz
    $exe = Get-ChildItem -Recurse -Filter "krew-$os"*"*.exe" | Select-Object -First 1
    if (-not $exe) { Die "Executável do krew não encontrado após extração" }

    & $exe.FullName install krew | Out-Null
    Pop-Location
    Remove-Item -Recurse -Force $tmp
    Write-Ok "krew instalado"
  }

  # adiciona PATH persistente
  $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($currentPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$currentPath;$binDir", "User")
    Write-Ok "Adicionado ao PATH do usuário: $binDir (reabra o terminal)"
  }

  # plugins úteis
  $plugins = @("ctx","ns","neat","whoami","view-secret","tree","access-matrix")
  foreach ($p in $plugins) {
    try {
      kubectl krew list | Select-String -Pattern "^$p$" -Quiet | Out-Null
      if ($?) { Write-Ok "krew plugin já instalado: $p"; continue }
    } catch {}
    try {
      kubectl krew install $p | Out-Null
      Write-Ok "krew plugin instalado: $p"
    } catch {
      Write-Warn "Falha instalando plugin $p (pode ignorar se não usa)."
    }
  }
}

# -----------------------
# Execution
# -----------------------
if (-not (Test-Admin)) {
  Write-Warn "Recomendado rodar como Administrador (WSL/Docker exigem). Continuando..."
}

Ensure-Winget
if ($UpgradeAll) { Upgrade-All }

Install-DevTools
Install-Fonts
Install-CloudK8sTools
Setup-PowerShellProfile

if ($InstallWSL) { Enable-WSL }
if ($InstallDocker) { Install-DockerDesktop }
Install-KrewOnWindows

Write-Ok "Bootstrap concluído."
Write-Host ""
Write-Host "Próximos passos:" -ForegroundColor Cyan
Write-Host "1) Reabra o Windows Terminal" -ForegroundColor Cyan
Write-Host "2) Configure a fonte no perfil do terminal: MesloLGS NF" -ForegroundColor Cyan
Write-Host "3) Rode: kubectl version --client; helm version; terraform -version; k9s" -ForegroundColor Cyan
Write-Host "4) (Opcional) Habilite WSL e Docker flags se não usou: -InstallWSL -InstallDocker" -ForegroundColor Cyan