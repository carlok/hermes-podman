# Decisions

Each decision records what was chosen, why, and what was observed. "Observed"
means run and seen, not read in documentation. Observations were made on
2026-10-10 with Podman 4.9.3 / podman-compose 1.0.6 / skopeo 1.13.3 (Ubuntu
24.04 packages), first in a rootless sandbox and then on the GitHub Actions
ubuntu-24.04 VM (see `.github/workflows/ci.yml`).

## Why Podman, rootless

- No root daemon. The container runs under your user's sub-UID range, so a
  container escape lands in an unprivileged account. Container root maps to a
  sub-UID (observed: host UID 100000), the `hermes` process maps to you.
- Day-to-day operation needs no sudo. The only sudo steps are package
  installation, creating `/srv/hermes-podman`, and `loginctl enable-linger`.
- Ubuntu ships Podman, skopeo and podman-compose as distro packages.

## Why a pinned tag **and** digest, never `latest`

- `docker.io/nousresearch/hermes-agent:v0.21.6@sha256:55e192fb…` was the newest
  release tag on 2026-10-10. The Hermes docs describe pinned tags as `X.Y.Z`;
  Docker Hub actually publishes them as `vX.Y.Z` (`0.21.6` does not exist,
  `v0.21.6` does). Older releases used date tags such as `v2026.9.24`; `hermes
  --version` in v0.21.6 prints `Hermes Agent v0.21.6 (2026.9.24)`.
- Tags that are **not** used: `latest`, `stable`, `main` (moving), `rc.*`
  (release candidates), `*-desktop` (desktop variant), `*-amd64`/`*-arm64`
  (single-arch).
- Observed: on 2026-10-10 `stable`/`latest` pointed to
  `sha256:9774f4f3…`, built about 4.5 hours after `v0.21.6`, so they are **not**
  the same image as `v0.21.6`. Another reason not to use them.
- The digest is the multi-arch index digest reported by
  `skopeo inspect --format '{{.Digest}}' docker://docker.io/nousresearch/hermes-agent:v0.21.6`
  (same value Docker Hub shows). With both tag and digest in the reference,
  Podman pulls by digest; the tag is there for humans. A weekly CI job checks
  the tag still resolves to the pinned digest, so upstream re-tagging is noticed.
- Podman records a `tag@digest` reference as `repo@digest` (the tag is shown as
  `<none>` in `podman images`). `verify.sh` therefore compares digests.

## Why headless gateway only

- The VM is a server: Hermes talks to messaging platforms over outbound
  connections. Nothing needs to reach the VM, so `compose.yaml` has no `ports:`
  and no `HERMES_DASHBOARD`.
- Observed: the image still starts an s6 `dashboard` service slot and an
  API server for the gateway bound to loopback **inside** the container
  (`[stage2] Generated API_SERVER_KEY for the loopback gateway api_server`).
  Neither is reachable from outside because nothing is published;
  `verify.sh` asserts `podman port hermes` is empty.
- **No browser.** No `shm_size`, the `-desktop` image variant is not used, and
  `scripts/disable-browser-tools.sh` removes the `browser` and `computer_use`
  toolsets from every platform in `data/config.yaml` after setup. Observed: the
  standard image still ships a Chromium binary under `/opt/hermes/tools`
  (`[stage2] Using pinned agent-browser Chromium binary …`); it is never
  invoked once the toolsets are off, but it cannot be removed without
  rebuilding the image, which this project deliberately does not do.

## s6 as PID 1: no `entrypoint:`, no `init:`

The image entrypoint `/opt/hermes/docker/entrypoint-dispatch.sh` execs
s6-overlay's `/init` only when it is PID 1; otherwise it falls back to an
unsupervised mode. So `compose.yaml` and the Quadlet unit keep the image
entrypoint and never add `init: true` / `--init`. Observed: PID 1 is
`s6-svscan`, the gateway runs as the s6 service `gateway-default`, and killing
the gateway process makes s6 start a new one within seconds (tested in CI).

## The rootless UID problem, and how it was solved

The image starts as root, runs its bootstrap (`stage2-hook.sh`), then drops to
user `hermes` (UID/GID 10000) with `s6-setuidgid`. In rootless Podman,
container UID 10000 is not you on the host, it is a sub-UID. Options tested
against a bind mount of `./data` (rootless, Podman 4.9.3):

| Option | Result | Host owner of data/ files |
|---|---|---|
| A. plain bind mount `./data:/opt/data` | works: the image's own bootstrap chowns its dirs to 10000 (`Fixing ownership of /opt/data`) | `109999` (sub-UID); you need `podman unshare` to read your own data |
| B. `./data:/opt/data:U` | works, same result as A, plus Podman re-chowns the whole tree on every start | `109999` |
| C. `podman unshare chown 10000:10000 data` before first start | works, no chown at boot | `109999` |
| D. named volume | works | `109999`, and the data lives in `~/.local/share/containers/storage/volumes/…`, **outside BASE_DIR**, which breaks the "all state in BASE_DIR/data" rule |
| E. **`userns_mode: keep-id:uid=10000,gid=10000` + `user: "0:0"`** | works | **you** (e.g. `ubuntu:ubuntu`) |

**Chosen: E.** `keep-id:uid=10000,gid=10000` tells Podman to map *your* host
UID/GID to 10000/10000 inside the container, which is exactly the `hermes`
user. `user: "0:0"` is needed because `keep-id` otherwise makes the container
start as 10000, and the image refuses non-root starts (its bootstrap needs root
for the UID remap and seeding; observed error text in `main-wrapper.sh`).
Container root becomes an unprivileged sub-UID (observed: host UID 100000).

Consequences:

- `data/` is created with a plain `mkdir` by `first-setup.sh`; no chown, no `:U`.
- Every file the gateway writes is owned by you on the host, so backups, `ls`,
  editing `data/config.yaml` and deleting work with normal tools (CI checks
  that nothing under `data/` has another owner).
- Do not set `HERMES_UID`/`PUID`: the image would `usermod` hermes to a
  different UID inside the container and break the mapping.
- Commands run in the container as root (plain `podman exec hermes …`) write
  files owned by a sub-UID. The Makefile always uses `--user hermes`; the image
  also re-chowns its own directories at boot.
- `scripts/backup.sh`, `restore.sh` and `uninstall.sh` still run `tar`/`rm`
  under `podman unshare`, so a stray sub-UID-owned file cannot break them.
- Needs Podman ≥ 4.3 for `keep-id:uid=…,gid=…` (Ubuntu 24.04 has 4.9.3;
  Ubuntu 22.04's 3.4.4 does not have it).

## Restart policy `always`

`podman-restart.service` (shipped by the podman package) runs
`podman start --all --filter restart-policy=always`. Observed in the unit
file: containers with `unless-stopped` would **not** come back after a reboot.
Hence `restart: always`. See BOOT.md.

## Secrets

- The wizard writes keys to `data/.env` inside the gitignored `data/`.
- The repo's `.env` (from `.env.example`) holds only container environment
  such as `TZ`; it is gitignored and created with mode 600.
- No script prints `.env` content; `first-setup.sh` only reports ownership.

## Tooling notes observed on Ubuntu 24.04

- `podman-compose` 1.0.6 passes `userns_mode`, `user`, `env_file`, `restart`
  and `stop_grace_period` through to `podman run` (seen in its generated
  command line). It fails if `env_file` is missing, so `make up` creates `.env`.
- The project name defaults to the directory name (`hermes-podman`), so the
  compose network is `hermes-podman_default`. The container name is fixed to
  `hermes`.
- Rootless networking on 24.04's Podman 4.9 uses slirp4netns, which needs
  `/dev/net/tun`.
- `hermes tools disable … --platform X` works non-interactively; `hermes tools`
  (the UI) and `hermes tools --summary` require a TTY.
- `hermes setup --non-interactive` creates a default `config.yaml` without
  credentials (used by CI).
