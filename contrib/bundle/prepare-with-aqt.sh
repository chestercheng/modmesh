#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

QT_VERSION=6.11.1
PYTHON_VERSION=3.14.7
PYTHON_RELEASE=20260929
DEPS_ROOT="$BUNDLE_REPO_ROOT/build/bundle-deps"
TOOLS_PREFIX="$DEPS_ROOT/tools"
SDK_ROOT="$DEPS_ROOT/sdk"
SDK_PREFIX="$SDK_ROOT/$QT_VERSION/macos"
AQT_CONFIG=${AQT_CONFIG:-$BUNDLE_REPO_ROOT/thirdparty/aqt_settings.ini}

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "macOS is required for macOS bundle dependencies" >&2
    exit 1
}

[[ "$(uname -m)" == "arm64" ]] || {
    echo "Apple Silicon macOS is required for macOS bundle dependencies" >&2
    exit 1
}

sha=0211ccf04c5e0a0feb0b9bf1148030e1f6a31b8eae624f13919a7752a4e3dc79
archive="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/$archive"
tmp=$(mktemp -d -t solvcon-bundle-deps)
trap 'rm -rf "$tmp"' EXIT

curl --fail --location --retry 3 --output "$tmp/$archive" "$url"
[[ "$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)" == "$sha" ]] || {
    echo "Python archive SHA-256 mismatch" >&2
    exit 1
}

mkdir -p "$TOOLS_PREFIX" "$SDK_PREFIX"
tar -xzf "$tmp/$archive" --strip-components=1 -C "$TOOLS_PREFIX"
tar -xzf "$tmp/$archive" --strip-components=1 -C "$SDK_PREFIX"

"$TOOLS_PREFIX/bin/python3" -I -m pip --isolated install \
    'pip-system-certs==5.3' 'aqtinstall==3.3.0' 'py7zr==1.1.0' \
    'cmake==4.4.3' 'pybind11==3.0.1'

AQT_CONFIG="$AQT_CONFIG" "$TOOLS_PREFIX/bin/python3" -I -m aqt install-qt \
    mac desktop "$QT_VERSION" clang_64 --outputdir "$SDK_ROOT" \
    --modules qtshadertools

"$TOOLS_PREFIX/bin/python3" -I -m pip --isolated \
    --python "$SDK_PREFIX/bin/python3" install --only-binary=:all: \
    "PySide6==$QT_VERSION" "shiboken6==$QT_VERSION" \
    'numpy==2.5.3' 'matplotlib==3.11.2' 'jsonschema==4.26.0' \
    zstandard lz4

echo "Tools prefix: $TOOLS_PREFIX"
echo "SDK prefix: $SDK_PREFIX"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79:
