# auto-cleanup

Conservative VPS disk cleanup policy, packaged as installable fixtures and
scripts.

Use this repo when you want predictable limits for common disk-growth sources
without installing broad cleanup jobs that might remove data you still care
about. The installer writes only the files needed for:

- Docker log caps through `/etc/docker/daemon.json`
- Weekly safe Docker pruning through a systemd timer
- journald size/retention limits
- size-based `/var/log/btmp` rotation
- APT periodic cleanup

It does not automate Docker volume pruning or temp-directory cleanup. Docker
volumes can hold application data, so they are left for an operator to prune
manually. Temporary directories are already handled by the distro's
`systemd-tmpfiles-clean.timer` on systemd hosts.

Default installed policy:

| Area | Default |
| --- | --- |
| Docker logs | `local` driver, `10m` x `3`, compressed |
| Docker build cache | prune older than `168h`, reserve `1GB` |
| Docker containers/networks | prune unused older than `168h` |
| Docker images | prune unused older than `720h` |
| journald | `SystemMaxUse=300M`, `SystemKeepFree=1G`, `MaxRetentionSec=14day` |
| btmp | rotate at `50M`, keep 1 rotated file |
| APT cache | autoclean every 7 days, clean every 30 days |

This repo intentionally does not install jobs that run:

- `docker system prune --volumes`
- `docker volume prune`
- direct deletion under `/var/lib/docker`
- direct deletion of APT/dpkg locks

## Install

The normal workflow is: review the planned writes, stage them under a
temporary root if you want to inspect the file tree, then install on the host.

Review the plan first. Dry-run does not install files, but it still validates
Docker daemon JSON when Docker config management is enabled:

```sh
./scripts/install.sh --dry-run
```

For a file-tree preview that does not touch the host, use the staged install
flow below.

Install on a VPS:

```sh
sudo ./scripts/install.sh
```

You can run `--dry-run` and `--root` without sudo. Repository tests are
container-only; use `make test`. Use sudo only for a real install or uninstall
against `/etc`, `/usr/local`, and systemd.

By default, a real install writes to these Linux locations:

- `/usr/local/sbin/vps-docker-clean`
- `/etc/systemd/system/vps-docker-clean.{service,timer}`
- `/etc/systemd/journald.conf.d/auto-cleanup-limits.conf`
- `/etc/logrotate.d/auto-cleanup-btmp`, only when no active-looking existing
  size-based btmp policy is found
- `/etc/apt/apt.conf.d/90auto-cleanup-periodic`, only when no active-looking
  existing cleanup policy is found
- `/etc/docker/daemon.json`

When service actions are enabled, the installer runs `systemctl daemon-reload`,
enables `vps-docker-clean.timer`, and restarts `systemd-journald` if the
journald fixture was installed. Docker is restarted only when you pass
`--restart-docker`.

The Docker daemon config is merged as JSON and backed up before modification.
Unrelated daemon keys are preserved, while `log-driver` and `log-opts` are
replaced by the exact repo policy: `local` with `max-size=10m`,
`max-file=3`, and `compress=true`. Existing file mode and ownership are
preserved when `daemon.json` is rewritten. Existing containers must still be
recreated before they use the new logging driver. The installer does not
restart Docker by default. If `/etc/docker/daemon.json` is a symlink, the
installer refuses to replace it; merge that case manually.

When `dockerd` is available, install and strict checks also run
`dockerd --validate --config-file` against the daemon JSON. That validates the
config file itself, but it cannot prove that the host's Docker service command
line has no duplicate flags. If your Docker service starts `dockerd` with
`--log-driver` or `--log-opt`, remove those flags or merge the logging policy
manually before restarting Docker.

For files owned by this repo, the installer also refuses to replace symlink or
non-regular destinations. Move or resolve those manually before installing.

Common install switches:

- `--root DIR` stages under another root for tests or image builds.
- `--prefix DIR` changes where the cleanup executable is installed.
- `--etc-dir DIR` changes the configuration root.
- `--skip-docker-config` leaves Docker daemon configuration untouched.
- `--skip-journald` leaves journald configuration untouched.
- `--skip-btmp-logrotate` leaves btmp rotation untouched.
- `--skip-apt-periodic` leaves APT periodic cleanup untouched.
- `--restart-docker` restarts Docker after updating daemon config.
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

After install, restart Docker when convenient. Existing containers must then be
recreated before they use the new daemon logging defaults. For Compose-managed
workloads, run the Compose command from each workload's own Compose project
directory:

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

Uninstall removes the files installed by this repo and disables the timer. It
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

The Docker cleanup script checks which builder-cache retention command the
local Docker CLI supports. Classic `docker builder prune` uses
`--keep-storage`; newer builder/Buildx prune commands may advertise
`--reserved-space`. The default path stays on `docker builder prune` so cleanup
targets the local Docker builder cache. If neither builder storage-reservation
flag is advertised, the script still prunes old local build cache but skips the
reservation flag. `docker buildx prune` is used only when
`ALLOW_BUILDX_PRUNE=1` is set, because Buildx prunes the selected builder,
which may be remote, shared, or otherwise different from the local builder. If
no supported build-cache prune command is available, it skips build-cache
cleanup and continues with the other safe Docker prune steps.

If the Docker CLI is missing or the Docker daemon is not reachable, the cleanup
script exits successfully without pruning. That avoids noisy timer failures on
hosts where Docker is temporarily stopped or not installed.

The systemd timer uses `OnCalendar=weekly`, which systemd normalizes to Monday
00:00 local time, adds up to one hour of randomized delay, and allows
coalescing within `AccuracySec=1h`.

The installed cleanup script accepts these optional environment overrides.
`DOCKER` must be an executable name or path, not a command line with arguments.

- `DOCKER`, default `docker`
- `BUILD_CACHE_UNTIL`, default `168h`
- `BUILD_CACHE_RESERVED`, default `1GB`
- `CONTAINER_UNTIL`, default `168h`
- `NETWORK_UNTIL`, default `168h`
- `IMAGE_UNTIL`, default `720h`
- `ALLOW_BUILDX_PRUNE`, default `0`; set to `1` only when the selected Buildx
  builder is safe for this timer to prune

For timer runs, place overrides in `/etc/default/vps-docker-clean`, for example:

```sh
BUILD_CACHE_RESERVED=2GB
IMAGE_UNTIL=1440h
```

See `fixtures/default/vps-docker-clean.example` for a commented template.

The installer does not create this override file unless you install one
manually.

Primary references:

- Docker prune behavior: <https://docs.docker.com/engine/manage-resources/pruning/>
- Docker logging driver configuration: <https://docs.docker.com/engine/logging/configure/>
- Docker local logging driver options: <https://docs.docker.com/engine/logging/drivers/local/>
- Classic builder prune flags: <https://docs.docker.com/reference/cli/docker/builder/prune/>
- Buildx prune flags: <https://docs.docker.com/reference/cli/docker/buildx/prune/>
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

The test entrypoints refuse direct host execution. Run them through Make so the
container wrapper can set the in-container guard:

```sh
make test              # default Debian broad lane
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
