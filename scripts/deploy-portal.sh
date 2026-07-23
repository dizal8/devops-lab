#!/usr/bin/env bash
set -Eeuo pipefail

REPO="$HOME/devops-lab"
FILE="kubernetes/dizal-web/configmap.yaml"
APP="dizal-web"
NAMESPACE="default"
ARGO_NAMESPACE="argocd"
MARKER="${1:-DZL DevOps Platform}"

cd "$REPO"

echo "1/7 Validating portal file..."
test -s "$FILE"
grep -q "$MARKER" "$FILE" || {
  echo "ERROR: Marker not found in $FILE: $MARKER"
  exit 1
}

echo "2/7 Showing changes..."
git diff -- "$FILE"

if git diff --quiet -- "$FILE"; then
  echo "No uncommitted portal changes detected."
else
  echo "3/7 Committing and pushing..."
  git add "$FILE"
  git commit -m "Update DZL platform portal"
  git push origin main
fi

LOCAL_COMMIT="$(git rev-parse HEAD)"
echo "Local commit: $LOCAL_COMMIT"

echo "4/7 Forcing Argo CD repository refresh..."
kubectl annotate application "$APP" \
  -n "$ARGO_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "Waiting for Argo CD synchronization..."
for attempt in $(seq 1 36); do
  SYNC="$(kubectl get application "$APP" -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.status.sync.status}')"

  HEALTH="$(kubectl get application "$APP" -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.status.health.status}')"

  REVISION="$(kubectl get application "$APP" -n "$ARGO_NAMESPACE" \
    -o jsonpath='{.status.sync.revision}')"

  echo "Attempt $attempt: sync=$SYNC health=$HEALTH revision=$REVISION"

  if [[ "$SYNC" == "Synced" &&
        "$HEALTH" == "Healthy" &&
        "$REVISION" == "$LOCAL_COMMIT" ]]; then
    break
  fi

  if [[ "$attempt" -eq 36 ]]; then
    echo "ERROR: Argo CD did not synchronize commit $LOCAL_COMMIT"
    exit 1
  fi

  sleep 5
done

echo "5/7 Verifying live ConfigMap..."
kubectl get configmap dizal-web-content \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.index\.html}' \
  | grep -q "$MARKER" || {
    echo "ERROR: Marker missing from live ConfigMap."
    exit 1
  }

echo "6/7 Restarting deployment because ConfigMap uses subPath..."
kubectl rollout restart deployment/"$APP" -n "$NAMESPACE"
kubectl rollout status deployment/"$APP" \
  -n "$NAMESPACE" \
  --timeout=180s

echo "7/7 Verifying HTML served through Traefik..."
for attempt in $(seq 1 20); do
  if curl -fsS \
    -H "Host: dzl.ro" \
    http://192.168.0.102 \
    | grep -q "$MARKER"; then

    echo
    echo "SUCCESS: Portal deployed from Git commit $LOCAL_COMMIT"
    echo "Open: http://dzl.ro"
    exit 0
  fi

  sleep 3
done

echo "ERROR: New HTML is not being served."
exit 1
