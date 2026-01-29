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
