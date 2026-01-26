# server/CMakeLists.txt
#
# Parity stage 3:
# - Define exactly one real server executable from the Make build
# - No refactoring
# - No extra flags or includes

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
    xymoncomm
    xymontime
)

