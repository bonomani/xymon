Reference Migration Status Summary
===============================

Current State
-------------
Reference mode validation remains stable on Linux/BSD flows, and workflow
coverage now includes OpenBSD, NetBSD, and macOS (`ref-valid-*`). Recent
portability fixes addressed macOS runner constraints (Bash 3.2 and tool path
differences) in dependency/refs scripts and CMake install hooks.

What Changed Last
-----------------
- Added `ref-valid-openbsd.yml`, `ref-valid-netbsd.yml`, and `ref-valid-macos.yml`.
- Made CI shell scripts Bash 3 compatible (removed `mapfile`, `${var^^}`, and associative arrays in macOS execution paths).
- Replaced hardcoded install command paths (`/bin/*`, `/usr/bin/find`) with portable command resolution via `PATH`.
- Added macOS bootstrap support and explicit `XYMONUSER` propagation in CMake configure.
- Corrected `HAVE_RPCENT_H` config generation to avoid false-positive `#ifdef` branches.

Known Exceptions
----------------
- Extra helper binaries present in CMake tree: `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`.
- Optional staging log artifact if `tee` is used: `/var/lib/xymon/install-cmake-reference.log`.

Open Risks
----------
- macOS `ref-valid-macos.yml` still needs a full matrix rerun to confirm end-to-end parity outputs.
- `HTTPDGID` mapping for `rep` and `snap` must remain conditional to avoid "invalid group" errors.

Last Validated
--------------
- Date: 2026-02-12
- Environment: local smoke validation and CMake configure checks for macOS compatibility fixes; see `STATUS-HISTORY.md` for detailed run notes.
