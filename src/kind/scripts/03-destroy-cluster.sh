#!/usr/bin/env bash
# Remove o cluster Kind
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${CONFIG:-${SCRIPT_DIR}/../kind-config.yaml}"
CLUSTER_NAME="$(grep -E '^name:' "$CONFIG" | awk '{print $2}')"

kind delete cluster --name "$CLUSTER_NAME"
