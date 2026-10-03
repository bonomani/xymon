#!/usr/bin/env bash
# CI-only report, not for merging: what the suite left in SysV IPC.
echo "IPC-REPORT xymond-left=$(pgrep -f '/xymond/xymond ' 2>/dev/null | wc -l | tr -d ' ')"
echo "IPC-REPORT sem-sets=$(ipcs -s 2>/dev/null | grep -c '^s')"
for k in kern.ipc.semmni kern.seminfo.semmni; do v=$(sysctl -n $k 2>/dev/null) && echo "IPC-REPORT $k=$v"; done
echo "PASS: IPC report printed"
