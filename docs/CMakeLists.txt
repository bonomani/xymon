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
