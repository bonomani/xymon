/*
 * RRDtool argv-API probe, compiled by build/Makefile.test-rrd from build/rrd.sh.
 *
 * Modern RRDtool declares rrd_update() as (int, const char **); older releases
 * use (int, char **). Redeclaring with the prototype that matches the installed
 * rrd.h compiles cleanly; the other one is a conflicting declaration and fails.
 * build/rrd.sh compiles this twice (with and without -DRRD_ARGV_CONST) and keeps
 * whichever succeeds, then sets -DRRD_CONST_ARGS accordingly.
 */
#include <rrd.h>

#ifdef RRD_ARGV_CONST
int rrd_update(int, const char **);
#else
int rrd_update(int, char **);
#endif

int main(void) { return 0; }
