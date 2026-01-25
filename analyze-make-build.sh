#!/bin/sh
set -eu

LOG=build.log

if [ ! -f Makefile ] && [ ! -f makefile ] && [ ! -f GNUmakefile ]; then
    if [ -x ./configure ]; then
        ./configure
    else
        echo "ERROR: no Makefile found and no ./configure script available" >&2
        exit 1
    fi
fi

if make -n clean >/dev/null 2>&1; then
    make clean
fi

make V=1 2>&1 | tee "$LOG"

awk '
BEGIN {
    FS=" "
    OFS="\t"
    print "kind","target","source","binary","objects","compile_flags","include_dirs","defines","static_libs","external_libs"
}

function reset() {
    kind=""
    target=""
    source=""
    binary=""
    objects=""
    compile_flags=""
    include_dirs=""
    defines=""
    static_libs=""
    external_libs=""
}

$1 ~ /^(gcc|cc|clang)$/ {
    reset()

    is_compile=0
    is_link=0

    for (i=1; i<=NF; i++) {
        if ($i == "-c") is_compile=1
        if ($i == "-o" && $(i-1) != "-c") is_link=1
    }

    if (is_compile) {
        kind="compile"
        for (i=1; i<=NF; i++) {
            if ($i ~ /\.(c|cc|cpp)$/) source=$i
            else if ($i ~ /\.o$/) target=$i
            else if ($i ~ /^-I/) include_dirs=include_dirs $i " "
            else if ($i ~ /^-D/) defines=defines $i " "
            else if ($i ~ /^-/ && $i !~ /^-I|^-D|-c|-o$/)
                compile_flags=compile_flags $i " "
        }

        print kind,target,source,"","",compile_flags,include_dirs,defines,"",""
        next
    }

    if (is_link) {
        kind="link"
        for (i=1; i<=NF; i++) {
            if ($i == "-o") binary=$(i+1)
            else if ($i ~ /\.o$/) objects=objects $i " "
            else if ($i ~ /\.a$/) static_libs=static_libs $i " "
            else if ($i ~ /^-l/) external_libs=external_libs $i " "
        }

        print kind,"","",binary,objects,"","","",static_libs,external_libs
    }
}
' "$LOG"

