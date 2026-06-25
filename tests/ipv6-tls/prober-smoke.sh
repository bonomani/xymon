#!/bin/sh
#
# Runtime smoke for the IPv6 service-test *prober* (P3a -- contest.c's connection
# engine). Proves the standalone `contest` opens a real TCP connection over IPv6
# (and IPv4 for parity), and reports a refused IPv6 connection correctly.
#
# This complements smoke.sh (which covers the xymond server side). It exercises
# the xymonnet prober's v6 connect path that P3a added (sockaddr_storage +
# socket(AF_INET6) + connect), driven exactly as a hosts.cfg v6 literal would
# drive it (contest takes IP/PORT/TESTSPEC and feeds the IP to add_tcp_test).
#
# Requires: the standalone `contest` (build: make -C xymonnet contest), python3
# (for the throwaway listeners), and a usable ::1 on loopback. Skips (77) if any
# is missing. Exit 0 = all checks passed.

set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
CONTEST=${CONTEST:-$repo/xymonnet/contest}
P6=${P6:-19987}; P4=${P4:-19988}; PC=${PC:-19989}
pass=0; fail=0; lpid=

ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1 (got open=$2)"; fail=$((fail+1)); }
cleanup() { [ -n "$lpid" ] && kill "$lpid" 2>/dev/null; }
trap cleanup EXIT INT TERM

command -v python3 >/dev/null 2>&1 || { echo "SKIP: need python3 for the test listeners"; exit 77; }
[ -x "$CONTEST" ] || { echo "SKIP: no contest at $CONTEST (build: make -C xymonnet contest)"; exit 77; }
ip -6 addr show lo 2>/dev/null | grep -qw "::1" || { echo "SKIP: no ::1 on loopback (sudo ip addr add ::1/128 dev lo)"; exit 77; }

# listen FAMILY(4|6) ADDR PORT  -> background one-shot banner listener; prints its PID
listen() {
	python3 -c '
import socket,sys,time
fam = socket.AF_INET6 if sys.argv[1]=="6" else socket.AF_INET
s = socket.socket(fam, socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[2], int(sys.argv[3]))); s.listen(5); s.settimeout(8)
end = time.time()+8
while time.time() < end:
    try:
        c,_ = s.accept(); c.sendall(b"220 prober-smoke\r\n")
        try: c.recv(200)
        except Exception: pass
        c.close()
    except Exception: break
' "$1" "$2" "$3" >/dev/null 2>&1 & echo $!
}

# openstate IP PORT -> the open= value contest reports (1=connected, 0=failed)
openstate() {
	XYMONHOME=/tmp "$CONTEST" --timeout=5 "$1/$2/smtp" 2>/dev/null | sed -n 's/.*open=\([0-9]\).*/\1/p' | head -1
}

echo "== IPv6 prober connect smoke (P3a contest engine) =="

lpid=$(listen 6 ::1 "$P6"); sleep 0.5
v=$(openstate "::1" "$P6"); [ "$v" = "1" ] && ok "IPv6 connect (::1) -> open" || bad "IPv6 connect (::1) -> open" "$v"
kill "$lpid" 2>/dev/null; lpid=

lpid=$(listen 4 127.0.0.1 "$P4"); sleep 0.5
v=$(openstate "127.0.0.1" "$P4"); [ "$v" = "1" ] && ok "IPv4 connect (127.0.0.1) -> open" || bad "IPv4 connect (127.0.0.1) -> open" "$v"
kill "$lpid" 2>/dev/null; lpid=

# no listener on $PC -> a v6 connect must FAIL closed (open=0), not falsely succeed
v=$(openstate "::1" "$PC"); [ "$v" = "0" ] && ok "IPv6 no-listener -> refused (open=0)" || bad "IPv6 no-listener -> refused (open=0)" "$v"

echo "---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
