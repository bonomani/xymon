cmake_minimum_required(VERSION 3.16)

project(xymon C)

include(CheckFunctionExists)
check_function_exists(setenv HAVE_SETENV)
if(HAVE_SETENV)
    add_compile_definitions(HAVE_SETENV=1)
endif()

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Xymon identity / options
# ----------------------------------------------------------------------

option(USE_GNUINSTALLDIRS "Use GNUInstallDirs layout (FHS-style)" OFF)
option(LEGACY_APPLY_OWNERSHIP "Apply chown/chgrp in legacy install" OFF)

set(XYMONHOSTNAME "localhost" CACHE STRING "")
set(XYMONHOSTIP "127.0.0.1" CACHE STRING "")
set(XYMONHOSTOS "linux" CACHE STRING "")
set(XYMONHOSTURL "http://localhost" CACHE STRING "")
set(XYMONCGIURL "/xymon-cgi" CACHE STRING "")
set(SECUREXYMONCGIURL "/xymon-seccgi" CACHE STRING "")

set(XYMONUSER "xymon" CACHE STRING "")
set(HTTPDGID "" CACHE STRING "")
option(HTTPDGID_CHGRP "Apply HTTPDGID chgrp during install" ON)

option(ENABLE_RRD "Build rrd-based components" ON)
option(ENABLE_LDAP "Enable LDAP checks" ON)
option(ENABLE_SSL "Enable SSL checks" ON)

set(XYMON_VARIANT "all" CACHE STRING "")
option(LOCALCLIENT "Enable local client configuration" OFF)

# ----------------------------------------------------------------------
# Legacy layout
# ----------------------------------------------------------------------

if(NOT USE_GNUINSTALLDIRS)
    set(XYMONTOPDIR "/var/lib/xymon")
    set(XYMONHOME "/var/lib/xymon/server")
    set(XYMONCLIENTHOME "/var/lib/xymon/client")
    set(XYMONVAR "/var/lib/xymon/data")
    set(XYMONLOGDIR "/var/log/xymon")

    set(INSTALLBINDIR "/var/lib/xymon/server/bin")
    set(INSTALLETCDIR "/var/lib/xymon/server/etc")
    set(INSTALLEXTDIR "/var/lib/xymon/server/ext")
    set(INSTALLTMPDIR "/var/lib/xymon/server/tmp")
    set(INSTALLWEBDIR "/var/lib/xymon/server/web")
    set(INSTALLWWWDIR "/var/lib/xymon/server/www")

    set(CGIDIR "/var/lib/xymon/cgi-bin")
    set(SECURECGIDIR "/var/lib/xymon/cgi-secure")
endif()

# ----------------------------------------------------------------------
# config.h
# ----------------------------------------------------------------------

file(WRITE "${CMAKE_BINARY_DIR}/config.h"
"#ifndef __CONFIG_H__
#define __CONFIG_H__ 1
#define PACKAGE_NAME \"xymon\"
#define PACKAGE_VERSION \"cmake\"
#define XYMONTOPDIR \"${XYMONTOPDIR}\"
#define XYMONHOME \"${XYMONHOME}\"
#define XYMONCLIENTHOME \"${XYMONCLIENTHOME}\"
#define XYMONLOGDIR \"${XYMONLOGDIR}\"
#define XYMONHOSTNAME \"${XYMONHOSTNAME}\"
#define XYMONHOSTIP \"${XYMONHOSTIP}\"
#define XYMONHOSTOS \"${XYMONHOSTOS}\"
#endif
")

include_directories(
    "${CMAKE_SOURCE_DIR}/include"
    "${CMAKE_SOURCE_DIR}/lib"
    "${CMAKE_BINARY_DIR}"
)

find_path(PCRE_INCLUDE_DIR pcre.h
    PATHS
        /usr/pkg/include
        /usr/local/include
        /opt/homebrew/include
        /opt/local/include
    PATH_SUFFIXES
        pcre
)
if(PCRE_INCLUDE_DIR)
    include_directories("${PCRE_INCLUDE_DIR}")
endif()

add_compile_options(
    -g -O2 -Wall -Wno-unused -Wno-pointer-sign
    -include "${CMAKE_BINARY_DIR}/config.h"
)

add_compile_definitions(
    _REENTRANT
    _LARGEFILE_SOURCE
    _FILE_OFFSET_BITS=64
)

# ----------------------------------------------------------------------
# Variant handling
# ----------------------------------------------------------------------

string(TOLOWER "${XYMON_VARIANT}" XYMON_VARIANT)

set(XYMON_BUILD_SERVER OFF)
set(XYMON_BUILD_CLIENT OFF)

if(XYMON_VARIANT STREQUAL "all")
    set(XYMON_BUILD_SERVER ON)
    set(XYMON_BUILD_CLIENT ON)
elseif(XYMON_VARIANT STREQUAL "server")
    set(XYMON_BUILD_SERVER ON)
elseif(XYMON_VARIANT STREQUAL "client")
    set(XYMON_BUILD_CLIENT ON)
else()
    message(FATAL_ERROR "XYMON_VARIANT must be all, server or client")
endif()

# ----------------------------------------------------------------------
# Subdirectories
# ----------------------------------------------------------------------

add_subdirectory(lib)

if(XYMON_BUILD_SERVER)
    add_subdirectory(xymongen)
    add_subdirectory(common)
    add_subdirectory(xymond)
    add_subdirectory(xymonnet)
    add_subdirectory(web)
    add_subdirectory(docs)
    add_subdirectory(xymonproxy)
    add_subdirectory(build)
endif()

if(XYMON_BUILD_CLIENT)
    add_subdirectory(client)
endif()

# ----------------------------------------------------------------------
# install-legacy-dirs
# ----------------------------------------------------------------------

set(LEGACY_DESTDIR "" CACHE PATH "DESTDIR for legacy install")

add_custom_target(install-legacy-dirs
    COMMAND "${CMAKE_COMMAND}" -E make_directory
        "${LEGACY_DESTDIR}${XYMONTOPDIR}"
        "${LEGACY_DESTDIR}${XYMONHOME}"
        "${LEGACY_DESTDIR}${XYMONHOME}/download"
        "${LEGACY_DESTDIR}${XYMONVAR}"
        "${LEGACY_DESTDIR}${XYMONVAR}/acks"
        "${LEGACY_DESTDIR}${XYMONVAR}/data"
        "${LEGACY_DESTDIR}${XYMONVAR}/disabled"
        "${LEGACY_DESTDIR}${XYMONVAR}/hist"
        "${LEGACY_DESTDIR}${XYMONVAR}/histlogs"
        "${LEGACY_DESTDIR}${XYMONVAR}/hostdata"
        "${LEGACY_DESTDIR}${XYMONVAR}/logs"
        "${LEGACY_DESTDIR}${XYMONVAR}/rrd"
        "${LEGACY_DESTDIR}${INSTALLBINDIR}"
        "${LEGACY_DESTDIR}${INSTALLETCDIR}"
        "${LEGACY_DESTDIR}${INSTALLEXTDIR}"
        "${LEGACY_DESTDIR}${INSTALLTMPDIR}"
        "${LEGACY_DESTDIR}${INSTALLWEBDIR}"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/gifs"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/help"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/html"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/menu"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/notes"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/rep"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/snap"
        "${LEGACY_DESTDIR}${INSTALLWWWDIR}/wml"
        "${LEGACY_DESTDIR}${CGIDIR}"
        "${LEGACY_DESTDIR}${SECURECGIDIR}"
)

# ----------------------------------------------------------------------
# install-legacy-files (SAFE / DETERMINISTIC)
# ----------------------------------------------------------------------

add_custom_target(install-legacy-files
    DEPENDS install-legacy-dirs
)

add_custom_command(
    TARGET install-legacy-files POST_BUILD
    COMMAND env DESTDIR="${LEGACY_DESTDIR}"
            "${CMAKE_COMMAND}"
            --install "${CMAKE_BINARY_DIR}"
            --prefix "${XYMONTOPDIR}"
)

if(EXISTS "${CMAKE_SOURCE_DIR}/web/webfiles")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_directory
                "${CMAKE_SOURCE_DIR}/web/webfiles"
                "${LEGACY_DESTDIR}${INSTALLWEBDIR}"
    )
endif()
if(EXISTS "${CMAKE_SOURCE_DIR}/xymond/webfiles")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_directory
                "${CMAKE_SOURCE_DIR}/xymond/webfiles"
                "${LEGACY_DESTDIR}${INSTALLWEBDIR}"
    )
endif()

if(EXISTS "${CMAKE_SOURCE_DIR}/web/www")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_directory
                "${CMAKE_SOURCE_DIR}/web/www"
                "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
    )
endif()
if(EXISTS "${CMAKE_SOURCE_DIR}/xymond/wwwfiles")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_directory
                "${CMAKE_SOURCE_DIR}/xymond/wwwfiles"
                "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
    )
endif()

foreach(subdir help menu gifs)
    if(EXISTS "${CMAKE_SOURCE_DIR}/web/${subdir}")
        add_custom_command(
            TARGET install-legacy-files POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_directory
                    "${CMAKE_SOURCE_DIR}/web/${subdir}"
                    "${LEGACY_DESTDIR}${INSTALLWWWDIR}/${subdir}"
        )
    endif()
endforeach()

add_custom_command(
    TARGET install-legacy-files POST_BUILD
    COMMAND /usr/bin/find
            "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
            -type d -exec chmod 755 {} +
)

add_custom_command(
    TARGET install-legacy-files POST_BUILD
    COMMAND /usr/bin/find
            "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
            -type f -exec chmod 644 {} +
)

if(LEGACY_APPLY_OWNERSHIP)
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND /bin/chown -R "${XYMONUSER}:${XYMONUSER}"
                "${LEGACY_DESTDIR}${XYMONHOME}"
                "${LEGACY_DESTDIR}${XYMONVAR}"
    )
endif()

# ----------------------------------------------------------------------
# Vérification et application du groupe HTTPDGID
# ----------------------------------------------------------------------
find_program(GETENT_EXECUTABLE getent)

if(LEGACY_APPLY_OWNERSHIP AND HTTPDGID_CHGRP AND HTTPDGID)
    set(HTTPDGID_EXISTS OFF)
    if(GETENT_EXECUTABLE)
        execute_process(
            COMMAND "${GETENT_EXECUTABLE}" group "${HTTPDGID}"
            RESULT_VARIABLE HTTPDGID_GETENT_RESULT
            OUTPUT_QUIET ERROR_QUIET
        )
        if(HTTPDGID_GETENT_RESULT EQUAL 0)
            set(HTTPDGID_EXISTS ON)
        endif()
    endif()

    if(HTTPDGID_EXISTS)
        add_custom_command(
            TARGET install-legacy-files POST_BUILD
            COMMAND /bin/chgrp -R "${HTTPDGID}" "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
            COMMAND /bin/chmod -R g+w "${LEGACY_DESTDIR}${INSTALLWWWDIR}/rep"
            COMMAND /bin/chmod -R g+w "${LEGACY_DESTDIR}${INSTALLWWWDIR}/snap"
            COMMENT "Application du groupe web ${HTTPDGID} sur les dossiers de rapports"
        )
    endif()
endif()

# ----------------------------------------------------------------------
# Cas spécifique : xymonping (SETUID) via CMake Scripting
# ----------------------------------------------------------------------
if(XYMON_BUILD_SERVER)
    install(CODE [[
        set(_dest "$ENV{DESTDIR}")
        if(_dest STREQUAL "")
            set(_dest "")
        endif()
        set(_target "${_dest}${CMAKE_INSTALL_PREFIX}/server/bin/xymonping")
        if(EXISTS "${_target}")
            execute_process(COMMAND /usr/bin/stat -c "%a|%U|%G" "${_target}" OUTPUT_VARIABLE before_msg)
            string(STRIP "${before_msg}" before_msg)
            message(STATUS "Legacy hook: existing perms before change ${before_msg}")
            execute_process(COMMAND chown root:bc "${_target}" RESULT_VARIABLE chown_res)
            if(NOT chown_res EQUAL 0)
                message(WARNING "Legacy hook: chown root:bc failed with ${chown_res}")
            endif()
            execute_process(COMMAND chmod 4755 "${_target}")
            execute_process(COMMAND /usr/bin/stat -c "%a|%U|%G" "${_target}" OUTPUT_VARIABLE after_msg)
            string(STRIP "${after_msg}" after_msg)
            message(STATUS "Legacy hook: perms after change ${after_msg}")
        else()
            message(STATUS "Legacy hook: xymonping missing at ${_target}; cannot set perms")
        endif()
    ]])
endif()
