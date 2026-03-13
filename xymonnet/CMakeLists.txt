# xymonnet/CMakeLists.txt

option(ENABLE_CARES "Enable c-ares support" ON)
option(ENABLE_SNMP "Enable SNMP collector" ON)

find_library(CARES_LIBRARY cares)
find_library(LDAP_LIBRARY ldap)
find_library(LBER_LIBRARY lber)

add_executable(xymonnet
    xymonnet.c
    contest.c
    httptest.c
    httpresult.c
    ldaptest.c
    dns.c
    dns2.c
    httpcookies.c
)
if(ENABLE_LDAP)
    target_compile_definitions(xymonnet PRIVATE HAVE_LDAP)
endif()
if(ENABLE_CARES AND CARES_LIBRARY)
    target_link_libraries(xymonnet ${CARES_LIBRARY})
endif()
if(ENABLE_LDAP AND LDAP_LIBRARY AND LBER_LIBRARY)
    target_link_libraries(xymonnet ${LDAP_LIBRARY} ${LBER_LIBRARY})
endif()
target_link_libraries(xymonnet
    xymontime
    xymoncomm
    xymon
    ${XYMON_PCRE_LIBRARY}
    ssl
    crypto
)

add_executable(xymonping
    xymonping.c
)
target_link_libraries(xymonping
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(beastat
    beastat.c
)
target_link_libraries(beastat
    xymoncomm
    xymontime
    xymoncomm
    ${XYMON_PCRE_LIBRARY}
    ssl
    crypto
)

add_executable(contest
    contest.c
    httptest.c
    dns.c
    dns2.c
    httpcookies.c
)
target_compile_definitions(contest PRIVATE STANDALONE)
if(ENABLE_CARES AND CARES_LIBRARY)
    target_link_libraries(contest ${CARES_LIBRARY})
endif()
if(APPLE)
    target_link_libraries(contest
        xymontime
        xymoncomm
        ssl
        crypto
    )
else()
    target_link_libraries(contest
        -Wl,--start-group
        xymontime
        xymoncomm
        -Wl,--end-group
        ssl
        crypto
    )
endif()

if(ENABLE_SNMP)
    find_program(NETSNMP_CONFIG net-snmp-config)
    if(NETSNMP_CONFIG)
        execute_process(
            COMMAND ${NETSNMP_CONFIG} --cflags
            OUTPUT_VARIABLE NETSNMP_CFLAGS
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        execute_process(
            COMMAND ${NETSNMP_CONFIG} --libs
            OUTPUT_VARIABLE NETSNMP_LIBS
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        separate_arguments(NETSNMP_CFLAGS)
        separate_arguments(NETSNMP_LIBS)
        if(APPLE)
            set(_netsnmp_cflags_filtered "")
            foreach(_flag IN LISTS NETSNMP_CFLAGS)
                if(_flag MATCHES "^-I" OR _flag MATCHES "^-D" OR _flag MATCHES "^-U")
                    list(APPEND _netsnmp_cflags_filtered "${_flag}")
                endif()
            endforeach()
            set(NETSNMP_CFLAGS "${_netsnmp_cflags_filtered}")
        endif()

        add_executable(xymon-snmpcollect
            xymon-snmpcollect.c
        )
        # Net-SNMP headers and this source require C99 (declarations after statements).
        set_property(TARGET xymon-snmpcollect PROPERTY C_STANDARD 99)
        set_property(TARGET xymon-snmpcollect PROPERTY C_STANDARD_REQUIRED ON)
        set_property(TARGET xymon-snmpcollect PROPERTY C_EXTENSIONS ON)
        target_compile_options(xymon-snmpcollect PRIVATE
            ${NETSNMP_CFLAGS}
            -std=gnu99
            -Wno-declaration-after-statement
            -Wno-error=declaration-after-statement
        )
        target_link_libraries(xymon-snmpcollect
            xymon
            xymontime
            xymoncomm
            ${NETSNMP_LIBS}
        )
        if(INSTALL_EXTRA)
            install(TARGETS xymon-snmpcollect
                RUNTIME DESTINATION ${INSTALLBINDIR_DEST}
            )
        endif()
    else()
        message(STATUS "SNMP enabled but net-snmp-config not found; skipping xymon-snmpcollect")
    endif()
endif()

install(TARGETS xymonnet xymonping beastat
    RUNTIME DESTINATION ${INSTALLBINDIR_DEST}
)
if(INSTALL_EXTRA)
    install(TARGETS contest
        RUNTIME DESTINATION ${INSTALLBINDIR_DEST}
    )
endif()

if(XYMON_LAYOUT STREQUAL "fhs")
    set(_XYMONNET_FHS_INSTALL_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/install-fhs-protocols.cmake")
    configure_file(
        "${CMAKE_SOURCE_DIR}/cmake/XymonnetInstallFhs.cmake.in"
        "${_XYMONNET_FHS_INSTALL_SCRIPT}"
        @ONLY
    )
    install(SCRIPT "${_XYMONNET_FHS_INSTALL_SCRIPT}")
else()
    install(FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/protocols.cfg
        DESTINATION ${INSTALLETCDIR_DEST}
    )
endif()
set(_xymonnet_again_src "${CMAKE_CURRENT_SOURCE_DIR}/xymonnet-again.sh")
if(NOT EXISTS "${_xymonnet_again_src}")
    set(_xymonnet_again_src "${CMAKE_CURRENT_BINARY_DIR}/xymonnet-again.sh")
    configure_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/xymonnet-again.sh.DIST
        ${_xymonnet_again_src}
        COPYONLY
        FILE_PERMISSIONS
          OWNER_READ OWNER_WRITE OWNER_EXECUTE
          GROUP_READ GROUP_EXECUTE
          WORLD_READ WORLD_EXECUTE
    )
endif()

install(PROGRAMS
    ${_xymonnet_again_src}
    DESTINATION ${INSTALLEXTDIR_DEST}
)

if(XYMON_INSTALL_MANPAGES)
    install(FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/xymonnet.1
        ${CMAKE_CURRENT_SOURCE_DIR}/xymonping.1
        ${CMAKE_CURRENT_SOURCE_DIR}/xymonnet-again.sh.1
        DESTINATION ${INSTALLMAN1DIR_DEST}
    )
    install(FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/protocols.cfg.5
        DESTINATION ${INSTALLMAN5DIR_DEST}
    )
endif()
