# shellcheck shell=bash disable=SC2034  # variables are used by the scripts that source this file
# Shared helpers. Sourced by the other scripts; not executable on its own.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="$REPO_DIR/data"
BACKUP_DIR="$REPO_DIR/backups"
CONTAINER=hermes
COMPOSE="${COMPOSE:-podman-compose}"
# Must match compose.yaml (userns_mode / user).
USERNS="keep-id:uid=10000,gid=10000"

# The pinned image reference, read from compose.yaml so there is one source.
image_ref() {
    sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$REPO_DIR/compose.yaml" | sed -n 1p
}

# Version tag part of the image reference (e.g. v0.21.6).
image_tag() {
    local ref; ref="$(image_ref)"; ref="${ref%@*}"; echo "${ref##*:}"
}

is_running() {
    [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ]
}

compose() {
    (cd "$REPO_DIR" && "$COMPOSE" "$@")
}

ensure_env_file() {
    if [ ! -f "$REPO_DIR/.env" ]; then
        cp "$REPO_DIR/.env.example" "$REPO_DIR/.env"
        chmod 600 "$REPO_DIR/.env"
        echo "Created .env from .env.example"
    fi
}

ensure_data_dir() {
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
}

# One-off container with the same image, mapping and mount as the service.
# Usage: run_oneoff [podman run options...] -- [hermes args...]
run_oneoff() {
    local opts=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
    [ "${1:-}" = "--" ] && shift
    podman run --rm "${opts[@]}" \
        --userns "$USERNS" --user 0:0 \
        --env-file "$REPO_DIR/.env" \
        -v "$DATA_DIR:/opt/data" \
        "$(image_ref)" "$@"
}

# True when the Quadlet unit (deploy/hermes.container) manages the container.
quadlet_active() {
    systemctl --user is-active --quiet hermes.service 2>/dev/null
}

# Stop/start the container through whoever owns it: systemd for Quadlet
# (its container is --rm and Restart=always would fight `podman stop`),
# podman otherwise.
stop_hermes() {
    if quadlet_active; then systemctl --user stop hermes.service
    else podman_stop; fi
}

# `podman stop` that tolerates a failed network cleanup once the container is
# really stopped. Podman 5 on Ubuntu 26.04 (rootless, pasta) can exit 125 with
# "rootless netns: kill network process: permission denied" after a clean stop.
podman_stop() {
    if ! podman stop -t 30 "$CONTAINER" >/dev/null; then
        is_running && return 1
        echo "note: container stopped; ignoring podman's network cleanup error" >&2
    fi
}
start_hermes() {
    if [ "${1:-}" = quadlet ]; then systemctl --user start hermes.service
    else podman start "$CONTAINER" >/dev/null; fi
}

# `podman-compose down`, tolerating the same network cleanup error: succeed
# once the container is gone.
compose_down() {
    compose down && return 0
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
    if podman container exists "$CONTAINER"; then return 1; fi
}
