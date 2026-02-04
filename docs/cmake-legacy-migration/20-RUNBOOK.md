Legacy Mode Validation Runbook
==============================

Scope
-----
This runbook defines the exact steps required to validate the CMake Legacy mode
against the existing `configure + make` build system.

Important Safety Rule
---------------------
During migration and validation, neither build system is allowed to write to
real system paths such as `/var/lib/xymon` or `/var/log/xymon`.

Rules
-----
- Legacy `make install` must run with a safe DESTDIR and must land under `/tmp/...`.
- Never run legacy `make install` without DESTDIR.
- CMake validation must use a sandbox install via DESTDIR.
- Do not pass `-D` options to `cmake --build`; pass them to `cmake -S/-B`.

Definition of Legacy Mode
-------------------------
Legacy mode in CMake is defined as:
- `USE_GNUINSTALLDIRS = OFF`
- Absolute paths identical to the Makefile rules
- No FHS normalization
- No refactoring
- No dependency re-interpretation
- No invented paths
- No behavior change

CMake must emulate the legacy system, not modernize it.

Source of Truth
---------------
The only authoritative reference for legacy installation behavior is:
- `build/Makefile.rules` target `install-dirs`

The Makefiles are the contract, not the live filesystem or assumptions.

Reference List Policy
---------------------
`docs/cmake-legacy-migration/legacy.ref` is a versioned reference snapshot.
Update it only when legacy Makefiles change, and record the update in
`STATUS-HISTORY.md`.

Prerequisites
-------------
- `/bin/chown` and `/bin/chmod` for ownership/permission hooks.
- `/usr/bin/find` for parity checks.

Variables Glossary
------------------
- `LEGACY_DESTDIR`: staging root for legacy installs (e.g., `/tmp/cmake-ref-root`).
- `LEGACY_APPLY_OWNERSHIP`: `OFF` for staging (no chown/chgrp), `ON` for root install.
- `XYMONUSER`: legacy owner user for installed files.
- `HTTPDGID`: optional group for `www/rep` and `www/snap` when defined and present.

Configuration
-------------
Configure CMake exactly as follows:

```sh
cmake -S . -B build-cmake \
  -DUSE_GNUINSTALLDIRS=OFF \
  -DCMAKE_INSTALL_PREFIX=/ \
  -DLEGACY_DESTDIR=/tmp/cmake-ref-root \
  -DXYMON_VARIANT=all
```

Legacy Install Targets and Modes
--------------------------------
Targets:
- `install-legacy-dirs`: creates the legacy directory tree only.
- `install-legacy-files`: installs binaries, CGIs, client assets, and web files;
  enforces permissions and ownership when `LEGACY_APPLY_OWNERSHIP=ON`.

Modes:
- Staging: `LEGACY_APPLY_OWNERSHIP=OFF`, use DESTDIR, no privileged ownership changes.
- Root install: `LEGACY_APPLY_OWNERSHIP=ON`, run under sudo; `xymonping` is restored to `4755 root:bc`.

Sandbox Installation (Required)
-------------------------------
CMake validation must be done via a sandbox install:

```sh
cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ \
  -DLEGACY_DESTDIR=/tmp/cmake-ref-root \
  -DXYMON_VARIANT=all
LEGACY_DESTDIR=/tmp/cmake-ref-root cmake --build build-cmake \
  --target install-legacy-dirs install-legacy-files
```

Legacy make install must also be staged under `/tmp`:

```sh
sudo DESTDIR=/tmp/legacy-ref make install
```

Note: legacy makefiles currently land under `/tmp/var/lib/xymon` even when
DESTDIR is set, so use that path for the legacy reference list.

To generate the reference list:

```sh
find /tmp/var/lib/xymon -printf '/var/lib/xymon/%P\n' \
  | sed 's|/var/lib/xymon/$|/var/lib/xymon|' \
  | sort > docs/cmake-legacy-migration/legacy.ref
```

Note: the CMake list is generated per run (e.g., `/tmp/cmake.list`) and is not
a reference. It is only used for comparison against `legacy.ref`.

Cleanup:

```sh
rm -rf /tmp/cmake-ref-root /tmp/legacy-ref /tmp/var/lib/xymon
```

Validation Procedure
--------------------
1) Directory structure parity

```sh
find /tmp/cmake-ref-root/var/lib/xymon -type d | sort
```

Compare against Section 3 of `30-REFERENCE.md`.

2) Symlink parity

```sh
find /tmp/cmake-ref-root/var/lib/xymon/server -type l -ls
```

Symlink targets must match legacy rules.

3) config.h parity
- Compare macros against the legacy-generated `config.h` when available.
- Critical items: `WORDS_BIGENDIAN`, `WORDS_LITTLEENDIAN`, `HAVE_*`, `PATH_MAX`, and all `XYMON*DIR` macros.

4) Compilation flags parity

```sh
make VERBOSE=1 > legacy.build.log
cmake --build build-cmake --verbose > cmake.build.log
```

Verify include paths, macros, and optimization/debug flags.

5) Binaries

```sh
ls -l /tmp/cmake-ref-root/var/lib/xymon/server/bin
ldd /tmp/cmake-ref-root/var/lib/xymon/server/bin/xymond
```

Libraries must match legacy expectations.

6) Embedded paths

```sh
strings /tmp/cmake-ref-root/var/lib/xymon/server/bin/* | grep /var/lib/xymon
```

Embedded paths must match legacy paths.

Not Allowed
-----------
Never:
- Introducing GNUInstallDirs behavior in Legacy mode.
- Changing directory layout or path names.
- Removing symlinks required by legacy logic.
- Editing legacy Makefiles to add DESTDIR support.

Avoid unless explicitly instructed:
- "Improving" legacy behavior during validation.

Portability Matrix (Planned)
----------------------------
Run the same staging install + diff on:
- Debian/Ubuntu
- RHEL/Rocky
- systems without a `nobody` group

Record:
- whether `HTTPDGID` exists
- whether any chgrp/chown warnings appear in OFF mode

Suggested test flow:
1) `cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ -DLEGACY_APPLY_OWNERSHIP=OFF`
2) `LEGACY_DESTDIR=/tmp/cmake-ref-root cmake --build build-cmake --target install-legacy-dirs install-legacy-files`
3) `find /tmp/cmake-ref-root/var/lib/xymon -printf '/var/lib/xymon/%P\n' | sort > /tmp/cmake.list`
4) `diff -u /tmp/legacy.list /tmp/cmake.list`

XYMONUSER Missing (Planned)
---------------------------
Goal: verify OFF mode still succeeds when `XYMONUSER` does not exist.

Procedure:
- `env -u XYMONUSER LEGACY_APPLY_OWNERSHIP=OFF cmake --build build-cmake --target install-legacy-files`

Expected result:
- Install completes without chown/chgrp attempts and logs remain clean.

Acceptance Criteria
-------------------
Legacy mode is valid if and only if:
- All directories match Section 3 of `30-REFERENCE.md`.
- All symlinks match Makefile logic.
- `config.h` values are equivalent to legacy intent.
- Binaries link against expected libraries.
- Embedded paths are unchanged.
- CMake validates via DESTDIR without touching the real system.
