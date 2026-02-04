Legacy Docs Naming Convention
=============================

This folder groups the legacy migration documents in a predictable order so
both humans and tooling can find the right reference quickly.

Start here: `00-INDEX.md`.

Naming Scheme
-------------
- 00-INDEX.md: entry point and routing
- 10-PLAN.md: acceptance criteria and checklist
- 20-RUNBOOK.md: step-by-step validation procedure
- 30-REFERENCE.md: canonical legacy install contract
- 40-STATUS.md: current status snapshot
- STATUS-HISTORY.md: detailed run history and notes

Guidelines
----------
- Keep one source of truth per topic.
- Update `40-STATUS.md` after any significant change or validation run.
- Append run details to `STATUS-HISTORY.md` when needed.
- Track changes in `STATUS-HISTORY.md`.
