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

## Repo-first pin bumps

`make upgrade VERSION=<tag>` edits `compose.yaml` and `deploy/hermes.container` in place
and then asks you to commit the change. If you would rather keep the checkout clean, make
the bump the commit instead:

1. Resolve the digest — never type it by hand:

   ```sh
   curl -fsS https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/vX.Y.Z \
     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], d["digest"], d["last_updated"][:19])'
   # or: skopeo inspect --format '{{.Digest}}' docker://docker.io/nousresearch/hermes-agent:vX.Y.Z
   ```

2. Commit **both** files to `main` in one commit, with the tag, the digest and the
   publish date in the message.
3. On the host:

   ```sh
   make backup && git pull --ff-only && make down && make up && make verify
   ```

Rollback then becomes `git revert --no-edit HEAD && make down && make up && make verify`,
with the same data-restore caveat as above.

## Verifying an upgrade (do not gate on log greps)

A connect line is not proof, and its absence is not a failure: from v0.22 the messaging
connect is logged through the logger into `data/logs/`, not to container stdout, so a
check that greps `podman logs` can declare failure seconds after a healthy connect.
Gate on these instead:

```sh
hermes --version                      # exact target tag
grep '^_config_version' data/config.yaml
hermes gateway status
hermes cron list                      # same ids, schedules and enabled flags
hermes memory status                  # provider still installed and active
make verify
```

A `gateway.exit_nonzero` line in `data/logs/gateway-exit-diag.log` is usually the teardown
of a rollback rather than a crash — compare against `data/logs/container-boot.log` first.

## Upgrading across v0.21 → v0.22

- Config migrates on first start (`_config_version` 50 → 51) and the runtime moves from
  Python 3.14.7 to 3.14.9. Allow ~20 s before the gateway reaches the platform.
- `session_reset` idle/daily modes are retired: `session_reset: {mode: none}` only warns;
  clear it with `hermes config unset session_reset`.
- Memory providers left core (holographic, retaindb, honcho, mem0, hindsight, supermemory,
  openviking). A profile that still names one boots with "could not be installed
  automatically"; install it explicitly:

  ```sh
  hermes plugins install holographic --yes-deps --enable
  ```

  Without `--yes-deps` a non-interactive install refuses and installs nothing. The plugin
  lands in the profile's `plugins/` directory, which lives on the data volume.
- Inside an s6 container, `gateway.host_rendezvous: ignoring host record … owned by uid
  10000 (expected 0)` repeats every ~5 s: the unprivileged gateway writes the record while
  the root supervisor expects a root-owned one. It does not block the platform connect.
