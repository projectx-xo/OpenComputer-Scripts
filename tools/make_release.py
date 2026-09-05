#!/usr/bin/env python3
"""Generate the strict data-only release manifest for one immutable source commit."""
import argparse
from pathlib import Path
import re
import subprocess
import zlib

FILES = [
    'central/central.lua', 'central/hologram.lua', 'bootstrap/bootstrap.lua', 'runtime/manifest.lua',
    'runtime/strike.lua', 'runtime/launchpad.lua', 'runtime/radar.lua', 'runtime/intel.lua',
    'service/stratcom.lua', 'service/update.lua', 'service/rc.lua', 'service/console.lua', 'install.lua',
]
parser = argparse.ArgumentParser()
parser.add_argument('--ref', required=True)
parser.add_argument('--version', default='3.0.0')
args = parser.parse_args()
if not re.fullmatch(r'[0-9a-fA-F]{40}', args.ref):
    parser.error('--ref must be the full immutable source commit SHA')
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}', args.version):
    parser.error('invalid version')
root = Path(__file__).resolve().parent.parent
lines = ['return {', f'    version = "{args.version}",', f'    ref = "{args.ref}",', '    files = {']
for name in FILES:
    data = subprocess.check_output(['git', 'show', f'{args.ref}:{name}'], cwd=root)
    lines.append(f'        ["{name}"] = {{size = {len(data)}, checksum = "{zlib.adler32(data):08x}"}},')
lines += ['    },', '}', '']
(root / 'release.lua').write_text('\n'.join(lines))
