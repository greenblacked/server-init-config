# GitHub Actions runner (private repositories)

[Back to the runner guide](../README.md#github-actions-runner-private-repositories)

## Before enabling it

- Use only repositories and contributors you trust. Disable fork pull-request
  workflows in every served repository. Polling and post-assignment rejection are
  not a boundary that prevents untrusted code from starting.
- Install Docker with cgroup v2 and the systemd cgroup driver, host tools/job
  isolation, and the per-job limits (`ci-jobs.slice`) first. This optional setup
  assumes an existing runner host; it is not a standalone GitHub-only bootstrap.
- The controller's `docker` group membership is root-equivalent. Jobs have no
  Docker socket, Docker daemon, or sudo; Docker-based actions, `container:` jobs,
  and service containers are unsupported.
- BuildKit is enabled by default and relaxes seccomp, system-path, and applicable
  AppArmor/SELinux restrictions. It needs user namespaces. See
  [the BuildKit trade-off](#the-buildkit-trade-off); use `GH_BUILDKIT=0` to opt out.
- Check [capacity](#capacity-and-the-shared-ceiling) before sharing a small host
  with GitLab. The default GitHub limit is one pod, not one additional free slot.

## Validation status

Mocked controller tests are not end-to-end registration evidence. A real host and
App are still needed to verify personal-account runner group `1`, JIT config
delivery to `Runner.Listener`, direct Listener startup and exit codes, the
`Running job:` log marker, buildx remote TLS, BuildKit on SELinux/AppArmor, and the
unit's lack of `AF_NETLINK`. Test a small trusted repository before relying on it.

## How it works

Optional (`--github-runner`, never part of `--base` or `--all`). The same host that runs the GitLab jobs also runs GitHub Actions jobs for the **private repositories of one GitHub App installation** on your personal account. Nothing long-lived is registered: a controller (`github-runner-ctl.service`, user `github-runner`) polls GitHub every 30 s, and for each queued job that asks for `runs-on: [self-hosted, hetzner]` it asks GitHub for a **just-in-time (JIT) runner** and starts one *pod* for that job:

- a runner container (runs as uid 1001, `--cap-drop ALL`, `no-new-privileges`, no `sudo`, no Docker socket, process, CPU and memory limits, inside `ci-jobs.slice`);
- a rootless BuildKit container on the same private Docker network for image builds (`docker/setup-buildx-action` with the `remote` driver, TLS with a CA that exists for this one job);
- a network of its own (Docker's default `br-<id>` bridge naming, so the job isolation rules apply, internet allowed).

GitHub removes the runner after its one job; the controller then removes the pod. At most one pod runs at a time (`GH_MAX_JOBS=1`). Public, archived, `internal` and excluded repositories are never served, and a runner of this host found in such a repository (for example after you made it public) is deleted. The controller starts no pod for a pull request from a fork or for a job whose labels are not exactly ours, and kills a pod that was given such a job after all (see below: the filters decide only whether a pod is started, they do not decide which job an idle runner takes).

## Create the GitHub App

Once, in the browser, signed in as the account that owns the private repositories. The labels below are GitHub's at the time of writing; if the page looks different, the [GitHub docs on registering an App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app) have the current ones.

1. Open <https://github.com/settings/apps/new> (or: avatar, **Settings**, **Developer settings**, **GitHub Apps**, **New GitHub App**).
2. Fill in the form. Everything not in this table stays as it is or empty:

   | Field | Value | Why |
   |---|---|---|
   | GitHub App name | unique on GitHub, e.g. `hetzner-runner-<your user>` | only a name |
   | Homepage URL | any URL, e.g. your profile `https://github.com/<your user>` | required by the form, not used |
   | Callback URL, Setup URL | empty | no user sign-in |
   | Request user authorization (OAuth) during installation, Enable Device Flow | off | not needed |
   | Webhook, **Active** | **off** (untick) | the controller polls; the server needs no public URL |
   | Repository permissions, **Administration** | **Read and write** | create and delete the per-job runners |
   | Repository permissions, **Actions** | **Read-only** | see queued runs and jobs |
   | Repository permissions, **Metadata** | Read-only (set by GitHub, cannot be changed) | list the repositories |
   | All other repository, organization and account permissions | No access | least privilege: no *Contents*, so the App cannot read your code |
   | Subscribe to events | none (greyed out without a webhook) | |
   | Where can this GitHub App be installed? | **Only on this account** | nobody else can install it |

3. **Create GitHub App**. On the App's page (**General**) note the **Client ID** (starts with `Iv`), the installer asks for it.
4. Same page, **Private keys**, **Generate a private key**: the browser downloads `<app-name>.<date>.private-key.pem`. This file is the App's password: keep it off shared folders and chats, and delete the copies once the installer has taken it (see below).
5. Left menu **Install App**, **Install** next to your account, choose **All repositories**, **Install**. New private repositories are then picked up by themselves; the controller itself never serves public, archived or excluded ones (`GH_EXCLUDE_REPOS` keeps a private one out). **Only select repositories** works too if you prefer to list them.
6. In each private repository that will use the runner, keep fork pull requests from running workflows: repository **Settings**, **Actions**, **General**, *Fork pull request workflows in private repositories*: **Run workflows from fork pull requests** unticked (GitHub's default). This setting, not the controller, is what stops code from a fork reaching the server.

Check it before the server part (browser): **Settings**, **Applications**, **Installed GitHub Apps** lists the App with *Repository access: All repositories*; **Configure** shows the permissions above. If you change a permission later, GitHub asks you to accept it on the installation (an email and a banner on the App's installation page) and the old permissions stay until you do.

When the self-test below fails:

| Line in the self-test output | Cause | Fix |
|---|---|---|
| `FAIL  key /etc/github-runner/app.pem is missing, unreadable or not a private key` | wrong file given to the installer (for example the public key or a truncated copy) | rerun the installer with the downloaded `.pem` (`GH_KEY_SRC=...`) |
| `FAIL  GET /app: ... (wrong GH_APP_CLIENT_ID or key?)` | wrong Client ID, a key of another App, or the server clock off by minutes | compare the Client ID with the App page; `timedatectl` must show *System clock synchronized: yes*; generate a new key if unsure |
| `FAIL  permission administration: none (needs write)` (or `actions`) | the permission is not set on the App | step 2 (App page, **Permissions & events**) |
| `FAIL  no installation token: ...` | the App is not installed on your account, or a changed permission is not yet accepted on the installation | step 5; accept the pending request on the installation page |
| `WARN  no private repository would be served` | the installation sees no private repository, or all are excluded | step 5 (repository access), `GH_EXCLUDE_REPOS` |
| `FAIL  no Administration token for owner/repo` / `FAIL  listing runners of owner/repo` | Administration is read-only, or the change is not accepted on the installation | Administration: **Read and write**, then accept on the installation page |

Key rotation: see [Rotate the App key](#rotate-the-app-key). To stop new runner
creation immediately, stop the controller and uninstall the App (Installed GitHub
Apps, **Configure**, **Uninstall**). Deleting a private key alone does not revoke
already-issued installation tokens; those can remain usable until they expire.
Stopping the controller does not terminate existing job pods.

## Install

Copy the key to the server (laptop, any directory), then run the installer (server, as `ops`, any directory). It asks for your GitHub user, the Client ID and the path of the key, installs the controller, pulls the pinned images, runs a **self-test** and only then enables the service:

```bash
scp app-key.pem ops@SERVER_IP:/home/ops/app-key.pem
```

```bash
sudo bash -c 'cd /root/server-init-config && runner/setup.sh --github-runner'
```

The self-test mints a JWT, gets an installation token, checks the App's permissions and lists the repositories of the installation with `SERVE` or `SKIP (reason)` for each, without creating any runner or container. Run it again any time (it changes nothing):

```bash
sudo bash /root/server-init-config/runner/install/github-runner.sh --self-test
```

Delete the downloaded key copies (laptop and `/home/ops/app-key.pem`); the host keeps its own copy in `/etc/github-runner/app.pem` (mode 600, owner `github-runner`). The installer needs the per-job limits (`--job-limits`), Docker with cgroup v2 and the systemd cgroup driver, and `user.max_user_namespaces` above 0 for BuildKit (written to `/etc/sysctl.d/91-github-runner-userns.conf` only when it is 0; the installer says so). The settings are in `/etc/github-runner/config.env` (no secrets): `GH_OWNER`, `GH_APP_CLIENT_ID`, `GH_INSTALLATION_ID` (found by itself), `GH_LABELS` (default `self-hosted,linux,arm64,hetzner`; at least one custom label is required, so a plain `runs-on: self-hosted` job is never taken), `GH_RUNNER_GROUP_ID` (default 1), `GH_MAX_JOBS`, `GH_POLL_INTERVAL`, `GH_IDLE_TIMEOUT` (default 300 s: a pod whose runner took no job in that time is killed and its runner deleted), `GH_EXCLUDE_REPOS` (comma separated `name` or `owner/name`), `GH_ALLOW_FORK_RUNS`, `GH_BUILDKIT`, `GH_JOB_CPUS`, `GH_JOB_MEMORY`, `GH_BUILDKIT_CPUS`, `GH_BUILDKIT_MEMORY`, `GH_JOB_SUBNET_POOL`. Change a value by passing it to the installer again (`sudo GH_MAX_JOBS=2 bash /root/server-init-config/runner/install/github-runner.sh --no-self-test`), which keeps all other values and makes a backup, or edit the file and `sudo systemctl restart github-runner-ctl` (running pods keep running). `sudo bash /root/server-init-config/runner/install/github-runner.sh --help` lists everything. Installation is not transactional: preflight can install dependencies, and later failures can leave a changed key, user-namespace setting, service account, or installed files. On an existing installation, a failed self-test does not stop or disable the existing service.

Running pods: `sudo docker ps --filter label=io.server-init.github-runner=job`. Logs: `journalctl -u github-runner-ctl -f` (one `event=...` line per decision; tokens, the JIT config and the key are never logged). `health` has a "GitHub Actions runner" section: service state, age of the last successful poll, installation token age, API quota left, active pods, leftover pod parts and the age of the runner image.

## Use it in a workflow

In a private repository of the installation:

```yaml
jobs:
  test:
    runs-on: [self-hosted, hetzner]
    steps:
      - uses: actions/checkout@<commit-sha>
      - run: npm ci && npm test
```

Image builds go through the BuildKit container of the pod. **This snippet has not been run on a real host yet**; check it with a small repository first:

```yaml
      - uses: docker/setup-buildx-action@<commit-sha>
        with:
          driver: remote
          endpoint: tcp://buildkitd:1234
          driver-opts: |
            cacert=/etc/buildkit-tls/ca.pem
            cert=/etc/buildkit-tls/cert.pem
            key=/etc/buildkit-tls/key.pem
      - uses: docker/build-push-action@<commit-sha>
        with:
          context: .
          push: true
          tags: ghcr.io/OWNER/IMAGE:${{ github.sha }}
```

There is no Docker daemon in a job: `docker build`, `docker run`, `container:` jobs, service containers and Docker-based actions do not work; use buildx as above and push the result (or `outputs: type=oci,dest=image.tar`). The BuildKit cache lives for this one job. `sudo` is not available either, so install tools with the `setup-*` actions or in the image you build.

## What these jobs can and cannot reach

The pods use the same isolation as the GitLab jobs (`ci-job-isolation.service`): the cloud metadata address is dropped, and the host's own services are closed. One thing is opened, for the GitHub pods only: when the npm cache is installed (`/opt/npm-cache`, Verdaccio on the docker0 IP, port 4873), the pod networks may reach **that one port**. They come from a dedicated address pool, `GH_JOB_SUBNET_POOL` (default `10.213.0.0/20`, one `/28` per pod, chosen so it collides with neither Docker's default pools nor the stacks here), and `ci-job-isolation.sh` reads that value from `/etc/github-runner/config.env` and adds one rule to `CI-JOBS-IN`: `-i br-+ -s <pool> -d <docker0 IP> -p tcp --dport 4873 -j ACCEPT`. No other `br-` network gets it. The controller then sets `NPM_CONFIG_REGISTRY` (and the two Yarn variables; the docker0 address comes from `docker network inspect bridge`, the unit has no netlink access) in the runner container to the same address the GitLab jobs use; without `/opt/npm-cache` it sets nothing. Pick another pool with `GH_JOB_SUBNET_POOL` (a private block between /16 and /27 that nothing else uses), rerun the installer, which reloads the isolation rules. The controller requires `ci-job-isolation.service` to start successfully. If the pool is full (more pods than `/28` ranges, which `GH_MAX_JOBS` normally prevents) the controller logs `subnet_pool_exhausted` and the job stays queued. The runner container runs as uid 1001, the user of the runner image; there is no user-namespace remapping, so on the host that is uid 1001, which on a default install may be the `ops` account. Nothing owned by that uid is mounted into a pod and a pod has no view of host processes, so this grants nothing today; keep it that way (mount no host paths into pods, give no files to uid 1001).

## The BuildKit trade-off

Rootless BuildKit needs `--security-opt seccomp=unconfined` and `--security-opt systempaths=unconfined` (plus `apparmor=unconfined` where AppArmor is active, and `label=disable` where SELinux is on) so that `runc` can create user namespaces and mount a `/proc` of its own. It runs as uid 1000 inside the container, not privileged, with Docker's default capabilities, and is reachable only from its own pod network with a client certificate. The price: the container's syscall filter is off, so a kernel bug reachable from a user namespace matters more here than for the runner container, which keeps the default filter. Hardening that was **not** added because it breaks rootless BuildKit or could not be tested: `--cap-drop ALL` (the bounding set also limits the capabilities in the new user namespace), `no-new-privileges` (`newuidmap` is setuid) and `--read-only` (BuildKit needs a writable state volume). What is set: CPU, memory without swap and a process limit, the cgroup of `ci-jobs.slice`, and nothing from the host mounted except its own certificates, read-only. BuildKit stays on by default; **`GH_BUILDKIT=0` is the per-host opt-out** (no sidecar, no certificates, no unconfined container): `sudo GH_BUILDKIT=0 bash /root/server-init-config/runner/install/github-runner.sh --no-self-test`. Only repositories you own and trust (private, no fork runs) get a pod.

## Fork pull requests and public repositories

GitHub's advice is to use self-hosted runners almost never for public repositories: anyone can open a pull request that runs code on your host. For private repositories, whoever can push a branch or open a pull request from a fork can run code on this host. **The real control is the repository setting: keep Settings, Actions, General, "Run workflows from fork pull requests" off in every private repository** (it is off by default), and do not give write access to people you do not trust.

What the controller adds does not replace that setting. A JIT runner that is waiting for a job takes **any** queued job of its repository that matches its labels, so the filters before a pod starts (no fork pull request runs, labels that are all ours with a custom one, only private and active repositories) decide whether a pod is started, not which job it gets. Therefore, as soon as a pod is busy, the controller looks up the job it was given and, if it is a fork pull request (unless `GH_ALLOW_FORK_RUNS=1`) or its labels are not ours, kills the pod, deletes the runner and logs `job_rejected`; the job then fails on GitHub. It never serves a repository whose `private`, `visibility` and `archived` fields do not all say "private and active", and it deletes this host's runners in repositories that turned public or archived. There is a window: the repository list is read every poll (30 s by default), so for about one poll after you make a repository public a job that is already queued can still get a pod. Make a repository public only when nothing is queued, or stop `github-runner-ctl` first.

## Capacity and the shared ceiling

A pod is a runner container with the same limits as a GitLab job (`GH_JOB_CPUS` and `GH_JOB_MEMORY` start from the values in `config.toml`: 1.5 CPUs, 1536m, no swap, 2048 processes) plus the BuildKit sidecar (1 CPU, 768m). Everything runs inside `ci-jobs.slice`, whose ceiling (`MemoryMax=3G`, `TasksMax=4096`) is shared with the GitLab jobs. On a CAX11 that is tight: with `concurrent = 2` a busy host can hit the 3 GB ceiling and the kernel kills a job. With the GitHub runner installed use `concurrent = 1` for GitLab, or raise `JOBS_MEMORY_MAX` on a bigger server, or set `GH_BUILDKIT=0` if you do not build images. `GH_MAX_JOBS` stays 1 on this size. All idle checks (`update.sh`, the weekly cleanup, the engine update, `selinux`, `health`) count the pods as CI jobs; the weekly engine update also stops the controller while Docker is upgraded.

## Runner image updates

GitHub stops queuing jobs to a runner that has not updated for 30 days, and the runner version is the image. The image is pinned by digest in `common/lib.sh` (`GHR_RUNNER_IMAGE`, with the BuildKit image next to it). Bump both there (look the digest up from the registry, never type one) and run `runner/install/update.sh`: it writes the pins into `config.env`, pulls them and restarts the controller at once (a running pod keeps running and is adopted again; a restart deferred until idle would have been lost). `health` warns when the image is 25 days old (age alone is never a failure). The pod runs `Runner.Listener` directly, not `run.sh`, so Docker sees the Listener's real exit code: 0 done, 1 or 2 an error, 3 or 4 it staged a self-update, which means the pinned image is too old (`runner_update_required`, and `health` fails until a pod ends cleanly). Independently of the code, a runner that ends within two minutes without having taken a job counts as a failure: the controller logs `runner_failed` with the last lines of the runner log and pauses new pods for 30 s, doubling up to 15 minutes. A pod that cannot be started (image, network, JIT request, `docker run` error) backs off the same way and logs the Docker error.

## Rotate the App key

On the App page generate a new private key, copy it to the server and rerun the installer with it (it checks that the file is an RSA key, replaces `/etc/github-runner/app.pem`, keeps a backup of the old one and runs the self-test): `sudo GH_KEY_SRC=/home/ops/new-key.pem bash /root/server-init-config/runner/install/github-runner.sh`. After a successful self-test it restarts an active controller, clearing cached JWTs and installation tokens; running pods keep running. Then revoke the old key on the App page and delete downloaded and backup copies. List backups with `sudo find /etc/github-runner -maxdepth 1 -name 'app.pem.bak.*' -type f`; remove each listed file explicitly. Revocation is the reliable control; secure erasure is not guaranteed on SSDs or snapshotting filesystems.

## Remove it

Drain jobs first: stopping the controller alone leaves existing pods running.
The following cleanup deliberately terminates remaining GitHub jobs. Server, as
`ops`, any directory:

```bash path=null start=null
sudo systemctl disable --now github-runner-ctl
sudo docker ps -a --filter label=io.server-init.github-runner=job
sudo docker network ls --filter label=io.server-init.github-runner=job
```

Review those lists, then remove only the labelled resources:

```bash path=null start=null
sudo bash -c '
set -euo pipefail
mapfile -t containers < <(docker ps -aq --filter label=io.server-init.github-runner=job)
if ((${#containers[@]})); then docker rm -f "${containers[@]}"; fi
mapfile -t networks < <(docker network ls -q --filter label=io.server-init.github-runner=job)
if ((${#networks[@]})); then docker network rm "${networks[@]}"; fi
'
```

Do not use `docker network prune`: it can remove unrelated networks.
Afterwards remove the controller's config, unit, executable, optional sysctl
drop-in and `/run/github-runner` state; reload systemd and restart
`ci-job-isolation` to remove its pool exception. Deleting the sysctl drop-in does
not undo the current kernel value; do not disable user namespaces if another
service needs them. Remove the service account only after cleanup.
On GitHub uninstall/delete the App and delete leftover runners in each
repository's Settings, Actions, Runners. Revoke its private keys before deleting
local key backups.
