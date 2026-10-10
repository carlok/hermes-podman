#!/usr/bin/env bash
# Static checks for the hard rules in docs/DECISIONS.md. No containers needed.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok:   $*"; }
cd "$REPO_DIR" || exit 1

ref="$(image_ref)"
[[ "$ref" =~ ^docker\.io/nousresearch/hermes-agent:v[0-9]+(\.[0-9]+){2,3}@sha256:[0-9a-f]{64}$ ]] \
    || fail "compose.yaml image is not an explicit release tag + digest: $ref"
ok "compose.yaml pins $ref"

q="$(sed -n 's/^Image=//p' deploy/hermes.container)"
[ "$q" = "$ref" ] || fail "deploy/hermes.container Image=$q differs from compose.yaml"
ok "Quadlet unit pins the same image"

for key in 'ports:' 'entrypoint:' 'init:' 'shm_size:' 'HERMES_DASHBOARD' 'privileged:' 'network_mode: host'; do
    if grep -v '^[[:space:]]*#' compose.yaml | grep -qF "$key"; then fail "compose.yaml contains forbidden '$key'"; fi
done
for key in 'PublishPort=' 'Entrypoint=' 'RunInit=' 'ShmSize=' 'HERMES_DASHBOARD' 'Network=host'; do
    if grep -v '^[[:space:]]*#' deploy/hermes.container | grep -qF "$key"; then fail "Quadlet contains forbidden '$key'"; fi
done
ok "no ports, entrypoint override, init, shm_size or dashboard"

grep -qE '^restart: always|^    restart: always' compose.yaml || fail "restart policy must be 'always' (podman-restart.service)"
ok "restart: always"

for f in .env data/ backups/; do grep -qxF "$f" .gitignore || fail ".gitignore lacks $f"; done
if git ls-files --error-unmatch .env >/dev/null 2>&1; then fail ".env is tracked by git"; fi
if [ -n "$(git ls-files data backups)" ]; then fail "data/ or backups/ tracked by git"; fi
ok "secrets and state are gitignored and untracked"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x scripts/*.sh || fail "shellcheck"; ok "shellcheck clean"
else
    echo "skip: shellcheck not installed"
fi
echo "Lint passed."
