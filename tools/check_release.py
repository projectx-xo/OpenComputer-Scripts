#!/usr/bin/env python3
"""Verify that the generated release describes the checked-out application files."""
from pathlib import Path
import re
import zlib

root = Path(__file__).resolve().parent.parent
text = (root / 'release.lua').read_text()
assert re.search(r'ref = "[0-9a-fA-F]{40}"', text), 'missing immutable source commit'
entries = re.findall(r'\["([\w/.-]+)"\] = \{size = (\d+), checksum = "([0-9a-f]{8})"\}', text)
assert entries, 'empty release'
for name, size, checksum in entries:
    data = (root / name).read_bytes()
    assert len(data) == int(size), f'{name}: size differs from release'
    assert f'{zlib.adler32(data):08x}' == checksum, f'{name}: checksum differs from release'
print(f'Release integrity passed for {len(entries)} application files')
