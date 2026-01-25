cmake_minimum_required(VERSION 3.16)

project(xymon C)

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Parity rule:
# - No variants (server/client built together in Make)
# - No invented libraries
# - No extra warnings or errors
# - No architecture enforcement
# ----------------------------------------------------------------------

include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/lib
)

add_compile_options(
    -g
    -O2
    -Wall
    -Wno-unused
    -Wno-pointer-sign
)

add_compile_definitions(
    _REENTRANT
    _LARGEFILE_SOURCE
    _FILE_OFFSET_BITS=64
    LINUX
)

# ----------------------------------------------------------------------
# Parity stage 1: libraries only
# ----------------------------------------------------------------------

add_subdirectory(lib)

