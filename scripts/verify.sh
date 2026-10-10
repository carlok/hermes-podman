#!/usr/bin/env bash
# Check that the running deployment matches this repo. Used by `make status`
# style checks and by CI. Exits non-zero on the first failure.
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok:   $*"; }

is_running || fail "container $CONTAINER is not running"
ok "container $CONTAINER is running"

# Podman stores tag@digest references as repo@digest, so compare the digest.
img="$(podman inspect -f '{{.ImageName}}' "$CONTAINER")"
want_digest="$(image_ref)"; want_digest="${want_digest##*@}"
case "$img" in *"@$want_digest") ok "image digest $want_digest ($(image_tag))" ;;
    *) fail "container image $img is not compose.yaml's $(image_ref)" ;; esac

ports="$(podman inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")"
case "$ports" in "{}"|"null"|"") ok "no published ports" ;; *) fail "published ports: $ports" ;; esac
[ -z "$(podman port "$CONTAINER")" ] || fail "podman port lists mappings"

env="$(podman inspect -f '{{.Config.Env}}' "$CONTAINER")"
case "$env" in *HERMES_DASHBOARD=1*|*HERMES_DASHBOARD=true*) fail "HERMES_DASHBOARD is set" ;; esac
ok "dashboard not enabled"

pid1="$(podman exec "$CONTAINER" cat /proc/1/cmdline | tr '\0' ' ')"
case "$pid1" in *s6-svscan*|*/init*) ok "PID 1 is s6 ($pid1)" ;; *) fail "PID 1 is not s6: $pid1" ;; esac

want="$(image_tag)"
ver="$(podman exec "$CONTAINER" hermes --version 2>/dev/null | sed -n 1p)"
case "$ver" in *"Hermes Agent $want "*) ok "version: $ver" ;; *) fail "version '$ver' does not match $want" ;; esac

# The gateway is a supervised s6 service. Two traps here, both seen on a fast real boot:
#   - podman's log stream persists across container restarts, so a banner from the PREVIOUS
#     start satisfies a naive grep: scope the check to this container start;
#   - s6 needs a moment to bring the slot up, so probe it in a loop instead of once.
started="$(podman inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || true)"
since=""
if [ -n "$started" ]; then
    # "2026-10-10 18:02:51.123456789 +0000 UTC" -> "2026-10-10T18:02:51Z"
    since="$(printf '%s' "$started" | awk '{print $1"T"$2"Z"}' | sed 's/\.[0-9]*Z$/Z/')"
fi
for _ in $(seq 1 30); do
    if [ -n "$since" ]; then
        logs="$(podman logs --since "$since" "$CONTAINER" 2>&1 || true)"
    else
        logs="$(podman logs "$CONTAINER" 2>&1 || true)"
    fi
    grep -qF 'Hermes Gateway Starting' <<<"$logs" && break
    sleep 2
done
grep -qF 'Hermes Gateway Starting' <<<"$logs" \
    || fail "gateway start banner not in podman logs${since:+ since $since} (this container start)"
ok "podman logs show the gateway starting under s6 (this start)"
SVSTAT=/package/admin/s6/command/s6-svstat
st=""
for _ in $(seq 1 30); do
    st="$(podman exec "$CONTAINER" "$SVSTAT" /run/service/gateway-default 2>&1 || true)"
    case "$st" in up*) break ;; esac
    sleep 2
done
case "$st" in up*) ok "s6 service gateway-default: $st" ;; *) fail "gateway-default not up under s6 after 60s: $st" ;; esac
gpid="$(podman exec "$CONTAINER" "$SVSTAT" -p /run/service/gateway-default)"
guser="$(podman exec "$CONTAINER" ps -o user= -p "$gpid" | tr -d ' ')"
[ "$guser" = hermes ] || fail "gateway runs as '$guser', expected hermes"
ok "gateway pid $gpid runs as hermes (host: $(podman top "$CONTAINER" huser,pid | awk -v p="$gpid" '$2==p{print $1}'))"

me="$(id -u)"
bad="$(find "$DATA_DIR" -maxdepth 2 ! -uid "$me" -print 2>/dev/null | sed -n 1,5p)"
[ -z "$bad" ] || fail "files in data/ not owned by $(id -un): $bad"
ok "data/ owned by $(id -un) on the host (hermes UID 10000 inside the container)"

if grep -nE '^  [a-z_]+: \[.*\b(browser|computer_use)\b' "$DATA_DIR/config.yaml" >/dev/null 2>&1; then
    fail "browser/computer_use toolsets enabled in data/config.yaml"
fi
ok "browser and computer_use toolsets disabled"
echo "All checks passed."
