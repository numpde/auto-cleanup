# auto-cleanup

Docker disk cleanup profiles for a small VPS or a development workstation.
Requires Docker Engine 28 or newer for managed native build-cache GC.

Use this repo when you want predictable limits for common disk-growth sources
without installing broad cleanup jobs that might remove data you still care
about. The installer writes only the files needed for:

- Docker log caps through `/etc/docker/daemon.json`
- Profile-based Docker pruning through a systemd timer
- Native BuildKit cache budgets for the local Docker builder
- journald size/retention limits
- size-based `/var/log/btmp` rotation
- APT periodic cleanup

It does not automate Docker volume pruning or temp-directory cleanup. Docker
volumes can hold application data, so they are left for an operator to prune
manually. Temporary directories are already handled by the distro's
`systemd-tmpfiles-clean.timer` on systemd hosts.

Choose `vps` to prioritize disk space or `workstation` to retain more build
cache. A fresh install defaults to `vps`; reinstalling without `--profile`
preserves the saved selection and cache budget. An explicit `--profile` applies
that profile's defaults, with `--cache-gib N` taking precedence for the budget.

| Docker policy | `vps` (default) | `workstation` |
| --- | --- | --- |
| Native build-cache budget | 1 GiB | 40 GiB |
| Scheduled pruning | Daily | Weekly |
| Unreferenced images, including tagged images | Created over 24 hours ago | Created over 14 days ago |
| Disposable stopped containers | Created over 24 hours ago | Created over 7 days ago |
| Unreferenced networks | Created over 24 hours ago | Created over 7 days ago |

Only containers carrying the label `auto-cleanup.disposable=true` are eligible.
Apply it only to containers whose writable files and logs may be deleted, for
example disposable test tasks. Ordinary service containers are preserved,
including when stopped or failed. Volumes are never pruned.

Image age is **creation age**, not time since last use or download. An image
used daily with `docker run --rm` can be pruned between runs. Tags and Compose
files do not protect an image; an existing container reference does. Removing
a disposable container can make its image eligible in the same cleanup run.
Pruned images may need to be downloaded or rebuilt, including rollback images.

Shared policy:

| Area | Default |
| --- | --- |
| Docker logs | `local` driver, `10m` x `3`, compressed |
| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |
| btmp | rotate at `50M`, keep 1 compressed rotated file |
| APT cache | autoclean every 7 days, clean every 30 days |

This repo intentionally does not install jobs that run:

- `docker system prune --volumes`
- `docker volume prune`
- direct deletion under `/var/lib/docker`
- direct deletion of APT/dpkg locks

## Install

The normal workflow is: review the planned writes, stage them under a
temporary root if you want to inspect the file tree, then install on the host.

Review the plan first. Dry-run does not install files, but it still parses the
existing Docker daemon JSON and the repo policy when Docker config management
is enabled:

```sh
./scripts/install.sh --dry-run
./scripts/install.sh --profile workstation --dry-run
```

For a file-tree preview that does not touch the host, use the staged install
flow below.

Install on a VPS:

```sh
sudo ./scripts/install.sh
# Or select the workstation defaults:
sudo ./scripts/install.sh --profile workstation
# Override the selected profile's cache budget:
sudo ./scripts/install.sh --cache-gib 8
```

You can run `--dry-run` and `--root` without sudo. Repository tests are
container-only; use `make test` for the default lane or `make test/all` for the
full local suite. Use sudo only for a real install or uninstall against `/etc`,
`/usr/local`, and systemd.

By default, a real install writes to these Linux locations:

- `/usr/local/sbin/vps-docker-clean`
- `/etc/systemd/system/vps-docker-clean.{service,timer}`
- `/etc/default/vps-docker-clean.policy` (generated profile settings)
- `/etc/systemd/journald.conf.d/auto-cleanup-limits.conf`
- `/etc/logrotate.d/auto-cleanup-btmp`, only when no active-looking existing
  size-based btmp policy is found
- `/etc/apt/apt.conf.d/90auto-cleanup-periodic`, only when no active-looking
  existing cleanup policy is found
- `/etc/docker/daemon.json`

When service actions are enabled, the installer runs `systemctl daemon-reload`,
enables `vps-docker-clean.timer`, and restarts `systemd-journald` if the
journald fixture was installed. Docker is restarted only when you pass
`--restart-docker`. That is an immediate Docker service restart; expect running
containers to be interrupted according to your Docker/systemd restart policy.

The installer announces each service command before waiting for it and reports
completion only when the command succeeds. Docker startup can take time; while
the installer waits, follow its logs in another terminal with
`sudo journalctl -fu docker.service`. A failed Docker restart restores the
previous daemon configuration and attempts one recovery restart. Recovery is
reported separately: the installation still fails, and other installed files
and earlier service changes remain.

The Docker daemon config is merged as JSON and backed up before modification.
Unrelated daemon and `builder` keys are preserved. The complete `builder.gc`
section is replaced with an enabled, size-based rule using the selected budget
and zero reserved cache. Existing custom GC rules are replaced deliberately.
`log-driver` and `log-opts` are
replaced by the exact repo policy: `local` with `max-size=10m`,
`max-file=3`, and `compress=true`. Existing file mode and ownership are
preserved when `daemon.json` is rewritten. Existing containers must still be
recreated before they use the new logging driver. The installer does not
restart Docker by default. If `/etc/docker/daemon.json` is a symlink, the
installer refuses to replace it; merge that case manually.

When `dockerd` is available, real installs prevalidate the would-be merged
daemon JSON before replacing `/etc/docker/daemon.json`; strict checks validate
the installed daemon JSON. `dockerd --validate --config-file` validates the
config file itself, but it cannot prove that the host's Docker service command
line has no duplicate flags. If your Docker service starts `dockerd` with
`--log-driver` or `--log-opt`, remove those flags or merge the logging policy
manually before restarting Docker.

For files owned by this repo, the installer also refuses to replace symlink or
non-regular destinations, and refuses destination paths whose existing parent
directories are symlinks. Move or resolve those manually before installing.

Common install switches:

- `--root DIR` stages under another root for tests or image builds.
- `--profile vps|workstation` selects defaults explicitly.
- `--cache-gib N` sets a positive whole-GiB cache budget (maximum 8589934591).
- `--prefix DIR` changes where the cleanup executable is installed.
- `--etc-dir DIR` changes the configuration root.
- `--skip-docker-config` leaves Docker daemon configuration untouched; neither
  cache GC nor logging is managed by this installation.
- `--skip-journald` leaves journald configuration untouched.
- `--skip-btmp-logrotate` leaves btmp rotation untouched.
- `--skip-apt-periodic` leaves APT periodic cleanup untouched.
- `--restart-docker` restarts Docker immediately after updating daemon config;
  this can interrupt running containers.
- `--no-enable-timer` installs the timer without enabling it.
- `--no-service-actions` skips all `systemctl` calls for file-only installs.

Use `--no-service-actions` when staging inside images, containers, rescue
environments, or any host where `systemctl` is present but systemd is not
usable as the service manager. Service actions are skipped automatically with
`--root` or a custom `--etc-dir`, because systemd only discovers units from its
configured system directories.

Custom `--root`, `--prefix`, and `--etc-dir` values must be absolute paths
other than `/`, must not start with `//`, must not contain `.` or `..` path
components, and must not contain whitespace, `&`, `|`, backslashes, `%`, `#`,
`;`, `$`, quotes, or backticks.

Script dependencies are intentionally small: POSIX `/bin/sh` and standard tools
such as `install`, `sed`, `grep`, and `awk`. Run scripts from a complete
checkout so `scripts/lib/common.sh` is available. Python 3 is required only when
Docker daemon JSON management is enabled.

At runtime, the installed policy assumes a systemd-based host with logrotate
and the distro's APT periodic timer machinery available.

After install, restart Docker unless you used `--restart-docker`. This activates
the native cache budget and new logging defaults. Existing containers must
additionally be recreated to adopt the logging defaults; recreation is not
needed for cache GC. For Compose-managed workloads, run the Compose
command from each workload's own Compose project directory:

```sh
sudo systemctl restart docker
docker compose up -d --force-recreate
```

## Staged Install

Use `--root` when you want to inspect the install tree or validate an image
build without changing the running host:

```sh
./scripts/install.sh --root /tmp/auto-cleanup-root
find /tmp/auto-cleanup-root -type f -print
```

With `--root`, service actions are skipped automatically, and generated paths
are placed under the staged root while preserving their normal absolute layout.

## Uninstall

```sh
sudo ./scripts/uninstall.sh
```

Useful uninstall switches:

- `--dry-run` prints intended removals without removing files.
- `--root DIR`, `--prefix DIR`, and `--etc-dir DIR` match install paths.
- `--restore-docker-backup FILE` restores an explicit daemon backup.
- `--skip-journald`, `--skip-btmp-logrotate`, and `--skip-apt-periodic`
  leave those optional policies in place.
- `--no-service-actions` skips all `systemctl` calls for file-only removal.

As with install, uninstall skips service actions automatically with `--root` or
a custom `--etc-dir`.

Uninstall removes the files installed by this repo, including the generated
`.policy` file, and disables the timer. It preserves the operator-owned
`/etc/default/vps-docker-clean` override file. It
does not edit `/etc/docker/daemon.json` by default because that file may contain
unrelated daemon configuration. The install script creates timestamped backups
beside the daemon file, preserving file mode and ownership, named like:

```text
/etc/docker/daemon.json.auto-cleanup.bak.20260705T175500Z
```

For repo-owned paths, uninstall removes regular files and symlinks but refuses
unexpected non-regular destinations such as directories.

When service actions are enabled, uninstall runs `systemctl disable --now` for
the timer, runs `systemctl daemon-reload`, and restarts `systemd-journald`
unless journald removal was skipped.

To restore a Docker daemon backup explicitly:

```sh
sudo ./scripts/uninstall.sh \
  --restore-docker-backup /etc/docker/daemon.json.auto-cleanup.bak.YYYYMMDDTHHMMSSZ
```

Backup restore uses `cp -p`, preserving backup file mode, ownership, and
timestamps where permitted. The backup path must be absolute and must refer to
a regular file, not a symlink. The restore destination
`/etc/docker/daemon.json` must not be a symlink or other non-regular file.
When `--root` is used, the backup path is still read from the current
filesystem; only the restore destination is staged under `--root`.

After restoring a Docker daemon backup on a real host, restart Docker and
recreate affected containers when convenient so the restored daemon settings are
actually in use.

## Install btmp rotation only

For a Debian/Ubuntu systemd host needing only failed-login log rotation, install
`logrotate` and use `fixtures/logrotate/btmp` as `/etc/logrotate.d/btmp`.
Back up the previous policy outside `/etc/logrotate.d` and confirm there is only
one active stanza for `/var/log/btmp`; do not install a second
`auto-cleanup-btmp` stanza. This manual lane leaves Docker, journald, and APT
cleanup policy untouched.

Install `examples/logrotate.timer.d/hourly.conf` as
`/etc/systemd/system/logrotate.timer.d/hourly.conf`, run
`logrotate --debug /etc/logrotate.conf`, then reload systemd, enable/restart
`logrotate.timer`, and start `logrotate.service` once. Use a normal service run,
not forced rotation of all package logs. The drop-in schedules the distro's
logrotate service hourly and therefore also checks its other log policies hourly.
It is a manual example, not installed by `scripts/install.sh`.

The btmp policy rotates monthly or when an hourly check sees more than `50M`,
retains one compressed archive, and creates the replacement with mode `0660`
and owner `root:utmp`. Growth between checks can exceed `50M`; this is not a
hard disk quota. The first run compresses the existing large log, so confirm
free space for compression before starting it. Check the service result, the
next timer trigger, and the active and archived btmp file sizes afterwards.

## Notes

The installer avoids replacing distro-owned logrotate files. If any file under
the selected `logrotate.d` directory already has an active-looking stanza that
includes `/var/log/btmp` and `maxsize 50M`, the btmp fixture is skipped. A
distro btmp stanza without that size cap does not block installation of the
repo-owned fixture.

`check.sh --strict` accepts an existing btmp policy only when an active-looking
stanza that includes `/var/log/btmp` also includes `maxsize 50M`.

If you intentionally keep distro-owned btmp rotation elsewhere, either add the
size cap there or install with `--skip-btmp-logrotate`.

The installer also avoids overriding existing active APT cleanup policy. If the
selected `apt.conf.d` directory already has a positive `AutocleanInterval` or
`CleanInterval`, or the APT-supported value `"always"`, the APT fixture is
skipped. Update-only periodic settings or disabled cleanup intervals do not
block installation of the repo-owned cleanup policy.

APT cleanup is delegated to the distro's existing apt timers and
`apt.systemd.daily`; this repo only installs the periodic policy file.

`check.sh --strict` accepts existing APT config only when it includes a
positive cleanup interval such as `AutocleanInterval "7";` or
`CleanInterval "30";`, or the APT-supported value `"always"`.

If you intentionally manage APT cleanup elsewhere, either set an active cleanup
interval there or install with `--skip-apt-periodic`.

Docker's native garbage collector manages cache periodically during builder
operation, independently of the image/container/network timer. It can reclaim
recent unused cache when the budget is exceeded; there is no seven-day age
exemption. The budget is a GC target, not a disk quota. In-use cache and retained
image layers can prevent immediate recovery of space.

This installation manages the default `docker` builder and the rootful local
daemon at `unix:///var/run/docker.sock`. It does not manage custom Buildx
builders, remote engines, or rootless Docker. Scheduled pruning explicitly
selects that local socket, ignoring ambient Docker host/context/TLS settings.
Docker Engine 28+ is required because older engines may silently ignore the
cache maximum. A real managed-Docker install requires a qualifying `dockerd`
binary; a staged install without it reports the target requirement.

No cleanup policy guarantees a disk will never fill. Database contents, uploads,
other application data and non-Docker files need their own limits and disk
monitoring. This repository does not install a disk alerting service.

Individual prune command failures are reported, but the cleanup script still
attempts the remaining safe prune categories before exiting nonzero. That keeps
one failed cleanup area from preventing the rest of the scheduled cleanup.

If the Docker CLI is missing or the local daemon is unreachable, the cleanup
script exits nonzero so systemd records the failed cleanup.

The timer uses the profile's daily or weekly schedule, adds up to one hour of
randomized delay, and allows coalescing within `AccuracySec=1h`. Its persistent
timer can catch up a missed run when enabled; installation can therefore lead
to pruning soon after the timer starts. Use `--no-enable-timer` to install
without enabling it on a fresh host. It does not stop an already active timer.

The installed cleanup script accepts these optional environment overrides.
`DOCKER` must be an executable name or path, not a command line with arguments.
The override file is loaded by systemd as an `EnvironmentFile`; it is not a
shell script, and shell expansions or extra command arguments are not evaluated.

- `DOCKER`, default `docker`
- `CONTAINER_UNTIL`, profile default
- `NETWORK_UNTIL`, profile default
- `IMAGE_UNTIL`, profile default

Age overrides must be positive whole hours, such as `48h`. Systemd reads the
generated `.policy` file first and the operator override file second. Do not
edit the generated file or override profile/cache fields through the runtime
environment: use the installer options. The removed `BUILD_CACHE_UNTIL`,
`BUILD_CACHE_RESERVED`, and `ALLOW_BUILDX_PRUNE` settings are rejected; remove
them from an existing override file before upgrading.

For timer runs, place overrides in `/etc/default/vps-docker-clean`, for example:

```sh
IMAGE_UNTIL=168h
```

See `fixtures/default/vps-docker-clean.example` for a commented template.

The installer preserves an existing override file and does not create one.

Installation and `check.sh` display managed defaults, not evaluated operator
overrides or proof of the running daemon's configuration. To inspect the two
installed environment files through systemd without pruning, use this command
for the default installation paths:

```sh
sudo systemd-run --wait --pipe --collect \
  -p EnvironmentFile=/etc/default/vps-docker-clean.policy \
  -p EnvironmentFile=-/etc/default/vps-docker-clean \
  /usr/local/sbin/vps-docker-clean --show-policy
```

This creates a temporary service that prints the effective ages and container
selector without contacting Docker. It reads the managed file and then the
operator override file, but does not inherit custom drop-ins on the cleanup
service. Adjust paths for a custom installation. Direct `--show-policy` execution
also works when the three age variables are explicitly supplied.

To run the installed cleanup service, use
`sudo systemctl start vps-docker-clean.service`; this performs pruning.

Primary references:

- Docker prune behavior: <https://docs.docker.com/engine/manage-resources/pruning/>
- Docker logging driver configuration: <https://docs.docker.com/engine/logging/configure/>
- Docker local logging driver options: <https://docs.docker.com/engine/logging/drivers/local/>
- BuildKit GC: <https://docs.docker.com/build/cache/garbage-collection/>
- Docker 28 GC fields: <https://github.com/moby/moby/blob/v28.0.0/daemon/config/builder.go>
- journald limits: `man journald.conf`
- logrotate `maxsize`: `man logrotate.conf`
- systemd timer calendar syntax: `man systemd.time`
- APT periodic options: `man apt.conf` and `/usr/lib/apt/apt.systemd.daily`

## Verification

There are two different checks:

- Repository tests prove that the scripts, fixtures, docs contracts, and
  install behavior still match this repo.
- Installed policy checks inspect a real or staged filesystem and report
  whether the expected files and policy values are present.

For repository tests, run:

```sh
make test
```

Repository tests are intentionally containerized. `make test` builds the pinned
Debian test image from the copied repository context, then runs the broad
in-container suite as a non-root user with no network, no Docker socket, a
read-only root filesystem, dropped capabilities, and `/tmp` mounted noexec.
The build context is deny-by-default and explicitly allowlists the source files
needed by the test image; posture canaries check that common local secrets and
generated files, including files under allowlisted source directories, stay out
of the image.

The test entrypoints refuse direct host execution. Run them through Make so the
container wrapper can set the in-container guard:

```sh
make test              # default Debian broad lane
make test/all          # posture, matrix, and root metadata lanes
make test/matrix       # Debian and Ubuntu broad lanes
make test/posture      # build-context and container-hardening canaries
make test/root-container  # narrow root metadata lane
```

The broad lane checks shell/Python syntax, install manifest integrity, README
policy contracts, container posture, install/check/uninstall behavior, default
installed file sets, and Docker cleanup behavior through a fake Docker fixture.
The root lane is separate because only metadata preservation needs uid 0; it
runs with all capabilities dropped except `CHOWN` and `FOWNER`, and still has no
network or Docker socket.

For installed policy checks, run `check.sh`. Without `--strict`, it prints what
it finds. With `--strict`, missing or invalid expected policy becomes a failing
exit status:

```sh
./scripts/check.sh
./scripts/check.sh --strict
./scripts/check.sh --root /tmp/auto-cleanup-root --strict
```

For component installs, pass the same skip flags to `check.sh` that you passed
to `install.sh`.

Strict checks also flag repo-owned installed paths that are symlinks or
non-regular files.
