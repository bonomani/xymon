LEGACY MODE VALIDATION GUIDE
============================

Scope
-----
This document defines the exact steps required to validate the **Legacy mode**
of the CMake build against the existing `configure + make` build system.

IMPORTANT SAFETY RULE
---------------------
During migration and validation, **neither build system is allowed to write to
the real system paths** such as `/var/lib/xymon` or `/var/log/xymon`.

- Legacy `make install` MUST run only with a safe staging DESTDIR and MUST be
  verified to land under `/tmp/...` (current behavior: `/tmp/var/lib/xymon`).
- DESTDIR must be passed as an environment/Make variable (e.g.,
  `DESTDIR=/tmp/legacy-ref make install` or `env DESTDIR=/tmp/legacy-ref make install`).
- Never run legacy `make install` without DESTDIR, and never allow it to write
  to `/var/lib/xymon` on the host.
- CMake MUST be validated using a sandbox install via DESTDIR only.

----------------------------------------------------------------------
1. Definition of "Legacy Mode"
----------------------------------------------------------------------

Legacy mode in CMake is defined as:

- USE_GNUINSTALLDIRS = OFF
- Absolute paths identical to the Makefile rules
- No FHS normalization
- No refactoring
- No dependency re-interpretation
- No invented paths
- No behavior change

CMake is required to emulate the legacy system, not modernize it.

----------------------------------------------------------------------
2. Source of Truth
----------------------------------------------------------------------

The ONLY authoritative reference for legacy installation behavior is:

    build/Makefile.rules
    target: install-dirs

Because:
- legacy `configure` does NOT support --prefix
- legacy `make install` is not fully DESTDIR-compliant and currently stages to
  `/tmp/var/lib/xymon` even when DESTDIR is set
- legacy install is root-only

Therefore:
- Makefiles are the contract
- Not the filesystem
- Not documentation
- Not assumptions

----------------------------------------------------------------------
3. Canonical Legacy Directory Contract
----------------------------------------------------------------------

The following directories MUST be created by CMake in Legacy mode:

/var/lib/xymon/server
/var/lib/xymon/server/download
/var/lib/xymon/server/bin
/var/lib/xymon/server/etc
/var/lib/xymon/server/ext
/var/lib/xymon/server/tmp
/var/lib/xymon/server/web
/var/lib/xymon/server/www
/var/lib/xymon/server/www/gifs
/var/lib/xymon/server/www/help
/var/lib/xymon/server/www/html
/var/lib/xymon/server/www/menu
/var/lib/xymon/server/www/notes
/var/lib/xymon/server/www/rep
/var/lib/xymon/server/www/snap
/var/lib/xymon/server/www/wml
/var/lib/xymon/data
/var/lib/xymon/data/acks

Symbolic links MUST be created when paths differ:

/var/lib/xymon/server/bin  -> INSTALLBINDIR
/var/lib/xymon/server/etc  -> INSTALLETCDIR
/var/lib/xymon/server/ext  -> INSTALLEXTDIR
/var/lib/xymon/server/tmp  -> INSTALLTMPDIR
/var/lib/xymon/server/web  -> INSTALLWEBDIR
/var/lib/xymon/server/www  -> INSTALLWWWDIR

Conditions for symlink creation MUST match Makefile logic.

----------------------------------------------------------------------
4. Legacy System: What You MUST NOT Run
----------------------------------------------------------------------

Do NOT run these during validation:

- `make install` (legacy) **without** DESTDIR
- any command that writes to `/var/lib/xymon` on the host system
- any validation approach based on comparing the real filesystem

Rationale:
- legacy install is root-only
- legacy install is not reversible in a controlled way

Legacy is validated via staged installs under `/tmp` + build logs, not by
writing to the live filesystem.

----------------------------------------------------------------------
5. CMake Configuration for Legacy Validation
----------------------------------------------------------------------

Configure CMake exactly as follows:

    cmake -B build-cmake \
          -DUSE_GNUINSTALLDIRS=OFF \
          -DCMAKE_INSTALL_PREFIX=/

No other layout-related options are allowed.

----------------------------------------------------------------------
5.1 Legacy Install Targets & Modes
----------------------------------------------------------------------

Targets:
- `install-legacy-dirs`: creates the legacy directory tree only.
- `install-legacy-files`: installs binaries, CGIs, client assets, and web files;
  also enforces permissions/ownership when `LEGACY_APPLY_OWNERSHIP=ON`.

Modes:
- Staging (packaging): set `LEGACY_APPLY_OWNERSHIP=OFF` and use DESTDIR to stage
  under `/tmp/...` without privileged ownership changes.
- Root install: set `LEGACY_APPLY_OWNERSHIP=ON` and run the install target under
  sudo; the `xymonping` hook re-applies `root:bc` and `4755`.

----------------------------------------------------------------------
5.2 Responsibility Split (Global vs Sub-CMakeLists)
----------------------------------------------------------------------

Sub-CMakeLists.txt responsibilities:
- Per-component install rules for binaries, CGIs, scripts, and manpages
  (common, xymongen, xymonnet, xymonproxy, xymond, web, client).
- Web/help assets and manpage HTML staging (docs).

Global legacy responsibilities:
- Legacy directory tree creation (`install-legacy-dirs`).
- Legacy webfile/wwwfile staging (top-level legacy install step).
- Ownership/permission gating via `LEGACY_APPLY_OWNERSHIP`.
- `xymonping` suid + `root:bc` fixup hook.

----------------------------------------------------------------------
6. Sandbox Installation (Required)
----------------------------------------------------------------------

CMake MUST be validated via sandbox install only. Example:

    cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/
    cmake --build build-cmake --target install-legacy-dirs install-legacy-files \
          -DLEGACY_DESTDIR=/tmp/cmake-ref-root

Legacy make install must also be staged under `/tmp`:

    sudo DESTDIR=/tmp/legacy-ref make install

Note: legacy makefiles currently land under `/tmp/var/lib/xymon` even when
DESTDIR is set, so use that path for the legacy reference list.

The real system is not touched.

Cleanup is trivial:

    rm -rf /tmp/cmake-ref-root /tmp/legacy-ref /tmp/var/lib/xymon

----------------------------------------------------------------------
7. Validation Procedure
----------------------------------------------------------------------

7.1 Directory Structure

Verify that /tmp/cmake-ref-root contains EXACTLY the legacy directory contract:

    find /tmp/cmake-ref-root/var/lib/xymon -type d | sort

Compare this list against Section 3.

- No extra directories allowed
- No missing directories allowed

7.2 Symbolic Links

Verify symlinks:

    find /tmp/cmake-ref-root/var/lib/xymon/server -type l -ls

Symlink targets MUST match legacy rules.

7.3 config.h Parity

Compare macros against the legacy-generated config.h when available,
or compare against the Makefile/configure outputs used by the legacy build.

Critical items:
- WORDS_BIGENDIAN / WORDS_LITTLEENDIAN
- HAVE_* macros
- PATH_MAX
- XYMON*DIR macros and string values

7.4 Compilation Flags (Command Parity)

Capture real compiler invocations.

Legacy:
    make VERBOSE=1 > legacy.build.log

CMake:
    cmake --build build-cmake --verbose > cmake.build.log

Verify:
- -I paths
- -D macros
- optimization/debug flags
- config.h inclusion behavior

7.5 Binaries

Verify binaries exist in the sandbox install tree:

    ls -l /tmp/cmake-ref-root/var/lib/xymon/server/bin

Verify runtime dependencies:

    ldd /tmp/cmake-ref-root/var/lib/xymon/server/bin/xymond

Libraries must match legacy expectations.

7.6 Embedded Paths

Some tools embed paths at build time.

Verify with:

    strings /tmp/cmake-ref-root/var/lib/xymon/server/bin/* | grep /var/lib/xymon

Embedded paths must match legacy paths.

----------------------------------------------------------------------
8. What Is NOT Allowed
----------------------------------------------------------------------

- Introducing GNUInstallDirs behavior in Legacy mode
- Changing directory layout
- Renaming paths

----------------------------------------------------------------------
9. Tooling Prerequisites
----------------------------------------------------------------------

Legacy validation assumes:
- `/bin/chown` and `/bin/chmod` exist for the ownership/permission hook.
- `/usr/bin/find` is available for the directory parity checks.

----------------------------------------------------------------------
10. Portability Test Matrix (Planned)
----------------------------------------------------------------------

Run the same staging install + diff on:
- Debian/Ubuntu (with and without a "nobody" group)
- RHEL/Rocky

Record:
- whether `HTTPDGID` group exists and how the install behaves when missing
- whether any chgrp/chown warnings appear in OFF mode (should not)

Suggested test flow (per distro):
1) `cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ -DLEGACY_APPLY_OWNERSHIP=OFF`
2) `cmake --build build-cmake --target install-legacy-dirs install-legacy-files -DLEGACY_DESTDIR=/tmp/cmake-ref-root`
3) `find /tmp/cmake-ref-root/var/lib/xymon -printf '/var/lib/xymon/%P\n' | sort > /tmp/cmake.list`
4) `diff -u /tmp/legacy.list /tmp/cmake.list`

----------------------------------------------------------------------
11. XYMONUSER Missing (Planned)
----------------------------------------------------------------------

Goal: verify OFF mode still succeeds when XYMONUSER does not exist.

Procedure:
- `env -u XYMONUSER LEGACY_APPLY_OWNERSHIP=OFF cmake --build build-cmake --target install-legacy-files`
- Expected: install completes without chown/chgrp attempts and logs remain clean.
 
----------------------------------------------------------------------
12. What Is NOT Allowed
----------------------------------------------------------------------

- Removing symlinks
- Replacing absolute paths with prefix-relative ones
- Editing the legacy Makefiles to add DESTDIR support
- "Improving" legacy behavior during validation

----------------------------------------------------------------------
13. Acceptance Criteria
----------------------------------------------------------------------

Legacy mode is VALID if and only if:

- All directories match Section 3
- All symlinks match Makefile logic
- config.h values are equivalent to legacy intent
- Binaries link against the expected libraries
- Embedded paths are unchanged
- CMake can validate via DESTDIR without touching the real system

----------------------------------------------------------------------
End of document
----------------------------------------------------------------------
