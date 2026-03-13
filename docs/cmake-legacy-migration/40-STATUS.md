Reference Migration Status Summary
===============================

Current State
-------------
Reference mode validation remains stable on Linux/BSD flows, and workflow
coverage now includes OpenBSD, NetBSD, and macOS via
`ref-validate-select.yml` family selection. Recent
portability fixes addressed macOS runner constraints (Bash 3.2 and tool path
differences) in dependency/refs scripts and CMake install hooks.

Legacy OS Scope Decision
------------------------
- Implemented migration families remain Linux, FreeBSD, NetBSD, OpenBSD, and
  macOS.
- `AIX` and `SunOS` / `Solaris` remain deferred: the legacy tree on
  `origin/main` still has native build metadata for them, but this repo does
  not currently have a native runner, container, or `cross-platform-actions`
  path to validate them in CI.
- `HP-UX` and `GNU` / Hurd remain out of scope under the current CI runtime
  model for the same reason.
- Obsolete legacy-only targets remain unimplemented and not planned:
  `IRIX`, `OSF1` / Tru64, `SCO_SV`, `GNU_kFreeBSD`, and the `OSX` alias
  makefile.

What Changed Last
-----------------
- Added OpenBSD, NetBSD, and macOS family coverage in reference validation.
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
- macOS family in `ref-validate-select.yml` still needs a full matrix rerun to confirm end-to-end parity outputs.
- `HTTPDGID` mapping for `rep` and `snap` must remain conditional to avoid "invalid group" errors.
- Deferred legacy Unix families (`AIX`, `SunOS` / `Solaris`) have no CI-backed
  parity signal until dedicated external infrastructure is introduced.

Last Validated
--------------
- Date: 2026-02-12
- Environment: local smoke validation and CMake configure checks for macOS compatibility fixes; see `STATUS-HISTORY.md` for detailed run notes.
