# lib/CMakeLists.txt
#
# Parity stage 2:
# - Exactly match reference static libraries
# - No refactoring
# - No architecture changes

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

    environ.c
    cgiurls.c
    holidays.c
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
# libxymon.a (canonical aggregate library)
# ----------------------------------------------------------------------

# Dummy source required by CMake for aggregate static library
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/xymon_dummy.c
"void xymon_dummy(void) {}\n"
)

add_library(xymon STATIC
    ${CMAKE_CURRENT_BINARY_DIR}/xymon_dummy.c
)

target_link_libraries(xymon
    xymoncomm
    xymontime
)

set_target_properties(xymon PROPERTIES
    OUTPUT_NAME xymon
)

