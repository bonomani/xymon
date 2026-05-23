# docs/CMakeLists.txt

# Doc files generated at configure time from *.DIST templates. Placeholders
# (@INSTALLWWWDIR@, @CGIDIR@, ...) come from the top-level CMakeLists.txt.
# Mirrors the legacy docs/Makefile substitution rules.
set(_DOC_GENERATED "")
foreach(_doc xymon-tips.html xymon-apacheconf.txt install.html)
    configure_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/${_doc}.DIST
        ${CMAKE_CURRENT_BINARY_DIR}/${_doc}
        @ONLY
    )
    list(APPEND _DOC_GENERATED ${CMAKE_CURRENT_BINARY_DIR}/${_doc})
endforeach()

add_custom_target(docs ALL DEPENDS ${_DOC_GENERATED})

file(GLOB _DOC_HELP_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/*.html"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.png"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.jpg"
)
# *.DIST files don't match the *.html/*.txt globs above, so the exclude
# below is only needed for the historical xymon-tips.html.DIST entry --
# kept defensive in case future globs widen.
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*\\.DIST$")
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*/man-index\\.html$")

if(XYMON_LAYOUT STREQUAL "fhs")
    set(_DOC_HELP_FILES_FHS "${_DOC_HELP_FILES}")
    set(_DOC_GENERATED_FHS "${_DOC_GENERATED}")
    set(_XYMONDOCS_FHS_INSTALL_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/install-fhs-help.cmake")
    configure_file(
        "${CMAKE_SOURCE_DIR}/cmake/XymonDocsInstallFhs.cmake.in"
        "${_XYMONDOCS_FHS_INSTALL_SCRIPT}"
        @ONLY
    )
    install(SCRIPT "${_XYMONDOCS_FHS_INSTALL_SCRIPT}")
else()
    install(FILES ${_DOC_GENERATED}
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
