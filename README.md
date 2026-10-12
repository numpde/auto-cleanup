# auto-cleanup

Automatically remove old, unused Docker images and limit log and cache growth. Install a daily VPS schedule or a weekly workstation schedule.

By default, image cleanup removes images created more than 24 hours ago that no
container references. Images used by running **or stopped** containers are kept.
Volumes are never pruned. You can also keep selected images by tag, such as
`my-app:latest`.

The installer also configures Docker build-cache and log limits, system journal
retention, failed-login log rotation, and APT cache cleanup. These policies limit
retention; they cannot guarantee free disk space.

## Quick commands

Run repository commands from the checkout on the Docker host. Examples use
`sudo`; omit it when logged in as root. The commands below use the default paths.

### Install on a fresh host

Requires a Debian/Ubuntu-style systemd host with Python 3.8+, Docker, logrotate,
and APT tools. Managing Docker's logging and build-cache settings requires Docker
Engine 28+ and its `dockerd` executable. Use `--skip-docker-config` on older Docker
or when you want to leave those settings alone.

If cleanup is already installed, use [Update or change settings](#update-or-change-settings)
instead. Disable any other scheduled Docker image-pruning jobs and wait for
their active runs to finish before installing.

**Get the repository:**

```sh
git clone https://github.com/numpde/auto-cleanup.git
cd auto-cleanup
```

**Preview the default VPS installation.** This prints planned actions without
installing files or starting services:

```sh
sudo ./scripts/install.sh --profile vps --dry-run
```

**Install and enable daily cleanup.** This allows unused images older than 24
hours to be removed; no image inventory or configuration edit is needed:

```sh
sudo ./scripts/install.sh --profile vps
```

Installation enables the Docker cleanup timer and restarts journald. A missed
timer run can trigger cleanup soon after installation. Docker itself is **not
restarted**: its new cache and logging settings wait for a later restart.
Existing containers keep their logging settings until recreated.

To keep Docker's configuration unchanged, use this install command **instead**,
and add `--skip-docker-config` to the preview and checker commands too:

```sh
sudo ./scripts/install.sh --profile vps --skip-docker-config
```

To inspect the installation before allowing scheduled Docker cleanup, add
`--no-enable-timer` to your install command. This only prevents starting the
Docker cleanup timer; it does not postpone the other host policies.

### Check the installation

**Check installed files and policy; do not run cleanup:**

```sh
sudo ./scripts/check.sh --strict
```

If you installed with `--skip-docker-config`, check with the same flag:

```sh
sudo ./scripts/check.sh --strict --skip-docker-config
```

Repeat any other component skip flags and custom paths used for installation.
A successful check does not prove that Docker has loaded its new settings or
that optional protected tags or an inventory are valid.

**Show the schedule:**

```sh
sudo systemctl list-timers vps-docker-clean.timer
```

### Run cleanup now

**Delete eligible Docker resources now, then read the result:**

```sh
sudo systemctl start vps-docker-clean.service
sudo journalctl -u vps-docker-clean.service -n 100 --no-pager
sudo systemctl show vps-docker-clean.service -p Result -p ExecMainStatus
df -h /
```

`systemctl start` waits for this run to finish. `Result=success` and
`ExecMainStatus=0` indicate success; an inactive service after completion is
normal. Failed runs may have removed some resources before stopping.
The space shown by `df` is for `/`; Docker may store its data on another filesystem.

### Pause or enable scheduled cleanup

**Disable scheduled Docker cleanup until you enable it again:**

```sh
sudo systemctl disable --now vps-docker-clean.timer
sudo systemctl status vps-docker-clean.service --no-pager
```

Disabling the timer does not stop an active cleanup run. Wait for that service
to finish before updating or uninstalling. It also does not stop Docker's own
build-cache cleanup, journald, logrotate, or APT cleanup.

**Enable daily/weekly cleanup using the saved profile:**

```sh
sudo systemctl enable --now vps-docker-clean.timer
sudo systemctl list-timers vps-docker-clean.timer
```

Enabling the timer schedules runs; it does not guarantee a run immediately.
Use [Run cleanup now](#run-cleanup-now) for a first run you can inspect.

## Defaults and what can be removed

| Docker policy | `vps` (default) | `workstation` |
| --- | --- | --- |
| Native build-cache budget | 1 GiB | 40 GiB |
| Scheduled cleanup | Daily | Weekly |
| Unprotected images without container references | Created over 24 hours ago | Created over 14 days ago |
| Disposable stopped containers | Created over 24 hours ago | Created over 7 days ago |
| Unreferenced networks | Created over 24 hours ago | Created over 7 days ago |

Only stopped containers labelled `auto-cleanup.disposable=true` can be pruned.
Apply that label only when their writable files and logs may be deleted.
Other containers remain, including stopped or failed ones. Age means time since
creation, not time since last use, download, or container stop.

| Area | Default |
| --- | --- |
| Docker logs | `local` driver, `10m` x `3`, compressed |
| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |
| btmp | rotate at `50M`, keep 1 compressed rotated file |
| APT cache | autoclean every 7 days, clean every 30 days |

`btmp` records failed logins. Its policy rotates monthly or when a logrotate
check sees more than `50M`; the file can grow beyond that size between checks.
The APT policy also enables daily package-list refreshes. Existing enabled APT
cleanup and matching btmp policies are preserved; see [Host policies](#host-policies).

Shared image layers, active cache, application data, and other filesystem users
can prevent enough space being freed. There is no disk alerting service.
This repo does not install jobs that run `docker system prune --volumes` or
`docker volume prune`, perform direct deletion under `/var/lib/docker`, or delete
APT/dpkg locks. Temporary-file cleanup stays with the distro's existing tools.

Cleanup targets the local Docker daemon at `unix:///var/run/docker.sock`,
ignoring Docker context, host, and TLS environment settings. Rootless Docker and
remote daemons are outside its scope. Build-cache limits apply to the daemon's
default builder; custom Buildx builders and CI builders need separate policies.

## Update or change settings

First [stop the timer and wait for any active cleanup](#pause-or-enable-scheduled-cleanup).
Run the desired installer command once, check the installation, then re-enable
the timer. To update the code in a clean checkout, fetch it before reinstalling:

```sh
git pull --ff-only
```

Pulling updates the checkout; reinstalling updates the service's installed files.
The scheduled service does not run from the checkout.

Choose **one** of these installer commands, adding your component skip flags and
custom paths as needed:

| Intended change | Command |
| --- | --- |
| Reinstall using saved profile, cache budget, and image protection | `sudo ./scripts/install.sh --no-enable-timer` |
| Retain no extra images beyond container references | `sudo ./scripts/install.sh --image-protection none --no-enable-timer` |
| Also keep the local image tagged `my-app:latest` | `sudo ./scripts/install.sh --keep-image my-app:latest --no-enable-timer` |
| Keep two selected tags | `sudo ./scripts/install.sh --keep-image my-app:latest --keep-image other:stable --no-enable-timer` |
| Select workstation ages/schedule and an 8 GiB cache budget | `sudo ./scripts/install.sh --profile workstation --cache-gib 8 --no-enable-timer` |

Reinstalling without `--profile` preserves the profile and cache budget.
Supplying `--profile` resets its ages, schedule, and cache budget to that profile's
defaults; `--cache-gib` overrides the budget. Host age overrides still take
precedence over profile ages. Image protection is preserved unless
you select a new mode or tag list.

`--keep-image` selects tag protection and replaces the saved tag list with all
tags supplied in that invocation. Every chosen tag must exist locally before
cleanup. `latest` is a literal tag name: it does not select the newest image or
pull from a registry. Selecting `none` or `inventory` clears the saved tag list.
Older policies without a saved mode conservatively select `inventory` on reinstall;
use `--image-protection none` to select ordinary unused-image cleanup explicitly.

**Skip flags are not saved.** Supply them on each install and check. Omitting
`--skip-docker-config` on a later install permits Docker configuration changes.
Skip flags leave existing files and policies in place; they do not disable them.
Likewise, `--no-enable-timer` does not stop a timer that is already active.

If `/etc/default/vps-docker-clean` already assigns `IMAGE_PROTECTION_MODE` or
`IMAGE_KEEP_TAGS`, remove those assignments before selecting protection through
installer options. The installer otherwise refuses the choice before writing,
and preserves the override file.

## Installation reference

Run `./scripts/install.sh --help` for all options. Python 3.8+ is required even
when Docker configuration management is skipped. The host also needs `apt-config`,
the distro's APT periodic machinery, logrotate, and standard shell utilities for
the components you install.

| Option | Effect |
| --- | --- |
| `--profile vps\|workstation` | Select profile defaults |
| `--cache-gib N` | Positive whole-GiB cache budget, up to 8589934591 |
| `--image-protection none\|tags\|inventory` | Select extra image protection; `tags` needs a saved or supplied nonempty tag list |
| `--keep-image TAG` | Keep a local repository:tag; repeat for multiple tags; replaces the saved list |
| `--skip-docker-config` | Leave Docker logging and native build-cache cleanup configuration unchanged |
| `--skip-journald` | Leave journald policy unchanged |
| `--skip-btmp-logrotate` | Leave btmp policy unchanged |
| `--skip-apt-periodic` | Leave APT policy unchanged |
| `--restart-docker` | Restart Docker after configuring it, when service actions are enabled |
| `--no-enable-timer` | Do not enable or start the Docker cleanup timer |
| `--no-service-actions` | Skip all systemctl calls; files are still installed |
| `--dry-run` | Print planned actions without installing files or changing services |
| `--root DIR` | Stage beneath another root; skip service actions |
| `--prefix DIR` | Change executable prefix, default `/usr/local` |
| `--etc-dir DIR` | Change configuration root, default `/etc`; skip service actions |

### Installed files and activation

| File | Purpose |
| --- | --- |
| `/usr/local/sbin/vps-docker-clean` | Cleanup executable |
| `/etc/systemd/system/vps-docker-clean.{service,timer}` | Service and schedule |
| `/etc/default/vps-docker-clean.policy` | Generated profile and image protection settings |
| `/etc/docker/daemon.json` | Docker logging and native build-cache cleanup |
| `/etc/systemd/journald.conf.d/auto-cleanup-limits.conf` | Journal limits |
| `/etc/logrotate.d/auto-cleanup-btmp` | Conditional btmp policy |
| `/etc/apt/apt.conf.d/90auto-cleanup-periodic` | Conditional APT policy |

The installer reloads systemd, enables the timer unless requested otherwise, and
restarts journald unless skipped. The persistent timer can catch up a missed run;
it adds up to an hour of randomized delay and uses `AccuracySec=1h`.

Docker configuration changes wait for a restart. Use `--restart-docker` during
installation only when you are ready for running workloads to be interrupted.
This option has no effect with `--skip-docker-config` or disabled service actions.
Existing containers must be recreated to adopt new daemon logging defaults.
A failed installer-requested restart restores the previous Docker configuration
and attempts one recovery restart. Installation still fails; earlier file and
service changes remain. Follow progress with `sudo journalctl -fu docker.service`.

### Preview files and custom paths

For a file-tree preview without installing on the host:

```sh
./scripts/install.sh --root /tmp/auto-cleanup-root
./scripts/check.sh --root /tmp/auto-cleanup-root --strict
find /tmp/auto-cleanup-root -type f -print
```

Staging writes beneath the supplied root and skips service actions. Dry-run and
staging can run without sudo when their inputs are readable. They still inspect
host tool versions and parse relevant configuration. Without `dockerd`, staging
reports the Docker 28+ target requirement and skips daemon validation; it does
not prove the target host meets that requirement.

Custom paths must be absolute, not `/` or `//`, with no `.` or `..` components.
Whitespace, `&`, `|`, backslashes, `%`, `#`, `;`, `$`, quotes and backticks are
rejected before writing. A custom `--etc-dir` does not change the default image
inventory/lock location; set `IMAGE_PROTECTION_FILE` in the override file when
that location must change. Its parent directory must exist.

## Image protection

All modes keep images referenced by containers. Choose additional protection
with installer options:

| Mode | What else is kept | How to select it |
| --- | --- | --- |
| `none` (fresh default) | Nothing | `--image-protection none` |
| `tags` | Current local images for selected tags | `--keep-image repository:tag` |
| `inventory` | Images listed by deployment tooling | `--image-protection inventory` |

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

Use `--image-protection inventory` when your deployment tooling maintains a JSON
file listing every image needed for deployment, rollback, or recovery. That
tooling is the inventory publisher; this repository does not supply it. It must
refresh the file's expiry even when no new deployment occurs.

Prepare the publisher before enabling cleanup. For an existing installation,
follow [Update or change settings](#update-or-change-settings). Cleanup cannot
infer an omitted rollback requirement or select recovery images for you.

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

Use the immutable repository digests in `RepoDigests`, not local image IDs.
Every listed digest must resolve to an image on this host; a registry copy alone
does not count. Name at least one deployment, with a nonempty `current` list for
each. `rollback` and `recovery` may be empty if no images need that protection.
Timestamps use `YYYY-MM-DDTHH:MM:SS` with `Z` or an explicit `±HH:MM` timezone,
for example `2030-01-01T00:00:00Z`. Optional fractional seconds accept 1–9 digits;
comparisons use microsecond precision.

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

The [default age thresholds](#defaults-and-what-can-be-removed) can be overridden
for this host. Compose files do not protect images; tags add protection only
when selected in `tags` mode.

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

For an override-only change, [pause scheduled cleanup](#pause-or-enable-scheduled-cleanup)
and wait for an active run to finish, edit this file, then
[inspect the effective settings](#policy-inspection-and-failures) and re-enable
the timer. No reinstall is needed: the next service run reads the file again.

This is a systemd EnvironmentFile, not a shell script; shell expansions are not
evaluated. `DOCKER` must name one executable, not a command line with arguments.
See [the override template](fixtures/default/vps-docker-clean.example).

| Setting | Default and accepted values |
| --- | --- |
| `DOCKER` | `docker`; an executable name or path |
| `CONTAINER_UNTIL`, `NETWORK_UNTIL`, `IMAGE_UNTIL` | Profile defaults; positive whole hours such as `48h`, without leading zeros |
| `IMAGE_MIN_FREE_GIB` | `0` disables pressure; nonnegative whole GiB without leading zeros |
| `IMAGE_PROTECTION_MODE` | Saved installer choice: `none`, `tags` or `inventory`; fresh installations use `none`; existing policies without a mode select `inventory` conservatively |
| `IMAGE_KEEP_TAGS` | Empty; whitespace-separated explicit local repository:tag names; must be nonempty in `tags` mode and empty in other modes |
| `IMAGE_PROTECTION_FILE` | `/etc/default/vps-docker-clean.images.json`; absolute path for inventory mode and the lock base in every mode; parent directory must exist |

Systemd reads the generated `.policy` first and overrides second. Change profile,
cache budget, image protection mode and kept tags through installer options,
not by editing the generated file. Without a mode supplied by either file, the
cleanup executable defaults to `inventory` to preserve existing protection.
Obsolete `BUILD_CACHE_UNTIL`, `BUILD_CACHE_RESERVED` and `ALLOW_BUILDX_PRUNE`
overrides are rejected; remove them before upgrading.

## Policy inspection and failures

The [installation checker](#check-the-installation) compares generated policy and
managed files with the repository's expected configuration. Use installer options
for saved policy choices and the operator override file or service drop-ins for
other supported settings. Without `--strict`, discrepancies are reported without
a failing exit status.

The checker examines policy on disk. It does not validate effective overrides,
selected tag availability, inventory completeness, deployment locking, or whether
Docker has loaded its new configuration. There is no protection-only validation
command: starting the service checks the selected protection and then deletes
eligible resources. An initial failed tag or inventory check prevents all Docker
pruning, including containers and networks.

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

Use [Run cleanup now](#run-cleanup-now) to start the service and inspect its result.

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

APT cleanup uses the distro's existing timers and `apt.systemd.daily`. When
installed, this repository's policy also enables daily package-list updates and
verbose periodic reporting.
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
follow the [installation path restrictions](#installation-reference). Restore
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

`make test` runs the Debian 12 suite. `make test/all` adds Ubuntu 20.04 (Python 3.8),
Ubuntu 24.04, build-context canaries, and file-ownership checks run as container root. The broad suites run without root or
capabilities, with a read-only filesystem and an explicit build-context
allowlist. Test-image builds need engine access and network when dependencies
are not cached. Use `make test/matrix`, `make test/posture` or
`make test/root-container` for individual lanes; `make shell` opens the test image.
