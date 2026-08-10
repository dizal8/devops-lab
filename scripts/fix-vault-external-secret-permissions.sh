#!/usr/bin/env bash

set -uo pipefail

REPO="${HOME}/devops-lab"

VAULT_NS="vault"
VAULT_POD="vault-0"
VAULT_CONTAINER="vault"
VAULT_ADDR="http://127.0.0.1:8200"

POLICY_NAME="external-secrets-read"
ROLE_NAME="external-secrets"
POLICY_FILE="${REPO}/infrastructure/vault/policies/external-secrets-read.hcl"

BOOTSTRAP_DIR="${HOME}/.vault-bootstrap"

ESO_NS="external-secrets"
ESO_SA="vault-auth"

DEMO_NS="secret-demo"
EXTERNAL_SECRET="vault-demo-secret"
DEPLOYMENT="vault-secret-demo"
ARGO_APP="vault-secret-demo"

info() {
  printf '\n===== %s =====\n' "$*"
}

ok() {
  printf '\n[OK] %s\n' "$*"
}

error() {
  printf '\n[ERROR] %s\n' "$*" >&2
}

cleanup() {
  unset ROOT_TOKEN TEST_JWT LOGIN_TOKEN 2>/dev/null || true
}

trap cleanup EXIT

cd "$REPO" || exit 1

info "PREFLIGHT"

for cmd in kubectl python3 git find sort; do
  command -v "$cmd" >/dev/null 2>&1 || {
    error "Lipsește comanda: $cmd"
    exit 1
  }
done

test -s "$POLICY_FILE" || {
  error "Lipsește policy file: $POLICY_FILE"
  exit 1
}

kubectl get pod "$VAULT_POD" -n "$VAULT_NS" >/dev/null 2>&1 || {
  error "vault-0 nu există."
  exit 1
}

kubectl get serviceaccount "$ESO_SA" -n "$ESO_NS" >/dev/null 2>&1 || {
  error "ServiceAccount ${ESO_NS}/${ESO_SA} nu există."
  exit 1
}

info "VAULT STATUS"

STATUS_JSON="$(
  kubectl exec \
    -n "$VAULT_NS" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env VAULT_ADDR="$VAULT_ADDR" \
    vault status -format=json 2>/dev/null || true
)"

SEALED="$(
  STATUS_JSON="$STATUS_JSON" python3 -c '
import json, os
data=json.loads(os.environ["STATUS_JSON"])
print(str(data.get("sealed", True)).lower())
' 2>/dev/null || echo true
)"

if [ "$SEALED" != "false" ]; then
  error "Vault este sealed. Rulează: bash scripts/vault-unseal.sh"
  exit 1
fi

ok "Vault este unsealed."

info "BOOTSTRAP TOKEN"

INIT_FILE="$(
  find "$BOOTSTRAP_DIR" \
    -maxdepth 1 \
    -type f \
    -name 'vault-init-*.json' \
    -printf '%T@ %p\n' 2>/dev/null |
  sort -nr |
  head -n1 |
  cut -d' ' -f2-
)"

test -s "$INIT_FILE" || {
  error "Nu am găsit fișierul bootstrap."
  exit 1
}

ROOT_TOKEN="$(
  python3 -c '
import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    token=json.load(f).get("root_token")
if not token:
    raise SystemExit(1)
print(token)
' "$INIT_FILE"
)" || {
  error "Nu am putut obține root token."
  exit 1
}

vault() {
  kubectl exec \
    -n "$VAULT_NS" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env \
      VAULT_ADDR="$VAULT_ADDR" \
      VAULT_TOKEN="$ROOT_TOKEN" \
    vault "$@"
}

info "APLIC POLICY"

kubectl exec \
  -i \
  -n "$VAULT_NS" \
  -c "$VAULT_CONTAINER" \
  "$VAULT_POD" \
  -- env \
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$ROOT_TOKEN" \
  vault policy write "$POLICY_NAME" - \
  < "$POLICY_FILE" >/dev/null || {
    error "Nu am putut aplica politica."
    exit 1
}

ok "Policy ${POLICY_NAME} aplicată."

info "CONFIGUREZ ROLUL KUBERNETES"

vault write "auth/kubernetes/role/${ROLE_NAME}" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$ESO_NS" \
  audience="vault" \
  token_policies="$POLICY_NAME" \
  token_ttl="1h" \
  token_max_ttl="4h" >/dev/null || {
    error "Nu am putut configura rolul ${ROLE_NAME}."
    exit 1
}

info "VALIDEZ ROLUL"

ROLE_JSON="$(
  vault read \
    -format=json \
    "auth/kubernetes/role/${ROLE_NAME}" 2>/dev/null
)" || {
  error "Nu pot citi rolul ${ROLE_NAME}."
  exit 1
}

ROLE_JSON="$ROLE_JSON" \
POLICY_NAME="$POLICY_NAME" \
ESO_SA="$ESO_SA" \
ESO_NS="$ESO_NS" \
python3 - <<'PY'
import json
import os

data = json.loads(os.environ["ROLE_JSON"]).get("data", {})

policies = data.get("token_policies") or data.get("policies") or []
service_accounts = data.get("bound_service_account_names") or []
namespaces = data.get("bound_service_account_namespaces") or []

expected_policy = os.environ["POLICY_NAME"]
expected_sa = os.environ["ESO_SA"]
expected_ns = os.environ["ESO_NS"]

assert expected_policy in policies, f"Policy lipsă: {policies}"
assert expected_sa in service_accounts, f"SA lipsă: {service_accounts}"
assert expected_ns in namespaces, f"Namespace lipsă: {namespaces}"

print("Role validation: OK")
print("Policy:", expected_policy)
print("ServiceAccount:", expected_sa)
print("Namespace:", expected_ns)
PY

if [ "$?" -ne 0 ]; then
  error "Validarea rolului a eșuat."
  exit 1
fi

info "TEST AUTENTIFICARE KUBERNETES -> VAULT"

TEST_JWT="$(
  kubectl create token "$ESO_SA" \
    -n "$ESO_NS" \
    --audience=vault \
    --duration=10m
)" || {
  error "Nu am putut genera JWT de test."
  exit 1
}

LOGIN_JSON="$(
  kubectl exec \
    -n "$VAULT_NS" \
    -c "$VAULT_CONTAINER" \
    "$VAULT_POD" \
    -- env VAULT_ADDR="$VAULT_ADDR" \
    vault write \
      -format=json \
      auth/kubernetes/login \
      role="$ROLE_NAME" \
      jwt="$TEST_JWT" 2>/dev/null
)" || {
  error "Login Kubernetes -> Vault a eșuat."
  exit 1
}

LOGIN_TOKEN="$(
  LOGIN_JSON="$LOGIN_JSON" python3 -c '
import json,os
data=json.loads(os.environ["LOGIN_JSON"])
token=data.get("auth",{}).get("client_token")
if not token:
    raise SystemExit(1)
print(token)
'
)" || {
  error "Vault nu a emis token."
  exit 1
}

LOGIN_POLICIES="$(
  LOGIN_JSON="$LOGIN_JSON" python3 -c '
import json,os
data=json.loads(os.environ["LOGIN_JSON"])
print(",".join(data.get("auth",{}).get("policies",[])))
'
)"

echo "Token policies: $LOGIN_POLICIES"

info "TEST READ CU TOKENUL ESO"

kubectl exec \
  -n "$VAULT_NS" \
  -c "$VAULT_CONTAINER" \
  "$VAULT_POD" \
  -- env \
    VAULT_ADDR="$VAULT_ADDR" \
    VAULT_TOKEN="$LOGIN_TOKEN" \
  vault kv get \
    -format=json \
    secret/devops-lab/demo \
    >/dev/null || {
      error "Policy încă nu permite citirea secretului demo."
      exit 1
    }

ok "Token-ul ESO poate citi secret/devops-lab/demo."

unset TEST_JWT LOGIN_TOKEN ROOT_TOKEN

info "FORȚEZ RECONCILIEREA EXTERNAL SECRET"

kubectl annotate externalsecret "$EXTERNAL_SECRET" \
  -n "$DEMO_NS" \
  force-sync="$(date +%s)" \
  --overwrite >/dev/null || {
    error "Nu pot forța reconcilierea ExternalSecret."
    exit 1
  }

READY=false

for i in $(seq 1 60); do

  ESO_READY="$(
    kubectl get externalsecret "$EXTERNAL_SECRET" \
      -n "$DEMO_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null || true
  )"

  ESO_REASON="$(
    kubectl get externalsecret "$EXTERNAL_SECRET" \
      -n "$DEMO_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' \
      2>/dev/null || true
  )"

  SECRET_EXISTS=false

  kubectl get secret "$EXTERNAL_SECRET" \
    -n "$DEMO_NS" >/dev/null 2>&1 &&
    SECRET_EXISTS=true

  READY_REPLICAS="$(
    kubectl get deployment "$DEPLOYMENT" \
      -n "$DEMO_NS" \
      -o jsonpath='{.status.readyReplicas}' \
      2>/dev/null || true
  )"

  printf \
    '%02d/60 | ESO=%s | Reason=%s | Secret=%s | Deployment=%s\n' \
    "$i" \
    "${ESO_READY:-unknown}" \
    "${ESO_REASON:-unknown}" \
    "$SECRET_EXISTS" \
    "${READY_REPLICAS:-0}"

  if [ "$ESO_READY" = "True" ] &&
     [ "$SECRET_EXISTS" = true ] &&
     [ "$READY_REPLICAS" = "1" ]; then
    READY=true
    break
  fi

  sleep 5
done

info "REZULTAT"

kubectl get externalsecret "$EXTERNAL_SECRET" \
  -n "$DEMO_NS"

echo
kubectl get secret "$EXTERNAL_SECRET" \
  -n "$DEMO_NS" \
  -o custom-columns='NAME:.metadata.name,TYPE:.type'

echo
kubectl get deployment "$DEPLOYMENT" \
  -n "$DEMO_NS"

echo
kubectl get application "$ARGO_APP" \
  -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

echo
kubectl logs \
  -n "$DEMO_NS" \
  deployment/"$DEPLOYMENT" \
  --tail=10 2>/dev/null || true

if [ "$READY" != true ]; then
  echo
  kubectl describe externalsecret "$EXTERNAL_SECRET" \
    -n "$DEMO_NS" || true

  error "Fluxul nu a devenit Ready."
  exit 1
fi

ok "Vault -> ESO -> Kubernetes Secret -> Deployment FUNCȚIONEAZĂ."
