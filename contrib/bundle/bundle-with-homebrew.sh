#!/bin/bash
#
# This script is a prototype to create a self-contained macOS .app bundle for
# solvcon, package it into a DMG file, and verify both are hermetic. It employs
# macdeployqt, otool, and install_name_tool to process the binaries, and ad-hoc
# codesign to reseal them.
#
# !! WARNING !!
# The script is only tested in a standalone VM environment, and assumes the
# dependency prefix may be prepared with Homebrew. Be very careful when running
# it in a development or production machine.
#
# Usage:
#   ./contrib/bundle/bundle-with-homebrew.sh check --dependency-prefix DIR \
#       --runtime-python-env DIR --build-python-env DIR
#   ./contrib/bundle/bundle-with-homebrew.sh bundle [--skip-build]
#                                                   [--skip-check]
#                                                   --dependency-prefix DIR
#                                                   --runtime-python-env DIR
#                                                   --build-python-env DIR
#                                                   [--output DIR]
#   ./contrib/bundle/bundle-with-homebrew.sh verify path/to/pilot.dmg
#
# Legacy usage without a subcommand still runs the bundle step:
#   ./contrib/bundle/bundle-with-homebrew.sh --dependency-prefix DIR
#                                            --runtime-python-env DIR
#                                            --build-python-env DIR
#                                            [--skip-build] [--skip-check]
#                                            [--output DIR]
#
#   --skip-build   Skip `make pilot` and use the existing build output.
#   --skip-check   Skip the bundle/DMG verification phase.
#   --dependency-prefix DIR
#                  Copy native dependencies from DIR.
#   --runtime-python-env DIR
#                  Copy pip runtime packages from DIR.
#   --build-python-env DIR
#                  Load pybind11 build metadata from DIR.
#   --output DIR   Write pilot.dmg into DIR (default: build/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$BUNDLE_REPO_ROOT"

MIN_LOADS=${MIN_LOADS:-50}
MACOS_ARCHITECTURES=arm64
MACOS_DEPLOYMENT_TARGET=26.0
# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
  contrib/bundle/bundle-with-homebrew.sh check --dependency-prefix DIR --runtime-python-env DIR --build-python-env DIR
  contrib/bundle/bundle-with-homebrew.sh bundle --dependency-prefix DIR --runtime-python-env DIR --build-python-env DIR [--skip-build] [--skip-check] [--output DIR]
  contrib/bundle/bundle-with-homebrew.sh verify path/to/pilot.dmg
  contrib/bundle/bundle-with-homebrew.sh all --dependency-prefix DIR --runtime-python-env DIR --build-python-env DIR [--skip-build] [--skip-check] [--output DIR]

Subcommands:
  check    Check macOS bundle release dependencies. Does not build or install.
  bundle   Build/package pilot.app and pilot.dmg with native dependencies.
  verify   Verify a generated release DMG artifact.
  all      Run check and then bundle.
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

For a fresh macOS bundling environment, try:
  bash contrib/vm/macos/mac26_vmsetup.sh homebrew
  bash contrib/vm/macos/mac26_vmsetup.sh dependency
  make bundle-deps RELEASE_DEPENDENCY_PREFIX="$(brew --prefix)"
EOF
}

require_command() {
    local cmd="$1" hint="${2:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd: $(command -v "$cmd")"
    else
        fail "$cmd: not found${hint:+ ($hint)}"
    fi
}

python_module_check() {
    local module="$1" hint="${2:-}" expected="${3:-}" out
    out=$(mktemp -t solvcon-bundle-pycheck)
    if PYTHONPATH="$RUNTIME_SITE" PYTHONNOUSERSITE=1 \
        "$PYTHON" -s - "$module" "$expected" <<'PY' >"$out" 2>&1
import importlib
import os
import sys
module = sys.argv[1]
expected = sys.argv[2]
try:
    mod = importlib.import_module(module)
except Exception as e:
    print(f"{type(e).__name__}: {e}")
    raise SystemExit(1)
else:
    path = os.path.realpath(getattr(mod, "__file__", ""))
    if expected and os.path.commonpath((path, expected)) != expected:
        print(f"{module} is outside {expected}: {path}")
        raise SystemExit(1)
    print(path or "built-in")
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

python_framework_check() {
    "$PYTHON" -s <<'PY'
import os
import sys
import sysconfig

fw = sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX")
if not fw:
    raise SystemExit("PYTHONFRAMEWORKPREFIX is empty; Homebrew framework Python is required")
ver = f"{sys.version_info[0]}.{sys.version_info[1]}"
path = os.path.join(fw, "Python.framework", "Versions", ver, "Python")
if not os.path.isfile(path):
    raise SystemExit(f"Python dylib not found: {path}")
print(path)
PY
}

check_pybind11_cmake() {
    local config_dir
    if [[ -x "$BUILD_PYTHON" ]]; then
        config_dir=$("$BUILD_PYTHON" -m pybind11 --cmakedir \
            2>/dev/null || true)
        if [[ -n "$config_dir" && -f "$config_dir/pybind11Config.cmake" ]]; then
            ok "pybind11 CMake config: $config_dir/pybind11Config.cmake"
            return 0
        fi
    fi
    fail "pybind11 CMake config: not found in $BUILD_PYTHON_ENV"
}

check_deps() {
    local fw_path base_abi runtime_abi build_abi failed=0
    require_macos

    if [[ "$(uname -m)" == "$MACOS_ARCHITECTURES" ]]; then
        ok "macOS architecture: $MACOS_ARCHITECTURES"
    else
        fail "macOS architecture: $(uname -m) (expected $MACOS_ARCHITECTURES)" || failed=1
    fi

    ok "Native dependency prefix: $DEPENDENCY_PREFIX"

    for cmd in cmake file make otool \
        install_name_tool codesign hdiutil lipo rsync shasum; do
        require_command "$cmd" || failed=1
    done

    [[ -x "$PYTHON" ]] && ok "python3: $PYTHON" || \
        { fail "python3: not found at $PYTHON" || true; failed=1; }
    [[ -x "$MACDEPLOYQT" ]] && ok "macdeployqt: $MACDEPLOYQT" || \
        { fail "macdeployqt: not found at $MACDEPLOYQT" || true; failed=1; }
    [[ -x "$QTPATHS" ]] && ok "qtpaths: $QTPATHS" || \
        { fail "qtpaths: not found at $QTPATHS" || true; failed=1; }

    base_abi=$("$PYTHON" -c \
        'import platform, sys; print("%d.%d-%s" % (*sys.version_info[:2], platform.machine()))')
    runtime_abi=$("$RUNTIME_PYTHON" -c \
        'import platform, sys; print("%d.%d-%s" % (*sys.version_info[:2], platform.machine()))')
    build_abi=$("$BUILD_PYTHON" -c \
        'import platform, sys; print("%d.%d-%s" % (*sys.version_info[:2], platform.machine()))')
    if [[ "$base_abi" == "$runtime_abi" && "$base_abi" == "$build_abi" ]]; then
        ok "Python ABI: $base_abi"
    else
        fail "Python ABI mismatch: base=$base_abi runtime=$runtime_abi build=$build_abi" || failed=1
    fi

    if fw_path=$(python_framework_check 2>&1); then
        case "$fw_path" in
        "$DEPENDENCY_PREFIX"/*) ok "Python framework dylib: $fw_path" ;;
        *) fail "Python framework is outside $DEPENDENCY_PREFIX: $fw_path" || failed=1 ;;
        esac
    else
        fail "$fw_path" || failed=1
    fi

    check_pybind11_cmake || failed=1
    python_module_check numpy "make bundle-deps" "$RUNTIME_SITE" || failed=1
    python_module_check PySide6 "brew install pyside" \
        "$DEPENDENCY_PREFIX" || failed=1
    python_module_check shiboken6 "brew install pyside" \
        "$DEPENDENCY_PREFIX" || failed=1
    python_module_check shiboken6_generator "brew install pyside" \
        "$DEPENDENCY_PREFIX" || failed=1
    python_module_check matplotlib.pyplot \
        "make bundle-deps" "$RUNTIME_SITE" || failed=1
    python_module_check PIL "make bundle-deps" "$RUNTIME_SITE" || failed=1
    python_module_check jsonschema "make bundle-deps" \
        "$RUNTIME_SITE" || failed=1
    python_module_check lz4.frame "make bundle-deps" \
        "$RUNTIME_SITE" || failed=1
    python_module_check zstandard "make bundle-deps" \
        "$RUNTIME_SITE" || failed=1

    if [[ $failed -ne 0 ]]; then
        setup_hint
        exit 1
    fi
}

# Active Python's "X.Y" version string.
bundle_pyver() {
    "$PYTHON" -s -c "import sys; print('%d.%d' % sys.version_info[:2])"
}

# Print every Mach-O regular file under $1, NUL-delimited. Native helpers do
# not consistently use a filename suffix or executable mode.
list_macho() {
    local f
    while IFS= read -r -d '' f; do
        if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then
            printf '%s\0' "$f"
        fi
    done < <(find "$1" -type f -print0)
}

# Print every LC_RPATH entry of the Mach-O at $1, one per line.  `otool -L`
# does not list these, so we parse `otool -l`.  The entry `otool -l` output
# looks like:
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
        c && $1 == "path"   { print $2; c = 0 }
    '
}

# Print the executable directory governing @executable_path for a Mach-O. The
# nearest containing .app wins, which also handles nested helper applications.
executable_dir_for_macho() {
    local bin="$1" dir executable
    dir=${bin%/*}
    while [[ "$dir" == "$APP"/* || "$dir" == "$APP" ]]; do
        if [[ "$dir" == *.app && -d "$dir/Contents/MacOS" ]]; then
            executable=$(find "$dir/Contents/MacOS" -type f -print -quit)
            [[ -n "$executable" ]] && dirname "$executable" && return 0
        fi
        [[ "$dir" == "$APP" ]] && break
        dir=${dir%/*}
    done
    dirname "$BINARY"
}

expand_macho_path() {
    local bin="$1" value="$2" root
    case "$value" in
    @loader_path) printf '%s\n' "${bin%/*}" ;;
    @loader_path/*) printf '%s/%s\n' "${bin%/*}" "${value#@loader_path/}" ;;
    @executable_path) executable_dir_for_macho "$bin" ;;
    @executable_path/*)
        root=$(executable_dir_for_macho "$bin")
        printf '%s/%s\n' "$root" "${value#@executable_path/}"
        ;;
    /*) printf '%s\n' "$value" ;;
    *) return 1 ;;
    esac
}

# Resolve a tokenized load command against the bundle or dependency prefix.
resolve_macho_load() {
    local bin="$1" load="$2" allow_prefix="${3:-0}"
    local rp root candidate suffix matches count source_bin
    case "$load" in
    @loader_path/*|@executable_path/*)
        candidate=$(expand_macho_path "$bin" "$load")
        if [[ -f "$candidate" ]]; then
            printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" \
                "$(basename "$candidate")"
            return 0
        fi
        if [[ "$load" == @loader_path/* && -n "${SOURCE_MAP:-}" ]]; then
            source_bin=$(awk -F '\t' -v bin="$bin" '$1 == bin { print $2; exit }' \
                "$SOURCE_MAP")
            if [[ -n "$source_bin" ]]; then
                candidate="${source_bin%/*}/${load#@loader_path/}"
                [[ -f "$candidate" ]] && printf '%s\n' "$candidate" && return 0
            fi
        fi
        ;;
    @rpath/*)
        suffix=${load#@rpath/}
        while IFS= read -r rp; do
            root=$(expand_macho_path "$bin" "$rp" || true)
            [[ -n "$root" ]] || continue
            candidate="$root/$suffix"
            if [[ -f "$candidate" ]]; then
                printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)" \
                    "$(basename "$candidate")"
                return 0
            fi
        done < <(binary_rpaths "$bin")

        matches=$(find "$APP" -type f -path "*/$suffix" -print 2>/dev/null | \
            while IFS= read -r candidate; do
                printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
            done | sort -u)
        count=$(printf '%s\n' "$matches" | grep -c . || true)
        [[ $count -eq 1 ]] && printf '%s\n' "$matches" && return 0

        if [[ "$allow_prefix" -eq 1 && -n "${DEPENDENCY_PREFIX:-}" ]]; then
            matches=$(find "$DEPENDENCY_PREFIX" \( -type f -o -type l \) \
                -path "*/$suffix" -print 2>/dev/null | while IFS= read -r candidate; do
                    [[ -f "$candidate" ]] || continue
                    printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
                done | sort -u)
            count=$(printf '%s\n' "$matches" | grep -c . || true)
            [[ $count -eq 1 ]] && printf '%s\n' "$matches" && return 0
        fi
        ;;
    /*)
        if [[ -f "$load" ]]; then
            printf '%s/%s\n' "$(cd "$(dirname "$load")" && pwd -P)" \
                "$(basename "$load")"
            return 0
        fi
        ;;
    esac
    return 1
}

# Verify the .app under $1 contains no external load command, install name, or
# rpath. Tokenized paths must resolve inside the app. Print offenders.
check_self_contained() {
    local total=0 bad=0 f load_refs install_id rpath_refs token_refs
    local token_rpath_refs load resolved rp expanded
    while IFS= read -r -d '' f; do
        total=$((total+1))
        load_refs=$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' \
            | grep -E '^/' | grep -Ev '^(/System/Library/|/usr/lib/)' || true)
        install_id=$(otool -D "$f" 2>/dev/null | tail -n +2 \
            | grep -E '^/' | grep -Ev '^(/System/Library/|/usr/lib/)' || true)
        rpath_refs=$(binary_rpaths "$f" | grep -E '^/' \
            | grep -Ev '^(/System/Library/|/usr/lib/)' || true)
        token_rpath_refs=""
        while IFS= read -r rp; do
            case "$rp" in @loader_path*|@executable_path*) ;; *) continue ;; esac
            expanded=$(expand_macho_path "$f" "$rp" || true)
            if [[ -d "$expanded" ]]; then
                expanded=$(cd "$expanded" && pwd -P)
            else
                token_rpath_refs="${token_rpath_refs}${token_rpath_refs:+$'\n'}$rp"
                continue
            fi
            case "$expanded" in
            "$APP"/*) ;;
            *) token_rpath_refs="${token_rpath_refs}${token_rpath_refs:+$'\n'}$rp" ;;
            esac
        done < <(binary_rpaths "$f")
        token_refs=""
        while IFS= read -r load; do
            [[ -n "$load" ]] || continue
            resolved=$(resolve_macho_load "$f" "$load" || true)
            case "$resolved" in
            "$APP"/*|/System/Library/*|/usr/lib/*) ;;
            *) token_refs="${token_refs}${token_refs:+$'\n'}$load" ;;
            esac
        done < <(otool -L "$f" 2>/dev/null | awk 'NR>1 && $1 ~ /^@/ {print $1}')
        if [[ -n "$load_refs" || -n "$install_id" || -n "$rpath_refs" || \
                -n "$token_rpath_refs" || -n "$token_refs" ]]; then
            bad=$((bad+1))
            echo "    BAD: $f"
            [[ -n "$load_refs" ]] && echo "$load_refs" | sed 's/^/        load:  /'
            [[ -n "$install_id" ]] && echo "$install_id" | sed 's/^/        id:    /'
            [[ -n "$rpath_refs" ]] && echo "$rpath_refs" | sed 's/^/        rpath: /'
            [[ -n "$token_rpath_refs" ]] && echo "$token_rpath_refs" | \
                sed 's/^/        rpath: /'
            [[ -n "$token_refs" ]] && echo "$token_refs" | sed 's/^/        token: /'
        fi
    done < <(list_macho "$1")
    if [[ $bad -eq 0 ]]; then
        echo "    OK: $total Mach-O files resolve only inside the app or macOS"
        return 0
    fi
    echo "ERROR: $bad of $total Mach-O files have external references" >&2
    return 1
}

check_macho_platform() {
    local app="$1" total=0 bad=0 f minos found_minos
    while IFS= read -r -d '' f; do
        total=$((total+1))
        found_minos=0
        if ! lipo -verify_arch "$MACOS_ARCHITECTURES" "$f" \
                >/dev/null 2>&1; then
            echo "    BAD: $f has no $MACOS_ARCHITECTURES slice" >&2
            bad=$((bad+1))
        fi
        while IFS= read -r minos; do
            if ! awk -v actual="$minos" \
                    -v maximum="$MACOS_DEPLOYMENT_TARGET" 'BEGIN {
                split(actual, a, ".")
                split(maximum, m, ".")
                exit !((a[1] + 0 < m[1] + 0) ||
                    (a[1] + 0 == m[1] + 0 && a[2] + 0 < m[2] + 0) ||
                    (a[1] + 0 == m[1] + 0 && a[2] + 0 == m[2] + 0 &&
                        a[3] + 0 <= m[3] + 0))
            }'; then
                echo "    BAD: $f requires macOS $minos" >&2
                bad=$((bad+1))
            fi
            found_minos=1
        done < <(otool -l "$f" 2>/dev/null | awk '
            $1 == "cmd" {
                wanted = ($2 == "LC_BUILD_VERSION" ||
                    $2 == "LC_VERSION_MIN_MACOSX")
                next
            }
            wanted && ($1 == "minos" || $1 == "version") {
                print $2
                wanted = 0
            }
        ')
        if [[ $found_minos -eq 0 ]]; then
            echo "    BAD: $f has no macOS deployment version" >&2
            bad=$((bad+1))
        fi
    done < <(list_macho "$app")
    if [[ $bad -eq 0 ]]; then
        echo "    OK: $total Mach-O files support $MACOS_ARCHITECTURES" \
            "and macOS $MACOS_DEPLOYMENT_TARGET"
        return 0
    fi
    echo "ERROR: found $bad incompatible Mach-O platform entries" >&2
    return 1
}

verify_app_structure() {
    local app="$1" bin
    [[ -d "$app" ]] || fail "app not found: $app"
    [[ -f "$app/Contents/Info.plist" ]] || fail "Info.plist not found"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"
    [[ -x "$bin" ]] || fail "main binary not executable: $bin"
    [[ -d "$app/Contents/Frameworks" ]] || fail "Contents/Frameworks not found"
    [[ -d "$app/Contents/Resources" ]] || fail "Contents/Resources not found"
    file "$bin"
}

runtime_import_check() {
    local bin="$1" code
    code='import importlib.metadata
import pathlib
import sys
import fontTools
import jsonschema
import lz4.frame
import matplotlib.pyplot
import numpy
import PIL.Image
import PySide6
import shiboken6
import zstandard
import solvcon.pilot.base._base_app
jsonschema.validate({}, {})
assert lz4.frame.decompress(lz4.frame.compress(b"pilot")) == b"pilot"
compressed = zstandard.ZstdCompressor().compress(b"pilot")
assert zstandard.ZstdDecompressor().decompress(compressed) == b"pilot"
assert PIL.Image.new("RGB", (1, 1)).size == (1, 1)
assert numpy.arange(3).sum() == 3
for distribution in ("fonttools", "matplotlib", "jsonschema", "lz4", "Pillow", "zstandard"):
    importlib.metadata.version(distribution)
prefix = pathlib.Path(sys.prefix).resolve()
for module in (fontTools, jsonschema, lz4, matplotlib, numpy, PIL, PySide6, shiboken6, solvcon, zstandard):
    assert pathlib.Path(module.__file__).resolve().is_relative_to(prefix), module.__file__'
    (
        cd /
        env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
            PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
            PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
            "$bin" --mode=python -c "$code"
    )
}

smoke_launch_verify() {
    local bin="$1" trace="$2" app="$3" pid elapsed=0 loaded bad_paths
    : > "$trace"
    env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
        PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
        PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
        DYLD_PRINT_LIBRARIES=1 \
        "$bin" >/dev/null 2>"$trace" &
    pid=$!
    while [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed + 1))
        loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
        [[ ${loaded:-0} -ge $MIN_LOADS ]] && break
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    loaded=$(grep -c '^dyld\[' "$trace" 2>/dev/null || true)
    if [[ $loaded -lt $MIN_LOADS ]]; then
        echo "ERROR: pilot loaded only $loaded libraries; did it crash early?" >&2
        sed -n '1,80p' "$trace" >&2
        return 1
    fi
    bad_paths=$(grep -E '^dyld\[' "$trace" | awk '{print $NF}' | while IFS= read -r path; do
        case "$path" in
        "$app"/*|/System/Library/*|/usr/lib/*|/System/Volumes/Preboot/Cryptexes/OS/*) ;;
        *) printf '%s\n' "$path" ;;
        esac
    done | sort -u)
    if [[ -n "$bad_paths" ]]; then
        echo "ERROR: smoke launch loaded libraries from outside the app or macOS:" >&2
        echo "$bad_paths" | sed -n '1,20p' >&2
        return 1
    fi
    echo "    OK: $loaded libraries loaded from the app or macOS"
}

VERIFY_MNT=""
VERIFY_TMP=""
VERIFY_TRACE=""
VERIFY_MARKER=""
cleanup_verify() {
    [[ -n "${VERIFY_MNT:-}" ]] && hdiutil detach -quiet "$VERIFY_MNT" >/dev/null 2>&1 || true
    [[ -n "${VERIFY_TMP:-}" ]] && rm -rf "$VERIFY_TMP"
    [[ -n "${VERIFY_TRACE:-}" ]] && rm -f "$VERIFY_TRACE"
    [[ -n "${VERIFY_MARKER:-}" ]] && rm -f "$VERIFY_MARKER"
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
    trap cleanup_verify EXIT

    note "Mounting DMG"
    hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
    app=$(find "$mnt" -maxdepth 2 -name '*.app' -type d -print -quit)
    [[ -n "$app" ]] || fail "no .app found in $dmg"
    bin="$app/Contents/MacOS/$(basename "$app" .app)"
    APP="$app"
    BINARY="$bin"

    note "Checking mounted app structure"
    verify_app_structure "$app"

    note "Checking code signature before launch"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose=4 "$app" 2>&1 || \
        echo "    warning: spctl rejected this app (expected for ad-hoc signed prototype builds)"

    note "Static scan for external Mach-O paths"
    check_self_contained "$app"

    note "Checking Mach-O architecture and deployment versions"
    check_macho_platform "$app"

    note "Runtime import check from a writable app copy"
    cp -R "$app" "$tmp/"
    copied_app="$tmp/$(basename "$app")"
    codesign --verify --deep --strict "$copied_app"
    touch "$marker"
    runtime_import_check "$copied_app/Contents/MacOS/$(basename "$copied_app" .app)"
    if find "$copied_app" -name '*.pyc' -newer "$marker" -print -quit | grep -q .; then
        echo "ERROR: runtime import wrote Python bytecode into the signed app bundle:" >&2
        find "$copied_app" -name '*.pyc' -newer "$marker" -print | sed -n '1,20p' >&2
        return 1
    fi
    codesign --verify --deep --strict "$copied_app"

    note "Smoke launch from mounted DMG"
    smoke_launch_verify "$bin" "$trace" "$app"

    note "Release artifact verification passed"
}

COMMAND=bundle
if [[ $# -gt 0 ]]; then
    case "$1" in
        check|bundle|verify|all)
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
case "$COMMAND" in
    verify)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        VERIFY_ARTIFACT="$1"
        shift
        ;;
esac

SKIP_BUILD=0
SKIP_CHECK=0
DEPENDENCY_PREFIX=""
RUNTIME_PYTHON_ENV=""
BUILD_PYTHON_ENV=""
OUTPUT_DIR="$BUNDLE_REPO_ROOT/build"

if [[ "$COMMAND" == "check" || "$COMMAND" == "bundle" || "$COMMAND" == "all" ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --skip-build) SKIP_BUILD=1    ; shift ;;
        --skip-check) SKIP_CHECK=1    ; shift ;;
        --dependency-prefix)
            [[ $# -ge 2 ]] || { echo "Missing argument for --dependency-prefix" >&2; usage >&2; exit 2; }
            DEPENDENCY_PREFIX="$2"
            shift 2
            ;;
        --runtime-python-env)
            [[ $# -ge 2 ]] || { echo "Missing argument for --runtime-python-env" >&2; usage >&2; exit 2; }
            RUNTIME_PYTHON_ENV="$2"
            shift 2
            ;;
        --build-python-env)
            [[ $# -ge 2 ]] || { echo "Missing argument for --build-python-env" >&2; usage >&2; exit 2; }
            BUILD_PYTHON_ENV="$2"
            shift 2
            ;;
            --output)
                [[ $# -ge 2 ]] || { echo "Missing argument for --output" >&2; usage >&2; exit 2; }
                OUTPUT_DIR="$2"
                shift 2
                ;;
            *) echo "Unknown option: $1" >&2 ; usage >&2 ; exit 1 ;;
        esac
    done
elif [[ $# -gt 0 ]]; then
    usage >&2
    exit 2
fi

if [[ "$COMMAND" != "verify" ]]; then
    [[ -n "$DEPENDENCY_PREFIX" ]] || \
        { echo "Missing required --dependency-prefix DIR" >&2; usage >&2; exit 2; }
    [[ -d "$DEPENDENCY_PREFIX" ]] || \
        { echo "Dependency prefix is not a directory: $DEPENDENCY_PREFIX" >&2; exit 1; }
    DEPENDENCY_PREFIX=$(cd "$DEPENDENCY_PREFIX" && pwd -P)
    [[ "$DEPENDENCY_PREFIX" != "/" ]] || \
        { echo "Dependency prefix must not be the filesystem root" >&2; exit 1; }
    [[ -d "$RUNTIME_PYTHON_ENV" ]] || \
        { echo "Runtime Python environment not found: $RUNTIME_PYTHON_ENV" >&2; exit 1; }
    [[ -d "$BUILD_PYTHON_ENV" ]] || \
        { echo "Build Python environment not found: $BUILD_PYTHON_ENV" >&2; exit 1; }
    RUNTIME_PYTHON_ENV=$(cd "$RUNTIME_PYTHON_ENV" && pwd -P)
    BUILD_PYTHON_ENV=$(cd "$BUILD_PYTHON_ENV" && pwd -P)
    PYTHON="$DEPENDENCY_PREFIX/bin/python3"
    MACDEPLOYQT="$DEPENDENCY_PREFIX/bin/macdeployqt"
    QTPATHS="$DEPENDENCY_PREFIX/bin/qtpaths"
    RUNTIME_PYTHON="$RUNTIME_PYTHON_ENV/bin/python"
    BUILD_PYTHON="$BUILD_PYTHON_ENV/bin/python"
    [[ -x "$RUNTIME_PYTHON" ]] || \
        { echo "Runtime Python not found: $RUNTIME_PYTHON" >&2; exit 1; }
    [[ -x "$BUILD_PYTHON" ]] || \
        { echo "Build Python not found: $BUILD_PYTHON" >&2; exit 1; }
    RUNTIME_SITE=$("$RUNTIME_PYTHON" -c \
        'import sysconfig; print(sysconfig.get_path("purelib"))')
    PYBIND11_CMAKE_DIR=$("$BUILD_PYTHON" -m pybind11 --cmakedir)
    [[ -d "$RUNTIME_SITE" ]] || \
        { echo "Runtime site-packages not found: $RUNTIME_SITE" >&2; exit 1; }
    [[ -d "$PYBIND11_CMAKE_DIR" ]] || \
        { echo "pybind11 CMake config not found: $PYBIND11_CMAKE_DIR" >&2; exit 1; }
fi

if [[ "$COMMAND" == "all" ]]; then
    check_deps
fi

# Record the starting time of the script and the first step. SECONDS is bash's
# built-in elapsed-second counter.
T_SCRIPT=$SECONDS
T_STEP=$T_SCRIPT

# Single cleanup hook for every temp resource the script creates. EachS
# variable is initialised empty here and populated lazily (in later steps).
# The trap is set once. Any later step can register a temp file or DMG mount
# without juggling its own trap.
CLOSURE_TMP=""
TRACE=""
DMG_MOUNT=""
cleanup() {
    [[ -n "$CLOSURE_TMP" ]] && rm -rf "$CLOSURE_TMP"
    [[ -n "$TRACE" ]] && rm -f "$TRACE"
    if [[ -n "$DMG_MOUNT" ]]; then
        hdiutil detach -quiet "$DMG_MOUNT" >/dev/null 2>&1 \
            || hdiutil detach -force -quiet "$DMG_MOUNT" >/dev/null 2>&1 \
            || true
        rmdir "$DMG_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

case "$COMMAND" in
    check)
        check_deps
        exit 0
        ;;
    verify)
        verify_dmg "$VERIFY_ARTIFACT"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Derive paths
# ---------------------------------------------------------------------------

PY_VER=$(bundle_pyver)
BUILD_PATH=build/relbundle
APP="$BUNDLE_REPO_ROOT/$BUILD_PATH/cpp/binary/pilot/pilot.app"
BINARY="$APP/Contents/MacOS/pilot"
FW_DIR="$APP/Contents/Frameworks"

# Locate the Python framework used at build time.
PY_FW=$(PYTHONNOUSERSITE=1 "$PYTHON" -s -c "
import sys, os, sysconfig
fw = sysconfig.get_config_var('PYTHONFRAMEWORKPREFIX')
if fw:
    print(os.path.join(fw, 'Python.framework'))
else:
    base = os.path.dirname(os.path.dirname(sys.executable))
    print(os.path.join(base, 'Frameworks', 'Python.framework'))
")
PY_DYLIB="$PY_FW/Versions/$PY_VER/Python"
NEW_PY_PATH="@executable_path/../Frameworks/Python.framework/Versions/$PY_VER/Python"

case "$PY_FW" in
    "$DEPENDENCY_PREFIX"/*) ;;
    *) echo "ERROR: Python.framework is outside $DEPENDENCY_PREFIX: $PY_FW" >&2; exit 1 ;;
esac

# PySide6 and shiboken6 belong to the Homebrew Qt stack. Locate their complete
# package directories explicitly; every other Python package comes from the
# isolated pip runtime environment.
QT_PYTHON_PATHS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && QT_PYTHON_PATHS+=("$line")
done < <(PYTHONPATH="$RUNTIME_SITE" PYTHONNOUSERSITE=1 "$PYTHON" -s -c "
import importlib, os
for name in ('PySide6', 'shiboken6'):
    mod = importlib.import_module(name)
    print(os.path.realpath(os.path.dirname(mod.__file__)))
")

for path in "${QT_PYTHON_PATHS[@]}"; do
    case "$path" in
        "$DEPENDENCY_PREFIX"/*) ;;
        *) echo "ERROR: Qt Python package is outside $DEPENDENCY_PREFIX: $path" >&2; exit 1 ;;
    esac
done

QT_METADATA_PATHS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && QT_METADATA_PATHS+=("$line")
done < <(PYTHONPATH="$RUNTIME_SITE" PYTHONNOUSERSITE=1 "$PYTHON" -s -c "
import importlib.metadata, os
for name in ('PySide6', 'shiboken6'):
    try:
        dist = importlib.metadata.distribution(name)
    except importlib.metadata.PackageNotFoundError:
        continue
    print(os.path.realpath(dist._path))
")

for path in "${QT_METADATA_PATHS[@]}"; do
    case "$path" in
        "$DEPENDENCY_PREFIX"/*) ;;
        *) echo "ERROR: Qt Python metadata is outside $DEPENDENCY_PREFIX: $path" >&2; exit 1 ;;
    esac
done

echo "==> Build path : $BUILD_PATH"
echo "==> App bundle : $APP"
echo "==> Python fw  : $PY_FW"
echo "==> pip runtime: $RUNTIME_SITE"
echo "==> pip build  : $PYBIND11_CMAKE_DIR"
echo "==> macOS arch : $MACOS_ARCHITECTURES"
echo "==> macOS min  : $MACOS_DEPLOYMENT_TARGET"
for path in "${QT_PYTHON_PATHS[@]}"; do
    echo "==> Qt Python  : $path"
done

[[ -f "$PY_DYLIB" ]] || { echo "ERROR: Python dylib not found at $PY_DYLIB" >&2; exit 1; }

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
    rm -rf "$BUNDLE_REPO_ROOT/$BUILD_PATH"
    echo "==> make pilot BUILD_PATH=$BUILD_PATH"
    env PATH="$DEPENDENCY_PREFIX/bin:$PATH" \
        PYTHONPATH="$RUNTIME_SITE" \
        CMAKE_PREFIX_PATH="$DEPENDENCY_PREFIX" \
        CMAKE_OSX_ARCHITECTURES="$MACOS_ARCHITECTURES" \
        CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
        PYTHON_EXECUTABLE="$PYTHON" \
        pybind11_DIR="$PYBIND11_CMAKE_DIR" \
        make pilot BUILD_PATH="$BUILD_PATH"
fi

[[ -f "$BINARY" ]] || { echo "ERROR: pilot binary not found at $BINARY" >&2; exit 1; }
echo "    [Step 1 (Build pilot): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 2: Deploy Qt
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> macdeployqt (bundles Qt frameworks, plugins, transitive dylibs)"
# macdeployqt looks for sibling frameworks under <prefix>/lib/, but Homebrew
# puts Python.framework under <prefix>/Frameworks/. This triggers two cosmetic
# ERROR lines (exit 0; Qt deployment unaffected; Step 3 bundles Python
# ourselves). Filter just those lines; pipefail keeps real failures visible.
"$MACDEPLOYQT" "$APP" -verbose=1 2>&1 | sed -E \
    -e '/^ERROR: .*otool-classic: can.t open file: .*lib\/Python\.framework.*No such file or directory/d' \
    -e '/^ERROR: no file at ".*lib\/Python\.framework/d'
echo "    [Step 2 (Deploy Qt): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 3: Bundle Python framework
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Bundling Python.framework"

DEST_FW="$FW_DIR/Python.framework"
rm -rf "$DEST_FW"
cp -R "$PY_FW" "$DEST_FW"

install_name_tool -change "$PY_DYLIB" "$NEW_PY_PATH" "$BINARY"
echo "    Python -> $NEW_PY_PATH"

# site-packages inside the framework is a symlink into Cellar; replace with a
# real directory so subsequent steps can drop packages in.
BUNDLED_SITE="$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/site-packages"
rm -rf "$BUNDLED_SITE"
mkdir -p "$BUNDLED_SITE"
echo "    [Step 3 (Bundle Python framework): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 4: Bundle site-packages
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Copying Python packages into bundled site-packages"
PTH_FILE=$(find "$RUNTIME_SITE" -maxdepth 1 -name '*.pth' -print -quit)
[[ -z "$PTH_FILE" ]] || {
    echo "ERROR: runtime environment contains an unsupported .pth file: $PTH_FILE" >&2
    exit 1
}
rsync -aL --exclude '__pycache__' "$RUNTIME_SITE/" "$BUNDLED_SITE/"

for path in "${QT_PYTHON_PATHS[@]}"; do
    rsync -aL --exclude '__pycache__' "$path" "$BUNDLED_SITE/"
done
for path in "${QT_METADATA_PATHS[@]}"; do
    rsync -aL "$path" "$BUNDLED_SITE/"
done
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
# mutate the sealed contents and break the code signature). Use the bundled
# python so the .pyc magic matches the interpreter that will actually read
# them. unchecked-hash makes the cache trusted unconditionally, sidestepping
# mtime drift from rsync/DMG creation that would otherwise let the default
# timestamp mode falsely invalidate the cache at runtime.
#
# Target the whole lib/python<ver> tree so both the stdlib (which Step 3
# copied in via `cp -R`, including Homebrew's timestamp-mode .pyc) and the
# rsynced site-packages get a uniform unchecked-hash cache. The `-f` flag
# forces rewrite over the inherited stdlib .pyc.
#
# Drop lib/python<ver>/test first: CPython's own test suite is not used at
# runtime, accounts for ~100 MB, and ships intentionally-bad-syntax fixtures
# that would make compileall exit nonzero. Use `|| true` so any stray
# uncompilable file in a package's own tests/ does not kill the build --
# those files are not imported at runtime, so missing .pyc is harmless. The
# trailing sanity check fails loudly if compileall produced nothing at all,
# which would silently revert us to the writes-into-bundle problem.
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
echo "==> Pre-compiling bundled Python modules"
PY_LIB="$DEST_FW/Versions/$PY_VER/lib/python$PY_VER"
rm -rf "$PY_LIB/test"
"$DEST_FW/Versions/$PY_VER/bin/python$PY_VER" -m compileall -f \
    --invalidation-mode unchecked-hash -q \
    "$PY_LIB" || true
PYC_COUNT=$(find "$PY_LIB" -name '*.pyc' | wc -l | tr -d ' ')
[[ $PYC_COUNT -gt 0 ]] || \
    { echo "ERROR: compileall produced no .pyc files under $PY_LIB" >&2; exit 1; }
echo "    compiled $PYC_COUNT .pyc files"
echo "    [Step 5.5 (Pre-compile bytecode): $((SECONDS - T_STEP))s]"

# ---------------------------------------------------------------------------
# Step 6: Vendor native dependencies
#
# macdeployqt only follows Qt's load commands, so other dependencies (Python's
# lib-dynload .so files, libpyside6, libshiboken6, etc.) still resolve through
# the build prefix at runtime. Walk every Mach-O in the bundle, copy prefix
# dylibs and frameworks into Contents/Frameworks/, rewrite load commands and
# LC_ID_DYLIB to the bundled copy, and strip the source prefix from LC_RPATH.
# ---------------------------------------------------------------------------

bundle_load_path() {
    local bin="$1" target="$2" rel
    rel=$("$PYTHON" -c \
        'import os, sys; print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))' \
        "$bin" "$target")
    printf '@loader_path/%s\n' "$rel"
}

record_missing_load() {
    local bin="$1" load="$2"
    if ! grep -qxF "$bin -> $load" "$SEEN_MISSING"; then
        printf '%s -> %s\n' "$bin" "$load" >> "$SEEN_MISSING"
        echo "    ERROR: could not resolve $load loaded by $bin" >&2
    fi
}

same_macho_identity() {
    local left="$1" right="$2" left_uuid right_uuid
    left_uuid=$(otool -l "$left" | awk '$1 == "uuid" { print $2 }')
    right_uuid=$(otool -l "$right" | awk '$1 == "uuid" { print $2 }')
    [[ -n "$left_uuid" && "$left_uuid" == "$right_uuid" ]]
}

copy_dependency_dylib() {
    local source="$1" base destination known
    base=${source##*/}
    destination="$FW_DIR/$base"
    known=$(awk -F '\t' -v base="$base" '$1 == base { print $2; exit }' \
        "$DYLIB_SOURCES")
    if [[ -n "$known" && "$known" != "$source" ]]; then
        echo "ERROR: dynamic library name collision for $base:" >&2
        echo "    $known" >&2
        echo "    $source" >&2
        return 1
    fi
    if [[ -f "$destination" && -z "$known" ]]; then
        if same_macho_identity "$source" "$destination"; then
            printf '%s\t%s\n' "$base" "$source" >> "$DYLIB_SOURCES"
            printf '%s\t%s\n' "$destination" "$source" >> "$SOURCE_MAP"
        else
            echo "ERROR: $source collides with bundled $destination" >&2
            return 1
        fi
    fi
    if [[ ! -f "$destination" ]]; then
        cp -L "$source" "$destination" || return 1
        chmod u+w "$destination"
        printf '%s\t%s\n' "$base" "$source" >> "$DYLIB_SOURCES"
        printf '%s\t%s\n' "$destination" "$source" >> "$SOURCE_MAP"
        echo "$destination" >> "$QUEUE"
    fi
    printf '%s\n' "$destination"
}

copy_dependency_framework() {
    local source="$1" source_fw name destination target relative known src_bin
    source_fw=${source%%.framework/*}.framework
    name=$(basename "$source_fw" .framework)
    destination="$FW_DIR/$name.framework"
    relative=${source#"$source_fw"/}
    known=$(awk -F '\t' -v name="$name" '$1 == name { print $2; exit }' \
        "$FRAMEWORK_SOURCES")
    if [[ -n "$known" && "$known" != "$source_fw" ]]; then
        echo "ERROR: framework name collision for $name.framework:" >&2
        echo "    $known" >&2
        echo "    $source_fw" >&2
        return 1
    fi
    if [[ -d "$destination" && -z "$known" ]]; then
        target="$destination/$relative"
        if same_macho_identity "$source" "$target"; then
            printf '%s\t%s\n' "$name" "$source_fw" >> "$FRAMEWORK_SOURCES"
        else
            echo "ERROR: $source_fw collides with bundled $destination" >&2
            return 1
        fi
    fi
    if [[ ! -d "$destination" ]]; then
        mkdir -p "$destination"
        rsync -a --copy-unsafe-links "$source_fw/" "$destination/" || return 1
        chmod -R u+w "$destination"
        printf '%s\t%s\n' "$name" "$source_fw" >> "$FRAMEWORK_SOURCES"
        while IFS= read -r -d '' src_bin; do
            target="$destination/${src_bin#"$source_fw"/}"
            printf '%s\t%s\n' "$target" "$src_bin" >> "$SOURCE_MAP"
            echo "$target" >> "$QUEUE"
        done < <(list_macho "$source_fw")
    fi
    printf '%s/%s\n' "$destination" "$relative"
}

# Walk every dependency edge. Prefix dependencies are copied into the bundle,
# and each edge records the exact replacement load command.
vendor_native_deps() {
    CLOSURE_TMP=$(mktemp -d)
    QUEUE="$CLOSURE_TMP/queue"
    SEEN_BIN="$CLOSURE_TMP/seen_bin"
    SEEN_MISSING="$CLOSURE_TMP/seen_missing"
    REWRITE_EDGES="$CLOSURE_TMP/rewrite_edges"
    SOURCE_MAP="$CLOSURE_TMP/source_map"
    DYLIB_SOURCES="$CLOSURE_TMP/dylib_sources"
    FRAMEWORK_SOURCES="$CLOSURE_TMP/framework_sources"
    touch "$QUEUE" "$SEEN_BIN" "$SEEN_MISSING" "$REWRITE_EDGES" \
        "$SOURCE_MAP" "$DYLIB_SOURCES" "$FRAMEWORK_SOURCES"

    list_macho "$APP" | xargs -0 -n1 echo >> "$QUEUE"

    local BIN OLD SRC TARGET NEW resolved
    while [[ -s "$QUEUE" ]]; do
        BIN=$(head -n 1 "$QUEUE")
        sed -i '' '1d' "$QUEUE"
        grep -qxF "$BIN" "$SEEN_BIN" && continue
        echo "$BIN" >> "$SEEN_BIN"
        while IFS= read -r OLD; do
            case "$OLD" in
            /System/Library/*|/usr/lib/*|"$APP"/*) continue ;;
            "$DEPENDENCY_PREFIX"/*) SRC="$OLD" ;;
            @loader_path/*|@executable_path/*|@rpath/*)
                resolved=$(resolve_macho_load "$BIN" "$OLD" 1 || true)
                case "$resolved" in
                "$APP"/*)
                    NEW=$(bundle_load_path "$BIN" "$resolved")
                    printf '%s\t%s\t%s\n' "$BIN" "$OLD" "$NEW" >> "$REWRITE_EDGES"
                    continue
                    ;;
                /System/Library/*|/usr/lib/*) continue ;;
                "$DEPENDENCY_PREFIX"/*) SRC="$resolved" ;;
                *) record_missing_load "$BIN" "$OLD"; continue ;;
                esac
                ;;
            /*|@*) record_missing_load "$BIN" "$OLD"; continue ;;
            *) continue ;;
            esac

            if [[ ! -f "$SRC" ]]; then
                record_missing_load "$BIN" "$OLD"
                continue
            fi
            SRC=$("$PYTHON" -c \
                'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SRC")
            case "$SRC" in
            *.framework/*) TARGET=$(copy_dependency_framework "$SRC") || return 1 ;;
            *) TARGET=$(copy_dependency_dylib "$SRC") || return 1 ;;
            esac
            NEW=$(bundle_load_path "$BIN" "$TARGET")
            printf '%s\t%s\t%s\n' "$BIN" "$OLD" "$NEW" >> "$REWRITE_EDGES"
        done < <(otool -L "$BIN" 2>/dev/null | awk 'NR>1 {print $1}')
    done

    if [[ -s "$SEEN_MISSING" ]]; then
        echo "ERROR: native dependencies are missing from $DEPENDENCY_PREFIX" >&2
        return 1
    fi

    echo "    bundled $(wc -l < "$DYLIB_SOURCES" | tr -d ' ') dylibs and \
$(wc -l < "$FRAMEWORK_SOURCES" | tr -d ' ') frameworks"
}

rewrite_load_commands() {
    local BIN OLD NEW f fw_path name vname bin_path VER python_target
    while IFS=$'\t' read -r BIN OLD NEW; do
        install_name_tool -change "$OLD" "$NEW" "$BIN"
    done < "$REWRITE_EDGES"

    while IFS= read -r -d '' f; do
        case "$f" in
            *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$f" ;;
        esac
    done < <(list_macho "$APP")
    for f in "$FW_DIR"/*.dylib; do
        [[ -f "$f" ]] || continue
        install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null
    done
    for fw_path in "$FW_DIR"/*.framework; do
        [[ -d "$fw_path" ]] || continue
        name=$(basename "$fw_path" .framework)
        for VER in "$fw_path"/Versions/*; do
            [[ -d "$VER" && ! -L "$VER" ]] || continue
            bin_path="$VER/$name"
            [[ -f "$bin_path" ]] || continue
            vname=$(basename "$VER")
            install_name_tool -id "@loader_path/$name" "$bin_path" 2>/dev/null
        done
    done

    # Two re-export stubs inside Python.framework still hard-code the original
    # Homebrew Python path. Redirect them to the bundled copy.
    python_target="$DEST_FW/Versions/$PY_VER/Python"
    for f in \
        "$DEST_FW/Versions/$PY_VER/lib/libpython${PY_VER}.dylib" \
        "$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/config-${PY_VER}-darwin/libpython${PY_VER}.dylib"
    do
        [[ -f "$f" ]] || continue
        if otool -L "$f" | awk 'NR>1 {print $1}' | grep -qxF "$PY_DYLIB"; then
            NEW=$(bundle_load_path "$f" "$python_target")
            install_name_tool -change "$PY_DYLIB" "$NEW" "$f"
        fi
    done
}

# Delete source-prefix rpaths. Add a loader-relative path to the bundle's
# Frameworks directory so the rule also works for nested helper applications.
strip_dependency_rpaths() {
    local BIN dependency_rps rp replacement
    while IFS= read -r -d '' BIN; do
        dependency_rps=$(binary_rpaths "$BIN" | grep -F "$DEPENDENCY_PREFIX/" || true)
        [[ -z "$dependency_rps" ]] && continue
        replacement=$(bundle_load_path "$BIN" "$FW_DIR")
        if ! binary_rpaths "$BIN" | grep -qxF "$replacement"; then
            install_name_tool -add_rpath "$replacement" "$BIN"
        fi
        while IFS= read -r rp; do
            [[ -z "$rp" ]] && continue
            install_name_tool -delete_rpath "$rp" "$BIN"
        done <<< "$dependency_rps"
    done < <(list_macho "$APP")
}

# PySide6 wheels ship a private copy of Qt under PySide6/Qt/lib. Its .abi3.so
# modules load that copy via @rpath; pilot's C++ binary loads Qt from
# Contents/Frameworks/. Two Qt instances in one process => duplicate Obj-C
# classes, separate global state, "QWidget: Must construct a QApplication"
# abort. Replace each duplicated nested framework with a relative symlink to
# the main bundle copy. Frameworks unique to PySide6 (QtCharts, ...) are left
# in place; their @rpath/QtCore... refs resolve through these symlinks too.
dedupe_pyside_qt() {
    local pyqt_lib count=0 nested name main rel
    pyqt_lib="$DEST_FW/Versions/$PY_VER/lib/python${PY_VER}/site-packages/PySide6/Qt/lib"
    [[ -d "$pyqt_lib" ]] || return 0
    # 9 levels: PySide6/Qt/lib up to Contents/Frameworks/.
    rel='../../../../../../../../..'
    for nested in "$pyqt_lib"/Qt*.framework; do
        [[ -d "$nested" && ! -L "$nested" ]] || continue
        name=$(basename "$nested" .framework)
        main="$FW_DIR/${name}.framework"
        [[ -d "$main" && ! -L "$main" ]] || continue
        rm -rf "$nested"
        ln -s "$rel/${name}.framework" "$nested"
        count=$((count+1))
    done
    if [[ $count -gt 0 ]]; then
        echo "    deduped $count PySide6/Qt/lib framework(s) into main Qt"
    fi
}

# Set the embedded Python environment for Finder/open launches. User packages
# can carry a second PySide6, and writing a missing .pyc would invalidate the
# app signature.
inject_python_environment() {
    local plist="$APP/Contents/Info.plist" name value
    [[ -f "$plist" ]] || { echo "    SKIP: no Info.plist at $plist" >&2; return 0; }
    # macdeployqt's Step 2 codesign locks Info.plist read-only; Step 7
    # re-locks it.
    chmod u+w "$plist"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" \
        2>/dev/null || true
    for name in PYTHONNOUSERSITE PYTHONDONTWRITEBYTECODE; do
        value=1
        if /usr/libexec/PlistBuddy -c "Print :LSEnvironment:$name" \
                "$plist" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c \
                "Set :LSEnvironment:$name $value" "$plist"
        else
            /usr/libexec/PlistBuddy -c \
                "Add :LSEnvironment:$name string $value" "$plist"
        fi || {
            echo "    ERROR: failed to set LSEnvironment.$name" >&2
            return 1
        }
        echo "    Info.plist LSEnvironment.$name = $value"
    done
}

T_STEP=$SECONDS
echo "==> Vendoring native dependencies from $DEPENDENCY_PREFIX"
vendor_native_deps
echo "==> Redirecting native dependency load commands to bundled copies"
rewrite_load_commands
echo "==> Stripping dependency-prefix rpaths"
strip_dependency_rpaths
echo "==> Deduplicating PySide6's bundled Qt against the main bundle Qt"
dedupe_pyside_qt
echo "==> Setting the embedded Python environment in Info.plist"
inject_python_environment
echo "==> Checking rewritten native dependency paths"
check_self_contained "$APP"
echo "    [Step 6 (Vendor native deps): $((SECONDS - T_STEP))s]"

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
    done < <(list_macho "$APP/Contents")
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

# Re-seal each nested framework (Python.framework, Qt*.framework, ...).
# On macOS the framework version directory carries the signature.
sign_frameworks() {
    local FW VER
    find "$APP" -name '*.framework' -type d -print | \
        awk '{print length($0), $0}' | sort -k1,1nr | cut -d' ' -f2- | \
        while IFS= read -r FW; do
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
    codesign --verify --deep --strict "$APP"
}

T_STEP=$SECONDS
echo "==> Ad-hoc re-signing all bundled Mach-O files"
sign_inner_machos
sign_helper_apps
sign_frameworks
echo "==> Ad-hoc re-signing the app bundle"
sign_main_app
echo "    [Step 7 (Ad-hoc codesign): $((SECONDS - T_STEP))s]"

echo ""
echo "Bundle complete: $APP"

# ---------------------------------------------------------------------------
# Step 8: Package DMG
# ---------------------------------------------------------------------------

T_STEP=$SECONDS
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/pilot.dmg"
echo "==> Creating $DMG from $APP"
hdiutil create -volname "solvcon Pilot" \
    -srcfolder "$APP" \
    -ov -format UDZO \
    "$DMG"
SIZE=$(du -sh "$DMG" | cut -f1)
echo "    [Step 8 (Package DMG): $((SECONDS - T_STEP))s]"

echo ""
echo "DMG complete: $DMG ($SIZE)"

# ---------------------------------------------------------------------------
# Step 9: Verify hermeticity
#
# Two complementary checks per artifact:
#   - Static scan of every Mach-O load command and LC_RPATH for references
#     outside the app and macOS system locations.
#   - Smoke launch under env -i with DYLD_PRINT_LIBRARIES=1 to catch
#     anything that resolves at runtime via PATH or dyld fallbacks.
# Repeated for both the .app and the .app inside the mounted DMG.
# ---------------------------------------------------------------------------

# A real launch loads ~900-1500 libraries (Qt + Python + dependents, yeah it's
# a lot, and why this script is still a prototype). Anything under this floor
# suggests the process was killed before dyld finished its initial pass and the
# trace tells us nothing.
# env -i drops every variable; we set only the minimum to let Cocoa initialise.
# pilot is a GUI app and never exits on its own, so we poll the trace at 1 Hz
# and SIGTERM as soon as dyld has emitted >= MIN_LOADS lines. Polling absorbs
# the multi-second kernel signature validation stall on a fresh codesign or DMG
# mount without paying a fixed wait on subsequent launches.
launch_and_trace() {
    local bin="$1" pid elapsed=0 loaded
    : > "$TRACE"
    env -i HOME="${HOME:-/}" USER="${USER:-nobody}" \
        PATH=/usr/bin:/bin TERM="${TERM:-xterm}" \
        PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
        DYLD_PRINT_LIBRARIES=1 \
        "$bin" >/dev/null 2>"$TRACE" &
    pid=$!
    while [[ $elapsed -lt 15 ]]; do
        sleep 1
        elapsed=$((elapsed+1))
        loaded=$(grep -c '^dyld\[' "$TRACE" 2>/dev/null || true)
        [[ ${loaded:-0} -ge $MIN_LOADS ]] && break
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Run a sandboxed launch and verify the dyld trace: enough loads happened, and
# every load came from the app or macOS.
smoke_check() {
    local bin="$1" app="$2" label="${3:-}" total bad_paths
    [[ -n "$label" ]] && label=" ($label)"
    echo "==> Smoke launch${label} under sandboxed env (DYLD_PRINT_LIBRARIES=1)"
    launch_and_trace "$bin"
    total=$(grep -c '^dyld\[' "$TRACE" || true)
    bad_paths=$(grep -E '^dyld\[' "$TRACE" | awk '{print $NF}' | while IFS= read -r path; do
        case "$path" in
        "$app"/*|/System/Library/*|/usr/lib/*|/System/Volumes/Preboot/Cryptexes/OS/*) ;;
        *) printf '%s\n' "$path" ;;
        esac
    done | sort -u)
    if [[ $total -lt $MIN_LOADS ]]; then
        echo "ERROR: pilot loaded only $total libraries (expected >= $MIN_LOADS);" \
             "did it crash early?" >&2
        sed -n '1,40p' "$TRACE" >&2
        exit 1
    fi
    if [[ -n "$bad_paths" ]]; then
        echo "ERROR: dyld loaded libraries from outside the app or macOS:" >&2
        echo "$bad_paths" | sed -n '1,20p' >&2
        exit 1
    fi
    echo "    OK: $total libraries loaded from the app or macOS"
}

# Run Step 9 against both the .app and the .app inside the mounted DMG. TRACE
# and DMG_MOUNT are set on globals so the cleanup trap can tear them down on
# any exit path.
if [[ $SKIP_CHECK -eq 0 ]]; then
    T_STEP=$SECONDS
    TRACE=$(mktemp -t check-bundle-trace)

    echo ""
    echo "==> Checking $APP"
    echo "==> Static scan for external Mach-O paths"
    check_self_contained "$APP"
    echo "==> Checking Mach-O architecture and deployment versions"
    check_macho_platform "$APP"
    smoke_check "$BINARY" "$APP"
    echo ""
    echo "Bundle check passed: $APP"

    DMG_MOUNT=$(mktemp -d -t check-dmg)
    echo ""
    echo "==> Mounting $DMG at $DMG_MOUNT"
    hdiutil attach -nobrowse -readonly -mountpoint "$DMG_MOUNT" "$DMG" \
        >/dev/null

    DMG_APP=$(find "$DMG_MOUNT" -maxdepth 2 -name '*.app' -type d -print -quit)
    [[ -n "$DMG_APP" ]] || { echo "ERROR: no .app found in $DMG" >&2; exit 1; }
    echo "==> Found app: $DMG_APP"
    DMG_BINARY="$DMG_APP/Contents/MacOS/$(basename "$DMG_APP" .app)"
    APP="$DMG_APP"
    BINARY="$DMG_BINARY"
    echo "==> Static scan (DMG) for external Mach-O paths"
    check_self_contained "$DMG_APP"
    echo "==> Checking Mach-O architecture and deployment versions (DMG)"
    check_macho_platform "$DMG_APP"
    echo "==> Runtime import check (DMG)"
    runtime_import_check "$DMG_BINARY"
    smoke_check "$DMG_BINARY" "$DMG_APP" "DMG"
    echo ""
    echo "DMG check passed: $DMG"
    echo "    [Step 9 (Verify hermeticity): $((SECONDS - T_STEP))s]"
fi

echo ""
echo "Total elapsed: $((SECONDS - T_SCRIPT))s"

# vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4:
