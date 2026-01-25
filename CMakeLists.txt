cmake_minimum_required(VERSION 3.16)

project(xymon C)

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Parity rule:
# - No variants (server/client are built together in the Make build)
# - No invented libraries
# - No extra warnings or errors
# - No architecture enforcement at this stage
# ----------------------------------------------------------------------

# Global include paths observed in the build
include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/lib
)

# Global compile flags observed everywhere
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
# Build structure mirrors real artifacts, not architecture intent
# ----------------------------------------------------------------------

add_subdirectory(lib)

