# hermes-podman

[![ci](https://github.com/carlok/hermes-podman/actions/workflows/ci.yml/badge.svg)](https://github.com/carlok/hermes-podman/actions/workflows/ci.yml)

Headless [Hermes Agent](https://hermes-agent.nousresearch.com/) gateway on an
Ubuntu cloud VM with **rootless Podman** and **podman-compose**, described
entirely by this repository: setup, day-2 operations, upgrade, backup,
restore, reboot survival and removal.

| | |
|---|---|
| Image | `docker.io/nousresearch/hermes-agent:v0.21.6@sha256:55e192fba0cd4fde61142abbff5adeacff40efdb482ccd0ff877924bd274f909` |
| Install path | `/srv/hermes-podman` (`BASE_DIR`) |
| Runs as | your normal user, rootless; no sudo day to day |
| Mode | `gateway run` only. No dashboard, no published ports, no browser tools |
| State | everything mutable in `BASE_DIR/data` (mounted at `/opt/data`) |

Why each of those choices was made: [docs/DECISIONS.md](docs/DECISIONS.md).

## Prerequisites

- Ubuntu 26.04 LTS VM (what CI tests: Podman 5.7.0, podman-compose 1.5.0,
  skopeo 1.21, rootless networking via pasta). 24.04 (Podman 4.9.3,
  podman-compose 1.0.6) also worked in CI before the move to 26.04; 22.04's
  Podman 3.4 is too old for `userns keep-id:uid=…`. See DECISIONS.md.
- A normal user with sub-UIDs (`grep $USER /etc/subuid`; Ubuntu creates them
  for users added with `adduser`).
- Outbound HTTPS to Docker Hub and to your model provider / chat platforms.
  Nothing inbound.

One-time sudo commands, and why:

```sh
# 1. Packages: Podman, skopeo (digest lookup), podman-compose, rootless helpers (uidmap, passt).
sudo apt-get update && sudo apt-get install -y podman skopeo podman-compose uidmap passt make git
# 2. BASE_DIR lives under /srv, which only root can create. Hand it to your user.
sudo install -d -o "$USER" -g "$USER" /srv/hermes-podman
# 3. Keep your user's systemd manager running without a login (reboot survival).
sudo loginctl enable-linger "$USER"
```

## Quick start

```sh
git clone https://github.com/carlok/hermes-podman.git /srv/hermes-podman
cd /srv/hermes-podman
./scripts/preflight.sh     # read-only report: versions, sub-UIDs, linger, old Hermes installs
make setup                 # creates .env and data/, runs the interactive Hermes wizard
make up                    # starts the gateway
make verify                # checks: running, s6, version, no ports, ownership, no browser tools
systemctl --user enable podman-restart.service   # start on boot (docs/BOOT.md)
```

`make setup` runs `hermes setup` in a throwaway container. The wizard asks for
your model provider and messaging platform credentials and writes them to
`data/.env` (mode 600, gitignored). Nothing is printed. It then removes the
`browser` and `computer_use` toolsets from every platform
(`scripts/disable-browser-tools.sh`).

## Day to day

The three commands you will actually use:

```sh
make status   # container state, Hermes version, published ports (must be none), gateway status
make logs     # follow the gateway logs
make chat     # talk to the agent from the terminal, inside the running container
```

Everything else:

| Command | What it does |
|---|---|
| `make up` / `make down` | start / stop and remove the container (data/ is kept) |
| `make restart` | `podman restart hermes` |
| `make shell` | bash in the container as the `hermes` user |
| `make verify` | full deployment check, exits non-zero on failure |
| `make backup` | stops the container, writes `backups/hermes-data-<UTC time>-<tag>.tar.gz`, starts it again |
| `make restore ARCHIVE=backups/…` | replaces data/ from a backup (old data/ kept as `data.pre-restore-*`) |
| `make upgrade` | lists releases; `make upgrade VERSION=vX.Y.Z` backs up, re-pins, recreates ([docs/UPGRADE.md](docs/UPGRADE.md)) |
| `make uninstall` | removes container, images, Quadlet unit; `PURGE=1` also deletes data ([docs/UNINSTALL.md](docs/UNINSTALL.md)) |

Reconfigure later (e.g. add a platform): `make down && ./scripts/first-setup.sh && make up`.
Re-running the wizard keeps existing values as defaults.

## Repository layout

```
compose.yaml              pinned image+digest, gateway run, restart: always, keep-id userns, ./data mount, no ports
.env.example              container environment (copied to .env, gitignored)
Makefile                  the commands above
scripts/lib.sh            shared helpers (image ref is read from compose.yaml)
scripts/preflight.sh      read-only report; stops if an old Hermes install is found
scripts/first-setup.sh    one-time wizard wrapper; creates data/ with the right owner
scripts/disable-browser-tools.sh  strips browser/computer_use toolsets from config.yaml
scripts/backup.sh         stop, tar data/, start
scripts/restore.sh        restore into data/ or into a scratch directory
scripts/upgrade.sh        list releases / re-pin tag+digest via skopeo, back up, recreate
scripts/uninstall.sh      remove what this project created
scripts/verify.sh         deployment checks (used by make verify and CI)
scripts/lint.sh           static checks of the hard rules (used by CI)
deploy/hermes.container   Quadlet unit, alternative to compose (docs/BOOT.md)
docs/                     DECISIONS, UPGRADE, UNINSTALL, BOOT
.github/workflows/ci.yml  end-to-end test on a GitHub ubuntu-26.04 VM
```

## Verified, and not verified

CI (`.github/workflows/ci.yml`) runs on a fresh GitHub-hosted Ubuntu 26.04 VM
(the `ubuntu-26.04` runner image, which GitHub still labels **preview**)
as a non-root user and checks, on every push and weekly (first green 26.04 run:
[38044574602](https://github.com/carlok/hermes-podman/actions/runs/38044574602); the earlier 24.04 runs were also green):

- the pinned digest still matches the `v0.21.6` tag on Docker Hub;
- no `ports:`, `entrypoint:`, `init:`, `shm_size` or dashboard anywhere; shellcheck;
- `first-setup.sh --non-interactive`, `make up`, then `verify.sh`: container
  running, PID 1 is `s6-svscan`, `gateway-default` s6 service up and running as
  `hermes`, `hermes --version` = `v0.21.6`, no published ports, every file in
  `data/` owned by the host user, browser/computer_use toolsets off;
- killing the gateway process: s6 restarts it;
- `podman stop` + restart of the user's systemd manager: `podman-restart.service`
  brings the container back;
- the Quadlet unit starts the same container and comes back the same way;
- backup, restore into a scratch directory, full restore into data/;
- `upgrade.sh` lists releases, refuses `latest`, is a no-op on the current pin;
- `uninstall.sh` with `PURGE=1` leaves no container, image, unit or data.

Not verifiable in CI, so **unverified** until you do it on your VM:

- the **interactive** wizard with real API keys (CI only runs `--non-interactive`, so
  the gateway starts with no model provider and no platforms);
- a real **VM reboot** (CI restarts `user@UID.service`, which is what linger
  runs at boot, but not the kernel);
- a real **upgrade to a different version** (CI only exercises the same-version path,
  to avoid a second 3 GB pull);
- messaging platforms actually connecting (needs your tokens).

Suggested first-day check on the VM: `make setup`, `make up`, `make verify`,
`sudo reboot`, log in, `make verify` again.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `make up` says data/ is not initialised | run `make setup` first |
| `pasta: …` / `slirp4netns failed` at start | rootless network helper missing; `sudo apt-get install passt` (Podman 5 default) |
| `Error: --userns and --pod cannot be set together` | podman-compose ≥ 1.1 puts services in a pod; keep `x-podman: in_pod: false` in compose.yaml |
| `keep-id: unknown option uid` | Podman older than 4.3; use Ubuntu 26.04 (or 24.04) |
| `rootless netns: kill network process: permission denied` (exit 125) on stop | Podman 5.7 on 26.04: the container did stop, only network cleanup failed. The scripts and `make down` check the real state and carry on |
| `ERROR: container started with --user …` | someone added a non-root `user:`; keep `user: "0:0"` (s6 drops to hermes itself) |
| files in data/ owned by `100000`-ish UIDs | something ran as container root (e.g. `podman exec hermes …` without `--user hermes`). Fix with `podman unshare chown -R 0:0 data` (inside `podman unshare`, UID 0 is you) |
| container gone after reboot | linger off (`loginctl show-user $USER -p Linger`) or `podman-restart.service` not enabled; see docs/BOOT.md |
| `level=error msg="Unable to clean up network … device or resource busy"` on stop | harmless Podman 4.9 (Ubuntu 24.04) message; the container stops and restarts normally |
| `toomanyrequests` from Docker Hub | anonymous pull limit; wait, or `podman login docker.io` |
| gateway keeps restarting | `make logs`; usually a missing/invalid key in `data/.env`; re-run the wizard |
| zombie processes | `entrypoint:` or `init: true` was added; remove it (the image needs s6 as PID 1) |

## License

MIT, see [LICENSE](LICENSE). Hermes Agent itself is a separate project by Nous Research.
