"""Generate management commands from OpenAPI and newer server routes, offline."""
import json, re
from pathlib import Path
m = json.load(open('zigfs-cli/models/management.json'))
for method, path in re.findall('\\.method = \\.(\\w+), \\.path = "([^"]+)"', Path('zigfs/src/transport/management.zig').read_text()):
    path = re.sub(':(\\w+)', '{\\1}', path)
    if '/multipart-uploads/{id}' in path:
        path = path.replace('{id}', '{uploadId}')
    m['paths'].setdefault(path, {}).setdefault(method, {'description': 'Current server route; input checked by server'})
family = {'users': 'user', 'groups': 'group', 'policies': 'policy', 'access-keys': 'access-key', 'oidc/providers': 'oidc-provider', 'roles': 'role', 'organizations': 'organization', 'role-sessions': 'role-session', 'event-destinations': 'event-destination'}
items = []
for path, methods in m['paths'].items():
    tail = path.removeprefix('/_admin/v1/')
    for method, spec in methods.items():
        if method not in ('get', 'post', 'put', 'patch', 'delete'):
            continue
        names = re.findall('{(\\w+)}', tail)
        resource = re.sub('/\\{\\w+\\}', '', tail)
        parts = resource.split('/')
        if parts[0] == 'auth':
            cmd = 'admin auth ' + ' '.join(parts[1:])
        elif resource in family:
            verb = {'get': 'info' if names else 'list', 'post': 'create', 'put': 'set', 'patch': 'update', 'delete': 'remove'}[method]
            cmd = 'admin ' + family[resource] + ' ' + verb
        elif resource.startswith('users/access-keys'):
            cmd = 'admin user access-key ' + {'get': 'list', 'post': 'create', 'patch': 'update', 'delete': 'remove'}[method]
        elif resource == 'buckets':
            cmd = 'admin bucket ' + {'get': 'list', 'post': 'create', 'delete': 'remove'}[method]
        elif resource.startswith('buckets/'):
            name = parts[1]
            if name == 'directories':
                cmd = 'admin directory ' + ('cleanup' if len(parts) > 2 else 'create' if method == 'post' else 'remove')
            elif name == 'multipart-uploads':
                cmd = 'admin multipart list'
            elif name == 'event-subscriptions':
                cmd = 'admin event-subscription ' + ('get' if method == 'get' else 'set')
            elif name == 'legal-hold':
                cmd = 'admin object legalhold set'
            else:
                cmd = 'admin bucket ' + name + ' ' + ('get' if method == 'get' else 'set')
        elif resource.startswith('multipart-uploads'):
            cmd = 'admin multipart ' + ('complete' if resource.endswith('/complete') else 'info' if method == 'get' else 'create' if method == 'post' else 'abort')
        elif resource == 'objects/presign':
            cmd = 'admin object presign'
        elif resource.startswith('settings/kms'):
            suffix = resource.removeprefix('settings/kms').strip('/')
            if suffix == 'keys':
                cmd = 'admin kms key ' + ('list' if method == 'get' else 'create')
            elif suffix == 'keys/action':
                cmd = 'admin kms key action'
            elif suffix:
                cmd = 'admin kms ' + suffix
            else:
                cmd = 'admin kms ' + ('info' if method == 'get' else 'set')
        elif resource.startswith('settings/') and parts[1] in ('logs', 'audit-logs'):
            cmd = 'admin ' + ' '.join(parts[1:]) + (' ' + ('get' if method == 'get' else 'set') if len(parts) == 2 else '')
        elif resource.startswith('settings'):
            cmd = 'admin ' + ' '.join(parts) + (' get' if method == 'get' else ' set')
        elif resource == 'monitoring/diagnostics':
            cmd = 'admin diagnostics ' + ('get' if method == 'get' else 'set')
        elif resource.startswith('storage'):
            cmd = 'admin ' + ' '.join(parts) + (' info' if len(parts) == 1 else '')
        elif resource in ('system', 'health', 'monitoring'):
            cmd = 'admin ' + resource
        elif resource == 'sts/assume-role':
            cmd = 'admin role-session create'
        else:
            cmd = 'admin ' + ' '.join(parts) + (' get' if method == 'get' else ' set' if method in ('put', 'patch') else ' invoke' if method == 'post' else ' remove')
        items.append({'command': cmd, 'path': path, 'method': method.upper(), 'parameters': names, 'operation': spec, 'path_parameters': methods.get('parameters', [])})
Path('zigfs-cli/src/models/management-routes.json').write_text(json.dumps(items, separators=(',', ':')) + '\n')
lines = ['// Generated from Management OpenAPI plus the current route table.', 'pub const entries = .{']
for x in sorted(items, key=lambda x: x['command']):
    lines.append('    .{ .path = ' + json.dumps(x['command']) + ', .operation = "management" },')
lines.append('};')
Path('zigfs-cli/src/management_catalog.zig').write_text('\n'.join(lines) + '\n')
print(len(items), 'management routes')
