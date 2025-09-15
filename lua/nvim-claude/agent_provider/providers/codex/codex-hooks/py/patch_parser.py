#!/usr/bin/env python3
from typing import Iterator


def extract_patch(cmd: str) -> str | None:
    if not cmd:
        return None
    marker = '*** Begin Patch'
    idx = cmd.find(marker)
    if idx == -1:
        return None
    return cmd[idx:]


def iter_targets(patch_text: str) -> Iterator[str]:
    if not patch_text:
        return
    for line in patch_text.splitlines():
        if line.startswith('*** Update File: '):
            yield line[len('*** Update File: '):].strip()
        elif line.startswith('*** Add File: '):
            yield line[len('*** Add File: '):].strip()
        elif line.startswith('*** Delete File: '):
            yield line[len('*** Delete File: '):].strip()

