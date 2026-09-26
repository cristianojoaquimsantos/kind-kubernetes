#!/usr/bin/env bash
# Instala/valida pré-requisitos do Kind no WSL (Ubuntu)
set -euo pipefail

KIND_VERSION="${KIND_VERSION:-latest}"      # ex.: KIND_VERSION=v0.30.0
KUBECTL_VERSION="${KUBECTL_VERSION:-stable}" # ex.: KUBECTL_VERSION=v1.34.1

log()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; }

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) err "Arquitetura não suportada: $(uname -m)"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 1. Ambiente WSL / systemd
# ---------------------------------------------------------------------------
if grep -qi microsoft /proc/version; then
  log "Rodando no WSL."
else
  warn "Não parece ser WSL. Seguindo mesmo assim."
fi

if [[ "$(ps -p 1 -o comm=)" != "systemd" ]]; then
  warn "systemd não está ativo. Adicione em /etc/wsl.conf:"
  warn "  [boot]"
  warn "  systemd=true"
  warn "Depois rode no PowerShell: wsl --shutdown  e abra o WSL novamente."
fi

sudo apt-get update -y
sudo apt-get install -y ca-certificates curl

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------
DOCKER_GROUP_ADDED=false
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    log "Docker disponível: $(docker version --format '{{.Server.Version}}')"
  else
    err "O comando docker existe, mas o daemon não responde."
    err "Se usa Docker Desktop: abra-o e habilite a integração com esta distro."
    err "Se usa Docker Engine nativo: sudo systemctl start docker e confira o grupo docker."
    exit 1
  fi
else
  log "Instalando Docker Engine nativo no WSL..."
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  DOCKER_GROUP_ADDED=true
fi

# ---------------------------------------------------------------------------
# 3. kubectl
# ---------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1 && [[ "${FORCE:-0}" != "1" ]]; then
  log "kubectl já instalado: $(kubectl version --client -o yaml | grep gitVersion | awk '{print $2}')"
else
  [[ "$KUBECTL_VERSION" == "stable" ]] && KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  log "Instalando kubectl ${KUBECTL_VERSION}..."
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi

# ---------------------------------------------------------------------------
# 4. kind
# ---------------------------------------------------------------------------
if command -v kind >/dev/null 2>&1 && [[ "${FORCE:-0}" != "1" ]]; then
  log "kind já instalado: $(kind version)"
else
  if [[ "$KIND_VERSION" == "latest" ]]; then
    KIND_VERSION="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
      | grep -Po '"tag_name":\s*"\K[^"]+')"
  fi
  log "Instalando kind ${KIND_VERSION}..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
fi

# ---------------------------------------------------------------------------
# 5. Limites de inotify (clusters multi-node estouram o padrão)
# ---------------------------------------------------------------------------
log "Ajustando limites de inotify..."
sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system >/dev/null

log "Pré-requisitos concluídos."
if $DOCKER_GROUP_ADDED; then
  warn "Seu usuário foi adicionado ao grupo docker. Rode 'newgrp docker' ou reabra o terminal antes de criar o cluster."
fi
