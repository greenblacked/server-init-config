# Runner maintenance log

## 2026-11-19 — System-wide h2ci updates

On the existing h2ci managed deployment, install the updater extensions with
`sudo bash runner/install/h2ci-system-updates.sh`. The unprivileged `ops`
entry point is still `server-update`. It applies signed OS RPM updates, then
reconciles `/etc/h2ci-container-update/images.json`. Docker, containerd and
GitLab Runner retain the guarded Sunday timer; its service now invokes the
same entry point in engine mode, and the daily report includes its latest
outcome. Neither path reboots the host.

`sudo server-update --h2ci-verify` only checks the active images and timer;
it does not install packages, pull images, or restart services. To approve an
image update, review its release and migration requirements, then set the
vendor version and digest plus `from`, the exact current Compose image
reference. An entry without `from` cannot trigger a replacement. Do not
overwrite live Compose files with the templates to apply a pin. A verified
rollback holds that target digest (see
`/var/lib/h2ci-server-update/<service>.rollback`) until reviewed; keep the
rollback volume archives in `/var/backups/monitoring` or
`/var/backups/h2ci-container-update` according to the host's retention policy.

## 2026-11-18 — Monitoring Compose drift on `h2ci`

Compared the deployed `/opt/monitoring/docker-compose.yml` with `runner/stacks/monitoring/docker-compose.yml` using `config-drift --diff`. The three image pins differ:

| Service | Running on `h2ci` | Repository target | Memory limit (unchanged) |
| --- | --- | --- | --- |
| Prometheus | `3.4.0` | `3.15.1` | 512 MiB |
| Node Exporter | `1.9.1` | `1.12.1` | 64 MiB |
| Grafana | `12.0.0` | `13.3.0` | 512 MiB |

The remaining differences are one comment and the error wording for missing `MON_UID` or `MON_GID`; both files require the same variables. No other Compose settings differ. All three containers were running with zero recorded restarts. Their local readiness, metrics, or health endpoints returned HTTP 200, and Grafana reported its database as OK. No local Grafana backup archive was found in `/var/backups/monitoring` at the time of review. No deployment changes were made.

**Recommendation:** Treat this as planned version drift, not an incident. Keep the running stack in place until a maintenance window. Review and stage the Prometheus and Node Exporter upgrades separately: the [Grafana 13 upgrade and rollback runbook](grafana-13-upgrade.md) assumes both are already on their repository versions, which is not true on this host. Review the update dry run before applying anything. Create and verify a Grafana backup before starting Grafana 13; its database migration is one-way, so rolling back to Grafana 12 requires restoring the pre-upgrade archive. Afterward, verify scrape continuity, Grafana database health, the datasource, and dashboards.
