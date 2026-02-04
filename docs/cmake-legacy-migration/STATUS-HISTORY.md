Legacy Migration Status History
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

Entry: 2026-02-04
-----------------

RUN SUMMARY - IMPORTANT POINTS

1) Root cause of the initial errors
- "chgrp nobody" fails because the "nobody" group does not exist (depends on distro).
- "chown" fails in non-root mode (Operation not permitted).
- "cmake --build ... -D..." is invalid: -D options are passed to "cmake -S/-B" (configure), not to "cmake --build" (build).
- DESTDIR must be passed as an environment/Make variable (e.g., `DESTDIR=/tmp/legacy-ref make install` or `env DESTDIR=/tmp/legacy-ref make install`), not as a separate argument.

2) Applied CMake fixes
- Added a CMake switch: LEGACY_APPLY_OWNERSHIP (ON/OFF)
- OFF: no chown/chgrp operations (user staging/packaging mode).
- ON: chown/chgrp executed (root installation mode).
- install-legacy-dirs: creates legacy directories.
- install-legacy-files: copies web files + chmod (and ownership only if LEGACY_APPLY_OWNERSHIP=ON).
- install-legacy-files now invokes `cmake --install` to handle binaries, CGIs, and non-web client components.
- Conditional copy of web directories (EXISTS) to avoid errors if a folder is missing.

3) Validated commands (OK)

A) Staging / packaging (no privileges)
- configure:
  cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=OFF
- prepare destdir:
  rm -rf dist-legacy && mkdir dist-legacy
- build target:
  cmake --build build-cmake --target install-legacy-files

B) Root installation (with privileges)
- configure:
  cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=ON
- build target as root (requires interactive sudo password):
  sudo cmake --build build-cmake --target install-legacy-files

4) Parity diff (OK)
- `sudo make install DESTDIR=/tmp/legacy-ref` (reference tree lives under `/tmp/var/lib/xymon`; collected with `find /tmp/var/lib/xymon … | sed 's|/tmp||' | sort > docs/cmake-legacy-migration/legacy.ref`)
- `cmake --build build-cmake --target install-legacy-dirs`/`install-legacy-files` with `LEGACY_DESTDIR=/tmp/cmake-ref-root` (staging under `/tmp/cmake-ref-root`; normalized tree via `find /tmp/cmake-ref-root/var/lib/xymon … | sed 's|/tmp/cmake-ref-root||' | sort > /tmp/cmake.list`)
- The diff compares `docs/cmake-legacy-migration/legacy.ref` against the generated CMake list with identical path roots.
- The CMake list was regenerated after the clean ON-mode install; rerunning the diff now only highlights the documented extra helper binaries and the optional staging log file.
- Latest ON-mode install succeeded: the inline hook logged `Legacy hook: existing perms before change 755|xymon|xymon` and `Legacy hook: perms after change 4755|root|bc`, closing the `xymonping` SUID/group parity gap.
- Key divergences needing justification:
  * Extra helper binaries (e.g., `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`) appear only in the CMake tree and are now documented as intentional extras.
  * If `tee` is used during staging, `/var/lib/xymon/install-cmake-legacy.log` appears in the diff; treat it as a non-product artifact (exclude from parity checks or avoid `tee` when generating the list).
  * The new `install-legacy-files` hook now chowns `root`, logs the stat snapshots before/after the change, and then chmods `4755`; the latest run confirms the final `4755 root` state.
- These points are documented in the validation plan (criteria OK).

5) Install modes and portability (OK)
- `LEGACY_APPLY_OWNERSHIP=OFF cmake --build build-cmake --target install-legacy-files` completes with no chown/chgrp, and the same `Up-to-date` log appears even when `XYMONUSER` or `HTTPDGID` are unset (`env -u XYMONUSER ...`, `env -u HTTPDGID ...`), showing the install path is resilient when those variables are absent.
- `find /tmp/cmake-ref-root/var/lib/xymon/cgi-bin -type f ! -perm 755` returns nothing (OK).
- `find /tmp/cmake-ref-root/var/lib/xymon -perm 777` returns nothing unexpected (OK).
- `test -d /tmp/cmake-ref-root/var/lib/xymon/server/www/help`, `.../menu`, and `stat .../www | grep '755'` pass (OK).
- DESTDIR packaging: `cmake -S . -B build-cmake-destdir -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ -DLEGACY_DESTDIR=/tmp/pkg`, followed by `cmake --build build-cmake-destdir` (to generate binaries) and `cmake --build build-cmake-destdir --target install-legacy-files`, succeeds and writes to `/tmp/pkg`; the first install attempt failed until the build artifacts existed.
- After deleting `/tmp/cmake-ref-root` and rerunning the ON-mode install from scratch, `stat -c '%n|%U|%G|%a' /tmp/cmake-ref-root/var/lib/xymon/server/bin/xymonping` now shows `4755|root|root`; the inline hook runs after the recursive `chown -R` and re-applies `chown root` + `chmod 4755`.

6) Result
- OFF: install-legacy-files finishes without error (no chown), including the edge-case runs above.
- ON + sudo: command runs successfully and the inline hook confirms `4755 root` for `xymonping`.

7) Remaining watch point
- The HTTPDGID/rep/snap mapping must stay conditional (HTTPDGID defined + group exists) if you want to avoid "invalid group" errors.
