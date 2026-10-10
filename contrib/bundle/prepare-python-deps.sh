#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  prepare-python-deps.sh DEPENDENCY_PREFIX RUNTIME_ENV BUILD_ENV

Create isolated pip environments for macOS Pilot bundling. DEPENDENCY_PREFIX
provides the Homebrew Python used to create both environments.
EOF
}

[[ $# -eq 3 ]] || { usage >&2; exit 2; }

DEPENDENCY_PREFIX="$1"
RUNTIME_ENV="$2"
BUILD_ENV="$3"

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "ERROR: macOS is required" >&2
    exit 1
}
[[ -d "$DEPENDENCY_PREFIX" ]] || {
    echo "ERROR: dependency prefix is not a directory: $DEPENDENCY_PREFIX" >&2
    exit 1
}

DEPENDENCY_PREFIX=$(cd "$DEPENDENCY_PREFIX" && pwd -P)
PYTHON="$DEPENDENCY_PREFIX/bin/python3"
[[ -x "$PYTHON" ]] || {
    echo "ERROR: Homebrew Python not found: $PYTHON" >&2
    exit 1
}
[[ -n "$RUNTIME_ENV" && -n "$BUILD_ENV" ]] || {
    echo "ERROR: Python environment paths must not be empty" >&2
    exit 1
}
mkdir -p "$(dirname "$RUNTIME_ENV")" "$(dirname "$BUILD_ENV")"
RUNTIME_ENV=$("$PYTHON" -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' "$RUNTIME_ENV")
BUILD_ENV=$("$PYTHON" -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' "$BUILD_ENV")

[[ "$RUNTIME_ENV" != "/" && "$RUNTIME_ENV" != "$DEPENDENCY_PREFIX" ]] || {
    echo "ERROR: unsafe runtime environment path: $RUNTIME_ENV" >&2
    exit 1
}
[[ "$BUILD_ENV" != "/" && "$BUILD_ENV" != "$DEPENDENCY_PREFIX" ]] || {
    echo "ERROR: unsafe build environment path: $BUILD_ENV" >&2
    exit 1
}
[[ "$RUNTIME_ENV" != "$BUILD_ENV" ]] || {
    echo "ERROR: runtime and build environments must be different" >&2
    exit 1
}
paths_overlap() {
    case "$1/" in "$2/"*) return 0 ;; esac
    case "$2/" in "$1/"*) return 0 ;; esac
    return 1
}
if paths_overlap "$RUNTIME_ENV" "$BUILD_ENV" || \
        paths_overlap "$RUNTIME_ENV" "$DEPENDENCY_PREFIX" || \
        paths_overlap "$BUILD_ENV" "$DEPENDENCY_PREFIX"; then
    echo "ERROR: Python environments and dependency prefix must not overlap" >&2
    exit 1
fi
[[ ! -e "$RUNTIME_ENV" || -f "$RUNTIME_ENV/pyvenv.cfg" ]] || {
    echo "ERROR: refusing to clear a non-venv path: $RUNTIME_ENV" >&2
    exit 1
}
[[ ! -e "$BUILD_ENV" || -f "$BUILD_ENV/pyvenv.cfg" ]] || {
    echo "ERROR: refusing to clear a non-venv path: $BUILD_ENV" >&2
    exit 1
}
"$PYTHON" -m venv --clear --without-pip "$RUNTIME_ENV"
"$PYTHON" -m venv --clear "$BUILD_ENV"

RUNTIME_SITE=$("$RUNTIME_ENV/bin/python" -c \
    'import sysconfig; print(sysconfig.get_path("purelib"))')
"$PYTHON" -m pip install \
    --disable-pip-version-check --ignore-installed --no-input \
    --no-deps --only-binary=:all: \
    --target "$RUNTIME_SITE" \
    --requirement "$SCRIPT_DIR/requirements-runtime.txt"
"$BUILD_ENV/bin/python" -m pip install \
    --disable-pip-version-check --no-deps --no-input --only-binary=:all: \
    --requirement "$SCRIPT_DIR/requirements-build.txt"

PYTHONPATH="$RUNTIME_SITE" "$PYTHON" -m pip freeze \
    --path "$RUNTIME_SITE" > "$RUNTIME_ENV/requirements.freeze.txt"
"$BUILD_ENV/bin/python" -m pip freeze \
    > "$BUILD_ENV/requirements.freeze.txt"

echo "Runtime Python environment: $RUNTIME_ENV"
echo "Build Python environment:   $BUILD_ENV"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
