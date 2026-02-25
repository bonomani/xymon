include(CheckCSourceCompiles)

function(xymon_check_rrdtool12 include_dir library result_var)
    if(NOT include_dir OR NOT library)
        set(${result_var} OFF PARENT_SCOPE)
        return()
    endif()

    set(_XYMON_RRDTOOL12_CHECK_SOURCE [=[
#include <stdio.h>
#include <rrd.h>
int main(void) {
    int x = 0, y = 0;
    char **args = NULL;
    char ***calc = NULL;
    return rrd_graph(0, args, calc, &x, &y, (FILE *)0, (double *)0, (double *)0);
}
]=])

    set(_XYMON_SAVE_CMAKE_REQUIRED_INCLUDES ${CMAKE_REQUIRED_INCLUDES})
    set(_XYMON_SAVE_CMAKE_REQUIRED_LIBRARIES ${CMAKE_REQUIRED_LIBRARIES})
    set(CMAKE_REQUIRED_INCLUDES "${include_dir}")
    set(CMAKE_REQUIRED_LIBRARIES "${library}")
    check_c_source_compiles("${_XYMON_RRDTOOL12_CHECK_SOURCE}" _XYMON_RRDTOOL12_CHECK)
    set(${result_var} ${_XYMON_RRDTOOL12_CHECK} PARENT_SCOPE)
    set(CMAKE_REQUIRED_INCLUDES ${_XYMON_SAVE_CMAKE_REQUIRED_INCLUDES})
    set(CMAKE_REQUIRED_LIBRARIES ${_XYMON_SAVE_CMAKE_REQUIRED_LIBRARIES})
endfunction()
