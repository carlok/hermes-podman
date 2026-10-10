#!/usr/bin/env bash
# Report what is on this machine before changing anything. Read-only.
# Exit 1 if a previous non-Podman Hermes install is found (it is never deleted).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

echo "== Tools"
for t in podman skopeo podman-compose git make; do
    if command -v "$t" >/dev/null 2>&1; then
        printf '%-15s %s\n' "$t" "$("$t" --version 2>/dev/null | tail -n1)"
    else
        printf '%-15s MISSING\n' "$t"
    fi
done

echo "== Rootless prerequisites"
user="$(id -un)"
grep -q "^$user:" /etc/subuid && echo "subuid: $(grep "^$user:" /etc/subuid)" || echo "subuid: MISSING for $user"
grep -q "^$user:" /etc/subgid && echo "subgid: $(grep "^$user:" /etc/subgid)" || echo "subgid: MISSING for $user"
if command -v loginctl >/dev/null 2>&1; then
    echo "linger: $(loginctl show-user "$user" -p Linger 2>/dev/null || echo unknown)"
fi
if command -v podman >/dev/null 2>&1; then
    echo "podman rootless: $(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo unknown)"
    echo "cgroups: $(podman info --format '{{.Host.CgroupsVersion}} {{.Host.CgroupManager}}' 2>/dev/null || echo unknown)"
fi

echo "== Previous Hermes installs (reported, never touched)"
found=0
for p in "$HOME/.hermes" "$HOME/.local/bin/hermes"; do
    if [ -e "$p" ]; then echo "FOUND: $p"; found=1; fi
done
for d in "$HOME/.config/systemd/user" /etc/systemd/system; do
    for u in "$d"/hermes*.service; do
        [ -e "$u" ] && { echo "FOUND unit: $u"; found=1; }
    done
done
if command -v podman >/dev/null 2>&1; then
    other="$(podman ps -a --format '{{.Names}} {{.Image}}' | grep -i hermes | grep -v "^$CONTAINER " || true)"
    [ -n "$other" ] && { echo "FOUND other Hermes containers:"; echo "$other"; found=1; }
fi
if [ "$found" = 1 ]; then
    echo "A previous Hermes install exists. Nothing was changed. Review it, then re-run with ALLOW_LEFTOVERS=1 to continue anyway." >&2
    [ "${ALLOW_LEFTOVERS:-0}" = 1 ] || exit 1
else
    echo "none"
fi
