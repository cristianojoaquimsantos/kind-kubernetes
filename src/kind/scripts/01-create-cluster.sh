#!/usr/bin/env bash
# Cria o cluster Kind (1 control plane + 2 workers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-${SCRIPT_DIR}/../kind-config.yaml}"
CLUSTER_NAME="$(grep -E '^name:' "$CONFIG" | awk '{print $2}')"
CONTEXT="kind-${CLUSTER_NAME}"

log() { echo -e "\e[1;34m[INFO]\e[0m $*"; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Cluster '${CLUSTER_NAME}' já existe. Use 03-destroy-cluster.sh para recriar."
  kubectl --context "$CONTEXT" get nodes -o wide
  exit 0
fi

log "Criando cluster '${CLUSTER_NAME}' com ${CONFIG}..."
# KIND_NODE_IMAGE opcional para fixar a versão do Kubernetes, ex.:
#   KIND_NODE_IMAGE=kindest/node:v1.34.0 ./01-create-cluster.sh
kind create cluster \
  --config "$CONFIG" \
  ${KIND_NODE_IMAGE:+--image "$KIND_NODE_IMAGE"} \
  --wait 180s

kubectl config use-context "$CONTEXT" >/dev/null

log "Aguardando todos os nós ficarem Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# node-role.* não pode ser aplicado pelo kubelet (NodeRestriction), por isso via kubectl
log "Aplicando role 'worker' nos workers..."
for node in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
  kubectl label "$node" node-role.kubernetes.io/worker=worker --overwrite >/dev/null
done

kubectl get nodes -o wide
log "Cluster pronto. Contexto atual: ${CONTEXT}"
