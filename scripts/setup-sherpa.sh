#!/bin/bash
set -euo pipefail
# Resolve a caller-relative archive before switching to the repository directory.
source_archive=""
if [[ $# == 1 ]]; then
  case "$1" in
    /*) source_archive="$1" ;;
    *) source_archive="$PWD/$1" ;;
  esac
fi
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'This pinned runtime requires Apple Silicon macOS.' >&2; exit 1; }
version=1.13.7
name="sherpa-onnx-v${version}-osx-arm64-shared-no-tts-lib"
expected=b3a5484f071094d3a922062e6793aca3e0ccc7388bfa5797959fa51fabffc906
mkdir -p .build/native
staging="$(mktemp -d "$PWD/.build/native/install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
archive="$staging/runtime.tar.bz2"
if [[ $# == 1 ]]; then
  cp "$source_archive" "$archive"
elif [[ $# == 0 ]]; then
  curl --fail --location --retry 3 "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${version}/${name}.tar.bz2" --output "$archive"
else
  echo 'Usage: scripts/setup-sherpa.sh [existing-release-archive]' >&2; exit 1
fi
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Runtime archive SHA256 mismatch; nothing extracted.' >&2; exit 1; }
tar -xjf "$archive" -C "$staging"
[[ -f "$staging/$name/lib/libsherpa-onnx-c-api.dylib" ]] || { echo 'Verified archive missing C API library.' >&2; exit 1; }
rm -rf ".build/native/$name"
mv "$staging/$name" .build/native/
printf '%s\n' "$PWD/.build/native/$name/lib/libsherpa-onnx-c-api.dylib"
