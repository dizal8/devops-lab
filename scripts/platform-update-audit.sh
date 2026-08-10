#!/usr/bin/env bash

set -uo pipefail

REPO="${HOME}/devops-lab"

info() {
  printf '\n===== %s =====\n' "$*"
}

cd "$REPO" || {
  echo "Nu pot accesa $REPO"
  exit 1
}

info "SYSTEM"

printf 'Host: '
hostname

printf 'Kernel: '
uname -r

if [ -f /etc/os-release ]; then
  grep -E '^(PRETTY_NAME)=' /etc/os-release || true
fi

info "REBOOT REQUIRED"

if [ -f /var/run/reboot-required ]; then
  echo "YES"
  cat /var/run/reboot-required || true
else
  echo "NO"
fi

info "K3S / KUBERNETES"

kubectl version || true

echo
kubectl get nodes -o wide

info "ARGO CD APPLICATIONS"

kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  | sort

info "HELM RELEASES"

helm list -A

info "HELM REPOSITORIES"

helm repo list || true

info "REFRESH HELM INDEXES"

helm repo update || true

info "INSTALLED CHARTS"

helm list -A \
  -o custom-columns='NAME:.Name,NAMESPACE:.Namespace,CHART:.Chart,APP_VERSION:.AppVersion,STATUS:.Status'

info "UPDATE CANDIDATES"

check_chart() {
  LABEL="$1"
  QUERY="$2"

  echo
  echo "--- $LABEL ---"

  helm search repo "$QUERY" \
    --versions \
    2>/dev/null |
  head -n 6 || true
}

check_chart "Vault" "hashicorp/vault"
check_chart "External Secrets" "external-secrets/external-secrets"
check_chart "cert-manager" "jetstack/cert-manager"
check_chart "Kyverno" "kyverno/kyverno"
check_chart "kube-prometheus-stack" "prometheus-community/kube-prometheus-stack"
check_chart "Loki" "grafana/loki"
check_chart "Alloy" "grafana/alloy"
check_chart "Argo CD" "argo/argo-cd"

info "NON-HEALTHY PODS"

kubectl get pods -A \
  --no-headers |
awk '
$4 != "Running" &&
$4 != "Completed" {
  print
}
' || true

info "FAILED HELM RELEASES"

helm list -A \
  --failed || true

info "PVC"

kubectl get pvc -A

info "GIT"

git status

echo
echo "Audit finalizat."
