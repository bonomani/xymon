CMake Legacy Validation Plan
============================

Purpose
-------
Define the acceptance criteria and checklist for validating CMake Legacy mode
against the existing `configure + make` behavior. For step-by-step commands,
use `20-RUNBOOK.md`.

Scope
-----
- Legacy mode only (`USE_GNUINSTALLDIRS=OFF`).
- Absolute paths must match the legacy Makefile contract.
- No behavior changes, refactors, or modernizations.

Acceptance Criteria
-------------------
- Directory layout matches the legacy contract in `30-REFERENCE.md`.
- Symlinks are created only when legacy rules require them.
- Permissions match legacy behavior or are explicitly documented exceptions.
- Staged installs via DESTDIR succeed without touching real system paths.
- OFF mode performs no chown/chgrp operations.
- ON mode under sudo applies ownership and restores `xymonping` to `4755 root:bc`.
- Parity diff contains only documented exceptions.

Checklist (Status)
------------------
A. Structure and Architecture
- [x] Clear target separation: `install-legacy-dirs` creates the tree; `install-legacy-files` installs files and permissions.
- [x] DESTDIR support via `LEGACY_DESTDIR` for staging/packaging.
- [x] Explicit `LEGACY_APPLY_OWNERSHIP` switch (OFF/ON).
- [x] Deterministic behavior without privileges (OFF mode).
- [x] Deterministic behavior with sudo (ON mode).

B. Legacy Paths and Layout
- [x] `XYMONTOPDIR = /var/lib/xymon`.
- [x] `XYMONHOME = /var/lib/xymon/server`.
- [x] `XYMONVAR = /var/lib/xymon/data`.
- [x] `CGIDIR` and `SECURECGIDIR` created.
- [x] Complete data tree created (acks, hist, rrd, etc.).

C. Web Files
- [x] Validation uses the staging tree under `/tmp/cmake-ref-root/var/lib/xymon/...`.
- [x] Permission checks pass on staging tree.
- [x] Conditional web directory copy works and tolerates missing source folders.
- [x] Default permissions are applied: directories `755`, files `644`.

D. Ownership and Groups
- [x] OFF mode skips all chown/chgrp operations, even with missing `XYMONUSER` or `HTTPDGID`.
- [x] ON mode applies chown only when `LEGACY_APPLY_OWNERSHIP=ON`.
- [x] `HTTPDGID` group existence is checked before chgrp; warn if missing.
- [x] Post-install hook restores `xymonping` to `4755 root:bc` and logs before/after.

E. Parity With Legacy `make install`
- [x] Legacy reference captured with `sudo make install DESTDIR=/tmp/legacy-ref`.
- [x] `docs/cmake-legacy-migration/legacy.ref` is up to date with legacy Makefiles.
- [x] CMake legacy install uses `LEGACY_DESTDIR=/tmp/cmake-ref-root`.
- [x] Path normalization produces comparable lists rooted at `/var/lib/xymon/...`.
- [x] Diff between `legacy.ref` and the generated CMake list shows only documented exceptions.
- [x] Install hook is inline `install(CODE ...)` and uses `$ENV{DESTDIR}`.
- [x] `legacy.ref` is versioned reference data and must only be updated when legacy Makefiles change, with updates recorded in `STATUS-HISTORY.md`.

F. Binaries and Non-Web Components
- [x] `install-legacy-files` stages server binaries, CGIs, and client assets.
- [x] Per-component installs remain in sub-CMakeLists.txt files.
- [x] Global legacy logic handles directory tree, web staging, and ownership gating.

G. CMake API and UX
- [x] No `-D` options are passed to `cmake --build`.
- [x] All options are passed during configure (`cmake -S/-B`).
- [x] Targets documented: `install-legacy-dirs`, `install-legacy-files`.
- [x] Modes documented: staging (OFF) and root install (ON).

H. Robustness and Portability
- [x] Hardcoded tool prerequisites documented: `/bin/chown`, `/bin/chmod`, `/usr/bin/find`.
- [x] DESTDIR packaging validation succeeds.
- [x] Edge cases validated: `XYMONUSER` missing in OFF mode, `HTTPDGID` missing in OFF mode.
- [x] Privileged ON-mode install validates `xymonping` ends as `4755 root:bc`.
- [ ] Test matrix runs on Debian/Ubuntu.
- [ ] Test matrix runs on RHEL/Rocky.
- [ ] Test matrix runs without a `nobody` group.
- [ ] OFF mode validation when `XYMONUSER` does not exist.

I. Final Validation Criteria
- [x] `install-legacy-files` reproduces the legacy tree (exceptions noted).
- [x] Permissions diff identical or justified.
- [x] OFF mode logs clean.
- [x] ON mode logs clean and `xymonping` ends as `4755 root:bc`.
- [x] DESTDIR packaging works end-to-end.

Accepted Exceptions
-------------------
- Extra helper binaries present in CMake tree: `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`.
- Optional staging log artifact if `tee` is used: `/var/lib/xymon/install-cmake-legacy.log`.
- Staging stamp files created by CMake installs: `/var/lib/xymon/cgi-bin/.stamp`, `/var/lib/xymon/cgi-secure/.stamp`.

Status
------
GLOBAL STATUS
- [x] Infrastructure: OK
- [x] Legacy web: OK
- [x] Ownership gating: OK
- [x] Full legacy parity: ACCEPTED (exceptions documented)
