# common/CMakeLists.txt

add_executable(xymongrep
    xymongrep.c
)
target_link_libraries(xymongrep
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymondigest
    xymondigest.c
)
target_link_libraries(xymondigest
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymon_common
    xymon.c
)
set_target_properties(xymon_common PROPERTIES
    OUTPUT_NAME xymon
)
target_link_libraries(xymon_common
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymoncmd
    xymoncmd.c
)
target_link_libraries(xymoncmd
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymonlaunch
    xymonlaunch.c
)
target_link_libraries(xymonlaunch
    xymontime
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymoncfg
    xymoncfg.c
)
target_link_libraries(xymoncfg
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

install(TARGETS xymongrep xymondigest xymon_common xymoncmd xymonlaunch xymoncfg
    RUNTIME DESTINATION ${INSTALLBINDIR}
)

file(GLOB _COMMON_MAN1 "${CMAKE_CURRENT_SOURCE_DIR}/*.1")
file(GLOB _COMMON_MAN5 "${CMAKE_CURRENT_SOURCE_DIR}/*.5")
file(GLOB _COMMON_MAN7 "${CMAKE_CURRENT_SOURCE_DIR}/*.7")
file(GLOB _COMMON_MAN8 "${CMAKE_CURRENT_SOURCE_DIR}/*.8")

install(FILES ${_COMMON_MAN1}
    DESTINATION ${XYMONHOME}/man/man1
)
install(FILES ${_COMMON_MAN5}
    DESTINATION ${XYMONHOME}/man/man5
)
install(FILES ${_COMMON_MAN7}
    DESTINATION ${XYMONHOME}/man/man7
)
install(FILES ${_COMMON_MAN8}
    DESTINATION ${XYMONHOME}/man/man8
)

install(CODE [[
    set(_dest "$ENV{DESTDIR}")
    if(_dest STREQUAL "")
        set(_dest "")
    endif()
    set(_bindir "${_dest}${CMAKE_INSTALL_PREFIX}/server/bin")
    if(EXISTS "${_bindir}/xymon")
        file(REMOVE "${_bindir}/bb")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink xymon "${_bindir}/bb")
    endif()
    if(EXISTS "${_bindir}/xymoncmd")
        file(REMOVE "${_bindir}/bbcmd")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink xymoncmd "${_bindir}/bbcmd")
    endif()
    if(EXISTS "${_bindir}/xymondigest")
        file(REMOVE "${_bindir}/bbdigest")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink xymondigest "${_bindir}/bbdigest")
    endif()
    if(EXISTS "${_bindir}/xymongrep")
        file(REMOVE "${_bindir}/bbhostgrep")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink xymongrep "${_bindir}/bbhostgrep")
    endif()
    if(EXISTS "${_bindir}/xymoncfg")
        file(REMOVE "${_bindir}/bbhostshow")
        execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink xymoncfg "${_bindir}/bbhostshow")
    endif()
]])
