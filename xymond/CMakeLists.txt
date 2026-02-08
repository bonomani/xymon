# xymond/CMakeLists.txt

add_executable(xymond
    xymond.c
)
target_link_libraries(xymond
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_channel
    xymond_channel.c
)
target_link_libraries(xymond_channel
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_locator
    xymond_locator.c
)
target_link_libraries(xymond_locator
    xymoncomm
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(xymond_filestore
    xymond_filestore.c
    xymond_worker.c
)
target_link_libraries(xymond_filestore
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_history
    xymond_history.c
    xymond_worker.c
)
target_link_libraries(xymond_history
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(xymond_alert
    xymond_alert.c
    xymond_worker.c
    do_alert.c
)
target_link_libraries(xymond_alert
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_sample
    xymond_sample.c
    xymond_worker.c
)
target_link_libraries(xymond_sample
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(xymond_client
    xymond_client.c
    xymond_worker.c
    client_config.c
)
target_link_libraries(xymond_client
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_hostdata
    xymond_hostdata.c
    xymond_worker.c
)
target_link_libraries(xymond_hostdata
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(xymond_capture
    xymond_capture.c
    xymond_worker.c
)
target_link_libraries(xymond_capture
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymond_distribute
    xymond_distribute.c
    xymond_worker.c
)
target_link_libraries(xymond_distribute
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(combostatus
    combostatus.c
)
target_link_libraries(combostatus
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(xymonfetch
    xymonfetch.c
)
target_link_libraries(xymonfetch
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(xymon_mailack
    xymon-mailack.c
)
set_target_properties(xymon_mailack PROPERTIES
    OUTPUT_NAME xymon-mailack
)
target_link_libraries(xymon_mailack
    xymoncomm
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(trimhistory
    trimhistory.c
)
target_link_libraries(trimhistory
    xymoncomm
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(convertnk
    convertnk.c
)
target_link_libraries(convertnk
    xymoncomm
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(rrdcachectl
    rrdcachectl.c
)
target_link_libraries(rrdcachectl
    xymoncomm
    xymontime
    xymoncomm
    ssl
    crypto
)

if(ENABLE_RRD)
    find_path(RRD_INCLUDE_DIR rrd.h)
    find_library(RRD_LIBRARY rrd)
    if(RRD_INCLUDE_DIR AND RRD_LIBRARY)
        add_executable(xymond_rrd
            xymond_rrd.c
            xymond_worker.c
            do_rrd.c
            client_config.c
        )
        target_compile_definitions(xymond_rrd PRIVATE RRDTOOL12)
        target_include_directories(xymond_rrd PRIVATE ${RRD_INCLUDE_DIR})
target_link_libraries(xymond_rrd
            xymontime
            xymoncomm
            ${RRD_LIBRARY}
            pcre
            ssl
            crypto
        )
    endif()
endif()

# ----------------------------------------------------------------------
# Config and script generation (parity with Makefile cfgfiles)
# ----------------------------------------------------------------------

set(XYMOND_CFGDIR ${CMAKE_CURRENT_BINARY_DIR}/etcfiles)
file(MAKE_DIRECTORY ${XYMOND_CFGDIR})

if(XYMONCGIURL STREQUAL SECUREXYMONCGIURL)
    set(_XYMON_APACHE_TEMPLATE ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/xymon-apache-open.DIST)
else()
    set(_XYMON_APACHE_TEMPLATE ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/xymon-apache-secure.DIST)
endif()

configure_file(
    ${_XYMON_APACHE_TEMPLATE}
    ${XYMOND_CFGDIR}/xymon-apache.conf
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/xymonserver.cfg.DIST
    ${XYMOND_CFGDIR}/xymonserver.cfg
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/hosts.cfg.DIST
    ${XYMOND_CFGDIR}/hosts.cfg
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/alerts.cfg.DIST
    ${XYMOND_CFGDIR}/alerts.cfg
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/tasks.cfg.DIST
    ${XYMOND_CFGDIR}/tasks.cfg
    @ONLY
)

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/cgioptions.cfg.DIST
    ${XYMOND_CFGDIR}/cgioptions.cfg
    @ONLY
)

execute_process(
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/../build/bb-commands.sh
    OUTPUT_VARIABLE _BB_COMMANDS
    RESULT_VARIABLE _BB_COMMANDS_RESULT
)
if(_BB_COMMANDS_RESULT EQUAL 0)
    file(APPEND ${XYMOND_CFGDIR}/xymonserver.cfg "${_BB_COMMANDS}")
endif()

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/xymon.sh.DIST
    ${CMAKE_CURRENT_BINARY_DIR}/xymon.sh
    @ONLY
)
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/xymonreports.sh.DIST
    ${CMAKE_CURRENT_BINARY_DIR}/xymonreports.sh
    @ONLY
)
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/moverrd.sh.DIST
    ${CMAKE_CURRENT_BINARY_DIR}/moverrd.sh
    @ONLY
)

add_custom_target(xymond_cfgfiles ALL
    DEPENDS
        ${XYMOND_CFGDIR}/xymon-apache.conf
        ${XYMOND_CFGDIR}/xymonserver.cfg
        ${XYMOND_CFGDIR}/hosts.cfg
        ${XYMOND_CFGDIR}/alerts.cfg
        ${XYMOND_CFGDIR}/tasks.cfg
        ${XYMOND_CFGDIR}/cgioptions.cfg
        ${CMAKE_CURRENT_BINARY_DIR}/xymon.sh
        ${CMAKE_CURRENT_BINARY_DIR}/xymonreports.sh
        ${CMAKE_CURRENT_BINARY_DIR}/moverrd.sh
)

# ----------------------------------------------------------------------
# Staged install config merge (parity with install-cfg)
# ----------------------------------------------------------------------

set(INSTALL_ETC_STAGING ${CMAKE_BINARY_DIR}/install/etc)
set(INSTALL_WWW_STAGING ${CMAKE_BINARY_DIR}/install/www)
set(INSTALL_WEB_STAGING ${CMAKE_BINARY_DIR}/install/web)

add_custom_target(xymond_install_cfg ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory ${INSTALL_ETC_STAGING}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${INSTALL_WWW_STAGING}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${INSTALL_WEB_STAGING}
    COMMAND $<TARGET_FILE:merge-lines> ${XYMOND_CFGDIR}/xymonserver.cfg ${INSTALL_ETC_STAGING}/xymonserver.cfg LARRDCOLUMN=TRENDSCOLUMN LARRDS=TEST2RRD
    COMMAND $<TARGET_FILE:merge-lines> ${XYMOND_CFGDIR}/cgioptions.cfg ${INSTALL_ETC_STAGING}/cgioptions.cfg
    COMMAND $<TARGET_FILE:merge-sects> ${XYMOND_CFGDIR}/tasks.cfg ${INSTALL_ETC_STAGING}/tasks.cfg larrdstatus=rrdstatus larrddata=rrddata
    COMMAND $<TARGET_FILE:merge-sects> ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/client-local.cfg ${INSTALL_ETC_STAGING}/client-local.cfg
    COMMAND $<TARGET_FILE:merge-sects> ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/graphs.cfg ${INSTALL_ETC_STAGING}/graphs.cfg
    COMMAND $<TARGET_FILE:merge-lines> ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/columndoc.csv ${INSTALL_ETC_STAGING}/columndoc.csv
    COMMAND ${CMAKE_COMMAND}
            -DSETUP_NEWFILES_EXE=$<TARGET_FILE:setup-newfiles>
            -DSETUP_NEWFILES_LIST=${SETUP_NEWFILES_LIST}
            -DINSTALL_ETC_STAGING=${INSTALL_ETC_STAGING}
            -P ${CMAKE_CURRENT_BINARY_DIR}/setup-newfiles.cmake
    DEPENDS
        xymond_cfgfiles
        merge-lines
        merge-sects
        setup-newfiles
        ${SETUP_NEWFILES_LIST}
)

add_dependencies(xymond_install_cfg setup-newfiles)

install(TARGETS
    xymond
    xymond_channel
    xymond_locator
    xymond_filestore
    xymond_history
    xymond_alert
    xymond_sample
    xymond_client
    xymond_hostdata
    xymond_capture
    xymond_distribute
    combostatus
    xymonfetch
    xymon_mailack
    trimhistory
    convertnk
    rrdcachectl
    RUNTIME DESTINATION ${INSTALLBINDIR}
)

if(TARGET xymond_rrd)
    install(TARGETS xymond_rrd
        RUNTIME DESTINATION ${INSTALLBINDIR}
    )
endif()

install(FILES
    ${XYMOND_CFGDIR}/xymon-apache.conf
    ${XYMOND_CFGDIR}/xymonserver.cfg
    ${XYMOND_CFGDIR}/hosts.cfg
    ${XYMOND_CFGDIR}/alerts.cfg
    ${XYMOND_CFGDIR}/tasks.cfg
    ${XYMOND_CFGDIR}/cgioptions.cfg
    DESTINATION ${INSTALLETCDIR}
)

set(_LEGACY_ETC_FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/analysis.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/combo.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/critical.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/graphs.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/holidays.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/rrddefinitions.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/snmpmibs.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/xymonmenu.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/client-local.cfg
    ${CMAKE_CURRENT_SOURCE_DIR}/etcfiles/columndoc.csv
)
install(FILES ${_LEGACY_ETC_FILES}
    DESTINATION ${INSTALLETCDIR}
)

install(PROGRAMS
    ${CMAKE_CURRENT_BINARY_DIR}/xymon.sh
    ${CMAKE_CURRENT_BINARY_DIR}/xymonreports.sh
    ${CMAKE_CURRENT_BINARY_DIR}/moverrd.sh
    DESTINATION ${INSTALLBINDIR}
)

file(GLOB _XYMOND_MAN1 "${CMAKE_CURRENT_SOURCE_DIR}/*.1")
file(GLOB _XYMOND_MAN5 "${CMAKE_CURRENT_SOURCE_DIR}/*.5")
file(GLOB _XYMOND_MAN8 "${CMAKE_CURRENT_SOURCE_DIR}/*.8")
install(FILES ${_XYMOND_MAN1}
    DESTINATION ${XYMONHOME}/man/man1
)
install(FILES ${_XYMOND_MAN5}
    DESTINATION ${XYMONHOME}/man/man5
)
install(FILES ${_XYMOND_MAN8}
    DESTINATION ${XYMONHOME}/man/man8
)

install(CODE "
set(_dest \"\$ENV{DESTDIR}\")
if(_dest STREQUAL \"\")
  set(_dest \"\")
endif()
set(_etc \"\${_dest}${INSTALLETCDIR}\")
set(_critical_cfg \"\${_etc}/critical.cfg\")
set(_critical_cfg_bak \"\${_etc}/critical.cfg.bak\")
if(EXISTS \"\${_critical_cfg}\")
  execute_process(COMMAND \"${CMAKE_COMMAND}\" -E copy_if_different \"\${_critical_cfg}\" \"\${_critical_cfg_bak}\")
else()
  execute_process(COMMAND \"${CMAKE_COMMAND}\" -E touch \"\${_critical_cfg}\")
  execute_process(COMMAND \"${CMAKE_COMMAND}\" -E touch \"\${_critical_cfg_bak}\")
endif()
execute_process(COMMAND /bin/chmod 664 \"\${_critical_cfg}\")
execute_process(COMMAND /bin/chmod 664 \"\${_critical_cfg_bak}\")
file(MAKE_DIRECTORY \"\${_etc}/tasks.d\")
set(_server_root \"\${_dest}${XYMONHOME}\")
if(EXISTS \"\${_server_root}/bin/xymon.sh\")
  execute_process(COMMAND \"${CMAKE_COMMAND}\" -E create_symlink \"bin/xymon.sh\" \"\${_server_root}/xymon.sh\")
endif()
")

install(CODE "
if(HTTPDGID_CHGRP AND NOT \"${HTTPDGID}\" STREQUAL \"\")
  foreach(_dir \"${INSTALLWWWDIR}/rep\" \"${INSTALLWWWDIR}/snap\")
    if(EXISTS \"\$ENV{DESTDIR}\${_dir}\")
      execute_process(
        COMMAND chgrp \"${HTTPDGID}\" \"\$ENV{DESTDIR}\${_dir}\"
        RESULT_VARIABLE _chgrp_res
      )
      if(NOT _chgrp_res EQUAL 0)
        message(STATUS \"chgrp failed for \${_dir} (group ${HTTPDGID})\")
      endif()
    endif()
  endforeach()
endif()
")

# Generate a CMake script to feed setup-newfiles via INPUT_FILE (no shell).
set(SETUP_NEWFILES_LIST ${CMAKE_BINARY_DIR}/setup-newfiles.list)
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/setup-newfiles.cmake
"execute_process(\n"
"  COMMAND \\\"${CMAKE_COMMAND}\\\" -P \\\"${CMAKE_CURRENT_BINARY_DIR}/write-setup-newfiles-list.cmake\\\"\n"
")\n"
"execute_process(\n"
"  COMMAND \\\"${SETUP_NEWFILES_EXE}\\\" \\\"${INSTALL_ETC_STAGING}/\\\"\n"
"  INPUT_FILE \\\"${SETUP_NEWFILES_LIST}\\\"\n"
")\n"
)

file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/write-setup-newfiles-list.cmake
"file(WRITE \\\"${SETUP_NEWFILES_LIST}\\\" \"hosts.cfg\\nalerts.cfg\\nanalysis.cfg\\ncombo.cfg\\nclient-local.cfg\\nholidays.cfg\\nrrddefinitions.cfg\\nsnmpmibs.cfg\\nxymonmenu.cfg\\nxymon-apache.conf\\n\")\n"
)

add_custom_command(
    OUTPUT ${SETUP_NEWFILES_LIST}
    COMMAND ${CMAKE_COMMAND} -P ${CMAKE_CURRENT_BINARY_DIR}/write-setup-newfiles-list.cmake
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/write-setup-newfiles-list.cmake
)
