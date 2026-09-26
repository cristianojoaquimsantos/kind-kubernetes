#!/usr/bin/env bash
# Sobe o Rancher (single node / Docker) na mesma rede Docker dos clusters Kind
set -euo pipefail

RANCHER_LINE="${RANCHER_LINE:-v2.15}"              # linha de versão (resolve o último patch)
RANCHER_VERSION="${RANCHER_VERSION:-}"             # ex.: v2.15.1 (sobrepõe RANCHER_LINE)
RANCHER_HOST="${RANCHER_HOST:-rancher.kind.internal}"
RANCHER_PORT="${RANCHER_PORT:-8443}"
CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
DATA_VOLUME="${DATA_VOLUME:-rancher-data}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="${SCRIPT_DIR}/../.rancher-bootstrap"

log()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Rede do Kind (criada pelo kind create cluster)
# ---------------------------------------------------------------------------
if ! docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
  err "Rede Docker '${DOCKER_NETWORK}' não existe. Crie o cluster Kind antes (01-create-cluster.sh)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Container já existe?
# ---------------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" != "true" ]]; then
    log "Container '${CONTAINER_NAME}' existe e está parado. Iniciando..."
    docker start "$CONTAINER_NAME" >/dev/null
  else
    log "Container '${CONTAINER_NAME}' já está em execução."
  fi
else
  # -------------------------------------------------------------------------
  # 3. Resolver versão
  # -------------------------------------------------------------------------
  if [[ -z "$RANCHER_VERSION" ]]; then
    log "Resolvendo último patch da linha ${RANCHER_LINE}..."
    RANCHER_VERSION="$(curl -fsSL "https://api.github.com/repos/rancher/rancher/releases?per_page=100" \
      | grep -Po '"tag_name":\s*"\K[^"]+' \
      | grep -E "^${RANCHER_LINE//./\\.}\.[0-9]+$" \
      | sort -V | tail -1 || true)"
    if [[ -z "$RANCHER_VERSION" ]]; then
      err "Não foi possível resolver a versão. Defina RANCHER_VERSION=vX.Y.Z manualmente."
      exit 1
    fi
  fi
  log "Versão do Rancher: ${RANCHER_VERSION}"

  # -------------------------------------------------------------------------
  # 4. Senha de bootstrap
  # -------------------------------------------------------------------------
  if [[ -f "$SECRET_FILE" ]]; then
    BOOTSTRAP_PASSWORD="$(cat "$SECRET_FILE")"
  else
    # pipefail desligado só aqui: o 'tr' recebe SIGPIPE quando o 'head' fecha o pipe
    BOOTSTRAP_PASSWORD="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
    echo "$BOOTSTRAP_PASSWORD" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  fi

  # -------------------------------------------------------------------------
  # 5. Subir o container
  #    - rede 'kind': mesma bridge dos nós, evita bloqueio entre redes Docker
  #    - porta publicada em 0.0.0.0 para ser alcançável pelo gateway da rede kind
  # -------------------------------------------------------------------------
  log "Criando container '${CONTAINER_NAME}'..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --hostname "$RANCHER_HOST" \
    --restart unless-stopped \
    --privileged \
    --network "$DOCKER_NETWORK" \
    -p "0.0.0.0:${RANCHER_PORT}:443" \
    -v "${DATA_VOLUME}:/var/lib/rancher" \
    -e CATTLE_BOOTSTRAP_PASSWORD="$BOOTSTRAP_PASSWORD" \
    "rancher/rancher:${RANCHER_VERSION}" >/dev/null
fi

# ---------------------------------------------------------------------------
# 6. Resolução de nome no WSL
# ---------------------------------------------------------------------------
if ! grep -qE "[[:space:]]${RANCHER_HOST}([[:space:]]|$)" /etc/hosts; then
  log "Adicionando ${RANCHER_HOST} ao /etc/hosts do WSL..."
  echo "127.0.0.1 ${RANCHER_HOST}" | sudo tee -a /etc/hosts >/dev/null
fi

# ---------------------------------------------------------------------------
# 7. Aguardar o Rancher responder
# ---------------------------------------------------------------------------
log "Aguardando o Rancher inicializar (pode levar alguns minutos)..."
for i in $(seq 1 60); do
  if [[ "$(curl -sk --max-time 3 "https://127.0.0.1:${RANCHER_PORT}/ping" || true)" == "pong" ]]; then
    break
  fi
  if [[ "$i" == "60" ]]; then
    err "Rancher não respondeu em 5 minutos. Verifique: docker logs -f ${CONTAINER_NAME}"
    exit 1
  fi
  sleep 5
done

echo
log "Rancher pronto."
echo "  URL (Windows e WSL): https://${RANCHER_HOST}:${RANCHER_PORT}"
if [[ -f "$SECRET_FILE" ]]; then
  echo "  Senha de bootstrap:  $(cat "$SECRET_FILE")"
fi
echo
warn "No primeiro login, confirme a Server URL exatamente como: https://${RANCHER_HOST}:${RANCHER_PORT}"
