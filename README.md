# auto-cleanup

Manage host log/package maintenance and Docker retention on a Linux systemd host.
Each Docker daemon is explicitly enrolled and cleaned as its owning account.
Rootful and rootless daemons can coexist; containers' internal users do not
change daemon ownership. Cleanup needs no socket mount inside an application or
Traefik container, and it does not configure routing.

Host maintenance and Docker targets are separate installations. Adding or
removing one daemon does not change another daemon's policy or host settings.
New timers remain disabled until explicitly enabled. Updates preserve an
existing active timer after a successful installation.

Requires Python 3.8+, systemd (including busctl), and standard Linux tools. Host APT/btmp maintenance
also requires apt-config, the distro's APT periodic machinery, and logrotate.
Docker targets require the Docker CLI; managed native cache GC requires the
**selected daemon** to run Docker Engine 28+ and a local dockerd validator.
Rootless Docker commands run through runuser as the owner. Restarting that daemon
uses the owner's user systemd manager.
The installer does not install prerequisites, create users or enable Docker.

## Why this design

A shared VPS can have one rootful Docker daemon serving several applications
alongside rootless daemons owned by individual accounts. Cleanup therefore needs
an explicit choice of which daemon to manage and which resources to retain.

**Host maintenance and Docker retention have different scopes.** Journald, APT
and btmp policies apply to the host once. Each Docker daemon has its own images,
containers and cache budget. Separate enrollment lets you add or remove a daemon
policy without changing host maintenance. Docker targets share installed cleanup
code, so updating that code can temporarily pause other targets too.

**The daemon determines the cleanup account.** A non-root Traefik container can
still belong to a rootful daemon. auto-cleanup runs that daemon's cleanup as root
and a rootless daemon's cleanup as its owning account. An explicit local socket
and checks of socket ownership and daemon kind reduce the risk of cleaning the
wrong daemon through an ambient Docker context.

**One saved JSON file keeps policy consistent.** Installation saves the reviewed
target settings as root-owned JSON. Checks and the cleanup runner then read that
saved policy. The installer derives the service account and timer calendar from
the target settings and checks
them against systemd before activation. This keeps retention policy from drifting
between environment overrides, example files and service definitions.

**System timers give the host operator one place to manage cleanup.** Rootful
and rootless cleanup jobs use the same systemd commands and journal, while each
service runs as its daemon's owner. This separates responsibility for scheduling
from the account used to access Docker. The rootless Docker daemon still has to
be running and reachable when cleanup runs.

**Deployment tooling knows which unused images are still needed.** A rollback
image may have no container referencing it, so Docker usage alone cannot identify
every image worth keeping. Inventory mode lets deployment tooling name current,
rollback and recovery images and coordinate changes through a shared lock.
The tradeoff is that the deployment tooling must publish and renew that inventory.
Tags offer simpler explicit protection; the examples' `none` mode adds only
container-reference protection.

**Writing policy, scheduling cleanup and restarting Docker are separate choices.**
You can inspect installed settings before enabling a new timer and choose when
a daemon restart may interrupt applications. Successful updates resume previously
active cleanup timers. Docker's native cache GC has its own lifecycle: once
active in the daemon, it can reclaim cache even while the cleanup timer is disabled.

**Separate locations keep source updates and retained state under control.**
Keep the checkout root-owned because privileged lifecycle commands execute its
code. Scheduled jobs use installed copies, so pulling source changes does not
update those jobs until you install them. Configuration lives separately from
installed code, and removing a target preserves its protection inventory and
stable lock. This lets you remove scheduling without discarding the deployment
coordination state.

## Clone and preview

```sh
sudo git clone https://github.com/numpde/auto-cleanup.git /opt/auto-cleanup
cd /opt/auto-cleanup
sudo ./scripts/auto-cleanup host install --dry-run
```

Use a root-owned checkout; `/opt/auto-cleanup` is the recommended location, not a
required path. Scheduled cleanup uses installed copies. Keep a checkout for
installation, checks, updates and removal.

| Location | Purpose |
| --- | --- |
| `/opt/auto-cleanup/` | Recommended source checkout |
| `/etc/auto-cleanup/` | Saved host and Docker target policies |
| `/usr/local/lib/auto-cleanup/` | Installed cleanup runner and configuration loader |
| `/etc/systemd/system/` | Cleanup service/timer templates and target drop-ins |
| `/var/lib/auto-cleanup/NAME/` | Protection directory used by the examples; the target selects its actual path |

Review [examples/host.json](examples/host.json). Its boolean `journald`, `apt`,
and `btmp` selections are persisted at `/etc/auto-cleanup/host.json`. Set a
component to `false` to leave it unmanaged. On updates, deselecting a previously
selected component removes this repository's file; external policy remains.

```sh
sudo ./scripts/auto-cleanup host install --config examples/host.json
sudo ./scripts/auto-cleanup host check
```

| Host component | Managed policy |
| --- | --- |
| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |
| btmp | Rotate monthly or over `50M` at a logrotate check; keep one compressed rotation |
| APT | Refresh package lists daily; autoclean every 7 days; clean every 30 days |

Existing effective APT cleanup and matching external btmp rotation are preserved.
Native inspectors reject conflicting policies before managed writes. A selected
repository-owned fixture is refreshed on update. btmp can exceed its threshold
between logrotate checks. APT uses the distro's existing timers.

## Enroll a Docker daemon

Copy and review either [examples/rootful.json](examples/rootful.json) or
[examples/agent-mail.json](examples/agent-mail.json). The Agent Mail example
uses the inspected UID 1000 layout; verify the account and socket on your host.
The rootful example manages a shared root-owned daemon, regardless of whether
Traefik or other containers run internally as non-root users.

```sh
cp examples/agent-mail.json /tmp/agent-mail-cleanup.json
# Edit the copied settings, including image protection.
sudo ./scripts/auto-cleanup docker install --config /tmp/agent-mail-cleanup.json --dry-run
sudo ./scripts/auto-cleanup docker install --config /tmp/agent-mail-cleanup.json
sudo ./scripts/auto-cleanup docker check agent-mail --live
```

Enroll the shared rootful daemon separately. One target covers every application
using that daemon, including Traefik. Review the copied file before installation:

```sh
cp examples/rootful.json /tmp/rootful-cleanup.json
# Edit the copied settings, including image protection.
sudo ./scripts/auto-cleanup docker install --config /tmp/rootful-cleanup.json --dry-run
sudo ./scripts/auto-cleanup docker install --config /tmp/rootful-cleanup.json
sudo ./scripts/auto-cleanup docker check rootful --live
```

Enrollment contacts exactly the configured local Unix socket under its owner,
checks socket ownership and daemon kind, and rejects duplicate daemon enrollment
or overlapping configuration/protection paths. Existing enrolled daemons must
also be reachable during live uniqueness checks. Docker context, host and TLS
environment variables cannot redirect cleanup. Missing or mismatched targets
fail without fallback.

The runner requires `--config`; legacy environment-only execution is unsupported.
Additional cleanup-unit fragments/drop-ins are unsupported. Enrollment checks
effective systemd account, executable and calendar before enabling a timer.
Alias-inherited overrides are discovered by the effective manager check
after files are installed and units reloaded. A failed check leaves the selected
cleanup timer stopped; reconcile the override before retrying installation.

The installed JSON at `/etc/auto-cleanup/docker/NAME.json` is the runtime and
lifecycle authority. It is root-owned and read-only to the cleanup account.
Systemd runs `auto-cleanup-docker@NAME.service` as that account; one timer
instance provides its schedule. All cleanup instances belong to the system
manager, including rootless targets: manage them with `sudo systemctl`.
The rootless Docker daemon's own user service is separate.
Inventory and its stable lock belong to the
cleanup account. The installer creates a missing protection directory without
changing ownership of existing directories.

### Target settings

Every field is required; unknown fields and duplicate JSON keys are rejected.

| Field | Meaning |
| --- | --- |
| `name` | Stable target name, also used in filenames and unit instances |
| `kind` | `rootful` or `rootless` |
| `user` | `root` for rootful; the actual non-root daemon owner for rootless |
| `socket` | Absolute local Unix socket path; remote Docker is unsupported |
| `daemon_config` | Actual daemon JSON path, or `null` to leave it unmanaged |
| `daemon_service` | Actual daemon service name, e.g. `docker.service`; `null` when unmanaged |
| `cache_gib` | Positive whole-GiB native build-cache GC target; `null` when unmanaged |
| `schedule` | `daily` or `weekly` |
| `container_until` | Disposable stopped-container creation age, e.g. `24h` |
| `network_until` | Unreferenced-network creation age, e.g. `24h` |
| `image_until` | Unprotected-image creation age, e.g. `168h` |
| `image_min_free_gib` | Free-space floor on the daemon's storage filesystem; `0` disables pressure eviction |
| `image_protection_mode` | `none`, `tags` or `inventory` |
| `image_keep_tags` | Nonempty list of explicit local repository:tags in `tags` mode; empty otherwise |
| `image_protection_file` | Absolute inventory path and lock base in every mode |

`daemon_config`, `daemon_service` and `cache_gib` must either all be supplied to
manage daemon logging and native cache GC together, or all be `null` to leave
that configuration unmanaged.

Hours must be positive whole numbers without leading zeros, within Docker's
supported duration range. Paths cannot contain whitespace, dot components or
shell syntax. The examples select daily cleanup, 24-hour container/network ages,
seven-day image retention, a 1 GiB cache budget and disabled pressure eviction.
Those values are explicit example choices, not an implicit profile applied on
updates. Account, kind, socket and protection path cannot change during an
update; remove and enroll a target to change its identity.

### What cleanup can remove

Only stopped containers labelled `auto-cleanup.disposable=true` are eligible.
Apply this label only when their writable files and logs may be deleted. Other
containers remain, including stopped and failed containers.

Unreferenced networks older than `network_until` are eligible across the selected
daemon. Network pruning has no disposable-label filter.

All container-referenced images are protected, including stopped containers and
references captured before disposable containers are removed. Additional image
protection is selected explicitly:

| Mode | Additional protection |
| --- | --- |
| `none` | None beyond container references |
| `tags` | Images currently selected by each listed local tag |
| `inventory` | Deployment, rollback and recovery images published by deployment tooling |

The examples use `none`. Compose files and unselected tags do not protect rollback
images. `latest` is a literal tag, not a request to select or pull a newer image.
A missing selected tag stops cleanup. If a selected tag moves, its new image is
protected and the previous image needs another protection source.

Unprotected images older than `image_until` are eligible even with ample free
space. Enabling `image_min_free_gib` also permits younger unprotected images to
be removed until the floor is reached. Protected images are never sacrificed
for this floor; insufficient reclaimable space produces failure. Age is measured
from creation, not last use, download or stop.

Images are removed individually by full local ID without force or implicit parent
pruning. Docker refusal is reported as failure. An operation can fail after some
deletions; completed deletion is not rolled back.

There is no automatic volume deletion, broad system prune, direct deletion under
Docker storage, database retention or disk alerting. Buildx caches are outside
this cleanup runner and need their own policy. Native daemon cache budgets add
up across daemons and are GC targets, not hard quotas. Daemons sharing a storage
filesystem observe the same available space; the free-space floor is not a
per-application allocation. RAM and database growth require separate management.

### Deployment inventory and locking

Inventory mode requires a publisher outside this repository. The publisher must
renew expiry even without a new deployment and hold the same exclusive lock
through inventory publication and deployment changes. See
[the inventory example](tests/fixtures/image-protection.json) for the format:
`version`, `daemon_id`, `expires_at`, `deployments` with current/rollback digest
lists, and recovery digests. Digests must resolve to local immutable images.

Cleanup uses `image_protection_file + ".lock"` in every mode. Inventory mode
also reads the JSON file; other modes use the path only as a lock base. Inventory
and lock must be regular files owned by the cleanup account and not writable
by group or others; use mode `0600`. Never replace or unlink the stable lock.
Missing, expired, changed, wrong-daemon or unresolved inventory stops cleanup.
The runner rechecks inventory before mutations. Clients ignoring the lock can
race deployment and cleanup.

### Daemon logging and cache configuration

With a non-null `daemon_config`, installation merges `local` logging defaults
(`10m` × `3`, compressed) and the cache budget. Unrelated daemon and builder
settings remain; owned logging settings and the entire `builder.gc` section are
replaced. A backup preserves the previous file's ownership and mode. Configuration
must still match the validated candidate when applied; otherwise installation
refuses the write. Rootless configuration work runs as its owner.

Installation writes configuration but does not restart Docker by default.
Use `--restart-docker` only when interruption is acceptable; it restarts the
selected system service or owner user service. A failed restart restores the
previous daemon configuration and attempts recovery, while other installation
changes remain. New logging defaults affect newly created containers; the app
operator owns any recreation. Existing bounded Compose log settings can remain.
Native cache GC runs independently of the cleanup timer and can reclaim recent
unused cache.

## Operate, update and remove

```sh
sudo ./scripts/auto-cleanup docker list
sudo ./scripts/auto-cleanup docker check agent-mail --live
sudo systemctl enable --now auto-cleanup-docker@agent-mail.timer
sudo systemctl start auto-cleanup-docker@agent-mail.service
sudo journalctl -u auto-cleanup-docker@agent-mail.service -n 100 --no-pager
```

Enabling a persistent timer can trigger a missed run soon afterward. A manual
service start performs cleanup. `docker check` validates installed files and
on-disk policy; `--live` also inspects daemon identity, effective systemd execution
and schedule, and timer state. Neither
runs cleanup or proves on-disk cache settings are active in a running daemon.

Edit a reviewed copy of the saved target and apply it with `--config`, or update
software using saved settings:

```sh
sudo git pull --ff-only
sudo ./scripts/auto-cleanup docker install agent-mail
sudo ./scripts/auto-cleanup host install
```

Updates pause the selected timer and stop its cleanup service before publishing
changes, then resume a previously active timer on success. A changed shared
runtime also pauses other enrolled cleanup services/timers and resumes active
timers after successful publication. Failures can leave cleanup paused; inspect
logs and installed files before retrying. Lifecycle mutations are serialized by
a protected installation lock. This lock is separate from deployment locks.

```sh
sudo ./scripts/auto-cleanup docker remove agent-mail --dry-run
sudo ./scripts/auto-cleanup docker remove agent-mail
sudo ./scripts/auto-cleanup host remove
```

Removing a target disables/stops its timer and stops its service. It preserves
its daemon configuration, inventory/lock and all Docker data. Shared runtime
files are removed only when no targets remain. Removing host maintenance leaves
Docker targets alone. External host policies remain.

`scripts/install.sh`, `check.sh` and `uninstall.sh` are thin scoped entrypoints:
for example, `sudo ./scripts/install.sh host` or
`sudo ./scripts/check.sh docker agent-mail`. Bare legacy flags are unsupported.
Use `scripts/auto-cleanup` for listing and migration.

## Migrate a legacy singleton installation

Prepare a reviewed rootful JSON target matching the effective old policy and
operator overrides. Keep the old protection/lock path and set `daemon_config`,
`daemon_service` and `cache_gib` to `null` to preserve existing Docker settings.

```sh
sudo ./scripts/auto-cleanup docker migrate --config /absolute/reviewed-rootful.json --dry-run
sudo ./scripts/auto-cleanup docker migrate --config /absolute/reviewed-rootful.json
```

Migration supports the bundled baseline legacy executable/units and simple
literal EnvironmentFile assignments. It refuses custom or unsupported artifacts,
unit overrides, complex quoting, unknown settings or policy changes before
handoff. It stops/disables the old timer, stops the old service, installs the
replacement, then removes obsolete managed files. The new timer stays disabled
unless `--enable-timer` is explicitly supplied. A failed handoff can leave the old
files intact with scheduling paused; inspect before retrying.

Host and daemon policies, operator override history, inventory and lock remain.
The old override file is historical input after migration; the new target JSON
owns future settings. Enroll host maintenance separately. To change policy or
manage the daemon configuration, first migrate unchanged, then update the target.
The archived legacy fixtures are migration comparison data, never installed or
executed by the new lifecycle.

## Staging and verification

Add `--root /absolute/stage` to install/check/remove/migrate commands to use an
offline file tree. Staging never contacts Docker or systemd managers, never runs
cleanup, and does not prove target-host readiness. Temporary native-policy probes
still run inside the caller environment. Dry runs preview managed changes without
writing them. Installation is not a transaction across every component; failures
may leave earlier changes in place.

Tests are container-only; use `make test`. The repository wrapper copies an
allowlisted context into pinned Debian/Ubuntu images. Runtime lanes are offline,
read-only, resource bounded and have no host Docker socket or source write mount.
The narrow root lane covers metadata and configured rootful execution; the broad
non-root lane covers configured rootless execution using a fake Docker boundary.
These prove argument, ownership, retention and refusal behavior; they do not
qualify a real target-host Docker daemon or systemd scheduling.

```sh
make test
make test/all
```
