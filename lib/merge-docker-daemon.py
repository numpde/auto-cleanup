#!/usr/bin/env python3
"""Merge owned logging and optional native GC settings, preserving other daemon keys."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import re
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


def reject_json_constant(value):
    raise ValueError(f"non-JSON numeric constant {value!r}")


def parse_json_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"JSON number {value!r} is outside the finite numeric range")
    return number


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
            data = json.load(handle, parse_constant=reject_json_constant, parse_float=parse_json_float)
    except UnicodeDecodeError as exc:
        raise SystemExit(f"{path}: invalid UTF-8: {exc}") from exc
    except ValueError as exc:
        raise SystemExit(f"{path}: invalid JSON: {exc}") from exc
    except OSError as exc:
        raise SystemExit(f"{path}: cannot read: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: expected a JSON object")
    return data


def validate_policy(policy, path):
    extra = policy.keys() - {"log-driver", "log-opts"}
    if extra:
        raise SystemExit(f"{path}: logging policy cannot change unrelated daemon keys: {sorted(extra)}")
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
    replaced = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if owner is not None:
            os.chown(tmp_name, owner[0], owner[1])
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
        replaced = True
        # Persist the directory entry for the atomic replace on Linux filesystems.
        dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        if replaced:
            print(f"Replaced {path}; directory durability could not be confirmed.", file=sys.stderr)
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        except OSError as cleanup_error:
            print(f"Could not remove temporary daemon file {tmp_name}: {cleanup_error}", file=sys.stderr)
        raise


def backup_path(path):
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    candidate = path.with_name(f"{path.name}.auto-cleanup.bak.{stamp}")
    if not candidate.exists() and not candidate.is_symlink():
        return candidate
    index = 1
    while True:
        indexed = path.with_name(f"{path.name}.auto-cleanup.bak.{stamp}.{index}")
        if not indexed.exists() and not indexed.is_symlink():
            return indexed
        index += 1


def copy_backup(src, dst, owner):
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as backup, src.open("rb") as source:
            shutil.copyfileobj(source, backup)
            backup.flush()
            os.fchown(backup.fileno(), owner[0], owner[1])
            shutil.copystat(src, backup.fileno())
            os.fsync(backup.fileno())
        dir_fd = os.open(dst.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except BaseException:
        try:
            os.unlink(dst)
        except FileNotFoundError:
            pass
        except OSError as cleanup_error:
            print(f"Could not remove incomplete daemon backup {dst}: {cleanup_error}", file=sys.stderr)
        raise


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
    parser = argparse.ArgumentParser(description="Merge Docker daemon logging and cache policy")
    parser.add_argument("--daemon-json", required=True)
    parser.add_argument("--policy-json", required=True)
    parser.add_argument("--cache-gib", help="native GC maximum, in positive whole GiB; requires Docker 28+")
    parser.add_argument("--check", action="store_true", help="check policy without writing files")
    parser.add_argument(
        "--output-json",
        help="write the merged daemon JSON to this path without updating daemon-json",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--print-json", action="store_true", help="print the candidate without writing files")
    parser.add_argument("--expect-output-sha256", help="refuse a merged result that differs from a validated candidate")
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
    if args.cache_gib is not None:
        if re.fullmatch(r"[1-9][0-9]*", args.cache_gib) is None:
            parser.error("--cache-gib must be a positive whole number without leading zeros")
        # Docker's signed 64-bit byte count must hold the whole-GiB conversion.
        if len(args.cache_gib) > 10 or int(args.cache_gib) > 8589934591:
            parser.error("--cache-gib must not exceed 8589934591 GiB")
        builder = daemon.get("builder", {})
        if not isinstance(builder, dict):
            raise SystemExit(f"Cannot configure cache in {daemon_path}: builder must be a JSON object.")
        # Replace custom GC rules: retaining them could defeat the selected budget.
        merged["builder"] = dict(builder, gc={
            "enabled": True,
            "policy": [{"all": True, "reservedSpace": "0", "maxUsedSpace": args.cache_gib + "GB"}],
        })

    if args.check:
        if merged != daemon:
            raise SystemExit(f"Docker logging or cache policy differs from the installed settings: {daemon_path}")
        return 0

    output = json.dumps(merged, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.expect_output_sha256 is not None and hashlib.sha256(output.encode()).hexdigest() != args.expect_output_sha256:
        raise SystemExit('Docker configuration changed after validation; refusing to write a different candidate')
    if args.print_json:
        sys.stdout.write(output)
        return 0
    if args.output_json is not None:
        output_path = pathlib.Path(args.output_json)
        if output_path == daemon_path:
            raise SystemExit(f"{output_path}: output path must differ from daemon-json; use the normal merge mode to update it with a backup")
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
