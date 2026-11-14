# build/CMakeLists.txt

add_executable(merge-lines merge-lines.c)
add_executable(merge-sects merge-sects.c)

add_executable(setup-newfiles setup-newfiles.c)
target_link_libraries(setup-newfiles xymonclient)
