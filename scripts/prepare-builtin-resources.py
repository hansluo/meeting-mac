#!/usr/bin/env python3
"""Prepare a verified, relocatable seed. Developer paths never enter the app catalog."""
import hashlib
import json
import pathlib
import shutil
import sys

repo = pathlib.Path(__file__).resolve().parent.parent
destination = pathlib.Path(sys.argv[1])
catalog = json.loads((repo / 'Sources/MeetingCore/Resources/builtin-assets.json').read_text())
sources = {
    'embeddinggemma300m': repo / 'models/embeddinggemma-300m',
    'sensevoice-int8': repo / 'models/sensevoice-int8/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17',
    'sherpa-onnx1.13.7': repo / '.build/native/sherpa-onnx-v1.13.7-osx-arm64-shared-no-tts-lib',
    'llama-server-ollama0.40.4': repo / '.build/local-llm/runtime-0.40.4',
}
for asset in catalog:
    for entry in asset['files']:
        source = sources[asset['id']] / entry['path']
        if source.is_symlink() or not source.is_file() or source.stat().st_size != entry['size']:
            raise SystemExit(f"Missing or invalid built-in resource: {asset['id']}/{entry['path']}")
        with source.open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
            if digest is None:
                hasher = hashlib.sha256()
                for block in iter(lambda: handle.read(1024 * 1024), b''):
                    hasher.update(block)
                digest = hasher.hexdigest()
        if digest != entry['sha256']:
            raise SystemExit(f"Built-in resource SHA256 mismatch: {asset['id']}/{entry['path']}")
        target = destination / asset['id'] / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if entry['path'] == 'llama-server':
            target.chmod(0o755)
print(f"Prepared {len(catalog)} verified built-in assets")
