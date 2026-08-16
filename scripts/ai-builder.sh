#!/usr/bin/env bash

set -euo pipefail

REPO="${HOME}/devops-lab"
TASK_FILE="${1:-}"

cd "$REPO"

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n===== %s =====\n' "$*"
}

[ -n "$TASK_FILE" ] ||
  fail "Usage: scripts/ai-builder.sh <task-file>"

[ -s "$TASK_FILE" ] ||
  fail "Task file inexistent sau gol: $TASK_FILE"

command -v codex >/dev/null ||
  fail "Codex CLI lipsește."

command -v git >/dev/null ||
  fail "Git lipsește."

BRANCH="$(git branch --show-current)"

[ "$BRANCH" != "main" ] ||
  fail "Builder-ul nu poate rula pe main."

case "$BRANCH" in
  ai/*)
    ;;
  *)
    fail "Builder-ul poate rula numai pe branch-uri ai/*."
    ;;
esac

info "BUILDER PREFLIGHT"

echo "Branch: $BRANCH"
echo "Task:   $TASK_FILE"

#
# Permitem task-ul curent să fie tracked sau untracked,
# dar repository-ul trebuie să nu conțină alte modificări
# neașteptate în fișiere tracked.
#
if ! git diff --quiet; then
  fail "Există modificări tracked necomise înainte de Builder."
fi

if ! git diff --cached --quiet; then
  fail "Există modificări staged înainte de Builder."
fi

info "CODEX BUILDER"

PROMPT="$(
  cat ai-platform-operator/prompts/builder.md
  printf '\n\n# APPROVED TASK\n\n'
  cat "$TASK_FILE"
)"

codex exec \
  --ephemeral \
  --sandbox workspace-write \
  "$PROMPT"

info "POST-BUILD SAFETY CHECK"

CURRENT_BRANCH="$(git branch --show-current)"

[ "$CURRENT_BRANCH" = "$BRANCH" ] ||
  fail "Branch-ul s-a schimbat în timpul execuției."

case "$CURRENT_BRANCH" in
  ai/*)
    ;;
  *)
    fail "Builder-ul a ieșit din namespace-ul ai/*."
    ;;
esac

echo
git status --short

info "DIFF CHECK"

git diff --check

git diff --stat

echo
git diff

info "BUILDER COMPLETE"

echo "Builder-ul a terminat."
echo "NU fac commit."
echo "NU fac push."
echo "NU fac merge."
echo "Următorul pas este Reviewer."
