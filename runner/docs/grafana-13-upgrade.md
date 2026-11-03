# Runbook: Grafana 12.0.0 to 13.3.0 on a runner host

For the first production upgrade of the monitoring stack with the repo's own tooling (`runner/update.sh`, `runner/install/monitoring-backup.sh`). Read it once completely before the change window. The background (why the data is archived, what `--rollback` does and does not do, the encryption key) is in [runner/README.md](../README.md#grafana-upgrade-and-rollback); this page is the order of work, the checks and the stop conditions.

Conventions: everything runs on the server as `ops` over SSH with `sudo`, unless a block says "laptop". `SERVER_IP`, `NOTED_COMMIT` and `FILE` are placeholders you fill in. `ops` cannot read `/root` and is not in the `docker` group, so repo paths go through `sudo bash -c 'cd ... && ...'` and every `docker` call has `sudo`.

## 1. Scope and expected outcome

Changes on the host:

| What | From | To |
|---|---|---|
| Grafana image | `grafana/grafana:12.0.0` | `grafana/grafana:13.3.0` |
| Grafana `mem_limit` | `256m` | `512m` |
| Grafana data (`monitoring_grafana-data`, SQLite) | Grafana 12 schema | migrated forward on the first start; dashboards and folders move into Grafana 13 unified storage |
| `/var/backups/monitoring/` | - | one new archive `grafana-12.0.0-<date>.tar.gz` |
| npm cache (only when `/opt/npm-cache` exists) | `verdaccio/verdaccio:6.1.2` | `verdaccio/verdaccio:7.0.2`; the old storage is moved aside inside its volume, the cache refills from npmjs |

Does not change: Prometheus (`v3.15.1`) and node-exporter (`v1.12.1`) images and data, the provisioned datasource and dashboard files, `/opt/monitoring/.env` (except `MON_UID` and `MON_GID`, which are already there), the Caddy override if present, secrets, `config.toml`, the runner registration, `daemon.json`, SSH.

The Grafana rows hold if the host's current checkout is `3635bc2`, the commit just before the Grafana bump (`008905a`). The Verdaccio 7 upgrade (`2b48300`) landed after the bump, so every host coming from before the bump that has `/opt/npm-cache` gets the npm-cache change in the same `update.sh` run: the old Verdaccio 6 storage is moved aside (not deleted) and the cache starts empty. Read the README section ["npm cache upgrade and rollback"](../README.md#npm-cache-upgrade-and-rollback) before the window; expect `npm-cache` in the `would update:` list of step 3.11 on such a host. A host on an older checkout than `3635bc2` gets every other difference too. The dry run in step 3.11 lists everything; read that list, do not assume.

Done means: `/api/health` says `13.3.0` with `database: ok`, the container is not OOM-killed, the Prometheus datasource is healthy, the provisioned dashboard and every hand-made dashboard and folder from before are present, `health -q` has no FAIL.

## 2. Risks and blast radius

- Grafana is down for minutes: stopped for the archive, recreated on the new image, then busy with the first-start migration. Prometheus and node-exporter keep running and keep scraping, so no metrics are lost; only the UI is gone.
- CI jobs are not blocked by the monitoring steps. `update.sh` does not wait for an idle runner for host tools, monitoring or logging; only the registry-cache and npm-cache restarts and `--os` are skipped while jobs run (exit code 3). A run with jobs active can therefore finish Grafana and still exit 3; rerun it when idle to finish the caches.
- The Grafana 13 migration is one-way. After it, rollback means restoring the archive. Anything created or edited in Grafana after the archive was written is lost (dashboards, folders, users, preferences). Ask people not to edit dashboards in the window.
- Between the end of the archive and the recreate, `monitoring-backup.sh` starts the old 12.0.0 container again. Edits made in that short gap are also not in the archive.
- The archive contains `grafana.db`. With Grafana's built-in default secret key (no `GF_SECURITY_SECRET_KEY` in `.env`) the data source credentials in it are decryptable by anyone who gets the file. It is root-only, mode 0600: keep it on the host, do not copy it off.
- `update.sh` also syncs host tools, logging and the caches in the same run. Unrelated diffs ride along; the dry run shows them.
- The weekly cleanup and the disk guard run `docker image prune -af --filter until=...`, which removes every image no container uses (the filter looks at the image's creation date, not at when it was pulled). After the upgrade the Grafana 12.0.0 image and the helper image used by the backup and the restore are unused and can disappear, so a rollback may need a fresh pull from Docker Hub. Rollback step 0 pulls them first; for the timers see 3.12.
- A Grafana that is unhealthy after the update is only a `WARN` in `update.sh` and does not change its exit code. Always run the checks in step 6.

## 3. Pre-checks

Run them at least a day before the window, except 3.9 to 3.12, which belong right before it. Work in `tmux` (installed by the init) so a dropped SSH session cannot kill `update.sh` midway:

```bash
tmux new -A -s grafana13
```

### 3.1 Helper for the Grafana API (re-paste after a reconnect)

Reads the admin credentials from the root-only `.env` inside `sudo bash` and hands them to `curl -K` through a pipe, so the password is never in an argument list, the shell history or the output. It assumes the password the installer generated (letters and digits only); a hand-set password containing `"` or `\` would need escaping in the `user = ...` line that `curl -K` reads.

```bash
gapi() { sudo bash -c 'u=$(grep "^GF_SECURITY_ADMIN_USER=" /opt/monitoring/.env | cut -d= -f2-); p=$(grep "^GF_SECURITY_ADMIN_PASSWORD=" /opt/monitoring/.env | cut -d= -f2-); curl -fsS --max-time 20 -K <(printf "user = \"%s:%s\"\n" "$u" "$p") "$@"' _ "$@"; }
```

```bash
gapi http://127.0.0.1:3000/api/org | jq -c '{id, name}'
```

Expect one JSON object such as `{"id":1,"name":"Main Org."}`. An error here means the credentials or Grafana are wrong; fix that first.

### 3.2 Current versions

```bash
sudo docker inspect -f '{{.Config.Image}} {{.HostConfig.Memory}} {{.State.Status}}' monitoring-grafana-1
```

Expect `grafana/grafana:12.0.0 268435456 running` (256m). Anything else: stop and work out why the host is not on the expected state.

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq -c '{version, database}'
```

Expect `{"version":"12.0.0","database":"ok"}`.

### 3.3 Disk: archive and image

The archive is written to `/var/backups/monitoring` (same filesystem as `/var`), compressed, via a temp file in that directory, so one archive is the peak. The 13.3.0 image is pulled on top, into Docker's storage.

```bash
sudo docker system df -v | grep -E 'VOLUME NAME|monitoring_grafana-data'
```

The `SIZE` column is the uncompressed size of the Grafana volume. This command only reads.

```bash
df -h /var /var/lib/docker
```

Free space on the `/var` filesystem should be comfortably more than the volume size, and the Docker filesystem needs room for the new image (a few hundred MB, estimate). The disk guard cleans at 85% used on `/` (README, "Cleanup"): do not start close to it.

```bash
sudo ls -lA /var/backups/monitoring
```

Expect nothing, or earlier `grafana-*.tar.gz` files (the newest 3 are kept, so an old one is pruned after the new one is written). `No such file or directory` is fine on a host that never ran the backup.

Check there is a database to archive. `monitoring-backup.sh` carries on without a backup when the volume has no `grafana.db`:

```bash
sudo docker exec monitoring-grafana-1 ls -l /var/lib/grafana/grafana.db
```

Expect a non-empty file owned by the monitoring user.

### 3.4 Memory for the 512m limit

```bash
free -m
```

`available` should cover 512 MiB for Grafana on top of what the runner jobs use (`concurrent = 2` on a 4 GB CAX11). The limit is a cap, not a reservation, but an OOM kill of the migration is the main failure mode of this upgrade.

```bash
sudo docker stats --no-stream
```

Look at the `MEM USAGE` of the job containers and the current Grafana (`monitoring-grafana-1`).

### 3.5 Baseline of what is in Grafana

Written to the `ops` home directory; titles and uids only, no secrets. Compared in step 6.

```bash
gapi 'http://127.0.0.1:3000/api/search?type=dash-db' | jq -r '.[] | [.uid, .title, (.folderTitle // "-")] | @tsv' | sort > ~/grafana-dashboards-before.tsv; wc -l < ~/grafana-dashboards-before.tsv
```

```bash
gapi 'http://127.0.0.1:3000/api/search?type=dash-folder' | jq -r '.[] | [.uid, .title, (.folderTitle // "-")] | @tsv' | sort > ~/grafana-folders-before.tsv; wc -l < ~/grafana-folders-before.tsv
```

The folder list comes from the search API instead of `/api/folders`, so nested folders are included too (the third column is the parent folder, `-` at the top level). This is from Grafana's API behaviour, not verified against its documentation here; if the list looks short compared with what you see in the UI, check the UI.

```bash
gapi http://127.0.0.1:3000/api/datasources | jq -r '.[] | [.uid, .type, .name] | @tsv' | sort > ~/grafana-datasources-before.tsv; cat ~/grafana-datasources-before.tsv
```

A stock host has one dashboard (`gitlab-runner-host`, folder `GitLab Runner`) and the datasource `prometheus` (plus `loki` when logging is installed). Every other line is hand-made content that has to survive.

### 3.6 Health baseline

```bash
sudo /usr/local/bin/health -q --no-color; echo "exit=$?"
```

Exit 0 is clean, 1 has warnings, 2 has failures. Fix FAILs first. Save the WARN lines so you can tell old from new afterwards. The summary line has the form `N OK  N WARN  N FAIL`.

### 3.7 Docker Compose version

```bash
sudo docker compose version --short
```

Docker Compose 2.23.1 or newer is needed only when `/opt/npm-cache` is installed; `update.sh` checks this before it changes anything and stops with a message otherwise.

```bash
sudo test -f /opt/npm-cache/docker-compose.yml && echo "npm-cache installed" || echo "npm-cache not installed"
```

### 3.8 Secret key and Caddy override

```bash
sudo grep -c '^GF_SECURITY_SECRET_KEY=' /opt/monitoring/.env
```

Prints a count only, never the value. `1` means the host has its own key (keep it with every archive, see the README). `0` means Grafana uses the public default key: the backup step then prints a `NOTE:` and the archive is as sensitive as described in section 2. Do not add a key now: values stored under the default key would become unreadable.

```bash
sudo test -f /opt/monitoring/docker-compose.override.yml && echo "override present (Caddy on a domain)" || echo "no override"
```

`update.sh` neither writes nor reads this file; `docker compose` in `/opt/monitoring` merges it by itself, so Caddy keeps running (it depends on Grafana, so it may restart with it). Its `GF_SERVER_*` settings sit in `.env` and are untouched. The API checks below use `127.0.0.1:3000` and work either way.

### 3.9 Repo state on the server, and a copy for rollback

`runner/bootstrap.sh` streams `git archive HEAD` to `/root/server-init-config`, so on a normal host there is no `.git`:

```bash
sudo bash -c 'if [ -d /root/server-init-config/.git ]; then git -C /root/server-init-config status --porcelain --untracked-files=no; git -C /root/server-init-config rev-parse --short HEAD; else echo "archive copy, no .git"; fi'
```

With a git clone expect empty status output and the short hash: write that hash down as `NOTED_COMMIT`. With an archive copy there is no hash on the server: take `NOTED_COMMIT` from the laptop (the `copying <hash>` line of the last bootstrap, or the last commit the host was updated from) and keep an exact copy of the current tree, which makes the repo rollback independent of the laptop:

```bash
sudo bash -c 'test ! -e /root/server-init-config.pre-grafana13 && cp -a /root/server-init-config /root/server-init-config.pre-grafana13'
```

The guard matters: `cp -a` onto a directory that exists would nest the tree inside it, and an earlier copy may be the only good one. If the command prints nothing and returns at once, the copy already exists (an earlier attempt). Do not overwrite it blindly. Compare it with the current tree:

```bash
sudo diff -rq /root/server-init-config /root/server-init-config.pre-grafana13 && echo "copy identical to the current tree"
```

Identical: nothing to do. Different, and the current tree is still the one the host runs on (nothing was copied to the server yet): move the old copy aside with `sudo mv /root/server-init-config.pre-grafana13 /root/server-init-config.pre-grafana13.old`, then run the guarded `cp` again. Different, and the current tree is already a newer one: keep the existing copy, it is the one to go back to.

### 3.10 Copy the new repo state to the server

Laptop, repo root, on the commit you intend to deploy. The copy takes `HEAD`, not your uncommitted edits, so the tree must be clean:

```bash
git status --porcelain --untracked-files=no
```

```bash
git rev-parse --short HEAD
```

The first prints nothing; note the second.

Do not rerun `runner/bootstrap.sh` for this. It is not copy-only: after the copy it runs `runner/setup.sh` for the components (firewall, registry-cache, monitoring, logging, register, and job-limits, npm-cache and shared-cache when a runner is registered; the `--no-*` flags only drop some of them) and installs every one that is missing on the host, `register` included, which asks for a runner token. Only installed components are skipped, and `bootstrap.sh` refreshes none of them. The block below is the copy step of `bootstrap.sh` alone (`copy_repo` in `runner/bootstrap.sh`: the same `git archive` of `HEAD` without `.git`, `tar.umask=0022`, `install -d -m 0700`, extraction next to the target, then an atomic swap). Laptop, repo root (`ops` because root SSH is closed on a locked host; add `-p PORT` to `ssh` if SSH is not on 22):

```bash
git -c tar.umask=0022 archive --format=tar HEAD | ssh -o BatchMode=yes ops@SERVER_IP 'sudo -n sh -c "set -e; rm -rf /root/server-init-config.new /root/server-init-config.old; install -d -m 0700 /root/server-init-config.new; tar -x -C /root/server-init-config.new; if [ -e /root/server-init-config ]; then mv /root/server-init-config /root/server-init-config.old; fi; mv /root/server-init-config.new /root/server-init-config; rm -rf /root/server-init-config.old"'
```

`runner/bootstrap.sh --dry-run SERVER_IP --user ops` changes nothing and prints the line `bootstrap.sh` would use for the copy, if you want to compare. Check the copy arrived:

```bash
sudo test -f /root/server-init-config/runner/setup.sh && echo "copy ok"
```

On a host that runs a git clone instead, bring the clone to the intended commit yourself and skip the copy; do not use `update.sh --pull` (README: this setup has no server-side credential).

Server: confirm the copy has the intended tag, and that the installed compose file differs from it only by what section 1 lists:

```bash
sudo grep -E 'image: grafana/grafana' /root/server-init-config/runner/stacks/monitoring/docker-compose.yml
```

```bash
sudo diff /opt/monitoring/docker-compose.yml /root/server-init-config/runner/stacks/monitoring/docker-compose.yml
```

Expect `image: grafana/grafana:13.3.0` from the first. The diff (exit 1) should show only the Grafana image line and the `mem_limit` line with the comment above it. `update.sh` overwrites the installed compose file, so any other local edit on the host shows up here and would be lost: decide about it now.

Pull the new image, and the pinned helper image that the backup (and the restore) runs in, shortly before the window. This makes a registry problem less likely after the archive was taken, not impossible: `update.sh` still runs `docker compose pull -q`, which contacts the registry again, and a failure there aborts the run through the ERR trap (section 5). Pull close to the window and away from the timers of 3.12, because the cleanup removes unused images:

```bash
sudo docker pull grafana/grafana:13.3.0
```

```bash
sudo docker pull alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
```

### 3.11 Dry run

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh --dry-run'; echo "exit=$?"
```

Not entirely passive: it takes the update lock, runs the Compose version check and `bash -n` on the scripts, and the Prometheus config check runs `promtool` in a container from the Prometheus image (pulled if that tag is not on the host). The Grafana backup runs in its own dry-run mode, which starts no container and pulls nothing. Expect, among other `[dry-run]` lines:

```text
[HH:MM:SS] [dry-run] would back up monitoring_grafana-data, if it holds a database (12.0.0 -> 13.3.0) to /var/backups/monitoring/grafana-12.0.0-<date>.tar.gz
[HH:MM:SS] [dry-run] would update /opt/monitoring/docker-compose.yml
[HH:MM:SS] would update:
  - monitoring/docker-compose.yml
```

The `would update:` list must contain `monitoring/docker-compose.yml` and nothing you cannot explain. On a host that has `/opt/npm-cache` and comes from before the bump, expect `npm-cache` as well: Verdaccio 7 landed after the Grafana bump and moves the old npm storage aside in the same run (section 1; README, "npm cache upgrade and rollback"). If the backup line says `no backup needed`, the installed compose is already on Grafana 13 or the repo copy is not the intended one: stop. Also stop on `WARN: the Grafana backup check failed (dry run only, nothing changed)`: the backup could not even be checked, and the real run is likely to stop at the backup. `ERROR:` anywhere: stop and fix. Expect `exit=0`.

### 3.12 Timers that touch Docker

Choose the window away from these timers, in the server's local time (units in `runner/systemd/`):

- weekly cleanup, Monday 03:30 plus up to 10 minutes random delay; it runs `docker image prune -af --filter until=...` and the other prunes;
- disk guard, every 30 minutes from 10 minutes after boot; it runs the same cleanup with 1-day retention when `/` is at 85% or more;
- engine update (Docker CE and GitLab Runner), Sunday 04:30 plus up to 30 minutes random delay; when no job runs it stops the runner and restarts Docker.

The weekly timers are `Persistent=true`, so one that was missed (server off) runs shortly after the next boot. A prune can remove the images you just pulled; a Docker restart in the middle of the backup or the first start is worse. Look at the next run times:

```bash
systemctl list-timers 'runner-*' --no-pager
```

Also keep the disk below the guard threshold (3.3), otherwise the cleanup starts by itself in the window.

## 4. Optional staging stop at 12.4.13

The README states that the Grafana 13.0 upgrade notes recommend the latest 12.x minor as a stop, and that this repo did not stage it (small database, CI upgrades 12.0.0 straight to the repo tag with a folder and a dashboard). That recommendation was not verified when this runbook was written (grafana.com could not be reached; third-party summaries suggested no mandatory stop), and neither was that `12.4.13` is the latest 12.x release. Before the change, read https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v13.0/ and decide. If it recommends the stop, or the host holds much hand-made content, do this first, on its own day if you like (README, "Grafana upgrade and rollback").

A minor move inside 12 triggers no archive (the backup runs only when the major changes), so take one by hand first. `--force` backs up although the major is unchanged; the archive is named after the installed version (`grafana-12.0.0-<date>.tar.gz`):

```bash
sudo bash /root/server-init-config/runner/install/monitoring-backup.sh --force --to-tag 12.4.13
```

Then set the tag, start it and check (the sed is the README's, with the other tag):

```bash
sudo bash -c 'cd /opt/monitoring && sed -i "s|image: grafana/grafana:.*|image: grafana/grafana:12.4.13|" docker-compose.yml && docker compose up -d grafana'
```

```bash
for i in $(seq 1 60); do curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/api/health && break; sleep 5; done; curl -fsS http://127.0.0.1:3000/api/health | jq -c '{version, database}'
```

Expect `{"version":"12.4.13","database":"ok"}`; repeat the dashboard comparison of step 6. Then continue with step 5 as written. Effects: `update.sh` will then name its archive `grafana-12.4.13-<date>.tar.gz` (the installed compose says 12.4.13), and the way back to 12.0.0 is the manual archive from above, with `12.0.0` in the README's `sed`; if you go back only to 12.4.13, use that tag instead.

## 5. Upgrade

Window: runner idle if you can (`sudo docker ps -q --filter label=com.gitlab.gitlab-runner.managed=true | wc -l` prints `0`), otherwise accept exit code 3 and a second run later. Same tmux session as above. Re-run 3.2 and 3.5 if more than a day has passed.

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh'
```

The README "Update" section has the same command. What it does, in order: host tools, then the monitoring stack: `promtool` check of the Prometheus config, the Grafana backup, sync of the Prometheus and Grafana files and the compose file, `docker compose config`, `docker compose pull`, `docker compose up -d`, wait for Prometheus `/-/ready`, then up to about 1 to 2.5 minutes of waiting for Grafana `/api/health`. Then logging, registry-cache, npm-cache, a prune of old config backups and `health -q`.

What the backup step prints (timestamps omitted):

```text
grafana backup: stopping Grafana for a consistent copy
grafana backup: monitoring_grafana-data (12.0.0 -> 13.3.0)
grafana backup: wrote /var/backups/monitoring/grafana-12.0.0-<YYYYMMDD-HHMMSS>.tar.gz (<size>)
NOTE: this Grafana uses its built-in default encryption key, ...      <- only when .env has no GF_SECURITY_SECRET_KEY
```

The archive is `0600 root`, the newest 3 are kept. Grafana is down from the stop until the new container passes the health wait.

Timing (estimate, not measured on a production host): the archive takes seconds for a small database; the pull and the first start with migration take a few minutes. The step waits for Grafana only briefly, so a long migration on a big database prints `WARN: grafana did not report healthy yet` and the run goes on.

Stop conditions, and what to do:

| You see | Meaning | Do |
|---|---|---|
| `grafana backup: ... no backup needed` or `holds no database yet, nothing to back up` | no archive is made and the run goes on | cannot be stopped in time once printed: 3.3 and the dry run in 3.11 must have shown the backup beforehand |
| `ERROR: monitoring: Grafana data backup failed` | the helper container could not run (image pull, daemon); Grafana is running again on 12.0.0 (the script restarts it) | fix the cause (network, Docker Hub), rerun. The monitoring files were not changed; the host tools, which run first, may already have been |
| `ERROR: ... promtool rejected the new Prometheus config` | config problem, before the backup | fix and rerun |
| `ERROR at line N: update aborted. Changed files are backed up in ... (runner/install/update.sh --rollback ...)` | an unguarded command failed, for example `docker compose pull`; `runner/update.sh` is a wrapper for the script named in the message | read section 7 first: check whether Grafana 13 ever started before using `--rollback` |
| `monitoring: prometheus not ready, files restored` | `update.sh` restored the files itself, exit 1 | see section 7 |
| `WARN: grafana did not report healthy yet` | not an error exit; migration may still be running or failed | step 6, and the log check there |

Exit codes of `update.sh`: `0` everything done; `3` a step was skipped because CI jobs were running (the summary line `SKIPPED (rerun when idle): ...` names it; Grafana is done regardless); `1` an error from a check (`ERROR: ...`, printed by `die`, which exits 1); the `ERROR at line N` trap message is different: it comes with the exit status of the command that failed, non-zero but not always 1. The script does not flip to non-zero because Grafana is unhealthy.

Record the archive name and check it right away:

```bash
sudo bash -c 'f=$(ls -1t /var/backups/monitoring/grafana-*.tar.gz | head -n 1); echo "$f"; stat -c "%a %U" "$f"; tar -tzf "$f" | grep -E "^(\./)?grafana\.db$"'
```

Expect the path `grafana-12.0.0-<date>.tar.gz`, `600 root`, and `./grafana.db`. This archive is `FILE` in section 7.

## 6. Validation

Start right after `update.sh` returns. The first command waits up to 5 minutes (60 tries, 5 s apart) for Grafana to answer.

```bash
for i in $(seq 1 60); do curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:3000/api/health && break; sleep 5; done; curl -fsS http://127.0.0.1:3000/api/health | jq -c '{version, database}'
```

Expect `{"version":"13.3.0","database":"ok"}`. If the loop times out, go to the log check below and to section 7.

```bash
sudo docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' monitoring-grafana-1
```

Expect `false 0`. Run it again after 5 to 10 minutes; `true` or a growing count means the migration or normal operation is hitting the 512m cap (section 8).

```bash
sudo docker inspect -f '{{.Config.Image}} {{.HostConfig.Memory}}' monitoring-grafana-1
```

Expect `grafana/grafana:13.3.0 536870912`.

Prometheus datasource, through Grafana, with the helper from 3.1:

```bash
gapi http://127.0.0.1:3000/api/datasources/uid/prometheus/health | jq -r .status
```

Expect `OK`.

```bash
gapi -G --data-urlencode 'query=up{job="node"}' http://127.0.0.1:3000/api/datasources/proxy/uid/prometheus/api/v1/query | jq -r '.data.result[0].value[1]'
```

Expect `1`: Grafana reads a live series through its datasource.

Provisioned dashboard:

```bash
gapi http://127.0.0.1:3000/api/dashboards/uid/gitlab-runner-host | jq -r '.dashboard.title, .meta.folderTitle'
```

Expect `GitLab Runner Host` and `GitLab Runner`. Open it in the browser too (below) and check the panels show data.

Hand-made content, against the baseline from 3.5. Empty diff output means identical:

```bash
gapi 'http://127.0.0.1:3000/api/search?type=dash-db' | jq -r '.[] | [.uid, .title, (.folderTitle // "-")] | @tsv' | sort | diff ~/grafana-dashboards-before.tsv - && echo "dashboards identical"
```

```bash
gapi 'http://127.0.0.1:3000/api/search?type=dash-folder' | jq -r '.[] | [.uid, .title, (.folderTitle // "-")] | @tsv' | sort | diff ~/grafana-folders-before.tsv - && echo "folders identical"
```

```bash
gapi http://127.0.0.1:3000/api/datasources | jq -r '.[] | [.uid, .type, .name] | @tsv' | sort | diff ~/grafana-datasources-before.tsv - && echo "datasources identical"
```

Host health, which also checks Prometheus, Grafana, targets and Loki:

```bash
sudo /usr/local/bin/health -q --no-color; echo "exit=$?"
```

Expect no FAIL (`Grafana healthy` line present) and no new WARN compared with 3.6.

Grafana log for migration errors. A lot of `migrat` lines at info level is normal on the first start; read the `error` ones:

```bash
sudo docker logs --since 30m monitoring-grafana-1 2>&1 | grep -iE 'error|migrat'
```

```bash
sudo docker logs --since 30m monitoring-grafana-1 2>&1 | grep -E 'level=(error|crit)'
```

The second is narrower (Grafana's logfmt `level=` field). Anything about a failed migration, `database is locked`, a killed process or a panic: section 7 or 8.

Login through the SSH tunnel (README, "Grafana and logs"). Laptop, any directory, leave it running, then open `http://localhost:3000`, user `admin`:

```bash
ssh -N -L 127.0.0.1:3000:127.0.0.1:3000 -L 127.0.0.1:9090:127.0.0.1:9090 ops@SERVER_IP
```

The `127.0.0.1:` before each local port keeps the tunnel on the laptop's loopback, whatever `GatewayPorts` says in the client config.

The password, if you need it. This prints it, and in tmux it stays in the pane history: plain `clear` does not remove it. Read it in a throwaway tmux window, which takes its history with it when it closes:

```bash
tmux new-window
```

```bash
sudo grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env
```

```bash
exit
```

`exit` closes the throwaway window (you are back in the window you came from). If you ran the `grep` in the main window instead, afterwards run `clear && tmux clear-history`. Also clear the scrollback of the terminal on your laptop, where the output was shown too.

Log in, open Dashboards, check the runner dashboard and a hand-made one, open Connections, Data sources, Prometheus, "Save & test". Without an HTTPS domain Grafana listens on `127.0.0.1` only.

## 7. Rollback

Roll back (restore the archive) when, after the migration had its time:

- Grafana does not become healthy and the logs show a failed or repeating migration, or it is OOM-killed again with the limit raised to what the host can spare;
- dashboards or folders from the baseline are missing or broken and cannot be fixed by hand quickly;
- the data source credentials or logins no longer work.

Fix forward instead when Grafana is healthy on 13.3.0 and the data is complete: UI differences, a single panel to repair, a transient `database is locked` that goes away after one restart, or only the `WARN` because the migration was still running. Set a time limit before the window (for example 30 minutes after the start of the migration), and decide by the criteria, not by the clock alone. Every minute on 13 adds edits that a rollback throws away.

`runner/update.sh --rollback` alone does not downgrade Grafana once 13 has run. It restores the repo-managed files from the newest `/var/backups/server-init-config/<timestamp>/` and recreates the stacks (Grafana restarts, on 13), but with the current (13) tree it keeps the installed Grafana 13 compose file (image and 512m limit) and says so in a `WARN:` line, because the old Grafana cannot read migrated data. Grafana's data comes back only from the archive. Use `--rollback` only for the other files (and when Grafana 13 never started, in which case it also puts the old compose file back); check first that the newest backup directory is the one of your run:

```bash
sudo ls -1t /var/backups/server-init-config | head -n 3
```

**Order matters: if you use `--rollback` at all, run it before step 1 below, with the current (13) tree on the server, never after it.** After step 1 the server tree is the `3635bc2` copy, and its `runner/install/update.sh` has no `keep_grafana_major` / `grafana_ran_tag` guard (added after the bump, in `9417213`). Laptop, repo root, to see it for yourself (prints `0`):

```bash
git show 3635bc2:runner/install/update.sh | grep -c 'keep_grafana_major\|grafana_ran_tag'
```

Its `--rollback` would put the 12.0.0 / 256m compose file back from the backup and force-recreate Grafana 12 on the migrated data. For the same reason its README has no "Grafana upgrade and rollback" section: take the restore commands from this page (inlined below, copied from the current `runner/README.md`) or from the README of the current repo on your laptop, not from the server's copy. `--rollback` also puts the older npm-cache compose file back, which starts Verdaccio 6.1.2 on the storage that 7.x wrote (README, "npm cache upgrade and rollback"); it is only a cache.

**Step 0, before anything is stopped.** Pull the images the restore needs. The cleanup may have removed them after the upgrade (section 2), and a pull problem is better found while Grafana still runs:

```bash
sudo docker pull grafana/grafana:12.0.0
```

```bash
sudo docker pull alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f
```

Then, in this order:

1. Put the repo copy back to the commit you upgraded from, otherwise the next `update.sh` upgrades again. With the copy from 3.9, guarded so that no tree is overwritten or lost:

   ```bash
   sudo bash -c 'test -d /root/server-init-config.pre-grafana13 && test ! -e /root/server-init-config.grafana13 && mv /root/server-init-config /root/server-init-config.grafana13 && mv /root/server-init-config.pre-grafana13 /root/server-init-config'
   ```

   If it does nothing (the `test` failed): `/root/server-init-config.pre-grafana13` missing means 3.9 was skipped or the host runs a git clone, so use the clone or the laptop route below; `/root/server-init-config.grafana13` already existing is the leftover of an earlier attempt, look at it with `sudo ls -ld /root/server-init-config.grafana13`, move it away with `sudo mv /root/server-init-config.grafana13 /root/server-init-config.grafana13.earlier` and run the command again. If it stops after the first `mv`, `/root/server-init-config` is missing: run `sudo mv /root/server-init-config.pre-grafana13 /root/server-init-config` by hand. With a git clone: `sudo git -C /root/server-init-config checkout --detach NOTED_COMMIT`. From the laptop: check out `NOTED_COMMIT` and run the copy block of 3.10 (not `runner/bootstrap.sh`, which would also run `setup.sh` components, see 3.10).
2. List the archives, newest first. Pick the one named after the old version, `FILE` = `grafana-12.0.0-<date>.tar.gz` from step 5 of the upgrade:

   ```bash
   sudo ls -1t /var/backups/monitoring
   ```

3. Verify it independently if you want certainty (the restore command in step 4 also does `tar -tzf` before it deletes anything): it prints `./grafana.db`.

   ```bash
   sudo tar -tzf /var/backups/monitoring/FILE | grep -E '^(\./)?grafana\.db$'
   ```

4. Restore. Replace `FILE` with the archive from step 2. This replaces everything in the Grafana volume, but only after `tar -tzf` has read the whole archive, so a corrupt or truncated file stops the command before anything is deleted (copied exactly from `runner/README.md`, "Grafana upgrade and rollback", with its pinned helper image):

   ```bash
   sudo bash -c 'tar -tzf /var/backups/monitoring/FILE >/dev/null && cd /opt/monitoring && docker compose stop grafana && docker run --rm -i --network none -v monitoring_grafana-data:/v alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f sh -c "find /v -mindepth 1 -delete && tar -xzf - -C /v" < /var/backups/monitoring/FILE'
   ```

5. Start the old image and check (also copied from the README: sets `image: grafana/grafana:12.0.0`, starts Grafana, then asks `/api/health`):

   ```bash
   sudo bash -c 'cd /opt/monitoring && sed -i "s|image: grafana/grafana:.*|image: grafana/grafana:12.0.0|" docker-compose.yml && docker compose up -d grafana && curl -fsS http://127.0.0.1:3000/api/health'
   ```

   `version` in the answer should be the old one. The `curl` can fail if it runs before Grafana listens; repeat the health loop of step 6. If you staged at 12.4.13 and want that version, use that tag in the `sed`.

Grafana 12.0.0 then runs with the `512m` limit of the 13 compose file until a normal `update.sh` run with the rolled-back repo copy; that is harmless. That run also takes npm-cache back to Verdaccio 6.1.2 (README, "npm cache upgrade and rollback").

Post-rollback validation:

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq -c '{version, database}'
```

Expect `{"version":"12.0.0","database":"ok"}`. The three `diff` commands of step 6 against `~/grafana-*-before.tsv` must print `identical`, with one exception: anything created after the archive is gone. The provisioned runner dashboard comes back from the repo files. Run `health -q` again. The secret key in `.env` is unchanged by all of this and matches the archive; never edit it.

A rollback makes no new archive. The 12.0.0 archive stays in `/var/backups/monitoring`; do not delete it until a retry of the upgrade has succeeded.

## 8. Known issues and troubleshooting

- **SQLite `database is locked` during the unified-storage migration.** Secondary summaries of the Grafana 13 upgrade mention that the migration can be tuned with `[unified_storage]` settings `migration_cache_size_kb` and `migration_parquet_buffer`. The official upgrade guide could not be read while writing this, so none of that is verified: confirm the names, meaning and sensible values in the upgrade guide and the Grafana configuration reference before using them. If they are right, they can be set as environment variables in `/opt/monitoring/.env`, using Grafana's `GF_<SECTION>_<KEY>` rule; `update.sh` does not rewrite that file (it only sets `MON_UID` and `MON_GID`). A migration that died half way leaves unknown state: restore the archive (section 7, steps 2 to 4), set the keys, then start the new image with `sudo bash -c 'cd /opt/monitoring && docker compose up -d grafana'` (the compose file still has 13.3.0).
- **OOM-kill at 512m** (`OOMKilled` is `true`, or `RestartCount` grows, or the container restart-loops). Restore the archive (steps 2 to 4 of section 7; the README says the same), raise the limit, start the new image again. Temporary change of the Grafana `mem_limit` only (`1g` is an example, take what the host can spare next to the jobs; the sed range starts at the `grafana:` service, the last one in the file, so no other limit changes):

  ```bash
  sudo sed -i '/^  grafana:/,$ s/mem_limit: 512m/mem_limit: 1g/' /opt/monitoring/docker-compose.yml
  ```

  ```bash
  sudo bash -c 'cd /opt/monitoring && docker compose up -d grafana'
  ```

  The next `update.sh` run puts `512m` back and recreates Grafana. A lasting change belongs in the repo's `runner/stacks/monitoring/docker-compose.yml`, copied to the server with the block of 3.10 and deployed with `update.sh`. Do not use a `docker-compose.override.yml` for it: `grafana-domain.sh` writes that file for Caddy and overwrites it.
- **Grafana unhealthy after the update.** `update.sh` only prints `WARN: grafana did not report healthy yet` and exits 0 (or 3). `health` then shows `Grafana not healthy` and `update.sh` logs `health exit code 2`. Check `sudo docker logs --tail 100 monitoring-grafana-1` and `sudo docker inspect -f '{{.State.Status}} {{.State.OOMKilled}} {{.RestartCount}}' monitoring-grafana-1`. A migration that is still progressing is fine; give it a few minutes and repeat the health loop.
- **`NOTE: ... built-in default encryption key`.** The host's `.env` has no `GF_SECURITY_SECRET_KEY`, so the credentials stored in `grafana.db` (and in the archive) are encrypted with Grafana's public default key: whoever gets the archive can decrypt them. Not an error. Keep the archive on the host; do not add a key to an install that has data (README).

## 9. After the upgrade

- Keep the 12.0.0 archive until you are satisfied, at least a few days of normal use. An ordinary `update.sh` on Grafana 13 makes no new archive (same major), so it stays; it never leaves the host.
- Delete the rollback copy of the repo tree when you no longer need it: `sudo rm -rf /root/server-init-config.pre-grafana13 /root/server-init-config.grafana13`.
- Remove the baseline files when done: `rm -f ~/grafana-dashboards-before.tsv ~/grafana-folders-before.tsv ~/grafana-datasources-before.tsv`.
- Record the outcome: host, date, repo commit, archive name, `health -q` result, anything in the Grafana log, how long the migration took. The next host benefits from the real numbers.
- Roll out to the other runner hosts one at a time, with this runbook and at least a day between hosts, starting with the one with the least hand-made Grafana content.

## 10. Sources

Repo files read for this runbook (commands were checked against them):

- `runner/update.sh`, `runner/install/update.sh` (update flow, `--dry-run`, `--rollback`, exit codes, ERR trap, `restore_files`, `keep_grafana_major`, Grafana health wait)
- `runner/install/monitoring-backup.sh` (archive path, mode 0600, keep 3, `--force`, log lines, default-key NOTE)
- `runner/install/monitoring.sh`, `runner/install/grafana-domain.sh` (`.env`, the secret key, the Caddy override)
- `runner/stacks/monitoring/docker-compose.yml`, `env.example`, `grafana/provisioning/*`, `grafana/dashboards/gitlab-runner.json`, `prometheus/prometheus.yml`
- `runner/README.md` (sections "Grafana upgrade and rollback", "Grafana and logs", "Update", "Daily use"), `runner/bootstrap.sh`, `runner/setup.sh`
- `common/lib.sh` (`HELPER_IMAGE`, `require_compose_min`, `ci_jobs_running`, `chown_volumes`), `common/health`
- `runner/scripts/runner-weekly-cleanup.sh`, `runner/scripts/runner-disk-guard.sh`, `runner/scripts/runner-engine-update.sh` and the timers in `runner/systemd/` (image prune, thresholds, schedules)
- `tools/ci/runner-host-e2e.sh`, section 4. CI runs these Grafana API checks: `/api/health` (version, `database: ok`), the Prometheus datasource (`/api/datasources/uid/prometheus` and its `/health`), the `up{job="node"}` query through the datasource proxy, the dashboard list `/api/search?type=dash-db` by title, dashboards by uid (`/api/dashboards/uid/...`), folders by uid (`/api/folders/<uid>`), and the OOM-kill and restart count of the container. Used only in this runbook, so not exercised by CI: `/api/org`, the `/api/datasources` list, `/api/search?type=dash-folder`, the provisioned dashboard `gitlab-runner-host` by uid, and the baseline and diff files.

Grafana documentation:

- https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v13.0/ - the 13.0 upgrade notes. Not read in full while writing this (grafana.com was unreachable from the authoring environment): the statement that the notes recommend the latest 12.x minor as a stop comes from the repo README, the 512 MB minimum from a comment in the compose file, and the `[unified_storage]` setting names (`migration_cache_size_kb`, `migration_parquet_buffer`) from secondary summaries. None of the three was confirmed against the official page, nor was that `12.4.13` is the latest 12.x release (section 4). Verify them before the window.
- Grafana's `GF_<SECTION>_<KEY>` environment variable rule and the HTTP API paths used (`/api/health`, `/api/search`, `/api/datasources/...`, `/api/dashboards/uid/...`): general Grafana behavior; the paths listed above are exercised by the repo's CI against Grafana 13.3.0, the others are not. None was re-read from the official pages here. That `/api/search?type=dash-folder` also returns nested folders is likewise from API behaviour, not from the documentation.
