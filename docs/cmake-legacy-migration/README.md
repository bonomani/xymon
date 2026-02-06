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
- legacy.linux.server.ref: versioned legacy reference list used by CI (Linux server)
- legacy.linux.client.ref: legacy reference list (Linux client ct-server)
- legacy.linux.localclient.ref: legacy reference list (Linux client ct-client)
- legacy.freebsd.ref: BSD legacy server reference list (FreeBSD)
- legacy.openbsd.ref: BSD legacy server reference list (OpenBSD)
- legacy.netbsd.ref: BSD legacy server reference list (NetBSD)
Keyfile checksums follow the same naming scheme:
- legacy.linux.server.keyfiles.sha256
- legacy.linux.client.keyfiles.sha256
- legacy.linux.localclient.keyfiles.sha256

Guidelines
----------
- Keep one source of truth per topic.
- Update `40-STATUS.md` after any significant change or validation run.
- Append run details to `STATUS-HISTORY.md` when needed.
- Track changes in `STATUS-HISTORY.md`.

Generating `legacy.linux.server.ref`
-----------------------
Use this only when legacy Makefiles change.

```sh
sudo DESTDIR=/tmp/legacy-ref make install
find /tmp/var/lib/xymon -printf '/var/lib/xymon/%P\n' \
  | sed 's|/var/lib/xymon/$|/var/lib/xymon|' \
  | sort > docs/cmake-legacy-migration/legacy.linux.server.ref
```

BSD references follow the same procedure, replacing the output path:
- `legacy.freebsd.ref`
- `legacy.openbsd.ref`
- `legacy.netbsd.ref`

CI workflows
------------
Legacy references are generated via the per-OS workflows:
- `.github/workflows/legacy-reference-linux.yml`
- `.github/workflows/legacy-reference-freebsd.yml`
- `.github/workflows/legacy-reference-openbsd.yml`
- `.github/workflows/legacy-reference-netbsd.yml`
