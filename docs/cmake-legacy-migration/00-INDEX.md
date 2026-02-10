Reference Migration Docs Index
===========================

Purpose
-------
This folder contains the authoritative documents for the reference staging
migration. Use the guide below to pick the right entry point.

Decision Tree
-------------
- I need the rules and acceptance criteria: `10-PLAN.md`
- I need the exact steps and commands: `20-RUNBOOK.md`
- I need the immutable reference contract: `30-REFERENCE.md`
- I need the latest status summary: `40-STATUS.md`
- I need detailed history or run notes: `STATUS-HISTORY.md`

Quick Start
-----------
- Plan/checklist: `10-PLAN.md`
- Run steps: `20-RUNBOOK.md`
- Reference install contract: `30-REFERENCE.md`
- Latest status: `40-STATUS.md`

Quick Commands
--------------
```sh
cmake -S . -B build-cmake -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ \
  -DLEGACY_DESTDIR=/tmp/cmake-ref-root \
  -DXYMON_VARIANT=all
LEGACY_DESTDIR=/tmp/cmake-ref-root cmake --build build-cmake \
  --target install-legacy-dirs install-legacy-files
sudo DESTDIR=/tmp/xymon-stage make install
```

Contents
--------
- README.md: naming convention and usage
- 10-PLAN.md: validation checklist and acceptance criteria
- 20-RUNBOOK.md: step-by-step commands and validation procedure
- 30-REFERENCE.md: canonical reference install layout and constraints
- 40-STATUS.md: condensed progress and current status
- STATUS-HISTORY.md: detailed run notes and historical context
- refs/${BUILD_TOOL}.${OS}.${VARIANT}/ref: versioned reference list used by CI (per host variant)
- refs/${BUILD_TOOL}.${OS}.${VARIANT}/keyfiles.sha256: corresponding keyfile checksums
