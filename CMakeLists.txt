cmake_minimum_required(VERSION 3.16)

project(xymon C)

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# ----------------------------------------------------------------------
# Xymon identity / options
# ----------------------------------------------------------------------

option(USE_GNUINSTALLDIRS "Use GNUInstallDirs layout (FHS-style)" OFF)
option(LEGACY_APPLY_OWNERSHIP "Apply chown/chgrp in legacy install" OFF)

if(NOT DEFINED XYMONHOSTNAME OR XYMONHOSTNAME STREQUAL "")
    execute_process(
        COMMAND hostname
        OUTPUT_VARIABLE _HOSTNAME
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _HOSTNAME_RESULT
    )
    if(_HOSTNAME_RESULT EQUAL 0 AND NOT _HOSTNAME STREQUAL "")
        set(XYMONHOSTNAME "${_HOSTNAME}" CACHE STRING "" FORCE)
    else()
        set(XYMONHOSTNAME "localhost" CACHE STRING "" FORCE)
    endif()
endif()
set(XYMONHOSTIP "127.0.0.1" CACHE STRING "")
if(NOT DEFINED XYMONHOSTOS OR XYMONHOSTOS STREQUAL "")
    string(TOLOWER "${CMAKE_SYSTEM_NAME}" _DEFAULT_HOSTOS)
    set(XYMONHOSTOS "${_DEFAULT_HOSTOS}" CACHE STRING "" FORCE)
endif()
set(XYMONHOSTURL "/xymon" CACHE STRING "")
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

# Match legacy Makefile defaults for runtime helpers.
if(CMAKE_SYSTEM_NAME STREQUAL "HP-UX" OR CMAKE_SYSTEM_NAME STREQUAL "SunOS" OR CMAKE_SYSTEM_NAME STREQUAL "SCO_SV")
    set(_DEFAULT_MAILPROGRAM "mailx")
else()
    set(_DEFAULT_MAILPROGRAM "mail")
endif()
set(MAILPROGRAM "${_DEFAULT_MAILPROGRAM}" CACHE STRING "")
set(FPING "xymonping" CACHE STRING "")

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

set(CONFIG_GUARD "__CONFIG_H__" CACHE INTERNAL "Guard macro for config.h")
set(PACKAGE_NAME "xymon" CACHE INTERNAL "Package name")
set(PACKAGE_VERSION "cmake" CACHE INTERNAL "Package version")

# Legacy build assumes these helpers and headers exist; mirror the legacy defaults here.
set(HAVE_SOCKLEN_T 1 CACHE INTERNAL "" FORCE)
set(HAVE_SNPRINTF 1 CACHE INTERNAL "" FORCE)
set(HAVE_VSNPRINTF 1 CACHE INTERNAL "" FORCE)
set(HAVE_RPCENT_H OFF CACHE INTERNAL "" FORCE)
set(HAVE_SYS_SELECT_H 1 CACHE INTERNAL "" FORCE)
set(HAVE_UINT32_TYPEDEF 1 CACHE INTERNAL "" FORCE)
set(HAVE_UNAME 1 CACHE INTERNAL "" FORCE)
set(HAVE_SETENV 1 CACHE INTERNAL "" FORCE)
set(HAVE_STRTOLL_H 1 CACHE INTERNAL "" FORCE)
set(HAVE_BINARY_TREE 0 CACHE INTERNAL "" FORCE)

include_directories(
    "${CMAKE_SOURCE_DIR}/include"
    "${CMAKE_SOURCE_DIR}/lib"
    "${CMAKE_BINARY_DIR}"
)

configure_file(
    "${CMAKE_SOURCE_DIR}/cmake/config.h.in"
    "${CMAKE_BINARY_DIR}/config.h"
    @ONLY
)

find_path(PCRE_INCLUDE_DIR pcre.h
    PATHS
        /usr/pkg/include
        /usr/local/include
        /usr/local/opt/pcre/include
        /opt/homebrew/include
        /opt/homebrew/opt/pcre/include
        /opt/local/include
    PATH_SUFFIXES
        pcre
)
if(PCRE_INCLUDE_DIR)
    include_directories("${PCRE_INCLUDE_DIR}")
endif()

find_library(PCRE_LIBRARY pcre
    PATHS
        /usr/pkg/lib
        /usr/local/lib
        /usr/local/opt/pcre/lib
        /opt/homebrew/lib
        /opt/homebrew/opt/pcre/lib
        /opt/local/lib
)
if(PCRE_LIBRARY)
    get_filename_component(PCRE_LIBRARY_DIR "${PCRE_LIBRARY}" DIRECTORY)
    link_directories("${PCRE_LIBRARY_DIR}")
endif()

if(CMAKE_SYSTEM_NAME MATCHES "OpenBSD|FreeBSD")
    link_directories(/usr/local/lib /usr/X11R6/lib)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -L/usr/local/lib -L/usr/X11R6/lib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
    link_directories(/usr/pkg/lib)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -L/usr/pkg/lib")
elseif(APPLE)
    find_path(OPENSSL_INCLUDE_DIR openssl/ssl.h
        PATHS
            /opt/homebrew/opt/openssl@3/include
            /opt/homebrew/opt/openssl@1.1/include
            /usr/local/opt/openssl@3/include
            /usr/local/opt/openssl@1.1/include
            /opt/homebrew/include
            /usr/local/include
    )
    if(OPENSSL_INCLUDE_DIR)
        include_directories("${OPENSSL_INCLUDE_DIR}")
    endif()

    find_library(OPENSSL_SSL_LIBRARY ssl
        PATHS
            /opt/homebrew/opt/openssl@3/lib
            /opt/homebrew/opt/openssl@1.1/lib
            /usr/local/opt/openssl@3/lib
            /usr/local/opt/openssl@1.1/lib
            /opt/homebrew/lib
            /usr/local/lib
    )
    if(OPENSSL_SSL_LIBRARY)
        get_filename_component(OPENSSL_SSL_LIBRARY_DIR "${OPENSSL_SSL_LIBRARY}" DIRECTORY)
        link_directories("${OPENSSL_SSL_LIBRARY_DIR}")
        set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -L${OPENSSL_SSL_LIBRARY_DIR}")
    endif()
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

if(APPLE)
    add_compile_definitions(XYMON_APPLE)
endif()

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
    set(XYMON_BUILD_CLIENT ON)
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

if(XYMON_BUILD_CLIENT)
    add_custom_command(
        TARGET install-legacy-dirs POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/bin"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/etc"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/tmp"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/logs"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/ext"
            "${LEGACY_DESTDIR}${XYMONCLIENTHOME}/local"
    )
endif()

# ----------------------------------------------------------------------
# install-legacy-files (SAFE / DETERMINISTIC)
# ----------------------------------------------------------------------

add_custom_target(install-legacy-files
    DEPENDS install-legacy-dirs
)
add_dependencies(install-legacy-files setup-newfiles)

add_custom_command(
    TARGET install-legacy-files POST_BUILD
    COMMAND env DESTDIR="${LEGACY_DESTDIR}"
            "${CMAKE_COMMAND}"
            --install "${CMAKE_BINARY_DIR}"
            --prefix "${XYMONTOPDIR}"
)

set(SETUP_NEWFILES_SCRIPT "${CMAKE_BINARY_DIR}/run-setup-newfiles.cmake")
file(WRITE "${SETUP_NEWFILES_SCRIPT}" [=[
if(NOT DEFINED SRC_DIR OR NOT DEFINED DEST_DIR OR NOT DEFINED MD5_FILE OR NOT DEFINED SETUP_NEWFILES_EXE OR NOT DEFINED TMP_FILE)
  message(FATAL_ERROR "run-setup-newfiles: missing required variables")
endif()
execute_process(
  COMMAND /usr/bin/find .
  WORKING_DIRECTORY "${SRC_DIR}"
  OUTPUT_VARIABLE _raw
  RESULT_VARIABLE _find_res
)
if(NOT _find_res EQUAL 0)
  message(FATAL_ERROR "run-setup-newfiles: find failed in ${SRC_DIR}")
endif()
string(REPLACE "\n" ";" _lines "${_raw}")
set(_filtered "")
foreach(_line IN LISTS _lines)
  if(_line STREQUAL "")
    continue()
  endif()
  if(_line MATCHES "RCS" OR _line MATCHES "\\.svn" OR _line MATCHES "DIST")
    continue()
  endif()
  list(APPEND _filtered "${_line}")
endforeach()
list(JOIN _filtered "\n" _joined)
file(WRITE "${TMP_FILE}" "${_joined}\n")
execute_process(
  COMMAND "${SETUP_NEWFILES_EXE}" "${DEST_DIR}" "${MD5_FILE}"
  INPUT_FILE "${TMP_FILE}"
  WORKING_DIRECTORY "${SRC_DIR}"
  RESULT_VARIABLE _setup_res
)
if(NOT _setup_res EQUAL 0)
  message(FATAL_ERROR "run-setup-newfiles: setup-newfiles failed")
endif()
]=])

if(EXISTS "${CMAKE_SOURCE_DIR}/web/webfiles")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_directory
                "${CMAKE_SOURCE_DIR}/web/webfiles"
                "${LEGACY_DESTDIR}${INSTALLWEBDIR}"
    )
endif()
if(EXISTS "${CMAKE_SOURCE_DIR}/xymond/webfiles" AND EXISTS "${CMAKE_SOURCE_DIR}/build/md5.dat")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}"
                -DSETUP_NEWFILES_EXE="$<TARGET_FILE:setup-newfiles>"
                -DSRC_DIR="${CMAKE_SOURCE_DIR}/xymond/webfiles"
                -DDEST_DIR="${LEGACY_DESTDIR}${INSTALLWEBDIR}/"
                -DMD5_FILE="${CMAKE_SOURCE_DIR}/build/md5.dat"
                -DTMP_FILE="${CMAKE_BINARY_DIR}/setup-newfiles.web.list"
                -P "${SETUP_NEWFILES_SCRIPT}"
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
if(EXISTS "${CMAKE_SOURCE_DIR}/xymond/wwwfiles" AND EXISTS "${CMAKE_SOURCE_DIR}/build/md5.dat")
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND "${CMAKE_COMMAND}"
                -DSETUP_NEWFILES_EXE="$<TARGET_FILE:setup-newfiles>"
                -DSRC_DIR="${CMAKE_SOURCE_DIR}/xymond/wwwfiles"
                -DDEST_DIR="${LEGACY_DESTDIR}${INSTALLWWWDIR}/"
                -DMD5_FILE="${CMAKE_SOURCE_DIR}/build/md5.dat"
                -DTMP_FILE="${CMAKE_BINARY_DIR}/setup-newfiles.www.list"
                -P "${SETUP_NEWFILES_SCRIPT}"
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
            set(_use_chown 0)
            execute_process(
                COMMAND /usr/bin/stat -c "%a|%U|%G" "${_target}"
                RESULT_VARIABLE _stat_c_res
                OUTPUT_VARIABLE before_msg
                ERROR_QUIET
            )
            if(_stat_c_res EQUAL 0)
                set(_use_chown 1)
            else()
                execute_process(
                    COMMAND /usr/bin/stat -f "%Lp|%Su|%Sg" "${_target}"
                    OUTPUT_VARIABLE before_msg
                    ERROR_QUIET
                )
            endif()
            string(STRIP "${before_msg}" before_msg)
            message(STATUS "Legacy hook: existing perms before change ${before_msg}")
            if(_use_chown)
                execute_process(COMMAND chown root "${_target}" RESULT_VARIABLE chown_res)
                if(NOT chown_res EQUAL 0)
                    message(WARNING "Legacy hook: chown root failed with ${chown_res}")
                endif()
            else()
                message(STATUS "Legacy hook: skip chown root on this platform")
            endif()
            execute_process(COMMAND chmod 4755 "${_target}")
            if(_use_chown)
                execute_process(COMMAND /usr/bin/stat -c "%a|%U|%G" "${_target}" OUTPUT_VARIABLE after_msg ERROR_QUIET)
            else()
                execute_process(COMMAND /usr/bin/stat -f "%Lp|%Su|%Sg" "${_target}" OUTPUT_VARIABLE after_msg ERROR_QUIET)
            endif()
            string(STRIP "${after_msg}" after_msg)
            message(STATUS "Legacy hook: perms after change ${after_msg}")
        else()
            message(STATUS "Legacy hook: xymonping missing at ${_target}; cannot set perms")
        endif()
    ]])
endif()
