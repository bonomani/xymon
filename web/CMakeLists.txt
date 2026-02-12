# web/CMakeLists.txt

add_executable(history.cgi history.c)
target_link_libraries(history.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(eventlog.cgi eventlog.c)
target_link_libraries(eventlog.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(report.cgi report.c)
target_link_libraries(report.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(reportlog.cgi reportlog.c)
target_link_libraries(reportlog.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(snapshot.cgi snapshot.c)
target_link_libraries(snapshot.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(findhost.cgi findhost.c)
target_link_libraries(findhost.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(csvinfo.cgi csvinfo.c)
target_link_libraries(csvinfo.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(acknowledge.cgi acknowledge.c)
target_link_libraries(acknowledge.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(xymonpage xymonpage.c)
target_link_libraries(xymonpage xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(datepage.cgi datepage.c)
target_link_libraries(datepage.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(svcstatus.cgi
    svcstatus.c
    svcstatus-info.c
    svcstatus-trends.c
)
target_link_libraries(svcstatus.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(enadis.cgi enadis.c)
target_link_libraries(enadis.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(confreport.cgi confreport.c)
target_link_libraries(confreport.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(criticalview.cgi criticalview.c)
target_link_libraries(criticalview.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(criticaleditor.cgi criticaleditor.c)
target_link_libraries(criticaleditor.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(ackinfo.cgi ackinfo.c)
target_link_libraries(ackinfo.cgi xymoncomm xymontime xymoncomm ssl crypto)

add_executable(statusreport.cgi statusreport.c)
target_link_libraries(statusreport.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(boilerplate.cgi boilerplate.c)
target_link_libraries(boilerplate.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(hostgraphs.cgi hostgraphs.c)
target_link_libraries(hostgraphs.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(ghostlist.cgi ghostlist.c)
target_link_libraries(ghostlist.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(notifications.cgi notifications.c)
target_link_libraries(notifications.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(acknowledgements.cgi acknowledgements.c)
target_link_libraries(acknowledgements.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(hostlist.cgi hostlist.c)
target_link_libraries(hostlist.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(useradm.cgi useradm.c)
target_link_libraries(useradm.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(chpasswd.cgi chpasswd.c)
target_link_libraries(chpasswd.cgi xymoncomm xymontime xymoncomm pcre ssl crypto)

add_executable(appfeed.cgi appfeed.c)
target_link_libraries(appfeed.cgi xymoncomm xymontime xymoncomm xymon pcre ssl crypto)

add_executable(cgiwrap cgiwrap.c)
target_compile_definitions(cgiwrap PRIVATE XYMONHOME=\"${XYMONHOME}\")
target_link_libraries(cgiwrap xymoncomm xymontime xymoncomm pcre ssl crypto)

if(ENABLE_RRD)
    find_path(RRD_INCLUDE_DIR rrd.h)
    find_library(RRD_LIBRARY rrd)
    if(RRD_INCLUDE_DIR AND RRD_LIBRARY)
        set(_WEB_RRD_EXTRA_LIBS)
        find_library(PNG_LIBRARY NAMES png16 png)
        if(PNG_LIBRARY)
            list(APPEND _WEB_RRD_EXTRA_LIBS "${PNG_LIBRARY}")
        endif()

        add_executable(showgraph.cgi showgraph.c)
        target_compile_definitions(showgraph.cgi PRIVATE RRDTOOL12)
        target_include_directories(showgraph.cgi PRIVATE ${RRD_INCLUDE_DIR})
        target_link_libraries(showgraph.cgi xymoncomm xymontime xymoncomm pcre ssl crypto ${RRD_LIBRARY} ${_WEB_RRD_EXTRA_LIBS})

        add_executable(perfdata.cgi perfdata.c)
        target_compile_definitions(perfdata.cgi PRIVATE RRDTOOL12)
        target_include_directories(perfdata.cgi PRIVATE ${RRD_INCLUDE_DIR})
        target_link_libraries(perfdata.cgi xymoncomm xymontime xymoncomm pcre ssl crypto ${RRD_LIBRARY} ${_WEB_RRD_EXTRA_LIBS} m)
    endif()
endif()

install(TARGETS
    history.cgi
    eventlog.cgi
    report.cgi
    reportlog.cgi
    snapshot.cgi
    findhost.cgi
    csvinfo.cgi
    acknowledge.cgi
    xymonpage
    datepage.cgi
    svcstatus.cgi
    enadis.cgi
    confreport.cgi
    criticalview.cgi
    criticaleditor.cgi
    ackinfo.cgi
    statusreport.cgi
    boilerplate.cgi
    hostgraphs.cgi
    ghostlist.cgi
    notifications.cgi
    acknowledgements.cgi
    hostlist.cgi
    useradm.cgi
    chpasswd.cgi
    appfeed.cgi
    cgiwrap
    RUNTIME DESTINATION ${INSTALLBINDIR}
)

if(TARGET showgraph.cgi)
    install(TARGETS showgraph.cgi
        RUNTIME DESTINATION ${INSTALLBINDIR}
    )
endif()
if(TARGET perfdata.cgi)
    install(TARGETS perfdata.cgi
        RUNTIME DESTINATION ${INSTALLBINDIR}
    )
endif()

install(DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/cgi/
    DESTINATION ${CGIDIR}
    USE_SOURCE_PERMISSIONS
    PATTERN ".stamp" EXCLUDE
)
install(DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/cgi-secure/
    DESTINATION ${SECURECGIDIR}
    USE_SOURCE_PERMISSIONS
    PATTERN ".stamp" EXCLUDE
)

file(GLOB _WEB_MAN1 "${CMAKE_CURRENT_SOURCE_DIR}/*.1")
file(GLOB _WEB_MAN5 "${CMAKE_CURRENT_SOURCE_DIR}/*.5")
file(GLOB _WEB_MAN8 "${CMAKE_CURRENT_SOURCE_DIR}/*.8")

install(FILES ${_WEB_MAN1}
    DESTINATION ${XYMONHOME}/man/man1
)
install(FILES ${_WEB_MAN5}
    DESTINATION ${XYMONHOME}/man/man5
)
install(FILES ${_WEB_MAN8}
    DESTINATION ${XYMONHOME}/man/man8
)

# ----------------------------------------------------------------------
# CGI script symlinks (parity with install-cgi)
# ----------------------------------------------------------------------

set(_CGI_SCRIPT_NAMES
    history.sh
    eventlog.sh
    report.sh
    reportlog.sh
    snapshot.sh
    findhost.sh
    csvinfo.sh
    columndoc.sh
    datepage.sh
    svcstatus.sh
    historylog.sh
    confreport.sh
    confreport-critical.sh
    criticalview.sh
    certreport.sh
    nongreen.sh
    hostgraphs.sh
    ghostlist.sh
    notifications.sh
    acknowledgements.sh
    hostlist.sh
    perfdata.sh
    topchanges.sh
    showgraph.sh
    appfeed.sh
    appfeed-critical.sh
)

set(_SEC_CGI_SCRIPT_NAMES
    acknowledge.sh
    enadis.sh
    criticaleditor.sh
    ackinfo.sh
    useradm.sh
    chpasswd.sh
)

set(_CGI_DIR ${CMAKE_CURRENT_BINARY_DIR}/cgi)
set(_SEC_CGI_DIR ${CMAKE_CURRENT_BINARY_DIR}/cgi-secure)

add_custom_command(
    OUTPUT ${_CGI_DIR}/.stamp ${_SEC_CGI_DIR}/.stamp
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_CGI_DIR} ${_SEC_CGI_DIR}
    COMMAND ${CMAKE_COMMAND} -E touch ${_CGI_DIR}/.stamp ${_SEC_CGI_DIR}/.stamp
    DEPENDS cgiwrap
)

add_custom_target(web_cgi_links ALL
    DEPENDS ${_CGI_DIR}/.stamp ${_SEC_CGI_DIR}/.stamp
)

foreach(_cgi ${_CGI_SCRIPT_NAMES})
    add_custom_command(
        TARGET web_cgi_links POST_BUILD
        # Bullseye ships CMake 3.18, which lacks `cmake -E create_hardlink`.
        COMMAND ln -f
                $<TARGET_FILE:cgiwrap>
                ${_CGI_DIR}/${_cgi}
    )
endforeach()

foreach(_cgi ${_SEC_CGI_SCRIPT_NAMES})
    add_custom_command(
        TARGET web_cgi_links POST_BUILD
        COMMAND ln -f
                $<TARGET_FILE:cgiwrap>
                ${_SEC_CGI_DIR}/${_cgi}
    )
endforeach()
