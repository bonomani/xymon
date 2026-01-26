# xymonnet/CMakeLists.txt

option(ENABLE_LDAP "Enable LDAP checks" OFF)
option(ENABLE_CARES "Enable c-ares support" ON)
option(ENABLE_SNMP "Enable SNMP collector" OFF)

find_library(TIRPC_LIBRARY tirpc)
find_path(TIRPC_INCLUDE_DIR rpc/rpc.h PATH_SUFFIXES tirpc)
find_library(CARES_LIBRARY cares)
find_library(LDAP_LIBRARY ldap)
find_library(LBER_LIBRARY lber)

add_executable(xymonnet
    xymonnet.c
    contest.c
    httptest.c
    httpresult.c
    ldaptest.c
    dns.c
    dns2.c
    httpcookies.c
)
if(ENABLE_LDAP)
    target_compile_definitions(xymonnet PRIVATE HAVE_LDAP)
endif()
if(ENABLE_CARES AND CARES_LIBRARY)
    target_link_libraries(xymonnet ${CARES_LIBRARY})
endif()
if(ENABLE_LDAP AND LDAP_LIBRARY AND LBER_LIBRARY)
    target_link_libraries(xymonnet ${LDAP_LIBRARY} ${LBER_LIBRARY})
endif()
if(TIRPC_LIBRARY)
    target_link_libraries(xymonnet ${TIRPC_LIBRARY})
    if(TIRPC_INCLUDE_DIR)
        target_include_directories(xymonnet PRIVATE ${TIRPC_INCLUDE_DIR})
    endif()
endif()
target_link_libraries(xymonnet
    xymontime
    xymoncomm
    xymon
    pcre
    ssl
    crypto
)

add_executable(xymonping
    xymonping.c
)
if(TIRPC_LIBRARY)
    target_link_libraries(xymonping ${TIRPC_LIBRARY})
    if(TIRPC_INCLUDE_DIR)
        target_include_directories(xymonping PRIVATE ${TIRPC_INCLUDE_DIR})
    endif()
endif()
target_link_libraries(xymonping
    xymontime
    xymoncomm
    ssl
    crypto
)

add_executable(beastat
    beastat.c
)
if(TIRPC_LIBRARY)
    target_link_libraries(beastat ${TIRPC_LIBRARY})
    if(TIRPC_INCLUDE_DIR)
        target_include_directories(beastat PRIVATE ${TIRPC_INCLUDE_DIR})
    endif()
endif()
target_link_libraries(beastat
    xymoncomm
    xymontime
    xymoncomm
    pcre
    ssl
    crypto
)

add_executable(contest
    contest.c
    httptest.c
    dns.c
    dns2.c
    httpcookies.c
)
target_compile_definitions(contest PRIVATE STANDALONE)
if(ENABLE_CARES AND CARES_LIBRARY)
    target_link_libraries(contest ${CARES_LIBRARY})
endif()
if(TIRPC_LIBRARY)
    target_link_libraries(contest ${TIRPC_LIBRARY})
    if(TIRPC_INCLUDE_DIR)
        target_include_directories(contest PRIVATE ${TIRPC_INCLUDE_DIR})
    endif()
endif()
target_link_libraries(contest
    -Wl,--start-group
    xymontime
    xymoncomm
    -Wl,--end-group
    ssl
    crypto
)

if(ENABLE_SNMP)
    add_executable(xymon-snmpcollect
        xymon-snmpcollect.c
    )
    target_link_libraries(xymon-snmpcollect
        xymon
        xymoncomm
        xymontime
    )
    install(TARGETS xymon-snmpcollect
        RUNTIME DESTINATION ${INSTALLBINDIR}
    )
endif()

install(TARGETS xymonnet xymonping beastat contest
    RUNTIME DESTINATION ${INSTALLBINDIR}
)
