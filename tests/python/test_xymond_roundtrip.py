# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/python/test_xymond_roundtrip.py -- end-to-end network round-trip.
#
# Submits a `status` to a private xymond instance and reads it back via
# `xymondboard`, over raw TCP. This exercises the daemon's core message path
# (receive -> in-memory board -> query), which no other test covers.

import time

from xymon_proto import parse_board, query_board, submit_status

# testname pins the assertion to the row we created; without it a stray "green"
# and a stray "Round-trip OK" from two different rows could pass a substring
# check while the actual row was wrong (Criterion 6 / decision 3).
FIELDS = "testname,color,line1"
NCOLS = 3


def _rows_until(host, port, hostfilter, match, attempts=20, delay=0.2):
    """Poll the board until a parsed row satisfies `match` -- the board updates a
    moment after the status is received, so a single read can race ahead of it.
    Returns (matched_row_or_None, all_rows_from_last_read)."""
    rows = []
    for _ in range(attempts):
        rows = parse_board(query_board(host, port, hostfilter, FIELDS), NCOLS)
        for row in rows:
            if match(row):
                return row, rows
        time.sleep(delay)
    return None, rows


def test_status_roundtrip(xymond_server):
    host, port = xymond_server
    submit_status(host, port, "localhost.testcpu", "green", "Round-trip OK")

    row, rows = _rows_until(
        host, port, "localhost", lambda r: r[0] == "testcpu"
    )
    assert row is not None, f"testcpu row never appeared; board rows:\n{rows!r}"
    # Exact structured round-trip: one whole row, not three substrings. line1 is
    # the first line of the stored status message, which xymond keeps verbatim
    # *including* the color word -- so "green Round-trip OK", not "Round-trip OK".
    assert row == ["testcpu", "green", "green Round-trip OK"], (
        f"round-trip row mismatch: {row!r}\nfull board:\n{rows!r}"
    )


def test_ghost_status_is_dropped(xymond_server):
    host, port = xymond_server
    # Real negative test: actually submit a status for a host absent from
    # hosts.cfg, then prove xymond dropped it (default ghosthandling=GH_LOG).
    submit_status(host, port, "ghost.example.testcpu", "red", "Ghost must be dropped")

    # Give xymond at least as long as the positive path would take to register a
    # status, so "absent" means "rejected", not "not yet processed".
    matched, rows = _rows_until(
        host, port, "ghost.example", lambda r: r[0] == "testcpu", attempts=10
    )
    assert matched is None, f"ghost host was accepted into the board:\n{rows!r}"
    assert rows == [], f"unexpected rows for ghost host:\n{rows!r}"
