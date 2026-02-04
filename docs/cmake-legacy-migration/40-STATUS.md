Legacy Migration Status Summary
===============================

Current State
-------------
Legacy mode validation is complete and parity is accepted, with a documented
exception list. OFF mode is deterministic without chown/chgrp, and ON mode
under sudo restores `xymonping` to `4755 root:bc`.

What Changed Last
-----------------
- Added `LEGACY_APPLY_OWNERSHIP` to control chown/chgrp behavior.
- `install-legacy-files` now uses `cmake --install` for non-web components.
- Post-install hook restores `xymonping` permissions and ownership.

Known Exceptions
----------------
- Extra helper binaries present in CMake tree: `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`.
- Optional staging log artifact if `tee` is used: `/var/lib/xymon/install-cmake-legacy.log`.

Open Risks
----------
- `HTTPDGID` mapping for `rep` and `snap` must remain conditional to avoid "invalid group" errors.

Last Validated
--------------
- Date: 2026-02-04
- Environment: see `STATUS-HISTORY.md` for detailed run notes.
