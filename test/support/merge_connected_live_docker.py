#!/usr/bin/env python3
"""Test-only Docker transport for the unchanged installed control launcher.

This wrapper changes only the launcher's control-container network and injects a
Ruby Docker/HTTP transport. All CLI dispatch and service lifecycle methods run.
It never returns invented Docker output or a successful lifecycle result.
"""
import os
from pathlib import Path
import re
import sys


def control_command(args, support, token, routes):
    args = list(args)
    acquisitions = {'pull', 'build', 'buildx', 'load', 'import'}
    if args and (args[0] in acquisitions or (args[0] == 'image' and len(args) > 1 and args[1] in acquisitions)):
        raise ValueError('fixture refuses image acquisition')
    if args[:1] != ['run']:
        return args
    if '--name' in args and re.fullmatch(r'silo-rr-[0-9a-f]{32}', args[args.index('--name') + 1]):
        networks = [v.split('=', 1)[1] for v in args if v.startswith('--network=')]
        networks += [args[i + 1] for i, v in enumerate(args[:-1]) if v == '--network']
        if networks != ['none']:
            raise ValueError('metadata probe must be networkless')
        forbidden = ('--mount', '--volume', '--volumes-from', '--tmpfs', '--publish', '--publish-all')
        if any(v in ('-v', '-p', '-P') or v.startswith(forbidden) or
               (v.startswith(('-v', '-p')) and not v.startswith('--')) for v in args[1:]):
            raise ValueError('metadata probe must have no mounts or ports')
        if '--pull=never' not in args:
            raise ValueError('metadata probe must use cached image only')
        # These are actual fixed metadata/bundle probes, not control containers.
        # Forward unchanged except for invocation ownership, with no Ruby preload.
        return [args[0], '--label', 'silo-migrate.connected-merge-live=' + token, *args[1:]]
    if '--network' not in args or args[args.index('--network') + 1] != 'host':
        raise ValueError('unexpected control network')
    args[args.index('--network') + 1] = 'none'
    # Insert just before image, after the launcher's own RUBYOPT environment.
    index = args.index('bundle') - 1
    args[index:index] = ['--label', 'silo-migrate.connected-merge-live=' + token,
        '--label', 'silo-migrate.connected-control=true',
        '--mount', 'type=bind,src=' + str(support) + ',dst=/connected-transport.rb,readonly',
        '--mount', 'type=bind,src=' + str(routes) + ',dst=' + str(routes),
        '-e', 'RUBYOPT=-W0 -r/connected-transport.rb',
        '-e', 'SILO_CONNECTED_TOKEN=' + token,
        '-e', 'SILO_CONNECTED_ROUTE_DIR=' + str(routes)]
    return args


if __name__ == '__main__':
    try:
        args = control_command(sys.argv[1:], Path(os.environ['SILO_CONNECTED_SUPPORT']),
                               os.environ['SILO_CONNECTED_TOKEN'], Path(os.environ['SILO_CONNECTED_ROUTE_DIR']))
    except (ValueError, KeyError):
        sys.exit('connected fixture transport refused command')
    os.execv('/usr/bin/docker', ['docker', *args])
