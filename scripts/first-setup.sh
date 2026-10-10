#!/usr/bin/env bash
# One-time setup: create data/ with the right ownership, then run the
# interactive Hermes setup wizard (it asks for your API keys and writes them
# to data/.env). Extra arguments go to `hermes setup`, e.g. --non-interactive.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

"$REPO_DIR/scripts/preflight.sh"

if is_running; then
    echo "The hermes container is running. Run 'make down' first." >&2
    exit 1
fi

ensure_env_file
# With userns keep-id the host user IS the container's hermes user (10000),
# so a plain mkdir gives the right ownership; no chown or :U needed.
ensure_data_dir

echo "Pulling $(image_ref) ..."
podman pull "$(image_ref)" >/dev/null

tty_opts=()
[ -t 0 ] && tty_opts=(-it)
echo "Starting the Hermes setup wizard (API keys are written to data/.env, never printed here)."
run_oneoff "${tty_opts[@]}" -- setup "$@"

"$REPO_DIR/scripts/disable-browser-tools.sh"

echo
echo "Ownership of data/ (expected: $(id -un)):"
stat -c '%U:%G %a %n' "$DATA_DIR"
echo "Next: make up"
