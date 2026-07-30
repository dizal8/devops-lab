#!/usr/bin/env bash

set -uo pipefail

REPOSITORY="${HOME}/devops-lab"
VALUES_FILE="${REPOSITORY}/infrastructure/vault/values.yaml"
EXPECTED_OLD_PATH='/v1/sys/health?standbyok=true'
NEW_PATH='/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=204&uninitcode=204'

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

cd "$REPOSITORY" ||
  fail "Nu pot accesa repository-ul: $REPOSITORY"

[ -s "$VALUES_FILE" ] ||
  fail "Fișierul Vault values lipsește sau este gol."

info "Verific configurația liveness existentă"

CURRENT_PATH="$(
  awk '
    /^[[:space:]]*livenessProbe:/ {
      in_probe = 1
      next
    }

    in_probe && /^[[:space:]]*path:/ {
      sub(/^[[:space:]]*path:[[:space:]]*/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print
      exit
    }
  ' "$VALUES_FILE"
)"

[ -n "${CURRENT_PATH:-}" ] ||
  fail "Nu am identificat server.livenessProbe.path."

printf 'Path actual: %s\n' "$CURRENT_PATH"

if [ "$CURRENT_PATH" = "$NEW_PATH" ]; then
  success "Liveness probe este deja corectată."
else
  if [ "$CURRENT_PATH" != "$EXPECTED_OLD_PATH" ]; then
    warning "Path-ul actual diferă de valoarea așteptată."
    warning "Actual: $CURRENT_PATH"
  fi

  info "Actualizez liveness probe"

  VALUES_FILE="$VALUES_FILE" NEW_PATH="$NEW_PATH" python3 <<'PYTHON'
import os
import re
from pathlib import Path

path = Path(os.environ["VALUES_FILE"])
new_path = os.environ["NEW_PATH"]

text = path.read_text(encoding="utf-8")

pattern = re.compile(
    r"(?ms)"
    r"(^[ \t]+livenessProbe:\s*\n)"
    r"(.*?)"
    r"(^[ \t]+path:\s*).*$"
)

match = pattern.search(text)

if not match:
    raise SystemExit(
        "Nu am găsit livenessProbe.path în values.yaml."
    )

replacement = (
    match.group(1)
    + match.group(2)
    + match.group(3)
    + '"'
    + new_path
    + '"'
)

updated = text[:match.start()] + replacement + text[match.end():]

path.write_text(updated, encoding="utf-8")
PYTHON

  [ "$?" -eq 0 ] ||
    fail "Modificarea values.yaml a eșuat."
fi

info "Validez rezultatul"

grep -A6 '^[[:space:]]*livenessProbe:' "$VALUES_FILE" ||
  fail "Nu pot afișa configurația liveness."

grep -Fq "sealedcode=204" "$VALUES_FILE" ||
  fail "Parametrul sealedcode=204 lipsește."

grep -Fq "uninitcode=204" "$VALUES_FILE" ||
  fail "Parametrul uninitcode=204 lipsește."

git diff --check ||
  fail "git diff --check a identificat probleme."

echo
git diff -- "$VALUES_FILE"

success "Configurația probei Vault a fost corectată local."
