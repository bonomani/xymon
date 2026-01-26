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
# libxymon.a  (mixed-source library, as in Make)
# ----------------------------------------------------------------------

add_library(xymon STATIC
    ${CMAKE_SOURCE_DIR}/xymongen/util.c
    ${CMAKE_SOURCE_DIR}/xymongen/debug.c
    ${CMAKE_SOURCE_DIR}/xymongen/csvreport.c
    ${CMAKE_SOURCE_DIR}/lib/environment.c
    ${CMAKE_SOURCE_DIR}/lib/envexpand.c
    ${CMAKE_SOURCE_DIR}/lib/getweekday.c
    ${CMAKE_SOURCE_DIR}/lib/holidays.c
)

set_target_properties(xymon PROPERTIES
    OUTPUT_NAME xymon
)

target_link_libraries(xymon
    xymoncomm
    xymontime
)

