# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/python/xymon_proto.py -- minimal Xymon wire-protocol helpers.
#
# Talks to xymond over a raw TCP socket, deliberately NOT through the xymon
# client binary: the protocol is line-oriented text, so the stdlib socket is
# enough and the harness stays portable to any OS with python3 (Linux, macOS,
# *BSD). One connection per message mirrors how real clients behave -- xymond
# answers a query and closes.

import socket


def send(host, port, payload, read=False, timeout=3.0):
    """Open a connection, send payload, optionally read the full reply.

    For queries (read=True) we half-close our write side so xymond sees EOF and
    flushes its response, then drain until the peer closes. Returns the decoded
    reply, or None for fire-and-forget submissions.
    """
    data = payload if isinstance(payload, bytes) else payload.encode()
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(data)
        if not read:
            return None
        s.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks).decode(errors="replace")


def submit_status(host, port, machine, color, text):
    """Submit a `status MACHINE.TEST COLOR text` message (fire-and-forget)."""
    send(host, port, f"status {machine} {color} {text}\n")


def query_board(host, port, hostfilter, fields):
    """Issue a `xymondboard host=... fields=...` query and return the reply."""
    return send(host, port, f"xymondboard host={hostfilter} fields={fields}\n", read=True)


def parse_board(reply, ncols):
    """Split an xymondboard reply into rows of exactly `ncols` pipe-separated
    fields. Blank lines and short/garbled lines are dropped so a caller can make
    an exact-tuple assertion on a real data row rather than substring-matching
    across the whole blob."""
    rows = []
    for line in reply.splitlines():
        if not line:
            continue
        parts = line.split("|")
        if len(parts) == ncols:
            rows.append(parts)
    return rows


def ping(host, port, timeout=0.5):
    """Send `ping` and return the reply, or "" if the connection is refused or
    times out. xymond answers `xymond <version>\\n`, which is what the readiness
    probe checks -- proving the daemon is actually serving, not merely that the
    port is open."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.sendall(b"ping\n")
            s.shutdown(socket.SHUT_WR)
            try:
                return s.recv(256).decode(errors="replace")
            except socket.timeout:
                return ""
    except OSError:
        return ""
