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

install(TARGETS
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

install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/clientlaunch.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/xymonclient.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/localclient.cfg
    DESTINATION ${XYMONCLIENTHOME}/etc
)
install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/xymonclient.cfg
    DESTINATION ${XYMONCLIENTHOME}/etc
    RENAME xymonclient.cfg.bak
)
install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/clientlaunch.cfg
    DESTINATION ${XYMONCLIENTHOME}/etc
    RENAME clientlaunch.cfg.bak
)

install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/README-local
    DESTINATION ${XYMONCLIENTHOME}/local
    RENAME README
)

install(CODE [[
    set(_dest "$ENV{DESTDIR}")
    if(_dest STREQUAL "")
        set(_dest "")
    endif()
    set(_clientroot "${_dest}${CMAKE_INSTALL_PREFIX}/client")
    file(MAKE_DIRECTORY
        "${_clientroot}"
        "${_clientroot}/etc"
        "${_clientroot}/ext"
        "${_clientroot}/local"
        "${_clientroot}/logs"
        "${_clientroot}/tmp"
    )
]])
