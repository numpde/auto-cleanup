#!/usr/bin/env python3
"""Inspect native logrotate policy before installing or checking btmp rotation."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

OWNED_FILE = 'auto-cleanup-btmp'
TARGET = '/var/log/btmp'


def inspect_size(path):
    if not path.exists():
        return None
    value = str(path)
    if '"' in value or '\n' in value or '\r' in value:
        raise ValueError(f'Cannot represent logrotate include path: {value!r}')
    with tempfile.TemporaryDirectory(prefix='auto-cleanup-logrotate-') as scratch:
        config = Path(scratch) / 'config'
        config.write_text(f'include {value}\n')
        config.chmod(0o600)
        result = subprocess.run(['logrotate', '--debug', '--state', '/dev/null', str(config)],
                                env=dict(os.environ, LC_ALL='C'), text=True, capture_output=True,
                                timeout=30, check=False)
    output = result.stdout + result.stderr
    frame = re.search(r'^Handling ([0-9]+) logs\s*$', output, re.M)
    if frame is None or re.search(r'^error:', output[:frame.start()], re.M):
        raise ValueError(f'Logrotate could not parse {path}: {output.strip()}')
    blocks = re.split(r'^rotating pattern: ', output[frame.end():], flags=re.M)[1:]
    if len(blocks) != int(frame.group(1)):
        raise ValueError(f'Cannot read logrotate rotation blocks for {path}')
    sizes = []
    for block in blocks:
        if re.search(r'^\s*considering log /var/log/btmp\s*$', block, re.M):
            size = re.search(r'log files >= ([0-9]+) are rotated earlier', block)
            sizes.append(int(size.group(1)) if size else 0)
    if len(sizes) > 1:
        raise ValueError(f'Multiple active logrotate stanzas select {TARGET}')
    # Debug also checks live log files. Their absence or permissions do not change
    # the configuration already parsed above, including during staged installs.
    if result.returncode and not re.search(r'^error:', output[frame.end():], re.M):
        raise ValueError(f'Logrotate inspection failed for {path}: {output.strip()}')
    return sizes[0] if sizes else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--reference-policy', type=Path, required=True)
    parser.add_argument('--plan', action='store_true')
    args = parser.parse_args()
    if not args.directory.is_absolute() or not args.reference_policy.is_absolute():
        parser.error('directory and reference-policy must be absolute')
    expected = inspect_size(args.reference_policy)
    if expected in (None, 0):
        raise ValueError(f'Reference policy {args.reference_policy} must supply a btmp size limit')
    if args.plan and (args.directory / OWNED_FILE).exists():
        with tempfile.TemporaryDirectory(prefix='auto-cleanup-btmp-candidate-') as scratch:
            candidate = Path(scratch)
            for source in args.directory.iterdir():
                if source.name != OWNED_FILE:
                    (candidate / source.name).symlink_to(source)
            shutil.copyfile(args.reference_policy, candidate / OWNED_FILE)
            (candidate / OWNED_FILE).chmod(0o644)
            if inspect_size(candidate) != expected:
                raise ValueError('Candidate btmp policy does not retain its reference size limit')
        print('install')
        return
    current = inspect_size(args.directory)
    if current == expected:
        print('skip' if args.plan else 'Effective btmp size policy matches')
    elif current is None and args.plan:
        print('install')
    else:
        raise ValueError(f'Cannot manage btmp rotation: existing size limit is {current!r}, required {expected} bytes; update the existing stanza or use --skip-btmp-logrotate')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f'Cannot inspect btmp policy: {error}', file=sys.stderr)
        sys.exit(1)
