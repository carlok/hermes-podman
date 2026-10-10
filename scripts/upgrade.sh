#!/usr/bin/env bash
# Upgrade (or downgrade) the pinned Hermes version.
#   scripts/upgrade.sh                 # show current version and available releases
#   scripts/upgrade.sh v0.21.7         # back up, pin tag+digest, pull, recreate
# The digest is looked up with skopeo, never typed by hand. compose.yaml is
# edited in place; commit it afterwards (see docs/UPGRADE.md).
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

REPO=docker.io/nousresearch/hermes-agent
current="$(image_ref)"
echo "Current: $current"
if is_running; then
    echo "Running: $(podman exec "$CONTAINER" hermes --version 2>/dev/null | sed -n 1p)"
fi

target="${1:-}"
if [ -z "$target" ]; then
    # Sorted by push date, not by version string: Hermes switched from date
    # tags (v2026.9.24) to semver (v0.21.6), so a version sort would mislead.
    echo "Newest release tags on Docker Hub (rc.*, -desktop, per-arch and moving tags hidden):"
    python3 - <<'PY' || { echo "Docker Hub API unreachable; try: skopeo list-tags docker://$REPO" >&2; exit 1; }
import json, re, urllib.request
url = "https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags?page_size=100&ordering=last_updated"
rel = re.compile(r"^v?\d+(\.\d+){2,3}$")
tags = []
for _ in range(5):  # rc.* tags are numerous; look a few pages deep
    with urllib.request.urlopen(url, timeout=30) as r:
        page = json.load(r)
    tags += page["results"]
    url = page.get("next")
    if not url:
        break
for t in [t for t in tags if rel.match(t["name"])][:10]:
    print(f'  {t["name"]:<14} pushed {t["last_updated"][:10]}')
PY
    echo "Usage: $0 <tag>    (an explicit version tag; never latest/stable/main)"
    exit 0
fi
case "$target" in
    latest|stable|main|*desktop*|rc.*) echo "Refusing moving or non-release tag '$target'." >&2; exit 1 ;;
esac

digest="$(skopeo inspect --format '{{.Digest}}' "docker://$REPO:$target")"
new="$REPO:$target@$digest"
echo "Target:  $new"
[ "$new" = "$current" ] && { echo "Already pinned to this image."; exit 0; }

if [ -d "$DATA_DIR" ]; then
    "$REPO_DIR/scripts/backup.sh"
fi

podman pull "$new" >/dev/null
sed -i "s|^\([[:space:]]*image:[[:space:]]*\).*|\1$new|" "$REPO_DIR/compose.yaml"
sed -i "s|^Image=.*|Image=$new|" "$REPO_DIR/deploy/hermes.container"

compose down
compose up -d
sleep 5
echo "Now running: $(podman exec "$CONTAINER" hermes --version 2>/dev/null | sed -n 1p)"
echo "Previous image was: $current"
echo "Commit the change:  git commit -am 'Upgrade Hermes to $target'"
