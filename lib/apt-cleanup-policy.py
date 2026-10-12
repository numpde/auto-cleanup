#!/usr/bin/env python3
"""Inspect effective APT cleanup and preflight a candidate managed policy."""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

OWNED_FILE = '90auto-cleanup-periodic'


def quote_path(path):
    value = str(path)
    if '"' in value or '\n' in value or '\r' in value:
        raise ValueError(f'APT configuration cannot represent this path: {value!r}')
    return '"' + value + '"'


def effective_cleanup(parts, main):
    with tempfile.TemporaryDirectory(prefix='auto-cleanup-apt-') as scratch:
        bootstrap = Path(scratch) / 'bootstrap'
        bootstrap.write_text(f'Dir::Etc::parts {quote_path(parts)};\nDir::Etc::main {quote_path(main)};\n')
        result = subprocess.run(
            ['apt-config', 'shell', 'Enable', 'APT::Periodic::Enable',
             'Auto', 'APT::Periodic::AutocleanInterval', 'Clean', 'APT::Periodic::CleanInterval'],
            env=dict(os.environ, APT_CONFIG=str(bootstrap)), text=True, capture_output=True,
            timeout=30, check=False,
        )
    if result.returncode:
        raise ValueError(f'APT rejected configuration in {parts}: {result.stderr.strip()}')
    settings = {}
    for assignment in shlex.split(result.stdout):
        key, separator, value = assignment.partition('=')
        if not separator or key not in {'Enable', 'Auto', 'Clean'} or key in settings:
            raise ValueError(f'Cannot read APT cleanup settings from apt-config: {assignment!r}')
        settings[key] = value
    enabled = int(settings.get('Enable', '1')) != 0
    active = any(value == 'always' or (re.fullmatch(r'[0-9]+[smhd]?', value) and int(value.rstrip('smhd')) > 0)
                 for value in (settings.get('Auto', '0'), settings.get('Clean', '0')))
    return enabled and active, settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apt-dir', type=Path, required=True)
    parser.add_argument('--candidate-policy', type=Path)
    args = parser.parse_args()
    if not args.apt_dir.is_absolute():
        parser.error('--apt-dir must be absolute')
    parts = args.apt_dir / 'apt.conf.d'
    main_file = args.apt_dir / 'apt.conf'
    active, settings = effective_cleanup(parts, main_file)
    if args.candidate_policy is None:
        if not active:
            raise ValueError(f'No effective APT cleanup is enabled in {args.apt_dir}: {settings}')
        print('Effective APT cleanup is enabled')
        return
    if active and not (parts / OWNED_FILE).exists():
        print('skip')
        return
    with tempfile.TemporaryDirectory(prefix='auto-cleanup-apt-candidate-') as scratch:
        candidate = Path(scratch)
        if parts.exists():
            for source in parts.iterdir():
                if source.name != OWNED_FILE:
                    (candidate / source.name).symlink_to(source)
        shutil.copyfile(args.candidate_policy, candidate / OWNED_FILE)
        active, settings = effective_cleanup(candidate, main_file)
        if not active:
            raise ValueError(f'Cannot install APT cleanup: existing settings disable the candidate policy ({settings}); correct the APT configuration or use --skip-apt-periodic')
    print('install')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'Cannot inspect APT cleanup policy: {error}', file=sys.stderr)
        sys.exit(1)
