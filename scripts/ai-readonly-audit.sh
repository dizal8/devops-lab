#!/usr/bin/env bash

set -euo pipefail

REPO="${HOME}/devops-lab"
PROMPT_FILE="${REPO}/ai-platform-operator/prompts/audit.md"
REPORT_DIR="${REPO}/ai-platform-operator/reports"
LOG_DIR="${REPO}/logs"

cd "$REPO"

mkdir -p "$REPORT_DIR" "$LOG_DIR"

timestamp="$(date +%Y%m%d-%H%M%S)"

REPORT_FILE="${REPORT_DIR}/audit-${timestamp}.md"
LOG_FILE="${LOG_DIR}/ai-audit-${timestamp}.log"

echo "===== PREFLIGHT ====="

for cmd in codex git; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[ERROR] Lipsește: $cmd"
    exit 1
  }
done

test -s "$PROMPT_FILE" || {
  echo "[ERROR] Lipsește promptul: $PROMPT_FILE"
  exit 1
}

codex login status

echo
echo "===== BASELINE REPOSITORY ====="

#
# Ignorăm artefactele generate de operator.
#
git status --porcelain \
  --untracked-files=all \
  -- \
  . \
  ':(exclude)ai-platform-operator/reports/**' \
  ':(exclude)logs/**' \
  > /tmp/ai-before-status

cat /tmp/ai-before-status || true

echo
echo "===== CODEX READ-ONLY AUDIT ====="

codex exec \
  --ephemeral \
  --sandbox read-only \
  --output-last-message "$REPORT_FILE" \
  "$(cat "$PROMPT_FILE")" \
  2> >(tee "$LOG_FILE" >&2)

echo
echo "===== VERIFY REPOSITORY ====="

git status --porcelain \
  --untracked-files=all \
  -- \
  . \
  ':(exclude)ai-platform-operator/reports/**' \
  ':(exclude)logs/**' \
  > /tmp/ai-after-status

if ! diff -u \
  /tmp/ai-before-status \
  /tmp/ai-after-status
then
  echo
  echo "[ERROR] Codex sau alt proces a modificat repository-ul."
  exit 1
fi

echo "[OK] Repository neschimbat."

echo
echo "===== REPORT ====="

cat "$REPORT_FILE"

echo
echo "===== RESULT ====="
echo "Report: $REPORT_FILE"
echo "Log:    $LOG_FILE"

echo
echo "[OK] Audit read-only finalizat."
