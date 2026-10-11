# Porting an existing Hermes install into this deployment

The rest of this repo assumes a fresh VM. This page covers the other case: a host that
already ran Hermes natively (a git install plus `~/.hermes` and a systemd unit) and now
moves into the pinned container. It records what actually broke when that was done, so a
second port does not rediscover it.

Nothing here changes `compose.yaml`: the portable definition stays portable. Anything
machine-local belongs in the gitignored `compose.override.yaml` (see README,
"Machine-local extras").

## What travels, and what does not

Three buckets, and the third is not a copy:

- **Secrets** — the old `~/.hermes/.env`, `auth.json`, `secrets/`, plus the git identity and
  credentials the repos need (`~/.gitconfig`, `~/.git-credentials`).
- **Knowledge** — `state.db` (copy it with SQLite's online-backup API, not `cp`: the old
  gateway may still be writing), `memories/`, `skills/`, `sessions/`, `cron/`, `scripts/`,
  `hooks/`, `config.yaml`, `SOUL.md`, and whatever else the old home carries that is not a
  cache.
- **Repos** — *not* copied. Bind-mount the host's repo directory at the **same path** inside
  the container, so absolute workdirs recorded in cron jobs keep resolving. On the host that
  is one extra line in `compose.override.yaml`:

  ```yaml
  services:
    hermes:
      volumes:
        - /home/you/projects:/home/you/projects
  ```

Do not copy the old `tools/`, `installs/`, `cache/`, `logs/`, `state-snapshots/` or the
native install itself: the image ships its own runtime, and those regenerate. On one host
they were ~5 GB of the 2.7 GB home, i.e. almost everything.

## The layout traps

The container's Hermes home is `/opt/data`, and two different `HOME`s are in play:
`/opt/data` for the gateway and its cron children, `/opt/data/home` for interactive shells.
Scripts and prompts written for the host layout resolve `~/.hermes/...` or `~/projects/...`
and therefore read the wrong thing or nothing at all — silently, from a cron job, hours
later.

Two fixes, both inside `data/` so they are backed up with everything else:

```sh
# 1. ~/.hermes -> the live files, as a REAL directory of per-file symlinks: a
#    self-referential directory symlink (~/.hermes -> /opt/data) makes any
#    shutil.copytree / find -L recurse until it dies.
mkdir -p /opt/data/.hermes
for f in .env auth.json config.yaml SOUL.md install_id state.db shared-state.db; do
    ln -sfn "../$f" "/opt/data/.hermes/$f"
done
for d in scripts memories skills cron sessions hooks secrets plugins; do
    ln -sfn "../$d" "/opt/data/.hermes/$d"
done
ln -sfn /opt/data/.hermes /opt/data/home/.hermes

# 2. ~/projects -> the mounted host repos
ln -sfn /home/you/projects /opt/data/projects
ln -sfn /home/you/projects /opt/data/home/projects
```

Verify from both homes before trusting the crons:

```sh
for H in /opt/data /opt/data/home; do
    HOME=$H python3 -c 'import os;print(os.path.expanduser("~/.hermes/.env"), os.path.exists(os.path.expanduser("~/.hermes/.env")))'
done
```

## Tooling the image does not have

`gh`, `jq`, `tirith`, `himalaya`, `sqlite3` and `tmux` are absent. `git`, `python3`, `node`,
`npm` and `curl` are present, and cron scripts that use only the standard library need
nothing.

The cron `PATH` includes `/opt/data/.local/bin`, and that directory is writable and lives in
`data/`, so static binaries can be dropped in — no image rebuild, no change to the portable
definition:

```sh
curl -fsSL -o /opt/data/.local/bin/jq https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64
curl -fsSL -o /tmp/gh.tgz "https://github.com/cli/cli/releases/download/v${GHV}/gh_${GHV}_linux_amd64.tar.gz"
tar -xzf /tmp/gh.tgz -C /tmp && cp "/tmp/gh_${GHV}_linux_amd64/bin/gh" /opt/data/.local/bin/
chmod +x /opt/data/.local/bin/gh /opt/data/.local/bin/jq
```

Prompts that assert host facts ("gh x.y is installed at /usr/bin/gh", `$HOME/projects/...`)
must be re-worded for the container; they are stored in the cron store, not in a script, so
nothing fails loudly until the job runs and produces nonsense.

## Two hazards

**A one-off container is not inert.** `podman run <image> <cmd>` still boots s6, which brings
up a `gateway-default` service slot, and Hermes loads `$HERMES_HOME/.env` on some paths with
`override=True`. Rehearsing against a copy of the real `.env` can therefore take the live
messaging poller. Bind a sanitized `.env` over it (a bogus bot token) and pass the same
override in the environment; afterwards check the container's own logs for a platform connect
and the live gateway for a conflict.

Also: `podman run IMAGE -- <cmd>` is wrong. The arguments arrive as `-- --cmd`, s6 hands them
to the wrapper as a bogus command and the container stays up, supervised, forever. Use
`IMAGE <cmd>`.

**Only one poller per platform.** Stop the native gateway *before* `make up`, and `disable`
it rather than `stop`, or systemd restarts it next to the container; both would call
`getUpdates` on the same token.

## Cutover order

```sh
# 1. rehearse the staged knowledge subset against the pinned image, one-off (no gateway)
podman run --rm --userns keep-id:uid=10000,gid=10000 --user 0:0 \
    --env-file <scratch>/.env -v <scratch>:/opt/data <image> --version
podman run ... <image> cron list          # the ported jobs, with their ids

# 2. create data/ and copy the staged set in (repo scripts handle the rest)
./scripts/first-setup.sh --non-interactive

# 3. hand the poller over, then start
systemctl --user disable --now hermes-gateway
make up && make verify

# 4. prove it end-to-end: message the bot, then check the container's logs
```

A rehearsal is worth it even without a gateway: an older release image reads a newer git
checkout's `state.db` and `config.yaml` without complaint, and `cron list` proves the jobs
survived.

## Keep the old install until the container has proved itself

The native install is the rollback path, not litter. After a day of real cron runs, one
reboot (`make verify` afterwards) and one `make backup`, reclaim it in two stages:

- **stage A** — the host-only subtrees: `~/.hermes/{tools,installs,cache,logs,state-snapshots,backups,.curator_backups,bin}` and any root-owned files a `sudo` install left behind.
  Keep `config.yaml`, `.env`, `state.db`, `memories/`, `skills/`, `cron/`, `scripts/` and the
  gateway unit file: that is what rollback needs.
- **stage B** — the install itself (`/usr/local/lib/hermes-agent` and its launchers). Only
  after stage A has been quiet for a few days.

Rollback at any time before stage B: `make down && systemctl --user enable --now hermes-gateway`.

One trap while cleaning: `podman image prune -a` also deletes the pinned image whenever no
container references it (between restarts). Plain `podman image prune` only.

## Verifying from inside, because some things cannot be seen from outside

```sh
s6-svstat /run/service/gateway-default          # up (pid …) — supervised, not just running
hermes gateway status
grep -c 'Hermes Gateway Starting' <data>/logs/gateways/default/current   # 2 = one boot-internal restart, benign
podman logs hermes | grep -i 'Connected to Telegram'
podman inspect hermes --format '{{json .Mounts}}'   # data/ AND the repo mount, both present
```

Run every cron job's script once with `HOME=/opt/data` before trusting the schedule, and
trigger the harmless ones with `hermes cron run <id>` — the gateway log then shows
`delivered to telegram:<chat>`. Do **not** trigger jobs that publish (blog) or push
(cron-config backup): a dry run that appends to a log those jobs diff against distorts the
next real run.
