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
- legacy.ref: versioned legacy reference list used by CI
- legacy.freebsd.ref: BSD legacy reference list (FreeBSD)
- legacy.openbsd.ref: BSD legacy reference list (OpenBSD)
- legacy.netbsd.ref: BSD legacy reference list (NetBSD)

Guidelines
----------
- Keep one source of truth per topic.
- Update `40-STATUS.md` after any significant change or validation run.
- Append run details to `STATUS-HISTORY.md` when needed.
- Track changes in `STATUS-HISTORY.md`.

Generating `legacy.ref`
-----------------------
Use this only when legacy Makefiles change.

```sh
sudo DESTDIR=/tmp/legacy-ref make install
find /tmp/var/lib/xymon -printf '/var/lib/xymon/%P\n' \
  | sed 's|/var/lib/xymon/$|/var/lib/xymon|' \
  | sort > docs/cmake-legacy-migration/legacy.ref
```

BSD references follow the same procedure, replacing the output path:
- `legacy.freebsd.ref`
- `legacy.openbsd.ref`
- `legacy.netbsd.ref`
