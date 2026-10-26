"""Regenerate portable XZ integrity fixtures using Python's independent liblzma.

The raw XCF is embedded in the current Dart fixture so no GIMP is required.
"""
import base64
import json
import lzma
from pathlib import Path
import re

path = Path('test/envelope_fixtures.dart')
raw = base64.b64decode(re.search(r"'raw':\s*'([^']+)'", path.read_text())[1])
encode = lambda data: base64.b64encode(data).decode()
records = {'raw': encode(raw),
    'xz_crc64': encode(lzma.compress(raw, check=lzma.CHECK_CRC64)),
    'xz_sha256': encode(lzma.compress(raw, check=lzma.CHECK_SHA256)),
    'xz_concatenated': encode(lzma.compress(raw[:50], check=lzma.CHECK_CRC64) + b'\0' * 4 +
        lzma.compress(raw[50:], check=lzma.CHECK_SHA256) + b'\0' * 8)}
path.write_text('/// Independent Python liblzma outputs; regenerate with tool/generate_envelope_fixtures.py.\n'
    'const Map<String, String> envelopeFixtures = ' + json.dumps(records, indent=2).replace('"', "'") + ';\n')
