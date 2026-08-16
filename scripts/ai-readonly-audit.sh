#!/usr/bin/env bash

set -uo pipefail

REPO="${HOME}/devops-lab"
PROMPT_FILE="${REPO}/ai-platform-operator/prompts/audit.md"
REPORT_DIR="${REPO}/ai-platform-operator/reports"
LOG_DIR="${REPO}/logs"

mkdir -p "$REPORT_DIR" "$LOG_DIR"

cd "$REPO" || exit 1

timestamp="$(date +%Y%m%d-%H%M%S)"

REPORT_FILE="${REPORT_DIR}/audit-${timestamp}.md"
LOG_FILE="${LOG_DIR}/ai-audit-${timestamp}.log"

echo "===== PREFLIGHT ====="

command -v codex >/dev/null 2>&1 || {
  echo "[ERROR] Codex nu este instalat."
  exit 1
}

test -s "$PROMPT_FILE" || {
  echo "[ERROR] Promptul de audit lipsește."
  exit 1
}

codex login status || {
  echo "[ERROR] Codex nu este autentificat."
  exit 1
}

echo
echo "===== GIT BEFORE ====="

BEFORE_STATUS="$(git status --porcelain)"

git status --short

echo
echo "===== CODEX READ-ONLY AUDIT ====="

PROMPT="$(cat "$PROMPT_FILE")"

codex exec \
  --ephemeral \
  --sandbox read-only \
  --output-last-message "$REPORT_FILE" \
  "$PROMPT" \
  2> >(tee "$LOG_FILE" >&2)

CODEX_STATUS=$?

echo
echo "===== CODEX EXIT ====="
echo "$CODEX_STATUS"

if [ "$CODEX_STATUS" -ne 0 ]; then
  echo "[ERROR] Codex audit a eșuat."
  exit "$CODEX_STATUS"
fi

test -s "$REPORT_FILE" || {
  echo "[ERROR] Raportul Codex este gol."
  exit 1
}

echo
echo "===== VERIFY NO MODIFICATIONS ====="

AFTER_STATUS="$(git status --porcelain)"

if [ "$BEFORE_STATUS" != "$AFTER_STATUS" ]; then
  echo "[ERROR] Working tree s-a modificat în timpul auditului."
  git status
  exit 1
fi

echo "Working tree neschimbat: OK"

echo
echo "===== REPORT ====="

cat "$REPORT_FILE"

echo
echo "===== FILES ====="
echo "Report: $REPORT_FILE"
echo "Log:    $LOG_FILE"
