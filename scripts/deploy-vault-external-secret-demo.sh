#!/usr/bin/env bash

set -uo pipefail

REPOSITORY="${HOME}/devops-lab"
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_CONTAINER="vault"
VAULT_ADDR="http://127.0.0.1:8200"

ESO_NAMESPACE="external-secrets"
ESO_SERVICE_ACCOUNT="vault-auth"

DEMO_NAMESPACE="secret-demo"
APP_NAME="vault-secret-demo"

MANIFEST_DIRECTORY="${REPOSITORY}/applications/vault-secret-demo"
ARGO_APPLICATION_FILE="${REPOSITORY}/clusters/lab01/applications/vault-secret-demo.yaml"
BOOTSTRAP_DIRECTORY="${HOME}/.vault-bootstrap"

LOG_PREFIX="[vault-secret-demo]"

info() {
  printf '\n[INFO] %s\n' "$*"
}

success() {
  printf '\n[OK] %s\n' "$*"
}

warning() {
  printf '\n[WARN] %s\n' "$*" >&2
}

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

cleanup() {
  unset ROOT_TOKEN DEMO_API_KEY 2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "Script întrerupt."' INT TERM

cd "$REPOSITORY" ||
  fail "Nu pot accesa repository-ul: $REPOSITORY"

info "Verific dependențele"

for command_name in kubectl git python3 openssl find sort; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "Comanda lipsește: $command_name"
done

kubectl cluster-info >/dev/null 2>&1 ||
  fail "Clusterul Kubernetes nu este accesibil."

info "Verific Vault"

kubectl get pod "$VAULT_POD" \
  -n "$VAULT_NAMESPACE" >/dev/null 2>&1 ||
  fail "Podul Vault nu există."

VAULT_SEALED="$(
  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env VAULT_ADDR="$VAULT_ADDR" \
    vault status -format=json 2>/dev/null |
  python3 -c '
import json
import sys
print(str(json.load(sys.stdin).get("sealed")).lower())
' 2>/dev/null || true
)"

[ "$VAULT_SEALED" = "false" ] ||
  fail "Vault este sealed. Rulează mai întâi scripts/vault-unseal.sh."

info "Verific autentificarea Kubernetes pentru External Secrets"

kubectl get namespace "$ESO_NAMESPACE" >/dev/null 2>&1 ||
  fail "Namespace-ul external-secrets nu există."

kubectl get serviceaccount "$ESO_SERVICE_ACCOUNT" \
  -n "$ESO_NAMESPACE" >/dev/null 2>&1 ||
  fail "ServiceAccount external-secrets/vault-auth nu există."

info "Identific fișierul bootstrap Vault"

INIT_FILE="$(
  find "$BOOTSTRAP_DIRECTORY" \
    -maxdepth 1 \
    -type f \
    -name 'vault-init-*.json' \
    -printf '%T@ %p\n' 2>/dev/null |
  sort -nr |
  head -n 1 |
  cut -d' ' -f2-
)"

[ -n "${INIT_FILE:-}" ] ||
  fail "Nu am găsit vault-init-*.json în $BOOTSTRAP_DIRECTORY."

ROOT_TOKEN="$(
  python3 - "$INIT_FILE" <<'PYTHON'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
token = data.get("root_token")

if not token:
    raise SystemExit("root_token lipsește din fișierul bootstrap.")

print(token)
PYTHON
)" || fail "Nu am putut extrage root_token."

[ -n "$ROOT_TOKEN" ] ||
  fail "Root token-ul extras este gol."

info "Verific existența KV v2 la mount-ul secret/"

KV_VERSION="$(
  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      vault secrets list -format=json 2>/dev/null |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
mount = data.get("secret/", {})
print(mount.get("options", {}).get("version", ""))
' 2>/dev/null || true
)"

if [ "$KV_VERSION" != "2" ]; then
  fail "Mount-ul secret/ nu este configurat ca KV v2."
fi

info "Generez secretul demo și îl salvez în Vault"

DEMO_API_KEY="$(openssl rand -hex 32)" ||
  fail "Nu am putut genera cheia demo."

kubectl exec \
  -n "$VAULT_NAMESPACE" \
  -c "$VAULT_CONTAINER" \
  "$VAULT_POD" \
  -- env \
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$ROOT_TOKEN" \
    vault kv put \
      secret/devops-lab/demo \
      api_key="$DEMO_API_KEY" \
      environment="lab01" \
      owner="external-secrets" \
      >/dev/null ||
  fail "Nu am putut scrie secretul în Vault."

unset DEMO_API_KEY

success "Secretul a fost scris în Vault fără a fi afișat."

info "Creez manifestele GitOps complete"

mkdir -p "$MANIFEST_DIRECTORY"
mkdir -p "$(dirname "$ARGO_APPLICATION_FILE")"

cat > "${MANIFEST_DIRECTORY}/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: secret-demo
  labels:
    app.kubernetes.io/name: vault-secret-demo
    app.kubernetes.io/part-of: devops-lab
YAML

cat > "${MANIFEST_DIRECTORY}/cluster-secret-store.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-cluster-store
  labels:
    app.kubernetes.io/name: vault-secret-demo
    app.kubernetes.io/part-of: devops-lab
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: external-secrets
          serviceAccountRef:
            name: vault-auth
            namespace: external-secrets
            audiences:
              - vault
YAML

cat > "${MANIFEST_DIRECTORY}/external-secret.yaml" <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vault-demo-secret
  namespace: secret-demo
  labels:
    app.kubernetes.io/name: vault-secret-demo
    app.kubernetes.io/part-of: devops-lab
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-cluster-store
  target:
    name: vault-demo-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: API_KEY
      remoteRef:
        key: devops-lab/demo
        property: api_key
    - secretKey: ENVIRONMENT
      remoteRef:
        key: devops-lab/demo
        property: environment
YAML

cat > "${MANIFEST_DIRECTORY}/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-secret-demo
  namespace: secret-demo
  labels:
    app.kubernetes.io/name: vault-secret-demo
    app.kubernetes.io/part-of: devops-lab
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: vault-secret-demo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: vault-secret-demo
        app.kubernetes.io/part-of: devops-lab
    spec:
      containers:
        - name: demo
          image: busybox:1.37
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -ec
          args:
            - |
              test -n "${API_KEY}"
              test "${ENVIRONMENT}" = "lab01"
              echo "Vault secret loaded successfully."
              while true; do
                sleep 3600
              done
          env:
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: vault-demo-secret
                  key: API_KEY
            - name: ENVIRONMENT
              valueFrom:
                secretKeyRef:
                  name: vault-demo-secret
                  key: ENVIRONMENT
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - test -n "${API_KEY}" && test "${ENVIRONMENT}" = "lab01"
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - test -n "${API_KEY}"
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

cat > "${MANIFEST_DIRECTORY}/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - cluster-secret-store.yaml
  - external-secret.yaml
  - deployment.yaml
YAML

cat > "${MANIFEST_DIRECTORY}/README.md" <<'MARKDOWN'
# Vault External Secret Demo

Demonstrates the following secret-delivery path:

Vault KV v2 → External Secrets Operator → Kubernetes Secret → Deployment

The secret value is never stored in Git.
MARKDOWN

cat > "$ARGO_APPLICATION_FILE" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault-secret-demo
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  labels:
    app.kubernetes.io/name: vault-secret-demo
    app.kubernetes.io/part-of: devops-lab
spec:
  project: default
  source:
    repoURL: https://github.com/dizal8/devops-lab.git
    targetRevision: main
    path: applications/vault-secret-demo
  destination:
    server: https://kubernetes.default.svc
    namespace: secret-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML

info "Validez manifestele"

kubectl kustomize "$MANIFEST_DIRECTORY" >/dev/null ||
  fail "Validarea Kustomize a eșuat."

git diff --check ||
  fail "git diff --check a identificat probleme."

info "Salvez modificările în Git"

git add \
  "$MANIFEST_DIRECTORY" \
  "$ARGO_APPLICATION_FILE"

if git diff --cached --quiet; then
  warning "Nu există modificări noi pentru commit."
else
  git commit -m "feat(secrets): integrate Vault with External Secrets" ||
    fail "Commit-ul Git a eșuat."

  git push origin main ||
    fail "Push-ul către GitHub a eșuat."
fi

info "Solicit reconcilierea aplicației root"

kubectl annotate application lab01-root \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null ||
  fail "Nu am putut solicita refresh pentru lab01-root."

info "Aștept crearea aplicației Argo CD"

APP_FOUND=false

for attempt in $(seq 1 36); do
  if kubectl get application "$APP_NAME" \
    -n argocd >/dev/null 2>&1; then
    APP_FOUND=true
    break
  fi

  printf '%02d/36 | aștept aplicația %s\n' "$attempt" "$APP_NAME"
  sleep 5
done

[ "$APP_FOUND" = true ] ||
  fail "Aplicația Argo CD $APP_NAME nu a fost creată."

info "Declanșez sincronizarea efectivă"

kubectl patch application "$APP_NAME" \
  -n argocd \
  --type merge \
  -p '{
    "operation": {
      "initiatedBy": {
        "username": "kubectl"
      },
      "sync": {
        "revision": "HEAD",
        "prune": true,
        "syncOptions": [
          "CreateNamespace=true"
        ]
      }
    }
  }' >/dev/null ||
  fail "Nu am putut declanșa sincronizarea Argo CD."

info "Aștept sincronizarea și generarea secretului"

READY=false

for attempt in $(seq 1 60); do
  APP_SYNC="$(
    kubectl get application "$APP_NAME" \
      -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true
  )"

  STORE_READY="$(
    kubectl get clustersecretstore vault-cluster-store \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || true
  )"

  EXTERNAL_SECRET_READY="$(
    kubectl get externalsecret vault-demo-secret \
      -n "$DEMO_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || true
  )"

  SECRET_EXISTS="false"
  if kubectl get secret vault-demo-secret \
    -n "$DEMO_NAMESPACE" >/dev/null 2>&1; then
    SECRET_EXISTS="true"
  fi

  DEPLOYMENT_READY="$(
    kubectl get deployment vault-secret-demo \
      -n "$DEMO_NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' \
      2>/dev/null || true
  )"

  printf '%02d/60 | Argo=%s | Store=%s | ExternalSecret=%s | Secret=%s | ReadyReplicas=%s\n' \
    "$attempt" \
    "${APP_SYNC:-unknown}" \
    "${STORE_READY:-unknown}" \
    "${EXTERNAL_SECRET_READY:-unknown}" \
    "$SECRET_EXISTS" \
    "${DEPLOYMENT_READY:-0}"

  if [ "$APP_SYNC" = "Synced" ] &&
     [ "$STORE_READY" = "True" ] &&
     [ "$EXTERNAL_SECRET_READY" = "True" ] &&
     [ "$SECRET_EXISTS" = "true" ] &&
     [ "$DEPLOYMENT_READY" = "1" ]; then
    READY=true
    break
  fi

  sleep 5
done

echo
echo "===== ARGO CD ====="

kubectl get applications \
  lab01-root \
  external-secrets \
  vault \
  "$APP_NAME" \
  -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo
echo "===== CLUSTER SECRET STORE ====="

kubectl get clustersecretstore vault-cluster-store

echo
echo "===== EXTERNAL SECRET ====="

kubectl get externalsecret vault-demo-secret \
  -n "$DEMO_NAMESPACE"

echo
echo "===== KUBERNETES SECRET ====="

kubectl get secret vault-demo-secret \
  -n "$DEMO_NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,TYPE:.type,KEYS:.data'

echo
echo "===== DEPLOYMENT ====="

kubectl get deployment vault-secret-demo \
  -n "$DEMO_NAMESPACE"

echo
echo "===== POD LOG ====="

kubectl logs \
  -n "$DEMO_NAMESPACE" \
  deployment/vault-secret-demo \
  --tail=20 2>/dev/null || true

if [ "$READY" != true ]; then
  echo
  echo "===== DIAGNOSTIC EXTERNAL SECRET ====="

  kubectl describe externalsecret vault-demo-secret \
    -n "$DEMO_NAMESPACE" 2>/dev/null || true

  echo
  echo "===== DIAGNOSTIC STORE ====="

  kubectl describe clustersecretstore vault-cluster-store \
    2>/dev/null || true

  fail "Integrarea nu a devenit Ready în intervalul de verificare."
fi

success "Vault → External Secrets → Kubernetes Secret → Deployment funcționează end-to-end."
