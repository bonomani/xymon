# tests/python/ — functional network harness (pytest)

A Python/pytest harness that sits alongside the bash regression suite
(`tests/`, see `../README.md`). Bash and Python are both first-class here;
each is used where it is stronger. This harness exists for **functional
network scenarios** that need byte-level socket control, timeouts, and retries
— things that are awkward in shell. Its first scenario is the xymond message
round-trip.

## What it covers

`test_xymond_roundtrip.py` starts a private `xymond`, submits a `status`
message, and reads it back via `xymondboard` over a raw TCP socket (never the
`xymon` client binary, so it stays portable to any OS with python3 — Linux,
macOS, *BSD).

## Running

Directly:

    pip install -r tests/python/requirements.txt
    pytest tests/python/ -v

By default it resolves the in-tree binary `xymond/xymond`; point elsewhere with
`XYMOND_BIN=/path/to/xymond`. If xymond is not built, the tests **skip**.

Through the unified suite (covers bash + this harness in one run):

    ./tests/testsuite        # discovers tests/integration/xymond-roundtrip.sh,
                             # which runs this pytest harness and maps its result

## Isolation guarantees

- **Dynamic port.** A free port is discovered (`bind(0)`) and passed explicitly
  to `--listen`, so a running production xymond on 1984 is never touched.
- **Private XYMONHOME.** A throwaway tmp tree with its own `hosts.cfg`; nothing
  under the real install is read or written.
- **Zero zombies.** The daemon is always reaped in a `finally` (terminate then
  kill), even on test failure or interruption.
- **Fail fast.** If xymond never opens its listener, startup aborts within 5s
  rather than hanging.

## Conventions

- One connection per protocol message (mirrors real clients).
- Helpers live flat in `xymon_proto.py` (imported directly by the tests).
- New functional-network scenarios go here as `test_*.py`; shell-level or
  build/packaging invariants stay in the bash areas under `tests/`.
