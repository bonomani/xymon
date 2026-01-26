# xymongen/CMakeLists.txt
#
# Parity stage 3:
# - One real executable: xymongen
# - Real filesystem layout
# - No refactoring
# - No extra flags

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

