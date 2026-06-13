# PLAN — xymond functional network test + Python harness in tests/

Branch: `feature/tests-xymond-roundtrip` (based on `origin/feat/tests-bootstrap`, PR #101)
Target PR: base = `feat/tests-bootstrap` (stacked on #101), title
`tests: xymond network round-trip + python harness alongside the bash suite`

## Goal

1. Add an end-to-end functional test: start `xymond`, send it a `status` over a
   raw TCP socket, read it back via `xymondboard`, and verify the round-trip.
2. Establish **Python (pytest) as a first-class capability alongside Bash** in a
   follow-up PR, without modifying PR #101 or breaking its runner's contract.
   Each language is used where it is stronger (see "Bash vs Python policy").

## Context / decisions (validated with the user + code reading)

- **Base = `feat/tests-bootstrap` (PR #101), not `main`.** #101 is open and
  already creates `tests/` (runner `tests/testsuite`, `tests/lib/assert.sh`,
  per-domain dirs, `tests/integration/` reserved for e2e). We stack on top → a
  real follow-up, zero collision, reusing the scaffolding. Rebase onto `main`
  once #101 merges.
- **#101's policy stays unchanged in #101.** The "Why no framework" text
  correctly describes that PR's initial scope. This follow-up PR then extends the
  policy to allow pytest only for the network functional scenarios that justify
  it, and updates `tests/README.md` in its own diff. So there is no contradiction
  to fix in #101.
- **Target OS = broad POSIX**: Linux, macOS, *BSD (FreeBSD/NetBSD/OpenBSD),
  potentially more exotic. **Not Windows for the server**: `xymond` is a POSIX
  daemon (`fork`, BSD sockets) — confirmed, no Windows server build.
- **Bash AND Python coexist.** `tests/testsuite` discovers only executable
  `*.sh`; the `*.py` files are invisible to it → pytest is added in this
  follow-up PR without changing the runner's discovery. A `.sh` *bridge* connects
  pytest to the single runner.

## Bash vs Python policy (which for what)

- **Bash** (`tests/<domain>/*.sh`, #101 contract): shell invariants, shipped
  files, packaging artefacts, build/configure probes, build-related checks. Zero
  dependencies, runs anywhere bash + the tool under test exist.
- **Python** (`tests/python/...`, pytest): fine-grained network protocol (bytes,
  timeouts, retries), structured parsing of replies (`xymondboard`), portable
  process lifecycle. The xymond round-trip belongs here — it's what Python does
  better.
- **Explicit limit**: pytest is not the new default for all tests. Its use stays
  reserved for scenarios where network/process control gives a concrete benefit;
  existing shell tests are unchanged.

## Corrections to the initial spec (from reading the xymond code)

1. **Port: NO "port 0 → ephemeral port" on the xymond side.** `xymond.c:5493`:
   `listenport==0` falls back to `XYMONDPORT` then `1984`. So the harness asks
   the kernel for a free port with `bind(("127.0.0.1", 0))`, closes that socket,
   then passes the obtained port to `--listen=127.0.0.1:PORT`. Because that close
   creates a small TOCTOU race, full startup is retried at most 5 times on the
   xymond message `Cannot bind to listen socket`, within a global deadline.
2. **Ghost host dropped silently + split on the LAST dot.** `xymond.c:1226` and
   `2097`: `strrchr(hosttest, '.')` → `localhost.testcpu` gives host=`localhost`,
   test=`testcpu`. So `hosts.cfg` must contain the **host `localhost`**, not
   `localhost.testcpu`. → `etc/hosts.cfg` = `127.0.0.1 localhost`, passed via
   `--hosts=FILE` (xymond.c:5302). The `testcpu` test is auto-created by the
   `status`. Default ghost handling (GH_LOG) is enough since the host is known by
   name; `--ghosts=allow` (loadhosts.c:409 returns the name without hosts.cfg) is
   a simple fallback.
3. **`psutil` removed**: `subprocess.Popen` + `terminate()`/`kill()` are enough,
   cross-OS, with no native dependency.
4. **CI**: no workflow or parallel job. The bridge is discovered by the
   `testsuite` already run in `build.yml`'s server job; only `python3-pytest` is
   added to that job's dependencies.

### Facts verified in the code (complementary pass)

- **No daemonization by default**: `daemonize=0` (xymond.c:5237). Do NOT pass
  `--daemon` → xymond stays in the foreground, `Popen` tracks the real PID.
- **Single-process model**: connections are served in a single event loop; the
  only `fork()` is the periodic checkpoint child (xymond.c:5748,
  `save_checkpoint(); exit(0)`) which only fires after `checkpointinterval` — not
  during a short test. → killing one PID is clean, zero zombies (Criterion 3)
  achievable as-is.
- **No sender ACL by default**: `statussenders` and `wwwsenders` are NULL
  (xymond.c:185), and `oksender(NULL,…)` returns 1 (ipaccess.c:66). → both the
  `status` submit AND the `xymondboard` read are accepted from 127.0.0.1. Do NOT
  pass `--status-senders` / `--www-senders`.
- **`xymondboard` processed in-process on the same listener** (xymond.c:4026) →
  round-trip over a single port/socket confirmed.
- **Readiness checkable by protocol**: the `ping` command answers
  `xymond VERSION\n` (`xymond.c:4421`). Startup polling must check this reply, not
  merely that some process accepts a connection on the candidate port.
- **Board field**: the valid field for the text is **`line1`** (the default list
  in xymond.c ends with `…,cookie,line1`), not `msg`. Query =
  `xymondboard host=localhost fields=testname,color,line1`. Fields are separated
  by `|`, so the test can verify a full structured line.
- **`line1` keeps the color word** (verified at runtime): a
  `status localhost.testcpu green Round-trip OK` produces
  `testcpu|green|green Round-trip OK` — xymond stores the message body as-is
  (color included), it does not strip it. So the exact assertion is on
  `green Round-trip OK`, not `Round-trip OK`. The synthetic `info` and `trends`
  rows (empty line1) also appear for the host → a plain `"green" in board` would
  match the wrong row; hence the structured parsing.

## Decisions from the plan review

1. **No false-green pytest.** Absent prerequisites (`python3`, pytest, in-tree
   xymond binary not built) stay skips decided by the bridge before launching
   pytest. An empty collection (`pytest` rc=5) is an error, not a skip. In bridge
   mode, a session where every test is skipped is also an error; a small pytest
   hook, enabled by `XYMON_TESTSUITE_BRIDGE=1`, forces a non-zero rc in that case.
   Only rc=0 means PASS after a real run.
2. **Explicit override = assertion.** In a direct pytest run, an `XYMOND_BIN`
   explicitly set but absent/non-executable must fail, like `require_bin`. Only an
   in-tree binary absent without an override may produce a skip.
3. **Structured assertions.** The test parses each `testname|color|line1` line and
   requires exactly `testcpu|green|green Round-trip OK`; two substrings from
   different lines do not suffice.
4. **Real negative ghost test.** The scenario first submits
   `status ghost.example.testcpu red Ghost must be dropped`, then verifies that
   `ghost.example` does not appear in the board. A plain query of an initially
   empty board does not test ghost rejection.
5. **Precisely worded timeout.** Readiness uses a global 5-second deadline,
   collision retries included. Cleanup is bounded separately (`terminate`, max
   wait, then `kill`); the criterion no longer claims the whole fixture, teardown
   included, finishes in under 5 seconds.
6. **Honest portability.** This PR's mandatory CI stays Linux. macOS and the BSDs
   are design targets (Python stdlib + POSIX sockets), not a "green" criterion
   verified by this PR.

## Delivered tree

```
tests/                              # scaffolding inherited from PR #101
├── README.md                       # policy extended in THIS follow-up PR
├── lib/assert.sh                   # reused as-is
├── testsuite                       # single runner — unchanged
├── integration/
│   └── xymond-roundtrip.sh         # +x BRIDGE: runs pytest, maps rc -> 0/77/fail
└── python/                         # NEW Python harness (invisible to testsuite)
    ├── requirements.txt            # pytest>=5.0 (real floor: ExitCode; NO psutil)
    ├── conftest.py                 # fixtures, lifecycle, retries, bridge contract
    ├── xymon_proto.py              # send/query/ping + board parsing
    └── test_xymond_roundtrip.py    # round-trip scenario
```

Layout note: the #101 suite is organized by domain, not by language.
`tests/python/` is a **tooling area** (the harness), not a domain; the *test*
itself is attached to its domain via the bridge in `tests/integration/`. This
split is kept for this PR; it can be revisited if several domains adopt Python.

## Bridge `tests/integration/xymond-roundtrip.sh`

`#!/usr/bin/env bash` + `set -euo pipefail`. #101 contract (0/77/fail):
- python3 or pytest absent, or in-tree xymond binary not built without an override
  → `exit 77` (explicit skip).
- `require_bin XYMOND ...` keeps the contract: in-tree default absent → skip,
  explicit override invalid → fail.
- otherwise export `XYMON_TESTSUITE_BRIDGE=1`, then `pytest tests/python -q`.
- maps: 0→0; 5 (nothing collected), "all skipped", and any other rc → fail.
So `./tests/testsuite` and `make test` also cover the Python via a single entry.

## conftest.py (fixtures)

- `xymond_bin` (session): locates `xymond` (local build / env `XYMOND_BIN`);
  default absent → `pytest.skip`, explicit override invalid → failure.
- `xymon_home` (function): `tmp_path_factory`, creates `etc/ tmp/ data/`, writes
  `etc/hosts.cfg` = `127.0.0.1 localhost # noconn`, sets `XYMONHOME`, `XYMONTMP`,
  `XYMONVAR`. Function-scoped so two sequential xymond instances never share a
  board, data dir, or pidfile.
- `_free_port()`: asks the kernel for an ephemeral IPv4 port via `bind(0)`.
- `xymond_server` (function): launches
  `xymond --listen=127.0.0.1:PORT --hosts=<tmp>` (NO `--daemon`, NO
  `--status-senders`/`--www-senders`); waits for a `xymond ...` reply to `ping`,
  within a global 5 s deadline. If xymond exits with `Cannot bind to listen
  socket`, it picks a new port and retries (max 5 launches). Any other early exit
  fails immediately with the log. In `finally`, `terminate()`→`wait(3)`→`kill()`
  (Criterion 3, zero zombies).
- Session hook: only when `XYMON_TESTSUITE_BRIDGE=1`, turns a fully-skipped
  session into a failure so the bridge cannot produce a false PASS.

## Scenario (test_xymond_roundtrip.py)

1. Connect to the fixture's port.
2. `status localhost.testcpu green Round-trip OK\n`.
3. Conditional polling of the board, no fixed sleep.
4. `xymondboard host=localhost fields=testname,color,line1\n`.
5. Parse the `|` lines and assert exactly on
   `("testcpu", "green", "green Round-trip OK")`.
6. Negative test: submit a status for `ghost.example.testcpu`, then verify that
   this host does not appear in `xymondboard host=ghost.example`.

## CI — wired by discovery, NO new job

`build.yml` already runs `./tests/testsuite` after the build (server leg, l.108).
The bridge `tests/integration/xymond-roundtrip.sh` is therefore **wired in
automatically** — no job to add. Only addition needed: `python3-pytest` in the
apt list (done), otherwise the bridge skips (77) instead of running the test.

- `build.yml` stays ubuntu-only; we do NOT touch the matrix. Extending it to
  macOS/BSD is a separate CI effort (the project already has BSD dep lanes). The
  harness avoids Linux-only APIs to stay runnable on macOS/*BSD.
- `tests.yml` (suite without build): xymond not built → `require_bin` skip →
  bridge skip. No change required.

## Acceptance criteria

- [ ] C1 — PR #101 stays unchanged; this follow-up PR documents the pytest
  extension itself in `tests/README.md`.
- [ ] C2 — xymond readiness proven by `ping` within a global 5 s deadline,
  collision retries included; any startup error exposes the log.
- [ ] C3 — Zero residual `xymond` after the suite (try/finally + kill).
- [ ] C4 — Green in the existing Linux server job; no Linux-specific mechanism in
  the Python harness.
- [ ] C5 — `./tests/testsuite` runs the whole Bash + Python suite; an empty
  collection or a fully-skipped Python session cannot produce PASS.
- [ ] C6 — Round-trip validated on the exact structured line
  `testcpu|green|green Round-trip OK`, and ghost rejection validated after a real
  submission.
- [ ] C7 — An explicit invalid `XYMOND_BIN` fails both via the bridge and in a
  direct pytest run.

## Implementation steps

1. [x] Prototype: `xymond` starts/binds with a minimal env (`XYMONHOME` +
   `--hosts` + `--listen`); non-fatal PID file warning, suppressed via
   `--pidfile`. Real `status`→`xymondboard` round-trip validated on the binary
   (green + text OK).
2. [x] `tests/python/` prototype: requirements, conftest, xymon_proto, test_*.
3. [x] Local prototype: `pytest tests/python/` → 2 passed.
4. [x] Bridge prototype `tests/integration/xymond-roundtrip.sh`; `./tests/testsuite`
   → 11 passed / 1 skip / 0 fail, integration discovered, no regression.
5. [x] Initial CI wiring: `python3-pytest` added to `build.yml` (bridge discovered
   by the `testsuite` already run in CI; no new job).
6. [x] Initial documentation in `tests/python/README.md`.
7. [x] Apply the review decisions: bind retry + `ping` readiness, structured
   parsing, real ghost submission, override contract, "all skipped" protection.
   Verified at runtime: direct pytest (2 passed), bridge (rc=0), invalid override
   → fail both direct (rc=1) AND via the bridge (require_bin, rc=1), all-skipped
   session under `XYMON_TESTSUITE_BRIDGE=1` → rc≠0, `./tests/testsuite` → 11
   passed / 1 skip (pre-existing xymonclient-linux) / 0 fail.
8. [x] Update `tests/README.md` in this follow-up PR to document the pytest scope
   ("The one carve-out" section), without modifying PR #101.
9. [x] Replay direct pytest, standalone bridge, and `./tests/testsuite`, including
   the negative cases: invalid override (direct + bridge), all-skipped under the
   bridge flag. (Real bind collision not forced — retry path verified by reading
   + the substring `Cannot bind to listen socket` confirmed at xymond.c:5535.)
10. [ ] Amend the existing commit, then open the PR with base
    `feat/tests-bootstrap` (no Co-Authored-By trailer).

## Corrections from the branch analysis

- **Honest pytest floor**: `requirements.txt` goes from `>=8.0.0` to `>=5.0` (the
  only real need is `pytest.ExitCode`, which landed in 5.0). CI installs the
  distro's `python3-pytest` (7.x on Ubuntu) and the bridge only does
  `import pytest` (never `pip install -r`) → a floor above the distro version was
  both unenforced and contradicted by the lane that runs it.
- **CI coverage erosion documented**: a comment in `build.yml` next to
  `python3-pytest` — if that package disappears, the bridge *skips* (77) instead
  of failing, and a lone skip is invisible among the passing server tests; the
  round-trip would silently stop running in CI. Keep it.
- **Shared XYMONHOME trap removed**: `xymon_home` is back to *function* scope (no
  more board/data/pidfile shared between two sequential xymond instances).
- **#4 bind retry untested — deliberate decision**: no monkeypatch test to force
  the collision. The code is safe (degrades to a clean hard-fail if the message
  changes); a test holding a port + monkeypatching `_free_port` would risk the
  flakiness the suite forbids. Kept as documented defensive code.

## Out of scope

- Server on Windows (POSIX-only). Testing the `xymon` client binary.
- xymond_channel/_history/_rrd: we test `xymond` alone (enough for the round-trip).
