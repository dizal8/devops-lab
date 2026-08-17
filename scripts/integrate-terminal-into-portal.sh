#!/usr/bin/env bash

set -euo pipefail

REPO="${HOME}/devops-lab"
PORTAL_FILE="${REPO}/kubernetes/dizal-web/configmap.yaml"
ARGO_NS="argocd"
ARGO_APP="dizal-web"
APP_NS="default"
DEPLOYMENT="dizal-web"

cd "$REPO"

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '\n[OK] %s\n' "$*"
}

info() {
  printf '\n===== %s =====\n' "$*"
}

info "PREFLIGHT"

for cmd in git kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Lipsește comanda: $cmd"
done

[ -s "$PORTAL_FILE" ] ||
  fail "Nu există $PORTAL_FILE"

ORIGINAL_BRANCH="$(git branch --show-current)"

printf 'Branch: %s\n' "$ORIGINAL_BRANCH"

BACKUP="logs/configmap-dizal-web-$(date +%Y%m%d-%H%M%S).yaml"

cp "$PORTAL_FILE" "$BACKUP"

printf 'Backup: %s\n' "$BACKUP"

info "INTEGREZ TERMINALUL ÎN UI"

python3 <<'PY'
from pathlib import Path
import re
import sys

path = Path("kubernetes/dizal-web/configmap.yaml")
text = path.read_text()

MARKER = "DZL_TERMINAL_INTEGRATION_V1"

if MARKER in text:
    print("Integrarea există deja. Nu dublez componentele.")
    sys.exit(0)


def indent_block(block, indent):
    return "\n".join(
        indent + line if line else indent
        for line in block.strip("\n").splitlines()
    )


# ---------------------------------------------------------
# CSS
# ---------------------------------------------------------

css = r'''
/* DZL_TERMINAL_INTEGRATION_V1 */

.dzl-terminal-action {
  appearance: none;
  font: inherit;
  cursor: pointer;
}

.dzl-terminal-overlay {
  position: fixed;
  inset: 0;
  z-index: 99990;

  display: none;
  align-items: center;
  justify-content: center;

  padding: 3vh 3vw;

  background:
    radial-gradient(
      circle at top,
      rgba(30, 64, 175, .14),
      transparent 40%
    ),
    rgba(2, 8, 23, .88);

  backdrop-filter: blur(8px);
}

.dzl-terminal-overlay.open {
  display: flex;
}

.dzl-terminal-window {
  width: min(1500px, 94vw);
  height: min(900px, 88vh);

  display: flex;
  flex-direction: column;

  overflow: hidden;

  border:
    1px solid rgba(96, 165, 250, .28);

  border-radius: 16px;

  background: #080d14;

  box-shadow:
    0 30px 90px rgba(0, 0, 0, .60),
    0 0 45px rgba(59, 130, 246, .08);
}

.dzl-terminal-window.expanded {
  width: 98vw;
  height: 96vh;
}

.dzl-terminal-header {
  min-height: 54px;

  display: flex;
  align-items: center;
  justify-content: space-between;

  gap: 12px;

  padding: 9px 12px;

  border-bottom:
    1px solid rgba(148, 163, 184, .16);

  background: #0d1726;
}

.dzl-terminal-title {
  display: flex;
  align-items: center;
  gap: 10px;

  min-width: 0;

  color: #e5efff;
  font-weight: 700;
}

.dzl-terminal-title-icon {
  color: #67e8f9;
  font-family: monospace;
  font-weight: 900;
}

.dzl-private-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;

  padding: 4px 8px;

  border:
    1px solid rgba(52, 211, 153, .28);

  border-radius: 999px;

  background:
    rgba(16, 185, 129, .10);

  color: #6ee7b7;

  font-size: 10px;
  font-weight: 800;

  white-space: nowrap;
}

.dzl-terminal-controls,
.dzl-terminal-shortcuts {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: wrap;
}

.dzl-terminal-control,
.dzl-terminal-shortcut {
  appearance: none;

  border:
    1px solid rgba(148, 163, 184, .20);

  border-radius: 8px;

  background: #142033;
  color: #dbeafe;

  padding: 7px 10px;

  font: inherit;
  font-size: 11px;
  font-weight: 700;

  cursor: pointer;
}

.dzl-terminal-control:hover,
.dzl-terminal-shortcut:hover {
  border-color: #60a5fa;
  background: #172b46;
}

.dzl-terminal-control.danger:hover {
  border-color: #fb7185;
}

.dzl-terminal-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;

  gap: 8px;

  padding: 7px 10px;

  border-bottom:
    1px solid rgba(148, 163, 184, .12);

  background: #0a121e;
}

.dzl-terminal-hint {
  color: #64748b;
  font-size: 10px;
  white-space: nowrap;
}

.dzl-terminal-frame-wrap {
  flex: 1;
  min-height: 0;

  background: #000;
}

#dzl-terminal-frame {
  width: 100%;
  height: 100%;

  display: block;

  border: 0;

  background: #000;
}

.dzl-terminal-toast {
  position: fixed;

  left: 50%;
  bottom: 24px;

  z-index: 100000;

  transform:
    translate(-50%, 20px);

  opacity: 0;
  pointer-events: none;

  padding: 9px 13px;

  border:
    1px solid rgba(96, 165, 250, .28);

  border-radius: 9px;

  background: #0f1b2d;
  color: #dbeafe;

  font-size: 12px;

  transition:
    opacity .18s ease,
    transform .18s ease;
}

.dzl-terminal-toast.visible {
  opacity: 1;

  transform:
    translate(-50%, 0);
}

body.dzl-terminal-open {
  overflow: hidden;
}

@media (max-width: 720px) {

  .dzl-terminal-overlay {
    padding:
      max(6px, env(safe-area-inset-top))
      max(5px, env(safe-area-inset-right))
      max(6px, env(safe-area-inset-bottom))
      max(5px, env(safe-area-inset-left));
  }

  .dzl-terminal-window,
  .dzl-terminal-window.expanded {
    width: 97vw;
    height: 94dvh;

    border-radius: 11px;
  }

  .dzl-terminal-header {
    min-height: 48px;

    padding:
      6px 8px;
  }

  .dzl-private-pill {
    display: none;
  }

  .dzl-terminal-controls {
    gap: 3px;
  }

  .dzl-terminal-control {
    padding: 6px 8px;
    font-size: 10px;
  }

  .dzl-terminal-toolbar {
    overflow-x: auto;

    justify-content:
      flex-start;
  }

  .dzl-terminal-shortcuts {
    flex-wrap: nowrap;
  }

  .dzl-terminal-shortcut {
    white-space: nowrap;

    padding: 6px 8px;
  }

  .dzl-terminal-hint {
    display: none;
  }
}

:fullscreen .dzl-terminal-window {
  width: 100vw;
  height: 100vh;

  max-width: none;
  max-height: none;

  border: 0;
  border-radius: 0;
}
'''

style_matches = list(
    re.finditer(
        r'^(?P<indent>[ \t]*)</style>[ \t]*$',
        text,
        flags=re.MULTILINE,
    )
)

if not style_matches:
    raise RuntimeError("Nu găsesc </style> în portal.")

style = style_matches[0]
indent = style.group("indent")

insert = indent_block(css, indent) + "\n"

text = (
    text[:style.start()]
    + insert
    + text[style.start():]
)


# ---------------------------------------------------------
# QUICK ACTION BUTTONS
# ---------------------------------------------------------

actions_pattern = re.compile(
    r'^(?P<indent>[ \t]*)'
    r'(?P<line><a class="quick-action" '
    r'href="https://github\.com/dizal8/devops-lab/actions"'
    r'[^>]*>Actions</a>)[ \t]*$',
    flags=re.MULTILINE,
)

match = actions_pattern.search(text)

if not match:
    raise RuntimeError(
        "Nu găsesc butonul Actions în quick actions."
    )

indent = match.group("indent")

buttons = f'''
{indent}<button
{indent}  class="quick-action dzl-terminal-action"
{indent}  type="button"
{indent}  onclick="dzlOpenTerminal()"
{indent}>Terminal</button>
{indent}<button
{indent}  class="quick-action dzl-terminal-action"
{indent}  type="button"
{indent}  onclick="dzlOpenAIOps()"
{indent}>AI Ops</button>
'''.rstrip()

text = (
    text[:match.end()]
    + "\n"
    + buttons
    + text[match.end():]
)


# ---------------------------------------------------------
# TERMINAL OVERLAY + JAVASCRIPT
# ---------------------------------------------------------

portal_component = r'''
<!-- DZL_TERMINAL_INTEGRATION_V1 -->

<div
  id="dzl-terminal-overlay"
  class="dzl-terminal-overlay"
  aria-hidden="true"
>
  <div
    id="dzl-terminal-window"
    class="dzl-terminal-window"
  >

    <div class="dzl-terminal-header">

      <div class="dzl-terminal-title">
        <span class="dzl-terminal-title-icon">
          &gt;_
        </span>

        <span>DZL Terminal</span>

        <span class="dzl-private-pill">
          ● TAILNET PRIVATE
        </span>
      </div>

      <div class="dzl-terminal-controls">

        <button
          class="dzl-terminal-control"
          type="button"
          onclick="dzlReloadTerminal()"
        >
          Reconnect
        </button>

        <button
          class="dzl-terminal-control"
          type="button"
          onclick="dzlToggleTerminalExpand()"
        >
          Expand
        </button>

        <button
          class="dzl-terminal-control"
          type="button"
          onclick="dzlTerminalFullscreen()"
        >
          Fullscreen
        </button>

        <button
          class="dzl-terminal-control"
          type="button"
          onclick="dzlOpenTerminalSeparate()"
        >
          ↗
        </button>

        <button
          class="dzl-terminal-control danger"
          type="button"
          onclick="dzlCloseTerminal()"
        >
          ✕
        </button>

      </div>
    </div>

    <div class="dzl-terminal-toolbar">

      <div class="dzl-terminal-shortcuts">

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'cd ~/devops-lab && git status --short'
          )"
        >
          Git
        </button>

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'kubectl get pods -A'
          )"
        >
          Pods
        </button>

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'kubectl get applications -n argocd'
          )"
        >
          Argo
        </button>

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'kubectl get pod vault-0 -n vault'
          )"
        >
          Vault
        </button>

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'kubectl get externalsecret -A'
          )"
        >
          ESO
        </button>

        <button
          class="dzl-terminal-shortcut"
          onclick="dzlCopyCommand(
            'bash scripts/ai-readonly-audit.sh'
          )"
        >
          AI Audit
        </button>

      </div>

      <div class="dzl-terminal-hint">
        Commands copy to clipboard · shell stays private
      </div>

    </div>

    <div class="dzl-terminal-frame-wrap">

      <iframe
        id="dzl-terminal-frame"
        title="DZL private terminal"
        data-src="https://dzl.tail52c2d4.ts.net:8443/"
        allow="clipboard-read; clipboard-write; fullscreen"
      ></iframe>

    </div>

  </div>
</div>

<div
  id="dzl-terminal-toast"
  class="dzl-terminal-toast"
></div>

<script>
(function () {

  const TERMINAL_URL =
    "https://dzl.tail52c2d4.ts.net:8443/";

  function overlay() {
    return document.getElementById(
      "dzl-terminal-overlay"
    );
  }

  function terminalWindow() {
    return document.getElementById(
      "dzl-terminal-window"
    );
  }

  function frame() {
    return document.getElementById(
      "dzl-terminal-frame"
    );
  }

  function toast(message) {

    const element =
      document.getElementById(
        "dzl-terminal-toast"
      );

    if (!element) {
      return;
    }

    element.textContent = message;

    element.classList.add(
      "visible"
    );

    clearTimeout(
      window.dzlToastTimer
    );

    window.dzlToastTimer =
      setTimeout(
        function () {
          element.classList.remove(
            "visible"
          );
        },
        1800
      );
  }


  window.dzlOpenTerminal =
    function () {

      const terminalOverlay =
        overlay();

      const terminalFrame =
        frame();

      if (!terminalOverlay ||
          !terminalFrame) {
        return;
      }

      if (!terminalFrame.src) {
        terminalFrame.src =
          terminalFrame.dataset.src
          || TERMINAL_URL;
      }

      terminalOverlay.classList.add(
        "open"
      );

      terminalOverlay.setAttribute(
        "aria-hidden",
        "false"
      );

      document.body.classList.add(
        "dzl-terminal-open"
      );
    };


  window.dzlCloseTerminal =
    function () {

      const terminalOverlay =
        overlay();

      if (!terminalOverlay) {
        return;
      }

      terminalOverlay.classList.remove(
        "open"
      );

      terminalOverlay.setAttribute(
        "aria-hidden",
        "true"
      );

      document.body.classList.remove(
        "dzl-terminal-open"
      );
    };


  window.dzlReloadTerminal =
    function () {

      const terminalFrame =
        frame();

      if (!terminalFrame) {
        return;
      }

      terminalFrame.src =
        TERMINAL_URL
        + "?reconnect="
        + Date.now();

      toast(
        "Terminal reconnected"
      );
    };


  window.dzlToggleTerminalExpand =
    function () {

      const element =
        terminalWindow();

      if (!element) {
        return;
      }

      element.classList.toggle(
        "expanded"
      );
    };


  window.dzlTerminalFullscreen =
    async function () {

      const element =
        terminalWindow();

      if (!element) {
        return;
      }

      try {

        if (!document.fullscreenElement) {
          await element.requestFullscreen();
        } else {
          await document.exitFullscreen();
        }

      } catch (error) {

        console.error(error);

        toast(
          "Fullscreen unavailable"
        );
      }
    };


  window.dzlOpenTerminalSeparate =
    function () {

      window.open(
        TERMINAL_URL,
        "_blank",
        "noopener,noreferrer"
      );
    };


  window.dzlCopyCommand =
    async function (command) {

      try {

        await navigator.clipboard.writeText(
          command
        );

        toast(
          "Command copied"
        );

      } catch (error) {

        console.error(error);

        toast(
          command
        );
      }
    };


  window.dzlOpenAIOps =
    async function () {

      const command =
        "bash scripts/ai-readonly-audit.sh";

      try {

        await navigator.clipboard.writeText(
          command
        );

      } catch (_) {
      }

      window.dzlOpenTerminal();

      toast(
        "AI Audit command copied"
      );
    };


  document.addEventListener(
    "keydown",
    function (event) {

      if (event.key === "Escape") {
        window.dzlCloseTerminal();
      }

    }
  );


  document.addEventListener(
    "click",
    function (event) {

      const terminalOverlay =
        overlay();

      if (event.target ===
          terminalOverlay) {

        window.dzlCloseTerminal();
      }

    }
  );

})();
</script>
'''

body_matches = list(
    re.finditer(
        r'^(?P<indent>[ \t]*)</body>[ \t]*$',
        text,
        flags=re.MULTILINE,
    )
)

if not body_matches:
    raise RuntimeError(
        "Nu găsesc </body>."
    )

body = body_matches[-1]
indent = body.group("indent")

component = (
    indent_block(
        portal_component,
        indent,
    )
    + "\n"
)

text = (
    text[:body.start()]
    + component
    + text[body.start():]
)

path.write_text(text)

print(
    "Terminal integration inserted successfully."
)
PY


info "VALIDARE CONFIGMAP"

kubectl apply \
  --dry-run=client \
  -f "$PORTAL_FILE" \
  >/dev/null

git diff --check \
  -- "$PORTAL_FILE"

grep -n \
  "DZL_TERMINAL_INTEGRATION_V1" \
  "$PORTAL_FILE"

grep -n \
  "dzl.tail52c2d4.ts.net:8443" \
  "$PORTAL_FILE"

ok "ConfigMap valid."


info "GIT DIFF"

git diff \
  --stat \
  -- "$PORTAL_FILE"

git diff \
  -- "$PORTAL_FILE" \
  | sed -n '1,220p'


info "COMMIT FEATURE BRANCH"

git add \
  "$PORTAL_FILE" \
  scripts/integrate-terminal-into-portal.sh

git diff --cached --check

if ! git diff --cached --quiet; then

  git commit \
    -m "feat(portal): integrate private web terminal"

else

  echo "Nu există schimbări noi de commit."

fi

FEATURE_COMMIT="$(
  git rev-parse HEAD
)"

git push \
  -u origin \
  "$ORIGINAL_BRANCH"


info "PROMOVEZ MODIFICAREA PE MAIN"

if [ "$ORIGINAL_BRANCH" != "main" ]; then

  git switch main

  git pull \
    --ff-only \
    origin main

  if git merge-base \
       --is-ancestor \
       "$FEATURE_COMMIT" \
       HEAD; then

    echo "Commit-ul există deja pe main."

  else

    git cherry-pick \
      "$FEATURE_COMMIT"

    git push \
      origin main

  fi

  git switch \
    "$ORIGINAL_BRANCH"

else

  git push \
    origin main

fi


info "ARGO CD REFRESH"

kubectl annotate application \
  "$ARGO_APP" \
  -n "$ARGO_NS" \
  argocd.argoproj.io/refresh=hard \
  --overwrite \
  >/dev/null


info "ARGO CD SYNC"

kubectl patch application \
  "$ARGO_APP" \
  -n "$ARGO_NS" \
  --type merge \
  -p '{
    "operation": {
      "initiatedBy": {
        "username": "portal-terminal-integration"
      },
      "sync": {
        "revision": "HEAD",
        "prune": true
      }
    }
  }' \
  >/dev/null


info "AȘTEPT ARGO CD"

for i in $(seq 1 60); do

  SYNC="$(
    kubectl get application \
      "$ARGO_APP" \
      -n "$ARGO_NS" \
      -o jsonpath='{.status.sync.status}' \
      2>/dev/null || true
  )"

  HEALTH="$(
    kubectl get application \
      "$ARGO_APP" \
      -n "$ARGO_NS" \
      -o jsonpath='{.status.health.status}' \
      2>/dev/null || true
  )"

  printf \
    '%02d/60 | Sync=%s | Health=%s\n' \
    "$i" \
    "$SYNC" \
    "$HEALTH"

  if [ "$SYNC" = "Synced" ] &&
     [ "$HEALTH" = "Healthy" ]; then
    break
  fi

  sleep 3

done


info "RELOAD PORTAL PODS"

kubectl rollout restart \
  deployment/"$DEPLOYMENT" \
  -n "$APP_NS"

kubectl rollout status \
  deployment/"$DEPLOYMENT" \
  -n "$APP_NS" \
  --timeout=180s


info "FINAL PLATFORM STATE"

kubectl get application \
  "$ARGO_APP" \
  -n "$ARGO_NS" \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

kubectl get deployment \
  "$DEPLOYMENT" \
  -n "$APP_NS"

echo
echo "===== PUBLIC PORTAL ====="

if curl \
     -ksSf \
     https://app.lab01.dzl.ro/ \
     | grep -q 'DZL_TERMINAL_INTEGRATION_V1'; then

  ok "Portalul public conține noua integrare."

else

  echo \
    "[WARN] Nu am confirmat marker-ul prin curl."

fi


echo
echo "===== PRIVATE TERMINAL ====="

HTTP_CODE="$(
  curl \
    -k \
    -s \
    -o /dev/null \
    -w '%{http_code}' \
    https://dzl.tail52c2d4.ts.net:8443/
)"

echo "Terminal HTTPS: $HTTP_CODE"

[ "$HTTP_CODE" = "200" ] ||
  fail "Terminalul privat nu răspunde cu HTTP 200."


echo
echo "============================================"
echo " DZL PORTAL TERMINAL INTEGRATION COMPLETE"
echo "============================================"
echo
echo "Portal:"
echo "  https://app.lab01.dzl.ro/"
echo
echo "Private recovery terminal:"
echo "  https://dzl.tail52c2d4.ts.net:8443/"
echo
echo "Branch:"
git branch --show-current

ok "Integrarea este finalizată."
