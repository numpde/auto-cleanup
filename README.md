# auto-cleanup

Install disk-retention policies for a Linux Docker host: image, container and
network cleanup; local build-cache and log limits; journald retention; failed-login
log rotation; and APT cache cleanup.

The cleanup service always protects images referenced by containers. Choose
whether to retain additional images through selected local tags or a deployment
inventory, or to apply cleanup to all images without container references.
**Before enabling cleanup, choose [an image protection mode](#2-choose-image-protection-and-review-existing-schedules).**
The default remains `inventory`; it requires a valid deployment inventory.

## Requirements and defaults

Use a complete checkout on a Debian/Ubuntu-style systemd host with Python 3.11+,
Docker CLI, logrotate, apt-config, the distro's APT periodic machinery, and standard shell
utilities. Python is required for cleanup even with `--skip-docker-config`.
Managed local build-cache limits require Docker Engine 28+ and a qualifying
`dockerd` binary on a real host; staging without `dockerd` reports that target
requirement.

Cleanup always selects the rootful local daemon at
`unix:///var/run/docker.sock`, ignoring ambient Docker context, host and TLS
settings. The daemon configuration applies to its default `docker` builder.
Custom Buildx builders, remote builders and rootless Docker require their own
configuration. CI manages its builders' cache retention.

| Docker policy | `vps` (default) | `workstation` |
| --- | --- | --- |
| Native build-cache budget | 1 GiB | 40 GiB |
| Scheduled cleanup | Daily | Weekly |
| Unprotected images without container references | Created over 24 hours ago | Created over 14 days ago |
| Disposable stopped containers | Created over 24 hours ago | Created over 7 days ago |
| Unreferenced networks | Created over 24 hours ago | Created over 7 days ago |

A fresh installation selects `vps`. Reinstalling without `--profile` preserves
the saved profile and cache budget. Explicit `--profile` selects that profile's
defaults; `--cache-gib N` overrides its cache budget.

| Area | Default |
| --- | --- |
| Docker logs | `local` driver, `10m` x `3`, compressed |
| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |
| btmp | rotate at `50M`, keep 1 compressed rotated file |
| APT cache | autoclean every 7 days, clean every 30 days |

These are retention targets, not disk quotas. Shared layers, active cache,
application data and other filesystem users may prevent enough space being freed.
No disk alerting service is installed.

This repo does not install jobs that run `docker system prune --volumes` or
`docker volume prune`, perform direct deletion under `/var/lib/docker`, or delete
APT/dpkg locks. Volumes are never pruned. Temporary-file cleanup remains with
the distro's existing machinery.

## Prepare and install

### 1. Review the intended changes

```sh
./scripts/install.sh --dry-run --no-enable-timer
./scripts/install.sh --profile workstation --dry-run --no-enable-timer
```

Dry-run installs no files, but still parses existing daemon JSON when Docker
configuration is managed. For a file-tree preview, stage under a temporary root:

```sh
./scripts/install.sh --root /tmp/auto-cleanup-root
./scripts/check.sh --root /tmp/auto-cleanup-root --strict
find /tmp/auto-cleanup-root -type f -print
```

Staging preserves the normal absolute layout beneath that root and skips service
actions. Dry-run and staging can run without sudo.

### 2. Choose image protection and review existing schedules

Choose one mode for `/etc/default/vps-docker-clean`, the operator's systemd
EnvironmentFile. The installer preserves this file on reinstall. All modes protect
container references and apply the same age and free-space rules to other images.

| Mode | Additional image protection | Preparation |
| --- | --- | --- |
| `none` | None | Set `IMAGE_PROTECTION_MODE=none` |
| `tags` | Images currently bearing selected local tags | Set the mode and a nonempty `IMAGE_KEEP_TAGS` list |
| `inventory` (default) | Deployment, rollback and recovery digests | Configure tooling to publish and renew [the inventory](#deployment-inventory-mode) |

For container references alone, use:

```ini
IMAGE_PROTECTION_MODE=none
```

To also keep selected tagged images, use their exact local repository:tag names:

```ini
IMAGE_PROTECTION_MODE=tags
IMAGE_KEEP_TAGS='my-app:latest other:stable'
```

Cleanup resolves tags to local image IDs automatically. `latest` is a literal tag
name; it does not select the newest image or fetch anything from a registry.
Every selected tag must exist locally before any pruning can start.

Leaving the mode unset selects `inventory`. An absent or invalid inventory blocks
the entire cleanup service, including container and network pruning. Setting
`none` or `tags` intentionally replaces inventory protection, even if an inventory
already exists. These modes need no inventory publisher. Remove any nonempty
`IMAGE_KEEP_TAGS` when selecting `none` or `inventory`; it is rejected outside
`tags` mode. See [image protection](#image-protection) for tag changes and the
shared lock.

When replacing an existing cleanup schedule, disable its image-pruning jobs and
wait for any active run to finish before preparing the replacement. Use one host
image-retention schedule. Stop an already active `vps-docker-clean.timer` before
changing its installation, then wait for any running cleanup service to finish.
Stopping the timer does not stop an existing run; `--no-enable-timer` does not
stop the timer.

### 3. Install without enabling cleanup

```sh
sudo ./scripts/install.sh --no-enable-timer
# Or select workstation defaults and a cache budget:
sudo ./scripts/install.sh --profile workstation --cache-gib 8 --no-enable-timer
sudo ./scripts/check.sh --strict
```

The default destinations are:

| File | Purpose |
| --- | --- |
| `/usr/local/sbin/vps-docker-clean` | Cleanup executable |
| `/etc/systemd/system/vps-docker-clean.{service,timer}` | Service and schedule |
| `/etc/default/vps-docker-clean.policy` | Generated profile settings |
| `/etc/docker/daemon.json` | Docker logging and local cache GC |
| `/etc/systemd/journald.conf.d/auto-cleanup-limits.conf` | Journal limits |
| `/etc/logrotate.d/auto-cleanup-btmp` | Conditional btmp policy |
| `/etc/apt/apt.conf.d/90auto-cleanup-periodic` | Conditional APT policy |

The installer preserves an existing operator override file and does not create
the protection inventory. Review existing btmp and APT policy before installing;
use their skip flags when those policies are managed elsewhere. Detection rules
are described under [host policies](#host-policies).

With service actions enabled, installation reloads systemd and restarts journald
unless skipped. Without `--no-enable-timer`, it also enables and starts the timer.
The timer is persistent: it can catch up a missed run immediately, adds up to an
hour of randomized delay, and uses `AccuracySec=1h`.

Docker is restarted only with `--restart-docker`. Otherwise daemon changes remain
on disk until a restart. If Docker configuration was managed, arrange a restart
to activate the cache budget and logging defaults. Existing containers need
recreation only to adopt those logging defaults. These actions can interrupt
workloads; run Compose commands from each workload's own project directory.

A failed installer-requested Docker restart restores the previous daemon JSON
and attempts one recovery restart. Recovery is reported separately; installation
still fails, and earlier file and service changes remain. Follow a slow restart
with `sudo journalctl -fu docker.service`.

### 4. Inspect and enable

Review the profile and override files, confirm your chosen image protection mode
is prepared, and use the [inspection commands](#inspect-and-run) below. For
`inventory`, confirm publication, renewal and deployment lock participation.
Installed policy checks do not validate selected tags or the protection inventory,
or prove that daemon changes are active.

Once ready:

```sh
sudo systemctl enable --now vps-docker-clean.timer
sudo systemctl status vps-docker-clean.timer
sudo journalctl -u vps-docker-clean.service -n 100 --no-pager
```

Inspect the first service result and actual filesystem free space.

### Installation options

Run `./scripts/install.sh --help` for the complete CLI.

| Option | Effect |
| --- | --- |
| `--profile vps\|workstation` | Select profile defaults |
| `--cache-gib N` | Positive whole-GiB cache budget, up to 8589934591 |
| `--skip-docker-config` | Leave Docker logging and native cache GC unmanaged |
| `--skip-journald` | Leave journald policy unmanaged |
| `--skip-btmp-logrotate` | Leave btmp policy unmanaged |
| `--skip-apt-periodic` | Leave APT policy unmanaged |
| `--restart-docker` | Restart Docker during installation |
| `--no-enable-timer` | Do not enable or start the timer |
| `--no-service-actions` | Skip all systemctl calls |
| `--root DIR` | Stage beneath another root |
| `--prefix DIR` | Change executable prefix, default `/usr/local` |
| `--etc-dir DIR` | Change configuration root, default `/etc` |

Use `--no-service-actions` for file-only installation where systemd is unavailable.
Service actions are automatically skipped with `--root` or custom `--etc-dir`.
`--root`, `--prefix` and `--etc-dir` must be absolute paths other than `/`.
They must not start with `//` or contain `.` or `..` path components. Whitespace,
`&`, `|`, backslashes, `%`, `#`, `;`, `$`, quotes and backticks are rejected
before writing.

## Image protection

Container image IDs are protected in every mode, including stopped containers
and references captured before disposable-container pruning. Cleanup retains those
captured references for the entire run and adds container references found before
image removal. An absent container source image does not block unrelated cleanup.

In `none` mode, container references are the only image protection. In `tags`
mode, cleanup also protects each selected tag's current local image. It checks
tags again before pruning and image removal. If a tag moves, its new target is
protected; the old target becomes eligible if no remaining protection covers it.
If a selected tag disappears, cleanup stops. Earlier deletions are not rolled back.
Tags outside `IMAGE_KEEP_TAGS` do not provide additional protection.

### Shared lock in every mode

All cleanup invocations for one daemon must use the same `IMAGE_PROTECTION_FILE`
path. Cleanup takes an exclusive lock on that path plus `.lock`, by default
`/etc/default/vps-docker-clean.images.json.lock`. Its parent directory must already
exist. In `none` and `tags` modes, the configured path is used only to locate the
lock; cleanup does not read an inventory there.

The lock must be a regular file, not a symlink, owned by root for the installed
service, with no group or other write permission; use mode `0600`. Cleanup creates it if absent
and fails promptly if it is busy. Never replace or unlink the lock file.
Deployment tooling can use the same exclusive `flock` through image/container
changes to coordinate with cleanup. Clients that ignore the lock can race cleanup.

### Deployment inventory mode

`inventory` is the default and preserves the existing requirement for an explicit,
valid inventory. Docker cannot decide which unused image you intend to retain for
a future deployment, rollback or recovery. Deployment tooling must publish those
choices and renew the inventory's expiry, even when no new deployment occurs.
Cleanup cannot discover an omitted rollback requirement. This repository supplies
the reader, not a publisher or deployment lock participant.

The default inventory path is `/etc/default/vps-docker-clean.images.json`.

The following shows the format; replace all placeholders, including expiry,
with real values before use:

```json
{
  "version": 1,
  "daemon_id": "REPLACE_WITH_LOCAL_DOCKER_ID",
  "expires_at": "REPLACE_WITH_FUTURE_TIMESTAMP_WITH_TIMEZONE",
  "deployments": {
    "app": {
      "current": ["registry.example/app@sha256:REPLACE_WITH_64_HEX_DIGEST"],
      "rollback": []
    }
  },
  "recovery": []
}
```

Obtain the daemon identity with:

```sh
sudo docker --host unix:///var/run/docker.sock info --format '{{.ID}}'
```

Inspect each intended image, replacing `IMAGE_REFERENCE` with its real reference:

```sh
sudo docker --host unix:///var/run/docker.sock image inspect IMAGE_REFERENCE
```

Use the immutable repository digests in `RepoDigests`. Every listed digest must
resolve locally to that same digest. Remote-only images do
not count as retained local recovery. The inventory must name at least one deployment. Each deployment needs a
nonempty `current` list; `rollback` and `recovery` may be empty when none are deliberately retained.
Timestamps require a timezone, for example `2030-01-01T00:00:00Z`.

Keep the inventory owned by root for the installed service as a regular file,
not a symlink, without group or other write permission; use mode `0600`. Missing,
expired, malformed, insecure or wrong-daemon inventories block cleanup. Duplicate
JSON keys and unknown fields are rejected. The maximum inventory size is 1 MiB.

All deployment publishers must use the same inventory path and participate in
[the shared lock](#shared-lock-in-every-mode). Hold an exclusive `flock` before
pulling images or changing containers and through atomic publication of the final
inventory. Write a temporary file in the same directory and rename it while
holding the lock. Before dropping old container references, publish the union of
current, incoming and rollback digests after they resolve locally.

Cleanup rechecks inventory bytes and expiry immediately before each mutation.
Changed or expired inventory stops further deletion. Explicitly listed inventory
digests must exist locally when the inventory is loaded.

## Cleanup policy and overrides

Only stopped containers labelled `auto-cleanup.disposable=true` are eligible for
container pruning. Apply that label only when their writable files and logs may
be deleted. Ordinary containers remain retained, including stopped or failed ones.
All age thresholds measure creation age, not time since last use or download.
Compose files do not protect images; tags protect them only when selected in
`tags` mode.

Image cleanup considers the oldest images first, preserving container references
and the additional protection selected by the mode. An unprotected image older
than `IMAGE_UNTIL` is eligible regardless of free space. When `IMAGE_MIN_FREE_GIB` is nonzero, space pressure
may also evict younger unprotected images until that free-space floor is reached.
Available bytes are measured on Docker's reported root filesystem; shared image
sizes and Docker's reclaimable estimate are not counted as released bytes.
Protected images are never removed to meet the floor. An unmet floor produces
failure rather than permission to delete protected images or other data.

Images are removed by full local ID without force or implicit parent pruning.
Docker may refuse removal of an image with multiple tags; cleanup retains it and
reports failure. See [Docker image removal](https://docs.docker.com/reference/cli/docker/image/rm/).

For service runs, place optional overrides in `/etc/default/vps-docker-clean`:

```ini
IMAGE_UNTIL=168h
IMAGE_MIN_FREE_GIB=5
```

This is a systemd EnvironmentFile, not a shell script; shell expansions are not
evaluated. `DOCKER` must name one executable, not a command line with arguments.
See [the override template](fixtures/default/vps-docker-clean.example).

| Setting | Default and accepted values |
| --- | --- |
| `DOCKER` | `docker`; an executable name or path |
| `CONTAINER_UNTIL`, `NETWORK_UNTIL`, `IMAGE_UNTIL` | Profile defaults; positive whole hours such as `48h`, without leading zeros |
| `IMAGE_MIN_FREE_GIB` | `0` disables pressure; nonnegative whole GiB without leading zeros |
| `IMAGE_PROTECTION_MODE` | `inventory`; `none`, `tags` or `inventory` |
| `IMAGE_KEEP_TAGS` | Empty; whitespace-separated explicit local repository:tag names; must be nonempty in `tags` mode and empty in other modes |
| `IMAGE_PROTECTION_FILE` | `/etc/default/vps-docker-clean.images.json`; absolute path for inventory mode and the lock base in every mode; parent directory must exist |

Systemd reads the generated `.policy` first and overrides second. Change profile
and cache budget through installer options, not by editing the generated file.
Obsolete `BUILD_CACHE_UNTIL`, `BUILD_CACHE_RESERVED` and `ALLOW_BUILDX_PRUNE`
overrides are rejected; remove them before upgrading.

## Inspect and run

Check installed files and expected policy without cleanup:

```sh
sudo ./scripts/check.sh --strict
```

Use the same component skip flags and custom paths as installation. Repo-owned
configuration files must match their source fixtures or rendered templates;
place supported custom settings in the operator override file or service drop-ins. Without
`--strict`, the checker reports discrepancies without making them a failing exit
status. On a real host it also reports timer state and free space on `/`; that
space report does not validate the Docker filesystem free-space floor. It checks
policy on disk, not tag availability, inventory completeness, effective overrides,
deployment lock participation or the running daemon's activation of that policy.
No command validates selected tags or the inventory alone: starting the service
checks the selected mode's protection and then performs cleanup.

To inspect effective cleanup policy settings without contacting Docker or pruning,
use the default installation paths:

```sh
sudo systemd-run --wait --pipe --collect \
  -p EnvironmentFile=/etc/default/vps-docker-clean.policy \
  -p EnvironmentFile=-/etc/default/vps-docker-clean \
  /usr/local/sbin/vps-docker-clean --show-policy
```

This temporary service reads defaults then overrides; it does not inherit custom
cleanup-service drop-ins. Adjust paths for a custom installation. Direct
`--show-policy` execution requires the three age variables to be supplied.

To perform cleanup immediately:

```sh
sudo systemctl start vps-docker-clean.service
sudo journalctl -u vps-docker-clean.service -n 100 --no-pager
```

A missing CLI, unreachable daemon or failed protection check produces a nonzero
exit. A nonzero result from a prune or image-removal command is logged; cleanup
tries the remaining candidates and categories, then reports failure. Inspection
errors, timeouts, missing selected tags and changed or expired inventories stop
the run. Earlier deletions are not rolled back. Each Docker command has a
two-minute timeout; the service has a thirty-minute total timeout.
After a timeout, inspect actual state before assuming every deletion completed.

## Host policies

Docker daemon JSON is merged and backed up before modification. Unrelated daemon
and `builder` settings remain; the entire `builder.gc` section and logging
settings are replaced with this repository's policy. Cache GC uses the selected
size budget and zero reserved cache. It operates independently of scheduled
image cleanup and can reclaim recent unused cache; no age exemption applies.
The budget is a GC target. See [BuildKit GC](https://docs.docker.com/build/cache/garbage-collection/).

Existing daemon-file mode and ownership are preserved. When available, `dockerd`
validates the planned JSON before installation and the installed JSON during
strict checks. This does not detect duplicate Docker service command-line
logging flags; resolve those before restarting Docker. Managed files and their
existing parent directories cannot be symlinks, and destinations cannot be
non-regular files.

APT cleanup uses the distro's existing timers and `apt.systemd.daily`.
`apt-config` determines effective settings, including filename eligibility,
configuration order and `apt.conf`. Installation preserves existing enabled
cleanup; update-only or disabled intervals do not count. Before installing its
fixture, it checks a temporary candidate configuration. If other settings would
leave cleanup disabled, installation fails before writing managed files; correct
those settings or use `--skip-apt-periodic`. Strict checks also require effective
cleanup to remain enabled. The repo-owned fixture is refreshed on reinstall.

For btmp, native logrotate directory inspection determines which files are
selected and the effective size limit. Matching external policy is preserved.
An existing btmp stanza with no matching limit, duplicate entries or configuration
parse errors stops installation before managed writes; update the existing
stanza or use `--skip-btmp-logrotate`. Ignored backup files do not count as policy.
Reinstallation refreshes the repo-owned fixture. The inspector reads the selected
`logrotate.d` directory using logrotate defaults; it does not validate separate
settings in the host's main `logrotate.conf`. Strict checks require the matching
btmp size policy. Component installs must use matching checker skip flags.

### Install only btmp rotation

Install `logrotate`, back up the previous policy outside `/etc/logrotate.d`, and
use [the btmp fixture](fixtures/logrotate/btmp) as `/etc/logrotate.d/btmp`.
Ensure only one active stanza refers to `/var/log/btmp`.

For hourly checks, install [the timer drop-in](examples/logrotate.timer.d/hourly.conf)
as `/etc/systemd/system/logrotate.timer.d/hourly.conf`, then:

```sh
sudo logrotate --debug /etc/logrotate.conf
sudo systemctl daemon-reload
sudo systemctl enable --now logrotate.timer
sudo systemctl restart logrotate.timer
sudo systemctl start logrotate.service
```

This manual example is not installed by `install.sh`. It changes the distro's
logrotate schedule, so all its policies are checked hourly. Use an ordinary
service run rather than forcing rotation of every package log.

The fixture rotates monthly or when a check sees more than `50M`, keeps one
compressed archive, and creates a replacement owned by `root:utmp` with mode
`0660`. Growth between checks can exceed `50M`. Ensure space for compression of
the existing log, then inspect service results, the next trigger and file sizes.

## Uninstall

Preview removal first:

```sh
sudo ./scripts/uninstall.sh --dry-run
```

On a live host, stop the timer and wait for any running cleanup service to finish.
Stopping the timer prevents scheduled runs but does not stop an existing run:

```sh
sudo systemctl stop vps-docker-clean.timer
sudo systemctl status vps-docker-clean.service
```

Once no cleanup run remains:

```sh
sudo ./scripts/uninstall.sh
```

Removal attempts to disable and stop the timer, removes the executable,
service/timer units, generated profile and selected optional policies, reloads
systemd, and restarts journald unless skipped. Verify that the timer stopped;
uninstall continues if the disable command fails. It preserves the operator override, deployment
inventory/lock and Docker daemon JSON. It does not restore deleted resources.

Use matching `--root`, `--prefix` and `--etc-dir` for custom installs. The optional
policy skip flags leave those files installed; `--no-service-actions` skips
systemctl. Staged or custom-configuration removal skips service actions
automatically. Uninstall refuses unexpected non-regular destinations but can
remove symlinks at repo-owned file paths.

To restore an explicit daemon backup:

```sh
sudo ./scripts/uninstall.sh \
  --restore-docker-backup /etc/docker/daemon.json.auto-cleanup.bak.YYYYMMDDTHHMMSSZ
```

The backup must be an absolute path to a regular file, not a symlink, and must
follow the [installation path restrictions](#installation-options). Restore
preserves metadata where permitted and refuses a symlink/non-regular destination.
With `--root`, the backup is read from the current filesystem and the restore
destination is staged. Restart Docker to activate restored settings; recreate
containers only if they need to adopt restored logging defaults.

## Repository tests

Tests are container-only; use `make test`. The test container has no network or
Docker socket, so retention checks exercise a Docker test double rather than
pruning host resources.

```sh
make test
make test/all
```

`make test` runs the Debian suite. `make test/all` adds Ubuntu, build-context
canaries and root metadata checks. The broad suites run without root or
capabilities, with a read-only filesystem and an explicit build-context
allowlist. Test-image builds need engine access and network when dependencies
are not cached. Use `make test/matrix`, `make test/posture` or
`make test/root-container` for individual lanes; `make shell` opens the test image.
