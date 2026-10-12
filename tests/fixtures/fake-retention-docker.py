#!/usr/bin/env python3
"""Stateful Docker port for retention failure and reference tests."""
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['RETENTION_STATE'])
state = json.loads(state_path.read_text())
assert sys.argv[1:3] == ['--host', 'unix:///var/run/docker.sock']
args = sys.argv[3:]
with Path(os.environ['FAKE_DOCKER_LOG']).open('a') as stream:
    stream.write(' '.join(args) + '\n')
if args[0] == 'info':
    print(json.dumps({'ID': 'test-daemon', 'DockerRootDir': str(state_path.parent)}))
elif args[:2] == ['image', 'inspect']:
    reference = args[2]
    lookup = state.get('inspect_aliases', {}).get(reference, reference)
    images = [image for image in state['images'] if lookup == image['Id'] or lookup in image.get('RepoDigests', []) or lookup in image.get('RepoTags', [])]
    if not images:
        sys.exit(1)
    print(json.dumps([None] if state.get('malformed_inspect') else images))
elif args[:2] == ['container', 'ls']:
    if state.get('retarget_tag_after_container_lists') or state.get('fail_container_list_at'):
        state['container_lists'] = state.get('container_lists', 0) + 1
        if state['container_lists'] == state.get('retarget_tag_after_container_lists'):
            for image in state['images']:
                tags = [tag for tag in image.get('RepoTags', []) if tag != state['retarget_tag']]
                if image['Id'] == state['retarget_to']:
                    tags.append(state['retarget_tag'])
                image['RepoTags'] = tags
        state_path.write_text(json.dumps(state))
        if state['container_lists'] == state.get('fail_container_list_at'):
            sys.exit(1)
    for container in state['containers']:
        print(container)
elif args[:2] == ['container', 'inspect']:
    print(json.dumps([{'Image': state['containers'][args[2]]}]))
elif args[:2] == ['image', 'ls']:
    for image in state['images']:
        print(image['Id'])
elif args[:2] == ['image', 'rm']:
    assert args[2] == '--no-prune' and len(args) == 4
    image = next(image for image in state['images'] if image['Id'] == args[3])
    if args[3] in state['containers'].values() or len(image.get('RepoTags', [])) > 1 or state.get('refuse_removal'):
        sys.exit(1)
    state['images'] = [image for image in state['images'] if image['Id'] != args[3]]
    state_path.write_text(json.dumps(state))
elif args[:2] in (['container', 'prune'], ['network', 'prune']):
    if args[0] == 'container' and state.get('disposable_containers'):
        state['containers'] = {}
        state_path.write_text(json.dumps(state))
    if state.get('change_inventory'):
        Path(os.environ['IMAGE_PROTECTION_FILE']).write_text('{}')
    if args[0] == 'container' and state.get('remove_tag_on_container_prune'):
        for image in state['images']:
            image['RepoTags'] = [tag for tag in image.get('RepoTags', []) if tag != state['remove_tag_on_container_prune']]
        state_path.write_text(json.dumps(state))
else:
    raise AssertionError(args)
