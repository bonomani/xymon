cmake_minimum_required(VERSION 3.16)

project(xymon C)

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Xymon paths / identity (configurable, parity with Autotools)
# ----------------------------------------------------------------------

option(USE_GNUINSTALLDIRS "Use GNUInstallDirs layout (FHS-style) instead of legacy Xymon layout" OFF)

set(XYMONHOSTNAME "localhost" CACHE STRING "Xymon host name")
set(XYMONHOSTIP "127.0.0.1" CACHE STRING "Xymon host IP")
set(XYMONHOSTOS "linux" CACHE STRING "Xymon host OS")
set(XYMONHOSTURL "http://localhost" CACHE STRING "Xymon host URL")
set(XYMONCGIURL "/xymon-cgi" CACHE STRING "Xymon CGI URL")
set(SECUREXYMONCGIURL "/xymon-seccgi" CACHE STRING "Xymon secure CGI URL")
set(XYMONUSER "xymon" CACHE STRING "Xymon user")
set(HTTPDGID "nobody" CACHE STRING "Webserver group for reports/snap directories")
option(HTTPDGID_CHGRP "Apply HTTPDGID chgrp during install" ON)
option(ENABLE_RRD "Build rrd-based components" ON)
option(ENABLE_LDAP "Enable LDAP checks" ON)
set(XYMON_VARIANT "all" CACHE STRING "Build variant: all, server, or client")
option(LOCALCLIENT "Enable local client configuration (client-only builds)" OFF)
set(RUNTIMEDEFS "" CACHE STRING "Runtime defs for scripts")
set(MANROOT "/usr/local/man" CACHE STRING "Man page root")
option(ENABLE_SSL "Enable SSL checks" ON)

if(NOT USE_GNUINSTALLDIRS)
    set(XYMONTOPDIR "/var/lib/xymon" CACHE STRING "Xymon top directory")
    set(XYMONHOME "/var/lib/xymon/server" CACHE STRING "Xymon server home")
    set(XYMONCLIENTHOME "/var/lib/xymon/client" CACHE STRING "Xymon client home")
    set(XYMONVAR "/var/lib/xymon/data" CACHE STRING "Xymon var directory")
    set(XYMONLOGDIR "/var/log/xymon" CACHE STRING "Xymon log directory")
    set(INSTALLETCDIR "/var/lib/xymon/server/etc" CACHE STRING "Install etc directory")
    set(INSTALLWWWDIR "/var/lib/xymon/server/www" CACHE STRING "Install www directory")
    set(INSTALLWEBDIR "/var/lib/xymon/server/web" CACHE STRING "Install web dir")
    set(INSTALLBINDIR "/var/lib/xymon/server/bin" CACHE STRING "Install bin dir")
    set(INSTALLEXTDIR "/var/lib/xymon/server/ext" CACHE STRING "Install ext dir")
    set(INSTALLTMPDIR "/var/lib/xymon/server/tmp" CACHE STRING "Install tmp dir")
    set(CGIDIR "/var/lib/xymon/cgi-bin" CACHE STRING "CGI dir")
    set(SECURECGIDIR "/var/lib/xymon/cgi-secure" CACHE STRING "Secure CGI dir")
else()
    include(GNUInstallDirs)

    set(XYMONTOPDIR "${CMAKE_INSTALL_PREFIX}/xymon" CACHE STRING "Xymon top directory" FORCE)
    set(XYMONHOME "${XYMONTOPDIR}/server" CACHE STRING "Xymon server home" FORCE)
    set(XYMONCLIENTHOME "${XYMONTOPDIR}/client" CACHE STRING "Xymon client home" FORCE)
    set(XYMONVAR "${CMAKE_INSTALL_LOCALSTATEDIR}/lib/xymon/data" CACHE STRING "Xymon var directory" FORCE)
    set(XYMONLOGDIR "${CMAKE_INSTALL_LOCALSTATEDIR}/log/xymon" CACHE STRING "Xymon log directory" FORCE)

    set(INSTALLBINDIR "${CMAKE_INSTALL_BINDIR}" CACHE STRING "Install bin dir" FORCE)
    set(INSTALLETCDIR "${CMAKE_INSTALL_SYSCONFDIR}/xymon" CACHE STRING "Install etc directory" FORCE)
    set(INSTALLEXTDIR "${CMAKE_INSTALL_LIBDIR}/xymon/ext" CACHE STRING "Install ext dir" FORCE)
    set(INSTALLTMPDIR "${CMAKE_INSTALL_LOCALSTATEDIR}/tmp/xymon" CACHE STRING "Install tmp dir" FORCE)
    set(INSTALLWEBDIR "${CMAKE_INSTALL_DATADIR}/xymon/web" CACHE STRING "Install web dir" FORCE)
    set(INSTALLWWWDIR "${CMAKE_INSTALL_DATADIR}/xymon/www" CACHE STRING "Install www directory" FORCE)

    set(CGIDIR "${CMAKE_INSTALL_DATADIR}/xymon/cgi-bin" CACHE STRING "CGI dir" FORCE)
    set(SECURECGIDIR "${CMAKE_INSTALL_DATADIR}/xymon/cgi-secure" CACHE STRING "Secure CGI dir" FORCE)
    set(MANROOT "${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_MANDIR}" CACHE STRING "Man page root" FORCE)
endif()

# Optional dependency overrides (used by cmake-local-setup.sh)
set(RRDINCDIR "" CACHE STRING "RRD include dir override")
set(RRDLIBDIR "" CACHE STRING "RRD library dir override")
set(PCREINCDIR "" CACHE STRING "PCRE include dir override")
set(PCRELIBDIR "" CACHE STRING "PCRE library dir override")
set(SSLINCDIR "" CACHE STRING "OpenSSL include dir override")
set(SSLLIBDIR "" CACHE STRING "OpenSSL library dir override")
set(LDAPINCDIR "" CACHE STRING "LDAP include dir override")
set(LDAPLIBDIR "" CACHE STRING "LDAP library dir override")
set(CARESINCDIR "" CACHE STRING "C-ARES include dir override")
set(CARESLIBDIR "" CACHE STRING "C-ARES library dir override")

# Best-effort auto-detection (only fills empty overrides)
if(NOT RRDINCDIR)
    unset(RRDINCDIR CACHE)
    find_path(RRDINCDIR NAMES rrd.h)
endif()
if(NOT RRDLIBDIR)
    find_library(_RRD_LIB NAMES rrd)
    if(_RRD_LIB)
        get_filename_component(RRDLIBDIR "${_RRD_LIB}" DIRECTORY)
    endif()
endif()

if(NOT PCREINCDIR)
    unset(PCREINCDIR CACHE)
    find_path(PCREINCDIR NAMES pcre.h)
endif()
if(NOT PCRELIBDIR)
    find_library(_PCRE_LIB NAMES pcre)
    if(_PCRE_LIB)
        get_filename_component(PCRELIBDIR "${_PCRE_LIB}" DIRECTORY)
    endif()
endif()

if(NOT SSLINCDIR)
    unset(SSLINCDIR CACHE)
    find_path(SSLINCDIR NAMES openssl/ssl.h)
endif()
if(NOT SSLLIBDIR)
    find_library(_SSL_LIB NAMES ssl)
    if(_SSL_LIB)
        get_filename_component(SSLLIBDIR "${_SSL_LIB}" DIRECTORY)
    endif()
endif()

if(NOT LDAPINCDIR)
    unset(LDAPINCDIR CACHE)
    find_path(LDAPINCDIR NAMES ldap.h)
endif()
if(NOT LDAPLIBDIR)
    find_library(_LDAP_LIB NAMES ldap)
    if(_LDAP_LIB)
        get_filename_component(LDAPLIBDIR "${_LDAP_LIB}" DIRECTORY)
    endif()
endif()

if(NOT CARESINCDIR)
    unset(CARESINCDIR CACHE)
    find_path(CARESINCDIR NAMES ares.h)
endif()
if(NOT CARESLIBDIR)
    find_library(_CARES_LIB NAMES cares)
    if(_CARES_LIB)
        get_filename_component(CARESLIBDIR "${_CARES_LIB}" DIRECTORY)
    endif()
endif()

# Persist detected values for reporting
set(RRDINCDIR "${RRDINCDIR}" CACHE STRING "RRD include dir override" FORCE)
set(RRDLIBDIR "${RRDLIBDIR}" CACHE STRING "RRD library dir override" FORCE)
set(PCREINCDIR "${PCREINCDIR}" CACHE STRING "PCRE include dir override" FORCE)
set(PCRELIBDIR "${PCRELIBDIR}" CACHE STRING "PCRE library dir override" FORCE)
set(SSLINCDIR "${SSLINCDIR}" CACHE STRING "OpenSSL include dir override" FORCE)
set(SSLLIBDIR "${SSLLIBDIR}" CACHE STRING "OpenSSL library dir override" FORCE)
set(LDAPINCDIR "${LDAPINCDIR}" CACHE STRING "LDAP include dir override" FORCE)
set(LDAPLIBDIR "${LDAPLIBDIR}" CACHE STRING "LDAP library dir override" FORCE)
set(CARESINCDIR "${CARESINCDIR}" CACHE STRING "C-ARES include dir override" FORCE)
set(CARESLIBDIR "${CARESLIBDIR}" CACHE STRING "C-ARES library dir override" FORCE)
set(INSTALLETCDIR "/var/lib/xymon/server/etc" CACHE STRING "Install etc directory")
set(INSTALLWWWDIR "/var/lib/xymon/server/www" CACHE STRING "Install www directory")
set(INSTALLWEBDIR "/var/lib/xymon/server/web" CACHE STRING "Install web dir")
set(INSTALLBINDIR "/var/lib/xymon/server/bin" CACHE STRING "Install bin dir")
set(INSTALLEXTDIR "/var/lib/xymon/server/ext" CACHE STRING "Install ext dir")
set(INSTALLTMPDIR "/var/lib/xymon/server/tmp" CACHE STRING "Install tmp dir")
set(CGIDIR "/var/lib/xymon/cgi-bin" CACHE STRING "CGI dir")
set(SECURECGIDIR "/var/lib/xymon/cgi-secure" CACHE STRING "Secure CGI dir")
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

# Optional include/lib overrides (only applied when provided)
set(_XYMON_EXTRA_INCLUDES "")
set(_XYMON_EXTRA_LIBDIRS "")
foreach(_dir IN LISTS RRDINCDIR PCREINCDIR SSLINCDIR LDAPINCDIR CARESINCDIR)
    if(_dir)
        list(APPEND _XYMON_EXTRA_INCLUDES "${_dir}")
    endif()
endforeach()
foreach(_dir IN LISTS RRDLIBDIR PCRELIBDIR SSLLIBDIR LDAPLIBDIR CARESLIBDIR)
    if(_dir)
        list(APPEND _XYMON_EXTRA_LIBDIRS "${_dir}")
    endif()
endforeach()
if(_XYMON_EXTRA_INCLUDES)
    include_directories(${_XYMON_EXTRA_INCLUDES})
endif()
if(_XYMON_EXTRA_LIBDIRS)
    link_directories(${_XYMON_EXTRA_LIBDIRS})
endif()

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
)

# ----------------------------------------------------------------------
# OS-specific settings (parity with build/Makefile.<OS>)
# ----------------------------------------------------------------------

set(XYMON_EXTRA_CFLAGS "")
set(XYMON_EXTRA_INCLUDES "")
set(XYMON_EXTRA_LIBDIRS "")
set(XYMON_NETLIBS "")

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(XYMON_OSDEF LINUX)
    set(XYMON_NETLIBS tirpc)
    list(APPEND XYMON_EXTRA_INCLUDES /usr/include/tirpc)
    list(APPEND XYMON_EXTRA_CFLAGS -Wno-pointer-sign)
elseif(CMAKE_SYSTEM_NAME STREQUAL "FreeBSD")
    set(XYMON_OSDEF BSD)
    list(APPEND XYMON_EXTRA_INCLUDES /usr/local/include)
    list(APPEND XYMON_EXTRA_LIBDIRS /usr/local/lib)
    list(APPEND XYMON_EXTRA_CFLAGS -Wno-pointer-sign)
elseif(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
    set(XYMON_OSDEF BSD)
    if(EXISTS "/usr/pkg/include")
        list(APPEND XYMON_EXTRA_INCLUDES /usr/pkg/include)
        list(APPEND XYMON_EXTRA_LIBDIRS /usr/pkg/lib)
        set(XYMON_NETBSD_RPATH "/usr/pkg/lib")
    elseif(EXISTS "/usr/local/include")
        list(APPEND XYMON_EXTRA_INCLUDES /usr/local/include)
        list(APPEND XYMON_EXTRA_LIBDIRS /usr/local/lib)
    endif()
    list(APPEND XYMON_EXTRA_CFLAGS -Wno-pointer-sign)
elseif(CMAKE_SYSTEM_NAME STREQUAL "OpenBSD")
    set(XYMON_OSDEF BSD)
    list(APPEND XYMON_EXTRA_INCLUDES /usr/local/include)
    list(APPEND XYMON_EXTRA_LIBDIRS /usr/local/lib)
    list(APPEND XYMON_EXTRA_CFLAGS -Wno-pointer-sign)
elseif(CMAKE_SYSTEM_NAME STREQUAL "SunOS")
    set(XYMON_OSDEF SunOS)
    set(XYMON_NETLIBS resolv socket nsl)
    list(APPEND XYMON_EXTRA_CFLAGS -Wno-pointer-sign)
    set(MAILPROGRAM "mailx" CACHE STRING "Mail program" FORCE)
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(XYMON_OSDEF Darwin)
    list(APPEND XYMON_EXTRA_CFLAGS -DBIND_8_COMPAT=1 -D_BSD_SOCKLEN_T_=int)
elseif(CMAKE_SYSTEM_NAME STREQUAL "HP-UX")
    set(XYMON_OSDEF HPUX)
    set(XYMON_NETLIBS nsl)
    set(MAILPROGRAM "mailx" CACHE STRING "Mail program" FORCE)
elseif(CMAKE_SYSTEM_NAME STREQUAL "IRIX")
    set(XYMON_OSDEF IRIX)
elseif(CMAKE_SYSTEM_NAME STREQUAL "OSF1")
    set(XYMON_OSDEF OSF)
elseif(CMAKE_SYSTEM_NAME STREQUAL "AIX")
    set(XYMON_OSDEF AIX)
elseif(CMAKE_SYSTEM_NAME STREQUAL "SCO_SV")
    set(XYMON_OSDEF SCO_SV)
    set(XYMON_NETLIBS socket nsl)
    set(MAILPROGRAM "mailx" CACHE STRING "Mail program" FORCE)
elseif(CMAKE_SYSTEM_NAME STREQUAL "GNU")
    set(XYMON_OSDEF LINUX)
elseif(CMAKE_SYSTEM_NAME STREQUAL "GNU/kFreeBSD")
    set(XYMON_OSDEF "")
else()
    set(XYMON_OSDEF generic)
endif()

# RPATH parity: enabled on Linux/FreeBSD/GNU/GNU_kFreeBSD when not PKGBUILD
if(NOT PKGBUILD)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux" OR
       CMAKE_SYSTEM_NAME STREQUAL "FreeBSD" OR
       CMAKE_SYSTEM_NAME STREQUAL "GNU" OR
       CMAKE_SYSTEM_NAME STREQUAL "GNU/kFreeBSD")
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,--rpath,")
    endif()
endif()

if(XYMON_OSDEF)
    add_compile_definitions(${XYMON_OSDEF})
endif()
if(XYMON_EXTRA_CFLAGS)
    add_compile_options(${XYMON_EXTRA_CFLAGS})
endif()
if(XYMON_EXTRA_INCLUDES)
    include_directories(${XYMON_EXTRA_INCLUDES})
endif()
if(XYMON_EXTRA_LIBDIRS)
    link_directories(${XYMON_EXTRA_LIBDIRS})
endif()
if(XYMON_VARIANT STREQUAL "client")
    add_compile_definitions(CLIENTONLY)
endif()
if(LOCALCLIENT)
    add_compile_definitions(LOCALCLIENT)
endif()
if(XYMON_NETLIBS)
    link_libraries(${XYMON_NETLIBS})
endif()

if(XYMON_NETBSD_RPATH)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -Wl,--rpath=${XYMON_NETBSD_RPATH}")
endif()

string(TOLOWER "${XYMON_VARIANT}" XYMON_VARIANT)
if(NOT XYMON_VARIANT STREQUAL "all" AND
   NOT XYMON_VARIANT STREQUAL "server" AND
   NOT XYMON_VARIANT STREQUAL "client")
    message(FATAL_ERROR "XYMON_VARIANT must be one of: all, server, client")
endif()

set(XYMON_BUILD_SERVER OFF)
set(XYMON_BUILD_CLIENT OFF)
if(XYMON_VARIANT STREQUAL "all")
    set(XYMON_BUILD_SERVER ON)
    set(XYMON_BUILD_CLIENT ON)
elseif(XYMON_VARIANT STREQUAL "server")
    set(XYMON_BUILD_SERVER ON)
elseif(XYMON_VARIANT STREQUAL "client")
    set(XYMON_BUILD_CLIENT ON)
endif()

# ----------------------------------------------------------------------
# Core libraries
# ----------------------------------------------------------------------

add_subdirectory(lib)

# ----------------------------------------------------------------------
# Server executables
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(xymongen)
endif()

# ----------------------------------------------------------------------
# Common tools
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(common)
endif()

# ----------------------------------------------------------------------
# Client tools
# ----------------------------------------------------------------------

if(XYMON_BUILD_CLIENT)
    add_subdirectory(client)
endif()

# ----------------------------------------------------------------------
# Xymond daemons
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(xymond)
endif()

# ----------------------------------------------------------------------
# Xymon network tests
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(xymonnet)
endif()

# ----------------------------------------------------------------------
# Web CGI tools
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(web)
endif()

# ----------------------------------------------------------------------
# Docs
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(docs)
endif()

# ----------------------------------------------------------------------
# Proxy tools
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(xymonproxy)
endif()

# ----------------------------------------------------------------------
# Build tools (merge-lines, merge-sects, setup-newfiles, ...)
# ----------------------------------------------------------------------

if(XYMON_BUILD_SERVER)
    add_subdirectory(build)
endif()
