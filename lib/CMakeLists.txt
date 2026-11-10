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

    # The archives hold what lib/Makefile puts in them, so a program built
    # against the installed archives links as it does against make's:
    # libxymon.a is XYMONLIBOBJS, libxymoncomm.a those and the
    # communication objects, libxymontime.a run and timing.
    set(XYMON_LIB_SOURCES
        osdefs.c acklog.c availability.c calc.c cgi.c cgiurls.c clientlocal.c
        color.c crondate.c digest.c encoding.c environ.c errormsg.c eventlog.c
        files.c headfoot.c xymonrrd.c holidays.c htmllog.c ipaccess.c
        loadalerts.c loadcriticalconf.c links.c matching.c md5.c memory.c
        misc.c msort.c netservices.c notifylog.c acknowledgementslog.c
        readmib.c reportlog.c rmd160c.c sha1.c sha2.c sig.c stackio.c
        strfunc.c suid.c timefunc.c tree.c url.c webaccess.c
    )

    add_library(xymoncomm STATIC
        ${XYMON_LIB_SOURCES}
        loadhosts.c
        locator.c
        sendmsg.c
        xymond_ipc.c
        xymond_buffer.c
        # TLS (compiled empty without HAVE_OPENSSL); used by sendmsg.c and the daemon
        xymontls.c
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
            ${XYMON_SSL_LIBRARIES}
            ${XYMON_NET_LIBRARIES}
        )
    else()
        target_link_libraries(xymoncomm
            ${XYMON_SSL_LIBRARIES}
            ${XYMON_NET_LIBRARIES}
        )
    endif()
    if(XYMON_NET_INCLUDE_DIRS)
        target_include_directories(xymoncomm PUBLIC ${XYMON_NET_INCLUDE_DIRS})
    endif()
endif()

# ----------------------------------------------------------------------
# libxymontime.a
# ----------------------------------------------------------------------

add_library(xymontime STATIC
    run.c
    timing.c
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
    xymontls.c
    xymond_ipc.c
    xymond_buffer.c
)

set_target_properties(xymonclientcomm PROPERTIES
    OUTPUT_NAME xymonclientcomm
)
target_compile_definitions(xymonclientcomm PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
if(XYMON_NET_LIBRARIES)
    target_link_libraries(xymonclientcomm PUBLIC ${XYMON_NET_LIBRARIES})
endif()
# sendmsg.c/xymontls.c reach OpenSSL when HAVE_OPENSSL is set; empty otherwise
target_link_libraries(xymonclientcomm PUBLIC ${XYMON_SSL_LIBRARIES})
if(XYMON_NET_INCLUDE_DIRS)
    target_include_directories(xymonclientcomm PUBLIC ${XYMON_NET_INCLUDE_DIRS})
endif()

if(XYMON_BUILD_SERVER)
    # ----------------------------------------------------------------------
    # libxymon.a (aggregate)
    # ----------------------------------------------------------------------

    add_library(xymon STATIC
        ${XYMON_LIB_SOURCES}
    )
    if(WORDS_BIGENDIAN)
        target_compile_definitions(xymon PRIVATE WORDS_BIGENDIAN XYMON_BIG_ENDIAN)
    else()
        target_compile_definitions(xymon PRIVATE WORDS_LITTLEENDIAN XYMON_LITTLE_ENDIAN)
    endif()
    target_compile_options(xymon PRIVATE
        -include${CMAKE_SOURCE_DIR}/lib/osdefs.h
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
            RUNTIME DESTINATION ${INSTALLBINDIR_DEST}
        )
    endif()
endif()
