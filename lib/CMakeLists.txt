# lib/CMakeLists.txt
#
# Parity stage 3:
# - Define exactly three real static library artifacts from the reference Make build
#   * libxymoncomm.a
#   * libxymontime.a
#   * libxymon.a
# - No executables
# - No refactoring
# - No extra flags (use top-level flags/includes only)

# ----------------------------------------------------------------------
# libxymoncomm.a
# ----------------------------------------------------------------------

add_library(xymoncomm STATIC
    errormsg.c
    tree.c
    memory.c
    md5.c
    strfunc.c
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
)

set_target_properties(xymoncomm PROPERTIES
    OUTPUT_NAME xymoncomm
)

# ----------------------------------------------------------------------
# libxymontime.a
# ----------------------------------------------------------------------

add_library(xymontime STATIC
    timefunc.c
    timing.c
    crondate.c
)

set_target_properties(xymontime PROPERTIES
    OUTPUT_NAME xymontime
)

# ----------------------------------------------------------------------
# libxymon.a
# ----------------------------------------------------------------------

add_library(xymon STATIC
    util.c
    debug.c
    csvreport.c
    loadlayout.c
    loaddata.c
    pagegen.c
    process.c
    wmlgen.c
    rssgen.c
)

set_target_properties(xymon PROPERTIES
    OUTPUT_NAME xymon
)

