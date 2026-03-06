Reference Docs Naming Convention
=============================

This folder groups the reference migration documents in a predictable order so
both humans and tooling can find the right reference quickly.

Start here: `00-INDEX.md`.

Naming Scheme
-------------
- 00-INDEX.md: entry point and routing
- 10-PLAN.md: acceptance criteria and checklist
- 20-RUNBOOK.md: step-by-step validation procedure
- 30-REFERENCE.md: canonical reference install contract
- 40-STATUS.md: current status snapshot
- STATUS-HISTORY.md: detailed run history and notes
- refs/make_<os>/<variant>/inventory.tsv: canonical inventory used to derive ref/perms/symlinks
- refs/make_<os>/<variant>/keyfiles.sha256: corresponding keyfile checksums
- refs/make_<os>/<variant>/meta/config.h: captured legacy config header
- refs/make_<os>/<variant>/meta/config.defines: normalized config macro list

During CI runs, refs are staged under `/tmp/xymon-refs/<build>.<os>.<variant>/` before sync.

Guidelines
----------
- Keep one source of truth per topic.
- Update `40-STATUS.md` after any significant change or validation run.
- Append run details to `STATUS-HISTORY.md` when needed.
- Track changes in `STATUS-HISTORY.md`.
- Treat all `refs/make_<os>/<variant>/*` files as read-only. Do not edit them by hand.
- References are generated via `.github/workflows/pipeline-select-run-lanes.yml` (selector)
  and `.github/workflows/pipeline-run-lane-reusable.yml` (lane execution).
- `ci/bootstrap-install.sh` performs configure/build/install orchestration per lane.
- `.github/workflows/pipeline-sync-artifacts.yml` collects artifacts and writes them to
  `origin/ci/references-update` and `origin/ci/references-update-archive`.
- Manually merge `origin/ci/references-update` into your code branch after reviewing the changes.

Generating `refs/make_linux/server/inventory.tsv`
-----------------------
Use this only when legacy Makefiles change.
Follow the exact commands in `20-RUNBOOK.md`.

BSD references follow the same procedure, replacing the output path:
- `refs/make_freebsd/server/inventory.tsv`
- `refs/make_openbsd/server/inventory.tsv`
- `refs/make_netbsd/server/inventory.tsv`

CI workflows
------------
Legacy references are generated via:
- `.github/workflows/pipeline-select-run-lanes.yml`
- `.github/workflows/pipeline-run-lane-reusable.yml`
- `.github/workflows/pipeline-analyze-selector-run.yml` (run analysis/reporting)
