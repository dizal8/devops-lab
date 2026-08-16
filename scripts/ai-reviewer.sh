#!/usr/bin/env bash

set -euo pipefail

REPO="${HOME}/devops-lab"
REPORT_DIR="${REPO}/ai-platform-operator/reports"

cd "$REPO"

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n===== %s =====\n' "$*"
}

command -v codex >/dev/null ||
  fail "Codex CLI lipsește."

BRANCH="$(git branch --show-current)"

case "$BRANCH" in
  ai/*)
    ;;
  *)
    fail "Reviewer-ul rulează numai pe ai/*."
    ;;
esac

mkdir -p "$REPORT_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="${REPORT_DIR}/review-${TIMESTAMP}.md"

info "REVIEW PREFLIGHT"

echo "Branch: $BRANCH"
echo "Base:   main"

git diff --check

info "CODEX REVIEWER"

PROMPT="$(
  cat ai-platform-operator/prompts/reviewer.md

  printf '\n\n# CURRENT BRANCH\n\n%s\n' "$BRANCH"

  printf '\n# REVIEW INSTRUCTIONS\n\n'
  cat <<'EOF'
Review all repository changes currently present in the working tree
and compare the branch with main.

This is a READ-ONLY review.

Do not edit files.
Do not commit.
Do not push.
Do not mutate Kubernetes.
EOF
)"

codex exec \
  --ephemeral \
  --sandbox read-only \
  --output-last-message "$REPORT" \
  "$PROMPT"

info "REVIEW REPORT"

cat "$REPORT"

info "REVIEW COMPLETE"

echo "Report: $REPORT"
