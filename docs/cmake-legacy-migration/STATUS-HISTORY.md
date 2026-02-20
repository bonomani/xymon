Reference Migration Status History
===============================

How to Update
-------------
Add a new entry at the top using this template:

Entry: YYYY-MM-DD
-----------------

Summary:
- What changed
- What was validated
- What remains

Environment:
- Distro/Version
- Toolchain
- Notable variables (e.g., `LEGACY_APPLY_OWNERSHIP`, `LEGACY_DESTDIR`)

Details:
- Link to logs or diffs if stored elsewhere

Entry: 2026-02-12
-----------------

Summary:
- Added BSD-style reference validation workflows for OpenBSD, NetBSD, and macOS (`ref-valid-*` naming).
- Added macOS reference validation matrix (server/localclient/client), using FreeBSD references as the closest baseline.
- Fixed multiple macOS runner compatibility issues found during workflow execution.

Environment:
- GitHub Actions macOS runner (`bash` 3.2 default shell behavior).
- Build path: CMake bootstrap/install/reference generation and compare scripts.
- Notable variables: `LEGACY_APPLY_OWNERSHIP=ON`, `XYMONUSER=_www`, `XYMONGROUP=_www`.

Details:
- Root causes observed on macOS:
  - `bad substitution` from `${val^^}` (Bash 4 syntax unsupported by Bash 3.2).
  - `mapfile: command not found` (Bash 4 builtin unavailable).
  - `declare -A` usage in shell scripts (associative arrays unsupported in Bash 3.2).
  - `/bin/chown` not found due to hardcoded absolute paths in CMake install hooks.
  - `HAVE_RPCENT_H` generated as `#define HAVE_RPCENT_H 0` with `#ifdef` checks, causing wrong include behavior on BSD/macOS-like platforms.
- Fixes applied:
  - `cmake/config.h.in`: switched `HAVE_RPCENT_H` from `#cmakedefine01` to `#cmakedefine`.
  - `ci/bootstrap-install.sh`: added `--os macos` support and propagated `-DXYMONUSER=...` to CMake configure.
  - `ci/deps/packages-from-yaml.sh`: removed Bash 4-only constructs (`${val^^}`, `mapfile`, associative arrays).
  - `ci/generate-refs.sh`: removed `mapfile` and array dependency for keyfiles; now uses sorted list file.
  - `ci/compare-refs.sh`: replaced associative-array owner rendering with `awk`-based mapping.
  - `CMakeLists.txt` and `xymond/CMakeLists.txt`: replaced hardcoded `/bin/*` and `/usr/bin/find` commands with portable command names resolved via `PATH`.
- Validation performed:
  - `bash -n` checks on updated scripts.
  - Local smoke run of `ci/generate-refs.sh` with synthetic tree (success).
  - Local smoke run of `ci/compare-refs.sh` with synthetic baseline/candidate (success).
  - Local CMake configure check for client variant with ownership mode enabled (success).
- Remaining validation:
  - Full GitHub Actions macOS `ref-valid-macos.yml` matrix rerun to confirm end-to-end parity behavior.

Entry: 2026-02-04
-----------------

RUN SUMMARY - IMPORTANT POINTS

1) Root cause of the initial errors
- "chgrp nobody" fails because the "nobody" group does not exist (depends on distro).
- "chown" fails in non-root mode (Operation not permitted).
- "cmake --build ... -D..." is invalid: -D options are passed to "cmake -S/-B" (configure), not to "cmake --build" (build).
- DESTDIR must be passed as an environment/Make variable (e.g., `DESTDIR=/tmp/xymon-stage make install` or `env DESTDIR=/tmp/xymon-stage make install`), not as a separate argument.

2) Applied CMake fixes
- Added a CMake switch: LEGACY_APPLY_OWNERSHIP (ON/OFF)
- OFF: no chown/chgrp operations (user staging/packaging mode).
- ON: chown/chgrp executed (root installation mode).
- install-reference-dirs: creates reference directories.
- install-reference-files: copies web files + chmod (and ownership only if LEGACY_APPLY_OWNERSHIP=ON).
- install-reference-files now invokes `cmake --install` to handle binaries, CGIs, and non-web client components.
- Conditional copy of web directories (EXISTS) to avoid errors if a folder is missing.

3) Validated commands (OK)

A) Staging / packaging (no privileges)
- configure:
  cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=OFF
- prepare destdir:
  rm -rf dist-reference && mkdir dist-reference
- build target:
  cmake --build build-cmake --target install-reference-files

B) Root installation (with privileges)
- configure:
  cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=ON
- build target as root (requires interactive sudo password):
  sudo cmake --build build-cmake --target install-reference-files

4) Parity diff (OK)
- `sudo make install DESTDIR=/tmp/xymon-stage` (reference tree lives under `/tmp/var/lib/xymon`; collected with `find /tmp/var/lib/xymon … | sed 's|/tmp||' | sort > docs/cmake-reference-migration/refs/reference.linux.server.ref`)
- `cmake --build build-cmake --target install-reference-dirs`/`install-reference-files` with `LEGACY_DESTDIR=/tmp/cmake-ref-root` (staging under `/tmp/cmake-ref-root`; normalized tree via `find /tmp/cmake-ref-root/var/lib/xymon … | sed 's|/tmp/cmake-ref-root||' | sort > /tmp/cmake.list`)
- The diff compares `docs/cmake-reference-migration/refs/reference.linux.server.ref` against the generated CMake list with identical path roots.
- The CMake list was regenerated after the clean ON-mode install; rerunning the diff now only highlights the documented extra helper binaries and the optional staging log file.
- Latest ON-mode install succeeded: the inline hook logged `Reference hook: existing perms before change 755|xymon|xymon` and `Reference hook: perms after change 4755|root|bc`, closing the `xymonping` SUID/group parity gap.
- Key divergences needing justification:
  * Extra helper binaries (e.g., `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`) appear only in the CMake tree and are now documented as intentional extras.
  * If `tee` is used during staging, `/var/lib/xymon/install-cmake-reference.log` appears in the diff; treat it as a non-product artifact (exclude from parity checks or avoid `tee` when generating the list).
  * The new `install-reference-files` hook now chowns `root`, logs the stat snapshots before/after the change, and then chmods `4755`; the latest run confirms the final `4755 root` state.
- These points are documented in the validation plan (criteria OK).

5) Install modes and portability (OK)
- `LEGACY_APPLY_OWNERSHIP=OFF cmake --build build-cmake --target install-reference-files` completes with no chown/chgrp, and the same `Up-to-date` log appears even when `XYMONUSER` or `HTTPDGID` are unset (`env -u XYMONUSER ...`, `env -u HTTPDGID ...`), showing the install path is resilient when those variables are absent.
- `find /tmp/cmake-ref-root/var/lib/xymon/cgi-bin -type f ! -perm 755` returns nothing (OK).
- `find /tmp/cmake-ref-root/var/lib/xymon -perm 777` returns nothing unexpected (OK).
- `test -d /tmp/cmake-ref-root/var/lib/xymon/server/www/help`, `.../menu`, and `stat .../www | grep '755'` pass (OK).
- DESTDIR packaging: `cmake -S . -B build-cmake-destdir -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ -DLEGACY_DESTDIR=/tmp/pkg`, followed by `cmake --build build-cmake-destdir` (to generate binaries) and `cmake --build build-cmake-destdir --target install-reference-files`, succeeds and writes to `/tmp/pkg`; the first install attempt failed until the build artifacts existed.
- After deleting `/tmp/cmake-ref-root` and rerunning the ON-mode install from scratch, `stat -c '%n|%U|%G|%a' /tmp/cmake-ref-root/var/lib/xymon/server/bin/xymonping` now shows `4755|root|root`; the inline hook runs after the recursive `chown -R` and re-applies `chown root` + `chmod 4755`.

6) Result
- OFF: install-reference-files finishes without error (no chown), including the edge-case runs above.
- ON + sudo: command runs successfully and the inline hook confirms `4755 root` for `xymonping`.

7) Remaining watch point
- The HTTPDGID/rep/snap mapping must stay conditional (HTTPDGID defined + group exists) if you want to avoid "invalid group" errors.
