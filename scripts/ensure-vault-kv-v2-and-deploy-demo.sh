#!/usr/bin/env bash

set -uo pipefail

REPOSITORY="${HOME}/devops-lab"
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_CONTAINER="vault"
VAULT_ADDR="http://127.0.0.1:8200"
BOOTSTRAP_DIRECTORY="${HOME}/.vault-bootstrap"
DEMO_SCRIPT="${REPOSITORY}/scripts/deploy-vault-external-secret-demo.sh"

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
  unset ROOT_TOKEN 2>/dev/null || true
}

trap cleanup EXIT
trap 'fail "Script întrerupt."' INT TERM

cd "$REPOSITORY" ||
  fail "Nu pot accesa repository-ul: $REPOSITORY"

info "Verific dependențele"

for command_name in kubectl python3 find sort bash; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "Comanda lipsește: $command_name"
done

kubectl cluster-info >/dev/null 2>&1 ||
  fail "Clusterul Kubernetes nu este accesibil."

kubectl get pod "$VAULT_POD" \
  -n "$VAULT_NAMESPACE" >/dev/null 2>&1 ||
  fail "Podul Vault nu există."

info "Verific dacă Vault este unsealed"

VAULT_STATUS="$(
  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env VAULT_ADDR="$VAULT_ADDR" \
    vault status -format=json 2>/dev/null || true
)"

[ -n "$VAULT_STATUS" ] ||
  fail "Nu pot citi statusul Vault."

VAULT_SEALED="$(
  printf '%s' "$VAULT_STATUS" |
  python3 -c '
import json
import sys
print(str(json.load(sys.stdin).get("sealed")).lower())
' 2>/dev/null || true
)"

[ "$VAULT_SEALED" = "false" ] ||
  fail "Vault este sealed. Rulează scripts/vault-unseal.sh."

info "Identific ultimul fișier bootstrap Vault"

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

path = Path(sys.argv[1])

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"Fișier bootstrap invalid: {exc}")

token = data.get("root_token")

if not token:
    raise SystemExit("root_token lipsește.")

print(token)
PYTHON
)" || fail "Nu am putut extrage root token-ul."

[ -n "$ROOT_TOKEN" ] ||
  fail "Root token-ul extras este gol."

info "Inspectez mount-ul secret/"

MOUNTS_JSON="$(
  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      vault secrets list -format=json 2>/dev/null
)" || fail "Nu am putut lista secrets engines."

MOUNT_EXISTS="$(
  printf '%s' "$MOUNTS_JSON" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print("true" if "secret/" in data else "false")
'
)"

MOUNT_TYPE="$(
  printf '%s' "$MOUNTS_JSON" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("secret/", {}).get("type", ""))
'
)"

KV_VERSION="$(
  printf '%s' "$MOUNTS_JSON" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("secret/", {}).get("options", {}).get("version", ""))
'
)"

printf 'Mount existent : %s\n' "$MOUNT_EXISTS"
printf 'Mount type     : %s\n' "${MOUNT_TYPE:-none}"
printf 'KV version     : %s\n' "${KV_VERSION:-none}"

if [ "$MOUNT_EXISTS" = "false" ]; then
  info "Mount-ul secret/ lipsește. Îl creez ca KV v2."

  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      vault secrets enable \
        -path=secret \
        -version=2 \
        kv \
        >/dev/null ||
    fail "Crearea mount-ului secret/ KV v2 a eșuat."

elif [ "$MOUNT_TYPE" != "kv" ]; then
  fail "Mount-ul secret/ există, dar nu este de tip KV. Tip detectat: $MOUNT_TYPE"

elif [ "$KV_VERSION" = "2" ]; then
  success "Mount-ul secret/ este deja KV v2."

else
  info "Mount-ul secret/ este KV v1. Activez versionarea KV v2."

  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      vault kv enable-versioning secret \
      >/dev/null ||
    fail "Conversia secret/ din KV v1 în KV v2 a eșuat."
fi

info "Verific rezultatul final"

FINAL_MOUNTS_JSON="$(
  kubectl exec \
    -n "$VAULT_NAMESPACE" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
      vault secrets list -format=json 2>/dev/null
)" || fail "Nu am putut verifica mount-urile după modificare."

FINAL_TYPE="$(
  printf '%s' "$FINAL_MOUNTS_JSON" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("secret/", {}).get("type", ""))
'
)"

FINAL_VERSION="$(
  printf '%s' "$FINAL_MOUNTS_JSON" |
  python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data.get("secret/", {}).get("options", {}).get("version", ""))
'
)"

printf 'Tip final     : %s\n' "$FINAL_TYPE"
printf 'Versiune finală: %s\n' "$FINAL_VERSION"

[ "$FINAL_TYPE" = "kv" ] ||
  fail "Mount-ul secret/ nu este de tip KV după remediere."

[ "$FINAL_VERSION" = "2" ] ||
  fail "Mount-ul secret/ nu este KV v2 după remediere."

success "Mount-ul secret/ este configurat corect ca KV v2."

unset ROOT_TOKEN

[ -x "$DEMO_SCRIPT" ] ||
  fail "Scriptul demo nu există sau nu este executabil: $DEMO_SCRIPT"

info "Rulez automat integrarea Vault → External Secrets → Kubernetes"

bash "$DEMO_SCRIPT"
DEMO_STATUS=$?

[ "$DEMO_STATUS" -eq 0 ] ||
  fail "Integrarea External Secrets a eșuat cu exit code $DEMO_STATUS."

success "Configurarea KV v2 și integrarea External Secrets sunt complete."
