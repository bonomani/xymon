# server/CMakeLists.txt
#
# Parity stage 3:
# - One real server executable
# - Explicit paths (no guessing by CMake)
# - No refactoring
# - No extra flags

add_executable(xymongen
    ${CMAKE_SOURCE_DIR}/server/xymongen.c
    ${CMAKE_SOURCE_DIR}/server/loadlayout.c
    ${CMAKE_SOURCE_DIR}/server/loaddata.c
    ${CMAKE_SOURCE_DIR}/server/pagegen.c
    ${CMAKE_SOURCE_DIR}/server/process.c
    ${CMAKE_SOURCE_DIR}/server/wmlgen.c
    ${CMAKE_SOURCE_DIR}/server/rssgen.c
    ${CMAKE_SOURCE_DIR}/server/util.c
    ${CMAKE_SOURCE_DIR}/server/debug.c
    ${CMAKE_SOURCE_DIR}/server/csvreport.c
)

target_link_libraries(xymongen
    xymoncomm
    xymontime
)

