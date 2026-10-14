"""Read effective system-manager unit properties through structured D-Bus replies."""
import json

BUS = 'org.freedesktop.systemd1'
MANAGER = '/org/freedesktop/systemd1'


def dropin_names(unit):
    stem, suffix = unit.rsplit('.', 1)
    names = {unit, suffix}
    stems = {stem}
    if '@' in stem:
        template = stem.split('@', 1)[0] + '@'
        stems.add(template)
        names.add(template + '.' + suffix)
    for stem in stems:
        while '-' in stem:
            stem = stem.rsplit('-', 1)[0]
            names.add(stem + '-.' + suffix)
    return names


def unit_properties(command, name, interface, properties):
    reply = json.loads(command(['busctl', '--system', '--json=short', 'call', BUS, MANAGER,
                                BUS + '.Manager', 'LoadUnit', 's', name]))
    objects = reply.get('data') if isinstance(reply, dict) else None
    if (not isinstance(reply, dict) or set(reply) != {'type', 'data'} or reply.get('type') != 'o'
            or not isinstance(objects, list) or len(objects) != 1
            or not isinstance(objects[0], str) or not objects[0].startswith(MANAGER + '/unit/')):
        raise ValueError(f'systemd did not report a unit object for {name}')
    output = command(['busctl', '--system', '--json=short', 'get-property', BUS, objects[0],
                      BUS + '.' + interface, *properties])
    replies = [json.loads(line) for line in output.splitlines()]
    if len(replies) != len(properties) or any(not isinstance(value, dict) or set(value) != {'type', 'data'} for value in replies):
        raise ValueError(f'systemd did not report the requested properties for {name}')
    return {key: value['data'] for key, value in zip(properties, replies)}


def manager_unit_paths(command):
    reply = json.loads(command(['busctl', '--system', '--json=short', 'get-property', BUS, MANAGER,
                                BUS + '.Manager', 'UnitPath']))
    if (not isinstance(reply, dict) or set(reply) != {'type', 'data'}
            or reply.get('type') != 'as' or not isinstance(reply.get('data'), list)):
        raise ValueError('systemd did not report its unit search directories')
    return reply['data']
