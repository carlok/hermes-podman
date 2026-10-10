# Surviving a reboot

Rootless containers belong to your user's systemd manager (`user@UID.service`).
Without **linger**, that manager only runs while you are logged in, so nothing
starts at boot. Pick **one** of the two options below, never both: both create
a container named `hermes`.

## Common step: linger (one-time sudo)

```sh
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger      # Linger=yes
```

If `systemctl --user` says it cannot connect to the bus over SSH, set
`export XDG_RUNTIME_DIR=/run/user/$(id -u)` in your shell profile.

## Option A (default): compose + podman-restart.service

```sh
make up
systemctl --user enable podman-restart.service
```

`podman-restart.service` ships with the podman package
(`/usr/lib/systemd/user/podman-restart.service`). At boot it runs
`podman start --all --filter restart-policy=always`; that is why
`compose.yaml` uses `restart: always` (with `unless-stopped` the container
would stay down). `make down` removes the container, so a stopped deployment
stays stopped across reboots.

Check: `systemctl --user is-enabled podman-restart.service` → `enabled`.

## Option B: Quadlet unit

`deploy/hermes.container` describes the same container (same image pin,
userns mapping, env file, data mount, no ports) for Podman's Quadlet systemd
generator. Systemd then owns the container lifecycle; there is no compose.

```sh
make down                                         # remove the compose container first
systemctl --user disable podman-restart.service   # if you enabled option A
mkdir -p ~/.config/containers/systemd
cp deploy/hermes.container ~/.config/containers/systemd/
systemctl --user daemon-reload                    # generates hermes.service
systemctl --user start hermes.service
make verify
```

The `[Install] WantedBy=default.target` section makes the generated service
start at boot; Quadlet units are not "enabled" with `systemctl enable`.
The paths in the unit assume `/srv/hermes-podman`; edit `EnvironmentFile=` and
`Volume=` if your BASE_DIR differs. Validate with
`/usr/libexec/podman/quadlet -dryrun -user`.

With Quadlet, use `systemctl --user stop|start|restart hermes.service` instead
of `make down|up|restart`; `make logs`, `status`, `shell`, `chat`, `verify` and
`backup` work unchanged (`backup.sh` notices the active `hermes.service` and
stops/starts it with `systemctl --user`, because the Quadlet container is
created with `--rm` and would be restarted by systemd under a plain
`podman stop`). Logs are
also in `journalctl --user -u hermes.service`.

## What was tested

| Path | How | Result |
|---|---|---|
| s6 restarts a crashed gateway | CI kills the gateway PID inside the container | new PID within seconds |
| Option A after "reboot" | CI: linger on, `podman stop hermes`, `sudo systemctl restart user@UID.service` | container running again, `verify.sh` passes |
| Option B after "reboot" | CI: same restart of `user@UID.service` with the Quadlet unit installed | container running again, `verify.sh` passes |
| Real VM reboot | not possible in CI | **unverified**: do `sudo reboot` once on your VM, then `make verify` |

Restarting `user@UID.service` is what linger does at boot (the user manager
starts and reaches `default.target`), but it does not exercise kernel boot,
network-online timing or a cold image cache. Hence the manual check.
