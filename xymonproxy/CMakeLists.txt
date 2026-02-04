# xymonproxy/CMakeLists.txt

add_executable(xymonproxy
    xymonproxy.c
)
target_link_libraries(xymonproxy
    xymoncomm
    xymontime
    xymon
    ssl
    crypto
)

add_executable(xymoncgimsg.cgi
    xymoncgimsg.c
)
target_link_libraries(xymoncgimsg.cgi
    xymontime
    xymoncomm
    xymon
    ssl
    crypto
)

install(TARGETS xymonproxy xymoncgimsg.cgi
    RUNTIME DESTINATION ${INSTALLBINDIR}
)

install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/xymonproxy.8
    ${CMAKE_CURRENT_SOURCE_DIR}/xymoncgimsg.cgi.8
    DESTINATION ${XYMONHOME}/man/man8
)
