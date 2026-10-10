#!/usr/bin/env bash
# Remove what this project created. Each step asks first (YES=1 answers yes
# to everything except deleting data/ and backups/, which needs PURGE=1).
# Never touches anything outside this repo except the items listed in
# docs/UNINSTALL.md.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

ask() { [ "${YES:-0}" = 1 ] && return 0; read -r -p "$1 [y/N] " a; [ "$a" = y ] || [ "$a" = Y ]; }

if podman container exists "$CONTAINER" && ask "Stop and remove container '$CONTAINER'?"; then
    compose_down
fi

quadlet="$HOME/.config/containers/systemd/hermes.container"
if [ -f "$quadlet" ] && ask "Remove Quadlet unit $quadlet?"; then
    systemctl --user stop hermes.service 2>/dev/null || true
    rm -f "$quadlet"
    systemctl --user daemon-reload 2>/dev/null || true
fi

imgs="$(podman images --format '{{.ID}}' docker.io/nousresearch/hermes-agent | sort -u)"
if [ -n "$imgs" ] && ask "Remove all local nousresearch/hermes-agent images?"; then
    # shellcheck disable=SC2086
    podman rmi -f $imgs
fi

if [ "${PURGE:-0}" = 1 ]; then
    if [ "${YES:-0}" = 1 ] || ask "PERMANENTLY delete data/, backups/ and data.pre-restore-*/ (API keys, sessions, memories)?"; then
        # podman unshare: some files may belong to sub-UIDs the host user cannot delete directly.
        podman unshare rm -rf "$DATA_DIR" "$BACKUP_DIR" "$REPO_DIR"/data.pre-restore-*
        rm -f "$REPO_DIR/.env"
        echo "Deleted data/, backups/ and .env."
    fi
else
    echo "Kept data/, backups/ and .env (re-run with PURGE=1 to delete them)."
fi

echo "Not changed (shared with other containers; see docs/UNINSTALL.md):"
echo "  - podman-restart.service user unit:  systemctl --user disable podman-restart.service"
echo "  - linger for $(id -un):              loginctl disable-linger $(id -un)"
echo "  - packages podman/skopeo/podman-compose"
echo "  - this repository directory: $REPO_DIR"
