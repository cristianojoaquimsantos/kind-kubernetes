#!/usr/bin/env bash
# Sobe um nginx com 2 réplicas espalhadas pelos workers para validar o cluster
# KEEP=1 ./02-smoke-test.sh  -> mantém os recursos após o teste
set -euo pipefail

NS=smoke-test

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: worker
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: nginx
      containers:
        - name: nginx
          image: nginx:stable-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
EOF

kubectl -n "$NS" rollout status deployment/nginx --timeout=120s
kubectl -n "$NS" get pods -o wide

echo "Testando DNS e Service de dentro do cluster..."
kubectl -n "$NS" run curl --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w "HTTP %{http_code}\n" http://nginx.${NS}.svc.cluster.local

if [[ "${KEEP:-0}" != "1" ]]; then
  kubectl delete namespace "$NS" --wait=false
  echo "Namespace ${NS} removido."
fi
