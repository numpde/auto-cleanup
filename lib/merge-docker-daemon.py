#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

EXPECTED_LOG_DRIVER = "local"
EXPECTED_LOG_OPTS = {
    "compress": "true",
    "max-file": "3",
    "max-size": "10m",
}


def load_json(path):
    try:
        stat_result = path.stat()
    except FileNotFoundError:
        return {}
    except OSError as exc:
        raise SystemExit(f"{path}: cannot stat: {exc}") from exc
    if stat_result.st_size == 0:
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except UnicodeDecodeError as exc:
        raise SystemExit(f"{path}: invalid UTF-8: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON: {exc}") from exc
    except OSError as exc:
        raise SystemExit(f"{path}: cannot read: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return data


def validate_policy(policy, path):
    log_driver = policy.get("log-driver")
    if log_driver is None:
        raise SystemExit(f"{path}: missing log-driver")
    if log_driver is not None and not isinstance(log_driver, str):
        raise SystemExit(f"{path}: log-driver must be a string")
    if log_driver != EXPECTED_LOG_DRIVER:
        raise SystemExit(f"{path}: log-driver must be {EXPECTED_LOG_DRIVER!r}")
    log_opts = policy.get("log-opts")
    if log_opts is None:
        raise SystemExit(f"{path}: missing log-opts")
    if not isinstance(log_opts, dict):
        raise SystemExit(f"{path}: log-opts must be a JSON object")
    for key, value in log_opts.items():
        if not isinstance(value, str):
            raise SystemExit(f"{path}: log-opts.{key} must be a string")
        if key not in EXPECTED_LOG_OPTS:
            raise SystemExit(f"{path}: unexpected log-opts.{key}")
    for key, value in EXPECTED_LOG_OPTS.items():
        if log_opts.get(key) != value:
            raise SystemExit(f"{path}: log-opts.{key} must be {value!r}")


def atomic_write(path, text, mode, owner):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if owner is not None:
            os.chown(tmp_name, owner[0], owner[1])
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
        # Persist the directory entry for the atomic replace on Linux filesystems.
        dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def backup_path(path):
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    candidate = path.with_name(f"{path.name}.auto-cleanup.bak.{stamp}")
    if not candidate.exists():
        return candidate
    index = 1
    while True:
        indexed = path.with_name(f"{path.name}.auto-cleanup.bak.{stamp}.{index}")
        if not indexed.exists():
            return indexed
        index += 1


def copy_backup(src, dst, owner):
    shutil.copy2(src, dst)
    os.chown(dst, owner[0], owner[1])
    with dst.open("rb") as handle:
        os.fsync(handle.fileno())


def validate_raw_absolute_path(raw_path, label):
    if not raw_path.startswith("/"):
        raise SystemExit(f"{raw_path}: {label} path must be absolute")
    if raw_path.startswith("//"):
        raise SystemExit(f"{raw_path}: {label} path must not start with //")
    components = raw_path.split("/")
    if "." in components or ".." in components:
        raise SystemExit(f"{raw_path}: {label} path must not contain '.' or '..' components")


def reject_symlink_parents(path):
    current = pathlib.Path(path.anchor)
    for component in path.parent.parts[1:]:
        current = current / component
        if current.is_symlink():
            raise SystemExit(f"{path}: refusing path through symlink directory: {current}")


def main():
    parser = argparse.ArgumentParser(description="Merge Docker daemon log policy")
    parser.add_argument("--daemon-json", required=True)
    parser.add_argument("--policy-json", required=True)
    parser.add_argument(
        "--output-json",
        help="write the merged daemon JSON to this path without updating daemon-json",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    validate_raw_absolute_path(args.daemon_json, "daemon")
    if args.output_json is not None:
        validate_raw_absolute_path(args.output_json, "output")

    daemon_path = pathlib.Path(args.daemon_json)
    policy_path = pathlib.Path(args.policy_json)
    reject_symlink_parents(daemon_path)
    if daemon_path.is_symlink():
        raise SystemExit(f"{daemon_path}: refusing to replace symlink")
    if daemon_path.exists() and not daemon_path.is_file():
        raise SystemExit(f"{daemon_path}: expected a regular file")
    if not policy_path.exists():
        raise SystemExit(f"{policy_path}: policy file not found")
    if not policy_path.is_file():
        raise SystemExit(f"{policy_path}: expected a regular file")

    daemon = load_json(daemon_path)
    policy = load_json(policy_path)
    validate_policy(policy, policy_path)
    merged = dict(daemon)
    merged.update(policy)

    output = json.dumps(merged, indent=2, sort_keys=True) + "\n"
    if args.output_json is not None:
        output_path = pathlib.Path(args.output_json)
        reject_symlink_parents(output_path)
        if output_path.is_symlink():
            raise SystemExit(f"{output_path}: refusing to replace symlink")
        if output_path.exists() and not output_path.is_file():
            raise SystemExit(f"{output_path}: expected a regular file")
        if args.dry_run:
            print(f"would write merged daemon JSON to {output_path}")
            return 0
        atomic_write(output_path, output, 0o644, None)
        print(f"wrote merged daemon JSON to {output_path}")
        return 0

    if daemon_path.exists() and daemon_path.read_text(encoding="utf-8") == output:
        print(f"unchanged {daemon_path}")
        return 0

    if args.dry_run:
        print(f"would merge {policy_path} into {daemon_path}")
        return 0

    mode = 0o644
    owner = None
    if daemon_path.exists():
        existing_stat = daemon_path.stat()
        mode = existing_stat.st_mode & 0o777
        owner = (existing_stat.st_uid, existing_stat.st_gid)
        backup = backup_path(daemon_path)
        copy_backup(daemon_path, backup, owner)
        print(f"backed up {daemon_path} to {backup}")

    atomic_write(daemon_path, output, mode, owner)
    print(f"updated {daemon_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
