#!/usr/bin/env bash
# Remove o container do Rancher
#   PURGE=1 ./06-rancher-down.sh  -> também apaga o volume de dados e a senha de bootstrap
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
DATA_VOLUME="${DATA_VOLUME:-rancher-data}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker rm -f "$CONTAINER_NAME" 2>/dev/null && echo "Container ${CONTAINER_NAME} removido." || true

if [[ "${PURGE:-0}" == "1" ]]; then
  docker volume rm "$DATA_VOLUME" 2>/dev/null && echo "Volume ${DATA_VOLUME} removido." || true
  rm -f "${SCRIPT_DIR}/../.rancher-bootstrap"
  echo "Atenção: clusters importados continuam com o namespace cattle-system."
  echo "Para limpar: kubectl --context <ctx> delete namespace cattle-system cattle-fleet-system cattle-impersonation-system --ignore-not-found"
fi
