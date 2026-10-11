#!/bin/bash
#
# This script is a prototype to create a self-contained macOS .app bundle for
# solvcon from an explicit dependency prefix, package it into a DMG file, and
# verify both are hermetic. No devenv activation or Homebrew is needed.
#
#   - Python: python-build-standalone (not a macOS framework build), installed
#     in the traditional prefix layout.
#   - Qt: installed by aqt, retaining its <version>/macos layout.
#   - PySide6, shiboken6, numpy, matplotlib: pip packages in the prefix.
#
# It employs macdeployqt, otool, and install_name_tool to process the binaries,
# and ad-hoc codesign to reseal them.
#
# !! WARNING !!
# This is a prototype. It writes under build/ and, with `bundle`, edits the
# copies of the binaries inside the .app only. Only `prepare` installs into the
# dependency prefix. Neither `check` nor `bundle` installs dependencies.
#
# Usage:
#   ./contrib/bundle/bundle-with-prefix.sh prepare [--dry-run]
#   ./contrib/bundle/bundle-with-prefix.sh check [--prefix DIR]
#   ./contrib/bundle/bundle-with-prefix.sh bundle [--prefix DIR] [--skip-build]
#                                                [--skip-check] [--dry-run]
#                                                [--output DIR]
#   ./contrib/bundle/bundle-with-prefix.sh verify path/to/pilot.dmg
#
#   --skip-build   Skip `make pilot` and use the existing build output.
#   --skip-check   Skip the bundle/DMG verification phase.
#   --dry-run      Check the environment and print the plan; change nothing.
#   --output DIR   Write pilot.dmg into DIR (default: build/).
#   --prefix DIR   Dependency prefix (default: build/bundle-deps/6.11.1/macos).
#                  For `prepare`, DIR must end with /6.11.1/macos.
#   AQT_CONFIG     Override the shared CI aqt settings file.
#
# The DMG holds pilot.app and a shortcut to /Applications. The icons are placed
# with the app on the left and Applications on the right by driving Finder
# through AppleScript, which needs the Automation permission and a desktop
# session. It is best effort; set BUNDLE_DMG_LAYOUT=0 to skip the placement.
#
# Layout of the Python runtime inside the bundle:
#   Contents/Frameworks/libpython<X.Y>.dylib   found through @rpath
#   Contents/lib/python<X.Y>/                   standard library
#   Contents/lib/python<X.Y>/site-packages/     pip packages and solvcon
# The embedded interpreter is started with the default configuration, so
# CPython locates its prefix by walking up from Contents/MacOS/pilot until it
# finds lib/python<X.Y>/os.py, which resolves to Contents/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CALLER_DIR="$PWD"
cd "$BUNDLE_REPO_ROOT"

MIN_LOADS=${MIN_LOADS:-50}
BUNDLE_BUILD_PATH=${BUNDLE_BUILD_PATH:-build/relbundle}
QT_VERSION=6.11.1
PYTHON_VERSION=3.14.7
PYTHON_RELEASE=20260929
PREFIX="$BUNDLE_REPO_ROOT/build/bundle-deps/$QT_VERSION/macos"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
  contrib/bundle/bundle-with-prefix.sh prepare [--prefix DIR] [--dry-run]
  contrib/bundle/bundle-with-prefix.sh check [--prefix DIR]
  contrib/bundle/bundle-with-prefix.sh bundle [--prefix DIR] [--skip-build] [--skip-check] [--dry-run] [--output DIR]
  contrib/bundle/bundle-with-prefix.sh verify path/to/pilot.dmg [--prefix DIR]
  contrib/bundle/bundle-with-prefix.sh all [--prefix DIR] [--skip-build] [--skip-check] [--dry-run] [--output DIR]

Subcommands:
  prepare  Install standalone Python, aqt Qt, and pip packages into the prefix.
  check    Check the dependency prefix. Does not build or install.
  bundle   Build/package pilot.app and pilot.dmg from the prefix, then verify.
  verify   Verify a generated release DMG artifact.
  all      Run check and then bundle. Never installs dependencies.

The default prefix is build/bundle-deps/6.11.1/macos under the repo.
prepare requires a prefix ending in /6.11.1/macos, preserving aqt's layout.
Relative --prefix, --output, and artifact paths are relative to the caller.
--dry-run is available for prepare, bundle, and all; it changes nothing.
prepare uses thirdparty/aqt_settings.ini, as CI does; AQT_CONFIG overrides it.
EOF
}

note() { printf '==> %s\n' "$*"; }
ok() { printf 'OK    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; return 1; }

require_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required for macOS bundle release"
}

setup_hint() {
    cat >&2 <<'EOF'

Prepare the default dependency prefix on macOS, then retry:
  ./contrib/bundle/bundle-with-prefix.sh prepare
Or select an existing prefix with --prefix DIR.
EOF
}

prepare_prefix() {
    local arch sha archive url deps_root version config
    config="${AQT_CONFIG:-$BUNDLE_REPO_ROOT/thirdparty/aqt_settings.ini}"
    case "$config" in /*) ;; *) config="$CALLER_DIR/$config" ;; esac
    [[ -f "$config" ]] || { fail "aqt settings file not found: $config"; return 1; }
    case "$PREFIX" in
        */"$QT_VERSION"/macos) deps_root=${PREFIX%/"$QT_VERSION"/macos} ;;
        *) fail "prepare prefix must end with /$QT_VERSION/macos"; return 1 ;;
    esac
    case "$(uname -m)" in
        arm64)
            arch=aarch64
            sha=0211ccf04c5e0a0feb0b9bf1148030e1f6a31b8eae624f13919a7752a4e3dc79
            ;;
        x86_64)
            arch=x86_64
            sha=18b12f5836c6a5cee8223f1759d26bd3174c1271bb3b7882dc09e2d961f3c863
            ;;
        *) fail "unsupported macOS architecture: $(uname -m)"; return 1 ;;
    esac
    archive="cpython-${PYTHON_VERSION}+${PYTHON_RELEASE}-${arch}-apple-darwin-install_only.tar.gz"
    url="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_RELEASE/$archive"
    note "Dependency prefix: $PREFIX"
    note "Python $PYTHON_VERSION ($arch), standalone release $PYTHON_RELEASE"
    note "Qt $QT_VERSION (mac desktop clang_64), with qtshadertools"
    note "aqt settings: $config"
    note "aqt TLS: macOS system certificate store (pip-system-certs)"
    if [[ $DRY_RUN -ne 0 ]]; then
        note "DRY RUN: download $url and verify SHA-256 $sha"
        note "Extract Python into $PREFIX; install pinned CI packages with its pip"
        note "Run AQT_CONFIG=\"$config\" aqt install-qt mac desktop $QT_VERSION clang_64 --outputdir \"$deps_root\" --modules qtshadertools"
        return 0
    fi

    if [[ -e "$PREFIX/bin/python3" ]]; then
        version=$("$PREFIX/bin/python3" -I -c 'import platform; print(platform.python_version())')
        [[ "$version" == "$PYTHON_VERSION" ]] || \
            { fail "prefix has Python $version; expected $PYTHON_VERSION. Choose a new prefix."; return 1; }
    else
        for cmd in curl tar shasum; do
            require_command "$cmd"
        done
        PREPARE_TMP=$(mktemp -d -t solvcon-prefix)
        curl --fail --location --retry 3 --output "$PREPARE_TMP/$archive" "$url"
        [[ "$(shasum -a 256 "$PREPARE_TMP/$archive" | cut -d' ' -f1)" == "$sha" ]] || \
            { fail "Python archive SHA-256 mismatch"; return 1; }
        mkdir -p "$PREFIX"
        tar -xzf "$PREPARE_TMP/$archive" --strip-components=1 -C "$PREFIX"
    fi
    PREFIX=$(cd "$PREFIX" && pwd -P)
    deps_root=${PREFIX%/"$QT_VERSION"/macos}
    export PATH="$PREFIX/bin:$PATH"
    python_dylib_check >/dev/null
    if [[ -x "$PREFIX/bin/qtpaths" ]]; then
        version=$("$PREFIX/bin/qtpaths" --query QT_VERSION)
        [[ "$version" == "$QT_VERSION" ]] || \
            { fail "prefix has Qt $version; expected $QT_VERSION. Choose a new prefix."; return 1; }
    fi
    # aqt spawns fresh worker interpreters on macOS. The .pth bootstrap enables
    # system certificate verification in the workers as well as the parent.
    "$PREFIX/bin/python3" -I -m pip --isolated install \
        'pip-system-certs==5.3' 'aqtinstall==3.3.0' 'py7zr==1.1.0' \
        'cmake==4.4.3' 'pybind11==3.0.1'
    "$PREFIX/bin/python3" -I -B - <<'PY'
import ssl
from pip._vendor import truststore

if ssl.SSLContext is not truststore.SSLContext:
    raise SystemExit('System certificate startup hook did not activate')
context = ssl.create_default_context()
if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname:
    raise SystemExit('TLS certificate and hostname checks must remain enabled')
print('    OK: macOS system certificate verification is active')
PY
    AQT_CONFIG="$config" "$PREFIX/bin/python3" -I -m aqt install-qt mac desktop "$QT_VERSION" clang_64 \
        --outputdir "$deps_root" --modules qtshadertools
    "$PREFIX/bin/python3" -I -m pip --isolated install --only-binary=:all: \
        "PySide6==$QT_VERSION" "shiboken6==$QT_VERSION" \
        'numpy==2.5.3' 'matplotlib==3.11.2' 'jsonschema==4.26.0' \
        zstandard lz4
    check_deps
    note "Dependency preparation complete: $PREFIX"
}

require_command() {
    local cmd="$1" hint="${2:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd: $(command -v "$cmd")"
    else
        fail "$cmd: not found${hint:+ ($hint)}"
    fi
}

# Resolve a command and require it to live under the selected prefix.
require_in_prefix() {
    local cmd="$1" path
    path=$(command -v "$cmd" 2>/dev/null || true)
    if [[ -n "$path" && "$path" == "$PREFIX"/* ]]; then
        ok "$cmd is under the dependency prefix: $path"
    else
        fail "$cmd is not from the dependency prefix (${path:-not found}; expected under $PREFIX)"
    fi
}

python_module_check() {
    local module="$1" hint="${2:-}" out
    out=$(mktemp -t solvcon-bundle-pycheck)
    if "$PREFIX/bin/python3" -I -B - "$module" "$PREFIX" <<'PY' >"$out" 2>&1
import importlib
import os
import sys
module = sys.argv[1]
try:
    mod = importlib.import_module(module)
except Exception as e:
    print(f"{type(e).__name__}: {e}")
    raise SystemExit(1)
else:
    path = os.path.realpath(mod.__file__)
    if os.path.commonpath([path, sys.argv[2]]) != sys.argv[2]:
        raise SystemExit(f"module is outside the dependency prefix: {path}")
    print(path)
PY
    then
        ok "python module $module: $(cat "$out")"
        rm -f "$out"
    else
        cat "$out" >&2 || true
        rm -f "$out"
        fail "python module $module: missing${hint:+ ($hint)}"
    fi
}

# The embedded interpreter needs the shared libpython. A framework build is not
# expected: python-build-standalone installs libpython<X.Y>.dylib in lib/.
python_dylib_check() {
    local ver path
    ver=$(bundle_pyver)
    path="$PREFIX/lib/libpython${ver}.dylib"
    [[ -f "$path" ]] || { echo "Python dylib not found: $path"; return 1; }
    [[ -f "$PREFIX/lib/python${ver}/os.py" ]] || \
        { echo "Python stdlib not found: $PREFIX/lib/python${ver}"; return 1; }
    echo "$path"
}

check_pybind11_cmake() {
    local config_dir
    config_dir=$("$PREFIX/bin/python3" -I -B -m pybind11 --cmakedir 2>/dev/null || true)
    if [[ "$config_dir" == "$PREFIX"/* && -f "$config_dir/pybind11Config.cmake" ]]; then
        ok "pybind11 CMake config: $config_dir/pybind11Config.cmake"
        return 0
    fi
    fail "pybind11 CMake config: not found (python3 -m pip install pybind11)"
}

check_deps() {
    local dylib_path failed=0 qt_ver pyside_ver
    require_macos

    ok "dependency prefix: $PREFIX"

    for cmd in cmake make python3 macdeployqt qtpaths otool \
        install_name_tool codesign hdiutil rsync shasum; do
        require_command "$cmd" || failed=1
    done

    require_in_prefix python3 || failed=1
    require_in_prefix macdeployqt || failed=1
    require_in_prefix qtpaths || failed=1

    if dylib_path=$(python_dylib_check 2>&1); then
        ok "Python shared library: $dylib_path"
    else
        fail "$dylib_path" || failed=1
    fi

    check_pybind11_cmake || failed=1
    python_module_check numpy "python3 -m pip install numpy" || failed=1
    python_module_check PySide6 "python3 -m pip install pyside6" || failed=1
    python_module_check shiboken6 "python3 -m pip install shiboken6" || failed=1
    python_module_check matplotlib "python3 -m pip install matplotlib" || failed=1
    python_module_check jsonschema "python3 -m pip install jsonschema" || failed=1
    python_module_check zstandard "python3 -m pip install zstandard" || failed=1
    python_module_check lz4.frame "python3 -m pip install lz4" || failed=1

    qt_ver=$("$PREFIX/bin/qtpaths" --query QT_VERSION 2>/dev/null || true)
    pyside_ver=$("$PREFIX/bin/python3" -I -B -c "import PySide6; print(PySide6.__version__)" 2>/dev/null || true)
    if [[ -n "$qt_ver" && "$qt_ver" == "$pyside_ver" ]]; then
        ok "Qt $qt_ver matches PySide6 $pyside_ver"
    else
        fail "Qt (${qt_ver:-unknown}) and PySide6 (${pyside_ver:-unknown}) versions differ" || failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        setup_hint
        exit 1
    fi
}

# Selected Python's "X.Y" version string.
bundle_pyver() {
    "$PREFIX/bin/python3" -I -B -c "import sys; print('%d.%d' % sys.version_info[:2])"
}

# Print every Mach-O under $1, NUL-delimited: standalone dylibs, .so
# extensions, MacOS/ binaries, and the main binary of every nested framework.
# Framework binaries cannot be matched by file mode, because the packages ship
# them as 0644, so synthesise the canonical path (Versions/<v>/<name>)
# explicitly.
list_macho() {
    find "$1" -name '*.framework' -type d -print0 | \
        while IFS= read -r -d '' fw; do
            local nm ver bin
            nm=$(basename "$fw" .framework)
            for ver in "$fw"/Versions/*; do
                [[ -d "$ver" && ! -L "$ver" ]] || continue
                bin="$ver/$nm"
                [[ -f "$bin" ]] && printf '%s\0' "$bin"
            done
        done
    find "$1" -type f \( -name '*.dylib' -o -name '*.so' -o -path '*/MacOS/*' \) -print0
}

# Print every LC_RPATH entry of the Mach-O at $1, one per line.  `otool -L`
# does not list these, so we parse `otool -l`.  The entry in the `otool -l`
# output looks like:
# ```
# Load command 33
#           cmd LC_RPATH
#       cmdsize 96
#          path /path/to/PySide6 (offset 12)
# ```
# The parsed result is:
# ```
# /path/to/PySide6
# ```
binary_rpaths() {
    otool -l "$1" 2>/dev/null | awk '
        /^[[:space:]]*cmd / { c = 0 }
        /cmd LC_RPATH/      { c = 1; next }
        c && $1 == "path"   {
            sub(/^[[:space:]]*path /, "")
            sub(/ \(offset [0-9]+\).*$/, "")
            if (!seen[$0]++) print
            c = 0
        }
    '
}

resolve_rpath() {
    local bin="$1" ref="$2" rp directory candidate resolved rpaths
    rpaths=$(binary_rpaths "$bin") || return 1
    while IFS= read -r rp; do
        case "$rp" in
            @loader_path/*) directory="$(dirname "$bin")/${rp#@loader_path/}" ;;
            @executable_path/*) directory="$(dirname "$BINARY")/${rp#@executable_path/}" ;;
            /*) directory="$rp" ;;
            *) continue ;;
        esac
        candidate="$directory/${ref#@rpath/}"
        [[ -f "$candidate" ]] || continue
        resolved=$("$PREFIX/bin/python3" -I -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$candidate") || return 1
        case "$resolved" in
            "$APP/Contents/"*|"$PREFIX/"*) printf '%s\n' "$resolved"; return 0 ;;
        esac
    done <<< "$rpaths"
    return 1
}

binary_loads() {
    otool -L "$1" | awk '/^[[:space:]]/ {
        sub(/^[[:space:]]+/, "")
        sub(/ \(compatibility version.*$/, "")
        if (!seen[$0]++) print
    }'
}

external_references() {
    local ref
    while IFS= read -r ref; do
        case "$ref" in
            /System/Library|/System/Library/*|/usr/lib|/usr/lib/*) ;;
            /Library/Apple/System/Library|/Library/Apple/System/Library/*) ;;
            /System/iOSSupport/System/Library|/System/iOSSupport/System/Library/*|/System/iOSSupport/usr/lib|/System/iOSSupport/usr/lib/*) ;;
            /System/Volumes/Preboot/Cryptexes/OS/System/Library|/System/Volumes/Preboot/Cryptexes/OS/System/Library/*|/System/Volumes/Preboot/Cryptexes/OS/usr/lib|/System/Volumes/Preboot/Cryptexes/OS/usr/lib/*) ;;
            /*) printf '%s\n' "$ref" ;;
        esac
    done
}

external_runtime_loads() {
    local trace="$1" bin="$2" app real_app
    app=$(dirname "$(dirname "$(dirname "$bin")")")
    real_app=$(cd "$app" && pwd -P)
    awk -v app="$app/" -v real_app="$real_app/" '
        /^dyld\[/ {
            sub(/^dyld\[[^]]*\]:[[:space:]]*/, "")
            sub(/^<[^>]*>[[:space:]]*/, "")
            if (index($0, app) == 1 || index($0, real_app) == 1) next
            if ($0 ~ /^\/(usr\/lib|System\/Library)\//) next
            if ($0 ~ /^\/Library\/Apple\/System\/Library\//) next
            if ($0 ~ /^\/System\/iOSSupport\/(usr\/lib|System\/Library)\//) next
            if ($0 ~ /^\/System\/Volumes\/Preboot\/Cryptexes\/OS\/(usr\/lib|System\/Library)\//) next
            print
        }
    ' "$trace"
}

# Only macOS system paths may remain absolute; all other dependencies belong
# inside the app, even when they were not under the selected prefix.
check_self_contained() {
    local total=0 bad=0 f load_refs rpath_refs
    while IFS= read -r -d '' f; do
        total=$((total+1))
        load_refs=$(binary_loads "$f" | external_references) || return 1
        rpath_refs=$(binary_rpaths "$f" | external_references) || return 1
        if [[ -n "$load_refs" || -n "$rpath_refs" ]]; then
            bad=$((bad+1))
            echo "    BAD: $f"
            [[ -n "$load_refs" ]] && echo "$load_refs" | sed 's/^/        load:  /'
            [[ -n "$rpath_refs" ]] && echo "$rpath_refs" | sed 's/^/        rpath: /'
        fi
    done < <(list_macho "$1")
    [[ $total -gt 0 ]] || { fail "no Mach-O files found in $1"; return 1; }
    if [[ $bad -eq 0 ]]; then
        echo "    OK: $total Mach-O files, no external non-system paths"
        return 0
    fi
    echo "ERROR: $bad of $total Mach-O files still reference host prefixes" >&2
    return 1
}

verify_app_structure() {
    local app="$1" bin
    [[ -d "$app" ]] || fail "app not found: $app"
    [[ -f "$app/Contents/Info.plist" ]] || fail "Info.plist not found"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" == "$(basename "$bin")" ]] || \
        fail "CFBundleExecutable does not name the main binary"
    [[ -x "$bin" ]] || fail "main binary not executable: $bin"
    [[ -d "$app/Contents/Frameworks" ]] || fail "Contents/Frameworks not found"
    [[ -d "$app/Contents/Resources" ]] || fail "Contents/Resources not found"
    file "$bin"
}

runtime_import_check() {
    local bin="$1" contents external
    contents=$(dirname "$(dirname "$bin")")
    if (
        cd "$VERIFY_TMP" || exit 1
        env -i HOME="$VERIFY_TMP/home" USER="${USER:-nobody}" \
            PATH=/usr/bin:/bin TERM="${TERM:-xterm}" PYTHONNOUSERSITE=1 DYLD_PRINT_LIBRARIES=1 \
            "$bin" --mode=python - "$contents" <<'PY'
import pathlib
import sys

import jsonschema
import lz4.frame
import matplotlib
import numpy
import PySide6
import shiboken6
import solvcon
import zstandard
from solvcon.pilot.base import _base_app
from matplotlib.backends.backend_agg import FigureCanvasAgg
from matplotlib.figure import Figure

contents = pathlib.Path(sys.argv[1]).resolve()
assert pathlib.Path(sys.prefix).resolve() == contents, sys.prefix
assert sys.flags.no_user_site
for module in (jsonschema, lz4.frame, matplotlib, numpy, PySide6,
               shiboken6, solvcon, zstandard, _base_app):
    path = pathlib.Path(module.__file__).resolve()
    assert contents in path.parents, (module.__name__, str(path))
figure = Figure()
figure.subplots().plot([0, 1], [0, 1])
FigureCanvasAgg(figure).draw()
data = b'solvcon bundle codec check'
assert lz4.frame.decompress(lz4.frame.compress(data)) == data
assert zstandard.ZstdDecompressor().decompress(
    zstandard.ZstdCompressor().compress(data)) == data
print('    OK: bundled imports, Matplotlib rendering, and MCAP codecs')
PY
    ) 2>"$VERIFY_TRACE"; then
        external=$(external_runtime_loads "$VERIFY_TRACE" "$bin")
        [[ -z "$external" ]] || { fail "runtime import loaded external native code: $external"; return 1; }
        grep -q '^dyld\[' "$VERIFY_TRACE" || { fail "runtime import produced no dyld trace"; return 1; }
    else
        cat "$VERIFY_TRACE" >&2
        fail "isolated runtime import check failed"
        return 1
    fi
}

smoke_launch_verify() {
    local bin="$1" trace="$2" pid elapsed=0 loaded external
    : > "$trace"
    (
        cd "$VERIFY_TMP"
        exec env -i HOME="$VERIFY_TMP/home" USER="${USER:-nobody}" \
            PATH=/usr/bin:/bin TERM="${TERM:-xterm}" PYTHONNOUSERSITE=1 \
            DYLD_PRINT_LIBRARIES=1 "$bin"
    ) >/dev/null 2>"$trace" &
    pid=$!
    while [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
        loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
        [[ ${loaded:-0} -ge $MIN_LOADS ]] && break
    done
    # Loading libraries is not enough: pilot can abort right after, as it does
    # when the Qt platform plugin is missing. It must still be running after
    # the settle time.
    local settle=0 early_exit=0
    while [[ $settle -lt ${SMOKE_SETTLE:-5} ]]; do
        kill -0 "$pid" 2>/dev/null || { early_exit=1; break; }
        sleep 1
        settle=$((settle + 1))
    done
    kill -0 "$pid" 2>/dev/null || early_exit=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [[ $early_exit -eq 1 ]]; then
        echo "ERROR: pilot exited within ${SMOKE_SETTLE:-5}s of loading its libraries:" >&2
        grep -v '^dyld\[' "$trace" | head -20 | sed 's/^/    /' >&2
        return 1
    fi

    loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
    if [[ $loaded -lt $MIN_LOADS ]]; then
        echo "ERROR: pilot loaded only $loaded libraries; did it crash early?" >&2
        sed -n '1,80p' "$trace" >&2
        return 1
    fi
    external=$(external_runtime_loads "$trace" "$bin")
    if [[ -n "$external" ]]; then
        echo "ERROR: smoke launch loaded native code outside the app and macOS system locations:" >&2
        printf '%s\n' "$external" >&2
        return 1
    fi
    echo "    OK: $loaded libraries loaded from the app and macOS system locations"
}

VERIFY_MNT=""
VERIFY_TMP=""
VERIFY_TRACE=""
VERIFY_MARKER=""
cleanup_verify() {
    if [[ -n "${VERIFY_MNT:-}" ]]; then
        hdiutil detach -quiet "$VERIFY_MNT" >/dev/null 2>&1 \
            || hdiutil detach -force -quiet "$VERIFY_MNT" >/dev/null 2>&1 \
            || true
        rmdir "$VERIFY_MNT" 2>/dev/null || true
    fi
    [[ -n "${VERIFY_TMP:-}" ]] && rm -rf "$VERIFY_TMP"
    [[ -n "${VERIFY_TRACE:-}" ]] && rm -f "$VERIFY_TRACE"
    [[ -n "${VERIFY_MARKER:-}" ]] && rm -f "$VERIFY_MARKER"
    return 0
}

verify_dmg() {
    local dmg="$1" mnt tmp trace marker app bin copied_app
    require_macos
    [[ -f "$dmg" ]] || fail "release artifact not found: $dmg"

    note "Release artifact"
    ls -lh "$dmg"
    shasum -a 256 "$dmg"
    hdiutil imageinfo "$dmg" >/dev/null

    VERIFY_MNT=$(mktemp -d -t solvcon-release-dmg)
    VERIFY_TMP=$(mktemp -d -t solvcon-release-app)
    VERIFY_TRACE=$(mktemp -t solvcon-release-dyld)
    VERIFY_MARKER=$(mktemp -t solvcon-release-marker)
    mnt="$VERIFY_MNT"
    tmp="$VERIFY_TMP"
    trace="$VERIFY_TRACE"
    marker="$VERIFY_MARKER"
    mkdir -p "$tmp/home"

    note "Mounting DMG"
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
    app=$(find "$mnt" -maxdepth 2 -name '*.app' -type d -print -quit)
    [[ -n "$app" ]] || fail "no .app found in $dmg"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"

    note "Checking mounted app structure"
    verify_app_structure "$app"

    note "Checking code signature before launch"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose=4 "$app" 2>&1 || \
        echo "    warning: spctl rejected this app (expected for ad-hoc signed prototype builds)"

    note "Static scan for host package paths"
    check_self_contained "$app"

    note "Runtime import check from a writable app copy"
    ditto "$app" "$tmp/$(basename "$app")"
    copied_app="$tmp/$(basename "$app")"
    codesign --verify --deep --strict "$copied_app"
    touch "$marker"
    runtime_import_check "$copied_app/Contents/MacOS/$(basename "$copied_app" .app)"
    smoke_launch_verify "$copied_app/Contents/MacOS/$(basename "$copied_app" .app)" "$trace"
    if find "$copied_app" -name '*.pyc' -newer "$marker" -print -quit | grep -q .; then
        echo "ERROR: runtime import wrote Python bytecode into the signed app bundle:" >&2
        find "$copied_app" -name '*.pyc' -newer "$marker" -print | sed -n '1,20p' >&2
        return 1
    fi
    codesign --verify --deep --strict "$copied_app"

    note "Smoke launch from mounted DMG"
    smoke_launch_verify "$bin" "$trace"

    note "Release artifact verification passed"
}

COMMAND=bundle
if [[ $# -gt 0 ]]; then
    case "$1" in
        prepare|check|bundle|verify|all)
            COMMAND="$1"
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
    esac
fi

VERIFY_ARTIFACT=""
SKIP_BUILD=0
SKIP_CHECK=0
DRY_RUN=0
OUTPUT_DIR="$BUNDLE_REPO_ROOT/build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --prefix|--output)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || \
                { echo "Missing argument for $1" >&2; exit 2; }
            if [[ "$1" == --prefix ]]; then
                PREFIX="$2"
            elif [[ "$COMMAND" == bundle || "$COMMAND" == all ]]; then
                OUTPUT_DIR="$2"
            else
                echo "--output is only available for bundle and all" >&2
                exit 2
            fi
            shift 2
            ;;
        --dry-run)
            [[ "$COMMAND" == prepare || "$COMMAND" == bundle || "$COMMAND" == all ]] || \
                { echo "--dry-run is only available for prepare, bundle, and all" >&2; exit 2; }
            DRY_RUN=1
            shift
            ;;
        --skip-build|--skip-check)
            [[ "$COMMAND" == bundle || "$COMMAND" == all ]] || \
                { echo "$1 is only available for bundle and all" >&2; exit 2; }
            if [[ "$1" == --skip-build ]]; then SKIP_BUILD=1; else SKIP_CHECK=1; fi
            shift
            ;;
        *)
            if [[ "$COMMAND" == verify && -z "$VERIFY_ARTIFACT" && "$1" != -* ]]; then
                VERIFY_ARTIFACT="$1"
                shift
            else
                echo "Unexpected argument: $1" >&2
                usage >&2
                exit 2
            fi
            ;;
    esac
done
[[ "$COMMAND" != verify || -n "$VERIFY_ARTIFACT" ]] || { usage >&2; exit 2; }

case "$PREFIX" in /*) ;; *) PREFIX="$CALLER_DIR/$PREFIX" ;; esac
PREFIX=${PREFIX%/}
[[ -n "$PREFIX" && "$PREFIX" != / ]] || { echo "--prefix must not be the filesystem root" >&2; exit 2; }
case "$OUTPUT_DIR" in /*) ;; *) OUTPUT_DIR="$CALLER_DIR/$OUTPUT_DIR" ;; esac
if [[ -n "$VERIFY_ARTIFACT" && "$VERIFY_ARTIFACT" != /* ]]; then
    VERIFY_ARTIFACT="$CALLER_DIR/$VERIFY_ARTIFACT"
fi
require_macos
if [[ -d "$PREFIX" ]]; then
    PREFIX=$(cd "$PREFIX" && pwd -P)
fi
[[ "$PREFIX" != / ]] || { echo "--prefix must not resolve to the filesystem root" >&2; exit 2; }
export PATH="$PREFIX/bin:$PATH"
export PYTHONNOUSERSITE=1
unset PYTHONHOME PYTHONPATH
PREFIX_ESC=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$+?(){}|]/\\&/g')
PREFIX_PATH_RE="^${PREFIX_ESC}/"

# Record the starting time of the script and the first step. SECONDS is bash's
# built-in elapsed-second counter.
T_SCRIPT=$SECONDS
T_STEP=$T_SCRIPT

# Single cleanup hook for every temp resource the script creates. Each
# variable is initialised empty here and populated lazily (in later steps).
# The trap is set once. Any later step can register a temp file or DMG mount
# without juggling its own trap.
CLOSURE_TMP=""
PREPARE_TMP=""
DMG_STAGE=""
DMG_RW=""
LAYOUT_MNT=""
cleanup() {
    cleanup_verify
    [[ -n "$PREPARE_TMP" ]] && rm -rf "$PREPARE_TMP"
    [[ -n "$CLOSURE_TMP" ]] && rm -rf "$CLOSURE_TMP"
    if [[ -n "$LAYOUT_MNT" ]]; then
        hdiutil detach -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
            || hdiutil detach -force -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
            || true
    fi
    [[ -n "$DMG_STAGE" ]] && rm -rf "$DMG_STAGE"
    [[ -n "$DMG_RW" ]] && rm -f "$DMG_RW"
    return 0
}
trap cleanup EXIT

case "$COMMAND" in
    prepare)
        prepare_prefix
        exit 0
        ;;
    check)
        check_deps
        exit 0
        ;;
    verify)
        verify_dmg "$VERIFY_ARTIFACT"
        exit 0
        ;;
esac
check_deps

# ---------------------------------------------------------------------------
# Derive paths
# ---------------------------------------------------------------------------

PY_VER=$(bundle_pyver)
BUILD_PATH="$BUNDLE_BUILD_PATH"
case "$BUILD_PATH" in
    build/*) ;;
    *) fail "BUNDLE_BUILD_PATH must be a relative path under build/"; exit 2 ;;
esac
case "/$BUILD_PATH/" in
    */../*) fail "BUNDLE_BUILD_PATH must not contain .."; exit 2 ;;
esac
APP=$("$PREFIX/bin/python3" -I -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$BUNDLE_REPO_ROOT/$BUILD_PATH/cpp/binary/pilot/pilot.app")
if [[ "$PREFIX" == "$APP" || "$PREFIX" == "$APP"/* ]]; then
    fail "dependency prefix must not be inside the app being rebuilt"
    exit 2
fi
BINARY="$APP/Contents/MacOS/pilot"
FW_DIR="$APP/Contents/Frameworks"
PY_DYLIB="$PREFIX/lib/libpython${PY_VER}.dylib"
PY_STDLIB="$PREFIX/lib/python${PY_VER}"
BUNDLED_LIB="$APP/Contents/lib/python${PY_VER}"
BUNDLED_SITE="$BUNDLED_LIB/site-packages"

# Copy the complete prefix's site-packages first; reducing the package set is
# separate from making the dependency source explicit.
SITE_DIRS=()
SITE_PATHS=$("$PREFIX/bin/python3" -I -B - "$PREFIX" <<'PY'
import os
import site
import sys

for directory in dict.fromkeys(site.getsitepackages()):
    directory = os.path.realpath(directory)
    if os.path.commonpath([directory, sys.argv[1]]) != sys.argv[1]:
        raise SystemExit(f"site-packages is outside the prefix: {directory}")
    if os.path.isdir(directory):
        print(directory)
PY
)
while IFS= read -r line; do
    [[ -n "$line" ]] && SITE_DIRS+=("$line")
done <<< "$SITE_PATHS"
[[ -n "$SITE_PATHS" ]] || { fail "no site-packages found in $PREFIX"; exit 1; }

echo "==> Prefix     : $PREFIX"
echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> libpython  : $PY_DYLIB"
echo "==> stdlib     : $PY_STDLIB"
echo "==> bundled at : $BUNDLED_LIB"
for d in "${SITE_DIRS[@]}"; do
    echo "==> site-pkgs  : $d"
done

[[ -f "$PY_DYLIB" ]] || { echo "ERROR: Python dylib not found at $PY_DYLIB" >&2; exit 1; }
[[ -f "$PY_STDLIB/os.py" ]] || { echo "ERROR: Python stdlib not found at $PY_STDLIB" >&2; exit 1; }

if [[ $DRY_RUN -ne 0 ]]; then
    echo ""
    echo "DRY RUN: nothing was changed. The bundle step would:"
    echo "  1. rm -rf $APP and run: make pilot BUILD_PATH=$BUILD_PATH"
    echo "  2. macdeployqt \"$APP\""
    echo "  3. copy libpython${PY_VER}.dylib into Contents/Frameworks and the stdlib into Contents/lib"
    echo "  4. copy the prefix's site-packages into $BUNDLED_SITE"
    echo "  5. copy solvcon (without _solvcon*.so) and pre-compile bytecode"
    echo "  6. vendor prefix dependencies into Contents/Frameworks, rewrite load commands and rpaths"
    echo "  7. ad-hoc codesign, 8. create $OUTPUT_DIR/pilot.dmg, 9. verify hermeticity"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Build pilot
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
if [[ $SKIP_BUILD -eq 0 ]]; then
    # macdeployqt cannot redeploy on top of an existing .app: it
    # short-circuits but its later codesign pass still walks paths the
    # (skipped) deploy step would have populated, failing nested signing.
    # `make pilot` only re-links the binary; remove the .app so the
    # build produces a virgin one each run.
    rm -rf "$APP"
    echo "==> make pilot BUILD_PATH=$BUILD_PATH"
    PYBIND11_CMAKE_DIR=$("$PREFIX/bin/python3" -I -B -m pybind11 --cmakedir)
    env -u CMAKE_PREFIX_PATH make -W CMakeLists.txt pilot BUILD_PATH="$BUILD_PATH" \
        CMAKE_ARGS="${CMAKE_ARGS:-} --fresh -DCMAKE_PREFIX_PATH=\"$PREFIX\" -DQt6_DIR=\"$PREFIX/lib/cmake/Qt6\" -DPYTHON_EXECUTABLE=\"$PREFIX/bin/python3\" -Dpybind11_DIR=\"$PYBIND11_CMAKE_DIR\""
elif [[ -d "$FW_DIR" ]]; then
    fail "--skip-build requires an undeployed app; rerun without --skip-build"
    exit 1
fi

[[ -f "$BINARY" ]] || { echo "ERROR: pilot binary not found at $BINARY" >&2; exit 1; }
echo "    [Step 1 (Build pilot): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 2: Deploy Qt
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> macdeployqt (bundles Qt frameworks, plugins, transitive dylibs)"
# The pilot binary carries the prefix's lib/ as an rpath, which is how
# macdeployqt finds Qt. libpython and libpyside6 are not Qt, so macdeployqt may
# warn about them; Step 3 and Step 6 bundle them ourselves.
"$PREFIX/bin/macdeployqt" "$APP" -verbose=1 -libpath="$PREFIX/lib"

# macdeployqt puts the plugins in Contents/PlugIns, but this Qt does not add
# that directory to its search path: it reads no Contents/Resources/qt.conf and
# only looks beside the executable, so pilot aborts with "Could not find the Qt
# platform plugin cocoa". A qt.conf beside the executable would fix it but
# breaks the code signature, because Contents/MacOS is sealed as code. A
# symlink to each plugin directory signs cleanly and is found.
echo "==> Linking Qt plugin directories next to the executable"
for plugin_dir in "$APP"/Contents/PlugIns/*/; do
    [[ -d "$plugin_dir" ]] || continue
    plugin_name=$(basename "$plugin_dir")
    ln -sfn "../PlugIns/$plugin_name" "$APP/Contents/MacOS/$plugin_name"
    echo "    MacOS/$plugin_name -> ../PlugIns/$plugin_name"
done
echo "    [Step 2 (Deploy Qt): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 3: Bundle the Python runtime
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Bundling libpython and the standard library"
mkdir -p "$FW_DIR" "$BUNDLED_LIB"

# pilot already links @rpath/libpython<X.Y>.dylib and carries
# @executable_path/../Frameworks as its first rpath, so the dylib needs no
# rewrite of the main binary.
cp -L "$PY_DYLIB" "$FW_DIR/"
chmod u+w "$FW_DIR/$(basename "$PY_DYLIB")"
echo "    libpython -> $FW_DIR/$(basename "$PY_DYLIB")"

# The standard library, minus what pilot never uses. site-packages is filled
# in Step 4. The CPython test suite and the Tk and IDLE trees are the bulk.
rsync -aL \
    --exclude '__pycache__' --exclude 'site-packages' --exclude 'test' \
    --exclude 'tkinter' --exclude 'idlelib' --exclude 'turtledemo' \
    --exclude 'ensurepip' --exclude 'config-*' \
    "$PY_STDLIB/" "$BUNDLED_LIB/"
mkdir -p "$BUNDLED_SITE"
echo "    stdlib -> $BUNDLED_LIB"
echo "    [Step 3 (Bundle Python runtime): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 4: Bundle site-packages
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Copying Python packages into bundled site-packages"
for SITE in "${SITE_DIRS[@]}"; do
    rsync -aL --exclude '__pycache__' --exclude '*.pth' \
        --exclude 'solvcon' --exclude '_solvcon*.so' \
        "$SITE/" "$BUNDLED_SITE/"
done
# The PySide6 wheel carries every Qt binding plus qml, plugins, translations,
# and deployment scripts. Its Qt frameworks are not in the prefix (the nested
# copies are removed so PySide6 shares the main Qt), so a binding for a module
# pilot does not use could never load. Keep only the bindings pilot imports.
# Override the list with BUNDLE_PYSIDE_MODULES.
prune_pyside6() {
    local pyside="$BUNDLED_SITE/PySide6" f name mod removed=0
    local keep="${BUNDLE_PYSIDE_MODULES:-QtCore,QtGui,QtWidgets,QtSvg}"
    [[ -d "$pyside" ]] || return 0
    for f in "$pyside"/Qt*.abi3.so "$pyside"/Qt*.pyi; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f")
        mod=${name%%.*}
        case ",$keep," in
            *",$mod,"*) ;;
            *) rm -f "$f"; removed=$((removed + 1)) ;;
        esac
    done
    rm -rf "$pyside/Qt" "$pyside/scripts" "$pyside/include" \
        "$pyside/typesystems" "$pyside/glue" "$pyside/examples"
    rm -f "$pyside"/libpyside6qml*.dylib
    echo "    PySide6: kept $keep, removed $removed other binding file(s)"
}
prune_pyside6
echo "    [Step 4 (Bundle site-packages): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 5: Bundle solvcon
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Copying solvcon package into bundled site-packages"
# Copy the solvcon Python package. Skip _solvcon*.so because the binary code is
# statically linked into pilot via PYBIND11_EMBEDDED_MODULE.
rsync -a --exclude '__pycache__' --exclude '_solvcon*.so' \
    "$BUNDLE_REPO_ROOT/solvcon" "$BUNDLED_SITE/"
echo "    solvcon -> $BUNDLED_SITE/solvcon"
echo "    [Step 5 (Bundle solvcon): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 5.5: Pre-compile bundled bytecode
#
# Ship .pyc alongside .py so the embedded interpreter finds a valid cache on
# import and never writes back into the signed bundle (a runtime write would
# mutate the sealed contents and break the code signature). The prefix's
# python3 has the same version as the embedded one, so the .pyc magic matches.
# unchecked-hash makes the cache trusted unconditionally, sidestepping mtime
# drift from rsync/DMG creation that would otherwise let the default timestamp
# mode falsely invalidate the cache at runtime.
#
# `|| true` keeps a stray uncompilable file in a package's own tests/ from
# killing the build; those files are not imported at runtime. The trailing
# sanity check fails loudly if compileall produced nothing at all.
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Pre-compiling bundled Python modules"
"$PREFIX/bin/python3" -I -B -m compileall -f \
    --invalidation-mode unchecked-hash -q \
    "$BUNDLED_LIB" || true
PYC_COUNT=$(find "$BUNDLED_LIB" -name '*.pyc' | wc -l | tr -d ' ')
[[ $PYC_COUNT -gt 0 ]] || \
    { echo "ERROR: compileall produced no .pyc files under $BUNDLED_LIB" >&2; exit 1; }
echo "    compiled $PYC_COUNT .pyc files"
echo "    [Step 5.5 (Pre-compile bytecode): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 6: Vendor the prefix's dependencies
#
# macdeployqt only follows Qt's load commands, so everything else (libpyside6,
# libshiboken6, Python extension modules and what they link) still resolves
# through the prefix at runtime. Walk every Mach-O in the bundle, copy missing
# prefix dylibs/frameworks into Contents/Frameworks/, rewrite absolute load
# commands to the bundled copy, and replace non-system LC_RPATH entries with
# @executable_path/../Frameworks.
# ---------------------------------------------------------------------------

# Copy one dylib named $1 into Contents/Frameworks/ from the first of the
# remaining arguments that exists. Returns 1 if none exists.
vendor_dylib() {
    local base="$1" cand
    shift
    for cand in "$@"; do
        if [[ -f "$cand" ]]; then
            cp -L "$cand" "$FW_DIR/$base" 2>/dev/null || return 1
            chmod u+w "$FW_DIR/$base"
            echo "$base" >> "$SEEN_DYLIB"
            echo "$FW_DIR/$base" >> "$QUEUE"
            return 0
        fi
    done
    return 1
}

# Copy the framework $1 into Contents/Frameworks/ from the directory $2.
vendor_framework() {
    local fw="$1" src="$2"
    [[ -d "$src" ]] || return 1
    mkdir -p "$FW_DIR/$fw.framework"
    rsync -a --copy-unsafe-links "$src/" "$FW_DIR/$fw.framework/" 2>/dev/null || return 1
    chmod -R u+w "$FW_DIR/$fw.framework"
    echo "$fw" >> "$SEEN_FW"
    list_macho "$FW_DIR/$fw.framework" | xargs -0 -n1 echo >> "$QUEUE"
}

warn_missing() {
    if ! grep -qxF "$1" "$SEEN_MISSING"; then
        echo "$1" >> "$SEEN_MISSING"
        echo "    ERROR: could not resolve $1" >&2
    fi
}

# BFS-walk every Mach-O in the bundle: pop one, copy any missing prefix
# dependency into Contents/Frameworks/, enqueue what we just copied. Touching
# each file once keeps cost linear in bundle size. Sets the global SEEN_DYLIB /
# SEEN_FW indexes consumed by rewrite_load_commands below.
vendor_prefix_deps() {
    CLOSURE_TMP=$(mktemp -d)
    QUEUE="$CLOSURE_TMP/queue"
    SEEN_BIN="$CLOSURE_TMP/seen_bin"
    SEEN_DYLIB="$CLOSURE_TMP/seen_dylib"
    SEEN_FW="$CLOSURE_TMP/seen_fw"
    SEEN_MISSING="$CLOSURE_TMP/seen_missing"
    touch "$QUEUE" "$SEEN_BIN" "$SEEN_DYLIB" "$SEEN_FW" "$SEEN_MISSING"

    # Skip what's already in Contents/Frameworks/.
    local f
    for f in "$FW_DIR"/*.dylib; do
        [[ -f "$f" ]] && basename "$f" >> "$SEEN_DYLIB"
    done
    for f in "$FW_DIR"/*.framework; do
        [[ -d "$f" ]] && basename "$f" .framework >> "$SEEN_FW"
    done

    list_macho "$APP" | xargs -0 -n1 echo >> "$QUEUE"

    local BIN OLD fw base name loads id resolved
    while [[ -s "$QUEUE" ]]; do
        BIN=$(head -n 1 "$QUEUE")
        sed -i '' '1d' "$QUEUE"
        grep -qxF "$BIN" "$SEEN_BIN" && continue
        echo "$BIN" >> "$SEEN_BIN"
        loads=$(binary_loads "$BIN")
        id=$(otool -D "$BIN" | awk 'NR > 1 && NF && !seen { print; seen = 1 }')
        while IFS= read -r OLD; do
            [[ -z "$OLD" || "$OLD" == "$id" ]] && continue
            case "$OLD" in
            */*.framework/Versions/*/*)
                # An absolute prefix path, or an @rpath reference.
                if [[ "$OLD" == @rpath/* ]]; then
                    name=${OLD#@rpath/}
                    fw=${name%%.framework*}
                    grep -qxF "$fw" "$SEEN_FW" && continue
                    vendor_framework "$fw" "$PREFIX/lib/$fw.framework" || warn_missing "$OLD"
                elif [[ "$OLD" =~ $PREFIX_PATH_RE ]]; then
                    fw=${OLD##*/}
                    grep -qxF "$fw" "$SEEN_FW" && continue
                    vendor_framework "$fw" "${OLD%%/Versions/*}" || warn_missing "$OLD"
                fi
                ;;
            @rpath/lib*.dylib|@loader_path/lib*.dylib)
                # Sibling references such as @rpath/libpyside6.abi3.6.11.dylib.
                base=${OLD##*/}
                if [[ "$OLD" == @rpath/* ]] && resolved=$(resolve_rpath "$BIN" "$OLD"); then
                    if [[ "$resolved" == "$APP/Contents/"* ]]; then
                        continue
                    fi
                    grep -qxF "$base" "$SEEN_DYLIB" && continue
                    vendor_dylib "$base" "$resolved" || warn_missing "$OLD"
                    continue
                fi
                grep -qxF "$base" "$SEEN_DYLIB" && continue
                # A sibling of the loader (for example Pillow's .dylibs/) is
                # already in place and needs no vendoring.
                [[ "$OLD" == @loader_path/* && -f "$(dirname "$BIN")/$base" ]] && continue
                vendor_dylib "$base" \
                    "$PREFIX/lib/$base" \
                    "$PREFIX/lib/python${PY_VER}/site-packages/PySide6/$base" \
                    "$PREFIX/lib/python${PY_VER}/site-packages/shiboken6/$base" \
                    || warn_missing "$OLD"
                ;;
            @loader_path/*)
                [[ -f "$(dirname "$BIN")/${OLD#@loader_path/}" ]] || warn_missing "$OLD"
                ;;
            /*)
                if [[ "$OLD" =~ $PREFIX_PATH_RE ]]; then
                    [[ -f "$APP/Contents/${OLD#"$PREFIX/"}" ]] && continue
                    base=${OLD##*/}
                    grep -qxF "$base" "$SEEN_DYLIB" && continue
                    vendor_dylib "$base" "$OLD" || warn_missing "$OLD"
                fi
                ;;
            esac
        done <<< "$loads"
    done

    [[ ! -s "$SEEN_MISSING" ]] || { fail "unresolved native dependencies; bundle aborted"; return 1; }

    echo "    bundled $(wc -l < "$SEEN_DYLIB" | tr -d ' ') dylibs and \
$(wc -l < "$SEEN_FW" | tr -d ' ') frameworks"
}

# Rewrite every absolute prefix reference whose target is now bundled (load
# commands and LC_ID_DYLIB). @rpath references are left alone: they resolve
# through the @executable_path/../Frameworks rpath that strip_prefix_rpaths
# installs. Reads SEEN_DYLIB / SEEN_FW populated by vendor_prefix_deps.
rewrite_load_commands() {
    # Surrounding spaces let bash do containment with the *" $tok "* glob.
    local INDEX FW_INDEX
    INDEX=" $(tr '\n' ' ' < "$SEEN_DYLIB")"
    FW_INDEX=" $(tr '\n' ' ' < "$SEEN_FW")"

    local BIN OLD fw ver base NEW loads id
    while IFS= read -r -d '' BIN; do
        loads=$(binary_loads "$BIN")
        id=$(otool -D "$BIN" | awk 'NR > 1 && NF && !seen { print; seen = 1 }')
        while IFS= read -r OLD; do
            [[ "$OLD" != "$id" && "$OLD" =~ $PREFIX_PATH_RE ]] || continue
            if [[ -f "$APP/Contents/${OLD#"$PREFIX/"}" ]]; then
                NEW="@executable_path/../${OLD#"$PREFIX/"}"
                install_name_tool -change "$OLD" "$NEW" "$BIN"
                continue
            fi
            case "$OLD" in
            */*.framework/Versions/*/*)
                fw=${OLD##*/}
                if [[ "$FW_INDEX" == *" $fw "* ]]; then
                    # Preserve the original version segment.
                    ver=${OLD#*.framework/Versions/}; ver=${ver%%/*}
                    NEW="@executable_path/../Frameworks/${fw}.framework/Versions/${ver}/${fw}"
                    install_name_tool -change "$OLD" "$NEW" "$BIN"
                fi
                ;;
            /*)
                base=${OLD##*/}
                if [[ "$INDEX" == *" $base "* ]]; then
                    NEW="@executable_path/../Frameworks/$base"
                    install_name_tool -change "$OLD" "$NEW" "$BIN"
                fi
                ;;
            esac
        done <<< "$loads"
        if [[ "$id" == /* ]]; then
            install_name_tool -id "@executable_path/../${BIN#"$APP/Contents/"}" "$BIN"
        fi
    done < <(list_macho "$APP")
}

# LC_RPATH is invisible to otool -L so the rewrite above missed it. A surviving
# source rpath silently falls back at runtime on the build machine and fails
# everywhere else. For each affected Mach-O: add @executable_path/../Frameworks
# (so bundled siblings stay reachable via @rpath/), then delete every host
# entry one at a time (install_name_tool removes one per call).
strip_prefix_rpaths() {
    local EP_RPATH='@executable_path/../Frameworks'
    local BIN host_rps rp rpaths loads directory resolved
    while IFS= read -r -d '' BIN; do
        rpaths=$(binary_rpaths "$BIN")
        host_rps=$(printf '%s\n' "$rpaths" | external_references)
        while IFS= read -r rp; do
            case "$rp" in
                @loader_path/*) directory="$(dirname "$BIN")/${rp#@loader_path/}" ;;
                @executable_path/*) directory="$(dirname "$BINARY")/${rp#@executable_path/}" ;;
                *) continue ;;
            esac
            resolved=$("$PREFIX/bin/python3" -I -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$directory")
            case "$resolved" in
                "$APP/Contents"|"$APP/Contents/"*) ;;
                *) host_rps="${host_rps}${host_rps:+$'\n'}$rp" ;;
            esac
        done <<< "$rpaths"
        loads=$(binary_loads "$BIN")
        if [[ -z "$host_rps" && "$BIN" != "$BINARY" ]] && ! grep -q '^@rpath/' <<< "$loads"; then
            continue
        fi
        if ! grep -qxF "$EP_RPATH" <<< "$rpaths"; then
            if [[ -n "$host_rps" ]]; then
                rp=${host_rps%%$'\n'*}
                install_name_tool -rpath "$rp" "$EP_RPATH" "$BIN"
                host_rps=${host_rps#"$rp"}
                host_rps=${host_rps#$'\n'}
            else
                install_name_tool -add_rpath "$EP_RPATH" "$BIN"
            fi
        fi
        while IFS= read -r rp; do
            [[ -z "$rp" ]] && continue
            install_name_tool -delete_rpath "$rp" "$BIN"
        done <<< "$host_rps"
    done < <(list_macho "$APP")
}

# A PySide6 wheel ships a private copy of Qt under PySide6/Qt/lib. Its .abi3.so
# modules load that copy via @rpath; pilot's C++ binary loads Qt from
# Contents/Frameworks/. Two Qt instances in one process => duplicate Obj-C
# classes, separate global state, "QWidget: Must construct a QApplication"
# abort. A prefix that already removed the nested frameworks (the same fix the
# CI applies on macOS) has nothing to do here. Otherwise replace each
# duplicated nested framework with a relative symlink to the main bundle copy.
# Frameworks unique to PySide6 (QtCharts, ...) are left in place; their
# @rpath/QtCore... refs resolve through these symlinks too.
dedupe_pyside_qt() {
    local pyqt_lib count=0 nested name main rel
    pyqt_lib="$BUNDLED_SITE/PySide6/Qt/lib"
    [[ -d "$pyqt_lib" ]] || return 0
    # The link lives in PySide6/Qt/lib/; six levels up reach Contents/:
    # Qt, PySide6, site-packages, python<X.Y>, lib, Contents.
    rel='../../../../../..'
    for nested in "$pyqt_lib"/Qt*.framework; do
        [[ -d "$nested" && ! -L "$nested" ]] || continue
        name=$(basename "$nested" .framework)
        main="$FW_DIR/${name}.framework"
        [[ -d "$main" && ! -L "$main" ]] || continue
        rm -rf "$nested"
        ln -s "$rel/Frameworks/${name}.framework" "$nested"
        count=$((count+1))
    done
    if [[ $count -gt 0 ]]; then
        echo "    deduped $count PySide6/Qt/lib framework(s) into main Qt"
    else
        echo "    no duplicated Qt framework under PySide6/Qt/lib"
    fi
}

# Set PYTHONNOUSERSITE=1 in LSEnvironment so a Finder/open launch of pilot
# never adds ~/Library/Python/<X.Y>/lib/python/site-packages to sys.path,
# which on dev machines may carry a second PySide6 (and its Qt). Same
# dual-instance crash as dedupe_pyside_qt fixes for the in-bundle case.
inject_pythonnousersite() {
    local plist="$APP/Contents/Info.plist"
    [[ -f "$plist" ]] || { fail "no Info.plist at $plist"; return 1; }
    # macdeployqt's Step 2 codesign locks Info.plist read-only; Step 7
    # re-locks it.
    chmod u+w "$plist"
    if /usr/libexec/PlistBuddy -c "Print :LSEnvironment:PYTHONNOUSERSITE" \
            "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c \
            "Set :LSEnvironment:PYTHONNOUSERSITE 1" "$plist" || {
            echo "    ERROR: failed to set LSEnvironment.PYTHONNOUSERSITE" >&2
            return 1
        }
    else
        # Dict may already exist; tolerate either way.
        /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" \
            2>/dev/null || true
        /usr/libexec/PlistBuddy -c \
            "Add :LSEnvironment:PYTHONNOUSERSITE string 1" "$plist" || {
            echo "    ERROR: failed to add LSEnvironment.PYTHONNOUSERSITE" >&2
            return 1
        }
    fi
    echo "    Info.plist LSEnvironment.PYTHONNOUSERSITE = 1"
}

T_STEP=$SECONDS
echo "==> Vendoring prefix dependencies"
vendor_prefix_deps
echo "==> Redirecting absolute prefix load commands to bundled copies"
rewrite_load_commands
echo "==> Replacing host rpaths with @executable_path/../Frameworks"
strip_prefix_rpaths
echo "==> Deduplicating PySide6's bundled Qt against the main bundle Qt"
dedupe_pyside_qt
echo "==> Setting PYTHONNOUSERSITE=1 in Info.plist"
inject_pythonnousersite
check_self_contained "$APP"
echo "    [Step 6 (Vendor prefix deps): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 7: Ad-hoc codesign
#
# Sign bottom-up. `codesign --deep` would skip files we added after the
# original signing so each nested artifact must be sealed first, in dependency
# order: dylibs/.so, then nested helper .apps, then frameworks, then the main
# binary and main .app.
# ---------------------------------------------------------------------------

# Sign every standalone dylib and .so under Contents/.
sign_inner_machos() {
    local BIN
    while IFS= read -r -d '' BIN; do
        codesign --force --sign - "$BIN"
    done < <(find "$APP/Contents" \( -name '*.dylib' -o -name '*.so' \) -print0)
}

# Sign nested helper apps (e.g. QtWebEngineCore's QtWebEngineProcess.app)
# before sealing their containing framework.  Reverse-sort by path
# length so the deepest .app signs first.
sign_helper_apps() {
    local INNER_APP
    find "$APP" -name '*.app' -type d -print | awk '{print length($0), $0}' | \
        sort -k1,1nr | cut -d' ' -f2- | while IFS= read -r INNER_APP; do
        [[ "$INNER_APP" == "$APP" ]] && continue
        rm -rf "$INNER_APP/Contents/_CodeSignature"
        codesign --force --sign - "$INNER_APP"
    done
}

# Re-seal each nested framework (Qt*.framework, ...).
# On macOS the framework version directory carries the signature.
sign_frameworks() {
    local FW VER
    for FW in "$FW_DIR"/*.framework; do
        [[ -d "$FW" ]] || continue
        for VER in "$FW"/Versions/*; do
            [[ -d "$VER" && ! -L "$VER" ]] || continue
            rm -rf "$VER/_CodeSignature"
            codesign --force --sign - "$VER"
        done
    done
}

# Sign the main binary, then the outer .app.
sign_main_app() {
    codesign --force --sign - "$BINARY"
    codesign --force --sign - "$APP"
}

T_STEP=$SECONDS
echo "==> Ad-hoc re-signing all bundled Mach-O files"
sign_inner_machos
sign_helper_apps
sign_frameworks
echo "==> Ad-hoc re-signing the app bundle"
sign_main_app
codesign --verify --deep --strict "$APP"
echo "    [Step 7 (Ad-hoc codesign): $((SECONDS - T_STEP))s]"

echo ""
echo "Bundle complete: $APP"

# ---------------------------------------------------------------------------
# Step 8: Package DMG
# ---------------------------------------------------------------------------

# Run a command and give up after $1 seconds. macOS has no timeout(1).
# Returns 124 on timeout, otherwise the command's own status.
run_with_timeout() {
    local secs="$1" pid elapsed=0 rc=0
    shift
    # A background job reads /dev/null unless told otherwise; <&0 keeps the
    # caller's stdin, which carries the AppleScript heredoc.
    "$@" <&0 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $elapsed -ge $secs ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pid" || rc=$?
    return $rc
}

# Lay the volume out as an installer: the app on the left and a shortcut to
# /Applications on the right, so the user drags from left to right. Finder
# stores the icon positions in the volume's .DS_Store, so the image has to be
# mounted writable and Finder driven through AppleScript. That needs the
# Automation permission for the terminal and a desktop session, so it is best
# effort: on failure the DMG still carries the Applications shortcut and only
# the placement is left to Finder. BUNDLE_DMG_LAYOUT=0 skips it.
layout_dmg_window() {
    local volname="$1" app_name="$2" mnt="$3"
    run_with_timeout 90 osascript - "$volname" "$app_name" <<'APPLESCRIPT'
on run argv
    set volName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk volName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 800, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 104
            set position of item appName of container window to {160, 190}
            set position of item "Applications" of container window to {440, 190}
            close
            open
            update without registering applications
            delay 2
        end tell
    end tell
end run
APPLESCRIPT
}

# Package $1 (.app) as the compressed image $2. The image carries the app and
# a symlink named Applications that points at /Applications.
create_dmg() {
    local app="$1" dmg="$2" volname="${BUNDLE_DMG_VOLNAME:-solvcon Pilot}"
    local app_name size_mb rc=0
    app_name=$(basename "$app")

    DMG_STAGE=$(mktemp -d -t solvcon-dmg-stage)
    # ditto keeps the symlinks, modes and xattrs the code signature seals.
    ditto "$app" "$DMG_STAGE/$app_name"
    ln -s /Applications "$DMG_STAGE/Applications"

    # Leave room for the .DS_Store that Finder writes into the volume.
    size_mb=$(( $(du -sm "$DMG_STAGE" | cut -f1) + 64 ))
    DMG_RW="$(mktemp -u -t solvcon-dmg-rw).dmg"
    hdiutil create -volname "$volname" -srcfolder "$DMG_STAGE" \
        -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$DMG_RW" >/dev/null

    if [[ "${BUNDLE_DMG_LAYOUT:-1}" != "0" ]]; then
        LAYOUT_MNT="/Volumes/$volname"
        if [[ -e "$LAYOUT_MNT" ]]; then
            echo "    WARN: $LAYOUT_MNT is already mounted; eject it to place the icons" >&2
            LAYOUT_MNT=""
        else
            hdiutil attach -readwrite -noverify -noautoopen \
                -mountpoint "$LAYOUT_MNT" "$DMG_RW" >/dev/null
            # Finder does not know a volume the instant it mounts; scripting
            # it before then is accepted and silently does nothing.
            sleep 3
            layout_dmg_window "$volname" "$app_name" "$LAYOUT_MNT" >/dev/null 2>&1 || rc=$?
            local waited=0
            while [[ ! -f "$LAYOUT_MNT/.DS_Store" && $waited -lt 10 ]]; do
                sleep 1
                waited=$((waited + 1))
            done
            if [[ $rc -eq 0 && -f "$LAYOUT_MNT/.DS_Store" ]]; then
                echo "    icon layout: $app_name on the left, Applications on the right"
            else
                echo "    WARN: could not place the icons (osascript status $rc);" \
                     "the DMG still has the Applications shortcut" >&2
            fi
            sync
            hdiutil detach -quiet "$LAYOUT_MNT" >/dev/null 2>&1 \
                || { sleep 2; hdiutil detach -force -quiet "$LAYOUT_MNT" >/dev/null; }
            LAYOUT_MNT=""
        fi
    fi

    hdiutil convert "$DMG_RW" -format UDZO -ov -o "$dmg" >/dev/null
    rm -f "$DMG_RW"
    DMG_RW=""
    rm -rf "$DMG_STAGE"
    DMG_STAGE=""
}

T_STEP=$SECONDS
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/pilot.dmg"
echo "==> Creating $DMG from $APP (with an Applications shortcut)"
create_dmg "$APP" "$DMG"
SIZE=$(du -sh "$DMG" | cut -f1)
echo "    [Step 8 (Package DMG): $((SECONDS - T_STEP))s]"

echo ""
echo "DMG complete: $DMG ($SIZE)"

# ---------------------------------------------------------------------------
# Step 9: Verify hermeticity
#
# Use the same signature, isolated import/render, and smoke checks as the
# standalone verify command. The writable copy catches bytecode mutations.
# ---------------------------------------------------------------------------
if [[ $SKIP_CHECK -eq 0 ]]; then
    T_STEP=$SECONDS
    verify_dmg "$DMG"
    echo "    [Step 9 (Verify hermeticity): $((SECONDS - T_STEP))s]"
fi

echo ""
echo "Total elapsed: $((SECONDS - T_SCRIPT))s"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
