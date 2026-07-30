#!/usr/bin/env bash

set -uo pipefail

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_CONTAINER="vault"
VAULT_ADDRESS="http://127.0.0.1:8200"
BOOTSTRAP_DIRECTORY="${HOME}/.vault-bootstrap"

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
  unset UNSEAL_KEY 2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "Script întrerupt."' INT TERM

info "Verific dependențele"

for cmd in kubectl python3 find sort; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Comanda lipsește: $cmd"
done

kubectl cluster-info >/dev/null 2>&1 ||
  fail "Clusterul Kubernetes nu este accesibil."

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
  fail "Nu am găsit vault-init-*.json."

[ -s "$INIT_FILE" ] ||
  fail "Fișier bootstrap gol sau inaccesibil: $INIT_FILE"

printf 'Bootstrap file: %s\n' "$INIT_FILE"

info "Încarc cheia de unseal fără să o afișez"

UNSEAL_KEY="$(
  python3 - "$INIT_FILE" <<'PYTHON'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

for field in (
    "unseal_keys_b64",
    "keys_base64",
    "unseal_keys_hex",
    "keys",
):
    values = data.get(field)
    if isinstance(values, list) and values:
        print(values[0])
        raise SystemExit(0)

raise SystemExit("Cheia de unseal nu a fost găsită.")
PYTHON
)" || fail "Nu am putut extrage cheia de unseal."

[ -n "$UNSEAL_KEY" ] ||
  fail "Cheia extrasă este goală."

success "Cheia a fost încărcată în memorie."

info "Aștept ca instanța containerului Vault să fie disponibilă"

CONTAINER_READY=false

for attempt in $(seq 1 90); do
  PHASE="$(
    kubectl get pod "$VAULT_POD" \
      -n "$VAULT_NAMESPACE" \
      -o jsonpath='{.status.phase}' \
      2>/dev/null || true
  )"

  CONTAINER_ID="$(
    kubectl get pod "$VAULT_POD" \
      -n "$VAULT_NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].containerID}' \
      2>/dev/null || true
  )"

  RUNNING="$(
    kubectl get pod "$VAULT_POD" \
      -n "$VAULT_NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[?(@.name=="vault")].state.running.startedAt}' \
      2>/dev/null || true
  )"

  if [ "$PHASE" = "Running" ] &&
     [ -n "$CONTAINER_ID" ] &&
     [ -n "$RUNNING" ]; then
    CONTAINER_READY=true
    printf 'Container disponibil la încercarea %s/90.\n' "$attempt"
    break
  fi

  printf 'Aștept containerul: %s/90 phase=%s\n' \
    "$attempt" "${PHASE:-unknown}"

  sleep 2
done

[ "$CONTAINER_READY" = true ] ||
  fail "Containerul Vault nu a devenit disponibil."

info "Execut unseal"

UNSEAL_DONE=false

for attempt in $(seq 1 30); do
  if kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- \
    env VAULT_ADDR="$VAULT_ADDRESS" \
    vault operator unseal "$UNSEAL_KEY" \
    >/dev/null
  then
    UNSEAL_DONE=true
    printf 'Comanda unseal a reușit la încercarea %s/30.\n' "$attempt"
    break
  fi

  warning "Containerul s-a schimbat sau nu este încă accesibil: $attempt/30"
  sleep 2
done

unset UNSEAL_KEY

[ "$UNSEAL_DONE" = true ] ||
  fail "Comanda de unseal nu a reușit."

info "Validez starea Vault"

VALID=false

for attempt in $(seq 1 30); do
  STATUS_JSON="$(
    kubectl exec \
      -n "$VAULT_NAMESPACE" \
      -c "$VAULT_CONTAINER" \
      "$VAULT_POD" \
      -- \
      env VAULT_ADDR="$VAULT_ADDRESS" \
      vault status -format=json \
      2>/dev/null || true
  )"

  if [ -n "$STATUS_JSON" ] &&
     printf '%s' "$STATUS_JSON" |
     python3 -c '
import json
import sys

status = json.load(sys.stdin)

print("Initialized :", status.get("initialized"))
print("Sealed      :", status.get("sealed"))
print("Storage     :", status.get("storage_type"))
print("HA enabled  :", status.get("ha_enabled"))
print("HA mode     :", status.get("ha_mode", "n/a"))

raise SystemExit(0 if status.get("sealed") is False else 1)
' 
  then
    VALID=true
    break
  fi

  sleep 2
done

[ "$VALID" = true ] ||
  fail "Vault este încă sealed sau statusul nu poate fi citit."

info "Aștept readiness Kubernetes"

kubectl wait \
  -n "$VAULT_NAMESPACE" \
  --for=condition=Ready \
  "pod/$VAULT_POD" \
  --timeout=120s ||
  warning "Vault este unsealed, dar readiness nu este încă True."

kubectl annotate application vault \
  -n argocd \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null 2>&1 || true

sleep 8

info "Starea finală"

kubectl get pod "$VAULT_POD" \
  -n "$VAULT_NAMESPACE" \
  -o wide

echo

kubectl get applications \
  lab01-root \
  vault \
  external-secrets \
  -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

success "Vault a fost deblocat."
