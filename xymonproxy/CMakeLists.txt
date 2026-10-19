# xymonproxy/CMakeLists.txt

add_executable(xymonproxy
    xymonproxy.c
)
target_link_libraries(xymonproxy
    xymoncomm
    xymontime
    xymon
    ${XYMON_SSL_LIBRARIES}
)

add_executable(xymoncgimsg.cgi
    xymoncgimsg.c
)
target_link_libraries(xymoncgimsg.cgi
    xymontime
    xymoncomm
    xymon
    ${XYMON_SSL_LIBRARIES}
)

install(TARGETS xymonproxy xymoncgimsg.cgi
    RUNTIME DESTINATION ${INSTALLBINDIR_DEST}
)

if(XYMON_INSTALL_MANPAGES)
    install(FILES
        ${CMAKE_CURRENT_SOURCE_DIR}/xymonproxy.8
        ${CMAKE_CURRENT_SOURCE_DIR}/xymoncgimsg.cgi.8
        DESTINATION ${INSTALLMAN8DIR_DEST}
    )
endif()
