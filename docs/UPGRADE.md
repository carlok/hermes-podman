# Upgrade and rollback

The image is pinned in two places that must always match:
`compose.yaml` (`image:`) and `deploy/hermes.container` (`Image=`).
`scripts/upgrade.sh` edits both; `scripts/lint.sh` (CI) fails if they differ.

## See what is available

```sh
make upgrade
```

Prints the current pin and the newest release tags on Docker Hub, ordered by
push date (Docker Hub API), hiding `latest`, `stable`, `main`, `rc.*`,
`-desktop` and per-arch tags. Push date, not version sort, because Hermes moved
from date tags (`v2026.9.24`) to semver (`v0.21.6`) and `v2026…` would sort
as "newer". Read the release notes before picking one:
<https://github.com/NousResearch/hermes-agent/releases>.

## Upgrade

```sh
make upgrade VERSION=v0.21.7     # example tag; use one that make upgrade listed
make verify
git commit -am "Upgrade Hermes to v0.21.7"
```

What `scripts/upgrade.sh` does, in order:

1. Refuses moving or non-release tags (`latest`, `stable`, `main`, `rc.*`, `*desktop*`).
2. Looks up the digest: `skopeo inspect --format '{{.Digest}}' docker://docker.io/nousresearch/hermes-agent:<tag>`.
   Nothing is typed by hand.
3. If the pin is unchanged, stops ("Already pinned").
4. `scripts/backup.sh` (stops the container, tars data/, restarts it).
5. `podman pull <tag>@<digest>`.
6. Rewrites `image:` in compose.yaml and `Image=` in deploy/hermes.container.
7. `podman-compose down && podman-compose up -d`, prints the new `hermes --version`.

On first start the new version migrates `config.yaml` if its schema changed
and writes a timestamped backup of the old config first (Hermes docs). Set
`HERMES_SKIP_CONFIG_MIGRATION=1` in `.env` to prevent that.

If you run the **Quadlet** unit instead of compose, do the steps by hand:
`./scripts/upgrade.sh` would start a compose container. Run
`./scripts/backup.sh`, edit both pins with the skopeo digest, then
`cp deploy/hermes.container ~/.config/containers/systemd/ && systemctl --user daemon-reload && systemctl --user restart hermes.service`.

Unverified: CI only runs the "same version" path of upgrade.sh. An upgrade to
a different version has not been run end to end.

## Roll back

The previous pin is in git history and the pre-upgrade backup is in `backups/`
(its file name ends in the old tag).

```sh
make down
git log --oneline -- compose.yaml                 # find the commit before the upgrade
git checkout <commit> -- compose.yaml deploy/hermes.container
make restore ARCHIVE=backups/hermes-data-<time>-v0.21.6.tar.gz   # only if the new version changed data
make up
make verify
git commit -am "Roll back Hermes to v0.21.6"
```

Restoring data is needed when the newer version migrated `config.yaml` or
databases in a way the old one cannot read. The old image is still in local
storage until you prune it, so no download is needed; otherwise Podman pulls
it again by digest.

Clean up old images when you are happy: `podman image prune`.
