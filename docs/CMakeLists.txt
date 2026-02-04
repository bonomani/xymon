# docs/CMakeLists.txt

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/xymon-tips.html.DIST
    ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
    @ONLY
)

add_custom_target(docs ALL
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
)

install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/xymon-tips.html
    DESTINATION ${INSTALLWWWDIR}/help
)

file(GLOB _DOC_HELP_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/*.html"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.txt"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.png"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.jpg"
)
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*/xymon-tips\\.html\\.DIST$")
list(FILTER _DOC_HELP_FILES EXCLUDE REGEX ".*/man-index\\.html$")

install(FILES ${_DOC_HELP_FILES}
    DESTINATION ${INSTALLWWWDIR}/help
)
install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/manpages/
    DESTINATION ${INSTALLWWWDIR}/help/manpages
)
install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/man-index.html
    DESTINATION ${INSTALLWWWDIR}/help/manpages
    RENAME index.html
)
