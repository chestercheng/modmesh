#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

QT_VERSION=6.11.1
PYTHON_VERSION=3.14.7
PYTHON_RELEASE=20260929
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
    "shiboken6==$QT_VERSION" "shiboken6-generator==$QT_VERSION" \
    'numpy==2.5.3' 'matplotlib==3.11.2' 'jsonschema==4.26.0' \
    zstandard lz4

tar -xf "$tmp/$PYSIDE_ARCHIVE" -C "$tmp"
export PATH="$SDK_PREFIX/bin:$TOOLS_PREFIX/bin:$PATH"
SHIBOKEN_PREFIX=$("$SDK_PREFIX/bin/python3" -I -c \
    'import os, shiboken6; print(os.path.dirname(shiboken6.__file__))')
SHIBOKEN_TOOLS_PREFIX=$("$SDK_PREFIX/bin/python3" -I -c \
    'import os, shiboken6_generator; print(os.path.dirname(shiboken6_generator.__file__))')
export CMAKE_PREFIX_PATH="$SHIBOKEN_TOOLS_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# Raw standalone archives retain /install in the Python build metadata.
SYSCONFIG_MODULE_DIR="$tmp/python-sysconfig"
mkdir -p "$SYSCONFIG_MODULE_DIR"
cat > "$SYSCONFIG_MODULE_DIR/_solvcon_sysconfigdata.py" <<'PY'
import importlib
import os

build_time_vars = importlib.import_module(
    os.environ["SOLVCON_ORIGINAL_SYSCONFIGDATA_NAME"]
).build_time_vars.copy()
include = os.environ["SOLVCON_PYTHON_INCLUDE"]
build_time_vars["INCLUDEPY"] = include
build_time_vars["CONFINCLUDEPY"] = include
PY
ORIGINAL_SYSCONFIGDATA_NAME=$("$SDK_PREFIX/bin/python3" -I -c \
    'import sysconfig; print(sysconfig._get_sysconfigdata_name())')
PYTHON_INCLUDE=$("$SDK_PREFIX/bin/python3" -I -c \
    'import sysconfig; print(sysconfig.get_path("include"))')

NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
# Do not use --standalone: the bindings must load the AQT Qt installation.
PYSIDE_BUILD_OPTIONS="--qtpaths='$SDK_PREFIX/bin/qtpaths' \
--shiboken-target-path='$SHIBOKEN_PREFIX' \
--module-subset=Core,Gui,Widgets,Svg \
--macos-arch=arm64 \
--macos-deployment-target=$MACOS_DEPLOYMENT_TARGET \
--disable-pyi --log-level=verbose --no-qt-tools --enable-numpy-support \
--parallel=$NPROC --make-spec=ninja"
(
    export _PYTHON_SYSCONFIGDATA_NAME=_solvcon_sysconfigdata
    export _PYTHON_SYSCONFIGDATA_PATH="$SYSCONFIG_MODULE_DIR"
    export SOLVCON_ORIGINAL_SYSCONFIGDATA_NAME="$ORIGINAL_SYSCONFIGDATA_NAME"
    export SOLVCON_PYTHON_INCLUDE="$PYTHON_INCLUDE"
    actual_include=$("$SDK_PREFIX/bin/python3" -I -c \
        'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')
    [[ "$actual_include" == "$PYTHON_INCLUDE" && \
        -f "$actual_include/Python.h" ]] || {
        echo "Invalid Python include path: $actual_include" >&2
        exit 1
    }
    cd "$tmp/$PYSIDE_ROOT"
    "$SDK_PREFIX/bin/python3" -I -m pip --isolated install \
        --no-build-isolation --no-deps \
        --config-settings="--global-option=--build-type=pyside6" \
        --config-settings="--build-option=$PYSIDE_BUILD_OPTIONS" .
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
