#!/usr/bin/env bash
set -e

echo "== Architecture guards (B6.7) =="

# ---- Guard 1: forbidden includes of loaders ----
echo "[1/4] Checking forbidden loader includes..."

if grep -R '#include "loadalerts' lib/*.c | grep -v 'loadalerts.c'; then
  echo "ERROR: loadalerts included outside its module"
  exit 1
fi

if grep -R '#include "loadcriticalconf' lib/*.c | grep -v 'loadcriticalconf.c'; then
  echo "ERROR: loadcriticalconf included outside its module"
  exit 1
fi

if grep -R '#include "loadhosts' lib/*.c | grep -v 'loadhosts.c'; then
  echo "ERROR: loadhosts included outside its module"
  exit 1
fi


# ---- Guard 2: common must not reference loaders ----
echo "[2/4] Checking xymon_common isolation..."

COMMON_FILES="
errormsg.c
tree.c
memory.c
md5.c
strfunc.c
timefunc.c
digest.c
encoding.c
calc.c
misc.c
msort.c
files.c
stackio.c
sig.c
suid.c
xymond_buffer.c
xymond_ipc.c
matching.c
timing.c
crondate.c
"

for f in $COMMON_FILES; do
  if grep -E 'loadalerts|loadhosts|loadcriticalconf' "lib/$f"; then
    echo "ERROR: loader reference found in common file: $f"
    exit 1
  fi
done


# ---- Guard 3: libxymon.h must stay neutral ----
echo "[3/4] Checking libxymon.h neutrality..."

if grep -E 'loadalerts|loadhosts|loadcriticalconf|xymond_' include/libxymon.h; then
  echo "ERROR: server or loader symbol leaked into libxymon.h"
  exit 1
fi


# ---- Guard 4: loadhosts.c is the only file allowed to include .c ----
echo "[4/4] Checking forbidden .c inclusions..."

if grep -R '#include ".*\.c"' lib/*.c | grep -v 'loadhosts.c'; then
  echo "ERROR: .c inclusion found outside loadhosts.c"
  exit 1
fi


echo "OK: architecture guards passed"

