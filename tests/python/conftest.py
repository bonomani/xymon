# SPDX-License-Identifier: GPL-2.0-or-later
#
# tests/python/conftest.py -- xymond lifecycle fixtures for the functional
# network harness. Universal (Linux/macOS/*BSD): only python3 + a built xymond.
#
# Design notes (validated against the xymond source, see docs/PLAN.md):
#  * Free port via bind(0) discovery, then passed explicitly as --listen=IP:PORT.
#    xymond itself treats listenport 0 as "fall back to 1984", NOT "pick a free
#    port" (xymond.c:5493), so the discovery has to happen here, not in the
#    daemon. Closing the probe socket before xymond binds is a TOCTOU window, so
#    a "Cannot bind to listen socket" exit is retried on a fresh port.
#  * Readiness is proven by the `ping` handshake (xymond answers `xymond <ver>`,
#    xymond.c:4425), not a bare TCP connect -- a connect can succeed before the
#    daemon is actually serving requests.
#  * hosts.cfg must name the host as `localhost` (xymond splits HOST.TEST on the
#    LAST dot via strrchr, xymond.c:1226), and the test name `testcpu` is
#    auto-created by the status submit.
#  * No --daemon: xymond stays foreground so the Popen handle tracks the real
#    PID. Connections are served in a single event loop (no per-connection fork),
#    so terminate()/kill() of that one PID leaves nothing behind (zero zombies).
#  * No --status-senders/--www-senders: both ACLs default to "allow all"
#    (oksender(NULL,...)==1, ipaccess.c:66), so submit and query from 127.0.0.1
#    are accepted without extra flags.

import os
import pathlib
import socket
import subprocess
import time

import pytest

from xymon_proto import ping

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
START_TIMEOUT = 5.0  # Criterion 2: global readiness deadline, retries included.
MAX_LAUNCHES = 5     # bind() TOCTOU retries within START_TIMEOUT.


def _resolve_xymond():
    """Return (path, is_override). An explicit XYMOND_BIN is an assertion that
    the binary exists there; the in-tree default is best-effort."""
    override = os.environ.get("XYMOND_BIN")
    if override:
        return pathlib.Path(override), True
    return REPO_ROOT / "xymond" / "xymond", False


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _terminate(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)


def _drain(proc):
    """Read whatever xymond wrote. Only call after the process has exited, so the
    pipe is at EOF and the read returns promptly."""
    try:
        return proc.stdout.read() if proc.stdout else ""
    except (OSError, ValueError):
        return ""


def _await_ready(proc, host, port, deadline):
    """Poll until xymond answers `ping`. Returns (ready, early_exit_output).
    `ready` True means it is serving; otherwise early_exit_output holds the
    captured log if the process died (used to decide retry vs. hard fail)."""
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False, _drain(proc)
        if ping(host, port).startswith("xymond "):
            return True, ""
        time.sleep(0.1)
    return False, None  # still alive but unresponsive within the deadline


@pytest.fixture(scope="session")
def xymond_bin():
    path, is_override = _resolve_xymond()
    if path.is_file() and os.access(path, os.X_OK):
        return str(path)
    if is_override:
        # Mirror require_bin: an explicit override pointing at nothing is a
        # broken build/layout, not a reason to skip green (Criterion 7).
        pytest.fail(
            f"XYMOND_BIN set to '{path}' but no executable is there "
            "-- broken build, not a skip",
            pytrace=False,
        )
    pytest.skip("xymond binary not built (set XYMOND_BIN or build xymond/xymond)")


@pytest.fixture
def xymon_home(tmp_path_factory):
    # Function-scoped on purpose: each test gets its own etc/data/tmp and pidfile
    # so two sequential xymond instances never share a board, a data dir, or a
    # pidfile. Session scope would save a few ms but leave a trap for any future
    # test that assumes a clean board or runs concurrently.
    home = tmp_path_factory.mktemp("xymonhome")
    for sub in ("etc", "tmp", "data"):
        (home / sub).mkdir()
    # Host must be named `localhost`; the `# noconn` tag keeps xymond from
    # trying to ping it. The test service `testcpu` is created on first status.
    (home / "etc" / "hosts.cfg").write_text("127.0.0.1 localhost # noconn\n")
    return home


@pytest.fixture
def xymond_server(xymond_bin, xymon_home):
    """Start a private xymond on a free port; yield (host, port); always reap.

    The port is discovered by us (xymond won't pick one), so there is a small
    race where another process can grab it before xymond binds. A bind failure
    is therefore retried on a fresh port, up to MAX_LAUNCHES, all inside the
    single START_TIMEOUT readiness deadline (Criterion 2)."""
    host = "127.0.0.1"
    hosts = xymon_home / "etc" / "hosts.cfg"
    env = dict(os.environ)
    env.update(
        XYMONHOME=str(xymon_home),
        XYMONTMP=str(xymon_home / "tmp"),
        XYMONVAR=str(xymon_home / "data"),
    )

    deadline = time.monotonic() + START_TIMEOUT
    proc = None
    last = ""
    try:
        for _ in range(MAX_LAUNCHES):
            port = _free_port()
            proc = subprocess.Popen(
                [
                    xymond_bin,
                    f"--listen={host}:{port}",
                    f"--hosts={hosts}",
                    "--no-daemon",
                    f"--pidfile={xymon_home / 'xymond.pid'}",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            ready, out = _await_ready(proc, host, port, deadline)
            if ready:
                yield host, port
                return
            _terminate(proc)
            last = out if out else f"xymond did not answer ping on {host}:{port}"
            proc = None
            # Retry only the specific port-collision race, and only with time left.
            if out and "Cannot bind to listen socket" in out and time.monotonic() < deadline:
                continue
            raise RuntimeError(f"xymond failed to start:\n{last}")
        raise RuntimeError(
            f"xymond not ready after {MAX_LAUNCHES} bind attempts:\n{last}"
        )
    finally:
        if proc is not None:
            _terminate(proc)


def pytest_sessionfinish(session, exitstatus):
    """Bridge contract (Criterion 5): when invoked from the bash testsuite
    (XYMON_TESTSUITE_BRIDGE=1), a session where everything was skipped -- or
    nothing ran -- must not report success, or the bridge would map it to a
    green PASS that proves nothing. Promote that case to a failing exit code."""
    if os.environ.get("XYMON_TESTSUITE_BRIDGE") != "1":
        return
    reporter = session.config.pluginmanager.get_plugin("terminalreporter")
    if reporter is None:
        return
    stats = reporter.stats
    ran_for_real = stats.get("passed") or stats.get("failed") or stats.get("error")
    if not ran_for_real:
        # TESTS_FAILED (1) is stable across pytest versions; the NO_TESTS_*
        # member was renamed between releases. The bridge maps any non-zero,
        # non-5 code to fail, so this surfaces the empty/all-skipped session.
        session.exitstatus = pytest.ExitCode.TESTS_FAILED
