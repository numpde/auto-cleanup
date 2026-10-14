"""Translate supported legacy EnvironmentFiles as data, without shell evaluation."""
import re

MANAGED = {'PROFILE', 'CACHE_GIB', 'SCHEDULE', 'CONTAINER_UNTIL', 'NETWORK_UNTIL', 'IMAGE_UNTIL',
           'IMAGE_PROTECTION_MODE', 'IMAGE_KEEP_TAGS'}
OVERRIDES = {'CONTAINER_UNTIL', 'NETWORK_UNTIL', 'IMAGE_UNTIL', 'IMAGE_MIN_FREE_GIB',
             'IMAGE_PROTECTION_MODE', 'IMAGE_KEEP_TAGS', 'IMAGE_PROTECTION_FILE', 'DOCKER'}


def assignments(text, allowed):
    if any(ord(char) < 32 and char not in ('\n', '\t') for char in text):
        raise ValueError('legacy configuration contains unsupported control characters')
    values = {}
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        key, separator, value = line.partition('=')
        key, value = key.strip(), value.strip()
        if not separator or key not in allowed or key in values:
            raise ValueError(f'unsupported or duplicate legacy assignment on line {number}: {key!r}')
        if len(value) >= 2 and value[0] in ('"', "'") and value[-1] == value[0]:
            value = value[1:-1]
        if any(char in value for char in ('"', "'", '\\', '$', '`')) or any(ord(char) < 32 for char in value):
            raise ValueError(f'legacy {key} uses unsupported quoting or expansion; reconcile it before migration')
        values[key] = value
    return values


def effective_policy(managed_text, override_text):
    managed = assignments(managed_text, MANAGED)
    required = MANAGED - {'IMAGE_PROTECTION_MODE', 'IMAGE_KEEP_TAGS'}
    if not required <= managed.keys():
        raise ValueError('legacy managed policy is incomplete')
    if managed['SCHEDULE'] not in ('daily', 'weekly'):
        raise ValueError('legacy schedule must be daily or weekly')
    effective = dict(managed, **assignments(override_text, OVERRIDES))
    if effective.get('DOCKER', 'docker') != 'docker':
        raise ValueError('legacy custom Docker executable must be reconciled before migration')
    floor = effective.get('IMAGE_MIN_FREE_GIB', '0')
    if not re.fullmatch(r'0|[1-9][0-9]*', floor):
        raise ValueError('legacy free-space target must be nonnegative whole GiB')
    return dict(schedule=managed['SCHEDULE'],
                container_until=effective['CONTAINER_UNTIL'], network_until=effective['NETWORK_UNTIL'],
                image_until=effective['IMAGE_UNTIL'], image_min_free_gib=int(floor),
                image_protection_mode=effective.get('IMAGE_PROTECTION_MODE', 'inventory'),
                image_keep_tags=effective.get('IMAGE_KEEP_TAGS', '').split(),
                image_protection_file=effective.get('IMAGE_PROTECTION_FILE', '/etc/default/vps-docker-clean.images.json'))
