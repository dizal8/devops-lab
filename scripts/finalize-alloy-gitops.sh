#!/usr/bin/env bash

set -uo pipefail

REPO="${HOME}/devops-lab"

ARGO_NS="argocd"
APP_NAME="alloy"

NS="logging"

EXPECTED_CHART_VERSION="1.11.1"

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

for cmd in kubectl git python3; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Lipsește comanda: $cmd"
done

test -s "$APP_FILE" ||
  fail "Lipsește $APP_FILE"

kubectl get application "$APP_NAME" \
  -n "$ARGO_NS" >/dev/null 2>&1 ||
  fail "Application alloy nu există în Argo CD."

info "VERIFIC CONFIGURAȚIA GITOPS"

CHART_VERSION="$(
  APP_FILE="$APP_FILE" python3 <<'PY'
import os
import re
from pathlib import Path

text = Path(os.environ["APP_FILE"]).read_text(encoding="utf-8")

match = re.search(
    r'chart:\s*alloy\s*\n\s*targetRevision:\s*["\']?([^"\'\s]+)',
    text
)

print(match.group(1) if match else "")
PY
)"

echo "Chart declarat în Git: ${CHART_VERSION:-unknown}"

[ "$CHART_VERSION" = "$EXPECTED_CHART_VERSION" ] ||
  fail "GitOps nu declară Alloy ${EXPECTED_CHART_VERSION}."

ok "GitOps declară Alloy ${EXPECTED_CHART_VERSION}."

info "STATUS ARGO CD"

SYNC="$(
  kubectl get application "$APP_NAME" \
    -n "$ARGO_NS" \
    -o jsonpath='{.status.sync.status}'
)"

HEALTH="$(
  kubectl get application "$APP_NAME" \
    -n "$ARGO_NS" \
    -o jsonpath='{.status.health.status}'
)"

echo "Sync:   $SYNC"
echo "Health: $HEALTH"

[ "$SYNC" = "Synced" ] ||
  fail "Alloy nu este Synced."

[ "$HEALTH" = "Healthy" ] ||
  fail "Alloy nu este Healthy."

info "DETECTEZ AUTOMAT WORKLOAD-UL ALLOY"

DEPLOYMENTS="$(
  kubectl get deployment \
    -n "$NS" \
    -l app.kubernetes.io/name=alloy \
    -o name 2>/dev/null || true
)"

DAEMONSETS="$(
  kubectl get daemonset \
    -n "$NS" \
    -l app.kubernetes.io/name=alloy \
    -o name 2>/dev/null || true
)"

STATEFULSETS="$(
  kubectl get statefulset \
    -n "$NS" \
    -l app.kubernetes.io/name=alloy \
    -o name 2>/dev/null || true
)"

WORKLOAD_COUNT="$(
  printf '%s\n%s\n%s\n' \
    "$DEPLOYMENTS" \
    "$DAEMONSETS" \
    "$STATEFULSETS" |
  sed '/^[[:space:]]*$/d' |
  wc -l
)"

[ "$WORKLOAD_COUNT" -gt 0 ] ||
  fail "Nu am detectat niciun workload Alloy."

echo
echo "Workload-uri detectate:"
printf '%s\n%s\n%s\n' \
  "$DEPLOYMENTS" \
  "$DAEMONSETS" \
  "$STATEFULSETS" |
sed '/^[[:space:]]*$/d'

info "VALIDEZ READINESS"

WORKLOADS_READY=true

if [ -n "$DEPLOYMENTS" ]; then
  while IFS= read -r resource; do
    [ -n "$resource" ] || continue

    NAME="${resource#deployment.apps/}"

    DESIRED="$(
      kubectl get deployment "$NAME" \
        -n "$NS" \
        -o jsonpath='{.spec.replicas}'
    )"

    READY="$(
      kubectl get deployment "$NAME" \
        -n "$NS" \
        -o jsonpath='{.status.readyReplicas}'
    )"

    READY="${READY:-0}"

    echo "Deployment/$NAME: ${READY}/${DESIRED}"

    if [ "$READY" != "$DESIRED" ]; then
      WORKLOADS_READY=false
    fi
  done <<< "$DEPLOYMENTS"
fi

if [ -n "$DAEMONSETS" ]; then
  while IFS= read -r resource; do
    [ -n "$resource" ] || continue

    NAME="${resource#daemonset.apps/}"

    DESIRED="$(
      kubectl get daemonset "$NAME" \
        -n "$NS" \
        -o jsonpath='{.status.desiredNumberScheduled}'
    )"

    READY="$(
      kubectl get daemonset "$NAME" \
        -n "$NS" \
        -o jsonpath='{.status.numberReady}'
    )"

    READY="${READY:-0}"

    echo "DaemonSet/$NAME: ${READY}/${DESIRED}"

    if [ "$READY" != "$DESIRED" ]; then
      WORKLOADS_READY=false
    fi
  done <<< "$DAEMONSETS"
fi

if [ -n "$STATEFULSETS" ]; then
  while IFS= read -r resource; do
    [ -n "$resource" ] || continue

    NAME="${resource#statefulset.apps/}"

    DESIRED="$(
      kubectl get statefulset "$NAME" \
        -n "$NS" \
        -o jsonpath='{.spec.replicas}'
    )"

    READY="$(
      kubectl get statefulset "$NAME" \
        -n "$NS" \
        -o jsonpath='{.status.readyReplicas}'
    )"

    READY="${READY:-0}"

    echo "StatefulSet/$NAME: ${READY}/${DESIRED}"

    if [ "$READY" != "$DESIRED" ]; then
      WORKLOADS_READY=false
    fi
  done <<< "$STATEFULSETS"
fi

[ "$WORKLOADS_READY" = true ] ||
  fail "Cel puțin un workload Alloy nu este Ready."

ok "Workload-ul Alloy este Ready."

info "IMAGINI LIVE"

kubectl get pods \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  -o jsonpath='{range .items[*]}Pod: {.metadata.name}{"\n"}{range .spec.containers[*]}  Container: {.name}{"\n"}  Image: {.image}{"\n"}{end}{end}'

echo

info "PODURI ALLOY"

kubectl get pods \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  -o wide

info "VERIFIC LOGURILE RECENTE"

kubectl logs \
  -n "$NS" \
  -l app.kubernetes.io/name=alloy \
  --all-containers \
  --tail=40 \
  2>/dev/null || true

info "PLATFORMA"

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

ok "Migrarea Alloy la GitOps este validată."
