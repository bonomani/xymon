# docs/CMakeLists.txt

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/xymon-tips.html.DIST
    ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
    @ONLY
)

add_custom_target(docs ALL
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
)

file(GLOB _DOC_HELP_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/*.html"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.png"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.jpg"
)
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*/xymon-tips\\.html\\.DIST$")
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*/man-index\\.html$")

if(XYMON_LAYOUT STREQUAL "fhs")
    set(_DOC_HELP_FILES_FHS "${_DOC_HELP_FILES}")
    set(_XYMONDOCS_FHS_INSTALL_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/install-fhs-help.cmake")
    configure_file(
        "${CMAKE_SOURCE_DIR}/cmake/XymonDocsInstallFhs.cmake.in"
        "${_XYMONDOCS_FHS_INSTALL_SCRIPT}"
        @ONLY
    )
    install(SCRIPT "${_XYMONDOCS_FHS_INSTALL_SCRIPT}")
else()
    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
        DESTINATION ${INSTALLWWWDIR_DEST}/help
    )

    install(FILES ${_DOC_HELP_FILES}
        DESTINATION ${INSTALLWWWDIR_DEST}/help
    )
    install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/manpages/
        DESTINATION ${INSTALLWWWDIR_DEST}/help/manpages
    )
    install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/man-index.html
        DESTINATION ${INSTALLWWWDIR_DEST}/help/manpages
        RENAME index.html
    )
endif()
