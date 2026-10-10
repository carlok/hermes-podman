#!/usr/bin/env bash
# Restore data/ from a backup archive.
#   scripts/restore.sh backups/hermes-data-....tar.gz            # into data/
#   scripts/restore.sh ARCHIVE /some/scratch/dir                 # test restore
# Restoring into data/ never deletes the current data: it is moved aside to
# data.pre-restore-<timestamp>/ first. Asks for confirmation unless YES=1.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

archive="${1:?usage: restore.sh ARCHIVE [TARGET_DIR]}"
target="${2:-$DATA_DIR}"
[ -f "$archive" ] || { echo "No such archive: $archive" >&2; exit 1; }
first="$(podman unshare tar -tzf "$archive" | sed -n 1p)"
case "$first" in data/*) ;; *) echo "$archive does not look like a backup made by backup.sh" >&2; exit 1 ;; esac

if [ "$target" = "$DATA_DIR" ]; then
    if is_running; then
        echo "The container is running. Run 'make down' first." >&2
        exit 1
    fi
    if [ "${YES:-0}" != 1 ]; then
        read -r -p "Replace data/ with $archive? Current data/ is kept as data.pre-restore-*. [y/N] " a
        [ "$a" = y ] || [ "$a" = Y ] || { echo "Aborted."; exit 1; }
    fi
    if [ -e "$DATA_DIR" ]; then
        aside="$REPO_DIR/data.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
        mv "$DATA_DIR" "$aside"
        echo "Previous data moved to $aside"
    fi
else
    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        echo "Target $target exists and is not empty." >&2
        exit 1
    fi
fi

mkdir -p "$target"
podman unshare tar --numeric-owner -xzf "$archive" -C "$target" --strip-components=1
chmod 700 "$target"
echo "Restored $archive into $target"
