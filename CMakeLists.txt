cmake_minimum_required(VERSION 3.14)

project(xymon C)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

message(STATUS "System: ${CMAKE_SYSTEM_NAME}")
message(STATUS "Compiler: ${CMAKE_C_COMPILER}")

# RPM-hardened linkers can force PIE at link time. Build static archives as
# position-independent objects so they remain linkable in that mode.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

# ----------------------------------------------------------------------
# Xymon identity / options
# ----------------------------------------------------------------------

option(USE_GNUINSTALLDIRS "Use GNUInstallDirs-derived layout (FHS-style)" OFF)
option(LEGACY_APPLY_OWNERSHIP "Apply chown/chgrp in legacy install" OFF)
set(XYMON_LAYOUT "" CACHE STRING "Install layout: home_tree, var_tree, bsd_local, macos_tree, or fhs")
set_property(CACHE XYMON_LAYOUT PROPERTY STRINGS home_tree var_tree bsd_local macos_tree fhs)

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
option(INSTALL_EXTRA "Install extra/debug/helper binaries (non-reference set)" OFF)

set(XYMON_VARIANT "server" CACHE STRING "")
option(LOCALCLIENT "Enable local client configuration" OFF)

# PCRE is used by server/localclient builds. Plain client builds avoid it.
set(_XYMON_VARIANT_PRE "${XYMON_VARIANT}")
string(TOLOWER "${_XYMON_VARIANT_PRE}" _XYMON_VARIANT_PRE)
set(XYMON_REQUIRE_PCRE OFF)
if(_XYMON_VARIANT_PRE STREQUAL "server" OR LOCALCLIENT)
    set(XYMON_REQUIRE_PCRE ON)
endif()

# Match legacy Makefile defaults for runtime helpers.
if(CMAKE_SYSTEM_NAME STREQUAL "HP-UX" OR CMAKE_SYSTEM_NAME STREQUAL "SunOS" OR CMAKE_SYSTEM_NAME STREQUAL "SCO_SV")
    set(_DEFAULT_MAILPROGRAM "mailx")
else()
    set(_DEFAULT_MAILPROGRAM "mail")
endif()
set(MAILPROGRAM "${_DEFAULT_MAILPROGRAM}" CACHE STRING "")
if(NOT DEFINED FPING)
    set(_DEFAULT_FPING "xymonping")
    if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        find_program(
            _LEGACY_FPING
            NAMES fping
            PATHS / /usr /usr/local /opt /usr/pkg /opt/csw
            PATH_SUFFIXES bin sbin
            NO_DEFAULT_PATH
        )
        if(_LEGACY_FPING)
            set(_DEFAULT_FPING "${_LEGACY_FPING}")
        endif()
    endif()
    set(FPING "${_DEFAULT_FPING}" CACHE STRING "")
endif()

# ----------------------------------------------------------------------
# Install layout
# ----------------------------------------------------------------------

if(XYMON_LAYOUT STREQUAL "")
    if(USE_GNUINSTALLDIRS)
        set(XYMON_LAYOUT "fhs")
    elseif(CMAKE_SYSTEM_NAME MATCHES "FreeBSD|NetBSD")
        set(XYMON_LAYOUT "home_tree")
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        set(XYMON_LAYOUT "macos_tree")
    else()
        set(XYMON_LAYOUT "var_tree")
    endif()
endif()

if(NOT XYMON_LAYOUT MATCHES "^(home_tree|var_tree|bsd_local|macos_tree|fhs)$")
    message(FATAL_ERROR "XYMON_LAYOUT must be one of: home_tree, var_tree, bsd_local, macos_tree, fhs")
endif()

if(XYMON_LAYOUT STREQUAL "fhs")
    set(USE_GNUINSTALLDIRS ON CACHE BOOL "Use GNUInstallDirs layout (FHS-style)" FORCE)
else()
    set(USE_GNUINSTALLDIRS OFF CACHE BOOL "Use GNUInstallDirs layout (FHS-style)" FORCE)
endif()

if(NOT DEFINED XYMON_INSTALL_MANPAGES)
    if(XYMON_LAYOUT MATCHES "^(home_tree|macos_tree)$")
        set(XYMON_INSTALL_MANPAGES OFF CACHE BOOL "Install Xymon manpages" FORCE)
    else()
        set(XYMON_INSTALL_MANPAGES ON CACHE BOOL "Install Xymon manpages" FORCE)
    endif()
endif()

if(XYMON_LAYOUT STREQUAL "var_tree")
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
elseif(XYMON_LAYOUT STREQUAL "home_tree")
    set(XYMONTOPDIR "/home/_www")
    set(XYMONHOME "/home/_www/server")
    set(XYMONCLIENTHOME "/home/_www/client")
    set(XYMONVAR "/home/_www/data")
    set(XYMONLOGDIR "/var/log/xymon")

    set(INSTALLBINDIR "/home/_www/server/bin")
    set(INSTALLETCDIR "/home/_www/server/etc")
    set(INSTALLEXTDIR "/home/_www/server/ext")
    set(INSTALLTMPDIR "/home/_www/server/tmp")
    set(INSTALLWEBDIR "/home/_www/server/web")
    set(INSTALLWWWDIR "/home/_www/server/www")

    set(CGIDIR "/home/_www/cgi-bin")
    set(SECURECGIDIR "/home/_www/cgi-secure")
elseif(XYMON_LAYOUT STREQUAL "bsd_local")
    if(NOT DEFINED XYMON_BSD_LOCALBASE)
        set(XYMON_BSD_LOCALBASE "${CMAKE_INSTALL_PREFIX}" CACHE PATH "BSD local base prefix for XYMON_LAYOUT=bsd_local")
    endif()
    if(NOT DEFINED XYMON_BSD_LOCALSTATEDIR)
        set(XYMON_BSD_LOCALSTATEDIR "/var" CACHE PATH "BSD local state root for XYMON_LAYOUT=bsd_local")
    endif()

    if(XYMON_BSD_LOCALBASE STREQUAL "")
        message(FATAL_ERROR "XYMON_BSD_LOCALBASE must not be empty when XYMON_LAYOUT=bsd_local")
    endif()
    if(XYMON_BSD_LOCALSTATEDIR STREQUAL "")
        message(FATAL_ERROR "XYMON_BSD_LOCALSTATEDIR must not be empty when XYMON_LAYOUT=bsd_local")
    endif()

    set(XYMONTOPDIR "${XYMON_BSD_LOCALBASE}/libexec/xymon")
    set(XYMONHOME "${XYMONTOPDIR}/server")
    set(XYMONCLIENTHOME "${XYMONTOPDIR}/client")
    set(XYMONVAR "${XYMON_BSD_LOCALSTATEDIR}/xymon")
    set(XYMONLOGDIR "${XYMON_BSD_LOCALSTATEDIR}/log/xymon")

    set(INSTALLBINDIR "${XYMONHOME}/bin")
    set(INSTALLETCDIR "${XYMON_BSD_LOCALBASE}/etc/xymon")
    set(INSTALLEXTDIR "${XYMONHOME}/ext")
    set(INSTALLTMPDIR "${XYMONVAR}/tmp")
    set(INSTALLWEBDIR "${XYMON_BSD_LOCALBASE}/share/xymon/web")
    set(INSTALLWWWDIR "${XYMON_BSD_LOCALBASE}/share/xymon/www")

    set(CGIDIR "${XYMON_BSD_LOCALBASE}/www/cgi-bin/xymon")
    set(SECURECGIDIR "${XYMON_BSD_LOCALBASE}/www/cgi-secure/xymon")
elseif(XYMON_LAYOUT STREQUAL "macos_tree")
    set(XYMONTOPDIR "/Library/WebServer")
    set(XYMONHOME "/Library/WebServer/server")
    set(XYMONCLIENTHOME "/Library/WebServer/client")
    set(XYMONVAR "/Library/WebServer/data")
    set(XYMONLOGDIR "/var/log/xymon")

    set(INSTALLBINDIR "/Library/WebServer/server/bin")
    set(INSTALLETCDIR "/Library/WebServer/server/etc")
    set(INSTALLEXTDIR "/Library/WebServer/server/ext")
    set(INSTALLTMPDIR "/Library/WebServer/server/tmp")
    set(INSTALLWEBDIR "/Library/WebServer/server/web")
    set(INSTALLWWWDIR "/Library/WebServer/server/www")

    set(CGIDIR "/Library/WebServer/cgi-bin")
    set(SECURECGIDIR "/Library/WebServer/cgi-secure")
elseif(XYMON_LAYOUT STREQUAL "fhs")
    if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
        set(CMAKE_INSTALL_PREFIX "/usr" CACHE PATH "Install prefix for FHS layout" FORCE)
    endif()
    include(GNUInstallDirs)

    set(XYMONTOPDIR "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xymon")
    set(XYMONHOME "${XYMONTOPDIR}/server")
    set(XYMONCLIENTHOME "${XYMONTOPDIR}/client")
    set(XYMONVAR "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/lib/xymon")
    set(XYMONLOGDIR "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/log/xymon")

    set(INSTALLBINDIR "${XYMONHOME}/bin")
    set(INSTALLETCDIR "${CMAKE_INSTALL_FULL_SYSCONFDIR}/xymon")
    set(INSTALLEXTDIR "${XYMONHOME}/ext")
    set(INSTALLTMPDIR "${XYMONVAR}/tmp")
    set(INSTALLWEBDIR "${CMAKE_INSTALL_FULL_SYSCONFDIR}/xymon/web")
    set(INSTALLWWWDIR "${XYMONVAR}/www")

    set(CGIDIR "${XYMONTOPDIR}/cgi-bin")
    set(SECURECGIDIR "${XYMONTOPDIR}/cgi-secure")
endif()

message(STATUS "Xymon layout: ${XYMON_LAYOUT}")
message(STATUS "Install manpages: ${XYMON_INSTALL_MANPAGES}")

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
    "${CMAKE_BINARY_DIR}"
)

set(XYMON_NET_LIBRARIES)
set(XYMON_NET_INCLUDE_DIRS)

unset(XYMON_PCRE_LIBRARY CACHE)
unset(XYMON_PCRE_LIBRARY)
if(XYMON_REQUIRE_PCRE)
    find_library(XYMON_PCRE_LIBRARY
        NAMES pcre pcre2-8 pcre2
        PATHS
            /usr/pkg/lib
            /usr/local/lib
            /opt/homebrew/lib
            /opt/local/lib
    )
    if(XYMON_PCRE_LIBRARY)
        get_filename_component(XYMON_PCRE_LIBRARY_DIR "${XYMON_PCRE_LIBRARY}" DIRECTORY)
        link_directories("${XYMON_PCRE_LIBRARY_DIR}")
        if(XYMON_PCRE_LIBRARY MATCHES "pcre2")
            add_compile_definitions(PCRE2)
        endif()
    else()
        message(FATAL_ERROR "PCRE library not found (tried pcre, pcre2-8, pcre2)")
    endif()
endif()

# Match legacy build/Makefile.* NETLIBS handling for shared comm libraries.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_library(XYMON_TIRPC_LIBRARY tirpc)
    if(XYMON_TIRPC_LIBRARY)
        list(APPEND XYMON_NET_LIBRARIES "${XYMON_TIRPC_LIBRARY}")
    endif()

    find_path(XYMON_TIRPC_INCLUDE_DIR rpc/rpc.h PATH_SUFFIXES tirpc)
    if(XYMON_TIRPC_INCLUDE_DIR)
        list(APPEND XYMON_NET_INCLUDE_DIRS "${XYMON_TIRPC_INCLUDE_DIR}")
    endif()
elseif(CMAKE_SYSTEM_NAME STREQUAL "SunOS")
    list(APPEND XYMON_NET_LIBRARIES resolv socket nsl)
elseif(CMAKE_SYSTEM_NAME STREQUAL "HP-UX")
    list(APPEND XYMON_NET_LIBRARIES nsl)
elseif(CMAKE_SYSTEM_NAME STREQUAL "SCO_SV")
    list(APPEND XYMON_NET_LIBRARIES socket nsl)
endif()

if(CMAKE_SYSTEM_NAME MATCHES "OpenBSD|FreeBSD")
    include_directories(/usr/local/include /usr/X11R6/include)
    link_directories(/usr/local/lib /usr/X11R6/lib)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -L/usr/local/lib -L/usr/X11R6/lib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "NetBSD")
    include_directories(/usr/pkg/include)
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

# Legacy configure.server injects -DHAVE_OPENSSL when SSL support is enabled.
if(ENABLE_SSL)
    add_compile_definitions(HAVE_OPENSSL)
endif()

if(APPLE)
    # Match legacy Darwin Makefile flags so resolver constants like T_A/C_IN
    # are available from system DNS headers.
    add_compile_definitions(BIND_8_COMPAT=1)
endif()

# ----------------------------------------------------------------------
# Variant handling
# ----------------------------------------------------------------------

string(TOLOWER "${XYMON_VARIANT}" XYMON_VARIANT)

set(XYMON_BUILD_SERVER OFF)
set(XYMON_BUILD_CLIENT OFF)

if(XYMON_VARIANT STREQUAL "server")
    set(XYMON_BUILD_SERVER ON)
    set(XYMON_BUILD_CLIENT ON)
elseif(XYMON_VARIANT STREQUAL "client")
    set(XYMON_BUILD_CLIENT ON)
else()
    message(FATAL_ERROR "XYMON_VARIANT must be server or client")
endif()

set(XYMON_CLIENT_COMPILE_DEFINITIONS
    CLIENTONLY=1
)
if(LOCALCLIENT)
    list(APPEND XYMON_CLIENT_COMPILE_DEFINITIONS LOCALCLIENT=1)
endif()

# Legacy Makefile client-only layout installs directly under XYMONTOPDIR
# (bin/, etc/, ...), while server builds use the split server/client tree.
if(NOT XYMON_LAYOUT STREQUAL "fhs" AND XYMON_BUILD_CLIENT AND NOT XYMON_BUILD_SERVER)
    set(XYMONHOME "${XYMONTOPDIR}")
    set(XYMONCLIENTHOME "${XYMONTOPDIR}")
    set(INSTALLBINDIR "${XYMONTOPDIR}/bin")
    set(INSTALLETCDIR "${XYMONTOPDIR}/etc")
    set(INSTALLEXTDIR "${XYMONTOPDIR}/ext")
    set(INSTALLTMPDIR "${XYMONTOPDIR}/tmp")
    set(INSTALLWEBDIR "${XYMONTOPDIR}/web")
    set(INSTALLWWWDIR "${XYMONTOPDIR}/www")
endif()

set(XYMONHOME_INSTALL_DEST "${XYMONHOME}")
set(XYMONHOME_INSTALL_FULL "${XYMONHOME}")
set(XYMONCLIENTHOME_INSTALL_DEST "${XYMONCLIENTHOME}")
set(XYMONCLIENTHOME_INSTALL_FULL "${XYMONCLIENTHOME}")
set(XYMONVAR_INSTALL_DEST "${XYMONVAR}")
set(XYMONVAR_INSTALL_FULL "${XYMONVAR}")
set(XYMONLOGDIR_INSTALL_DEST "${XYMONLOGDIR}")
set(XYMONLOGDIR_INSTALL_FULL "${XYMONLOGDIR}")

set(INSTALLBINDIR_DEST "${INSTALLBINDIR}")
set(INSTALLBINDIR_FULL "${INSTALLBINDIR}")
set(INSTALLETCDIR_DEST "${INSTALLETCDIR}")
set(INSTALLETCDIR_FULL "${INSTALLETCDIR}")
set(INSTALLEXTDIR_DEST "${INSTALLEXTDIR}")
set(INSTALLEXTDIR_FULL "${INSTALLEXTDIR}")
set(INSTALLTMPDIR_DEST "${INSTALLTMPDIR}")
set(INSTALLTMPDIR_FULL "${INSTALLTMPDIR}")
set(INSTALLWEBDIR_DEST "${INSTALLWEBDIR}")
set(INSTALLWEBDIR_FULL "${INSTALLWEBDIR}")
set(INSTALLWWWDIR_DEST "${INSTALLWWWDIR}")
set(INSTALLWWWDIR_FULL "${INSTALLWWWDIR}")
set(CGIDIR_DEST "${CGIDIR}")
set(CGIDIR_FULL "${CGIDIR}")
set(SECURECGIDIR_DEST "${SECURECGIDIR}")
set(SECURECGIDIR_FULL "${SECURECGIDIR}")

set(INSTALLMAN1DIR_DEST "${XYMONHOME}/man/man1")
set(INSTALLMAN1DIR_FULL "${XYMONHOME}/man/man1")
set(INSTALLMAN5DIR_DEST "${XYMONHOME}/man/man5")
set(INSTALLMAN5DIR_FULL "${XYMONHOME}/man/man5")
set(INSTALLMAN7DIR_DEST "${XYMONHOME}/man/man7")
set(INSTALLMAN7DIR_FULL "${XYMONHOME}/man/man7")
set(INSTALLMAN8DIR_DEST "${XYMONHOME}/man/man8")
set(INSTALLMAN8DIR_FULL "${XYMONHOME}/man/man8")

if(XYMON_LAYOUT STREQUAL "fhs")
    set(XYMONHOME_INSTALL_DEST "${CMAKE_INSTALL_LIBEXECDIR}/xymon/server")
    set(XYMONHOME_INSTALL_FULL "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xymon/server")
    set(XYMONCLIENTHOME_INSTALL_DEST "${CMAKE_INSTALL_LIBEXECDIR}/xymon/client")
    set(XYMONCLIENTHOME_INSTALL_FULL "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xymon/client")
    set(XYMONVAR_INSTALL_DEST "${CMAKE_INSTALL_LOCALSTATEDIR}/lib/xymon")
    set(XYMONVAR_INSTALL_FULL "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/lib/xymon")
    set(XYMONLOGDIR_INSTALL_DEST "${CMAKE_INSTALL_LOCALSTATEDIR}/log/xymon")
    set(XYMONLOGDIR_INSTALL_FULL "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/log/xymon")

    set(INSTALLBINDIR_DEST "${XYMONHOME_INSTALL_DEST}/bin")
    set(INSTALLBINDIR_FULL "${XYMONHOME_INSTALL_FULL}/bin")
    set(INSTALLETCDIR_DEST "${CMAKE_INSTALL_SYSCONFDIR}/xymon")
    set(INSTALLETCDIR_FULL "${CMAKE_INSTALL_FULL_SYSCONFDIR}/xymon")
    set(INSTALLEXTDIR_DEST "${XYMONHOME_INSTALL_DEST}/ext")
    set(INSTALLEXTDIR_FULL "${XYMONHOME_INSTALL_FULL}/ext")
    set(INSTALLTMPDIR_DEST "${CMAKE_INSTALL_LOCALSTATEDIR}/lib/xymon/tmp")
    set(INSTALLTMPDIR_FULL "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/lib/xymon/tmp")
    set(INSTALLWEBDIR_DEST "${CMAKE_INSTALL_SYSCONFDIR}/xymon/web")
    set(INSTALLWEBDIR_FULL "${CMAKE_INSTALL_FULL_SYSCONFDIR}/xymon/web")
    set(INSTALLWWWDIR_DEST "${CMAKE_INSTALL_LOCALSTATEDIR}/lib/xymon/www")
    set(INSTALLWWWDIR_FULL "${CMAKE_INSTALL_FULL_LOCALSTATEDIR}/lib/xymon/www")
    set(CGIDIR_DEST "${CMAKE_INSTALL_LIBEXECDIR}/xymon/cgi-bin")
    set(CGIDIR_FULL "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xymon/cgi-bin")
    set(SECURECGIDIR_DEST "${CMAKE_INSTALL_LIBEXECDIR}/xymon/cgi-secure")
    set(SECURECGIDIR_FULL "${CMAKE_INSTALL_FULL_LIBEXECDIR}/xymon/cgi-secure")

    set(INSTALLMAN1DIR_DEST "${CMAKE_INSTALL_MANDIR}/man1")
    set(INSTALLMAN1DIR_FULL "${CMAKE_INSTALL_FULL_MANDIR}/man1")
    set(INSTALLMAN5DIR_DEST "${CMAKE_INSTALL_MANDIR}/man5")
    set(INSTALLMAN5DIR_FULL "${CMAKE_INSTALL_FULL_MANDIR}/man5")
    set(INSTALLMAN7DIR_DEST "${CMAKE_INSTALL_MANDIR}/man7")
    set(INSTALLMAN7DIR_FULL "${CMAKE_INSTALL_FULL_MANDIR}/man7")
    set(INSTALLMAN8DIR_DEST "${CMAKE_INSTALL_MANDIR}/man8")
    set(INSTALLMAN8DIR_FULL "${CMAKE_INSTALL_FULL_MANDIR}/man8")
endif()

configure_file(
    "${CMAKE_SOURCE_DIR}/cmake/XymonInstallHelpers.cmake.in"
    "${CMAKE_BINARY_DIR}/XymonInstallHelpers.cmake"
    @ONLY
)

configure_file(
    "${CMAKE_SOURCE_DIR}/cmake/config.h.in"
    "${CMAKE_BINARY_DIR}/config.h"
    @ONLY
)

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
)

if(XYMON_BUILD_SERVER)
    add_custom_command(
        TARGET install-legacy-dirs POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory
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
endif()

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
if(TARGET setup-newfiles)
    add_dependencies(install-legacy-files setup-newfiles)
endif()
if(TARGET web_cgi_links)
    add_dependencies(install-legacy-files web_cgi_links)
endif()
if(TARGET docs)
    add_dependencies(install-legacy-files docs)
endif()

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
  COMMAND find .
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

if(XYMON_BUILD_SERVER)
    if(EXISTS "${CMAKE_SOURCE_DIR}/web/webfiles")
        add_custom_command(
            TARGET install-legacy-files POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_directory
                    "${CMAKE_SOURCE_DIR}/web/webfiles"
                    "${LEGACY_DESTDIR}${INSTALLWEBDIR}"
        )
    endif()
    if(TARGET setup-newfiles AND EXISTS "${CMAKE_SOURCE_DIR}/xymond/webfiles" AND EXISTS "${CMAKE_SOURCE_DIR}/build/md5.dat")
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
    if(TARGET setup-newfiles AND EXISTS "${CMAKE_SOURCE_DIR}/xymond/wwwfiles" AND EXISTS "${CMAKE_SOURCE_DIR}/build/md5.dat")
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
        COMMAND find
                "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
                -type d -exec chmod 755 {} +
    )

    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND find
                "${LEGACY_DESTDIR}${INSTALLWWWDIR}"
                -type f -exec chmod 644 {} +
    )

    # Legacy make install keeps report/snapshot directories group-writable.
    # Apply this even in staging mode (LEGACY_APPLY_OWNERSHIP=OFF).
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND chmod 775 "${LEGACY_DESTDIR}${INSTALLWWWDIR}/rep"
        COMMAND chmod 775 "${LEGACY_DESTDIR}${INSTALLWWWDIR}/snap"
    )
endif()

if(LEGACY_APPLY_OWNERSHIP)
    if(XYMON_BUILD_CLIENT)
        add_custom_command(
            TARGET install-legacy-files POST_BUILD
            COMMAND chown -R "${XYMONUSER}:${XYMONUSER}"
                    "${LEGACY_DESTDIR}${XYMONCLIENTHOME}"
        )
    endif()
    if(XYMON_BUILD_SERVER)
        add_custom_command(
            TARGET install-legacy-files POST_BUILD
            COMMAND chown -R "${XYMONUSER}:${XYMONUSER}"
                    "${LEGACY_DESTDIR}${XYMONHOME}"
                    "${LEGACY_DESTDIR}${XYMONVAR}"
                    "${LEGACY_DESTDIR}${CGIDIR}"
                    "${LEGACY_DESTDIR}${SECURECGIDIR}"
        )

        # Legacy make keeps these top-level directories owned by root.
        if(XYMON_INSTALL_MANPAGES)
            add_custom_command(
                TARGET install-legacy-files POST_BUILD
                COMMAND chown root:0 "${LEGACY_DESTDIR}${CGIDIR}"
                COMMAND chown root:0 "${LEGACY_DESTDIR}${SECURECGIDIR}"
                COMMAND chown root:0 "${LEGACY_DESTDIR}${XYMONHOME}/man"
            )
        else()
            add_custom_command(
                TARGET install-legacy-files POST_BUILD
                COMMAND chown root:0 "${LEGACY_DESTDIR}${CGIDIR}"
                COMMAND chown root:0 "${LEGACY_DESTDIR}${SECURECGIDIR}"
            )
        endif()
    endif()
endif()

# ----------------------------------------------------------------------
# Vérification et application du groupe HTTPDGID
# ----------------------------------------------------------------------
if(LEGACY_APPLY_OWNERSHIP AND HTTPDGID_CHGRP AND HTTPDGID AND XYMON_BUILD_SERVER)
    # Legacy make applies the HTTP group only to report/snapshot outputs and critical cfg.
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND chgrp -R "${HTTPDGID}" "${LEGACY_DESTDIR}${INSTALLWWWDIR}/rep"
        COMMAND chgrp -R "${HTTPDGID}" "${LEGACY_DESTDIR}${INSTALLWWWDIR}/snap"
        COMMAND chgrp "${HTTPDGID}" "${LEGACY_DESTDIR}${INSTALLETCDIR}/critical.cfg"
        COMMAND chgrp "${HTTPDGID}" "${LEGACY_DESTDIR}${INSTALLETCDIR}/critical.cfg.bak"
        COMMAND chmod -R g+w "${LEGACY_DESTDIR}${INSTALLWWWDIR}/rep"
        COMMAND chmod -R g+w "${LEGACY_DESTDIR}${INSTALLWWWDIR}/snap"
        COMMENT "Application du groupe web ${HTTPDGID} sur les dossiers de rapports"
    )
endif()

# ----------------------------------------------------------------------
# Cas spécifique : xymonping (SETUID) via CMake Scripting
# ----------------------------------------------------------------------
if(LEGACY_APPLY_OWNERSHIP AND XYMON_BUILD_SERVER)
    add_custom_command(
        TARGET install-legacy-files POST_BUILD
        COMMAND chown root:"${XYMONUSER}" "${LEGACY_DESTDIR}${INSTALLBINDIR}/xymonping"
        COMMAND chmod 4755 "${LEGACY_DESTDIR}${INSTALLBINDIR}/xymonping"
    )
endif()

# ----------------------------------------------------------------------
# Docker build helper targets (Debian family)
# ----------------------------------------------------------------------
set(XYMON_DOCKER_COMPOSE_FILE "${CMAKE_BINARY_DIR}/docker-compose.yml")
set(XYMON_PLATFORM_CATALOG_FILE "${CMAKE_SOURCE_DIR}/ci/deps/platform-catalog.yaml")
set(XYMON_DOCKER_MATRIX_RESOLVER "${CMAKE_SOURCE_DIR}/ci/run/docker/resolve-matrix.py")
find_program(XYMON_DOCKER_PYTHON_EXECUTABLE NAMES python3 python)

if(XYMON_DOCKER_PYTHON_EXECUTABLE
        AND EXISTS "${XYMON_DOCKER_MATRIX_RESOLVER}"
        AND EXISTS "${XYMON_PLATFORM_CATALOG_FILE}")
    execute_process(
        COMMAND "${XYMON_DOCKER_PYTHON_EXECUTABLE}" "${XYMON_DOCKER_MATRIX_RESOLVER}"
                --platform-catalog "${XYMON_PLATFORM_CATALOG_FILE}"
                --list-targets
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        RESULT_VARIABLE XYMON_DOCKER_SERVICE_RESULT
        OUTPUT_VARIABLE XYMON_DOCKER_SERVICE_OUTPUT
        ERROR_VARIABLE XYMON_DOCKER_SERVICE_ERROR
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )

    if(NOT XYMON_DOCKER_SERVICE_RESULT EQUAL 0)
        string(STRIP "${XYMON_DOCKER_SERVICE_ERROR}" XYMON_DOCKER_SERVICE_ERROR)
        if(XYMON_DOCKER_SERVICE_ERROR STREQUAL "")
            set(XYMON_DOCKER_SERVICE_ERROR "resolver returned ${XYMON_DOCKER_SERVICE_RESULT}")
        endif()
        message(WARNING "Docker helper targets disabled: ${XYMON_DOCKER_SERVICE_ERROR}")
    else()
        set(XYMON_DOCKER_SERVICE_LIST "${XYMON_DOCKER_SERVICE_OUTPUT}")
        if(XYMON_DOCKER_SERVICE_LIST STREQUAL "")
            message(WARNING "Docker helper targets disabled: no docker_build entries found in ${XYMON_PLATFORM_CATALOG_FILE}")
        else()
            string(REPLACE "\n" ";" XYMON_DOCKER_SERVICE_LIST "${XYMON_DOCKER_SERVICE_LIST}")

            add_custom_target(docker-generate
                COMMAND "${XYMON_DOCKER_PYTHON_EXECUTABLE}" "${XYMON_DOCKER_MATRIX_RESOLVER}"
                        --platform-catalog "${XYMON_PLATFORM_CATALOG_FILE}"
                        --compose-output "${XYMON_DOCKER_COMPOSE_FILE}"
                DEPENDS "${XYMON_PLATFORM_CATALOG_FILE}" "${XYMON_DOCKER_MATRIX_RESOLVER}"
                WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
                COMMENT "Regenerate Docker definitions from the platform catalog"
            )

            set(XYMON_DOCKER_TARGETS)
            foreach(_xy_mon_service ${XYMON_DOCKER_SERVICE_LIST})
                string(STRIP _xy_mon_service "${_xy_mon_service}")
                if(_xy_mon_service STREQUAL "")
                    continue()
                endif()
                set(_xy_mon_target "docker-${_xy_mon_service}")
                add_custom_target(${_xy_mon_target}
                    COMMAND docker compose -f "${XYMON_DOCKER_COMPOSE_FILE}" build "${_xy_mon_service}"
                    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
                    USES_TERMINAL
                    COMMENT "Build Docker image: ${_xy_mon_service}"
                )
                add_dependencies(${_xy_mon_target} docker-generate)
                list(APPEND XYMON_DOCKER_TARGETS ${_xy_mon_target})
            endforeach()

            if(XYMON_DOCKER_TARGETS)
                add_custom_target(docker-debian-family DEPENDS ${XYMON_DOCKER_TARGETS})
            endif()
        endif()
    endif()
endif()
