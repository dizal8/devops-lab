#!/usr/bin/env bash

set -uo pipefail

REPO="${HOME}/devops-lab"

ARGO_NS="argocd"
ROOT_APP="lab01-root"
APP_NAME="alloy"

NS="logging"
RELEASE="alloy"

NEW_VERSION="1.11.1"

VALUES_FILE="${REPO}/infrastructure/alloy/values.yaml"
APP_FILE="${REPO}/clusters/lab01/applications/alloy.yaml"

info() {
  printf '\n===== %s =====\n' "$*"
}

ok() {
  printf '\n[OK] %s\n' "$*"
}

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

cd "$REPO" || fail "Repository indisponibil."

info "PREFLIGHT"

for cmd in kubectl helm git python3; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Lipsește comanda: $cmd"
done

helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 ||
  fail "Release Alloy nu există."

kubectl get application "$ROOT_APP" \
  -n "$ARGO_NS" >/dev/null 2>&1 ||
  fail "lab01-root nu există."

info "STARE ACTUALĂ"

helm list -n "$NS" | grep -E '^alloy[[:space:]]' || true

echo
kubectl get pods \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  -o wide || true

info "VERIFIC CHART ${NEW_VERSION}"

AVAILABLE="$(
  helm search repo grafana/alloy \
    --version "$NEW_VERSION" \
    -o json 2>/dev/null || true
)"

if [ -z "$AVAILABLE" ] || [ "$AVAILABLE" = "[]" ]; then
  fail "Chart grafana/alloy ${NEW_VERSION} nu este disponibil."
fi

ok "Chart ${NEW_VERSION} disponibil."

info "EXPORT CONFIGURAȚIE HELM ACTUALĂ"

helm get values "$RELEASE" \
  -n "$NS" \
  -o yaml \
  > "$VALUES_FILE"

if [ ! -s "$VALUES_FILE" ] ||
   grep -qxF 'null' "$VALUES_FILE"; then
  printf '{}\n' > "$VALUES_FILE"
fi

info "CREEZ APPLICATION GITOPS"

cat > "$APP_FILE" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: lab01
spec:
  project: default

  sources:
    - repoURL: https://grafana.github.io/helm-charts
      chart: alloy
      targetRevision: 1.11.1
      helm:
        releaseName: alloy
        valueFiles:
          - $values/infrastructure/alloy/values.yaml

    - repoURL: https://github.com/dizal8/devops-lab.git
      targetRevision: main
      ref: values

  destination:
    server: https://kubernetes.default.svc
    namespace: logging

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - PruneLast=true
YAML

info "VALIDARE HELM"

helm template alloy grafana/alloy \
  --version "$NEW_VERSION" \
  -n "$NS" \
  -f "$VALUES_FILE" \
  >/tmp/alloy-rendered.yaml ||
  fail "helm template a eșuat."

kubectl apply \
  --dry-run=client \
  -f "$APP_FILE" \
  >/dev/null ||
  fail "Application Alloy invalid."

git diff --check ||
  fail "git diff --check a găsit probleme."

info "COMMIT + PUSH"

git add \
  "$VALUES_FILE" \
  "$APP_FILE"

if ! git diff --cached --quiet; then
  git commit \
    -m "feat(gitops): manage Alloy 1.11.1 with Argo CD" ||
    fail "Commit eșuat."

  git push origin main ||
    fail "Push eșuat."
fi

info "REFRESH ROOT APPLICATION"

kubectl annotate application "$ROOT_APP" \
  -n "$ARGO_NS" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null ||
  fail "Refresh lab01-root eșuat."

info "AȘTEPT APPLICATION ALLOY"

FOUND=false

for i in $(seq 1 40); do

  if kubectl get application "$APP_NAME" \
    -n "$ARGO_NS" >/dev/null 2>&1; then
    FOUND=true
    break
  fi

  printf '%02d/40 | aștept Application Alloy\n' "$i"

  sleep 5
done

[ "$FOUND" = true ] ||
  fail "Application Alloy nu a fost creată."

info "SYNC EFECTIV"

kubectl patch application "$APP_NAME" \
  -n "$ARGO_NS" \
  --type merge \
  -p '{
    "operation": {
      "initiatedBy": {
        "username": "kubectl"
      },
      "sync": {
        "revision": "HEAD",
        "prune": false,
        "syncOptions": [
          "CreateNamespace=true",
          "ServerSideApply=true"
        ]
      }
    }
  }' >/dev/null ||
  fail "Sync Alloy eșuat."

info "AȘTEPT HEALTHY"

READY=false

for i in $(seq 1 90); do

  SYNC="$(
    kubectl get application "$APP_NAME" \
      -n "$ARGO_NS" \
      -o jsonpath='{.status.sync.status}' \
      2>/dev/null || true
  )"

  HEALTH="$(
    kubectl get application "$APP_NAME" \
      -n "$ARGO_NS" \
      -o jsonpath='{.status.health.status}' \
      2>/dev/null || true
  )"

  DESIRED="$(
    kubectl get daemonset alloy \
      -n "$NS" \
      -o jsonpath='{.status.desiredNumberScheduled}' \
      2>/dev/null || true
  )"

  READY_DS="$(
    kubectl get daemonset alloy \
      -n "$NS" \
      -o jsonpath='{.status.numberReady}' \
      2>/dev/null || true
  )"

  printf '%02d/90 | Sync=%s | Health=%s | Alloy=%s/%s\n' \
    "$i" \
    "${SYNC:-unknown}" \
    "${HEALTH:-unknown}" \
    "${READY_DS:-0}" \
    "${DESIRED:-0}"

  if [ "$SYNC" = "Synced" ] &&
     [ "$HEALTH" = "Healthy" ] &&
     [ -n "$DESIRED" ] &&
     [ "$DESIRED" != "0" ] &&
     [ "$READY_DS" = "$DESIRED" ]; then
    READY=true
    break
  fi

  sleep 5
done

if [ "$READY" != true ]; then
  echo
  kubectl get pods -n "$NS" -o wide
  echo
  kubectl describe daemonset alloy -n "$NS" | tail -80
  fail "Alloy nu a devenit Healthy."
fi

info "VERIFIC LOGURI ALLOY"

kubectl logs \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  --tail=30 \
  2>/dev/null || true

info "VERIFICARE PLATFORMĂ"

kubectl get applications \
  alloy \
  cert-manager \
  cert-manager-resources \
  external-secrets \
  vault \
  vault-secret-demo \
  monitoring \
  -n "$ARGO_NS" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo
echo "===== ALLOY PODS ====="

kubectl get pods \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  -o wide

echo
echo "===== GIT ====="

git status

ok "Alloy 1.11.1 este gestionat prin Argo CD și funcționează."
