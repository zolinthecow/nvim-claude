#!/usr/bin/env python3

import os
import shlex
import sys


def parse_targets(command, cwd):
    if not command or any(char in command for char in '\n\r;&|<>`$()#'):
        return []

    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return []

    if not tokens or tokens[0] != 'rm':
        return []

    targets = []
    options = True
    for token in tokens[1:]:
        if options and token == '--':
            options = False
            continue
        if options and token.startswith('-') and token != '-':
            continue
        options = False
        if any(char in token for char in '*?[]{}~'):
            return []
        path = token if os.path.isabs(token) else os.path.join(cwd, token)
        targets.append(os.path.abspath(os.path.normpath(path)))

    return targets


def main():
    if len(sys.argv) != 3:
        return 2
    cwd = sys.argv[2] if os.path.isdir(sys.argv[2]) else os.getcwd()
    for target in parse_targets(sys.argv[1], cwd):
        sys.stdout.buffer.write(os.fsencode(target) + b'\0')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
