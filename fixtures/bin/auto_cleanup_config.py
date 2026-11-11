"""Authoritative configuration for explicitly enrolled local Docker daemons."""
import json
import datetime as dt
import os
from pathlib import Path
import re
import stat

TARGET_FIELDS = {
    'name', 'kind', 'user', 'socket', 'daemon_config', 'daemon_service', 'schedule',
    'cache_gib', 'container_until', 'network_until', 'image_until',
    'image_min_free_gib', 'image_protection_mode', 'image_keep_tags', 'image_protection_file',
}
SCHEDULES = {'daily': '*-*-* 00:00:00', 'weekly': 'Mon *-*-* 00:00:00'}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate configuration setting {key!r}')
        result[key] = value
    return result


def read_json(path, trusted=False):
    path = Path(path)
    if trusted:
        for parent in path.absolute().parents:
            metadata = parent.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                raise ValueError(f'target configuration parent {parent} must be a root-owned directory without group/other write access')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor) as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError(f'configuration {path} must be a regular file')
        if trusted and (metadata.st_uid != 0 or metadata.st_mode & 0o022):
            raise ValueError('target configuration must be root-owned and not writable by group or others')
        return json.load(stream, object_pairs_hook=unique_object)


def absolute_path(value, label):
    if (not isinstance(value, str) or not re.fullmatch(r'/[A-Za-z0-9_./-]+', value)
            or value.endswith('/') or any(part in ('.', '..', '') for part in value.split('/')[1:])):
        raise ValueError(f'{label} must be an absolute path without whitespace, shell syntax or dot components')
    return Path(value)


def integer(value, label, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f'{label} must be a whole number between {minimum} and {maximum}')


def validate_target(target):
    if not isinstance(target, dict) or set(target) != TARGET_FIELDS:
        raise ValueError(f'target configuration must contain exactly: {", ".join(sorted(TARGET_FIELDS))}')
    for key in ('name', 'user'):
        if not isinstance(target[key], str) or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', target[key]):
            raise ValueError(f'{key} must be a simple Linux account or target name')
    if target['kind'] not in ('rootful', 'rootless'):
        raise ValueError('kind must be rootful or rootless')
    if (target['user'] == 'root') != (target['kind'] == 'rootful'):
        raise ValueError('rootful cleanup must run as root; rootless cleanup must run as its non-root daemon owner')
    for key in ('socket', 'image_protection_file'):
        absolute_path(target[key], key)
    if target['daemon_config'] is not None:
        absolute_path(target['daemon_config'], 'daemon_config')
        if not isinstance(target['daemon_service'], str) or not re.fullmatch(r'[A-Za-z0-9_-]+\.service', target['daemon_service']):
            raise ValueError('daemon_service must name one systemd service without arguments or specifiers')
        integer(target['cache_gib'], 'cache_gib', 1, 8589934591)
    elif target['daemon_service'] is not None or target['cache_gib'] is not None:
        raise ValueError('unmanaged daemon_config requires daemon_service and cache_gib to be null')
    if target['schedule'] not in SCHEDULES:
        raise ValueError('schedule must be daily or weekly')
    integer(target['image_min_free_gib'], 'image_min_free_gib', 0, 8589934591)
    for key in ('container_until', 'network_until', 'image_until'):
        if key == 'network_until' and target[key] is None:
            continue
        if not isinstance(target[key], str) or not re.fullmatch(r'[1-9][0-9]*h', target[key]):
            raise ValueError(f'{key} must be positive whole hours, such as 24h')
        # Docker parses prune ages as Go durations: signed int64 nanoseconds.
        integer(int(target[key][:-1]), key, 1, (2**63 - 1) // 3600000000000)
        try:
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=int(target[key][:-1]))
        except (OverflowError, ValueError) as error:
            raise ValueError(f'{key} exceeds the supported datetime range') from error
    mode, tags = target['image_protection_mode'], target['image_keep_tags']
    if mode not in ('none', 'tags', 'inventory') or not isinstance(tags, list):
        raise ValueError('image_protection_mode must be none, tags or inventory; image_keep_tags must be a list')
    if (mode == 'tags') != bool(tags):
        raise ValueError('tags mode requires a nonempty tag list; other modes require an empty list')
    for reference in tags:
        if not isinstance(reference, str) or re.search(r'\s|[\x00-\x1f]', reference):
            raise ValueError('image_keep_tags must contain explicit local repository:tag strings')
        repository, separator, tag = reference.rpartition(':')
        if not separator or not repository or '@' in reference or not tag or '/' in tag or re.fullmatch(r'sha256:[0-9a-f]{64}', reference):
            raise ValueError(f'image_keep_tags requires repository:tag, received {reference!r}')
    return target


def load_target(path, trusted=False):
    return validate_target(read_json(path, trusted=trusted))


def verify_socket_owner(target, uid):
    metadata = os.stat(target['socket'])
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != uid:
        raise ValueError(f"Docker socket {target['socket']} must be a Unix socket owned by {target['user']}")
