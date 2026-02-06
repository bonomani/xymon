Legacy Migration Docs Index
===========================

Purpose
-------
This folder contains the authoritative documents for the legacy CMake
migration. Use the guide below to pick the right entry point.

Decision Tree
-------------
- I need the rules and acceptance criteria: `10-PLAN.md`
- I need the exact steps and commands: `20-RUNBOOK.md`
- I need the immutable legacy contract: `30-REFERENCE.md`
- I need the latest status summary: `40-STATUS.md`
- I need detailed history or run notes: `STATUS-HISTORY.md`

Quick Start
-----------
- Plan/checklist: `10-PLAN.md`
- Run steps: `20-RUNBOOK.md`
- Legacy install contract: `30-REFERENCE.md`
- Latest status: `40-STATUS.md`

Quick Commands
--------------
```sh
cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ \
  -DLEGACY_DESTDIR=/tmp/cmake-ref-root \
  -DXYMON_VARIANT=all
LEGACY_DESTDIR=/tmp/cmake-ref-root cmake --build build-cmake \
  --target install-legacy-dirs install-legacy-files
sudo DESTDIR=/tmp/legacy-ref make install
```

Contents
--------
- README.md: naming convention and usage
- 10-PLAN.md: validation checklist and acceptance criteria
- 20-RUNBOOK.md: step-by-step commands and validation procedure
- 30-REFERENCE.md: canonical legacy install layout and constraints
- 40-STATUS.md: condensed progress and current status
- STATUS-HISTORY.md: detailed run notes and historical context
- legacy.linux.server.ref: versioned legacy reference list used by CI (Linux server)
- legacy.linux.client.ref: legacy reference list (Linux client ct-server)
- legacy.linux.localclient.ref: legacy reference list (Linux client ct-client)
- legacy.freebsd.ref: BSD legacy server reference (FreeBSD)
- legacy.openbsd.ref: BSD legacy server reference (OpenBSD)
- legacy.netbsd.ref: BSD legacy server reference (NetBSD)
