cmake_minimum_required(VERSION 3.16)

project(xymon C)

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Xymon paths / identity (configurable, parity with Autotools)
# ----------------------------------------------------------------------

set(XYMONTOPDIR "/var/lib/xymon" CACHE STRING "Xymon top directory")
set(XYMONHOME "/var/lib/xymon/server" CACHE STRING "Xymon server home")
set(XYMONCLIENTHOME "/var/lib/xymon/client" CACHE STRING "Xymon client home")
set(XYMONLOGDIR "/var/log/xymon" CACHE STRING "Xymon log directory")
set(XYMONHOSTNAME "localhost" CACHE STRING "Xymon host name")
set(XYMONHOSTIP "127.0.0.1" CACHE STRING "Xymon host IP")
set(XYMONHOSTOS "linux" CACHE STRING "Xymon host OS")
set(XYMONHOSTURL "http://localhost" CACHE STRING "Xymon host URL")
set(XYMONCGIURL "/xymon-cgi" CACHE STRING "Xymon CGI URL")
set(SECUREXYMONCGIURL "/xymon-cgi" CACHE STRING "Xymon secure CGI URL")
set(XYMONVAR "/var/lib/xymon" CACHE STRING "Xymon var directory")
set(XYMONUSER "xymon" CACHE STRING "Xymon user")
set(RUNTIMEDEFS "" CACHE STRING "Runtime defs for scripts")
set(INSTALLETCDIR "/etc/xymon" CACHE STRING "Install etc directory")
set(INSTALLWWWDIR "/var/www/xymon" CACHE STRING "Install www directory")
set(INSTALLWEBDIR "/var/www/xymon/cgi-bin" CACHE STRING "Install web dir")
set(INSTALLBINDIR "/usr/local/bin" CACHE STRING "Install bin dir")
set(INSTALLEXTDIR "/usr/local/lib/xymon/ext" CACHE STRING "Install ext dir")
set(CGIDIR "/var/www/xymon/cgi-bin" CACHE STRING "CGI dir")
set(SECURECGIDIR "/var/www/xymon/cgi-secure" CACHE STRING "Secure CGI dir")
set(FPING "/usr/bin/fping" CACHE STRING "Path to fping")
set(MAILPROGRAM "/usr/sbin/sendmail -t" CACHE STRING "Mail program")

# ----------------------------------------------------------------------
# Parity rules:
# - No variants
# - No invented libraries
# - No code refactoring
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# Endianness (REQUIRED by sha1/sha2/rmd160c)
# Autotools sets this via config.h
# We must do it BEFORE configure_file()
# ----------------------------------------------------------------------

include(TestBigEndian)
test_big_endian(IS_BIG_ENDIAN)
if(IS_BIG_ENDIAN)
    set(WORDS_BIGENDIAN 1)
    set(WORDS_LITTLEENDIAN 0)
else()
    set(WORDS_BIGENDIAN 0)
    set(WORDS_LITTLEENDIAN 1)
endif()

# ----------------------------------------------------------------------
# Generate config.h (parity with Autotools, pure CMake)
# ----------------------------------------------------------------------

include(CheckIncludeFile)
include(CheckFunctionExists)
include(CheckSymbolExists)
include(CheckTypeSize)

check_include_file("rpc/rpcent.h" HAVE_RPCENT_H)
check_include_file("sys/select.h" HAVE_SYS_SELECT_H)

set(CMAKE_EXTRA_INCLUDE_FILES "sys/types.h;sys/socket.h")
check_type_size("socklen_t" SIZEOF_SOCKLEN_T)
check_type_size("u_int32_t" SIZEOF_U_INT32_T)
unset(CMAKE_EXTRA_INCLUDE_FILES)

check_function_exists(snprintf HAVE_SNPRINTF)
check_function_exists(vsnprintf HAVE_VSNPRINTF)
check_function_exists(strtoll HAVE_STRTOLL_H)
check_function_exists(uname HAVE_UNAME)
check_function_exists(setenv HAVE_SETENV)

check_symbol_exists(PATH_MAX "limits.h" HAVE_PATH_MAX)
check_symbol_exists(SHUT_RD "sys/socket.h" HAVE_SHUT_RD)
check_symbol_exists(SHUT_WR "sys/socket.h" HAVE_SHUT_WR)
check_symbol_exists(SHUT_RDWR "sys/socket.h" HAVE_SHUT_RDWR)

if(NOT HAVE_PATH_MAX)
    file(WRITE ${CMAKE_BINARY_DIR}/cmake_pathmax.c
"#include <stdio.h>\n#include <unistd.h>\n#include <limits.h>\nint main(void){\n#ifndef PATH_MAX\nlong res = pathconf(\"/\", _PC_PATH_MAX);\nif (res == -1) res = 4096;\nprintf(\"%ld\", res);\n#endif\nreturn 0;}\n")
    try_run(PATHMAX_RUN PATHMAX_COMPILE
        ${CMAKE_BINARY_DIR}
        ${CMAKE_BINARY_DIR}/cmake_pathmax.c
        RUN_OUTPUT_VARIABLE PATHMAX_OUTPUT
    )
    if(PATHMAX_COMPILE AND PATHMAX_RUN EQUAL 0 AND PATHMAX_OUTPUT MATCHES "^[0-9]+$")
        set(PATH_MAX_VALUE "${PATHMAX_OUTPUT}")
    else()
        set(PATH_MAX_VALUE 4096)
    endif()
endif()

file(WRITE ${CMAKE_BINARY_DIR}/config.h
"/* This file is auto-generated */\n#ifndef __CONFIG_H__\n#define __CONFIG_H__ 1\n\n")

file(APPEND ${CMAKE_BINARY_DIR}/config.h
"#define PACKAGE_NAME \"xymon\"\n#define PACKAGE_VERSION \"cmake\"\n\n")

file(APPEND ${CMAKE_BINARY_DIR}/config.h
"#define LINUX 1\n\n")

if(WORDS_LITTLEENDIAN)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define WORDS_LITTLEENDIAN 1\n/* #undef WORDS_BIGENDIAN */\n\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef WORDS_LITTLEENDIAN */\n#define WORDS_BIGENDIAN 1\n\n")
endif()

file(APPEND ${CMAKE_BINARY_DIR}/config.h
"#define XYMONTOPDIR   \"${XYMONTOPDIR}\"\n#define XYMONHOME     \"${XYMONHOME}\"\n#define XYMONCLIENTHOME \"${XYMONCLIENTHOME}\"\n#define XYMONLOGDIR   \"${XYMONLOGDIR}\"\n\n")

file(APPEND ${CMAKE_BINARY_DIR}/config.h
"#define XYMONHOSTNAME \"${XYMONHOSTNAME}\"\n#define XYMONHOSTIP   \"${XYMONHOSTIP}\"\n#define XYMONHOSTOS   \"${XYMONHOSTOS}\"\n\n")

if(ENABLE_SSL)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define ENABLE_SSL 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef ENABLE_SSL */\n")
endif()
if(ENABLE_LDAP)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define ENABLE_LDAP 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef ENABLE_LDAP */\n")
endif()

if(SIZEOF_SOCKLEN_T)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_SOCKLEN_T 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_SOCKLEN_T */\n")
endif()
if(HAVE_SNPRINTF)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_SNPRINTF 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_SNPRINTF */\n")
endif()
if(HAVE_VSNPRINTF)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_VSNPRINTF 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_VSNPRINTF */\n")
endif()
if(HAVE_RPCENT_H)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_RPCENT_H 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_RPCENT_H */\n")
endif()
if(HAVE_SYS_SELECT_H)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_SYS_SELECT_H 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_SYS_SELECT_H */\n")
endif()
if(SIZEOF_U_INT32_T)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_UINT32_TYPEDEF 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_UINT32_TYPEDEF */\n")
endif()
if(HAVE_STRTOLL_H)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_STRTOLL_H 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_STRTOLL_H */\n")
endif()
if(HAVE_UNAME)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_UNAME 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_UNAME */\n")
endif()
if(HAVE_SETENV)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define HAVE_SETENV 1\n")
else()
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_SETENV */\n")
endif()

if(NOT HAVE_PATH_MAX)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define PATH_MAX ${PATH_MAX_VALUE}\n")
endif()
if(NOT HAVE_SHUT_RD)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define SHUT_RD 0\n")
endif()
if(NOT HAVE_SHUT_WR)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define SHUT_WR 1\n")
endif()
if(NOT HAVE_SHUT_RDWR)
    file(APPEND ${CMAKE_BINARY_DIR}/config.h "#define SHUT_RDWR 2\n")
endif()

file(APPEND ${CMAKE_BINARY_DIR}/config.h "/* #undef HAVE_BINARY_TREE */\n\n#endif\n")

# ----------------------------------------------------------------------
# Global include paths
# ----------------------------------------------------------------------

include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/lib
    ${CMAKE_BINARY_DIR}
)

# ----------------------------------------------------------------------
# Global compile flags (observed in Make build)
# ----------------------------------------------------------------------

add_compile_options(
    -g
    -O2
    -Wall
    -Wno-unused
    -Wno-pointer-sign
    -include ${CMAKE_BINARY_DIR}/config.h
)

# ----------------------------------------------------------------------
# Global compile definitions
# (runtime / libc / largefile only)
# ----------------------------------------------------------------------

add_compile_definitions(
    _REENTRANT
    _LARGEFILE_SOURCE
    _FILE_OFFSET_BITS=64
    LINUX
)

# ----------------------------------------------------------------------
# Core libraries
# ----------------------------------------------------------------------

add_subdirectory(lib)

# ----------------------------------------------------------------------
# Server executables
# ----------------------------------------------------------------------

add_subdirectory(xymongen)

# ----------------------------------------------------------------------
# Common tools
# ----------------------------------------------------------------------

add_subdirectory(common)

# ----------------------------------------------------------------------
# Client tools
# ----------------------------------------------------------------------

add_subdirectory(client)

# ----------------------------------------------------------------------
# Xymond daemons
# ----------------------------------------------------------------------

add_subdirectory(xymond)

# ----------------------------------------------------------------------
# Xymon network tests
# ----------------------------------------------------------------------

add_subdirectory(xymonnet)

# ----------------------------------------------------------------------
# Web CGI tools
# ----------------------------------------------------------------------

add_subdirectory(web)

# ----------------------------------------------------------------------
# Docs
# ----------------------------------------------------------------------

add_subdirectory(docs)

# ----------------------------------------------------------------------
# Build tools (merge-lines, merge-sects, setup-newfiles, ...)
# ----------------------------------------------------------------------

add_subdirectory(build)
