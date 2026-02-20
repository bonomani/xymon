# client/CMakeLists.txt

set(CLIENT_OUTPUT_DIR ${CMAKE_BINARY_DIR}/client)

add_executable(client_xymon
    ../common/xymon.c
)
set_target_properties(client_xymon PROPERTIES
    OUTPUT_NAME xymon
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymon
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

add_executable(client_xymonlaunch
    ../common/xymonlaunch.c
)
set_target_properties(client_xymonlaunch PROPERTIES
    OUTPUT_NAME xymonlaunch
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymonlaunch
    xymontime
    xymonclient
)

add_executable(client_xymoncmd
    ../common/xymoncmd.c
)
set_target_properties(client_xymoncmd PROPERTIES
    OUTPUT_NAME xymoncmd
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymoncmd
    xymonclient
)

add_executable(client_xymongrep
    ../common/xymongrep.c
)
set_target_properties(client_xymongrep PROPERTIES
    OUTPUT_NAME xymongrep
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymongrep
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

add_executable(client_xymoncfg
    ../common/xymoncfg.c
)
set_target_properties(client_xymoncfg PROPERTIES
    OUTPUT_NAME xymoncfg
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymoncfg
    xymonclient
)

add_executable(client_xymondigest
    ../common/xymondigest.c
)
set_target_properties(client_xymondigest PROPERTIES
    OUTPUT_NAME xymondigest
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(client_xymondigest
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

add_executable(logfetch
    logfetch.c
)
set_target_properties(logfetch PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(logfetch
    xymonclient
)

add_executable(clientupdate
    clientupdate.c
)
set_target_properties(clientupdate PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(clientupdate
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

add_executable(orcaxymon
    orcaxymon.c
)
set_target_properties(orcaxymon PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(orcaxymon
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

add_executable(msgcache
    msgcache.c
)
set_target_properties(msgcache PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
)
target_link_libraries(msgcache
    xymonclientcomm
    xymonclient
    ssl
    crypto
)

set(_CLIENT_EXTRA_MEMINFO_TARGETS)
if(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
    add_executable(freebsd-meminfo
        freebsd-meminfo.c
    )
    set_target_properties(freebsd-meminfo PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
    )
    list(APPEND _CLIENT_EXTRA_MEMINFO_TARGETS freebsd-meminfo)
elseif(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
    add_executable(netbsd-meminfo
        netbsd-meminfo.c
    )
    set_target_properties(netbsd-meminfo PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
    )
    list(APPEND _CLIENT_EXTRA_MEMINFO_TARGETS netbsd-meminfo)
elseif(CMAKE_SYSTEM_NAME STREQUAL "OpenBSD")
    add_executable(openbsd-meminfo
        openbsd-meminfo.c
    )
    set_target_properties(openbsd-meminfo PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CLIENT_OUTPUT_DIR}
    )
    list(APPEND _CLIENT_EXTRA_MEMINFO_TARGETS openbsd-meminfo)
endif()

set(_CLIENT_PROGRAM_TARGETS
    client_xymon
    client_xymonlaunch
    client_xymoncmd
    client_xymongrep
    client_xymoncfg
    client_xymondigest
    logfetch
    clientupdate
    orcaxymon
    msgcache
)
list(APPEND _CLIENT_PROGRAM_TARGETS ${_CLIENT_EXTRA_MEMINFO_TARGETS})

foreach(_client_target IN LISTS _CLIENT_PROGRAM_TARGETS)
    target_compile_definitions(${_client_target} PRIVATE ${XYMON_CLIENT_COMPILE_DEFINITIONS})
endforeach()

install(TARGETS
    ${_CLIENT_PROGRAM_TARGETS}
    RUNTIME DESTINATION ${XYMONCLIENTHOME}/bin
)

file(GLOB _CLIENT_SCRIPTS
    "${CMAKE_CURRENT_SOURCE_DIR}/xymonclient-*.sh"
    "${CMAKE_CURRENT_SOURCE_DIR}/xymonclient.sh"
)

install(PROGRAMS
    ${_CLIENT_SCRIPTS}
    DESTINATION ${XYMONCLIENTHOME}/bin
)
install(PROGRAMS
    ${CMAKE_CURRENT_SOURCE_DIR}/runclient.sh
    DESTINATION ${XYMONCLIENTHOME}
)

# Keep client cfg generation aligned with legacy Make:
# - clientlaunch.cfg: substitute @CLIENTFLAGS@ (empty or --local)
# - xymonclient.cfg: substitute @XYMONHOSTIP@ and append bb-commands.sh output
set(_clientlaunch_src "${CMAKE_CURRENT_BINARY_DIR}/clientlaunch.cfg")
set(_xymonclient_src "${CMAKE_CURRENT_BINARY_DIR}/xymonclient.cfg")

set(_clientflags "")
if(LOCALCLIENT)
    set(_clientflags "--local")
endif()

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/clientlaunch.cfg.DIST" _clientlaunch_template)
string(REPLACE "@CLIENTFLAGS@" "${_clientflags}" _clientlaunch_content "${_clientlaunch_template}")
file(WRITE "${_clientlaunch_src}" "${_clientlaunch_content}")

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/xymonclient.cfg.DIST" _xymonclient_template)
string(REPLACE "@XYMONHOSTIP@" "${XYMONHOSTIP}" _xymonclient_content "${_xymonclient_template}")
file(WRITE "${_xymonclient_src}" "${_xymonclient_content}")

execute_process(
    COMMAND sh "${CMAKE_SOURCE_DIR}/build/bb-commands.sh"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/client"
    OUTPUT_VARIABLE _bb_commands_out
    ERROR_VARIABLE _bb_commands_err
    RESULT_VARIABLE _bb_commands_res
)
if(NOT _bb_commands_res EQUAL 0)
    message(FATAL_ERROR "Failed to run build/bb-commands.sh: ${_bb_commands_err}")
endif()
file(APPEND "${_xymonclient_src}" "${_bb_commands_out}")

install(FILES
    ${_clientlaunch_src}
    ${_xymonclient_src}
    ${CMAKE_CURRENT_SOURCE_DIR}/localclient.cfg
    DESTINATION ${XYMONCLIENTHOME}/etc
)
install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/README-local
    DESTINATION ${XYMONCLIENTHOME}/local
    RENAME README
)

install(CODE "
    set(_dest \"\$ENV{DESTDIR}\")
    if(_dest STREQUAL \"\")
        set(_dest \"\")
    endif()
    set(_clientroot \"\${_dest}${XYMONCLIENTHOME}\")
    file(MAKE_DIRECTORY
        \"\${_clientroot}\"
        \"\${_clientroot}/etc\"
        \"\${_clientroot}/ext\"
        \"\${_clientroot}/local\"
        \"\${_clientroot}/logs\"
        \"\${_clientroot}/tmp\"
    )
")
