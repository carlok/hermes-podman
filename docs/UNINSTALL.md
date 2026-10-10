# Uninstall

Everything this project creates, and how to remove it. `make uninstall`
(`scripts/uninstall.sh`) does steps 1-4 and asks before each one. Data is only
deleted with `PURGE=1`.

```sh
cd /srv/hermes-podman
make backup                  # optional: keep a final backup somewhere safe first
make uninstall               # container, Quadlet unit, images; keeps data/
PURGE=1 make uninstall       # also deletes data/, backups/, data.pre-restore-*/ and .env
```

## What exists and where

| # | Item | Path / name | Removed by |
|---|---|---|---|
| 1 | container | `hermes` (+ network `hermes-podman_default`) | `podman-compose down` (or `podman rm -f hermes`) |
| 2 | Quadlet unit (option B only) | `~/.config/containers/systemd/hermes.container` | `systemctl --user stop hermes.service; rm …; systemctl --user daemon-reload` |
| 3 | images | `docker.io/nousresearch/hermes-agent` (all local versions), under `~/.local/share/containers/storage` | `podman rmi -f $(podman images -q docker.io/nousresearch/hermes-agent)` |
| 4 | state and secrets | `/srv/hermes-podman/data/`, `backups/`, `data.pre-restore-*/`, `.env` | `PURGE=1` → `podman unshare rm -rf …` (unshare in case a file belongs to a sub-UID) |
| 5 | boot hook (option A) | `podman-restart.service` enabled for your user | `systemctl --user disable podman-restart.service` (manual: it also starts other `restart=always` containers you may have) |
| 6 | linger | `/var/lib/systemd/linger/$USER` | `loginctl disable-linger "$USER"` (manual, same reason) |
| 7 | the repo | `/srv/hermes-podman` | `rm -rf /srv/hermes-podman` after steps 1-4; then `sudo rmdir /srv/hermes-podman` if your user cannot remove it from `/srv` |
| 8 | packages | podman, skopeo, podman-compose, uidmap, passt | `sudo apt-get remove podman skopeo podman-compose` (manual; uidmap/passt may be used by others) |

This project never creates `~/.hermes`, `~/.local/bin/hermes` or any system
systemd unit. If `preflight.sh` reported those, they came from a different
Hermes install and are left alone.

CI runs `YES=1 PURGE=1 ./scripts/uninstall.sh` and then checks that the
container, images, Quadlet file, data/, backups/ and .env are all gone.
