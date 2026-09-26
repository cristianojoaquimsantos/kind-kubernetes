#!/usr/bin/env bash
# Importa um cluster Kind no Rancher
#
# Uso:
#   ./05-rancher-import.sh <kube-context> '<URL do import.yaml gerado pelo Rancher>'
#
# Exemplo:
#   ./05-rancher-import.sh kind-kind-lab \
#     'https://rancher.kind.internal:8443/v3/import/abc123_c-m-xyz.yaml'
set -euo pipefail

CONTEXT="${1:-}"
IMPORT_URL="${2:-}"
RANCHER_HOST="${RANCHER_HOST:-rancher.kind.internal}"
RANCHER_PORT="${RANCHER_PORT:-8443}"
DOCKER_NETWORK="${DOCKER_NETWORK:-kind}"
MAX_K8S_MINOR="${MAX_K8S_MINOR:-36}"   # ajuste conforme a matriz de suporte da sua versão do Rancher

log()  { echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn() { echo -e "\e[1;33m[WARN]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; }

if [[ -z "$CONTEXT" || -z "$IMPORT_URL" ]]; then
  err "Uso: $0 <kube-context> '<import-url>'"
  echo "Contextos disponíveis:"; kubectl config get-contexts -o name
  exit 1
fi

K="kubectl --context ${CONTEXT}"

# ---------------------------------------------------------------------------
# 1. Versão do Kubernetes x Rancher
# ---------------------------------------------------------------------------
MINOR="$($K version -o json | grep -A6 serverVersion | grep -Po '"minor":\s*"\K[0-9]+' | head -1)"
log "Cluster ${CONTEXT}: Kubernetes 1.${MINOR}"
if (( MINOR > MAX_K8S_MINOR )); then
  warn "Kubernetes 1.${MINOR} pode não ser suportado por esta versão do Rancher (máx. configurado: 1.${MAX_K8S_MINOR})."
  warn "Se o agente falhar, recrie o cluster com KIND_NODE_IMAGE=kindest/node:v1.${MAX_K8S_MINOR}.x"
fi

# ---------------------------------------------------------------------------
# 2. IP do gateway da rede kind (IPv4)
# ---------------------------------------------------------------------------
GATEWAY="$(docker network inspect "$DOCKER_NETWORK" \
  -f '{{range .IPAM.Config}}{{.Gateway}}{{"\n"}}{{end}}' | grep -v ':' | grep -v '^$' | head -1)"
if [[ -z "$GATEWAY" ]]; then
  err "Não foi possível obter o gateway IPv4 da rede ${DOCKER_NETWORK}."
  exit 1
fi
log "Gateway da rede ${DOCKER_NETWORK}: ${GATEWAY}"

# ---------------------------------------------------------------------------
# 3. CoreDNS: ${RANCHER_HOST} -> gateway (porta publicada ${RANCHER_PORT})
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

$K -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' > "$TMP/Corefile"

if grep -q "$RANCHER_HOST" "$TMP/Corefile"; then
  # Atualiza o IP caso o gateway tenha mudado
  sed -i -E "s|^([[:space:]]*)[0-9.]+[[:space:]]+${RANCHER_HOST//./\\.}|\1${GATEWAY} ${RANCHER_HOST}|" "$TMP/Corefile"
  log "Entrada do CoreDNS para ${RANCHER_HOST} já existe (IP conferido)."
else
  log "Adicionando ${RANCHER_HOST} -> ${GATEWAY} no CoreDNS..."
  awk -v gw="$GATEWAY" -v host="$RANCHER_HOST" '
    { print }
    /^\.:53[[:space:]]*\{/ && !done {
      print "    hosts {"
      print "       " gw " " host
      print "       fallthrough"
      print "    }"
      done=1
    }' "$TMP/Corefile" > "$TMP/Corefile.new"
  mv "$TMP/Corefile.new" "$TMP/Corefile"
fi

$K -n kube-system create configmap coredns --from-file=Corefile="$TMP/Corefile" \
  --dry-run=client -o yaml | $K -n kube-system replace -f -
$K -n kube-system rollout restart deployment/coredns >/dev/null
$K -n kube-system rollout status deployment/coredns --timeout=120s

# ---------------------------------------------------------------------------
# 4. Teste de conectividade de dentro do cluster
# ---------------------------------------------------------------------------
log "Testando https://${RANCHER_HOST}:${RANCHER_PORT}/ping a partir de um pod..."
PONG="$($K run rancher-ping --rm -i --restart=Never --quiet --image=curlimages/curl -- \
  curl -sk --max-time 10 "https://${RANCHER_HOST}:${RANCHER_PORT}/ping" 2>/dev/null || true)"
if [[ "$PONG" != *pong* ]]; then
  err "O cluster não alcança o Rancher. Resposta: '${PONG}'"
  err "Confira: docker ps (porta 0.0.0.0:${RANCHER_PORT}) e o hosts no CoreDNS."
  exit 1
fi
log "Conectividade OK."

# ---------------------------------------------------------------------------
# 5. Aplicar o manifesto de import
# ---------------------------------------------------------------------------
log "Aplicando manifesto do Rancher..."
curl --insecure -fsSL "$IMPORT_URL" | $K apply -f -

log "Aguardando cattle-cluster-agent..."
for i in $(seq 1 30); do
  $K -n cattle-system get deployment cattle-cluster-agent >/dev/null 2>&1 && break
  sleep 5
done
$K -n cattle-system rollout status deployment/cattle-cluster-agent --timeout=300s

log "Import concluído. O cluster deve ficar 'Active' no Rancher em alguns minutos."
$K -n cattle-system get pods -o wide
