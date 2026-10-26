#!/usr/bin/env python3
"""Fetch the pinned corpus and verify size and SHA-256 before accepting files."""
import argparse
import concurrent.futures
import gzip
import bz2
import lzma
import hashlib
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('test/corpus'))
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--verify-only', action='store_true')
    arguments = parser.parse_args()
    manifest = json.loads((arguments.root / 'manifest.json').read_text())

    def fetch(entry):
        path = arguments.root / entry['local']
        if not path.resolve().is_relative_to(arguments.root.resolve()):
            raise ValueError('Unsafe corpus path: ' + entry['local'])
        if not entry['url'].startswith('https://'):
            raise ValueError('Corpus download requires HTTPS')
        if path.exists():
            data = path.read_bytes()
        elif arguments.verify_only:
            raise FileNotFoundError(path)
        else:
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(urllib.parse.quote(entry['url'], safe=':/%'), timeout=60) as response:
                        data = response.read(entry['size'] + 1)
                    break
                except Exception:
                    if attempt == 3:
                        raise
                    time.sleep(attempt + 1)
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Corpus content changed: ' + entry['local'])
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if 'decoded_local' in entry:
            decoded = arguments.root / entry['decoded_local']
            if not decoded.resolve().is_relative_to(arguments.root.resolve()):
                raise ValueError('Unsafe decoded corpus path')
            decoder = lzma.decompress if entry['local'].endswith('.xz') else bz2.decompress if entry['local'].endswith('.bz2') else gzip.decompress
            expected = decoder(data)
            if arguments.verify_only:
                if decoded.read_bytes() != expected:
                    raise ValueError('Decompressed corpus content changed: ' + entry['local'])
            else:
                decoded.parent.mkdir(parents=True, exist_ok=True)
                decoded.write_bytes(expected)
        return entry['local']

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(arguments.jobs, 8))) as executor:
        for count, _ in enumerate(executor.map(fetch, manifest['entries']), 1):
            if count % 100 == 0:
                print(f'{count}/{len(manifest["entries"])} verified', flush=True)
    print(f'All {len(manifest["entries"])} downloaded artifacts verified.')


if __name__ == '__main__':
    main()
