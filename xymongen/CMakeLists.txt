# xymongen/CMakeLists.txt
#
# Parity stage 3:
# - One real executable: xymongen
# - Real filesystem layout
# - No refactoring
# - No extra compile flags
# - Explicitly link required external libraries

add_executable(xymongen
    xymongen.c
    loadlayout.c
    loaddata.c
    pagegen.c
    process.c
    wmlgen.c
    rssgen.c
    util.c
    debug.c
    csvreport.c
)

target_link_libraries(xymongen
    xymon
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

install(TARGETS xymongen
    RUNTIME DESTINATION ${INSTALLBINDIR}
)

install(FILES
    ${CMAKE_CURRENT_SOURCE_DIR}/xymongen.1
    DESTINATION ${XYMONHOME}/man/man1
)
