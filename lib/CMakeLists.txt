# lib/CMakeLists.txt
#
# Parity stage 1:
# - Define exactly one real static library artifact from the reference Make build.
# - No executables.
# - No refactoring.
# - No extra flags (use top-level flags/includes only).

add_library(xymoncomm STATIC
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
)

set_target_properties(xymoncomm PROPERTIES
    OUTPUT_NAME xymoncomm
)

