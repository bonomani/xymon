# lib/CMakeLists.txt
#
# Parity stage 2 (xymongen scope only)
# - Exactly match objects required to link xymongen
# - No refactoring
# - No invented files
# - Match historical Makefile behavior

if(XYMON_BUILD_SERVER)
    # ----------------------------------------------------------------------
    # libxymoncomm.a
    # ----------------------------------------------------------------------

    add_library(xymoncomm STATIC
    # core utilities
    errormsg.c
    tree.c
    memory.c
    md5.c
    strfunc.c
    digest.c
    encoding.c
    calc.c
    run.c
    misc.c
    msort.c
    files.c
    stackio.c
    sig.c
    suid.c
    matching.c

    # IPC / buffers
    xymond_buffer.c
    xymond_ipc.c

    # environment / urls
    environ.c
    cgi.c
    cgiurls.c
    url.c
    ipaccess.c
    clientlocal.c

    # messaging / combo
    sendmsg.c
    ../xymond/combostatus.c

    # links / URLs
    links.c

    # colors / html / rendering
    color.c
    headfoot.c
    htmllog.c
    reportlog.c

    # hosts.cfg handling
    loadhosts.c

    # alerts / SLA / calendar
    loadalerts.c
    loadcriticalconf.c
    holidays.c

    # events / acks / availability
    eventlog.c
    acklog.c
    availability.c
    webaccess.c
    notifylog.c
    acknowledgementslog.c

    # SNMP MIB helpers
    readmib.c

    # RRD / graph helpers
    xymonrrd.c

    # network / locator
    netservices.c
    locator.c

    # crypto backends used by digest.c
    sha1.c
    sha2.c
    rmd160c.c
    )

    set_target_properties(xymoncomm PROPERTIES
        OUTPUT_NAME xymoncomm
    )

    # REQUIRED: endianness macro (parity with historical Makefile)
    # This MUST be a compile definition, not a compile option
    if(WORDS_BIGENDIAN)
        target_compile_definitions(xymoncomm PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
    else()
        target_compile_definitions(xymoncomm PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
    endif()

    target_compile_options(xymoncomm PRIVATE
        -include${CMAKE_SOURCE_DIR}/lib/osdefs.h
    )

    # External libraries required by objects in libxymoncomm.a
    if(CMAKE_SYSTEM_NAME MATCHES "OpenBSD|FreeBSD")
        target_link_directories(xymoncomm PUBLIC /usr/local/lib /usr/X11R6/lib)
        target_link_options(xymoncomm PUBLIC -L/usr/local/lib -L/usr/X11R6/lib)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
        target_link_directories(xymoncomm PUBLIC /usr/pkg/lib)
        target_link_options(xymoncomm PUBLIC -L/usr/pkg/lib)
    endif()

    if(XYMON_PCRE_LIBRARY)
        target_link_libraries(xymoncomm
            "${XYMON_PCRE_LIBRARY}"
            ssl
            crypto
        )
    else()
        target_link_libraries(xymoncomm
            ssl
            crypto
        )
    endif()
endif()

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

# In client-only builds, xymontime must compile with the same client macros
# as libxymonclient to avoid server-only header paths (e.g. PCRE includes).
if(NOT XYMON_BUILD_SERVER)
    target_compile_definitions(xymontime PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
endif()

# ----------------------------------------------------------------------
# libxymonclient.a
# ----------------------------------------------------------------------

add_library(xymonclient_color OBJECT color.c)

add_library(xymonclient_timefunc OBJECT timefunc.c)

add_library(xymonclient_environ OBJECT environ.c)
set(_XYMONCLIENT_SOURCES
    osdefs.c
    cgiurls.c
    crondate.c
    digest.c
    encoding.c
    errormsg.c
    holidays.c
    ipaccess.c
    md5.c
    memory.c
    misc.c
    msort.c
    rmd160c.c
    sha1.c
    sha2.c
    sig.c
    stackio.c
    strfunc.c
    suid.c
    tree.c
)

if(LOCALCLIENT)
    list(APPEND _XYMONCLIENT_SOURCES
        clientlocal.c
        matching.c
    )
endif()

add_library(xymonclient STATIC
    ${_XYMONCLIENT_SOURCES}
    $<TARGET_OBJECTS:xymonclient_color>
    $<TARGET_OBJECTS:xymonclient_timefunc>
    $<TARGET_OBJECTS:xymonclient_environ>
)

set_target_properties(xymonclient PROPERTIES
    OUTPUT_NAME xymonclient
)

if(WORDS_BIGENDIAN)
    target_compile_definitions(xymonclient PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
else()
    target_compile_definitions(xymonclient PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
endif()
target_compile_definitions(xymonclient PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
target_compile_definitions(xymonclient_color PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
target_compile_definitions(xymonclient_timefunc PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
target_compile_definitions(xymonclient_environ PRIVATE
    ${XYMON_CLIENT_COMPILE_DEFINITIONS}
    XYMONHOME=\"${XYMONCLIENTHOME}\"
)

if(LOCALCLIENT)
    if(XYMON_PCRE_LIBRARY)
        target_link_libraries(xymonclient PUBLIC "${XYMON_PCRE_LIBRARY}")
    endif()
endif()

# ----------------------------------------------------------------------
# libxymonclientcomm.a
# ----------------------------------------------------------------------

add_library(xymonclientcomm STATIC
    locator.c
    loadhosts.c
    sendmsg.c
    xymond_ipc.c
    xymond_buffer.c
)

set_target_properties(xymonclientcomm PROPERTIES
    OUTPUT_NAME xymonclientcomm
)
target_compile_definitions(xymonclientcomm PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})

if(XYMON_BUILD_SERVER)
    # ----------------------------------------------------------------------
    # libxymon.a (aggregate)
    # ----------------------------------------------------------------------

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

    # ----------------------------------------------------------------------
    # Standalone tools (parity with lib/Makefile)
    # ----------------------------------------------------------------------

    add_executable(test-endianness
        test-endianness.c
    )

    add_executable(loadhosts
        loadhosts.c
    )
    target_compile_definitions(loadhosts PRIVATE STANDALONE)
    target_link_libraries(loadhosts
        xymontime
        xymoncomm
    )

    if(INSTALL_EXTRA)
    add_executable(stackio
        stackio.c
    )
    target_compile_definitions(stackio PRIVATE STANDALONE)
    target_link_libraries(stackio
        xymontime
        xymoncomm
        xymon
    )
    endif()

    add_executable(availability
        availability.c
    )
    target_compile_definitions(availability PRIVATE STANDALONE)
    target_link_libraries(availability
        xymontime
        xymoncomm
        xymon
    )

    add_executable(md5
        md5.c
    )
    target_compile_definitions(md5 PRIVATE STANDALONE)
    if(WORDS_BIGENDIAN)
        target_compile_definitions(md5 PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
    else()
        target_compile_definitions(md5 PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
    endif()

    add_executable(sha1
        sha1.c
    )
    target_compile_definitions(sha1 PRIVATE STANDALONE)
    if(WORDS_BIGENDIAN)
        target_compile_definitions(sha1 PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
    else()
        target_compile_definitions(sha1 PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
    endif()

    add_executable(rmd160
        rmd160c.c
    )
    target_compile_definitions(rmd160 PRIVATE STANDALONE)
    if(WORDS_BIGENDIAN)
        target_compile_definitions(rmd160 PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
    else()
        target_compile_definitions(rmd160 PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
    endif()

    if(INSTALL_EXTRA)
    add_executable(locator
        locator.c
    )
    target_compile_definitions(locator PRIVATE STANDALONE)
    target_link_libraries(locator
        xymontime
        xymoncomm
        xymon
    )
    endif()
    add_executable(tree
        tree.c
    )
    target_compile_definitions(tree PRIVATE STANDALONE)

    set(_helper_targets
        loadhosts
        availability
        md5
        sha1
        rmd160
        tree
    )
    if(INSTALL_EXTRA)
        list(APPEND _helper_targets stackio locator)
    endif()
    if(INSTALL_EXTRA)
        install(TARGETS ${_helper_targets}
            RUNTIME DESTINATION ${INSTALLBINDIR}
        )
    endif()
endif()
