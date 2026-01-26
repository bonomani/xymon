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

# Generate config.h (parity with Autotools ./configure)
configure_file(
    ${CMAKE_SOURCE_DIR}/config.h.in
    ${CMAKE_BINARY_DIR}/config.h
)

# Global include paths observed in the build
include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/lib
    ${CMAKE_BINARY_DIR}
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
# Parity stage 1–2: core libraries
# ----------------------------------------------------------------------

add_subdirectory(lib)

# ----------------------------------------------------------------------
# Parity stage 3: first server executable
# ----------------------------------------------------------------------

add_subdirectory(xymongen)

