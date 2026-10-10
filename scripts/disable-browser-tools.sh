#!/usr/bin/env bash
# This deployment is a headless gateway on a cloud VM: no browser automation
# and no desktop computer-use. Remove those toolsets from every platform listed
# in data/config.yaml. Idempotent; safe to re-run after `hermes setup`.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

cfg="$DATA_DIR/config.yaml"
[ -f "$cfg" ] || { echo "No $cfg yet; run make setup first." >&2; exit 1; }
if is_running; then
    echo "Stop the container first (make down): config.yaml is rewritten." >&2
    exit 1
fi

# Platform names = keys of the top-level platform_toolsets: mapping.
platforms="$(awk '/^platform_toolsets:/{f=1;next} f&&/^[^[:space:]#]/{f=0} f&&/^  [a-z_]+:/{sub(":","",$1);print $1}' "$cfg" | tr '\n' ' ')"
[ -n "$platforms" ] || platforms="cli"
echo "Disabling browser and computer_use toolsets for: $platforms"
# shellcheck disable=SC2016  # $p expands inside the container shell
run_oneoff -- sh -c '
  for p in '"$platforms"'; do
    hermes tools disable browser computer_use --platform "$p" >/dev/null 2>&1 \
      || hermes tools disable browser --platform "$p" >/dev/null
  done' >/dev/null 2>&1
if grep -nE '^  [a-z_]+: \[.*\b(browser|computer_use)\b' "$cfg"; then
    echo "WARNING: a platform still lists browser/computer_use (see above)." >&2
    exit 1
fi
echo "Done."
