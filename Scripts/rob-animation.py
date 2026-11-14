#!/usr/bin/env python3
"""Read/edit Animation Studio assets; this tool cannot execute robot motion."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import uuid

DEFAULT = Path.home() / 'Documents/ROB Animations/library.json'

def add_pack(library, pack):
    """Append by stable ID; a previously installed/user-edited asset always wins."""
    if pack.get('schemaVersion') != 1:
        raise ValueError('Expected animation pack schemaVersion 1')
    for table in ('poses', 'sequences'):
        existing = {value['id'] for value in library[table]}
        for value in pack[table]:
            if value['id'] not in existing:
                library[table].append(value)
                existing.add(value['id'])
    return library

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=DEFAULT)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('read', help='Print the current JSON document with its revision')
    export = sub.add_parser('export', help='Write a copy for editing')
    export.add_argument('output', type=Path)
    apply = sub.add_parser('apply', help='Submit an edited export to the running app')
    apply.add_argument('input', type=Path)
    apply.add_argument('--expected-revision', type=int)
    apply.add_argument('--wait', type=float, default=10)
    pack = sub.add_parser('add-pack', help='Append a gesture pack; preserve existing assets and edits by ID')
    pack.add_argument('input', type=Path)
    pack.add_argument('--wait', type=float, default=10)
    args = parser.parse_args()
    if args.command in ('read', 'export'):
        value = json.loads(args.library.read_text())
        text = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n'
        if args.command == 'read': print(text, end='')
        else: args.output.write_text(text)
        return 0
    data = args.input.read_bytes()
    if len(data) > 16_000_000: raise ValueError('Animation document exceeds 16 MB')
    value = json.loads(data)
    if args.command == 'add-pack':
        library = json.loads(args.library.read_text())
        before = json.dumps(library, sort_keys=True)
        value = add_pack(library, value)
        if json.dumps(value, sort_keys=True) == before:
            print(json.dumps({'ok': True, 'revision': value['revision'], 'detail': 'Pack already installed; existing edits preserved.'}))
            return 0
    revision = getattr(args, 'expected_revision', None)
    if revision is None: revision = value['revision']
    if value.get('schemaVersion') != 1 or not isinstance(revision, int) or revision < 0:
        raise ValueError('Expected schemaVersion 1 and a nonnegative integer revision')
    if value['revision'] != revision: raise ValueError('The document revision must match --expected-revision')
    inbox = args.library.parent / 'inbox'
    inbox.mkdir(parents=True, exist_ok=True)
    token = str(uuid.uuid4())
    temporary = inbox / (token + '.tmp')
    request = inbox / (token + '.json')
    result = inbox / (token + '.result')
    temporary.write_text(json.dumps({'expectedRevision': revision, 'document': value}, indent=2, allow_nan=False))
    os.replace(temporary, request)
    deadline = time.monotonic() + min(60, max(0, args.wait))
    while time.monotonic() < deadline:
        if result.exists():
            response = json.loads(result.read_text())
            print(json.dumps(response, indent=2))
            return 0 if response.get('ok') else 1
        time.sleep(.1)
    print(json.dumps({'status': 'pending', 'request': str(request), 'result': str(result),
                     'detail': 'Open Torso Servo Controls in Cerebro to process this edit. No robot motion.'}, indent=2))
    return 2

if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
