# macOS Pilot Bundle

`bundle-with-prefix.sh` uses an explicit dependency prefix, without devenv
activation or Homebrew. Only `prepare` downloads and installs dependencies.
`check`, `bundle`, and `verify` do not install anything.

Run these commands on macOS from the repository root:

```bash
./contrib/bundle/bundle-with-prefix.sh prepare --dry-run
./contrib/bundle/bundle-with-prefix.sh prepare
./contrib/bundle/bundle-with-prefix.sh check
./contrib/bundle/bundle-with-prefix.sh bundle
./contrib/bundle/bundle-with-prefix.sh verify build/pilot.dmg
```

The matching Makefile targets are `bundle-prepare`, `bundle-precheck`,
`bundle`, and `bundle-test`. `make bundle` checks the prefix and builds the
artifact; it never prepares dependencies automatically.

## Dependency Prefix

The default prefix is `build/bundle-deps/6.11.1/macos`. It contains both Qt and
a complete standalone Python installation:

```text
build/bundle-deps/6.11.1/macos/
    bin/python3
    bin/macdeployqt
    bin/qtpaths
    include/
    lib/QtCore.framework/
    lib/libpython3.14.dylib
    lib/python3.14/site-packages/
```

`prepare` installs Qt with `aqt install-qt --outputdir`, preserving aqt's
versioned directory layout. It installs Python into that same prefix. The
standalone archive is SHA-256 checked before extraction. The native CPU
selects the arm64 or x86_64 Python archive; this is not a universal2 Python
build.

The Qt download uses the same `thirdparty/aqt_settings.ini` as CI, passed
through the `AQT_CONFIG` environment variable for the aqt process. No manual
`AQT_CONFIG` export is needed.
The shared settings blacklist the Yamagata mirror for redirects and remove
it from fallbacks after TLS certificate validation failures. TLS
verification and archive checksum checking stay enabled; the checksum
algorithm remains `sha1` to match the existing CI settings.

`AQT_CONFIG` can select another settings file. Relative overrides are
resolved against the caller's working directory. The selected path appears
in both the preparation log and the dry-run plan. The file must exist before
any dependencies are installed.

The pinned versions come from the successful macOS CI job on 2026-10-09:

| Component | Version |
| --- | --- |
| Python | 3.14.7, standalone release 20260929 |
| Qt, PySide6, shiboken6 | 6.11.1 |
| Qt extra module | qtshadertools |
| aqtinstall | 3.3.0 |
| py7zr | 1.1.0 |
| CMake | 4.4.3 |
| pybind11 | 3.0.1 |
| NumPy | 2.5.3 |
| Matplotlib | 3.11.2 |
| jsonschema | 4.26.0 |

The MCAP codecs `zstandard` and `lz4` are also installed. Their versions and
transitive pip dependencies are not locked. `shiboken6_generator` is not a
required dependency: the referenced CI job builds without it.

The standalone prefix also installs `pip-system-certs==5.3` as a preparation
dependency. Its startup hook makes Python SSL clients, including aqt's
spawned download workers, use the macOS system certificate store through
truststore. This addresses trust-chain differences when system curl succeeds
but Requests cannot find an issuer. Certificate and hostname verification
remain enabled. No Keychain certificates are added or trust policies changed.
Preparation verifies that the startup hook is active before launching aqt.
The hook affects Python processes in the dedicated prefix only; `.pth` files
remain excluded from the packaged app.

CI's installer action caches Qt, so a successful cached CI run does not
prove that every download mirror is working. If certificate failures also
occur despite the system-trust bootstrap, check the network/proxy CA trust.
Requests accepts a trusted CA bundle through `REQUESTS_CA_BUNDLE`;
Python's `-I` does not ignore that variable. Do not bypass TLS verification
to complete the download.

Choose another location with `--prefix DIR`, or `RELEASE_PREFIX=DIR` for
Makefile targets. For `prepare`, the path must end in `/6.11.1/macos` so Qt
and Python land in the same directory. Other commands accept an existing
compatible prefix at any location. Relative prefix, output, and artifact
paths are resolved against the caller's working directory.

```bash
./contrib/bundle/bundle-with-prefix.sh prepare \
    --prefix "$HOME/solvcon-bundle-deps/6.11.1/macos"
make bundle RELEASE_PREFIX="$HOME/solvcon-bundle-deps/6.11.1/macos"
```

`prepare` writes into the selected prefix. Use a dedicated directory, not a
system Python installation. Xcode command-line tools and `make` must already
be available. Do not substitute `pip install --target` for the complete
Python runtime: Pilot embeds libpython and also needs its headers and stdlib.

## Packaging and Verification

The script builds through `make pilot` in `build/relbundle`, with a fresh
CMake configure tied to the selected Python and Qt. `BUNDLE_BUILD_PATH` may
select another relative directory under `build/`. `--skip-build` accepts only
an undeployed app, not a previous bundle.

Python packages and distribution metadata are copied from the selected
prefix, rather than inferred from a startup import trace. `.pth` startup
hooks are excluded. PySide6 remains limited to Pilot's QtCore, QtGui,
QtWidgets, and QtSvg bindings; the app uses the deployed Qt rather than the
wheel's private Qt. The CPython test, Tk, and IDLE trees are excluded.

Native dependencies are copied and rewritten inside the app only. Unresolved
dependencies, failed Mach-O edits, and failed signatures stop the bundle.
The script does not delete an extension to hide an unresolved dependency.
Absolute non-system load commands and rpaths are rejected before signing.

The default `bundle` command runs the same artifact verification as
`verify`: signatures, mounted-app structure, native path checks, bundled
module origins, Matplotlib rendering, MCAP codec round trips, and GUI smoke
launches. Runtime probes use a temporary working directory and HOME, disable
user site-packages, and check the writable copy for bytecode/signature
changes after use. No repository Python package should mask a missing
bundled file. Both import/render and GUI dyld traces must contain only native
code from the launched app or macOS system locations.

`--skip-check` skips the final runtime artifact checks, not the static or
signature checks during packaging. Such an artifact is not release-verified.
Set `BUNDLE_DMG_LAYOUT=0` to skip the best-effort Finder icon arrangement.

These are ad-hoc signed prototype artifacts. A warning from `spctl` is not a
Developer ID signing or notarization result. Before distribution, also test
Finder launch and the supported GUI features on a clean macOS machine that
has no source prefix or Homebrew installed.

<!-- vim: set ff=unix fenc=utf8 et sw=4 ts=4 sts=4 tw=79: -->
