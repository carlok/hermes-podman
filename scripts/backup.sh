#!/usr/bin/env bash
# Timestamped tar of data/ into backups/. The container is stopped first
# (Hermes keeps SQLite databases in WAL mode; a live copy can be torn) and
# started again afterwards if it was running.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

[ -d "$DATA_DIR" ] || { echo "No data/ to back up." >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

was_running=0
owner=podman
if is_running; then
    was_running=1
    quadlet_active && owner=quadlet
    echo "Stopping $CONTAINER ($owner) for a consistent backup ..."
    stop_hermes
fi
restart() { if [ "$was_running" = 1 ]; then start_hermes "$owner"; echo "Started $CONTAINER again."; fi; }
trap restart EXIT

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/hermes-data-$ts-$(image_tag).tar.gz"
# Run tar inside the rootless user namespace so files created by any
# container UID (not only hermes) are readable, and keep numeric owners.
podman unshare tar --numeric-owner -czf "$out" -C "$REPO_DIR" data
chmod 600 "$out"
echo "Backup written: $out ($(du -h "$out" | cut -f1))"
