#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

QT_VERSION=6.11.1
PYTHON_VERSION=3.14.7
PYTHON_RELEASE=20260929
LIBCLANG_VERSION=21.1.2
MACOS_DEPLOYMENT_TARGET=13.0
DEPS_ROOT="$BUNDLE_REPO_ROOT/build/bundle-deps"
TOOLS_PREFIX="$DEPS_ROOT/tools"
SDK_ROOT="$DEPS_ROOT/sdk"
# aqt always installs under <output>/<Qt version>/<architecture>.
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

tmp=$(mktemp -d -t solvcon-bundle-deps)
trap 'rm -rf "$tmp"' EXIT

download() {
    local url=$1 archive=$2 sha=$3
    curl --fail --location --retry 3 --output "$tmp/$archive" "$url"
    [[ "$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)" == "$sha" ]] || {
        echo "$archive SHA-256 mismatch" >&2
        exit 1
    }
}

PYTHON_ARCHIVE="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/$PYTHON_ARCHIVE"
download "$PYTHON_URL" "$PYTHON_ARCHIVE" \
    0211ccf04c5e0a0feb0b9bf1148030e1f6a31b8eae624f13919a7752a4e3dc79

PYSIDE_ROOT="pyside-setup-everywhere-src-$QT_VERSION"
PYSIDE_ARCHIVE="$PYSIDE_ROOT.tar.xz"
PYSIDE_URL="https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-$QT_VERSION-src/$PYSIDE_ARCHIVE"
download "$PYSIDE_URL" "$PYSIDE_ARCHIVE" \
    6ffd9835bb0dd2c56f061d62f1616bb1707cfc0202b80e3165d6be087f3965e2

LIBCLANG_ARCHIVE="libclang-release_${LIBCLANG_VERSION}-based-macos-universal.7z"
LIBCLANG_URL="https://download.qt.io/development_releases/prebuilt/libclang/$LIBCLANG_ARCHIVE"
download "$LIBCLANG_URL" "$LIBCLANG_ARCHIVE" \
    8464005b1598c52357ae4999164aaec3f048bacaa63674fb81b0ca5efd58f549

rm -rf "$TOOLS_PREFIX" "$SDK_ROOT"
mkdir -p "$TOOLS_PREFIX" "$SDK_PREFIX"
tar -xzf "$tmp/$PYTHON_ARCHIVE" --strip-components=1 -C "$TOOLS_PREFIX"
tar -xzf "$tmp/$PYTHON_ARCHIVE" --strip-components=1 -C "$SDK_PREFIX"

"$TOOLS_PREFIX/bin/python3" -I -m pip --isolated install \
    'pip-system-certs==5.3' 'aqtinstall==3.3.0' 'py7zr==1.1.0' \
    'cmake==4.4.3' 'ninja==1.13.0' 'pybind11==3.0.1'

# qtbase supplies Core, Gui, Widgets, plugins, and deployment tools. Svg is a
# separate base archive, while ShaderTools is an extra module.
AQT_CONFIG="$AQT_CONFIG" "$TOOLS_PREFIX/bin/python3" -I -m aqt install-qt \
    mac desktop "$QT_VERSION" clang_64 --outputdir "$SDK_ROOT" \
    --archives qtbase qtsvg --modules qtshadertools

for component in Core Gui Widgets Svg ShaderTools; do
    config="$SDK_PREFIX/lib/cmake/Qt6$component/Qt6${component}Config.cmake"
    [[ -f "$config" ]] || {
        echo "AQT installation is missing Qt6$component" >&2
        exit 1
    }
done

"$TOOLS_PREFIX/bin/python3" -I -m pip --isolated \
    --python "$SDK_PREFIX/bin/python3" install --only-binary=:all: \
    setuptools wheel \
    'numpy==2.5.3' 'matplotlib==3.11.2' 'jsonschema==4.26.0' \
    zstandard lz4

tar -xf "$tmp/$LIBCLANG_ARCHIVE" -C "$tmp" \
    libclang/lib libclang/include
while IFS= read -r rel; do
    [[ -e "$tmp/libclang/$rel" ]] && continue
    mkdir -p "$tmp/libclang/$(dirname "$rel")"
    : > "$tmp/libclang/$rel"
    chmod +x "$tmp/libclang/$rel"
done < <(grep -rhoE '[$][{]_IMPORT_PREFIX[}]/[A-Za-z0-9._/-]+' \
    "$tmp/libclang/lib/cmake" 2>/dev/null | \
    sed 's#[$][{]_IMPORT_PREFIX[}]/##' | sort -u)

tar -xf "$tmp/$PYSIDE_ARCHIVE" -C "$tmp"
export LLVM_INSTALL_DIR="$tmp/libclang"
export PATH="$SDK_PREFIX/bin:$TOOLS_PREFIX/bin:$PATH"
NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
# Do not use --standalone: the bindings must load the AQT Qt installation.
(
    cd "$tmp/$PYSIDE_ROOT"
    "$SDK_PREFIX/bin/python3" setup.py install \
        --qtpaths="$SDK_PREFIX/bin/qtpaths" \
        --module-subset=Core,Gui,Widgets,Svg \
        --macos-arch=arm64 \
        --macos-deployment-target="$MACOS_DEPLOYMENT_TARGET" \
        --disable-pyi \
        --verbose-build \
        --ignore-git \
        --no-qt-tools \
        --enable-numpy-support \
        --parallel="$NPROC" \
        --make-spec=ninja
)

PYSIDE_DIR=$("$SDK_PREFIX/bin/python3" -I - <<'PY'
import importlib.util
import os
import PySide6
from PySide6 import QtCore, QtGui, QtSvg, QtWidgets
import shiboken6
import shiboken6_generator

if importlib.util.find_spec("PySide6.QtMultimedia") is not None:
    raise SystemExit("unexpected PySide6.QtMultimedia binding")
print(os.path.dirname(PySide6.__file__))
PY
)
[[ ! -d "$PYSIDE_DIR/Qt" ]] || {
    echo "Source-built PySide6 unexpectedly bundled a private Qt runtime" >&2
    exit 1
}

echo "Tools prefix: $TOOLS_PREFIX"
echo "SDK prefix: $SDK_PREFIX"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79:
